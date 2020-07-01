/* ---------------------------------------------------------------------------

  ca_obj_reduce.c

  This file is part of Ruby/CArray extension library.
  You can redistribute it and/or modify it under the terms of
  the Ruby Licence.

  Copyright (C) 2005 Hiroki Motoyoshi

---------------------------------------------------------------------------- */

#include "carray.h"

static int8_t CA_OBJ_REDUCE;

static VALUE rb_cCAReduce;

/* rdoc:
  class CAReduce < CAVirtual # :nodoc:
  end
*/

/* ------------------------------------------------------------------- */

int
ca_reduce_setup (CAReduce *ca, CArray *parent, ca_size_t count, ca_size_t offset)
{
  ca_size_t elements;

  /* check arguments */

  if ( ! ca_is_boolean_type(parent) ) {
    rb_raise(rb_eRuntimeError, 
             "[BUG] CAReduce can't inherit other than boolean array");
  }

  elements  = parent->elements / count;

  ca->obj_type  = CA_OBJ_REDUCE;
  ca->data_type = CA_BOOLEAN;     /* data type is fixed to boolean */
  ca->flags     = 0;
  ca->ndim      = 1;
  ca->bytes     = ca_sizeof[CA_BOOLEAN];
  ca->elements  = elements;
  ca->ptr       = NULL;
  ca->mask      = NULL;
  ca->dim       = &ca->elements;

  ca->parent    = parent;
  ca->attach    = 0;
  ca->nosync    = 0;

  ca->count     = count;
  ca->offset    = offset;

  if ( ca_has_mask(parent) ) {
    ca_create_mask(ca);
  }

  if ( ca_is_scalar(parent) ) {
    ca_set_flag(ca, CA_FLAG_SCALAR);
  }

  return 0;
}

CAReduce *
ca_reduce_new (CArray *parent, ca_size_t count, ca_size_t offset)
{
  CAReduce *ca = ALLOC(CAReduce);
  ca_reduce_setup(ca, parent, count, offset);
  return ca;
}

static void
free_ca_reduce (void *ap)
{
  CAReduce *ca = (CAReduce *) ap;
  if ( ca != NULL ) {
    ca_free(ca->mask);
    /* free(ca->dim); */
    xfree(ca);
  }
}

/* ------------------------------------------------------------------- */

static void *
ca_reduce_func_clone (void *ap)
{
  CAReduce *ca = (CAReduce *) ap;
  return ca_reduce_new(ca->parent, ca->count, ca->offset);
}

static char *
ca_reduce_func_ptr_at_addr (void *ap, ca_size_t addr)
{
  CAReduce *ca = (CAReduce *) ap;
  return ca->ptr + addr;
}

static char *
ca_reduce_func_ptr_at_index (void *ap, ca_size_t *idx)
{
  CAReduce *ca = (CAReduce *) ap;
  return ca_func[CA_OBJ_ARRAY].ptr_at_index(ca, idx);
}

static void
ca_reduce_func_fetch_addr (void *ap, ca_size_t addr, void *ptr)
{
  CAReduce *ca = (CAReduce *) ap;
  char q;
  int i;
  for (i=0; i<ca->count; i++) {
    ca_fetch_addr(ca->parent, addr*ca->count+ca->offset, &q);
    if ( q ) {
      *(char*)ptr = (char) 1;
      return;
    }
  }
  *(char*)ptr = (char) 0;
}

static void
ca_reduce_func_store_addr (void *ap, ca_size_t addr, void *ptr)
{
  CAReduce *ca = (CAReduce *) ap;
  ca_size_t i;
  for (i=0; i<ca->count; i++) {
    ca_store_addr(ca->parent, addr*ca->count+i+ca->offset, ptr);
  }
}

static void
ca_reduce_func_allocate (void *ap)
{
  CAReduce *ca = (CAReduce *) ap;
  ca_attach(ca->parent);
  /* ca->ptr = ALLOC_N(char, ca->elements); */
  ca->ptr = malloc_with_check(ca_length(ca));  
}

static void
ca_reduce_func_attach (void *ap)
{
  CAReduce *ca = (CAReduce *) ap;
  char *p;
  ca_size_t i;
  ca_attach(ca->parent);
  /* ca->ptr = ALLOC_N(char, ca->elements); */
  ca->ptr = malloc_with_check(ca_length(ca));  
  p = ca->ptr;
  for (i=0; i<ca->elements; i++) {
    ca_reduce_func_fetch_addr(ca, i, p);
    p++;
  }
}

static void
ca_reduce_func_sync (void *ap)
{
  CAReduce *ca = (CAReduce *) ap;
  char *p;
  ca_size_t i;
  p = ca->ptr;
  ca_attach(ca->parent);
  for (i=0; i<ca->elements; i++) {
    ca_reduce_func_store_addr(ca, i, p);
    p++;
  }
  ca_sync(ca->parent);
  ca_detach(ca->parent);
}

static void
ca_reduce_func_detach (void *ap)
{
  CAReduce *ca = (CAReduce *) ap;
  free(ca->ptr);
  ca->ptr = NULL;
  ca_detach(ca->parent);
}

static void
ca_reduce_func_copy_data (void *ap, void *ptr)
{
  CAReduce *ca = (CAReduce *) ap;
  ca_size_t i;
  char *p;
  ca_attach(ca->parent);
  p = ptr;
  for (i=0; i<ca->elements; i++) {
    ca_reduce_func_fetch_addr(ca, i, p);
    p++;
  }
  ca_detach(ca->parent);
}

static void
ca_reduce_func_sync_data (void *ap, void *ptr)
{
  CAReduce *ca = (CAReduce *) ap;
  char *p;
  ca_size_t i;
  ca_attach(ca->parent);
  p = ptr;
  for (i=0; i<ca->elements; i++) {
    ca_reduce_func_store_addr(ca, i, p);
    p++;
  }
  ca_sync(ca->parent);
  ca_detach(ca->parent);
}

static void
ca_reduce_func_fill_data (void *ap, void *ptr)
{
  CAReduce *ca = (CAReduce *) ap;
  ca_size_t i;
  ca_attach(ca->parent);
  for (i=0; i<ca->elements; i++) {
    ca_reduce_func_store_addr(ca, i, ptr);
  }
  ca_sync(ca->parent);
  ca_detach(ca->parent);
}

static void
ca_reduce_func_create_mask (void *ap)
{
  CAReduce *ca = (CAReduce *) ap;

  ca_update_mask(ca->parent);
  if ( ! ca->parent->mask ) {
    ca_create_mask(ca->parent);
  }

  ca->mask = (CArray *) ca_reduce_new(ca->parent->mask, ca->count, ca->offset);
}

ca_operation_function_t ca_reduce_func = {
  -1, /* CA_OBJ_REDUCE */
  CA_VIRTUAL_ARRAY,
  free_ca_reduce,
  ca_reduce_func_clone,
  ca_reduce_func_ptr_at_addr,
  ca_reduce_func_ptr_at_index,
  ca_reduce_func_fetch_addr,
  NULL,
  ca_reduce_func_store_addr,
  NULL,
  ca_reduce_func_allocate,
  ca_reduce_func_attach,
  ca_reduce_func_sync,
  ca_reduce_func_detach,
  ca_reduce_func_copy_data,
  ca_reduce_func_sync_data,
  ca_reduce_func_fill_data,
  ca_reduce_func_create_mask,
};

/* ------------------------------------------------------------------- */

static VALUE
rb_ca_reduce_s_allocate (VALUE klass)
{
  CAReduce *ca;
  return Data_Make_Struct(klass, CAReduce, ca_mark, ca_free, ca);
}

static VALUE
rb_ca_reduce_initialize_copy (VALUE self, VALUE other)
{
  CAReduce *ca, *cs;

  Data_Get_Struct(self,  CAReduce, ca);
  Data_Get_Struct(other, CAReduce, cs);

  ca_reduce_setup(ca, cs->parent, cs->count, cs->offset);

  return self;
}

void
Init_ca_obj_reduce ()
{
  rb_cCAReduce = rb_define_class("CAReduce", rb_cCAVirtual);

  CA_OBJ_REDUCE = ca_install_obj_type(rb_cCAReduce, ca_reduce_func);
  rb_define_const(rb_cObject, "CA_OBJ_REDUCE", INT2NUM(CA_OBJ_REDUCE));

  rb_define_alloc_func(rb_cCAReduce, rb_ca_reduce_s_allocate);
  rb_define_method(rb_cCAReduce, "initialize_copy",
                                      rb_ca_reduce_initialize_copy, 1);
}


