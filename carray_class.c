/* ---------------------------------------------------------------------------

  carray_class.c

  This file is part of Ruby/CArray extension library.
  You can redistribute it and/or modify it under the terms of
  the Ruby Licence.

  Copyright (C) 2005 Hiroki Motoyoshi

---------------------------------------------------------------------------- */

#include "carray.h"

/* rdoc: 
  # returns the machine endianness.
  #     CArray.endian #=> 0 (CA_LITTLE_ENDIAN)
  #     CArray.endian #=> 1 (CA_BIG_ENDIAN)

  def CArray.endian 
  end
*/

static VALUE
rb_ca_s_endian (VALUE klass)
{
  return INT2NUM(ca_endian);
}

/* rdoc:
  # returns true if the byte order of the architecture is
  # big endian.

  def CArray.big_endian?
  end
*/

static VALUE
rb_ca_s_big_endian_p (VALUE klass)
{
  return ( ca_endian == CA_BIG_ENDIAN ) ? Qtrue : Qfalse;
}

/* rdoc: 
  # returns true if the byte order of the architecture is
  # little endian.

  def CArray.little_endian?
  end
*/

static VALUE
rb_ca_s_little_endian_p (VALUE klass)
{
  return ( ca_endian == CA_LITTLE_ENDIAN ) ? Qtrue : Qfalse;
}

/* rdoc:
  #  Returns the byte length of an element of the given data type.
  #  Retruns <code>0</code> if data_type is equal to CA_FIXLEN.
  #     CArray.sizeof(CA_INT32)  #=> 4
  #     CArray.sizeof(CA_DOUBLE) #=> 8
  #     CArray.sizeof(CA_FIXLEN)   #=> 0

  def CArray.sizeof (data_type)
  end
*/

static VALUE
rb_ca_s_sizeof (VALUE klass, VALUE rtype)
{
  int8_t data_type;
  int32_t bytes;
  rb_ca_guess_type_and_bytes(rtype, INT2FIX(0), &data_type, &bytes);
  return LONG2NUM(bytes);
}


/* rdoc:
  #  Returns true if the given data_type indicate the valid data_type.

  def CArray.data_type?(data_type)
  end
*/

static VALUE
rb_ca_s_data_type (VALUE klass, VALUE rtype)
{
  int8_t data_type = rb_ca_guess_type(rtype);
  if ( data_type <= CA_NONE || data_type >= CA_NTYPE ) {
    rb_raise(rb_eArgError,
            "data type is out of range (%i..%i)", CA_NONE+1, CA_NTYPE-1);
  }
  return ca_valid[data_type] == 1 ? Qtrue : Qfalse;
}

/* rdoc:
  #  Returns string representaion of the data_type specifier.

  def CArray.data_type_name(data_type)
  end
*/


static VALUE
rb_ca_s_data_type_name (VALUE klass, VALUE type)
{
  int8_t data_type = NUM2INT(type);
  CA_CHECK_DATA_TYPE(data_type);
  return rb_str_new2(ca_type_name[data_type]);
}

/* ------------------------------------------------------------------- */

void
Init_carray_class ()
{
  rb_define_const(rb_cObject, "CA_BIG_ENDIAN", INT2NUM(CA_BIG_ENDIAN));
  rb_define_const(rb_cObject, "CA_LITTLE_ENDIAN", INT2NUM(CA_LITTLE_ENDIAN));

  rb_define_singleton_method(rb_cCArray, "endian", rb_ca_s_endian, 0); 
  rb_define_singleton_method(rb_cCArray, "big_endian?",
                             rb_ca_s_big_endian_p, 0);
  rb_define_singleton_method(rb_cCArray, "little_endian?",
                             rb_ca_s_little_endian_p, 0);
  rb_define_singleton_method(rb_cCArray, "sizeof", rb_ca_s_sizeof, 1);
  rb_define_singleton_method(rb_cCArray, "data_type?",
                             rb_ca_s_data_type, 1);
  rb_define_singleton_method(rb_cCArray, "data_type_name",
                             rb_ca_s_data_type_name, 1);
}

