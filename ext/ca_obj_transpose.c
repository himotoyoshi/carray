/* ---------------------------------------------------------------------------

  ca_obj_transpose.c

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
  ca_size_t  *imap;
  ca_size_t   step;
} CATrans;

static int8_t CA_OBJ_TRANSPOSE;

static VALUE rb_cCATrans;

/* yard:
  class CATranspose < CAVirtual # :nodoc:
  end
*/

/* ------------------------------------------------------------------- */

int
ca_trans_setup (CATrans *ca, CArray *parent, ca_size_t *imap)
{
  int8_t data_type, ndim;
  ca_size_t bytes, elements;
  ca_size_t *dim0;
  ca_size_t newdim[CA_RANK_MAX];
  ca_size_t map[CA_RANK_MAX];
  int8_t i;
  ca_size_t idim, step;

  data_type = parent->data_type;
  bytes     = parent->bytes;
  ndim      = parent->ndim;
  elements  = parent->elements;
  dim0      = parent->dim;

  for (i=0; i<ndim; i++) {
    map[i] = -1;
  }

  for (i=0; i<ndim; i++) {
    idim = imap[i];
    if ( idim < 0 || idim >= ndim ) {
      rb_raise(rb_eRuntimeError,
               "specified %i-th dimension number out of range", i);
    }

    if ( map[idim] != -1 ) {
      rb_raise(rb_eRuntimeError,
               "specified %i-th dimension number is duplicated", i);
    }
    map[idim] = i;
    newdim[i] = dim0[idim];
  }

  step = 1;
  for (i=imap[ndim-1]+1; i<ndim; i++) {
    step *= dim0[i];
  }

  ca->obj_type  = CA_OBJ_TRANSPOSE;
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
  ca->imap      = ALLOC_N(ca_size_t, ndim);
  ca->step      = step;

  memcpy(ca->dim,  newdim, ndim * sizeof(ca_size_t));
  memcpy(ca->imap, imap,   ndim * sizeof(ca_size_t));

  if ( ca_has_mask(parent) ) {
    ca_create_mask(ca);
  }

  return 0;
}

CATrans *
ca_trans_new (CArray *parent, ca_size_t *imap)
{
  CATrans *ca = ALLOC(CATrans);
  ca_trans_setup(ca, parent, imap);
  return ca;
}

static void
free_ca_trans (void *ap)
{
  CATrans *ca = (CATrans *) ap;
  if ( ca != NULL ) {
    xfree(ca->imap);
    ca_free(ca->mask);
    xfree(ca->dim);
    xfree(ca);
  }
}

static void ca_trans_attach (CATrans *cb);
static void ca_trans_sync (CATrans *cb);
static void ca_trans_fill (CATrans *ca, char *ptr);


/* ------------------------------------------------------------------- */

static void *
ca_trans_func_clone (void *ap)
{
  CATrans *ca = (CATrans *) ap;
  return ca_trans_new(ca->parent, ca->imap);
}

static char *
ca_trans_func_ptr_at_addr (void *ap, ca_size_t addr)
{
  CATrans *ca = (CATrans *) ap;
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
ca_trans_func_ptr_at_index (void *ap, ca_size_t *idx)
{
  CATrans *ca = (CATrans *) ap;
  if ( ca->ptr ) {
    return ca_array_func_ptr_at_index(ca, idx);
  }
  else {
    ca_size_t *imap = ca->imap;
    ca_size_t idx0[CA_RANK_MAX];
    int8_t i;
    for (i=0; i<ca->ndim; i++) {
      idx0[imap[i]] = idx[i];
    }
    return ca_ptr_at_index(ca->parent, idx0);
  }
}

static void
ca_trans_func_fetch_index (void *ap, ca_size_t *idx, void *ptr)
{
  CATrans *ca = (CATrans *) ap;
  ca_size_t *imap = ca->imap;
  ca_size_t idx0[CA_RANK_MAX];
  int8_t i;
  for (i=0; i<ca->ndim; i++) {
    idx0[imap[i]] = idx[i];
  }
  ca_fetch_index(ca->parent, idx0, ptr);
}

static void
ca_trans_func_store_index (void *ap, ca_size_t *idx, void *ptr)
{
  CATrans *ca = (CATrans *) ap;
  ca_size_t *imap = ca->imap;
  ca_size_t idx0[CA_RANK_MAX];
  int8_t i;
  for (i=0; i<ca->ndim; i++) {
    idx0[imap[i]] = idx[i];
  }
  ca_store_index(ca->parent, idx0, ptr);
}

static void
ca_trans_func_allocate (void *ap)
{
  CATrans *ca = (CATrans *) ap;
  ca_attach(ca->parent);
  /* ca->ptr = ALLOC_N(char, ca_length(ca)); */
  ca->ptr = malloc_with_check(ca_length(ca));  
}

static void
ca_trans_func_attach (void *ap)
{
  CATrans *ca = (CATrans *) ap;
  ca_attach(ca->parent);
  /* ca->ptr = ALLOC_N(char, ca_length(ca)); */
  ca->ptr = malloc_with_check(ca_length(ca));  
  ca_trans_attach(ca);
}

static void
ca_trans_func_sync (void *ap)
{
  CATrans *ca = (CATrans *) ap;
  ca_trans_sync(ca);
  ca_sync(ca->parent);
}

static void
ca_trans_func_detach (void *ap)
{
  CATrans *ca = (CATrans *) ap;
  free(ca->ptr);
  ca->ptr = NULL;
  ca_detach(ca->parent);
}

static void
ca_trans_func_copy_data (void *ap, void *ptr)
{
  CATrans *ca = (CATrans *) ap;
  char *ptr0 = ca->ptr;
  ca_attach(ca->parent);
  ca->ptr = ptr;
  ca_trans_attach(ca);
  ca->ptr = ptr0;
  ca_detach(ca->parent);
}

static void
ca_trans_func_sync_data (void *ap, void *ptr)
{
  CATrans *ca = (CATrans *) ap;
  char *ptr0 = ca->ptr;
  ca_attach(ca->parent);
  ca->ptr = ptr;
  ca_trans_sync(ca);
  ca->ptr = ptr0;
  ca_sync(ca->parent);
  ca_detach(ca->parent);
}

static void
ca_trans_func_fill_data (void *ap, void *ptr)
{
  CATrans *ca = (CATrans *) ap;
  ca_attach(ca->parent);
  ca_trans_fill(ca, ptr);
  ca_sync(ca->parent);
  ca_detach(ca->parent);
}

static void
ca_trans_func_create_mask (void *ap)
{
  CATrans *ca = (CATrans *) ap;
  ca_create_mask(ca->parent);
  ca->mask =
    (CArray *) ca_trans_new(ca->parent->mask, ca->imap);
}

ca_operation_function_t ca_trans_func = {
  -1, /* CA_OBJ_TRANSPOSE */
  CA_VIRTUAL_ARRAY,
  free_ca_trans,
  ca_trans_func_clone,
  ca_trans_func_ptr_at_addr,
  ca_trans_func_ptr_at_index,
  NULL,
  ca_trans_func_fetch_index,
  NULL,
  ca_trans_func_store_index,
  ca_trans_func_allocate,
  ca_trans_func_attach,
  ca_trans_func_sync,
  ca_trans_func_detach,
  ca_trans_func_copy_data,
  ca_trans_func_sync_data,
  ca_trans_func_fill_data,
  ca_trans_func_create_mask,
};

/* ------------------------------------------------------------------- */

static void
ca_trans_attach_loop (CATrans *ca, int8_t level, ca_size_t *idx, ca_size_t *idx0)
{
  ca_size_t step = ca->step;
  ca_size_t dim = ca->dim[level];
  ca_size_t *imap = ca->imap;
  ca_size_t i;

  if ( level == ca->ndim - 1 ) {
    idx[level] = 0;
    idx0[imap[level]] = 0;
    switch ( ca->bytes ) {
    case 1:
      {
        int8_t *p = ca_ptr_at_index(ca, idx);
        int8_t *q = ca_ptr_at_index(ca->parent, idx0);
        for (i=0; i<dim; i++) {
          *p++ = *q;
          q += step;
        }
      }
      break;
    case 2:
      {
        int16_t *p = ca_ptr_at_index(ca, idx);
        int16_t *q = ca_ptr_at_index(ca->parent, idx0);
        for (i=0; i<dim; i++) {
          *p++ = *q;
          q += step;
        }
      }
      break;
    case 4:
      {
        int32_t *p = ca_ptr_at_index(ca, idx);
        int32_t *q = ca_ptr_at_index(ca->parent, idx0);
        for (i=0; i<dim; i++) {
          *p++ = *q;
          q += step;
        }
      }
      break;
    case 8:
      {
        float64_t *p = ca_ptr_at_index(ca, idx);
        float64_t *q = ca_ptr_at_index(ca->parent, idx0);
        for (i=0; i<dim; i++) {
          *p++ = *q;
          q += step;
        }
      }
      break;
    default:
      {
        char *p = ca_ptr_at_index(ca, idx);
        char *q = ca_ptr_at_index(ca->parent, idx0);
        for (i=0; i<dim; i++) {
          memcpy(p, q, ca->bytes);
          p += ca->bytes;
          q += ca->bytes*step;
        }
      }
    }
  }
  else {
    for (i=0; i<dim; i++) {
      idx[level]  = i;
      idx0[imap[level]] = i;
      ca_trans_attach_loop(ca, level+1, idx, idx0);
    }
  }
}

static void
ca_trans_attach (CATrans *ca)
{
  ca_size_t idx[CA_RANK_MAX];
  ca_size_t idx0[CA_RANK_MAX];
  ca_trans_attach_loop(ca, 0, idx, idx0);
}

static void
ca_trans_sync_loop (CATrans *ca, int8_t level, ca_size_t *idx, ca_size_t *idx0)
{
  ca_size_t step = ca->step;
  ca_size_t dim = ca->dim[level];
  ca_size_t *imap = ca->imap;
  ca_size_t i;

  if ( level == ca->ndim - 1 ) {
    idx[level] = 0;
    idx0[imap[level]] = 0;
    switch ( ca->bytes ) {
    case 1:
      {
        int8_t *p = ca_ptr_at_index(ca, idx);
        int8_t *q = ca_ptr_at_index(ca->parent, idx0);
        for (i=0; i<dim; i++) {
          *q = *p++;
          q += step;
        }
      }
      break;
    case 2:
      {
        int16_t *p = ca_ptr_at_index(ca, idx);
        int16_t *q = ca_ptr_at_index(ca->parent, idx0);
        for (i=0; i<dim; i++) {
          *q = *p++;
          q += step;
        }
      }
      break;
    case 4:
      {
        int32_t *p = ca_ptr_at_index(ca, idx);
        int32_t *q = ca_ptr_at_index(ca->parent, idx0);
        for (i=0; i<dim; i++) {
          *q = *p++;
          q += step;
        }
      }
      break;
    case 8:
      {
        float64_t *p = ca_ptr_at_index(ca, idx);
        float64_t *q = ca_ptr_at_index(ca->parent, idx0);
        for (i=0; i<dim; i++) {
          *q = *p++;
          q += step;
        }
      }
      break;
    default:
      {
        char *p = ca_ptr_at_index(ca, idx);
        char *q = ca_ptr_at_index(ca->parent, idx0);
        for (i=0; i<dim; i++) {
          memcpy(q, p, ca->bytes);
          p += ca->bytes;
          q += ca->bytes * step;
        }
      }
    }
  }
  else {
    for (i=0; i<dim; i++) {
      idx[level] = i;
      idx0[imap[level]] = i;
      ca_trans_sync_loop(ca, level+1, idx, idx0);
    }
  }
}

static void
ca_trans_sync (CATrans *ca)
{
  ca_size_t idx[CA_RANK_MAX];
  ca_size_t idx0[CA_RANK_MAX];
  ca_trans_sync_loop(ca, 0, idx, idx0);
}

/*
static void
ca_trans_fill_loop (CATrans *ca, char *ptr,
                   int8_t level, ca_size_t *idx0)
{
  ca_size_t *imap = ca->imap;
  ca_size_t i;

  if ( level == ca->ndim - 1 ) {
    for (i=0; i<ca->dim[level]; i++) {
      idx0[imap[level]] = i;
      memcpy(ca_ptr_at_index(ca->parent, idx0), ptr, ca->bytes);
    }
  }
  else {
    for (i=0; i<ca->dim[level]; i++) {
      idx0[imap[level]] = i;
      ca_trans_fill_loop(ca, ptr, level+1, idx0);
    }
  }
}
*/

static void
ca_trans_fill (CATrans *ca, char *ptr)
{
  ca_fill(ca->parent, ptr);
}

/* ------------------------------------------------------------------- */

VALUE
rb_ca_trans_new (VALUE cary, ca_size_t *imap)
{
  volatile VALUE obj;
  CArray *parent;
  CATrans *ca;
  rb_check_carray_object(cary);
  Data_Get_Struct(cary, CArray, parent);
  ca = ca_trans_new(parent, imap);
  obj = ca_wrap_struct(ca);
  rb_ca_set_parent(obj, cary);
  rb_ca_data_type_inherit(obj, cary);
  return obj;
}

/* yard:
  class CArray
    def transposed
    end
  end
*/

static VALUE
rb_ca_trans (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE obj;
  CArray *ca;
  ca_size_t imap[CA_RANK_MAX];
  int8_t i;

  Data_Get_Struct(self, CArray, ca);

  if ( argc == 0 ) {
    for (i=0; i<ca->ndim; i++) {
      imap[i] = ca->ndim - i - 1;
    }
  }
  else if ( argc == ca->ndim ) {
    for (i=0; i<ca->ndim; i++) {
      imap[i] = NUM2SIZE(argv[i]);
    }
  }
  else {
    rb_raise(rb_eArgError, "# of arguments should be equal to ndim");
  }

  obj = rb_ca_trans_new(self, imap);

  return obj;
}

static VALUE
rb_ca_trans_s_allocate (VALUE klass)
{
  CATrans *ca;
  return Data_Make_Struct(klass, CATrans, ca_mark, ca_free, ca);
}

static VALUE
rb_ca_trans_initialize_copy (VALUE self, VALUE other)
{
  CATrans *ca, *cs;

  Data_Get_Struct(self,  CATrans, ca);
  Data_Get_Struct(other, CATrans, cs);

  ca_trans_setup(ca, cs->parent, cs->imap);

  return self;
}

void
Init_ca_obj_transpose ()
{
  rb_cCATrans = rb_define_class("CATranspose", rb_cCAVirtual);

  CA_OBJ_TRANSPOSE = ca_install_obj_type(rb_cCATrans, ca_trans_func);
  rb_define_const(rb_cObject, "CA_OBJ_TRANSPOSE", INT2NUM(CA_OBJ_TRANSPOSE));

  rb_define_method(rb_cCArray, "transposed", rb_ca_trans, -1);

  rb_define_alloc_func(rb_cCATrans, rb_ca_trans_s_allocate);
  rb_define_method(rb_cCATrans, "initialize_copy",
                                      rb_ca_trans_initialize_copy, 1);
}
