#include "ruby.h"
#include "carray.h"
#include "ca_kernel_iterator.h"
#include "ca_obj_face.h"
#include <math.h>
#include <float.h>
#include <stdlib.h>

/* Interned IDs used by the dispatchers below.  rb_funcall is retained
 * only where there is no clean C entry: `-` (operator dispatch in
 * rb_ca_order handles Integer vs CArray uniformly via method dispatch)
 * and Symbol tag comparison for `method:` kwarg. */
static ID id_axis, id_sub,
          id_sym_binary, id_sym_linear;

/* ------------------------------------------------------------------- */

#define proc_project(type)                    \
  {                                           \
    type *p = (type*)co->ptr;                 \
    type *q = (type*)ca->ptr;                 \
    for (i=0; i<ci->elements; i++) {          \
      if ( *mii ) {                           \
        *mio = 1;                             \
      }                                       \
      n = *(ip+i);                            \
      if ( n < 0 ) {                          \
        if ( lfill ) {                        \
          *(p+i) = *(type *)lfill;            \
        }                                     \
        else {                                \
          *mio = 1;                           \
        }                                     \
      }                                       \
      else if ( n >= map_elements ) {         \
        if ( ufill ) {                        \
          *(p+i) = *(type *)ufill;            \
        }                                     \
        else {                                \
          *mio = 1;                           \
        }                                     \
      }                                       \
      else {                                  \
        if ( *(mia+n) ) {                     \
          *mio = 1;                           \
        }                                     \
        else {                                \
          *(p+i) = *(q+n);                    \
        }                                     \
      }                                       \
      mio++; mii++;                           \
    }                                         \
  }

/* Inner loop of ca_project: gather ca[ci[i]] into co with optional
 * lfill/ufill for out-of-range indices.  Called only by ca_project. */
static void
ca_project_loop (CArray *co, CArray *ca, CArray *ci, char *lfill, char *ufill)
{
  ca_size_t map_elements = ca->elements;
  ca_size_t *ip = (ca_size_t*) ci->ptr;
  ca_size_t n, i;
  boolean8_t *mi, *ma;
  boolean8_t *mio, *mii, *mia;

  ca_create_mask(co);
  mio = (boolean8_t *) co->mask->ptr;
  mii = mi = ca_allocate_mask_iterator(1, ci);
  mia = ma = ca_allocate_mask_iterator(1, ca);

  switch ( co->bytes ) {
  case 1: proc_project(int8_t); break;
  case 2: proc_project(int16_t); break;
  case 4: proc_project(int32_t); break;
  case 8: proc_project(float64_t); break;
  default:
    {
      char *p = co->ptr;
      char *q = ca->ptr;
      for (i=0; i<ci->elements; i++) {
        if ( *mii ) {
          *mio = 1;
        }
        n = *(ip+i);
        if ( n < 0 ) {
          if ( lfill ) {
            memcpy(p + i * ca->bytes, lfill, ca->bytes);
          }
          else {
            *mio = 1;
          }
        }
        else if ( n >= map_elements ) {
          if ( ufill ) {
            memcpy(p + i * ca->bytes, ufill, ca->bytes);
          }
          else {
            *mio = 1;
          }
        }
        else {
          if ( *(mia+n) ) {
            *mio = 1;
          }
          else {
            memcpy(p + i * ca->bytes, q + n * ca->bytes, ca->bytes);
          }
        }
        mio++; mii++;
      }
    }
    break;
  }
  xfree(mi);
  xfree(ma);
}

CArray *
ca_project (CArray *ca, CArray *ci, char *lfill, char *ufill)
{
  CArray *co;

  ca_attach_n(2, ca, ci); /* ATTACH */

  co = carray_new(ca->data_type, ci->ndim, ci->dim, ca->bytes, NULL);
  ca_project_loop(co, ca, ci, lfill, ufill);

  ca_detach_n(2, ca, ci); /* DETACH */

  return co;
}

/* project(idx, lval=nil, uval=nil) — gather: for each element of `idx`,
 * pick `self[idx[i]]`.  Returns an entity CArray shaped like `idx`.
 *
 * Out-of-range index handling: negative or >= self.elements indices
 * produce `lval` (lower) / `uval` (upper) if provided, otherwise mask
 * the output cell.  Masked inputs (`idx` mask or `self` mask) also
 * propagate as masked output.
 */
VALUE
rb_ca_project (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE obj, ridx, vlfval, vufval, vstorage;
  CArray *ca, *ci, *co;
  char *lfval, *ufval;
  int self_is_face;

  rb_scan_args(argc, argv, "12", (VALUE *)&ridx, (VALUE *) &vlfval, (VALUE *) &vufval);

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  self_is_face = ca_is_face(ca);

  rb_check_carray_object(ridx);
  ci = ca_wrap_readonly(ridx, CA_SIZE);

  /* The fill args arrive as surface values.  rb_ca_obj2ptr owns the
     surface->storage conversion: for a Face self it fires the scalar_to_storage
     write hook (a datetime scalar / Time is reconciled to the Face's unit),
     for a plain array it writes the storage bytes directly. */
  lfval = xmalloc(ca->bytes);
  ufval = xmalloc(ca->bytes);

  if ( ! NIL_P(vlfval) ) {
    rb_ca_obj2ptr(self, vlfval, lfval);
    rb_ca_obj2ptr(self, vlfval, ufval);
  }

  if ( ! NIL_P(vufval) ) {
    rb_ca_obj2ptr(self, vufval, ufval);
  }

  /* Strip Face -> gather on storage -> face-lift (the same tail sort/search
     use, see docs/authoring/FaceOrderingSearch.md).  The gather runs on the raw
     storage so length / miss->UNDEF / fill semantics are unchanged; the
     result is then re-wrapped as the source Face, and copy_state carries the
     subclass state (datetime/timedelta unit, categorical labels). */
  vstorage = self;
  if ( self_is_face ) {
    vstorage = rb_ca_strip_face_value(self);
    TypedData_Get_Struct(vstorage, CArray, &carray_data_type, ca);
  }

  co = ca_project(ca, ci,
                 ( ! NIL_P(vlfval) ) ? lfval : NULL,
                 ( ( ! NIL_P(vufval) ) || ( ! NIL_P(vlfval) ) ) ? ufval : NULL);

  xfree(lfval);
  xfree(ufval);

  obj = ca_wrap_struct(co);

  if ( ! ca_is_any_masked(co) ) {
    obj = rb_ca_unmask_copy(obj);
  }

  if ( self_is_face ) {
    obj = ca_face_lift(obj, self);
  }

  return obj;
}

/* ------------------------------------------------------------------------- */

/* ---- search family kwarg trampolines (dual API: index vs addr) ------
 *
 * Each trampoline parses the `axis:` kwarg and dispatches:
 *   axis nil -> inline no-axis flat path: flatten self + flatten query
 *               (if CArray) + call the _ki kernel at axis 0, then
 *               reshape the result to the query's shape via
 *               ca_reshape_search_result
 *   axis k   -> per-axis kernel from carray_kernels.c.  The "index"
 *               variants use the :fiber_local kernels (axis-local
 *               position per fiber); the "addr" variants use the
 *               :view_flat kernels (view-flat address per fiber).
 *
 * For the no-axis path both variant families route through the index
 * kernel (_ki, not _addr_ki): the 1-D flattening makes addr == index,
 * so the two names share the same implementation.
 */

extern VALUE rb_ca_bsearch_ki              (VALUE self, VALUE rval, VALUE raxis);
extern VALUE rb_ca_bsearch_addr_ki         (VALUE self, VALUE rval, VALUE raxis);
extern VALUE rb_ca_search_ki               (int argc, VALUE *argv, VALUE self);
extern VALUE rb_ca_search_addr_ki          (int argc, VALUE *argv, VALUE self);
extern VALUE rb_ca_search_nearest_ki       (VALUE self, VALUE rval, VALUE raxis);
extern VALUE rb_ca_search_nearest_addr_ki  (VALUE self, VALUE rval, VALUE raxis);

/* Direct C function entries used by the dispatchers below.  Declared
 * here when not already in carray.h / umbrella headers.
 *
 * The `_c` suffix marks "C-callable entry": a thin twin of the Ruby-
 * binding function that skips rb_scan_args.  Ruby's `:` kwarg parsing
 * reads the call-frame keyword-splat state, which is only set by full
 * method dispatch -- calling the Ruby entry directly from C would
 * segfault.  Pattern: Ruby entry parses argv via rb_scan_args and
 * forwards to the `_c` twin.
 */
extern VALUE rb_ca_sort_addr_c               (VALUE self, VALUE axis, int stable, int masked_last);
extern VALUE rb_ca_axis2addr_c               (VALUE self, VALUE vindices, VALUE vaxis);
extern VALUE rb_ca_count_not_masked_c        (VALUE self, VALUE axis_val);
extern VALUE rb_ca_flip_axis                 (VALUE self, long axis);
extern VALUE rb_ca_argmin_addr_ki            (int argc, VALUE *argv, VALUE self);
extern VALUE rb_ca_argmax_addr_ki            (int argc, VALUE *argv, VALUE self);
extern VALUE rb_ca_minmax_ki                 (int argc, VALUE *argv, VALUE self);
extern VALUE rb_ca_linear_section_binary_ki  (VALUE self, VALUE rval, VALUE raxis);
extern VALUE rb_ca_linear_section_linear_ki  (VALUE self, VALUE rval, VALUE raxis);
extern VALUE rb_ca_linear_fetch_ki           (VALUE self, VALUE rval, VALUE raxis);
extern VALUE rb_ca_insert_axis               (int argc, VALUE *argv, VALUE self);
extern VALUE rb_ca_reshape                   (int argc, VALUE *argv, VALUE self);

/* mkkernel-emitted kernels marked `c_callable: true`: extern symbols
 * in carray_kernels.c that allow direct C-level dispatch without going
 * through rb_funcall + kwarg hash construction. */
extern VALUE rb_ca_sort_index_ki_quick       (VALUE self, VALUE vaxis);
extern VALUE rb_ca_partition_index_ki        (VALUE self, VALUE vaxis, VALUE vkth);
extern VALUE rb_ca_rank_index_ki_quick_dense (VALUE self, VALUE vaxis, int dense);

/* ---- no-axis (flat) search helper -----------------------------------
 *
 * Contract for the no-axis path (`axis: nil`):
 *   non-CArray query -> scalar result (Integer / nil)
 *   CArray query     -> query-shaped CArray result (UNDEF cells on no-match)
 *
 * Implementation: flatten self + flatten query, run the per-axis _ki
 * kernel at axis 0, then reshape the raw 1-D result to query's shape
 * via the helper below.
 */

/* Rebuild a query-shaped result from the kernel output.  Two paths:
 *   (a) scalar collapse: _ki returns Integer / nil when query is a
 *       single-element CArray.  Build a query-shaped entity directly
 *       and store the value (CA_UNDEF for nil -> auto-mask).
 *   (b) CArray result: reshape to query.shape (the helpers flatten the
 *       query before calling _ki, so the raw result is 1-D).
 *
 * Called by the search family trampolines below (bsearch_kw /
 * search_kw / search_nearest_kw and their _addr siblings) on the
 * no-axis path. */
static VALUE
ca_reshape_search_result (VALUE query, VALUE rraw)
{
  CArray *cq;
  GetCArray(query, cq);

  if ( ! rb_obj_is_carray(rraw) ) {
    VALUE vr = rb_carray_new(CA_SIZE, cq->ndim, cq->dim, 0, NULL);
    rb_ca_store_addr(vr, 0, NIL_P(rraw) ? CA_UNDEF : rraw);
    return vr;
  }

  VALUE shape_argv[CA_RANK_MAX];
  for ( int8_t k = 0; k < cq->ndim; k++ ) {
    shape_argv[k] = LONG2NUM((long) cq->dim[k]);
  }
  return rb_ca_reshape((int) cq->ndim, shape_argv, rraw);
}

static VALUE
rb_ca_bsearch_kw (int argc, VALUE *argv, VALUE self)
{
  VALUE ropt = rb_pop_options(&argc, &argv);
  VALUE raxis = Qnil;
  rb_scan_options(ropt, "axis", &raxis);
  rb_check_arity(argc, 1, 1);

  if ( NIL_P(raxis) ) {
    VALUE flat = rb_ca_flatten(self);
    VALUE q    = rb_obj_is_carray(argv[0]) ? rb_ca_flatten(argv[0]) : argv[0];
    VALUE r    = rb_ca_bsearch_ki(flat, q, INT2FIX(0));
    return rb_obj_is_carray(argv[0]) ? ca_reshape_search_result(argv[0], r) : r;
  }
  return rb_ca_bsearch_ki(self, argv[0], raxis);
}

static VALUE
rb_ca_bsearch_addr_kw (int argc, VALUE *argv, VALUE self)
{
  VALUE ropt = rb_pop_options(&argc, &argv);
  VALUE raxis = Qnil;
  rb_scan_options(ropt, "axis", &raxis);
  rb_check_arity(argc, 1, 1);

  if ( NIL_P(raxis) ) {
    /* 1-D self: view-flat addr == axis-local index, so the no-axis
       path reuses _ki (not _addr_ki) -- both variants share output. */
    VALUE flat = rb_ca_flatten(self);
    VALUE q    = rb_obj_is_carray(argv[0]) ? rb_ca_flatten(argv[0]) : argv[0];
    VALUE r    = rb_ca_bsearch_ki(flat, q, INT2FIX(0));
    return rb_obj_is_carray(argv[0]) ? ca_reshape_search_result(argv[0], r) : r;
  }
  return rb_ca_bsearch_addr_ki(self, argv[0], raxis);
}

static VALUE
rb_ca_search_kw (int argc, VALUE *argv, VALUE self)
{
  VALUE ropt = rb_pop_options(&argc, &argv);
  VALUE raxis = Qnil;
  rb_scan_options(ropt, "axis", &raxis);
  rb_check_arity(argc, 1, 2);

  if ( NIL_P(raxis) ) {
    VALUE flat = rb_ca_flatten(self);
    VALUE q    = rb_obj_is_carray(argv[0]) ? rb_ca_flatten(argv[0]) : argv[0];
    VALUE r;
    VALUE ki_argv[3] = { q, INT2FIX(0), argv[1] };
    if ( argc >= 2 ) {
      r = rb_ca_search_ki(3, ki_argv, flat);
    }
    else {
      r = rb_ca_search_ki(2, ki_argv, flat);
    }
    return rb_obj_is_carray(argv[0]) ? ca_reshape_search_result(argv[0], r) : r;
  }
  /* search_ki(val, axis, eps) -- argc=2 (val,axis) or 3 (val,axis,eps) */
  VALUE ki_argv[3] = { argv[0], raxis, argv[1] };
  if ( argc >= 2 ) {
    return rb_ca_search_ki(3, ki_argv, self);
  }
  return rb_ca_search_ki(2, ki_argv, self);
}

static VALUE
rb_ca_search_addr_kw (int argc, VALUE *argv, VALUE self)
{
  VALUE ropt = rb_pop_options(&argc, &argv);
  VALUE raxis = Qnil;
  rb_scan_options(ropt, "axis", &raxis);
  rb_check_arity(argc, 1, 2);

  if ( NIL_P(raxis) ) {
    /* 1-D self: addr == index reuses _ki (not _addr_ki). */
    VALUE flat = rb_ca_flatten(self);
    VALUE q    = rb_obj_is_carray(argv[0]) ? rb_ca_flatten(argv[0]) : argv[0];
    VALUE r;
    VALUE ki_argv[3] = { q, INT2FIX(0), argv[1] };
    if ( argc >= 2 ) {
      r = rb_ca_search_ki(3, ki_argv, flat);
    }
    else {
      r = rb_ca_search_ki(2, ki_argv, flat);
    }
    return rb_obj_is_carray(argv[0]) ? ca_reshape_search_result(argv[0], r) : r;
  }
  VALUE ki_argv[3] = { argv[0], raxis, argv[1] };
  if ( argc >= 2 ) {
    return rb_ca_search_addr_ki(3, ki_argv, self);
  }
  return rb_ca_search_addr_ki(2, ki_argv, self);
}

static VALUE
rb_ca_search_nearest_kw (int argc, VALUE *argv, VALUE self)
{
  VALUE ropt = rb_pop_options(&argc, &argv);
  VALUE raxis = Qnil;
  rb_scan_options(ropt, "axis", &raxis);
  rb_check_arity(argc, 1, 1);

  if ( NIL_P(raxis) ) {
    VALUE flat = rb_ca_flatten(self);
    VALUE q    = rb_obj_is_carray(argv[0]) ? rb_ca_flatten(argv[0]) : argv[0];
    VALUE r    = rb_ca_search_nearest_ki(flat, q, INT2FIX(0));
    return rb_obj_is_carray(argv[0]) ? ca_reshape_search_result(argv[0], r) : r;
  }
  return rb_ca_search_nearest_ki(self, argv[0], raxis);
}

static VALUE
rb_ca_search_nearest_addr_kw (int argc, VALUE *argv, VALUE self)
{
  VALUE ropt = rb_pop_options(&argc, &argv);
  VALUE raxis = Qnil;
  rb_scan_options(ropt, "axis", &raxis);
  rb_check_arity(argc, 1, 1);

  if ( NIL_P(raxis) ) {
    /* 1-D self: addr == index reuses _ki (not _addr_ki) -- same as bsearch_addr. */
    VALUE flat = rb_ca_flatten(self);
    VALUE q    = rb_obj_is_carray(argv[0]) ? rb_ca_flatten(argv[0]) : argv[0];
    VALUE r    = rb_ca_search_nearest_ki(flat, q, INT2FIX(0));
    return rb_obj_is_carray(argv[0]) ? ca_reshape_search_result(argv[0], r) : r;
  }
  return rb_ca_search_nearest_addr_ki(self, argv[0], raxis);
}


/* ===========================================================================
 * Ordering surface (C-side implementations of CArray ordering methods).
 *
 * Call sites use direct C function calls wherever possible; rb_funcall
 * is retained only where there is no clean C entry: the `-` operator
 * (Ruby method dispatch handles both `Integer - Integer` and
 * `CArray - Integer` / `Integer - CArray` uniformly) and Symbol tag
 * comparison for `method:` kwarg.
 * =========================================================================== */

/* ---- sort_by_key family ---------------------------------------------- */

/* sort_by_key(key, axis: 0) -- gather self at key.sort_addr(axis:). */
static VALUE
rb_ca_sort_by_key (int argc, VALUE *argv, VALUE self)
{
  VALUE rkey, rkw = Qnil, raxis = Qnil;
  rb_scan_args(argc, argv, "1:", &rkey, &rkw);
  rb_scan_options(rkw, "axis", &raxis);
  if ( NIL_P(raxis) ) {
    raxis = INT2FIX(0);
  }
  VALUE addrs = rb_ca_sort_addr_c(rkey, raxis, 0, 1);  /* masked_last=1 (:last), unchanged default */
  return rb_ca_fetch(self, addrs);
}

/* max_by_key(key, axis: nil) -- self[key.max_addr(axis:)] (or UNDEF if empty). */
static VALUE
rb_ca_max_by_key (int argc, VALUE *argv, VALUE self)
{
  VALUE rkey, rkw = Qnil, raxis = Qnil;
  rb_scan_args(argc, argv, "1:", &rkey, &rkw);
  rb_scan_options(rkw, "axis", &raxis);
  if ( RTEST(rb_ca_is_empty(self)) ) {
    return rb_const_get(rb_cObject, rb_intern("UNDEF"));
  }

  VALUE addrs;

  if ( NIL_P(raxis) ) {
    VALUE ki_argv[1] = { Qnil };   /* non-NULL for safety, unused at argc=0 */
    addrs = rb_ca_argmax_addr_ki(0, ki_argv, rkey);
  }
  else {
    VALUE kw = rb_hash_new();
    rb_hash_aset(kw, ID2SYM(id_axis), raxis);
    addrs = rb_ca_argmax_addr_ki(1, &kw, rkey);
  }
  return rb_ca_fetch(self, addrs);
}

/* min_by_key(key, axis: nil) -- self[key.min_addr(axis:)] (or UNDEF if empty). */
static VALUE
rb_ca_min_by_key (int argc, VALUE *argv, VALUE self)
{
  VALUE rkey, rkw = Qnil, raxis = Qnil;
  rb_scan_args(argc, argv, "1:", &rkey, &rkw);
  rb_scan_options(rkw, "axis", &raxis);
  if ( RTEST(rb_ca_is_empty(self)) ) {
    return rb_const_get(rb_cObject, rb_intern("UNDEF"));
  }

  VALUE addrs;

  if ( NIL_P(raxis) ) {
    VALUE ki_argv[1] = { Qnil };
    addrs = rb_ca_argmin_addr_ki(0, ki_argv, rkey);
  }
  else {
    VALUE kw = rb_hash_new();
    rb_hash_aset(kw, ID2SYM(id_axis), raxis);
    addrs = rb_ca_argmin_addr_ki(1, &kw, rkey);
  }
  return rb_ca_fetch(self, addrs);
}

/* ---- take_along_axis / put_along_axis -------------------------------- */

/* C-callable positional twin: skip rb_scan_args / kwarg hash machinery
   so internal C consumers (e.g. nlargest / nsmallest family) can call
   directly without a kwarg trampoline.  The Ruby binding forwards here. */
static VALUE
rb_ca_take_along_axis_c (VALUE self, VALUE indices, VALUE raxis)
{
  if ( NIL_P(raxis) ) {
    raxis = INT2FIX(0);
  }
  VALUE addrs = rb_ca_axis2addr_c(self, indices, raxis);
  return rb_ca_fetch(self, addrs);
}

static VALUE
rb_ca_take_along_axis (int argc, VALUE *argv, VALUE self)
{
  VALUE ropt = rb_pop_options(&argc, &argv);
  VALUE raxis = Qnil;
  rb_scan_options(ropt, "axis", &raxis);
  rb_check_arity(argc, 1, 1);
  return rb_ca_take_along_axis_c(self, argv[0], raxis);
}

static VALUE
rb_ca_put_along_axis (int argc, VALUE *argv, VALUE self)
{
  VALUE ropt = rb_pop_options(&argc, &argv);
  VALUE raxis = Qnil;
  rb_scan_options(ropt, "axis", &raxis);
  rb_check_arity(argc, 2, 2);
  if ( NIL_P(raxis) ) {
    raxis = INT2FIX(0);
  }
  VALUE addrs = rb_ca_axis2addr_c(self, argv[0], raxis);
  rb_ca_store(self, addrs, argv[1]);
  return self;
}

/* ---- range -- (min..max) via fused minmax ----------------------------- */

static VALUE
rb_ca_range_method (VALUE self)
{
  VALUE mm_argv[1] = { Qnil };
  VALUE pair = rb_ca_minmax_ki(0, mm_argv, self);
  VALUE lo = rb_ary_entry(pair, 0);
  VALUE hi = rb_ary_entry(pair, 1);
  return rb_range_new(lo, hi, 0);
}

/* ---- nlargest / nsmallest family ------------------------------------- */

/* Per-axis top-k positions (cap clamped, axis normalized).
 * Called by rb_ca_topk_index below. */
static VALUE
rb_ca_topk_positions (VALUE self, long cap, long axis_norm, int desc)
{
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  long dim_axis = (long) ca->dim[axis_norm];
  VALUE raxis_norm = LONG2NUM(axis_norm);

  if ( cap >= dim_axis ) {
    VALUE full = rb_ca_sort_index_ki_quick(self, raxis_norm);
    if ( desc ) {
      full = rb_ca_flip_axis(full, NUM2LONG(raxis_norm));
    }
    return rb_ca_copy(full);
  }

  long pivot = desc ? (dim_axis - cap) : (cap - 1);
  VALUE rpivot = LONG2NUM(pivot);

  /* Build a Ruby indexer spec: nil on every axis except `axis_norm`,
     where we take the top-k (or bottom-k) range after partitioning. */
  int ndim = (int) ca->ndim;
  VALUE spec[CA_RANK_MAX];
  for ( int k = 0; k < ndim; k++ ) {
    spec[k] = Qnil;
  }
  spec[axis_norm] = desc
    ? rb_range_new(rpivot, LONG2NUM(dim_axis - 1), 0)   /* (pivot..dim-1) */
    : rb_range_new(INT2FIX(0), LONG2NUM(cap), 1);       /* (0...cap) */

  /* partidx_full[*spec] |> take_along_axis(...) |> sort_index(...) |>
     flip(if desc) |> take_along_axis(...) |> copy. */
  VALUE partidx_full = rb_ca_partition_index_ki(self, raxis_norm, rpivot);
  VALUE partidx_top  = rb_ca_fetch2(partidx_full, ndim, spec);
  VALUE vals_top     = rb_ca_take_along_axis_c(self, partidx_top, raxis_norm);
  VALUE order        = rb_ca_sort_index_ki_quick(vals_top, raxis_norm);
  if ( desc ) {
    order = rb_ca_flip_axis(order, NUM2LONG(raxis_norm));
  }
  VALUE picked = rb_ca_take_along_axis_c(partidx_top, order, raxis_norm);
  return rb_ca_copy(picked);
}

/* Dispatcher: normalize axis, clamp cap, empty-cap corner.
 * Called by rb_ca_nlargest_index / rb_ca_nsmallest_index (index
 * variants) and indirectly by rb_ca_topk_values below. */
static VALUE
rb_ca_topk_index (VALUE self, VALUE rn, VALUE raxis, int desc, const char *name)
{
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  long a = rb_ca_normalize_axis_value(self, raxis, name);
  long n_val = NUM2LONG(rn);
  long dim_a = (long) ca->dim[a];
  long cap = (n_val < dim_a) ? n_val : dim_a;
  if ( cap < 0 ) {
    cap = 0;
  }
  if ( cap == 0 ) {
    /* Return zero-along-axis int64 array via the C carray constructor. */
    ca_size_t out_dim[CA_RANK_MAX];
    for ( int k = 0; k < (int) ca->ndim; k++ ) {
      out_dim[k] = (k == a) ? 0 : ca->dim[k];
    }
    return rb_carray_new(CA_INT64, ca->ndim, out_dim, 0, NULL);
  }
  return rb_ca_topk_positions(self, cap, a, desc);
}

static VALUE
rb_ca_nlargest_index (int argc, VALUE *argv, VALUE self)
{
  VALUE ropt = rb_pop_options(&argc, &argv);
  VALUE raxis = Qnil;
  rb_scan_options(ropt, "axis", &raxis);
  rb_check_arity(argc, 1, 1);
  if ( NIL_P(raxis) ) {
    rb_raise(rb_eArgError, "nlargest_index: axis: kwarg is required");
  }
  return rb_ca_topk_index(self, argv[0], raxis, 1, "nlargest_index");
}

static VALUE
rb_ca_nsmallest_index (int argc, VALUE *argv, VALUE self)
{
  VALUE ropt = rb_pop_options(&argc, &argv);
  VALUE raxis = Qnil;
  rb_scan_options(ropt, "axis", &raxis);
  rb_check_arity(argc, 1, 1);
  if ( NIL_P(raxis) ) {
    rb_raise(rb_eArgError, "nsmallest_index: axis: kwarg is required");
  }
  return rb_ca_topk_index(self, argv[0], raxis, 0, "nsmallest_index");
}

/* Shared body for nlargest / nsmallest (desc=1 vs desc=0).
 * Called by rb_ca_nlargest and rb_ca_nsmallest below. */
static VALUE
rb_ca_topk_values (VALUE self, VALUE rn, VALUE raxis, int desc, const char *name)
{
  if ( NIL_P(raxis) ) {
    /* No-axis path: flatten + axis-0 topk + fetch. */
    VALUE flat = rb_ca_flatten(self);
    VALUE idx  = rb_ca_topk_index(flat, rn, INT2FIX(0), desc, name);
    return rb_ca_take_along_axis_c(flat, idx, INT2FIX(0));
  }
  long a = rb_ca_normalize_axis_value(self, raxis, name);
  VALUE idx = rb_ca_topk_index(self, rn, LONG2NUM(a), desc, name);
  return rb_ca_take_along_axis_c(self, idx, LONG2NUM(a));
}

static VALUE
rb_ca_nlargest (int argc, VALUE *argv, VALUE self)
{
  VALUE ropt = rb_pop_options(&argc, &argv);
  VALUE raxis = Qnil;
  rb_scan_options(ropt, "axis", &raxis);
  rb_check_arity(argc, 1, 1);
  return rb_ca_topk_values(self, argv[0], raxis, 1, "nlargest");
}

static VALUE
rb_ca_nsmallest (int argc, VALUE *argv, VALUE self)
{
  VALUE ropt = rb_pop_options(&argc, &argv);
  VALUE raxis = Qnil;
  rb_scan_options(ropt, "axis", &raxis);
  rb_check_arity(argc, 1, 1);
  return rb_ca_topk_values(self, argv[0], raxis, 0, "nsmallest");
}

/* ---- order(axis:, descending:, method:) -------------------------------
 *
 * method: :ordinal (default) assigns every cell a distinct rank (ties
 * broken by stable original position, scipy.stats.rankdata 'ordinal'
 * style).  method: :dense assigns tied values the same rank (no gaps),
 * the standard "dense rank" -- lets order(descending:) compose as a
 * sort_addr priority key without silently dropping a lower-priority
 * key on ties: ordinal ranks are already a total order (no two cells
 * ever compare equal), so a later sort_addr key never gets consulted;
 * dense ranks preserve ties, so it does.
 *
 * descending: still works under method: :dense via the same
 * (n-1)-ascending transform below: n is fixed per-fiber, so within a
 * tied group ascending values are equal and (n-1)-ascending stays
 * equal too -- ties survive the transform, and the group-to-group
 * order still reverses correctly. */

static VALUE
rb_ca_order (int argc, VALUE *argv, VALUE self)
{
  VALUE ropt = rb_pop_options(&argc, &argv);
  VALUE raxis = Qnil, rdesc = Qfalse, rmethod = Qnil;
  rb_scan_options(ropt, "axis,descending,method", &raxis, &rdesc, &rmethod);
  rb_check_arity(argc, 0, 0);

  int dense = 0;   /* default method: :ordinal */
  if ( ! NIL_P(rmethod) ) {
    static ID sym_ordinal = 0, sym_dense = 0;
    if ( ! sym_ordinal ) sym_ordinal = rb_intern("ordinal");
    if ( ! sym_dense )   sym_dense   = rb_intern("dense");
    ID method_id = SYM2ID(rmethod);
    if      ( method_id == sym_ordinal ) dense = 0;
    else if ( method_id == sym_dense )   dense = 1;
    else {
      rb_raise(rb_eArgError, "order: unknown method %s (expected :ordinal or :dense)",
               rb_id2name(method_id));
    }
  }

  VALUE asc, n;
  if ( NIL_P(raxis) ) {
    VALUE flat = rb_ca_flatten(self);
    /* Direct C-level dispatch via c_callable: true extern (mkkernel). */
    VALUE ranked = rb_ca_rank_index_ki_quick_dense(flat, INT2FIX(0), dense);
    /* reshape(*shape) */
    CArray *ca;
    TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
    VALUE shape_argv[CA_RANK_MAX];
    for ( long k = 0; k < (long) ca->ndim; k++ ) {
      shape_argv[k] = LONG2NUM((long) ca->dim[k]);
    }
    asc = rb_ca_reshape((int) ca->ndim, shape_argv, ranked);
    n = RTEST(rb_ca_has_mask(self))
      ? SIZE2NUM(ca_count_not_masked(ca))   /* = elements - count_masked */
      : rb_ca_elements(self);
  } else {
    long axis_norm = rb_ca_normalize_axis_value(self, raxis, "order");
    VALUE raxis_norm = LONG2NUM(axis_norm);
    asc = rb_ca_rank_index_ki_quick_dense(self, raxis_norm, dense);
    if ( RTEST(rb_ca_has_mask(self)) ) {
      n = rb_ca_count_not_masked_c(self, raxis_norm);
    } else {
      CArray *ca;
      TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
      n = LONG2NUM((long) ca->dim[axis_norm]);
    }
    if ( RTEST(rb_obj_is_kind_of(n, rb_cCArray)) ) {
      VALUE ia_argv[1] = { raxis_norm };
      n = rb_ca_insert_axis(1, ia_argv, n);
    }
  }

  VALUE diff;
  if ( RTEST(rdesc) ) {
    /* `-` via rb_funcall handles both Integer-Integer and
       CArray/Integer mixed receivers uniformly via Ruby's operator
       dispatch.  No single C entry covers both. */
    VALUE n_minus_1 = rb_funcall(n, id_sub, 1, INT2FIX(1));
    diff = rb_funcall(n_minus_1, id_sub, 1, asc);
  } else {
    diff = asc;
  }
  /* Output data_type: CA_SIZE (= ca_size_t, int64 on 64-bit builds),
     matching the rest of the *_index family (sort_index / partition_index
     / rank_index) that order is built on.  No explicit cast needed here:
     asc (rank_index_ki's output) is already CA_SIZE, and Integer - CArray
     promotion in the descending branch preserves it. */
  return diff;
}

/* ---- linear_section / linear_fetch ----------------------------------- */

/* Coerce self to CA_FLOAT64 (no-copy when already f64 via
 * rb_ca_to_float64), then optionally flatten when axis is nil.
 * Called by rb_ca_linear_section_m and rb_ca_linear_fetch_m. */
static VALUE
ca_linear_prep (VALUE self, VALUE raxis, const char *name, long *axis_out)
{
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  /* Face gate: linear_section / linear_fetch treat the axis as a continuous
     numeric coordinate (fractional index by interpolating the stored values).
     An ORDERABLE Face (storage order == surface order) is descended to its
     storage here; the fraction is defined in storage space, which for a
     numeric-relabel Face (datetime int64, etc.) is exactly the coordinate.
     Non-orderable Faces raise.  Non-numeric storage (e.g. a fixlen-string
     Face) is caught by the rb_ca_to_float64 cast below, so no separate
     float-numeric flag is needed. */
  if ( ca_is_face(ca) ) {
    if ( ! ca_test_flag(ca, CA_FLAG_FACE_ORDERABLE_STORAGE) ) {
      rb_raise(rb_eArgError,
               "%s: Face-typed input (%s) is not orderable by storage; "
               "use ca.parent to descend to storage",
               name, rb_obj_classname(self));
    }
    self = rb_ca_strip_face_value(self);
    TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  }
  VALUE sc = (ca->data_type == CA_FLOAT64) ? self : rb_ca_to_float64(self);
  if ( NIL_P(raxis) ) {
    CArray *sca;
    TypedData_Get_Struct(sc, CArray, &carray_data_type, sca);
    if ( sca->ndim > 1 ) {
      sc = rb_ca_flatten(sc);
    }
    *axis_out = 0;
  } else {
    *axis_out = rb_ca_normalize_axis_value(sc, raxis, name);
  }
  return sc;
}

static VALUE
rb_ca_linear_section_m (int argc, VALUE *argv, VALUE self)
{
  VALUE ropt = rb_pop_options(&argc, &argv);
  VALUE raxis = Qnil, rmethod = ID2SYM(id_sym_binary);
  rb_scan_options(ropt, "axis,method", &raxis, &rmethod);
  rb_check_arity(argc, 1, 1);
  VALUE val = argv[0];

  /* Query gate (generic, mirror search + reference flip
     PROPOSAL_TO_COMPARABLE_RECEIVER_FLIP): the reference axis Face reconciles
     the query into its own space.  A COMPARABLE axis is directly comparable
     -> strip a Face query, take a plain query as-is.  A non-COMPARABLE Face
     axis calls its own to_comparable(query) for ANY query type (Face CArray,
     our Scalar, a Ruby Time / DateTime, ...), then strips; it raises if it
     cannot reconcile the query.  `self` is still the pre-strip axis Face
     here, so it carries the unit for to_comparable and its COMPARABLE flag. */
  {
    int val_is_face = 0, self_is_face = 0, self_comparable = 0;
    CArray *sca;
    if ( rb_obj_is_kind_of(val, rb_cCArray) ) {
      CArray *vca;
      TypedData_Get_Struct(val, CArray, &carray_data_type, vca);
      val_is_face = ca_is_face(vca);
    }
    TypedData_Get_Struct(self, CArray, &carray_data_type, sca);
    if ( ca_is_face(sca) ) {
      self_is_face = 1;
      self_comparable = ca_test_flag(sca, CA_FLAG_FACE_COMPARABLE_STORAGE);
    }
    if ( self_comparable ) {
      if ( val_is_face ) {
        val = rb_ca_strip_face_value(val);
      }
    }
    else if ( self_is_face ) {
      if ( rb_respond_to(self, rb_intern("to_comparable")) ) {
        val = rb_funcall(self, rb_intern("to_comparable"), 1, val);
        val = rb_ca_strip_face_value(val);
      }
      else {
        rb_raise(rb_eArgError,
                 "linear_section: non-comparable Face axis (%s) has no "
                 "to_comparable to reconcile the query; use ca.parent to "
                 "search the hidden storage explicitly",
                 rb_obj_classname(self));
      }
    }
  }

  long axis_norm = 0;
  VALUE sc = ca_linear_prep(self, raxis, "linear_section", &axis_norm);
  VALUE raxis_norm = LONG2NUM(axis_norm);

  if ( rmethod == ID2SYM(id_sym_binary) ) {
    return rb_ca_linear_section_binary_ki(sc, val, raxis_norm);
  } else if ( rmethod == ID2SYM(id_sym_linear) ) {
    return rb_ca_linear_section_linear_ki(sc, val, raxis_norm);
  } else {
    rb_raise(rb_eArgError,
             "linear_section: unknown method %"PRIsVALUE
             " (expected :binary or :linear)",
             rb_inspect(rmethod));
  }
}

static VALUE
rb_ca_linear_fetch_m (int argc, VALUE *argv, VALUE self)
{
  VALUE ropt = rb_pop_options(&argc, &argv);
  VALUE raxis = Qnil;
  rb_scan_options(ropt, "axis", &raxis);
  rb_check_arity(argc, 1, 1);
  VALUE addr = argv[0];

  long axis_norm = 0;
  VALUE sc = ca_linear_prep(self, raxis, "linear_fetch", &axis_norm);
  return rb_ca_linear_fetch_ki(sc, addr, LONG2NUM(axis_norm));
}

/* [MOVED] locate_addr / locate_nearest_addr (formerly matchup /
 * matchup_nearest) -> lib/carray/methods/locate_addr.rb (thin
 * compositions of sort_addr + fetch + bsearch (or linear_section +
 * mask_invalid + round/floor/ceil + int64) + project, all of which have
 * Ruby surfaces). */

/* [MOVED] median / percentile / quantile -> ext/carray_median_percentile.c
 * (kth-fetch + 5-method picker + partition-vs-sort dispatch).  That
 * file calls rb_ca_partition_copy_c (non-static in carray_partition.c)
 * for the numeric path; CA_OBJECT routes through the CA_OBJECT branches
 * of partition_copy / sort. */

extern VALUE rb_ca_value_array (VALUE self);  /* carray_mask.c */

void
Init_carray_order (void)
{
  id_axis         = rb_intern("axis");
  id_sub          = rb_intern("-");
  id_sym_binary   = rb_intern("binary");
  id_sym_linear   = rb_intern("linear");

  rb_define_method(rb_cCArray,  "project", rb_ca_project, -1);

  /* Search family (dual API: index / addr) -- see the trampoline
     comment block above for the axis: kwarg dispatch contract. */
  rb_define_method(rb_cCArray,  "bsearch",             rb_ca_bsearch_kw,             -1);
  rb_define_method(rb_cCArray,  "search",              rb_ca_search_kw,              -1);
  rb_define_method(rb_cCArray,  "search_nearest",      rb_ca_search_nearest_kw,      -1);
  rb_define_method(rb_cCArray,  "bsearch_addr",        rb_ca_bsearch_addr_kw,        -1);
  rb_define_method(rb_cCArray,  "search_addr",         rb_ca_search_addr_kw,         -1);
  rb_define_method(rb_cCArray,  "search_nearest_addr", rb_ca_search_nearest_addr_kw, -1);

  rb_define_method(rb_cCArray, "sort_by_key",      rb_ca_sort_by_key,      -1);
  rb_define_method(rb_cCArray, "max_by_key",       rb_ca_max_by_key,       -1);
  rb_define_method(rb_cCArray, "min_by_key",       rb_ca_min_by_key,       -1);
  rb_define_method(rb_cCArray, "take_along_axis",  rb_ca_take_along_axis,  -1);
  rb_define_method(rb_cCArray, "put_along_axis",   rb_ca_put_along_axis,   -1);
  rb_define_method(rb_cCArray, "range",            rb_ca_range_method,      0);
  rb_define_method(rb_cCArray, "nlargest",         rb_ca_nlargest,         -1);
  rb_define_method(rb_cCArray, "nsmallest",        rb_ca_nsmallest,        -1);
  rb_define_method(rb_cCArray, "nlargest_index",   rb_ca_nlargest_index,   -1);
  rb_define_method(rb_cCArray, "nsmallest_index",  rb_ca_nsmallest_index,  -1);
  rb_define_method(rb_cCArray, "order",            rb_ca_order,            -1);
  rb_define_method(rb_cCArray, "linear_section",   rb_ca_linear_section_m, -1);
  rb_define_method(rb_cCArray, "linear_fetch",     rb_ca_linear_fetch_m,   -1);

  /* [MOVED] bindings for the following live elsewhere:
       sort / sort_copy            -> carray_sort.c
       partition / partition_copy  -> carray_partition.c
       median / percentile / quantile -> carray_median_percentile.c
                                      (bound by Init_carray_median_percentile) */
}
