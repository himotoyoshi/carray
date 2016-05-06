/* ---------------------------------------------------------------------------

  ruby_ccomplex.c

  This file is part of Ruby/CArray extension library.
  You can redistribute it and/or modify it under the terms of
  the Ruby Licence.

  Copyright (C) 2005 Hiroki Motoyoshi

---------------------------------------------------------------------------- */

#include "ruby.h"
#include "carray.h"
#include "math.h"

#ifdef HAVE_COMPLEX_H

#if RUBY_VERSION_CODE >= 190
#else
static VALUE rb_cComplex;
#endif

VALUE rb_cCComplex;

VALUE rb_ccomplex_new2 (double re, double im);

#if RUBY_VERSION_CODE >= 220
struct RComplex {
    struct RBasic basic;
    const VALUE real;
    const VALUE imag;
};
static double complex
rb_complex_to_cval (VALUE self) 
{
  struct RComplex *dat;
  double re, im;
  dat = ((struct RComplex *)(self));
  re = NUM2DBL(dat->real);
  im = NUM2DBL(dat->imag);
  return re + I * im;
}
#else
#if RUBY_VERSION_CODE >= 190
static double complex
rb_complex_to_cval (VALUE self) 
{
  double re = NUM2DBL(RCOMPLEX(self)->real);
  double im = NUM2DBL(RCOMPLEX(self)->imag);
  return re + I * im;
}
#else
static double complex
rb_complex_to_cval (VALUE self) 
{
  double re = NUM2DBL(rb_ivar_get(self, rb_intern("@real")));
  double im = NUM2DBL(rb_ivar_get(self, rb_intern("@image")));
  return re + I * im;
}
static VALUE
rb_Complex (VALUE x, VALUE y) 
{
  return rb_funcall(rb_cComplex, rb_intern("new"), 2, x, y);
}
#endif
#endif

double complex
rb_num2cc(VALUE num)
{
  if ( rb_obj_is_kind_of(num, rb_cCComplex) ) {
    double complex *cp;
    Data_Get_Struct(num, double complex, cp);
    return *cp;
  }
  switch ( TYPE(num) ) {
  case T_FIXNUM:
    return (double complex) FIX2LONG(num);
  case T_BIGNUM:
    return (double complex) rb_big2dbl(num);
  case T_FLOAT:
    return (double complex) NUM2DBL(num);
  }
  if ( rb_obj_is_kind_of(num, rb_cComplex) ) {
    return rb_complex_to_cval(num);
  }
  if ( rb_respond_to(num, rb_intern("to_c")) ) {
    return rb_complex_to_cval(rb_funcall(num, rb_intern("to_c"), 0));
  }
  if ( rb_respond_to(num, rb_intern("to_cc")) ) {
    return rb_funcall(num, rb_intern("to_cc"), 0);
  }
  if ( rb_respond_to(num, rb_intern("to_f")) ) {
    return rb_num2cc(rb_funcall(num, rb_intern("to_f"), 0));
  }
  rb_raise(rb_eRuntimeError, "can not convert to CComplex");
}

static VALUE
rb_num_to_cc (VALUE num)
{
  if ( rb_obj_is_kind_of(num, rb_cCComplex) ) {
    double complex cc = 0.0, *cp;
    cp = &cc;
    Data_Get_Struct(num, double complex, cp);
    return rb_ccomplex_new(cc);
  }
  switch ( TYPE(num) ) {
  case T_FIXNUM:
    return rb_ccomplex_new((double complex) FIX2LONG(num));
  case T_BIGNUM:
    return rb_ccomplex_new((double complex) rb_big2dbl(num));
  case T_FLOAT:
    return rb_ccomplex_new((double complex) NUM2DBL(num));
  }
  if ( rb_obj_is_kind_of(num, rb_cComplex) ) {
    return rb_ccomplex_new(rb_complex_to_cval(num));
  }
  if ( rb_respond_to(num, rb_intern("to_c")) ) {
    return rb_ccomplex_new(rb_complex_to_cval(rb_funcall(num, rb_intern("to_c"), 0)));
  }
  if ( rb_respond_to(num, rb_intern("to_f")) ) {
    return rb_ccomplex_new(NUM2DBL(rb_funcall(num, rb_intern("to_f"), 0)));
  }
  rb_raise(rb_eRuntimeError, "can not convert to CComplex");
}

VALUE
rb_ccomplex_new (double complex c)
{
  VALUE obj;
  double complex *cp;
  obj = Data_Make_Struct(rb_cCComplex, double complex, 0, xfree, cp);
  *cp = c;
  return obj;
}

VALUE
rb_ccomplex_new2 (double re, double im)
{
  VALUE obj;
  double complex *cp;
  obj = Data_Make_Struct(rb_cCComplex, double complex, 0, xfree, cp);
  *cp = re + I * im;
  return obj;
}

VALUE
rb_CComplex (int argc, VALUE *argv, VALUE self)
{
  if ( argc == 1 ) {
    return rb_ccomplex_new(NUM2CC(argv[0]));
  }
  else if ( argc == 2 ) {
    return rb_ccomplex_new2(NUM2DBL(argv[0]), NUM2DBL(argv[1]));
  }
  else {
    rb_raise(rb_eArgError, "invalid # of arguments");
  }
}

static VALUE
rb_cc_s_allocate (VALUE klass)
{
  double complex *cp;
  return Data_Make_Struct(klass, double complex, 0, xfree, cp);
}

static VALUE
rb_cc_initialize (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE rre, rim;
  double complex *cp;

  Data_Get_Struct(self, double complex, cp);

  rb_scan_args(argc, argv, "11", &rre, &rim);

  if ( NIL_P(rim) ) {
    *cp = NUM2DBL(rre);
  }
  else {
    *cp = NUM2DBL(rre) + I * NUM2DBL(rim);
  }

  return Qnil;
}

static VALUE
rb_cc_to_c (VALUE self)
{
  double complex *cp;
  Data_Get_Struct(self, double complex, cp);
  return rb_Complex(rb_float_new(creal(*cp)), rb_float_new(cimag(*cp)));
}

static VALUE
rb_complex_to_cc (VALUE self)
{
  if ( rb_obj_is_kind_of(self, rb_cCComplex) ) {
    return self;
  }
  else {
    return rb_ccomplex_new(rb_complex_to_cval(self));
  }
}


static VALUE
rb_cc_real(VALUE self)
{
  double complex *cp;

  Data_Get_Struct(self, double complex, cp);

  return rb_float_new(creal(*cp));
}

static VALUE
rb_cc_imag(VALUE self)
{
  double complex *cp;

  Data_Get_Struct(self, double complex, cp);

  return rb_float_new(cimag(*cp));
}

static VALUE
rb_cc_inspect (VALUE self)
{
  volatile VALUE vary = rb_ary_new(), rim;
  double complex *cp;
  double re, im;

  Data_Get_Struct(self, double complex, cp);

  re = creal(*cp);
  im = cimag(*cp);

  rb_ary_push(vary, rb_inspect(rb_float_new(re)));

  rim = rb_inspect(rb_float_new(im));

  if ( StringValuePtr(rim)[0] != '-' ) {
    rb_ary_push(vary, rb_str_new2("+"));
  }

  rb_ary_push(vary, rim);
  rb_ary_push(vary, rb_str_new2("i"));

  return rb_ary_join(vary, Qnil);
}

static VALUE
rb_cc_conj(VALUE self)
{
  double complex *cp;

  Data_Get_Struct(self, double complex, cp);

  return CC2NUM(conj(*cp));
}

static VALUE
rb_cc_arg(VALUE self)
{
  double complex *cp;

  Data_Get_Struct(self, double complex, cp);

  return rb_float_new(carg(*cp));
}

static VALUE
rb_cc_abs(VALUE self)
{
  double complex *cp;

  Data_Get_Struct(self, double complex, cp);

  return rb_float_new(cabs(*cp));
}

static VALUE
rb_cc_coerce(VALUE self, VALUE other)
{
  VALUE argv[1];

  if ( rb_obj_is_kind_of(other, rb_cNumeric) ) {
    return rb_assoc_new(CC2NUM(NUM2CC(other)), self);
  }

  argv[0] = other;
  return rb_call_super(1, argv);
}

static VALUE
rb_cc_equal(VALUE self, VALUE other)
{
  double complex a, b;

  if ( rb_obj_is_kind_of(other, rb_cNumeric) ) {
    a = NUM2CC(self);
    b = NUM2CC(other);
    return ( a == b ) ? Qtrue : Qfalse;
  }
  else {
    return rb_funcall(other, rb_intern("=="), 1, self);
  }
}

static VALUE
rb_cc_uminus(VALUE self)
{
  return CC2NUM( - NUM2CC(self) );
}

static VALUE
rb_cc_plus(VALUE self, VALUE other)
{
  double complex a, b;

  if ( rb_obj_is_kind_of(other, rb_cNumeric) ) {
    a = NUM2CC(self);
    b = NUM2CC(other);
    return CC2NUM( a + b );
  }
  else {
#if RUBY_VERSION_CODE >= 190
    return rb_num_coerce_bin(self, other, '+');
#else
    return rb_num_coerce_bin(self, other);
#endif
  }
}

static VALUE
rb_cc_minus(VALUE self, VALUE other)
{
  double complex a, b;

  if ( rb_obj_is_kind_of(other, rb_cNumeric) ) {
    a = NUM2CC(self);
    b = NUM2CC(other);
    return CC2NUM( a - b );
  }
  else {
#if RUBY_VERSION_CODE >= 190
    return rb_num_coerce_bin(self, other, '-');
#else
    return rb_num_coerce_bin(self, other);
#endif
  }
}

static VALUE
rb_cc_asterisk(VALUE self, VALUE other)
{
  double complex a, b;

  if ( rb_obj_is_kind_of(other, rb_cNumeric) ) {
    a = NUM2CC(self);
    b = NUM2CC(other);
    return CC2NUM( a * b );
  }
  else {
#if RUBY_VERSION_CODE >= 190
    return rb_num_coerce_bin(self, other, '*');
#else
    return rb_num_coerce_bin(self, other);
#endif
  }
}

static VALUE
rb_cc_slash(VALUE self, VALUE other)
{
  double complex a, b;

  if ( rb_obj_is_kind_of(other, rb_cNumeric) ) {
    a = NUM2CC(self);
    b = NUM2CC(other);
    return CC2NUM( a / b );
  }
  else {
#if RUBY_VERSION_CODE >= 190
    return rb_num_coerce_bin(self, other, '/');
#else
    return rb_num_coerce_bin(self, other);
#endif
  }
}

static VALUE
rb_cc_star2(VALUE self, VALUE other)
{
  double complex a, b;

  if ( rb_obj_is_kind_of(other, rb_cNumeric) ) {
    a = NUM2CC(self);
    b = NUM2CC(other);
    return CC2NUM( cpow(a, b) );
  }
  else {
#if RUBY_VERSION_CODE >= 190
    return rb_num_coerce_bin(self, other, rb_intern("**"));
#else
    return rb_num_coerce_bin(self, other);
#endif
  }
}

static VALUE rb_cc_cos   (VALUE self) { return CC2NUM(ccos(NUM2CC(self))); }
static VALUE rb_cc_sin   (VALUE self) { return CC2NUM(csin(NUM2CC(self))); }
static VALUE rb_cc_tan   (VALUE self) { return CC2NUM(ctan(NUM2CC(self))); }

static VALUE rb_cc_acos  (VALUE self) { return CC2NUM(cacos(NUM2CC(self))); }
static VALUE rb_cc_asin  (VALUE self) { return CC2NUM(casin(NUM2CC(self))); }
static VALUE rb_cc_atan  (VALUE self) { return CC2NUM(catan(NUM2CC(self))); }

static VALUE rb_cc_cosh  (VALUE self) { return CC2NUM(ccosh(NUM2CC(self))); }
static VALUE rb_cc_sinh  (VALUE self) { return CC2NUM(csinh(NUM2CC(self))); }
static VALUE rb_cc_tanh  (VALUE self) { return CC2NUM(ctanh(NUM2CC(self))); }

static VALUE rb_cc_acosh (VALUE self) { return CC2NUM(cacosh(NUM2CC(self))); }
static VALUE rb_cc_asinh (VALUE self) { return CC2NUM(casinh(NUM2CC(self))); }
static VALUE rb_cc_atanh (VALUE self) { return CC2NUM(catanh(NUM2CC(self))); }

static VALUE rb_cc_exp   (VALUE self) { return CC2NUM(cexp(NUM2CC(self))); }
static VALUE rb_cc_log   (VALUE self) { return CC2NUM(clog(NUM2CC(self))); }
static VALUE rb_cc_sqrt  (VALUE self) { return CC2NUM(csqrt(NUM2CC(self))); }

void
Init_ccomplex ()
{
#if RUBY_VERSION_CODE >= 190
#else
  rb_cComplex = rb_const_get(rb_cObject, rb_intern("Complex"));
#endif

  rb_cCComplex = rb_define_class("CComplex", rb_cNumeric);

  rb_define_method(rb_cComplex, "to_cc", rb_complex_to_cc, 0);
  rb_define_method(rb_cNumeric, "to_cc", rb_num_to_cc, 0);

  rb_define_global_function("CComplex", rb_CComplex, -1);

  rb_define_alloc_func(rb_cCComplex, rb_cc_s_allocate);
  rb_define_method(rb_cCComplex, "initialize", rb_cc_initialize, -1);
  rb_define_method(rb_cCComplex, "to_c", rb_cc_to_c, 0);
  rb_define_method(rb_cCComplex, "real", rb_cc_real, 0);
  rb_define_method(rb_cCComplex, "imag", rb_cc_imag, 0);
  rb_define_method(rb_cCComplex, "inspect", rb_cc_inspect, 0);
  rb_define_method(rb_cCComplex, "to_s", rb_cc_inspect, 0);

  rb_define_method(rb_cCComplex, "conj", rb_cc_conj, 0);
  rb_define_method(rb_cCComplex, "arg", rb_cc_arg, 0);
  rb_define_method(rb_cCComplex, "abs", rb_cc_abs, 0);

  rb_define_method(rb_cCComplex, "coerce", rb_cc_coerce, 1);

  rb_define_method(rb_cCComplex, "==", rb_cc_equal, 1);
  rb_define_method(rb_cCComplex, "-@", rb_cc_uminus, 1);
  rb_define_method(rb_cCComplex, "+", rb_cc_plus, 1);
  rb_define_method(rb_cCComplex, "-", rb_cc_minus, 1);
  rb_define_method(rb_cCComplex, "*", rb_cc_asterisk, 1);
  rb_define_method(rb_cCComplex, "/", rb_cc_slash, 1);
  rb_define_method(rb_cCComplex, "**", rb_cc_star2, 1);

  rb_define_method(rb_cCComplex, "sqrt", rb_cc_sqrt, 0);
  rb_define_method(rb_cCComplex, "exp", rb_cc_exp, 0);
  rb_define_method(rb_cCComplex, "log", rb_cc_log, 0);
  rb_define_method(rb_cCComplex, "cos", rb_cc_cos, 0);
  rb_define_method(rb_cCComplex, "sin", rb_cc_sin, 0);
  rb_define_method(rb_cCComplex, "tan", rb_cc_tan, 0);
  rb_define_method(rb_cCComplex, "cosh", rb_cc_cosh, 0);
  rb_define_method(rb_cCComplex, "sinh", rb_cc_sinh, 0);
  rb_define_method(rb_cCComplex, "tanh", rb_cc_tanh, 0);
  rb_define_method(rb_cCComplex, "acos", rb_cc_acos, 0);
  rb_define_method(rb_cCComplex, "asin", rb_cc_asin, 0);
  rb_define_method(rb_cCComplex, "atan", rb_cc_atan, 0);
  rb_define_method(rb_cCComplex, "acosh", rb_cc_acosh, 0);
  rb_define_method(rb_cCComplex, "asinh", rb_cc_asinh, 0);
  rb_define_method(rb_cCComplex, "atanh", rb_cc_atanh, 0);

  rb_define_const(rb_cObject, "CI", CC2NUM(I));

}

#else

void
Init_ccomplex () {}

#endif
