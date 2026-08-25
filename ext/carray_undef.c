/* ---------------------------------------------------------------------------

  UNDEF sentinel value: the single instance of UndefClass exported as
  the top-level constant `UNDEF`.  Used by mask-bearing CArray APIs
  to mean "masked / no value here" without choosing a numeric sentinel
  (NaN / -1 / etc.) that might collide with valid data.

  Identity semantics: every reference to UNDEF is the same Ruby object;
  C code compares with raw pointer equality (`rval == CA_UNDEF`).  The
  GC pin in Init_carray_undef guarantees the pointer stays valid even
  under Ruby 3+ compacting GC.

  Coercion asymmetry: to_s / inspect return the literal string "UNDEF"
  (display works), but to_f / to_i / to_int raise TypeError (numeric
  coercion is rejected so accidental arithmetic on UNDEF surfaces as
  an error rather than silently producing 0 / NaN).

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
  return rb_str_new2("UNDEF");
}

static VALUE rb_ud_to_f (VALUE self)
{
  rb_raise(rb_eTypeError, "can't coerce UNDEF into Float");
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
Init_carray_undef (void)
{
  rb_cUNDEF = rb_define_class("UndefClass", rb_cObject);
  rb_define_method(rb_cUNDEF, "inspect", rb_ud_inspect, 0);
  rb_define_method(rb_cUNDEF, "to_s",    rb_ud_to_s,    0);
  rb_define_method(rb_cUNDEF, "to_f",    rb_ud_to_f,    0);
  rb_define_method(rb_cUNDEF, "to_i",    rb_ud_to_i,    0);
  rb_define_method(rb_cUNDEF, "to_int",  rb_ud_to_i,    0);
  rb_define_method(rb_cUNDEF, "==",      rb_ud_equal,   1);

  /* Singleton: instantiate once, then undef `new` so no second instance
     can be created.  The identity invariant relies on this. */
  CA_UNDEF = rb_funcall(rb_cUNDEF, rb_intern("new"), 0);
  rb_undef_method(CLASS_OF(rb_cUNDEF), "new");
  rb_const_set(rb_cObject, rb_intern("UNDEF"), CA_UNDEF);

  /* CAREFUL: CA_UNDEF is dereferenced via raw pointer compare
     (`rval == CA_UNDEF`) throughout the C code, so the underlying
     object must not be relocated.  Constant registration above
     keeps the object reachable but does not prevent compacting GC
     (Ruby 2.7+) from moving it to a new address; the pin here
     disables compaction for this single sentinel. */
  rb_gc_register_mark_object(CA_UNDEF);
}

