/* ---------------------------------------------------------------------------

  ca_obj_fake.c

  This file is part of Ruby/CArray extension library.
  You can redistribute it and/or modify it under the terms of
  the Ruby Licence.

  Copyright (C) 2005 Hiroki Motoyoshi

---------------------------------------------------------------------------- */

#include "carray.h"

typedef struct {
  int16_t   obj_type;
  int8_t    data_type;
  int8_t    rank;
  int32_t   flags;
  int32_t   bytes;
  int32_t   elements;
  int32_t  *dim;
  char     *ptr;
  CArray   *mask;
  CArray   *parent;
  uint32_t  attach;
  uint8_t   nosync;
} CAFake;

static int8_t CA_OBJ_FAKE;

static VALUE rb_cCAFake;

/* rdoc: 
  class CAFake < CAVirtual # :nodoc:
  end
*/

/* ------------------------------------------------------------------- */

int
ca_fake_setup (CAFake *ca, CArray *parent, int8_t data_type, int32_t bytes)
{
  int8_t rank;
  int32_t *dim, elements;

  /* check arguments */

  CA_CHECK_DATA_TYPE(data_type);
  CA_CHECK_BYTES(data_type, bytes);

  rank     = parent->rank;
  dim      = parent->dim;
  elements = parent->elements;

  ca->obj_type  = CA_OBJ_FAKE;
  ca->data_type = data_type;
  ca->flags     = 0;
  ca->rank      = rank;
  ca->bytes     = bytes;
  ca->elements  = elements;
  ca->ptr       = NULL;
  ca->mask      = NULL;
  ca->dim       = ALLOC_N(int32_t, rank);

  ca->parent    = parent;
  ca->attach    = 0;
  ca->nosync    = 0;

  memcpy(ca->dim, dim, rank * sizeof(int32_t));

  if ( ca_has_mask(parent) ) {
    ca_create_mask(ca);
  }

  if ( ca_is_scalar(parent) ) {
    ca_set_flag(ca, CA_FLAG_SCALAR);
  }

  return 0;
}

CAFake *
ca_fake_new (CArray *parent, int8_t data_type, int32_t bytes)
{
  CAFake *ca = ALLOC(CAFake);
  ca_fake_setup(ca, parent, data_type, bytes);
  return ca;
}

static void
free_ca_fake (void *ap)
{
  CAFake *ca = (CAFake *) ap;
  if ( ca != NULL ) {
    ca_free(ca->mask);
    xfree(ca->dim);
    xfree(ca);
  }
}


/* ------------------------------------------------------------------- */

static void *
ca_fake_func_clone (void *ap)
{
  CAFake *ca = (CAFake *) ap;
  return ca_fake_new(ca->parent, ca->data_type, ca->bytes);
}

static char *
ca_fake_func_ptr_at_addr (void *ap, int32_t addr)
{
  CAFake *ca = (CAFake *) ap;
  return ca->ptr + ca->bytes * addr;
}

static char *
ca_fake_func_ptr_at_index (void *ap, int32_t *idx)
{
  CAFake *ca = (CAFake *) ap;
  return ca_func[CA_OBJ_ARRAY].ptr_at_index(ca, idx);
}

static void
ca_fake_func_fetch_index (void *ap, int32_t *idx, void *ptr)
{
  CAFake *ca = (CAFake *) ap;
  if ( ca->parent->bytes <= 32 ) {
    char v[32];
    ca_fetch_index(ca->parent, idx, v);
    ca_ptr2ptr(ca->parent, v, ca, ptr);
  }
  else {
    char *v = malloc_with_check(ca->parent->bytes);
    ca_fetch_index(ca->parent, idx, v);
    ca_ptr2ptr(ca->parent, v, ca, ptr);
    free(v);
  }
}

static void
ca_fake_func_store_index (void *ap, int32_t *idx, void *ptr)
{
  CAFake *ca = (CAFake *) ap;
  if ( ca->parent->bytes <= 32 ) {
    char v[32];
    ca_ptr2ptr(ca, ptr, ca->parent, v);
    ca_store_index(ca->parent, idx, v);
  }
  else {
    char *v = malloc_with_check(ca->parent->bytes);
    ca_ptr2ptr(ca, ptr, ca->parent, v);
    ca_store_index(ca->parent, idx, v);
    free(v);
  }
}

static void
ca_fake_func_allocate (void *ap)
{
  CAFake *ca = (CAFake *) ap;
  ca_attach(ca->parent);
  /* ca->ptr = ALLOC_N(char, ca_length(ca)); */
  ca->ptr = malloc_with_check(ca_length(ca));  

  /* initialize elements with 0 for CA_OBJECT data_type */
  if ( ca->data_type == CA_OBJECT ) {
    VALUE *p = (VALUE *) ca->ptr;
    VALUE zero = INT2FIX(0);
    int32_t i;
    for (i=0; i<ca->elements; i++) {
      *p++ = zero;
    }
  }
}

static void
ca_fake_func_attach (void *ap)
{
  void ca_fake_attach (CAFake *cb);

  CAFake *ca = (CAFake *) ap;
  ca_attach(ca->parent);
  /* ca->ptr = ALLOC_N(char, ca_length(ca)); */
  ca->ptr = malloc_with_check(ca_length(ca));  

  /* initialize elements with 0 for CA_OBJECT data_type */
  if ( ca->data_type == CA_OBJECT ) {
    VALUE *p = (VALUE *) ca->ptr;
    VALUE zero = INT2FIX(0);
    int32_t i;
    for (i=0; i<ca->elements; i++) {
      *p++ = zero;
    }
  }

  if ( ca->parent->mask ) {
    ca_cast_block_with_mask(ca->elements, ca->parent, ca->parent->ptr, 
                            ca, ca->ptr, 
                            (boolean8_t*)ca->parent->mask->ptr);
  }
  else {
    ca_cast_block(ca->elements, ca->parent, ca->parent->ptr, ca, ca->ptr);
  }
}

static void
ca_fake_func_sync (void *ap)
{
  CAFake *ca = (CAFake *) ap;
  ca_update_mask(ca);
  if ( ca->mask ) {
    ca_cast_block_with_mask(ca->elements, ca, ca->ptr, ca->parent, ca->parent->ptr, 
                            (boolean8_t *)ca->parent->mask->ptr);
  }
  else {
    ca_cast_block(ca->elements, ca, ca->ptr, ca->parent, ca->parent->ptr);
  }
  ca_sync(ca->parent);
}

static void
ca_fake_func_detach (void *ap)
{
  CAFake *ca = (CAFake *) ap;
  free(ca->ptr);
  ca->ptr = NULL;
  ca_detach(ca->parent);
}

static void
ca_fake_func_copy_data (void *ap, void *ptr)
{
  CAFake *ca = (CAFake *) ap;
  ca_attach(ca->parent);
  ca_update_mask(ca);
  if ( ca->parent->mask ) {
    ca_cast_block_with_mask(ca->elements, ca->parent, ca->parent->ptr, ca, ptr, 
                            (boolean8_t*)ca->parent->mask->ptr);
  }
  else {
    ca_cast_block(ca->elements, ca->parent, ca->parent->ptr, ca, ptr);
  }
  ca_detach(ca->parent);
}

static void
ca_fake_func_sync_data (void *ap, void *ptr)
{
  CAFake *ca = (CAFake *) ap;
  ca_attach(ca->parent);
  if ( ca->parent->mask ) {
    ca_cast_block_with_mask(ca->elements, ca, ptr, ca->parent, ca->parent->ptr, 
                            (boolean8_t*)ca->parent->mask->ptr);
  }
  else {
    ca_cast_block(ca->elements, ca, ptr, ca->parent, ca->parent->ptr);
  }
  ca_detach(ca->parent);
}

static void
ca_fake_func_fill_data (void *ap, void *ptr)
{
  CAFake *ca = (CAFake *) ap;
  if ( ca->parent->bytes <= 32 ) {
    char v[32];
    ca_ptr2ptr(ca, ptr, ca->parent, v);
    ca_fill(ca->parent, v);
  }
  else {
    char *v = malloc_with_check(ca->parent->bytes);
    ca_ptr2ptr(ca, ptr, ca->parent, v);
    ca_fill(ca->parent, v);
    free(v);
  }
}

static void
ca_fake_func_create_mask (void *ap)
{
  CAFake *ca = (CAFake *) ap;
  ca_update_mask(ca->parent);
  if ( ! ca->parent->mask ) {
    ca_create_mask(ca->parent);
  }
  ca->mask =
    (CArray *) ca_refer_new(ca->parent->mask,
                            CA_BOOLEAN, ca->rank, ca->dim, 0, 0);
}

ca_operation_function_t ca_fake_func = {
  -1, /* CA_OBJ_FAKE */
  CA_VIRTUAL_ARRAY,
  free_ca_fake,
  ca_fake_func_clone,
  ca_fake_func_ptr_at_addr,
  ca_fake_func_ptr_at_index,
  NULL,
  ca_fake_func_fetch_index,
  NULL,
  ca_fake_func_store_index,
  ca_fake_func_allocate,
  ca_fake_func_attach,
  ca_fake_func_sync,
  ca_fake_func_detach,
  ca_fake_func_copy_data,
  ca_fake_func_sync_data,
  ca_fake_func_fill_data,
  ca_fake_func_create_mask,
};

/* ------------------------------------------------------------------- */

VALUE
rb_ca_fake_new (VALUE cary, int8_t data_type, int32_t bytes)
{
  volatile VALUE obj;
  CArray *parent;
  CAFake *ca;
  rb_check_carray_object(cary);
  Data_Get_Struct(cary, CArray, parent);
  ca  = ca_fake_new(parent, data_type, bytes);
  obj = ca_wrap_struct(ca);
  rb_ca_set_parent(obj, cary);
  return obj;
}

/* rdoc:
  class CArray
    def fake (data_type, options={:bytes=>0})
    end
  end
*/

VALUE
rb_ca_fake (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE obj, rtype, ropt, rbytes = Qnil;
  CArray *ca;
  int8_t  data_type;
  int32_t bytes;

  Data_Get_Struct(self, CArray, ca);

  rb_scan_args(argc, argv, "11", &rtype, &ropt);
  rb_scan_options(ropt, "bytes", &rbytes);

  rb_ca_guess_type_and_bytes(rtype, rbytes, &data_type, &bytes);
  obj = rb_ca_fake_new(self, data_type, bytes);
  rb_ca_data_type_import(obj, rtype);

  return obj;
}

VALUE
rb_ca_fake_type (VALUE self, VALUE rtype, VALUE rbytes)
{
  volatile VALUE obj;
  int8_t  data_type;
  int32_t bytes;
  rb_ca_guess_type_and_bytes(rtype, rbytes, &data_type, &bytes);
  obj = rb_ca_fake_new(self, data_type, bytes);
  rb_ca_data_type_import(obj, rtype);
  return obj;
}

static VALUE
rb_ca_fake_s_allocate (VALUE klass)
{
  CAFake *ca;
  return Data_Make_Struct(klass, CAFake, ca_mark, ca_free, ca);
}

static VALUE
rb_ca_fake_initialize_copy (VALUE self, VALUE other)
{
  CAFake *ca, *cs;

  Data_Get_Struct(self,  CAFake, ca);
  Data_Get_Struct(other, CAFake, cs);

  ca_fake_setup(ca, cs->parent, cs->data_type, cs->bytes);

  return self;
}

void
Init_ca_obj_fake ()
{
  rb_cCAFake = rb_define_class("CAFake", rb_cCAVirtual);

  CA_OBJ_FAKE = ca_install_obj_type(rb_cCAFake, ca_fake_func);
  rb_define_const(rb_cObject, "CA_OBJ_FAKE", INT2NUM(CA_OBJ_FAKE));

  rb_define_method(rb_cCArray, "fake", rb_ca_fake, -1);

  rb_define_alloc_func(rb_cCAFake, rb_ca_fake_s_allocate);
  rb_define_method(rb_cCAFake, "initialize_copy",
                                      rb_ca_fake_initialize_copy, 1);
}


