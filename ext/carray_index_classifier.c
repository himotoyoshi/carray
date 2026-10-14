/* ---------------------------------------------------------------------------

  Index classifier for `[]` / `[]=` — turns the argv passed to
  CArray subscription into a CAIndexInfo describing the region
  (POINT / BLOCK / ITERATOR / ADDRESS / GRID / SELECT / …).  The
  public entry `rb_ca_scan_index` in ca_obj_access.c forwards to
  `rb_ca_scan_index_v2` here.

  See docs/topics/Indexer_decision_tree.md for the wire-format spec.

  Design shape:
    - one REG per handler function (grep-friendly)
    - rubber-dim pre-pass with a stack-allocated argv_expanded slot
    - a single negative-index normaliser used by all handlers
    - fast paths (POINT / ADDRESS, ndim == argc, all-FIXNUM) at
      the top of the entry point
    - single-character alphabetic Symbols (:a-:z / :A-:Z) are
      reserved and kept free of meaning; the classifier raises
      IndexError when they appear.

--------------------------------------------------------------------------- */

#include "carray.h"
#include <math.h>
#include "carray_internal.h"   /* ca_index_in_range_at */
#include "carray_index_classifier.h"

/* Range accessor macros — carray_access.c keeps a private cache
   with the same shape; the duplication here keeps this file
   self-contained without cross-file symbol exposure. */
static ID ca_classifier_id_begin    = 0;
static ID ca_classifier_id_end      = 0;
static ID ca_classifier_id_excl_end = 0;
#define CA_CLASSIFIER_RANGE_BEG(r)  (rb_funcall((r), ca_classifier_id_begin,    0))
#define CA_CLASSIFIER_RANGE_END(r)  (rb_funcall((r), ca_classifier_id_end,      0))
#define CA_CLASSIFIER_RANGE_EXCL(r) (rb_funcall((r), ca_classifier_id_excl_end, 0))

/* -------------------------------------------------------------------- */
/* Symbol cache — see the range-macro comment above for why this
   file keeps its own copy independent of carray_access.c. */

static VALUE ca_classifier_sym_perc  = Qundef;
static VALUE ca_classifier_sym_under = Qundef;
static VALUE ca_classifier_sym_gt    = Qundef;   /* :> slab-iterator marker */
static VALUE ca_classifier_sym_tilde = Qundef;   /* :~ rubber-dim alias for `false` */

static inline void
ca_classifier_sym_cache_init (void)
{
  if ( ca_classifier_sym_perc == Qundef ) {
    ca_classifier_sym_perc  = ID2SYM(rb_intern("%"));
    ca_classifier_sym_under = ID2SYM(rb_intern("_"));
    ca_classifier_sym_gt    = ID2SYM(rb_intern(">"));
    ca_classifier_sym_tilde = ID2SYM(rb_intern("~"));
    ca_classifier_id_begin    = rb_intern("begin");
    ca_classifier_id_end      = rb_intern("end");
    ca_classifier_id_excl_end = rb_intern("exclude_end?");
  }
}

/* -------------------------------------------------------------------- */
/* Classifier context — every handler reads / writes through this
   struct.  Lives on rb_ca_scan_index_v2's stack; not exposed. */

typedef struct {
  /* inputs (read-only after init) */
  int          ca_ndim;
  ca_size_t   *ca_dim;
  ca_size_t    ca_elements;
  long         argc;        /* may be adjusted by rubber-dim expansion */
  VALUE       *argv;        /* points at argv_expanded after pre-pass */

  /* output (target of handlers) */
  CAIndexInfo *info;

  /* working storage for rubber-dim expansion */
  VALUE        argv_expanded[CA_RANK_MAX];
} ca_classifier_ctx_t;

/* -------------------------------------------------------------------- */
/* helpers */

/* Negative-index normalisation gathered in one place, replacing
   the CA_CHECK_INDEX_AT macro that used to be expanded at every
   call site.  Error-message format is byte-identical with the
   legacy path so downstream error-message assertions still match. */
static inline ca_size_t
ca_classifier_normalize_axis_index (ca_size_t k, ca_size_t dim, int axis, int range_check)
{
  ca_size_t given = k;
  if ( k < 0 ) {
    k += dim;
  }
  if ( range_check && ( k < 0 || k >= dim ) ) {
    ca_index_out_of_range_at(given, dim, axis);
  }
  return k;
}

/* Whether a range picks no cells along an axis of length dim: an exclusive
   range that ends where it starts, or an endless one that starts at the end
   of the axis.  `last` has been counted from the end already; `start` has
   not.  A range in CArray otherwise always picks a cell -- one ending
   before its start reads backwards. */
static inline int
ca_classifier_range_is_empty (ca_size_t start, ca_size_t last, int excl,
                              int endless, ca_size_t dim)
{
  ca_size_t s = ( start < 0 ) ? start + dim : start;
  return endless ? ( s == dim ) : ( excl && s == last );
}

/* The first index of a run of cells along an axis.  A run of no cells may
   start at the end of the axis (position n), as an empty slice at the end
   of a Ruby Array does; a run with cells has to start on one. */
static inline ca_size_t
ca_classifier_run_start (ca_size_t idx, ca_size_t n, int axis, int empty)
{
  ca_size_t i = ( idx < 0 ) ? idx + n : idx;
  if ( i < 0 || i > n || ( ! empty && i == n ) ) {
    ca_index_out_of_range_at(idx, n, axis);
  }
  return i;
}

/* Flat-address normalisation for the `argc == 1, ndim > 1,
   Integer` path.  CA_CHECK_INDEX does not carry axis info in its
   message, which is the intended behaviour on the flat path. */
static inline ca_size_t
ca_classifier_normalize_flat_address (ca_size_t addr, ca_size_t elements, int range_check)
{
  if ( range_check ) {
    CA_CHECK_INDEX(addr, elements);
  }
  return addr;
}

NORETURN(static void ca_classifier_invalid_key (VALUE v, int axis));
static void
ca_classifier_invalid_key (VALUE v, int axis)
{
  volatile VALUE s = rb_inspect(v);
  rb_raise(rb_eIndexError,
           "object '%s' is invalid for the index for reference at %i-dim",
           StringValueCStr(s), axis);
}

/* A Bignum key is past the end of any axis, but has no ca_size_t to report
   through ca_index_out_of_range_at; it is reported as it was given. */
NORETURN(static void ca_classifier_key_too_large (VALUE v, const char *where));
static void
ca_classifier_key_too_large (VALUE v, const char *where)
{
  volatile VALUE s = rb_inspect(v);
  rb_raise(rb_eIndexError, "%s: index %s is out of range%s",
           ca_calling_method_name(), StringValueCStr(s), where);
}

/* A key names a position when it holds an integer: a Fixnum, or a Float
   with no fraction (a count from `sum` is a Float).  Returns 1 with the
   position in *out, 2 for an integer past any axis (a Bignum, or a Float
   beyond the Fixnum range), and 0 for anything else (a Float with a
   fraction, NaN, Inf, a Rational, a String). */
static int
ca_classifier_key_position (VALUE v, ca_size_t *out)
{
  if ( FIXNUM_P(v) ) {
    *out = (ca_size_t) FIX2LONG(v);
    return 1;
  }
  if ( RB_FLOAT_TYPE_P(v) ) {
    double d = RFLOAT_VALUE(v);
    if ( ! isfinite(d) || d != floor(d) ) {
      return 0;
    }
    if ( d < -4.6e18 || d > 4.6e18 ) {
      return 2;
    }
    *out = (ca_size_t) d;
    return 1;
  }
  if ( RB_TYPE_P(v, T_BIGNUM) ) {
    return 2;
  }
  return 0;
}

/* A key that has to name a position: a scalar key, or one inside a Range,
   an Array form or a step.  `where` follows the value in the out-of-range
   message. */
static ca_size_t
ca_classifier_key_int_where (VALUE v, int axis, const char *where)
{
  ca_size_t k;
  switch ( ca_classifier_key_position(v, &k) ) {
  case 1:
    return k;
  case 2:
    ca_classifier_key_too_large(v, where);
  default:
    ca_classifier_invalid_key(v, axis);
  }
}

static ca_size_t
ca_classifier_key_int (VALUE v, int axis)
{
  char where[32];
  snprintf(where, sizeof(where), " on axis %d", axis);
  return ca_classifier_key_int_where(v, axis, where);
}

int
ca_index_key_is_scalar (VALUE arg)
{
  return FIXNUM_P(arg) || RB_FLOAT_TYPE_P(arg) || RB_TYPE_P(arg, T_BIGNUM);
}

/* A step: an integer like any key, except that one past any axis is not
   past anything -- it is a step larger than any axis, so it reaches one
   cell.  It is read as the largest Fixnum of its sign, which does the
   same. */
static ca_size_t
ca_classifier_key_step (VALUE v, int axis)
{
  ca_size_t k;
  if ( ca_classifier_key_position(v, &k) == 2 ) {
    int positive = RB_FLOAT_TYPE_P(v) ? ( RFLOAT_VALUE(v) > 0 ) : rb_big_sign(v);
    return positive ? (ca_size_t) FIXNUM_MAX : (ca_size_t) FIXNUM_MIN;
  }
  return ca_classifier_key_int(v, axis);
}

/* An axis of length 0 has no cells: a range on it reads none when it starts
   at 0 (as `[][0..-1]` does), and is out of range otherwise.  Returns 1 when
   the axis was filled in. */
static int
ca_classifier_block_on_empty_axis (CAIndexInfo *info, int axis, ca_size_t dim,
                                   ca_size_t start)
{
  if ( dim != 0 ) {
    return 0;
  }
  if ( start != 0 ) {
    ca_index_out_of_range_at(start, dim, axis);
  }
  info->index_type[axis]        = CA_IDX_BLOCK;
  info->index[axis].block.start = 0;
  info->index[axis].block.count = 0;
  info->index[axis].block.step  = 1;
  return 1;
}

/* -------------------------------------------------------------------- */
/* Fast paths. */

/* Fast path 1: ca[i, j, k] all-FIXNUM, argc == ndim → POINT.
   Returns 1 if classified, 0 if the caller should continue. */
static inline int
ca_classifier_try_point_fast_path (ca_classifier_ctx_t *ctx)
{
  long i;
  if ( ctx->argc < 1 || ctx->argc != ctx->ca_ndim ) {
    return 0;
  }
  for (i = 0; i < ctx->argc; i++) {
    if ( ! FIXNUM_P(ctx->argv[i]) ) {
      return 0;
    }
  }

  ctx->info->type = CA_REG_POINT;
  ctx->info->ndim = (int16_t) ctx->argc;
  for (i = 0; i < ctx->argc; i++) {
    ca_size_t k = FIX2LONG(ctx->argv[i]);
    if ( ctx->info->range_check ) {
      /* Bignum and Float are rejected by FIXNUM_P above; the slow path's
         integer-key branch picks them up so the
         Integer semantics are preserved end-to-end. */
      k = ca_classifier_normalize_axis_index(k, ctx->ca_dim[i], (int) i,
                                   ctx->info->range_check);
    }
    ctx->info->index_type[i] = CA_IDX_SCALAR;
    ctx->info->index[i].scalar = k;
  }
  return 1;
}

/* Fast path 2: ca[flat_addr] single FIXNUM, ndim > 1 → ADDRESS. */
static inline int
ca_classifier_try_address_fast_path (ca_classifier_ctx_t *ctx)
{
  ca_size_t addr;
  if ( ctx->argc != 1 || ctx->ca_ndim <= 1 || ! FIXNUM_P(ctx->argv[0]) ) {
    return 0;
  }
  addr = FIX2LONG(ctx->argv[0]);
  addr = ca_classifier_normalize_flat_address(addr, ctx->ca_elements,
                                    ctx->info->range_check);
  ctx->info->type = CA_REG_ADDRESS;
  ctx->info->ndim = 1;
  ctx->info->index[0].scalar = addr;
  return 1;
}

/* -------------------------------------------------------------------- */
/* Single-character alphabetic Symbols (`:a`-`:z` / `:A`-`:Z`) are
   reserved: no index form gives them a meaning, and none should
   until one is decided.  Raises IndexError saying so, rather than
   the generic "invalid as the index" message.  The caller passes
   any Symbol that is not `:_` / `:%`; a non-reserved Symbol
   returns without action. */
static inline void
ca_classifier_check_reserved_symbol (VALUE sym)
{
  const char *name;
  if ( ! SYMBOL_P(sym) ) return;
  name = rb_id2name(SYM2ID(sym));
  if ( name != NULL
       && name[0] != '\0' && name[1] == '\0'
       && ( ( name[0] >= 'a' && name[0] <= 'z' )
            || ( name[0] >= 'A' && name[0] <= 'Z' ) )
       && name[0] != '_' /* :_ is iterator marker, handled separately */ ) {
    rb_raise(rb_eIndexError,
             "symbol :%s is reserved",
             name);
  }
}

/* -------------------------------------------------------------------- */
/* Per-axis BLOCK builders.
 *
 * Each helper takes the user-supplied arg + axis index + dim and
 * populates info->index[axis].block plus
 * info->index_type[axis] = BLOCK.  Error messages are byte-
 * identical with the legacy path so downstream regexes still
 * match. */

/* Range → BLOCK */
static void
ca_classifier_axis_from_range (ca_classifier_ctx_t *ctx, int axis, VALUE arg)
{
  ca_size_t   start, last, count, step;
  int         excl;
  volatile VALUE iv_beg, iv_end, iv_excl;
  CAIndexInfo *info = ctx->info;
  ca_size_t   dim   = ctx->ca_dim[axis];

  iv_beg  = CA_CLASSIFIER_RANGE_BEG(arg);
  iv_end  = CA_CLASSIFIER_RANGE_END(arg);
  iv_excl = CA_CLASSIFIER_RANGE_EXCL(arg);

  start = NIL_P(iv_beg) ? 0  : ca_classifier_key_int(iv_beg, axis);
  last  = NIL_P(iv_end) ? -1 : ca_classifier_key_int(iv_end, axis);
  excl  = RTEST(iv_excl);

  if ( ca_classifier_block_on_empty_axis(info, axis, dim, start) ) {
    return;
  }
  info->index_type[axis] = CA_IDX_BLOCK;

  if ( last < 0 ) {
    last += dim;  /* don't use CA_CHECK_INDEX for excl */
  }
  /* No cells: an exclusive range that ends where it starts, or an endless
     one that starts at the end of the axis. */
  if ( ca_classifier_range_is_empty(start, last, excl, NIL_P(iv_end), dim) ) {
    if ( info->range_check ) {
      start = ca_classifier_run_start(start, dim, axis, 1);
    }
    info->index[axis].block.start = start;
    info->index[axis].block.count = 0;
    info->index[axis].block.step  = 1;
    return;
  }
  if ( info->range_check ) {
    start = ca_index_in_range_at(start, dim, axis);
  }
  if ( excl ) {
    last += ( last >= start ) ? -1 : 1;
  }
  if ( info->range_check ) {
    if ( last < 0 || last >= dim ) {
      ca_index_out_of_range_at(last, dim, axis);
    }
  }
  count = llabs(last - start) + 1;
  step  = ( last >= start ) ? 1 : -1;
  info->index[axis].block.start = start;
  info->index[axis].block.count = count;
  info->index[axis].block.step  = step;
}

/* A run of cells from `iv_beg` toward `iv_end` (inclusive unless excl)
   taking every `step`-th: an ArithmeticSequence, or the `[range, step]`
   form.  The step says the direction, as it does for Ruby: one that points
   away from the end reads nothing, and an endless run with a negative
   step goes down to the first cell.  A begin of nil starts at the end the
   step walks from. */
static void
ca_classifier_block_stepped (ca_classifier_ctx_t *ctx, int axis,
                             VALUE iv_beg, VALUE iv_end, int excl, ca_size_t step)
{
  ca_size_t   start, last, count, bound, s;
  int         endless = NIL_P(iv_end);
  CAIndexInfo *info = ctx->info;
  ca_size_t   dim   = ctx->ca_dim[axis];

  if ( step == 0 ) {
    rb_raise(rb_eArgError,
             "step in index equals to 0 in block reference");
  }
  start = NIL_P(iv_beg) ? ( step < 0 ? dim - 1 : 0 )
                        : ca_classifier_key_int(iv_beg, axis);
  last  = endless ? ( step < 0 ? 0 : dim - 1 )
                  : ca_classifier_key_int(iv_end, axis);
  if ( NIL_P(iv_beg) && dim == 0 ) {
    start = 0;
  }
  if ( ca_classifier_block_on_empty_axis(info, axis, dim, start) ) {
    return;
  }
  info->index_type[axis] = CA_IDX_BLOCK;
  if ( ! endless && last < 0 ) {
    last += dim;
  }
  /* CAREFUL: start is range-checked here whatever info->range_check says.
     A run that starts outside the axis would otherwise read as an empty
     region, which upstream callers do not expect. */
  s = ( start < 0 ) ? start + dim : start;
  if ( ( endless && step > 0 && s == dim ) || ( ! endless && excl && s == last ) ) {
    info->index[axis].block.start = ca_classifier_run_start(start, dim, axis, 1);
    info->index[axis].block.count = 0;
    info->index[axis].block.step  = 1;
    return;
  }
  start = ca_index_in_range_at(start, dim, axis);
  if ( excl && ! endless ) {
    last += ( last >= start ) ? -1 : 1;
  }
  if ( last < 0 || last >= dim ) {
    ca_index_out_of_range_at(last, dim, axis);
  }
  if ( (last > start && step < 0) || (last < start && step > 0) ) {
    info->index[axis].block.start = start;
    info->index[axis].block.count = 0;
    info->index[axis].block.step  = 1;
    return;
  }
  /* start and last are both inside the axis, so their distance fits; the
     step is taken by magnitude unsigned, since -step overflows at its
     minimum.  (count - 1) * step below is then at most that distance. */
  {
    unsigned long long span  = (unsigned long long)
                               (last >= start ? last - start : start - last);
    unsigned long long ustep = step < 0 ? 0ULL - (unsigned long long) step
                                        : (unsigned long long) step;
    count = (ca_size_t) (span / ustep) + 1;
  }
  bound = start + (count - 1) * step;
  bound = ca_index_in_range_at(bound, dim, axis);
  info->index[axis].block.start = start;
  info->index[axis].block.count = count;
  info->index[axis].block.step  = step;
}

#ifdef HAVE_RB_ARITHMETIC_SEQUENCE_EXTRACT
/* ArithSeq → BLOCK */
static void
ca_classifier_axis_from_arithseq (ca_classifier_ctx_t *ctx, int axis, VALUE arg)
{
  rb_arithmetic_sequence_components_t x;
  rb_arithmetic_sequence_extract(arg, &x);
  ca_classifier_block_stepped(ctx, axis, x.begin, x.end, RTEST(x.exclude_end),
                              ca_classifier_key_step(x.step, axis));
}
#endif

/* T_ARRAY → BLOCK.  Accepts [nil] / [Range] / [Integer] (len 1),
   [nil, step] / [Range, step] / [start, count] (len 2), or
   [start, count, step] (len 3). */
static void
ca_classifier_axis_from_array (ca_classifier_ctx_t *ctx, int axis, VALUE arg)
{
  CAIndexInfo *info = ctx->info;
  ca_size_t   dim   = ctx->ca_dim[axis];
  long len = RARRAY_LEN(arg);

  info->index_type[axis] = CA_IDX_BLOCK;

  if ( len == 1 ) {
    VALUE a0 = rb_ary_entry(arg, 0);
    if ( NIL_P(a0) ) {                    /* [nil] → ALL */
      info->index_type[axis] = CA_IDX_ALL;
      return;
    }
    if ( rb_obj_is_kind_of(a0, rb_cRange) ) {  /* [Range] → recurse */
      ca_classifier_axis_from_range(ctx, axis, a0);
      return;
    }
    /* [Integer] */
    {
      ca_size_t given = ca_classifier_key_int(a0, axis);
      ca_size_t start = given;
      start = ca_index_in_range_at(start, dim, axis);
      info->index[axis].block.start = start;
      info->index[axis].block.count = 1;
      info->index[axis].block.step  = 1;
      return;
    }
  }

  if ( len == 2 ) {
    VALUE a0 = rb_ary_entry(arg, 0);
    VALUE a1 = rb_ary_entry(arg, 1);

    if ( NIL_P(a0) ) {                    /* [nil, step] */
      ca_size_t start = 0, count, step;
      step = ca_classifier_key_step(a1, axis);
      if ( step == 0 ) {
        rb_raise(rb_eArgError,
                 "step in index equals to 0 in block reference");
      }
      /* every cell of the axis from the first at that step: none of an
         axis of length 0.  A negative step from the first cell reaches only
         it. */
      if ( dim == 0 ) {
        count = 0;
        step  = 1;
      }
      else if ( step < 0 ) {
        count = 1;
      }
      else {
        count = (dim - 1) / step + 1;
      }
      info->index[axis].block.start = start;
      info->index[axis].block.count = count;
      info->index[axis].block.step  = step;
      return;
    }

    if ( rb_obj_is_kind_of(a0, rb_cRange) ) {  /* [Range, step] */
      ca_classifier_block_stepped(ctx, axis,
                                  CA_CLASSIFIER_RANGE_BEG(a0),
                                  CA_CLASSIFIER_RANGE_END(a0),
                                  RTEST(CA_CLASSIFIER_RANGE_EXCL(a0)),
                                  ca_classifier_key_step(a1, axis));
      return;
    }

    /* [start, count] */
    {
      ca_size_t start, count, bound;
      ca_size_t given;
      given = ca_classifier_key_int(a0, axis);
      count = ca_classifier_key_int(a1, axis);
      /* The start counts from the end when negative; the last cell is
         counted from that start and has to be inside as it is.  A count
         of 0 may start at the end of the axis. */
      start = ca_classifier_run_start(given, dim, axis, count == 0);
      if ( count > 0 &&
           ( __builtin_add_overflow(start, count - 1, &bound) || bound >= dim ) ) {
        rb_raise(rb_eIndexError,
                 "%s: index [%" PRId64 ", %" PRId64 "] is out of range for "
                 "length %" PRId64 " on axis %i",
                 ca_calling_method_name(), (ca_size_t) given, (ca_size_t) count,
                 (ca_size_t) dim, axis);
      }
      info->index[axis].block.start = start;
      info->index[axis].block.count = count;
      info->index[axis].block.step  = 1;
      return;
    }
  }

  if ( len == 3 ) {                      /* [start, count, step] */
    ca_size_t given, start, count, step, bound;
    given = ca_classifier_key_int(rb_ary_entry(arg, 0), axis);
    count = ca_classifier_key_int(rb_ary_entry(arg, 1), axis);
    step  = ca_classifier_key_step(rb_ary_entry(arg, 2), axis);
    if ( step == 0 ) {
      rb_raise(rb_eArgError,
               "step in index equals to 0 in block reference");
    }
    /* The start counts from the end when negative; the last cell is
       counted from that start and has to be inside as it is, not a bound
       that wraps back in from either end.  A count of 0 may start at the
       end of the axis. */
    start = ca_classifier_run_start(given, dim, axis, count == 0);
    if ( count > 0 &&
         ( __builtin_mul_overflow(count - 1, step, &bound) ||
           __builtin_add_overflow(start, bound, &bound) ||
           bound < 0 || bound >= dim ) ) {
      rb_raise(rb_eIndexError,
               "%s: index [%" PRId64 ", %" PRId64 ", %" PRId64 "] is out of "
               "range for length %" PRId64 " on axis %i",
               ca_calling_method_name(), (ca_size_t) given, (ca_size_t) count,
               (ca_size_t) step, (ca_size_t) dim, axis);
    }
    info->index[axis].block.start = start;
    info->index[axis].block.count = count;
    info->index[axis].block.step  = step;
    return;
  }

  rb_raise(rb_eIndexError,
           "invalid form of index range at %i-dim "
           "(should be [start[,count[,step]]], [range, step])",
           axis);
}

/* -------------------------------------------------------------------- */
/* Per-axis dispatcher — main-loop body.
 *
 * Returns 1 to signal the main loop to STOP (a CArray at an axis
 * position triggers a REG = GRID short-circuit that skips
 * remaining axes and the post-loop ndim check).  Otherwise
 * returns 0.  Sets *out_is_grid when the GRID short-circuit
 * fires; out_is_grid must not be NULL. */
static int
ca_classifier_dispatch_axis_arg (ca_classifier_ctx_t *ctx, int axis, VALUE arg,
                         int *out_is_grid)
{
  CAIndexInfo *info = ctx->info;
  ca_size_t   dim   = ctx->ca_dim[axis];

  if ( ca_index_key_is_scalar(arg) ) {
    ca_size_t k = ca_classifier_key_int(arg, axis);
    info->index_type[axis] = CA_IDX_SCALAR;
    if ( info->range_check ) {
      k = ca_classifier_normalize_axis_index(k, dim, axis, info->range_check);
    }
    info->index[axis].scalar = k;
    return 0;
  }
  if ( NIL_P(arg) ) {
    info->index_type[axis] = CA_IDX_ALL;
    return 0;
  }
  if ( rb_obj_is_kind_of(arg, rb_cRange) ) {
    ca_classifier_axis_from_range(ctx, axis, arg);
    return 0;
  }
#ifdef HAVE_RB_ARITHMETIC_SEQUENCE_EXTRACT
  if ( rb_obj_is_kind_of(arg, rb_cArithSeq) ) {
    ca_classifier_axis_from_arithseq(ctx, axis, arg);
    return 0;
  }
#endif
  if ( TYPE(arg) == T_ARRAY ) {
    ca_classifier_axis_from_array(ctx, axis, arg);
    return 0;
  }
  if ( SYMBOL_P(arg) ) {
    /* :> is the slab-iterator marker.  :_ is newaxis, intercepted
       at the [] / []= entry before scan_index sees it — if it
       reaches this branch it slipped past the newaxis hook. */
    if ( arg == ca_classifier_sym_gt ) {
      info->index_type[axis] = CA_IDX_SYMBOL;
      info->index[axis].symbol.id   = SYM2ID(arg);
      info->index[axis].symbol.spec = Qnil;
      return 0;
    }
    if ( arg == ca_classifier_sym_under ) {
      /* :_ reached here because it slipped past the [] / []=
         newaxis hook (typically CArray.scan_index called directly). */
      rb_raise(rb_eIndexError,
               "symbol :_ (newaxis) is handled at the [] / []= level, "
               "not valid in scan_index");
    }
    ca_classifier_check_reserved_symbol(arg);  /* raises if reserved */
    rb_raise(rb_eIndexError,
             "symbol :%"PRIsVALUE" is invalid as the index for slab iterator "
             "(use :> instead)",
             rb_sym2str(arg));
  }
  if ( rb_obj_is_carray(arg) ) {
    /* CArray (boolean / integer) at an axis position → GRID.
       Signal the caller to stop populating later axes; the
       main-loop caller breaks out after this axis. */
    CArray *ci;
    TypedData_Get_Struct(arg, CArray, &carray_data_type, ci);
    if ( ca_is_boolean_type(ci) || ca_is_integer_type(ci) ) {
      if ( out_is_grid ) *out_is_grid = 1;
      return 1;  /* signal caller: stop main loop, REG = GRID */
    }
    rb_raise(rb_eIndexError,
             "data_type %s is invalid for reference by gridding at %i-dim "
             "(should be boolean or integer)",
             ca_type_name[ci->data_type], axis);
  }
  ca_classifier_invalid_key(arg, axis);
}

/* -------------------------------------------------------------------- */
/* Rubber-dim pre-pass.  Walks ctx->argv detecting Qfalse (or its
   `:~` alias), expands the rubber slot into `Qnil` fills in
   ctx->argv_expanded, and re-points ctx->argv at it.  At most one
   rubber marker is honoured; a second one falls through to the
   per-axis dispatcher and raises. */

/* Expand the rubber marker (`false` or `:~`) of a key list for an
   array of ndim axes into as many nils as it stands for, writing the
   list into out (CA_RANK_MAX slots).  Returns the new count, or -1 when
   the list has no rubber marker (out is then untouched).  Only the first
   marker is honoured; a later one is left for the axis reader to refuse. */
long
ca_index_expand_rubber (int ndim, long argc, const VALUE *argv, VALUE *out)
{
  long i, j;
  int rubber_pos = -1;
  int rndim;

  ca_classifier_sym_cache_init();
  for (i = 0; i < argc; i++) {
    if ( argv[i] == Qfalse || argv[i] == ca_classifier_sym_tilde ) {
      rubber_pos = (int) i;
      break;
    }
  }
  if ( rubber_pos < 0 ) {
    return -1;
  }
  if ( argc > ndim + 1 ) {
    rb_raise(rb_eIndexError,
             "index specification exceeds the ndim of carray (%i)", ndim);
  }
  /* CAREFUL: rndim == 0 is a valid outcome -- the rubber consumes nothing
     when argc == ndim + 1 (e.g. `[false, 0, 1]` on ndim = 2 collapses to
     `[0, 1]`).  Clamping only at the negative side preserves that path. */
  rndim = ndim - (int) argc + 1;
  if ( rndim < 0 ) rndim = 0;
  j = 0;
  for (i = 0; i < argc; i++) {
    if ( i == rubber_pos ) {
      int k;
      for (k = 0; k < rndim; k++) {
        out[j++] = Qnil;
      }
    } else {
      out[j++] = argv[i];
    }
  }
  return j;
}

static void
ca_classifier_expand_rubber_dim (ca_classifier_ctx_t *ctx)
{
  long n = ca_index_expand_rubber(ctx->ca_ndim, ctx->argc, ctx->argv,
                                  ctx->argv_expanded);
  if ( n < 0 ) {
    /* No rubber dim -- validate argc == ndim and pass through. */
    if ( ctx->argc != ctx->ca_ndim ) {
      rb_raise(rb_eIndexError,
               "%i indices given for a carray of ndim %i",
               (int) ctx->argc, ctx->ca_ndim);
    }
    return;
  }
  ctx->argc = n;
  ctx->argv = ctx->argv_expanded;
}

/* Read one key along an axis of length dim, as the indexer reads it when
   the key is not a CArray: an Integer, nil, a Range, an
   ArithmeticSequence or an Array form.  Fills *start / *count / *step and
   returns CA_IDX_SCALAR (count 1), CA_IDX_ALL (the whole axis) or
   CA_IDX_BLOCK.  Anything else raises IndexError.  grid and CASelectAxis
   read their non-CArray keys through this, so a key means the same cells
   whichever view the indexer builds. */
int
ca_index_axis_key (VALUE arg, ca_size_t dim, int axis,
                   ca_size_t *start, ca_size_t *count, ca_size_t *step)
{
  ca_classifier_ctx_t ctx;
  CAIndexInfo info;
  ca_size_t dims[CA_RANK_MAX];
  int is_grid = 0;

  ca_classifier_sym_cache_init();
  if ( axis < 0 || axis >= CA_RANK_MAX ) {
    rb_raise(rb_eArgError, "axis %d is out of range", axis);
  }
  dims[axis]   = dim;
  ctx.ca_ndim  = axis + 1;
  ctx.ca_dim   = dims;
  ctx.info     = &info;
  info.range_check = 1;
  if ( rb_obj_is_carray(arg) || arg == ca_classifier_sym_gt ) {
    ca_classifier_invalid_key(arg, axis);
  }
  ca_classifier_dispatch_axis_arg(&ctx, axis, arg, &is_grid);
  switch ( info.index_type[axis] ) {
  case CA_IDX_SCALAR:
    *start = info.index[axis].scalar;
    *count = 1;
    *step  = 1;
    return CA_IDX_SCALAR;
  case CA_IDX_ALL:
    *start = 0;
    *count = dim;
    *step  = 1;
    return CA_IDX_ALL;
  default:
    *start = info.index[axis].block.start;
    *count = info.index[axis].block.count;
    *step  = info.index[axis].block.step;
    return CA_IDX_BLOCK;
  }
}

/* -------------------------------------------------------------------- */
/* Final REG decision — walks info->index_type[] and decides
   POINT / BLOCK / ITERATOR / GRID. */

static void
ca_classifier_finalize_reg (ca_classifier_ctx_t *ctx, int is_grid)
{
  int i, is_point = 1, is_iterator = 0;
  CAIndexInfo *info = ctx->info;

  for (i = 0; i < info->ndim; i++) {
    switch ( info->index_type[i] ) {
      case CA_IDX_SCALAR: break;
      case CA_IDX_ALL:    is_point = 0; break;
      case CA_IDX_SYMBOL: is_iterator = 1; break;
      default:            is_point = 0; break;
    }
  }

  if ( is_grid )           info->type = CA_REG_GRID;
  else if ( is_iterator )  info->type = CA_REG_ITERATOR;
  else if ( is_point )     info->type = CA_REG_POINT;
  else                     info->type = CA_REG_BLOCK;

  /* CAREFUL: when REG == ITERATOR, every CA_IDX_SCALAR axis must
     be rewritten into a BLOCK with {start, count = 1, step = 1}.
     Downstream iterator machinery treats SCALAR and BLOCK
     differently, and skipping this rewrite silently changes the
     iteration shape. */
  if ( info->type == CA_REG_ITERATOR ) {
    for (i = 0; i < info->ndim; i++) {
      if ( info->index_type[i] == CA_IDX_SCALAR ) {
        ca_size_t start = info->index[i].scalar;
        info->index_type[i]           = CA_IDX_BLOCK;
        info->index[i].block.start    = start;
        info->index[i].block.step     = 1;
        info->index[i].block.count    = 1;
      }
    }
  }
}

/* -------------------------------------------------------------------- */
/* argc == 1 special dispatch.  Returns 1 if the region was
   classified here, 0 to continue to the main loop. */

static int
ca_classifier_try_argc1_special (ca_classifier_ctx_t *ctx)
{
  VALUE arg = ctx->argv[0];
  CAIndexInfo *info = ctx->info;

  /* A single Qfalse / :~ means ALL, so `ca[:~]` and `ca[false]`
     both collapse to `ca[]`. */
  if ( arg == Qfalse || arg == ca_classifier_sym_tilde ) {
    info->type = CA_REG_ALL;
    return 1;
  }

  /* T_STRING: "field" → MEMBER. */
  if ( TYPE(arg) == T_STRING ) {
    info->type   = CA_REG_MEMBER;
    info->symbol = ID2SYM(rb_intern(StringValueCStr(arg)));
    return 1;
  }

  /* argc == 1 CArray → GRID / MAPPING / SELECT. */
  if ( rb_obj_is_carray(arg) ) {
    CArray *cs;
    TypedData_Get_Struct(arg, CArray, &carray_data_type, cs);
    if ( ca_is_integer_type(cs) ) {
      if ( ctx->ca_ndim == 1 && cs->ndim == 1 ) {
        info->type = CA_REG_GRID;
      } else {
        info->type = CA_REG_MAPPING;
      }
      return 1;
    }
    if ( ca_is_boolean_type(cs) ) {
      /* A boolean selector of more than one axis states a shape, and has
         to have the array's; a 1-D one picks by position among all the
         cells. */
      if ( cs->ndim > 1 ) {
        int k, same = ( cs->ndim == ctx->ca_ndim );
        for (k = 0; same && k < cs->ndim; k++) {
          same = ( cs->dim[k] == ctx->ca_dim[k] );
        }
        if ( ! same ) {
          volatile VALUE sshape = rb_ary_new(), ashape = rb_ary_new();
          for (k = 0; k < cs->ndim; k++)     rb_ary_push(sshape, SIZE2NUM(cs->dim[k]));
          for (k = 0; k < ctx->ca_ndim; k++) rb_ary_push(ashape, SIZE2NUM(ctx->ca_dim[k]));
          rb_raise(rb_eArgError,
                   "boolean selector of shape %"PRIsVALUE" for an array of shape "
                   "%"PRIsVALUE" (a selector states its shape; use .flatten to "
                   "select by position)", sshape, ashape);
        }
      }
      if ( ctx->ca_elements != cs->elements ) {
        rb_raise(rb_eArgError,
                 "mismatch of # of elements ( %" PRId64 " <=> %" PRId64 " ) "
                 "in reference by selection",
                 (ca_size_t) cs->elements,
                 (ca_size_t) ctx->ca_elements);
      }
      info->type   = CA_REG_SELECT;
      info->select = cs;
      return 1;
    }
    rb_raise(rb_eIndexError,
             "data_type %s is invalid for reference by selection/mapping"
             "(should be boolean or integer)",
             ca_type_name[cs->data_type]);
  }

  /* ndim > 1 with an integer key → ADDRESS.  Fixnum was caught by the
     fast path; this branch handles Bignum and Float. */
  if ( ctx->ca_ndim > 1
       && ca_index_key_is_scalar(arg) ) {
    ca_size_t addr = ca_classifier_key_int_where(arg, 0, "");
    info->type = CA_REG_ADDRESS;
    info->ndim = 1;
    if ( info->range_check ) {
      CA_CHECK_INDEX(addr, ctx->ca_elements);
    }
    info->index[0].scalar = addr;
    return 1;
  }

  /* ndim > 1 with nil → FLATTEN. */
  if ( ctx->ca_ndim > 1 && NIL_P(arg) ) {
    info->type = CA_REG_FLATTEN;
    return 1;
  }

  /* ndim > 1 with Range / ArithSeq / T_ARRAY → ADDRESS_COMPLEX.
     The classifier only sets info->type here; the actual
     [start, count, step] triple is built by re-scanning argv
     against a flat dim = [elements] at the Ruby surface
     (rb_ca_s_scan_index_v2 below). */
  if ( ctx->ca_ndim > 1 ) {
    info->type = CA_REG_ADDRESS_COMPLEX;
    return 1;
  }

  /* argc == 1 && ndim == 1: fall through to the main loop
     (which classifies this as POINT 1-D). */
  return 0;
}

/* -------------------------------------------------------------------- */
/* Entry point. */

void
rb_ca_scan_index_v2 (int ca_ndim, ca_size_t *ca_dim, ca_size_t ca_elements,
                     long argc, VALUE *argv, CAIndexInfo *info)
{
  ca_classifier_ctx_t ctx;
  long i;

  ca_classifier_sym_cache_init();

  ctx.ca_ndim     = ca_ndim;
  ctx.ca_dim      = ca_dim;
  ctx.ca_elements = ca_elements;
  ctx.argc        = argc;
  ctx.argv        = argv;
  ctx.info        = info;

  info->ndim   = 0;
  info->select = NULL;

  /* argc == 0 → ALL */
  if ( argc == 0 ) {
    info->type = CA_REG_ALL;
    return;
  }

  /* argv[0] = multi-char Symbol → METHOD_CALL.  Single-char
     specials (:_ / :%) fall through the strlen check and are
     handled downstream (argc == 1 special / fast paths / main
     loop).  Single-char alphabetic reserved Symbols
     also fall through here and are raised later by the per-axis
     dispatcher's SYMBOL_P branch. */
  if ( SYMBOL_P(argv[0]) ) {
    const char *name = rb_id2name(SYM2ID(argv[0]));
    if ( name != NULL && strlen(name) > 1 ) {
      info->type   = CA_REG_METHOD_CALL;
      info->symbol = argv[0];
      return;
    }
  }

  /* Fast paths. */
  if ( ca_classifier_try_point_fast_path(&ctx) ) return;
  if ( ca_classifier_try_address_fast_path(&ctx) ) return;

  /* argc == 1 special cases. */
  if ( argc == 1 ) {
    if ( ca_classifier_try_argc1_special(&ctx) ) return;
  }

  /* Main loop entered when argc >= 1 was not handled above, or
     when argc == 1 && ndim == 1 falls through to the POINT 1-D
     classification below. */

  /* CAREFUL: pre-scan for :%.  The Symbol at any position pins the
     final REG and short-circuits both the main loop and the argc /
     ndim validation below — skipping the pre-scan lets the ndim
     mismatch check fire before the Symbol is recognised. */
  for (i = 0; i < ctx.argc; i++) {
    if ( ctx.argv[i] == ca_classifier_sym_perc ) {
      info->type = CA_REG_REPEAT;
      return;
    }
  }

  ca_classifier_expand_rubber_dim(&ctx);

  info->ndim = (int16_t) ctx.argc;
  {
    int is_grid = 0;
    int stop = 0;
    for (i = 0; i < ctx.argc && ! stop; i++) {
      stop = ca_classifier_dispatch_axis_arg(&ctx, (int) i, ctx.argv[i], &is_grid);
    }

    /* CAREFUL: the GRID short-circuit skips the post-loop ndim
       validation.  A CArray at an axis position may reduce the
       effective info->ndim below ctx.ca_ndim, and re-checking
       here would raise on legitimate grid regions. */
    if ( ! is_grid && ctx.ca_ndim != info->ndim ) {
      rb_raise(rb_eIndexError,
               "%i indices given for a carray of ndim %i",
               info->ndim, ctx.ca_ndim);
    }

    ca_classifier_finalize_reg(&ctx, is_grid);
  }
}

#ifdef CARRAY_DEV_BUILD
/* -------------------------------------------------------------------- */
/* Debug / test surface: CArray._scan_index_v2(dim_array, idx_array)
   returns a plain [type_int, index_array] pair rather than the
   full CAIndexInfo struct.  Kept for spec regression checks and
   downstream introspection. */

static VALUE
rb_ca_s_scan_index_v2 (VALUE self, VALUE rdim, VALUE ridx)
{
  CAIndexInfo info;
  ca_size_t   dim[CA_RANK_MAX];
  ca_size_t   elements;
  int         ndim, i;
  VALUE       rindex;

  Check_Type(rdim, T_ARRAY);
  Check_Type(ridx, T_ARRAY);

  ndim = (int) RARRAY_LEN(rdim);
  elements = 1;
  for (i = 0; i < ndim; i++) {
    dim[i] = NUM2SIZE(rb_ary_entry(rdim, i));
    elements *= dim[i];
  }

  CA_CHECK_RANK(ndim);
  CA_CHECK_DIM(ndim, dim);

  info.range_check = 1;
  rb_ca_scan_index_v2(ndim, dim, elements,
                      RARRAY_LEN(ridx),
                      (VALUE *) RARRAY_CONST_PTR(ridx), &info);

  rindex = rb_ary_new();
  switch ( info.type ) {
    case CA_REG_ALL:
    case CA_REG_FLATTEN:
    case CA_REG_SELECT:
    case CA_REG_REPEAT:
    case CA_REG_GRID:
    case CA_REG_MAPPING:
    case CA_REG_METHOD_CALL:
    case CA_REG_MEMBER:
    case CA_REG_ATTRIBUTE:
      break;
    case CA_REG_ADDRESS:
      rb_ary_push(rindex, SIZE2NUM(info.index[0].scalar));
      break;
    case CA_REG_ADDRESS_COMPLEX: {
      /* Recursive flat re-scan: build a 1-D dim = [elements] and
         re-classify; the resulting BLOCK / SCALAR / ALL is wrapped
         in a single-element array so the caller can consume it
         uniformly with the other cases. */
      CAIndexInfo flat_info;
      ca_size_t   flat_dim[1];
      VALUE       inner;
      flat_dim[0] = elements;
      flat_info.range_check = 1;
      rb_ca_scan_index_v2(1, flat_dim, elements,
                          RARRAY_LEN(ridx),
                          (VALUE *) RARRAY_CONST_PTR(ridx), &flat_info);
      /* Wrap index[0] as [start, count, step] / scalar / [0, elements, 1]
         depending on which per-axis kind the flat re-scan produced. */
      switch ( flat_info.index_type[0] ) {
        case CA_IDX_BLOCK:
          inner = rb_ary_new3(3,
                              SIZE2NUM(flat_info.index[0].block.start),
                              SIZE2NUM(flat_info.index[0].block.count),
                              SIZE2NUM(flat_info.index[0].block.step));
          rb_ary_push(rindex, inner);
          break;
        case CA_IDX_SCALAR:
          rb_ary_push(rindex, SIZE2NUM(flat_info.index[0].scalar));
          break;
        case CA_IDX_ALL:
          rb_ary_push(rindex,
                      rb_ary_new3(3, INT2NUM(0), SIZE2NUM(elements),
                                  INT2NUM(1)));
          break;
        default: break;
      }
      break;
    }
    case CA_REG_POINT:
      for (i = 0; i < ndim; i++) {
        rb_ary_push(rindex, SIZE2NUM(info.index[i].scalar));
      }
      break;
    case CA_REG_BLOCK:
    case CA_REG_ITERATOR:
      for (i = 0; i < ndim; i++) {
        switch ( info.index_type[i] ) {
          case CA_IDX_SCALAR:
            rb_ary_push(rindex, SIZE2NUM(info.index[i].scalar));
            break;
          case CA_IDX_ALL:
            rb_ary_push(rindex,
                        rb_ary_new3(3, INT2NUM(0),
                                       rb_ary_entry(rdim, i),
                                       INT2NUM(1)));
            break;
          case CA_IDX_BLOCK:
            rb_ary_push(rindex,
                        rb_ary_new3(3,
                                    SIZE2NUM(info.index[i].block.start),
                                    SIZE2NUM(info.index[i].block.count),
                                    SIZE2NUM(info.index[i].block.step)));
            break;
          case CA_IDX_SYMBOL:
            rb_ary_push(rindex,
                        rb_ary_new3(2,
                                    ID2SYM(info.index[i].symbol.id),
                                    info.index[i].symbol.spec));
            break;
          default:
            rb_raise(rb_eIndexError, "unknown index spec");
        }
      }
      break;
    default:
      rb_raise(rb_eArgError, "unknown index specification");
  }

  return rb_ary_new3(2, INT2NUM(info.type), rindex);
}
#endif

void
Init_carray_index_classifier (void)
{
  ca_classifier_sym_cache_init();
#ifdef CARRAY_DEV_BUILD
  rb_define_singleton_method(rb_cCArray, "_scan_index_v2",
                             rb_ca_s_scan_index_v2, 2);
#endif
}
