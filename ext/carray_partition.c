/* ---------------------------------------------------------------------------

  Partition family (quickselect): `partition` (CARemap view via
  partition_addr_ki) and `partition_copy` (eager per-fiber quickselect).
  Sibling of carray_order.c (full sort + search surfaces) and
  ca_sort_kernels.h (typed numeric kernels).

  Dispatch by data_type:
    numeric (i8..f64) -> typed ca_partition_quick_* kernels
    CA_FIXLEN         -> ca_quickselect_bytes (memcmp lexicographic order)
    CA_OBJECT         -> partition_index_ki trampoline (rb_funcall(<=>))

---------------------------------------------------------------------------- */

#include "ruby.h"
#include "carray.h"
#include "ca_kernel_iterator.h"   /* CA_FOR_EACH_FIBER_INOUT */
#include "ca_obj_face.h"          /* CA_FACE_LIFT_IF_FACE */
#include "ca_sort_kernels.h"      /* ca_partition_quick_* / ca_partition_nan_* */
#include <string.h>               /* memcmp */
#include <math.h>

/* External entries reached at link time (extern declarations rather than
   carray.h additions to keep the public header lean): */
extern VALUE rb_ca_remap_new         (VALUE cary, VALUE rmapper);           /* ca_obj_remap.c */
extern VALUE rb_ca_partition_addr_ki (VALUE self, VALUE vaxis, VALUE vkth); /* carray_kernels.c (generated, bind_ruby: false) */
/* _mp ("masked position") twin: explicit masked_last, used by `partition`
   / `partition_copy` to pass masked_position: through (see MASKED_POSITION
   rev1 in mkkernel.rb's MkKernel.sort doc). */
extern VALUE rb_ca_partition_addr_ki_mp (VALUE self, VALUE vaxis, VALUE vkth, int masked_last);

/* Generic comparator-based quickselect on a flat byte buffer.
 *
 * Reorders `buf[lo..hi]` (cell size = `bytes`) in place so that
 * `buf[kth]` is the kth-smallest element under `cmp`, with all cells
 * before kth <= pivot and all after >= pivot.  Order within the two
 * regions is unspecified.  Average O(n).  Median-of-three pivot +
 * Hoare partition + one-side recursion.  Insertion-sort base case for
 * small ranges (< 8 cells).
 *
 * Comparator-based dispatch keeps this routine data_type-generic (used
 * by the CA_FIXLEN partition_copy path); the mkkernel-generated
 * partition_index_quickselect_* functions inline the comparator per
 * dtype for the numeric paths.
 *
 * `swap_tmp` and `pivot` must be caller-provided scratch buffers of size
 * `bytes` (used for cell swaps via memcpy; avoids alloca / per-swap
 * malloc).
 */
static void
ca_quickselect_bytes (char *buf, ca_size_t lo, ca_size_t hi,
                      ca_size_t kth, ca_size_t bytes,
                      int (*cmp)(const void *, const void *),
                      char *swap_tmp, char *pivot)
{
#define SWAP_CELL(_a, _b)                                              \
  do {                                                                 \
    memcpy(swap_tmp, (_a), (size_t) bytes);                            \
    memcpy((_a), (_b), (size_t) bytes);                                \
    memcpy((_b), swap_tmp, (size_t) bytes);                            \
  } while (0)
#define CELL(_i) (buf + (_i) * bytes)
/* cmp == NULL signals raw memcmp over `bytes` (= CA_FIXLEN lexicographic
   order; revived for the fixlen partition_copy path).  Otherwise use the
   supplied comparator (= numeric type-specific cmp).  The ternary
   evaluates each operand once (only one branch runs), so CELL(++i) side
   effects are safe. */
#define QSCMP(_a, _b) ( cmp ? cmp((_a), (_b)) : memcmp((_a), (_b), (size_t) bytes) )

  while ( lo < hi ) {
    /* Small-range base case: insertion sort. */
    if ( hi - lo < 8 ) {
      for ( ca_size_t i = lo + 1; i <= hi; i++ ) {
        memcpy(swap_tmp, CELL(i), (size_t) bytes);
        ca_size_t j = i;
        while ( j > lo && QSCMP(swap_tmp, CELL(j - 1)) < 0 ) {
          memcpy(CELL(j), CELL(j - 1), (size_t) bytes);
          j--;
        }
        memcpy(CELL(j), swap_tmp, (size_t) bytes);
      }
      return;
    }
    /* Median-of-three pivot: order buf[lo], buf[mid], buf[hi]. */
    ca_size_t mid = lo + (hi - lo) / 2;
    if ( QSCMP(CELL(mid), CELL(lo)) < 0 ) SWAP_CELL(CELL(mid), CELL(lo));
    if ( QSCMP(CELL(hi),  CELL(lo)) < 0 ) SWAP_CELL(CELL(hi),  CELL(lo));
    if ( QSCMP(CELL(hi),  CELL(mid)) < 0 ) SWAP_CELL(CELL(hi), CELL(mid));
    /* Stash pivot at hi-1 (Hoare partition variant). */
    SWAP_CELL(CELL(mid), CELL(hi - 1));
    /* Copy pivot into caller-provided scratch (avoid per-iteration
       xmalloc; pivot lifetime is just this partition step). */
    memcpy(pivot, CELL(hi - 1), (size_t) bytes);
    /* Hoare partition (pivot at hi-1; scan lo..hi-2). */
    ca_size_t i = lo, j = hi - 1;
    for (;;) {
      while ( QSCMP(CELL(++i), pivot) < 0 );
      while ( QSCMP(CELL(--j), pivot) > 0 );
      if ( i >= j ) break;
      SWAP_CELL(CELL(i), CELL(j));
    }
    /* Restore pivot to its final position. */
    SWAP_CELL(CELL(i), CELL(hi - 1));
    /* buf[lo..i-1] <= pivot, buf[i] == pivot, buf[i+1..hi] >= pivot. */
    if ( kth == i ) return;
    else if ( kth < i ) hi = i - 1;
    else lo = i + 1;
  }
#undef SWAP_CELL
#undef CELL
#undef QSCMP
}

/* partition_copy(kth, axis: 0) — eager counterpart to `partition(kth,
 * axis:)`.  Returns a fresh entity CArray with the kth fiber-local
 * position holding the kth-smallest value.  Average O(n) per fiber via
 * quickselect.  Mask handling, axis kwarg, kth validation: identical to
 * rb_ca_partitioned_view.
 *
 * C-callable twin of rb_ca_partition_copy (the Ruby entry) that skips
 * rb_scan_args (the `:`-options form requires a proper Ruby method
 * dispatch frame and segfaults when called from C).  Takes vkth + vaxis
 * directly.  Non-static so carray_median_percentile.c can call it via
 * an extern decl.
 */
VALUE
rb_ca_partition_copy_c (VALUE self, VALUE vkth, VALUE vaxis)
{
  /* Mask handling (= same as partition view). */
  VALUE target = self;
  CArray *cat;
  TypedData_Get_Struct(target, CArray, &carray_data_type, cat);
  if ( ca_has_mask(cat) ) {
    if ( RTEST(rb_ca_is_any_masked(target)) ) {
      rb_raise(rb_eArgError,
               "partition_copy: masked input not supported "
               "(use ca.value or ca.strip_mask(fill))");
    }
    target = rb_ca_value_array(target);
    TypedData_Get_Struct(target, CArray, &carray_data_type, cat);
  }

  /* Normalize axis. */
  int axis = NUM2INT(vaxis);
  if ( axis < 0 ) axis += cat->ndim;
  if ( axis < 0 || axis >= cat->ndim ) {
    rb_raise(rb_eArgError, "partition_copy: axis %d out of range for ndim %d",
             NUM2INT(vaxis), cat->ndim);
  }

  /* Normalize kth (-dim[axis] <= kth < dim[axis], negative counts from end). */
  ca_size_t fiber_n = cat->dim[axis];
  ca_size_t kth = (ca_size_t) NUM2SSIZET(vkth);
  if ( kth < 0 ) kth += fiber_n;
  if ( kth < 0 || kth >= fiber_n ) {
    rb_raise(rb_eArgError,
             "partition_copy: kth %ld out of range for axis %d (dim=%ld)",
             (long) NUM2SSIZET(vkth), axis, (long) fiber_n);
  }

  /* CA_OBJECT branch: partition_index_ki carries the rb_funcall(<=>)
   * comparator.  Build the entity via partition_index_ki ->
   * take_along_axis -> copy.  Slower than the numeric inline quickselect,
   * but the cost is the per-pair rb_funcall, not an architectural
   * penalty. */
  if ( cat->data_type == CA_OBJECT ) {
    static ID id_partition_index_ki = 0;
    static ID id_take_along_axis    = 0;
    static ID id_axis_sym           = 0;
    if ( !id_partition_index_ki ) {
      id_partition_index_ki = rb_intern("partition_index_ki");
      id_take_along_axis    = rb_intern("take_along_axis");
      id_axis_sym           = rb_intern("axis");
    }
    VALUE idx = rb_funcall(target, id_partition_index_ki, 2,
                           INT2NUM(axis), SIZET2NUM(kth));
    VALUE kw = rb_hash_new();
    rb_hash_aset(kw, ID2SYM(id_axis_sym), INT2NUM(axis));
    VALUE tla_argv[2] = { idx, kw };
    VALUE view = rb_funcallv_kw(target, id_take_along_axis, 2, tla_argv,
                                RB_PASS_KEYWORDS);
    return rb_ca_copy(view);
  }

  /* CA_FIXLEN branch: per-fiber quickselect via the generic byte-buffer
     selector with raw memcmp ordering (cmp == NULL).  Same lexicographic
     total order as the fixlen sort/partition kernels and the bincmp
     operators.  Output preserves the fixlen byte width. */
  if ( ca_is_fixlen_type(cat) ) {
    ca_size_t fbytes = (ca_size_t) cat->bytes;
    volatile VALUE vout = rb_ca_template_with_type(target,
                                                   INT2NUM(cat->data_type),
                                                   INT2NUM((int) fbytes));
    CArray *cao;
    TypedData_Get_Struct(vout, CArray, &carray_data_type, cao);
    char *swap_tmp = ALLOCA_N(char, fbytes);
    char *pivot    = ALLOCA_N(char, fbytes);
    ca_iter_state st_in, st_out;
    char       *pi, *po;
    ca_size_t   n;
    CA_FOR_EACH_FIBER_INOUT(st_in, st_out, cat, cao, (int8_t) axis,
                            CA_KERNEL_NO_MASK, pi, po, n) {
      memcpy(po, pi, (size_t) n * (size_t) fbytes);
      if ( n > 1 ) {
        ca_quickselect_bytes(po, 0, n - 1, kth, fbytes, NULL, swap_tmp, pivot);
      }
    }
    return vout;
  }

  if ( cat->data_type != CA_BOOLEAN &&
       (cat->data_type < CA_INT8 || cat->data_type > CA_FLOAT64) ) {
    rb_raise(rb_eCADataTypeError,
             "partition_copy: data_type %d not supported "
             "(expected one of: bool, i8, u8, i16, u16, i32, u32, i64, u64, f32, f64, object)",
             cat->data_type);
  }

  volatile VALUE vout = rb_ca_template_with_type(target,
                                                 INT2NUM(cat->data_type),
                                                 INT2NUM(0));
  CArray *cao;
  TypedData_Get_Struct(vout, CArray, &carray_data_type, cao);

  /* Numeric path: per-dtype quickselect with inline cmp via the typed
     ca_partition_quick_* kernels (avoids the function-pointer
     indirection of the comparator-based ca_quickselect_bytes).
     Float NaN policy = pre-partition NaN to tail (same convention as
     sort_copy); if kth falls in the finite slice, quickselect over
     finite; if kth >= finite_count, the cell is already NaN and no
     further work is needed. */
  ca_size_t bytes = (ca_size_t) cat->bytes;

  ca_iter_state st_in, st_out;
  char       *pi, *po;
  ca_size_t   n;

  CA_FOR_EACH_FIBER_INOUT(st_in, st_out, cat, cao, (int8_t) axis,
                          CA_KERNEL_NO_MASK, pi, po, n) {
    memcpy(po, pi, (size_t) n * (size_t) bytes);
    if ( n <= 1 ) continue;
    switch ( cat->data_type ) {
      case CA_BOOLEAN: ca_partition_quick_u8 ((uint8_t   *) po, n, kth); break;
      case CA_INT8:    ca_partition_quick_i8 ((int8_t    *) po, n, kth); break;
      case CA_UINT8:   ca_partition_quick_u8 ((uint8_t   *) po, n, kth); break;
      case CA_INT16:   ca_partition_quick_i16((int16_t   *) po, n, kth); break;
      case CA_UINT16:  ca_partition_quick_u16((uint16_t  *) po, n, kth); break;
      case CA_INT32:   ca_partition_quick_i32((int32_t   *) po, n, kth); break;
      case CA_UINT32:  ca_partition_quick_u32((uint32_t  *) po, n, kth); break;
      case CA_INT64:   ca_partition_quick_i64((int64_t   *) po, n, kth); break;
      case CA_UINT64:  ca_partition_quick_u64((uint64_t  *) po, n, kth); break;
      case CA_FLOAT32: {
        ca_size_t fin = ca_partition_nan_f32((float32_t *) po, n);
        if ( kth < fin ) ca_partition_quick_f32((float32_t *) po, fin, kth);
        /* else: po[kth] is NaN already (= NaN-at-end policy), nothing to do */
        break;
      }
      case CA_FLOAT64: {
        ca_size_t fin = ca_partition_nan_f64((double *) po, n);
        if ( kth < fin ) ca_partition_quick_f64((double *) po, fin, kth);
        break;
      }
      default:
        rb_raise(rb_eCADataTypeError,
                 "partition_copy: BUG: unexpected data_type %d", cat->data_type);
    }
  }

  return vout;
}

/* masked_position: -aware twin of {rb_ca_partition_copy_c}.  Masked
 * cells are an incomparable sentinel (same role NaN plays for float
 * dtypes): unmasked input takes the fast rb_ca_partition_copy_c path
 * unchanged; masked input delegates to {partition} (which handles the
 * masked_position split via partition_addr_ki_mp) + copy, mirroring the
 * CA_FIXLEN / CA_OBJECT delegation pattern already used by sort_copy.
 * rb_ca_partition_copy_c itself keeps raising on masked input (its
 * other callers -- carray_median_percentile.c's flat lane -- always
 * pre-strip the mask before calling it, per
 * devel/MEMO_PER_AXIS_ORDER_STAT_MASK.md; per-axis order statistics
 * with mask are a separate, still-open gap).
 */
static VALUE
rb_ca_partition_copy_c_mp (VALUE self, VALUE vkth, VALUE vaxis, int masked_last)
{
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  if ( ! ca_has_mask(ca) ) {
    return rb_ca_partition_copy_c(self, vkth, vaxis);
  }
  /* rb_ca_partitioned_view's rb_scan_args "1:" pattern needs call-frame
     keyword-splat state, only set by full Ruby method dispatch -- a raw
     C call segfaults/misparses (same constraint documented on
     rb_ca_partition_copy_c above).  Go through rb_funcallv_kw +
     RB_PASS_KEYWORDS instead, same pattern as the CA_OBJECT branch in
     rb_ca_partition_copy_c below. */
  static ID id_partition = 0;
  if ( !id_partition ) id_partition = rb_intern("partition");
  VALUE kw = rb_hash_new();
  rb_hash_aset(kw, ID2SYM(rb_intern("axis")), vaxis);
  rb_hash_aset(kw, ID2SYM(rb_intern("masked_position")), masked_last ? ID2SYM(rb_intern("last")) : ID2SYM(rb_intern("first")));
  VALUE pv_argv[2] = { vkth, kw };
  VALUE view = rb_funcallv_kw(self, id_partition, 2, pv_argv, RB_PASS_KEYWORDS);
  VALUE obj = rb_ca_copy(view);
  CA_FACE_LIFT_IF_FACE(obj, self, ca);
  return obj;
}

/* Ruby entry: partition_copy(kth, axis: 0, masked_position: :last) */
static VALUE
rb_ca_partition_copy (int argc, VALUE *argv, VALUE self)
{
  VALUE vkth, rkw = Qnil;
  VALUE vaxis = INT2NUM(0);
  VALUE vmasked_position = Qnil;
  rb_scan_args(argc, argv, "1:", &vkth, &rkw);
  rb_scan_options(rkw, "axis,masked_position", &vaxis, &vmasked_position);

  int masked_last = 1;
  if ( !NIL_P(vmasked_position) ) {
    static ID sym_first = 0, sym_last = 0;
    if ( !sym_first ) sym_first = rb_intern("first");
    if ( !sym_last )  sym_last  = rb_intern("last");
    ID mp_id = SYM2ID(vmasked_position);
    if      ( mp_id == sym_last )  masked_last = 1;
    else if ( mp_id == sym_first ) masked_last = 0;
    else {
      rb_raise(rb_eArgError,
               "partition_copy: unknown masked_position %s (expected :first or :last)",
               rb_id2name(mp_id));
    }
  }
  return rb_ca_partition_copy_c_mp(self, vkth, vaxis, masked_last);
}

/* partition(kth, axis: 0, masked_position: :last)
 *
 * Returns a CARemap view of +self+ partitioned along +axis+ such that
 * the cell at the kth fiber-local position contains the kth-smallest
 * value, with all cells before it <= and all cells after >=.  Order
 * within the < and > regions is unspecified.  Average O(n) per fiber
 * via the partition_addr_ki kernel (mkkernel `:sort` kind, algorithm:
 * :partition).
 *
 * Signature mirrors rb_ca_sorted_view: positional kth + optional axis: /
 * masked_position: kwargs (default 0 / :last).  Mask handling mirrors
 * {sort}: masked cells are an incomparable sentinel clustered at
 * masked_position:, excluded from the kth-selection; a kth landing in
 * the masked cluster needs no selection (unspecified order, same
 * contract as the < / > regions).  kth validation matches
 * partition_addr_ki (-dim[axis] <= kth < dim[axis], negative counts
 * from end).
 */
static VALUE
rb_ca_partitioned_view (int argc, VALUE *argv, VALUE self)
{
  VALUE vkth, rkw = Qnil;
  VALUE vaxis = INT2NUM(0);
  VALUE vmasked_position = Qnil;

  rb_scan_args(argc, argv, "1:", &vkth, &rkw);
  rb_scan_options(rkw, "axis,masked_position", &vaxis, &vmasked_position);

  int masked_last = 1;
  if ( !NIL_P(vmasked_position) ) {
    static ID sym_first = 0, sym_last = 0;
    if ( !sym_first ) sym_first = rb_intern("first");
    if ( !sym_last )  sym_last  = rb_intern("last");
    ID mp_id = SYM2ID(vmasked_position);
    if      ( mp_id == sym_last )  masked_last = 1;
    else if ( mp_id == sym_first ) masked_last = 0;
    else {
      rb_raise(rb_eArgError,
               "partition: unknown masked_position %s (expected :first or :last)",
               rb_id2name(mp_id));
    }
  }

  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  /* CA_FIXLEN flows through the same partition_addr_ki fixlen dialect
     as numeric; masked_position: applies uniformly across dtypes. */
  VALUE target = self;

  /* partition_addr_ki_mp validates axis + kth, splits masked cells to
     masked_position:, and quickselects per fiber over the unmasked
     sub-range.  Returns CA_SIZE same-shape array of view-flat addresses
     suitable for direct ca_remap_new wrap; the remap gather carries
     target's mask bits through so masked cells stay masked at their
     clustered position (no extra output-mask step needed here). */
  volatile VALUE sigma_addr = rb_ca_partition_addr_ki_mp(target, vaxis, vkth, masked_last);
  {
    VALUE obj = rb_ca_remap_new(target, sigma_addr);
    CA_FACE_LIFT_IF_FACE(obj, self, ca);
    return obj;
  }
}

/* ----------------------------------------------------------------------- */

void
Init_carray_partition (void)
{
  /* `partition(kth, axis: k)` returns a CARemap view via the
     quickselect kernel partition_addr_ki.  The eager-position sibling
     `partition_index` (lib/carray/ordering.rb) wraps partition_index_ki
     under the same convention. */
  rb_define_method(rb_cCArray,  "partition", rb_ca_partitioned_view, -1);

  /* `partition_copy` is the eager counterpart to `partition`: returns a
     fresh entity array via per-fiber quickselect, bypassing the CARemap
     scatter layer.  Same mask / axis / kth semantics as the view form. */
  rb_define_method(rb_cCArray,  "partition_copy", rb_ca_partition_copy, -1);
}
