/* ---------------------------------------------------------------------------

  carray_class.c

  This file is part of Ruby/CArray extension library.

  Copyright (C) 2005-2020 Hiroki Motoyoshi

---------------------------------------------------------------------------- */

#include "carray.h"

/* @overload endian 

(Inquiry) 
Returns the machine endianness.
   0 (CA_LITTLE_ENDIAN)
   1 (CA_BIG_ENDIAN)
*/

static VALUE
rb_ca_s_endian (VALUE klass)
{
  return INT2NUM(ca_endian);
}

/* @overload big_endian?
  
(Inquiry) 
Returns true if the byte order of the architecture is big endian.
*/

static VALUE
rb_ca_s_big_endian_p (VALUE klass)
{
  return ( ca_endian == CA_BIG_ENDIAN ) ? Qtrue : Qfalse;
}

/* @overload little_endian?

(Inquiry) 
Returns true if the byte order of the architecture is
little endian.
*/

static VALUE
rb_ca_s_little_endian_p (VALUE klass)
{
  return ( ca_endian == CA_LITTLE_ENDIAN ) ? Qtrue : Qfalse;
}

/* @overload sizeof (data_type)

(Inquiry) 
Returns the byte length of an element of the given data type.
Retruns <code>0</code> if data_type is equal to CA_FIXLEN.
     CArray.sizeof(CA_INT32)  #=> 4
     CArray.sizeof(CA_DOUBLE) #=> 8
     CArray.sizeof(CA_FIXLEN)   #=> 0

*/

static VALUE
rb_ca_s_sizeof (VALUE klass, VALUE rtype)
{
  int8_t data_type;
  ca_size_t bytes;
  rb_ca_guess_type_and_bytes(rtype, INT2NUM(0), &data_type, &bytes);
  return SIZE2NUM(bytes);
}


/* @overload data_type?(data_type)

(Inquiry) 
Returns true if the given data_type indicate the valid data_type.
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

/* @overload data_type_name(data_type)

(Inquiry) 
Returns string representaion of the data_type specifier.
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

