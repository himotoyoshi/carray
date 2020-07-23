/* ---------------------------------------------------------------------------

  carray_cast.c

  This file is part of Ruby/CArray extension library.

  Copyright (C) 2005-2020 Hiroki Motoyoshi

---------------------------------------------------------------------------- */

#include "carray.h"

boolean8_t
OBJ2BOOL (VALUE v)
{
  if ( v == Qfalse || v == Qnil ) {
    return 0;
  }
  else if ( v == Qtrue ) {
    return 1;
  }
  else if ( rb_obj_is_kind_of(v, rb_cInteger) ) {
    int flag = NUM2INT(v);
    if ( flag == 0 || flag == 1 ) {
      return flag;
    }
  }
  {
    VALUE inspect = rb_inspect(v);
    rb_raise(rb_eCADataTypeError,
             "can't cast object '%s' to <boolean>", StringValuePtr(inspect));
  }
}

VALUE
BOOL2OBJ (boolean8_t x)
{
  return ( x != 0 ) ? INT2NUM(1) : INT2NUM(0);
}

double
OBJ2DBL (VALUE val)
{
  switch ( TYPE(val) ) {
  case T_FLOAT:
    return NUM2DBL(val);
  case T_NIL:
    return 0.0/0.0;
    /* rb_raise(rb_eTypeError, "no implicit conversion to float from nil"); */
    break;
  case T_STRING: {
    volatile VALUE rstr = rb_funcall(val, rb_intern("strip"), 0);
    char *str = StringValuePtr(rstr);
    if ( ! strncasecmp("nan", str, 3) ) {
      return 0.0/0.0;
    }
    else if ( ! strncasecmp("inf", str, 3) ) {
      return 1.0/0.0;
    }
    else if ( ! strncasecmp("-inf", str, 4) ) {
      return -1.0/0.0;
    }
    else if ( ! strncasecmp("infinity", str, 8) ) {
      return 1.0/0.0;
    }
    else if ( ! strncasecmp("-infinity", str, 9) ) {
      return -1.0/0.0;
    }
    return NUM2DBL(rb_Float(val));
  }
  default:
    return NUM2DBL(rb_Float(val));
  }
}

long
rb_obj2long (VALUE val)
{
  switch ( TYPE(val) ) {
  case T_FIXNUM:
    return NUM2LONG(val);
  case T_BIGNUM:
    return (long) NUM2LL(val);
  case T_NIL:
    rb_raise(rb_eTypeError, "no implicit conversion from nil to integer");
    break;
  default:
    return NUM2LONG(rb_Integer(val));
  }
}

unsigned long
rb_obj2ulong (VALUE val)
{
  switch ( TYPE(val) ) {
  case T_FIXNUM:
    return NUM2ULONG(val);
  case T_BIGNUM:
    return (unsigned long) rb_num2ull(val);
  case T_NIL:
    rb_raise(rb_eTypeError, "no implicit conversion from nil to integer");
    break;
  default:
    return NUM2ULONG(rb_Integer(val));
  }
}

long long
rb_obj2ll (VALUE val)
{
  switch ( TYPE(val) ) {
  case T_FIXNUM:
    return NUM2LONG(val);
  case T_NIL:
    rb_raise(rb_eTypeError, "no implicit conversion fron nil to integer");
    break;
  default:
    return NUM2LL(rb_Integer(val));
  }
}

unsigned long long
rb_obj2ull (VALUE val)
{
  switch ( TYPE(val) ) {
  case T_FIXNUM:
    return NUM2ULONG(val);
  case T_NIL:
    rb_raise(rb_eTypeError, "no implicit conversion from nil to integer");
    break;
  default:
    return rb_num2ull(rb_Integer(val));
  }
}

void
ca_cast_block (ca_size_t n, void *ap1, void *ptr1,
               void *ap2, void *ptr2)
{
  CArray *ca1 = (CArray *) ap1;
  CArray *ca2 = (CArray *) ap2;
  if ( n < 0 ) {
    rb_raise(rb_eRuntimeError, 
             "[BUG] in ca_cast_block(): negative count");
  }
  ca_cast_func_table[ca1->data_type][ca2->data_type](n, ca1, ptr1, ca2, ptr2, NULL);
}

void
ca_cast_block_with_mask (ca_size_t n, void *ap1, void *ptr1,
                         void *ap2, void *ptr2, boolean8_t *m)
{
  CArray *ca1 = (CArray *) ap1;
  CArray *ca2 = (CArray *) ap2;
  if ( n < 0 ) {
    rb_raise(rb_eRuntimeError, 
             "[BUG] in ca_cast_block_with_mask(): negative count");
  }
  ca_cast_func_table[ca1->data_type][ca2->data_type](n, ca1, ptr1, ca2, ptr2, m);
}

VALUE
ca_ptr2obj (void *ap, void *ptr)
{
  volatile VALUE obj;
  static CArray dummy;
  CArray *ca = (CArray *) ap;
  dummy.data_type = CA_OBJECT;
  ca_cast_func_table[ca->data_type][CA_OBJECT](1, ca, ptr, &dummy, (void*)&obj, NULL);
  return obj;
}

void
ca_obj2ptr (void *ap, VALUE obj, void *ptr)
{
  CArray *ca = (CArray *)ap;
  static CArray dummy;
  dummy.data_type = CA_OBJECT;
  ca_cast_func_table[CA_OBJECT][ca->data_type](1, &dummy, &obj, ca, ptr, NULL);
  return;
}

void
ca_ptr2ptr (void *ap1, void *ptr1, void *ap2, void *ptr2)
{
  CArray *ca1 = (CArray *)ap1;
  CArray *ca2 = (CArray *)ap2;
  ca_cast_func_table[ca1->data_type][ca2->data_type](1, ca1, ptr1, ca2, ptr2, NULL);
  return;
}

void
ca_ptr2val (void *ap1, void *ptr1, int8_t data_type, void *ptr2)
{
  CArray *ca1 = (CArray *)ap1;
  static CArray dummy;
  CA_CHECK_DATA_TYPE(data_type);
  dummy.data_type = data_type;
  ca_cast_func_table[ca1->data_type][data_type](1, ca1, ptr1, &dummy, ptr2, NULL);
  return;
}

void
ca_val2ptr (int8_t data_type, void *ptr1, void *ap2, void *ptr2)
{
  CArray *ca2 = (CArray *)ap2;
  static CArray dummy;
  CA_CHECK_DATA_TYPE(data_type);
  dummy.data_type = data_type;
  ca_cast_func_table[data_type][ca2->data_type](1, &dummy, ptr1, ca2, ptr2, NULL);
  return;
}

void
ca_val2val (int8_t data_type1, void *ptr1, int8_t data_type2, void *ptr2)
{
  static CArray dummy1, dummy2;
  CA_CHECK_DATA_TYPE(data_type1);
  CA_CHECK_DATA_TYPE(data_type2);
  dummy1.data_type = data_type1;
  dummy2.data_type = data_type2;
  ca_cast_func_table[data_type1][data_type2](1, &dummy1, ptr1, &dummy2, ptr2, NULL);
  return;
}

/* --------------------------------------------------------------------- */

static VALUE
rb_ca_data_class_to_object (VALUE self) 
{
  volatile VALUE obj;
  CArray *ca;
  int i;

  Data_Get_Struct(self, CArray, ca);

  if ( ca_is_scalar(ca) ) {
    obj = rb_cscalar_new(CA_OBJECT, 0, ca->mask);
  }
  else {
    obj = rb_carray_new(CA_OBJECT, ca->ndim, ca->dim, 0, ca->mask);
  }

  for (i=0; i<ca->elements; i++) {
    rb_ca_store_addr(obj, i, rb_ca_fetch_addr(self, i));
  }
  
  return obj;
}

static VALUE
rb_ca_object_to_data_class (VALUE self, VALUE rtype, ca_size_t bytes) 
{
  volatile VALUE obj, rval;
  CArray *ca;
  int i;
  ID id_encode = rb_intern("encode");

  Data_Get_Struct(self, CArray, ca);

  if ( ca_is_scalar(ca) ) {
    obj = rb_cscalar_new(CA_FIXLEN, bytes, ca->mask);
  }
  else {
    obj = rb_carray_new(CA_FIXLEN, ca->ndim, ca->dim, bytes, ca->mask);
  }
  rb_ca_data_type_import(obj, rtype);

  for (i=0; i<ca->elements; i++) {
    rval = rb_ca_fetch_addr(self, i);
    if ( TYPE(rval) == T_STRING ) {
      rb_ca_store_addr(obj, i, rval);
    }
    else {
      rb_ca_store_addr(obj, i, rb_funcall(rval, id_encode, 0));
    }
  }
  
  return obj;
}

/* @overload to_type (data_type, bytes: nil) 

(Conversion) Returns an array of elements that are converted 
to the given data type from the object.
*/

static VALUE
rb_ca_to_type_internal (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE obj, rtype = Qnil, ropt, rbytes = Qnil;
  CArray *ca, *cb;
  int8_t data_type;
  ca_size_t bytes;

  Data_Get_Struct(self, CArray, ca);

  rb_scan_args(argc, argv, "11", (VALUE *) &rtype, (VALUE *) &ropt);
  rb_scan_options(ropt, "bytes", &rbytes);

  rb_ca_guess_type_and_bytes(rtype, rbytes, &data_type, &bytes);

  if ( rb_ca_has_data_class(self) && data_type == CA_OBJECT ) {
    return rb_ca_data_class_to_object(self);
  }

  if ( rb_ca_is_object_type(self) && rb_obj_is_data_class(rtype) ) {
    return rb_ca_object_to_data_class(self, rtype, bytes);
  }

  ca_update_mask(ca);

  if ( ca_is_scalar(ca) ) {
    obj = rb_cscalar_new(data_type, bytes, ca->mask);
  }
  else {
    obj = rb_carray_new(data_type, ca->ndim, ca->dim, bytes, ca->mask);
  }

  rb_ca_data_type_import(obj, rtype);

  Data_Get_Struct(obj, CArray, cb);

  ca_attach(ca);
  if ( ca_has_mask(ca) ) {
    ca_cast_block_with_mask(cb->elements, ca, ca->ptr, cb, cb->ptr, 
                            (boolean8_t*)ca->mask->ptr);
  }
  else {
    ca_cast_block(cb->elements, ca, ca->ptr, cb, cb->ptr);
  }
  ca_detach(ca);

  return obj;
}

VALUE
rb_ca_to_type (VALUE self, VALUE rtype, VALUE rbytes)
{
  volatile VALUE ropt = rb_hash_new();
  VALUE args[2] = { rtype, ropt };
  rb_set_options(ropt, "bytes", rbytes);
  return rb_ca_to_type_internal(2, args, self);
}

#define rb_ca_to_type_method_body(code) \
{ \
  VALUE rcode = INT2NUM(code); \
  return rb_ca_to_type_internal(1, &rcode, self); \
}

/* @overload fixlen (bytes:)

(Conversion) Short-Hand of "CArray#to_type(:fixlen, bytes:)"
 */

VALUE
rb_ca_to_fixlen (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE ropt = rb_pop_options(&argc, &argv);
  VALUE list[2];
//  rb_scan_args(argc, argv, "0");
  list[0] = INT2NUM(CA_FIXLEN);
  list[1] = ropt;
  return rb_ca_to_type_internal(2, list, self);
}

/* @overload fixlen (bytes:)

(Conversion) Short-Hand of "CArray#to_type(:boolean)"
 */
VALUE rb_ca_to_boolean (VALUE self)
{
  rb_ca_to_type_method_body(CA_BOOLEAN);
}

/* @overload int8 

(Conversion) Short-Hand of "CArray#to_type(:int8)"
*/
VALUE rb_ca_to_int8 (VALUE self)
{
  rb_ca_to_type_method_body(CA_INT8);
}

/* @overload uint8 

(Conversion) Short-Hand of "CArray#to_type(:uint8)"
*/
VALUE rb_ca_to_uint8 (VALUE self)
{
  rb_ca_to_type_method_body(CA_UINT8);
}

/* @overload int16 

(Conversion) Short-Hand of "CArray#to_type(:int16)"
*/
VALUE rb_ca_to_int16 (VALUE self)
{
  rb_ca_to_type_method_body(CA_INT16);
}

/* @overload uint16

(Conversion) Short-Hand of "CArray#to_type(:uint16)"
*/
VALUE rb_ca_to_uint16 (VALUE self)
{
  rb_ca_to_type_method_body(CA_UINT16);
}

/* @overload int32 

(Conversion) Short-Hand of "CArray#to_type(:int32)"
*/
VALUE rb_ca_to_int32 (VALUE self)
{
  rb_ca_to_type_method_body(CA_INT32);
}

/* @overload uint32

(Conversion) Short-Hand of "CArray#to_type(:uint32)"
*/
VALUE rb_ca_to_uint32 (VALUE self)
{
  rb_ca_to_type_method_body(CA_UINT32);
}

/* @overload int64 

(Conversion) Short-Hand of "CArray#to_type(:int64)"
*/
VALUE rb_ca_to_int64 (VALUE self)
{
  rb_ca_to_type_method_body(CA_INT64);
}

/* @overload uint64 

(Conversion) Short-Hand of "CArray#to_type(:uint64)"
*/
VALUE rb_ca_to_uint64 (VALUE self)
{
  rb_ca_to_type_method_body(CA_UINT64);
}

/* @overload float32 

(Conversion) Short-Hand of "CArray#to_type(:float32)"
*/
VALUE rb_ca_to_float32 (VALUE self)
{
  rb_ca_to_type_method_body(CA_FLOAT32);
}

/* @overload float64

(Conversion) Short-Hand of "CArray#to_type(:float64)"
*/
VALUE rb_ca_to_float64 (VALUE self)
{
  rb_ca_to_type_method_body(CA_FLOAT64);
}

/* @overload float128

(Conversion) Short-Hand of "CArray#to_type(:float128)"
*/
VALUE rb_ca_to_float128 (VALUE self)
{
  rb_ca_to_type_method_body(CA_FLOAT128);
}

/* @overload cmplx64

(Conversion) Short-Hand of "CArray#to_type(:cmplx64)"
*/
VALUE rb_ca_to_cmplx64 (VALUE self)
{
  rb_ca_to_type_method_body(CA_CMPLX64);
}

/* @overload cmplx128

(Conversion) Short-Hand of "CArray#to_type(:cmplx128)"
*/
VALUE rb_ca_to_cmplx128 (VALUE self)
{
  rb_ca_to_type_method_body(CA_CMPLX128);
}

/* @overload cmplx256

(Conversion) Short-Hand of "CArray#to_type(:cmplx256)"
*/
VALUE rb_ca_to_cmplx256 (VALUE self)
{
  rb_ca_to_type_method_body(CA_CMPLX256);
}

/* @overload object

(Conversion) Short-Hand of "CArray#to_type(:object)"
*/
VALUE rb_ca_to_VALUE (VALUE self)
{
  rb_ca_to_type_method_body(CA_OBJECT);
}

/* ------------------------------------------------------------------------*/

/* CArray#as_type */

static VALUE
rb_ca_as_type_internal (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE obj, rtype = Qnil, ropt, rbytes = Qnil;
  CArray *ca;
  int8_t data_type;
  ca_size_t bytes;

  rb_scan_args(argc, argv, "11", (VALUE *) &rtype, (VALUE *) &ropt);
  rb_scan_options(ropt, "bytes", &rbytes);

  rb_ca_guess_type_and_bytes(rtype, rbytes, &data_type, &bytes);

  Data_Get_Struct(self, CArray, ca);
  if ( ca->data_type == data_type ) {
    if ( ! ca_is_fixlen_type(ca) ) {
      return self;
    }
  }

  obj = rb_ca_fake_type(self, rtype, rbytes);
  rb_ca_data_type_import(obj, rtype);

  return obj;
}

/* @overload as_type (data_type, bytes: nil)

(Reference) Creates CAFake object of the given data type refers to the object.
*/

VALUE
rb_ca_as_type (VALUE self, VALUE rtype, VALUE rbytes)
{
  volatile VALUE ropt = rb_hash_new();
  VALUE args[2] = { rtype, ropt };
  rb_set_options(ropt, "bytes", rbytes);
  return rb_ca_as_type_internal(2, args, self);
}

#define rb_ca_as_type_method_body(code) \
{ \
  VALUE rcode = INT2NUM(code); \
  return rb_ca_as_type_internal(1, &rcode, self); \
}

/* @overload as_fixlen (bytes: nil)

(Reference) Short-Hand of `CArray#as_type(:fixlen, bytes: nil)`
 */
VALUE
rb_ca_as_fixlen (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE rtype, ropt = rb_pop_options(&argc, &argv);
  VALUE list[2];
  rb_scan_args(argc, argv, "01", (VALUE *)  &rtype);
  list[0] = ( NIL_P(rtype) ) ? INT2NUM(CA_FIXLEN) : rtype;
  list[1] = ropt;
  return rb_ca_as_type_internal(2, list, self);
}

/* @overload as_boolean

(Reference) Short-Hand of `CArray#as_type(:boolean)`
*/
VALUE rb_ca_as_boolean (VALUE self)
{
  rb_ca_as_type_method_body(CA_BOOLEAN);
}

/* @overload as_int8

(Reference) Short-Hand of `CArray#as_type(:int8)`
*/
VALUE rb_ca_as_int8 (VALUE self)
{
  rb_ca_as_type_method_body(CA_INT8);
}

/* @overload as_uint8

(Reference) Short-Hand of `CArray#as_type(:uint8)`
*/
VALUE rb_ca_as_uint8 (VALUE self)
{
  rb_ca_as_type_method_body(CA_UINT8);
}

/* @overload as_int16

(Reference) Short-Hand of `CArray#as_type(:int16)`
*/
VALUE rb_ca_as_int16 (VALUE self)
{
  rb_ca_as_type_method_body(CA_INT16);
}

/* @overload as_uint16

(Reference) Short-Hand of `CArray#as_type(:uint16)`
*/
VALUE rb_ca_as_uint16 (VALUE self)
{
  rb_ca_as_type_method_body(CA_UINT16);
}

/* @overload as_int32

(Reference) Short-Hand of `CArray#as_type(:int32)`
*/
VALUE rb_ca_as_int32 (VALUE self)
{
  rb_ca_as_type_method_body(CA_INT32);
}

/* @overload as_uint32

(Reference) Short-Hand of `CArray#as_type(:uint32)`
*/
VALUE rb_ca_as_uint32 (VALUE self)
{
  rb_ca_as_type_method_body(CA_UINT32);
}

/* @overload as_int64

(Reference) Short-Hand of `CArray#as_type(:int64)`
*/
VALUE rb_ca_as_int64 (VALUE self)
{
  rb_ca_as_type_method_body(CA_INT64);
}

/* @overload as_uint64

(Reference) Short-Hand of `CArray#as_type(:uint64)`
*/
VALUE rb_ca_as_uint64 (VALUE self)
{
  rb_ca_as_type_method_body(CA_UINT64);
}

/* @overload as_float32

(Reference) Short-Hand of `CArray#as_type(:float32)`
*/
VALUE rb_ca_as_float32 (VALUE self)
{
  rb_ca_as_type_method_body(CA_FLOAT32);
}

/* @overload as_float64

(Reference) Short-Hand of `CArray#as_type(:float64)`
*/
VALUE rb_ca_as_float64 (VALUE self)
{
  rb_ca_as_type_method_body(CA_FLOAT64);
}

/* @overload as_float128

(Reference) Short-Hand of `CArray#as_type(:float128)`
*/
VALUE rb_ca_as_float128 (VALUE self)
{
  rb_ca_as_type_method_body(CA_FLOAT128);
}

/* @overload as_cmplx64

(Reference) Short-Hand of `CArray#as_type(:cmplx64)`
*/
VALUE rb_ca_as_cmplx64 (VALUE self)
{
  rb_ca_as_type_method_body(CA_CMPLX64);
}

/* @overload as_cmplx128

(Reference) Short-Hand of `CArray#as_type(:cmplx128)`
*/
VALUE rb_ca_as_cmplx128 (VALUE self)
{
  rb_ca_as_type_method_body(CA_CMPLX128);
}

/* @overload as_cmplx256

(Reference) Short-Hand of `CArray#as_type(:cmplx256)`
*/
VALUE rb_ca_as_cmplx256 (VALUE self)
{
  rb_ca_as_type_method_body(CA_CMPLX256);
}

/* @overload as_object

(Reference) Short-Hand of `CArray#as_type(:object)`
*/
VALUE rb_ca_as_VALUE (VALUE self)
{
  rb_ca_as_type_method_body(CA_OBJECT);
}

/* ------------------------------------------------------------------------*/

VALUE
rb_ca_cast_block (ca_size_t n, VALUE ra1, void *ptr1,
                  VALUE ra2, void *ptr2)
{
  CArray *ca1, *ca2;
  Data_Get_Struct(ra1, CArray, ca1);
  Data_Get_Struct(ra2, CArray, ca2);
  if ( n < 0 ) {
    rb_raise(rb_eRuntimeError, "[BUG] in rb_ca_cast_block: negative count");
  }
  ca_cast_func_table[ca1->data_type][ca2->data_type](n, ca1, ptr1, ca2, ptr2, NULL);
  return Qnil;
}

VALUE
rb_ca_ptr2ptr (VALUE ra1, void *ptr1, VALUE ra2, void *ptr2)
{
  CArray *ca1, *ca2;
  Data_Get_Struct(ra1, CArray, ca1);
  Data_Get_Struct(ra2, CArray, ca2);
  ca_cast_func_table[ca1->data_type][ca2->data_type](1, ca1, ptr1, ca2, ptr2, NULL);
  return Qnil;
}


VALUE
rb_ca_ptr2obj (VALUE self, void *ptr)
{
  volatile VALUE obj;
  static CArray dummy;
  CArray *ca;
  Data_Get_Struct(self, CArray, ca);
  dummy.data_type = CA_OBJECT;
  ca_cast_func_table[ca->data_type][CA_OBJECT](1, ca, ptr, &dummy, (void*)&obj, NULL);
  if ( ca_is_fixlen_type(ca) ) {
    OBJ_TAINT(obj);
    return rb_ca_data_class_decode(self, obj);
  }
  else {
    return obj;
  }
}

VALUE
rb_ca_obj2ptr (VALUE self, VALUE obj, void *ptr)
{
  static CArray dummy;
  CArray *ca;
  Data_Get_Struct(self, CArray, ca);
  if ( obj == CA_UNDEF ) {
    memset(ptr, 0, ca->bytes);
  }
  else {
    obj = ( ca_is_fixlen_type(ca) ) ? rb_ca_data_class_encode(self, obj) : obj;
    dummy.data_type = CA_OBJECT;
    ca_cast_func_table[CA_OBJECT][ca->data_type](1, &dummy, &obj, ca, ptr, NULL);
  }
  return Qnil;
}

VALUE
rb_ca_wrap_writable (VALUE arg, VALUE rtype)
{
  volatile VALUE obj = arg;
  CArray *ca = NULL;
  int8_t data_type;

  if ( rb_obj_is_carray(obj) ) {                    /* obj == carray */
    Data_Get_Struct(obj, CArray, ca);
    if ( ca_is_readonly(ca) ) {
      rb_raise(rb_eRuntimeError, "can't modify read-only carray");
    }
    if ( NIL_P(rtype) ) {
      data_type = ca->data_type;
    }
    else {
      data_type = rb_ca_guess_type(rtype);
    }
    if ( ca->data_type != data_type ) {
      obj = rb_ca_fake_type(obj, rtype, Qnil);
    }
  }
  else if ( NIL_P(obj) ) {                          /* obj == nil */
    if ( NIL_P(rtype) ) {
      data_type = CA_OBJECT;
    }
    else {
      data_type = rb_ca_guess_type(rtype);
    }
    obj = rb_cscalar_new(data_type, 0, NULL);
  }
  else if ( rb_respond_to(obj, rb_intern("ca")) ) { /* respond_to obj.ca */
    obj = rb_funcall(obj, rb_intern("ca"), 0);
    Data_Get_Struct(obj, CArray, ca);
    if ( NIL_P(rtype) ) {
      data_type = ca->data_type;
    }
    else {
      data_type = rb_ca_guess_type(rtype);
    }
    if ( ca->data_type != data_type ) {
      obj = rb_ca_fake_type(obj, INT2NUM(data_type), Qnil);
    }
  }
  else {
    volatile VALUE inspect = rb_inspect(CLASS_OF(obj));
    rb_raise(rb_eRuntimeError,
             "given object '%s' can't be wrapped as carray",
             StringValuePtr(inspect));
  }

  return obj;
}

/* @overload wrap_writable (other, date_type = nil)

[TBD]
*/

static VALUE
rb_ca_s_wrap_writable (int argc, VALUE *argv, VALUE klass)
{
  volatile VALUE obj, rtype;
  rb_scan_args(argc, argv, "11", (VALUE *) &obj, (VALUE *) &rtype);
  return rb_ca_wrap_writable(obj, rtype);
}

VALUE
rb_ca_wrap_readonly (VALUE arg, VALUE rtype)
{
  volatile VALUE obj = arg;
  CArray *ca = NULL;
  int8_t data_type;

  if ( rb_obj_is_carray(obj) ) {                     /* carray */
    Data_Get_Struct(obj, CArray, ca);
    if ( NIL_P(rtype) ) {
      data_type = ca->data_type;
    }
    else {
      data_type = rb_ca_guess_type(rtype);
    }
    if ( ca->data_type != data_type ) {
      obj = rb_ca_fake_type(obj, rtype, Qnil);
    }
  }
  else if ( rb_obj_is_kind_of(obj, rb_cNumeric) ) {  /* number */
    if ( NIL_P(rtype) ) {
      data_type = CA_OBJECT;
    }
    else {
      data_type = rb_ca_guess_type(rtype);
    }
    obj = rb_cscalar_new_with_value(data_type, 0, obj);
  }
  else if ( TYPE(obj) == T_ARRAY ) {                 /* array */
    obj = rb_funcall(obj, rb_intern("to_ca"), 0);
    Data_Get_Struct(obj, CArray, ca);
    if ( NIL_P(rtype) ) {
      data_type = CA_OBJECT;
    }
    else {
      data_type = rb_ca_guess_type(rtype);
    }
    if ( ca->data_type != data_type ) {
      obj = rb_ca_fake_type(obj, INT2NUM(data_type), Qnil);
    }
  }
  else if ( TYPE(obj) == T_STRING ) {                /* string */
    if ( NIL_P(rtype) ) {
      data_type = CA_OBJECT;
    }
    else {
      data_type = rb_ca_guess_type(rtype);
    }
    if ( data_type == CA_OBJECT ) {
      obj = rb_cscalar_new_with_value(data_type, 0, obj);
    }
    else {
      volatile VALUE ref = obj;
      if ( ! RB_OBJ_FROZEN(ref) ) {
        ref = rb_obj_dup(ref);
        rb_obj_freeze(ref);
      }
      ca_size_t dim = RSTRING_LEN(ref)/ca_sizeof[data_type];
      obj = rb_ca_wrap_new(data_type, 1, &dim, ca_sizeof[data_type], NULL, RSTRING_PTR(ref));
      rb_ivar_set(obj, rb_intern("referred_object"), ref);
    }
  }
  else if ( NIL_P(obj) ) {                            /* nil */
    if ( NIL_P(rtype) ) {
      data_type = CA_OBJECT;
    }
    else {
      data_type = rb_ca_guess_type(rtype);
    }
    obj = rb_cscalar_new(data_type, 0, NULL);
  }
  else if ( rb_respond_to(obj, rb_intern("ca")) ) {
    obj = rb_funcall(obj, rb_intern("ca"), 0);
    Data_Get_Struct(obj, CArray, ca);
    if ( NIL_P(rtype) ) {
      data_type = ca->data_type;
    }
    else {
      data_type = rb_ca_guess_type(rtype);
    }
    if ( ca->data_type != data_type ) {
      obj = rb_ca_fake_type(obj, INT2NUM(data_type), Qnil);
    }
  }
  else if ( rb_respond_to(obj, rb_intern("to_ca")) ) {
    obj = rb_funcall(obj, rb_intern("to_ca"), 0);
    Data_Get_Struct(obj, CArray, ca);
    if ( NIL_P(rtype) ) {
      data_type = ca->data_type;
    }
    else {
      data_type = rb_ca_guess_type(rtype);
    }
    if ( ca->data_type != data_type ) {
      obj = rb_ca_fake_type(obj, INT2NUM(data_type), Qnil);
    }
  }
  else {                                           /* object */
    if ( NIL_P(rtype) ) {
      data_type = CA_OBJECT;
    }
    else {
      data_type = rb_ca_guess_type(rtype);
    }
    obj = rb_cscalar_new_with_value(data_type, 0, obj);
  }

  return obj;
}

/* @overload wrap_readonly (other, date_type = nil)

[TBD]
*/

static VALUE
rb_ca_s_wrap_readonly (int argc, VALUE *argv, VALUE klass)
{
  volatile VALUE obj, rtype;
  rb_scan_args(argc, argv, "11", (VALUE *) &obj, (VALUE *) &rtype);
  return rb_ca_wrap_readonly(obj, rtype);
}

VALUE
rb_ca_cast (volatile VALUE self)
{
  volatile VALUE obj = self;
  if ( ! rb_obj_is_carray(obj) ) {
    switch ( TYPE(obj) ) {
    case T_FIXNUM:
    case T_BIGNUM:
      obj = rb_cscalar_new_with_value(CA_INT64, 0, obj);
      break;
    case T_FLOAT:
      obj = rb_cscalar_new_with_value(CA_FLOAT64, 0, obj);
      break;
    case T_TRUE:
    case T_FALSE:
      obj = rb_cscalar_new_with_value(CA_BOOLEAN, 0, obj);
      break;
    case T_ARRAY:
      obj = rb_funcall(obj, rb_intern("to_ca"), 0);
      break;
    default:
      if ( rb_obj_is_kind_of(obj, rb_cRange) ) {
        obj = rb_funcall(obj, rb_intern("to_ca"), 0);
        break;
      }
#ifdef HAVE_COMPLEX_H
      if ( rb_obj_is_kind_of(obj, rb_cCComplex) ) {
        obj = rb_cscalar_new_with_value(CA_CMPLX128, 0, obj);
        break;
      }
#endif
      obj = rb_cscalar_new_with_value(CA_OBJECT, 0, obj);
      break;
    }
  }
  return obj;
}

/* @overload cast (value)

[TBD]
*/

static VALUE
rb_ca_s_cast (VALUE klass, VALUE val)
{
  return rb_ca_cast(val);
}

void
rb_ca_cast_self_or_other (volatile VALUE *self, volatile VALUE *other)
{
  CArray *ca, *cb;
  int test;
  int self_is_object = 0;
  int other_is_object = 0;

  if ( ! rb_obj_is_carray(*self) ) {
    self_is_object = 1;
    if ( rb_ca_is_object_type(*other) ) {
      *self = rb_cscalar_new_with_value(CA_OBJECT, 0, *self);
    }
    else if ( rb_ca_is_float_type(*other) ) {
      *self = rb_cscalar_new_with_value(CA_FLOAT64, 0, *self);
    }
#ifdef HAVE_COMPLEX_H
    else if ( rb_ca_is_complex_type(*other) ) {
      *self = rb_cscalar_new_with_value(CA_CMPLX128, 0, *self);
    }
#endif
    else {
      switch ( TYPE(*self) ) {
      case T_FIXNUM:
        *self = rb_cscalar_new_with_value(CA_INT64, 0, *self);
        break;
      case T_FLOAT:
        *self = rb_cscalar_new_with_value(CA_FLOAT64, 0, *self);
        break;
      case T_TRUE:
      case T_FALSE:
        *self = rb_cscalar_new_with_value(CA_BOOLEAN, 0, *self);
        break;
      default:
#ifdef HAVE_COMPLEX_H
        if ( rb_obj_is_kind_of(*self, rb_cCComplex) ) {
          *self = rb_cscalar_new_with_value(CA_CMPLX128, 0, *self);
          break;
        }
#endif
        *self = rb_cscalar_new_with_value(CA_OBJECT, 0, *self);
        break;
      }
    }
  }

  if ( ! rb_obj_is_carray(*other) ) {
    other_is_object = 1;

    if ( rb_ca_is_object_type(*self) ) {
      *other = rb_cscalar_new_with_value(CA_OBJECT, 0, *other);
    }
    else if ( rb_ca_is_float_type(*self) ) {
      *other = rb_cscalar_new_with_value(CA_FLOAT64, 0, *other);
    }
#ifdef HAVE_COMPLEX_H
    else if ( rb_ca_is_complex_type(*self) ) {
      *other = rb_cscalar_new_with_value(CA_CMPLX128, 0, *other);
    }
#endif
    else {
      switch ( TYPE(*other) ) {
      case T_FIXNUM:
      case T_BIGNUM:
        *other = rb_cscalar_new_with_value(CA_INT64, 0, *other);
        break;
      case T_FLOAT:
        *other = rb_cscalar_new_with_value(CA_FLOAT64, 0, *other);
        break;
      case T_TRUE:
      case T_FALSE:
        *other = rb_cscalar_new_with_value(CA_BOOLEAN, 0, *other);
        break;
      default:
#ifdef HAVE_COMPLEX_H
        if ( rb_obj_is_kind_of(*other, rb_cCComplex) ) {
          *other = rb_cscalar_new_with_value(CA_CMPLX128, 0, *other);
          break;
        }
#endif
        *other = rb_cscalar_new_with_value(CA_OBJECT, 0, *other);
        break;
      }
    }
  }

  Data_Get_Struct(*self, CArray, ca);
  Data_Get_Struct(*other, CArray, cb);

  if ( ca->obj_type == CA_OBJ_UNBOUND_REPEAT ) {
    *self = ca_ubrep_bind_with(*self, *other);
    Data_Get_Struct(*self, CArray, ca);
  }

  if ( cb->obj_type == CA_OBJ_UNBOUND_REPEAT ) {
    *other = ca_ubrep_bind_with(*other, *self);
    Data_Get_Struct(*other, CArray, cb);
  }

  if ( ca_is_scalar(ca) ^ ca_is_scalar(cb) || 
       self_is_object || 
       other_is_object ) {
    if ( other_is_object || 
         ( ( ! other_is_object ) && ca_is_scalar(cb) ) ) {
      test = ca_cast_table2[cb->data_type][ca->data_type];
      if ( test == 0 ) {
        return;
      }
      else if ( test > 0 ) {
        *other = rb_ca_wrap_readonly(*other, INT2NUM(ca->data_type));
        return;
      }
    }
    if ( self_is_object || 
         ( ( ! self_is_object ) && ca_is_scalar(ca) ) ) {
      test = ca_cast_table2[ca->data_type][cb->data_type];
      if ( test == 0 ) {
        return;
      }
      else if ( test > 0 ) {
        *self = rb_ca_wrap_readonly(*self, INT2NUM(cb->data_type));
        return;
      }
    }
  }
    
  test = ca_cast_table[cb->data_type][ca->data_type];

  if ( test == 0 ) {
    return;
  }
  else if ( test > 0 ) {
    *other = rb_ca_wrap_readonly(*other, INT2NUM(ca->data_type));
    return;
  }

  test = ca_cast_table[ca->data_type][cb->data_type];

  if ( test > 0 ) {
    *self = rb_ca_wrap_readonly(*self, INT2NUM(cb->data_type));
    return;
  }

  rb_raise(rb_eRuntimeError,
           "can't coerce carray with data_types of '%s' and '%s'",
           ca_type_name[ca->data_type],
           ca_type_name[cb->data_type]);
}

/* @overload cast_self_or_other (other)

[TBD]
*/

VALUE
rb_ca_s_cast_self_or_other (VALUE klass, VALUE self, VALUE other)
{
  rb_ca_cast_self_or_other(&self, &other);
  return rb_assoc_new(self, other);
}

void
rb_ca_cast_other (VALUE *self, volatile VALUE *other)
{
  CArray *ca, *cb;
  CScalar *cs;
  int test0, test1;

  Data_Get_Struct(*self, CArray, ca);

  if ( ! rb_obj_is_carray(*other) ) {
    if ( rb_ca_is_object_type(*self) ) {
      *other = rb_cscalar_new_with_value(CA_OBJECT, 0, *other);
    }
    else if ( rb_ca_is_float_type(*self) ) {
      *other = rb_cscalar_new_with_value(CA_FLOAT64, 0, *other);
    }
#ifdef HAVE_COMPLEX_H
    else if ( rb_ca_is_complex_type(*self) ) {
      *other = rb_cscalar_new_with_value(CA_CMPLX128, 0, *other);
      return;
    }
#endif
    else {
      switch ( TYPE(*other) ) {
      case T_FIXNUM:
      case T_BIGNUM:
        *other = rb_cscalar_new_with_value(CA_INT64, 0, *other);
        break;
      case T_FLOAT:
        *other = rb_cscalar_new_with_value(CA_FLOAT64, 0, *other);
        break;
      case T_TRUE:
      case T_FALSE:
        *other = rb_cscalar_new_with_value(CA_BOOLEAN, 0, *other);
        break;
      default:
#ifdef HAVE_COMPLEX_H
        if ( rb_obj_is_kind_of(*other, rb_cCComplex) ) {
          *other = rb_cscalar_new_with_value(CA_CMPLX128, 0, *other);
          break;
        }
#endif
        *other = rb_cscalar_new_with_value(CA_OBJECT, 0, *other);
        break;
      }
    }
    
    Data_Get_Struct(*other, CScalar, cs);

    test0 = ca_cast_table2[cs->data_type][ca->data_type];

    if ( test0 > 0 ) {
      *other = rb_ca_wrap_readonly(*other, INT2NUM(ca->data_type));
    }

  }

  Data_Get_Struct(*other, CArray, cb);

  if ( cb->obj_type == CA_OBJ_UNBOUND_REPEAT ) {
    *other = ca_ubrep_bind_with(*other, *self);
    Data_Get_Struct(*other, CArray, cb);
  }

  test1 = ca_cast_table[cb->data_type][ca->data_type];

  if ( test1 == 0 ) {
    return;
  }
  else if ( test1 > 0 ) {
    *other = rb_ca_wrap_readonly(*other, INT2NUM(ca->data_type));
    return;
  }

  rb_raise(rb_eRuntimeError,
           "can't coerce carray with data_types of '%s' and '%s'",
           ca_type_name[ca->data_type],
           ca_type_name[cb->data_type]);
}

/* @overload cast_with (other)

[TBD]
*/

VALUE
rb_ca_cast_with (VALUE self, VALUE other)
{
  if ( rb_obj_is_carray(self) ) {
    rb_ca_cast_self_or_other(&self, &other);
  }
  else {
    rb_raise(rb_eRuntimeError, "first argument should be a carray");
  }
  return rb_assoc_new(self, other);
}

void
Init_carray_cast ()
{
  /* CArray data_type conversion */

  rb_define_method(rb_cCArray, "to_type", rb_ca_to_type_internal, -1);

  rb_define_method(rb_cCArray, "fixlen", rb_ca_to_fixlen, -1);
  rb_define_method(rb_cCArray, "boolean", rb_ca_to_boolean, 0);
  rb_define_method(rb_cCArray, "int8", rb_ca_to_int8, 0);
  rb_define_method(rb_cCArray, "uint8", rb_ca_to_uint8, 0);
  rb_define_method(rb_cCArray, "int16", rb_ca_to_int16, 0);
  rb_define_method(rb_cCArray, "uint16", rb_ca_to_uint16, 0);
  rb_define_method(rb_cCArray, "int32", rb_ca_to_int32, 0);
  rb_define_method(rb_cCArray, "uint32", rb_ca_to_uint32, 0);
  rb_define_method(rb_cCArray, "int64", rb_ca_to_int64, 0);
  rb_define_method(rb_cCArray, "uint64", rb_ca_to_uint64, 0);
  rb_define_method(rb_cCArray, "float32", rb_ca_to_float32, 0);
  rb_define_method(rb_cCArray, "float64", rb_ca_to_float64, 0);
  rb_define_method(rb_cCArray, "float128", rb_ca_to_float128, 0);
  rb_define_method(rb_cCArray, "cmplx64", rb_ca_to_cmplx64, 0);
  rb_define_method(rb_cCArray, "cmplx128", rb_ca_to_cmplx128, 0);
  rb_define_method(rb_cCArray, "cmplx256", rb_ca_to_cmplx256, 0);
  rb_define_method(rb_cCArray, "object", rb_ca_to_VALUE, 0);

  rb_define_alias(rb_cCArray, "byte", "uint8");
  rb_define_alias(rb_cCArray, "short", "int16");
  rb_define_alias(rb_cCArray, "int", "int32");
  rb_define_alias(rb_cCArray, "float", "float32");
  rb_define_alias(rb_cCArray, "double", "float64");
  rb_define_alias(rb_cCArray, "complex", "cmplx64");
  rb_define_alias(rb_cCArray, "dcomplex", "cmplx128");

  rb_define_method(rb_cCArray, "as_type", rb_ca_as_type_internal, -1);

  rb_define_method(rb_cCArray, "as_fixlen", rb_ca_as_fixlen, -1);
  rb_define_method(rb_cCArray, "as_boolean", rb_ca_as_boolean, 0);
  rb_define_method(rb_cCArray, "as_int8", rb_ca_as_int8, 0);
  rb_define_method(rb_cCArray, "as_uint8", rb_ca_as_uint8, 0);
  rb_define_method(rb_cCArray, "as_int16", rb_ca_as_int16, 0);
  rb_define_method(rb_cCArray, "as_uint16", rb_ca_as_uint16, 0);
  rb_define_method(rb_cCArray, "as_int32", rb_ca_as_int32, 0);
  rb_define_method(rb_cCArray, "as_uint32", rb_ca_as_uint32, 0);
  rb_define_method(rb_cCArray, "as_int64", rb_ca_as_int64, 0);
  rb_define_method(rb_cCArray, "as_uint64", rb_ca_as_uint64, 0);
  rb_define_method(rb_cCArray, "as_float32", rb_ca_as_float32, 0);
  rb_define_method(rb_cCArray, "as_float64", rb_ca_as_float64, 0);
  rb_define_method(rb_cCArray, "as_float128", rb_ca_as_float128, 0);
  rb_define_method(rb_cCArray, "as_cmplx64", rb_ca_as_cmplx64, 0);
  rb_define_method(rb_cCArray, "as_cmplx128", rb_ca_as_cmplx128, 0);
  rb_define_method(rb_cCArray, "as_cmplx256", rb_ca_as_cmplx256, 0);
  rb_define_method(rb_cCArray, "as_object", rb_ca_as_VALUE, 0);

  rb_define_alias(rb_cCArray, "as_byte", "as_uint8");
  rb_define_alias(rb_cCArray, "as_short", "as_int16");
  rb_define_alias(rb_cCArray, "as_int", "as_int32");
  rb_define_alias(rb_cCArray, "as_float", "as_float32");
  rb_define_alias(rb_cCArray, "as_double", "as_float64");
  rb_define_alias(rb_cCArray, "as_complex", "as_cmplx64");
  rb_define_alias(rb_cCArray, "as_dcomplex", "as_cmplx128");

  rb_define_singleton_method(rb_cCArray,
           "wrap_writable", rb_ca_s_wrap_writable, -1);
  rb_define_singleton_method(rb_cCArray,
           "wrap_readonly", rb_ca_s_wrap_readonly, -1);
  rb_define_singleton_method(rb_cCArray,
                             "cast", rb_ca_s_cast, 1);
  rb_define_singleton_method(rb_cCArray,
           "cast_self_or_other", rb_ca_s_cast_self_or_other, 2);

  rb_define_method(rb_cCArray, "cast_with", rb_ca_cast_with, 1);
}

