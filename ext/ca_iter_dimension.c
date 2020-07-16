/* ---------------------------------------------------------------------------

  ca_iter_dimension.c

  This file is part of Ruby/CArray extension library.
  You can redistribute it and/or modify it under the terms of
  the Ruby Licence.

  Copyright (C) 2005 Hiroki Motoyoshi

---------------------------------------------------------------------------- */

#include "ruby.h"
#include "carray.h"

VALUE rb_cCADimIterator;

/* rdoc: 
  class CADimensionIterator < CAIterator # :nodoc:
  end
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
  CArray  *kernel;
  int8_t   symflag[CA_RANK_MAX];
  int8_t   symindex[CA_RANK_MAX];
} CADimIterator;

/* -------------------------------------------------------------------- */

static CArray *
ca_di_kernel_at_index (void *it, ca_size_t *idx, CArray *ref)
{
  CADimIterator *dit = (CADimIterator *)it;
  CABlock *kernel;
  int8_t i;
  ca_size_t val;

  if ( ref == dit->reference ) {
    kernel = ca_clone(dit->kernel);
  }
  else {
    CABlock *ck = (CABlock *)dit->kernel;
    kernel = ca_block_new(ref,
                          ck->ndim, ck->size0,
                          ck->start, ck->step, ck->count,
                          ck->offset);
  }

  ca_update_mask(kernel);

  for (i=0; i<dit->ndim; i++) {
    val = idx[i];
    CA_CHECK_INDEX(val, dit->dim[i]);
    kernel->start[dit->symindex[i]] = val * kernel->step[dit->symindex[i]];
    if ( kernel->mask ) {
      ((CABlock*)(kernel->mask))->start[dit->symindex[i]] =
        val * kernel->step[dit->symindex[i]];
    }
  }

  return (CArray*) kernel;
}

static CArray *
ca_di_kernel_at_addr (void *it, ca_size_t addr, CArray *ref)
{
  CADimIterator *dit = (CADimIterator *) it;
  ca_size_t *dim = dit->dim;
  ca_size_t idx[CA_RANK_MAX];
  int8_t i;
  for (i=dit->ndim-1; i>=0; i--) {
    idx[i] = addr % dim[i];
    addr  /= dim[i];
  }
  return ca_di_kernel_at_index(it, idx, ref);
}

static CArray *
ca_di_kernel_move_to_index (void *it, ca_size_t *idx, CArray *kern)
{
  CADimIterator *dit = (CADimIterator *)it;
  CABlock *kernel = (CABlock *) kern;
  int8_t i;
  ca_size_t val;

  ca_update_mask(kernel);

  for (i=0; i<dit->ndim; i++) {
    val = idx[i];
    CA_CHECK_INDEX(val, dit->dim[i]);
    kernel->start[dit->symindex[i]] = val * kernel->step[dit->symindex[i]];
    if ( kernel->mask ) {
      ((CABlock*)(kernel->mask))->start[dit->symindex[i]] =
        val * kernel->step[dit->symindex[i]];
    }
  }

  return (CArray*) kernel;
}

static CArray *
ca_di_kernel_move_to_addr (void *it, ca_size_t addr, CArray *ref)
{
  CADimIterator *dit = (CADimIterator *) it;
  ca_size_t *dim = dit->dim;
  ca_size_t idx[CA_RANK_MAX];
  int8_t i;
  for (i=dit->ndim-1; i>=0; i--) {
    idx[i] = addr % dim[i];
    addr  /= dim[i];
  }
  return ca_di_kernel_move_to_index(it, idx, ref);
}

VALUE rb_ca_ref_block (VALUE self, CAIndexInfo *info);

void
ca_di_setup (VALUE self, VALUE rref, CAIndexInfo *info)
{
  volatile VALUE rindex, rker, rsymtbl;
  CADimIterator *it;
  CAIndexInfo blk_spec;
  int8_t ndim;
  int i, j, k;

  Data_Get_Struct(self, CADimIterator, it);

  if ( info->type != CA_REG_ITERATOR ) {
    rb_raise(rb_eRuntimeError, "given spec is not for dim iteratror");
  }

  rsymtbl = rb_hash_new();

  blk_spec      = *info;
  blk_spec.type = CA_REG_BLOCK;
  for (i=0; i<info->ndim; i++) {
    if ( info->index_type[i] == CA_IDX_SYMBOL ) {
      blk_spec.index_type[i] = CA_IDX_ALL;
      rb_hash_aset(rsymtbl, ID2SYM(blk_spec.index[i].symbol.id), INT2NUM(i));
    }
  }

  rref = rb_ca_ref_block(rref, &blk_spec);

  rindex = rb_ary_new2(info->ndim);
  ndim = 0;

  j = 0;
  k = 0;

  for (i=0; i<info->ndim; i++) {
    if ( info->index_type[i] == CA_IDX_SCALAR ) {
      rb_ary_store(rindex, i, SIZE2NUM(info->index[i].scalar));
      continue; /* escape from j++ */
    }
    else if ( info->index_type[i] == CA_IDX_SYMBOL ) {
      rb_ary_store(rindex, i, rb_ary_new3(1, SIZE2NUM(0)));
      it->symflag[j]       = 1;
      it->symindex[ndim] = j;
      ndim++;
    }
    else if ( info->index_type[i] == CA_IDX_ALL ) {
      rb_ary_store(rindex, i, Qnil);
      it->symflag[j] = 0;
    }
    else if ( info->index_type[i] == CA_IDX_BLOCK ) {
      rb_ary_store(rindex, i,
                   rb_ary_new3(3, SIZE2NUM(0),
                               SIZE2NUM(info->index[i].block.count),
                               SIZE2NUM(1)));
      it->symflag[j] = 0;
    }
    j++;
  }

  rker = rb_apply(rref, rb_intern("[]"), rindex);

  it->ndim = ndim;
  Data_Get_Struct(rref, CArray, it->reference);
  Data_Get_Struct(rker, CArray, it->kernel);
  it->kernel_at_addr  = ca_di_kernel_at_addr;
  it->kernel_at_index = ca_di_kernel_at_index;
  it->kernel_move_to_addr  = ca_di_kernel_move_to_addr;
  it->kernel_move_to_index = ca_di_kernel_move_to_index;

  for (i=0; i<it->ndim; i++) {
    it->dim[i] = it->reference->dim[it->symindex[i]];
  }

  rb_ivar_set(self, rb_intern("@reference"), rref); /* required ivar */
  rb_ivar_set(self, rb_intern("@kernel"), rker);
  rb_ivar_set(self, rb_intern("@symtbl"), rsymtbl);
}

static VALUE
rb_di_s_allocate (VALUE klass)
{
  CADimIterator *it;
  return Data_Make_Struct(klass, CADimIterator, 0, free, it);
}

static VALUE
rb_di_initialize_copy (VALUE self, VALUE other)
{
  volatile VALUE rref, rker;
  CADimIterator *is, *io;

  Data_Get_Struct(self, CADimIterator, is);
  Data_Get_Struct(other, CADimIterator, io);

  rref = rb_ivar_get(self, rb_intern("@reference"));
  rker = rb_obj_clone(rb_ivar_get(self, rb_intern("@kernel")));

  *io = *is;

  Data_Get_Struct(rker, CArray, io->kernel);

  rb_ivar_set(self, rb_intern("@reference"), rref); /* required ivar */
  rb_ivar_set(self, rb_intern("@kernel"), rker);

  return self;
}

VALUE
rb_ca_dim_iterator (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE obj;
  CAIndexInfo info;
  CArray *ca;

  Data_Get_Struct(self, CArray, ca);

  info.range_check = 1;
  rb_ca_scan_index(ca->ndim, ca->dim, ca->elements, argc, argv, &info);

  obj = rb_di_s_allocate(rb_cCADimIterator);
  ca_di_setup(obj, self, &info);

  return obj;
}

VALUE
rb_dim_iter_new (VALUE rref, CAIndexInfo *info)
{
  volatile VALUE obj;

  obj = rb_di_s_allocate(rb_cCADimIterator);
  ca_di_setup(obj, rref, info);

  return obj;
}

/* rdoc:
  class CADimensionIterator
    def sym2dim (sym)
    end
  end
*/


VALUE
rb_dim_iter_sym2dim (VALUE self, VALUE sym)
{
  volatile VALUE rsymtbl;
  rsymtbl = rb_ivar_get(self, rb_intern("@symtbl"));
  return rb_hash_aref(rsymtbl, sym);
}

void
Init_ca_iter_dimension ()
{
  rb_cCADimIterator = rb_define_class("CADimensionIterator", rb_cCAIterator);
  rb_define_const(rb_cCADimIterator, "UNIFORM_KERNEL", Qtrue);

  rb_define_alloc_func(rb_cCADimIterator, rb_di_s_allocate);
  rb_define_method(rb_cCADimIterator, "initialize_copy",
                                        rb_di_initialize_copy, 1);
  /* rb_define_method(rb_cCArray, "dimension_iterator", rb_ca_dim_iterator, -1); */
  rb_define_method(rb_cCADimIterator, "sym2dim", rb_dim_iter_sym2dim, 1);
}

