/* ---------------------------------------------------------------------------

  ca_obj_select.c

  This file is part of Ruby/CArray extension library.

  Copyright (C) 2005-2020 Hiroki Motoyoshi

---------------------------------------------------------------------------- */

#include "carray.h"

VALUE rb_cCASelect;

/* yard:
  class CASelect < CAVirtual # :nodoc:
  end
*/

typedef struct {
  int16_t   obj_type;
  int8_t    data_type;
  int8_t    ndim;
  int32_t   flags;
  ca_size_t   bytes;
  ca_size_t   elements;
  ca_size_t  *dim;  /* point to _dim */
  char     *ptr;
  CArray   *mask;
  CArray   *parent;
  uint32_t  attach;
  uint8_t   nosync;
  /* ---------- */
  CArray   *select;
  ca_size_t  _dim;
} CASelect;

/* ------------------------------------------------------------------- */

static int
ca_select_setup (CASelect *ca, CArray *parent, CArray *select, int share)
{
  int8_t data_type;
  ca_size_t bytes;
  int i;

  if ( ! ca_is_boolean_type(select) ) {
    rb_raise(rb_eRuntimeError,
             "selection array for CASelect should be have "
             "the data_type of CA_BOOLEAN");
  }

  data_type = parent->data_type;
  bytes     = parent->bytes;

  ca->obj_type  = CA_OBJ_SELECT;
  ca->data_type = data_type;
  ca->flags     = 0;
  ca->ndim      = 1;
  ca->bytes     = bytes;

  if ( share && ca_is_entity(select) ) {
    ca_set_flag(ca, CA_FLAG_SHARE_INDEX);
    ca->select = select;
  }
  else {
    if ( ca_has_mask(select) ) {
      boolean8_t *p, *q, *m;
      ca->select = ca_template(select);
      ca_attach(select);
      q = (boolean8_t *) ca->select->ptr;
      p = (boolean8_t *) select->ptr;
      m = (boolean8_t *) select->mask->ptr;
      for (i=0; i<select->elements; i++) {
        *q = ( *m ) ? 0 : *p;
        q++; p++; m++;
      }
      ca_detach(select);
    }
    else {
      ca->select = ca_copy(select);
    }
  }

  {
    int count = 0;
    boolean8_t *s = (boolean8_t *) ca->select->ptr;
    for (i=0; i<ca->select->elements; i++) {
      if ( *s ) {
        count++;
      }
      s++;
    }
    ca->elements  = count;
  }

  ca->ptr       = NULL;
  ca->mask      = NULL;
  ca->dim       = &(ca->_dim);
  ca->dim[0]    = ca->elements;

  ca->parent    = parent;
  ca->attach    = 0;
  ca->nosync    = 0;

  if ( ca_is_scalar(select) ) {
    ca_set_flag(ca, CA_FLAG_SCALAR);
  }

  return 0;
}

CArray *
ca_select_new (CArray *parent, CArray *select)
{
  CASelect *ca = ALLOC(CASelect);
  ca_select_setup(ca, parent, select, 0);
  return (CArray*) ca;
}

CArray *
ca_select_new_share (CArray *parent, CArray *select)
{
  CASelect *ca = ALLOC(CASelect);
  ca_select_setup(ca, parent, select, 1);
  return (CArray*) ca;
}

static void
free_ca_select (void *ap)
{
  CASelect *ca = (CASelect *) ap;
  if ( ca != NULL ) {
    ca_free(ca->mask);
    if ( ! (ca->flags & CA_FLAG_SHARE_INDEX) ) {
      ca_free(ca->select);
    }
    xfree(ca);
  }
}

void ca_select_to_ptr (CArray *ca, CArray *select, char *ptr);
void ca_select_from_ptr (CArray *ca, CArray *select, char *ptr);
void ca_select_fill (CArray *ca, CArray *select, char *valp);
void ca_select_to_carray (CArray *ca, CArray *select, CArray *cs);
void ca_select_from_carray (CArray *ca, CArray *select, CArray *cs);

/* ------------------------------------------------------------------- */

static void *
ca_select_func_clone (void *ap)
{
  CASelect *ca = (CASelect *) ap;
  return ca_select_new_share(ca->parent, ca->select);
}

static char *
ca_select_func_ptr_at_addr (void *ap, ca_size_t addr)
{
  CASelect *ca = (CASelect *) ap;

  if ( ca->ptr ) {
    return ca->ptr + ca->bytes * addr;
  }
  else {
    ca_size_t n, i, a;
    ca_size_t elements = ca->select->elements;
    boolean8_t  s;

    n = 0;
    a = 0;

    for (i=0; i<elements; i++) {
      ca_fetch_addr(ca->select, i, &s);
      if ( s ) {
        if ( addr == a++ ) {
          n = i;
          break;
        }
      }
    }

    if ( ca_is_attached(ca->parent) ) {
      return ca->parent->ptr + ca->bytes * n;
    }
    else {
      return ca_ptr_at_addr(ca->parent, n);
    }
  }
}

static char *
ca_select_func_ptr_at_index (void *ap, ca_size_t *idx)
{
  CASelect *ca = (CASelect *) ap;
  ca_size_t addr = idx[0];

  if ( ca->ptr ) {
    return ca->ptr + ca->bytes * addr;
  }
  else {
    return ca_select_func_ptr_at_addr(ca, idx[0]);
  }
}

static void
ca_select_func_fetch_addr (void *ap, ca_size_t addr, void *ptr)
{
  CASelect *ca = (CASelect *) ap;
  ca_size_t n, i, a;
  ca_size_t elements = ca->select->elements;
  boolean8_t  s;
  n = 0;
  a = 0;
  for (i=0; i<elements; i++) {
    ca_fetch_addr(ca->select, i, &s);
    if ( s ) {
      if ( addr == a++ ) {
        n = i;
        break;
      }
    }
  }
  ca_fetch_addr(ca->parent, n, ptr);
}

static void
ca_select_func_fetch_index (void *ap, ca_size_t *idx, void *ptr)
{
  ca_select_func_fetch_addr(ap, idx[0], ptr);
}

static void
ca_select_func_store_addr (void *ap, ca_size_t addr, void *ptr)
{
  CASelect *ca = (CASelect *) ap;
  ca_size_t n, i, a;
  ca_size_t elements = ca->select->elements;
  boolean8_t  s;
  n = 0;
  a = 0;
  for (i=0; i<elements; i++) {
    ca_fetch_addr(ca->select, i, &s);
    if ( s ) {
      if ( addr == a++ ) {
        n = i;
        break;
      }
    }
  }
  ca_store_addr(ca->parent, n, ptr);
}

static void
ca_select_func_store_index (void *ap, ca_size_t *idx, void *ptr)
{
  ca_select_func_store_addr(ap, idx[0], ptr);
}

static void
ca_select_func_allocate (void *ap)
{
  CASelect *ca = (CASelect *) ap;
  ca_attach(ca->parent);
  /* ca->ptr = ALLOC_N(char, ca_length(ca)); */
  ca->ptr = malloc_with_check(ca_length(ca));  
}

static void
ca_select_func_attach (void *ap)
{
  CASelect *ca = (CASelect *) ap;
  ca_attach(ca->parent);
  /* ca->ptr = ALLOC_N(char, ca_length(ca)); */
  ca->ptr = malloc_with_check(ca_length(ca));  
  ca_select_to_ptr(ca->parent, ca->select, ca->ptr);
}

static void
ca_select_func_sync (void *ap)
{
  CASelect *ca = (CASelect *) ap;
  ca_select_from_ptr(ca->parent, ca->select, ca->ptr);
  ca_sync(ca->parent);
}

static void
ca_select_func_detach (void *ap)
{
  CASelect *ca = (CASelect *) ap;
  free(ca->ptr);
  ca->ptr = NULL;
  ca_detach(ca->parent);
}

static void
ca_select_func_copy_data (void *ap, void *ptr)
{
  CASelect *ca = (CASelect *) ap;
  ca_attach(ca->parent);
  ca_select_to_ptr(ca->parent, ca->select, ptr);
  ca_detach(ca->parent);
}

static void
ca_select_func_sync_data (void *ap, void *ptr)
{
  CASelect *ca = (CASelect *) ap;
  ca_attach(ca->parent);
  ca_select_from_ptr(ca->parent, ca->select, ptr);
  ca_sync(ca->parent);
  ca_detach(ca->parent);
}


static void
ca_select_func_fill_data (void *ap, void *ptr)
{
  CASelect *ca = (CASelect *) ap;
  ca_attach(ca->parent);
  ca_select_fill(ca->parent, ca->select, ptr);
  ca_sync(ca->parent);
  ca_detach(ca->parent);
}

static void
ca_select_func_create_mask (void *ap)
{
  CASelect *ca = (CASelect *) ap;
  ca_update_mask(ca->parent);
  if ( ! ca->parent->mask ) {
    ca_create_mask(ca->parent);
  }
  ca->mask = (CArray *) ca_select_new_share(ca->parent->mask, ca->select);
}

ca_operation_function_t ca_select_func = {
  CA_OBJ_SELECT,
  CA_VIRTUAL_ARRAY,
  free_ca_select,
  ca_select_func_clone,
  ca_select_func_ptr_at_addr,
  ca_select_func_ptr_at_index,
  ca_select_func_fetch_addr,
  ca_select_func_fetch_index,
  ca_select_func_store_addr,
  ca_select_func_store_index,
  ca_select_func_allocate,
  ca_select_func_attach,
  ca_select_func_sync,
  ca_select_func_detach,
  ca_select_func_copy_data,
  ca_select_func_sync_data,
  ca_select_func_fill_data,
  ca_select_func_create_mask,
};

/* ------------------------------------------------------------------- */

VALUE
rb_ca_select_new (VALUE cary, VALUE select)
{
  volatile VALUE obj;
  CArray *parent, *cselect;
  CASelect *ca;
  rb_check_carray_object(cary);
  rb_check_carray_object(select);
  Data_Get_Struct(cary, CArray, parent);
  Data_Get_Struct(select, CArray, cselect);
  ca = (CASelect *) ca_select_new(parent, cselect);
  if ( ! ca ) {
    return Qnil;
  }
  obj = ca_wrap_struct(ca);
  rb_ca_set_parent(obj, cary);
  rb_ca_data_type_inherit(obj, cary);
  return obj;
}

VALUE
rb_ca_select_new_share (VALUE cary, VALUE select)
{
  volatile VALUE obj;
  CArray *parent, *cselect;
  CASelect *ca;
  rb_check_carray_object(cary);
  rb_check_carray_object(select);
  Data_Get_Struct(cary, CArray, parent);
  Data_Get_Struct(select, CArray, cselect);
  ca = (CASelect *) ca_select_new_share(parent, cselect);
  if ( ! ca ) {
    return Qnil;
  }
  obj = ca_wrap_struct(ca);
  rb_ca_set_parent(obj, cary);
  rb_ca_data_type_inherit(obj, cary);
  rb_ivar_set(obj, rb_intern("referred_index"), select);
  return obj;
}

/* -------------------------------------------------------------------- */

#define proc_select_to_ptr(type) \
  { \
    type *p = (type *) ptr; \
    type *q = (type *) ca->ptr; \
    for (i=ca->elements; i; i--) { \
      if ( *s ) { \
        *p++ = *q; \
      } \
      q++; s++; \
    } \
  }

void
ca_select_to_ptr (CArray *ca, CArray *select, char *ptr)
{
  boolean8_t *s = (boolean8_t*) select->ptr;
  ca_size_t i;

  switch ( ca->bytes ) {
  case 1: proc_select_to_ptr(int8_t); break;
  case 2: proc_select_to_ptr(int16_t); break;
  case 4: proc_select_to_ptr(int32_t); break;
  case 8: proc_select_to_ptr(float64_t); break;
  default: {
    char *p = ptr, *q = ca->ptr;
    ca_size_t bytes = ca->bytes;
    for (i=ca->elements; i; i--) {
      if ( *s ) {
        memcpy(q, p, bytes);
        p+=bytes;
      }
      q+=bytes; s++;
    }
    break;
  }
  }

}

/* ------------------------------------------------------------------- */

#define proc_select_from_ptr(type) \
  { \
    type *p = (type *) ptr; \
    type *q = (type *) ca->ptr; \
    for (i=ca->elements; i; i--) { \
      if ( *s ) { \
        *q = *p++; \
      } \
      q++; s++; \
    } \
  }

void
ca_select_from_ptr (CArray *ca, CArray *select, char *ptr)
{
  boolean8_t *s = (boolean8_t *) select->ptr;
  ca_size_t i;

  switch ( ca->bytes ) {
  case 1: proc_select_from_ptr(int8_t); break;
  case 2: proc_select_from_ptr(int16_t); break;
  case 4: proc_select_from_ptr(int32_t); break;
  case 8: proc_select_from_ptr(float64_t); break;
  default: {
    char *p = ptr;
    char *q = ca->ptr;
    ca_size_t bytes = ca->bytes;
    for (i=ca->elements; i; i--) {
      if ( *s ) {
        memcpy(q, p, bytes);
        p+=bytes;
      }
      q+=bytes; s++;
    }
    break;
  }
  }

}

/* ------------------------------------------------------------------- */

#define proc_select_fill(type) \
  { \
    type *q = (type *) ca->ptr; \
    type v = *(type *) valp; \
    for (i=ca->elements; i; i--) { \
      if ( *s ) { \
        *q = v; \
      } \
      q++; s++; \
    } \
  }

void
ca_select_fill (CArray *ca, CArray *select, char *valp)
{
  boolean8_t *s = (boolean8_t *) select->ptr;
  ca_size_t i;

  switch ( ca->bytes ) {
  case 1: proc_select_fill(int8_t); break;
  case 2: proc_select_fill(int16_t); break;
  case 4: proc_select_fill(int32_t); break;
  case 8: proc_select_fill(float64_t); break;
  default: {
    char *q = ca->ptr;
    ca_size_t bytes = ca->bytes;
    for (i=ca->elements; i; i--) {
      if ( *s ) {
        memcpy(q, valp, bytes);
      }
      q+=bytes; s++;
    }
    break;
  }
  }

}

/* ------------------------------------------------------------------- */

static VALUE
rb_cm_s_allocate (VALUE klass)
{
  CASelect *ca;
  return Data_Make_Struct(klass, CASelect, ca_mark, ca_free, ca);
}

static VALUE
rb_cm_initialize_copy (VALUE self, VALUE other)
{
  CASelect *ca, *cs;

  Data_Get_Struct(self,  CASelect, ca);
  Data_Get_Struct(other, CASelect, cs);

  /* share select info */
  ca_select_setup(ca, cs->parent, cs->select, 1);

  return self;
}

void
Init_ca_obj_select ()
{
  /* rb_cCASelect, CA_OBJ_SELECT are defined in rb_carray.c */
  rb_define_const(rb_cObject, "CA_OBJ_SELECT", INT2NUM(CA_OBJ_SELECT));

  rb_define_alloc_func(rb_cCASelect, rb_cm_s_allocate);
  rb_define_method(rb_cCASelect, "initialize_copy", rb_cm_initialize_copy, 1);
}

