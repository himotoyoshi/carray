#include "ruby.h"
#include "carray.h"
#include "carray_internal.h"   /* ca_integer_arg */
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

/* The result is wrapped before anything is copied into it: for an object
   array the gathered cells are VALUEs that only the result's mark keeps
   alive once the source is detached. */
static VALUE
ca_project (CArray *ca, CArray *ci, char *lfill, char *ufill)
{
  volatile VALUE obj;
  CArray *co;

  obj = rb_carray_new(ca->data_type, ci->ndim, ci->dim, ca->bytes, NULL);
  GetCArray(obj, co);

  ca_attach_n(2, ca, ci); /* window: nothing raises inside */
  ca_project_loop(co, ca, ci, lfill, ufill);
  ca_detach_n(2, ca, ci); /* DETACH */

  return obj;
}

/* rk.__count_below__(q, inclusive) -- for each cell of q, how many values
 * of the sorted array rk are below it (at or below it when inclusive).
 * rk is 1-D, ascending, with no masked or NaN value; q has rk's data type
 * (any shape, read in address order).  The count is the insertion position
 * of the cell among rk's values, found by binary search; a masked or NaN
 * cell gets an arbitrary count, for the caller to mask.  Returns an int64
 * array of q's shape.  Numeric and boolean types only. */

/* The search keeps a base and a length and moves the base by a comparison
   rather than branching on it, which keeps the loop free of mispredicted
   branches; the last comparison adds the cell at the base. */
#define CA_COUNT_BELOW_LOOP(T, CMP)                                   \
  {                                                                   \
    const T *r = (const T *) cr->ptr;                                 \
    const T *x = (const T *) cq->ptr;                                 \
    for ( i = 0; i < m; i++ ) {                                       \
      T v = x[i];                                                     \
      const T *base = r;                                              \
      ca_size_t len = n;                                              \
      if ( len == 0 ) { out[i] = 0; continue; }                       \
      while ( len > 1 ) {                                             \
        ca_size_t half = len / 2;                                     \
        base = (base[half] CMP v) ? base + half : base;               \
        len -= half;                                                  \
      }                                                               \
      out[i] = (int64_t) (base - r) + ((*base CMP v) ? 1 : 0);        \
    }                                                                 \
  }

#define CA_COUNT_BELOW(T)                                             \
  if ( inclusive ) CA_COUNT_BELOW_LOOP(T, <=)                         \
  else             CA_COUNT_BELOW_LOOP(T, <)

static VALUE
rb_ca_count_below (VALUE self, VALUE vq, VALUE vinclusive)
{
  volatile VALUE vout;
  CArray *cr, *cq, *co;
  ca_size_t n, m, i;
  int64_t *out;
  int inclusive = RTEST(vinclusive);

  GetCArray(self, cr);
  rb_check_carray_object(vq);
  GetCArray(vq, cq);
  if ( cr->ndim != 1 ) {
    rb_raise(rb_eArgError, "__count_below__: the reference must be 1-D");
  }
  if ( cr->data_type != cq->data_type ) {
    rb_raise(rb_eCADataTypeError,
             "__count_below__: the reference and the query must have one data type");
  }
  switch ( cr->data_type ) {
  case CA_BOOLEAN: case CA_INT8: case CA_UINT8: case CA_INT16: case CA_UINT16:
  case CA_INT32: case CA_UINT32: case CA_INT64: case CA_UINT64:
  case CA_FLOAT32: case CA_FLOAT64:
    break;
  default:
    rb_raise(rb_eCADataTypeError, "__count_below__: no order for %s",
             ca_type_name[cr->data_type]);
  }

  n = cr->elements;
  m = cq->elements;
  vout = rb_carray_new(CA_INT64, cq->ndim, cq->dim, 0, NULL);
  GetCArray(vout, co);
  out = (int64_t *) co->ptr;

  ca_attach_n(2, cr, cq); /* window: nothing raises inside */
  switch ( cr->data_type ) {
  case CA_BOOLEAN:
  case CA_UINT8:   CA_COUNT_BELOW(uint8_t);  break;
  case CA_INT8:    CA_COUNT_BELOW(int8_t);   break;
  case CA_INT16:   CA_COUNT_BELOW(int16_t);  break;
  case CA_UINT16:  CA_COUNT_BELOW(uint16_t); break;
  case CA_INT32:   CA_COUNT_BELOW(int32_t);  break;
  case CA_UINT32:  CA_COUNT_BELOW(uint32_t); break;
  case CA_INT64:   CA_COUNT_BELOW(int64_t);  break;
  case CA_UINT64:  CA_COUNT_BELOW(uint64_t); break;
  case CA_FLOAT32: CA_COUNT_BELOW(float);    break;
  case CA_FLOAT64: CA_COUNT_BELOW(double);   break;
  }
  ca_detach_n(2, cr, cq);

  return vout;
}

#undef CA_COUNT_BELOW
#undef CA_COUNT_BELOW_LOOP

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
  volatile VALUE hlfval = 0, hufval = 0;
  CArray *ca, *ci, *co;
  char *lfval, *ufval;
  int self_is_face;

  {
    VALUE ropt = Qnil;
    /* project takes no keyword: one given was read as a fill value. */
    rb_scan_args(argc, argv, "12:", (VALUE *)&ridx, (VALUE *) &vlfval,
                 (VALUE *) &vufval, &ropt);
    rb_scan_options(ropt, "");
  }

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  self_is_face = ca_is_face(ca);

  rb_check_carray_object(ridx);
  ca_check_index_array(ridx);
  ci = ca_wrap_readonly(ridx, CA_SIZE);

  /* The fill args arrive as surface values.  rb_ca_obj2ptr owns the
     surface->storage conversion: for a Face self it fires the element_to_storage
     write hook (a datetime scalar / Time is reconciled to the Face's unit),
     for a plain array it writes the storage bytes directly. */
  lfval = ALLOCV_N(char, hlfval, ca->bytes);   /* converting a fill value */
  ufval = ALLOCV_N(char, hufval, ca->bytes);   /* can raise; the unwind frees */

  if ( ! NIL_P(vlfval) && vlfval != CA_UNDEF ) {
    rb_ca_obj2ptr(self, vlfval, lfval);
    rb_ca_obj2ptr(self, vlfval, ufval);
  }

  if ( ! NIL_P(vufval) && vufval != CA_UNDEF ) {
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

  /* A fill of UNDEF is no fill: the cell is masked, as it is with none. */
  {
    VALUE vlower = vlfval;
    VALUE vupper = NIL_P(vufval) ? vlfval : vufval;
    obj = ca_project(ca, ci,
                     ( NIL_P(vlower) || vlower == CA_UNDEF ) ? NULL : lfval,
                     ( NIL_P(vupper) || vupper == CA_UNDEF ) ? NULL : ufval);
  }
  GetCArray(obj, co);

  ALLOCV_END(hlfval);
  ALLOCV_END(hufval);

  if ( ! ca_is_any_masked(co) ) {
    obj = rb_ca_unmask_copy(obj);
  }

  if ( self_is_face ) {
    obj = ca_face_lift(obj, self);
  }

  rb_ca_inherit_attr(obj, self);
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
extern VALUE rb_ca_rank_index_ki_kind_dense (VALUE self, VALUE vaxis, int stable, int dense);

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

/* The key orders self's cells one for one, so it has self's shape. */
static void
ca_by_key_check_shape (VALUE self, VALUE rkey, const char *name)
{
  CArray *ca, *ck;
  int8_t i;
  rb_check_carray_object(rkey);
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  TypedData_Get_Struct(rkey, CArray, &carray_data_type, ck);
  if ( ca->ndim == ck->ndim ) {
    for (i = 0; i < ca->ndim; i++) {
      if ( ca->dim[i] != ck->dim[i] ) break;
    }
    if ( i == ca->ndim ) return;
  }
  rb_raise(rb_eArgError, "%s: the key's shape %"PRIsVALUE" differs from "
           "the array's %"PRIsVALUE, name,
           rb_funcall(rkey, rb_intern("shape"), 0),
           rb_funcall(self, rb_intern("shape"), 0));
}

/* self at the addresses an extremum by key found.  A fiber with no cell to
   compare has a masked (or UNDEF) address and answers UNDEF. */
static VALUE
ca_by_key_fetch (VALUE self, VALUE addrs)
{
  if ( addrs == CA_UNDEF ) {
    return CA_UNDEF;
  }
  if ( rb_obj_is_carray(addrs) && RTEST(rb_ca_has_mask(addrs)) ) {
    return rb_funcall(self, rb_intern("project"), 1, addrs);
  }
  return rb_ca_fetch(self, addrs);
}

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
  ca_by_key_check_shape(self, rkey, "sort_by_key");
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
  ca_by_key_check_shape(self, rkey, "max_by_key");
  if ( NIL_P(raxis) && RTEST(rb_ca_is_empty(self)) ) {
    return CA_UNDEF;
  }
  rkey = ca_order_key(rkey, "max_by_key");

  VALUE addrs;

  if ( NIL_P(raxis) ) {
    VALUE ki_argv[1] = { Qnil };   /* non-NULL for safety, unused at argc=0 */
    addrs = rb_ca_argmax_addr_ki(0, ki_argv, rkey);
  }
  else {
    VALUE kw = rb_hash_new();
    rb_hash_aset(kw, ID2SYM(id_axis), raxis);
    addrs = rb_funcallv_kw(rkey, rb_intern("max_addr"), 1, &kw, RB_PASS_KEYWORDS);
  }
  return ca_by_key_fetch(self, addrs);
}

/* min_by_key(key, axis: nil) -- self[key.min_addr(axis:)] (or UNDEF if empty). */
static VALUE
rb_ca_min_by_key (int argc, VALUE *argv, VALUE self)
{
  VALUE rkey, rkw = Qnil, raxis = Qnil;
  rb_scan_args(argc, argv, "1:", &rkey, &rkw);
  rb_scan_options(rkw, "axis", &raxis);
  ca_by_key_check_shape(self, rkey, "min_by_key");
  if ( NIL_P(raxis) && RTEST(rb_ca_is_empty(self)) ) {
    return CA_UNDEF;
  }
  rkey = ca_order_key(rkey, "min_by_key");

  VALUE addrs;

  if ( NIL_P(raxis) ) {
    VALUE ki_argv[1] = { Qnil };
    addrs = rb_ca_argmin_addr_ki(0, ki_argv, rkey);
  }
  else {
    VALUE kw = rb_hash_new();
    rb_hash_aset(kw, ID2SYM(id_axis), raxis);
    addrs = rb_funcallv_kw(rkey, rb_intern("min_addr"), 1, &kw, RB_PASS_KEYWORDS);
  }
  return ca_by_key_fetch(self, addrs);
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
  /* A masked index reads as UNDEF: project carries the mask of its
     addresses into the result. */
  if ( RTEST(rb_ca_has_mask(addrs)) ) {
    return rb_funcall(self, rb_intern("project"), 1, addrs);
  }
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
  /* A masked index writes nothing.  The values are first laid out over the
     indices by the store itself (an array of the indices' shape, so a
     broadcast, UNDEF or a Face value means what it means unmasked), and
     only the cells at unmasked indices are written. */
  if ( RTEST(rb_ca_has_mask(addrs)) ) {
    VALUE sel  = rb_funcall(addrs, rb_intern("is_not_masked"), 0);
    VALUE vals = rb_funcall(self, rb_intern("project"), 1, addrs);
    rb_funcall(vals, rb_intern("[]="), 1, argv[1]);
    rb_ca_store(self, rb_funcall(addrs, rb_intern("[]"), 1, sel),
                rb_funcall(vals, rb_intern("[]"), 1, sel));
    return self;
  }
  rb_ca_store(self, addrs, argv[1]);
  return self;
}

/* ---- range -- (min..max) via fused minmax ----------------------------- */

static VALUE
rb_ca_range_method (VALUE self)
{
  VALUE mm_argv[1] = { Qnil };
  CArray *ca;
  VALUE pair;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  /* A Face answers its own minmax (in its order, with its elements). */
  pair = ca_is_face(ca) ? rb_funcall(self, rb_intern("minmax"), 0)
                        : rb_ca_minmax_ki(0, mm_argv, self);
  VALUE lo = rb_ary_entry(pair, 0);
  VALUE hi = rb_ary_entry(pair, 1);
  return rb_range_new(lo, hi, 0);
}

/* ---- nlargest / nsmallest family ------------------------------------- */

/* The answer is the cells first in the order (value, then NaN, then
   masked; the values descending for the largest) with ties broken by
   position, as `order` breaks them.  Fewer cells than the fiber are found
   by the buffered walk below.  The other routes (the whole fiber, and the
   keys the walk does not read) sort or partition every cell, which picks
   the right values but, among cells that tie with the last one picked,
   any of them; ca_topk_stable replaces the tied candidates by the
   earliest cells that tie and sorts the candidates by (order, position). */

typedef struct {
  const char       *v;      /* the fiber's values, contiguous */
  const boolean8_t *m;      /* its mask, or NULL */
  int8_t            type;
  ca_size_t         bytes;
  int               desc;
} ca_topk_fiber_t;

/* 0 a value, 1 NaN, 2 masked: the classes come in that order. */
static int
ca_topk_class (const ca_topk_fiber_t *f, ca_size_t i)
{
  if ( f->m && f->m[i] ) return 2;
  if ( f->type == CA_FLOAT64 && isnan(((const double *) f->v)[i]) ) return 1;
  if ( f->type == CA_FLOAT32 && isnan(((const float *) f->v)[i]) ) return 1;
  return 0;
}

#define CA_TOPK_CMP(T)                                                  \
  { T a_ = ((const T *) f->v)[i], b_ = ((const T *) f->v)[j];         \
    r = (a_ < b_) ? -1 : (a_ > b_) ? 1 : 0; }                          \
  break

/* The order of cells i and j, ties not broken. */
static int
ca_topk_cmp (const ca_topk_fiber_t *f, ca_size_t i, ca_size_t j)
{
  int ci = ca_topk_class(f, i), cj = ca_topk_class(f, j), r = 0;
  if ( ci != cj ) return ( ci < cj ) ? -1 : 1;
  if ( ci != 0 ) return 0;
  switch ( f->type ) {
  case CA_BOOLEAN:
  case CA_UINT8:   CA_TOPK_CMP(uint8_t);
  case CA_INT8:    CA_TOPK_CMP(int8_t);
  case CA_INT16:   CA_TOPK_CMP(int16_t);
  case CA_UINT16:  CA_TOPK_CMP(uint16_t);
  case CA_INT32:   CA_TOPK_CMP(int32_t);
  case CA_UINT32:  CA_TOPK_CMP(uint32_t);
  case CA_INT64:   CA_TOPK_CMP(int64_t);
  case CA_UINT64:  CA_TOPK_CMP(uint64_t);
  case CA_FLOAT32: CA_TOPK_CMP(float);
  case CA_FLOAT64: CA_TOPK_CMP(double);
  case CA_FIXLEN:
    r = memcmp(f->v + i * f->bytes, f->v + j * f->bytes, (size_t) f->bytes);
    r = ( r > 0 ) - ( r < 0 );
    break;
  default:
    r = 0;
  }
  return f->desc ? -r : r;
}

#undef CA_TOPK_CMP

/* Merge sort of positions by (order, position). */
static void
ca_topk_sort (const ca_topk_fiber_t *f, ca_size_t *p, ca_size_t *tmp, ca_size_t n)
{
  ca_size_t h, i, j, k;
  if ( n < 2 ) return;
  h = n / 2;
  ca_topk_sort(f, p, tmp, h);
  ca_topk_sort(f, p + h, tmp, n - h);
  i = 0; j = h; k = 0;
  while ( i < h && j < n ) {
    int r = ca_topk_cmp(f, p[i], p[j]);
    if ( r < 0 || ( r == 0 && p[i] < p[j] ) ) tmp[k++] = p[i++];
    else                                      tmp[k++] = p[j++];
  }
  while ( i < h ) tmp[k++] = p[i++];
  while ( j < n ) tmp[k++] = p[j++];
  memcpy(p, tmp, (size_t) n * sizeof(ca_size_t));
}

#define CA_TOPK_SCAN_VALUE(T)                                               \
  { const T *v_ = (const T *) f->v; T w_ = v_[worst];                       \
    for (j = 0; j <= end && ties > 0; j++) {                                \
      if ( v_[j] == w_ && ! ( f->m && f->m[j] ) ) { c[n++] = j; ties--; }   \
    } }                                                                      \
  break

/* The earliest cells, up to `end`, that tie with cell `worst`, appended to
   c[n..] until `ties` are found.  A value compares by ==, which leaves out
   NaN and the masked cells; those classes tie within themselves. */
static ca_size_t
ca_topk_scan_ties (const ca_topk_fiber_t *f, ca_size_t worst, ca_size_t end,
                   ca_size_t *c, ca_size_t n, ca_size_t ties)
{
  ca_size_t j;
  int cls = ca_topk_class(f, worst);
  if ( cls != 0 || f->type == CA_FIXLEN ) {
    for (j = 0; j <= end && ties > 0; j++) {
      if ( ca_topk_cmp(f, j, worst) == 0 ) { c[n++] = j; ties--; }
    }
    return n;
  }
  switch ( f->type ) {
  case CA_BOOLEAN:
  case CA_UINT8:   CA_TOPK_SCAN_VALUE(uint8_t);
  case CA_INT8:    CA_TOPK_SCAN_VALUE(int8_t);
  case CA_INT16:   CA_TOPK_SCAN_VALUE(int16_t);
  case CA_UINT16:  CA_TOPK_SCAN_VALUE(uint16_t);
  case CA_INT32:   CA_TOPK_SCAN_VALUE(int32_t);
  case CA_UINT32:  CA_TOPK_SCAN_VALUE(uint32_t);
  case CA_INT64:   CA_TOPK_SCAN_VALUE(int64_t);
  case CA_UINT64:  CA_TOPK_SCAN_VALUE(uint64_t);
  case CA_FLOAT32: CA_TOPK_SCAN_VALUE(float);
  case CA_FLOAT64: CA_TOPK_SCAN_VALUE(double);
  }
  return n;
}

#undef CA_TOPK_SCAN_VALUE

static void
ca_topk_fix_fiber (const ca_topk_fiber_t *f, ca_size_t len,
                   ca_size_t *c, ca_size_t cap, ca_size_t *tmp)
{
  ca_size_t worst = c[0], ties = 0, n = 0, end = 0, k;
  for (k = 1; k < cap; k++) {
    if ( ca_topk_cmp(f, c[k], worst) > 0 ) worst = c[k];
  }
  /* Keep the candidates before the worst; the ones tied with it are
     replaced by the earliest cells that tie, which lie no later than the
     last tied candidate. */
  for (k = 0; k < cap; k++) {
    if ( ca_topk_cmp(f, c[k], worst) < 0 ) {
      c[n++] = c[k];
    }
    else {
      ties++;
      if ( c[k] > end ) end = c[k];
    }
  }
  (void) len;
  n = ca_topk_scan_ties(f, worst, end, c, n, ties);
  ca_topk_sort(f, c, tmp, cap);
}

/* `picked` holds cap candidate positions per fiber along axis; returns the
   stable answer of the same shape.  The fibers are read with the axis
   moved last, from a contiguous copy. */
static VALUE
ca_topk_stable (VALUE self, VALUE picked, long axis, int desc)
{
  volatile VALUE key = ca_order_key(self, desc ? "nlargest" : "nsmallest");
  volatile VALUE vals, pk, holder = 0;
  VALUE perm[CA_RANK_MAX], inv[CA_RANK_MAX];
  CArray *cv, *cp;
  ca_topk_fiber_t f;
  ca_size_t len, cap, outer, o, *tmp;
  int ndim, k, last;

  GetCArray(key, cv);
  ndim = cv->ndim;
  last = ( axis == ndim - 1 );
  if ( ! last ) {
    int n = 0;
    for (k = 0; k < ndim; k++) if ( k != axis ) perm[n++] = INT2FIX(k);
    perm[n] = LONG2NUM(axis);
    for (k = 0; k < ndim; k++) inv[NUM2INT(perm[k])] = INT2FIX(k);
  }
  /* An entity whose fibers already lie along its last axis is read in
     place; anything else is copied into that layout. */
  if ( last && ca_is_entity(cv) ) {
    vals = key;
    ca_update_mask(cv);
  }
  else {
    vals = rb_ca_copy(last ? key : rb_funcallv(key, rb_intern("transpose"), ndim, perm));
  }
  pk   = rb_ca_copy(last ? picked : rb_funcallv(picked, rb_intern("transpose"), ndim, perm));
  GetCArray(vals, cv);
  GetCArray(pk, cp);

  len   = cv->dim[ndim - 1];
  cap   = cp->dim[ndim - 1];
  if ( len == 0 || cap == 0 ) return picked;
  outer = cv->elements / len;
  f.type  = cv->data_type;
  f.bytes = cv->bytes;
  f.desc  = desc;
  tmp = ALLOCV_N(ca_size_t, holder, cap);
  for (o = 0; o < outer; o++) {
    f.v = cv->ptr + o * len * cv->bytes;
    f.m = cv->mask ? (boolean8_t *) cv->mask->ptr + o * len : NULL;
    ca_topk_fix_fiber(&f, len, (ca_size_t *) cp->ptr + o * cap, cap, tmp);
  }
  ALLOCV_END(holder);
  return last ? pk : rb_ca_copy(rb_funcallv(pk, rb_intern("transpose"), ndim, inv));
}

/* Whether self holds a cell the order puts after the numbers: a masked
   cell, or a NaN. */
static int
ca_topk_has_cells_after_numbers (VALUE self, CArray *ca)
{
  if ( ca_has_mask(ca) && ca_count_masked(ca) > 0 ) {
    return 1;
  }
  if ( ca_is_float_type(ca) ) {
    VALUE nan = rb_funcall(self, rb_intern("is_nan"), 0);
    return RTEST(rb_funcall(nan, rb_intern("any"), 0));
  }
  return 0;
}

/* ---- the buffered walk ------------------------------------------------
   Each fiber is read once.  The cells that come before the cut (the last
   of the cap cells kept so far, in (order, position)) are collected in a
   buffer of a few times cap; when it fills, a selection keeps the first
   cap and the cut moves up.  The work area is the buffer, whatever the
   length of the fiber, and a fiber in order costs one selection per
   bufferful instead of a heap update per cell.

   The walk is written once as a macro over three others: CLASS(i) (0 a
   value, 1 NaN, 2 masked), AFTER(i, j) (cell i comes after cell j in
   (order, position)) and ENTERS(j) (cell j comes before the cut), and
   instantiated per type so that the comparisons
   are inline.  The fixlen type takes the generic comparison. */

/* Rearranges b[0..nb) so that b[0..cap) hold the cap cells first in
   (order, position): quickselect with median-of-three pivots; past a
   depth limit the remaining range is sorted (tmp holds nb positions). */
#define CA_TOPK_SELECT(AFTER)                                                 \
  do {                                                                        \
    lo = 0; hi = nb;                                                        \
    depth = 2;                                                              \
    for (s = nb; s > 1; s >>= 1) depth += 2;                                \
    while ( hi - lo > 16 ) {                                                \
      mid = lo + ( hi - lo ) / 2; last = hi - 1;                            \
      if ( depth-- == 0 ) break;                                            \
      if ( AFTER(b[lo], b[mid]) )   { t = b[lo]; b[lo] = b[mid]; b[mid] = t; }     \
      if ( AFTER(b[mid], b[last]) ) { t = b[mid]; b[mid] = b[last]; b[last] = t; } \
      if ( AFTER(b[lo], b[mid]) )   { t = b[lo]; b[lo] = b[mid]; b[mid] = t; }     \
      t = b[mid]; b[mid] = b[last]; b[last] = t;                            \
      for (s = lo, i = lo; i < last; i++) {                                 \
        if ( AFTER(b[last], b[i]) ) { t = b[s]; b[s] = b[i]; b[i] = t; s++; } \
      }                                                                     \
      t = b[s]; b[s] = b[last]; b[last] = t;                                \
      if ( s == cap || s + 1 == cap ) { lo = hi; break; }                   \
      if ( cap < s ) hi = s;                                                \
      else           lo = s + 1;                                            \
    }                                                                       \
    if ( hi > lo ) ca_topk_sort(f, b + lo, tmp, hi - lo);                   \
  } while (0)

#define CA_TOPK_DEFINE_BUF(NAME, T, CLASS, AFTER, ENTERS)                    \
static void                                                                   \
NAME (const ca_topk_fiber_t *f, ca_size_t len, ca_size_t cap,                 \
      ca_size_t *b, ca_size_t *tmp, ca_size_t size)                           \
{                                                                             \
  const T *v_ = (const T *) f->v;                                             \
  ca_size_t j, nb = 0, cut = 0, lo, hi, i, s, t, mid, last;                   \
  int rc_ = 3, depth;                                                         \
  T rv_;                                                                      \
  (void) v_;                                                                  \
  memset(&rv_, 0, sizeof(rv_));                                               \
  for (j = 0; j < len; j++) {                                                 \
    if ( rc_ != 3 && ! ( ENTERS(j) ) ) continue;                              \
    b[nb++] = j;                                                              \
    if ( nb == size ) {                                                       \
      CA_TOPK_SELECT(AFTER);                                                  \
      nb = cap;                                                               \
    }                                                                         \
    else if ( ! ( nb == cap && rc_ == 3 ) ) {    /* the first cap cells */    \
      continue;                                                               \
    }                                                                         \
    cut = b[0];                                                               \
    for (i = 1; i < cap; i++) if ( AFTER(b[i], cut) ) cut = b[i];             \
    rc_ = CLASS(cut);                                                         \
    if ( rc_ == 0 ) memcpy(&rv_, f->v + cut * f->bytes, sizeof(rv_));         \
  }                                                                           \
  if ( nb > cap ) CA_TOPK_SELECT(AFTER);                                      \
  ca_topk_sort(f, b, tmp, cap);                                               \
}

/* The typed comparisons.  A cell enters when it comes before the cut;
   one that ties the cut does not, it lies later. */
#define CA_TOPK_CLASS_INT(i)   ( ( f->m && f->m[i] ) ? 2 : 0 )
#define CA_TOPK_CLASS_FLT(i)   ( ( f->m && f->m[i] ) ? 2 : ( isnan(v_[i]) ? 1 : 0 ) )
#define CA_TOPK_AFTER_V(CLASS, i, j)                                          \
  ( CLASS(i) != CLASS(j) ? CLASS(i) > CLASS(j)                                \
  : ( CLASS(i) == 0 && v_[i] != v_[j] )                                       \
      ? ( f->desc ? v_[i] < v_[j] : v_[i] > v_[j] )                           \
      : (i) > (j) )
#define CA_TOPK_AFTER_INT(i, j) CA_TOPK_AFTER_V(CA_TOPK_CLASS_INT, i, j)
#define CA_TOPK_AFTER_FLT(i, j) CA_TOPK_AFTER_V(CA_TOPK_CLASS_FLT, i, j)
#define CA_TOPK_ENTERS_V(CLASS, j)                                            \
  ( CLASS(j) < rc_ ||                                                         \
    ( CLASS(j) == 0 && rc_ == 0 &&                                            \
      ( f->desc ? v_[j] > rv_ : v_[j] < rv_ ) ) )
#define CA_TOPK_ENTERS_INT(j) CA_TOPK_ENTERS_V(CA_TOPK_CLASS_INT, j)
#define CA_TOPK_ENTERS_FLT(j) CA_TOPK_ENTERS_V(CA_TOPK_CLASS_FLT, j)

CA_TOPK_DEFINE_BUF(ca_topk_buf_u8,  uint8_t,  CA_TOPK_CLASS_INT, CA_TOPK_AFTER_INT, CA_TOPK_ENTERS_INT)
CA_TOPK_DEFINE_BUF(ca_topk_buf_i8,  int8_t,   CA_TOPK_CLASS_INT, CA_TOPK_AFTER_INT, CA_TOPK_ENTERS_INT)
CA_TOPK_DEFINE_BUF(ca_topk_buf_i16, int16_t,  CA_TOPK_CLASS_INT, CA_TOPK_AFTER_INT, CA_TOPK_ENTERS_INT)
CA_TOPK_DEFINE_BUF(ca_topk_buf_u16, uint16_t, CA_TOPK_CLASS_INT, CA_TOPK_AFTER_INT, CA_TOPK_ENTERS_INT)
CA_TOPK_DEFINE_BUF(ca_topk_buf_i32, int32_t,  CA_TOPK_CLASS_INT, CA_TOPK_AFTER_INT, CA_TOPK_ENTERS_INT)
CA_TOPK_DEFINE_BUF(ca_topk_buf_u32, uint32_t, CA_TOPK_CLASS_INT, CA_TOPK_AFTER_INT, CA_TOPK_ENTERS_INT)
CA_TOPK_DEFINE_BUF(ca_topk_buf_i64, int64_t,  CA_TOPK_CLASS_INT, CA_TOPK_AFTER_INT, CA_TOPK_ENTERS_INT)
CA_TOPK_DEFINE_BUF(ca_topk_buf_u64, uint64_t, CA_TOPK_CLASS_INT, CA_TOPK_AFTER_INT, CA_TOPK_ENTERS_INT)
CA_TOPK_DEFINE_BUF(ca_topk_buf_f32, float,    CA_TOPK_CLASS_FLT, CA_TOPK_AFTER_FLT, CA_TOPK_ENTERS_FLT)
CA_TOPK_DEFINE_BUF(ca_topk_buf_f64, double,   CA_TOPK_CLASS_FLT, CA_TOPK_AFTER_FLT, CA_TOPK_ENTERS_FLT)

/* fixlen: the generic comparison; v_ is unused. */
#define CA_TOPK_CLASS_GEN(i)    ca_topk_class(f, i)
#define CA_TOPK_AFTER_GEN(i, j) ca_topk_after(f, i, j)
#define CA_TOPK_ENTERS_GEN(j)   ( ca_topk_cmp(f, j, cut) < 0 )

/* Whether cell i comes after cell j in (order, position). */
static int
ca_topk_after (const ca_topk_fiber_t *f, ca_size_t i, ca_size_t j)
{
  int r = ca_topk_cmp(f, i, j);
  return r > 0 || ( r == 0 && i > j );
}

CA_TOPK_DEFINE_BUF(ca_topk_buf_gen, char, CA_TOPK_CLASS_GEN, CA_TOPK_AFTER_GEN, CA_TOPK_ENTERS_GEN)

#undef CA_TOPK_DEFINE_BUF
#undef CA_TOPK_SELECT
#undef CA_TOPK_CLASS_INT
#undef CA_TOPK_CLASS_FLT
#undef CA_TOPK_AFTER_V
#undef CA_TOPK_AFTER_INT
#undef CA_TOPK_AFTER_FLT
#undef CA_TOPK_ENTERS_V
#undef CA_TOPK_ENTERS_INT
#undef CA_TOPK_ENTERS_FLT
#undef CA_TOPK_CLASS_GEN
#undef CA_TOPK_AFTER_GEN
#undef CA_TOPK_ENTERS_GEN

/* The first cap cells of one fiber in (order, position), sorted, into
   b[0..cap).  b and tmp hold size positions, cap < size <= len. */
static void
ca_topk_buf_fiber (const ca_topk_fiber_t *f, ca_size_t len, ca_size_t cap,
                   ca_size_t *b, ca_size_t *tmp, ca_size_t size)
{
  switch ( f->type ) {
  case CA_BOOLEAN:
  case CA_UINT8:   ca_topk_buf_u8(f, len, cap, b, tmp, size);  break;
  case CA_INT8:    ca_topk_buf_i8(f, len, cap, b, tmp, size);  break;
  case CA_INT16:   ca_topk_buf_i16(f, len, cap, b, tmp, size); break;
  case CA_UINT16:  ca_topk_buf_u16(f, len, cap, b, tmp, size); break;
  case CA_INT32:   ca_topk_buf_i32(f, len, cap, b, tmp, size); break;
  case CA_UINT32:  ca_topk_buf_u32(f, len, cap, b, tmp, size); break;
  case CA_INT64:   ca_topk_buf_i64(f, len, cap, b, tmp, size); break;
  case CA_UINT64:  ca_topk_buf_u64(f, len, cap, b, tmp, size); break;
  case CA_FLOAT32: ca_topk_buf_f32(f, len, cap, b, tmp, size); break;
  case CA_FLOAT64: ca_topk_buf_f64(f, len, cap, b, tmp, size); break;
  default:         ca_topk_buf_gen(f, len, cap, b, tmp, size); break;
  }
}

/* Per-axis top-k positions of `key` (an order key: not object, not
   complex) by the buffered walk, for cap < the length of the axis.  The
   fibers come in the row-major order of the other axes, so the answer is
   filled with the axis last and moved into place at the end (cap cells
   per fiber). */
static VALUE
ca_topk_buffered_positions (VALUE key, long cap, long axis, int desc)
{
  volatile VALUE holder = 0, out;
  VALUE perm[CA_RANK_MAX];
  ca_size_t odim[CA_RANK_MAX];
  CArray *ck, *co;
  ca_iter_state st;
  ca_topk_fiber_t f;
  ca_size_t *buf, *tmp, n, o = 0, k, len, size;
  int64_t *op;
  boolean8_t *m;
  char *p;
  int ndim, i, j = 0;

  GetCArray(key, ck);
  ndim = ck->ndim;
  for (i = 0; i < ndim; i++) if ( i != axis ) odim[j++] = ck->dim[i];
  odim[ndim - 1] = cap;
  len = ck->dim[axis];
  out = rb_carray_new(CA_INT64, ndim, odim, 0, NULL);
  GetCArray(out, co);
  op = (int64_t *) co->ptr;

  f.type  = ck->data_type;
  f.bytes = ck->bytes;
  f.desc  = desc;
  size = ( len < 4 * cap + 256 ) ? len : 4 * cap + 256;
  buf = ALLOCV_N(ca_size_t, holder, 2 * size);
  tmp = buf + size;
  CA_FOR_EACH_FIBER_MASKED(st, ck, axis, 0, p, n, m) {
    f.v = p;
    f.m = m;
    ca_topk_buf_fiber(&f, n, cap, buf, tmp, size);
    for (k = 0; k < cap; k++) op[o * cap + k] = (int64_t) buf[k];
    o++;
  }
  ALLOCV_END(holder);
  if ( axis == ndim - 1 ) return out;
  for (i = 0; i < ndim; i++) {
    perm[i] = INT2FIX( i < axis ? i : ( i == axis ? ndim - 1 : i - 1 ) );
  }
  return rb_ca_copy(rb_funcallv(out, rb_intern("transpose"), ndim, perm));
}

/* Per-axis top-k positions (cap clamped, axis normalized).
 * Called by rb_ca_topk_index below. */
static VALUE
rb_ca_topk_positions (VALUE self, long cap, long axis_norm, int desc)
{
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  long dim_axis = (long) ca->dim[axis_norm];
  VALUE raxis_norm = LONG2NUM(axis_norm);

  /* The buffered walk reads any key but an object (its cells compare in
     Ruby) or a complex one (no order), and keeps cap cells per fiber. */
  if ( ca->data_type != CA_OBJECT && ! ca_is_complex_type(ca) ) {
    VALUE key = ca_order_key(self, desc ? "nlargest" : "nsmallest");
    CArray *ck;
    GetCArray(key, ck);
    if ( ck->data_type != CA_OBJECT && ! ca_is_complex_type(ck) &&
         cap < dim_axis ) {
      return ca_topk_buffered_positions(key, cap, axis_norm, desc);
    }
  }

  /* The largest: reversing the ascending order would put the NaN and the
     masked cells first, so rank them descending (NaN, then the masked
     cells, last) when there are any.  An object array is ranked by
     `order` both ways (its cells compare in Ruby). */
  if ( ca->data_type == CA_OBJECT ||
       ( desc && ca_topk_has_cells_after_numbers(self, ca) ) ) {
    VALUE kw = rb_hash_new();
    rb_hash_aset(kw, ID2SYM(rb_intern("axis")), raxis_norm);
    rb_hash_aset(kw, ID2SYM(rb_intern("descending")), desc ? Qtrue : Qfalse);
    VALUE rank = rb_funcallv_kw(self, rb_intern("order"), 1, &kw, RB_PASS_KEYWORDS);
    VALUE full = rb_ca_sort_index_ki_quick(rank, raxis_norm);
    if ( cap >= dim_axis ) {
      return rb_ca_copy(full);
    }
    int ndim = (int) ca->ndim;
    VALUE spec[CA_RANK_MAX];
    for ( int k = 0; k < ndim; k++ ) {
      spec[k] = Qnil;
    }
    spec[axis_norm] = rb_range_new(INT2FIX(0), LONG2NUM(cap), 1);
    return rb_ca_copy(rb_ca_fetch2(full, ndim, spec));
  }

  if ( cap >= dim_axis ) {
    VALUE full = rb_ca_sort_index_ki_quick(self, raxis_norm);
    return ca_topk_stable(self, full, axis_norm, desc);
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
  return ca_topk_stable(self, picked, axis_norm, desc);
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
  long n_val = ca_integer_arg(rn, "n", name);
  long dim_a = (long) ca->dim[a];
  /* As Array#max(n): a negative count is an error, one past the length
     gives the whole fiber. */
  if ( n_val < 0 ) {
    rb_raise(rb_eArgError, "%s: n must be non-negative (got %ld)", name, n_val);
  }
  long cap = (n_val < dim_a) ? n_val : dim_a;
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
 * descending: ranks the largest value 0, with NaN after the numbers as
 * ascending.  The kernel gives the descending dense rank; the ordinal rank
 * is the ascending ordinal rank of it, so tied cells keep their original
 * order in both directions. */

static VALUE
rb_ca_order (int argc, VALUE *argv, VALUE self)
{
  VALUE ropt = rb_pop_options(&argc, &argv);
  VALUE raxis = Qnil, rdesc = Qfalse, rmethod = Qnil, rkind = Qnil;
  rb_scan_options(ropt, "axis,descending,method,kind", &raxis, &rdesc, &rmethod, &rkind);
  rb_check_arity(argc, 0, 0);

  int dense = NIL_P(rmethod) ? 0
    : ca_symbol_choice(rmethod, "method", "ordinal", "dense", NULL);
  int do_stable = NIL_P(rkind) ? 0
  : ca_symbol_choice(rkind, "kind", "quick", "stable", NULL);

  if ( RTEST(rdesc) && ! dense ) {
    VALUE kw = rb_hash_new();
    rb_hash_aset(kw, ID2SYM(rb_intern("axis")), raxis);
    rb_hash_aset(kw, ID2SYM(rb_intern("descending")), Qtrue);
    rb_hash_aset(kw, ID2SYM(rb_intern("method")), ID2SYM(rb_intern("dense")));
    rb_hash_aset(kw, ID2SYM(rb_intern("kind")), do_stable ? ID2SYM(rb_intern("stable")) : ID2SYM(rb_intern("quick")));
    VALUE ranked = rb_funcallv_kw(self, rb_intern("order"), 1, &kw, RB_PASS_KEYWORDS);
    rb_hash_delete(kw, ID2SYM(rb_intern("descending")));
    rb_hash_delete(kw, ID2SYM(rb_intern("method")));
    return rb_funcallv_kw(ranked, rb_intern("order"), 1, &kw, RB_PASS_KEYWORDS);
  }

  /* The kernel's dense == 2 is the descending dense rank. */
  int kmode = ( dense && RTEST(rdesc) ) ? 2 : dense;
  if ( NIL_P(raxis) ) {
    VALUE flat = rb_ca_flatten(self);
    /* Direct C-level dispatch via c_callable: true extern (mkkernel). */
    VALUE ranked = rb_ca_rank_index_ki_kind_dense(flat, INT2FIX(0), do_stable, kmode);
    /* reshape(*shape) */
    CArray *ca;
    TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
    VALUE shape_argv[CA_RANK_MAX];
    for ( long k = 0; k < (long) ca->ndim; k++ ) {
      shape_argv[k] = LONG2NUM((long) ca->dim[k]);
    }
    return rb_ca_reshape((int) ca->ndim, shape_argv, ranked);
  }
  long axis_norm = rb_ca_normalize_axis_value(self, raxis, "order");
  /* Output data_type: CA_SIZE (int64 on 64-bit builds), as the rest of the
     *_index family. */
  return rb_ca_rank_index_ki_kind_dense(self, LONG2NUM(axis_norm), do_stable, kmode);
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
    ca_face_require_orderable(self, name, "order");
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

  /* Query gate: the reference axis, still a Face here, and the query are
     brought into one space (ca_face_reconcile_pair). */
  if ( rb_obj_is_carray(self) ) {
    CArray *sca;
    TypedData_Get_Struct(self, CArray, &carray_data_type, sca);
    if ( ca_is_face(sca) ) {
      volatile VALUE ref = self, query = val;
      ca_face_reconcile_pair(&ref, &query, "linear_section");
      self = ref;
      val  = query;
    }
  }

  {
    CArray *ca;
    TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
    if ( ca_is_complex_type(ca) ) {
      rb_raise(rb_eCADataTypeError,
               "linear_section: a %s array has no order (complex numbers are "
               "not ordered)", ca_type_name[ca->data_type]);
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

  /* A complex array interpolates its real and imaginary parts: the
     weights are real, so each part is a real interpolation. */
  {
    CArray *ca;
    TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
    if ( ca_is_complex_type(ca) ) {
      VALUE args[2], re, im;
      int n = 1;
      args[0] = addr;
      if ( ! NIL_P(ropt) ) args[n++] = ropt;
      re = rb_funcallv_kw(rb_funcall(self, rb_intern("real"), 0),
                          rb_intern("linear_fetch"), n, args,
                          NIL_P(ropt) ? RB_NO_KEYWORDS : RB_PASS_KEYWORDS);
      im = rb_funcallv_kw(rb_funcall(self, rb_intern("imag"), 0),
                          rb_intern("linear_fetch"), n, args,
                          NIL_P(ropt) ? RB_NO_KEYWORDS : RB_PASS_KEYWORDS);
      return rb_funcall(re, '+', 1,
                        rb_funcall(im, '*', 1, rb_Complex(INT2FIX(0), INT2FIX(1))));
    }
  }

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
  rb_define_private_method(rb_cCArray, "__count_below__", rb_ca_count_below, 2);

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
