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
    - single-character alphabetic Symbols (:a-:z / :A-:Z) reserved
      for future contraction notation; the classifier raises
      NotImplementedError when they appear.

--------------------------------------------------------------------------- */

#include "carray.h"
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

static VALUE ca_classifier_sym_star  = Qundef;
static VALUE ca_classifier_sym_perc  = Qundef;
static VALUE ca_classifier_sym_under = Qundef;
static VALUE ca_classifier_sym_gt    = Qundef;   /* :> slab-iterator marker */
static VALUE ca_classifier_sym_tilde = Qundef;   /* :~ rubber-dim alias for `false` */

static inline void
ca_classifier_sym_cache_init (void)
{
  if ( ca_classifier_sym_star == Qundef ) {
    ca_classifier_sym_star  = ID2SYM(rb_intern("*"));
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
  if ( k < 0 ) {
    k += dim;
  }
  if ( range_check && ( k < 0 || k >= dim ) ) {
    rb_raise(rb_eIndexError,
             "index out of range at %i-dim ( %" PRId64 " <=> 0..%" PRId64 " )",
             axis, (ca_size_t) k, (ca_size_t) (dim - 1));
  }
  return k;
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
      /* Bignum is rejected by FIXNUM_P above; the slow path's
         rb_obj_is_kind_of(arg, rb_cInteger) picks it up so the
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
   reserved for future contraction notation.  Raises
   NotImplementedError rather than the generic IndexError.  The
   caller passes any Symbol that is not `:_` / `:*` / `:%`; a
   non-reserved Symbol returns without action. */
static inline void
ca_classifier_check_reserved_contraction_symbol (VALUE sym)
{
  const char *name;
  if ( ! SYMBOL_P(sym) ) return;
  name = rb_id2name(SYM2ID(sym));
  if ( name != NULL
       && name[0] != '\0' && name[1] == '\0'
       && ( ( name[0] >= 'a' && name[0] <= 'z' )
            || ( name[0] >= 'A' && name[0] <= 'Z' ) )
       && name[0] != '_' /* :_ is iterator marker, handled separately */ ) {
    rb_raise(rb_eNotImpError,
             "symbol :%s is reserved for future contraction notation "
             "(not yet implemented)",
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

  start = NIL_P(iv_beg) ? 0  : NUM2SIZE(iv_beg);
  last  = NIL_P(iv_end) ? -1 : NUM2SIZE(iv_end);
  excl  = RTEST(iv_excl);

  info->index_type[axis] = CA_IDX_BLOCK;

  if ( info->range_check ) {
    /* Inlined CA_CHECK_INDEX_AT so the format string stays
       byte-identical with the surrounding helpers. */
    if ( start < 0 ) start += dim;
    if ( start < 0 || start >= dim ) {
      rb_raise(rb_eIndexError,
               "index out of range at %i-dim ( %" PRId64 " <=> 0..%" PRId64 " )",
               axis, (ca_size_t) start, (ca_size_t) (dim - 1));
    }
  }

  if ( last < 0 ) {
    last += dim;  /* don't use CA_CHECK_INDEX for excl */
  }
  if ( excl && start == last ) {
    info->index[axis].block.start = start;
    info->index[axis].block.count = 0;
    info->index[axis].block.step  = 1;
    return;
  }
  if ( excl ) {
    last += ( last >= start ) ? -1 : 1;
  }
  if ( info->range_check ) {
    if ( last < 0 || last >= dim ) {
      rb_raise(rb_eIndexError,
               "index %" PRId64 " is out of range (0..%" PRId64 ") at %i-dim",
               (ca_size_t) last, (ca_size_t) (dim - 1), axis);
    }
  }
  count = llabs(last - start) + 1;
  step  = ( last >= start ) ? 1 : -1;
  info->index[axis].block.start = start;
  info->index[axis].block.count = count;
  info->index[axis].block.step  = step;
}

#ifdef HAVE_RB_ARITHMETIC_SEQUENCE_EXTRACT
/* ArithSeq → BLOCK */
static void
ca_classifier_axis_from_arithseq (ca_classifier_ctx_t *ctx, int axis, VALUE arg)
{
  ca_size_t   start, last, count, step, bound;
  int         excl;
  volatile VALUE iv_beg, iv_end, iv_excl;
  rb_arithmetic_sequence_components_t x;
  CAIndexInfo *info = ctx->info;
  ca_size_t   dim   = ctx->ca_dim[axis];

  rb_arithmetic_sequence_extract(arg, &x);
  iv_beg = x.begin;
  iv_end = x.end;
  iv_excl = x.exclude_end;
  step   = NUM2SIZE(x.step);

  start = NIL_P(iv_beg) ? 0  : NUM2SIZE(iv_beg);
  last  = NIL_P(iv_end) ? -1 : NUM2SIZE(iv_end);
  excl  = RTEST(iv_excl);

  if ( step == 0 ) {
    rb_raise(rb_eRuntimeError,
             "step in index equals to 0 in block reference");
  }

  info->index_type[axis] = CA_IDX_BLOCK;

  /* CAREFUL: always range-check start on the ArithSeq path,
     ignoring info->range_check.  An ArithSeq with a negative or
     out-of-range start silently produces an empty region if this
     check is deferred, which upstream callers do not expect. */
  if ( start < 0 ) start += dim;
  if ( start < 0 || start >= dim ) {
    rb_raise(rb_eIndexError,
             "index out of range at %i-dim ( %" PRId64 " <=> 0..%" PRId64 " )",
             axis, (ca_size_t) start, (ca_size_t) (dim - 1));
  }

  if ( last < 0 ) {
    last += dim;
  }
  if ( excl && start == last ) {
    info->index[axis].block.start = start;
    info->index[axis].block.count = 0;
    info->index[axis].block.step  = 1;
    return;
  }
  if ( excl ) {
    last += ( last >= start ) ? -1 : 1;
  }
  if ( last < 0 || last >= dim ) {
    rb_raise(rb_eIndexError,
             "index %" PRId64 " is out of range (0..%" PRId64 ") at %i-dim",
             (ca_size_t) last, (ca_size_t) (dim - 1), axis);
  }
  if ( (last - start) * (long long) step < 0 ) {
    count = 1;
  }
  else {
    count = llabs(last - start) / llabs((long long) step) + 1;
  }
  bound = start + (count - 1) * step;
  if ( bound < 0 ) bound += dim;  /* CA_CHECK_INDEX_AT signature */
  if ( bound < 0 || bound >= dim ) {
    rb_raise(rb_eIndexError,
             "index out of range at %i-dim ( %" PRId64 " <=> 0..%" PRId64 " )",
             axis, (ca_size_t) bound, (ca_size_t) (dim - 1));
  }
  info->index[axis].block.start = start;
  info->index[axis].block.count = count;
  info->index[axis].block.step  = step;
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
      ca_size_t start = NUM2SIZE(a0);
      if ( start < 0 ) start += dim;
      if ( start < 0 || start >= dim ) {
        rb_raise(rb_eIndexError,
                 "index out of range at %i-dim ( %" PRId64 " <=> 0..%" PRId64 " )",
                 axis, (ca_size_t) start, (ca_size_t) (dim - 1));
      }
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
      ca_size_t start = 0, last, count, step, bound;
      step = NUM2SIZE(a1);
      if ( step == 0 ) {
        rb_raise(rb_eRuntimeError,
                 "step in index equals to 0 in block reference");
      }
      last = dim - 1;
      count = ( step < 0 ) ? 1 : (last / step + 1);
      bound = start + (count - 1) * step;
      if ( bound < 0 ) bound += dim;
      if ( bound < 0 || bound >= dim ) {
        rb_raise(rb_eIndexError,
                 "index out of range at %i-dim ( %" PRId64 " <=> 0..%" PRId64 " )",
                 axis, (ca_size_t) bound, (ca_size_t) (dim - 1));
      }
      info->index[axis].block.start = start;
      info->index[axis].block.count = count;
      info->index[axis].block.step  = step;
      return;
    }

    if ( rb_obj_is_kind_of(a0, rb_cRange) ) {  /* [Range, step] */
      ca_size_t   start, last, count, step, bound;
      int         excl;
      volatile VALUE iv_beg, iv_end, iv_excl;
      iv_beg  = CA_CLASSIFIER_RANGE_BEG(a0);
      iv_end  = CA_CLASSIFIER_RANGE_END(a0);
      iv_excl = CA_CLASSIFIER_RANGE_EXCL(a0);
      start = NIL_P(iv_beg) ? 0  : NUM2SIZE(iv_beg);
      last  = NIL_P(iv_end) ? -1 : NUM2SIZE(iv_end);
      excl  = RTEST(iv_excl);
      step  = NUM2SIZE(a1);
      if ( step == 0 ) {
        rb_raise(rb_eRuntimeError,
                 "step in index equals to 0 in block reference");
      }
      if ( start < 0 ) start += dim;
      if ( start < 0 || start >= dim ) {
        rb_raise(rb_eIndexError,
                 "index out of range at %i-dim ( %" PRId64 " <=> 0..%" PRId64 " )",
                 axis, (ca_size_t) start, (ca_size_t) (dim - 1));
      }
      if ( last < 0 ) last += dim;
      if ( excl && start == last ) {
        info->index[axis].block.start = start;
        info->index[axis].block.count = 0;
        info->index[axis].block.step  = 1;
        return;
      }
      if ( excl ) {
        last += ( last >= start ) ? -1 : 1;
      }
      if ( last < 0 || last >= dim ) {
        rb_raise(rb_eIndexError,
                 "index %" PRId64 " is out of range (0..%" PRId64 ") at %i-dim",
                 (ca_size_t) last, (ca_size_t) (dim - 1), axis);
      }
      if ( (last - start) * (long long) step < 0 ) {
        count = 1;
      }
      else {
        count = llabs(last - start) / llabs((long long) step) + 1;
      }
      bound = start + (count - 1) * step;
      if ( bound < 0 ) bound += dim;
      if ( bound < 0 || bound >= dim ) {
        rb_raise(rb_eIndexError,
                 "index out of range at %i-dim ( %" PRId64 " <=> 0..%" PRId64 " )",
                 axis, (ca_size_t) bound, (ca_size_t) (dim - 1));
      }
      info->index[axis].block.start = start;
      info->index[axis].block.count = count;
      info->index[axis].block.step  = step;
      return;
    }

    /* [start, count] */
    {
      ca_size_t start, count, bound;
      start = NUM2SIZE(a0);
      count = NUM2SIZE(a1);
      bound = start + (count - 1);
      if ( start < 0 ) start += dim;
      if ( start < 0 || start >= dim ) {
        rb_raise(rb_eIndexError,
                 "index out of range at %i-dim ( %" PRId64 " <=> 0..%" PRId64 " )",
                 axis, (ca_size_t) start, (ca_size_t) (dim - 1));
      }
      if ( bound < 0 ) bound += dim;
      if ( bound < 0 || bound >= dim ) {
        rb_raise(rb_eIndexError,
                 "index out of range at %i-dim ( %" PRId64 " <=> 0..%" PRId64 " )",
                 axis, (ca_size_t) bound, (ca_size_t) (dim - 1));
      }
      info->index[axis].block.start = start;
      info->index[axis].block.count = count;
      info->index[axis].block.step  = 1;
      return;
    }
  }

  if ( len == 3 ) {                      /* [start, count, step] */
    ca_size_t start, count, step, bound;
    start = NUM2SIZE(rb_ary_entry(arg, 0));
    count = NUM2SIZE(rb_ary_entry(arg, 1));
    step  = NUM2SIZE(rb_ary_entry(arg, 2));
    if ( step == 0 ) {
      rb_raise(rb_eRuntimeError,
               "step in index equals to 0 in block reference");
    }
    bound = start + (count - 1) * step;
    if ( start < 0 ) start += dim;
    if ( start < 0 || start >= dim ) {
      rb_raise(rb_eIndexError,
               "index out of range at %i-dim ( %" PRId64 " <=> 0..%" PRId64 " )",
               axis, (ca_size_t) start, (ca_size_t) (dim - 1));
    }
    if ( bound < 0 ) bound += dim;
    if ( bound < 0 || bound >= dim ) {
      rb_raise(rb_eIndexError,
               "index out of range at %i-dim ( %" PRId64 " <=> 0..%" PRId64 " )",
               axis, (ca_size_t) bound, (ca_size_t) (dim - 1));
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

  if ( rb_obj_is_kind_of(arg, rb_cInteger) ) {
    ca_size_t k = NUM2SIZE(arg);
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
    ca_classifier_check_reserved_contraction_symbol(arg);  /* raises if reserved */
    rb_raise(rb_eIndexError,
             "symbol :%s is invalid as the index for slab iterator "
             "(use :> instead)",
             rb_id2name(SYM2ID(arg)));
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
  {
    VALUE inspect = rb_inspect(arg);
    rb_raise(rb_eIndexError,
             "object '%s' is invalid for the index for reference at %i-dim",
             StringValuePtr(inspect), axis);
  }
}

/* -------------------------------------------------------------------- */
/* Rubber-dim pre-pass.  Walks ctx->argv detecting Qfalse (or its
   `:~` alias), expands the rubber slot into `Qnil` fills in
   ctx->argv_expanded, and re-points ctx->argv at it.  At most one
   rubber marker is honoured; a second one falls through to the
   per-axis dispatcher and raises. */

static void
ca_classifier_expand_rubber_dim (ca_classifier_ctx_t *ctx)
{
  long i, j;
  long argc      = ctx->argc;
  VALUE *argv    = ctx->argv;
  int rubber_pos = -1;
  long expanded_argc;
  int  rndim;

  for (i = 0; i < argc; i++) {
    if ( argv[i] == Qfalse || argv[i] == ca_classifier_sym_tilde ) {
      rubber_pos = (int) i;    /* :~ is an alias for the `false` rubber marker */
      /* Only the first rubber marker is honoured; later occurrences fall
         through to the per-axis dispatcher and raise. */
      break;
    }
  }

  if ( rubber_pos < 0 ) {
    /* No rubber dim — validate argc == ndim and pass through. */
    if ( argc != ctx->ca_ndim ) {
      rb_raise(rb_eIndexError,
               "number of indices exceeds the ndim of carray (%i > %i)",
               (int) argc, ctx->ca_ndim);
    }
    return;
  }

  if ( argc > ctx->ca_ndim + 1 ) {
    rb_raise(rb_eIndexError,
             "index specification exceeds the ndim of carray (%i)",
             ctx->ca_ndim);
  }

  /* rndim = number of nils the rubber expands to.
   *
   * CAREFUL: rndim == 0 is a valid outcome — the rubber consumes
   * nothing when argc == ndim + 1 (e.g. `[false, 0, 1]` on
   * ndim = 2 collapses to `[0, 1]`).  Clamping only at the
   * negative side preserves that path. */
  rndim = ctx->ca_ndim - (int)argc + 1;
  if ( rndim < 0 ) rndim = 0;
  expanded_argc = argc - 1 + rndim;

  j = 0;
  for (i = 0; i < argc; i++) {
    if ( i == rubber_pos ) {
      int k;
      for (k = 0; k < rndim; k++) {
        ctx->argv_expanded[j++] = Qnil;
      }
    } else {
      ctx->argv_expanded[j++] = argv[i];
    }
  }
  ctx->argc = expanded_argc;
  ctx->argv = ctx->argv_expanded;
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

  /* T_STRING: "@name" → ATTRIBUTE, "field" → MEMBER. */
  if ( TYPE(arg) == T_STRING ) {
    const char *s = StringValuePtr(arg);
    if ( s[0] == '@' ) {
      info->type   = CA_REG_ATTRIBUTE;
      info->symbol = rb_str_new2(s + 1);
    } else {
      info->type   = CA_REG_MEMBER;
      info->symbol = ID2SYM(rb_intern(s));
    }
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
      if ( ctx->ca_elements != cs->elements ) {
        rb_raise(rb_eRuntimeError,
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

  /* :* → UNBOUND_REPEAT. */
  if ( arg == ca_classifier_sym_star ) {
    info->type = CA_REG_UNBOUND_REPEAT;
    return 1;
  }

  /* ndim > 1 with Integer → ADDRESS.  Fixnum was caught by the
     fast path; this branch handles Bignum. */
  if ( ctx->ca_ndim > 1 && rb_obj_is_kind_of(arg, rb_cInteger) ) {
    ca_size_t addr = NUM2SIZE(arg);
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
     specials (:_ / :* / :%) fall through the strlen check and are
     handled downstream (argc == 1 special / fast paths / main
     loop).  Single-char alphabetic reserved-contraction Symbols
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

  /* CAREFUL: pre-scan for :% / :*.  Either Symbol at any position
     pins the final REG and short-circuits both the main loop and
     the argc / ndim validation below — skipping the pre-scan lets
     the ndim mismatch check fire before the Symbol is
     recognised. */
  for (i = 0; i < ctx.argc; i++) {
    if ( ctx.argv[i] == ca_classifier_sym_perc ) {
      info->type = CA_REG_REPEAT;
      return;
    }
    if ( ctx.argv[i] == ca_classifier_sym_star ) {
      info->type = CA_REG_UNBOUND_REPEAT;
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
               "number of indices does not equal to the ndim (%i != %i)",
               info->ndim, ctx.ca_ndim);
    }

    ca_classifier_finalize_reg(&ctx, is_grid);
  }
}

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
    case CA_REG_UNBOUND_REPEAT:
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
            rb_raise(rb_eRuntimeError, "unknown index spec");
        }
      }
      break;
    default:
      rb_raise(rb_eArgError, "unknown index specification");
  }

  return rb_ary_new3(2, INT2NUM(info.type), rindex);
}

void
Init_carray_index_classifier (void)
{
  ca_classifier_sym_cache_init();
  rb_define_singleton_method(rb_cCArray, "_scan_index_v2",
                             rb_ca_s_scan_index_v2, 2);
}
