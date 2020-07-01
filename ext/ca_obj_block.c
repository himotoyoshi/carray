/* ---------------------------------------------------------------------------

  ca_obj_block.c

  This file is part of Ruby/CArray extension library.
  You can redistribute it and/or modify it under the terms of
  the Ruby Licence.

  Copyright (C) 2005 Hiroki Motoyoshi

---------------------------------------------------------------------------- */

#include "carray.h"

VALUE rb_cCABlock;

/* rdoc:
  class CABlock < CAVirtual # :nodoc:
  end
*/

static int
ca_block_setup (CABlock *ca, CArray *parent, int8_t ndim, ca_size_t *dim,
               ca_size_t *start, ca_size_t *step, ca_size_t *count, ca_size_t offset)
{
  int8_t data_type;
  int8_t maxdim_index;
  ca_size_t maxdim_step, maxdim_step0;
  ca_size_t elements, bytes;
  int  i;

  data_type = parent->data_type;
  bytes     = parent->bytes;

  elements = 1;
  for (i=0; i<ndim; i++) {
    if ( count[i] < 0 ) {
      rb_raise(rb_eIndexError,
               "invalid size for %i-th dimension (negative)", i);
    }
    elements *= count[i];
  }

  maxdim_index = ndim-1;
  for (i=ndim-2; i>=0; i--) {
    if ( count[i] > count[maxdim_index] ) {
      maxdim_index = i;
    }
  }

  maxdim_step  = 1;
  maxdim_step0 = step[maxdim_index];
  for (i=maxdim_index+1; i<ndim; i++) {
    maxdim_step  *= count[i];
    maxdim_step0 *= dim[i];
  }

  ca->obj_type  = CA_OBJ_BLOCK;
  ca->data_type = data_type;
  ca->flags     = 0;
  ca->ndim      = ndim;
  ca->bytes     = bytes;
  ca->elements  = elements;
  ca->ptr       = NULL;
  ca->mask      = NULL;
  ca->parent    = parent;
  ca->attach    = 0;
  ca->nosync    = 0;
  ca->offset    = offset;
  ca->start     = ALLOC_N(ca_size_t, ndim);
  ca->step      = ALLOC_N(ca_size_t, ndim);
  ca->count     = ALLOC_N(ca_size_t, ndim);
  ca->size0     = ALLOC_N(ca_size_t, ndim);

  ca->maxdim_index = maxdim_index;
  ca->maxdim_step  = maxdim_step;
  ca->maxdim_step0 = maxdim_step0;

  /* printf("maxdim: %i %i %i\n", maxdim_index, maxdim_step, maxdim_step0); */

  ca->dim = ca->count; /* ca->dim should not be free */

  memcpy(ca->start, start, ndim * sizeof(ca_size_t));
  memcpy(ca->step,  step,  ndim * sizeof(ca_size_t));
  memcpy(ca->count, count, ndim * sizeof(ca_size_t));
  memcpy(ca->size0,  dim,  ndim * sizeof(ca_size_t));

  if ( ca_has_mask(parent) ) {
    ca_create_mask(ca);
  }

  return 0;
}

CABlock *
ca_block_new (CArray *parent, int8_t ndim, ca_size_t *dim,
             ca_size_t *start, ca_size_t *step, ca_size_t *count, ca_size_t offset)
{
  CABlock *ca = ALLOC(CABlock);
  ca_block_setup(ca, parent, ndim, dim, start, step, count, offset);
  return ca;
}

static void
free_ca_block (void *ap)
{
  CABlock *ca = (CABlock *) ap;
  if ( ca != NULL ) {
    xfree(ca->start);
    xfree(ca->step);
    xfree(ca->count);
    xfree(ca->size0);
    ca_free(ca->mask);
    /* free(ca->dim); */
    xfree(ca);
  }
}

static void ca_block_attach (CABlock *cb);
static void ca_block_sync (CABlock *cb);

/* ------------------------------------------------------------------- */

static void *
ca_block_func_clone (void *ap)
{
  CABlock *ca = (CABlock *) ap;
  return ca_block_new(ca->parent,
                      ca->ndim,  ca->size0,
                      ca->start, ca->step, ca->count, ca->offset);
}

static char *
ca_block_func_ptr_at_index (void *ap, ca_size_t *idx) ;

static char *
ca_block_func_ptr_at_addr (void *ap, ca_size_t addr)
{
  CABlock *ca = (CABlock *) ap;
  if ( ca->ptr ) {
    return ca->ptr + ca->bytes * addr;
  }
  else {
    ca_size_t idx[CA_RANK_MAX];
    ca_addr2index(ca, addr, idx);
    return ca_block_func_ptr_at_index(ca, idx);
  }
}

static char *
ca_block_func_ptr_at_index (void *ap, ca_size_t *idx)
{
  CABlock *ca = (CABlock *) ap;

  if ( ca->ptr ) {
    return ca_array_func_ptr_at_index(ca, idx);
  }
  else {
    ca_size_t *start = ca->start;
    ca_size_t *step  = ca->step;
    ca_size_t *size0 = ca->size0;
    int8_t   i;
    ca_size_t  n;
    n = start[0] + idx[0]*step[0];
    for (i=1; i<ca->ndim; i++) {
      n *= size0[i];
      n += start[i] + idx[i]*step[i];
    }
    n += ca->offset;
    if ( ca->parent->ptr ) {
      return ca->parent->ptr + ca->bytes * n;
    }
    else {
      return ca_ptr_at_addr(ca->parent, n);
    }
  }
}

static void
ca_block_func_fetch_index (void *ap, ca_size_t *idx, void *ptr)
{
  CABlock *ca = (CABlock *) ap;
  ca_size_t *start = ca->start;
  ca_size_t *step  = ca->step;
  ca_size_t *size0 = ca->size0;
  int8_t   i;
  ca_size_t  n;
  n = start[0] + idx[0]*step[0];
  for (i=1; i<ca->ndim; i++) {
    n *= size0[i];
    n += start[i] + idx[i]*step[i];
  }
  n += ca->offset;
  ca_fetch_addr(ca->parent, n, ptr);
}

static void
ca_block_func_store_index (void *ap, ca_size_t *idx, void *ptr)
{
  CABlock *ca = (CABlock *) ap;
  ca_size_t *start = ca->start;
  ca_size_t *step  = ca->step;
  ca_size_t *size0 = ca->size0;
  int8_t   i;
  ca_size_t  n;
  n = start[0] + idx[0]*step[0];
  for (i=1; i<ca->ndim; i++) {
    n *= size0[i];
    n += start[i] + idx[i]*step[i];
  }
  n += ca->offset;
  ca_store_addr(ca->parent, n, ptr);
}

static void
ca_block_func_allocate (void *ap)
{
  CABlock *ca = (CABlock *) ap;
  ca_attach(ca->parent);
  /* ca->ptr = ALLOC_N(char, ca_length(ca)); */
  ca->ptr = malloc_with_check(ca_length(ca));  
}

static void
ca_block_func_attach (void *ap)
{
  CABlock *ca = (CABlock *) ap;
  ca_attach(ca->parent);
  /* ca->ptr = ALLOC_N(char, ca_length(ca)); */
  ca->ptr = malloc_with_check(ca_length(ca));  
  ca_block_attach(ca);
}

static void
ca_block_func_sync (void *ap)
{
  CABlock *ca = (CABlock *) ap;
  ca_block_sync(ca);
  ca_sync(ca->parent);
}

static void
ca_block_func_detach (void *ap)
{
  CABlock *ca = (CABlock *) ap;
  free(ca->ptr);
  ca->ptr = NULL;
  ca_detach(ca->parent);
}

static void
ca_block_func_copy_data (void *ap, void *ptr)
{
  CABlock *ca = (CABlock *) ap;
  char *ptr0 = ca->ptr;
  ca_attach(ca->parent);
  ca->ptr = ptr;
  ca_block_attach(ca);
  ca->ptr = ptr0;
  ca_detach(ca->parent);
}

static void
ca_block_func_sync_data (void *ap, void *ptr)
{
  CABlock *ca = (CABlock *) ap;
  char *ptr0 = ca->ptr;
  ca_attach(ca->parent);
  ca->ptr = ptr;
  ca_block_sync(ca);
  ca->ptr = ptr0;
  ca_sync(ca->parent);
  ca_detach(ca->parent);
}

static void ca_block_fill (CABlock *ca, char *val);

static void
ca_block_func_fill_data (void *ap, void *ptr)
{
  CABlock *ca = (CABlock *) ap;
  ca_attach(ca->parent);
  ca_block_fill(ca, ptr);
  ca_sync(ca->parent);
  ca_detach(ca->parent);
}

static void
ca_block_func_create_mask (void *ap)
{
  CABlock *ca = (CABlock *) ap;
  ca_create_mask(ca->parent);
  ca->mask =
    (CArray *) ca_block_new(ca->parent->mask,
                            ca->ndim, ca->size0,
                            ca->start, ca->step, ca->count, ca->offset);
}

ca_operation_function_t ca_block_func = {
  CA_OBJ_BLOCK,
  CA_VIRTUAL_ARRAY,
  free_ca_block,
  ca_block_func_clone,
  ca_block_func_ptr_at_addr,
  ca_block_func_ptr_at_index,
  NULL,
  ca_block_func_fetch_index,
  NULL,
  ca_block_func_store_index,
  ca_block_func_allocate,
  ca_block_func_attach,
  ca_block_func_sync,
  ca_block_func_detach,
  ca_block_func_copy_data,
  ca_block_func_sync_data,
  ca_block_func_fill_data,
  ca_block_func_create_mask,
};

/* ------------------------------------------------------------------- */

VALUE
rb_ca_block_new (VALUE cary, int8_t ndim, ca_size_t *dim,
                ca_size_t *start, ca_size_t *step, ca_size_t *count, ca_size_t offset)
{
  volatile VALUE obj;
  CArray *parent;
  CABlock *ca;

  rb_check_carray_object(cary);
  Data_Get_Struct(cary, CArray, parent);

  ca = ca_block_new(parent, ndim, dim, start, step, count, offset);
  obj = ca_wrap_struct(ca);
  rb_ca_set_parent(obj, cary);
  rb_ca_data_type_inherit(obj, cary);
  return obj;
}

/* ---------------------------------------------------------------------- */

static void *mcopy_step (void *dest, const void *src,
            size_t bytes, size_t n, size_t dstep, size_t sstep);

static void *mfill_step(void *dest,
             size_t bytes, size_t n, size_t dstep, const void *src);

static void
ca_block_attach_loop2 (CABlock *ca, int8_t level, ca_size_t saddr, ca_size_t saddr0)
{
  ca_size_t count = ca->count[level];
  ca_size_t addr, addr0, i;

  if ( level == ca->ndim - 1 ) {
    if ( ca->parent->ptr ) {
      addr  = saddr  * ca->dim[level];
      addr0 = saddr0 * ca->size0[level] + ca->start[level];
      mcopy_step(ca_ptr_at_addr(ca, addr),
                 ca_ptr_at_addr(ca->parent, addr0 + ca->offset),
                 ca->bytes, count, 1, ca->step[level]);
    }
    else {
      for (i=0; i<count; i++) {
        addr  = saddr  * ca->dim[level] + i;
        addr0 = saddr0 * ca->size0[level] + ca->start[level]
                                          + i * ca->step[level];
        memcpy(ca_ptr_at_addr(ca, addr),
               ca_ptr_at_addr(ca->parent, addr0 + ca->offset),
               ca->bytes);
      }
    }
  }
  else {
    for (i=0; i<count; i++) {
      addr  = saddr  * ca->dim[level] + i;
      addr0 = saddr0 * ca->size0[level] + ca->start[level]
                                        + i * ca->step[level];
      ca_block_attach_loop2(ca, level+1, addr, addr0);
    }
  }
}

static void
ca_block_attach_loop (CABlock *ca, ca_size_t level, ca_size_t saddr, ca_size_t saddr0)
{
  ca_size_t count = ca->count[level];
  ca_size_t addr, addr0, i;

  if ( level == ca->ndim - 1 ) {
    if ( level == ca->maxdim_index ) {
      addr  = saddr  * ca->dim[level];
      addr0 = saddr0 * ca->size0[level] + ca->start[level];
      mcopy_step(ca_ptr_at_addr(ca, addr),
                 ca_ptr_at_addr(ca->parent, addr0 + ca->offset),
                 ca->bytes, count, 1, ca->step[level]);
    }
    else {
      char *p = ca_ptr_at_addr(ca, saddr* ca->dim[level]);
      char *q = ca_ptr_at_addr(ca->parent,
                saddr0*ca->size0[level]+ca->start[level]+ca->offset);
      ca_size_t pstep = ca->bytes;
      ca_size_t qstep = ca->bytes*ca->step[level];
      for (i=0; i<count; i++) {
        mcopy_step(p,
                   q,
                   ca->bytes, ca->count[ca->maxdim_index],
                   ca->maxdim_step, ca->maxdim_step0);
        p += pstep;
        q += qstep;
      }
    }
  }
  else {
    if ( level == ca->maxdim_index ) {
      addr  = saddr  * ca->dim[level];
      addr0 = saddr0 * ca->size0[level] + ca->start[level];
      ca_block_attach_loop(ca, level+1, addr, addr0);
    }
    else {
      for (i=0; i<count; i++) {
        addr  = saddr  * ca->dim[level] + i;
        addr0 = saddr0 * ca->size0[level] + ca->start[level]
                                             + i * ca->step[level];
        ca_block_attach_loop(ca, level+1, addr, addr0);
      }
    }
  }
}

static void
ca_block_attach (CABlock *ca)
{
  ca_size_t addr = 0, addr0 = 0;
  if ( ca->ndim <= 2 ) {
    ca_block_attach_loop2(ca, 0, addr, addr0);
  }
  else {
    ca_block_attach_loop(ca, 0, addr, addr0);
  }
}

static void
ca_block_sync_loop2 (CABlock *ca, int8_t level, ca_size_t saddr, ca_size_t saddr0)
{
  ca_size_t count = ca->count[level];
  ca_size_t addr, addr0, i;

  if ( level == ca->ndim - 1 ) {
    if ( ca->parent->ptr ) {
      addr  = saddr  * ca->dim[level];
      addr0 = saddr0 * ca->size0[level] + ca->start[level];
      mcopy_step(ca_ptr_at_addr(ca->parent, addr0 + ca->offset),
                 ca_ptr_at_addr(ca, addr),
                 ca->bytes, count, ca->step[level], 1);
    }
    else {
      for (i=0; i<count; i++) {
        addr  = saddr  * ca->dim[level] + i;
        addr0 = saddr0 * ca->size0[level] + ca->start[level]
                                          + i * ca->step[level];
        memcpy(ca_ptr_at_addr(ca->parent, addr0 + ca->offset),
               ca_ptr_at_addr(ca, addr),
               ca->bytes);
      }
    }
  }
  else {
    for (i=0; i<count; i++) {
      addr  = saddr  * ca->dim[level] + i;
      addr0 = saddr0 * ca->size0[level] + ca->start[level] + i * ca->step[level];
      ca_block_sync_loop2(ca, level+1, addr, addr0);
    }
  }
}

static void
ca_block_sync_loop (CABlock *ca, int8_t level, ca_size_t saddr, ca_size_t saddr0)
{
  ca_size_t count = ca->count[level];
  ca_size_t addr, addr0, i;

  if ( level == ca->ndim - 1 ) {
    if ( level == ca->maxdim_index ) {
      addr  = saddr  * ca->dim[level];
      addr0 = saddr0 * ca->size0[level] + ca->start[level];
      mcopy_step(ca_ptr_at_addr(ca->parent, addr0 + ca->offset),
                 ca_ptr_at_addr(ca, addr),
                 ca->bytes, count, ca->step[level], 1);
    }
    else {
      for (i=0; i<count; i++) {
        addr  = saddr  * ca->dim[level] + i;
        addr0 = saddr0 * ca->size0[level] + ca->start[level]
                                             + i * ca->step[level];
        mcopy_step(ca_ptr_at_addr(ca->parent, addr0 + ca->offset),
                   ca_ptr_at_addr(ca, addr),
                   ca->bytes, ca->count[ca->maxdim_index],
                   ca->maxdim_step0, ca->maxdim_step);
      }
    }
  }
  else {
    if ( level == ca->maxdim_index ) {
      addr  = saddr  * ca->dim[level];
      addr0 = saddr0 * ca->size0[level] + ca->start[level];
      ca_block_sync_loop(ca, level+1, addr, addr0);
    }
    else {
      for (i=0; i<count; i++) {
        addr  = saddr  * ca->dim[level] + i;
        addr0 = saddr0 * ca->size0[level] + ca->start[level]
                                             + i * ca->step[level];
        ca_block_sync_loop(ca, level+1, addr, addr0);
      }
    }
  }
}

static void
ca_block_sync (CABlock *cb)
{
  ca_size_t addr = 0, addr0 = 0;
  if ( cb->ndim <= 2 ) {
    ca_block_sync_loop2(cb, 0, addr, addr0);
  }
  else {
    ca_block_sync_loop(cb, 0, addr, addr0);
  }
}

static void
ca_block_fill_loop2 (CABlock *ca, int8_t level, ca_size_t saddr, char *val)
{
  ca_size_t count = ca->count[level];
  ca_size_t addr, i;
  if ( level == ca->ndim - 1 ) {
    addr = saddr * ca->dim[level];
    mfill_step(ca_ptr_at_addr(ca, addr),
               ca->bytes, count, ca->step[level], val);
  }
  else {
    for (i=0; i<count; i++) {
      addr  = saddr * ca->dim[level] + i;
      ca_block_fill_loop2(ca, level+1, addr, val);
    }
  }
}

static void
ca_block_fill_loop (CABlock *ca, int8_t level, ca_size_t saddr, char *val)
{
  ca_size_t count = ca->count[level];
  ca_size_t addr, i;
  if ( level == ca->ndim - 1 ) {
    if ( level == ca->maxdim_index ) {
      addr = saddr * ca->dim[level];
      mfill_step(ca_ptr_at_addr(ca, addr),
                 ca->bytes, count, ca->step[level], val);
    }
    else {
      for (i=0; i<count; i++) {
        addr  = saddr  * ca->dim[level] + i;
        mfill_step(ca_ptr_at_addr(ca, addr),
                   ca->bytes, ca->count[ca->maxdim_index],
                   ca->maxdim_step0, val);
      }
    }

  }
  else {
    if ( level == ca->maxdim_index ) {
      addr  = saddr  * ca->dim[level];
      ca_block_fill_loop(ca, level+1, addr, val);
    }
    else {
      for (i=0; i<count; i++) {
        addr  = saddr * ca->dim[level] + i;
        ca_block_fill_loop(ca, level+1, addr, val);
      }
    }

  }
}

static void
ca_block_fill (CABlock *ca, char *val)
{
  ca_size_t addr = 0;
  if ( ca->ndim <= 2 ) {
    ca_block_fill_loop2(ca, 0, addr, val);
  }
  else {
    ca_block_fill_loop(ca, 0, addr, val);
  }
}

/* -------------------------------------------------------------------- */

static void *
mcopy_step (void *dest, const void *src,
            size_t bytes, size_t n, size_t dstep, size_t sstep)
{
  if ( dstep == 1 && sstep == 1 ) {
    size_t bytelen = bytes * n;
    size_t words   = bytelen / sizeof(int);
    size_t rests   = bytelen % sizeof(int);
    int *sp = (int*) src;
    int *dp = (int*) dest;
    char *scp;
    char *dcp;
    ca_size_t i;
    for (i=words; i; i--) {
      *dp++ = *sp++;
    }
    scp = (char*)sp; dcp = (char*)dp;
    for (i=rests; i; i--) {
      *dcp++ = *scp++;
    }
  }
  else if ( dstep >= 1 || sstep >= 1 ) {
    switch ( bytes ) {
    case 1: {
      int8_t *sp = (int8_t*) src, *dp = (int8_t*) dest;
      while (n--) { *dp = *sp; dp+=dstep; sp+=sstep; }
      break;
    }
    case 2: {
      int16_t *sp = (int16_t*) src, *dp = (int16_t*) dest;
      while (n--) { *dp = *sp; dp+=dstep; sp+=sstep; }
      break;
    }
    case 4: {
      int32_t *sp = (int32_t*) src, *dp = (int32_t*) dest;
      while (n--) { *dp = *sp; dp+=dstep; sp+=sstep; }
      break;
    }
    case 8: {
      double *sp = (double*) src, *dp = (double*) dest;
      while (n--) { *dp = *sp; dp+=dstep; sp+=sstep; }
      break;
    }
    default: {
      char *sp = (char*) src, *dp = (char*) dest;
      while (n--) { memcpy(dp,sp,bytes); dp+=bytes*dstep; sp+=bytes*sstep; }
      break;
    }
    }
  }

  return dest;
}

static void *
mfill_step(void *dest, size_t bytes, size_t n, size_t dstep, const void *src)
{
  switch ( bytes ) {
  case 1: {
    int8_t *dp = (int8_t*) dest;
    int8_t v = *(int8_t*) src;
    while (n--) { *dp = v; dp+=dstep; }
    break;
  }
  case 2: {
    int16_t *dp = (int16_t*) dest;
    int16_t v = *(int16_t*) src;
    while (n--) { *dp = v; dp+=dstep; }
    break;
  }
  case 4: {
    int32_t *dp = (int32_t*) dest;
    int32_t v = *(int32_t*) src;
    while (n--) { *dp = v; dp+=dstep; }
    break;
  }
  case 8: {
    double *dp = (double*) dest;
    double v = *(double*) src;
    while (n--) { *dp = v; dp+=dstep; }
    break;
  }
  default: {
    char *sp = (char*) src, *dp = (char*) dest;
    while (n--) { memcpy(dp,sp,bytes); dp+=bytes*dstep; }
    break;
  }
  }

  return dest;
}

/* ---------------------------------------------------------------------- */

static VALUE
rb_cb_s_allocate (VALUE klass)
{
  CABlock *ca;
  return Data_Make_Struct(klass, CABlock, ca_mark, ca_free, ca);
}

static VALUE
rb_cb_initialize_copy (VALUE self, VALUE other)
{
  CABlock *ca, *cs;
  ca_size_t shrink[CA_RANK_MAX];
  int8_t i;

  Data_Get_Struct(self,  CABlock, ca);
  Data_Get_Struct(other, CABlock, cs);

  for (i=0; i<cs->ndim; i++) {
    shrink[i] = 0;
  }

  ca_block_setup(ca, cs->parent,
                cs->ndim, cs->size0, cs->start, cs->step, cs->count, cs->offset);

  /* CHECK ME : other.parent instead of other ? */
  rb_ca_set_parent(self, rb_ca_parent(other));
  rb_ca_data_type_inherit(self, rb_ca_parent(other));

  return self;
}

#define rb_cb_get_attr_ary(name)    \
  rb_cb_## name (VALUE self)        \
  {                                 \
    volatile VALUE ary;             \
    CABlock *cb;                    \
    int8_t i;                              \
    Data_Get_Struct(self, CABlock, cb);     \
    ary = rb_ary_new2(cb->ndim);            \
    for (i=0; i<cb->ndim; i++) {                    \
      rb_ary_store(ary, i, LONG2NUM(cb->name[i]));  \
    }                                               \
    return ary;                                     \
}

/* rdoc:
  class CABlock
    def size0
    end
    def start
    end
    def step 
    end
    def count
    end
    def offset
    end
  end
*/

static VALUE rb_cb_get_attr_ary(size0);
static VALUE rb_cb_get_attr_ary(start);
static VALUE rb_cb_get_attr_ary(step);
static VALUE rb_cb_get_attr_ary(count);

static VALUE
rb_cb_offset (VALUE self)
{
  CABlock *cb;
  Data_Get_Struct(self, CABlock, cb);
  return SIZE2NUM(cb->offset);
}

/* rdoc:
  class CABlock
    def idx2addr0 (idx)
    end
  end
*/

static VALUE
rb_cb_idx2addr0 (int argc, VALUE *argv, VALUE self)
{
  CABlock *cb;
  ca_size_t addr;
  int8_t i;
  ca_size_t idxi;

  Data_Get_Struct(self, CABlock, cb);

  if ( argc != cb->ndim ) {
    rb_raise(rb_eArgError,
             "invalid # of arguments (should be <%i>)", cb->ndim);
  }

  addr = 0;
  for (i=0; i<cb->ndim; i++) {
    idxi = NUM2SIZE(argv[i]);
    CA_CHECK_INDEX(idxi, cb->dim[i]);
    addr = cb->size0[i] * addr + cb->start[i] + idxi * cb->step[i];
  }

  return SIZE2NUM(addr + cb->offset);
}

/* rdoc:
  class CABlock
    def addr2addr0 (addr)
    end
  end
*/

static VALUE
rb_cb_addr2addr0 (VALUE self, VALUE raddr)
{
  CABlock *cb;
  ca_size_t addr = NUM2SIZE(raddr);
  ca_size_t idx[CA_RANK_MAX];
  int8_t i;

  Data_Get_Struct(self, CABlock, cb);

  ca_addr2index((CArray*)cb, addr, idx);

  addr = 0;
  for (i=0; i<cb->ndim; i++) {
    addr *= cb->size0[i];
    addr += cb->start[i] + idx[i] * cb->step[i];
  }

  return SIZE2NUM(addr + cb->offset);
}


/* rdoc:
  class CABlock
    def move (*index)
    end
  end
*/

static VALUE
rb_cb_move (int argc, VALUE *argv, VALUE self)
{
  CABlock *cb;
  ca_size_t start;
  int8_t i;

  Data_Get_Struct(self, CABlock, cb);

  if ( argc != cb->ndim ) {
    rb_raise(rb_eArgError, "invalid # of arguments");
  }

  ca_update_mask(cb);

  for (i=0; i<cb->ndim; i++) {
    start = NUM2SIZE(argv[i]);
    if ( start < 0 ) {
      start += cb->size0[i];
    }

    if ( start < 0 || start + (cb->dim[i]-1) * cb->step[i] >= cb->size0[i] ) {
      rb_raise(rb_eArgError, "%i-th index out of range", i);
    }

    cb->start[i] = start;

    if ( cb->mask ) {
      ((CABlock*)(cb->mask))->start[i] = start;
    }
  }

  return self;
}

void
Init_ca_obj_block ()
{
  /* rb_cCABlock, CA_OBJ_BLOCK are defined in rb_carray.c */

  rb_define_const(rb_cObject, "CA_OBJ_BLOCK", INT2NUM(CA_OBJ_BLOCK));

  rb_define_alloc_func(rb_cCABlock, rb_cb_s_allocate);
  rb_define_method(rb_cCABlock, "initialize_copy", rb_cb_initialize_copy, 1);

  rb_define_method(rb_cCABlock, "size0",  rb_cb_size0, 0);
  rb_define_method(rb_cCABlock, "start",  rb_cb_start, 0);
  rb_define_method(rb_cCABlock, "step",   rb_cb_step, 0);
  rb_define_method(rb_cCABlock, "count",  rb_cb_count, 0);
  rb_define_method(rb_cCABlock, "offset", rb_cb_offset, 0);

  rb_define_method(rb_cCABlock, "move",  rb_cb_move, -1);

  rb_define_method(rb_cCABlock, "idx2addr0",   rb_cb_idx2addr0, -1);
  rb_define_method(rb_cCABlock, "index2addr0", rb_cb_idx2addr0, -1);
  rb_define_method(rb_cCABlock, "addr2addr0",  rb_cb_addr2addr0, 1);
}
