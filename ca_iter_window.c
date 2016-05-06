/* ---------------------------------------------------------------------------

  ca_iter_window.c

  This file is part of Ruby/CArray extension library.
  You can redistribute it and/or modify it under the terms of
  the Ruby Licence.

  Copyright (C) 2005 Hiroki Motoyoshi

---------------------------------------------------------------------------- */

#include "carray.h"

typedef struct {
  int8_t  rank;
  int32_t dim[CA_RANK_MAX];
  CArray *reference;
  CArray * (*kernel_at_addr)(void *, int32_t, CArray *);
  CArray * (*kernel_at_index)(void *, int32_t *, CArray *);
  CArray * (*kernel_move_to_addr)(void *, int32_t, CArray *);
  CArray * (*kernel_move_to_index)(void *, int32_t *, CArray *);
  /* ----------- */
  CArray *kernel;
  int32_t offset[CA_RANK_MAX];
} CAWindowIterator;

VALUE rb_cCAWindowIterator;

/* rdoc:
  class CAWindowIterator < CAIterator # :nodoc:
  end
*/

extern int8_t CA_OBJ_WINDOW;

/* ----------------------------------------------------------------- */

CAWindow *
ca_window_new (CArray *carray,
             int32_t *start, int32_t *count, int8_t bounds, char *fill);


static CArray *
ca_vi_kernel_at_index (void *it, int32_t *idx, CArray *ref)
{
  CAWindowIterator *vit = (CAWindowIterator *) it;
  CAWindow *kernel;
  int32_t i, j;

  if ( ref == vit->reference ) {
    kernel = (CAWindow *)ca_clone(vit->kernel);
  }
  else {
    CAWindow *ck = (CAWindow *)vit->kernel;
    kernel = ca_window_new(ref, ck->start, ck->count, ck->bounds, ck->fill);
  }

  ca_update_mask(kernel);

  for (i=0; i<kernel->rank; i++) {
    j = idx[i];
    CA_CHECK_INDEX(j, vit->dim[i]);
    kernel->start[i] = j - vit->offset[i];
    if ( kernel->mask ) {
      ((CAWindow*)(kernel->mask))->start[i] = j - vit->offset[i];
    }
  }

  return (CArray*) kernel;
}

static CArray *
ca_vi_kernel_at_addr (void *it, int32_t addr, CArray *ref)
{
  CAWindowIterator *vit = (CAWindowIterator *) it;
  int32_t *dim = vit->dim;
  int32_t idx[CA_RANK_MAX];
  int32_t i;
  for (i=vit->rank-1; i>=0; i--) {
    idx[i] = addr % dim[i];
    addr  /= dim[i];
  }
  return ca_vi_kernel_at_index(it, idx, ref);
}

static CArray *
ca_vi_kernel_move_to_index (void *it, int32_t *idx, CArray *kern)
{
  CAWindowIterator *vit = (CAWindowIterator *) it;
  CAWindow *kernel = (CAWindow *) kern;
  int32_t *dim    = vit->dim;
  int32_t *offset = vit->offset;
  int32_t i, j;

  ca_update_mask(kernel);

  for (i=0; i<kernel->rank; i++) {
    j = idx[i];
    CA_CHECK_INDEX(j, dim[i]);
    kernel->start[i] = j - offset[i];
    if ( kernel->mask ) {
      ((CAWindow*)(kernel->mask))->start[i] = j - offset[i];
    }
  }

  return (CArray*) kernel;
}

static CArray *
ca_vi_kernel_move_to_addr (void *it, int32_t addr, CArray *ref)
{
  CAWindowIterator *vit = (CAWindowIterator *) it;
  int32_t *dim = vit->dim;
  int32_t idx[CA_RANK_MAX];
  int32_t i;
  for (i=vit->rank-1; i>=0; i--) {
    idx[i] = addr % dim[i];
    addr  /= dim[i];
  }
  return ca_vi_kernel_move_to_index(it, idx, ref);
}

void
ca_vi_setup (VALUE self, VALUE rref, VALUE rker)
{
  CAWindowIterator *it;
  CArray *ref, *ker;
  int32_t i;

  rker = rb_obj_clone(rker);

  Data_Get_Struct(self, CAWindowIterator, it);
  Data_Get_Struct(rref, CArray, ref);
  Data_Get_Struct(rker, CArray, ker);

  if ( ref->rank != ker->rank ) {
    rb_raise(rb_eRuntimeError, "rank mismatch between reference and kernel");
  }

  it->rank      = ref->rank;
  memcpy(it->dim, ref->dim, it->rank * sizeof(int32_t));
  it->reference = ref;
  it->kernel    = ker;
  it->kernel_at_addr  = ca_vi_kernel_at_addr;
  it->kernel_at_index = ca_vi_kernel_at_index;
  it->kernel_move_to_addr  = ca_vi_kernel_move_to_addr;
  it->kernel_move_to_index = ca_vi_kernel_move_to_index;

  for (i=0; i<it->rank; i++) {
    it->offset[i] = -(((CAWindow*)ker)->start[i]);
  }

  rb_ivar_set(self, rb_intern("@reference"), rref); /* required ivar */
  rb_ivar_set(self, rb_intern("@kernel"), rker);
}

/* ----------------------------------------------------------------- */

static VALUE
rb_vi_s_allocate (VALUE klass)
{
  CAWindowIterator *it;
  return Data_Make_Struct(klass, CAWindowIterator, 0, free, it);
}

static VALUE
rb_vi_initialize (VALUE self, VALUE rker)
{
  CArray *ker;
  
  rb_check_carray_object(rker);
  Data_Get_Struct(rker, CArray, ker);
  if ( ker->obj_type != CA_OBJ_WINDOW ) {
    rb_raise(rb_eRuntimeError, "kernel must be CAWindow object");
  }

  ca_vi_setup(self, rb_ca_parent(rker), rker);

  return Qnil;
}

static VALUE
rb_vi_initialize_copy (VALUE self, VALUE other)
{
  ca_vi_setup(other, rb_ivar_get(self, rb_intern("@reference")),
              rb_ivar_get(self, rb_intern("@kernel")));
  return self;
}

void
Init_ca_iter_window ()
{
  rb_cCAWindowIterator = rb_define_class("CAWindowIterator", rb_cCAIterator);
  rb_define_const(rb_cCAWindowIterator, "UNIFORM_KERNEL", Qtrue);

  rb_define_alloc_func(rb_cCAWindowIterator, rb_vi_s_allocate);
  rb_define_method(rb_cCAWindowIterator, "initialize", rb_vi_initialize, 1);
  rb_define_method(rb_cCAWindowIterator, "initialize_copy",
                            rb_vi_initialize_copy, 1);
}

