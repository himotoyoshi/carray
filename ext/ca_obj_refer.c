/* ---------------------------------------------------------------------------

  ca_obj_refer.c

  This file is part of Ruby/CArray extension library.
  You can redistribute it and/or modify it under the terms of
  the Ruby Licence.

  Copyright (C) 2005 Hiroki Motoyoshi

---------------------------------------------------------------------------- */

#include "carray.h"

VALUE rb_cCARefer;

/* rdoc:
  class CARefer < CAVirtual # :nodoc:
  end
*/

static int
ca_refer_setup (CARefer *ca, CArray *parent,
                int8_t data_type, int8_t ndim, ca_size_t *dim, ca_size_t bytes,
                ca_size_t offset)
{
  ca_size_t elements, ratio;
  int8_t i;
  int     is_deformed;

  CA_CHECK_DATA_TYPE(data_type);
  CA_CHECK_RANK(ndim);
  CA_CHECK_DIM(ndim, dim);
  CA_CHECK_BYTES(data_type, bytes);

  if ( ca_is_object_type(parent) && data_type != CA_OBJECT ) {
    rb_raise(rb_eRuntimeError, "object carray can't be referred by other type");
  }

  if ( parent->elements && bytes > parent->bytes * parent->elements ) {
    rb_raise(rb_eRuntimeError, "byte size mismatch");
  }

  /* calc datanum and check deformation */
  is_deformed = ( ndim == parent->ndim ) ? 0 : 1;
  ratio = 1;
  elements = 1;
  for (i=0; i<ndim; i++) {
    elements *= dim[i];
    if ( dim[i] != parent->dim[i] ) {
      is_deformed |= 1;
    }
  }
  if ( bytes < parent->bytes ) {
    if ( parent->bytes % bytes != 0 ) {
      rb_raise(rb_eArgError, "invalid bytes");
    }
    is_deformed = -2;
    ratio = parent->bytes / bytes;
  }
  else if ( bytes > parent->bytes ) {
    if ( bytes % parent->bytes != 0 ) {
      rb_raise(rb_eArgError, "invalid bytes");
    }
    is_deformed = 2;
    ratio = bytes / parent->bytes;
  }

  if ( offset < 0 ) {
    rb_raise(rb_eRuntimeError, 
             "negative offset for CARefer");
  }

  if ( ( bytes * elements + parent->bytes * offset ) >
                                     ( parent->bytes * parent->elements ) ) {
    rb_raise(rb_eRuntimeError, "data size too large for CARefer");
  }

  ca->obj_type  = CA_OBJ_REFER;
  ca->data_type = data_type;
  ca->flags     = 0;
  ca->ndim      = ndim;
  ca->bytes     = bytes;
  ca->elements  = elements;
  ca->dim       = ALLOC_N(ca_size_t, ndim);
  ca->ptr       = NULL;
  ca->mask      = NULL;
  ca->mask0     = NULL;

  ca->parent    = parent;
  ca->attach    = 0;
  ca->nosync    = 0;

  ca->is_deformed = (int8_t) is_deformed;
  ca->ratio     = ratio;
  ca->offset    = offset;

  if ( ca->offset > 0 && ca->is_deformed == 0 ) {
    ca->is_deformed = 1;
  }

  memcpy(ca->dim, dim, ndim * sizeof(ca_size_t));

  if ( ca_is_scalar(parent) ) {
    ca_set_flag(ca, CA_FLAG_SCALAR);
  }

  return 0;
}

CARefer *
ca_refer_new (CArray *parent,
              int8_t data_type, int8_t ndim, ca_size_t *dim, ca_size_t bytes,
              ca_size_t offset)
{
  CARefer *ca = ALLOC(CARefer);
  ca_refer_setup(ca, parent, data_type, ndim, dim, bytes, offset);
  return ca;
}

static void
free_ca_refer (void *ap)
{
  CARefer *ca = (CARefer *) ap;
  if ( ca != NULL ) {
    xfree(ca->dim);
    ca_free(ca->mask);
    ca_free(ca->mask0);
    xfree(ca);
  }
}

/* ------------------------------------------------------------------- */

static void *
ca_refer_func_clone (void *ap)
{
  CARefer *ca = (CARefer *) ap;
  return ca_refer_new(ca->parent,
                      ca->data_type, ca->ndim, ca->dim, ca->bytes, ca->offset);
}

static char *
ca_refer_func_ptr_at_addr (void *ap, ca_size_t addr)
{
  CARefer *ca = (CARefer *) ap;
  ca_size_t major, minor;
  switch ( ca->is_deformed ) {
  case 0:
  case 1:
    return ca->ptr + ca->bytes * addr;
  case -2:
    major = (addr * ca->bytes) / ca->parent->bytes;
    minor = (addr * ca->bytes) % ca->parent->bytes;
    return ca->ptr + ca->bytes * addr + minor;
  case 2:
    return ca->ptr + ca->bytes * (addr * ca->ratio);
  default:
    rb_raise(rb_eRuntimeError, "[BUG]");
  }
}

static char *
ca_refer_func_ptr_at_index (void *ap, ca_size_t *idx)
{
  CARefer *ca  = (CARefer*) ap;
  ca_size_t *dim = ca->dim;
  int8_t   i;
  ca_size_t  n;
  n = idx[0];                  /* n = idx[0]*dim[1]*dim[2]*...*dim[ndim-1] */
  for (i=1; i<ca->ndim; i++) { /*    + idx[1]*dim[1]*dim[2]*...*dim[ndim-1] */
    n = dim[i]*n+idx[i];       /*    ... + idx[ndim-2]*dim[1] + idx[ndim-1] */
  }
  return ca->ptr + ca->bytes * n;
}

static void
ca_refer_func_fetch_addr (void *ap, ca_size_t addr, void *ptr)
{
  CARefer *ca = (CARefer *) ap;
  ca_size_t major, minor;
  switch ( ca->is_deformed ) {
  case 0:
    ca_fetch_addr(ca->parent, addr, ptr);
  case 1:
    ca_fetch_addr(ca->parent, addr + ca->offset, ptr);
    break;
  case -2: {
    major = (addr * ca->bytes) / ca->parent->bytes;
    minor = (addr * ca->bytes) % ca->parent->bytes;
    if ( ca->parent->bytes <= 256 ) {
      char val[256];
      ca_fetch_addr(ca->parent, major + ca->offset, val);
      memcpy(ptr, val+minor, ca->bytes);
    }
    else {
      char *val = malloc_with_check(ca->parent->bytes);
      ca_fetch_addr(ca->parent, major + ca->offset, val);
      memcpy(ptr, val+minor, ca->bytes);
      free(val);
    }
    break;
  }
  case 2: {
    int i;
    for (i=0; i<ca->ratio; i++) {
      ca_fetch_addr(ca->parent,
                       addr * ca->ratio + i + ca->offset,
                       (char *) ptr + i * ca->parent->bytes);
    }
    break;
  }
  }
}

static void
ca_refer_func_fetch_index (void *ap, ca_size_t *idx, void *ptr)
{
  CARefer *ca = (CARefer *) ap;
  if ( ca->is_deformed ) {
    ca_size_t *dim = ca->dim;
    int8_t   i;
    ca_size_t  n;
    n = idx[0];
    for (i=1; i<ca->ndim; i++) {
      n = dim[i]*n+idx[i];
    }
    ca_refer_func_fetch_addr(ca, n, ptr);
  }
  else {
    ca_fetch_index(ca->parent, idx, ptr);
  }
}

static void
ca_refer_func_store_addr (void *ap, ca_size_t addr, void *ptr)
{
  CARefer *ca = (CARefer *) ap;
  ca_size_t major, minor;
  switch ( ca->is_deformed ) {
  case 0:
    ca_store_addr(ca->parent, addr, ptr);
    break;
  case 1:
    ca_store_addr(ca->parent, addr + ca->offset, ptr);
    break;
  case -2: {
    major = (addr * ca->bytes) / ca->parent->bytes;
    minor = (addr * ca->bytes) % ca->parent->bytes;
    if ( ca->parent->bytes <= 256 ) {
      char val[256];
      ca_fetch_addr(ca->parent, major + ca->offset, val);
      memcpy(val+minor, ptr, ca->bytes);
      ca_store_addr(ca->parent, major + ca->offset, val);
    }
    else {
      char *val = malloc_with_check(ca->parent->bytes);
      ca_fetch_addr(ca->parent, major + ca->offset, val);
      memcpy(val+minor, ptr, ca->bytes);
      ca_store_addr(ca->parent, major + ca->offset, val);
      free(val);
    }
    break;
  }
  case 2: {
    int i;
    for (i=0; i<ca->ratio; i++) {
      ca_store_addr(ca->parent,
                       addr * ca->ratio + i + ca->offset,
                       (char *) ptr + i * ca->parent->bytes);
    }
    break;
  }
  }
}

static void
ca_refer_func_store_index (void *ap, ca_size_t *idx, void *ptr)
{
  CARefer *ca = (CARefer *) ap;
  if ( ca->is_deformed ) {
    ca_size_t *dim = ca->dim;
    int8_t   i;
    ca_size_t  n;
    n = idx[0];
    for (i=1; i<ca->ndim; i++) {
      n = dim[i]*n+idx[i];
    }
    ca_refer_func_store_addr(ca, n, ptr);
  }
  else {
    ca_store_index(ca->parent, idx, ptr);
  }
}

static void
ca_refer_func_allocate (void *ap)
{
  CARefer *ca = (CARefer *) ap;
  ca_allocate(ca->parent);
  ca->ptr = ca->parent->ptr + ca->parent->bytes * ca->offset;
  return;
}

static void
ca_refer_func_attach (void *ap)
{
  CARefer *ca = (CARefer *) ap;
  ca_attach(ca->parent);
  ca->ptr = ca->parent->ptr + ca->parent->bytes * ca->offset;
  return;
}

static void
ca_refer_func_sync (void *ap)
{
  CARefer *ca = (CARefer *) ap;
  ca_sync(ca->parent);
  return;
}

static void
ca_refer_func_detach (void *ap)
{
  CARefer *ca = (CARefer *) ap;
  ca->ptr = NULL;
  ca_detach(ca->parent);
  return;
}

static void
ca_refer_func_copy_data (void *ap, void *ptr)
{
  CARefer *ca = (CARefer *) ap;
  if ( ptr != ca->ptr ) {
    ca_attach(ca->parent);
    memmove(ptr,
            ca->parent->ptr + ca->parent->bytes * ca->offset,
            ca_length(ca));
    ca_detach(ca->parent);
  }
}

static void
ca_refer_func_sync_data (void *ap, void *ptr)
{
  CARefer *ca = (CARefer *) ap;
  if ( ptr != ca->ptr ) {
    ca_allocate(ca->parent);
    memmove(ca->parent->ptr + ca->parent->bytes * ca->offset,
            ptr,
            ca_length(ca));
    ca_sync(ca->parent);
    ca_detach(ca->parent);
  }
}

#define proc_fill_bang_fixlen()                 \
  {                                             \
    ca_size_t i;                                  \
    ca_size_t bytes = ca->bytes;                  \
    char *p = ca->parent->ptr + ca->parent->bytes * ca->offset; \
    for (i=ca->elements; i; i--, p+=bytes) {    \
      memcpy(p, val, bytes);                    \
    }                                           \
  }

#define proc_fill_bang(type)                    \
  {                                             \
    ca_size_t i;                                  \
    type *p = (type *)(ca->parent->ptr + ca->parent->bytes * ca->offset); \
    type  v = *(type *)val;                     \
    for (i=ca->elements; i; i--, p++) {         \
      *p = v;                                   \
    }                                           \
  }

static void
ca_refer_func_fill_data (void *ap, void *val)
{
  CARefer *ca = (CARefer *) ap;

  ca_allocate(ca->parent);

  switch ( ca->data_type ) {
  case CA_FIXLEN: proc_fill_bang_fixlen();  break;
  case CA_BOOLEAN:
  case CA_INT8:
  case CA_UINT8:    proc_fill_bang(int8_t);  break;
  case CA_INT16:
  case CA_UINT16:   proc_fill_bang(int16_t); break;
  case CA_INT32:
  case CA_UINT32:
  case CA_FLOAT32:  proc_fill_bang(int32_t); break;
  case CA_INT64:
  case CA_UINT64:
  case CA_FLOAT64:  proc_fill_bang(float64_t);  break;
  case CA_FLOAT128: proc_fill_bang(float128_t);  break;
#ifdef HAVE_COMPLEX_H
  case CA_CMPLX64:  proc_fill_bang(cmplx64_t);  break;
  case CA_CMPLX128: proc_fill_bang(cmplx128_t);  break;
  case CA_CMPLX256: proc_fill_bang(cmplx256_t);  break;
#endif
  case CA_OBJECT:   proc_fill_bang(VALUE);  break;
  default: rb_bug("array has an unknown data type");
  }
  ca_sync(ca->parent);
  ca_detach(ca->parent);
}

static void
ca_refer_func_create_mask (void *ap)
{
  CARefer *ca = (CARefer *) ap;

  ca_update_mask(ca->parent);
  if ( ! ca->parent->mask ) {
    ca_create_mask(ca->parent);
  }

  if ( ca->bytes == ca->parent->bytes ) {
    ca->mask =
      (CArray *) ca_refer_new(ca->parent->mask,
                              CA_BOOLEAN, ca->ndim, ca->dim, 0, ca->offset);
  }
  else if ( ca->is_deformed == -2 ) {
    ca_size_t count[CA_RANK_MAX];
    int i;
    for (i=0; i<ca->parent->ndim; i++) {
      count[i] = 0;
    }
    count[ca->parent->ndim] = ca->ratio;
    ca->mask0 = 
      (CArray *) ca_repeat_new(ca->parent->mask, ca->parent->ndim+1, count);
    ca_unset_flag(ca->mask0, CA_FLAG_READ_ONLY);

    ca->mask  = 
      (CArray *) ca_refer_new(ca->mask0, 
                              CA_BOOLEAN, ca->ndim, ca->dim, 0, ca->offset);
  }
  else if ( ca->is_deformed == 2 ) {
    /* TODO */
    ca->mask0 = 
      (CArray *) ca_reduce_new(ca->parent->mask, ca->ratio, ca->offset);
    ca->mask  = 
      (CArray *) ca_refer_new(ca->mask0, CA_BOOLEAN, ca->ndim, ca->dim, 0, 0);
  }
}

ca_operation_function_t ca_refer_func = {
  CA_OBJ_REFER,
  CA_VIRTUAL_ARRAY,
  free_ca_refer,
  ca_refer_func_clone,
  ca_refer_func_ptr_at_addr,
  ca_refer_func_ptr_at_index,
  ca_refer_func_fetch_addr,
  ca_refer_func_fetch_index,
  ca_refer_func_store_addr,
  ca_refer_func_store_index,
  ca_refer_func_allocate,
  ca_refer_func_attach,
  ca_refer_func_sync,
  ca_refer_func_detach,
  ca_refer_func_copy_data,
  ca_refer_func_sync_data,
  ca_refer_func_fill_data,
  ca_refer_func_create_mask,
};

/* ------------------------------------------------------------------- */

static VALUE
rb_ca_refer_s_allocate (VALUE klass)
{
  CARefer *ca;
  return Data_Make_Struct(klass, CARefer, ca_mark, ca_free, ca);
}

static VALUE
rb_ca_refer_initialize_copy (VALUE self, VALUE other)
{
  CARefer *ca, *cs;

  Data_Get_Struct(self,  CARefer, ca);
  Data_Get_Struct(other, CARefer, cs);

  ca_refer_setup(ca, cs->parent, cs->data_type, cs->ndim, cs->dim,
                             cs->bytes, cs->offset);

  return self;
}

/* rdoc:
  class CArray
    # call-seq: 
    #    CArray.refer()
    #    CArray.refer(data_type, dim[, :bytes=>bytes, :offset=>offset])
    #    CArray.refer(data_class, dim)
    #
    # Returns CARefer object which refers self.
    # In second form, `data_type` can be different data_type of self,
    # as long as the total byte length of new array is smaller than 
    # that of self. 
    def refer (*argv)
    end
  end
*/

static VALUE
rb_ca_refer (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE obj = Qnil;
  CArray *ca;
  CARefer *cr;
  int8_t  data_type;
  int8_t  ndim;
  ca_size_t dim[CA_RANK_MAX];
  ca_size_t bytes, offset = 0;
  int8_t i;

  Data_Get_Struct(self, CArray, ca);

  if ( argc == 0 ) {                 /* CArray#refer() */
    data_type = ca->data_type;
    bytes     = ca->bytes;
    ndim      = ca->ndim;
    for (i=0; i<ndim; i++) {
      dim[i] = ca->dim[i];
    }
    cr = ca_refer_new((CArray*)ca, data_type, ndim, dim, bytes, offset);
    obj = ca_wrap_struct(cr);
    rb_ca_set_parent(obj, self);
    rb_ca_data_type_inherit(obj, self);
  }
  else {
    volatile VALUE rtype, rdim, ropt, rbytes = Qnil, roffset = Qnil;
    ca_size_t elements;

    ropt = rb_pop_options(&argc, &argv);
    rb_scan_args(argc, argv, "11", (VALUE *) &rtype, (VALUE *) &rdim);
    rb_scan_options(ropt, "bytes,offset", &rbytes, &roffset);

    if ( NIL_P(rbytes) ) {
      rbytes = rb_ca_bytes(self);
    }

    rb_ca_guess_type_and_bytes(rtype, rbytes, &data_type, &bytes);

    if ( NIL_P(rdim) ) {
      if ( ca->bytes != bytes ) {
        rb_raise(rb_eRuntimeError, 
                 "specify dimension shape for different byte size");
      }
      else {
        rdim = rb_ca_dim(self);
      }
    }

    Check_Type(rdim, T_ARRAY);
    ndim = RARRAY_LEN(rdim);

    elements = 1;
    for (i=0; i<ndim; i++) {
      dim[i] = NUM2SIZE(rb_ary_entry(rdim, i));
      elements *= dim[i];
    }

    if ( ! NIL_P(roffset) ) {
      offset = NUM2SIZE(roffset);
    }

    cr = ca_refer_new((CArray*)ca, data_type, ndim, dim, bytes, offset);
    obj = ca_wrap_struct(cr);
    rb_ca_set_parent(obj, self);
    rb_ca_data_type_import(obj, rtype);
  }

  return obj;
}

/* api: rb_ca_refer_new
 */

VALUE
rb_ca_refer_new (VALUE self,
                 int8_t data_type, int8_t ndim, ca_size_t *dim, ca_size_t bytes,
                 ca_size_t offset)
{
  volatile VALUE list, rdim, ropt;
  CArray *ca;
  int8_t i;

  Data_Get_Struct(self, CArray, ca);

  rdim = rb_ary_new2(ndim);
  for (i=0; i<ndim; i++) {
    rb_ary_store(rdim, i, SIZE2NUM(dim[i]));
  }

  list = rb_ary_new2(3);
  if ( data_type == CA_FIXLEN && rb_ca_has_data_class(self) ) {
    rb_ary_store(list, 0, rb_ca_data_class(self));
  }
  else {
    rb_ary_store(list, 0, INT2NUM(data_type));
  }
  rb_ary_store(list, 1, rdim);
  ropt = rb_hash_new();
  rb_set_options(ropt, "bytes,offset", SIZE2NUM(bytes), SIZE2NUM(offset));
  rb_ary_store(list, 2, ropt);

  return rb_ca_refer(3, RARRAY_PTR(list), self);
}


void
Init_ca_obj_refer ()
{
  /* rb_cCARefer, CA_OBJ_REFER are defined in ruby_carray.c */

  rb_define_const(rb_cObject, "CA_OBJ_REFER",    INT2NUM(CA_OBJ_REFER));

  rb_define_method(rb_cCArray, "refer", rb_ca_refer, -1);

  rb_define_alloc_func(rb_cCARefer, rb_ca_refer_s_allocate);
  rb_define_method(rb_cCARefer, "initialize_copy",
                                      rb_ca_refer_initialize_copy, 1);
}

