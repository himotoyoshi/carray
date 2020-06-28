#include "carray.h"

VALUE rb_cCArrayBoolean;
VALUE rb_cCArrayUInt8;
VALUE rb_cCArrayUInt16;
VALUE rb_cCArrayUInt32;
VALUE rb_cCArrayUInt64;
VALUE rb_cCArrayInt8;
VALUE rb_cCArrayInt16;
VALUE rb_cCArrayInt32;
VALUE rb_cCArrayInt64;
VALUE rb_cCArrayFloat32;
VALUE rb_cCArrayFloat64;
VALUE rb_cCArrayFloat128;
VALUE rb_cCArrayCmplx64;
VALUE rb_cCArrayCmplx128;
VALUE rb_cCArrayCmplx256;
VALUE rb_cCArrayObject;
VALUE rb_cCArrayFixlen;

VALUE
ca_data_type_class (int8_t data_type)
{
  switch ( data_type ) {
  case CA_BOOLEAN:  return rb_cCArrayBoolean; break;
  case CA_INT8:     return rb_cCArrayInt8;  break;
  case CA_UINT8:    return rb_cCArrayUInt8; break;
  case CA_INT16:    return rb_cCArrayInt16;  break;
  case CA_UINT16:   return rb_cCArrayUInt16; break;
  case CA_INT32:    return rb_cCArrayInt32;  break;
  case CA_UINT32:   return rb_cCArrayUInt32; break;
  case CA_INT64:    return rb_cCArrayInt64;  break;
  case CA_UINT64:   return rb_cCArrayUInt64; break;
  case CA_FLOAT32:  return rb_cCArrayFloat32;  break;
  case CA_FLOAT64:  return rb_cCArrayFloat64;  break;
  case CA_FLOAT128: return rb_cCArrayFloat128;  break;
  case CA_CMPLX64:  return rb_cCArrayCmplx64;  break;
  case CA_CMPLX128: return rb_cCArrayCmplx128;  break;
  case CA_CMPLX256: return rb_cCArrayCmplx256;  break;
  case CA_OBJECT:   return rb_cCArrayObject;  break;
  default: rb_raise(rb_eRuntimeError, "invalid data type");
  }

}

void
Init_carray_data_type ()
{
  rb_cCArrayBoolean  = rb_define_class_under(rb_cCArray, "Boolean", rb_cObject);
  rb_cCArrayUInt8  = rb_define_class_under(rb_cCArray, "UInt8", rb_cObject);
  rb_cCArrayUInt16 = rb_define_class_under(rb_cCArray, "UInt16", rb_cObject);
  rb_cCArrayUInt32 = rb_define_class_under(rb_cCArray, "UInt32", rb_cObject);
  rb_cCArrayUInt64 = rb_define_class_under(rb_cCArray, "UInt64", rb_cObject);
  rb_cCArrayInt8  = rb_define_class_under(rb_cCArray, "Int8", rb_cObject);
  rb_cCArrayInt16 = rb_define_class_under(rb_cCArray, "Int16", rb_cObject);
  rb_cCArrayInt32 = rb_define_class_under(rb_cCArray, "Int32", rb_cObject);
  rb_cCArrayInt64 = rb_define_class_under(rb_cCArray, "Int64", rb_cObject);
  rb_cCArrayFloat32 = rb_define_class_under(rb_cCArray, "Float32", rb_cObject);
  rb_cCArrayFloat64 = rb_define_class_under(rb_cCArray, "Float64", rb_cObject);
  rb_cCArrayFloat128 = rb_define_class_under(rb_cCArray, "Float128", rb_cObject);
  rb_cCArrayCmplx64 = rb_define_class_under(rb_cCArray, "Cmplx64", rb_cObject);
  rb_cCArrayCmplx128 = rb_define_class_under(rb_cCArray, "Cmplx128", rb_cObject);
  rb_cCArrayCmplx256 = rb_define_class_under(rb_cCArray, "Cmplx256", rb_cObject);
  rb_cCArrayObject = rb_define_class_under(rb_cCArray, "Object", rb_cObject);
  rb_cCArrayFixlen = rb_define_class_under(rb_cCArray, "Fixlen", rb_cObject);
}
