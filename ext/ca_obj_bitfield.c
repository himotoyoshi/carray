/* ---------------------------------------------------------------------------

  ca_obj_bitfield.c

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
  ca_size_t   byte_offset;
  ca_size_t   bit_offset;
  uint64_t  bit_mask;
} CABitfield;

static int8_t CA_OBJ_BITFIELD;

static VALUE rb_cCABitfield;

/* yard:
  class CABitField < CAVirtual # :nodoc:
  end
*/

static ca_size_t
bitfield_bitlen (uint64_t bit_mask, ca_size_t bytes)
{
  ca_size_t bitsize = bytes * 8;
  ca_size_t count = 0;
  ca_size_t i;
  for (i=0; i<bitsize; i++) {
    if ( ( bit_mask >> i ) & 1 ) {
      count++;
    }
  }
  return count;
}

static void
bitfield_fetch(char *dst, ca_size_t dbytes, 
                   char *src, ca_size_t sbytes,
                   ca_size_t byte_offset, ca_size_t bit_offset, uint64_t bit_mask,
                   ca_size_t elements)
{
  ca_size_t k;
  switch ( dbytes ) {
  case 1: {
    char   *p;
    uint8_t *q, *r;
    uint8_t mask = (uint8_t) bit_mask;
    p = src + byte_offset;
    q = (uint8_t *) dst;
    #ifdef _OPENMP
    #pragma omp parallel for private(r)
    #endif
    for (k=0; k<elements; k++) {
      r = (uint8_t *) (p+k*sbytes);
      *(q+k) = (( *r & mask ) >> bit_offset);
    }
    break;
  }
  case 2: {
    char   *p;
    uint16_t *q, *r;
    uint16_t mask = (uint16_t) bit_mask;
    p = src + byte_offset;
    q = (uint16_t *) dst;
    #ifdef _OPENMP
    #pragma omp parallel for private(r)
    #endif
    for (k=0; k<elements; k++) {
      r = (uint16_t *) (p+k*sbytes);
      *(q+k) = (( *r & mask ) >> bit_offset);
    }
    break;
  }
  case 4: {
    char   *p;
    uint32_t *q, *r;
    uint32_t mask = (uint32_t) bit_mask;
    p = src + byte_offset;
    q = (uint32_t *) dst;
    #ifdef _OPENMP
    #pragma omp parallel for private(r)
    #endif
    for (k=0; k<elements; k++) {
      r  = (uint32_t *) (p+k*sbytes);
      *(q+k) = (( *r & mask ) >> bit_offset);
    }
    break;
  }
  case 8: {
    char   *p;
    uint64_t *q, *r;
    uint64_t mask = (uint64_t) bit_mask;
    p = src + byte_offset;
    q = (uint64_t *) dst;
    #ifdef _OPENMP
    #pragma omp parallel for private(r)
    #endif
    for (k=0; k<elements; k++) {
      r  = (uint64_t *) (p+k*sbytes);
      *(q+k) = (( *r & mask ) >> bit_offset);
    }
    break;
  }
  default: 
    rb_raise(rb_eRuntimeError, "[BUG]");
  }
}

static void
bitfield_store(char *src, ca_size_t sbytes,
                   char *dst, ca_size_t dbytes, 
                   ca_size_t byte_offset, ca_size_t bit_offset, uint64_t bit_mask,
                   ca_size_t elements)
{
  ca_size_t k;
  switch ( dbytes ) {
  case 1: {
    char   *q;
    uint8_t *p, *r;
    uint8_t mask = (uint8_t) bit_mask;
    p = (uint8_t *) src;
    q = dst + byte_offset;
    #ifdef _OPENMP
    #pragma omp parallel for private(r)
    #endif
    for (k=0; k<elements; k++) {
      r  = p + k;
      *(uint8_t*)(q+k*dbytes) = 
        ( ((*(uint8_t*)(q+k*dbytes)) & ~mask) | ((*r << bit_offset) & mask) );
    }
    break;
  }
  case 2: {
    char   *q;
    uint16_t *p, *r;
    uint16_t mask = (uint16_t) bit_mask;
    p = (uint16_t *) src;
    q = dst + byte_offset;
    #ifdef _OPENMP
    #pragma omp parallel for private(r)
    #endif
    for (k=0; k<elements; k++) {
      r  = p + k;
      *(uint16_t*)(q+k*dbytes) = 
        ( ((*(uint16_t*)(q+k*dbytes)) & ~mask) | ((*r << bit_offset) & mask) );
    }
    break;
  }
  case 4: {
    char   *q;
    uint32_t *p, *r;
    uint32_t mask = (uint32_t) bit_mask;
    p = (uint32_t *) src;
    q = dst + byte_offset;
    #ifdef _OPENMP
    #pragma omp parallel for private(r)
    #endif
    for (k=0; k<elements; k++) {
      r  = p + k;
      *(uint32_t*)(q+k*dbytes) = 
        ( ((*(uint32_t*)(q+k*dbytes)) & ~mask) | ((*r << bit_offset) & mask) );
    }
    break;
  }
  case 8: {
    char   *q;
    uint64_t *p, *r;
    uint64_t mask = (uint64_t) bit_mask;
    p = (uint64_t *) src;
    q = dst + byte_offset;
    #ifdef _OPENMP
    #pragma omp parallel for private(r)
    #endif
    for (k=0; k<elements; k++) {
      r  = p + k;
      *(uint64_t*)(q+k*dbytes) = 
        ( ((*(uint64_t*)(q+k*dbytes)) & ~mask) | ((*r << bit_offset) & mask) );
    }
    break;
  }
  default:
    rb_raise(rb_eRuntimeError, "[BUG]");
  }
}


/* ------------------------------------------------------------------- */

int
ca_bitfield_setup (CABitfield *ca, CArray *parent,
                   ca_size_t offset, ca_size_t bitlen)
{
  int8_t ndim;
  int8_t data_type;
  ca_size_t bytes = 0, elements;
  ca_size_t bitsize;
  ca_size_t  byte_offset;
  ca_size_t  bit_offset;
  uint64_t bit_mask;
  ca_size_t i;

  /* check arguments */

  /*
  if ( ! ca_is_integer_type(parent) && ! ca_is_float_type(ca) ) {
    rb_raise(rb_eCADataTypeError, "invalid data_type for bitfield");
  }
  */

  ndim     = parent->ndim;
  bitsize  = parent->bytes * 8;
  elements = parent->elements;

  if ( bitlen <= 0 || bitlen > 64 ) {
    rb_raise(rb_eIndexError, "invalid bit length specified for bit field");
  }

  if ( offset + bitlen -1 >= bitsize ) {
    rb_raise(rb_eIndexError, "invalid offset for bit field");
  }

  if ( bitlen == 1 ) {
    data_type = CA_BOOLEAN;
  }
  else if ( bitlen <= 8 ) {
    data_type = CA_UINT8;
  }
  else if ( bitlen <= 16 ) {
    data_type = CA_UINT16;
  }
  else if ( bitlen <= 32 ) {
    data_type = CA_UINT32;
  }
  else {
    data_type = CA_UINT64;
  }

  CA_CHECK_BYTES(data_type, bytes);

  if ( bitlen > bytes * 8 ) {
    rb_raise(rb_eArgError, "invalid bit length for specified data_type");
  }

  if ( ( data_type == CA_BOOLEAN ) && ( bitlen > 1 ) ) {
    rb_raise(rb_eArgError, "invalid bit length for specified data_type");
  }

  if ( ca_endian == CA_BIG_ENDIAN ) {
    byte_offset = parent->bytes - offset/8 - bytes;
    bit_offset  = offset % 8;
    bit_mask    = 0;
    for (i=0; i<bitlen; i++) {
      bit_mask += 1 << ( bit_offset + i );
    }
    if ( byte_offset < 0 ) {
      for (i=0; i<-byte_offset; i++) {
        bit_mask = bit_mask << 8;
        bit_offset += 8;
      }
      byte_offset = 0;
    }
  }
  else {
    byte_offset = offset / 8;
    bit_offset  = offset % 8;
    bit_mask    = 0;
    for (i=0; i<bitlen; i++) {
      bit_mask += 1 << ( bit_offset + i );
    }
  }

  ca->obj_type  = CA_OBJ_BITFIELD;
  ca->data_type = data_type;
  ca->flags     = 0;
  ca->ndim      = ndim;
  ca->bytes     = bytes;
  ca->elements  = elements;
  ca->ptr       = NULL;
  ca->mask      = NULL;
  ca->dim       = ALLOC_N(ca_size_t, ndim);

  ca->parent    = parent;
  ca->attach    = 0;
  ca->nosync    = 0;

  ca->byte_offset = byte_offset;
  ca->bit_offset  = bit_offset;
  ca->bit_mask    = bit_mask;

  memcpy(ca->dim, parent->dim, ndim * sizeof(ca_size_t));

  if ( ca_has_mask(parent) ) {
    ca_create_mask(ca);
  }

  return 0;
}

CABitfield *
ca_bitfield_new (CArray *parent, ca_size_t offset, ca_size_t bitlen)
{
  CABitfield *ca = ALLOC(CABitfield);
  ca_bitfield_setup(ca, parent, offset, bitlen);
  return ca;
}

static void
free_ca_bitfield (void *ap)
{
  CABitfield *ca = (CABitfield *) ap;
  if ( ca != NULL ) {
    ca_free(ca->mask);
    xfree(ca->dim);
    xfree(ca);
  }
}

static void ca_bitfield_attach (CABitfield *ca);
static void ca_bitfield_sync (CABitfield *ca);
static void ca_bitfield_fill (CABitfield *ca, char *ptr);

/* ------------------------------------------------------------------- */

static void *
ca_bitfield_func_clone (void *ap)
{
  CABitfield *ca = (CABitfield *) ap;
  return ca_bitfield_new(ca->parent, 
                         8 * ca->byte_offset + ca->bit_offset, 
                         bitfield_bitlen(ca->bit_mask, ca->bytes));
}

static char *
ca_bitfield_func_ptr_at_addr (void *ap, ca_size_t addr)
{
  CABitfield *ca = (CABitfield *) ap;
  if ( ! ca->ptr ) {
    rb_raise(rb_eRuntimeError, "[BUG]");
    return NULL;
  }
  else {
    return ca->ptr + ca->bytes * addr;
  }
}

static char *
ca_bitfield_func_ptr_at_index (void *ap, ca_size_t *idx)
{
  CABitfield *ca = (CABitfield *) ap;
  if ( ! ca->ptr ) {
    rb_raise(rb_eRuntimeError, "[BUG]");
    return NULL;
  }
  else {
    return ca_func[CA_OBJ_ARRAY].ptr_at_index(ca, idx);
  }
}

static void
ca_bitfield_func_fetch_index (void *ap, ca_size_t *idx, void *ptr)
{
  CABitfield *ca = (CABitfield *) ap;
  char *v = xmalloc(ca->parent->bytes);
  ca_fetch_index(ca->parent, idx, v);
  memset(ptr, 0, ca->bytes);
  bitfield_fetch(ptr, ca->bytes, v, ca->parent->bytes,
                 ca->byte_offset, ca->bit_offset, ca->bit_mask, 1);
  xfree(v);
}

static void
ca_bitfield_func_store_index (void *ap, ca_size_t *idx, void *ptr)
{
  CABitfield *ca = (CABitfield *) ap;
  char *v = xmalloc(ca->parent->bytes);
  ca_fetch_index(ca->parent, idx, v);
  bitfield_store(ptr, ca->bytes, v, ca->parent->bytes,
                 ca->byte_offset, ca->bit_offset, ca->bit_mask, 1);
  ca_store_index(ca->parent, idx, v);
  xfree(v);
}

static void
ca_bitfield_func_allocate (void *ap)
{
  CABitfield *ca = (CABitfield *) ap;
  ca_attach(ca->parent);
  /* ca->ptr = ALLOC_N(char, ca_length(ca)); */
  ca->ptr = malloc_with_check(ca_length(ca));  
}

static void
ca_bitfield_func_attach (void *ap)
{
  void ca_bitfield_attach (CABitfield *cb);
  CABitfield *ca = (CABitfield *) ap;
  ca_attach(ca->parent);
  /* ca->ptr = ALLOC_N(char, ca_length(ca)); */
  ca->ptr = malloc_with_check(ca_length(ca));  
  ca_bitfield_attach(ca);
}

static void
ca_bitfield_func_sync (void *ap)
{
  CABitfield *ca = (CABitfield *) ap;
  ca_bitfield_sync(ca);
  ca_sync(ca->parent);
}

static void
ca_bitfield_func_detach (void *ap)
{
  CABitfield *ca = (CABitfield *) ap;
  free(ca->ptr);
  ca->ptr = NULL;
  ca_detach(ca->parent);
}

static void
ca_bitfield_func_copy_data (void *ap, void *ptr)
{
  CABitfield *ca = (CABitfield *) ap;
  char *ptr0 = ca->ptr;
  ca_attach(ca->parent);
  ca->ptr = ptr;
  ca_bitfield_attach(ca);
  ca->ptr = ptr0;
  ca_detach(ca->parent);
}

static void
ca_bitfield_func_sync_data (void *ap, void *ptr)
{
  CABitfield *ca = (CABitfield *) ap;
  char *ptr0 = ca->ptr;
  ca_attach(ca->parent);
  ca->ptr = ptr;
  ca_bitfield_sync(ca);
  ca->ptr = ptr0;
  ca_sync(ca->parent);
  ca_detach(ca->parent);
}

static void
ca_bitfield_func_fill_data (void *ap, void *ptr)
{
  CABitfield *ca = (CABitfield *) ap;
  ca_attach(ca->parent);
  ca_bitfield_fill(ca, ptr);
  ca_sync(ca->parent);
  ca_detach(ca->parent);
}

static void
ca_bitfield_func_create_mask (void *ap)
{
  CABitfield *ca = (CABitfield *) ap;

  ca_update_mask(ca->parent);
  if ( ! ca->parent->mask ) {
    ca_create_mask(ca->parent);
  }

  ca->mask = (CArray *) ca_refer_new(ca->parent->mask,
                                     CA_BOOLEAN, ca->ndim, ca->dim, 0, 0);
}

ca_operation_function_t ca_bitfield_func = {
  -1, /* CA_OBJ_BITFIELD */
  CA_VIRTUAL_ARRAY,
  free_ca_bitfield,
  ca_bitfield_func_clone,
  ca_bitfield_func_ptr_at_addr,
  ca_bitfield_func_ptr_at_index,
  NULL,
  ca_bitfield_func_fetch_index,
  NULL,
  ca_bitfield_func_store_index,
  ca_bitfield_func_allocate,
  ca_bitfield_func_attach,
  ca_bitfield_func_sync,
  ca_bitfield_func_detach,
  ca_bitfield_func_copy_data,
  ca_bitfield_func_sync_data,
  ca_bitfield_func_fill_data,
  ca_bitfield_func_create_mask,
};

/* ------------------------------------------------------------------- */

static void
ca_bitfield_attach (CABitfield *ca)
{
  memset(ca->ptr, 0, ca_length(ca));
  bitfield_fetch(ca->ptr, ca->bytes, ca->parent->ptr, ca->parent->bytes,
                 ca->byte_offset, ca->bit_offset, ca->bit_mask, ca->elements);
}

static void
ca_bitfield_sync (CABitfield *ca)
{
  bitfield_store(ca->ptr, ca->bytes, ca->parent->ptr, ca->parent->bytes,
                 ca->byte_offset, ca->bit_offset, ca->bit_mask, ca->elements);
}

static void
ca_bitfield_fill (CABitfield *ca, char *ptr)
{
  char *q = ca->parent->ptr;
  ca_size_t bytesp = ca->bytes;
  ca_size_t bytesq = ca->parent->bytes;
  ca_size_t byte_offset = ca->byte_offset;
  ca_size_t bit_offset = ca->bit_offset;
  uint64_t bit_mask = ca->bit_mask;
  ca_size_t i;

  for (i=0; i<ca->elements; i++) {
    bitfield_store(ptr, bytesp, q, bytesq, 
                   byte_offset, bit_offset, bit_mask, 1);
    q += bytesq;
  }
}

/* ------------------------------------------------------------------- */

VALUE
rb_ca_bitfield_new (VALUE cary, ca_size_t offset, ca_size_t bitlen)
{
  volatile VALUE obj;
  CArray *parent;
  CABitfield *ca;
  rb_check_carray_object(cary);
  Data_Get_Struct(cary, CArray, parent);
  ca = ca_bitfield_new(parent, offset, bitlen);
  obj = ca_wrap_struct(ca);
  rb_ca_set_parent(obj, cary);
  return obj;
}

/* yard:
  class CArray
    def bitfield (range, type)
    end
  end
*/

VALUE
rb_ca_bitfield (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE rrange, rtype;
  CArray *ca;
  ca_size_t offset, bitlen, step;
  int data_type = CA_NONE;
  ca_size_t bitsize;

  rb_scan_args(argc, argv, "11", (VALUE *) &rrange, (VALUE *) &rtype);

  Data_Get_Struct(self, CArray, ca);

  if ( TYPE(rrange) == T_FIXNUM ) {
    offset = NUM2INT(rrange);
    bitlen = 1;
  }
  else {
    bitsize = ca->bytes * 8;
    ca_parse_range(rrange, bitsize, &offset, &bitlen, &step);
    if ( step != 1 ) {
      rb_raise(rb_eIndexError, "invalid bit range specified for bit field");
    }
  }

  if ( ! NIL_P(rtype) ) {
    data_type = rb_ca_guess_type(rtype);
  }

  return rb_ca_bitfield_new(self, offset, bitlen);
}

static VALUE
rb_ca_bitfield_s_allocate (VALUE klass)
{
  CABitfield *ca;
  return Data_Make_Struct(klass, CABitfield, ca_mark, ca_free, ca);
}

static VALUE
rb_ca_bitfield_initialize_copy (VALUE self, VALUE other)
{
  CABitfield *ca, *cs;

  Data_Get_Struct(self,  CABitfield, ca);
  Data_Get_Struct(other, CABitfield, cs);

  ca_bitfield_setup(ca, cs->parent, 
                    8 * cs->byte_offset + cs->bit_offset, 
                    bitfield_bitlen(cs->bit_mask, cs->bytes));

  return self;
}

void
Init_ca_obj_bitfield ()
{
  rb_cCABitfield = rb_define_class("CABitfield", rb_cCAVirtual);

  CA_OBJ_BITFIELD = ca_install_obj_type(rb_cCABitfield, ca_bitfield_func);
  rb_define_const(rb_cObject, "CA_OBJ_BITFIELD", INT2NUM(CA_OBJ_BITFIELD));

  rb_define_method(rb_cCArray, "bitfield", rb_ca_bitfield, -1);

  rb_define_alloc_func(rb_cCABitfield, rb_ca_bitfield_s_allocate);
  rb_define_method(rb_cCABitfield, "initialize_copy",
                                      rb_ca_bitfield_initialize_copy, 1);
}

