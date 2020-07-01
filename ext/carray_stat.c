/* ---------------------------------------------------------------------------

  carray_stat.c

  This file is part of Ruby/CArray extension library.
  You can redistribute it and/or modify it under the terms of
  the Ruby Licence.

  Copyright (C) 2005 Hiroki Motoyoshi

---------------------------------------------------------------------------- */

#include "ruby.h"
#include "carray.h"
#include <math.h>
#include <float.h>
#include <stdarg.h>

#define MIN(x,y) ((x) < (y) ? (x) : (y))
#define MAX(x,y) ((x) > (y) ? (x) : (y))

/* ----------------------------------------------------------------- */

#define proc_cummin(type, from, conv) \
  { \
    type *ptr = (type *) ca->ptr; \
    type *q   = (type *) co->ptr; \
    boolean8_t *m = (ca->mask) ? (boolean8_t*) ca->mask->ptr : NULL; \
    boolean8_t *n = NULL; \
    type fval = ( ! NIL_P(rfval) ) ? (type) from(rfval) : (type)(0.0); \
    type min  = *ptr; \
    type val; \
    ca_size_t count = 0; \
    ca_size_t i; \
    if ( m ) { \
      count = 0; \
      ca_create_mask(co); \
      n = (boolean8_t*) co->mask->ptr; \
      for (i=ca->elements; i; i--, ptr++) { \
        if ( ! *m++ ) { \
          min = *ptr; \
          break; \
        } \
      } \
      ptr = (type *) ca->ptr; \
      m = (boolean8_t*) ca->mask->ptr; \
      count = 0; \
      for (i=ca->elements; i; i--, ptr++, q++, m++, n++) { \
        if ( ! *m ) { \
          val = *ptr; \
          if ( min > val )      { \
            min = val; \
          } \
        } \
        else { \
          count++; \
        } \
        if ( ( ! NIL_P(rmin_count) ) && count > min_count ) {   \
          if ( NIL_P(rfval) ) { \
            *n = 1; \
          } \
          else {\
            *q = fval; \
          }\
        } \
        else  { \
          *q = min; \
        } \
      } \
    } \
    else { \
      for (i=ca->elements; i; i--, ptr++, q++) {\
        val = *ptr; \
        if ( min > val ) { \
          min = val; \
        } \
        *q = min; \
      } \
    } \
  }


static VALUE
rb_ca_cummin (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE rmin_count = Qnil, rfval = Qnil, obj;
  CArray *ca, *co;
  ca_size_t min_count;

  if ( argc > 0 ) {
    rb_scan_args(argc, argv, "02", (VALUE *) &rmin_count, (VALUE *) &rfval);
  }

  Data_Get_Struct(self, CArray, ca);

  co = ca_template(ca);
  obj = ca_wrap_struct(co);

  min_count = ( NIL_P(rmin_count) || ! ca_has_mask(ca) ) ?
                                  ca->elements - 1 : NUM2SIZE(rmin_count);

  if ( min_count < 0 ) {
    min_count += ca->elements;
  }

  ca_attach(ca);

  switch ( ca->data_type ) {
  case CA_BOOLEAN:
  case CA_INT8:     proc_cummin(int8_t,     NUM2LONG,);   break;
  case CA_UINT8:    proc_cummin(uint8_t,   NUM2ULONG,);  break;
  case CA_INT16:    proc_cummin(int16_t,    NUM2LONG,);   break;
  case CA_UINT16:   proc_cummin(uint16_t,  NUM2ULONG,);  break;
  case CA_INT32:    proc_cummin(int32_t,    NUM2LONG,);   break;
  case CA_UINT32:   proc_cummin(uint32_t,  NUM2ULONG,);  break;
  case CA_INT64:    proc_cummin(int64_t,    NUM2LL,);     break;
  case CA_UINT64:   proc_cummin(uint64_t,  NUM2ULL,);    break;
  case CA_FLOAT32:  proc_cummin(float32_t,  NUM2DBL,);    break;
  case CA_FLOAT64:  proc_cummin(float64_t,  NUM2DBL,);    break;
  case CA_FLOAT128: proc_cummin(float128_t, NUM2DBL,);    break;
  case CA_OBJECT:   proc_cummin(VALUE, NUM2DBL, NUM2DBL); break;
  default: rb_raise(rb_eRuntimeError, "invalid data type");
  }

  ca_detach(ca);

  return obj;
}

/* ------------------------------------------------------------------- */

#define proc_cummax(type, from, conv) \
  { \
    type *ptr = (type *) ca->ptr; \
    type *q   = (type *) co->ptr; \
    boolean8_t *m = (ca->mask) ? (boolean8_t*) ca->mask->ptr : NULL; \
    boolean8_t *n = NULL; \
    type fval = ( ! NIL_P(rfval) ) ? (type) from(rfval) : (type)(0.0); \
    type max  = *ptr; \
    type val; \
    ca_size_t count = 0; \
    ca_size_t i; \
    if ( m ) { \
      count = 0; \
      ca_create_mask(co); \
      n = (boolean8_t*) co->mask->ptr; \
      for (i=ca->elements; i; i--, ptr++) { \
        if ( ! *m++ ) { \
          max = *ptr; \
          break; \
        } \
      } \
      ptr = (type *) ca->ptr; \
      m = (boolean8_t*) ca->mask->ptr; \
      count = 0; \
      for (i=ca->elements; i; i--, ptr++, q++, m++, n++) { \
        if ( ! *m ) { \
          val = *ptr; \
          if ( max < val )      { \
            max = val; \
          } \
        } \
        else { \
          count++; \
        } \
        if ( ( ! NIL_P(rmin_count) ) && count > min_count ) {   \
          if ( NIL_P(rfval) ) { \
            *n = 1; \
          } \
          else {\
            *q = fval; \
          }\
        } \
        else  { \
          *q = max; \
        } \
      } \
    } \
    else { \
      for (i=ca->elements; i; i--, ptr++, q++) {\
        val = *ptr; \
        if ( max < val ) { \
          max = val; \
        } \
        *q = max; \
      } \
    } \
  }

static VALUE
rb_ca_cummax (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE rmin_count = Qnil, rfval = Qnil, obj;
  CArray *ca, *co;
  ca_size_t min_count;

  if ( argc > 0 ) {
    rb_scan_args(argc, argv, "02", (VALUE *) &rmin_count, (VALUE *) &rfval);
  }

  Data_Get_Struct(self, CArray, ca);

  co = ca_template(ca);
  obj = ca_wrap_struct(co);

  min_count = ( NIL_P(rmin_count) || ! ca_has_mask(ca) ) ?
                                  ca->elements - 1 : NUM2SIZE(rmin_count);

  if ( min_count < 0 ) {
    min_count += ca->elements;
  }

  ca_attach(ca);

  switch ( ca->data_type ) {
  case CA_BOOLEAN:
  case CA_INT8:     proc_cummax(int8_t, NUM2LONG,);       break;
  case CA_UINT8:    proc_cummax(uint8_t, NUM2ULONG,);     break;
  case CA_INT16:    proc_cummax(int16_t, NUM2LONG,);      break;
  case CA_UINT16:   proc_cummax(uint16_t, NUM2ULONG,);    break;
  case CA_INT32:    proc_cummax(int32_t, NUM2LONG,);      break;
  case CA_UINT32:   proc_cummax(uint32_t, NUM2ULONG,);    break;
  case CA_INT64:    proc_cummax(int64_t, NUM2LL,);      break;
  case CA_UINT64:   proc_cummax(uint64_t, NUM2ULL,);    break;
  case CA_FLOAT32:  proc_cummax(float32_t, NUM2DBL,);    break;
  case CA_FLOAT64:  proc_cummax(float64_t, NUM2DBL,);    break;
  case CA_FLOAT128: proc_cummax(float128_t, NUM2DBL,);   break;
  case CA_OBJECT:   proc_cummax(VALUE, NUM2DBL, NUM2DBL); break;
  default: rb_raise(rb_eRuntimeError, "invalid data type");
  }

  ca_detach(ca);

  return obj;
}


/* ------------------------------------------------------------------- */

#define proc_cumprod(type, atype, from, conv) \
  { \
    type *ptr = (type *) ca->ptr; \
    atype *q   = (atype *) co->ptr; \
    boolean8_t *m = (ca->mask) ? (boolean8_t*) ca->mask->ptr : NULL; \
    boolean8_t *n = NULL; \
    atype fval = ( ! NIL_P(rfval) ) ? (type) from(rfval) : (atype)(0.0); \
    atype prod  = (atype)(1.0); \
    ca_size_t count = 0; \
    ca_size_t i; \
    if ( m ) { \
      count = 0; \
      ca_create_mask(co); \
      n = (boolean8_t*) co->mask->ptr; \
      for (i=ca->elements; i; i--, ptr++, q++, m++, n++) { \
        if ( ! *m ) { \
          prod *= (atype)conv(*ptr); \
        } \
        else { \
          count++; \
        } \
        if ( ( ! NIL_P(rmin_count) ) && count > min_count ) {   \
          if ( NIL_P(rfval) ) { \
            *n = 1; \
          } \
          else {\
            *q = fval; \
          }\
        } \
        else  { \
          *q = prod; \
        } \
      } \
    } \
    else { \
      for (i=ca->elements; i; i--, ptr++, q++) {\
        prod *= (atype)conv(*ptr); \
        *q = prod; \
      } \
    } \
  }

static VALUE
rb_ca_cumprod (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE rmin_count = Qnil, rfval = Qnil;
  CArray *ca, *co;
  ca_size_t min_count;

  if ( argc > 0 ) {
    rb_scan_args(argc, argv, "02", (VALUE *) &rmin_count, (VALUE *) &rfval);
  }

  Data_Get_Struct(self, CArray, ca);

  if ( ca_is_complex_type(ca) ) {
    co = carray_new(CA_CMPLX128, ca->ndim, ca->dim, 0, NULL);
  }
  else {
    co = carray_new(CA_FLOAT64, ca->ndim, ca->dim, 0, NULL);
  }

  min_count = ( NIL_P(rmin_count) || ! ca_has_mask(ca) ) ?
                                  ca->elements - 1 : NUM2SIZE(rmin_count);

  if ( min_count < 0 ) {
    min_count += ca->elements;
  }

  ca_attach(ca);

  switch ( ca->data_type ) {
  case CA_BOOLEAN:
  case CA_INT8:     proc_cumprod(int8_t, double, NUM2DBL,);       break;
  case CA_UINT8:    proc_cumprod(uint8_t, double, NUM2DBL,);     break;
  case CA_INT16:    proc_cumprod(int16_t, double, NUM2DBL,);      break;
  case CA_UINT16:   proc_cumprod(uint16_t, double, NUM2DBL,);    break;
  case CA_INT32:    proc_cumprod(int32_t, double, NUM2DBL,);      break;
  case CA_UINT32:   proc_cumprod(uint32_t, double, NUM2DBL,);    break;
  case CA_INT64:    proc_cumprod(int64_t, double, NUM2DBL,);      break;
  case CA_UINT64:   proc_cumprod(uint64_t, double, NUM2DBL,);    break;
  case CA_FLOAT32:  proc_cumprod(float32_t, double, NUM2DBL,);    break;
  case CA_FLOAT64:  proc_cumprod(float64_t, double, NUM2DBL,);    break;
  case CA_FLOAT128: proc_cumprod(float128_t, double, NUM2DBL,);   break;
#ifdef HAVE_COMPLEX_H
  case CA_CMPLX64:  proc_cumprod(cmplx64_t, cmplx128_t, NUM2CC,);  break;
  case CA_CMPLX128: proc_cumprod(cmplx128_t, cmplx128_t, NUM2CC,); break;
  case CA_CMPLX256: proc_cumprod(cmplx256_t, cmplx128_t, NUM2CC,); break;
#endif
  case CA_OBJECT:   proc_cumprod(VALUE, double, NUM2DBL, NUM2DBL); break;
  default: rb_raise(rb_eRuntimeError, "invalid data type");
  }

  ca_detach(ca);

  return ca_wrap_struct(co);
}


/* ----------------------------------------------------------------- */

#define proc_wsum(type, atype, conv, to) \
  { \
    type *p1 = (type*)ca->ptr; \
    type *p2; \
    ca_size_t  s2; \
    boolean8_t *m = (ca->mask) ? (boolean8_t*) ca->mask->ptr : NULL; \
    atype sum  = 0.0; \
    ca_size_t count = 0; \
    ca_size_t i; \
    ca_set_iterator(1, cw, &p2, &s2); \
    if ( m ) { \
      count = 0; \
      for (i=ca->elements; i; i--, p1++, p2+=s2) { \
        if ( ! *m++ ) { \
          sum += (atype)conv(*p1) * (atype)conv(*p2); \
        } \
        else { \
          count++; \
        } \
      } \
    } \
    else { \
      for (i=ca->elements; i; i--, p1++, p2+=s2) { \
        sum += (atype)conv(*p1) * (atype)conv(*p2); \
      } \
    } \
    if ( ( ! NIL_P(rmin_count) ) && count > min_count )     {   \
      out = ( NIL_P(rfval) ) ? CA_UNDEF : rfval;\
    } \
    else { \
      out = to(sum); \
    } \
  }

static VALUE
rb_ca_wsum (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE out, weight = argv[0], rmin_count = Qnil, rfval = Qnil, tmp;
  CArray *ca, *cw;
  ca_size_t min_count;

  if ( argc > 1 ) {
    rb_scan_args(argc, argv, "12", (VALUE *) &weight, (VALUE *) &rmin_count, (VALUE *) &rfval);
  }

  Data_Get_Struct(self, CArray, ca);
  cw = ca_wrap_readonly(weight, ca->data_type);

  ca_check_same_elements(ca, cw);

  if ( ca->elements == 0 ) {
    return ( NIL_P(rfval) ) ? CA_UNDEF : rfval;
  }

  if ( ca_has_mask(cw) ) {
    ca = ca_copy(ca);
    tmp = ca_wrap_struct(ca);
    ca_copy_mask_overlay(ca, ca->elements, 1, cw);
  }

  min_count = ( NIL_P(rmin_count) || ( ! ca_has_mask(ca) ) ) ?
                                   ca->elements - 1 : NUM2SIZE(rmin_count);

  if ( min_count < 0 ) {
    min_count += ca->elements;
  }

  ca_attach_n(2, ca, cw);

  switch ( ca->data_type ) {
  case CA_BOOLEAN:
  case CA_INT8:     proc_wsum(int8_t, double,,rb_float_new);       break;
  case CA_UINT8:    proc_wsum(uint8_t,double,,rb_float_new);     break;
  case CA_INT16:    proc_wsum(int16_t,double,,rb_float_new);      break;
  case CA_UINT16:   proc_wsum(uint16_t,double,,rb_float_new);    break;
  case CA_INT32:    proc_wsum(int32_t,double,,rb_float_new);      break;
  case CA_UINT32:   proc_wsum(uint32_t,double,,rb_float_new);    break;
  case CA_INT64:    proc_wsum(int64_t,double,,rb_float_new);      break;
  case CA_UINT64:   proc_wsum(uint64_t,double,,rb_float_new);    break;
  case CA_FLOAT32:  proc_wsum(float32_t,double,,rb_float_new);    break;
  case CA_FLOAT64:  proc_wsum(float64_t,double,,rb_float_new);    break;
  case CA_FLOAT128: proc_wsum(float128_t,double,,rb_float_new);   break;
#ifdef HAVE_COMPLEX_H
  case CA_CMPLX64:  proc_wsum(cmplx64_t,cmplx128_t,,rb_ccomplex_new); break;
  case CA_CMPLX128: proc_wsum(cmplx128_t,cmplx128_t,,rb_ccomplex_new); break;
  case CA_CMPLX256: proc_wsum(cmplx256_t,cmplx128_t,,rb_ccomplex_new); break;
#endif
  case CA_OBJECT:   proc_wsum(VALUE,double,NUM2DBL,rb_float_new); break;
  default: rb_raise(rb_eRuntimeError, "invalid data type");
  }

  ca_detach_n(2, ca, cw);

  return out;
}

/* ------------------------------------------------------------------- */

#define proc_cumwsum(type, atype, from, conv) \
  { \
    type *p1 = (type *) ca->ptr; \
    type *p2; \
    ca_size_t  s2; \
    atype *q   = (atype *) co->ptr; \
    boolean8_t *m = (ca->mask) ? (boolean8_t*) ca->mask->ptr : NULL; \
    boolean8_t *n = NULL; \
    atype fval = ( ! NIL_P(rfval) ) ? (type) from(rfval) : (atype)(0.0); \
    atype sum  = 0.0; \
    ca_size_t count = 0; \
    ca_size_t i; \
    ca_set_iterator(1, cw, &p2, &s2); \
    if ( m ) { \
      count = 0; \
      ca_create_mask(co); \
      n = (boolean8_t*) co->mask->ptr; \
      for (i=ca->elements; i; i--, p1++, p2+=s2, q++, m++, n++) {\
        if ( ! *m ) { \
          sum += (atype)conv(*p1) * (atype)conv(*p2); \
        } \
        else { \
          count++; \
        } \
        if ( ( ! NIL_P(rmin_count) ) && count > min_count ) {   \
          if ( NIL_P(rfval) ) { \
            *n = 1; \
          } \
          else {\
            *q = fval; \
          }\
        } \
        else  { \
          *q = sum; \
        } \
      } \
    } \
    else { \
      for (i=ca->elements; i; i--, p1++, p2+=s2, q++) { \
        sum += (atype)conv(*p1) * (atype)conv(*p2); \
        *q = sum; \
      } \
    } \
  }

static VALUE
rb_ca_cumwsum (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE weight = argv[0], rmin_count = Qnil, rfval = Qnil, tmp;
  CArray *ca, *cw, *co;
  ca_size_t min_count;

  if ( argc > 1 ) {
    rb_scan_args(argc, argv, "12", (VALUE *) &weight, (VALUE *)  &rmin_count, (VALUE *)  &rfval);
  }

  Data_Get_Struct(self, CArray, ca);
  cw = ca_wrap_readonly(weight, ca->data_type);

  ca_check_same_elements(ca, cw);

  if ( ca_has_mask(cw) ) {
    ca = ca_copy(ca);
    tmp = ca_wrap_struct(ca);
    ca_copy_mask_overlay(ca, ca->elements, 1, cw);
  }

  if ( ca_is_complex_type(ca) ) {
    co = carray_new(CA_CMPLX128, ca->ndim, ca->dim, 0, NULL);
  }
  else {
    co = carray_new(CA_FLOAT64, ca->ndim, ca->dim, 0, NULL);
  }

  min_count = ( NIL_P(rmin_count) || ( ! ca_has_mask(ca) ) ) ?
                                   ca->elements - 1 : NUM2SIZE(rmin_count);

  if ( min_count < 0 ) {
    min_count += ca->elements;
  }

  ca_attach(ca);

  switch ( ca->data_type ) {
  case CA_BOOLEAN:
  case CA_INT8:     proc_cumwsum(int8_t, double, NUM2DBL,);       break;
  case CA_UINT8:    proc_cumwsum(uint8_t, double, NUM2DBL,);     break;
  case CA_INT16:    proc_cumwsum(int16_t, double, NUM2DBL,);      break;
  case CA_UINT16:   proc_cumwsum(uint16_t, double, NUM2DBL,);    break;
  case CA_INT32:    proc_cumwsum(int32_t, double, NUM2DBL,);      break;
  case CA_UINT32:   proc_cumwsum(uint32_t, double, NUM2DBL,);    break;
  case CA_INT64:    proc_cumwsum(int64_t, double, NUM2DBL,);      break;
  case CA_UINT64:   proc_cumwsum(uint64_t, double, NUM2DBL,);    break;
  case CA_FLOAT32:  proc_cumwsum(float32_t, double, NUM2DBL,);    break;
  case CA_FLOAT64:  proc_cumwsum(float64_t, double, NUM2DBL,);    break;
  case CA_FLOAT128: proc_cumwsum(float128_t, double, NUM2DBL,);   break;
#ifdef HAVE_COMPLEX_H
  case CA_CMPLX64:  proc_cumwsum(cmplx64_t, cmplx128_t, NUM2CC,);  break;
  case CA_CMPLX128: proc_cumwsum(cmplx128_t, cmplx128_t, NUM2CC,); break;
  case CA_CMPLX256: proc_cumwsum(cmplx256_t, cmplx128_t, NUM2CC,); break;
#endif
  case CA_OBJECT:   proc_cumwsum(VALUE, double, NUM2DBL, NUM2DBL); break;
  default: rb_raise(rb_eRuntimeError, "invalid data type");
  }

  ca_detach(ca);

  return ca_wrap_struct(co);
}

/* ----------------------------------------------------------------- */

#define proc_wmean(type, atype, conv, to) \
  { \
    type *p1 = (type*)ca->ptr; \
    type *p2 = (type*)cw->ptr; \
    ca_size_t   s2; \
    boolean8_t *m = (ca->mask) ? (boolean8_t*) ca->mask->ptr : NULL; \
    atype sum = 0.0; \
    atype den = 0.0; \
    atype ave; \
    ca_size_t count = 0; \
    ca_size_t i; \
    ca_set_iterator(1, cw, &p2, &s2); \
    if ( m ) { \
      count = 0; \
      for (i=ca->elements; i; i--, p1++, p2+=s2) { \
        if ( ! *m++ ) { \
          sum += (atype)conv(*p1) * (atype)conv(*p2); \
          den += (atype)conv(*p2); \
        } \
        else { \
          count++; \
        } \
      } \
    } \
    else { \
      for (i=ca->elements; i; i--, p1++, p2+=s2) { \
        sum += (atype)conv(*p1) * (atype)conv(*p2); \
        den += (atype)conv(*p2); \
      } \
    } \
    if ( ( ! NIL_P(rmin_count) ) && count > min_count ) \
      out = ( NIL_P(rfval) ) ? CA_UNDEF : rfval; \
    else { \
      ave = sum / den; \
      out = to(ave); \
    } \
  }

static VALUE
rb_ca_wmean (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE out, weight = argv[0], rmin_count = Qnil, rfval = Qnil, tmp;
  CArray *ca, *cw;
  ca_size_t min_count;

  if ( argc > 1 ) {
    rb_scan_args(argc, argv, "12", (VALUE *) &weight, (VALUE *) &rmin_count, (VALUE *) &rfval);
  }

  Data_Get_Struct(self, CArray, ca);
  cw = ca_wrap_readonly(weight, ca->data_type);

  ca_check_same_elements(ca, cw);

  if ( ca->elements == 0 ) {
    return ( NIL_P(rfval) ) ? CA_UNDEF : rfval;
  }

  if ( ca_has_mask(cw) ) {
    ca = ca_copy(ca);
    tmp = ca_wrap_struct(ca);
    ca_copy_mask_overlay(ca, ca->elements, 1, cw);
  }

  min_count = ( NIL_P(rmin_count) || ( ! ca_has_mask(ca) ) ) ?
                                   ca->elements - 1 : NUM2SIZE(rmin_count);

  if ( min_count < 0 ) {
    min_count += ca->elements;
  }

  ca_attach_n(2, ca, cw);

  switch ( ca->data_type ) {
  case CA_BOOLEAN:
  case CA_INT8:     proc_wmean(int8_t, double,,rb_float_new);       break;
  case CA_UINT8:    proc_wmean(uint8_t,double,,rb_float_new);     break;
  case CA_INT16:    proc_wmean(int16_t,double,,rb_float_new);      break;
  case CA_UINT16:   proc_wmean(uint16_t,double,,rb_float_new);    break;
  case CA_INT32:    proc_wmean(int32_t,double,,rb_float_new);      break;
  case CA_UINT32:   proc_wmean(uint32_t,double,,rb_float_new);    break;
  case CA_INT64:    proc_wmean(int64_t,double,,rb_float_new);      break;
  case CA_UINT64:   proc_wmean(uint64_t,double,,rb_float_new);    break;
  case CA_FLOAT32:  proc_wmean(float32_t,double,,rb_float_new);    break;
  case CA_FLOAT64:  proc_wmean(float64_t,double,,rb_float_new);    break;
  case CA_FLOAT128: proc_wmean(float128_t,double,,rb_float_new);   break;
#ifdef HAVE_COMPLEX_H
  case CA_CMPLX64:  proc_wmean(cmplx64_t,cmplx128_t,,rb_ccomplex_new); break;
  case CA_CMPLX128: proc_wmean(cmplx128_t,cmplx128_t,,rb_ccomplex_new); break;
  case CA_CMPLX256: proc_wmean(cmplx256_t,cmplx128_t,,rb_ccomplex_new); break;
#endif
  case CA_OBJECT:   proc_wmean(VALUE,double,NUM2DBL,rb_float_new); break;
  default: rb_raise(rb_eRuntimeError, "invalid data type");
  }

  ca_detach_n(2, ca, cw);

  return out;
}

/* ----------------------------------------------------------------- */

#define proc_variancep(type,from) \
  { \
    type *ptr = (type *) ca->ptr; \
    boolean8_t *m = (ca->mask) ? (boolean8_t*) ca->mask->ptr : NULL; \
    double sum  = 0.0; \
    double sum2 = 0.0; \
    double del, var, ave; \
    ca_size_t count = 0; \
    ca_size_t nvalid; \
    ca_size_t i; \
    if ( m ) { \
      count = 0; \
      for (i=ca->elements; i; i--, ptr++) { \
        if ( ! *m++ ) { \
          sum += (double)from(*ptr); \
        } \
        else { \
          count++; \
        } \
      } \
      nvalid = ca->elements - count; \
    } \
    else { \
      for (i=ca->elements; i; i--, ptr++) { \
        sum += (double)from(*ptr); \
      } \
      nvalid = ca->elements; \
    } \
    if ( ( ! NIL_P(rmin_count) ) && count > min_count ) {       \
      out = ( NIL_P(rfval) ) ? CA_UNDEF : rfval; \
      break; \
    } \
    ave = sum / ((double) nvalid); \
    ptr = (type *) ca->ptr; \
    m = (ca->mask) ? (boolean8_t*) ca->mask->ptr : NULL; \
    if ( m ) { \
      for (i=ca->elements; i; i--, ptr++) { \
        if ( ! *m++ ) { \
          del = ((double)from(*ptr)) - ave; \
          sum2 += del*del; \
        } \
      } \
    } \
    else { \
      for (i=ca->elements; i; i--, ptr++) { \
        del = ((double)from(*ptr)) - ave; \
        sum2 += del*del; \
      } \
    } \
    var = sum2 / ((double) nvalid); \
    out = rb_float_new(var); \
  }

static VALUE
rb_ca_variancep (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE out, rmin_count = Qnil, rfval = Qnil;
  CArray *ca;
  ca_size_t min_count;

  if ( argc > 0 ) {
    rb_scan_args(argc, argv, "02", (VALUE *) &rmin_count, (VALUE *) &rfval);
  }

  Data_Get_Struct(self, CArray, ca);

  if ( ca->elements == 0 ) {
    return ( NIL_P(rfval) ) ? CA_UNDEF : rfval;
  }

  min_count = ( NIL_P(rmin_count) || ! ca_has_mask(ca) ) ?
                                     ca->elements - 1 : NUM2SIZE(rmin_count);

  if ( min_count < 0 ) {
    min_count += ca->elements;
  }

  ca_attach(ca);

  switch ( ca->data_type ) {
  case CA_BOOLEAN:
  case CA_INT8:    proc_variancep(int8_t,);    break;
  case CA_UINT8:   proc_variancep(uint8_t,);  break;
  case CA_INT16:   proc_variancep(int16_t,);   break;
  case CA_UINT16:  proc_variancep(uint16_t,); break;
  case CA_INT32:   proc_variancep(int32_t,);   break;
  case CA_UINT32:  proc_variancep(uint32_t,); break;
  case CA_INT64:   proc_variancep(int64_t,);   break;
  case CA_UINT64:  proc_variancep(uint64_t,); break;
  case CA_FLOAT32: proc_variancep(float32_t,); break;
  case CA_FLOAT64: proc_variancep(float64_t,); break;
  case CA_FLOAT128: proc_variancep(float128_t,); break;
  case CA_OBJECT:  proc_variancep(VALUE,NUM2DBL); break;
  default: rb_raise(rb_eRuntimeError, "invalid data type");
  }

  ca_detach(ca);

  return out;
}

/* ----------------------------------------------------------------- */

#define proc_variance(type,from) \
  { \
    type *ptr = (type *) ca->ptr; \
    boolean8_t *m = (ca->mask) ? (boolean8_t*) ca->mask->ptr : NULL; \
    double sum  = 0.0; \
    double sum2 = 0.0; \
    double del, var, ave; \
    ca_size_t count = 0; \
    ca_size_t nvalid; \
    ca_size_t i; \
    if ( m ) { \
      count = 0; \
      for (i=ca->elements; i; i--, ptr++) { \
        if ( ! *m++ ) { \
          sum += (double)from(*ptr); \
        } \
        else { \
          count++; \
        } \
      } \
      nvalid = ca->elements - count; \
    } \
    else { \
      for (i=ca->elements; i; i--, ptr++) { \
        sum += (double)from(*ptr); \
      } \
      nvalid = ca->elements; \
    } \
    if ( ( ! NIL_P(rmin_count) ) && count > min_count ) {       \
      out = ( NIL_P(rfval) ) ? CA_UNDEF : rfval; \
      break; \
    } \
    ave = sum / ((double) nvalid); \
    ptr = (type *) ca->ptr; \
    m = (ca->mask) ? (boolean8_t*) ca->mask->ptr : NULL; \
    if ( m ) { \
      for (i=ca->elements; i; i--, ptr++) { \
        if ( ! *m++ ) { \
          del = ((double)from(*ptr)) - ave; \
          sum2 += del*del; \
        } \
      } \
    } \
    else { \
      for (i=ca->elements; i; i--, ptr++) { \
        del = ((double)from(*ptr)) - ave; \
        sum2 += del*del; \
      } \
    } \
    var = sum2 / ((double) nvalid - 1); \
    out = rb_float_new(var); \
  }

static VALUE
rb_ca_variance (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE out, rmin_count = Qnil, rfval = Qnil;
  CArray *ca;
  ca_size_t min_count;

  if ( argc > 0 ) {
    rb_scan_args(argc, argv, "02", (VALUE *) &rmin_count, (VALUE *) &rfval);
  }

  Data_Get_Struct(self, CArray, ca);

  if ( ca->elements == 0 ) {
    return ( NIL_P(rfval) ) ? CA_UNDEF : rfval;
  }

  min_count = ( NIL_P(rmin_count) || ! ca_has_mask(ca) ) ?
                                     ca->elements - 1 : NUM2SIZE(rmin_count);

  if ( min_count < 0 ) {
    min_count += ca->elements;
  }

  ca_attach(ca);

  switch ( ca->data_type ) {
  case CA_BOOLEAN:
  case CA_INT8:     proc_variance(int8_t,);       break;
  case CA_UINT8:    proc_variance(uint8_t,);     break;
  case CA_INT16:    proc_variance(int16_t,);      break;
  case CA_UINT16:   proc_variance(uint16_t,);    break;
  case CA_INT32:    proc_variance(int32_t,);      break;
  case CA_UINT32:   proc_variance(uint32_t,);    break;
  case CA_INT64:    proc_variance(int64_t,);      break;
  case CA_UINT64:   proc_variance(uint64_t,);    break;
  case CA_FLOAT32:  proc_variance(float32_t,);    break;
  case CA_FLOAT64:  proc_variance(float64_t,);    break;
  case CA_FLOAT128: proc_variance(float128_t,);   break;
  case CA_OBJECT:   proc_variance(VALUE,NUM2DBL); break;
  default: rb_raise(rb_eRuntimeError, "invalid data type");
  }

  ca_detach(ca);

  return out;
}

static VALUE
rb_ca_count_true (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE out, rmin_count = Qnil, rfval = Qnil;
  CArray *ca;
  ca_size_t min_count;

  if ( argc > 1 ) {
    rb_scan_args(argc, argv, "02", (VALUE *) &rmin_count, (VALUE *) &rfval);
  }

  Data_Get_Struct(self, CArray, ca);

  if ( ! ca_is_boolean_type(ca) ) {
    rb_raise(rb_eCADataTypeError,
             "data_type should be CA_BOOLEAN for this method");
  }

  if ( ca->elements == 0 ) {
    return INT2NUM(0);
  }

  min_count = ( NIL_P(rmin_count) || ! ca_has_mask(ca) ) ?
                                     ca->elements - 1 : NUM2SIZE(rmin_count);

  if ( min_count < 0 ) {
    min_count += ca->elements;
  }

  ca_attach(ca);

  {
    boolean8_t *ptr = (boolean8_t *) ca->ptr;
    boolean8_t *m = (ca->mask) ? (boolean8_t*) ca->mask->ptr : NULL;
    ca_size_t count = 0;
    ca_size_t value_count = 0;
    ca_size_t i;
    if ( m ) {
      for (i=0; i<ca->elements; i++) {
        if ( *m ) {
          count++;
        }
        else if ( *ptr ) {
          value_count++;
        }
        ptr++; m++;
      }
    }
    else {
      for (i=0; i<ca->elements; i++) {
        if ( *ptr ) {
          value_count++;
        }
        ptr++;
      }
    }
    if ( ( ! NIL_P(rmin_count) ) && count > min_count ) {
      out = ( NIL_P(rfval) ) ? CA_UNDEF : rfval;
    }
    else {
      out = SIZE2NUM(value_count);
    }
  }

  ca_detach(ca);

  return out;
}

static VALUE
rb_ca_count_false (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE out, rmin_count = Qnil, rfval = Qnil;
  CArray *ca;
  ca_size_t min_count;

  if ( argc > 1 ) {
    rb_scan_args(argc, argv, "02", (VALUE *) &rmin_count, (VALUE *) &rfval);
  }

  Data_Get_Struct(self, CArray, ca);

  if ( ! ca_is_boolean_type(ca) ) {
    rb_raise(rb_eCADataTypeError,
             "data_type should be CA_BOOLEAN for this method");
  }

  if ( ca->elements == 0 ) {
    return INT2NUM(0);
  }

  min_count = ( NIL_P(rmin_count) || ! ca_has_mask(ca) ) ?
                                     ca->elements - 1 : NUM2SIZE(rmin_count);

  if ( min_count < 0 ) {
    min_count += ca->elements;
  }

  ca_attach(ca);

  {
    boolean8_t *ptr = (boolean8_t *) ca->ptr;
    boolean8_t *m = (ca->mask) ? (boolean8_t*) ca->mask->ptr : NULL;
    ca_size_t count = 0;
    ca_size_t value_count = 0;
    ca_size_t i;
    if ( m ) {
      for (i=0; i<ca->elements; i++) {
        if ( *m ) {
          count++;
        }
        else if ( !(*ptr) ) {
          value_count++;
        }
        ptr++; m++;
      }
    }
    else {
      for (i=0; i<ca->elements; i++) {
        if ( !(*ptr) ) {
          value_count++;
        }
        ptr++;
      }
    }
    if ( ( ! NIL_P(rmin_count) ) && count > min_count ) {
      out = ( NIL_P(rfval) ) ? CA_UNDEF : rfval;
    }
    else {
      out = SIZE2NUM(value_count);
    }
  }

  ca_detach(ca);

  return out;
}

/* ----------------------------------------------------------------- */

#define proc_count_equal(type,from) \
  { \
    type *ptr = (type *) ca->ptr; \
    boolean8_t *m = (ca->mask) ? (boolean8_t*) ca->mask->ptr : NULL; \
    type val  = (type) from(value); \
    ca_size_t count = 0; \
    ca_size_t value_count = 0; \
    ca_size_t i; \
    if ( m ) { \
      for (i=ca->elements; i; i--, ptr++)       { \
        if ( ! *m++ ) { \
          if (*ptr == val ) { \
            value_count++; \
          } \
        } \
        else { \
          count++; \
        } \
      } \
    } \
    else { \
      for (i=ca->elements; i; i--, ptr++)       { \
        if ( *ptr == val ) { \
          value_count++; \
        } \
      } \
    } \
    if ( ( ! NIL_P(rmin_count) ) && count > min_count ) {       \
      out = ( NIL_P(rfval) ) ? CA_UNDEF : rfval; \
    } \
    else { \
      out = SIZE2NUM(value_count); \
    } \
  }

#define proc_count_equal_data() \
  { \
    char *ptr = ca->ptr; \
    boolean8_t *m = (ca->mask) ? (boolean8_t*) ca->mask->ptr : NULL; \
    char *val = ALLOCA_N(char, ca->bytes); \
    ca_size_t count = 0; \
    ca_size_t value_count = 0; \
    ca_size_t i; \
    rb_ca_obj2ptr(self, value, val); \
    if ( m ) { \
      for (i=ca->elements; i; i--, ptr+=ca->bytes) {\
        if ( ! *m++ ) { \
          if ( !memcmp(ptr, val, ca->bytes) ) { \
            value_count++; \
          } \
        } \
        else { \
          count++; \
        } \
      } \
    } \
    else { \
      for (i=ca->elements; i; i--, ptr+=ca->bytes) { \
        if ( !memcmp(ptr, val, ca->bytes) ) { \
          value_count++; \
        } \
      } \
    } \
    if ( ( ! NIL_P(rmin_count) ) && count > min_count ) {       \
      out = ( NIL_P(rfval) ) ? CA_UNDEF : rfval; \
    } \
    else { \
      out = SIZE2NUM(value_count); \
    } \
  }

#define proc_count_equal_object() \
  { \
    VALUE *ptr = (VALUE *)ca->ptr;                                 \
    boolean8_t *m = (ca->mask) ? (boolean8_t*) ca->mask->ptr : NULL; \
    VALUE val = value; \
    ca_size_t count = 0; \
    ca_size_t value_count = 0; \
    ca_size_t i; \
    if ( m ) { \
      for (i=ca->elements; i; i--) {\
        if ( ! *m++ ) { \
          if ( rb_equal(*ptr, val) ) {      \
            value_count++; \
          } \
        } \
        else { \
          count++; \
        } \
        ptr++; \
      } \
    } \
    else { \
      for (i=ca->elements; i; i--) { \
        if ( rb_equal(*ptr, val) ) {      \
          value_count++; \
        } \
        ptr++; \
      } \
    } \
    if ( ( ! NIL_P(rmin_count) ) && count > min_count ) {       \
      out = ( NIL_P(rfval) ) ? CA_UNDEF : rfval; \
    } \
    else { \
      out = SIZE2NUM(value_count); \
    } \
  }

static VALUE
rb_ca_count_equal (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE out, value, rmin_count = Qnil, rfval = Qnil;
  CArray *ca;
  ca_size_t min_count;

  rb_scan_args(argc, argv, "12", (VALUE *) &value, (VALUE *) &rmin_count, (VALUE *) &rfval);

  Data_Get_Struct(self, CArray, ca);

  if ( ca->elements == 0 ) {
    return ( NIL_P(rfval) ) ? CA_UNDEF : rfval;
  }

  min_count = ( NIL_P(rmin_count) || ! ca_has_mask(ca) ) ?
                                     ca->elements - 1 : NUM2SIZE(rmin_count);

  if ( min_count < 0 ) {
    min_count += ca->elements;
  }

  ca_attach(ca);

  switch ( ca->data_type ) {
  case CA_FIXLEN:     proc_count_equal_data();     break;
  case CA_BOOLEAN:
  case CA_INT8:     proc_count_equal(int8_t,NUM2LONG);    break;
  case CA_UINT8:    proc_count_equal(uint8_t,NUM2ULONG);    break;
  case CA_INT16:    proc_count_equal(int16_t,NUM2LONG);   break;
  case CA_UINT16:   proc_count_equal(uint16_t,NUM2ULONG);   break;
  case CA_INT32:    proc_count_equal(int32_t,NUM2LONG);   break;
  case CA_UINT32:   proc_count_equal(uint32_t,NUM2LONG); break;
  case CA_INT64:    proc_count_equal(int64_t,NUM2LL);   break;
  case CA_UINT64:   proc_count_equal(uint64_t,NUM2LL); break;
  case CA_FLOAT32:  proc_count_equal(float32_t,NUM2DBL); break;
  case CA_FLOAT64:  proc_count_equal(float64_t,NUM2DBL); break;
  case CA_FLOAT128: proc_count_equal(float128_t,NUM2DBL); break;
#ifdef HAVE_COMPLEX_H
  case CA_CMPLX64:  proc_count_equal(cmplx64_t,NUM2CC); break;
  case CA_CMPLX128: proc_count_equal(cmplx128_t,NUM2CC); break;
  case CA_CMPLX256: proc_count_equal(cmplx256_t,NUM2CC); break;
#endif
  case CA_OBJECT:   proc_count_equal_object();     break;
  default: rb_raise(rb_eCADataTypeError, "invalid data type");
  }

  ca_detach(ca);

  return out;
}

/* ----------------------------------------------------------------- */

#define proc_count_equiv(type,from,nabs) \
  { \
    type *ptr = (type *) ca->ptr; \
    boolean8_t *m = (ca->mask) ? (boolean8_t*) ca->mask->ptr : NULL; \
    type val  = (type) from(value); \
    double rtol = fabs(NUM2DBL(reps)); \
    double vabs = nabs(val); \
    ca_size_t count = 0; \
    ca_size_t value_count = 0; \
    ca_size_t i; \
    if ( m ) { \
      for (i=ca->elements; i; i--, ptr++)       { \
        if ( ! *m++ ) { \
          if ( *ptr == val || \
               nabs(*ptr - val)/(MAX(nabs(*ptr), vabs)) <= rtol )\
            value_count++; \
        } \
        else { \
          count++; \
        } \
      } \
    } \
    else { \
      for (i=ca->elements; i; i--, ptr++)       { \
        if ( *ptr == val || \
             nabs(*ptr - val)/MAX(nabs(*ptr), vabs) <= rtol ) { \
          value_count++; \
        } \
      } \
    } \
    if ( ( ! NIL_P(rmin_count) ) && count > min_count ) {       \
      out = ( NIL_P(rfval) ) ? CA_UNDEF : rfval; \
    } \
    else { \
      out = SIZE2NUM(value_count); \
    } \
  }

static VALUE
rb_ca_count_equiv (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE out, value = argv[0], reps = argv[1],
                      rmin_count = Qnil, rfval = Qnil;
  CArray *ca;
  ca_size_t min_count;

  if ( argc > 2 ) {
    rb_scan_args(argc, argv, "22", (VALUE *) &value, (VALUE *) &reps, (VALUE *) &rmin_count, (VALUE *) &rfval);
  }

  Data_Get_Struct(self, CArray, ca);

  if ( ca->elements == 0 ) {
    return ( NIL_P(rfval) ) ? CA_UNDEF : rfval;
  }

  min_count = ( NIL_P(rmin_count) || ! ca_has_mask(ca) ) ?
                                     ca->elements - 1 : NUM2SIZE(rmin_count);

  if ( min_count < 0 ) {
    min_count += ca->elements;
  }

  ca_attach(ca);

  switch ( ca->data_type ) {
  case CA_BOOLEAN:
  case CA_INT8:     proc_count_equiv(int8_t,NUM2LONG,fabs);    break;
  case CA_UINT8:    proc_count_equiv(uint8_t,NUM2ULONG,fabs);    break;
  case CA_INT16:    proc_count_equiv(int16_t,NUM2LONG,fabs);   break;
  case CA_UINT16:   proc_count_equiv(uint16_t,NUM2ULONG,fabs);   break;
  case CA_INT32:    proc_count_equiv(int32_t,NUM2LONG,fabs);   break;
  case CA_UINT32:   proc_count_equiv(uint32_t,NUM2LONG,fabs); break;
  case CA_INT64:    proc_count_equiv(int64_t,NUM2LL,fabs);   break;
  case CA_UINT64:   proc_count_equiv(uint64_t,NUM2LL,fabs); break;
  case CA_FLOAT32:  proc_count_equiv(float32_t,NUM2DBL,fabs); break;
  case CA_FLOAT64:  proc_count_equiv(float64_t,NUM2DBL,fabs); break;
  case CA_FLOAT128: proc_count_equiv(float128_t,NUM2DBL,fabs); break;
#ifdef HAVE_COMPLEX_H
  case CA_CMPLX64:  proc_count_equiv(cmplx64_t,NUM2CC,cabs); break;
  case CA_CMPLX128: proc_count_equiv(cmplx128_t,NUM2CC,cabs); break;
  case CA_CMPLX256: proc_count_equiv(cmplx256_t,NUM2CC,cabs); break;
#endif
  default: rb_raise(rb_eCADataTypeError, "invalid data type");
  }

  ca_detach(ca);

  return out;
}

/* ----------------------------------------------------------------- */

#define proc_count_close(type,from,nabs) \
  { \
    type *ptr = (type *) ca->ptr; \
    boolean8_t *m = (ca->mask) ? (boolean8_t*) ca->mask->ptr : NULL; \
    type val  = (type) from(value); \
    double atol = fabs(NUM2DBL(aeps)); \
    ca_size_t count = 0; \
    ca_size_t value_count = 0; \
    ca_size_t i; \
    if ( m ) { \
      for (i=ca->elements; i; i--, ptr++)       { \
        if ( ! *m++ ) { \
          if ( nabs(*ptr - val) <= atol ) { \
            value_count++; \
          } \
        } \
        else { \
          count++; \
        } \
      } \
    } \
    else { \
      for (i=ca->elements; i; i--, ptr++)       { \
        if ( nabs(*ptr - val) <= atol ) { \
          value_count++; \
        } \
      } \
    } \
    if ( ( ! NIL_P(rmin_count) ) && count > min_count ) {       \
      out = ( NIL_P(rfval) ) ? CA_UNDEF : rfval; \
    } \
    else { \
      out = SIZE2NUM(value_count); \
    } \
  }

static VALUE
rb_ca_count_close (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE out, value = argv[0], aeps = argv[1],
                      rmin_count = Qnil, rfval = Qnil;
  CArray *ca;
  ca_size_t min_count;

  if ( argc > 2 ) {
    rb_scan_args(argc, argv, "22", (VALUE *) &value, (VALUE *) &aeps, (VALUE *) &rmin_count, (VALUE *) &rfval);
  }

  Data_Get_Struct(self, CArray, ca);

  if ( ca->elements == 0 ) {
    return ( NIL_P(rfval) ) ? CA_UNDEF : rfval;
  }

  min_count = ( NIL_P(rmin_count) || ! ca_has_mask(ca) ) ?
                                     ca->elements - 1 : NUM2SIZE(rmin_count);

  if ( min_count < 0 ) {
    min_count += ca->elements;
  }

  ca_attach(ca);

  switch ( ca->data_type ) {
  case CA_BOOLEAN:
  case CA_INT8:     proc_count_close(int8_t,NUM2LONG,fabs);    break;
  case CA_UINT8:    proc_count_close(uint8_t,NUM2ULONG,fabs);    break;
  case CA_INT16:    proc_count_close(int16_t,NUM2LONG,fabs);   break;
  case CA_UINT16:   proc_count_close(uint16_t,NUM2ULONG,fabs);   break;
  case CA_INT32:    proc_count_close(int32_t,NUM2LONG,fabs);   break;
  case CA_UINT32:   proc_count_close(uint32_t,NUM2LONG,fabs); break;
  case CA_INT64:    proc_count_close(int64_t,NUM2LL,fabs);   break;
  case CA_UINT64:   proc_count_close(uint64_t,NUM2LL,fabs); break;
  case CA_FLOAT32:  proc_count_close(float32_t,NUM2DBL,fabs); break;
  case CA_FLOAT64:  proc_count_close(float64_t,NUM2DBL,fabs); break;
  case CA_FLOAT128: proc_count_close(float128_t,NUM2DBL,fabs); break;
#ifdef HAVE_COMPLEX_H
  case CA_CMPLX64:  proc_count_close(cmplx64_t,NUM2CC,cabs); break;
  case CA_CMPLX128: proc_count_close(cmplx128_t,NUM2CC,cabs); break;
  case CA_CMPLX256: proc_count_close(cmplx256_t,NUM2CC,cabs); break;
#endif
  default: rb_raise(rb_eCADataTypeError, "invalid data type");
  }

  ca_detach(ca);

  return out;
}

/* ----------------------------------------------------------------- */

#define proc_all_equal(type,from) \
  { \
    type *ptr = (type *) ca->ptr; \
    boolean8_t *m = (ca->mask) ? (boolean8_t*) ca->mask->ptr : NULL; \
    type val  = (type) from(value); \
    ca_size_t i; \
    if ( m ) { \
      for (i=ca->elements; i; i--, ptr++) { \
        if ( ( ! *m++ ) && *ptr != val ) {  \
          flag = Qfalse; \
          break; \
        } \
      } \
    } \
    else { \
      for (i=ca->elements; i; i--, ptr++) { \
        if ( *ptr != val ) { \
          flag = Qfalse; \
          break; \
        } \
      } \
    } \
  }

#define proc_all_equal_object() \
  { \
    VALUE *ptr = (VALUE *) ca->ptr; \
    boolean8_t *m = (ca->mask) ? (boolean8_t*) ca->mask->ptr : NULL; \
    VALUE val  = value; \
    ca_size_t i; \
    if ( m ) { \
      for (i=ca->elements; i; i--, ptr++) { \
        if ( ( ! *m++ ) && ! rb_equal(*ptr,val) ) {      \
          flag = Qfalse; \
          break; \
        } \
      } \
    } \
    else { \
      for (i=ca->elements; i; i--, ptr++) { \
        if ( ! rb_equal(*ptr, val) ) {        \
          flag = Qfalse; \
          break; \
        } \
      } \
    } \
  }

#define proc_all_equal_data() \
  { \
    char *ptr = ca->ptr; \
    boolean8_t *m = (ca->mask) ? (boolean8_t*) ca->mask->ptr : NULL; \
    char *val = ALLOCA_N(char, ca->bytes); \
    ca_size_t i; \
    rb_ca_obj2ptr(self, value, val); \
    if ( m ) { \
      for (i=ca->elements; i; i--, ptr+=ca->bytes) { \
        if ( ( ! *m++ ) && memcmp(ptr, val, ca->bytes) ) {      \
          flag = Qfalse; \
          break; \
        } \
      } \
    } \
    else { \
      for (i=ca->elements; i; i--, ptr+=ca->bytes) { \
        if ( memcmp(ptr, val, ca->bytes) ) { \
          flag = Qfalse; \
          break; \
        } \
      } \
    } \
  }

static VALUE
rb_ca_all_equal_p (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE value;
  volatile VALUE flag = Qtrue;
  CArray *ca;

  rb_scan_args(argc, argv, "1", (VALUE *) &value);

  Data_Get_Struct(self, CArray, ca);

  ca_attach(ca);

  switch ( ca->data_type ) {
  case CA_FIXLEN:    proc_all_equal_data();     break;
  case CA_BOOLEAN:
  case CA_INT8:    proc_all_equal(int8_t,NUM2LONG);    break;
  case CA_UINT8:   proc_all_equal(uint8_t,NUM2ULONG);    break;
  case CA_INT16:   proc_all_equal(int16_t,NUM2LONG);   break;
  case CA_UINT16:  proc_all_equal(uint16_t,NUM2ULONG);   break;
  case CA_INT32:   proc_all_equal(int32_t,NUM2LONG);   break;
  case CA_UINT32:  proc_all_equal(uint32_t,NUM2ULONG); break;
  case CA_INT64:   proc_all_equal(int64_t,NUM2LL);   break;
  case CA_UINT64:  proc_all_equal(uint64_t,NUM2ULL); break;
  case CA_FLOAT32: proc_all_equal(float32_t,NUM2DBL); break;
  case CA_FLOAT64: proc_all_equal(float64_t,NUM2DBL); break;
  case CA_FLOAT128: proc_all_equal(float128_t,NUM2DBL); break;
#ifdef HAVE_COMPLEX_H
  case CA_CMPLX64:  proc_all_equal(cmplx64_t,NUM2CC); break;
  case CA_CMPLX128: proc_all_equal(cmplx128_t,NUM2CC); break;
  case CA_CMPLX256: proc_all_equal(cmplx256_t,NUM2CC); break;
#endif
  case CA_OBJECT:    proc_all_equal_object();     break;
  default: rb_raise(rb_eCADataTypeError, "invalid data type");
  }

  ca_detach(ca);

  return flag;
}

/* ----------------------------------------------------------------- */

#define proc_all_equiv(type,from,nabs) \
  { \
    type *ptr = (type *) ca->ptr; \
    boolean8_t *m = (ca->mask) ? (boolean8_t*) ca->mask->ptr : NULL; \
    type val  = (type) from(value); \
    double rtol = fabs(NUM2DBL(reps)); \
    double vabs = nabs(val); \
    ca_size_t i; \
    if ( m ) { \
      for (i=ca->elements; i; i--, ptr++) { \
        if ( ! *m++ ) {             \
          if ( *ptr != val && \
                nabs(*ptr - val)/MAX(nabs(*ptr), vabs) > rtol ) {\
            flag = Qfalse; \
            break; \
          } \
        } \
      } \
    } \
    else { \
      for (i=ca->elements; i; i--, ptr++) { \
        if ( *ptr != val && \
             nabs(*ptr - val)/MAX(nabs(*ptr), vabs) > rtol ) {\
          flag = Qfalse; \
          break; \
        } \
      } \
    } \
  }

static VALUE
rb_ca_all_equiv_p (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE value, reps;
  volatile VALUE flag = Qtrue;
  CArray *ca;

  rb_scan_args(argc, argv, "2", (VALUE *) &value, (VALUE *) &reps);

  Data_Get_Struct(self, CArray, ca);

  ca_attach(ca);

  switch ( ca->data_type ) {
  case CA_BOOLEAN:
  case CA_INT8:    proc_all_equiv(int8_t,NUM2LONG,fabs);    break;
  case CA_UINT8:   proc_all_equiv(uint8_t,NUM2ULONG,fabs);    break;
  case CA_INT16:   proc_all_equiv(int16_t,NUM2LONG,fabs);   break;
  case CA_UINT16:  proc_all_equiv(uint16_t,NUM2ULONG,fabs);   break;
  case CA_INT32:   proc_all_equiv(int32_t,NUM2LONG,fabs);   break;
  case CA_UINT32:  proc_all_equiv(uint32_t,NUM2ULONG,fabs); break;
  case CA_INT64:   proc_all_equiv(int64_t,NUM2LL,fabs);   break;
  case CA_UINT64:  proc_all_equiv(uint64_t,NUM2ULL,fabs); break;
  case CA_FLOAT32: proc_all_equiv(float32_t,NUM2DBL,fabs); break;
  case CA_FLOAT64: proc_all_equiv(float64_t,NUM2DBL,fabs); break;
  case CA_FLOAT128: proc_all_equiv(float128_t,NUM2DBL,fabs); break;
#ifdef HAVE_COMPLEX_H
  case CA_CMPLX64:  proc_all_equiv(cmplx64_t,NUM2CC,cabs); break;
  case CA_CMPLX128: proc_all_equiv(cmplx128_t,NUM2CC,cabs); break;
  case CA_CMPLX256: proc_all_equiv(cmplx256_t,NUM2CC,cabs); break;
#endif
  default: rb_raise(rb_eCADataTypeError, "invalid data type");
  }

  ca_detach(ca);

  return flag;
}

/* ----------------------------------------------------------------- */

#define proc_all_close(type,from,nabs) \
  { \
    type *ptr = (type *) ca->ptr; \
    boolean8_t *m = (ca->mask) ? (boolean8_t*) ca->mask->ptr : NULL; \
    type val  = (type) from(value); \
    double atol = fabs(NUM2DBL(aeps)); \
    ca_size_t i; \
    if ( m ) { \
      for (i=ca->elements; i; i--, ptr++) { \
        if ( ! *m++ ) { \
          if ( nabs(*ptr - val) > atol ) {\
            flag = Qfalse; \
            break; \
          } \
        } \
      } \
    } \
    else { \
      for (i=ca->elements; i; i--, ptr++) { \
        if ( nabs(*ptr - val) > atol ) {\
          flag = Qfalse; \
          break; \
        } \
      } \
    } \
  }

static VALUE
rb_ca_all_close_p (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE value, aeps;
  volatile VALUE flag = Qtrue;
  CArray *ca;

  rb_scan_args(argc, argv, "2", (VALUE *) &value, (VALUE *) &aeps);

  Data_Get_Struct(self, CArray, ca);

  ca_attach(ca);

  switch ( ca->data_type ) {
  case CA_BOOLEAN:
  case CA_INT8:    proc_all_close(int8_t,NUM2LONG,fabs);    break;
  case CA_UINT8:   proc_all_close(uint8_t,NUM2ULONG,fabs);    break;
  case CA_INT16:   proc_all_close(int16_t,NUM2LONG,fabs);   break;
  case CA_UINT16:  proc_all_close(uint16_t,NUM2ULONG,fabs);   break;
  case CA_INT32:   proc_all_close(int32_t,NUM2LONG,fabs);   break;
  case CA_UINT32:  proc_all_close(uint32_t,NUM2ULONG,fabs); break;
  case CA_INT64:   proc_all_close(int64_t,NUM2LL,fabs);   break;
  case CA_UINT64:  proc_all_close(uint64_t,NUM2ULL,fabs); break;
  case CA_FLOAT32: proc_all_close(float32_t,NUM2DBL,fabs); break;
  case CA_FLOAT64: proc_all_close(float64_t,NUM2DBL,fabs); break;
  case CA_FLOAT128: proc_all_close(float128_t,NUM2DBL,fabs); break;
#ifdef HAVE_COMPLEX_H
  case CA_CMPLX64:  proc_all_close(cmplx64_t,NUM2CC,cabs); break;
  case CA_CMPLX128: proc_all_close(cmplx128_t,NUM2CC,cabs); break;
  case CA_CMPLX256: proc_all_close(cmplx256_t,NUM2CC,cabs); break;
#endif
  default: rb_raise(rb_eCADataTypeError, "invalid data type");
  }

  ca_detach(ca);

  return flag;
}

/* ----------------------------------------------------------------- */

#define proc_any_equal(type,from) \
  { \
    type *ptr = (type *) ca->ptr; \
    boolean8_t *m = (ca->mask) ? (boolean8_t*) ca->mask->ptr : NULL; \
    type val  = (type) from(value); \
    ca_size_t i; \
    if ( m ) { \
      for (i=ca->elements; i; i--, ptr++) { \
        if ( ( ! *m++ ) && *ptr == val ) {  \
          flag = Qtrue; \
          break; \
        } \
      } \
    } \
    else { \
      for (i=ca->elements; i; i--, ptr++) { \
        if ( *ptr == val ) { \
          flag = Qtrue; \
          break; \
        } \
      } \
    } \
  }

#define proc_any_equal_object() \
  { \
    VALUE *ptr = (VALUE *) ca->ptr; \
    boolean8_t *m = (ca->mask) ? (boolean8_t*) ca->mask->ptr : NULL; \
    VALUE val  = value; \
    ca_size_t i; \
    if ( m ) { \
      for (i=ca->elements; i; i--, ptr++) { \
        if ( ( ! *m++ ) && rb_equal(*ptr,val) ) {       \
          flag = Qtrue; \
          break; \
        } \
      } \
    } \
    else { \
      for (i=ca->elements; i; i--, ptr++) { \
        if ( rb_equal(*ptr, val) ) {         \
          flag = Qtrue; \
          break; \
        } \
      } \
    } \
  }

#define proc_any_equal_data() \
  { \
    char *ptr = ca->ptr; \
    boolean8_t *m = (ca->mask) ? (boolean8_t*) ca->mask->ptr : NULL; \
    char *val = ALLOCA_N(char, ca->bytes); \
    ca_size_t i; \
    rb_ca_obj2ptr(self, value, val); \
    if ( m ) { \
      for (i=ca->elements; i; i--, ptr+=ca->bytes) \
        if ( ( ! *m++ ) && ! memcmp(ptr, val, ca->bytes) ) {    \
          flag = Qtrue; \
          break; \
        } \
    } \
    else { \
      for (i=ca->elements; i; i--, ptr+=ca->bytes) \
        if ( ! memcmp(ptr, val, ca->bytes) ) { \
          flag = Qtrue; \
          break; \
        } \
    } \
  }

static VALUE
rb_ca_any_equal_p (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE value;
  volatile VALUE flag = Qfalse;
  CArray *ca;

  rb_scan_args(argc, argv, "1", (VALUE *) &value);

  Data_Get_Struct(self, CArray, ca);

  ca_attach(ca);

  switch ( ca->data_type ) {
  case CA_FIXLEN:    proc_any_equal_data();     break;
  case CA_BOOLEAN:
  case CA_INT8:    proc_any_equal(int8_t,NUM2LONG);    break;
  case CA_UINT8:   proc_any_equal(uint8_t,NUM2ULONG);    break;
  case CA_INT16:   proc_any_equal(int16_t,NUM2LONG);   break;
  case CA_UINT16:  proc_any_equal(uint16_t,NUM2ULONG);   break;
  case CA_INT32:   proc_any_equal(int32_t,NUM2LONG);   break;
  case CA_UINT32:  proc_any_equal(uint32_t,NUM2ULONG); break;
  case CA_INT64:   proc_any_equal(int64_t,NUM2LL);   break;
  case CA_UINT64:  proc_any_equal(uint64_t,NUM2ULL); break;
  case CA_FLOAT32: proc_any_equal(float32_t,NUM2DBL); break;
  case CA_FLOAT64: proc_any_equal(float64_t,NUM2DBL); break;
  case CA_FLOAT128: proc_any_equal(float128_t,NUM2DBL); break;
#ifdef HAVE_COMPLEX_H
  case CA_CMPLX64:  proc_any_equal(cmplx64_t,NUM2CC); break;
  case CA_CMPLX128: proc_any_equal(cmplx128_t,NUM2CC); break;
  case CA_CMPLX256: proc_any_equal(cmplx256_t,NUM2CC); break;
#endif
  case CA_OBJECT:    proc_any_equal_object();     break;
  default: rb_raise(rb_eCADataTypeError, "invalid data type");
  }

  ca_detach(ca);

  return flag;
}

/* ----------------------------------------------------------------- */

#define proc_any_equiv(type,from,nabs) \
  { \
    type *ptr = (type *) ca->ptr; \
    boolean8_t *m = (ca->mask) ? (boolean8_t*) ca->mask->ptr : NULL; \
    type val  = (type) from(value); \
    double rtol = fabs(NUM2DBL(reps)); \
    double vabs = nabs(val); \
    ca_size_t i; \
    if ( m ) { \
    for (i=ca->elements; i; i--, ptr++) { \
        if ( ! *m++ ) { \
          if ( *ptr == val || \
               nabs(*ptr - val)/MAX(nabs(*ptr), vabs) <= rtol ) {\
            flag = Qtrue; \
            break; \
          } \
        } \
      } \
    } \
    else { \
      for (i=ca->elements; i; i--, ptr++) { \
        if ( *ptr == val || \
            nabs(*ptr - val)/MAX(nabs(*ptr), vabs) <= rtol ) {\
          flag = Qtrue; \
          break; \
        } \
      } \
    } \
  }

static VALUE
rb_ca_any_equiv_p (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE value, reps;
  volatile VALUE flag = Qfalse;
  CArray *ca;

  rb_scan_args(argc, argv, "2", (VALUE *) &value, (VALUE *) &reps);

  Data_Get_Struct(self, CArray, ca);

  ca_attach(ca);

  switch ( ca->data_type ) {
  case CA_BOOLEAN:
  case CA_INT8:    proc_any_equiv(int8_t,NUM2LONG,fabs);    break;
  case CA_UINT8:   proc_any_equiv(uint8_t,NUM2ULONG,fabs);    break;
  case CA_INT16:   proc_any_equiv(int16_t,NUM2LONG,fabs);   break;
  case CA_UINT16:  proc_any_equiv(uint16_t,NUM2ULONG,fabs);   break;
  case CA_INT32:   proc_any_equiv(int32_t,NUM2LONG,fabs);   break;
  case CA_UINT32:  proc_any_equiv(uint32_t,NUM2ULONG,fabs); break;
  case CA_INT64:   proc_any_equiv(int64_t,NUM2LL,fabs);   break;
  case CA_UINT64:  proc_any_equiv(uint64_t,NUM2ULL,fabs); break;
  case CA_FLOAT32: proc_any_equiv(float32_t,NUM2DBL,fabs); break;
  case CA_FLOAT64: proc_any_equiv(float64_t,NUM2DBL,fabs); break;
  case CA_FLOAT128: proc_any_equiv(float128_t,NUM2DBL,fabs); break;
#ifdef HAVE_COMPLEX_H
  case CA_CMPLX64:  proc_any_equiv(cmplx64_t,NUM2CC,cabs); break;
  case CA_CMPLX128: proc_any_equiv(cmplx128_t,NUM2CC,cabs); break;
  case CA_CMPLX256: proc_any_equiv(cmplx256_t,NUM2CC,cabs); break;
#endif
  default: rb_raise(rb_eCADataTypeError, "invalid data type");
  }

  ca_detach(ca);

  return flag;
}

/* ----------------------------------------------------------------- */

#define proc_any_close(type,from,nabs) \
  { \
    type *ptr = (type *) ca->ptr; \
    boolean8_t *m = (ca->mask) ? (boolean8_t*) ca->mask->ptr : NULL; \
    type val  = (type) from(value); \
    double atol = fabs(NUM2DBL(aeps)); \
    ca_size_t i; \
    if ( m ) { \
      for (i=ca->elements; i; i--, ptr++) { \
        if ( ! *m++ ) { \
          if ( nabs(*ptr - val) <= atol ) {\
            flag = Qtrue; \
            break; \
          } \
        } \
      } \
    } \
    else { \
      for (i=ca->elements; i; i--, ptr++) { \
        if ( nabs(*ptr - val) <= atol ) {\
          flag = Qtrue; \
          break; \
        } \
      } \
    } \
  }

static VALUE
rb_ca_any_close_p (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE value, aeps;
  volatile VALUE flag = Qfalse;
  CArray *ca;

  rb_scan_args(argc, argv, "2", (VALUE *) &value, (VALUE *) &aeps);

  Data_Get_Struct(self, CArray, ca);

  ca_attach(ca);

  switch ( ca->data_type ) {
  case CA_BOOLEAN:
  case CA_INT8:    proc_any_close(int8_t,NUM2LONG,fabs);    break;
  case CA_UINT8:   proc_any_close(uint8_t,NUM2ULONG,fabs);    break;
  case CA_INT16:   proc_any_close(int16_t,NUM2LONG,fabs);   break;
  case CA_UINT16:  proc_any_close(uint16_t,NUM2ULONG,fabs);   break;
  case CA_INT32:   proc_any_close(int32_t,NUM2LONG,fabs);   break;
  case CA_UINT32:  proc_any_close(uint32_t,NUM2ULONG,fabs); break;
  case CA_INT64:   proc_any_close(int64_t,NUM2LL,fabs);   break;
  case CA_UINT64:  proc_any_close(uint64_t,NUM2ULL,fabs); break;
  case CA_FLOAT32: proc_any_close(float32_t,NUM2DBL,fabs); break;
  case CA_FLOAT64: proc_any_close(float64_t,NUM2DBL,fabs); break;
  case CA_FLOAT128: proc_any_close(float128_t,NUM2DBL,fabsl); break;
#ifdef HAVE_COMPLEX_H
  case CA_CMPLX64:  proc_any_close(cmplx64_t,NUM2CC,cabs); break;
  case CA_CMPLX128: proc_any_close(cmplx128_t,NUM2CC,cabs); break;
  case CA_CMPLX256: proc_any_close(cmplx256_t,NUM2CC,cabsl); break;
#endif
  default: rb_raise(rb_eCADataTypeError, "invalid data type");
  }
  
  ca_detach(ca);

  return flag;
}

static VALUE
rb_ca_none_equal_p (int argc, VALUE *argv, VALUE self)
{
  return rb_ca_any_equal_p(argc, argv, self) ? Qfalse : Qtrue;
}

static VALUE
rb_ca_none_equiv_p (int argc, VALUE *argv, VALUE self)
{
  return rb_ca_any_equiv_p(argc, argv, self) ? Qfalse : Qtrue;
}

static VALUE
rb_ca_none_close_p (int argc, VALUE *argv, VALUE self)
{
  return rb_ca_any_close_p(argc, argv, self) ? Qfalse : Qtrue;
}

/* ----------------------------------------------------------------- */

#define proc_histogram(type, from) \
  { \
    type  *ptr = (type *) ca->ptr; \
    boolean8_t *m = (ca->mask) ? (boolean8_t*) ca->mask->ptr : NULL; \
    double min  = NUM2DBL(vmin); \
    double max  = NUM2DBL(vmax); \
    double diff = (max - min)/icls; \
    double trial; \
    ca_size_t i; \
    for (i=0; i<=icls+1; i++) \
      cls[i] = diff*i + min; \
    for (i=0; i<ca->elements; i++, ptr++) { \
      if ( m && *m++ ) continue; \
      trial = (double)from(*ptr); \
      if ( diff > 0 && trial >= min && trial <= max ) { \
        idx = (ca_size_t) ( (trial - min)/diff ); \
        hist[idx]++; \
      } \
      else if ( diff < 0 && trial >= max && trial <= min ) { \
        idx = (ca_size_t) ( (trial - min)/diff ); \
        hist[idx]++; \
      } \
    } \
  }

/*
static VALUE
rb_ca_histogram (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE vnum, vmin, vmax;
  CArray *ca, *co;
  ca_size_t i, idx, icls;
  ca_size_t *hist;
  ca_size_t dim[2] = {0, 3};
  double *cls, *p;

  rb_scan_args(argc, argv, "3", &vnum, &vmin, &vmax);

  Data_Get_Struct(self, CArray, ca);

  icls = NUM2SIZE(vnum);

  if ( icls < 1 ) {
    rb_raise(rb_eArgError, "bin number must be larger than 1");
  }

  hist = ALLOC_N(ca_size_t, icls+1);
  cls  = ALLOC_N(double, icls+2);

  MEMZERO(hist, ca_size_t, icls+1);
  MEMZERO(cls, double, icls+2);

  ca_attach(ca);

  switch ( ca->data_type ) {
  case CA_BOOLEAN:
  case CA_INT8:     proc_histogram(int8_t,); break;
  case CA_UINT8:    proc_histogram(uint8_t,); break;
  case CA_INT16:    proc_histogram(int16_t,); break;
  case CA_UINT16:   proc_histogram(uint16_t,); break;
  case CA_INT32:    proc_histogram(int32_t,); break;
  case CA_UINT32:   proc_histogram(uint32_t,); break;
  case CA_INT64:    proc_histogram(int64_t,); break;
  case CA_UINT64:   proc_histogram(uint64_t,); break;
  case CA_FLOAT32:  proc_histogram(float32_t,); break;
  case CA_FLOAT64:  proc_histogram(float64_t,); break;
  case CA_FLOAT128: proc_histogram(float128_t,); break;
  case CA_OBJECT:   proc_histogram(VALUE,NUM2DBL); break;
  default: rb_raise(rb_eCADataTypeError, "invalid data type");
  }

  ca_detach(ca);

  dim[0] = icls+1;

  co = carray_new(CA_FLOAT64, 2, dim, 0, NULL);

  p = (double *) co->ptr;

  for (i=0; i<icls+1; i++) {
    *p++ = cls[i];
    *p++ = cls[i+1];
    *p++ = (double) hist[i];
  }

  free(hist);
  free(cls);

  return ca_wrap_struct(co);
}
*/

/* ----------------------------------------------------------------- */

#define proc_grade(type, from)                             \
  {                                                          \
    ca_size_t *dst = (ca_size_t *) sa->ptr;                      \
    boolean8_t *m   = (ca->mask) ? (boolean8_t*) ca->mask->ptr : NULL; \
    boolean8_t *dm  = (sa->mask) ? (boolean8_t*) sa->mask->ptr : NULL; \
    type   *ptr = (type *) ca->ptr;                          \
    double min  = NUM2DBL(vmin);                             \
    double max  = min + (NUM2DBL(vmax)-min)*(((double)icls)/(icls-1));                      \
    type   miss = 0;                                         \
    double diff = max - min;                                 \
    double trial;                                            \
    ca_size_t i;                                               \
    if ( min > max ) {                                       \
      rb_raise(rb_eRuntimeError, "invalid (min, max) range");   \
    }                                                        \
    if ( min != max ) {                                      \
      for (i=0; i<ca->elements; i++, ptr++) {                \
        if ( m ) {                                           \
          miss = *m++;                                       \
        }                                                    \
        trial = from(*ptr);                                  \
        if ( miss ) {                                        \
          *dm = 1;                                           \
        }                                                    \
        else if ( isnan(trial) ) {                           \
          if ( ! dm ) {                                      \
            ca_create_mask(sa);                              \
            dm = (boolean8_t*) sa->mask->ptr;                    \
            dm += i;                                         \
            *dm = 1;                                         \
          }                                                  \
          *dm = 1;                                           \
        }                                                    \
        else {                                                  \
          *dst = (ca_size_t) floor( ((trial-min)/diff) * icls );  \
        }                                                       \
        dst++;                                                  \
        if ( dm ) {                                             \
          dm++;                                                 \
        }                                                       \
      }                                                         \
    }                                                           \
  }

static VALUE
rb_ca_grade (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE out, vnum, vmin, vmax;
  CArray *ca, *sa;
  ca_size_t icls;

  rb_scan_args(argc, argv, "12", (VALUE *) &vnum, (VALUE *) &vmin, (VALUE *) &vmax);

  if ( NIL_P(vmin) ) {
    vmin = rb_funcall(self, rb_intern("min"), 0);
  }

  if ( NIL_P(vmax) ) {
    vmax = rb_funcall(self, rb_intern("max"), 0);
  }

  Data_Get_Struct(self, CArray, ca);

  icls = NUM2LONG(vnum);

  if ( icls < 1 ) {
    rb_raise(rb_eArgError, "bin number must be larger than 1");
  }

  out = rb_carray_new_safe(CA_SIZE, ca->ndim, ca->dim, 0, NULL);
  Data_Get_Struct(out, CArray, sa);

  ca_attach(ca);

  if ( ca_has_mask(ca) ) {
    ca_create_mask(sa);
    ca_setup_mask(sa, ca->mask);
  }

  switch ( ca->data_type ) {
  case CA_BOOLEAN:
  case CA_INT8:    proc_grade(int8_t, );    break;
  case CA_UINT8:   proc_grade(uint8_t, );  break;
  case CA_INT16:   proc_grade(int16_t, );   break;
  case CA_UINT16:  proc_grade(uint16_t, ); break;
  case CA_INT32:   proc_grade(int32_t, );   break;
  case CA_UINT32:  proc_grade(uint32_t, ); break;
  case CA_INT64:   proc_grade(int64_t, );   break;
  case CA_UINT64:  proc_grade(uint64_t, ); break;
  case CA_FLOAT32: proc_grade(float32_t, );   break;
  case CA_FLOAT64: proc_grade(float64_t, );   break;
  case CA_FLOAT128: proc_grade(float128_t, ); break;
  case CA_OBJECT:  proc_grade(VALUE,NUM2DBL); break;
  default: rb_raise(rb_eCADataTypeError, "invalid data type");
  }

  ca_detach(ca);

  return out;
}

void
Init_carray_stat ()
{
  rb_define_method(rb_cCArray,  "wsum",        rb_ca_wsum, -1);
  rb_define_method(rb_cCArray,  "wmean",       rb_ca_wmean, -1);
  rb_define_method(rb_cCArray,  "variancep",   rb_ca_variancep, -1);
  rb_define_method(rb_cCArray,  "variance",    rb_ca_variance, -1);

  rb_define_method(rb_cCArray,  "cummin",      rb_ca_cummin, -1);
  rb_define_method(rb_cCArray,  "cummax",      rb_ca_cummax, -1);
  rb_define_method(rb_cCArray,  "cumprod",     rb_ca_cumprod, -1);
  rb_define_method(rb_cCArray,  "cumwsum",     rb_ca_cumwsum, -1);

  rb_define_method(rb_cCArray,  "count_true", rb_ca_count_true, -1);
  rb_define_method(rb_cCArray,  "count_false", rb_ca_count_false, -1);
  rb_define_method(rb_cCArray,  "count",       rb_ca_count_equal, -1);
  rb_define_method(rb_cCArray,  "count_equal", rb_ca_count_equal, -1);
  rb_define_method(rb_cCArray,  "count_equiv", rb_ca_count_equiv, -1);
  rb_define_method(rb_cCArray,  "count_close", rb_ca_count_close, -1);

  rb_define_method(rb_cCArray,  "all_equal?",  rb_ca_all_equal_p, -1);
  rb_define_method(rb_cCArray,  "all_equiv?",  rb_ca_all_equiv_p, -1);
  rb_define_method(rb_cCArray,  "all_close?",  rb_ca_all_close_p, -1);

  rb_define_method(rb_cCArray,  "any_equal?",  rb_ca_any_equal_p, -1);
  rb_define_method(rb_cCArray,  "any_equiv?",  rb_ca_any_equiv_p, -1);
  rb_define_method(rb_cCArray,  "any_close?",  rb_ca_any_close_p, -1);
  rb_define_method(rb_cCArray,  "none_equal?", rb_ca_none_equal_p, -1);
  rb_define_method(rb_cCArray,  "none_equiv?", rb_ca_none_equiv_p, -1);
  rb_define_method(rb_cCArray,  "none_close?", rb_ca_none_close_p, -1);

/*  rb_define_method(rb_cCArray,  "histogram", rb_ca_histogram, -1);  */
  rb_define_method(rb_cCArray,  "grade",       rb_ca_grade, -1);
  rb_define_method(rb_cCArray,  "gradate",     rb_ca_grade, -1);
  rb_define_method(rb_cCArray,  "quantize",    rb_ca_grade, -1);

}


