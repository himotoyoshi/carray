/* ---------------------------------------------------------------------------

  CArray class-level inquiries: host endianness, sizeof(data_type),
  data_type ↔ name / code conversion.

---------------------------------------------------------------------------- */

#include "carray.h"

/* ------------------------------------------------------------------- */
/* Symbol cache for data_type code → Symbol lookup.
 *
 * Pre-computed at Init time so `ca.data_type` can return
 * `ID2SYM(ca_data_type_sym[ca->data_type])` with no rb_intern call
 * per access.
 *
 * Indexed by data_type code (0 = CA_FIXLEN ... CA_NTYPE-1 = CA_OBJECT).
 * Symbol name = ca_type_name[i] ("fixlen" / "int8" / ... / "object").
 * Unused slots (CA_FLOAT128 = 12, CA_CMPLX256 = 15) are populated but
 * never reached at runtime because ca_valid[] is 0 there.
 * ------------------------------------------------------------------- */

ID ca_data_type_sym[CA_NTYPE];

VALUE
rb_ca_data_type_to_sym (int8_t data_type)
{
  CA_CHECK_DATA_TYPE(data_type);
  return ID2SYM(ca_data_type_sym[data_type]);
}

/* Returns the machine endianness as an integer
   (0 = CA_LITTLE_ENDIAN, 1 = CA_BIG_ENDIAN). */
static VALUE
rb_ca_s_endian (VALUE klass)
{
  return INT2NUM(ca_endian);
}

/* Returns true if the host byte order is big-endian. */
static VALUE
rb_ca_s_big_endian_p (VALUE klass)
{
  return ( ca_endian == CA_BIG_ENDIAN ) ? Qtrue : Qfalse;
}

/* Returns true if the host byte order is little-endian. */
static VALUE
rb_ca_s_little_endian_p (VALUE klass)
{
  return ( ca_endian == CA_LITTLE_ENDIAN ) ? Qtrue : Qfalse;
}

/* Returns the byte length of one element of the given data_type.
   Returns 0 for CA_FIXLEN (whose width is per-instance, not per-type). */
static VALUE
rb_ca_s_sizeof (VALUE klass, VALUE rtype)
{
  int8_t data_type;
  ca_size_t bytes;
  rb_ca_guess_type_and_bytes(rtype, INT2NUM(0), &data_type, &bytes);
  return SIZE2NUM(bytes);
}

/* Returns the string representation of a data_type specifier.
   Accepts Symbol, Integer code, Class, or String uniformly via
   rb_ca_guess_type. */
static VALUE
rb_ca_s_data_type_name (VALUE klass, VALUE type)
{
  int8_t data_type = rb_ca_guess_type(type);
  CA_CHECK_DATA_TYPE(data_type);
  return rb_str_new2(ca_type_name[data_type]);
}

/* Returns the internal int8_t data_type code (e.g. 8 for :int64,
   11 for :float64).  Inverse of rb_ca_s_data_type_name (which returns
   a String).  Accepts the same representations.
   Used by Ruby-side code that needs to compute kernel op_ids from a
   data_type (e.g. CAMonOp::CAST_BASE + code in lib/carray/lazy.rb).
   End users normally do not need this -- use Symbol comparison or
   the CA_* constants. */
static VALUE
rb_ca_s_data_type_code (VALUE klass, VALUE type)
{
  int8_t data_type = rb_ca_guess_type(type);
  CA_CHECK_DATA_TYPE(data_type);
  return INT2NUM(data_type);
}

/* ------------------------------------------------------------------- */

void
Init_carray_class (void)
{
  /* NOTE: ca_data_type_sym[] cache is initialized earlier in
     Init_carray_ext (ruby_carray.c) before the CA_* data_type constants
     are defined.  Don't re-initialize here. */

  rb_define_const(rb_cObject, "CA_BIG_ENDIAN", INT2NUM(CA_BIG_ENDIAN));
  rb_define_const(rb_cObject, "CA_LITTLE_ENDIAN", INT2NUM(CA_LITTLE_ENDIAN));

  rb_define_singleton_method(rb_cCArray, "endian", rb_ca_s_endian, 0); 
  rb_define_singleton_method(rb_cCArray, "big_endian?",
                             rb_ca_s_big_endian_p, 0);
  rb_define_singleton_method(rb_cCArray, "little_endian?",
                             rb_ca_s_little_endian_p, 0);
  rb_define_singleton_method(rb_cCArray, "sizeof", rb_ca_s_sizeof, 1);
  rb_define_singleton_method(rb_cCArray, "data_type_name",
                             rb_ca_s_data_type_name, 1);
  rb_define_singleton_method(rb_cCArray, "data_type_code",
                             rb_ca_s_data_type_code, 1);
}

