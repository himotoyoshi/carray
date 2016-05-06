/* ---------------------------------------------------------------------------

  ca_obj_field.c

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
  /* -------------*/
  int32_t   offset;
} CAField;

static int8_t CA_OBJ_FIELD;

static VALUE rb_cCAField;

/* rdoc:
  class CAField < CAVirtual # :nodoc:
  end
*/

/* ------------------------------------------------------------------- */

int
ca_field_setup (CAField *ca, CArray *parent,
                int32_t offset, int8_t data_type, int32_t bytes)
{
  int8_t rank;
  int32_t elements;

  /* check arguments */

  CA_CHECK_DATA_TYPE(data_type);
  CA_CHECK_BYTES(data_type, bytes);
  if ( offset < 0 ) {
    rb_raise(rb_eRuntimeError, "negative offset");
  }

  if ( data_type == CA_OBJECT ) {
    rb_raise(rb_eCADataTypeError,
            "CA_OBJECT can not to be a data_type for CAField");
  }

  if ( parent->bytes < offset + bytes ) {
    rb_raise(rb_eRuntimeError, "offset or bytes out of range");
  }

  rank     = parent->rank;
  elements = parent->elements;

  ca->obj_type  = CA_OBJ_FIELD;
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
  ca->offset    = offset;

  memcpy(ca->dim, parent->dim, rank * sizeof(int32_t));

  if ( ca_has_mask(parent) ) {
    ca_create_mask(ca);
  }

  if ( ca_is_scalar(parent) ) {
    ca_set_flag(ca, CA_FLAG_SCALAR);
  }

  return 0;
}

CAField *
ca_field_new (CArray *parent, int32_t offset, int8_t data_type, int32_t bytes)
{
  CAField *ca = ALLOC(CAField);
  ca_field_setup(ca, parent, offset, data_type, bytes);
  return ca;
}

static void
free_ca_field (void *ap)
{
  CAField *ca = (CAField *) ap;
  if ( ca != NULL ) {
    ca_free(ca->mask);
    xfree(ca->dim);
    xfree(ca);
  }
}

static void ca_field_attach (CAField *ca);
static void ca_field_sync (CAField *ca);
static void ca_field_fill (CAField *ca, char *ptr);

/* ------------------------------------------------------------------- */

static void *
ca_field_func_clone (void *ap)
{
  CAField *ca = (CAField *) ap;
  return ca_field_new(ca->parent, ca->offset, ca->data_type, ca->bytes);
}

static char *
ca_field_func_ptr_at_addr (void *ap, int32_t addr)
{
  CAField *ca = (CAField *) ap;
  if ( ! ca->ptr ) {
    int32_t idx[CA_RANK_MAX];
    ca_addr2index((CArray *)ca, addr, idx);
    return ca_ptr_at_index(ca, idx);
  }
  else {
    return ca->ptr + ca->bytes * addr;
  }
}

static char *
ca_field_func_ptr_at_index (void *ap, int32_t *idx)
{
  CAField *ca = (CAField *) ap;
  if ( ! ca->ptr ) {
    int32_t *dim    = ca->dim;
    int32_t i, n;
    n = idx[0];                  /* n = idx[0]*dim[1]*dim[2]*...*dim[rank-1] */
    for (i=1; i<ca->rank; i++) { /*    + idx[1]*dim[1]*dim[2]*...*dim[rank-1] */
      n = dim[i]*n+idx[i];       /*    ... + idx[rank-2]*dim[1] + idx[rank-1] */
    }

    if ( ca->parent->ptr == NULL ) {
      return ca_ptr_at_addr(ca->parent, n) + ca->offset;
    }
    else {
      return ca->parent->ptr + ca->parent->bytes * n + ca->offset;
    }
  }
  else {
    return ca_func[CA_OBJ_ARRAY].ptr_at_index(ca, idx);
  }
}

static void
ca_field_func_fetch_index (void *ap, int32_t *idx, void *ptr)
{
  CAField *ca = (CAField *) ap;
  if ( ca->parent->bytes <= 32 ) {
    char v[32];
    ca_fetch_index(ca->parent, idx, v);
    memcpy(ptr, v + ca->offset, ca->bytes);
  }
  else {
    char *v = malloc_with_check(ca->parent->bytes);
    ca_fetch_index(ca->parent, idx, v);
    memcpy(ptr, v + ca->offset, ca->bytes);
    free(v);
  }
}

static void
ca_field_func_store_index (void *ap, int32_t *idx, void *ptr)
{
  CAField *ca = (CAField *) ap;
  if ( ca->parent->bytes <= 32 ) {
    char v[32];
    ca_fetch_index(ca->parent, idx, v);
    memcpy(v + ca->offset, ptr, ca->bytes);
    ca_store_index(ca->parent, idx, v);
  }
  else {
    char *v = malloc_with_check(ca->parent->bytes);
    ca_fetch_index(ca->parent, idx, v);
    memcpy(v + ca->offset, ptr, ca->bytes);
    ca_store_index(ca->parent, idx, v);
    free(v);
  }
}

static void
ca_field_func_allocate (void *ap)
{
  CAField *ca = (CAField *) ap;
  ca_attach(ca->parent);
  /* ca->ptr = ALLOC_N(char, ca_length(ca)); */
  ca->ptr = malloc_with_check(ca_length(ca));  
}

static void
ca_field_func_attach (void *ap)
{
  void ca_field_attach (CAField *cb);

  CAField *ca = (CAField *) ap;
  ca_attach(ca->parent);
  /* ca->ptr = ALLOC_N(char, ca_length(ca)); */
  ca->ptr = malloc_with_check(ca_length(ca));  
  ca_field_attach(ca);
}

static void
ca_field_func_sync (void *ap)
{
  CAField *ca = (CAField *) ap;
  ca_field_sync(ca);
  ca_sync(ca->parent);
}

static void
ca_field_func_detach (void *ap)
{
  CAField *ca = (CAField *) ap;
  free(ca->ptr);
  ca->ptr = NULL;
  ca_detach(ca->parent);
}

static void
ca_field_func_copy_data (void *ap, void *ptr)
{
  CAField *ca = (CAField *) ap;
  char *ptr0 = ca->ptr;
  ca_attach(ca->parent);
  ca->ptr = ptr;
  ca_field_attach(ca);
  ca->ptr = ptr0;
  ca_detach(ca->parent);
}

static void
ca_field_func_sync_data (void *ap, void *ptr)
{
  CAField *ca = (CAField *) ap;
  char *ptr0 = ca->ptr;
  ca_attach(ca->parent);
  ca->ptr = ptr;
  ca_field_sync(ca);
  ca->ptr = ptr0;
  ca_sync(ca->parent);
  ca_detach(ca->parent);
}

static void
ca_field_func_fill_data (void *ap, void *ptr)
{
  CAField *ca = (CAField *) ap;
  ca_attach(ca->parent);
  ca_field_fill(ca, ptr);
  ca_sync(ca->parent);
  ca_detach(ca->parent);
}

static void
ca_field_func_create_mask (void *ap)
{
  CAField *ca = (CAField *) ap;
  ca_update_mask(ca->parent);
  if ( ! ca->parent->mask ) {
    ca_create_mask(ca->parent);
  }
  ca->mask =
    (CArray *) ca_refer_new(ca->parent->mask,
                            CA_BOOLEAN, ca->rank, ca->dim, 0, 0);
}

ca_operation_function_t ca_field_func = {
  -1, /* CA_OBJ_FIELD */
  CA_VIRTUAL_ARRAY,
  free_ca_field,
  ca_field_func_clone,
  ca_field_func_ptr_at_addr,
  ca_field_func_ptr_at_index,
  NULL,
  ca_field_func_fetch_index,
  NULL,
  ca_field_func_store_index,
  ca_field_func_allocate,
  ca_field_func_attach,
  ca_field_func_sync,
  ca_field_func_detach,
  ca_field_func_copy_data,
  ca_field_func_sync_data,
  ca_field_func_fill_data,
  ca_field_func_create_mask,
};

/* ------------------------------------------------------------------- */

static void
ca_field_attach (CAField *ca)
{
  int32_t pbytes = ca->parent->bytes;
  int32_t bytes = ca->bytes;
  int32_t n = ca->elements;

  switch ( ca->data_type ) {
  case CA_BOOLEAN:
  case CA_INT8:
  case CA_UINT8:
    {
      char *p = ca_ptr_at_addr(ca, 0);
      char *q = ca_ptr_at_addr(ca->parent, 0) + ca->offset;
      while ( n-- ) {
        *p = *q;
        p += 1; q += pbytes;
      }
    }
    break;
  case CA_INT16:
  case CA_UINT16:
    {
      int16_t *p = (int16_t*) ca_ptr_at_addr(ca, 0);
      char *q = ca_ptr_at_addr(ca->parent, 0) + ca->offset;
      while ( n-- ) {
        *p = *(int16_t*) q;
        p += 1; q += pbytes;
      }
    }
    break;
  case CA_INT32:
  case CA_UINT32:
  case CA_FLOAT32:
    {
      int32_t *p = (int32_t*) ca_ptr_at_addr(ca, 0);
      char *q = ca_ptr_at_addr(ca->parent, 0) + ca->offset;
      while ( n-- ) {
        *p = *(int32_t*) q;
        p += 1; q += pbytes;
      }
    }
    break;
  case CA_INT64:
  case CA_UINT64:
  case CA_FLOAT64:
    {
      float64_t *p = (float64_t*) ca_ptr_at_addr(ca, 0);
      char *q = ca_ptr_at_addr(ca->parent, 0) + ca->offset;
      while ( n-- ) {
        *p = *(float64_t*) q;
        p += 1; q += pbytes;
      }
    }
    break;
  default:
    {
      char *p = ca_ptr_at_addr(ca, 0);
      char *q = ca_ptr_at_addr(ca->parent, 0) + ca->offset;
      while ( n-- ) {
        memcpy(p, q, ca->bytes);
        p += bytes; q += pbytes;
      }
    }
  }
}

static void
ca_field_sync (CAField *ca)
{
  int32_t pbytes = ca->parent->bytes;
  int32_t bytes = ca->bytes;
  int32_t n = ca->elements;

  switch ( ca->data_type ) {
  case CA_BOOLEAN:
  case CA_INT8:
  case CA_UINT8:
    {
      char *p = ca_ptr_at_addr(ca, 0);
      char *q = ca_ptr_at_addr(ca->parent, 0) + ca->offset;
      while ( n-- ) {
        *q = *p;
        p += 1; q += pbytes;
      }
    }
    break;
  case CA_INT16:
  case CA_UINT16:
    {
      int16_t *p = (int16_t*) ca_ptr_at_addr(ca, 0);
      char *q = ca_ptr_at_addr(ca->parent, 0) + ca->offset;
      while ( n-- ) {
        *(int16_t*) q = *p;
        p += 1; q += pbytes;
      }
    }
    break;
  case CA_INT32:
  case CA_UINT32:
  case CA_FLOAT32:
    {
      int32_t *p = (int32_t*) ca_ptr_at_addr(ca, 0);
      char *q = ca_ptr_at_addr(ca->parent, 0) + ca->offset;
      while ( n-- ) {
        *(int32_t*) q = *p;
        p += 1; q += pbytes;
      }
    }
    break;
  case CA_INT64:
  case CA_UINT64:
  case CA_FLOAT64:
    {
      float64_t *p = (float64_t*) ca_ptr_at_addr(ca, 0);
      char *q = ca_ptr_at_addr(ca->parent, 0) + ca->offset;
      while ( n-- ) {
        *(float64_t*) q = *p;
        p += 1; q += pbytes;
      }
    }
    break;
  default:
    {
      char *p = ca_ptr_at_addr(ca, 0);
      char *q = ca_ptr_at_addr(ca->parent, 0) + ca->offset;
      while ( n-- ) {
        memcpy(q, p, ca->bytes);
        p += bytes; q += pbytes;
      }
    }
  }
}

static void
ca_field_fill (CAField *ca, char *ptr)
{
  int32_t pbytes = ca->parent->bytes;
  int32_t n = ca->elements;
  char *q = ca_ptr_at_addr(ca->parent, 0) + ca->offset;

  switch ( ca->data_type ) {
  case CA_BOOLEAN:
  case CA_INT8:
  case CA_UINT8:
    {
      char *p = ptr;
      while ( n-- ) {
        *q = *p;
        q += pbytes;
      }
    }
    break;
  case CA_INT16:
  case CA_UINT16:
    {
      int16_t *p = (int16_t*) ptr;
      while ( n-- ) {
        *(int16_t*) q = *p;
        q += pbytes;
      }
    }
    break;
  case CA_INT32:
  case CA_UINT32:
  case CA_FLOAT32:
    {
      int32_t *p = (int32_t*) ptr;
      while ( n-- ) {
        *(int32_t*) q = *p;
        q += pbytes;
      }
    }
    break;
  case CA_INT64:
  case CA_UINT64:
  case CA_FLOAT64:
    {
      float64_t *p = (float64_t*) ptr;
      while ( n-- ) {
        *(float64_t*) q = *p;
        q += pbytes;
      }
    }
    break;
  default:
    {
      while ( n-- ) {
        memcpy(q, ptr, ca->bytes);
        q += pbytes;
      }
    }
  }

}

/* ------------------------------------------------------------------- */

VALUE
rb_ca_field_new (VALUE cary, int32_t offset, int8_t data_type, int32_t bytes)
{
  volatile VALUE obj;
  CArray *parent;
  CAField *ca;
  rb_check_carray_object(cary);
  Data_Get_Struct(cary, CArray, parent);
  ca = ca_field_new(parent, offset, data_type, bytes);
  obj = ca_wrap_struct(ca);
  rb_ca_set_parent(obj, cary);
  return obj;
}

static VALUE
rb_ca_field_s_allocate (VALUE klass)
{
  CAField *ca;
  return Data_Make_Struct(klass, CAField, ca_mark, ca_free, ca);
}

static VALUE
rb_ca_field_initialize_copy (VALUE self, VALUE other)
{
  CAField *ca, *cs;

  Data_Get_Struct(self,  CAField, ca);
  Data_Get_Struct(other, CAField, cs);

  ca_field_setup(ca, cs->parent, cs->offset, cs->data_type, cs->bytes);

  return self;
}

/* ----------------------------------------------------------------------- */

/* rdoc:
  class CArray
    # call-seq:
    #    CArray#field(offset, data_type[, :bytes=>bytes]) 
    #    CArray#field(offset, data_class) 
    #    CArray#field(offset, template)
    #
    def field (offset, data_type)
    end
  end
*/

VALUE
rb_ca_field (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE obj, voffset, rtype, ropt, rbytes = Qnil;
  CArray *ca;
  int8_t  data_type;
  int32_t offset, bytes;

  if ( argc == 1 ) {
    return rb_ca_field_as_member(self, argv[0]);
  }

  Data_Get_Struct(self, CArray, ca);

  /* CArray#field(offset, data_type[, :bytes=>bytes]) */
  /* CArray#field(offset, data_class) */
  /* CArray#field(offset, template) */

  rb_scan_args(argc, argv, "21", &voffset, &rtype, &ropt);
  rb_scan_options(ropt, "bytes", &rbytes);

  offset = NUM2INT(voffset);

  if ( rb_obj_is_carray(rtype) ) {
    CArray *ct;
    int32_t dim[CA_RANK_MAX];
    int8_t rank;
    int i, j;
    Data_Get_Struct(rtype, CArray, ct);
    data_type = CA_FIXLEN;
    bytes     = ct->bytes * ct->elements;
    obj = rb_ca_field_new(self, offset, data_type, bytes);
    rb_ca_data_type_inherit(obj, rtype);
    rank = ca->rank + ct->rank;
    for (i=0; i<ca->rank; i++) {
      dim[i] = ca->dim[i];
    }
    for (j=0; j<ct->rank; j++, i++) {
      dim[i] = ct->dim[j];
    }
    obj = rb_ca_refer_new(obj, ct->data_type, rank, dim, ct->bytes, 0);
  }
  else {
    rb_ca_guess_type_and_bytes(rtype, rbytes, &data_type, &bytes);
    obj = rb_ca_field_new(self, offset, data_type, bytes);
    rb_ca_data_type_import(obj, rtype);
  }

  return obj;
}


void
Init_ca_obj_field ()
{
  rb_cCAField = rb_define_class("CAField", rb_cCAVirtual);

  CA_OBJ_FIELD = ca_install_obj_type(rb_cCAField, ca_field_func);
  rb_define_const(rb_cObject, "CA_OBJ_FIELD", INT2NUM(CA_OBJ_FIELD));

  rb_define_method(rb_cCArray, "field", rb_ca_field, -1);

  rb_define_alloc_func(rb_cCAField, rb_ca_field_s_allocate);
  rb_define_method(rb_cCAField, "initialize_copy",
                                      rb_ca_field_initialize_copy, 1);
}

