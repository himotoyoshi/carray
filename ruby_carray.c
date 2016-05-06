/* ---------------------------------------------------------------------------

  ruby_carray.c

  This file is part of Ruby/CArray extension library.
  You can redistribute it and/or modify it under the terms of
  the Ruby Licence.

  Copyright (C) 2005 Hiroki Motoyoshi

---------------------------------------------------------------------------- */

#include "carray.h"
#include "version.h"

VALUE rb_eCADataTypeError;
VALUE rb_mCA;

VALUE CA_NIL;

void Init_ccomplex ();
void Init_numeric_float_function ();

void Init_carray_core ();
void Init_carray_undef ();
void Init_carray_class ();
void Init_carray_test ();
void Init_carray_attribute ();
void Init_carray_loop ();
void Init_carray_mask ();
void Init_carray_access ();
void Init_carray_element ();
void Init_carray_iterator ();
void Init_carray_operator ();
void Init_carray_numeric ();
void Init_carray_math ();
void Init_carray_random ();
void Init_carray_utils ();
void Init_carray_order ();
void Init_carray_sort_addr ();
void Init_carray_stat ();
void Init_carray_stat_proc ();
void Init_carray_utils ();
void Init_carray_generate ();
void Init_carray_copy ();
void Init_carray_conversion ();
void Init_carray_cast ();

void Init_ca_obj_array ();
void Init_ca_obj_refer ();
void Init_ca_obj_farray ();
void Init_ca_obj_block ();
void Init_ca_obj_select ();
void Init_ca_obj_object ();
void Init_ca_obj_grid ();
void Init_ca_obj_window ();
void Init_ca_obj_shift ();
void Init_ca_obj_transpose ();
void Init_ca_obj_mapping ();
void Init_ca_obj_repeat ();
void Init_ca_obj_unbound_repeat ();
void Init_ca_obj_reduce ();
void Init_ca_obj_field ();
void Init_ca_obj_fake ();
void Init_ca_obj_bitarray ();
void Init_ca_obj_bitfield ();

void Init_carray_iterator ();
void Init_ca_iter_dimension ();
void Init_ca_iter_block ();
void Init_ca_iter_window ();

void
Init_carray_ext ()
{

  /* Classes and Modules */

  /* -- CArray class -- */

  rb_cCArray     = rb_define_class("CArray",    rb_cObject);
  rb_cCAWrap     = rb_define_class("CAWrap",    rb_cCArray);
  rb_cCScalar    = rb_define_class("CScalar",   rb_cCArray);
  rb_cCAVirtual  = rb_define_class("CAVirtual", rb_cCArray);
  rb_cCARefer    = rb_define_class("CARefer",   rb_cCAVirtual);
  rb_cCABlock    = rb_define_class("CABlock",   rb_cCAVirtual);
  rb_cCASelect   = rb_define_class("CASelect",  rb_cCAVirtual);
  rb_cCAObject   = rb_define_class("CAObject",  rb_cCAVirtual);
  rb_cCARepeat   = rb_define_class("CARepeat",  rb_cCAVirtual);
  rb_cCAUnboundRepeat  = rb_define_class("CAUnboundRepeat",  rb_cCAVirtual);

  /* -- Exception class -- */

  rb_eCADataTypeError =
    rb_define_class_under(rb_cCArray, "DataTypeError", rb_eStandardError);

  /* rdoc:
     class CArray::DataTypeError # :nodoc:
     end
  */

  /* -- CA module -- */
  /*   a namespace for misc utilities related with CArray */

  rb_mCA = rb_define_module("CA");

  /* CArray constants */

  /* -- version -- */

  /* rdoc: 
    class CArray
      VERSION = nil         # :nodoc:
      VERSION_CODE = nil    # :nodoc:
      VERSION_MAJOR = nil   # :nodoc:
      VERSION_MINOR = nil   # :nodoc:
      VERSION_TEENY = nil   # :nodoc:
      VERSION_DATE = nil    # :nodoc:
    end
  */
  
  rb_define_const(rb_cCArray, "VERSION", rb_str_new2(CA_VERSION));
  rb_define_const(rb_cCArray, "VERSION_CODE", INT2NUM(CA_VERSION_CODE));
  rb_define_const(rb_cCArray, "VERSION_MAJOR", INT2NUM(CA_VERSION_MAJOR));
  rb_define_const(rb_cCArray, "VERSION_MINOR", INT2NUM(CA_VERSION_MINOR));
  rb_define_const(rb_cCArray, "VERSION_TEENY", INT2NUM(CA_VERSION_TEENY));
  rb_define_const(rb_cCArray, "VERSION_DATE", rb_str_new2(CA_VERSION_DATE));

  /* -- system -- */
  rb_define_const(rb_cObject, "CA_RANK_MAX", INT2NUM(CA_RANK_MAX));
  CA_NIL = rb_funcall(rb_cObject, rb_intern("new"), 0);
  rb_define_const(rb_cObject, "CA_NIL", CA_NIL);

#ifdef HAVE_COMPLEX_H
  rb_define_const(rb_cCArray, "HAVE_COMPLEX", Qtrue);
#else
  rb_define_const(rb_cCArray, "HAVE_COMPLEX", Qfalse);
#endif

  /* -- data types -- */

  rb_define_const(rb_cObject, "CA_FIXLEN",     INT2NUM(CA_FIXLEN));
  rb_define_const(rb_cObject, "CA_BOOLEAN",     INT2NUM(CA_BOOLEAN));
  rb_define_const(rb_cObject, "CA_INT8",     INT2NUM(CA_INT8));
  rb_define_const(rb_cObject, "CA_UINT8",    INT2NUM(CA_UINT8));
  rb_define_const(rb_cObject, "CA_INT16",    INT2NUM(CA_INT16));
  rb_define_const(rb_cObject, "CA_UINT16",   INT2NUM(CA_UINT16));
  rb_define_const(rb_cObject, "CA_INT32",    INT2NUM(CA_INT32));
  rb_define_const(rb_cObject, "CA_UINT32",   INT2NUM(CA_UINT32));
  rb_define_const(rb_cObject, "CA_INT64",    INT2NUM(CA_INT64));
  rb_define_const(rb_cObject, "CA_UINT64",   INT2NUM(CA_UINT64));
  rb_define_const(rb_cObject, "CA_FLOAT32",  INT2NUM(CA_FLOAT32));
  rb_define_const(rb_cObject, "CA_FLOAT64",  INT2NUM(CA_FLOAT64));
  rb_define_const(rb_cObject, "CA_FLOAT128", INT2NUM(CA_FLOAT128));
  rb_define_const(rb_cObject, "CA_CMPLX64",  INT2NUM(CA_CMPLX64));
  rb_define_const(rb_cObject, "CA_CMPLX128", INT2NUM(CA_CMPLX128));
  rb_define_const(rb_cObject, "CA_CMPLX256", INT2NUM(CA_CMPLX256));
  rb_define_const(rb_cObject, "CA_OBJECT",   INT2NUM(CA_OBJECT));

  rb_define_const(rb_cObject, "CA_BYTE",        INT2NUM(CA_BYTE));
  rb_define_const(rb_cObject, "CA_SHORT",       INT2NUM(CA_INT16));
  rb_define_const(rb_cObject, "CA_INT",         INT2NUM(CA_INT32));
  rb_define_const(rb_cObject, "CA_FLOAT",       INT2NUM(CA_FLOAT));
  rb_define_const(rb_cObject, "CA_DOUBLE",      INT2NUM(CA_DOUBLE));
  rb_define_const(rb_cObject, "CA_COMPLEX",     INT2NUM(CA_COMPLEX));
  rb_define_const(rb_cObject, "CA_DCOMPLEX",    INT2NUM(CA_DCOMPLEX));

  rb_define_const(rb_cObject, "CA_ALIGN_VOIDP",    INT2NUM(CA_ALIGN_VOIDP));
  rb_define_const(rb_cObject, "CA_ALIGN_FIXLEN",   INT2NUM(CA_ALIGN_INT8));
  rb_define_const(rb_cObject, "CA_ALIGN_BOOLEAN",  INT2NUM(CA_ALIGN_INT8));
  rb_define_const(rb_cObject, "CA_ALIGN_INT8",     INT2NUM(CA_ALIGN_INT8));
  rb_define_const(rb_cObject, "CA_ALIGN_INT16",    INT2NUM(CA_ALIGN_INT16));
  rb_define_const(rb_cObject, "CA_ALIGN_INT32",    INT2NUM(CA_ALIGN_INT32));
  rb_define_const(rb_cObject, "CA_ALIGN_INT64",    INT2NUM(CA_ALIGN_INT64));
  rb_define_const(rb_cObject, "CA_ALIGN_FLOAT32",  INT2NUM(CA_ALIGN_FLOAT32));
  rb_define_const(rb_cObject, "CA_ALIGN_FLOAT64",  INT2NUM(CA_ALIGN_FLOAT64));
  rb_define_const(rb_cObject, "CA_ALIGN_FLOAT128", INT2NUM(CA_ALIGN_FLOAT128));
  rb_define_const(rb_cObject, "CA_ALIGN_CMPLX64",  INT2NUM(CA_ALIGN_CMPLX64));
  rb_define_const(rb_cObject, "CA_ALIGN_CMPLX128", INT2NUM(CA_ALIGN_CMPLX128));
  rb_define_const(rb_cObject, "CA_ALIGN_CMPLX256", INT2NUM(CA_ALIGN_CMPLX256));
  rb_define_const(rb_cObject, "CA_ALIGN_OBJECT",   INT2NUM(CA_ALIGN_OBJECT));

  /* load modules in external files */

  Init_carray_core(); /* Init_carray_core should be called first*/

#ifdef HAVE_COMPLEX_H
  Init_ccomplex();
#endif

  Init_numeric_float_function();

  Init_carray_class();
  Init_carray_test();
  Init_carray_attribute();
  Init_carray_undef();
  Init_carray_mask();
  Init_carray_loop();
  Init_carray_access();
  Init_carray_element();
  Init_carray_operator();
  Init_carray_math();      /* order of math, numeric should not be changed */
  Init_carray_numeric();   /* order of math, numeric should not be changed */
  Init_carray_random();
  Init_carray_order();
  Init_carray_sort_addr();  
  Init_carray_stat();
  Init_carray_stat_proc();

  Init_carray_utils();

  Init_carray_generate();
  Init_carray_copy();
  Init_carray_conversion();
  Init_carray_cast();

  Init_ca_obj_array();
  Init_ca_obj_refer();
  Init_ca_obj_farray();
  Init_ca_obj_block();
  Init_ca_obj_select();
  Init_ca_obj_object();
  Init_ca_obj_grid();
  Init_ca_obj_window();
  Init_ca_obj_shift();
  Init_ca_obj_transpose();
  Init_ca_obj_mapping();
  Init_ca_obj_repeat();
  Init_ca_obj_unbound_repeat();
  Init_ca_obj_reduce();
  Init_ca_obj_field();
  Init_ca_obj_fake();
  Init_ca_obj_bitarray();
  Init_ca_obj_bitfield();

  Init_carray_iterator();

  Init_ca_iter_dimension();
  Init_ca_iter_block();
  Init_ca_iter_window();
}

