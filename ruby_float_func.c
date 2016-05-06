/* ---------------------------------------------------------------------------

  ruby_numeric.c

  This file is part of Ruby/CArray extension library.
  You can redistribute it and/or modify it under the terms of
  the Ruby Licence.

  Copyright (C) 2005 Hiroki Motoyoshi

---------------------------------------------------------------------------- */

#include "ruby.h"
#include <math.h>

#define rb_num_func(name) \
static VALUE rb_num_ ## name (VALUE self) \
{ return rb_float_new(name(NUM2DBL(self))); }

rb_num_func(sqrt);
rb_num_func(exp);
rb_num_func(log);
rb_num_func(log10);

rb_num_func(sin);
rb_num_func(cos);
rb_num_func(tan);
rb_num_func(sinh);
rb_num_func(cosh);
rb_num_func(tanh);

rb_num_func(asin);
rb_num_func(acos);
rb_num_func(atan);
rb_num_func(asinh);
rb_num_func(acosh);
rb_num_func(atanh);

static VALUE 
rb_num_rad (VALUE self)
{ return rb_float_new(0.0174532925199433*NUM2DBL(self)); }

static VALUE 
rb_num_deg (VALUE self)
{ return rb_float_new(57.2957795130823*NUM2DBL(self)); }

static VALUE 
rb_num_distance (VALUE self, VALUE other)
{ 
  double fs = NUM2DBL(self), fo = NUM2DBL(other);
  return rb_float_new(fabs(fs - fo)); 
}

void
Init_numeric_float_function ()
{
  VALUE mod = rb_define_module_under(rb_cNumeric, "FloatFunction");

  rb_define_method(mod, "sqrt", rb_num_sqrt, 0);
  rb_define_method(mod, "exp", rb_num_exp, 0);
  rb_define_method(mod, "log", rb_num_log, 0);
  rb_define_method(mod, "log10", rb_num_log10, 0);
  rb_define_method(mod, "sin", rb_num_sin, 0);
  rb_define_method(mod, "cos", rb_num_cos, 0);
  rb_define_method(mod, "tan", rb_num_tan, 0);  
  rb_define_method(mod, "sinh", rb_num_sinh, 0);
  rb_define_method(mod, "cosh", rb_num_cosh, 0);
  rb_define_method(mod, "tanh", rb_num_tanh, 0);  
  rb_define_method(mod, "asin", rb_num_asin, 0);
  rb_define_method(mod, "acos", rb_num_acos, 0);
  rb_define_method(mod, "atan", rb_num_atan, 0);  
  rb_define_method(mod, "asinh", rb_num_asinh, 0);
  rb_define_method(mod, "acosh", rb_num_acosh, 0);
  rb_define_method(mod, "atanh", rb_num_atanh, 0);  
  rb_define_method(mod, "rad", rb_num_rad, 0);  
  rb_define_method(mod, "deg", rb_num_deg, 0);    
  rb_define_method(mod, "distance", rb_num_distance, 1);    

  rb_include_module(rb_cFloat, mod);
  rb_include_module(rb_cFixnum, mod);
  rb_include_module(rb_cBignum, mod);  
}

