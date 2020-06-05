# ----------------------------------------------------------------------------
#
#  carray_math.rb
#
#  This file is part of Ruby/CArray extension library.
#  You can redistribute it and/or modify it under the terms of
#  the Ruby Licence.
#
#  Copyright (C) 2005 Hiroki Motoyoshi
#
# ----------------------------------------------------------------------------

require './mkmath.rb'

HEADERS << <<HERE_END
/* ---------------------------------------------------------------------------

  carray_math.c

  This file is part of Ruby/CArray extension library.
  You can redistribute it and/or modify it under the terms of
  the Ruby Licence.

  This file is automatically generated from carray_math.rb.

  Copyright (C) 2005 Hiroki Motoyoshi

---------------------------------------------------------------------------- */

#ifdef HAVE_TGMATH_H
#include <tgmath.h>
#endif

#include "ruby.h"

static ID id_equal, id_lt, id_le, id_gt, id_ge;
static ID id_uminus, id_utilda;
static ID id_plus, id_minus, id_star, id_slash, id_percent, id_star_star;
static ID id_and, id_or, id_xor, id_lshift, id_rshift;

HERE_END

monop("zero", "zero",
      BOOL_TYPES => "(#2) = 0;",
      ALL_TYPES => "(#2) = 0;",
      CMPLX_TYPES => HAVE_COMPLEX ? "(#2) = 0.0;" : nil,
      OBJ_TYPES => '(#2) = 1;')

monop("one", "one",
      BOOL_TYPES => "(#2) = 1;",
      ALL_TYPES => "(#2) = 1;",
      CMPLX_TYPES => HAVE_COMPLEX ? "(#2) = 1.0;" : nil,
      OBJ_TYPES => '(#2) = 3;')

monop("frac", "frac",
      INT_TYPES =>
        %{(#2) = 0; },
      FLOAT_TYPES =>
        %{(#2) = ((#1)>0.0) ? (#1)-floor(#1) : ((#1)<0.0) ? (#1)-ceil(#1) : 0.0; },
      OBJ_TYPES => '(#2) = rb_funcall((#1), rb_intern("frac"), 0);')

monop("neg", "neg",
      ALL_TYPES => "(#2) = -(#1);",
      CMPLX_TYPES => HAVE_COMPLEX ? "(#2) = -(#1);" : nil,
      OBJ_TYPES => '(#2) = rb_funcall((#1), id_uminus, 0);')

monop("bit_neg", "bit_neg",
      BOOL_TYPES => "(#2) = (#1) ? 0 : 1;",
      INT_TYPES => "(#2) = ~(#1);",
      OBJ_TYPES => '(#2) = rb_funcall((#1), id_utilda, 0);')

alias_op("-@", "neg")
alias_op("~", "bit_neg")

monop("abs_i", "abs_i",
      INT_TYPES   => "(#2) = abs(#1);",
      FLOAT_TYPES => "(#2) = fabs((float64_t)#1);",
      CMPLX_TYPES => HAVE_COMPLEX ? "(#2) = cabs((cmplx128_t)#1);" : nil,
      OBJ_TYPES   => '(#2) = rb_funcall((#1), rb_intern("abs"), 0);')

DEFINITIONS << %{

static VALUE
rb_ca_abs (VALUE self)
{
  CArray *ca;

  Data_Get_Struct(self, CArray, ca);
  if ( ca_is_complex_type(ca) ) {
    VALUE ret = rb_ca_abs_i(self);
    return rb_ca_copy(rb_funcall(ret, rb_intern("real"), 0));
  }
  else {
    return rb_ca_abs_i(self);
  }
}

static VALUE
rb_ca_abs_bang (VALUE self)
{
  CArray *ca;
  rb_ca_modify(self);
  Data_Get_Struct(self, CArray, ca);
  if ( ca_is_complex_type(ca) ) {
    VALUE ret = rb_ca_abs_i(self);
    return rb_funcall(self, rb_intern("[]="), 1, ret);
  }
  else {
    return rb_ca_abs_i_bang(self);
  }
}

static VALUE rb_cmath_abs (VALUE mod, VALUE arg)
{ return rb_ca_abs(arg); }

}

METHODS << %{
  rb_define_method(rb_cCArray, "abs", rb_ca_abs, 0);
  rb_define_method(rb_cCArray, "abs!", rb_ca_abs_bang, 0);
  rb_define_module_function(rb_mCAMath, "abs", rb_cmath_abs, 1);
}

monop("conj", "conj",
      ALL_TYPES => "(#2) = (#1);",
      CMPLX_TYPES => HAVE_COMPLEX ? "(#2) = conj(#1);" : nil,
      OBJ_TYPES   => '(#2) = rb_funcall((#1), rb_intern("conj"), 0);')

monfunc("rad", "rad",
      FLOAT_TYPES => "(#2) = (0.0174532925199433*(#1));",
      OBJ_TYPES   => '(#2) = rb_funcall((#1), rb_intern("rad"), 0);')
monfunc("deg", "deg",
      FLOAT_TYPES => "(#2) = (57.2957795130823*(#1));",
      OBJ_TYPES   => '(#2) = rb_funcall((#1), rb_intern("deg"), 0);')
monfunc("ceil", "ceil",
      INT_TYPES => "(#2) = (#1);",
      FLOAT_TYPES => "(#2) = ceil(#1);",
      OBJ_TYPES   => '(#2) = rb_funcall((#1), rb_intern("ceil"), 0);')
monfunc("floor", "floor",
      INT_TYPES => "(#2) = (#1);",
      FLOAT_TYPES => "(#2) = floor(#1);",
      OBJ_TYPES   => '(#2) = rb_funcall((#1), rb_intern("floor"), 0);')
monfunc("round", "round",
      INT_TYPES => "(#2) = (#1);",
      FLOAT_TYPES => %{(#2) = ((#1)>0.0) ? floor((#1)+0.5) : ((#1)<0.0) ? ceil((#1)-0.5) : 0.0; },
      OBJ_TYPES   => '(#2) = rb_funcall((#1), rb_intern("round"), 0);')
monfunc("rcp", "rcp",
      INT_TYPES => "if ((#1)==0) {ca_zerodiv();}; (#2) = 1/(#1);",
      FLOAT_TYPES => "(#2) = 1/(#1);",
      CMPLX_TYPES => HAVE_COMPLEX ? "(#2) = 1/(#1);" : nil,
      OBJ_TYPES => '(#2) = rb_funcall(INT2NUM(1), id_slash, 1, (#1));')
monfunc("sqrt", "sqrt",
      FLOAT_TYPES => "(#2) = sqrt(#1);",
      CMPLX_TYPES => HAVE_COMPLEX ? "(#2) = csqrt(#1);" : nil,
      OBJ_TYPES   => '(#2) = rb_funcall((#1), rb_intern("sqrt"), 0);')
monfunc("exp", "exp",
      FLOAT_TYPES => "(#2) = exp(#1);",
      CMPLX_TYPES => HAVE_COMPLEX ? "(#2) = cexp(#1);" : nil,
      OBJ_TYPES   => '(#2) = rb_funcall((#1), rb_intern("exp"), 0);')
monfunc("exp10", "exp10",
      FLOAT_TYPES => "(#2) = pow(10, (#1));",
      CMPLX_TYPES => HAVE_COMPLEX ? "(#2) = cpow(10, (#1));" : nil,
      OBJ_TYPES   => '(#2) = rb_funcall(INT2NUM(10), id_star_star, 1, (#1));')
monfunc("log", "log",
      FLOAT_TYPES => "(#2) = log(#1);",
      CMPLX_TYPES => HAVE_COMPLEX ? "(#2) = clog(#1);" : nil,
      OBJ_TYPES   => '(#2) = rb_funcall((#1), rb_intern("log"), 0);')
monfunc("log10", "log10",
      FLOAT_TYPES => "(#2) = log10(#1);",
      OBJ_TYPES   => '(#2) = rb_funcall((#1), rb_intern("log10"), 0);')
monfunc("sin", "sin",
      FLOAT_TYPES => "(#2) = sin(#1);",
      CMPLX_TYPES => HAVE_COMPLEX ? "(#2) = csin(#1);" : nil,
      OBJ_TYPES   => '(#2) = rb_funcall((#1), rb_intern("sin"), 0);')
monfunc("cos", "cos",
      FLOAT_TYPES => "(#2) = cos(#1);",
      CMPLX_TYPES => HAVE_COMPLEX ? "(#2) = ccos(#1);" : nil,
      OBJ_TYPES   => '(#2) = rb_funcall((#1), rb_intern("cos"), 0);')
monfunc("tan", "tan",
      FLOAT_TYPES => "(#2) = tan(#1);",
      CMPLX_TYPES => HAVE_COMPLEX ? "(#2) = ctan(#1);" : nil,
      OBJ_TYPES   => '(#2) = rb_funcall((#1), rb_intern("tan"), 0);')
monfunc("asin", "asin",
      FLOAT_TYPES => "(#2) = asin(#1);",
      CMPLX_TYPES => HAVE_COMPLEX ? "(#2) = casin(#1);" : nil,
      OBJ_TYPES   => '(#2) = rb_funcall((#1), rb_intern("asin"), 0);')
monfunc("acos", "acos",
      FLOAT_TYPES => "(#2) = acos(#1);",
      CMPLX_TYPES => HAVE_COMPLEX ? "(#2) = cacos(#1);" : nil,
      OBJ_TYPES   => '(#2) = rb_funcall((#1), rb_intern("acos"), 0);')
monfunc("atan", "atan",
      FLOAT_TYPES => "(#2) = atan(#1);",
      CMPLX_TYPES => HAVE_COMPLEX ? "(#2) = catan(#1);" : nil,
      OBJ_TYPES   => '(#2) = rb_funcall((#1), rb_intern("atan"), 0);')
monfunc("sinh", "sinh",
      FLOAT_TYPES => "(#2) = sinh(#1);",
      CMPLX_TYPES => HAVE_COMPLEX ? "(#2) = sinh(#1);" : nil,
      OBJ_TYPES   => '(#2) = rb_funcall((#1), rb_intern("sinh"), 0);')
monfunc("cosh", "cosh",
      FLOAT_TYPES => "(#2) = cosh(#1);",
      CMPLX_TYPES => HAVE_COMPLEX ? "(#2) = cosh(#1);" : nil,
      OBJ_TYPES   => '(#2) = rb_funcall((#1), rb_intern("cosh"), 0);')
monfunc("tanh", "tanh",
      FLOAT_TYPES => "(#2) = tanh(#1);",
      CMPLX_TYPES => HAVE_COMPLEX ? "(#2) = tanh(#1);" : nil,
      OBJ_TYPES   => '(#2) = rb_funcall((#1), rb_intern("tanh"), 0);')
monfunc("asinh", "asinh",
      FLOAT_TYPES => "(#2) = asinh(#1);",
      CMPLX_TYPES => HAVE_COMPLEX ? "(#2) = asinh(#1);" : nil,
      OBJ_TYPES   => '(#2) = rb_funcall((#1), rb_intern("asinh"), 0);')
monfunc("acosh", "acosh",
      FLOAT_TYPES => "(#2) = acosh(#1);",
      CMPLX_TYPES => HAVE_COMPLEX ? "(#2) = acosh(#1);" : nil,
      OBJ_TYPES   => '(#2) = rb_funcall((#1), rb_intern("acosh"), 0);')
monfunc("atanh", "atanh",
      FLOAT_TYPES => "(#2) = atanh(#1);",
      CMPLX_TYPES => HAVE_COMPLEX ? "(#2) = atanh(#1);" : nil,
      OBJ_TYPES   => '(#2) = rb_funcall((#1), rb_intern("atanh"), 0);')


binop("pmax", "pmax",
      ALL_TYPES =>"(#3) = (#1) > (#2) ? (#1) : (#2);",
      CMPLX_TYPES => nil,
      OBJ_TYPES =>'(#3) = rb_funcall(rb_assoc_new((#1),(#2)), rb_intern("max"), 0);')

binop("pmin", "pmin",
      ALL_TYPES =>"(#3) = (#1) < (#2) ? (#1) : (#2);",
      CMPLX_TYPES => nil,
      OBJ_TYPES =>'(#3) = rb_funcall(rb_assoc_new((#1),(#2)), rb_intern("min"), 0);')

binop("+", "add",
      ALL_TYPES =>"(#3) = (#1) + (#2);",
      CMPLX_TYPES => HAVE_COMPLEX ? "(#3) = (#1) + (#2);" : nil,
      OBJ_TYPES =>'(#3) = rb_funcall((#1), id_plus, 1, (#2));')

binop("-", "sub",
      ALL_TYPES => "(#3) = (#1) - (#2);",
      CMPLX_TYPES => HAVE_COMPLEX ? "(#3) = (#1) - (#2);" : nil,
      OBJ_TYPES => '(#3) = rb_funcall((#1), id_minus, 1, (#2));')

binop("*", "mul",
      ALL_TYPES => "(#3) = (#1) * (#2);",
      CMPLX_TYPES => HAVE_COMPLEX ? "(#3) = (#1) * (#2);" : nil,
      OBJ_TYPES => '(#3) = rb_funcall((#1), id_star, 1, (#2));')

binop("/", "div",
      INT_TYPES => "if ((#2)==0) {ca_zerodiv();}; (#3) = (#1) / (#2);",
      FLOAT_TYPES => "(#3) = (#1) / (#2);",
      CMPLX_TYPES => HAVE_COMPLEX ? "(#3) = (#1) / (#2);" : nil,
      OBJ_TYPES => '(#3) = rb_funcall((#1), id_slash, 1, (#2));')

binop("quo_i", nil,
      OBJ_TYPES => '(#3) = rb_funcall((#1), rb_intern("quo"), 1, (#2));')

binop("rcp_mul", "rcp_mul",
      INT_TYPES => "if ((#1)==0) {ca_zerodiv();}; (#3) = (#2) / (#1);",
      FLOAT_TYPES => "(#3) = (#2) / (#1);",
      CMPLX_TYPES => HAVE_COMPLEX ? "(#3) = (#2) / (#1);" : nil,
      OBJ_TYPES => '(#3) = rb_funcall((#2), id_slash, 1, (#1));')

binop("%", "mod",
      INT_TYPES => "if ((#2)==0) {ca_zerodiv();}; (#3) = (#1) % (#2);",
      OBJ_TYPES => '(#3) = rb_funcall((#1), id_percent, 1, (#2));')

binop("&", "bit_and_i",
      BOOL_TYPES => "(#3) = (#1) & (#2);",
      INT_TYPES => "(#3) = (#1) & (#2);",
      OBJ_TYPES => '(#3) = rb_funcall((#1), id_and, 1, (#2));')

binop("|", "bit_or_i",
      BOOL_TYPES => "(#3) = (#1) | (#2);",
      INT_TYPES => "(#3) = (#1) | (#2);",
      OBJ_TYPES => '(#3) = rb_funcall((#1), id_or, 1, (#2));')

binop("^", "bit_xor_i",
      BOOL_TYPES => "(#3) = ((#1) != (#2)) ? 1 : 0;",
      INT_TYPES => "(#3) = (#1) ^ (#2);",
      OBJ_TYPES => '(#3) = rb_funcall((#1), id_xor, 1, (#2));')

DEFINITIONS << %q{

static VALUE
rb_ca_bit_and (VALUE self, VALUE other)
{
  if ( rb_ca_is_boolean_type(self) ) {
    return rb_ca_bit_and_i(self, rb_ca_wrap_readonly(other, INT2NUM(CA_BOOLEAN)));
  }
  else if ( rb_obj_is_carray(other) && rb_ca_is_boolean_type(other) ) {
    return rb_ca_bit_and_i(rb_ca_wrap_readonly(self, INT2NUM(CA_BOOLEAN)), other);
  }
  else {
    return rb_ca_bit_and_i(self, other);
  }
}

static VALUE
rb_ca_bit_or (VALUE self, VALUE other)
{
  if ( rb_ca_is_boolean_type(self) ) {
    return rb_ca_bit_or_i(self, rb_ca_wrap_readonly(other, INT2NUM(CA_BOOLEAN)));
  }
  else if ( rb_obj_is_carray(other) && rb_ca_is_boolean_type(other) ) {
    return rb_ca_bit_or_i(rb_ca_wrap_readonly(self, INT2NUM(CA_BOOLEAN)), other);
  }
  else {
    return rb_ca_bit_or_i(self, other);
  }
}

static VALUE
rb_ca_bit_xor (VALUE self, VALUE other)
{
  if ( rb_ca_is_boolean_type(self) ) {
    return rb_ca_bit_xor_i(self, rb_ca_wrap_readonly(other, INT2NUM(CA_BOOLEAN)));
  }
  else if ( rb_obj_is_carray(other) && rb_ca_is_boolean_type(other) ) {
    return rb_ca_bit_xor_i(rb_ca_wrap_readonly(self, INT2NUM(CA_BOOLEAN)), other);
  }
  else {
    return rb_ca_bit_xor_i(self, other);
  }
}

}

METHODS << %{
  rb_define_method(rb_cCArray, "bit_and", rb_ca_bit_and, 1);
  rb_define_method(rb_cCArray, "bit_or", rb_ca_bit_or, 1);
  rb_define_method(rb_cCArray, "bit_xor", rb_ca_bit_xor, 1);
}

binop("<<", "bit_lshift",
      INT_TYPES => "(#3) = (#1) << (#2);",
      OBJ_TYPES => '(#3) = rb_funcall((#1), id_lshift, 1, (#2));')

binop(">>", "bit_rshift",
      INT_TYPES => "(#3) = (#1) >> (#2);",
      OBJ_TYPES => '(#3) = rb_funcall((#1), id_rshift, 1, (#2));')

bincmp("feq", "feq",
       FLOAT_TYPES => %{
         <type> f1a = fabs((float64_t) #1);
         <type> f2a = fabs((float64_t) #2);
         <type> fmax = (f1a > f2a) ? f1a : f2a;
         (#3) = ( fabs(((float64_t) #1)-( (float64_t) #2)) <= fmax * <epsilon> ) ? 1 : 0;
       }
       )

bincmp("eq", "eq",
       FIXLEN_TYPES => "(#3) = ( b1 == b2 && (! memcmp(p1, p2, b1)) );",
       BOOL_TYPES => "(#3) = ( (#1) == (#2) );",
       ALL_TYPES => "(#3) = ( (#1) == (#2) );",
       CMPLX_TYPES => HAVE_COMPLEX ? "(#3) = (#1) == (#2);" : nil,
       OBJ_TYPES => '(#3) = rb_funcall((#1), id_equal, 1, (#2)) ? 1 : 0;')

bincmp("ne", "ne",
       FIXLEN_TYPES => "(#3) = ( b1 != b2 || memcmp(p1, p2, b1) );",
       BOOL_TYPES => "(#3) = ( (#1) != (#2) );",
       ALL_TYPES => "(#3) = ( (#1) != (#2) );",
       CMPLX_TYPES => HAVE_COMPLEX ? "(#3) = (#1) != (#2);" : nil,
       OBJ_TYPES => '(#3) = rb_funcall((#1), id_equal, 1, (#2)) ? 0 : 1;')

bincmp("gt", "gt",
       FIXLEN_TYPES => %Q{
         int cmp = memcmp(p1, p2, b1 < b2 ? b1 : b2) ;
         (#3) = ( cmp > 0 || ( cmp == 0 && b1 > b2 ) );
       },
       ALL_TYPES => "(#3) = ( (#1) > (#2) );",
       OBJ_TYPES => '(#3) = rb_funcall((#1), id_gt, 1, (#2)) ? 1 : 0;')

bincmp("lt", "lt",
       FIXLEN_TYPES => %Q{
         int cmp = memcmp(p1, p2, b1 < b2 ? b1 : b2) ;
         (#3) = ( cmp < 0 || ( cmp == 0 && b1 < b2 ) );
       },
       ALL_TYPES => "(#3) = ( (#1) < (#2) );",
       OBJ_TYPES => '(#3) = rb_funcall((#1), id_lt, 1, (#2)) ? 1 : 0;')

bincmp("ge", "ge",
       FIXLEN_TYPES => %Q{
         int cmp = memcmp(p1, p2, b1 < b2 ? b1 : b2) ;
         (#3) = ( cmp > 0 || ( cmp == 0 && b1 >= b2 ) );
       },
       ALL_TYPES => "(#3) = ( (#1) >= (#2) );",
       OBJ_TYPES => '(#3) = rb_funcall((#1), id_ge, 1, (#2)) ? 1 : 0;')

bincmp("le", "le",
       FIXLEN_TYPES => %Q{
         int cmp = memcmp(p1, p2, b1 < b2 ? b1 : b2) ;
         (#3) = ( cmp < 0 || ( cmp == 0 && b1 <= b2 ) );
       },
       ALL_TYPES => "(#3) = ( (#1) <= (#2) );",
       OBJ_TYPES => '(#3) = rb_funcall((#1), id_le, 1, (#2)) ? 1 : 0;')

monop("not", "not",
      BOOL_TYPES => "(#2) = (#1) ? 0 : 1;",
      OBJ_TYPES  => "(#2) = (RTEST(#1)) ? Qfalse : Qtrue;")

binop("and", "and_i",
      BOOL_TYPES => "(#3) = (#1) && (#2);",
      OBJ_TYPES => '(#3) = ((RTEST(#1)!=0) && (RTEST(#2)!=0)) ? Qtrue : Qfalse;')

binop("or",  "or_i" ,
      BOOL_TYPES => "(#3) = (#1) || (#2);",
      OBJ_TYPES => '(#3) = ((RTEST(#1)!=0) || (RTEST(#2)!=0)) ? Qtrue : Qfalse;')

binop("xor", "xor_i",
      BOOL_TYPES => "(#3) = (((#1)==0) == ((#2)==0)) ? 0 : 1;",
      OBJ_TYPES  => "(#3) = ((RTEST(#1)) == (RTEST(#2))) ? Qfalse : Qtrue;")


DEFINITIONS << %q{

static VALUE
rb_ca_and (VALUE self, VALUE other)
{
  if ( rb_ca_is_boolean_type(self) ) {
    return rb_ca_and_i(self, rb_ca_wrap_readonly(other, INT2NUM(CA_BOOLEAN)));
  }
  else if ( rb_obj_is_carray(other) && rb_ca_is_boolean_type(other) ) {
    return rb_ca_and_i(rb_ca_wrap_readonly(self, INT2NUM(CA_BOOLEAN)), other);
  }
  else {
    return rb_ca_and_i(self, other);
  }
}

static VALUE
rb_ca_or (VALUE self, VALUE other)
{
  if ( rb_ca_is_boolean_type(self) ) {
    return rb_ca_or_i(self, rb_ca_wrap_readonly(other, INT2NUM(CA_BOOLEAN)));
  }
  else if ( rb_obj_is_carray(other) && rb_ca_is_boolean_type(other) ) {
    return rb_ca_or_i(rb_ca_wrap_readonly(self, INT2NUM(CA_BOOLEAN)), other);
  }
  else {
    return rb_ca_or_i(self, other);
  }
}

static VALUE
rb_ca_xor (VALUE self, VALUE other)
{
  if ( rb_ca_is_boolean_type(self) ) {
    return rb_ca_xor_i(self, rb_ca_wrap_readonly(other, INT2NUM(CA_BOOLEAN)));
  }
  else if ( rb_obj_is_carray(other) && rb_ca_is_boolean_type(other) ) {
    return rb_ca_xor_i(rb_ca_wrap_readonly(self, INT2NUM(CA_BOOLEAN)), other);
  }
  else {
    return rb_ca_xor_i(self, other);
  }
}

}

METHODS << %{
  rb_define_method(rb_cCArray, "and", rb_ca_and, 1);
  rb_define_method(rb_cCArray, "or", rb_ca_or, 1);
  rb_define_method(rb_cCArray, "xor", rb_ca_xor, 1);
}

alias_op("add", "+")
alias_op("sub", "-")
alias_op("mul", "*")
alias_op("div", "/")
alias_op("mod", "%")
alias_op("bit_and", "&")
alias_op("bit_or", "|")
alias_op("bit_xor", "^")
alias_op("bit_lshift", "<<")
alias_op("bit_rshift", ">>")

#alias_op("==", "eq")
#alias_op("!=", "ne")
alias_op(">", "gt")
alias_op("<", "lt")
alias_op(">=", "ge")
alias_op("<=", "le")

moncmp("is_nan", "is_nan",
       INT_TYPES => "(#2) = 0;",
       FLOAT_TYPES => "(#2) = isnan(#1);",
       OBJ_TYPES   => '(#2) = rb_funcall((#1), rb_intern("nan?"), 0);')

moncmp("is_inf", "is_inf",
       INT_TYPES => "(#2) = 0;",
       FLOAT_TYPES => "(#2) = isinf(#1);",
       OBJ_TYPES   => '(#2) = rb_funcall((#1), rb_intern("infinite?"), 0);')

moncmp("is_finite", "is_finite",
       INT_TYPES => "(#2) = 1;",
       FLOAT_TYPES => "(#2) = isfinite(#1);",
       OBJ_TYPES   => '(#2) = rb_funcall((#1), rb_intern("finite?"), 0);')

bincmp("match", "match",
       FIXLEN_TYPES => %Q{
         (#3) = RTEST(rb_funcall(rb_str_new(p1,b1), rb_intern("=~"), 1, (#2)));
       },
       OBJ_TYPES => '(#3) = RTEST(rb_funcall((#1), rb_intern("=~"), 1, (#2)));')

bincmp("is_kind_of", "is_kind_of",
       OBJ_TYPES => '(#3) = RTEST(rb_obj_is_kind_of((#1), (#2)));')

alias_op("=~", "match")

DEFINITIONS << %q{

#define op_powi(type) \
static type \
op_powi_## type (type x, int32_t p) \
{ \
  type r=1; \
\
  switch(p) { \
  case 2: return x*x; \
  case 3: return x*x*x; \
  case 0: return 1; \
  case 1: return x; \
  } \
  if (p<0) { \
    type den = op_powi_## type(x, -p); \
    if (den==0) ca_zerodiv(); \
    return 1/den; \
  }\
  while (p) { \
    if ( (p%2) == 1 ) r *= x; \
    x *= x; \
    p /= 2; \
  } \
  return r; \
}

#define op_powi_fc(type) \
static type \
op_powi_## type (type x, int32_t p) \
{ \
  type r=1; \
\
  switch(p) { \
  case 2: return x*x; \
  case 3: return x*x*x; \
  case 0: return 1; \
  case 1: return x; \
  } \
  if (p<0) { \
    type den = op_powi_## type(x, -p); \
    return 1/den; \
  }\
  while (p) { \
    if ( (p%2) == 1 ) r *= x; \
    x *= x; \
    p /= 2; \
  } \
  return r; \
}

op_powi(int8_t);
op_powi(uint8_t);
op_powi(int16_t);
op_powi(uint16_t);
op_powi(int32_t);
op_powi(uint32_t);
op_powi(int64_t);
op_powi(uint64_t);
op_powi_fc(float32_t);
op_powi_fc(float64_t);
op_powi_fc(float128_t);
op_powi_fc(cmplx64_t);
op_powi_fc(cmplx128_t);

static void
ca_ipower_float32_t (ca_size_t n, boolean8_t *m,
                     char *ptr1, int32_t ipow, char *ptr2)
{
  float32_t *p1 = (float32_t *) ptr1, *p2 = (float32_t *) ptr2;
  if ( m ) {
    while (n--) {
      if ( ! *m++ ) { *p2 = op_powi_float32_t(*p1, ipow); }
      p1++; p2++;
    }
  }
  else
    while (n--) { (*p2) = op_powi_float32_t(*p1, ipow); p1++; p2++; }
}

static void
ca_ipower_float64_t (ca_size_t n, boolean8_t *m,
                     char *ptr1, int32_t ipow, char *ptr2)
{
  float64_t *p1 = (float64_t *) ptr1, *p2 = (float64_t *) ptr2;
  if ( m ) {
    while (n--) {
      if ( ! *m++ ) { *p2 = op_powi_float64_t(*p1, ipow); }
      p1++; p2++;
    }
  }
  else
    while (n--) { (*p2) = op_powi_float64_t(*p1, ipow); p1++; p2++; }
}

static void
ca_ipower_float128_t (ca_size_t n, boolean8_t *m,
                     char *ptr1, int32_t ipow, char *ptr2)
{
  float128_t *p1 = (float128_t *) ptr1, *p2 = (float128_t *) ptr2;
  if ( m ) {
    while (n--) {
      if ( ! *m++ ) { *p2 = op_powi_float128_t(*p1, ipow); }
      p1++; p2++;
    }
  }
  else
    while (n--) { (*p2) = op_powi_float128_t(*p1, ipow); p1++; p2++; }
}

static void
ca_ipower_cmplx64_t (ca_size_t n, boolean8_t *m,
                     char *ptr1, int32_t ipow, char *ptr2)
{
  cmplx64_t *p1 = (cmplx64_t *) ptr1, *p2 = (cmplx64_t *) ptr2;
  if ( m ) {
    while (n--) {
      if ( ! *m++ ) { *p2 = op_powi_cmplx64_t(*p1, ipow); }
      p1++; p2++;
    }
  }
  else
    while (n--) { (*p2) = op_powi_cmplx64_t(*p1, ipow); p1++; p2++; }
}

static void
ca_ipower_cmplx128_t (ca_size_t n, boolean8_t *m,
                     char *ptr1, int32_t ipow, char *ptr2)
{
  cmplx128_t *p1 = (cmplx128_t *) ptr1, *p2 = (cmplx128_t *) ptr2;
  if ( m ) {
    while (n--) {
      if ( ! *m++ ) { *p2 = op_powi_cmplx128_t(*p1, ipow); }
      p1++; p2++;
    }
  }
  else
    while (n--) { (*p2) = op_powi_cmplx128_t(*p1, ipow); p1++; p2++; }
}


static VALUE
rb_ca_ipower (VALUE self, VALUE other)
{
  volatile VALUE obj;
  CArray *ca, *co;
  int32_t ipow;
  boolean8_t *m;

  ipow = NUM2INT(other);

  Data_Get_Struct(self, CArray, ca);

  co = ca_template(ca);
  obj = ca_wrap_struct(co);

  ca_attach(ca);

  ca_copy_mask_overlay(co, co->elements, 1, ca);
  m = ( co->mask ) ? (boolean8_t *)co->mask->ptr : NULL;

  switch ( ca->data_type ) {
  case CA_FLOAT32: {
    ca_ipower_float32_t(ca->elements, m, ca->ptr, ipow, co->ptr);
    break;
  }
  case CA_FLOAT64: {
    ca_ipower_float64_t(ca->elements, m, ca->ptr, ipow, co->ptr);
    break;
  }
  case CA_FLOAT128: {
    ca_ipower_float128_t(ca->elements, m, ca->ptr, ipow, co->ptr);
    break;
  }
  case CA_CMPLX64: {
    ca_ipower_cmplx64_t(ca->elements, m, ca->ptr, ipow, co->ptr);
    break;
  }
  case CA_CMPLX128: {
    ca_ipower_cmplx128_t(ca->elements, m, ca->ptr, ipow, co->ptr);
    break;
  }
  default:
    rb_raise(rb_eCADataTypeError, "invalid data type for ipower");
    break;
  }

  ca_detach(ca);

  /* unresolved unbound repeat array generates unbound repeat array again */
  if ( ca->obj_type == CA_OBJ_UNBOUND_REPEAT ) {
    CAUnboundRepeat *cx = (CAUnboundRepeat *) ca;
    obj = rb_ca_ubrep_new(obj, cx->rep_rank, cx->rep_dim);
  }

  return obj;
}

static VALUE
rb_ca_ipower_bang (VALUE self, VALUE other)
{
  CArray *ca;
  int32_t ipow;
  boolean8_t *m;

  ipow = NUM2INT(other);

  Data_Get_Struct(self, CArray, ca);

  ca_attach(ca);

  m = ( ca->mask ) ? (boolean8_t *)ca->mask->ptr : NULL;

  switch ( ca->data_type ) {
  case CA_FLOAT32: {
    ca_ipower_float32_t(ca->elements, m, ca->ptr, ipow, ca->ptr);
    break;
  }
  case CA_FLOAT64: {
    ca_ipower_float64_t(ca->elements, m, ca->ptr, ipow, ca->ptr);
    break;
  }
  case CA_FLOAT128: {
    ca_ipower_float128_t(ca->elements, m, ca->ptr, ipow, ca->ptr);
    break;
  }
  case CA_CMPLX64: {
    ca_ipower_cmplx64_t(ca->elements, m, ca->ptr, ipow, ca->ptr);
    break;
  }
  case CA_CMPLX128: {
    ca_ipower_cmplx128_t(ca->elements, m, ca->ptr, ipow, ca->ptr);
    break;
  }
  default:
    rb_raise(rb_eRuntimeError, "invalid data type for ipower");
    break;
  }

  ca_sync(ca);
  ca_detach(ca);

  return self;
}

}

binop("**", "power",
      INT_TYPES   => "(#3) = op_powi_<type>((#1), (#2));",
      FLOAT_TYPES => "(#3) = pow((#1), (#2));",
      CMPLX_TYPES => HAVE_COMPLEX ? "(#3) = cpow((#1), (#2));" : nil,
      OBJ_TYPES   => '(#3) = rb_funcall((#1), id_star_star, 1, (#2));')

DEFINITIONS << %{

static VALUE rb_ca_pow (VALUE self, VALUE other)
{
  volatile VALUE obj;
  CArray *ca;

  Data_Get_Struct(self, CArray, ca);
  if ( ( ca_is_float_type(ca) || ca_is_complex_type(ca) ) &&
       rb_obj_is_kind_of(other, rb_cInteger) ) {
    return rb_ca_ipower(self, other);
  }
  else {
    obj = rb_ca_power(self, other);

    /* unresolved unbound repeat array generates unbound repeat array again */
    if ( ca->obj_type == CA_OBJ_UNBOUND_REPEAT ) {
      CAUnboundRepeat *cx = (CAUnboundRepeat *) ca;
      obj = rb_ca_ubrep_new(obj, cx->rep_rank, cx->rep_dim);
    }

    return obj;
  }
}

static VALUE rb_ca_pow_bang (VALUE self, VALUE other)
{
  CArray *ca;
  Data_Get_Struct(self, CArray, ca);
  if ( ( ca_is_float_type(ca) || ca_is_complex_type(ca) ) &&
       rb_obj_is_kind_of(other, rb_cInteger) ) {
    return rb_ca_ipower_bang(self, other);
  }
  else {
    return rb_ca_power_bang(self, other);
  }
}

}

METHODS << %{
  rb_define_method(rb_cCArray, "pow", rb_ca_pow, 1);
  rb_define_method(rb_cCArray, "pow!", rb_ca_pow_bang, 1);
}

alias_op("pow", "**")

METHODS << %{
  id_equal = rb_intern("==");
  id_lt    = rb_intern("<");
  id_le    = rb_intern("<=");
  id_gt    = rb_intern(">");
  id_ge    = rb_intern(">=");

  id_uminus = rb_intern("-@");
  id_utilda = rb_intern("~@");

  id_plus  = rb_intern("+");
  id_minus = rb_intern("-");
  id_star  = rb_intern("*");
  id_slash = rb_intern("/");
  id_percent = rb_intern("%");
  id_star_star = rb_intern("**");

  id_and  = rb_intern("&");
  id_or   = rb_intern("|");
  id_xor  = rb_intern("^");
  id_lshift = rb_intern("<<");
  id_rshift = rb_intern(">>");

}

create_code("carray_math", "carray_math.c")

