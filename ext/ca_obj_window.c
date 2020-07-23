/* ---------------------------------------------------------------------------

  ca_obj_window.c

  This file is part of Ruby/CArray extension library.

  Copyright (C) 2005-2020 Hiroki Motoyoshi

---------------------------------------------------------------------------- */

#include "carray.h"

/* should not be static variable as used by CAIteratorWindow */

VALUE rb_cCAWindow; 
int8_t CA_OBJ_WINDOW;

/* yard:
  class CAWindow < CAVirtual # :nodoc:
  end
*/


/* ------------------------------------------------------------------- */

int
ca_window_setup (CAWindow *ca, CArray *parent,
               ca_size_t *start, ca_size_t *count, int8_t bounds, char *fill)
{
  int8_t  data_type, ndim;
  ca_size_t *dim;
  ca_size_t bytes, elements;
  int i;

  data_type = parent->data_type;
  ndim      = parent->ndim;
  bytes     = parent->bytes;
  dim       = parent->dim;

  elements = 1;
  for (i=0; i<ndim; i++) {
    if ( count[i] <= 0 ) {
      rb_raise(rb_eIndexError,
               "invalid size for %i-th dimension (negative or zero)", i);
    }
    elements *= count[i];
  }

  ca->obj_type  = CA_OBJ_WINDOW;
  ca->data_type = data_type;
  ca->flags     = 0;
  ca->ndim      = ndim;
  ca->bytes     = bytes;
  ca->elements  = elements;
  ca->ptr       = NULL;
  ca->mask      = NULL;
  /* ca->dim will set as ca->count below */

  ca->parent    = parent;
  ca->attach    = 0;
  ca->nosync    = 0;
  ca->bounds    = bounds;
  ca->start     = ALLOC_N(ca_size_t, ndim);
  ca->count     = ALLOC_N(ca_size_t, ndim);
  ca->size0     = ALLOC_N(ca_size_t, ndim);
  ca->fill      = ALLOC_N(char, ca->bytes);

  ca->dim = ca->count;

  memcpy(ca->start, start, ndim * sizeof(ca_size_t));
  memcpy(ca->count, count, ndim * sizeof(ca_size_t));
  memcpy(ca->size0,  dim,  ndim * sizeof(ca_size_t));

  if ( fill ) {
    memcpy(ca->fill, fill, ca->bytes);
  }
  else {
    if ( ca_is_object_type(ca) ) {
      *(VALUE *)ca->fill = INT2NUM(0);
    }
    else {
      memset(ca->fill, 0, ca->bytes);
    }
  }

  if ( ca->bounds == CA_BOUNDS_MASK ) {
    ca_create_mask(ca);
  }

  return 0;
}

CAWindow *
ca_window_new (CArray *parent,
               ca_size_t *start, ca_size_t *count, int8_t bounds, char *fill)
{
  CAWindow *ca = ALLOC(CAWindow);
  ca_window_setup(ca, parent, start, count, bounds, fill);
  return ca;
}

static void
free_ca_window (void *ap)
{
  CAWindow *ca = (CAWindow *) ap;
  if ( ca != NULL ) {
    ca_free(ca->mask);
    xfree(ca->fill);
    xfree(ca->start);
    xfree(ca->count);
    xfree(ca->size0);
    /* xfree(ca->dim); */
    xfree(ca);
  }
}

static void ca_window_attach (CAWindow *ca);
static void ca_window_sync (CAWindow *ca);
static void ca_window_fill (CAWindow *ca, char *ptr);

/* ------------------------------------------------------------------- */

static void *
ca_window_func_clone (void *ap)
{
  CAWindow *ca = (CAWindow *) ap;
  return ca_window_new(ca->parent, ca->start, ca->count, ca->bounds, ca->fill);
}

static char *
ca_window_func_ptr_at_index (void *ap, ca_size_t *idx) ;

static char *
ca_window_func_ptr_at_addr (void *ap, ca_size_t addr)
{
  CAWindow *ca = (CAWindow *) ap;
  if ( ca->ptr ) {
    return ca->ptr + ca->bytes * addr;
  }
  else {
    ca_size_t idx[CA_RANK_MAX];
    ca_addr2index((CArray *)ca, addr, idx);
    return ca_window_func_ptr_at_index(ca, idx);
  }
}

static char *
ca_window_func_ptr_at_index (void *ap, ca_size_t *idx)
{
  ca_size_t k;
  CAWindow *ca = (CAWindow *) ap;
  if ( ! ca->ptr ) {
    ca_size_t *start = ca->start;
    ca_size_t *size0 = ca->size0;
    int8_t  i;
    ca_size_t n;
    n = 0;
    for (i=0; i<ca->ndim; i++) {
      k = start[i] + idx[i];
      k = ca_bounds_normalize_index(ca->bounds, size0[i], k);
      if ( k < 0 || k >= size0[i] ) {
        return ca->fill;
      }
      n = size0[i] * n + k;
    }

    if ( ! ca->parent->ptr ) {
      return ca_ptr_at_addr(ca->parent, n);
    }
    else {
      return ca->parent->ptr + ca->bytes * n;
    }
  }
  else {
    return ca_func[CA_OBJ_ARRAY].ptr_at_index(ca, idx);
  }
}

static void
ca_window_func_fetch_index (void *ap, ca_size_t *idx, void *ptr)
{
  CAWindow *ca = (CAWindow *) ap;
  ca_size_t *start = ca->start;
  ca_size_t *size0 = ca->size0;
  ca_size_t idx0[CA_RANK_MAX];
  int8_t  i;
  ca_size_t k;
  for (i=0; i<ca->ndim; i++) {
    k = start[i] + idx[i];
    k = ca_bounds_normalize_index(ca->bounds, size0[i], k);
    if ( k < 0 || k >= size0[i] ) {
      memcpy(ptr, ca->fill, ca->bytes);
      return;
    }
    idx0[i] = k;
  }
  ca_fetch_index(ca->parent, idx0, ptr);
}

static void
ca_window_func_store_index (void *ap, ca_size_t *idx, void *ptr)
{
  CAWindow *ca = (CAWindow *) ap;
  ca_size_t *start = ca->start;
  ca_size_t *size0 = ca->size0;
  ca_size_t idx0[CA_RANK_MAX];
  int8_t  i;
  ca_size_t k;
  for (i=0; i<ca->ndim; i++) {
    k = start[i] + idx[i];
    k = ca_bounds_normalize_index(ca->bounds, size0[i], k);
    if ( k < 0 || k >= size0[i] ) {
      return;
    }
    idx0[i] = k;
  }
  ca_store_index(ca->parent, idx0, ptr);
}

static void
ca_window_func_allocate (void *ap)
{
  CAWindow *ca = (CAWindow *) ap;
  ca_attach(ca->parent);
  /* ca->ptr = ALLOC_N(char, ca_length(ca)); */
  ca->ptr = malloc_with_check(ca_length(ca));  
}

static void
ca_window_func_attach (void *ap)
{
  void ca_window_attach (CAWindow *cb);

  CAWindow *ca = (CAWindow *) ap;
  ca_attach(ca->parent);
  /* ca->ptr = ALLOC_N(char, ca_length(ca)); */
  ca->ptr = malloc_with_check(ca_length(ca));  
  ca_window_attach(ca);
}

static void
ca_window_func_sync (void *ap)
{
  CAWindow *ca = (CAWindow *) ap;
  ca_window_sync(ca);
  ca_sync(ca->parent);
}

static void
ca_window_func_detach (void *ap)
{
  CAWindow *ca = (CAWindow *) ap;
  free(ca->ptr);
  ca->ptr = NULL;
  ca_detach(ca->parent);
}

static void
ca_window_func_copy_data (void *ap, void *ptr)
{
  CAWindow *ca = (CAWindow *) ap;
  char *ptr0 = ca->ptr;
  ca_attach(ca->parent);
  ca->ptr = ptr;
  ca_window_attach(ca);
  ca->ptr = ptr0;
  ca_detach(ca->parent);
}

static void
ca_window_func_sync_data (void *ap, void *ptr)
{
  CAWindow *ca = (CAWindow *) ap;
  char *ptr0 = ca->ptr;
  ca_attach(ca->parent);
  ca->ptr = ptr;
  ca_window_sync(ca);
  ca->ptr = ptr0;
  ca_sync(ca->parent);
  ca_detach(ca->parent);
}

static void
ca_window_func_fill_data (void *ap, void *ptr)
{
  CAWindow *ca = (CAWindow *) ap;
  ca_attach(ca->parent);
  ca_window_fill(ca, ptr);
  ca_sync(ca->parent);
  ca_detach(ca->parent);
}

static void
ca_window_func_create_mask (void *ap)
{
  CAWindow *ca = (CAWindow *) ap;
  boolean8_t fill;
  ca_size_t bounds = ca->bounds;

  ca_update_mask(ca->parent);
  if ( ! ca->parent->mask ) {
    ca_create_mask(ca->parent);
  }

  if ( bounds == CA_BOUNDS_MASK ) {
    bounds = CA_BOUNDS_FILL;
    fill = 1;
  }
  else {
    fill = 0;
  }

  ca->mask = (CArray *) ca_window_new(ca->parent->mask,
                                    ca->start, ca->count, bounds, (char*)&fill);
}

ca_operation_function_t ca_window_func = {
  -1, /* CA_OBJ_WINDOW */
  CA_VIRTUAL_ARRAY,
  free_ca_window,
  ca_window_func_clone,
  ca_window_func_ptr_at_addr,
  ca_window_func_ptr_at_index,
  NULL,
  ca_window_func_fetch_index,
  NULL,
  ca_window_func_store_index,
  ca_window_func_allocate,
  ca_window_func_attach,
  ca_window_func_sync,
  ca_window_func_detach,
  ca_window_func_copy_data,
  ca_window_func_sync_data,
  ca_window_func_fill_data,
  ca_window_func_create_mask,
};

/* ------------------------------------------------------------------- */

#define proc_window_attach_get(type) \
  if ( fill ) { \
    type *p, *v; \
    idx[level] = 0; \
    p = ca_ptr_at_index((CArray*)cb, idx); \
    v = (type*)cb->fill; \
    for (i=0; i<count; i++, p++) { \
      *p = *v; \
    } \
  } \
  else { \
    CArray *parent = cb->parent; \
    ca_size_t start  = cb->start[level]; \
    ca_size_t size0  = cb->size0[level]; \
    type *p, *q, *v;                   \
    idx[level]  = 0; \
    p = (type*)ca_ptr_at_index((CArray*)cb, idx); \
    v = (type*)cb->fill; \
    i = 0; \
    while ( start+i<0 && i<count ) { \
      k = start + i; \
      k = ca_bounds_normalize_index(cb->bounds, size0, k); \
      if ( k < 0 || k >= size0 ) { \
        *p = *v; \
      } \
      else { \
        idx0[level] = k; \
        *p = *(type*) ca_ptr_at_index(parent, idx0); \
      } \
      i++; p++; \
    } \
    idx0[level] = start+i; \
    q = (type*)ca_ptr_at_index(parent, idx0);\
    while ( start+i<size0 && i < count ) { \
      *p = *q; \
      i++, p++, q++; \
    } \
    while ( i < count ) { \
      k = start + i; \
      k = ca_bounds_normalize_index(cb->bounds, size0, k); \
      if ( k < 0 || k >= size0 ) { \
        *p = *v; \
      } \
      else { \
        idx0[level] = k; \
        *p = *(type*) ca_ptr_at_index(parent, idx0); \
      } \
      i++, p++; \
    } \
  }

static void
ca_window_attach_loop (CAWindow *cb, int8_t level,
                                ca_size_t *idx, ca_size_t *idx0, int fill)
{
  ca_size_t count = cb->count[level];
  ca_size_t i, k;

  if ( level == cb->ndim - 1 ) {
    switch ( cb->data_type ) {
    case CA_BOOLEAN:
    case CA_INT8:   proc_window_attach_get(int8_t); break;
    case CA_UINT8:  proc_window_attach_get(uint8_t); break;
    case CA_INT16:  proc_window_attach_get(int16_t); break;
    case CA_UINT16: proc_window_attach_get(uint16_t); break;
    case CA_INT32:  proc_window_attach_get(int32_t); break;
    case CA_UINT32:  proc_window_attach_get(uint32_t); break;
    case CA_INT64:   proc_window_attach_get(int64_t); break;
    case CA_UINT64:  proc_window_attach_get(uint64_t); break;
    case CA_FLOAT32: proc_window_attach_get(float32_t); break;
    case CA_FLOAT64: proc_window_attach_get(float64_t); break;
    case CA_FLOAT128: proc_window_attach_get(float128_t); break;
#ifdef HAVE_COMPLEX_H
    case CA_CMPLX64:  proc_window_attach_get(cmplx64_t); break;
    case CA_CMPLX128: proc_window_attach_get(cmplx128_t); break;
    case CA_CMPLX256: proc_window_attach_get(cmplx256_t); break;
#endif
    default:
      if ( fill ) {
        for (i=0; i<count; i++) {
          idx[level] = i;
          memcpy(ca_ptr_at_index((CArray*)cb, idx), cb->fill, cb->bytes);
        }
      }
      else {
        ca_size_t start = cb->start[level];
        ca_size_t size0 = cb->size0[level];
        for (i=0; i<count; i++) {
          idx[level]  = i;
          k = start + i;
          if ( k < 0 || k >= size0 ) {
            k = ca_bounds_normalize_index(cb->bounds, size0, k);
            if ( k < 0 || k >= size0 ) {
              memcpy(ca_ptr_at_index((CArray*)cb, idx), cb->fill, cb->bytes);
              continue;
            }
          }
          idx0[level] = k;
          memcpy(ca_ptr_at_index((CArray*)cb, idx), ca_ptr_at_index(cb->parent, idx0), cb->bytes);
        }
      }
    }
  }
  else {
    if ( fill ) {
      for (i=0; i<count; i++) {
        idx[level] = i;
        ca_window_attach_loop(cb, level+1, idx, idx0, 1);
      }
    }
    else {
      ca_size_t start = cb->start[level];
      ca_size_t size0 = cb->size0[level];
      for (i=0; i<count; i++) {
        idx[level]  = i;
        k = start + i;
        if ( k < 0 || k >= size0 ) {
          k = ca_bounds_normalize_index(cb->bounds, size0, k);
          if ( k < 0 || k >= size0 ) {
            ca_window_attach_loop(cb, level+1, idx, idx0, 1); /* fill */
            continue;
          }
        }
        idx0[level] = k;
        ca_window_attach_loop(cb, level+1, idx, idx0, 0); /* not-fill */
      }
    }
  }
}

void
ca_window_attach (CAWindow *cb)
{
  ca_size_t idx[CA_RANK_MAX];
  ca_size_t idx0[CA_RANK_MAX];
  ca_window_attach_loop(cb, (int8_t) 0, idx, idx0, 0);
}

#define proc_window_sync_set(type) \
  { \
    CArray *parent = cb->parent; \
    type *p, *q; \
    idx[level]  = 0; \
    p = (type*)ca_ptr_at_index((CArray*)cb, idx); \
    i = 0; \
    while ( start+i<0 && i<count ) { \
      k = start + i; \
      k = ca_bounds_normalize_index(cb->bounds, size0, k); \
      if ( k < 0 || k >= size0 ) { \
        ; \
      } \
      else { \
       idx0[level] = k; \
        *(type *)ca_ptr_at_index(parent, idx0) = *p; \
      } \
      i++; p++;                         \
    }\
    idx0[level] = start + i; \
    q = (type*)ca_ptr_at_index(parent, idx0);\
    while ( start+i < size0 && i<count ) { \
      *q = *p; \
      i++; p++; q++;                            \
    } \
    while ( i<count ) { \
      k = start + i; \
      k = ca_bounds_normalize_index(cb->bounds, size0, k); \
      if ( k < 0 || k >= size0 ) { \
        ; \
      } \
      else { \
        idx0[level] = k; \
        *(type*)ca_ptr_at_index(parent, idx0) = *p; \
      } \
      i++; p++; \
    } \
  }

static void
ca_window_sync_loop (CAWindow *cb, int8_t level,
                                ca_size_t *idx, ca_size_t *idx0)
{
  ca_size_t count = cb->count[level];
  ca_size_t start = cb->start[level];
  ca_size_t size0 = cb->size0[level];
  ca_size_t i, k;

  if ( level == cb->ndim - 1 ) {
    switch ( cb->data_type ) {
    case CA_BOOLEAN:
    case CA_INT8:   proc_window_sync_set(int8_t); break;
    case CA_UINT8:  proc_window_sync_set(uint8_t); break;
    case CA_INT16:  proc_window_sync_set(int16_t); break;
    case CA_UINT16: proc_window_sync_set(uint16_t); break;
    case CA_INT32:  proc_window_sync_set(int32_t); break;
    case CA_UINT32:  proc_window_sync_set(uint32_t); break;
    case CA_INT64:   proc_window_sync_set(int64_t); break;
    case CA_UINT64:  proc_window_sync_set(uint64_t); break;
    case CA_FLOAT32: proc_window_sync_set(float32_t); break;
    case CA_FLOAT64: proc_window_sync_set(float64_t); break;
    case CA_FLOAT128: proc_window_sync_set(float128_t); break;
#ifdef HAVE_COMPLEX_H
    case CA_CMPLX64:  proc_window_sync_set(cmplx64_t); break;
    case CA_CMPLX128: proc_window_sync_set(cmplx128_t); break;
    case CA_CMPLX256: proc_window_sync_set(cmplx256_t); break;
#endif
    default:
      for (i=0; i<count; i++) {
        idx[level]  = i;
        k = start + i;
        if ( k < 0 || k >= size0 ) {
          k = ca_bounds_normalize_index(cb->bounds, size0, k);
          if ( k < 0 || k >= size0 ) {
            continue;
          }
        }
        idx0[level] = k;
        memcpy(ca_ptr_at_index(cb->parent, idx0), ca_ptr_at_index((CArray*)cb, idx), cb->bytes);
      }
    }
  }
  else {
    for (i=0; i<count; i++) {
      idx[level]  = i;
      k = start + i;
      if ( k < 0 || k >= size0 ) {
        k = ca_bounds_normalize_index(cb->bounds, size0, k);
        if ( k < 0 || k >= size0 ) {
          continue;
        }
      }
      idx0[level] = k;
      ca_window_sync_loop(cb, level+1, idx, idx0);
    }
  }
}

void
ca_window_sync (CAWindow *cb)
{
  ca_size_t idx[CA_RANK_MAX];
  ca_size_t idx0[CA_RANK_MAX];
  ca_window_sync_loop(cb, (int8_t) 0, idx, idx0);
}

#define proc_window_fill_set(type) \
  { \
    CArray *parent = cb->parent; \
    type *q; \
    i = 0; \
    while ( start+i<0 && i<count ) { \
      k = start + i; \
      k = ca_bounds_normalize_index(cb->bounds, size0, k); \
      if ( k < 0 || k >= size0 ) { \
        ; \
      } \
      else { \
       idx0[level] = k; \
        *(type *)ca_ptr_at_index(parent, idx0) = *ptr; \
      } \
      i++; \
    }\
    idx0[level] = start + i; \
    q = (type*)ca_ptr_at_index(parent, idx0);\
    while ( start+i < size0 && i<count ) { \
      *q = *ptr; \
      i++; q++;                         \
    } \
    while ( i<count ) { \
      k = start + i; \
      k = ca_bounds_normalize_index(cb->bounds, size0, k); \
      if ( k < 0 || k >= size0 ) { \
        ; \
      } \
      else { \
        idx0[level] = k; \
        *(type*)ca_ptr_at_index(parent, idx0) = *ptr; \
      } \
      i++; \
    } \
  }

static void
ca_window_fill_loop (CAWindow *cb, char *ptr,
                    int8_t level, ca_size_t *idx0)
{
  ca_size_t count = cb->count[level];
  ca_size_t start = cb->start[level];
  ca_size_t size0 = cb->size0[level];
  ca_size_t i, k;

  if ( level == cb->ndim - 1 ) {
    switch ( cb->data_type ) {
    case CA_BOOLEAN:
    case CA_INT8:   proc_window_fill_set(int8_t); break;
    case CA_UINT8:  proc_window_fill_set(uint8_t); break;
    case CA_INT16:  proc_window_fill_set(int16_t); break;
    case CA_UINT16: proc_window_fill_set(uint16_t); break;
    case CA_INT32:  proc_window_fill_set(int32_t); break;
    case CA_UINT32:  proc_window_fill_set(uint32_t); break;
    case CA_INT64:   proc_window_fill_set(int64_t); break;
    case CA_UINT64:  proc_window_fill_set(uint64_t); break;
    case CA_FLOAT32: proc_window_fill_set(float32_t); break;
    case CA_FLOAT64: proc_window_fill_set(float64_t); break;
    case CA_FLOAT128: proc_window_fill_set(float128_t); break;
#ifdef HAVE_COMPLEX_H
    case CA_CMPLX64:  proc_window_fill_set(cmplx64_t); break;
    case CA_CMPLX128: proc_window_fill_set(cmplx128_t); break;
    case CA_CMPLX256: proc_window_fill_set(cmplx256_t); break;
#endif
    default:
      for (i=0; i<count; i++) {
        k = start + i;
        if ( k < 0 || k >= size0 ) {
          k = ca_bounds_normalize_index(cb->bounds, size0, k);
          if ( k < 0 || k >= size0 ) {
            continue;
          }
        }
        idx0[level] = k;
        memcpy(ca_ptr_at_index(cb->parent, idx0), ptr, cb->bytes);
      }
    }
  }
  else {
    for (i=0; i<count; i++) {
      k = start + i;
      if ( k < 0 || k >= size0 ) {
        k = ca_bounds_normalize_index(cb->bounds, size0, k);
        if ( k < 0 || k >= size0 ) {
          continue;
        }
      }
      idx0[level] = k;
      ca_window_fill_loop(cb, ptr, level+1, idx0);
    }
  }

}

void
ca_window_fill (CAWindow *cb, char *ptr)
{
  ca_size_t idx0[CA_RANK_MAX];
  ca_window_fill_loop(cb, ptr, (int8_t) 0, idx0);
}

/* ------------------------------------------------------------------- */

VALUE
rb_ca_window_new (VALUE cary,
                ca_size_t *start, ca_size_t *count, int8_t bounds, char *fill)
{
  volatile VALUE obj;
  CArray *parent;
  CAWindow *ca;
  rb_check_carray_object(cary);
  Data_Get_Struct(cary, CArray, parent);
  ca = ca_window_new(parent, start, count, bounds, fill);
  obj = ca_wrap_struct(ca);
  rb_ca_set_parent(obj, cary);
  rb_ca_data_type_inherit(obj, cary);
  return obj;
}

/* yard:
  class CArray
    def window (*argv)
    end
  end
*/

VALUE
rb_ca_window (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE obj, ropt, rfval = CA_NIL, rbounds = Qnil, rcs;
  CArray *ca;
  CScalar *cs;
  ca_size_t start[CA_RANK_MAX];
  ca_size_t count[CA_RANK_MAX];
  int32_t bounds = CA_BOUNDS_FILL;
  char *fill = NULL; 
  char *cbounds;
  ca_size_t i;

  Data_Get_Struct(self, CArray, ca);

  ropt = rb_pop_options(&argc, &argv);
  rb_scan_options(ropt, "bounds,fill_value", &rbounds, &rfval);

  if ( argc != ca->ndim ) {
    rb_raise(rb_eArgError, "ndim mismatch");
  }

  for (i=0; i<argc; i++) {
    ca_size_t offset, len, step;
    volatile VALUE arg = argv[i];
    ca_parse_range_without_check(arg, ca->dim[i], &offset, &len, &step);
    if ( step != 1 || len < 0 ) {
      rb_raise(rb_eArgError, 
               "first index should smaller than last index. "
               "The index range notation such as 0..-1 can't be used in CArray#window");
    }
    start[i] = offset;
    count[i] = len;
  }

  if ( rfval == CA_NIL ) {
    if ( rb_block_given_p() ) {
      rfval = rb_yield(self);
    }
  }
  else {
    /* rb_warn(":fill_value option for CArray#window will be obsoleted."); */
  }

  if ( rfval == CA_NIL ) {
    ;
  }
  else if ( rfval == CA_UNDEF ) {
    bounds = CA_BOUNDS_MASK;
  }
  else {
    rcs = rb_cscalar_new_with_value(ca->data_type, ca->bytes, rfval);
    Data_Get_Struct(rcs, CScalar, cs);
    fill = cs->ptr;
  }

  if ( ! NIL_P(rbounds) ) {
    switch ( TYPE(rbounds) ) {
    case T_STRING:
      cbounds = StringValuePtr(rbounds);
      if ( rfval == CA_UNDEF && strncmp(cbounds, "fill", 4) 
                             && strncmp(cbounds, "mask", 4) ) {
        rb_raise(rb_eRuntimeError, "conflicted bounds and fill_value");
      }
      if ( ! strncmp(cbounds, "ruby", 4) ) {
        bounds = CA_BOUNDS_RUBY;
      }
      else if ( ! strncmp(cbounds, "strict", 6) ) {
        bounds = CA_BOUNDS_STRICT;
      }
      else if ( ! strncmp(cbounds, "nearest", 7) ) {
        bounds = CA_BOUNDS_NEAREST;
      }
      else if ( ! strncmp(cbounds, "periodic", 8) ) {
        bounds = CA_BOUNDS_PERIODIC;
      }
      else if ( ! strncmp(cbounds, "reflect", 7) ) {
        bounds = CA_BOUNDS_REFLECT;
      }
      else if ( ! strncmp(cbounds, "mask", 4) ) {
        rb_warn("CAWindow option :bounds=>\"mask\" will be obsolete");
        rb_warn("use ca.window(...) { UNDEF }");
        bounds = CA_BOUNDS_MASK;
      }
      else if ( ! strncmp(cbounds, "fill", 4) ) {
        bounds = CA_BOUNDS_FILL;
      }
      else {
        rb_raise(rb_eRuntimeError, 
                 "unknown option value '%s' for :bounds", cbounds);        
      }
      break;
    case T_FIXNUM:
      bounds = NUM2INT(rbounds);
      break;
    default:
      rb_raise(rb_eRuntimeError, "invalid option value for :bounds");
    }
  }

  obj = rb_ca_window_new(self, start, count, bounds, fill);

  return obj;
}

/* ------------------------------------------------------------------- */

static VALUE
rb_ca_window_s_allocate (VALUE klass)
{
  CAWindow *ca;
  return Data_Make_Struct(klass, CAWindow, ca_mark, ca_free, ca);
}

static VALUE
rb_ca_window_initialize_copy (VALUE self, VALUE other)
{
  CAWindow *ca, *cs;

  Data_Get_Struct(self,  CAWindow, ca);
  Data_Get_Struct(other, CAWindow, cs);

  ca_window_setup(ca, cs->parent, cs->start, cs->count, cs->bounds, cs->fill);

  return self;
}

/* yard:
  class CAWindow
    def index2addr0 (idx)
    end
  end
*/

static VALUE
rb_ca_window_idx2addr0 (int argc, VALUE *argv, VALUE self)
{
  CAWindow *cw;
  ca_size_t addr;
  int8_t i;
  ca_size_t idxi;

  Data_Get_Struct(self, CAWindow, cw);

  if ( argc != cw->ndim ) {
    rb_raise(rb_eArgError,
             "invalid # of arguments (should be <%i>)", cw->ndim);
  }

  addr = 0;
  for (i=0; i<cw->ndim; i++) {
    idxi = NUM2SIZE(argv[i]);
    CA_CHECK_INDEX(idxi, cw->dim[i]);
    addr = cw->size0[i] * addr + cw->start[i] + idxi;
  }

  if ( addr < 0 || addr >= cw->parent->elements ) {
    return Qnil;
  }
  else {
    return SIZE2NUM(addr);
  }
}

/* yard:
  class CAWindow
    def addr2addr0 (addr)
    end
  end
*/

static VALUE
rb_ca_window_addr2addr0 (VALUE self, VALUE raddr)
{
  CAWindow *cw;
  ca_size_t addr = NUM2SIZE(raddr);
  ca_size_t idx[CA_RANK_MAX];
  int8_t i;

  Data_Get_Struct(self, CAWindow, cw);

  ca_addr2index((CArray*)cw, addr, idx);

  addr = 0;
  for (i=0; i<cw->ndim; i++) {
    addr *= cw->size0[i];
    addr += cw->start[i] + idx[i];
  }

  return SIZE2NUM(addr);
}


static VALUE
rb_ca_window_move (int argc, VALUE *argv, VALUE self)
{
  CAWindow *cw;
  ca_size_t start;
  int8_t i;

  Data_Get_Struct(self, CAWindow, cw);

  if ( argc != cw->ndim ) {
    rb_raise(rb_eArgError, "invalid # of arguments");
  }

  ca_update_mask(cw);
  for (i=0; i<cw->ndim; i++) {
    start = NUM2SIZE(argv[i]);
    cw->start[i] = start;
    if ( cw->mask ) {
      ((CAWindow*)(cw->mask))->start[i] = start;
    }
  }

  return self;
}

/* yard:
  class CAWindow
    def fill_value
    end
    def fill_value= (val)
    end
  end
*/

static VALUE
rb_ca_window_set_fill_value (VALUE self, VALUE rfval)
{
  CAWindow *cw;
  Data_Get_Struct(self, CAWindow, cw);
  rb_ca_obj2ptr(self, rfval, cw->fill);
  return Qnil;
}

static VALUE
rb_ca_window_get_fill_value (VALUE self)
{
  CAWindow *cw;
  Data_Get_Struct(self, CAWindow, cw);
  return rb_ca_ptr2obj(self, cw->fill);
}

static VALUE
rb_ca_window_get_bounds (VALUE self)
{
  CAWindow *cw;
  Data_Get_Struct(self, CAWindow, cw);
  return SIZE2NUM(cw->bounds);
}

#define rb_cw_get_attr_ary(name)    \
  rb_cw_## name (VALUE self)        \
  {                                 \
    volatile VALUE ary;             \
    CAWindow *cw;                    \
    int8_t i;                              \
    Data_Get_Struct(self, CAWindow, cw);     \
    ary = rb_ary_new2(cw->ndim);            \
    for (i=0; i<cw->ndim; i++) {                    \
      rb_ary_store(ary, i, SIZE2NUM(cw->name[i]));  \
    }                                               \
    return ary;                                     \
}

/* yard:
  class CAWindow
    def size0
    end
    def start
    end
    def step 
    end
    def count
    end
    def offset
    end
  end
*/

static VALUE rb_cw_get_attr_ary(start);
static VALUE rb_cw_get_attr_ary(count);
static VALUE rb_cw_get_attr_ary(size0);

void
Init_ca_obj_window ()
{    

  rb_cCAWindow = rb_define_class("CAWindow", rb_cCAVirtual);

  CA_OBJ_WINDOW = ca_install_obj_type(rb_cCAWindow, ca_window_func);
  rb_define_const(rb_cObject, "CA_OBJ_WINDOW", INT2NUM(CA_OBJ_WINDOW));

  rb_define_method(rb_cCArray, "window", rb_ca_window, -1);

  rb_define_alloc_func(rb_cCAWindow, rb_ca_window_s_allocate);
  rb_define_method(rb_cCAWindow, "initialize_copy",
                                      rb_ca_window_initialize_copy, 1);

  rb_define_method(rb_cCAWindow, "move",  rb_ca_window_move, -1);

  rb_define_method(rb_cCAWindow, "index2addr0",  rb_ca_window_idx2addr0, -1);
  rb_define_method(rb_cCAWindow, "addr2addr0", rb_ca_window_addr2addr0, 1);

  rb_define_method(rb_cCAWindow, "fill_value", rb_ca_window_get_fill_value, 0);
  rb_define_method(rb_cCAWindow, "fill_value=", rb_ca_window_set_fill_value, 1);

  rb_define_method(rb_cCAWindow, "bounds", rb_ca_window_get_bounds, 0);

  rb_define_method(rb_cCAWindow, "start",  rb_cw_start, 0);
  rb_define_method(rb_cCAWindow, "count",  rb_cw_count, 0);
  rb_define_method(rb_cCAWindow, "size0",  rb_cw_size0, 0);

}

