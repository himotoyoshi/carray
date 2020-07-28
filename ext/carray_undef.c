/* ---------------------------------------------------------------------------

  carray_undef.c

  This file is part of Ruby/CArray extension library.

  Copyright (C) 2005-2020 Hiroki Motoyoshi

---------------------------------------------------------------------------- */

#include "ruby.h"

static VALUE rb_cUNDEF;

VALUE CA_UNDEF;

static VALUE rb_ud_inspect (VALUE self) 
{
  return rb_str_new2("UNDEF");
}

static VALUE rb_ud_to_s (VALUE self) 
{
  /* rb_raise(rb_eTypeError, "can't coerce UNDEF into String"); */
  return rb_str_new2("UNDEF");
}

static VALUE rb_ud_to_f (VALUE self) 
{
  rb_raise(rb_eTypeError, "can't coerce UNDEF into Float");
  /* return rb_float_new(0.0/0.0); */
}

static VALUE rb_ud_to_i (VALUE self) 
{
  rb_raise(rb_eTypeError, "can't coerce UNDEF into Integer");
}

static VALUE rb_ud_equal (VALUE self, VALUE other) 
{
  return ( self == other ) ? Qtrue : Qfalse;
}

void
Init_carray_undef ()
{
  rb_cUNDEF = rb_define_class("UndefClass", rb_cObject);
  rb_define_method(rb_cUNDEF, "inspect", rb_ud_inspect, 0);
  rb_define_method(rb_cUNDEF, "to_s", rb_ud_to_s, 0);
  rb_define_method(rb_cUNDEF, "to_f", rb_ud_to_f, 0);
  rb_define_method(rb_cUNDEF, "to_i", rb_ud_to_i, 0);
  rb_define_method(rb_cUNDEF, "to_int", rb_ud_to_i, 0);
  rb_define_method(rb_cUNDEF, "==", rb_ud_equal, 1);

  CA_UNDEF  = rb_funcall(rb_cUNDEF, rb_intern("new"), 0);
  rb_undef_method(CLASS_OF(rb_cUNDEF), "new");
  rb_const_set(rb_cObject, rb_intern("UNDEF"), CA_UNDEF);
}

