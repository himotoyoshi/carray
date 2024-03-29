/* ---------------------------------------------------------------------------

  carray_attribute.c

  This file is part of Ruby/CArray extension library.

  Copyright (C) 2005-2020 Hiroki Motoyoshi

---------------------------------------------------------------------------- */

#include "carray.h"

/* ------------------------------------------------------------------- */

/* @overload obj_type

(Attribute) 
Returns the object type (e.g. CA_OBJ_ARRAY, CA_OBJ_BLOCK, ...).
Since the object type can be known from the class of the object,
this attribute methods is rarely used.
*/

VALUE
rb_ca_obj_type (VALUE self)
{
  CArray *ca;
  Data_Get_Struct(self, CArray, ca);
  return INT2NUM(ca->obj_type);
}

/* @overload data_type

(Attribute) 
Returns the data type of each element (e.g. CA_INT32, CA_FLOAT64, ...).
*/

VALUE
rb_ca_data_type (VALUE self)
{
  CArray *ca;
  Data_Get_Struct(self, CArray, ca);
  return INT2NUM(ca->data_type);
}

/* @overload ndim

(Attribute) 
Returns the number of dimensions (e.g. 1 for 1D array, 3 for 3D array, ...).
*/

VALUE
rb_ca_ndim (VALUE self)
{
  CArray *ca;
  Data_Get_Struct(self, CArray, ca);
  return INT2NUM(ca->ndim);
}

/* @overload bytes

(Attribute) 
Returns the byte size of each element (e.g. 4 for CA_INT32, 8 for CA_FLOAT64).
The byte size can be obtained using CArray.sizeof(data_type)
for the numerical data types, but
the byte size of fixed-length data type can be known 
only by this method.
*/

VALUE
rb_ca_bytes (VALUE self)
{
  CArray *ca;
  Data_Get_Struct(self, CArray, ca);
  return SIZE2NUM(ca->bytes);
}

/* @overload elements

(Attribute) 
Returns the number of elements
*/

VALUE
rb_ca_elements (VALUE self)
{
  CArray *ca;
  Data_Get_Struct(self, CArray, ca);
  return SIZE2NUM(ca->elements);
}

/* @overload dim

(Attribute) 
Returns the Array object contains the dimensional shape of array
(e.g. [2,3] for 2D 2x3 array, ...).
*/

VALUE
rb_ca_dim (VALUE self)
{
  volatile VALUE dim;
  CArray *ca;
  int i;
  Data_Get_Struct(self, CArray, ca);
  dim = rb_ary_new2(ca->ndim);
  for (i=0; i<ca->ndim; i++) {
    rb_ary_store(dim, i, SIZE2NUM(ca->dim[i]));
  }
  return dim;
}

/*
@overload dim0

(Attribute) 
Short-hand for "dim[0]"
*/  

VALUE
rb_ca_dim0 (VALUE self)
{
  CArray *ca;
  Data_Get_Struct(self, CArray, ca);
  return SIZE2NUM(ca->dim[0]);
}

/*
@overload dim1

(Attribute) 
Short-hand for "dim[1]"
*/  

VALUE
rb_ca_dim1 (VALUE self)
{
  CArray *ca;
  Data_Get_Struct(self, CArray, ca);
  return ( ca->ndim >= 2 ) ? SIZE2NUM(ca->dim[1]) : Qnil;
}

/*
@overload dim2

(Attribute) 
Short-hand for 'dim[2]'
*/  

VALUE
rb_ca_dim2 (VALUE self)
{
  CArray *ca;
  Data_Get_Struct(self, CArray, ca);
  return ( ca->ndim >= 3 ) ? SIZE2NUM(ca->dim[2]) : Qnil;
}

/*
@overload dim3

(Attribute) 
Short-hand for "dim[3]"
*/  

VALUE
rb_ca_dim3 (VALUE self)
{
  CArray *ca;
  Data_Get_Struct(self, CArray, ca);
  return ( ca->ndim >= 4 ) ? SIZE2NUM(ca->dim[3]) : Qnil;
}

/* @overload data_type_name

(Attribute) 
Returns the string representaion of the data_type (e.g. "int32", "fixlen")
*/

VALUE
rb_ca_data_type_name (VALUE self)
{
  CArray *ca;
  Data_Get_Struct(self, CArray, ca);
  return rb_str_new2(ca_type_name[ca->data_type]);
}

/* ------------------------------------------------------------------- */

int
ca_is_scalar (void *ap)
{
  CArray *ca = (CArray *) ap;
  return ca_test_flag(ca, CA_FLAG_SCALAR);
}

/* @overload scalar?

(Inquiry) Returns true if the object is a CScalar
*/

VALUE
rb_ca_is_scalar (VALUE self)
{
  CArray *ca;
  Data_Get_Struct(self, CArray, ca);
  return ( ca_is_scalar(ca) ) ? Qtrue : Qfalse;
}

/* api: rb_obj_is_cscalar */

VALUE
rb_obj_is_cscalar (VALUE obj)
{
  CArray *ca;
  if ( rb_obj_is_carray(obj) ) {
    Data_Get_Struct(obj, CArray, ca);
    return ( ca_is_scalar(ca) ) ? Qtrue : Qfalse;
  }
  return Qfalse;
}

/* ------------------------------------------------------------------- */

int
ca_is_virtual (void *ap)
{
  CArray *ca = (CArray *) ap;
  return ( ca_func[ca->obj_type].entity_type == CA_VIRTUAL_ARRAY ) ? 1 : 0;
}

/* @overload entity?

(Inquiry) Returns true if `self` is an entity array (not a virtual array).
*/

VALUE
rb_ca_is_entity (VALUE self)
{
  CArray *ca;
  Data_Get_Struct(self, CArray, ca);
  return ( ca_is_virtual(ca) ) ? Qfalse : Qtrue;
}

/*
@overload virtual?

(Inquiry) Returns true if `self` is a virtural array (not an entity array).
*/

VALUE
rb_ca_is_virtual (VALUE self)
{
  CArray *ca;
  Data_Get_Struct(self, CArray, ca);
  return ( ca_is_virtual(ca) ) ? Qtrue : Qfalse;
}

/* ------------------------------------------------------------------- */

/* @overload attached?

(Inquiry) Returns true if the object is attached.
*/

VALUE
rb_ca_is_attached (VALUE self)
{
  CArray *ca;
  Data_Get_Struct(self, CArray, ca);
  return ( ca_is_attached(ca) ) ? Qtrue : Qfalse;
}

/* ------------------------------------------------------------------- */

/* @overload empty?

(Inquiry) Returns true if the object is empty.
*/

VALUE
rb_ca_is_empty (VALUE self)
{
  CArray *ca;
  Data_Get_Struct(self, CArray, ca);
  return ( ca->elements == 0 ) ? Qtrue : Qfalse;
}

/* ------------------------------------------------------------------- */

int
ca_is_readonly (void *ap)
{
  CArray *ca = (CArray *) ap;
  if ( ca_test_flag(ca, CA_FLAG_READ_ONLY) ) {           /* test -> true */
    return 1;
  }
  else {                                                 /* test -> false */
    if ( ca_is_virtual(ca) && CAVIRTUAL(ca)->parent ) {
      if ( ca_is_readonly(CAVIRTUAL(ca)->parent) ) {     /* test -> true */
        ca_set_flag(ca, CA_FLAG_READ_ONLY);
        return 1;
      }
    }
    return 0;                                            /* all test -> false */
  }
}

/* @overload read_only?

(Inquiry) Returns true if the object is read-only
*/

VALUE
rb_ca_is_read_only (VALUE self)
{
  CArray *ca;
  Data_Get_Struct(self, CArray, ca);
  return ( ca_is_readonly(ca) ) ? Qtrue : Qfalse;
}

/* ------------------------------------------------------------------- */

int
ca_is_mask_array (void *ap)
{
  CArray *ca = (CArray *) ap;
  if ( ca_test_flag(ca, CA_FLAG_MASK_ARRAY) ) {           /* test -> true */
    return 1;
  }
  else {                                                   /* test -> false */
    if ( ca_is_virtual(ca) && CAVIRTUAL(ca)->parent ) {
      if ( ca_is_mask_array(CAVIRTUAL(ca)->parent) ) {     /* test -> true */
        ca_set_flag(ca, CA_FLAG_MASK_ARRAY);
        return 1;
      }
    }
    return 0;                                            /* all test -> false */
  }
}

/* @overload mask_array?

(Inquiry) Returns true if `self` is mask array (don't confuse with "masked array")
*/

VALUE
rb_ca_is_mask_array (VALUE self)
{
  CArray *ca;
  Data_Get_Struct(self, CArray, ca);
  return ( ca_is_mask_array(ca) ) ? Qtrue : Qfalse;
}

/* ------------------------------------------------------------------- */

int
ca_is_value_array (void *ap)
{
  CArray *ca = (CArray *) ap;
  if ( ca_test_flag(ca, CA_FLAG_VALUE_ARRAY) ) {           /* test -> true */
    return 1;
  }
  else {                                                   /* test -> false */
    if ( ca_is_virtual(ca) && CAVIRTUAL(ca)->parent ) {
      if ( ca_is_value_array(CAVIRTUAL(ca)->parent) ) {     /* test -> true */
        ca_set_flag(ca, CA_FLAG_VALUE_ARRAY);
        return 1;
      }
    }
    return 0;                                            /* all test -> false */
  }
}

/* @overload value_array?

(Inquiry) Returns true if `self` is a value array
*/

VALUE
rb_ca_is_value_array (VALUE self)
{
  CArray *ca;
  Data_Get_Struct(self, CArray, ca);
  return ( ca_is_value_array(ca) ) ? Qtrue : Qfalse;
}

/* ------------------------------------------------------------------- */

int
ca_is_fixlen_type (void *ap)
{
  CArray *ca = (CArray *) ap;
  return ( ca->data_type == CA_FIXLEN );
}

/* @overload fixlen?

(Inquiry) Returns true if `self` is fixed-length type array
*/

VALUE
rb_ca_is_fixlen_type (VALUE self)
{
  CArray *ca;
  Data_Get_Struct(self, CArray, ca);
  return ca_is_fixlen_type(ca) ? Qtrue : Qfalse;
}

/* ------------------------------------------------------------------- */

int
ca_is_boolean_type (void *ap)
{
  CArray *ca = (CArray *) ap;
  return ( ca->data_type == CA_BOOLEAN );
}

/* @overload boolean?

(Inquiry) Return true if `self` is boolean type array  
*/

VALUE
rb_ca_is_boolean_type (VALUE self)
{
  CArray *ca;
  Data_Get_Struct(self, CArray, ca);
  return ca_is_boolean_type(ca) ? Qtrue : Qfalse;
}

/* ------------------------------------------------------------------- */

int
ca_is_numeric_type (void *ap)
{
  CArray *ca = (CArray *) ap;
  return ( ( ca->data_type >= CA_INT8 ) &&
           ( ca->data_type <= CA_CMPLX256 ) );
}

/* @overload numeric?

(Inquiry) Returns true if `self` is numeric type array  
*/

VALUE
rb_ca_is_numeric_type (VALUE self)
{
  CArray *ca;
  Data_Get_Struct(self, CArray, ca);
  return ca_is_numeric_type(ca) ? Qtrue : Qfalse;
}

/* ------------------------------------------------------------------- */

int
ca_is_integer_type (void *ap)
{
  CArray *ca = (CArray *) ap;
  return ( ( ca->data_type >= CA_INT8 ) &&
           ( ca->data_type <= CA_UINT64 ) );
}

/* @overload integer?

(Inquiry) Returns true if `self` is integer type array  
*/

VALUE
rb_ca_is_integer_type (VALUE self)
{
  CArray *ca;
  Data_Get_Struct(self, CArray, ca);
  return ca_is_integer_type(ca) ? Qtrue : Qfalse;
}

/* ------------------------------------------------------------------- */

int
ca_is_unsigned_type (void *ap)
{
  CArray *ca = (CArray *) ap;
  switch ( ca->data_type ) {
  case CA_UINT8:
  case CA_UINT16:
  case CA_UINT32:
  case CA_UINT64:
    return 1;
  default:
    return 0;
  }
}

/* @overload unsigned?

(Inquiry) Return true if `self` is unsigned integer type array  
*/

VALUE
rb_ca_is_unsigned_type (VALUE self)
{
  CArray *ca;
  Data_Get_Struct(self, CArray, ca);
  return ca_is_unsigned_type(ca) ? Qtrue : Qfalse;
}

/* ------------------------------------------------------------------- */

int
ca_is_float_type (void *ap)
{
  CArray *ca = (CArray *) ap;
  return ( ( ca->data_type >= CA_FLOAT32 ) &&
           ( ca->data_type <= CA_FLOAT128 ) );
}

/* @overload float?

(Inquiry) Returns true if `self` is float type array  
*/

VALUE
rb_ca_is_float_type (VALUE self)
{
  CArray *ca;
  Data_Get_Struct(self, CArray, ca);
  return ca_is_float_type(ca) ? Qtrue : Qfalse;
}

/* ------------------------------------------------------------------- */

int
ca_is_complex_type (void *ap)
{
  CArray *ca = (CArray *) ap;
  return ( ( ca->data_type >= CA_CMPLX64 ) &&
           ( ca->data_type <= CA_CMPLX256 ) );
}

/* @overload complex?

(Inquiry) Returns true if `self` is complex type array  
*/

VALUE
rb_ca_is_complex_type (VALUE self)
{
  CArray *ca;
  Data_Get_Struct(self, CArray, ca);
  return ca_is_complex_type(ca) ? Qtrue : Qfalse;
}

/* ------------------------------------------------------------------- */

int
ca_is_object_type (void *ap)
{
  CArray *ca = (CArray *) ap;
  return ( ca->data_type == CA_OBJECT );
}

/* @overload object?

(Inquiry) Returns true if `self` is object type array
*/

VALUE
rb_ca_is_object_type (VALUE self)
{
  CArray *ca;
  Data_Get_Struct(self, CArray, ca);
  return ca_is_object_type(ca) ? Qtrue : Qfalse;
}

/* ------------------------------------------------------------------- */

static ID id_parent;

/* @overload parent

(Attribute) 
Returns the parent carray if `self` has parent,
or returns nil if `self` has no parent.
*/

VALUE
rb_ca_parent (VALUE self)
{
  return rb_ivar_get(self, id_parent);
}

VALUE
rb_ca_set_parent (VALUE self, VALUE obj)
{
  OBJ_INFECT(self, obj);
  rb_ivar_set(self, id_parent, obj);
  if ( OBJ_FROZEN(obj) ) {
    rb_ca_freeze(self);
  }
  return obj;
}

/* ------------------------------------------------------------------- */

static ID id_data_class;

/* @overload data_class

(Attribute) 
Returns data_class if `self` is fixed-length type and it 
has the data class.
*/

VALUE
rb_ca_data_class (VALUE self)
{
  volatile VALUE parent, data_class;
  CArray *ca;
  Data_Get_Struct(self, CArray, ca);
  if ( ca_test_flag(ca, CA_FLAG_NOT_DATA_CLASS) ) {
    return Qnil;
  }
  if ( ! ca_is_fixlen_type(ca) ) {      /* not a fixlen array */
    ca_set_flag(ca, CA_FLAG_NOT_DATA_CLASS);
    return Qnil;
  }
  data_class = rb_ivar_get(self, id_data_class);
  if ( ! NIL_P(data_class) ) {
    return data_class;
  }
  else {
    return Qnil;
    if ( ca_is_entity(ca) ) {  /* no further parent */
      ca_set_flag(ca, CA_FLAG_NOT_DATA_CLASS);
      return Qnil;
    }
    else {
      parent = rb_ca_parent(self);
      if ( NIL_P(parent) ) {   /* no parent */
        ca_set_flag(ca, CA_FLAG_NOT_DATA_CLASS);
        return Qnil;
      }
      else {
        CArray *cr;
        Data_Get_Struct(parent, CArray, cr);
        if ( cr->bytes != ca->bytes ) {  /* byte size mismatch */
          ca_set_flag(ca, CA_FLAG_NOT_DATA_CLASS);
          return Qnil;
        }
        else {
          data_class = rb_ca_data_class(parent); /* parent's data class */
          if ( ! NIL_P(data_class) ) {
            return data_class;
          }
          else {
            ca_set_flag(ca, CA_FLAG_NOT_DATA_CLASS);
            return Qnil;
          }
        }
      }
    }
  }
}

/* @overload has_data_class?

(Inquiry) Returns true if `self` is fixed-length type and has the data class.
*/

VALUE
rb_ca_has_data_class (VALUE self)
{
  CArray *ca;
  Data_Get_Struct(self, CArray, ca);
  if ( ca_test_flag(ca, CA_FLAG_NOT_DATA_CLASS) ) {
    return Qfalse;
  }
  else {
    if ( ca_is_fixlen_type(ca) ) {
      if ( RTEST(rb_ca_data_class(self)) ) {
        return Qtrue;
      }
    }
    ca_set_flag(ca, CA_FLAG_NOT_DATA_CLASS);
    return Qfalse;
  }
}

/* ------------------------------------------------------------------- */

VALUE
rb_ca_data_type_inherit (VALUE self, VALUE other)
{
  if ( RTEST(rb_ca_is_fixlen_type(self)) ) {
    VALUE data_class = rb_ca_data_class(other);
    if ( RTEST(data_class) ) {
      rb_ivar_set(self, rb_intern("member"), rb_hash_new());
      return rb_ivar_set(self, id_data_class, data_class);
    }
  }
  return Qnil;
}

VALUE
rb_ca_data_type_import (VALUE self, VALUE data_type)
{
  if ( RTEST(rb_ca_is_fixlen_type(self)) &&
       rb_obj_is_data_class(data_type) ) {
    rb_ivar_set(self, rb_intern("member"), rb_hash_new());
    return rb_ivar_set(self, id_data_class, data_type);
  }
  return Qnil;
}

static VALUE
rb_ca_set_data_class (VALUE self, VALUE klass)
{
  if ( RTEST(rb_ca_is_fixlen_type(self)) &&
       rb_obj_is_data_class(klass) ) {
    rb_ivar_set(self, rb_intern("member"), rb_hash_new());
    return rb_ivar_set(self, id_data_class, klass);
  }
  else {
    rb_raise(rb_eTypeError, "invalid data_class or self is not fixlen array.");
  }
  return Qnil;
}

/* ------------------------------------------------------------------- */

CArray *
ca_root_array (void *ap)
{
  CArray *ca = (CArray *)ap;
  if ( ca_is_entity(ca) ) {
    return ca;
  }
  else {
    CAVirtual *cr = (CAVirtual *)ca;
    if ( ! cr->parent ) {
      return ca;
    }
    else {
      return ca_root_array(cr->parent);
    }
  }
}

/* @overload root_array

(Attribute) 
Returns the object at the root of chain of reference.
*/

static VALUE
rb_ca_root_array (VALUE self)
{
  volatile VALUE refary;
  CArray *ca;
  Data_Get_Struct(self, CArray, ca);
  if ( ca_is_entity(ca) ) {
    return self;
  }
  else {
    refary = rb_ca_parent(self);
    if ( NIL_P(refary) ) {
      return self;
    }
    else {
      return rb_ca_root_array(refary);
    }
  }
}

/* ------------------------------------------------------------------- */

static VALUE
rb_ca_ancestors_loop (VALUE self, VALUE list)
{
  volatile VALUE refary;
  CArray *ca;
  Data_Get_Struct(self, CArray, ca);
  rb_ary_unshift(list, self);
  if ( ca_is_entity(ca) ) {
    return list;
  }
  else {
    refary = rb_ca_parent(self);
    if ( rb_obj_is_carray(refary) ) {
      return rb_ca_ancestors_loop(refary, list);
    }
    else {
      return list;
    }
  }
}

/* @overload ancestors

(Attribute) 
Returns the list of objects in the chain of reference.
*/

static VALUE
rb_ca_ancestors (VALUE self)
{
  volatile VALUE list;
  CArray *ca;
  Data_Get_Struct(self, CArray, ca);
  list = rb_ary_new();
  return rb_ca_ancestors_loop(self, list);
}

/* ------------------------------------------------------------------- */

void
Init_carray_attribute ()
{
  id_parent     = rb_intern("parent");
  id_data_class = rb_intern("data_class");

  rb_define_method(rb_cCArray, "obj_type", rb_ca_obj_type, 0);
  rb_define_method(rb_cCArray, "data_type", rb_ca_data_type, 0);
  rb_define_method(rb_cCArray, "bytes", rb_ca_bytes, 0);
  rb_define_method(rb_cCArray, "ndim", rb_ca_ndim, 0); 
  rb_define_method(rb_cCArray, "rank", rb_ca_ndim, 0); /* after carray-1.5.0 */
  rb_define_method(rb_cCArray, "shape", rb_ca_dim, 0); /* after carray-1.5.0 */
  rb_define_method(rb_cCArray, "dim", rb_ca_dim, 0);
  rb_define_method(rb_cCArray, "dim0", rb_ca_dim0, 0);
  rb_define_method(rb_cCArray, "dim1", rb_ca_dim1, 0);
  rb_define_method(rb_cCArray, "dim2", rb_ca_dim2, 0);
  rb_define_method(rb_cCArray, "dim3", rb_ca_dim3, 0);
  rb_define_method(rb_cCArray, "elements", rb_ca_elements, 0);
  rb_define_method(rb_cCArray, "length", rb_ca_elements, 0); 
  rb_define_method(rb_cCArray, "size", rb_ca_elements, 0); 
  
  rb_define_method(rb_cCArray, "data_type_name", rb_ca_data_type_name, 0);

  rb_define_method(rb_cCArray, "parent", rb_ca_parent, 0);

  rb_define_method(rb_cCArray, "data_class", rb_ca_data_class, 0);
  rb_define_method(rb_cCArray, "data_class=", rb_ca_set_data_class, 1);

  rb_define_method(rb_cCArray, "scalar?", rb_ca_is_scalar, 0);

  rb_define_method(rb_cCArray, "entity?", rb_ca_is_entity, 0);
  rb_define_method(rb_cCArray, "virtual?", rb_ca_is_virtual, 0);
  rb_define_method(rb_cCArray, "value_array?", rb_ca_is_value_array, 0);
  rb_define_method(rb_cCArray, "mask_array?", rb_ca_is_mask_array, 0);

  rb_define_method(rb_cCArray, "empty?", rb_ca_is_empty, 0);
  rb_define_method(rb_cCArray, "read_only?", rb_ca_is_read_only, 0);
  rb_define_method(rb_cCArray, "attached?", rb_ca_is_attached, 0);

  rb_define_method(rb_cCArray, "has_data_class?", rb_ca_has_data_class, 0);

  rb_define_method(rb_cCArray, "fixlen?",   rb_ca_is_fixlen_type, 0);
  rb_define_method(rb_cCArray, "boolean?",  rb_ca_is_boolean_type, 0);
  rb_define_method(rb_cCArray, "numeric?",  rb_ca_is_numeric_type, 0);
  rb_define_method(rb_cCArray, "integer?",  rb_ca_is_integer_type, 0);
  rb_define_method(rb_cCArray, "unsigned?", rb_ca_is_unsigned_type, 0);
  rb_define_method(rb_cCArray, "float?",    rb_ca_is_float_type, 0);
  rb_define_method(rb_cCArray, "complex?",  rb_ca_is_complex_type, 0);
  rb_define_method(rb_cCArray, "object?",   rb_ca_is_object_type, 0);

  rb_define_method(rb_cCArray, "root_array", rb_ca_root_array, 0);
  rb_define_method(rb_cCArray, "ancestors", rb_ca_ancestors, 0);
}

