/* ---------------------------------------------------------------------------

  carray_sort_addr.c

  This file is part of Ruby/CArray extension library.
  You can redistribute it and/or modify it under the terms of
  the Ruby Licence.

  Copyright (C) 2005 Hiroki Motoyoshi

---------------------------------------------------------------------------- */

#include "ruby.h"
#include "carray.h"
#include <math.h>

/* ----------------------------------------------------------------- */

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
qcmp_data (char *a, char *b, int32_t bytes)
{
  int cmp;
  cmp = memcmp(a, b, bytes);
  if ( cmp != 0 ) return cmp;
  return 0;
}

static int
qcmp_VALUE (VALUE *a, VALUE *b)
{
  int cmp;
  cmp = NUM2INT(rb_funcall(*a, rb_intern("<=>"), 1, *b));
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

static ca_qsort_cmp_func
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

/* ----------------------------------------------------------------- */

struct cmp_base {
  int      n;
  CArray **ca;
};

struct cmp_data {
  int32_t  i;
  struct cmp_base *base;
};

static int
qcmp_func (struct cmp_data *a, struct cmp_data *b)
{
  struct cmp_base *base = a->base;
  int n = base->n;
  CArray **ca = base->ca;
  int32_t ia = a->i;
  int32_t ib = b->i;
  int result;
  int i;
  for (i=0; i<n; i++) {
    int8_t data_type = ca[i]->data_type;
    char  *ptr = ca[i]->ptr;
    boolean8_t  *m = ( ca[i]->mask ) ? (boolean8_t *) ca[i]->mask->ptr : NULL;
    int32_t bytes = ca[i]->bytes;
    if ( ( ! m ) || 
         ( ( ! m[ia] ) && ( ! m[ib] ) ) ) {
      if ( data_type == CA_FIXLEN ) {
        result = ca_qsort_cmp[CA_FIXLEN](ptr + ia*bytes, 
                                         ptr + ib*bytes, bytes);
      }
      else {
        result = ca_qsort_cmp[data_type](ptr + ia*bytes, 
                                         ptr + ib*bytes);
      }
    }
    else if ( ( ! m[ia] ) && ( m[ib] ) ) {
      result = -1;
    }
    else if ( ( m[ia] ) && ( ! m[ib] ) ) {
      result = 1;
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

/* rdoc:
  # returns index table for index sort
  #
  #   idx = CA.sort_addr(a, b, c)  ### priority a > b > c
  #   a[idx]
  #   b[idx]
  #   c[idx]

  def CA.sort_addr (*args)
  end
*/

static VALUE
rb_ca_s_sort_addr (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE out;
  CArray *co;
  struct cmp_base *base;
  struct cmp_data *data;
  int32_t elements;
  int32_t *q;
  int j;
  int32_t i;
  
  if ( argc <= 0 ) {
    rb_raise(rb_eArgError, "no arg given");
  }

  rb_check_carray_object(argv[0]);
  elements = NUM2LONG(rb_ca_elements(argv[0]));
  
  for (j=0; j<argc; j++) {
    rb_check_carray_object(argv[j]);
    if ( elements != NUM2LONG(rb_ca_elements(argv[j])) ) {
      rb_raise(rb_eArgError, "elements mismatch");
    }
  }

  base = malloc_with_check(sizeof(struct cmp_base));
  base->n = argc;
  base->ca = malloc_with_check(sizeof(CArray *)*base->n);

  for (j=0; j<argc; j++) {
    CArray *ca;
    Data_Get_Struct(argv[j], CArray, ca);
    base->ca[j] = ca;
    ca_attach(ca);
  }

  data = malloc_with_check(sizeof(struct cmp_data)*elements);
  for (i=0; i<elements; i++) {
    data[i].i = i;
    data[i].base = base;
  }

#ifdef HAVE_MERGESORT
  mergesort(data, elements, sizeof(struct cmp_data), 
            (int (*)(const void*,const void*)) qcmp_func);
#else
  qsort(data, elements, sizeof(struct cmp_data),
            (int (*)(const void*,const void*)) qcmp_func);
#endif

  out = rb_ca_template_with_type(argv[0], INT2FIX(CA_INT32), INT2FIX(0));
  Data_Get_Struct(out, CArray, co);
  q = (int32_t *) co->ptr;
  
  for (i=0; i<elements; i++) {
    *q = data[i].i;
    q++;
  }

  for (j=0; j<argc; j++) {
    ca_detach(base->ca[j]);
  }

  free(data);
  free(base->ca);  
  free(base);        

  return out;
}

/* rdoc:
  class CArray
    # returns index table for index sort
    # This method same as,
    #
    #   idx = CA.sort_addr(self, *args) 
    def sort_addr (*args)
    end
  end
*/

static VALUE
rb_ca_sort_addr (int argc, VALUE *argv, VALUE self)
{
  VALUE list = rb_ary_new4(argc, argv);
  rb_ary_unshift(list, self);
  return rb_apply(rb_mCA, rb_intern("sort_addr"), list);
}

void
Init_carray_sort_addr ()
{
  rb_define_singleton_method(rb_mCA, "sort_addr", rb_ca_s_sort_addr, -1);
  rb_define_method(rb_cCArray, "sort_addr", rb_ca_sort_addr, -1);
}
