/* ---------------------------------------------------------------------------

  ca_iter_block.c

  This file is part of Ruby/CArray extension library.
  You can redistribute it and/or modify it under the terms of
  the Ruby Licence.

  Copyright (C) 2005 Hiroki Motoyoshi

---------------------------------------------------------------------------- */

#include "carray.h"

/* rdoc:
  class CABlockIterator < CAIterator # :nodoc: 
  end
*/

VALUE rb_cCABlockIterator;

/*
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
  // ---------- 
  int8_t    maxdim_index;
  int32_t   maxdim_step;
  int32_t   maxdim_step0;
  int32_t   offset;
  int32_t  *start;
  int32_t  *step;
  int32_t  *count;
  int32_t  *size0;
} CABlock;                  // 68 + 20*(rank) (bytes) 
*/

typedef struct {
  int8_t  rank;
  int32_t dim[CA_RANK_MAX];
  CArray *reference;
  CArray * (*kernel_at_addr)(void *, int32_t, CArray *);
  CArray * (*kernel_at_index)(void *, int32_t *, CArray *);
  CArray * (*kernel_move_to_addr)(void *, int32_t, CArray *);
  CArray * (*kernel_move_to_index)(void *, int32_t *, CArray *);
  /* ----------- */
  CABlock *kernel;
} CABlockIterator;

/* ----------------------------------------------------------------- */

static CArray *
ca_bi_kernel_at_index (void *it, int32_t *idx, CArray *ref)
{
  CABlockIterator *bit = (CABlockIterator *) it;
  CABlock *kernel;
  int32_t i, j;

  if ( ref == bit->reference ) {
    kernel = (CABlock *)ca_clone(bit->kernel);
  }
  else {
    CABlock *ck = (CABlock *)bit->kernel;
    kernel = ca_block_new(ref,
                          ck->rank, ck->size0,
                          ck->start, ck->step, ck->count,
                          ck->offset);
  }

  ca_update_mask(kernel);

  for (i=0; i<kernel->rank; i++) {
    j = idx[i];
    CA_CHECK_INDEX(j, bit->dim[i]);
    kernel->start[i] += j * kernel->dim[i];
    if ( kernel->mask ) {
      ((CABlock*)(kernel->mask))->start[i] += j * kernel->dim[i];
    }
  }

  return (CArray*) kernel;
}

static CArray *
ca_bi_kernel_at_addr (void *it, int32_t addr, CArray *ref)
{
  CABlockIterator *bit = (CABlockIterator *) it;
  int32_t *dim = bit->dim;
  int32_t idx[CA_RANK_MAX];
  int32_t i;
  for (i=bit->rank-1; i>=0; i--) {
    idx[i] = addr % dim[i];
    addr  /= dim[i];
  }
  return ca_bi_kernel_at_index(it, idx, ref);
}


static CArray *
ca_bi_kernel_move_to_index (void *it, int32_t *idx, CArray *kern)
{
  CABlockIterator *bit = (CABlockIterator *) it;
  CABlock *kernel = (CABlock *) kern;
  int32_t i, j;

  ca_update_mask(kernel);

  for (i=0; i<kernel->rank; i++) {
    j = idx[i];
    CA_CHECK_INDEX(j, bit->dim[i]);
    kernel->start[i] = j * kernel->dim[i];
    if ( kernel->mask ) {
      ((CABlock*)(kernel->mask))->start[i] = j * kernel->dim[i];
    }
  }

  return (CArray*) kernel;
}

static CArray *
ca_bi_kernel_move_to_addr (void *it, int32_t addr, CArray *ref)
{
  CABlockIterator *bit = (CABlockIterator *) it;
  int32_t *dim = bit->dim;
  int32_t idx[CA_RANK_MAX];
  int32_t i;
  for (i=bit->rank-1; i>=0; i--) {
    idx[i] = addr % dim[i];
    addr  /= dim[i];
  }
  return ca_bi_kernel_move_to_index(it, idx, ref);
}

void
ca_bi_setup (VALUE self, VALUE rref, VALUE rker)
{
  CABlockIterator *it;
  CArray *ref;
  CABlock *ker;
  int32_t dim[CA_RANK_MAX];
  int32_t i;

  rker = rb_obj_clone(rker);

  Data_Get_Struct(self, CABlockIterator, it);
  Data_Get_Struct(rref, CArray, ref);
  Data_Get_Struct(rker, CABlock, ker);

  if ( ref->rank != ker->rank ) {
    rb_raise(rb_eRuntimeError, "rank mismatch between reference and kernel");
  }

  for (i=0; i<ref->rank; i++) {
    if ( ker->step[i] != 1 ) {
      rb_raise(rb_eRuntimeError, "block should be contiguous");
    }
    dim[i] = ( ref->dim[i] - ker->start[i] ) / ker->dim[i];
    /*
    if ( ref->dim[i] % ker->dim[i] != 0 ) {
      rb_raise(rb_eRuntimeError, "invalid block size");
    }
    */
  }

  it->rank      = ref->rank;
  memcpy(it->dim, dim, it->rank * sizeof(int32_t));
  it->reference = ref;
  it->kernel    = ker;
  it->kernel_at_addr  = ca_bi_kernel_at_addr;
  it->kernel_at_index = ca_bi_kernel_at_index;
  it->kernel_move_to_addr  = ca_bi_kernel_move_to_addr;
  it->kernel_move_to_index = ca_bi_kernel_move_to_index;

  rb_ivar_set(self, rb_intern("@reference"), rref); /* required ivar */
  rb_ivar_set(self, rb_intern("@kernel"), rker);
}

static VALUE
rb_bi_s_allocate (VALUE klass)
{
  CABlockIterator *it;
  return Data_Make_Struct(klass, CABlockIterator, 0, free, it);
}

static VALUE
rb_bi_initialize_copy (VALUE self, VALUE other)
{
  ca_bi_setup(other, rb_ivar_get(self, rb_intern("@reference")),
        rb_ivar_get(self, rb_intern("@kernel")));
  return self;
}

/* rdoc:
  class CArray
    # Create block iterator.
    def blocks (*args)
    end
  end
*/

static VALUE
rb_ca_block_iterator (int argc, VALUE *argv, VALUE self)
{
  VALUE obj, rker;
  CArray *ker;

  rker = rb_ca_fetch2(self, argc, argv);

  rb_check_carray_object(rker);
  Data_Get_Struct(rker, CArray, ker);

  if ( ker->obj_type != CA_OBJ_BLOCK ) {
    rb_raise(rb_eRuntimeError, "kernel must be CABlock object");
  }

  obj = rb_bi_s_allocate(rb_cCABlockIterator);
  ca_bi_setup(obj, self, rker);

  return obj;
}

void
Init_ca_iter_block ()
{
  rb_cCABlockIterator = rb_define_class("CABlockIterator", rb_cCAIterator);
  rb_define_const(rb_cCABlockIterator, "UNIFORM_KERNEL", Qtrue);
  rb_define_alloc_func(rb_cCABlockIterator, rb_bi_s_allocate);
  rb_define_method(rb_cCABlockIterator, "initialize_copy",
                            rb_bi_initialize_copy, 1);
  rb_define_method(rb_cCArray, "blocks", rb_ca_block_iterator, -1);
}

