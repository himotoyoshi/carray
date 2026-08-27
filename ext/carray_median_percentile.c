/* ---------------------------------------------------------------------------

  C-native median / percentile / quantile.  Written as a C extension
  (not a transliteration of the Ruby script): the readability goal is
  that the compute logic reads as C, not as Ruby executed from C.

  Three lanes, dispatched on data_type:

  - numeric (CA_INT8..CA_FLOAT64): full C compute.  The kth selection /
    per-fiber sort already produces a fresh *contiguous* entity
    (rb_ca_partition_copy_c, sort_copy), so all post-selection extraction
    and arithmetic is a plain loop-interchange (OUTER/M/INNER) over
    native-typed buffers -> double, written into an rb_ca_new_reduced
    CA_FLOAT64 output.  Inner loops are instantiated per native type
    (X-macro, dispatched once) so the per-element read is a typed pointer
    load, not a switch; the even-median upper-region min is fmin-based so
    it vectorises.  No Ruby-surface funcall on this lane.

  - object (CA_OBJECT): arithmetic on arbitrary Ruby objects is
    irreducibly rb_funcall, so this lane drives the same CArray-level
    operations (partition_copy / slice / min / max / `+` / `/` / `*`) as
    per-array funcalls.  Matches production exactly: flat -> bare scalar,
    axis -> reduced CArray, mask+axis -> partition_copy raises.

  - fixlen: rejected (no numeric midpoint; ordering-pick methods alone
    are a partial surface, so fixlen median/percentile is not offered).

  Each function below is tagged with the lane it belongs to:

    [numeric] - numeric lane (CA_INT8..CA_FLOAT64); pure C double math,
                no Ruby-surface funcall.
    [object]  - CA_OBJECT lane; CArray-level / stored-object funcall.
    [shared]  - used by both lanes (or by the entry dispatch).
    [entry]   - Ruby method entry: validates args, dispatches by data_type.

  NOTE the two `pct_compute*` siblings: pct_compute is [numeric] (double
  in/out); pct_compute_object is [object] (funcall) and is reached ONLY by
  CA_OBJECT percentile/quantile -- never by numeric, never by median.

---------------------------------------------------------------------------- */

#include "ruby.h"
#include "carray.h"
#include <math.h>

/* Externals (link-time; kept out of carray.h to keep the header lean). */
extern VALUE rb_ca_partition_copy_c   (VALUE self, VALUE vkth, VALUE vaxis); /* carray_partition.c */
extern VALUE rb_ca_insert_axis        (int argc, VALUE *argv, VALUE self);  /* ca_obj_refer.c */

static ID id_axis, id_sort_copy, id_is_not_masked;
/* object lane (arbitrary Ruby objects -> arithmetic is irreducibly funcall) */
static ID id_plus, id_div, id_mul, id_min, id_max, id_sort, id_copy;
static ID id_aref, id_aset;
static VALUE sym_linear, sym_lower, sym_higher, sym_nearest, sym_midpoint;

/* [shared] data_type lane selector: true for CA_INT8..CA_FLOAT64. */
static inline int
mp_is_numeric (int8_t dt)
{
  return ( dt >= CA_INT8 && dt <= CA_FLOAT64 );
}

/* [numeric] X-macro over the numeric data_types.  All hot inner loops
   are instantiated per native type (dispatched ONCE on data_type) so
   the per-element load is a typed pointer read, not a switch: a
   generic per-element dispatch defeats vectorisation. */
#define MP_TYPES(_)                                                       \
  _(CA_INT8,   int8_t)   _(CA_UINT8,  uint8_t)                            \
  _(CA_INT16,  int16_t)  _(CA_UINT16, uint16_t)                          \
  _(CA_INT32,  int32_t)  _(CA_UINT32, uint32_t)                          \
  _(CA_INT64,  int64_t)  _(CA_UINT64, uint64_t)                          \
  _(CA_FLOAT32, float32_t) _(CA_FLOAT64, double)

/* [numeric] min over the upper region [k+1, n-1] of a partitioned fiber,
   skipping NaN (= matches production .min(axis:): NaN sorts to the tail
   and is ignored).  stride = element stride along the reduce axis.
   fmin ignores NaN (fmin(x,NaN)==x), so a +INFINITY seed naturally skips
   NaN and stays branch-free -> the compiler vectorises this loop, matching
   the production SIMD min(axis:).  An all-NaN (or empty) upper region
   leaves hi == +INFINITY; fall back to the kth value (degenerate). */
#define MP_GEN_MINUP(CT, T)                                              \
  static double                                                          \
  mp_minup_##T (const T *b, ca_size_t f0, long k, long n, long stride) { \
    double hi = (double) INFINITY;                                       \
    for ( long ai = k + 1; ai < n; ai++ ) {                             \
      double v = (double) b[f0 + (ca_size_t)(ai * stride)];             \
      hi = fmin(hi, v);                                                  \
    }                                                                    \
    return ( hi == (double) INFINITY )                                   \
             ? (double) b[f0 + (ca_size_t)(k * stride)] : hi;            \
  }
MP_TYPES(MP_GEN_MINUP)

/* ---- geometry helper ------------------------------------------------- */

/* [numeric] split self.shape around `axis` into the contiguous-entity
   walk dims: OUTER (axes before) x M (= dim[axis]) x INNER (axes after). */
static void
mp_geometry (CArray *ca, long axis, long *OUTER, long *M, long *INNER)
{
  long inner = 1, outer = 1;
  for ( int d = (int)axis + 1; d < ca->ndim; d++ ) inner *= ca->dim[d];
  for ( int d = 0; d < (int)axis; d++ )            outer *= ca->dim[d];
  *INNER = inner;
  *OUTER = outer;
  *M     = ca->dim[axis];
}

/* [numeric] keep_axis: [1,1,...,1] CA_FLOAT64 entity (original ndim)
   holding a scalar (or a single masked cell when is_undef). */
static VALUE
mp_keep_axis_full_f64 (VALUE self, double v, int is_undef)
{
  CArray *ca;
  GetCArray(self, ca);
  int nd = ca->ndim;
  ca_size_t *dim = ALLOCA_N(ca_size_t, nd);
  for ( int i = 0; i < nd; i++ ) dim[i] = 1;
  VALUE out = rb_carray_new(CA_FLOAT64, (int8_t) nd, dim, 0, NULL);
  CArray *co;
  GetCArray(out, co);
  if ( is_undef ) {
    ca_create_mask(co);
    ((boolean8_t *) co->mask->ptr)[0] = 1;
  } else {
    ((double *) co->ptr)[0] = v;
  }
  return out;
}

/* [shared] all-UNDEF reduced CA_FLOAT64 output for a zero-length reduction
   axis.  An order statistic of no elements has no value, so every reduced
   cell is masked -- matching mean / min (which return UNDEF cells), not a
   raise.  keep_axis controls whether the reduced axis is dropped or kept
   as a length-1 axis. */
static VALUE
mp_axis_all_masked (VALUE self, long axis, int keep_axis)
{
  int8_t ax = (int8_t) axis;
  VALUE out = rb_ca_new_reduced(self, &ax, 1, CA_FLOAT64, keep_axis);
  CArray *co;
  GetCArray(out, co);
  ca_create_mask(co);
  boolean8_t *m = (boolean8_t *) co->mask->ptr;
  for ( ca_size_t i = 0; i < co->elements; i++ ) m[i] = 1;
  return out;
}

/* ---- 5-method percentile picker -------------------------------------- */

typedef enum { PCT_LOWER_ONLY, PCT_UPPER_ONLY, PCT_BOTH } pct_need_t;

/* [shared] which of lower (sorted[k]) / upper (sorted[k+1]) the method
   needs.  Lets the caller skip the fetch it won't use.  Used by both
   lanes (the need classification is data type-independent). */
static pct_need_t
pct_need (VALUE method, long k, double r, long n)
{
  if ( method == sym_lower )   return PCT_LOWER_ONLY;
  if ( method == sym_higher )  return (r == 0.0) ? PCT_LOWER_ONLY : PCT_UPPER_ONLY;
  if ( method == sym_nearest ) {
    int use_k = (r < 0.5) || (r == 0.5 && (k % 2 == 0));
    return use_k ? PCT_LOWER_ONLY : PCT_UPPER_ONLY;
  }
  if ( method == sym_linear ) {
    if ( r == 0.0 || k + 1 >= n ) return PCT_LOWER_ONLY;
    return PCT_BOTH;
  }
  if ( method == sym_midpoint ) {
    if ( k + 1 >= n ) return PCT_LOWER_ONLY;
    return PCT_BOTH;
  }
  rb_raise(rb_eArgError, "percentile: invalid method (BUG)");
}

/* [numeric] 5-method picker, double in/out.  (The [object] twin is
   pct_compute_object, far below in the object lane.) */
static double
pct_compute (VALUE method, long k, double r, long n, double lo, double hi)
{
  if ( method == sym_lower )  return lo;
  if ( method == sym_higher ) return (r == 0.0) ? lo : hi;
  if ( method == sym_nearest ) {
    int use_k = (r < 0.5) || (r == 0.5 && (k % 2 == 0));
    return use_k ? lo : hi;
  }
  if ( method == sym_linear ) {
    if ( r == 0.0 || k + 1 >= n ) return lo;
    return lo * (1.0 - r) + hi * r;
  }
  if ( method == sym_midpoint ) {
    if ( k + 1 >= n ) return lo;
    return (lo + hi) / 2.0;
  }
  rb_raise(rb_eArgError, "percentile: invalid method (BUG)");
}

/* [shared] reject any method symbol outside the supported 5. */
static void
pct_validate_method (VALUE method)
{
  if ( method != sym_linear && method != sym_lower && method != sym_higher
    && method != sym_nearest && method != sym_midpoint ) {
    rb_raise(rb_eArgError,
             "percentile: method %"PRIsVALUE" not supported "
             "(use :linear / :lower / :higher / :nearest / :midpoint)",
             rb_inspect(method));
  }
}

/* =====================================================================
   median -- [numeric] lane  (CA_OBJECT median lives in the object lane)
   ===================================================================== */

/* [numeric] fill a reduced CA_FLOAT64 output from a partitioned entity
   (typed; one instantiation per native type). */
#define MP_GEN_MEDFILL(CT, T)                                            \
  static void                                                            \
  mp_medfill_##T (double *op, const T *b, long OUTER, long M,            \
                  long INNER, long n, long k, int odd) {                 \
    for ( long o = 0; o < OUTER; o++ ) {                                \
      for ( long in = 0; in < INNER; in++ ) {                           \
        ca_size_t f0 = (ca_size_t)((o * M) * INNER + in);               \
        double lo = (double) b[f0 + (ca_size_t)(k * INNER)];            \
        op[o * INNER + in] = odd ? lo                                   \
          : (lo + mp_minup_##T(b, f0, k, n, INNER)) / 2.0;             \
      }                                                                  \
    }                                                                    \
  }
MP_TYPES(MP_GEN_MEDFILL)

/* [numeric] dispatch median_fill once on data_type to the typed body. */
static void
median_fill (double *op, int8_t dt, const char *base,
             long OUTER, long M, long INNER, long n, long k, int odd)
{
  switch ( dt ) {
#define MP_CASE(CT, T) \
  case CT: mp_medfill_##T(op, (const T *) base, OUTER, M, INNER, n, k, odd); break;
  MP_TYPES(MP_CASE)
#undef MP_CASE
  default:
    rb_raise(rb_eCADataTypeError, "median: unsupported data_type %d", dt);
  }
}

/* [numeric] per-axis median -> reduced CA_FLOAT64 CArray. */
static VALUE
median_axis (VALUE self, long axis, long n, int keep_axis)
{
  CArray *ca;
  GetCArray(self, ca);
  int8_t dt = ca->data_type;
  long k = (n % 2 == 0) ? (n / 2 - 1) : ((n - 1) / 2);

  VALUE pp = rb_ca_partition_copy_c(self, LONG2NUM(k), LONG2NUM(axis));
  CArray *cp;
  GetCArray(pp, cp);

  int8_t ax = (int8_t) axis;
  VALUE out = rb_ca_new_reduced(self, &ax, 1, CA_FLOAT64, keep_axis);
  CArray *co;
  GetCArray(out, co);

  long OUTER, M, INNER;
  mp_geometry(ca, axis, &OUTER, &M, &INNER);
  median_fill((double *) co->ptr, dt, (const char *) cp->ptr,
              OUTER, M, INNER, n, k, (n % 2 != 0));
  RB_GC_GUARD(pp);
  return out;
}

/* [numeric] flat median scalar (double) of a 1-D numeric entity/view. */
static double
median_scalar_1d (VALUE src1d, long n)
{
  CArray *ca;
  GetCArray(src1d, ca);
  long k = (n % 2 == 0) ? (n / 2 - 1) : ((n - 1) / 2);
  VALUE pp = rb_ca_partition_copy_c(src1d, LONG2NUM(k), INT2FIX(0));
  CArray *cp;
  GetCArray(pp, cp);
  double res;
  median_fill(&res, ca->data_type, (const char *) cp->ptr,
              1, n, 1, n, k, (n % 2 != 0));   /* OUTER=1, M=n, INNER=1 */
  RB_GC_GUARD(pp);
  return res;
}

/* [numeric] flat median: strip mask / honour min_count, flatten, then
   reduce on axis 0 to a bare Float (or keep_axis [1..1] entity). */
static VALUE
median_flat (VALUE self, long min_count, VALUE fill_value, int keep_axis)
{
  VALUE src = self;
  int   filled = 0;   /* masked-out or empty -> use fill_value / UNDEF */

  if ( RTEST(rb_ca_has_mask(self)) ) {
    CArray *mc; GetCArray(self, mc);
    long cnt = (long) ca_count_not_masked(mc);   /* = elements - count_masked */
    if ( cnt < min_count ) filled = 1;
    else                   src = rb_ca_fetch(self, ID2SYM(id_is_not_masked));
  }
  if ( !filled ) {
    CArray *sc;
    GetCArray(src, sc);
    if ( sc->elements == 0 ) filled = 1;
  }

  if ( filled ) {
    int    is_undef = NIL_P(fill_value);
    double fillv    = is_undef ? 0.0 : NUM2DBL(fill_value);
    if ( keep_axis ) return mp_keep_axis_full_f64(self, fillv, is_undef);
    return is_undef ? CA_UNDEF : fill_value;
  }

  VALUE flat = rb_ca_flatten(src);
  CArray *fc;
  GetCArray(flat, fc);
  double scalar = median_scalar_1d(flat, (long) fc->elements);
  RB_GC_GUARD(flat);
  if ( keep_axis ) return mp_keep_axis_full_f64(self, scalar, 0);
  return rb_float_new(scalar);
}

/* =====================================================================
   object lane (CA_OBJECT)

   Arithmetic on arbitrary Ruby objects is irreducibly rb_funcall, so
   this lane drives the *same* CArray-level operations the numeric lane
   expresses inline in C: partition_copy / slice / min / max / `+` / `/`
   / `*`.  Combines are per-array funcalls (not per-scalar loops).  This
   matches production behaviour exactly: flat -> bare scalar, axis ->
   reduced CArray, mask+axis -> partition_copy raises.

   Every function in this block (down to the median entry) is [object].
   ===================================================================== */

/* [object] recv.mid(axis: raxis) -- e.g. min/max/sort along an axis. */
static VALUE
obj_call_axis (VALUE recv, ID mid, VALUE raxis)
{
  VALUE kw = rb_hash_new();
  rb_hash_aset(kw, ID2SYM(id_axis), raxis);
  VALUE argv[1] = { kw };
  return rb_funcallv_kw(recv, mid, 1, argv, RB_PASS_KEYWORDS);
}

/* [object] arr[*spec] with spec[axis]=idx, rest nil (= drop one axis). */
static VALUE
obj_slice (VALUE arr, long axis, long idx)
{
  CArray *ca;
  GetCArray(arr, ca);
  int ndim = ca->ndim;
  VALUE *spec = ALLOCA_N(VALUE, ndim);
  for ( int i = 0; i < ndim; i++ ) spec[i] = Qnil;
  spec[axis] = LONG2NUM(idx);
  return rb_funcallv(arr, id_aref, ndim, spec);
}

/* [object] min over pp[*spec] with spec[axis] = (k+1)..(n-1) along axis. */
static VALUE
obj_min_upper (VALUE pp, long axis, long k, long n)
{
  CArray *ca;
  GetCArray(pp, ca);
  int ndim = ca->ndim;
  VALUE *spec = ALLOCA_N(VALUE, ndim);
  for ( int i = 0; i < ndim; i++ ) spec[i] = Qnil;
  spec[axis] = rb_range_new(LONG2NUM(k + 1), LONG2NUM(n - 1), 0);
  VALUE sliced = rb_funcallv(pp, id_aref, ndim, spec);
  return obj_call_axis(sliced, id_min, LONG2NUM(axis));
}

/* [object] sorted[k] along axis via partition_copy. */
static VALUE
obj_kth_one (VALUE self, long axis, long k)
{
  VALUE pp = rb_ca_partition_copy_c(self, LONG2NUM(k), LONG2NUM(axis));
  return obj_slice(pp, axis, k);
}

/* [object] sorted[k] and sorted[k+1] from a single partition_copy(k). */
static void
obj_kth_pair (VALUE self, long axis, long k, long n, VALUE *lo, VALUE *hi)
{
  VALUE pp = rb_ca_partition_copy_c(self, LONG2NUM(k), LONG2NUM(axis));
  *lo = obj_slice(pp, axis, k);
  *hi = obj_min_upper(pp, axis, k, n);
}

/* [object] keep_axis flat: [1,...,1] entity holding val (UNDEF assigns
   masked).  Uses []= so UNDEF / arbitrary objects store correctly. */
static VALUE
obj_keep_axis_full (VALUE self, VALUE val)
{
  CArray *ca;
  GetCArray(self, ca);
  int ndim = ca->ndim;
  ca_size_t *dim = ALLOCA_N(ca_size_t, ndim);
  for ( int i = 0; i < ndim; i++ ) dim[i] = 1;
  int8_t ot = (ca->data_type == CA_OBJECT) ? CA_OBJECT : CA_FLOAT64;
  VALUE out = rb_carray_new(ot, (int8_t) ndim, dim, 0, NULL);
  VALUE *av = ALLOCA_N(VALUE, ndim + 1);
  for ( int i = 0; i < ndim; i++ ) av[i] = INT2FIX(0);
  av[ndim] = val;
  rb_funcallv(out, id_aset, ndim + 1, av);
  return out;
}

/* [object] per-axis median (= reduced CArray; 1-D self -> bare scalar).
   even-n combine and the *1.0 float-promote are stored-object funcalls. */
static VALUE
median_object_axis (VALUE self, long axis, long n, int keep_axis)
{
  VALUE result;
  if ( n % 2 == 0 ) {
    long k = n / 2 - 1;
    VALUE lo, hi;
    obj_kth_pair(self, axis, k, n, &lo, &hi);
    result = rb_funcall(rb_funcall(lo, id_plus, 1, hi), id_div, 1, DBL2NUM(2.0));
  } else {
    VALUE kv = obj_kth_one(self, axis, (n - 1) / 2);
    result = rb_funcall(kv, id_mul, 1, DBL2NUM(1.0));   /* force float promote */
  }
  if ( keep_axis ) {
    VALUE ia[1] = { LONG2NUM(axis) };
    result = rb_ca_insert_axis(1, ia, result);
  }
  return result;
}

/* [object] flat median: mask-strip / min_count, flatten, axis-0 reduce. */
static VALUE
median_object_flat (VALUE self, long min_count, VALUE fill_value, int keep_axis)
{
  VALUE src = self, result;
  int   filled = 0;
  if ( RTEST(rb_ca_has_mask(self)) ) {
    CArray *mc; GetCArray(self, mc);
    long cnt = (long) ca_count_not_masked(mc);   /* = elements - count_masked */
    if ( cnt < min_count ) filled = 1;
    else                   src = rb_ca_fetch(self, ID2SYM(id_is_not_masked));
  }
  if ( !filled ) {
    CArray *sc;
    GetCArray(src, sc);
    if ( sc->elements == 0 ) filled = 1;
  }
  if ( filled ) {
    result = NIL_P(fill_value) ? CA_UNDEF : fill_value;
  } else {
    VALUE flat = rb_ca_flatten(src);
    CArray *fc;
    GetCArray(flat, fc);
    result = median_object_axis(flat, 0, (long) fc->elements, 0);
    RB_GC_GUARD(flat);
  }
  return keep_axis ? obj_keep_axis_full(self, result) : result;
}

/* [object] 5-method picker on stored objects (funcall arithmetic; lo/hi
   pre-fetched).  Reached ONLY by CA_OBJECT percentile/quantile -- never
   by numeric (that path uses pct_compute) and never by median.
   The :linear / :midpoint interpolation funcalls are irreducible for
   arbitrary objects; the *1.0 in the pick methods is float-promotion to
   match the numeric "always Float" output contract. */
static VALUE
pct_compute_object (VALUE method, long k, double r, long n, VALUE lo, VALUE hi)
{
  if ( method == sym_lower )  return rb_funcall(lo, id_mul, 1, DBL2NUM(1.0));
  if ( method == sym_higher ) {
    VALUE v = (r == 0.0) ? lo : hi;
    return rb_funcall(v, id_mul, 1, DBL2NUM(1.0));
  }
  if ( method == sym_nearest ) {
    int use_k = (r < 0.5) || (r == 0.5 && (k % 2 == 0));
    return rb_funcall(use_k ? lo : hi, id_mul, 1, DBL2NUM(1.0));
  }
  if ( method == sym_linear ) {
    if ( r == 0.0 || k + 1 >= n ) return rb_funcall(lo, id_mul, 1, DBL2NUM(1.0));
    VALUE a = rb_funcall(lo, id_mul, 1, DBL2NUM(1.0 - r));
    VALUE b = rb_funcall(hi, id_mul, 1, DBL2NUM(r));
    return rb_funcall(a, id_plus, 1, b);
  }
  if ( method == sym_midpoint ) {
    if ( k + 1 >= n ) return rb_funcall(lo, id_mul, 1, DBL2NUM(1.0));
    return rb_funcall(rb_funcall(lo, id_plus, 1, hi), id_div, 1, DBL2NUM(2.0));
  }
  rb_raise(rb_eArgError, "percentile: invalid method (BUG)");
}

/* [object] single p via one partition_copy. */
static VALUE
pct_object_one_partition (VALUE self, long axis, long n, double p, VALUE method)
{
  if ( p == 100.0 )
    return rb_funcall(obj_call_axis(self, id_max, LONG2NUM(axis)),
                      id_mul, 1, DBL2NUM(1.0));
  if ( n == 1 )
    return rb_funcall(obj_slice(self, axis, 0), id_mul, 1, DBL2NUM(1.0));
  double f = (n - 1) * p / 100.0;
  long k = (long) floor(f);
  double r = f - k;
  pct_need_t need = pct_need(method, k, r, n);
  VALUE lo = Qnil, hi = Qnil;
  if ( need == PCT_LOWER_ONLY ) lo = obj_kth_one(self, axis, k);
  else                          obj_kth_pair(self, axis, k, n, &lo, &hi);
  return pct_compute_object(method, k, r, n, lo, hi);
}

/* [object] single p from a fully sorted entity (multi-p shared sort). */
static VALUE
pct_object_one_sorted (VALUE sorted, long axis, long n, double p, VALUE method)
{
  if ( p == 100.0 )
    return rb_funcall(obj_slice(sorted, axis, n - 1), id_mul, 1, DBL2NUM(1.0));
  if ( n == 1 )
    return rb_funcall(obj_slice(sorted, axis, 0), id_mul, 1, DBL2NUM(1.0));
  double f = (n - 1) * p / 100.0;
  long k = (long) floor(f);
  double r = f - k;
  pct_need_t need = pct_need(method, k, r, n);
  long kup = (k + 1 < n) ? (k + 1) : (n - 1);
  VALUE lo = Qnil, hi = Qnil;
  if ( need != PCT_UPPER_ONLY ) lo = obj_slice(sorted, axis, k);
  if ( need != PCT_LOWER_ONLY ) hi = obj_slice(sorted, axis, kup);
  return pct_compute_object(method, k, r, n, lo, hi);
}

/* [object] per-axis percentile -> array of (reduced CArray | scalar),
   one entry per requested p (keep_axis wrapping done by the entry). */
static VALUE
percentile_object_axis (VALUE self, VALUE pers, long axis, VALUE method)
{
  CArray *ca;
  GetCArray(self, ca);
  long n = (long) ca->dim[axis];
  long npers = RARRAY_LEN(pers);

  if ( n == 0 ) {
    /* zero-length axis: all-UNDEF reduced cell per p.  keep_axis wrapping
       is applied by the entry (rb_ca_percentile_m), so build reduced. */
    VALUE res = rb_ary_new_capa(npers);
    for ( long i = 0; i < npers; i++ )
      rb_ary_push(res, mp_axis_all_masked(self, axis, 0));
    return res;
  }

  if ( npers == 1 ) {
    double p = NUM2DBL(rb_ary_entry(pers, 0));
    return rb_ary_new_from_args(1,
             pct_object_one_partition(self, axis, n, p, method));
  }
  /* multi-p: one shared sort (CA_OBJECT sort trampolines to the focused
     Ruby per-slab helper), materialised once, then C-driven slicing. */
  VALUE sorted = rb_funcall(obj_call_axis(self, id_sort, LONG2NUM(axis)), id_copy, 0);
  VALUE result = rb_ary_new_capa(npers);
  for ( long i = 0; i < npers; i++ ) {
    double p = NUM2DBL(rb_ary_entry(pers, i));
    rb_ary_push(result, pct_object_one_sorted(sorted, axis, n, p, method));
  }
  RB_GC_GUARD(sorted);
  return result;
}

/* [object] masked per-axis percentile, one p.  `sorted` is a materialised
   sort(axis:) entity (present objects front, UNDEF tail per fiber); the
   stored VALUEs are read straight from its buffer, so the per-fiber select
   is C control flow driving only the interpolation funcalls.  n_present ==
   0 (or < min_count) yields an UNDEF cell (fill_value when given); the mask
   is created lazily, matching the numeric lane. */
static VALUE
pct_object_axis_masked_one (VALUE self, VALUE sorted, long axis, double p,
                            VALUE method, long OUTER, long M, long INNER,
                            const boolean8_t *sm, long min_count,
                            VALUE fill_value, int keep_axis)
{
  int8_t ax = (int8_t) axis;
  VALUE out = rb_ca_new_reduced(self, &ax, 1, CA_OBJECT, keep_axis);
  CArray *co;
  GetCArray(out, co);
  CArray *cs;
  GetCArray(sorted, cs);
  VALUE *sb = (VALUE *) cs->ptr;
  VALUE *op = (VALUE *) co->ptr;
  int is_undef = NIL_P(fill_value);

  for ( long o = 0; o < OUTER; o++ ) {
    for ( long in = 0; in < INNER; in++ ) {
      ca_size_t f0 = (ca_size_t)((o * M) * INNER + in);
      long oc = o * INNER + in;
      long np = M;
      if ( sm ) {
        np = 0;
        for ( long j = 0; j < M; j++ )
          if ( !sm[f0 + (ca_size_t)(j * INNER)] ) np++;
      }
      if ( np == 0 || np < min_count ) {
        if ( is_undef ) {
          if ( !co->mask ) ca_create_mask(co);
          ((boolean8_t *) co->mask->ptr)[oc] = 1;
        } else {
          op[oc] = fill_value;
        }
        continue;
      }
      long k; double r;
      if ( p == 100.0 )   { k = np - 1; r = 0.0; }
      else if ( np == 1 ) { k = 0;      r = 0.0; }
      else { double f = (np - 1) * p / 100.0; k = (long) floor(f); r = f - k; }
      pct_need_t need = pct_need(method, k, r, np);
      long kup = (k + 1 < np) ? (k + 1) : (np - 1);
      VALUE lo = Qnil, hi = Qnil;
      if ( need != PCT_UPPER_ONLY ) lo = sb[f0 + (ca_size_t)(k * INNER)];
      if ( need != PCT_LOWER_ONLY ) hi = sb[f0 + (ca_size_t)(kup * INNER)];
      op[oc] = pct_compute_object(method, k, r, np, lo, hi);
    }
  }
  return out;
}

/* [object] masked per-axis percentile: one sort(axis:) supplies the sorted
   material, then each p is a per-fiber select.  Returns an Array of reduced
   CA_OBJECT CArrays, one per p. */
static VALUE
percentile_object_axis_masked (VALUE self, VALUE pers, long axis, VALUE method,
                               long min_count, VALUE fill_value, int keep_axis)
{
  CArray *ca;
  GetCArray(self, ca);
  long npers = RARRAY_LEN(pers);
  long M = (long) ca->dim[axis];

  if ( M == 0 ) {
    VALUE res = rb_ary_new_capa(npers);
    for ( long i = 0; i < npers; i++ )
      rb_ary_push(res, mp_axis_all_masked(self, axis, keep_axis));
    return res;
  }

  VALUE sorted = rb_funcall(obj_call_axis(self, id_sort, LONG2NUM(axis)), id_copy, 0);
  CArray *cs;
  GetCArray(sorted, cs);
  const boolean8_t *sm = cs->mask ? (const boolean8_t *) cs->mask->ptr : NULL;

  long OUTER, MM, INNER;
  mp_geometry(ca, axis, &OUTER, &MM, &INNER);

  VALUE result = rb_ary_new_capa(npers);
  for ( long i = 0; i < npers; i++ ) {
    double p = NUM2DBL(rb_ary_entry(pers, i));
    rb_ary_push(result,
      pct_object_axis_masked_one(self, sorted, axis, p, method,
                                 OUTER, MM, INNER, sm, min_count,
                                 fill_value, keep_axis));
  }
  RB_GC_GUARD(sorted);
  return result;
}

/* [object] per-axis median with mask / min_count / fill_value (= object
   percentile(50, :linear); see the numeric median_axis_masked note). */
static VALUE
median_object_axis_masked (VALUE self, long axis, long min_count,
                           VALUE fill_value, int keep_axis)
{
  VALUE pers = rb_ary_new_from_args(1, DBL2NUM(50.0));
  VALUE res  = percentile_object_axis_masked(self, pers, axis, sym_linear,
                                             min_count, fill_value, keep_axis);
  return rb_ary_entry(res, 0);
}

/* [object] flat percentile: mask-strip / min_count, flatten, axis-0. */
static VALUE
percentile_object_flat (VALUE self, VALUE pers, long min_count, VALUE fill_value,
                        VALUE method)
{
  long npers = RARRAY_LEN(pers);
  VALUE src = self;
  int   filled = 0;
  if ( RTEST(rb_ca_has_mask(self)) ) {
    CArray *mc; GetCArray(self, mc);
    long cnt = (long) ca_count_not_masked(mc);   /* = elements - count_masked */
    if ( cnt < min_count ) filled = 1;
    else                   src = rb_ca_fetch(self, ID2SYM(id_is_not_masked));
  }
  if ( !filled ) {
    CArray *sc;
    GetCArray(src, sc);
    if ( sc->elements == 0 ) filled = 1;
  }
  if ( filled ) {
    VALUE fill = NIL_P(fill_value) ? CA_UNDEF : fill_value;
    VALUE result = rb_ary_new_capa(npers);
    for ( long i = 0; i < npers; i++ ) rb_ary_push(result, fill);
    return result;
  }
  VALUE flat = rb_ca_flatten(src);
  VALUE r = percentile_object_axis(flat, pers, 0, method);
  RB_GC_GUARD(flat);
  return r;
}

/* numeric masked per-axis driver (defined in the percentile lane below). */
static VALUE median_axis_masked (VALUE self, long axis, long min_count,
                                 VALUE fill_value, int keep_axis);

/* [entry] median(axis:, min_count:, fill_value:, keep_axis:).  Dispatches
   fixlen -> reject, object -> object lane, numeric -> numeric lane. */
static VALUE
rb_ca_median_m (int argc, VALUE *argv, VALUE self)
{
  VALUE ropt = rb_pop_options(&argc, &argv);
  VALUE raxis = Qnil, rmin_count = INT2FIX(0), fill_value = Qnil, rkeep = Qfalse;
  rb_scan_options(ropt, "axis,min_count,fill_value,keep_axis",
                  &raxis, &rmin_count, &fill_value, &rkeep);
  if ( argc != 0 )
    rb_raise(rb_eArgError, "median: no positional args accepted (got %d)", argc);

  CArray *ca;
  GetCArray(self, ca);
  /* Boolean rides the f64 lane: 0/1 -> 0.0/1.0, so median interpolates and
     returns a float (a 2-element median averages to 0.5), matching how the
     numeric lane treats integer input. */
  if ( ca->data_type == CA_BOOLEAN ) {
    self = rb_ca_wrap_readonly(self, INT2NUM(CA_FLOAT64));
    GetCArray(self, ca);
  }
  int8_t dt = ca->data_type;
  if ( ca_is_fixlen_type(ca) )
    rb_raise(rb_eCADataTypeError,
             "median: not defined for fixlen (no numeric midpoint); "
             "use a numeric or object array");
  int is_obj = (dt == CA_OBJECT);
  if ( !is_obj && !mp_is_numeric(dt) )
    rb_raise(rb_eCADataTypeError, "median: unsupported data_type %d", dt);

  long min_count = NUM2LONG(rmin_count);
  if ( min_count < 0 )
    rb_raise(rb_eArgError, "min_count must be non-negative; got %ld", min_count);
  int keep_axis = RTEST(rkeep);

  if ( !NIL_P(raxis) ) {
    long axis = rb_ca_normalize_axis_value(self, raxis, "median");
    long n = (long) ca->dim[axis];
    if ( n == 0 ) return mp_axis_all_masked(self, axis, keep_axis);
    /* mask / min_count / fill_value require the per-fiber select (each fiber
       has its own n_present); the plain partition path assumes a uniform n. */
    if ( RTEST(rb_ca_has_mask(self)) || min_count > 0 || !NIL_P(fill_value) )
      return is_obj
        ? median_object_axis_masked(self, axis, min_count, fill_value, keep_axis)
        : median_axis_masked(self, axis, min_count, fill_value, keep_axis);
    return is_obj ? median_object_axis(self, axis, n, keep_axis)
                  : median_axis(self, axis, n, keep_axis);
  }
  return is_obj ? median_object_flat(self, min_count, fill_value, keep_axis)
                : median_flat(self, min_count, fill_value, keep_axis);
}

/* =====================================================================
   percentile / quantile -- [numeric] lane below; the [object] percentile
   functions live up in the object lane.  The entries (rb_ca_percentile_m
   / rb_ca_quantile_m) at the bottom dispatch between them.
   ===================================================================== */

/* [numeric] fill a reduced CA_FLOAT64 output for one p, from either a
   partitioned entity (from_sorted == 0; upper via mp_minup) or a fully
   sorted entity (from_sorted == 1; upper = base[kup]). */
#define MP_GEN_PCTFILL(CT, T)                                            \
  static void                                                            \
  mp_pctfill_##T (double *op, const T *b, int from_sorted,              \
                  long OUTER, long M, long INNER, long n,                \
                  long k, double r, VALUE method, pct_need_t need) {     \
    long kup = (k + 1 < n) ? (k + 1) : (n - 1);                         \
    for ( long o = 0; o < OUTER; o++ ) {                                \
      for ( long in = 0; in < INNER; in++ ) {                           \
        ca_size_t f0 = (ca_size_t)((o * M) * INNER + in);              \
        double lo = 0.0, hi = 0.0;                                      \
        if ( need != PCT_UPPER_ONLY )                                   \
          lo = (double) b[f0 + (ca_size_t)(k * INNER)];                \
        if ( need != PCT_LOWER_ONLY )                                   \
          hi = from_sorted ? (double) b[f0 + (ca_size_t)(kup * INNER)] \
                           : mp_minup_##T(b, f0, k, n, INNER);          \
        if ( need == PCT_UPPER_ONLY ) lo = hi;                         \
        op[o * INNER + in] = pct_compute(method, k, r, n, lo, hi);      \
      }                                                                  \
    }                                                                    \
  }
MP_TYPES(MP_GEN_PCTFILL)

/* [numeric] dispatch pct_fill once on data_type to the typed body. */
static void
pct_fill (double *op, int8_t dt, const char *base, int from_sorted,
          long OUTER, long M, long INNER, long n,
          long k, double r, VALUE method, pct_need_t need)
{
  switch ( dt ) {
#define MP_CASE(CT, T) \
  case CT: mp_pctfill_##T(op, (const T *) base, from_sorted, \
                          OUTER, M, INNER, n, k, r, method, need); break;
  MP_TYPES(MP_CASE)
#undef MP_CASE
  default:
    rb_raise(rb_eCADataTypeError, "percentile: unsupported data_type %d", dt);
  }
}

/* [numeric] masked per-axis percentile fill.  `b` / `sm` are the sorted-copy
   entity's data and mask (present values front, UNDEF tail per fiber -- the
   invariant sort_copy(axis:) guarantees for masked input), so n_present per
   fiber = the count of non-masked cells (its leading run).  A fiber with
   n_present == 0 (or < min_count) yields an UNDEF cell, or fill_value when
   given.  The output mask is created lazily on the first UNDEF cell so a run
   with no empty fiber keeps has_mask == false, matching mean(axis:). */
#define MP_GEN_PCTFILL_MASKED(CT, T)                                         \
  static void                                                                \
  mp_pctfill_masked_##T (CArray *co, const T *b, const boolean8_t *sm,      \
                         long OUTER, long M, long INNER, double p,           \
                         VALUE method, long min_count,                       \
                         int is_undef, double fillv) {                       \
    double *op = (double *) co->ptr;                                         \
    for ( long o = 0; o < OUTER; o++ ) {                                    \
      for ( long in = 0; in < INNER; in++ ) {                               \
        ca_size_t f0 = (ca_size_t)((o * M) * INNER + in);                  \
        long oc = o * INNER + in;                                           \
        long np = M;                                                        \
        if ( sm ) {                                                         \
          np = 0;                                                           \
          for ( long j = 0; j < M; j++ )                                    \
            if ( !sm[f0 + (ca_size_t)(j * INNER)] ) np++;                   \
        }                                                                    \
        if ( np == 0 || np < min_count ) {                                  \
          if ( is_undef ) {                                                 \
            if ( !co->mask ) ca_create_mask(co);                           \
            ((boolean8_t *) co->mask->ptr)[oc] = 1;                        \
            op[oc] = 0.0;                                                   \
          } else {                                                          \
            op[oc] = fillv;                                                 \
          }                                                                 \
          continue;                                                         \
        }                                                                   \
        long k; double r;                                                   \
        if ( p == 100.0 )   { k = np - 1; r = 0.0; }                       \
        else if ( np == 1 ) { k = 0;      r = 0.0; }                       \
        else { double f = (np - 1) * p / 100.0; k = (long) floor(f); r = f - k; } \
        pct_need_t need = pct_need(method, k, r, np);                       \
        long kup = (k + 1 < np) ? (k + 1) : (np - 1);                      \
        double lo = 0.0, hi = 0.0;                                          \
        if ( need != PCT_UPPER_ONLY )                                       \
          lo = (double) b[f0 + (ca_size_t)(k * INNER)];                    \
        if ( need != PCT_LOWER_ONLY )                                       \
          hi = (double) b[f0 + (ca_size_t)(kup * INNER)];                  \
        if ( need == PCT_UPPER_ONLY ) lo = hi;                            \
        op[oc] = pct_compute(method, k, r, np, lo, hi);                    \
      }                                                                     \
    }                                                                       \
  }
MP_TYPES(MP_GEN_PCTFILL_MASKED)

/* [numeric] dispatch the masked fill once on data_type to the typed body. */
static void
pct_fill_masked (CArray *co, int8_t dt, const char *base, const boolean8_t *sm,
                 long OUTER, long M, long INNER, double p, VALUE method,
                 long min_count, int is_undef, double fillv)
{
  switch ( dt ) {
#define MP_CASE(CT, T) \
  case CT: mp_pctfill_masked_##T(co, (const T *) base, sm, OUTER, M, INNER, \
                                 p, method, min_count, is_undef, fillv); break;
  MP_TYPES(MP_CASE)
#undef MP_CASE
  default:
    rb_raise(rb_eCADataTypeError, "percentile: unsupported data_type %d", dt);
  }
}

/* [numeric] single p via one partition_copy -> reduced CA_FLOAT64. */
static VALUE
pct_axis_one_partition (VALUE self, long axis, long n, double p,
                        VALUE method, int keep_axis)
{
  CArray *ca;
  GetCArray(self, ca);
  int8_t dt = ca->data_type;

  long k;
  double r;
  if ( p == 100.0 )      { k = n - 1; r = 0.0; }
  else if ( n == 1 )     { k = 0;     r = 0.0; }
  else { double f = (n - 1) * p / 100.0; k = (long) floor(f); r = f - k; }

  pct_need_t need = pct_need(method, k, r, n);
  /* For higher/nearest that pick the upper element, we still partition at
     k and read min-upper; but UPPER_ONLY means we need element k+1.  To
     keep one partition correct, partition at the index we actually read:
     if UPPER_ONLY we need sorted[k+1] -> partition at k, min-upper gives
     it.  pct_fill handles that via from_sorted==0. */
  VALUE pp = rb_ca_partition_copy_c(self, LONG2NUM(k), LONG2NUM(axis));
  CArray *cp;
  GetCArray(pp, cp);

  int8_t ax = (int8_t) axis;
  VALUE out = rb_ca_new_reduced(self, &ax, 1, CA_FLOAT64, keep_axis);
  CArray *co;
  GetCArray(out, co);
  long OUTER, M, INNER;
  mp_geometry(ca, axis, &OUTER, &M, &INNER);
  pct_fill((double *) co->ptr, dt, (const char *) cp->ptr, 0,
           OUTER, M, INNER, n, k, r, method, need);
  RB_GC_GUARD(pp);
  return out;
}

/* [numeric] multi p: one shared sort_copy + per-p C slice.  (The single
   sort_copy funcall is the only Ruby-surface call left on this lane; it
   could be replaced by a C-callable sort_copy twin like partition_copy_c.) */
static VALUE
pct_axis_multi (VALUE self, VALUE pers_ary, long axis, long n,
                VALUE method, int keep_axis)
{
  CArray *ca;
  GetCArray(self, ca);
  int8_t dt = ca->data_type;
  long npers = RARRAY_LEN(pers_ary);

  /* one funcall to trigger the C per-fiber sort; result is a fresh
     contiguous entity.  Picking is full-C below. */
  VALUE kw = rb_hash_new();
  rb_hash_aset(kw, ID2SYM(id_axis), LONG2NUM(axis));
  VALUE sc_argv[1] = { kw };
  VALUE sorted = rb_funcallv_kw(self, id_sort_copy, 1, sc_argv, RB_PASS_KEYWORDS);
  CArray *cs;
  GetCArray(sorted, cs);

  long OUTER, M, INNER;
  mp_geometry(ca, axis, &OUTER, &M, &INNER);

  VALUE result = rb_ary_new_capa(npers);
  for ( long i = 0; i < npers; i++ ) {
    double p = NUM2DBL(rb_ary_entry(pers_ary, i));
    long k;
    double r;
    if ( p == 100.0 )  { k = n - 1; r = 0.0; }
    else if ( n == 1 ) { k = 0;     r = 0.0; }
    else { double f = (n - 1) * p / 100.0; k = (long) floor(f); r = f - k; }
    pct_need_t need = pct_need(method, k, r, n);

    int8_t ax = (int8_t) axis;
    VALUE out = rb_ca_new_reduced(self, &ax, 1, CA_FLOAT64, keep_axis);
    CArray *co;
    GetCArray(out, co);
    pct_fill((double *) co->ptr, dt, (const char *) cs->ptr, 1,
             OUTER, M, INNER, n, k, r, method, need);
    rb_ary_push(result, out);
  }
  RB_GC_GUARD(sorted);
  return result;
}

/* [numeric] per-axis percentile: 1 p -> partition, many p -> shared sort. */
static VALUE
pct_axis (VALUE self, VALUE pers_ary, long axis, VALUE method, int keep_axis)
{
  CArray *ca;
  GetCArray(self, ca);
  long n = (long) ca->dim[axis];
  long npers = RARRAY_LEN(pers_ary);

  if ( n == 0 ) {
    /* zero-length axis: every requested p reduces to an all-UNDEF cell. */
    VALUE res = rb_ary_new_capa(npers);
    for ( long i = 0; i < npers; i++ )
      rb_ary_push(res, mp_axis_all_masked(self, axis, keep_axis));
    return res;
  }

  if ( npers == 1 ) {
    double p = NUM2DBL(rb_ary_entry(pers_ary, 0));
    return rb_ary_new_from_args(1,
             pct_axis_one_partition(self, axis, n, p, method, keep_axis));
  }
  return pct_axis_multi(self, pers_ary, axis, n, method, keep_axis);
}

/* [numeric] per-axis percentile with mask / min_count / fill_value: a single
   masked sort_copy (present front, UNDEF tail per fiber) supplies the sorted
   material, then each p is a per-fiber select honouring that fiber's own
   n_present.  Returns an Array of reduced CA_FLOAT64 CArrays, one per p. */
static VALUE
pct_axis_masked (VALUE self, VALUE pers_ary, long axis, VALUE method,
                 long min_count, VALUE fill_value, int keep_axis)
{
  CArray *ca;
  GetCArray(self, ca);
  int8_t dt = ca->data_type;
  long npers = RARRAY_LEN(pers_ary);
  long M = (long) ca->dim[axis];

  if ( M == 0 ) {
    VALUE res = rb_ary_new_capa(npers);
    for ( long i = 0; i < npers; i++ )
      rb_ary_push(res, mp_axis_all_masked(self, axis, keep_axis));
    return res;
  }

  /* one masked sort_copy: present values front, UNDEF tail, per fiber. */
  VALUE kw = rb_hash_new();
  rb_hash_aset(kw, ID2SYM(id_axis), LONG2NUM(axis));
  VALUE sc_argv[1] = { kw };
  VALUE sorted = rb_funcallv_kw(self, id_sort_copy, 1, sc_argv, RB_PASS_KEYWORDS);
  CArray *cs;
  GetCArray(sorted, cs);
  const boolean8_t *sm = cs->mask ? (const boolean8_t *) cs->mask->ptr : NULL;

  long OUTER, MM, INNER;
  mp_geometry(ca, axis, &OUTER, &MM, &INNER);
  int    is_undef = NIL_P(fill_value);
  double fillv    = is_undef ? 0.0 : NUM2DBL(fill_value);

  VALUE result = rb_ary_new_capa(npers);
  for ( long i = 0; i < npers; i++ ) {
    double p = NUM2DBL(rb_ary_entry(pers_ary, i));
    int8_t ax = (int8_t) axis;
    VALUE out = rb_ca_new_reduced(self, &ax, 1, CA_FLOAT64, keep_axis);
    CArray *co;
    GetCArray(out, co);
    pct_fill_masked(co, dt, (const char *) cs->ptr, sm,
                    OUTER, MM, INNER, p, method, min_count, is_undef, fillv);
    rb_ary_push(result, out);
  }
  RB_GC_GUARD(sorted);
  return result;
}

/* [numeric] per-axis median with mask / min_count / fill_value.  Median is
   percentile(50, :linear) (odd n -> middle, even n -> mean of the two middle
   values), so it rides the same per-fiber select. */
static VALUE
median_axis_masked (VALUE self, long axis, long min_count, VALUE fill_value,
                    int keep_axis)
{
  VALUE pers = rb_ary_new_from_args(1, DBL2NUM(50.0));
  VALUE res  = pct_axis_masked(self, pers, axis, sym_linear,
                               min_count, fill_value, keep_axis);
  return rb_ary_entry(res, 0);
}

/* [numeric] flat percentile -> array of scalars (or keep_axis [1..1]
   entities), one per requested p. */
static VALUE
pct_flat (VALUE self, VALUE pers_ary, long min_count, VALUE fill_value,
          VALUE method, int keep_axis)
{
  long npers = RARRAY_LEN(pers_ary);
  VALUE src = self;
  int   masked_out = 0, is_undef = 0;
  double fillv = 0.0;

  if ( RTEST(rb_ca_has_mask(self)) ) {
    CArray *mc; GetCArray(self, mc);
    long cnt = (long) ca_count_not_masked(mc);   /* = elements - count_masked */
    if ( cnt < min_count ) {
      masked_out = 1; is_undef = NIL_P(fill_value);
      if ( !is_undef ) fillv = NUM2DBL(fill_value);
    } else {
      src = rb_ca_fetch(self, ID2SYM(id_is_not_masked));
    }
  }
  if ( !masked_out ) {
    CArray *sc;
    GetCArray(src, sc);
    if ( sc->elements == 0 ) {
      masked_out = 1; is_undef = NIL_P(fill_value);
      if ( !is_undef ) fillv = NUM2DBL(fill_value);
    }
  }

  VALUE result = rb_ary_new_capa(npers);

  if ( masked_out ) {
    for ( long i = 0; i < npers; i++ ) {
      VALUE v = keep_axis ? mp_keep_axis_full_f64(self, fillv, is_undef)
                          : (is_undef ? CA_UNDEF
                                      : (NIL_P(fill_value) ? CA_UNDEF : fill_value));
      rb_ary_push(result, v);
    }
    return result;
  }

  /* flatten -> 1-D, reduce on axis 0, extract op[0] per p. */
  VALUE flat = rb_ca_flatten(src);
  VALUE per_axis = pct_axis(flat, pers_ary, 0, method, 0);   /* array of [1] CArrays */
  for ( long i = 0; i < npers; i++ ) {
    CArray *r1;
    GetCArray(rb_ary_entry(per_axis, i), r1);
    double v = ((double *) r1->ptr)[0];
    VALUE out = keep_axis ? mp_keep_axis_full_f64(self, v, 0) : rb_float_new(v);
    rb_ary_push(result, out);
  }
  RB_GC_GUARD(flat);
  return result;
}

/* [shared] normalise + validate the p list: unwrap a single Array/CArray
   arg, reject empty, require each p be Numeric in [0,100]. */
static VALUE
pct_flatten_validate_pers (VALUE pers)
{
  if ( RARRAY_LEN(pers) == 1 ) {
    VALUE first = rb_ary_entry(pers, 0);
    if ( RB_TYPE_P(first, T_ARRAY) ) pers = first;
    else if ( rb_obj_is_kind_of(first, rb_cCArray) )
      pers = rb_funcall(first, rb_intern("to_a"), 0);
  }
  long len = RARRAY_LEN(pers);
  if ( len == 0 )
    rb_raise(rb_eArgError, "percentile: at least one p value required");
  for ( long i = 0; i < len; i++ ) {
    VALUE p = rb_ary_entry(pers, i);
    if ( !rb_obj_is_kind_of(p, rb_cNumeric) || NUM2DBL(p) < 0.0 || NUM2DBL(p) > 100.0 )
      rb_raise(rb_eArgError,
               "percentile: p must be Numeric in [0,100] (got %"PRIsVALUE")",
               rb_inspect(p));
  }
  return pers;
}

/* [entry] percentile(*pers, axis:, min_count:, fill_value:, method:,
   keep_axis:).  Dispatches fixlen -> reject, object -> object lane,
   numeric -> numeric lane. */
static VALUE
rb_ca_percentile_m (int argc, VALUE *argv, VALUE self)
{
  VALUE ropt = rb_pop_options(&argc, &argv);
  VALUE raxis = Qnil, rmin_count = INT2FIX(0), fill_value = Qnil,
        method = sym_linear, rkeep = Qfalse;
  rb_scan_options(ropt, "axis,min_count,fill_value,method,keep_axis",
                  &raxis, &rmin_count, &fill_value, &method, &rkeep);

  CArray *ca;
  GetCArray(self, ca);
  /* Boolean rides the f64 lane (0/1 -> 0.0/1.0), so percentile / quantile
     interpolate and return a float, matching the integer lane. */
  if ( ca->data_type == CA_BOOLEAN ) {
    self = rb_ca_wrap_readonly(self, INT2NUM(CA_FLOAT64));
    GetCArray(self, ca);
  }
  int8_t dt = ca->data_type;
  if ( ca_is_fixlen_type(ca) )
    rb_raise(rb_eCADataTypeError,
             "percentile: not defined for fixlen; use a numeric or object array");
  int is_obj = (dt == CA_OBJECT);
  if ( !is_obj && !mp_is_numeric(dt) )
    rb_raise(rb_eCADataTypeError, "percentile: unsupported data_type %d", dt);

  long min_count = NUM2LONG(rmin_count);
  if ( min_count < 0 )
    rb_raise(rb_eArgError, "min_count must be non-negative; got %ld", min_count);

  VALUE pers = pct_flatten_validate_pers(rb_ary_new_from_values(argc, argv));
  pct_validate_method(method);
  int keep_axis = RTEST(rkeep);
  int single_p = (RARRAY_LEN(pers) == 1);

  /* numeric lane bakes keep_axis into the reduced output; object lane
     returns unwrapped results and is keep-wrapped here (insert_axis for
     the per-axis form, obj_keep_axis_full for the flat form) -- matching
     production's structure for arbitrary-object results.

     Return shape: multi-p returns Array<Float> (flat) or Array<CArray>
     (per-axis); single-p unwraps the length-1 Array so the caller gets
     Float / CArray directly.  A single Array or CArray p argument is
     flattened first and follows the same rule (length 1 unwraps). */
  VALUE result;
  if ( !NIL_P(raxis) ) {
    long axis = rb_ca_normalize_axis_value(self, raxis, "percentile");
    /* mask / min_count / fill_value require the per-fiber select (each fiber
       has its own n_present); the plain partition/sort path assumes a
       uniform n.  These paths bake keep_axis into the reduced output. */
    int per_fiber = RTEST(rb_ca_has_mask(self)) || min_count > 0
                    || !NIL_P(fill_value);
    if ( !is_obj ) {
      result = per_fiber
        ? pct_axis_masked(self, pers, axis, method, min_count, fill_value, keep_axis)
        : pct_axis(self, pers, axis, method, keep_axis);
    } else if ( per_fiber ) {
      result = percentile_object_axis_masked(self, pers, axis, method,
                                             min_count, fill_value, keep_axis);
    } else {
      result = percentile_object_axis(self, pers, axis, method);
      if ( keep_axis ) {
        long len = RARRAY_LEN(result);
        VALUE w = rb_ary_new_capa(len);
        VALUE ia[1] = { LONG2NUM(axis) };
        for ( long i = 0; i < len; i++ )
          rb_ary_push(w, rb_ca_insert_axis(1, ia, rb_ary_entry(result, i)));
        result = w;
      }
    }
  } else if ( !is_obj ) {
    result = pct_flat(self, pers, min_count, fill_value, method, keep_axis);
  } else {
    result = percentile_object_flat(self, pers, min_count, fill_value, method);
    if ( keep_axis ) {
      long len = RARRAY_LEN(result);
      VALUE w = rb_ary_new_capa(len);
      for ( long i = 0; i < len; i++ )
        rb_ary_push(w, obj_keep_axis_full(self, rb_ary_entry(result, i)));
      result = w;
    }
  }

  if ( single_p ) return rb_ary_entry(result, 0);
  return result;
}

/* [entry] quantile(axis:, keep_axis:) = percentile(0, 25, 50, 75, 100, ...).
   Return shape: Array<Float> len 5 (flat) or Array<CArray> len 5 (per-axis),
   matching percentile's multi-p wrapping since we pass 5 fixed p values. */
static VALUE
rb_ca_quantile_m (int argc, VALUE *argv, VALUE self)
{
  VALUE ropt = rb_pop_options(&argc, &argv);
  if ( argc != 0 )
    rb_raise(rb_eArgError, "quantile: no positional args accepted (got %d)", argc);
  VALUE raxis = Qnil, rkeep = Qfalse;
  rb_scan_options(ropt, "axis,keep_axis", &raxis, &rkeep);
  VALUE opts = rb_hash_new();
  if ( !NIL_P(raxis) ) rb_hash_aset(opts, ID2SYM(rb_intern("axis")), raxis);
  rb_hash_aset(opts, ID2SYM(rb_intern("keep_axis")), rkeep);
  VALUE pa[6] = { INT2FIX(0), INT2FIX(25), INT2FIX(50), INT2FIX(75), INT2FIX(100),
                  opts };
  return rb_ca_percentile_m(6, pa, self);
}

void
Init_carray_median_percentile (void)
{
  id_axis          = rb_intern("axis");
  id_sort_copy     = rb_intern("sort_copy");
  id_is_not_masked = rb_intern("is_not_masked");
  id_plus = rb_intern("+");  id_div = rb_intern("/");  id_mul = rb_intern("*");
  id_min  = rb_intern("min"); id_max = rb_intern("max");
  id_sort = rb_intern("sort"); id_copy = rb_intern("copy");
  id_aref = rb_intern("[]"); id_aset = rb_intern("[]=");
  sym_linear   = ID2SYM(rb_intern("linear"));
  sym_lower    = ID2SYM(rb_intern("lower"));
  sym_higher   = ID2SYM(rb_intern("higher"));
  sym_nearest  = ID2SYM(rb_intern("nearest"));
  sym_midpoint = ID2SYM(rb_intern("midpoint"));

  rb_define_method(rb_cCArray, "median",     rb_ca_median_m,     -1);
  rb_define_method(rb_cCArray, "percentile", rb_ca_percentile_m, -1);
  rb_define_method(rb_cCArray, "quantile",   rb_ca_quantile_m,   -1);
}
