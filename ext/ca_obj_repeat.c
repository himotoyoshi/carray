/* ---------------------------------------------------------------------------

  ca_obj_repeat.c

  This file is part of Ruby/CArray extension library.

  Copyright (C) 2005-2020 Hiroki Motoyoshi

---------------------------------------------------------------------------- */

#include "carray.h"

VALUE rb_cCARepeat;

/* yard:
  class CARepeat < CAVirtual # :nodoc:
  end
*/

int
ca_repeat_setup (CARepeat *ca, CArray *parent, int8_t ndim, ca_size_t *count)
{
  int8_t data_type;
  ca_size_t elements, bytes, nrpt, repeat_level, repeat_num,
                     contig_level, contig_num, data_ndim;
  int i, j;

  nrpt = 1;
  data_ndim  = 0;
  for (i=0; i<ndim; i++) {
    if ( count[i] < 0 ) {
      rb_raise(rb_eRuntimeError,
               "negative size for %i-th dimension specified", i);
    }

    if ( count[i] ) {
      nrpt *= count[i];
    }
    else {
      data_ndim += 1;
    }
  }

  repeat_level = 0;
  repeat_num   = 1;
  for (i=0; i<ndim && count[i]; i++) {
    repeat_level = i+1;
    repeat_num  *= count[i];
  }

  contig_level = ndim-1;
  contig_num   = 1;
  for (i=ndim-1; i >= 0 && count[i]; i--) {
    contig_level = i;
    contig_num  *= count[i];
  }
  
  if ( data_ndim != parent->ndim ) {
    rb_raise(rb_eRuntimeError,
             "mismatch in ndim between original array and determined by # of dummies");
  }

  if ( ((double) parent->elements) * nrpt > CA_LENGTH_MAX ) {
    rb_raise(rb_eRuntimeError, "too large byte length");
  }

  data_type = parent->data_type;
  elements  = parent->elements * nrpt;
  bytes     = parent->bytes;

  ca->obj_type  = CA_OBJ_REPEAT;
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
  ca->count     = ALLOC_N(ca_size_t, ndim);
  ca->repeat_level = repeat_level;
  ca->repeat_num   = repeat_num;
  ca->contig_level = contig_level;
  ca->contig_num   = contig_num;

  j = 0;
  for (i=0; i<ndim; i++) {
    if ( count[i] ) {
      ca->dim[i] = count[i];
    }
    else {
      ca->dim[i] = parent->dim[j++];
    }
  }

  memcpy(ca->count, count, ndim * sizeof(ca_size_t));

  ca_set_flag(ca, CA_FLAG_READ_ONLY);

  if ( ca_has_mask(parent) ) {
    ca_create_mask(ca);
  }

  return 0;
}


CARepeat *
ca_repeat_new (CArray *parent, int8_t ndim, ca_size_t *count)
{
  CARepeat *ca = ALLOC(CARepeat);
  ca_repeat_setup(ca, parent, ndim, count);
  return ca;
}

static void
free_ca_repeat (void *ap)
{
  CARepeat *ca = (CARepeat *) ap;
  if ( ca != NULL ) {
    xfree(ca->count);
    ca_free(ca->mask);
    xfree(ca->dim);
    xfree(ca);
  }
}

static void ca_repeat_attach (CARepeat *cb);
static void ca_repeat_sync (CARepeat *cb);
static void ca_repeat_fill (CARepeat *ca, char *ptr);

/* ------------------------------------------------------------------- */

static void *
ca_repeat_func_clone (void *ap)
{
  CARepeat *ca = (CARepeat *) ap;
  return ca_repeat_new(ca->parent, ca->ndim, ca->count);
}

static char *
ca_repeat_func_ptr_at_addr (void *ap, ca_size_t addr)
{
  CARepeat *ca = (CARepeat *) ap;
  if ( ca->ptr ) {
    return ca->ptr + ca->bytes * addr;
  }
  else {
    ca_size_t idx[CA_RANK_MAX];
    ca_addr2index((CArray *)ca, addr, idx);
    return ca_ptr_at_index(ca, idx);
  }
}

static char *
ca_repeat_func_ptr_at_index (void *ap, ca_size_t *idx)
{
  CARepeat *ca = (CARepeat *) ap;
  if ( ca->ptr ) {
    return ca_array_func_ptr_at_index(ca, idx);
  }
  else {
    ca_size_t *count = ca->count;
    ca_size_t *dim0  = ca->parent->dim;
    int8_t   i;
    ca_size_t  n, j;

    j = 0;
    n = 0;
    for (i=0; i<ca->ndim; i++) {
      if ( ! count[i] ) {
        n = dim0[j]*n + idx[i];
        j++;
      }
    }

    if ( ca->parent->ptr ) {
      return ca->parent->ptr + ca->bytes * n;
    }
    else {
      return ca_ptr_at_addr(ca->parent, n);
    }
  }
}

static void
ca_repeat_func_fetch_index (void *ap, ca_size_t *idx, void *ptr)
{
  CARepeat *ca = (CARepeat *) ap;
  ca_size_t *count = ca->count;
  ca_size_t idx0[CA_RANK_MAX];
  int8_t   i;
  ca_size_t  n, j;
  j = 0;
  n = 0;
  for (i=0; i<ca->ndim; i++) {
    if ( ! count[i] ) {
      idx0[j++] = idx[i];
    }
  }
  ca_fetch_index(ca->parent, idx0, ptr);
}

static void
ca_repeat_func_store_index (void *ap, ca_size_t *idx, void *ptr)
{
  CARepeat *ca = (CARepeat *) ap;
  ca_size_t *count = ca->count;
  ca_size_t idx0[CA_RANK_MAX];
  int8_t   i;
  ca_size_t  n, j;
  j = 0;
  n = 0;
  for (i=0; i<ca->ndim; i++) {
    if ( ! count[i] ) {
      idx0[j++] = idx[i];
    }
  }
  ca_store_index(ca->parent, idx0, ptr);
}

static void
ca_repeat_func_allocate (void *ap)
{
  CARepeat *ca = (CARepeat *) ap;
  ca_attach(ca->parent);
  /* ca->ptr = ALLOC_N(char, ca_length(ca)); */
  ca->ptr = malloc_with_check(ca_length(ca));  
}

static void
ca_repeat_func_attach (void *ap)
{
  CARepeat *ca = (CARepeat *) ap;
  ca_attach(ca->parent);
  /* ca->ptr = ALLOC_N(char, ca_length(ca)); */
  ca->ptr = malloc_with_check(ca_length(ca));  
  ca_repeat_attach(ca);
}

static void
ca_repeat_func_sync (void *ap)
{
  CARepeat *ca = (CARepeat *) ap;
  ca_repeat_sync(ca);
  ca_sync(ca->parent);
}

static void
ca_repeat_func_detach (void *ap)
{
  CARepeat *ca = (CARepeat *) ap;
  free(ca->ptr);
  ca->ptr = NULL;
  ca_detach(ca->parent);
}

static void
ca_repeat_func_copy_data (void *ap, void *ptr)
{
  CARepeat *ca = (CARepeat *) ap;
  char *ptr0 = ca->ptr;
  ca_attach(ca->parent);
  ca->ptr = ptr;
  ca_repeat_attach(ca);
  ca->ptr = ptr0;
  ca_detach(ca->parent);
}

static void
ca_repeat_func_sync_data (void *ap, void *ptr)
{
  CARepeat *ca = (CARepeat *) ap;
  char *ptr0 = ca->ptr;
  ca_attach(ca->parent);
  ca->ptr = ptr;
  ca_repeat_sync(ca);
  ca->ptr = ptr0;
  ca_sync(ca->parent);
  ca_detach(ca->parent);
}

static void
ca_repeat_func_fill_data (void *ap, void *ptr)
{
  CARepeat *ca = (CARepeat *) ap;
  ca_attach(ca->parent);
  ca_repeat_fill(ca, ptr);
  ca_sync(ca->parent);
  ca_detach(ca->parent);
}

static void
ca_repeat_func_create_mask (void *ap)
{
  CARepeat *ca = (CARepeat *) ap;
  ca_update_mask(ca->parent);
  if ( ! ca->parent->mask ) {
    ca_create_mask(ca->parent);
  }
  ca->mask =
    (CArray *) ca_repeat_new(ca->parent->mask, ca->ndim, ca->count);
}

ca_operation_function_t ca_repeat_func = {
  -1, /* CA_OBJ_REPEAT */
  CA_VIRTUAL_ARRAY,
  free_ca_repeat,
  ca_repeat_func_clone,
  ca_repeat_func_ptr_at_addr,
  ca_repeat_func_ptr_at_index,
  NULL,
  ca_repeat_func_fetch_index,
  NULL,
  ca_repeat_func_store_index,
  ca_repeat_func_allocate,
  ca_repeat_func_attach,
  ca_repeat_func_sync,
  ca_repeat_func_detach,
  ca_repeat_func_copy_data,
  ca_repeat_func_sync_data,
  ca_repeat_func_fill_data,
  ca_repeat_func_create_mask,
};

/* ------------------------------------------------------------------- */

static void
memfill (void *dp, void *sp, ca_size_t bytes, ca_size_t n)
{
  switch ( bytes ) {
  case 1:
    memset(dp, *(uint8_t*)sp, n);
    break;
  case 2: {
    int16_t *p = (int16_t *) dp, *q = (int16_t *) sp;
    while (n--) { *p++ = *q; }
    break;
  }
  case 4: {
    int32_t *p = (int32_t *) dp, *q = (int32_t *) sp;
    while (n--) { *p++ = *q; }
    break;
  }
  case 8: {
    float64_t *p = (float64_t *) dp, *q = (float64_t *) sp;
    while (n--) { *p++ = *q; }
    break;
  }
  default: {
    ca_size_t i;
    char *p = (char *) dp, *q = (char *) sp;
    for (i=0; i<n; i++) {
      memcpy(p, q, bytes);
      p+=bytes;
    }
  }
  }
}

static void
ca_repeat_attach_loop1 (CARepeat *ca, int8_t level, int8_t level0,
                                    ca_size_t *idx, ca_size_t *idx0)
{
  ca_size_t *count = ca->count;
  ca_size_t i;

  if ( level == ca->contig_level ) {
    if ( ca->contig_num == 1 ) {
      for (i=0; i<ca->dim[level]; i++) {
	idx[level] = i;
	idx0[level0] = i;
	memcpy(ca_ptr_at_index(ca, idx), 
	       ca_ptr_at_index(ca->parent, idx0),
	       ca->bytes);
      }
    }
    else {
      char *dp, *sp;
      dp = ca_ptr_at_index(ca, idx);
      sp = ca_ptr_at_index(ca->parent, idx0);
      memfill(dp, sp, ca->bytes, ca->contig_num);
    }
  }
  else {
    for (i=0; i<ca->dim[level]; i++) {
      idx[level]  = i;
      if ( ! count[level] ) {
        idx0[level0] = i;
        ca_repeat_attach_loop1(ca, level+1, level0+1, idx, idx0);
      }
      else {
        ca_repeat_attach_loop1(ca, level+1, level0, idx, idx0);
      }
    }
  }
}

static void
ca_repeat_attach (CARepeat *ca)
{
  ca_size_t idx[CA_RANK_MAX];
  ca_size_t idx0[CA_RANK_MAX];
  ca_size_t i;
  char *dp, *sp;

  for (i=0; i<ca->ndim; i++) {
    idx[i] = 0;
    idx0[i] = 0;
  }
  ca_repeat_attach_loop1(ca, ca->repeat_level, 0, idx, idx0);

  sp = ca_ptr_at_addr(ca, 0);
  for (i=1; i<ca->repeat_num; i++) {
    dp = sp + i * ca->bytes * (ca->elements / ca->repeat_num);
    memcpy(dp, sp, ca->bytes * (ca->elements / ca->repeat_num));
  }
}

static void
ca_repeat_sync_loop (CARepeat *ca, int8_t level, int8_t level0,
                                    ca_size_t *idx, ca_size_t *idx0)
{
  ca_size_t *count = ca->count;
  ca_size_t i;

  if ( level == ca->contig_level ) {
    if ( ca->contig_num == 1 ) {
      memcpy(ca_ptr_at_index(ca->parent, idx0), ca_ptr_at_index(ca, idx),
             ca_length(ca->parent));
    }
    else {
      memcpy(ca_ptr_at_index(ca->parent, idx0), ca_ptr_at_index(ca, idx), ca->bytes);
    }
  }
  else {
    for (i=0; i<ca->dim[level]; i++) {
      idx[level]  = i;
      if ( ! count[level] ) {
        idx0[level0] = i;
        ca_repeat_sync_loop(ca, level+1, level0+1, idx, idx0);
      }
      else {
        ca_repeat_sync_loop(ca, level+1, level0, idx, idx0);
      }
    }
  }
}

static void
ca_repeat_sync (CARepeat *ca)
{
  ca_size_t idx[CA_RANK_MAX];
  ca_size_t idx0[CA_RANK_MAX];
  int8_t i;
  for (i=0; i<ca->ndim; i++) {
    idx[i] = 0;
    idx0[i] = 0;
  }
  ca_repeat_sync_loop(ca, ca->repeat_level, 0, idx, idx0);
}

static void
ca_repeat_fill (CARepeat *ca, char *ptr)
{
  ca_fill(ca->parent, ptr);
}

/* ------------------------------------------------------------------- */

VALUE
rb_ca_repeat_new (VALUE cary, int8_t ndim, ca_size_t *count)
{
  volatile VALUE obj;
  CArray *parent;
  CARepeat *ca;
  rb_check_carray_object(cary);
  Data_Get_Struct(cary, CArray, parent);
  ca = ca_repeat_new(parent, ndim, count);
  obj = ca_wrap_struct(ca);
  rb_ca_set_parent(obj, cary);
  rb_ca_data_type_inherit(obj, cary);
  return obj;
}

VALUE
rb_ca_repeat (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE obj;
  CArray *ca;
  ca_size_t count[CA_RANK_MAX];
  ca_size_t repeat;
  ca_size_t i;

  Data_Get_Struct(self, CArray, ca);

  if ( argc == 2 && 
       (
         ( argv[0] == ID2SYM(rb_intern("%")) && rb_obj_is_carray(argv[1]) ) ||
         ( argv[1] == ID2SYM(rb_intern("%")) && rb_obj_is_carray(argv[0]) ) 
       ) ) {
    volatile VALUE args;
    CArray *ct;
    ca_size_t ndim, dim[CA_RANK_MAX];
    int k;
    if ( argv[0] == ID2SYM(rb_intern("%") ) ) {
      Data_Get_Struct(argv[1], CArray, ct);
    }
    else {
      Data_Get_Struct(argv[0], CArray, ct);
    }
    if ( ct->ndim < ca->ndim ) {
      rb_raise(rb_eRuntimeError, "invalid ndim to template");
    }
    args = rb_ary_new();
    ndim = 0;
    if ( argv[0] == ID2SYM(rb_intern("%") ) ) {
      k = 0;
      for (i=0; i<ct->ndim; i++) {
        if ( ca->dim[k] == 1 ) {
          rb_ary_push(args, SIZE2NUM(ct->dim[i]));
          k++;
        }
        else if ( ct->dim[i] == ca->dim[k] ) {
          rb_ary_push(args, ID2SYM(rb_intern("%")));
          dim[ndim] = ca->dim[k];
          k++; ndim++;
        }
        else {
          rb_ary_push(args, SIZE2NUM(ct->dim[i]));
        }
      }
      if ( ndim != ca->ndim ) {
        self = rb_ca_refer_new(self, ca->data_type, ndim, dim, ca->bytes, 0);
      }
    }
    else {
      k = ca->ndim - 1;
      for (i=ct->ndim-1; i>=0; i--) {
        if ( ca->dim[k] == 1 ) {
          rb_ary_unshift(args, SIZE2NUM(ct->dim[i]));
          k--;
        }
        else if ( ct->dim[i] == ca->dim[k] ) {
          rb_ary_unshift(args, ID2SYM(rb_intern("%")));
          k--;
        }
        else {
          rb_ary_unshift(args, SIZE2NUM(ct->dim[i]));
        }
      }
      if ( k != 0 ) {
        ndim = 0;
        for (i=0; i<ca->ndim; i++) {
          if ( ca->dim[i] != 1 ) {
            dim[ndim] = ca->dim[i];
            ndim++;
          }
        }
        self = rb_ca_refer_new(self, ca->data_type, ndim, dim, ca->bytes, 0);
      }
    }
    return rb_ca_repeat((int)RARRAY_LEN(args), RARRAY_PTR(args), self);
  }

  repeat = 1;
  for (i=0; i<argc; i++) {
    if ( rb_obj_is_kind_of(argv[i], rb_cSymbol) ) {
      if ( argv[i] == ID2SYM(rb_intern("%")) ) {
        count[i] = 0;
      }
      else {
        rb_raise(rb_eArgError, "unknown symbol (!= ':%%') in arguments");
      }
    }
    else {
      count[i] = NUM2SIZE(argv[i]);
      if ( count[i] == 0 ) {
        rb_raise(rb_eArgError,
                 "zero repeat count specified in creating CARepeat object");
      }
      repeat *= count[i];
    }
  }

  if ( repeat == 1 ) {
    ca_size_t dim[CA_RANK_MAX];
    int8_t j = 0;
    for (i=0; i<argc; i++) {
      if ( count[i] == 0 ) {
        dim[i] = ca->dim[j];
        j++;
      }
      else {
        dim[i] = 1;
      }
    }
    obj = rb_ca_refer_new(self, ca->data_type, argc, dim, ca->bytes, 0);
  }
  else {
    obj = rb_ca_repeat_new(self, argc, count);
  }

  return obj;
}

static VALUE
rb_ca_repeat_s_allocate (VALUE klass)
{
  CARepeat *ca;
  return Data_Make_Struct(klass, CARepeat, ca_mark, ca_free, ca);
}

static VALUE
rb_ca_repeat_initialize_copy (VALUE self, VALUE other)
{
  CARepeat *ca, *cs;

  Data_Get_Struct(self,  CARepeat, ca);
  Data_Get_Struct(other, CARepeat, cs);

  ca_repeat_setup(ca, cs->parent, cs->ndim, cs->count);

  return self;
}

void
Init_ca_obj_repeat ()
{
  /* rb_cCARepeat, CA_OBJ_REPEAT are defined in rb_carray.c */

  rb_define_const(rb_cObject, "CA_OBJ_REPEAT", INT2NUM(CA_OBJ_REPEAT));

  rb_define_alloc_func(rb_cCARepeat, rb_ca_repeat_s_allocate);
  rb_define_method(rb_cCARepeat, "initialize_copy",
                                      rb_ca_repeat_initialize_copy, 1);
}
