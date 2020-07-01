/* ---------------------------------------------------------------------------

  ca_obj_object.c

  This file is part of Ruby/CArray extension library.
  You can redistribute it and/or modify it under the terms of
  the Ruby Licence.

  Copyright (C) 2005 Hiroki Motoyoshi

---------------------------------------------------------------------------- */

/*
  CAObject's template methods

  * Initializer

      initialize(...)

        call super(type, dim, bytes) in this method

  * For readable array

      fetch_addr(addr)  ### at least one of these two methods
      fetch_index(idx)

      copy_data(data)

  * For writable array

      store_addr(addr, val) ### at lease one of these two methods
      store_index(idx, val)

      sync_data(data)
      fill_data(value)

 */

#include "carray.h"

VALUE rb_cCAObject;


/* rdoc:
  class CAObject < CAVirtual # :nodoc:
  end
*/


/* ---------------------------------------------------------------------- */

static int8_t CA_OBJ_OBJECT_MASK;
static VALUE rb_cCAObjectMask;

/* rdoc:
  class CAObjectMask < CAVirtual # :nodoc:
  end
*/


static CAObjectMask *
ca_objmask_new (VALUE array, int8_t ndim, ca_size_t *dim)
{
  CAObjectMask *ca = ALLOC(CAObjectMask);
  ca_wrap_setup_null((CArray *)ca, CA_BOOLEAN, ndim, dim, 0, NULL);
  ca->obj_type = CA_OBJ_OBJECT_MASK;
  ca->array = array;

  return ca;
}

static VALUE
ca_objmask_mask_data (void *ap)
{
  CAObjectMask *ca = (CAObjectMask *) ap;
  return rb_funcall(rb_ivar_get(ca->array, rb_intern("__data__")), 
                    rb_intern("mask"), 0);
}

static void *
ca_objmask_func_clone (void *ap)
{
  CAObjectMask *ca = (CAObjectMask *) ap;
  return ca_objmask_new(ca->array, ca->ndim, ca->dim);
}

void
ca_objmask_func_fetch_addr (void *ap, ca_size_t addr, void *ptr)
{
  CAObjectMask *ca = (CAObjectMask *) ap;
  volatile VALUE ridx, raddr, rval;
  int i;

  if ( rb_obj_respond_to(ca->array, rb_intern("mask_fetch_addr"), Qtrue) ) {
    raddr = SIZE2NUM(addr);
    rval = rb_funcall(ca->array, rb_intern("mask_fetch_addr"), 1, raddr);
    *(uint8_t*) ptr = NUM2INT(rval) == 0 ? 0 : 1;
    ca_array_func_store_addr(ca, addr, ptr);        
  }
  else if ( rb_obj_respond_to(ca->array, rb_intern("mask_fetch_index"), Qtrue) ) {
    ca_size_t idx[CA_RANK_MAX];
    ca_addr2index(ca, addr, idx);
    ridx = rb_ary_new2(ca->ndim);
    for (i=0; i<ca->ndim; i++) {
      rb_ary_store(ridx, i, SIZE2NUM(idx[i]));
    }
    rval = rb_funcall(ca->array, rb_intern("mask_fetch_index"), 1, ridx);
    *(uint8_t*) ptr = NUM2INT(rval) == 0 ? 0 : 1;
    ca_array_func_store_index(ca, idx, ptr);        
  }
  else {
    ca_array_func_fetch_addr(ca, addr, ptr);    
  }
}

void
ca_objmask_func_fetch_index (void *ap, ca_size_t *idx, void *ptr)
{
  CAObjectMask *ca = (CAObjectMask *) ap;
  volatile VALUE ridx, raddr, rval;
  int i;

  if ( rb_obj_respond_to(ca->array, rb_intern("mask_fetch_index"), Qtrue) ) {
    ridx = rb_ary_new2(ca->ndim);
    for (i=0; i<ca->ndim; i++) {
      rb_ary_store(ridx, i, SIZE2NUM(idx[i]));
    }
    rval = rb_funcall(ca->array, rb_intern("mask_fetch_index"), 1, ridx);
    *(uint8_t*) ptr = NUM2INT(rval) == 0 ? 0 : 1;
    ca_array_func_store_index(ca, idx, ptr);        
  }
  else if ( rb_obj_respond_to(ca->array, rb_intern("mask_fetch_addr"), Qtrue) ) {
    ca_size_t addr = ca_index2addr(ca, idx);
    raddr = SIZE2NUM(addr);
    rval = rb_funcall(ca->array, rb_intern("mask_fetch_addr"), 1, raddr);
    *(uint8_t*) ptr = NUM2INT(rval) == 0 ? 0 : 1;
    ca_array_func_store_addr(ca, addr, ptr);        
  }
  else {
    ca_array_func_fetch_index(ca, idx, ptr);    
  }
}


void
ca_objmask_func_store_addr (void *ap, ca_size_t addr, void *ptr)
{
  CAObjectMask *ca = (CAObjectMask *) ap;
  volatile VALUE ridx, raddr, rval;
  int i;

  ca_array_func_store_addr(ca, addr, ptr);
  rval = INT2NUM( *(uint8_t*)ptr );
  if ( rb_obj_respond_to(ca->array, rb_intern("mask_store_addr"), Qtrue) ) {
    raddr = SIZE2NUM(addr);
    rb_funcall(ca->array, rb_intern("mask_store_addr"), 2, raddr, rval);
  }
  else if ( rb_obj_respond_to(ca->array, rb_intern("mask_store_index"), Qtrue) ) {
    ca_size_t idx[CA_RANK_MAX];
    ca_addr2index(ca, addr, idx);
    ridx = rb_ary_new2(ca->ndim);
    for (i=0; i<ca->ndim; i++) {
      rb_ary_store(ridx, i, SIZE2NUM(idx[i]));
    }
    rb_funcall(ca->array, rb_intern("mask_store_index"), 2, ridx, rval);
  }
}

void
ca_objmask_func_store_index (void *ap, ca_size_t *idx, void *ptr)
{
  CAObjectMask *ca = (CAObjectMask *) ap;
  volatile VALUE ridx, raddr, rval;
  int i;

  ca_array_func_store_index(ca, idx, ptr);  
  rval = INT2NUM( *(uint8_t*)ptr );

  if ( rb_obj_respond_to(ca->array, rb_intern("mask_store_index"), Qtrue) ) {
    ridx = rb_ary_new2(ca->ndim);
    for (i=0; i<ca->ndim; i++) {
      rb_ary_store(ridx, i, SIZE2NUM(idx[i]));
    }
    rb_funcall(ca->array, rb_intern("mask_store_index"), 2, ridx, rval);
  }
  else if ( rb_obj_respond_to(ca->array, rb_intern("mask_store_addr"), Qtrue) ) {
    ca_size_t addr = ca_index2addr(ca, idx);
    raddr = SIZE2NUM(addr);
    rb_funcall(ca->array, rb_intern("mask_store_addr"), 2, raddr, rval);
  }

}

static void
ca_objmask_func_attach (void *ap)
{
  CAObjectMask *ca = (CAObjectMask *) ap;
  if ( rb_obj_respond_to(ca->array, rb_intern("mask_copy_data"), Qtrue) ) {
    rb_funcall(ca->array, rb_intern("mask_copy_data"), 
                        1, ca_objmask_mask_data(ca));
  }
}

void
ca_objmask_func_sync (void *ap)
{
  CAObjectMask *ca = (CAObjectMask *) ap;
  if ( rb_obj_respond_to(ca->array, rb_intern("mask_sync_data"), Qtrue) ) {
    rb_funcall(ca->array, rb_intern("mask_sync_data"), 
                          1, ca_objmask_mask_data(ca));
  }
}

static void
ca_objmask_func_copy_data (void *ap, void *ptr)
{
  CAObjectMask *ca = (CAObjectMask *) ap;
  if ( rb_obj_respond_to(ca->array, rb_intern("mask_copy_data"), Qtrue) ) {
    char *ptr0 = ca->ptr;
    ca->ptr = ptr;
    rb_funcall(ca->array, rb_intern("mask_copy_data"),
                          1, ca_objmask_mask_data(ca));
    ca->ptr = ptr0;
  }
  else {
    ca_array_func_copy_data(ca, ptr);
  }
}

static void
ca_objmask_func_sync_data (void *ap, void *ptr)
{
  CAObjectMask *ca = (CAObjectMask *) ap;
  if ( rb_obj_respond_to(ca->array, rb_intern("mask_copy_data"), Qtrue) ) {  
    char *ptr0 = ca->ptr;
    ca->ptr = ptr;
    rb_funcall(ca->array, rb_intern("mask_sync_data"),
                          1, ca_objmask_mask_data(ca));
    ca->ptr = ptr0;
  }
  else {
    ca_array_func_sync_data(ca, ptr);
  }
}

void
ca_objmask_func_fill_data (void *ap, void *val)
{
  CAObjectMask *ca = (CAObjectMask *) ap;
  ca_array_func_fill_data(ca, val);
  if ( rb_obj_respond_to(ca->array, rb_intern("mask_fill_data"), Qtrue) ) {  
    rb_funcall(ca->array, rb_intern("mask_fill_data"), 
                          1, INT2NUM(*(uint8_t*)val));
  }
}

static ca_operation_function_t ca_objmask_func = {
  -1, /* CA_OBJ_OBJECT_MASK */
  CA_REAL_ARRAY,
  free_ca_wrap,
  ca_objmask_func_clone,
  ca_array_func_ptr_at_addr,
  ca_array_func_ptr_at_index,
  ca_objmask_func_fetch_addr,
  ca_objmask_func_fetch_index,
  ca_objmask_func_store_addr,
  ca_objmask_func_store_index,
  ca_array_func_allocate,
  ca_objmask_func_attach,
  ca_objmask_func_sync,
  ca_array_func_detach,
  ca_objmask_func_copy_data,
  ca_objmask_func_sync_data,
  ca_objmask_func_fill_data,
  ca_array_func_create_mask,
};

static VALUE
rb_ca_objmask_s_allocate (VALUE klass)
{
  CAObjectMask *ca;
  return Data_Make_Struct(klass, CAObjectMask, ca_mark, ca_free, ca);
}

static VALUE
rb_ca_objmask_initialize_copy (VALUE self, VALUE other)
{
  CAObjectMask *ca, *cs;

  Data_Get_Struct(self,  CAObjectMask, ca);
  Data_Get_Struct(other, CAObjectMask, cs);

  carray_setup((CArray *)ca, CA_BOOLEAN, cs->ndim, cs->dim, 0, NULL);
  ca->obj_type = CA_OBJ_OBJECT_MASK;
  ca->array = cs->array;

  return self;
}

/* -------------------------------------------------------------------- */

static int
ca_object_setup (CAObject *ca,
               int8_t data_type, int8_t ndim, ca_size_t *dim, ca_size_t bytes)
{
  ca_size_t elements;
  double  length;
  int8_t i;

  /* check arguments */

  CA_CHECK_DATA_TYPE(data_type);
  CA_CHECK_RANK(ndim);
  CA_CHECK_DIM(ndim, dim);
  CA_CHECK_BYTES(data_type, bytes);

  /* calculate total number of elements */

  elements = 1;
  length = bytes;
  for (i=0; i<ndim; i++) {
    elements *= dim[i];
    length   *= dim[i];
  }
  
  if ( length > CA_LENGTH_MAX ) {
    rb_raise(rb_eRuntimeError, "too large byte length");
  }

  ca->obj_type  = CA_OBJ_OBJECT;
  ca->data_type = data_type;
  ca->flags     = 0;
  ca->ndim      = ndim;
  ca->bytes     = bytes;
  ca->elements  = elements;
  ca->ptr       = NULL;
  ca->mask      = NULL;
  ca->parent    = NULL;
  ca->attach    = 0;
  ca->nosync    = 0;

  ca->dim       = ALLOC_N(ca_size_t, ndim);

  ca->data      = ca_wrap_new_null(data_type, ndim, dim, bytes, NULL);

  memcpy(ca->dim, dim, ndim * sizeof(ca_size_t));

  return 0;
}

static CAObject *
ca_object_new (int8_t data_type, int8_t ndim, ca_size_t *dim, ca_size_t bytes)
{
  CAObject *ca = ALLOC(CAObject);
  ca_object_setup(ca, data_type, ndim, dim, bytes);
  return ca;
}

static void
free_ca_object (void *ap)
{
  CAObject *ca = (CAObject *) ap;
  if ( ca != NULL ) {
    /* ca->mask will be GC-ed by Ruby interpreter */
    xfree(ca->dim);
    xfree(ca);
  }
}

/* ------------------------------------------------------------------- */

static void *
ca_object_func_clone (void *ap)
{
  CAObject *ca = (CAObject *) ap;
  return ca_object_new(ca->bytes, ca->ndim, ca->dim, ca->bytes);
}

#define ca_object_func_ptr_at_addr ca_array_func_ptr_at_addr
#define ca_object_func_ptr_at_index ca_array_func_ptr_at_index

static void
ca_object_func_fetch_addr (void *ap, ca_size_t addr, void *ptr)
{
  CAObject *ca = (CAObject *) ap;
  volatile VALUE ridx, raddr, rval;
  int i;
  if ( rb_obj_respond_to(ca->self, rb_intern("fetch_addr"), Qtrue) ) {
    raddr = SIZE2NUM(addr);
    rval = rb_funcall(ca->self, rb_intern("fetch_addr"), 1, raddr);
    if ( rval == CA_UNDEF ) {
      ca_update_mask(ca);
      if ( ! ca->mask ) {
        ca_create_mask(ca);
      }
      *(boolean8_t*)ca_ptr_at_addr(ca->mask, addr) = 1;
      if ( ca->data_type == CA_OBJECT ) {
        rb_ca_obj2ptr(ca->self, INT2NUM(0), ptr);
      }
    }
    else {
      if ( ca_has_mask(ca) ) {
        *(boolean8_t*)ca_ptr_at_addr(ca->mask, addr) = 0;        
      }
      rb_ca_obj2ptr(ca->self, rval, ptr);
    }
  }
  else {
    ca_size_t idx[CA_RANK_MAX];
    ca_addr2index(ca, addr, idx);
    ridx = rb_ary_new2(ca->ndim);
    for (i=0; i<ca->ndim; i++) {
      rb_ary_store(ridx, i, SIZE2NUM(idx[i]));
    }
    rval = rb_funcall(ca->self, rb_intern("fetch_index"), 1, ridx);
    if ( rval == CA_UNDEF ) {
      ca_update_mask(ca);
      if ( ! ca->mask ) {
        ca_create_mask(ca);
      }
      *(boolean8_t*)ca_ptr_at_index(ca->mask, idx) = 1;
      if ( ca->data_type == CA_OBJECT ) {
        rb_ca_obj2ptr(ca->self, INT2NUM(0), ptr);
      }
    }
    else {
      if ( ca_has_mask(ca) ) {
        *(boolean8_t*)ca_ptr_at_index(ca->mask, idx) = 0;        
      }
      rb_ca_obj2ptr(ca->self, rval, ptr);
    }
  }
}

static void
ca_object_func_fetch_index (void *ap, ca_size_t *idx, void *ptr)
{
  CAObject *ca = (CAObject *) ap;
  volatile VALUE ridx, raddr, rval;
  int i;
  if ( rb_obj_respond_to(ca->self, rb_intern("fetch_index"), Qtrue) ) {
    ridx = rb_ary_new2(ca->ndim);
    for (i=0; i<ca->ndim; i++) {
      rb_ary_store(ridx, i, SIZE2NUM(idx[i]));
    }
    rval = rb_funcall(ca->self, rb_intern("fetch_index"), 1, ridx);
    if ( rval == CA_UNDEF ) {
      ca_update_mask(ca);
      if ( ! ca->mask ) {
        ca_create_mask(ca);
      }
      *(boolean8_t*)ca_ptr_at_index(ca->mask, idx) = 1;
      if ( ca->data_type == CA_OBJECT ) {
        rb_ca_obj2ptr(ca->self, INT2NUM(0), ptr);
      }
    }
    else {
      if ( ca_has_mask(ca) ) {
        *(boolean8_t*)ca_ptr_at_index(ca->mask, idx) = 0;        
      }
      rb_ca_obj2ptr(ca->self, rval, ptr);
    }
  }
  else {
    ca_size_t addr = ca_index2addr(ca, idx);
    raddr = SIZE2NUM(addr);
    rval = rb_funcall(ca->self, rb_intern("fetch_addr"), 1, raddr);
    if ( rval == CA_UNDEF ) {
      ca_update_mask(ca);
      if ( ! ca->mask ) {
        ca_create_mask(ca);
      }
      *(boolean8_t*)ca_ptr_at_addr(ca->mask, addr) = 1;
      if ( ca->data_type == CA_OBJECT ) {
        rb_ca_obj2ptr(ca->self, INT2NUM(0), ptr);
      }
    }
    else {
      if ( ca_has_mask(ca) ) {
        *(boolean8_t*)ca_ptr_at_addr(ca->mask, addr) = 0;        
      }
      rb_ca_obj2ptr(ca->self, rval, ptr);
    }
  }
}

static void
ca_object_func_store_addr (void *ap, ca_size_t addr, void *ptr)
{
  CAObject *ca = (CAObject *) ap;
  volatile VALUE ridx, raddr, rval;
  int i;
  if ( rb_obj_respond_to(ca->self, rb_intern("store_addr"), Qtrue) ) {
    raddr = SIZE2NUM(addr);
    rval = rb_ca_ptr2obj(ca->self, ptr);
    rb_funcall(ca->self, rb_intern("store_addr"), 2, raddr, rval);
  }
  else {
    ca_size_t idx[CA_RANK_MAX];
    ca_addr2index(ca, addr, idx);
    ridx = rb_ary_new2(ca->ndim);
    for (i=0; i<ca->ndim; i++) {
      rb_ary_store(ridx, i, SIZE2NUM(idx[i]));
    }
    rval = rb_ca_ptr2obj(ca->self, ptr);
    rb_funcall(ca->self, rb_intern("store_index"), 2, ridx, rval);
  }
}

static void
ca_object_func_store_index (void *ap, ca_size_t *idx, void *ptr)
{
  CAObject *ca = (CAObject *) ap;
  volatile VALUE ridx, raddr, rval;
  int i;
  if ( rb_obj_respond_to(ca->self, rb_intern("store_index"), Qtrue) ) {
    ridx = rb_ary_new2(ca->ndim);
    for (i=0; i<ca->ndim; i++) {
      rb_ary_store(ridx, i, SIZE2NUM(idx[i]));
    }
    rval = rb_ca_ptr2obj(ca->self, ptr);
    rb_funcall(ca->self, rb_intern("store_index"), 2, ridx, rval);
  }
  else {
    ca_size_t addr = ca_index2addr(ca, idx);
    raddr = SIZE2NUM(addr);
    rval = rb_ca_ptr2obj(ca->self, ptr);
    rb_funcall(ca->self, rb_intern("store_addr"), 2, raddr, rval);
  }
}

static void
ca_object_func_allocate (void *ap)
{
  CAObject *ca = (CAObject *) ap;
  /* ca->data->ptr = ALLOC_N(char, ca_length(ca)); */
  ca->data->ptr = malloc_with_check(ca_length(ca));  
  if ( ca_is_object_type(ca->data) ) { /* GC safe */
    VALUE *p = (VALUE *) ca->data->ptr;
    VALUE zero = INT2NUM(0);
    ca_size_t i;
    for (i=0; i<ca->elements; i++) {
      *p++ = zero;
    }
  }
  ca->ptr = ca->data->ptr;
}

static void
ca_object_func_attach (void *ap)
{
  CAObject *ca = (CAObject *) ap;
  volatile VALUE data = rb_ivar_get(ca->self, rb_intern("__data__"));
  /* ca->data->ptr = ALLOC_N(char, ca_length(ca)); */
  ca->data->ptr = malloc_with_check(ca_length(ca));  
  if ( ca_is_object_type(ca->data) ) { /* GC safe */
    VALUE *p = (VALUE *) ca->data->ptr;
    VALUE zero = INT2NUM(0);
    ca_size_t i;
    for (i=0; i<ca->elements; i++) {
      *p++ = zero;
    }
  }
  ca->ptr = ca->data->ptr;  
  rb_funcall(ca->self, rb_intern("copy_data"), 1, data);
  if ( ca_has_mask(ca->data) ) {
    ca_update_mask(ca);
    if ( ! ca->mask ) {
      ca_create_mask(ca);
    }
  }
}

static void
ca_object_func_sync (void *ap)
{
  CAObject *ca = (CAObject *) ap;
  rb_funcall(ca->self, rb_intern("sync_data"),
             1, rb_ivar_get(ca->self, rb_intern("__data__")));
}

static void
ca_object_func_detach (void *ap)
{
  CAObject *ca = (CAObject *) ap;
  free(ca->data->ptr);
  ca->data->ptr = NULL;
  ca->ptr = NULL;
}

static void
ca_object_func_copy_data (void *ap, void *ptr)
{
  CAObject *ca = (CAObject *) ap;
  char *ptr0 = ca->data->ptr;
  ca->data->ptr = ptr;
  rb_funcall(ca->self, rb_intern("copy_data"),
             1, rb_ivar_get(ca->self, rb_intern("__data__")));
  ca->data->ptr = ptr0;
}

static void
ca_object_func_sync_data (void *ap, void *ptr)
{
  CAObject *ca = (CAObject *) ap;
  char *ptr0 = ca->data->ptr;
  ca->data->ptr = ptr;
  rb_funcall(ca->self, rb_intern("sync_data"),
             1, rb_ivar_get(ca->self, rb_intern("__data__")));
  ca->data->ptr = ptr0;
}

static void
ca_object_func_fill_data (void *ap, void *ptr)
{
  CAObject *ca = (CAObject *) ap;
  volatile VALUE rval;
  rval = rb_ca_ptr2obj(ca->self, ptr);
  rb_funcall(ca->self, rb_intern("fill_data"), 1, rval);
}

static void
ca_object_func_create_mask (void *ap)
{
  CAObject *ca = (CAObject *) ap;
  volatile VALUE rmask;
  if ( rb_obj_respond_to(ca->self, rb_intern("create_mask"), Qtrue) ) {
    rb_funcall(ca->self, rb_intern("create_mask"), 0);
  }
  else {
    rb_raise(rb_eRuntimeError, "can't create mask for CAObject");
  }
  ca_update_mask(ca->data);
  if ( ! ca->data->mask ) {
    ca_create_mask(ca->data);
  }
  ca->mask = (CArray*) ca_objmask_new(ca->self, ca->ndim, ca->dim);
  ca->mask->ptr = ca->data->mask->ptr;
  rmask = ca_wrap_struct(ca->mask);
  rb_ivar_set(ca->self, rb_intern("mask"), rmask);
}

ca_operation_function_t ca_object_func = {
  -1, /* CA_OBJ_OBJECT */
  CA_VIRTUAL_ARRAY,
  free_ca_object,
  ca_object_func_clone,
  ca_object_func_ptr_at_addr,
  ca_object_func_ptr_at_index,
  ca_object_func_fetch_addr,
  ca_object_func_fetch_index,
  ca_object_func_store_addr,
  ca_object_func_store_index,
  ca_object_func_allocate,
  ca_object_func_attach,
  ca_object_func_sync,
  ca_object_func_detach,
  ca_object_func_copy_data,
  ca_object_func_sync_data,
  ca_object_func_fill_data,
  ca_object_func_create_mask,
};

/* ------------------------------------------------------------------- */

static VALUE
rb_ca_object_s_allocate (VALUE klass)
{
  CAObject *ca;
  return Data_Make_Struct(klass, CAObject, ca_mark, ca_free, ca);
}

static VALUE
rb_ca_object_initialize_copy (VALUE self, VALUE other)
{
  volatile VALUE data;
  CAObject *ca, *cs;

  Data_Get_Struct(self,  CAObject, ca);
  Data_Get_Struct(other, CAObject, cs);

  ca_object_setup(ca, cs->data_type, cs->ndim, cs->dim, cs->bytes);
  ca->self = self;

  rb_ca_data_type_inherit(self, other);

  data = ca_wrap_struct(ca->data);
  rb_ca_data_type_inherit(data, self);
  rb_ivar_set(self, rb_intern("__data__"), data);

  ca_update_mask(cs);
  if ( cs->mask ) {
    ca->mask = cs->mask;
    rb_ivar_set(self, rb_intern("mask"),
                      rb_ivar_get(other, rb_intern("mask")));
  }

  return self;
}

static VALUE
rb_ca_object_initialize (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE rtype, rdim, ropt, rbytes = Qnil, rrdonly = Qnil, rparent = Qnil, rdata;
  CAObject *ca;
  int8_t data_type, ndim;
  ca_size_t dim[CA_RANK_MAX];
  ca_size_t bytes;
  int i;

  rb_scan_args(argc, argv, "21", (VALUE *) &rtype, (VALUE *) &rdim, (VALUE *) &ropt);
  rb_scan_options(ropt, "bytes,read_only,parent", 
                  &rbytes, &rrdonly, &rparent);

  if ( ( ! NIL_P(rparent) ) && rb_obj_is_carray(rparent) ) {
    rb_raise(rb_eRuntimeError, "option :parent should be a carray");
  }

  rb_ca_guess_type_and_bytes(rtype, rbytes, &data_type, &bytes);
  rb_ca_data_type_import(self, rtype);

  Check_Type(rdim, T_ARRAY);

  ndim = RARRAY_LEN(rdim);
  for (i=0; i<ndim; i++) {
    dim[i] = NUM2SIZE(rb_ary_entry(rdim, i));
  }

  Data_Get_Struct(self, CAObject, ca);
  ca_object_setup(ca, data_type, ndim, dim, bytes);
  ca->self = self;

  rdata = ca_wrap_struct(ca->data);
  rb_ca_data_type_inherit(rdata, self);

  rb_ivar_set(self, rb_intern("__data__"), rdata);

  if ( RTEST(rrdonly) ) {
    ca_set_flag(ca, CA_FLAG_READ_ONLY);
  }

  if ( ! NIL_P(rparent) ) {
    CArray *cp;
    Data_Get_Struct(rparent, CArray, cp);
    ca->parent = cp;
    rb_ca_set_parent(self, rparent);
  }
  
  ca_update_mask(ca);

  return Qnil;
}

void
Init_ca_obj_object ()
{
  rb_cCAObjectMask = rb_define_class("CAObjectMask", rb_cCArray);

  CA_OBJ_OBJECT_MASK = ca_install_obj_type(rb_cCAObjectMask, ca_objmask_func);
  rb_define_const(rb_cObject, "CA_OBJ_OBJECT_MASK", INT2NUM(CA_OBJ_OBJECT_MASK));

  rb_define_alloc_func(rb_cCAObjectMask, rb_ca_objmask_s_allocate);
  rb_define_method(rb_cCAObjectMask, "initialize_copy",
                                      rb_ca_objmask_initialize_copy, 1);
  

  rb_define_const(rb_cObject, "CA_OBJ_OBJECT", INT2NUM(CA_OBJ_OBJECT));

  rb_define_alloc_func(rb_cCAObject, rb_ca_object_s_allocate);
  rb_define_method(rb_cCAObject, "initialize_copy",
                                      rb_ca_object_initialize_copy, 1);
  rb_define_method(rb_cCAObject, "initialize",
                                      rb_ca_object_initialize, -1);
                                      
}


