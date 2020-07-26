/* ---------------------------------------------------------------------------

  ca_obj_bitarray.c

  This file is part of Ruby/CArray extension library.

  Copyright (C) 2005-2020 Hiroki Motoyoshi

---------------------------------------------------------------------------- */

#include "carray.h"

typedef struct {
  int16_t   obj_type;
  int8_t    data_type;
  int8_t    ndim;
  int32_t   flags;
  ca_size_t   bytes;
  ca_size_t   elements;
  ca_size_t  *dim;
  char     *ptr;
  CArray   *mask;
  CArray   *parent;
  uint32_t  attach;
  uint8_t   nosync;
  /* -------------*/
  ca_size_t   bytelen;
  ca_size_t   bitlen;
} CABitarray;

static int8_t CA_OBJ_BITARRAY;

static VALUE rb_cCABitarray;

/* yard:
  class CABitArray < CAVirtual # :nodoc:
  end
*/

static uint8_t bits[8] = {
  1,
  2,
  4,
  8,
  16,
  32,
  64,
  128
};

/* ------------------------------------------------------------------- */

int
ca_bitarray_setup (CABitarray *ca, CArray *parent)
{
  int8_t ndim;
  ca_size_t bitlen, elements;

  /* check arguments */

  if ( ca_is_complex_type(parent) || ( ca_is_object_type(parent) ) ) {
    rb_raise(rb_eCADataTypeError, "invalid data_type for bitarray");
  }

  ndim     = parent->ndim + 1;
  bitlen   = 8 * parent->bytes;
  elements = bitlen * parent->elements;

  ca->obj_type  = CA_OBJ_BITARRAY;
  ca->data_type = CA_BOOLEAN;
  ca->flags     = 0;
  ca->ndim      = ndim;
  ca->bytes     = 1;
  ca->elements  = elements;
  ca->ptr       = NULL;
  ca->mask      = NULL;
  ca->dim       = ALLOC_N(ca_size_t, ndim);

  ca->parent    = parent;
  ca->attach    = 0;
  ca->nosync    = 0;

  ca->bytelen   = parent->bytes;
  ca->bitlen    = bitlen;

  memcpy(ca->dim, parent->dim, (ndim-1) * sizeof(ca_size_t));
  ca->dim[ndim-1] = bitlen;

  if ( ca_has_mask(parent) ) {
    ca_create_mask(ca);
  }

  return 0;
}

CABitarray *
ca_bitarray_new (CArray *parent)
{
  CABitarray *ca = ALLOC(CABitarray);
  ca_bitarray_setup(ca, parent);
  return ca;
}

static void
free_ca_bitarray (void *ap)
{
  CABitarray *ca = (CABitarray *) ap;
  if ( ca != NULL ) {
    ca_free(ca->mask);
    xfree(ca->dim);
    xfree(ca);
  }
}

static void ca_bitarray_attach (CABitarray *ca);
static void ca_bitarray_sync (CABitarray *ca);
static void ca_bitarray_fill (CABitarray *ca, char *ptr);

/* ------------------------------------------------------------------- */

static void *
ca_bitarray_func_clone (void *ap)
{
  CABitarray *ca = (CABitarray *) ap;
  return ca_bitarray_new(ca->parent);
}

static char *
ca_bitarray_func_ptr_at_addr (void *ap, ca_size_t addr)
{
  CABitarray *ca = (CABitarray *) ap;
  if ( ! ca->ptr ) {
    rb_raise(rb_eRuntimeError, "[BUG] ");
    return NULL;
  }
  else {
    return ca->ptr + ca->bytes * addr;
  }
}

static char *
ca_bitarray_func_ptr_at_index (void *ap, ca_size_t *idx)
{
  CABitarray *ca = (CABitarray *) ap;
  if ( ! ca->ptr ) {
    rb_raise(rb_eRuntimeError, "[BUG]");
    return NULL;
  }
  else {
    return ca_func[CA_OBJ_ARRAY].ptr_at_index(ca, idx);
  }
}

static void
ca_bitarray_func_fetch_index (void *ap, ca_size_t *idx, void *ptr)
{
  CABitarray *ca = (CABitarray *) ap;
  ca_size_t bytes  = ca->parent->bytes;
  ca_size_t offset = idx[ca->ndim-1];
  ca_size_t major, minor;
  
  if ( ca_endian == CA_BIG_ENDIAN &&
       ca->parent->bytes != 1 &&
       ( ! ca_is_fixlen_type(ca->parent) ) ) {
    major = bytes - 1 - offset / 8;
  }
  else {
    major = offset / 8;
  }

  minor = offset % 8;

  if ( ca->parent->bytes <= 32 ) {
    uint8_t v[32];
    ca_fetch_index(ca->parent, idx, v);
    *(char*) ptr = ( ( v[major] & bits[minor] ) != 0 );
  }
  else {
    uint8_t *v = malloc_with_check(ca->parent->bytes);
    ca_fetch_index(ca->parent, idx, v);
    *(char*) ptr = ( ( v[major] & bits[minor] ) != 0 );
    free(v);
  }
}

static void
ca_bitarray_func_store_index (void *ap, ca_size_t *idx, void *ptr)
{
  CABitarray *ca = (CABitarray *) ap;
  uint8_t test = *(uint8_t *) ptr;
  ca_size_t offset = idx[ca->ndim-1];
  ca_size_t bytes  = ca->parent->bytes;
  ca_size_t major, minor;

  if ( ca_endian == CA_BIG_ENDIAN &&
       ca->parent->bytes != 1 &&
       ( ! ca_is_fixlen_type(ca->parent) ) ) {
    major = bytes - 1 - offset / 8;
  }
  else {
    major = offset / 8;
  }

  minor = offset % 8;

  if ( ca->parent->bytes <= 32 ) {
    uint8_t v[32];
    ca_fetch_index(ca->parent, idx, v);
    if ( test ) {
      v[major] = ( v[major] & ~bits[minor] ) | bits[minor];
    }
    else {
      v[major] = ( v[major] & ~bits[minor] );
    }
    ca_store_index(ca->parent, idx, v);
  }
  else {
    char *v = malloc_with_check(ca->parent->bytes);
    ca_fetch_index(ca->parent, idx, v);
    if ( test ) {
      v[major] = ( v[major] & ~bits[minor] ) | bits[minor];
    }
    else {
      v[major] = ( v[major] & ~bits[minor] );
    }
    ca_store_index(ca->parent, idx, v);
    free(v);
  }
}

static void
ca_bitarray_func_allocate (void *ap)
{
  CABitarray *ca = (CABitarray *) ap;
  ca_attach(ca->parent);
  /* ca->ptr = ALLOC_N(char, ca_length(ca)); */
  ca->ptr = malloc_with_check(ca_length(ca));  
}

static void
ca_bitarray_func_attach (void *ap)
{
  void ca_bitarray_attach (CABitarray *cb);

  CABitarray *ca = (CABitarray *) ap;
  ca_attach(ca->parent);
  /* ca->ptr = ALLOC_N(char, ca_length(ca)); */
  ca->ptr = malloc_with_check(ca_length(ca));  
  ca_bitarray_attach(ca);
}

static void
ca_bitarray_func_sync (void *ap)
{
  CABitarray *ca = (CABitarray *) ap;
  ca_bitarray_sync(ca);
  ca_sync(ca->parent);
}

static void
ca_bitarray_func_detach (void *ap)
{
  CABitarray *ca = (CABitarray *) ap;
  free(ca->ptr);
  ca->ptr = NULL;
  ca_detach(ca->parent);
}

static void
ca_bitarray_func_copy_data (void *ap, void *ptr)
{
  CABitarray *ca = (CABitarray *) ap;
  char *ptr0 = ca->ptr;
  ca_attach(ca->parent);
  ca->ptr = ptr;
  ca_bitarray_attach(ca);
  ca->ptr = ptr0;
  ca_detach(ca->parent);
}

static void
ca_bitarray_func_sync_data (void *ap, void *ptr)
{
  CABitarray *ca = (CABitarray *) ap;
  char *ptr0 = ca->ptr;
  ca_attach(ca->parent);
  ca->ptr = ptr;
  ca_bitarray_sync(ca);
  ca->ptr = ptr0;
  ca_sync(ca->parent);
  ca_detach(ca->parent);
}

static void
ca_bitarray_func_fill_data (void *ap, void *ptr)
{
  CABitarray *ca = (CABitarray *) ap;
  ca_attach(ca->parent);
  ca_bitarray_fill(ca, ptr);
  ca_sync(ca->parent);
  ca_detach(ca->parent);
}

static void
ca_bitarray_func_create_mask (void *ap)
{
  CABitarray *ca = (CABitarray *) ap;
  ca_size_t count[CA_RANK_MAX];
  int8_t i;

  for (i=0; i<ca->ndim-1; i++) {
    count[i] = 0;
  }
  count[ca->ndim-1] = ca->bitlen;

  ca_update_mask(ca->parent);
  if ( ! ca->parent->mask ) {
    ca_create_mask(ca->parent);
  }
  ca->mask = (CArray *) ca_repeat_new(ca->parent->mask, ca->ndim, count);

  ca_unset_flag(ca->mask, CA_FLAG_READ_ONLY);
}

ca_operation_function_t ca_bitarray_func = {
  -1, /* CA_OBJ_BITARRAY */
  CA_VIRTUAL_ARRAY,
  free_ca_bitarray,
  ca_bitarray_func_clone,
  ca_bitarray_func_ptr_at_addr,
  ca_bitarray_func_ptr_at_index,
  NULL,
  ca_bitarray_func_fetch_index,
  NULL,
  ca_bitarray_func_store_index,
  ca_bitarray_func_allocate,
  ca_bitarray_func_attach,
  ca_bitarray_func_sync,
  ca_bitarray_func_detach,
  ca_bitarray_func_copy_data,
  ca_bitarray_func_sync_data,
  ca_bitarray_func_fill_data,
  ca_bitarray_func_create_mask,
};

/* ------------------------------------------------------------------- */

static void
ca_bitarray_attach (CABitarray *ca)
{
  boolean8_t *p = (boolean8_t *)ca_ptr_at_addr(ca, 0);
  uint8_t *q = (uint8_t *)ca_ptr_at_addr(ca->parent, 0);
  uint8_t *r;
  uint8_t rr;
  ca_size_t elements = ca->parent->elements;
  ca_size_t bytes = ca->parent->bytes;
  ca_size_t n, m;
  if ( ca_endian == CA_BIG_ENDIAN &&
       ca->parent->bytes != 1 &&
       ( ! ca_is_fixlen_type(ca->parent) ) ) {
    n = elements;
    while ( n-- ) {
      m = bytes;
      r = q + bytes - 1;
      while ( m-- ) {
        rr = *r;
        *p++ = (rr & 1);
        *p++ = (rr & 2)   >> 1;
        *p++ = (rr & 4)   >> 2;
        *p++ = (rr & 8)   >> 3;
        *p++ = (rr & 16)  >> 4;
        *p++ = (rr & 32)  >> 5;
        *p++ = (rr & 64)  >> 6;
        *p++ = (rr & 128) >> 7;
        r--;
      }
      q += bytes;
    }
  }
  else {
    n = elements * bytes;
    while ( n-- ) {
      rr = *q++;
      *p++ = (rr & 1);
      *p++ = (rr & 2)   >> 1;
      *p++ = (rr & 4)   >> 2;
      *p++ = (rr & 8)   >> 3;
      *p++ = (rr & 16)  >> 4;
      *p++ = (rr & 32)  >> 5;
      *p++ = (rr & 64)  >> 6;
      *p++ = (rr & 128) >> 7;
    }
  }
}

static void
ca_bitarray_sync (CABitarray *ca)
{
  boolean8_t *p = (boolean8_t *)ca_ptr_at_addr(ca, 0);
  uint8_t *q = (uint8_t *)ca_ptr_at_addr(ca->parent, 0);
  uint8_t *r;
  ca_size_t elements = ca->parent->elements;
  ca_size_t bytes = ca->parent->bytes;
  ca_size_t n, m, i;
  if ( ca_endian == CA_BIG_ENDIAN &&
       ca->parent->bytes != 1 &&
       ( ! ca_is_fixlen_type(ca->parent) ) ) {
    n = elements;
    while ( n-- ) {
      m = bytes;
      r = q + bytes - 1;
      while ( m-- ) {
        *r = 0;
        for (i=0; i<8; i++) {
          *r += (*p) * bits[i];
          p++;
        }
        r--;
      }
      q += bytes;
    }
  }
  else {
    n = elements * bytes;
    while ( n-- ) {
      *q = 0;
      for (i=0; i<8; i++) {
        *q += (*p) * bits[i];
        p++;
      }
      q++;
    }
  }
}

static void
ca_bitarray_fill (CABitarray *ca, char *ptr)
{
  uint8_t *q = (uint8_t *)ca_ptr_at_addr(ca->parent, 0);
  uint8_t val = *(uint8_t *)ptr;
  if ( val ) {
    memset(q, 255, ca_length(ca->parent));
  }
  else {
    memset(q, 0, ca_length(ca->parent));
  }
}

/* ------------------------------------------------------------------- */

VALUE
rb_ca_bitarray_new (VALUE cary)
{
  volatile VALUE obj;
  CArray *parent;
  CABitarray *ca;
  rb_check_carray_object(cary);
  Data_Get_Struct(cary, CArray, parent);
  ca = ca_bitarray_new(parent);
  obj = ca_wrap_struct(ca);
  rb_ca_set_parent(obj, cary);
  return obj;
}

/* @overload bitarray

[TBD]
*/

VALUE
rb_ca_bitarray (VALUE self)
{
  volatile VALUE obj;
  CArray *ca;

  Data_Get_Struct(self, CArray, ca);

  obj = rb_ca_bitarray_new(self);

  return obj;
}

static VALUE
rb_ca_bitarray_s_allocate (VALUE klass)
{
  CABitarray *ca;
  return Data_Make_Struct(klass, CABitarray, ca_mark, ca_free, ca);
}

static VALUE
rb_ca_bitarray_initialize_copy (VALUE self, VALUE other)
{
  CABitarray *ca, *cs;

  Data_Get_Struct(self,  CABitarray, ca);
  Data_Get_Struct(other, CABitarray, cs);

  ca_bitarray_setup(ca, cs->parent);

  return self;
}

void
Init_ca_obj_bitarray ()
{
  rb_cCABitarray = rb_define_class("CABitarray", rb_cCAVirtual);

  CA_OBJ_BITARRAY = ca_install_obj_type(rb_cCABitarray, ca_bitarray_func);
  rb_define_const(rb_cObject, "CA_OBJ_BITARRAY", INT2NUM(CA_OBJ_BITARRAY));

  rb_define_method(rb_cCArray, "bitarray", rb_ca_bitarray, 0);
  rb_define_alias(rb_cCArray, "bits", "bitarray");

  rb_define_alloc_func(rb_cCABitarray, rb_ca_bitarray_s_allocate);
  rb_define_method(rb_cCABitarray, "initialize_copy",
                                      rb_ca_bitarray_initialize_copy, 1);
}

