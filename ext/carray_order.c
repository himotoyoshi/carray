/* ---------------------------------------------------------------------------

  carray_order.c

  This file is part of Ruby/CArray extension library.

  Copyright (C) 2005-2020 Hiroki Motoyoshi

---------------------------------------------------------------------------- */

#include "ruby.h"
#include "carray.h"
#include <math.h>
#include <float.h>

static ID id_equal;

static VALUE
rb_ca_value_not_masked (VALUE self)
{
  VALUE rval   = rb_ca_value_array(self);
  VALUE select = rb_ca_is_not_masked(self);
  return rb_ca_fetch(rval, select);
}

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
  free(mi);
  free(ma);
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

/* @overload project (idx, lval=nil, uval=nil)

TBD. Creates new array the element of the object as address.
*/

VALUE
rb_ca_project (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE obj, ridx, vlfval, vufval;
  CArray *ca, *ci, *co;
  char *lfval, *ufval;

  rb_scan_args(argc, argv, "12", (VALUE *)&ridx, (VALUE *) &vlfval, (VALUE *) &vufval);

  Data_Get_Struct(self, CArray, ca);

  rb_check_carray_object(ridx);
  ci = ca_wrap_readonly(ridx, CA_SIZE);

  lfval = malloc_with_check(ca->bytes);
  ufval = malloc_with_check(ca->bytes);

  if ( ! NIL_P(vlfval) ) {
    rb_ca_obj2ptr(self, vlfval, lfval);
    rb_ca_obj2ptr(self, vlfval, ufval);
  }

  if ( ! NIL_P(vufval) ) {
    rb_ca_obj2ptr(self, vufval, ufval);
  }

  co = ca_project(ca, ci,
                 ( ! NIL_P(vlfval) ) ? lfval : NULL,
                 ( ( ! NIL_P(vufval) ) || ( ! NIL_P(vlfval) ) ) ? ufval : NULL);

  free(lfval);
  free(ufval);

  obj = ca_wrap_struct(co);
  rb_ca_data_type_inherit(obj, self);

  if ( ! ca_is_any_masked(co) ) {
    obj = rb_ca_unmask_copy(obj);
  }

  return obj;
}

/* ----------------------------------------------------------------- */

#define proc_reverse_bang_mask()                         \
  {                                                     \
    boolean8_t *p = (boolean8_t *)ca->mask->ptr;                          \
    boolean8_t *q = (boolean8_t *)ca->mask->ptr + ca->elements - 1;       \
    boolean8_t v;                                             \
    for (; p<q; p++, q--) {                             \
      v = *p; *p = *q; *q = v;                          \
    }                                                   \
  }


#define proc_reverse_bang(type)                         \
  {                                                     \
    type *p = (type *)ca->ptr;                          \
    type *q = (type *)ca->ptr + ca->elements - 1;       \
    type v;                                             \
    for (; p<q; p++, q--) {                             \
      v = *p; *p = *q; *q = v;                          \
    }                                                   \
  }

#define proc_reverse_bang_data()                        \
  {                                                     \
    ca_size_t bytes = ca->bytes;                          \
    char *p = ca->ptr;                                  \
    char *q = ca->ptr + bytes * (ca->elements - 1);     \
    char *v = malloc_with_check(bytes);                     \
    for (; p<q; p+=bytes, q-=bytes) {                   \
      memcpy(v, p, bytes);                              \
      memcpy(p, q, bytes);                              \
      memcpy(q, v, bytes);                              \
    }                                                   \
    free(v);                                            \
  }

/* @overload reverse!

Reverses the elements of +ca+ in place.
*/

static VALUE
rb_ca_reverse_bang (VALUE self)
{
  CArray *ca;

  rb_ca_modify(self);

  Data_Get_Struct(self, CArray, ca);
  ca_attach(ca);

  switch ( ca->data_type ) {
  case CA_FIXLEN: proc_reverse_bang_data();  break;
  case CA_BOOLEAN:
  case CA_INT8:
  case CA_UINT8:    proc_reverse_bang(int8_t);  break;
  case CA_INT16:
  case CA_UINT16:   proc_reverse_bang(int16_t); break;
  case CA_INT32:
  case CA_UINT32:
  case CA_FLOAT32:  proc_reverse_bang(int32_t); break;
  case CA_INT64:
  case CA_UINT64:
  case CA_FLOAT64:  proc_reverse_bang(float64_t);  break;
  case CA_FLOAT128: proc_reverse_bang(float128_t);  break;
#ifdef HAVE_COMPLEX_H
  case CA_CMPLX64:  proc_reverse_bang(float64_t);  break;
  case CA_CMPLX128: proc_reverse_bang(cmplx128_t);  break;
  case CA_CMPLX256: proc_reverse_bang(cmplx256_t);  break;
#endif
  case CA_OBJECT:   proc_reverse_bang(VALUE);  break;
  default:
    rb_raise(rb_eCADataTypeError, "[BUG] array has an unknown data type");
  }

  if ( ca_has_mask(ca) ) {
    proc_reverse_bang_mask();
  }

  ca_sync(ca);
  ca_detach(ca);

  return self;
}

/* @overload reverse

Returns a new CArray object containing <i>ca</i>'s elements in
reverse order.
*/

static VALUE
rb_ca_reversed_copy (VALUE self)
{
  volatile VALUE out = rb_ca_copy(self);
  rb_ca_data_type_inherit(out, self);
  return rb_ca_reverse_bang(out);
}

/* ------------------------------------------------------------------------- */

typedef struct {
  ca_size_t bytes;
  char   *ptr;
} cmp_data;

typedef int (*ca_qsort_cmp_func)();

#define qcmp_type(type)         \
static int                      \
qcmp_## type (type *a, type *b) \
{                               \
  if ( *a > *b ) return 1;      \
  if ( *a < *b ) return -1;     \
  return 0;                     \
}

#define qcmp_f_type(type)       \
static int                      \
qcmp_## type (type *a, type *b) \
{                               \
  if ( isnan(*a) && ( ! isnan(*b) ) ) return 1;    \
  if ( isnan(*b) && ( ! isnan(*a) ) ) return -1;   \
  if ( *a > *b ) return 1;      \
  if ( *a < *b ) return -1;     \
  return 0;                     \
}

static int
qcmp_VALUE (VALUE *a, VALUE *b)
{
  int cmp;
  cmp = NUM2INT(rb_funcall(*a, rb_intern("<=>"), 1, *b));
  if ( cmp != 0 ) return cmp;
  return 0;
}

static int
qcmp_data (cmp_data *a, cmp_data *b)
{
  int cmp;
  cmp = memcmp(a->ptr, b->ptr, a->bytes);
  if ( cmp != 0 ) return cmp;
  return 0;
}

qcmp_type(boolean8_t)
qcmp_type(int8_t)
qcmp_type(uint8_t)
qcmp_type(int16_t)
qcmp_type(uint16_t)
qcmp_type(int32_t)
qcmp_type(uint32_t)
qcmp_type(int64_t)
qcmp_type(uint64_t)
qcmp_f_type(float32_t)
qcmp_f_type(float64_t)
qcmp_f_type(float128_t)

static int
qcmp_not_implement (void *a, void *b)
{
  rb_raise(rb_eNotImpError,
           "compare function is not implemented for the data type");
}

ca_qsort_cmp_func
ca_qsort_cmp[CA_NTYPE] = {
  qcmp_data,
  qcmp_boolean8_t,
  qcmp_int8_t,
  qcmp_uint8_t,
  qcmp_int16_t,
  qcmp_uint16_t,
  qcmp_int32_t,
  qcmp_uint32_t,
  qcmp_int64_t,
  qcmp_uint64_t,
  qcmp_float32_t,
  qcmp_float64_t,
  qcmp_float128_t,
  qcmp_not_implement,
  qcmp_not_implement,
  qcmp_not_implement,
  qcmp_VALUE,
};

/* @overload sort!

Sorts <i>ca</i>'s elements in place.
*/

static VALUE
rb_ca_sort_bang (VALUE self)
{
  CArray *ca;

  if ( rb_ca_is_any_masked(self) ) {
    rb_ca_sort_bang(rb_ca_value_not_masked(self));
    return self;
  }

  rb_ca_modify(self);

  Data_Get_Struct(self, CArray, ca);
  ca_attach(ca);

  if ( ca_is_fixlen_type(ca) ) {
    cmp_data *cmp_ptr, *p;
    char *ca_ptr, *q;
    ca_size_t i;
    cmp_ptr = malloc_with_check(sizeof(cmp_data)*ca->elements);
    ca_ptr  = malloc_with_check(ca_length(ca));
    for (i=0, p=cmp_ptr, q=ca->ptr; i<ca->elements; i++, p++, q+=ca->bytes) {
      p->bytes = ca->bytes;
      p->ptr   = q;
    }
    qsort(cmp_ptr, ca->elements, sizeof(cmp_data), ca_qsort_cmp[CA_FIXLEN]);
    for (i=0, p=cmp_ptr, q=ca_ptr; i<ca->elements; i++, p++, q+=ca->bytes) {
      memcpy(q, p->ptr, ca->bytes);
    }
    free(ca->ptr);
    ca->ptr = ca_ptr;
    free(cmp_ptr);
  }
  else {
    qsort(ca->ptr, ca->elements, ca->bytes, ca_qsort_cmp[ca->data_type]);
  }
  ca_sync(ca);
  ca_detach(ca);
  return self;
}

/* @overload sort

Returns a new CArray object containing <i>ca</i>'s elements sorted.
*/

static VALUE
rb_ca_sorted_copy (VALUE self)
{
  volatile VALUE out = rb_ca_copy(self);
  rb_ca_data_type_inherit(out, self);
  return rb_ca_sort_bang(out);
}


/* --------------------------------------------------------------- */

/* @overload bsearch

Returns a new CArray object containing <i>ca</i>'s elements sorted.
*/

static VALUE
rb_ca_binary_search (VALUE self, volatile VALUE rval)
{
  volatile VALUE out;
  CArray *ca;
  char *val;
  Data_Get_Struct(self, CArray, ca);

  /* FIXME : treat mask */
  /*
  if ( ca_has_mask(ca) && ca_is_any_masked(self) ) {
    VALUE val  = rb_funcall(self, rb_intern("value"), 0);
    VALUE select = rb_ca_is_not_masked(self);
    VALUE obj    = rb_funcall(val, rb_intern("[]"), 1, select);
    return rb_ca_binary_search(obj, rval);
  }
  */

  if ( ca_is_any_masked(ca) ) {
    rb_raise(rb_eRuntimeError, 
             "CArray#bsearch can't be applied to carray with masked element.");
  }

  ca_attach(ca);

  if ( rb_obj_is_carray(rval) ) {
    volatile VALUE vidx;
    CArray *cv, *co;
    char *ptr, *val;
    ca_size_t i, idx;
    Data_Get_Struct(rval, CArray, cv);
    if ( ca->data_type != cv->data_type ) {
      cv = ca_wrap_readonly(rval, ca->data_type);
    }
    co = carray_new(CA_SIZE, cv->ndim, cv->dim, 0, NULL);
    out = ca_wrap_struct(co);
    ca_attach(cv);
    if ( ca_is_fixlen_type(ca) ) {
      cmp_data *cmp_ptr, *p, *ptr, cmp_val;
      char *q;
      ca_size_t i;
      cmp_val.bytes = ca->bytes;
      cmp_ptr = malloc_with_check(sizeof(cmp_data)*ca->elements);
      for (i=0, p=cmp_ptr, q=ca->ptr; i<ca->elements; i++, p++, q+=ca->bytes) {
        p->bytes = ca->bytes;
        p->ptr   = q;
      }
      for (i=0; i<cv->elements; i++) {
        cmp_val.ptr = ca_ptr_at_addr(cv, i);
        ptr = bsearch(&cmp_val, cmp_ptr, ca->elements, sizeof(cmp_data),
                      ca_qsort_cmp[CA_FIXLEN]);
        vidx = ( ! ptr ) ? CA_UNDEF : SIZE2NUM(ptr - cmp_ptr);      
        rb_ca_store_addr(out, i, vidx);
      }
      free(cmp_ptr);
    }
    else {
      for (i=0; i<cv->elements; i++) {
        val = ca_ptr_at_addr(cv, i);
        ptr = bsearch(val, ca->ptr, ca->elements, ca->bytes,
                      ca_qsort_cmp[ca->data_type]);
        if ( ! ptr ) {
          rb_ca_store_addr(out, i, CA_UNDEF);
        }
        else {
          idx = (ptr - ca->ptr)/ca->bytes;      
          ca_store_addr(co, i, &idx);
        }
      }
    }
    ca_detach(cv);
  }
  else {
    val = ALLOCA_N(char, ca->bytes);
    rb_ca_obj2ptr(self, rval, val);
    if ( ca_is_fixlen_type(ca) ) {
      cmp_data *cmp_ptr, *p, *ptr, cmp_val;
      char *q;
      ca_size_t i;
      cmp_val.bytes = ca->bytes;
      cmp_val.ptr   = val;
      cmp_ptr = malloc_with_check(sizeof(cmp_data)*ca->elements);
      for (i=0, p=cmp_ptr, q=ca->ptr; i<ca->elements; i++, p++, q+=ca->bytes) {
        p->bytes = ca->bytes;
        p->ptr   = q;
      }
      ptr = bsearch(&cmp_val, cmp_ptr, ca->elements, sizeof(cmp_data),
                    ca_qsort_cmp[CA_FIXLEN]);
      out = ( ! ptr ) ? Qnil : SIZE2NUM((ptr - cmp_ptr));
      free(cmp_ptr);
    }
    else {
      char *ptr;
      ptr = bsearch(val, ca->ptr, ca->elements, ca->bytes,
                    ca_qsort_cmp[ca->data_type]);
      out = ( ! ptr ) ? Qnil : SIZE2NUM((ptr - ca->ptr)/ca->bytes);
    }
  }
  ca_detach(ca);
  return out;
}

/* @overload bsearch_index

TBD. 
*/

static VALUE
rb_ca_binary_search_index (VALUE self, volatile VALUE rval)
{
  VALUE raddr = rb_ca_binary_search(self, rval);
  return ( NIL_P(raddr) ) ? Qnil : rb_ca_addr2index(self, raddr);
}

/* ------------------------------------------------------------------------- */

#define proc_find_value(type)                                \
  {                                                          \
    type *ptr = (type *) ca->ptr;                            \
    boolean8_t *m = (ca->mask) ? (boolean8_t*) ca->mask->ptr : NULL; \
    type val  = (type) NUM2LL(value);                      \
    ca_size_t i;                                               \
    if ( m ) {                                               \
      for (i=0; i<ca->elements; i++, ptr++) {                \
        if ( ! *m++ ) {                                      \
          if ( *ptr == val ) {                               \
            addr = i;                                        \
            break;                                           \
          }                                                  \
        }                                                    \
      }                                                      \
    }                                                        \
    else {                                                   \
      for (i=0; i<ca->elements; i++, ptr++) {                \
        if ( *ptr == val ) {                                 \
          addr = i;                                          \
          break;                                             \
        }                                                    \
      }                                                      \
    }                                                        \
  }

#define proc_find_value_float(type, defeps)                  \
  {                                                          \
    type *ptr = (type *) ca->ptr;                            \
    boolean8_t *m = (ca->mask) ? (boolean8_t*) ca->mask->ptr : NULL; \
    type val  = (type) NUM2DBL(value);                       \
    double eps  = (NIL_P(veps)) ? defeps*fabs(val) : NUM2DBL(veps); \
    ca_size_t i;                                               \
    if ( m ) {                                               \
      for (i=0; i<ca->elements; i++, ptr++) {                \
        if ( ! *m++ ) {                                      \
          if ( fabs(*ptr - val) <= eps ) {                   \
            addr = i;                                        \
            break;                                           \
          }                                                  \
        }                                                    \
      }                                                      \
    }                                                        \
    else {                                                   \
      for (i=0; i<ca->elements; i++, ptr++) {                \
        if ( fabs(*ptr - val) <= eps ) {                     \
          addr = i;                                          \
          break;                                             \
        }                                                    \
      }                                                      \
    }                                                        \
  }

#define proc_find_value_float128(type, defeps)                  \
  {                                                          \
    type *ptr = (type *) ca->ptr;                            \
    boolean8_t *m = (ca->mask) ? (boolean8_t*) ca->mask->ptr : NULL; \
    type val  = (type) NUM2DBL(value);                       \
    float128_t eps  = (NIL_P(veps)) ? defeps*fabsl(val) : NUM2DBL(veps); \
    ca_size_t i;                                               \
    if ( m ) {                                               \
      for (i=0; i<ca->elements; i++, ptr++) {                \
        if ( ! *m++ ) {                                      \
          if ( fabsl(*ptr - val) <= eps ) {                   \
            addr = i;                                        \
            break;                                           \
          }                                                  \
        }                                                    \
      }                                                      \
    }                                                        \
    else {                                                   \
      for (i=0; i<ca->elements; i++, ptr++) {                \
        if ( fabsl(*ptr - val) <= eps ) {                     \
          addr = i;                                          \
          break;                                             \
        }                                                    \
      }                                                      \
    }                                                        \
  }

#define proc_find_value_cmplx(type, defeps)                  \
  {                                                          \
    type *ptr = (type *) ca->ptr;                            \
    boolean8_t *m = (ca->mask) ? (boolean8_t*) ca->mask->ptr : NULL; \
    type val  = (type) NUM2CC(value);                        \
    double eps  = (NIL_P(veps)) ? defeps*cabs(val) : NUM2DBL(veps); \
    ca_size_t i;                                               \
    if ( m ) {                                               \
      for (i=0; i<ca->elements; i++, ptr++) {                \
        if ( ! *m++ ) {                                      \
          if ( cabs(*ptr - val) <= eps ) {                   \
            addr = i;                                        \
            break;                                           \
          }                                                  \
        }                                                    \
      }                                                      \
    }                                                        \
    else {                                                   \
      for (i=0; i<ca->elements; i++, ptr++) {                \
        if ( cabs(*ptr - val) <= eps ) {                     \
          addr = i;                                          \
          break;                                             \
        }                                                    \
      }                                                      \
    }                                                        \
  }

#define proc_find_value_object()                             \
  {                                                          \
    VALUE *ptr = (VALUE *) ca->ptr;                          \
    boolean8_t *m = (ca->mask) ? (boolean8_t*) ca->mask->ptr : NULL; \
    ca_size_t i;                                               \
    if ( m ) {                                               \
      for (i=0; i<ca->elements; i++, ptr++) {                \
        if ( ! *m++ ) {                                      \
          if ( rb_funcall(value, id_equal, 1, *ptr) ) {      \
            addr = i;                                        \
            break;                                           \
          }                                                  \
        }                                                    \
      }                                                      \
    }                                                        \
    else {                                                   \
      for (i=0; i<ca->elements; i++, ptr++) {                \
        if ( rb_funcall(value, id_equal, 1, *ptr) ) {        \
          addr = i;                                          \
          break;                                             \
        }                                                    \
      }                                                      \
    }                                                        \
  }


/* @overload search

TBD. 
*/

static VALUE
rb_ca_linear_search (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE value, veps;
  CArray *ca;
  ca_size_t addr;

  rb_scan_args(argc, argv, "11", (VALUE *) &value, (VALUE *) &veps);

  Data_Get_Struct(self, CArray, ca);

  ca_attach(ca);

  addr = -1;

  switch ( ca->data_type ) {
  case CA_BOOLEAN:
  case CA_INT8:
  case CA_UINT8:    proc_find_value(int8_t);    break;
  case CA_INT16:
  case CA_UINT16:   proc_find_value(int16_t);   break;
  case CA_INT32:    proc_find_value(int32_t);   break;
  case CA_UINT32:   proc_find_value(uint32_t); break;
  case CA_INT64:    proc_find_value(int64_t);   break;
  case CA_UINT64:   proc_find_value(uint64_t); break;
  case CA_FLOAT32:  proc_find_value_float(float32_t, FLT_EPSILON); break;
  case CA_FLOAT64:  proc_find_value_float(float64_t, DBL_EPSILON); break;
  case CA_FLOAT128: proc_find_value_float128(float128_t, DBL_EPSILON); break;
#ifdef HAVE_COMPLEX_H
  case CA_CMPLX64:  proc_find_value_cmplx(cmplx64_t, FLT_EPSILON); break;
  case CA_CMPLX128: proc_find_value_cmplx(cmplx128_t, DBL_EPSILON); break;
  case CA_CMPLX256: proc_find_value_cmplx(cmplx256_t, DBL_EPSILON); break;
#endif
  case CA_OBJECT:   proc_find_value_object(); break;
  default:
    rb_raise(rb_eCADataTypeError, "invalid data type");
  }

  ca_detach(ca);

  return ( addr == -1 ) ? Qnil : SIZE2NUM(addr);
}

/* @overload search_index

TBD. 
*/

static VALUE
rb_ca_linear_search_index (int argc, VALUE *argv, VALUE self)
{
  VALUE raddr = rb_ca_linear_search(argc, argv, self);
  return ( NIL_P(raddr) ) ? Qnil : rb_ca_addr2index(self, raddr);
}

/* ----------------------------------------------------------------- */

#define proc_nearest_addr(type, from, ABS)              \
  {                                                     \
    type *ptr = (type *) ca->ptr;                       \
    boolean8_t *m = (ca->mask) ? (boolean8_t*) ca->mask->ptr : NULL; \
    type val  = (type) from(value);                     \
    double trial;                                       \
    double diff = 1.0/0.0;                              \
    ca_size_t i;                                          \
    addr = -1;                                           \
    if ( m ) {                                          \
      for (i=0; i<ca->elements; i++, ptr++) {           \
        if ( ! *m++ ) {                                 \
          trial = ABS(val - *ptr);                      \
          if ( trial < diff ) {                         \
            addr = i;                                   \
            diff = trial;                               \
          }                                             \
        }                                               \
      }                                                 \
    }                                                   \
    else {                                              \
      for (i=0; i<ca->elements; i++, ptr++) {           \
        trial = ABS(val - *ptr);                        \
        if ( trial < diff ) {                           \
          addr = i;                                     \
          diff = trial;                                 \
        }                                               \
      }                                                 \
    }                                                   \
  }

#define proc_nearest_addr_VALUE()              \
  {                                                     \
    VALUE *ptr = (VALUE *) ca->ptr;                       \
    boolean8_t *m = (ca->mask) ? (boolean8_t*) ca->mask->ptr : NULL; \
    VALUE val  = value;                     \
    VALUE trial;                                       \
    VALUE diff = rb_float_new(1.0/0.0);                              \
    ca_size_t i;                                          \
    addr = -1;                                           \
    if ( m ) {                                          \
      for (i=0; i<ca->elements; i++, ptr++) {           \
        if ( ! *m++ ) {                                 \
          trial = rb_funcall(val, rb_intern("distance"), 1, *ptr);                      \
          if ( rb_funcall(trial, rb_intern("<"), 1, diff) ) {                         \
            addr = i;                                   \
            diff = trial;                               \
          }                                             \
        }                                               \
      }                                                 \
    }                                                   \
    else {                                              \
      for (i=0; i<ca->elements; i++, ptr++) {           \
        trial = rb_funcall(val, rb_intern("distance"), 1, *ptr);                      \
        if ( rb_funcall(trial, rb_intern("<"), 1, diff) ) {                         \
          addr = i;                                     \
          diff = trial;                                 \
        }                                               \
      }                                                 \
    }                                                   \
  }

/* @overload search_nearest

TBD. 
*/

static VALUE
rb_ca_linear_search_nearest (VALUE self, VALUE value)
{
  CArray *ca;
  ca_size_t addr;

  Data_Get_Struct(self, CArray, ca);

  ca_attach(ca);

  switch ( ca->data_type ) {
  case CA_BOOLEAN:
  case CA_INT8:    proc_nearest_addr(int8_t,      NUM2LONG,   fabs); break;
  case CA_UINT8:   proc_nearest_addr(uint8_t,    NUM2ULONG,  fabs); break;
  case CA_INT16:   proc_nearest_addr(int16_t,     NUM2LONG,   fabs); break;
  case CA_UINT16:  proc_nearest_addr(uint16_t,   NUM2ULONG,  fabs); break;
  case CA_INT32:   proc_nearest_addr(int32_t,     NUM2LONG,   fabs); break;
  case CA_UINT32:  proc_nearest_addr(uint32_t,   NUM2ULONG,  fabs); break;
  case CA_INT64:   proc_nearest_addr(int64_t,     NUM2LL,     fabs); break;
  case CA_UINT64:  proc_nearest_addr(uint64_t,   rb_num2ull, fabs); break;
  case CA_FLOAT32: proc_nearest_addr(float32_t,   NUM2DBL,    fabs); break;
  case CA_FLOAT64: proc_nearest_addr(float64_t,   NUM2DBL,    fabs); break;
  case CA_FLOAT128: proc_nearest_addr(float128_t, NUM2DBL,    fabs); break;
#ifdef HAVE_COMPLEX_H
  case CA_CMPLX64:  proc_nearest_addr(cmplx64_t,  NUM2CC, cabs); break;
  case CA_CMPLX128: proc_nearest_addr(cmplx128_t, NUM2CC, cabs); break;
  case CA_CMPLX256: proc_nearest_addr(cmplx256_t, NUM2CC, cabs); break;
#endif
  case CA_OBJECT:  proc_nearest_addr_VALUE(); break;
  default:
    rb_raise(rb_eCADataTypeError, "invalid data type for nearest_addr()");
  }

  ca_detach(ca);

  return ( addr == -1 ) ? Qnil : SIZE2NUM(addr);
}

/* @overload search_nearest_index

TBD. 
*/

static VALUE
rb_ca_linear_search_nearest_index (VALUE self, VALUE value)
{
  VALUE raddr = rb_ca_linear_search_nearest(self, value);
  return ( NIL_P(raddr) ) ? Qnil : rb_ca_addr2index(self, raddr);
}

void
Init_carray_order ()
{
  id_equal = rb_intern("==");
  
  rb_define_method(rb_cCArray,  "project", rb_ca_project, -1);

  rb_define_method(rb_cCArray,  "reverse!", rb_ca_reverse_bang, 0);
  rb_define_method(rb_cCArray,  "reverse", rb_ca_reversed_copy, 0);

  rb_define_method(rb_cCArray,  "sort!", rb_ca_sort_bang, 0);
  rb_define_method(rb_cCArray,  "sort", rb_ca_sorted_copy, 0);

  rb_define_method(rb_cCArray,  "bsearch", rb_ca_binary_search, 1);
  rb_define_method(rb_cCArray,  "bsearch_index", rb_ca_binary_search_index, 1);

  rb_define_method(rb_cCArray,  "search", rb_ca_linear_search, -1);
  rb_define_method(rb_cCArray,  "search_index", rb_ca_linear_search_index, -1);

  rb_define_method(rb_cCArray,  "search_nearest",
                                rb_ca_linear_search_nearest, 1);
  rb_define_method(rb_cCArray,  "search_nearest_index",
                                rb_ca_linear_search_nearest_index, 1);

}
