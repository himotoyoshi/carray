/* ---------------------------------------------------------------------------

  ca_obj_farray.c

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
  /* --------------- */
  ca_size_t   step;
} CAFarray;

static int8_t CA_OBJ_FARRAY;

static VALUE rb_cCAFarray;

/* yard:
  class CAFArray < CAVirtual # :nodoc:
  end
*/

/* ------------------------------------------------------------------- */

int
ca_farray_setup (CAFarray *ca, CArray *parent)
{
  int8_t ndim, data_type;
  ca_size_t *dim, elements, bytes;
  int i;

  /* check arguments */

  data_type = parent->data_type;
  ndim      = parent->ndim;
  dim       = parent->dim;
  bytes     = parent->bytes;
  elements  = parent->elements;

  ca->obj_type  = CA_OBJ_FARRAY;
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

  for (i=0; i<ndim; i++) {
    ca->dim[i] = dim[ndim-1-i];
  }

  ca->step = 1;
  for (i=1; i<ndim; i++) {
    ca->step *= dim[i];
  }

  if ( ca_has_mask(parent) ) {
    ca_create_mask(ca);
  }

  if ( ca_is_scalar(parent) ) {
    ca_set_flag(ca, CA_FLAG_SCALAR);
  }

  return 0;
}

CAFarray *
ca_farray_new (CArray *parent)
{
  CAFarray *ca = ALLOC(CAFarray);
  ca_farray_setup(ca, parent);
  return ca;
}

static void
free_ca_farray (void *ap)
{
  CAFarray *ca = (CAFarray *) ap;
  if ( ca != NULL ) {
    ca_free(ca->mask);
    xfree(ca->dim);
    xfree(ca);
  }
}

/* ------------------------------------------------------------------- */

static void *
ca_farray_func_clone (void *ap)
{
  CAFarray *ca = (CAFarray *) ap;
  return ca_farray_new(ca->parent);
}

#define ca_farray_func_ptr_at_addr  ca_array_func_ptr_at_addr
#define ca_farray_func_ptr_at_index ca_array_func_ptr_at_index

static void
ca_farray_func_fetch_index (void *ap, ca_size_t *idx, void *ptr)
{
  CAFarray *ca = (CAFarray *) ap;
  int8_t  ndim = ca->ndim;
  ca_size_t idx0[CA_RANK_MAX];
  int i;
  for (i=0; i<ndim; i++) {
    idx0[i] = idx[ndim-1-i];
  }
  ca_fetch_index(ca->parent, idx0, ptr);
}

static void
ca_farray_func_store_index (void *ap, ca_size_t *idx, void *ptr)
{
  CAFarray *ca = (CAFarray *) ap;
  int8_t  ndim = ca->ndim;
  ca_size_t idx0[CA_RANK_MAX];
  int i;
  for (i=0; i<ndim; i++) {
    idx0[i] = idx[ndim-1-i];
  }
  ca_store_index(ca->parent, idx0, ptr);
}

static void
ca_farray_func_allocate (void *ap)
{
  CAFarray *ca = (CAFarray *) ap;
  ca_attach(ca->parent);
  /* ca->ptr = ALLOC_N(char, ca_length(ca)); */
  ca->ptr = malloc_with_check(ca_length(ca));  
}

static void ca_fa_attach (CAFarray *ca);
static void ca_fa_sync (CAFarray *ca);

static void
ca_farray_func_attach (void *ap)
{
  CAFarray *ca = (CAFarray *) ap;
  ca_attach(ca->parent);
  /* ca->ptr = ALLOC_N(char, ca_length(ca)); */
  ca->ptr = malloc_with_check(ca_length(ca));  
  ca_fa_attach(ca);
}

static void
ca_farray_func_sync (void *ap)
{
  CAFarray *ca = (CAFarray *) ap;
  ca_fa_sync(ca);
  ca_sync(ca->parent);
}

static void
ca_farray_func_detach (void *ap)
{
  CAFarray *ca = (CAFarray *) ap;
  free(ca->ptr);
  ca->ptr = NULL;
  ca_detach(ca->parent);
}

static void
ca_farray_func_copy_data (void *ap, void *ptr)
{
  CAFarray *ca = (CAFarray *) ap;
  char *ptr0 = ca->ptr;
  ca_attach(ca->parent);
  ca->ptr = ptr;
  ca_fa_attach(ca);
  ca->ptr = ptr0;
  ca_detach(ca->parent);
}

static void
ca_farray_func_sync_data (void *ap, void *ptr)
{
  CAFarray *ca = (CAFarray *) ap;
  char *ptr0 = ca->ptr;
  ca_attach(ca->parent);
  ca->ptr = ptr;
  ca_fa_sync(ca);
  ca->ptr = ptr0;
  ca_sync(ca->parent);
  ca_detach(ca->parent);
}

static void
ca_farray_func_fill_data (void *ap, void *ptr)
{
  CAFarray *ca = (CAFarray *) ap;
  ca_fill(ca->parent, ptr);
}

static void
ca_farray_func_create_mask (void *ap)
{
  CAFarray *ca = (CAFarray *) ap;
  ca_update_mask(ca->parent);
  if ( ! ca->parent->mask ) {
    ca_create_mask(ca->parent);
  }
  ca->mask = (CArray *) ca_farray_new(ca->parent->mask);
}

ca_operation_function_t ca_farray_func = {
  -1, /* CA_OBJ_FARRAY */
  CA_VIRTUAL_ARRAY,
  free_ca_farray,
  ca_farray_func_clone,
  ca_farray_func_ptr_at_addr,
  ca_farray_func_ptr_at_index,
  NULL,
  ca_farray_func_fetch_index,
  NULL,
  ca_farray_func_store_index,
  ca_farray_func_allocate,
  ca_farray_func_attach,
  ca_farray_func_sync,
  ca_farray_func_detach,
  ca_farray_func_copy_data,
  ca_farray_func_sync_data,
  ca_farray_func_fill_data,
  ca_farray_func_create_mask,
};

/* ------------------------------------------------------------------- */


static void
ca_fa_attach_loop (CAFarray *ca, int8_t level, ca_size_t *idx, ca_size_t *idx0)
{
  ca_size_t step = ca->step;
  ca_size_t dim = ca->dim[level];
  ca_size_t i;
  if ( level == ca->ndim - 1 ) {
    idx[level] = 0;
    idx0[0]    = 0;
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
          q += step * ca->bytes;
        }
      }
    }
  }
  else {
    int level0 = ca->ndim - 1 - level;
    for (i=0; i<dim; i++) {
      idx[level]  = i;
      idx0[level0] = i;
      ca_fa_attach_loop(ca, level+1, idx, idx0);
    }
  }
}

static void
ca_fa_attach (CAFarray *ca)
{
  ca_size_t idx[CA_RANK_MAX];
  ca_size_t idx0[CA_RANK_MAX];
  ca_fa_attach_loop(ca, 0, idx, idx0);
}

static void
ca_fa_sync_loop (CAFarray *ca, int8_t level, ca_size_t *idx, ca_size_t *idx0)
{
  ca_size_t step = ca->step;
  ca_size_t dim  = ca->dim[level];
  ca_size_t i;

  if ( level == ca->ndim - 1 ) {
    idx[level] = 0;
    idx0[0] = 0;
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
          q += step * ca->bytes;
        }
      }
    }
  }
  else {
    for (i=0; i<dim; i++) {
      idx[level]  = i;
      idx0[ca->ndim - 1 - level] = i;
      ca_fa_sync_loop(ca, level+1, idx, idx0);
    }
  }
}

static void
ca_fa_sync (CAFarray *ca)
{
  ca_size_t idx[CA_RANK_MAX];
  ca_size_t idx0[CA_RANK_MAX];
  ca_fa_sync_loop(ca, 0, idx, idx0);
}

/* ------------------------------------------------------------------- */

VALUE
rb_ca_farray_new (VALUE cary)
{
  volatile VALUE obj;
  CArray *parent;
  CAFarray *ca;
  rb_check_carray_object(cary);
  Data_Get_Struct(cary, CArray, parent);
  ca  = ca_farray_new(parent);
  obj = ca_wrap_struct(ca);
  rb_ca_set_parent(obj, cary);
  rb_ca_data_type_inherit(obj, cary);
  return obj;
}

/* yard:
  class CArray
    # create the virtual transposed array which dimension order is reversed.
    def t
    end
  end
*/

VALUE
rb_ca_farray (VALUE self)
{
  return rb_ca_farray_new(self);
}

static VALUE
rb_ca_farray_s_allocate (VALUE klass)
{
  CAFarray *ca;
  return Data_Make_Struct(klass, CAFarray, ca_mark, ca_free, ca);
}

static VALUE
rb_ca_farray_initialize_copy (VALUE self, VALUE other)
{
  CAFarray *ca, *cs;

  Data_Get_Struct(self,  CAFarray, ca);
  Data_Get_Struct(other, CAFarray, cs);

  ca_farray_setup(ca, cs->parent);

  return self;
}

void
Init_ca_obj_farray ()
{
  rb_cCAFarray = rb_define_class("CAFarray", rb_cCAVirtual);

  CA_OBJ_FARRAY = ca_install_obj_type(rb_cCAFarray, ca_farray_func);
  rb_define_const(rb_cObject, "CA_OBJ_FARRAY", INT2NUM(CA_OBJ_FARRAY));

  rb_define_method(rb_cCArray, "farray", rb_ca_farray, 0);
  rb_define_method(rb_cCArray, "t", rb_ca_farray, 0);

  rb_define_alloc_func(rb_cCAFarray, rb_ca_farray_s_allocate);
  rb_define_method(rb_cCAFarray, "initialize_copy",
                                      rb_ca_farray_initialize_copy, 1);
}


