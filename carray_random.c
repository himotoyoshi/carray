/* ---------------------------------------------------------------------------

  carray_random.c

  This file is part of Ruby/CArray extension library.
  You can redistribute it and/or modify it under the terms of
  the Ruby Licence.

  Copyright (C) 2005 Hiroki Motoyoshi

  This file is partially based on the codes in the following two files:

    * random.c in Ruby distribution ( ruby-1.8.6 )
       Copyright (C) 1993-2003 Yukihiro Matsumoto

    * na_random.c in Ruby/NArray distribution ( narray-0.5.9 )
       (C) Copyright 2003 by Masahiro TANAKA

---------------------------------------------------------------------------- */

#include "carray.h"
#include <math.h>
#include "mt19937ar.h"

static int first = 1;

static VALUE
rb_ca_s_srand(int argc, VALUE *argv, VALUE self)
{
  volatile VALUE seeds;
  unsigned long *init_key;
  int key_length;
  int i;

  if ( argc == 0 ) {
    volatile VALUE limit = ULONG2NUM(0xffffffff), val;
    seeds = rb_ary_new2(4);
    for (i=0; i<4; i++) {
      val = rb_funcall(rb_mKernel, rb_intern("rand"), 1, limit);
      rb_ary_store(seeds, i, val);
    }
  }
  else {
    seeds = rb_ary_new4(argc, argv);
  }

  key_length = RARRAY_LEN(seeds);
  init_key = malloc_with_check(sizeof(unsigned long)*key_length);

  for (i=0; i<key_length; i++) {
    init_key[i] = NUM2ULONG(rb_ary_entry(seeds, i));
  }

  init_by_array(init_key, key_length);

  free(init_key);

  first = 0;

  return Qnil;
}

/* -------------------------------------------------------------------- */

static int
bit_width (uint32_t max)
{
  static uint32_t bits[32] = {
    1, 2, 4, 8, 16, 32, 64, 128, 256,
    512, 1024, 2048, 4096, 8192, 16384, 32768, 65536,
    131072, 262144, 524288, 1048576, 2097152, 4194304,
    8388608, 16777216, 33554432, 67108864, 134217728,
    268435456, 536870912, 1073741824, 2147483648UL
  };
  int i;
  if ( max == 0 ) {
    return 0;
  }
  for (i=0; i<32; i++) {
    if ( max <= bits[i] ) {
      return i+1;
    }
  }
  return 32;
}

static void
ca_monop_random_boolean8_t (int n, char *ptr1, int i1, uint32_t max)
{
  boolean8_t *q1 = (boolean8_t *) ptr1, *p1;
  uint32_t val;
  int32_t k;

  if ( max > 1 ) {
    rb_raise(rb_eArgError, "given maximum number is out of range");
  }

  #ifdef _OPENMP
  #pragma omp parallel for private(p1)
  #endif
  for (k=0; k<n; k++) {
    p1 = q1 + k*i1;
    val = genrand_int32();
    val >>= 31;
    *(int8_t*)p1 = (int8_t) val;
  }
}

static void
ca_monop_random_int8_t (int n, char *ptr1, int i1, uint32_t max)
{
  int8_t *q1 = (int8_t *) ptr1, *p1;
  uint32_t val;
  int shift;
  int32_t k;

  if ( max > 0x80 ) {
    rb_raise(rb_eArgError, "given maximum number is out of range");
  }

  shift = 32 - bit_width(max);

  #ifdef _OPENMP
  #pragma omp parallel for private(p1)
  #endif
  for (k=0; k<n; k++) {
    p1 = q1 + k*i1;
    do {
      val = genrand_int32();
      val >>= shift;
    } while ( val >= max );
    *(int8_t*)p1 = (int8_t) val;
  }
}

static void
ca_monop_random_uint8_t (int n, char *ptr1, int i1, uint32_t max)
{
  uint8_t *q1 = (uint8_t *) ptr1, *p1;
  uint32_t val;
  int shift;
  int32_t k;

  if ( max > 0x100 ) {
    rb_raise(rb_eArgError, "given maximum number is out of range");
  }

  shift = 32 - bit_width(max);

  #ifdef _OPENMP
  #pragma omp parallel for private(p1)
  #endif
  for (k=0; k<n; k++) {
    p1 = q1 + k*i1;
    do {
      val = genrand_int32();
      val >>= shift;
    } while ( val >= max );
    *(uint8_t*)p1 = (uint8_t) val;
  }
}

static void
ca_monop_random_int16_t (int n, char *ptr1, int i1, uint32_t max)
{
  int16_t *q1 = (int16_t *) ptr1, *p1;
  uint32_t val;
  int shift;
  int32_t k;

  if ( max > 0x8000 ) {
    rb_raise(rb_eArgError, "given maximum number is out of range");
  }

  shift = 32 - bit_width(max);

  #ifdef _OPENMP
  #pragma omp parallel for private(p1)
  #endif
  for (k=0; k<n; k++) {
    p1 = q1 + k*i1;
    do {
      val = genrand_int32();
      val >>= shift;
    } while ( val >= max );
    *(int16_t*)p1 = (int16_t) val;
  }
}

static void
ca_monop_random_uint16_t (int n, char *ptr1, int i1, uint32_t max)
{
  uint16_t *q1 = (uint16_t *) ptr1, *p1;
  uint32_t val;
  int shift;
  int32_t k;

  if ( max > 0x10000 ) {
    rb_raise(rb_eArgError, "given maximum number is out of range");
  }

  shift = 32 - bit_width(max);

  #ifdef _OPENMP
  #pragma omp parallel for private(p1)
  #endif
  for (k=0; k<n; k++) {
    p1 = q1 + k*i1;
    do {
      val = genrand_int32();
      val >>= shift;
    } while ( val >= max );
    *(uint16_t*)p1 = (uint16_t) val;
  }
}


static void
ca_monop_random_int32_t (int n, char *ptr1, int i1, uint32_t max)
{
  int32_t *q1 = (int32_t *) ptr1, *p1;
  uint32_t val;
  int shift;
  int32_t k;

  if ( max > 0x80000000 ) {
    rb_raise(rb_eArgError, "given maximum number is out of range");
  }

  shift = 32 - bit_width(max);

  #ifdef _OPENMP
  #pragma omp parallel for private(p1)
  #endif
  for (k=0; k<n; k++) {
    p1 = q1 + k*i1;
    do {
      val = genrand_int32();
      val >>= shift;
    } while ( val >= max );
    *(int32_t*)p1 = (int32_t) val;
  }
}

static void
ca_monop_random_uint32_t (int n, char *ptr1, int i1, double max)
{
  uint32_t *q1 = (uint32_t *) ptr1, *p1;
  uint32_t val;
  int shift;
  int32_t k;

  if ( max > 4294967296.0 ) { /* 0x100000000 */
    rb_raise(rb_eArgError, "given maximum number is out of range");
  }

  if ( max > 4294967295.0 ) { /* 0xffffffff */
    shift = 0;
  }
  else {
    shift = 32 - bit_width((uint32_t) max);
  }

  #ifdef _OPENMP
  #pragma omp parallel for private(p1)
  #endif
  for (k=0; k<n; k++) {
    p1 = q1 + k*i1;
    do {
      val = genrand_int32();
      val >>= shift;
    } while ( val >= max );
    *(uint32_t*)p1 = (uint32_t) val;
  }
}

static void
ca_monop_random_float32_t(int n, char *ptr1, int i1, double rmax)
{
  float32_t *q1 = (float32_t *) ptr1, *p1;
  int32_t k;
  #ifdef _OPENMP
  #pragma omp parallel for private(p1)
  #endif
  for (k=0; k<n; k++) {
    p1 = q1 + k*i1;
    *(float32_t*)p1 = genrand_real2() * rmax;
  }
}

static void
ca_monop_random_float64_t(int n, char *ptr1, int i1, double rmax)
{
  float64_t *q1 = (float64_t *) ptr1, *p1;
  int32_t k;
  #ifdef _OPENMP
  #pragma omp parallel for private(p1)
  #endif
  for (k=0; k<n; k++) {
    p1 = q1 + k*i1;
    *(float64_t*)p1 = genrand_res53() * rmax;
  }
}

#ifdef HAVE_COMPLEX_H

static void
ca_monop_random_cmplx64_t(int n, char *ptr1, int i1, double rmax, double imax)
{
  cmplx64_t *q1 = (cmplx64_t *) ptr1, *p1;
  int32_t k;
  #ifdef _OPENMP
  #pragma omp parallel for private(p1)
  #endif
  for (k=0; k<n; k++) {
    p1 = q1 + k*i1;
    *(cmplx64_t*)p1 = genrand_real2() * rmax + I * (genrand_real2() * rmax);
  }
}

static void
ca_monop_random_cmplx128_t(int n, char *ptr1, int i1, double rmax, double imax)
{
  cmplx128_t *q1 = (cmplx128_t *) ptr1, *p1;
  int32_t k;
  #ifdef _OPENMP
  #pragma omp parallel for private(p1)
  #endif
  for (k=0; k<n; k++) {
    p1 = q1 + k*i1;
    *(cmplx128_t*)p1 = genrand_res53() * rmax + I * (genrand_res53() * rmax);
  }
}

#endif

ca_monop_func_t
ca_monop_random[CA_NTYPE] = {
  ca_monop_not_implement,
  ca_monop_random_boolean8_t,
  ca_monop_random_int8_t,
  ca_monop_random_uint8_t,
  ca_monop_random_int16_t,
  ca_monop_random_uint16_t,
  ca_monop_random_int32_t,
  ca_monop_random_uint32_t,
  ca_monop_not_implement, /* ca_monop_random_int64_t, */
  ca_monop_not_implement, /* ca_monop_random_uint64_t, */
  ca_monop_random_float32_t,
  ca_monop_random_float64_t,
  ca_monop_not_implement, /* ca_monop_random_float128_t, */
#ifdef HAVE_COMPLEX_H
  ca_monop_random_cmplx64_t,
  ca_monop_random_cmplx128_t,
  ca_monop_not_implement, /* ca_monop_random_cmplx256_t, */
#else
  ca_monop_not_implement,
  ca_monop_not_implement,
  ca_monop_not_implement,
#endif
  ca_monop_not_implement,
};

/* rdoc:
  class CArray
    def random! (max=1.0)
    end
  end
*/

static VALUE
rb_ca_random (int argc, VALUE *argv, VALUE self)
{
  VALUE  rrmax, rimax = Qnil;
  CArray *ca;
  double rmax, imax = 1;

  rb_ca_modify(self);

  Data_Get_Struct(self, CArray, ca);

  if ( ca_is_object_type(ca) ) {
    CArray *dmy;
    VALUE  *p;
    int i;

    rb_scan_args(argc, argv, "01", &rrmax);
    if ( NIL_P(rrmax) ) {
      rrmax = rb_float_new(1.0);
    }

    ca_clear_mask(ca);

    ca_attach(ca);

    if ( rb_obj_is_kind_of(rrmax, rb_cInteger) ) {
      int32_t *q;
      rmax = (double)NUM2INT(rrmax);
      dmy = carray_new(CA_INT32, ca->rank, ca->dim, ca->bytes, NULL);
      (*ca_monop_random[dmy->data_type])(dmy->elements,
                                      dmy->ptr, 1, (uint32_t)rmax);
      p = (VALUE *)ca->ptr;
      q = (int32_t *)dmy->ptr;
      for (i=0; i<ca->elements; i++) {
        *p = INT2NUM(*q);
        p++; q++;
      }
    }
    else if ( rb_obj_is_kind_of(rrmax, rb_cFloat) ) {
      float64_t *q;
      rmax = NUM2DBL(rrmax);
      dmy = carray_new(CA_FLOAT64, ca->rank, ca->dim, ca->bytes, NULL);
      (*ca_monop_random[dmy->data_type])(dmy->elements,
                                      dmy->ptr, 1, rmax);
      p = (VALUE *)ca->ptr;
      q = (float64_t *)dmy->ptr;
      for (i=0; i<ca->elements; i++) {
        *p = rb_float_new(*q);
        p++; q++;
      }
    }
    else {
      rb_raise(rb_eArgError,
               "maximum number should be an integer or a float number");
    }

    ca_sync(ca);
    ca_detach(ca);

    ca_free(dmy);

    return self;
  }

  rb_scan_args(argc, argv, "02", &rrmax, &rimax);

  if ( first ) {
    rb_ca_s_srand(0, NULL, rb_cCArray);
  }

  rmax = ( NIL_P(rrmax) ) ? 1.0 : NUM2DBL(rrmax);
  imax = ( NIL_P(rimax) ) ? rmax : NUM2DBL(rimax);

  if ( isinf(rmax) || isnan(rmax) || isinf(imax) || isnan(imax) ) {
    rb_raise(rb_eArgError,
             "maximum number should be finite");
  }

  if ( rmax < 0 || imax < 0 ) {
    rb_raise(rb_eArgError,
             "maximum number should be positive");
  }

  ca_clear_mask(ca);
  ca_attach(ca);

  switch ( ca->data_type ) {
  case CA_CMPLX64:
  case CA_CMPLX128:
    if ( rmax < 0 || imax < 0 ) {
      rb_raise(rb_eArgError,
               "maximum number should be positive");
    }
    (*ca_monop_random[ca->data_type])(ca->elements,
                                      ca->ptr, 1, rmax, imax);
    break;
  case CA_UINT32:
  case CA_FLOAT32:
  case CA_FLOAT64:
    if ( rmax < 0 ) {
      rb_raise(rb_eArgError,
               "maximum number should be positive");
    }
    (*ca_monop_random[ca->data_type])(ca->elements,
                                      ca->ptr, 1, rmax);
    break;
  default:
    if ( rmax < 1 ) {
      rb_raise(rb_eArgError,
               "maximum number should be positive");
    }
    (*ca_monop_random[ca->data_type])(ca->elements,
                                      ca->ptr, 1, (uint32_t)rmax);
  }

  ca_sync(ca);
  ca_detach(ca);

  return self;
}

void
ca_check_rand_init ()
{
  if ( first ) {
    rb_ca_s_srand(0, NULL, rb_cCArray);
  }
}

int32_t
ca_rand (double rmax)
{
  uint32_t val;
  int shift;

  ca_check_rand_init();

  if ( rmax < 0 || rmax > 0x7fffffff ) {
    rb_raise(rb_eArgError,
             "given maximum number is out of range");
  }

  shift = 32 - bit_width((uint32_t)rmax);

  do {
    val = genrand_int32();
    val >>= shift;
  } while ( val >= (uint32_t) rmax );

  return (int32_t) val;
}

void
Init_carray_random()
{
  rb_define_singleton_method(rb_cCArray,"srand", rb_ca_s_srand,-1);
  rb_define_method(rb_cCArray, "random!", rb_ca_random, -1);
}

