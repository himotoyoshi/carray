/* ---------------------------------------------------------------------------

  carray_numeric.c

  This file is part of Ruby/CArray extension library.
  You can redistribute it and/or modify it under the terms of
  the Ruby Licence.

  Copyright (C) 2005 Hiroki Motoyoshi

---------------------------------------------------------------------------- */

#include "ruby.h"
#include "carray.h"

#if RUBY_VERSION_CODE >= 240
# define rb_cFixnum rb_cInteger
# define rb_cBignum rb_cInteger
#endif

VALUE CA_NAN, CA_INF;

static ID id___or__;
static ID id___and__;
static ID id___xor__;
static ID id___rshift__;
static ID id___lshift__;

VALUE
rb_num_nan (VALUE self)
{
  return CA_NAN;
}

VALUE
rb_num_inf (VALUE self)
{
  return CA_INF;
}

static VALUE
rb_hack_or(VALUE x, VALUE y)
{
  if ( rb_obj_is_carray(y) ) {
    if ( rb_ca_is_boolean_type(y) ) {
      return rb_funcall(y, rb_intern("bit_or"), 1, x);
    }
    else {
#if RUBY_VERSION_CODE >= 190
      return rb_num_coerce_bin(x, y, '|');
#else
      return rb_num_coerce_bin(x, y);
#endif
    }
  }
  else {
    return rb_funcall(x, id___or__, 1, y);
  }
}

static VALUE
rb_hack_and (VALUE x, VALUE y)
{
  if ( rb_obj_is_carray(y) ) {
    if ( rb_ca_is_boolean_type(y) ) {
      return rb_funcall(y, rb_intern("bit_and"), 1, x);
    }
    else {
#if RUBY_VERSION_CODE >= 190
      return rb_num_coerce_bin(x, y, '&');
#else
      return rb_num_coerce_bin(x, y);
#endif
    }
  }
  else {
    return rb_funcall(x, id___and__, 1, y);
  }
}

static VALUE
rb_hack_xor (VALUE x, VALUE y)
{
  if ( rb_obj_is_carray(y) ) {
    if ( rb_ca_is_boolean_type(y) ) {
      return rb_funcall(y, rb_intern("bit_xor"), 1, x);
    }
    else {
#if RUBY_VERSION_CODE >= 190
      return rb_num_coerce_bin(x, y, '^');
#else
      return rb_num_coerce_bin(x, y);
#endif
    }
  }
  else {
    return rb_funcall(x, id___xor__, 1, y);
  }
}

static VALUE
rb_hack_lshift (VALUE x, VALUE y)
{
  if ( rb_obj_is_carray(y) ) {
#if RUBY_VERSION_CODE >= 190
      return rb_num_coerce_bin(x, y, rb_intern("<<"));
#else
      return rb_num_coerce_bin(x, y);
#endif
  }
  else {
    return rb_funcall(x, id___lshift__, 1, y);
  }
}

static VALUE
rb_hack_rshift (VALUE x, VALUE y)
{
  if ( rb_obj_is_carray(y) ) {
#if RUBY_VERSION_CODE >= 190
      return rb_num_coerce_bin(x, y, rb_intern(">>"));
#else
      return rb_num_coerce_bin(x, y);
#endif
  }
  else {
    return rb_funcall(x, id___rshift__, 1, y);
  }
}

static VALUE
rb_hack_star (VALUE x, VALUE y)
{
  return rb_funcall(y, rb_intern("*"), 1, x);
}

/* ------------------------------------------------------------------- */

#ifdef HAVE_COMPLEX_H

#include <math.h>
#include <float.h>

#define proc_arg_cmplx(type)                    \
  {                                             \
    type *p = (type *) ca->ptr;                 \
    double *q = (double *) co->ptr;             \
    boolean8_t *m = (ca->mask) ? (boolean8_t *) ca->mask->ptr : NULL; \
    ca_size_t i;                                  \
    if ( m ) {                                  \
      for (i=ca->elements; i; i--, p++, q++) {  \
        if ( ! *m++ )                           \
          *q = carg(*p);                        \
      }                                         \
    }                                           \
    else {                                      \
      for (i=ca->elements; i; i--, p++, q++) {  \
        *q = carg(*p);                          \
      }                                         \
    }                                           \
  }

static VALUE
rb_ca_arg (VALUE self)
{
  volatile VALUE obj;
  CArray *ca, *co;

  Data_Get_Struct(self, CArray, ca);

  co = carray_new(CA_FLOAT64, ca->ndim, ca->dim, 0, NULL);
  obj = ca_wrap_struct(co);

  if ( ca_has_mask(ca) ) {
    ca_copy_mask_overlay(co, co->elements, 1, ca);
  }

  ca_attach(ca);

  switch ( ca->data_type ) {
  case CA_FLOAT32:  proc_arg_cmplx(float32_t);  break;
  case CA_FLOAT64:  proc_arg_cmplx(float64_t);  break;
  case CA_FLOAT128: proc_arg_cmplx(float128_t);  break;
  case CA_CMPLX64:  proc_arg_cmplx(cmplx64_t);   break;
  case CA_CMPLX128: proc_arg_cmplx(cmplx128_t);  break;
  case CA_CMPLX256: proc_arg_cmplx(cmplx256_t);  break;
  default: rb_raise(rb_eRuntimeError, "invalid data type");
  }

  ca_detach(ca);

  return obj;
}

#endif

void
Init_carray_numeric ()
{
  /* hack Fixnum and Bignum's "|", "&", "^", "<<", ">>" */

  id___or__ = rb_intern("__or__");
  id___and__ = rb_intern("__and__");
  id___xor__ = rb_intern("__xor__");
  id___rshift__ = rb_intern("__rshift__");
  id___lshift__ = rb_intern("__lshift__");

  CA_NAN = rb_float_new(0.0/0.0);
  CA_INF = rb_float_new(1.0/0.0);
  rb_define_const(rb_cObject, "CA_NAN", CA_NAN);
  rb_define_const(rb_cObject, "CA_INF", CA_INF);
  rb_define_global_function("nan", rb_num_nan, 0);
  rb_define_global_function("inf", rb_num_inf, 0);

  rb_define_alias(rb_cTrueClass, "__or__", "|");
  rb_define_alias(rb_cTrueClass, "__and__", "&");
  rb_define_alias(rb_cTrueClass, "__xor__", "^");

  rb_define_alias(rb_cFalseClass, "__or__", "|");
  rb_define_alias(rb_cFalseClass, "__and__", "&");
  rb_define_alias(rb_cFalseClass, "__xor__", "^");

#if RUBY_VERSION_CODE >= 240

  rb_define_alias(rb_cInteger, "__or__", "|");
  rb_define_alias(rb_cInteger, "__and__", "&");
  rb_define_alias(rb_cInteger, "__xor__", "^");
  rb_define_alias(rb_cInteger, "__lshift__", "<<");
  rb_define_alias(rb_cInteger, "__rshift__", ">>");

#else
  rb_define_alias(rb_cFixnum, "__or__", "|");
  rb_define_alias(rb_cFixnum, "__and__", "&");
  rb_define_alias(rb_cFixnum, "__xor__", "^");
  rb_define_alias(rb_cFixnum, "__lshift__", "<<");
  rb_define_alias(rb_cFixnum, "__rshift__", ">>");

  rb_define_alias(rb_cBignum, "__or__", "|");
  rb_define_alias(rb_cBignum, "__and__", "&");
  rb_define_alias(rb_cBignum, "__xor__", "^");
  rb_define_alias(rb_cBignum, "__lshift__", "<<");
  rb_define_alias(rb_cBignum, "__rshift__", ">>");
#endif

  rb_define_method(rb_cTrueClass, "|", rb_hack_or, 1);
  rb_define_method(rb_cTrueClass, "&", rb_hack_and, 1);
  rb_define_method(rb_cTrueClass, "^", rb_hack_xor, 1);
  rb_define_method(rb_cTrueClass, "*", rb_hack_star, 1);

  rb_define_method(rb_cFalseClass, "|", rb_hack_or, 1);
  rb_define_method(rb_cFalseClass, "&", rb_hack_and, 1);
  rb_define_method(rb_cFalseClass, "^", rb_hack_xor, 1);
  rb_define_method(rb_cFalseClass, "*", rb_hack_star, 1);

#if RUBY_VERSION_CODE >= 240
  rb_define_method(rb_cInteger, "|", rb_hack_or, 1);
  rb_define_method(rb_cInteger, "&", rb_hack_and, 1);
  rb_define_method(rb_cInteger, "^", rb_hack_xor, 1);
  rb_define_method(rb_cInteger, "<<", rb_hack_lshift, 1);
  rb_define_method(rb_cInteger, ">>", rb_hack_rshift, 1);
#else
  rb_define_method(rb_cFixnum, "|", rb_hack_or, 1);
  rb_define_method(rb_cFixnum, "&", rb_hack_and, 1);
  rb_define_method(rb_cFixnum, "^", rb_hack_xor, 1);
  rb_define_method(rb_cFixnum, "<<", rb_hack_lshift, 1);
  rb_define_method(rb_cFixnum, ">>", rb_hack_rshift, 1);

  rb_define_method(rb_cBignum, "|", rb_hack_or, 1);
  rb_define_method(rb_cBignum, "&", rb_hack_and, 1);
  rb_define_method(rb_cBignum, "^", rb_hack_xor, 1);
  rb_define_method(rb_cBignum, "<<", rb_hack_lshift, 1);
  rb_define_method(rb_cBignum, ">>", rb_hack_rshift, 1);
#endif

#ifdef HAVE_COMPLEX_H
  rb_define_method(rb_cCArray, "arg", rb_ca_arg, 0);
#endif

}

