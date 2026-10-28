/* ---------------------------------------------------------------------------

  Sort surface: sort / sort_copy (value & view), sort_addr / axis2addr
  (address sort).  The typed textbook sort kernels live in
  carray_sort_kernel.c; partition / partition_copy in carray_partition.c.

---------------------------------------------------------------------------- */

#include "ruby.h"
#include "carray.h"
#include "ca_for_buffer.h"        /* rb_ca_call_with_buffer */
#include "ca_kernel_iterator.h"   /* CA_FOR_EACH_FIBER_INOUT (sort_copy) */
#include "ca_obj_face.h"          /* CA_FACE_LIFT_IF_FACE */
#include "ca_sort_kernels.h"      /* ca_sort_quick_* / ca_sort_merge_* / ca_partition_nan_* */
#include "ca_compare.h"           /* ca_elem_cmp[] -- shared element comparators */
#include "carray_internal.h"      /* ca_attach_window */
#include <math.h>
#include <float.h>

/* ----------------------------------------------------------------- */

/* CA_FIXLEN comparator: direct memcmp over the packed byte width.
 * The shared ca_elem_cmp table (ca_compare.h) leaves FIXLEN unsupported
 * because a 2-arg comparator cannot carry the width; numeric / object
 * data_types go through ca_elem_cmp[data_type].
 *
 * Called by sort_addr_cmp only. */
static int
cmp_fixlen_bytes (char *a, char *b, ca_size_t bytes)
{
  return memcmp(a, b, (size_t) bytes);
}

/* ----------------------------------------------------------------- */

struct cmp_base {
  int      n;
  CArray **ca;
  int      masked_last;  /* 1 (default, :last) or 0 (:first) */
};

struct sort_addr_key {
  ca_size_t  i;
  struct cmp_base *base;
};

/* Multi-key comparator for CArray.sort_addr: compares keys in priority
 * order, original index breaks ties (stable).  Masked cells are an
 * incomparable sentinel clustered at base->masked_last's end (same
 * role NaN plays for float data types, and the same masked_position:
 * contract as the sort/partition family's :sentinel kernel mode --
 * see MASKED_POSITION rev1 in mkkernel.rb's MkKernel.sort doc).
 *
 * Called as a qsort/mergesort callback in rb_ca_s_sort_addr. */
static int
sort_addr_cmp (struct sort_addr_key *a, struct sort_addr_key *b)
{
  struct cmp_base *base = a->base;
  int n = base->n;
  CArray **ca = base->ca;
  ca_size_t ia = a->i;
  ca_size_t ib = b->i;
  int result;
  int i;
  for (i=0; i<n; i++) {
    int8_t data_type = ca[i]->data_type;
    char  *ptr = ca[i]->ptr;
    boolean8_t  *m = ( ca[i]->mask ) ? (boolean8_t *) ca[i]->mask->ptr : NULL;
    ca_size_t bytes = ca[i]->bytes;
    if ( ( ! m ) ||
         ( ( ! m[ia] ) && ( ! m[ib] ) ) ) {
      if ( data_type == CA_FIXLEN ) {
        result = cmp_fixlen_bytes(ptr + ia*bytes,
                                  ptr + ib*bytes, bytes);
      }
      else {
        result = ca_elem_cmp[data_type](ptr + ia*bytes,
                                        ptr + ib*bytes);
      }
    }
    else if ( ( ! m[ia] ) && ( m[ib] ) ) {
      result = base->masked_last ? -1 : 1;
    }
    else if ( ( m[ia] ) && ( ! m[ib] ) ) {
      result = base->masked_last ? 1 : -1;
    }
    else {
      result = 0;
    }
    if ( result ) {
      return result;
    }
  }
  return ( ia > ib ) ? 1 : -1; /* for stable sort */
}

/* An object key compares through <=>, which can raise, and a raise must
   not unwind through libc's mergesort / qsort.  Those keys sort with this
   mergesort instead, whose frames hold nothing; the numeric ones keep
   libc's, which their comparisons cannot leave. */
static void
sort_addr_merge (struct sort_addr_key *a, struct sort_addr_key *aux,
                 ca_size_t n, int (*cmp)(const void *, const void *))
CA_SORT_MERGE_BY_CMP(struct sort_addr_key)

/* -------------------------------------------------------------------

  Multi-key sort by refinement (MSD), for keys of the numeric data types.

  The first key is sorted whole by the typed pair kernel
  (ca_sort_quick_pair_*); then only the runs of rows that tie on it are
  sorted by the second key, and so on, until no run is left or the keys
  run out.  The answer is the one sort_addr_cmp gives:

  - a pair sorts by (value, row), so rows that tie on every key stay in
    row order (the stable tie-break of sort_addr_cmp);
  - each run is split into numbers, NaN and masked cells, in the order
    sort_addr_cmp puts them (numbers, NaN, masked for masked_last;
    masked, numbers, NaN otherwise).  The NaN and the masked cells of a
    run tie among themselves (CA_FLOAT_ORDER_CMP / sort_addr_cmp), so
    each is a run for the next key.  The split is a stable one done in
    the load, not ca_partition_nan_pair_*, which allocates on every call
    and is called here once per run;
  - -0.0 and 0.0 tie, by == as by CA_FLOAT_ORDER_CMP.

  A run is (lo, n): the rows perm[lo..lo+n).  Within a run the rows are
  in row order, since they tie on every key before it, so the stable
  split keeps them so.

------------------------------------------------------------------- */

typedef struct {
  ca_size_t lo;
  ca_size_t n;
} msd_run_t;

typedef struct {
  msd_run_t *runs;
  ca_size_t  count;
} msd_runs_t;

static void
msd_add_run (msd_runs_t *out, ca_size_t lo, ca_size_t n)
{
  if ( out && n > 1 ) {
    out->runs[out->count].lo = lo;
    out->runs[out->count].n  = n;
    out->count++;
  }
}

/* Sort each run of +in+ by +key+, writing the new order into perm, and
   add the runs that still tie to +out+ (NULL for the last key). */
#define DEFINE_MSD_REFINE(TYPE, SUFFIX, IS_FLOAT)                             \
static void                                                                   \
msd_refine_##SUFFIX (CArray *key, ca_size_t *perm, void *vbuf,                \
                     msd_runs_t *in, msd_runs_t *out, int masked_last)        \
{                                                                             \
  const CA_U(TYPE) *ptr = (const CA_U(TYPE) *) key->ptr;                      \
  const boolean8_t *m = ( key->mask ) ? (boolean8_t *) key->mask->ptr : NULL; \
  ca_pair_##SUFFIX *buf = (ca_pair_##SUFFIX *) vbuf;                          \
  ca_size_t r;                                                                \
                                                                              \
  for (r=0; r<in->count; r++) {                                               \
    ca_size_t lo = in->runs[r].lo;                                            \
    ca_size_t n  = in->runs[r].n;                                             \
    ca_size_t *p = perm + lo;                                                 \
    ca_size_t n_num = 0, n_nan = 0, n_mask = 0;                               \
    ca_size_t o_num, o_nan, o_mask;                                           \
    ca_size_t k, s;                                                           \
                                                                              \
    for (k=0; k<n; k++) {                                                     \
      ca_size_t row = p[k];                                                   \
      if ( m && m[row] )                 n_mask++;                            \
      else if ( IS_FLOAT && isnan((double) ptr[row]) ) n_nan++;               \
      else                               n_num++;                             \
    }                                                                         \
    o_mask = masked_last ? n_num + n_nan : 0;                                 \
    o_num  = masked_last ? 0 : n_mask;                                        \
    o_nan  = o_num + n_num;                                                   \
    {                                                                         \
      ca_size_t i_num = o_num, i_nan = o_nan, i_mask = o_mask;                \
      for (k=0; k<n; k++) {                                                   \
        ca_size_t row = p[k];                                                 \
        TYPE v = ptr[row];                                                    \
        ca_size_t at;                                                         \
        if ( m && m[row] )             at = i_mask++;                         \
        else if ( IS_FLOAT && isnan((double) v) ) at = i_nan++;               \
        else                           at = i_num++;                          \
        buf[at].v = v;                                                        \
        buf[at].i = row;                                                      \
      }                                                                       \
    }                                                                         \
    ca_sort_quick_pair_##SUFFIX(buf + o_num, n_num);                          \
    for (k=0; k<n; k++) {                                                     \
      p[k] = buf[k].i;                                                        \
    }                                                                         \
    if ( ! out ) continue;                                                    \
    for (s=0, k=1; k<=n_num; k++) {                                           \
      if ( k == n_num || buf[o_num + k].v != buf[o_num + s].v ) {             \
        msd_add_run(out, lo + o_num + s, k - s);                              \
        s = k;                                                                \
      }                                                                       \
    }                                                                         \
    msd_add_run(out, lo + o_nan,  n_nan);                                     \
    msd_add_run(out, lo + o_mask, n_mask);                                    \
  }                                                                           \
}

DEFINE_MSD_REFINE(int8_t,    i8,  0)
DEFINE_MSD_REFINE(uint8_t,   u8,  0)
DEFINE_MSD_REFINE(int16_t,   i16, 0)
DEFINE_MSD_REFINE(uint16_t,  u16, 0)
DEFINE_MSD_REFINE(int32_t,   i32, 0)
DEFINE_MSD_REFINE(uint32_t,  u32, 0)
DEFINE_MSD_REFINE(int64_t,   i64, 0)
DEFINE_MSD_REFINE(uint64_t,  u64, 0)
DEFINE_MSD_REFINE(float32_t, f32, 1)
DEFINE_MSD_REFINE(double,    f64, 1)

/* Whether every key has a typed pair kernel, so that MSD can sort them. */
static int
msd_is_sortable (struct cmp_base *base)
{
  int j;
  for (j=0; j<base->n; j++) {
    switch ( base->ca[j]->data_type ) {
    case CA_BOOLEAN: case CA_INT8:  case CA_UINT8:
    case CA_INT16:   case CA_UINT16:
    case CA_INT32:   case CA_UINT32:
    case CA_INT64:   case CA_UINT64:
    case CA_FLOAT32: case CA_FLOAT64:
      break;
    default:
      return 0;
    }
  }
  return 1;
}

typedef struct {
  struct cmp_base *base;
  ca_size_t       *perm;      /* elements rows, the answer */
  void            *buf;       /* elements pairs of 16 bytes */
  msd_run_t       *runs[2];   /* elements / 2 + 1 runs each */
  ca_size_t        elements;
} msd_sort_t;

static void
msd_sort (msd_sort_t *s)
{
  struct cmp_base *base = s->base;
  msd_runs_t a, b, *in = &a, *out = &b;
  ca_size_t i;
  int j;

  for (i=0; i<s->elements; i++) {
    s->perm[i] = i;
  }
  a.runs = s->runs[0];  a.count = 0;
  b.runs = s->runs[1];  b.count = 0;
  msd_add_run(in, 0, s->elements);

  for (j=0; j<base->n && in->count > 0; j++) {
    CArray *key = base->ca[j];
    msd_runs_t *next = ( j < base->n - 1 ) ? out : NULL;
    msd_runs_t *t;
    if ( next ) next->count = 0;
    switch ( key->data_type ) {
    case CA_BOOLEAN:
    case CA_INT8:    msd_refine_i8 (key, s->perm, s->buf, in, next, base->masked_last); break;
    case CA_UINT8:   msd_refine_u8 (key, s->perm, s->buf, in, next, base->masked_last); break;
    case CA_INT16:   msd_refine_i16(key, s->perm, s->buf, in, next, base->masked_last); break;
    case CA_UINT16:  msd_refine_u16(key, s->perm, s->buf, in, next, base->masked_last); break;
    case CA_INT32:   msd_refine_i32(key, s->perm, s->buf, in, next, base->masked_last); break;
    case CA_UINT32:  msd_refine_u32(key, s->perm, s->buf, in, next, base->masked_last); break;
    case CA_INT64:   msd_refine_i64(key, s->perm, s->buf, in, next, base->masked_last); break;
    case CA_UINT64:  msd_refine_u64(key, s->perm, s->buf, in, next, base->masked_last); break;
    case CA_FLOAT32: msd_refine_f32(key, s->perm, s->buf, in, next, base->masked_last); break;
    case CA_FLOAT64: msd_refine_f64(key, s->perm, s->buf, in, next, base->masked_last); break;
    default:
      rb_raise(rb_eRuntimeError, "%s: [BUG] data type %d has no pair kernel",
               ca_calling_method_name(), (int) key->data_type);
    }
    if ( ! next ) break;
    t = in; in = out; out = t;
  }
}

/* ----------------------------------------------------------------- */

typedef struct {
  struct sort_addr_key *data;
  struct sort_addr_key *aux;     /* NULL: no object key, libc sorts */
  ca_size_t             elements;
  msd_sort_t           *msd;     /* non-NULL: every key is numeric, sort by MSD */
} sort_addr_run_t;

static VALUE
sort_addr_run (VALUE arg)
{
  sort_addr_run_t *r = (sort_addr_run_t *) arg;
  if ( r->msd ) {
    msd_sort(r->msd);
    return Qnil;
  }
  if ( r->aux ) {
    sort_addr_merge(r->data, r->aux, r->elements,
                    (int (*)(const void*,const void*)) sort_addr_cmp);
    return Qnil;
  }
#ifdef HAVE_MERGESORT
  mergesort(r->data, r->elements, sizeof(struct sort_addr_key),
            (int (*)(const void*,const void*)) sort_addr_cmp);
#else
  qsort(r->data, r->elements, sizeof(struct sort_addr_key),
            (int (*)(const void*,const void*)) sort_addr_cmp);
#endif
  return Qnil;
}

/* CArray.sort_addr(*args, masked_position: :last) — multi-key lex
 * sort.  Returns a 1-D CA_SIZE array of indices that sorts the
 * arguments in priority order (a > b > c):
 *
 *     idx = CArray.sort_addr(a, b, c)
 *     a[idx]; b[idx]; c[idx]
 *
 * All arguments must have the same element count.  Masked cells are
 * an incomparable sentinel clustered at masked_position: (:last
 * default, or :first); ties are broken by original index (stable). */
static VALUE
rb_ca_s_sort_addr_kw (int argc, VALUE *argv, VALUE ropt, VALUE self)
{
  volatile VALUE out;
  CArray *co;
  struct cmp_base base_s, *base = &base_s;
  struct sort_addr_key *data;
  volatile VALUE hlist = 0, hdata = 0, haux = 0, hmodes = 0, hruns0 = 0, hruns1 = 0;
  sort_addr_run_t run;
  msd_sort_t msd;
  char *modes;
  int has_object = 0;
  ca_size_t elements;
  ca_size_t *q;
  int j;
  ca_size_t i;

  VALUE vmasked_position = Qnil;
  rb_scan_options(ropt, "masked_position", &vmasked_position);
  int masked_last = NIL_P(vmasked_position) ? 1
    : ca_symbol_choice(vmasked_position, "masked_position", "first", "last", NULL);

  if ( argc <= 0 ) {
    rb_raise(rb_eArgError, "no arg given");
  }

  rb_check_carray_object(argv[0]);
  elements = NUM2SIZE(rb_ca_elements(argv[0]));

  for (j=0; j<argc; j++) {
    CArray *ca_j;
    rb_check_carray_object(argv[j]);
    if ( elements != NUM2SIZE(rb_ca_elements(argv[j])) ) {
      rb_raise(rb_eArgError, "elements mismatch");
    }
    TypedData_Get_Struct(argv[j], CArray, &carray_data_type, ca_j);
    if ( ca_is_face(ca_j) ) {
      argv[j] = ca_order_key(argv[j], "sort_addr");
      continue;
    }
    {
      CArray *k;
      TypedData_Get_Struct(argv[j], CArray, &carray_data_type, k);
      if ( ca_is_complex_type(k) ) {
        rb_raise(rb_eCADataTypeError,
                 "sort_addr: a %s key has no order (complex numbers are not "
                 "ordered); sort by its real part, imaginary part or abs",
                 ca_type_name[k->data_type]);
      }
    }
  }

  /* Scratch the unwind collects: the keys are read inside an attach
     window, and a comparison of object keys can raise. */
  base->n = argc;
  base->masked_last = masked_last;
  base->ca = ALLOCV_N(CArray *, hlist, base->n);
  modes = ALLOCV_N(char, hmodes, argc + 1);

  for (j=0; j<argc; j++) {
    TypedData_Get_Struct(argv[j], CArray, &carray_data_type, base->ca[j]);
    has_object |= ( base->ca[j]->data_type == CA_OBJECT );
    modes[j] = 'r';
  }
  modes[argc] = '\0';

  out = rb_ca_template_with_type(argv[0], INT2NUM(CA_SIZE), INT2NUM(0));
  TypedData_Get_Struct(out, CArray, &carray_data_type, co);
  q = (ca_size_t *) co->ptr;

  run.data     = NULL;
  run.aux      = NULL;
  run.elements = elements;
  run.msd      = NULL;

  if ( msd_is_sortable(base) ) {
    ca_size_t nruns = elements / 2 + 1;
    msd.base     = base;
    msd.perm     = q;
    msd.buf      = ALLOCV(hdata, (size_t) elements * sizeof(ca_pair_f64));
    msd.runs[0]  = ALLOCV_N(msd_run_t, hruns0, nruns);
    msd.runs[1]  = ( argc > 1 ) ? ALLOCV_N(msd_run_t, hruns1, nruns) : NULL;
    msd.elements = elements;
    run.msd      = &msd;
    ca_attach_window(argc, base->ca, modes, sort_addr_run, (VALUE) &run);
  }
  else {
    data = ALLOCV_N(struct sort_addr_key, hdata, elements);
    for (i=0; i<elements; i++) {
      data[i].i = i;
      data[i].base = base;
    }
    run.data = data;
    run.aux  = has_object ? ALLOCV_N(struct sort_addr_key, haux, elements) : NULL;
    ca_attach_window(argc, base->ca, modes, sort_addr_run, (VALUE) &run);
    for (i=0; i<elements; i++) {
      q[i] = data[i].i;
    }
  }

  ALLOCV_END(hruns1);
  ALLOCV_END(hruns0);
  ALLOCV_END(haux);
  ALLOCV_END(hdata);
  ALLOCV_END(hmodes);
  ALLOCV_END(hlist);

  return out;
}

static VALUE
rb_ca_s_sort_addr (int argc, VALUE *argv, VALUE self)
{
  VALUE ropt = rb_pop_options(&argc, &argv);
  return rb_ca_s_sort_addr_kw(argc, argv, ropt, self);
}

/* Internal sort_addr kernel entries (C-level only, no Ruby binding;
 * defined in the generated carray_kernels_sort.c).  The _quick and
 * _stable variants implement the kind: dispatch; both take an explicit
 * masked_last so `sort` / `sort_copy` can pass the masked_position:
 * kwarg through (see MkKernel.sort in mkkernel.rb). */
extern VALUE rb_ca_sort_addr_ki_quick_mp  (VALUE self, VALUE vaxis, int masked_last);
extern VALUE rb_ca_sort_addr_ki_stable_mp (VALUE self, VALUE vaxis, int masked_last);
extern VALUE rb_ca_remap_new           (VALUE cary, VALUE rmapper); /* ca_obj_remap.c (sort view) */

/* sort_addr(axis: nil, kind: :quick, masked_position: :last) — returns
 * view-flat addresses that index a sort.  Two modes:
 *
 *   axis: nil (no kwarg) — flat lex form, equivalent to
 *                          CArray.sort_addr(self, masked_position:).
 *                          Shape is preserved (NOT flattened -- this is
 *                          the legacy "1 key" case of the class method's
 *                          multi-key lex sort, pinned by
 *                          test_sort_addr_no_arg_2d_preserves_shape).
 *                          kind: has no effect (the flat lex path uses
 *                          qsort/mergesort with its own comparator).
 *   axis: k             — per-fiber view-flat addresses along axis k.
 *                          Output shape == self.shape.  Dispatches to
 *                          sort_addr_ki (mkkernel `:sort` kind).
 *
 * kind: selects the sort algorithm for the axis: path:
 *   :quick  (default) — introsort with mergesort escape
 *   :stable           — bottom-up mergesort
 *
 * Both kinds are algorithmically stable (pair sort with index tie-
 * break); kind: chooses the performance characteristic only.
 *
 * masked_position: (:last default, or :first) picks which end masked
 * cells cluster to.  Effective on BOTH modes: the axis: path forwards
 * to sort_addr_ki's masked_last-aware _mp entries; the no-axis path
 * forwards to CArray.sort_addr's own masked_last-aware comparator
 * (sort_addr_cmp).  See {sort}'s doc for the underlying incomparable-
 * sentinel contract.
 */

/* C-callable entry: skip rb_scan_args (which depends on call-frame
 * keyword-splat state, only set by full Ruby method dispatch).
 *   axis = Qnil      -> flat (= CArray.sort_addr(self, masked_position:))
 *   axis = Integer   -> per-fiber axis path
 *   stable: 0 (quick, default) / non-zero (stable)
 *   masked_last: 1 (default, :last) / 0 (:first)
 *
 * Called by the Ruby binding rb_ca_sort_addr below, and externally
 * by rb_ca_sort_by_key in carray_order.c (always with axis given, so
 * the flat branch below is unreached from that caller). */
VALUE
rb_ca_sort_addr_c (VALUE self, VALUE axis, int stable, int masked_last)
{
  if ( NIL_P(axis) ) {
    /* Legacy flat: equivalent to CArray.sort_addr(self, masked_position:).
       kind: ignored for now (the flat path uses qsort/mergesort
       internally). */
    volatile VALUE kw = rb_hash_new();
    rb_hash_aset(kw, ID2SYM(rb_intern("masked_position")),
                 masked_last ? ID2SYM(rb_intern("last")) : ID2SYM(rb_intern("first")));
    VALUE flat_argv[1] = { self };
    return rb_ca_s_sort_addr_kw(1, flat_argv, kw, rb_cCArray);
  }
  return stable ? rb_ca_sort_addr_ki_stable_mp(self, axis, masked_last)
                : rb_ca_sort_addr_ki_quick_mp (self, axis, masked_last);
}

/* Ruby binding entry: parses (axis: / kind: / masked_position:) kwargs,
   then forwards. */
static VALUE
rb_ca_sort_addr (int argc, VALUE *argv, VALUE self)
{
  VALUE opts = Qnil;
  VALUE axis = Qnil;
  VALUE kind = Qnil;
  VALUE vmasked_position = Qnil;

  rb_scan_args(argc, argv, "0:", &opts);
  rb_scan_options(opts, "axis,kind,masked_position", &axis, &kind, &vmasked_position);

  int do_stable = NIL_P(kind) ? 0
    : ca_symbol_choice(kind, "kind", "quick", "stable", NULL);

  int masked_last = NIL_P(vmasked_position) ? 1
    : ca_symbol_choice(vmasked_position, "masked_position", "first", "last", NULL);

  return rb_ca_sort_addr_c(self, axis, do_stable, masked_last);
}

/* axis2addr(indices, axis: 0) — converts per-fiber axis-local indices
 * into row-major view-flat addresses into self.  For each cell at coord
 * c = (c_0, ..., c_(n-1)) in `indices`:
 *
 *     addr[c] = sum_{j != axis} c_j * stride_j + indices[c] * stride_axis
 *
 * where strides are row-major over self.shape
 * (stride_j = product of self.dim[j+1..n-1]).
 *
 * This is the canonical converter between the two axis-position
 * representations the *_index / *_addr kernel families produce:
 *
 *     a.min_index(axis: k) — axis-local scalar per fiber
 *     a.min_addr(axis: k)  — view-flat address per fiber
 *     flat_addrs = key.axis2addr(key.min_index(axis: k), axis: k)
 *     # == key.min_addr(axis: k)
 *
 * Sits underneath `take_along_axis`: the heavy "axis-local -> view-
 * flat" arithmetic lives here, and `take_along_axis` is a one-liner
 * on top of `flatten[axis2addr(...)]`.
 *
 * Shape rule: indices.ndim == self.ndim, indices.dim[j] == self.dim[j]
 * for all j != axis; indices.dim[axis] is free (the output along axis
 * can be any length).
 *
 * indices data_type: any integer kind (zero-copy if already CA_SIZE).
 * Negative indices: Python-style (-1 = last), normalized internally.
 * OOB indices: raises IndexError.  Default axis: 0; negative axis
 * Python-style.
 *
 * Returns: CArray of CA_SIZE, same shape as indices.
 */

typedef struct {
  CArray    *idx_ca;
  ca_size_t *out_ptr;
  ca_size_t *strides;
  int        axis;
  ca_size_t  axis_size;
  boolean8_t *mask;      /* the indices' mask, or NULL */
} axis2addr_ctx_t;

/* Body of rb_ca_axis2addr_c: one flat address per index cell. */
static void
axis2addr_body (void *user_data, void *ptr, ca_size_t n)
{
  axis2addr_ctx_t *c       = (axis2addr_ctx_t *) user_data;
  ca_size_t       *idx_ptr = (ca_size_t *) ptr;
  int              ndim    = c->idx_ca->ndim;
  ca_size_t        coord[CA_RANK_MAX];

  for ( int8_t j = 0; j < ndim; j++ ) coord[j] = 0;
  for ( ca_size_t k = 0; k < n; k++ ) {
    /* A masked index has no address: the cell keeps the mask (copied from
       the indices) and is skipped here, its stored value unread. */
    if ( c->mask && c->mask[k] ) {
      c->out_ptr[k] = 0;
      goto advance;
    }
    ca_size_t norm = ca_index_in_range(idx_ptr[k], c->axis_size, "index");
    /* Compute flat addr: sum c_j * stride_j (with c_axis = norm). */
    ca_size_t addr = 0;
    for ( int8_t j = 0; j < ndim; j++ ) {
      if ( j == c->axis ) {
        addr += norm * c->strides[j];
      } else {
        addr += coord[j] * c->strides[j];
      }
    }
    c->out_ptr[k] = addr;
  advance:
    /* Advance coord row-major (last axis ticks fastest). */
    for ( int8_t j = (int8_t)(ndim - 1); j >= 0; j-- ) {
      if ( ++coord[j] < c->idx_ca->dim[j] ) break;
      coord[j] = 0;
    }
  }
}

/* C-callable entry: skip rb_scan_args (call-frame state dependency).
 * vaxis = Qnil treated as axis 0; Integer is taken as-is (negative
 * axis normalized internally).
 *
 * Called by the Ruby binding rb_ca_axis2addr below, and externally
 * by rb_ca_take_along_axis_c / rb_ca_put_along_axis in
 * carray_order.c. */
VALUE
rb_ca_axis2addr_c (VALUE self, VALUE vindices, VALUE vaxis)
{
  rb_check_carray_object(vindices);

  CArray *ca, *idx_ca, *out_ca;
  TypedData_Get_Struct(self,     CArray, &carray_data_type, ca);
  TypedData_Get_Struct(vindices, CArray, &carray_data_type, idx_ca);

  long axis_l = ca_normalize_axis_arg(NIL_P(vaxis) ? INT2FIX(0) : vaxis,
                                      (int) ca->ndim, NULL);
  int axis = (int) axis_l;

  /* Shape rule: indices.ndim == self.ndim, dims match except at axis. */
  if ( idx_ca->ndim != ca->ndim ) {
    rb_raise(rb_eArgError,
             "%s: indices.ndim (%d) must equal self.ndim (%d)",
             ca_calling_method_name(), (int) idx_ca->ndim, (int) ca->ndim);
  }
  for ( int8_t j = 0; j < ca->ndim; j++ ) {
    if ( j == axis ) continue;
    if ( idx_ca->dim[j] != ca->dim[j] ) {
      rb_raise(rb_eArgError,
               "%s: indices.dim[%d] (%lld) must equal "
               "self.dim[%d] (%lld)",
               ca_calling_method_name(), (int) j, (long long) idx_ca->dim[j],
               (int) j, (long long) ca->dim[j]);
    }
  }

  /* indices data_type: integer kind accepted; cast to CA_SIZE if needed
     (zero-copy when already CA_SIZE via to_type identity). */
  ca_check_index_array(vindices);
  if ( ! ca_is_integer_type(idx_ca) ) {
    rb_raise(rb_eArgError,
             "%s: indices data_type must be integer kind (got %s)",
             ca_calling_method_name(), ca_type_name[idx_ca->data_type]);
  }
  volatile VALUE vidx_cast = vindices;
  CArray         *idx_cast = idx_ca;
  if ( idx_ca->data_type != CA_SIZE ) {
    vidx_cast = rb_funcall(vindices, rb_intern("to_type"), 1,
                           INT2NUM(CA_SIZE));
    TypedData_Get_Struct(vidx_cast, CArray, &carray_data_type, idx_cast);
  }

  /* Row-major view-flat strides for self (in cells). */
  ca_size_t strides[CA_RANK_MAX];
  ca_size_t s = 1;
  for ( int8_t j = (int8_t)(ca->ndim - 1); j >= 0; j-- ) {
    strides[j] = s;
    s *= ca->dim[j];
  }
  ca_size_t axis_size = ca->dim[axis];

  /* Allocate output: same shape as indices, data_type CA_SIZE. */
  volatile VALUE vout =
    rb_ca_template_with_type(vidx_cast, INT2NUM(CA_SIZE), INT2NUM(0));
  TypedData_Get_Struct(vout, CArray, &carray_data_type, out_ca);

  /* out_ca is a freshly allocated entity of the indices' shape and cell
     width, so the indices are copied into it (a view is gathered without
     being attached) and turned into addresses in place: cell k is read
     before it is written. */
  axis2addr_ctx_t ctx;
  ctx.idx_ca    = idx_cast;
  ctx.out_ptr   = (ca_size_t *) out_ca->ptr;
  ctx.strides   = strides;
  ctx.axis      = axis;
  ctx.axis_size = axis_size;
  ctx.mask      = NULL;

  ca_copy_data(idx_cast, out_ca->ptr);
  /* A masked index gives a masked address: readers propagate it (UNDEF in
     that cell), writers skip it. */
  if ( ca_has_mask(idx_cast) ) {
    ca_copy_mask_overlay(out_ca, out_ca->elements, 1, idx_cast);
    ctx.mask = (boolean8_t *) out_ca->mask->ptr;
  }
  axis2addr_body(&ctx, out_ca->ptr, out_ca->elements);

  return vout;
}

/* Ruby binding entry: parses (indices, axis:) -> forwards to _c. */
static VALUE
rb_ca_axis2addr (int argc, VALUE *argv, VALUE self)
{
  VALUE vindices;
  VALUE opts = Qnil;
  VALUE vaxis = Qnil;

  rb_scan_args(argc, argv, "1:", &vindices, &opts);
  rb_scan_options(opts, "axis", &vaxis);
  return rb_ca_axis2addr_c(self, vindices, vaxis);
}


/* The array the order of v is read from, for a method that orders v's
   cells (a sort, a selection, a ranking, an extremum by key).  A plain
   array is its own key.  An ORDERABLE Face orders by its storage, so the
   key is the storage.  A Face that is not ORDERABLE but defines its own
   #order (CAConstString, whose cells are offsets; CARecord, whose bytes
   are no order) is keyed by that order, as a dense rank, so ties stay ties
   and a masked cell stays masked.  A Face that has no order (a CARecord
   without order_by:) raises in that order; any other Face raises here. */
VALUE
ca_order_key (VALUE v, const char *name)
{
  CArray *ca;
  TypedData_Get_Struct(v, CArray, &carray_data_type, ca);
  if ( ! ca_is_face(ca) ) {
    return v;
  }
  if ( ca_face_orders_by_itself(v) ) {
    VALUE opts = rb_hash_new();
    rb_hash_aset(opts, ID2SYM(rb_intern("method")), ID2SYM(rb_intern("dense")));
    return rb_funcallv_kw(v, rb_intern("order"), 1, &opts, RB_PASS_KEYWORDS);
  }
  ca_face_require_orderable(v, name, "order");
  return rb_ca_strip_face_value(v);
}

/* ===== sort / sort_copy (value & view surface, sibling of the
   sort_addr / axis2addr block above). =============== */

/* sort(axis: nil, kind: :quick, masked_position: :last) — returns a
 * CARemap view of self whose elements are sorted along the given axis.
 * When axis: is omitted, self is first flattened to 1-D and the entire
 * array is sorted (so the result is a 1-D view regardless of self.ndim).
 *
 * kind: selects the sort algorithm.  Both kinds are algorithmically
 * stable (pair sort with fiber-local index tie-break), so the order
 * is identical for equal values; the choice is a performance
 * characteristic:
 *
 *   :quick  (default) — portable textbook introsort with mergesort
 *                       escape.  Faster on random data.
 *   :stable           — portable textbook bottom-up mergesort with
 *                       insertion pre-pass and sorted-skip merge.
 *                       Slightly slower on random data but predictable
 *                       worst case.
 *
 * Mask handling: masked cells are an incomparable sentinel, the same
 * role NaN plays for float data types.  They are excluded from the value
 * comparison and clustered at one end of each fiber; masked_position:
 * picks which end (:last, default, or :first).  Relative order within
 * the masked cluster is unspecified (same contract as the < / > regions
 * of partition).  Since `sort` gathers through CARemap, each masked
 * cell's mask bit shows through at its new (clustered) position -- no
 * separate output mask handling is needed here.
 *
 * Dispatch:
 *   CA_FIXLEN   flows through sort_addr_ki's fixlen dialect (memcmp
 *               lexicographic order) + ca_remap_new, same view path as
 *               numeric.  kind: has no effect.
 *   CA_OBJECT   flows through sort_addr_ki's object dialect (Ruby `<=>`
 *               via rb_funcall) + ca_remap_new, same view path as
 *               numeric, both no-axis and axis: forms.
 */
static VALUE
rb_ca_sorted_view_kw (VALUE rkw, VALUE self)
{
  VALUE vaxis = Qnil;
  VALUE vkind = Qnil;
  VALUE vmasked_position = Qnil;

  /* `sort` accepts `axis:`, `kind:`, `masked_position:`. */
  rb_scan_options(rkw, "axis,kind,masked_position", &vaxis, &vkind, &vmasked_position);

  /* Resolve kind: -> do_stable.  :quick (default) = introsort; :stable
     = bottom-up mergesort.  Both share the same pair layout and produce
     identical orderings; only the algorithm differs. */
  int do_stable = NIL_P(vkind) ? 0
    : ca_symbol_choice(vkind, "kind", "quick", "stable", NULL);

  /* Resolve masked_position: -> masked_last.  :last (default) or :first. */
  int masked_last = NIL_P(vmasked_position) ? 1
    : ca_symbol_choice(vmasked_position, "masked_position", "first", "last", NULL);

  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  /* Build target view (flatten for no-arg, identity for axis: kwarg)
     before mask handling: rb_ca_flatten re-propagates the mask field
     from the parent, so any mask stripping must happen on the post-
     flatten target. */
  volatile VALUE target;   /* cat points into it; the walk can run a GC */
  VALUE vaxis_use;
  if ( NIL_P(vaxis) ) {
    target    = rb_ca_flatten(self);
    vaxis_use = INT2NUM(0);
  } else {
    target    = self;
    vaxis_use = vaxis;
  }

  /* sort_addr_ki_{quick,stable}_mp returns a CA_SIZE same-shape array of
     view-flat addresses into target, with masked cells clustered at
     masked_position: (mask field present but nothing actually masked is
     handled gracefully too -- the split degenerates to a no-op).  Feed
     directly to ca_remap_new to produce the sorted view; the remap gather
     carries target's mask bits through, so masked cells land at their
     clustered position still marked masked -- no extra output-mask step
     needed. */
  volatile VALUE sigma_addr = do_stable
                            ? rb_ca_sort_addr_ki_stable_mp(target, vaxis_use, masked_last)
                            : rb_ca_sort_addr_ki_quick_mp (target, vaxis_use, masked_last);
  {
    VALUE obj = rb_ca_remap_new(target, sigma_addr);
    CA_FACE_LIFT_IF_FACE(obj, self, ca);
    return obj;
  }
}

static VALUE
rb_ca_sorted_view (int argc, VALUE *argv, VALUE self)
{
  VALUE rkw = Qnil;
  rb_scan_args(argc, argv, "0:", &rkw);
  return rb_ca_sorted_view_kw(rkw, self);
}

/* sort_copy(axis: nil, kind: :quick, masked_position: :last) — eager
 * counterpart to {sort}.  Returns a fresh entity CArray of the same
 * shape and data_type as self, with elements sorted along the given
 * axis (no-arg flattens to 1-D, same convention as sort).
 *
 * Implementation: per-fiber gather + sort + scatter via
 * CA_FOR_EACH_FIBER_INOUT.  Bypasses the sort_addr_ki + ca_remap_new
 * view chain that sort uses: a single gather + sort + scatter per
 * fiber, no pair struct, no view layer.  This fast path is numeric-only
 * and mask-free (CA_KERNEL_NO_MASK below).
 *
 * Everything the fast path does not cover -- any data_type outside
 * CA_INT8..CA_FLOAT64 (fixlen, boolean, complex, object), and masked
 * input of any type -- delegates to {sort} + copy rather than duplicate
 * the fixlen dialect / the object comparator / the mask-position split
 * in this per-fiber loop; masked_position: is forwarded unchanged.
 * Masked cells keep their masked-ness (the view's remap gather carries
 * the mask bit through, and .copy materializes it), clustered at
 * masked_position: within each fiber -- same contract as {sort}.
 *
 * So sort_copy answers for exactly what sort answers for, which is what
 * being its eager counterpart means.  It once refused everything the
 * fast path could not take: object and boolean sorted through {sort}
 * but not through this, and complex reported its refusal in two
 * different ways depending on which of the pair was asked.
 */
static VALUE
rb_ca_sort_copy (int argc, VALUE *argv, VALUE self)
{
  VALUE rkw = Qnil;
  VALUE vaxis = Qnil;
  VALUE vkind = Qnil;
  VALUE vmasked_position = Qnil;

  rb_scan_args(argc, argv, "0:", &rkw);
  rb_scan_options(rkw, "axis,kind,masked_position", &vaxis, &vkind, &vmasked_position);

  /* Resolve kind:: :quick (default) = portable textbook quicksort,
     :stable = portable textbook bottom-up mergesort. */
  int do_stable = NIL_P(vkind) ? 0
    : ca_symbol_choice(vkind, "kind", "quick", "stable", NULL);
  /* The unmasked path below has no use for masked_position:, but a value
     sort would refuse is refused here too. */
  if ( ! NIL_P(vmasked_position) ) {
    ca_symbol_choice(vmasked_position, "masked_position", "first", "last", NULL);
  }

  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  /* The per-fiber path below covers unmasked CA_INT8..CA_FLOAT64 only.
     Everything else goes to {sort} (which handles the fixlen dialect,
     the object comparator and the masked_position split) + copy, for the
     same shape/class contract as the fast path. */
  if ( ca->data_type < CA_INT8 || ca->data_type > CA_FLOAT64
       || ca_has_mask(ca) ) {
    volatile VALUE sv_kw = rb_hash_new();
    if ( !NIL_P(vaxis) )            rb_hash_aset(sv_kw, ID2SYM(rb_intern("axis")), vaxis);
    if ( !NIL_P(vkind) )            rb_hash_aset(sv_kw, ID2SYM(rb_intern("kind")), vkind);
    if ( !NIL_P(vmasked_position) ) rb_hash_aset(sv_kw, ID2SYM(rb_intern("masked_position")), vmasked_position);
    VALUE obj = rb_ca_copy(rb_ca_sorted_view_kw(sv_kw, self));
    CA_FACE_LIFT_IF_FACE(obj, self, ca);
    return obj;
  }

  /* Build target view (flatten for no-arg, identity for axis: kwarg).
     Unmasked past this point (guarded above), so no mask handling is
     needed here -- see the analogous block in rb_ca_sorted_view. */
  volatile VALUE target;   /* cat points into it; the walk can run a GC */
  VALUE vaxis_use;
  if ( NIL_P(vaxis) ) {
    target    = rb_ca_flatten(self);
    vaxis_use = INT2NUM(0);
  } else {
    target    = self;
    vaxis_use = vaxis;
  }

  CArray *cat;
  TypedData_Get_Struct(target, CArray, &carray_data_type, cat);

  /* Normalize axis (negative -> +ndim, range check). */
  int axis = ca_normalize_axis_arg(vaxis_use, cat->ndim, NULL);

  /* Allocate output: same shape and data_type as target
     (bytes=0 = preserve native bytes). */
  volatile VALUE vout = rb_ca_template_with_type(target,
                                                 INT2NUM(cat->data_type),
                                                 INT2NUM(0));
  CArray *cao;
  TypedData_Get_Struct(vout, CArray, &carray_data_type, cao);

  /* Per-fiber sort via the CA_FOR_EACH_FIBER_INOUT catalog macro.
     The kernel_iterator engine guarantees pi/po contig delivery
     (aliasing the parent when possible, materialising into per-fiber
     or whole-view scratch otherwise), so the author body is stride-
     free: copy contig input -> contig output, sort in place. */
  ca_size_t fiber_n_for_check = (ca_size_t) cat->dim[axis];
  ca_size_t bytes   = (ca_size_t) cat->bytes;
  ca_iter_state st_in, st_out;
  char       *pi, *po;
  ca_size_t   n;

  /* Per-fiber aux buffer for the stable path: allocated once outside
     the fiber loop and reused across fibers (all fibers share the
     same axis length and data_type). */
  void *aux = NULL;
  volatile VALUE aux_holder = 0;      /* 0, not Qnil: ALLOCV_END reads a non-zero holder */
  if ( do_stable ) {
    aux = ALLOCV_N(char, aux_holder,
                   (size_t) cat->dim[axis] * (size_t) bytes);
  }
  CA_FOR_EACH_FIBER_INOUT(st_in, st_out, cat, cao, (int8_t) axis,
                          CA_KERNEL_NO_MASK, pi, po, n) {
    (void) fiber_n_for_check;
    memcpy(po, pi, (size_t) n * (size_t) bytes);
    if ( do_stable ) {
      switch ( cat->data_type ) {
        case CA_INT8:    ca_sort_merge_i8 ((int8_t    *) po, (int8_t    *) aux, n); break;
        case CA_UINT8:   ca_sort_merge_u8 ((uint8_t   *) po, (uint8_t   *) aux, n); break;
        case CA_INT16:   ca_sort_merge_i16((int16_t   *) po, (int16_t   *) aux, n); break;
        case CA_UINT16:  ca_sort_merge_u16((uint16_t  *) po, (uint16_t  *) aux, n); break;
        case CA_INT32:   ca_sort_merge_i32((int32_t   *) po, (int32_t   *) aux, n); break;
        case CA_UINT32:  ca_sort_merge_u32((uint32_t  *) po, (uint32_t  *) aux, n); break;
        case CA_INT64:   ca_sort_merge_i64((int64_t   *) po, (int64_t   *) aux, n); break;
        case CA_UINT64:  ca_sort_merge_u64((uint64_t  *) po, (uint64_t  *) aux, n); break;
        case CA_FLOAT32: {
          ca_size_t fin = ca_partition_nan_f32((float32_t *) po, n);
          ca_sort_merge_f32((float32_t *) po, (float32_t *) aux, fin);
          break;
        }
        case CA_FLOAT64: {
          ca_size_t fin = ca_partition_nan_f64((double *) po, n);
          ca_sort_merge_f64((double *) po, (double *) aux, fin);
          break;
        }
        default:
          rb_raise(rb_eCADataTypeError,
                   "sort_copy: BUG: unexpected data_type %d", cat->data_type);
      }
    } else {
      switch ( cat->data_type ) {
        case CA_INT8:    ca_sort_quick_i8 ((int8_t    *) po, n); break;
        case CA_UINT8:   ca_sort_quick_u8 ((uint8_t   *) po, n); break;
        case CA_INT16:   ca_sort_quick_i16((int16_t   *) po, n); break;
        case CA_UINT16:  ca_sort_quick_u16((uint16_t  *) po, n); break;
        case CA_INT32:   ca_sort_quick_i32((int32_t   *) po, n); break;
        case CA_UINT32:  ca_sort_quick_u32((uint32_t  *) po, n); break;
        case CA_INT64:   ca_sort_quick_i64((int64_t   *) po, n); break;
        case CA_UINT64:  ca_sort_quick_u64((uint64_t  *) po, n); break;
        case CA_FLOAT32: {
          ca_size_t fin = ca_partition_nan_f32((float32_t *) po, n);
          ca_sort_quick_f32((float32_t *) po, fin);
          break;
        }
        case CA_FLOAT64: {
          ca_size_t fin = ca_partition_nan_f64((double *) po, n);
          ca_sort_quick_f64((double *) po, fin);
          break;
        }
        default:
          rb_raise(rb_eCADataTypeError,
                   "sort_copy: BUG: unexpected data_type %d", cat->data_type);
      }
    }
  }
  ALLOCV_END(aux_holder);

  RB_GC_GUARD(target);
  rb_ca_inherit_attr(vout, self);
  return vout;
}


void
Init_carray_sort (void)
{
  rb_define_singleton_method(rb_cCArray, "sort_addr", rb_ca_s_sort_addr, -1);
  rb_define_method(rb_cCArray, "sort_addr", rb_ca_sort_addr, -1);
  rb_define_method(rb_cCArray, "axis2addr", rb_ca_axis2addr, -1);

  /* `sort` returns a CARemap view (no-axis flattens to 1-D);
     `sort_copy` is the eager entity counterpart.  Both accept axis:
     and kind: kwargs -- see the function comments above. */
  rb_define_method(rb_cCArray, "sort", rb_ca_sorted_view, -1);
  rb_define_method(rb_cCArray, "sort_copy", rb_ca_sort_copy, -1);
}
