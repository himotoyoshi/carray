/* ---------------------------------------------------------------------------

  ca_iter_block.c

  This file is part of Ruby/CArray extension library.

  Copyright (C) 2005-2020 Hiroki Motoyoshi

---------------------------------------------------------------------------- */

#include "carray.h"

/* yard:
  class CABlockIterator < CAIterator # :nodoc: 
  end
*/

VALUE rb_cCABlockIterator;

/*
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
  // ---------- 
  int8_t    maxdim_index;
  ca_size_t   maxdim_step;
  ca_size_t   maxdim_step0;
  ca_size_t   offset;
  ca_size_t  *start;
  ca_size_t  *step;
  ca_size_t  *count;
  ca_size_t  *size0;
} CABlock;                  // 68 + 20*(ndim) (bytes) 
*/

typedef struct {
  int8_t  ndim;
  ca_size_t dim[CA_RANK_MAX];
  CArray *reference;
  CArray * (*kernel_at_addr)(void *, ca_size_t, CArray *);
  CArray * (*kernel_at_index)(void *, ca_size_t *, CArray *);
  CArray * (*kernel_move_to_addr)(void *, ca_size_t, CArray *);
  CArray * (*kernel_move_to_index)(void *, ca_size_t *, CArray *);
  /* ----------- */
  CABlock *kernel;
} CABlockIterator;

/* ----------------------------------------------------------------- */

static CArray *
ca_bi_kernel_at_index (void *it, ca_size_t *idx, CArray *ref)
{
  CABlockIterator *bit = (CABlockIterator *) it;
  CABlock *kernel;
  int8_t  i;
  ca_size_t j;

  if ( ref == bit->reference ) {
    kernel = (CABlock *)ca_clone(bit->kernel);
  }
  else {
    CABlock *ck = (CABlock *)bit->kernel;
    kernel = ca_block_new(ref,
                          ck->ndim, ck->size0,
                          ck->start, ck->step, ck->count,
                          ck->offset);
  }

  ca_update_mask(kernel);

  for (i=0; i<kernel->ndim; i++) {
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
ca_bi_kernel_at_addr (void *it, ca_size_t addr, CArray *ref)
{
  CABlockIterator *bit = (CABlockIterator *) it;
  ca_size_t *dim = bit->dim;
  ca_size_t idx[CA_RANK_MAX];
  int8_t i;
  for (i=bit->ndim-1; i>=0; i--) {
    idx[i] = addr % dim[i];
    addr  /= dim[i];
  }
  return ca_bi_kernel_at_index(it, idx, ref);
}


static CArray *
ca_bi_kernel_move_to_index (void *it, ca_size_t *idx, CArray *kern)
{
  CABlockIterator *bit = (CABlockIterator *) it;
  CABlock *kernel = (CABlock *) kern;
  int8_t  i;
  ca_size_t j;

  ca_update_mask(kernel);

  for (i=0; i<kernel->ndim; i++) {
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
ca_bi_kernel_move_to_addr (void *it, ca_size_t addr, CArray *ref)
{
  CABlockIterator *bit = (CABlockIterator *) it;
  ca_size_t *dim = bit->dim;
  ca_size_t idx[CA_RANK_MAX];
  int8_t i;
  for (i=bit->ndim-1; i>=0; i--) {
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
  ca_size_t dim[CA_RANK_MAX];
  int8_t i;

  rker = rb_obj_clone(rker);

  Data_Get_Struct(self, CABlockIterator, it);
  Data_Get_Struct(rref, CArray, ref);
  Data_Get_Struct(rker, CABlock, ker);

  if ( ref->ndim != ker->ndim ) {
    rb_raise(rb_eRuntimeError, "ndim mismatch between reference and kernel");
  }

  for (i=0; i<ref->ndim; i++) {
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

  it->ndim      = ref->ndim;
  memcpy(it->dim, dim, it->ndim * sizeof(ca_size_t));
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

/* yard:
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

