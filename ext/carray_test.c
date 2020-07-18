/* ---------------------------------------------------------------------------

  carray_test.c

  This file is part of Ruby/CArray extension library.

  Copyright (C) 2005-2020 Hiroki Motoyoshi

  This file includes the modified routine (ca_mem_hash) from 

    * string.c in Ruby distribution ( ruby-1.8.6 )

       Copyright (C) 1993-2003 Yukihiro Matsumoto
       Copyright (C) 2000  Network Applied Communication Laboratory, Inc.
       Copyright (C) 2000  Information-technology Promotion Agency, Japan

---------------------------------------------------------------------------- */

#include "carray.h"

static ID id_equal;

/* various checking routine */

void
ca_check_type (void *ap, int8_t data_type)
{
  CArray *ca = (CArray *) ap;
  if ( ca->data_type != data_type ) {
    rb_raise(rb_eCADataTypeError, "data_type mismatch");
  }
}

void
ca_check_ndim (void *ap, int ndim)
{
  CArray *ca = (CArray *) ap;
  if ( ! ca_is_scalar(ca) ) {
    if ( ca->ndim != ndim ) {
      rb_raise(rb_eRuntimeError, "ndim mismatch");
    }
  }
}

void
ca_check_shape (void *ap, int ndim, ca_size_t *dim)
{
  CArray *ca = (CArray *) ap;
  int i;
  if ( ! ca_is_scalar(ca) ) {
    if ( ca->ndim != ndim ) {
      rb_raise(rb_eRuntimeError, "shape mismatch");
    }
    for (i=0; i<ndim; i++) {
      if ( ca->dim[i] != dim[i] ) {
        rb_raise(rb_eRuntimeError, "shape mismatch");
      }
    }
  }
}

void
ca_check_same_data_type (void *ap1, void *ap2)
{
  CArray *ca1 = (CArray *) ap1;
  CArray *ca2 = (CArray *) ap2;
  if ( ca1->data_type != ca2->data_type ) {
    rb_raise(rb_eCADataTypeError, "data_type mismatch");
  }
}

void
ca_check_same_ndim (void *ap1, void *ap2)
{
  CArray *ca1 = (CArray *) ap1;
  CArray *ca2 = (CArray *) ap2;
  if ( ca1->ndim != ca2->ndim ) {
    rb_raise(rb_eRuntimeError, "ndim mismatch");
  }
}

void
ca_check_same_elements (void *ap1, void *ap2)
{
  CArray *ca1 = (CArray *) ap1;
  CArray *ca2 = (CArray *) ap2;
  if ( ca1->elements != ca2->elements ) {
    rb_raise(rb_eRuntimeError, "elements mismatch");
  }
}

void
ca_check_same_shape (void *ap1, void *ap2)
{
  CArray *ca1 = (CArray *) ap1;
  CArray *ca2 = (CArray *) ap2;
  int i;
  if ( ( ! ca_is_scalar(ca1) ) && ( ! ca_is_scalar(ca2) ) ) {
    if ( ca1->ndim != ca2->ndim ) {
      rb_raise(rb_eRuntimeError, "shape mismatch");
    }
    for (i=0; i<ca1->ndim; i++) {
      if ( ca1->dim[i] != ca2->dim[i] ) {
        rb_raise(rb_eRuntimeError, "shape mismatch");
      }
    }
  }
}

void
ca_check_index (void *ap, ca_size_t *idx)
{
  CArray *ca = (CArray *) ap;
  int i;
  for (i=0; i<ca->ndim; i++) {
    if ( idx[i] < 0 || idx[i] >= ca->dim[i] ) {
      rb_raise(rb_eRuntimeError, "invalid index");
    }
  }
}

void
rb_check_carray_object (VALUE arg)
{
  if ( ! rb_obj_is_carray(arg) ) {
    rb_raise(rb_eRuntimeError, "CArray required");
  }
}

/* various predicate routine */

int
ca_has_same_shape (void *ap1, void *ap2)
{
  CArray *ca1 = (CArray *) ap1;
  CArray *ca2 = (CArray *) ap2;
  int i;
  if ( ca_is_scalar(ca1) || ca_is_scalar(ca2) ) {
    return 1;
  }
  else if ( ca1->ndim != ca2->ndim ) {
    return 0;
  }
  else {
    for (i=0; i<ca1->ndim; i++) {
      if ( ca1->dim[i] != ca2->dim[i] ) {
        return 0;
      }
    }
    return 1;
  }
}

int
ca_is_valid_index (void *ap, ca_size_t *idx)
{
  CArray *ca = (CArray *) ap;
  int8_t i;
  for (i=0; i<ca->ndim; i++) {
    if ( idx[i] < 0 || idx[i] >= ca->dim[i] ) {
      return 0;
    }
  }
  return 1;
}

/* predicate whether data_type is integer or not */

int
rb_ca_is_type (VALUE arg, int type)
{
  CArray *ca;
  if ( ! rb_obj_is_carray(arg) ) {
    rb_raise(rb_eRuntimeError, "CArray required");
  }
  Data_Get_Struct(arg, CArray, ca);
  return ca->data_type == type;
}

/* ------------------------------------------------------------- */

void
ca_check_data_class (VALUE rtype)
{
  if ( ! rb_obj_is_data_class(rtype) ) {
    VALUE inspect = rb_inspect(rtype);
    rb_raise(rb_eRuntimeError,
             "<%s> is not a data_class, which should has the features\n" \
             " * constant data_class::DATA_SIZE    -> integer\n" \
             " * constant data_class::MEMBERS      -> array of string\n" \
             " * constant data_class::MEMBER_TABLE -> hash\n" \
             " * method   data_class.decode(str)   -> data_class object\n" \
             " * method   data_class#encode()      -> string", StringValuePtr(inspect));
  }
}

VALUE
rb_obj_is_data_class (VALUE rtype)
{
  VALUE has_data_size, has_member_names, has_member_table;
  VALUE has_encode, has_decode;
  if ( TYPE(rtype) == T_CLASS ) {
    has_data_size    = 
      rb_funcall(rtype, rb_intern("const_defined?"), 1, rb_str_new2("DATA_SIZE"));
    has_member_names = 
      rb_funcall(rtype, rb_intern("const_defined?"), 1, rb_str_new2("MEMBERS"));
    has_member_table = 
      rb_funcall(rtype, rb_intern("const_defined?"), 1, rb_str_new2("MEMBER_TABLE"));
    has_encode       = 
      rb_funcall(rtype, rb_intern("method_defined?"), 1, rb_str_new2("encode"));
    has_decode       = rb_respond_to(rtype, rb_intern("decode"));
    return ( RTEST(has_data_size)    && 
             RTEST(has_member_table) && RTEST(has_member_names) &&
             RTEST(has_encode)       && RTEST(has_decode)        ) ? Qtrue : Qfalse;
  }
  return Qfalse;
}

/* ------------------------------------------------------------- */

/* yard:
  class CArray
    def valid_index? (*index)
    end
  end
*/

static VALUE
rb_ca_is_valid_index (int argc, VALUE *argv, VALUE self)
{
  CArray *ca;
  ca_size_t idx;
  int i;

  Data_Get_Struct(self, CArray, ca);

  if ( argc != ca->ndim ) {
    rb_raise(rb_eArgError,
             "invalid # of arguments (%i for %i)", argc, ca->ndim);
  }
  for (i=0; i<ca->ndim; i++) {
    idx = NUM2SIZE(argv[i]);
    if ( idx < 0 ) {
      idx += ca->dim[i];
    }
    if ( idx < 0 || idx >= ca->dim[i] ) {
      return Qfalse;
    }
  }

  return Qtrue;
}

/* yard:
  class CArray
    def valid_addr? (addr)
    end
  end
*/

static VALUE
rb_ca_is_valid_addr (VALUE self, VALUE raddr)
{
  CArray *ca;
  ca_size_t addr;

  Data_Get_Struct(self, CArray, ca);
  addr = NUM2SIZE(raddr);
  if ( addr < 0 ) {
    addr += ca->elements;
  }
  if ( addr < 0 || addr >= ca->elements ) {
    return Qfalse;
  }
  else {
    return Qtrue;
  }
}

/* yard:
  class CArray
    def has_same_shape? (other)
    end
  end
*/

static VALUE
rb_ca_has_same_shape (VALUE self, VALUE other)
{
  CArray *ca, *cb;
  Data_Get_Struct(self, CArray, ca);
  cb = ca_wrap_readonly(other, ca->data_type);
  return ca_has_same_shape(ca, cb) ? Qtrue : Qfalse;
}

/* ----------------------------------------------------------------------- */

typedef int (*ca_eql_func)();

#define eql_type(type)         \
static int                      \
eql_## type (type *a, type *b, int bytes) \
{                               \
  return ( *a == *b ); \
}

static int
eql_VALUE (VALUE *a, VALUE *b, int bytes)
{
  return ( rb_funcall(*a, id_equal, 1, *b) ) ? 1 : 0;
}

static int
eql_data (char *a, char *b, int bytes)
{
  return ( memcmp(a, b, bytes) ) ? 0 : 1;
}

eql_type(boolean8_t)
eql_type(int8_t)
eql_type(uint8_t)
eql_type(int16_t)
eql_type(uint16_t)
eql_type(int32_t)
eql_type(uint32_t)
eql_type(int64_t)
eql_type(uint64_t)
eql_type(float32_t)
eql_type(float64_t)
eql_type(float128_t)
eql_type(cmplx64_t)
eql_type(cmplx128_t)
eql_type(cmplx256_t)

ca_eql_func
ca_eql[CA_NTYPE] = {
  eql_data,
  eql_boolean8_t,
  eql_int8_t,
  eql_uint8_t,
  eql_int16_t,
  eql_uint16_t,
  eql_int32_t,
  eql_uint32_t,
  eql_int64_t,
  eql_uint64_t,
  eql_float32_t,
  eql_float64_t,
  eql_float128_t,
  eql_cmplx64_t,
  eql_cmplx128_t,
  eql_cmplx256_t,
  eql_VALUE,
};

int
ca_equal (void *ap, void *bp)
{
  CArray *ca = (CArray *) ap;
  CArray *cb = (CArray *) bp;
  int flag = 1;
  int masked_a, masked_b;
  boolean8_t *ma, *mb;
  ca_size_t i;
  ca_size_t bytes;
  char *pa;
  char *pb;
  ca_eql_func eql;

  if ( ca_is_scalar(ca) ^ ca_is_scalar(cb) ) { /* scalar comparison */
    return 0;
  }

  if ( ca->data_type != cb->data_type ) { /* data_type comparison */
    return 0;
  }

  if ( ca->bytes != cb->bytes ) { /* data_type comparison */
    return 0;
  }

  if ( ca->ndim != cb->ndim )  {          /* ndim comparison */
    return 0;
  }

  if ( ca->elements != cb->elements ) {   /* elements comparison */
    return 0;
  }

  for (i=0; i<ca->ndim; i++) {
    if ( ca->dim[i] != cb->dim[i] ) {     /* dimensional shape comparison */
      return 0;
    }
  }

  ca_attach_n(2, ca, cb);                 /* array contents comparison */

  masked_a = ca_is_any_masked(ca);
  masked_b = ca_is_any_masked(cb);

  bytes = ca->bytes;

  pa = ca->ptr;
  pb = cb->ptr;

  eql = ca_eql[ca->data_type];

  if ( masked_a && masked_b ) {         /* masked vs masked */
    ma = (boolean8_t*) ca->mask->ptr;
    mb = (boolean8_t*) cb->mask->ptr;
    for (i=0; i<ca->elements; i++, ma++, mb++) {
      if ( *ma != *mb || ( ( ! *ma ) && ( ! eql(pa, pb, bytes) ) ) ) {
        flag = 0;
        break;
      }
      pa += bytes; pb += bytes;
    }
  }
  else if ( masked_a ) {                /* masked vs not-masked */
    ma = (boolean8_t*) ca->mask->ptr;
    for (i=0; i<ca->elements; i++, ma++) {
      if ( *ma || ( ! eql(pa, pb, bytes) ) ) {
        flag = 0;
        break;
      }
      pa += bytes; pb += bytes;
    }
  }
  else if ( masked_b ) {                /* not-masked vs masked */
    mb = (boolean8_t*) cb->mask->ptr;
    for (i=0; i<ca->elements; i++, mb++) {
      if ( *mb || ( ! eql(pa, pb, bytes) ) ) {
        flag = 0;
        break;
      }
      pa += bytes; pb += bytes;
    }
  }
  else {                                /* not-masked vs not-masked */
    for (i=0; i<ca->elements; i++) {
      if ( ! eql(pa, pb, bytes) ) {
        flag = 0;
        break;
      }
      pa += bytes; pb += bytes;
    }
  }

  ca_detach_n(2, ca, cb);

  return flag;
}

/* yard:
  class CArray
    def == (other)
    end
    alias eql? ==
  end
*/

static VALUE
rb_ca_equal (VALUE self, VALUE other)
{
  CArray *ca, *cb;

  if ( ! rb_obj_is_carray(other) )  {    /* check kind_of?(CArray) */
    return Qfalse;
  }

  if ( rb_ca_has_data_class(self) || rb_ca_has_data_class(other) ) {
    if ( rb_ca_has_data_class(self) ^ rb_ca_has_data_class(other) ) {
      return Qfalse;
    }
    else {
      VALUE dc1 = rb_ca_data_class(self);
      VALUE dc2 = rb_ca_data_class(other);
      if ( ! rb_funcall(dc1, rb_intern("=="), 1, dc2) ) {
        return Qfalse;
      }
    }
  }

  Data_Get_Struct(self, CArray, ca);
  Data_Get_Struct(other, CArray, cb);

  return ( ca_equal(ca, cb) ) ? Qtrue : Qfalse;
}

/*
  ca_mem_hash()

  This hash function is modified version of rb_str_hash() 
                               in string.c of Ruby 1.8.6 distribution.
 */

int32_t
ca_mem_hash (char *mp, ca_size_t mlen)
{
  register ca_size_t len = mlen;
  register char   *p   = mp;
  register int32_t key = 0;
  while (len--) {
    key = key*65599 + *p;
    p++;
  }
  return key;
}

static int32_t
ca_hash (CArray *ca)
{
  int32_t hash;

  if ( ca_is_any_masked(ca) ) {
    ca_size_t bytes = ca->bytes;
    boolean8_t *m = (boolean8_t*) ca->mask->ptr;
    /* char *tptr = ALLOC_N(char, ca_length(ca)); */
    char *tptr = malloc_with_check(ca_length(ca));
    char *p;
    int32_t i;
    ca_attach(ca);
    memcpy(tptr, ca->ptr, ca_length(ca));
    p = tptr;
    #ifdef _OPENMP
    #pragma omp parallel for 
    #endif
    for (i=0; i<ca->elements; i++) {
      if ( *(m+i) ) {
        memset(p+i*bytes, 0, bytes);
      }
    }
    hash = ca_mem_hash(tptr, ca_length(ca));
    hash ^= ca_mem_hash(ca->mask->ptr, ca->elements);
    ca_detach(ca);
    free(tptr);
  }
  else {
    ca_attach(ca);
    hash = ca_mem_hash(ca->ptr, ca_length(ca));
    ca_detach(ca);
  }
  return hash;
}

/* yard:
  class CArray
    def hash
    end
  end
*/

VALUE
rb_ca_hash (VALUE self)
{
  CArray *ca;
  int32_t hash;

  Data_Get_Struct(self, CArray, ca);
  hash = ca_hash(ca);
  return ULONG2NUM(hash);
}

/* ----------------------------------------------------------------------- */

void
rb_ca_modify (VALUE self)
{
  if ( OBJ_FROZEN(self) ) {
    rb_error_frozen("CArray object");
  }
  /*
  if ( ( ! OBJ_TAINTED(self) ) && rb_safe_level() >= 4 ) {
    rb_raise(rb_eSecurityError, "Insecure: can't modify carray");
  }
  */
}

VALUE
rb_ca_freeze (VALUE self)
{
  CArray *ca;
  Data_Get_Struct(self, CArray, ca);
  ca_set_flag(ca, CA_FLAG_READ_ONLY);
  return rb_obj_freeze(self);
}

void
Init_carray_test ()
{
  id_equal = rb_intern("==");
  
  rb_define_method(rb_cCArray, "valid_index?", rb_ca_is_valid_index, -1);
  rb_define_method(rb_cCArray, "valid_addr?",  rb_ca_is_valid_addr, 1);
  rb_define_method(rb_cCArray, "same_shape?",  rb_ca_has_same_shape, 1);
  rb_define_method(rb_cCArray, "freeze",  rb_ca_freeze, 0);

  rb_define_method(rb_cCArray, "==", rb_ca_equal, 1);
  rb_define_method(rb_cCArray, "eql?", rb_ca_equal, 1);
  rb_define_method(rb_cCArray, "hash", rb_ca_hash, 0);
}
