/* ---------------------------------------------------------------------------

  carray_core.c

  This file is part of Ruby/CArray extension library.

  Copyright (C) 2005-2020 Hiroki Motoyoshi

---------------------------------------------------------------------------- */

#include "carray.h"
#include <stdarg.h>

/* definition of ca_endian */

#ifdef WORDS_BIGENDIAN
const int ca_endian = CA_BIG_ENDIAN;
#else
const int ca_endian = CA_LITTLE_ENDIAN;
#endif

/* definition of variables for ca_func mechanism */

VALUE ca_class[CA_OBJ_TYPE_MAX];
ca_operation_function_t ca_func[CA_OBJ_TYPE_MAX];
int ca_obj_num = 0;

/* 
   definition of validity of each data_type [1 for valid, 0 for invalid]

   The validity is determined in the configuration by extconf.rb.
*/

const int32_t
ca_valid[CA_NTYPE] = {
  1 /* fixlen type */,
#ifdef HAVE_TYPE_INT8_T
  1,
#else
  0,
#endif
#ifdef HAVE_TYPE_INT8_T
  1,
#else
  0,
#endif
#ifdef HAVE_TYPE_UINT8_T
  1,
#else
  0,
#endif
#ifdef HAVE_TYPE_INT16_T
  1,
#else
  0,
#endif
#ifdef HAVE_TYPE_UINT16_T
  1,
#else
  0,
#endif
#ifdef HAVE_TYPE_INT32_T
  1,
#else
  0,
#endif
#ifdef HAVE_TYPE_UINT32_T
  1,
#else
  0,
#endif
#ifdef HAVE_TYPE_INT64_T
  1,
#else
  0,
#endif
#ifdef HAVE_TYPE_UINT64_T
  1,
#else
  0,
#endif
#ifdef HAVE_TYPE_FLOAT32_T
  1,
#else
  0,
#endif
#ifdef HAVE_TYPE_FLOAT64_T
  1,
#else
  0,
#endif
#ifdef HAVE_TYPE_FLOAT128_T
  1,
#else
  0,
#endif
#ifdef HAVE_TYPE_CMPLX64_T
  1,
#else
  0,
#endif
#ifdef HAVE_TYPE_CMPLX128_T
  1,
#else
  0,
#endif
#ifdef HAVE_TYPE_CMPLX256_T
  1,
#else
  0,
#endif
  1
};

/* definition of ca_sizeof, the element data size */

const int32_t
ca_sizeof[CA_NTYPE] = {
  0 /* fixlen type */,
  sizeof(boolean8_t),
  sizeof(int8_t),
  sizeof(uint8_t),
  sizeof(int16_t),
  sizeof(uint16_t),
  sizeof(int32_t),
  sizeof(uint32_t),
  sizeof(int64_t),
  sizeof(uint64_t),
  sizeof(float32_t),
  sizeof(float64_t),
  sizeof(float128_t),
  sizeof(cmplx64_t),
  sizeof(cmplx128_t),
  sizeof(cmplx256_t),
  sizeof(VALUE),
};

/* definition of ca_type_name, the data type name */

const char *
ca_type_name[CA_NTYPE] = {
  "fixlen",
  "boolean",
  "int8",
  "uint8",
  "int16",
  "uint16",
  "int32",
  "uint32",
  "int64",
  "uint64",
  "float32",
  "float64",
  "float128",
  "cmplx64",
  "cmplx128",
  "cmplx256",
  "object",
};

/*
   casting table for ARRAY -> ARRAY

   test = ca_cast_table[ary1->data_type][ary2->data_type]

   test == 1  -> ary1 should be casted to ary2->data_type
   test == 0  -> ary1 need not to be casted
   test == -1 -> ary1 can't be casted to ary2->data_type,
                                         try casting for ary2 vs ary1
*/

const int
ca_cast_table[CA_NTYPE][CA_NTYPE] = {
/*      fix bol  i8  u8 i16 u16 i32 u32 i64 u64 f32 f64 f12 c64 c12 c25 obj */
/*fix*/ { 0, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,  1},
/*bol*/ {-1,  0,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1},
/* i8*/ {-1, -1,  0,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1},
/* u8*/ {-1, -1, -1,  0,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1},
/*i16*/ {-1, -1, -1, -1,  0,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1},
/*u16*/ {-1, -1, -1, -1, -1,  0,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1},
/*i32*/ {-1, -1, -1, -1, -1, -1,  0,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1},
/*u32*/ {-1, -1, -1, -1, -1, -1, -1,  0,  1,  1,  1,  1,  1,  1,  1,  1,  1},
/*i64*/ {-1, -1, -1, -1, -1, -1, -1, -1,  0,  1,  1,  1,  1,  1,  1,  1,  1},
/*u64*/ {-1, -1, -1, -1, -1, -1, -1, -1, -1,  0,  1,  1,  1,  1,  1,  1,  1},
/*f32*/ {-1, -1, -1, -1, -1, -1, -1, -1, -1, -1,  0,  1,  1,  1,  1,  1,  1},
/*f64*/ {-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,  0,  1,  1,  1,  1,  1},
/*f12*/ {-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,  0,  1,  1,  1,  1},
/*c64*/ {-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,  0,  1,  1,  1},
/*c12*/ {-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,  0,  1,  1},
/*c25*/ {-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,  0,  1},
/*obj*/ {-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,  0},
};

/*
   casting table for SCALAR -> ARRAY

   test = ca_cast_table[scl->data_type][ary->data_type]

   test == 1  -> scl should be casted to ary->data_type
   test == 0  -> scl need not to be casted
   test == -1 -> scl can't be casted to ary->data_type
*/

const int
ca_cast_table2[CA_NTYPE][CA_NTYPE] = {
/*      fix bol  i8  u8 i16 u16 i32 u32 i64 u64 f32 f64 f12 c64 c12 c25 obj */
/*fix*/ { 0, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,  1},
/*bol*/ {-1,  0,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1},
/* i8*/ {-1, -1,  0,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1},
/* u8*/ {-1, -1,  1,  0,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1},
/*i16*/ {-1, -1,  1,  1,  0,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1},
/*u16*/ {-1, -1,  1,  1,  1,  0,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1},
/*i32*/ {-1, -1,  1,  1,  1,  1,  0,  1,  1,  1,  1,  1,  1,  1,  1,  1,  1},
/*u32*/ {-1, -1,  1,  1,  1,  1,  1,  0,  1,  1,  1,  1,  1,  1,  1,  1,  1},
/*i64*/ {-1, -1,  1,  1,  1,  1,  1,  1,  0,  1,  1,  1,  1,  1,  1,  1,  1},
/*u64*/ {-1, -1,  1,  1,  1,  1,  1,  1,  1,  0,  1,  1,  1,  1,  1,  1,  1},
/*f32*/ {-1, -1, -1, -1, -1, -1, -1, -1, -1, -1,  0,  1,  1,  1,  1,  1,  1},
/*f64*/ {-1, -1, -1, -1, -1, -1, -1, -1, -1, -1,  1,  0,  1,  1,  1,  1,  1},
/*f12*/ {-1, -1, -1, -1, -1, -1, -1, -1, -1, -1,  1,  1,  0,  1,  1,  1,  1},
/*c64*/ {-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,  0,  1,  1,  1},
/*c12*/ {-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,  1,  0,  1,  1},
/*c25*/ {-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,  1,  1,  0,  1},
/*obj*/ {-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,  0},
};

/* ------------------------------------------------------------------- */

/*
  initialization of fundamental classes
    * CArray
    * CAWrap
    * CScalar
    * CARefer
    * CABlock
    * CASelect
    * CAObject
    * CARepeat
    * CAUnboundRepeat
*/

void
ca_init_obj_type ()
{
  extern ca_operation_function_t ca_array_func;
  extern ca_operation_function_t ca_wrap_func;
  extern ca_operation_function_t ca_scalar_func;
  extern ca_operation_function_t ca_refer_func;
  extern ca_operation_function_t ca_block_func;
  extern ca_operation_function_t ca_select_func;
  extern ca_operation_function_t ca_object_func;
  extern ca_operation_function_t ca_repeat_func;
  extern ca_operation_function_t ca_ubrep_func;

  /* CArray */
  ca_func[CA_OBJ_ARRAY]       = ca_array_func;
  ca_class[CA_OBJ_ARRAY]      = rb_cCArray;

  /* CAWrap */
  ca_func[CA_OBJ_ARRAY_WRAP]  = ca_wrap_func;
  ca_class[CA_OBJ_ARRAY_WRAP] = rb_cCAWrap;

  /* CAScalar */
  ca_func[CA_OBJ_SCALAR]      = ca_scalar_func;
  ca_class[CA_OBJ_SCALAR]     = rb_cCScalar;

  /* CARefer */
  ca_func[CA_OBJ_REFER]       = ca_refer_func;
  ca_class[CA_OBJ_REFER]      = rb_cCARefer;

  /* CABlock */
  ca_func[CA_OBJ_BLOCK]       = ca_block_func;
  ca_class[CA_OBJ_BLOCK]      = rb_cCABlock;

  /* CASelect */
  ca_func[CA_OBJ_SELECT]      = ca_select_func;
  ca_class[CA_OBJ_SELECT]     = rb_cCASelect;

  /* CAObject */
  ca_func[CA_OBJ_OBJECT]      = ca_object_func;
  ca_class[CA_OBJ_OBJECT]     = rb_cCAObject;

  /* CARepeat */
  ca_func[CA_OBJ_REPEAT]      = ca_repeat_func;
  ca_class[CA_OBJ_REPEAT]     = rb_cCARepeat;

  /* CAUnboundRepeat */
  ca_func[CA_OBJ_UNBOUND_REPEAT]  = ca_ubrep_func;
  ca_class[CA_OBJ_UNBOUND_REPEAT] = rb_cCAUnboundRepeat;

  ca_obj_num = 9;
}

/* api: ca_install_obj_type
   regsters a sub-class of CArray 
*/

int
ca_install_obj_type (VALUE klass, ca_operation_function_t func)
{
  int obj_type  = ca_obj_num++;

  if ( ca_obj_num >= CA_OBJ_TYPE_MAX ) {
    rb_raise(rb_eRuntimeError,
             "too many CArray object types installed <CA_OBJ_TYPE_MAX = %i>",
             CA_OBJ_TYPE_MAX);
  }

  func.obj_type      = obj_type;

  ca_class[obj_type] = klass;
  ca_func[obj_type]  = func;

  return obj_type;
}

/* ------------------------------------------------------------------- */

/* api: ca_mark
   mark function for any carray object
*/

void
ca_mark (void *ap)
{
  CArray *ca = (CArray *) ap;

  if ( ca_is_object_type(ca) ) {    /* object type array */
    if ( ca_is_attached(ca) ) { /* entity array */
      VALUE *p = (VALUE*) ca->ptr;
      ca_size_t n = ca->elements;
      while ( n-- ) {
        rb_gc_mark(*p++);
      }
    }
  }
}

/* api: ca_free
   free function for the carray object needs free operation.
*/

void
ca_free (void *ap)
{
  if ( ap ) {
    CArray *ca = (CArray *) ap;
    ca_func[ca->obj_type].free_object(ap); /* delegate */
  }
}

/* api: ca_free_nop
   (dummy) free function for the carray object does not need free operation.
*/

void
ca_free_nop (void *ap)
{
}

/* ------------------------------------------------------------------- */

/* api: ca_wrap_struct
   wraps CArray struct in C -> Ruby's object 
*/

VALUE
ca_wrap_struct (void *ap)
{
  CArray *ca = (CArray *) ap;
  return Data_Wrap_Struct(ca_class[ca->obj_type], ca_mark, ca_free, ca);
}

/* ------------------------------------------------------------------- */

/* calculate index from address */

void
ca_addr2index (void *ap, ca_size_t addr, ca_size_t *idx)
{
  CArray *ca = (CArray *) ap;
  ca_size_t *dim = ca->dim;
  int8_t i;
  for (i=ca->ndim-1; i>=0; i--) {
    idx[i] = addr % dim[i];
    addr  /= dim[i];
  }
}

/* calculate address from index */

ca_size_t
ca_index2addr (void *ap, ca_size_t *idx)
{
  CArray  *ca  = (CArray *) ap;
  ca_size_t *dim = ca->dim;
  int8_t   i;
  ca_size_t  n;
  n = idx[0];
  for (i=1; i<ca->ndim; i++) {
    n = dim[i]*n+idx[i];
  }
  return n;
}

/* ------------------------------------------------------------------- */

/* The cyclic reference detection should be done in 
     + ca_fetch_addr, ca_fetch_index,
     + ca_store_addr, ca_store_index,
  to avoid the system stack error in reference of the object array.
*/

void
ca_set_cyclic_check(void *ap)
{
  CArray *ca = (CArray *) ap;
  /* ca.data_type == CA_OBJECT */
  if ( ca_is_object_type(ca) ) {
    if ( ca->flags & CA_FLAG_CYCLE_CHECK ) {
      rb_raise(rb_eRuntimeError, "cyclic reference is not allowed in CArray");
    }
    ca_set_flag(ca, CA_FLAG_CYCLE_CHECK);
  }
}

void
ca_clear_cyclic_check(void *ap)
{
  CArray *ca = (CArray *) ap;
  /* ca.data_type == CA_OBJECT */
  if ( ca_is_object_type(ca) ) {
    ca_unset_flag(ca, CA_FLAG_CYCLE_CHECK);
  }
}

void
ca_test_cyclic_check(void *ap, void *ptr)
{
  CArray *ca = (CArray *) ap;

  /* ca.data_type == CA_OBJECT */
  if ( ca_is_object_type(ca) ) {
    VALUE rval = *(VALUE*) ptr;
    if ( rb_obj_is_carray(rval) ) {
      CArray *cv;
      Data_Get_Struct(rval, CArray, cv);
      if ( ca_test_flag(cv, CA_FLAG_CYCLE_CHECK) ) {
        rb_raise(rb_eRuntimeError, "cyclic reference is not allowed in CArray");
      }
    }
  }
}

/* ------------------------------------------------------------------- */

/* return pointer of the element at given address */

void *
ca_ptr_at_addr (void *ap, ca_size_t addr)
{
  CArray *ca = (CArray *) ap;

  if ( ca->ptr ) {
    switch ( ca->obj_type ) {
    case CA_OBJ_SCALAR:
      return ca->ptr;
    case CA_OBJ_REFER:
      return ((CARefer*)ca)->parent->ptr + ca->bytes * addr;
    default:
      return ca->ptr + ca->bytes * addr;
    }
  }

  return ca_func[ca->obj_type].ptr_at_addr(ap, addr);
}

/* return pointer of the element at given index */

void *
ca_ptr_at_index (void *ap, ca_size_t *idx)
{
  CArray *ca = (CArray *) ap;
  return ca_func[ca->obj_type].ptr_at_index(ca, idx);
}

/* fetch data of the element at given address to memory pointed by pval */

void
ca_fetch_addr (void *ap, ca_size_t addr, void *pval)
{
  CArray *ca = (CArray *) ap;
  char *ptr  = (char *)pval;

  ca_set_cyclic_check(ca);

  if ( ca->ptr ) {
    memcpy(ptr, ca->ptr + ca->bytes * addr, ca->bytes);
  }
  else if ( ca_func[ca->obj_type].fetch_addr ) { 
    ca_func[ca->obj_type].fetch_addr(ca, addr, ptr);
  }
  else if ( ca_func[ca->obj_type].fetch_index ) { /* delegate -> fetch_index */
    ca_size_t idx[CA_RANK_MAX];
    ca_addr2index(ca, addr, idx);
    ca_func[ca->obj_type].fetch_index(ca, idx, ptr);
  }
  else {
    rb_raise(rb_eRuntimeError,
             "[BUG] fetch_addr or fetch_index " \
             "are not defined for object type <%i>",
             ca->obj_type);
  }

  ca_test_cyclic_check(ca, ptr);

  ca_clear_cyclic_check(ca);
}

/* store value pointed by pval to the element at given address */

void
ca_store_addr (void *ap, ca_size_t addr, void *pval)
{
  CArray *ca = (CArray *) ap;
  char *ptr = (char *)pval;

  if ( ca_is_readonly(ca) ) {  /* read only array */
    rb_raise(rb_eRuntimeError,
             "can not store data to read-only array");
  }

  ca_set_cyclic_check(ca);

  if ( ca->ptr ) {
    memcpy(ca->ptr + ca->bytes * addr, ptr, ca->bytes);
  }
  else if ( ca_func[ca->obj_type].store_addr ) {
    ca_func[ca->obj_type].store_addr(ca, addr, ptr);
  }
  else if ( ca_func[ca->obj_type].store_index ) { /* delegate -> store_index */
    ca_size_t idx[CA_RANK_MAX];
    ca_addr2index(ca, addr, idx);
    ca_func[ca->obj_type].store_index(ca, idx, ptr);
  }
  else {
    ca_clear_cyclic_check(ca);
    rb_raise(rb_eRuntimeError,
             "[BUG] store_addr or store_index "\
             "are not defined for object type <%i>",
             ca->obj_type);
  }
  
  ca_clear_cyclic_check(ca);

}

/* fetch data of the element at given index to memory pointed by pval */

void
ca_fetch_index (void *ap, ca_size_t *idx, void *pval)
{
  CArray *ca = (CArray *) ap;
  char *ptr = (char *)pval;

  ca_set_cyclic_check(ca);

  if ( ca_func[ca->obj_type].fetch_index ) {
    ca_func[ca->obj_type].fetch_index(ca, idx, ptr);
  }
  else if ( ca_func[ca->obj_type].fetch_addr ) { /* delegate -> fetch_addr */
    ca_size_t addr = ca_index2addr(ca, idx);
    ca_func[ca->obj_type].fetch_addr(ca, addr, ptr);
  }
  else {
    ca_clear_cyclic_check(ca);      
    rb_raise(rb_eRuntimeError,
             "[BUG] fetch_addr or fetch_index " \
             "are not defined for object type <%i>",
             ca->obj_type);
  }

  ca_test_cyclic_check(ca, ptr);

  ca_clear_cyclic_check(ca);
}

/* store value pointed by pval to the element at given index */

void
ca_store_index (void *ap, ca_size_t *idx, void *pval)
{
  CArray *ca = (CArray *) ap;
  char *ptr = (char *) pval;

  if ( ca_is_readonly(ca) ) { /* read only array */
    rb_raise(rb_eRuntimeError,
             "can not store data to read-only array");
  }

  ca_set_cyclic_check(ca);

  if ( ca_func[ca->obj_type].store_index ) {
    ca_func[ca->obj_type].store_index(ca, idx, ptr);
  }
  else if ( ca_func[ca->obj_type].store_addr ) { /* delegate -> store_addr */
    ca_size_t addr = ca_index2addr(ca, idx);
    ca_func[ca->obj_type].store_addr(ca, addr, ptr);
  }
  else {
    rb_raise(rb_eRuntimeError,
             "[BUG] store_addr or store_index "\
             "are not defined for object type <%i>",
             ca->obj_type);
  }

  ca_clear_cyclic_check(ca);

}

/* ------------------------------------------------------------------- */

/* make ca->ptr to point the allocated memory block */

void
ca_allocate (void *ap)
{
  CArray *ca = (CArray *) ap;

  if ( ! ca ) {
    return;
  }

  if ( ca_is_virtual(ca) ) {  /* virtual array */

    CAVIRTUAL(ca)->attach += 1; /* increments attach level */
    if ( CAVIRTUAL(ca)->attach > CA_ATTACH_MAX ) {
      rb_raise(rb_eRuntimeError,
               "too large attach count of virtual array");
    }

    if ( ! ca->ptr ) {
      ca_func[ca->obj_type].allocate(ap);
    }
  }
  else {                      /* entity array */
    ca_func[ca->obj_type].allocate(ap);
  }

  if ( ca->data_type == CA_OBJECT ) { /* protection against GC */
    volatile VALUE rzero = INT2NUM(0);
    VALUE *p = (VALUE*)ca->ptr;
    ca_size_t i;
    for (i=0; i<ca->elements; i++) {
      *p++ = rzero;
    }
  }

  ca_clear_mask(ca); /* ca_update_mask called in ca_clear_mask */
  ca_allocate(ca->mask);
}

/* attach parent's data to ca->ptr */

void
ca_attach (void *ap)
{
  CArray *ca = (CArray *) ap;

  if ( ! ca ) {
    return;
  }

  if ( ca_is_virtual(ca) ) {  /* virtual array */

    CAVIRTUAL(ca)->attach += 1; /* increments attach level */
    if ( CAVIRTUAL(ca)->attach > CA_ATTACH_MAX ) {
      rb_raise(rb_eRuntimeError,
               "too large attach count of virtual array");
    }

    if ( ! ca->ptr ) {
      ca_func[ca->obj_type].attach(ap);
    }
  }
  else {                      /* entity array */
    ca_func[ca->obj_type].attach(ap);
  }

  ca_update_mask(ca);
  ca_attach(ca->mask);
}

/* attach parent's data to ca->ptr */

void
ca_update (void *ap)
{
  CArray *ca = (CArray *) ap;

  if ( ! ca ) {
    return;
  }

  if ( ca_is_virtual(ca) ) {  /* virtual array */

    if ( ca->ptr ) {
      ca_func[ca->obj_type].copy_data(ca, ca->ptr);
    }
    else {
      rb_raise(rb_eRuntimeError, 
        "[BUG] ca_update() called for not-attached virtal array");
    }

  }

  ca_update_mask(ca);
  ca_update(ca->mask);
}

/* synchronize the data pointed by ca->ptr to parent's memory block */

void
ca_sync (void *ap)
{
  CArray *ca = (CArray *) ap;

  if ( ! ca ) {
    return;
  }

  if ( ! ca->ptr ) {
    rb_raise(rb_eRuntimeError,
             "[BUG] tried to sync data to detached array");
  }

  if ( ca_is_readonly(ca) ) {
    rb_raise(rb_eRuntimeError,
             "can not modify read-only array");
  }

  ca_update_mask(ca);
  ca_sync(ca->mask);

  if ( ca_is_virtual(ca) ) {  /* virtual array */
    if ( ! CAVIRTUAL(ca)->nosync ) { /* FIXME : */
      ca_func[ca->obj_type].sync(ap);
    }
  }
  else {                      /* enitity array */
    ca_func[ca->obj_type].sync(ap);
  }

}

/* make ca->ptr to be detached */

void
ca_detach (void *ap)
{
  CArray *ca = (CArray *) ap;

  if ( ! ca ) {
    return;
  }

  if ( ! ca->ptr ) {
    rb_raise(rb_eRuntimeError,
             "[BUG] tried to detach a detached array");
  }

  if ( ca_is_virtual(ca) ) {  /* virtual array */
    if ( CAVIRTUAL(ca)->attach == 1 ) {
      ca_func[ca->obj_type].detach(ap);
    }
    CAVIRTUAL(ca)->attach -= 1;
  }
  else {                      /* entity array */
    ca_func[ca->obj_type].detach(ap);
  }

  ca_update_mask(ca);
  ca_detach(ca->mask);
}

/* multiple versions of ca_allocate, ca_attach, ca_sync, ca_detach */

void
ca_allocate_n (int n, ...)
{
  va_list args;
  va_start(args, n);
  while ( n-- ) {
    ca_allocate(va_arg(args, CArray *));
  }
  va_end(args);
}

void
ca_attach_n (int n, ...)
{
  va_list args;
  va_start(args, n);
  while ( n-- ) {
    ca_attach(va_arg(args, CArray *));
  }
  va_end(args);
}

void
ca_update_n (int n, ...)
{
  va_list args;
  va_start(args, n);
  while ( n-- ) {
    ca_update(va_arg(args, CArray *));
  }
  va_end(args);
}

void
ca_sync_n (int n, ...)
{
  va_list args;
  va_start(args, n);
  while ( n-- ) {
    ca_sync(va_arg(args, CArray *));
  }
  va_end(args);
}

void
ca_detach_n (int n, ...)
{
  va_list args;
  va_start(args, n);
  while ( n-- )
    ca_detach(va_arg(args, CArray *));
  va_end(args);
}

/* ------------------------------------------------------------------- */

/* attach parent's data to given pointer, not to ca->ptr */

void
ca_copy_data (void *ap, char *ptr)
{
  CArray *ca = (CArray *) ap;
  ca_func[ca->obj_type].copy_data(ap, ptr); /* delegate */
}

/* synchronize the data pointed by given pointer to parent's data */

void
ca_sync_data (void *ap, char *ptr)
{
  CArray *ca = (CArray *) ap;

  if ( ca_is_readonly(ca) ) {
    rb_raise(rb_eRuntimeError,
             "can not sync data to read-only array");
  }

  if ( ca_is_virtual(ca) ) {  /* virtual array */
    if ( CAVIRTUAL(ca)->nosync ) { /* ca is to be attached */
      ca_func[CA_OBJ_ARRAY].sync_data(ap, ptr);
    }
    else {
      ca_func[ca->obj_type].sync_data(ap, ptr);
    }
  }
  else {                      /* entity array */
    ca_func[ca->obj_type].sync_data(ap, ptr);
  }
}

/* fill data from given pointer */

void
ca_fill_data (void *ap, void *aptr)
{
  CArray *ca = (CArray *) ap;
  char *ptr = (char *) aptr;

  if ( ca_is_readonly(ca) ) {
    rb_raise(rb_eRuntimeError,
             "can not fill data to read-only array");
  }

  if ( ca_is_virtual(ca) ) {   /* virtual array */
    if ( ca_is_attached(ca) ) { /* ca is to be attached */
      ca_func[CA_OBJ_ARRAY].fill_data(ap, ptr);
    }
    else {
      ca_func[ca->obj_type].fill_data(ap, ptr);
    }
  }
  else {                       /* entity array */
    ca_func[ca->obj_type].fill_data(ap, ptr);
  }
}

/* ------------------------------------------------------------------- */

/* clone CArray struct */

void *
ca_clone (void *ap)
{
  CArray *ca = (CArray *) ap;
  return ca_func[ca->obj_type].clone(ap);
}

/* fill parent's data with the data pointed by aptr */

void
ca_fill (void *ap, void *aptr)
{
  CArray *ca = (CArray *) ap;
  char *ptr = (char *) aptr;

  if ( ca_is_readonly(ca) ) {
    rb_raise(rb_eRuntimeError, "can't fill read-only carray");
  }

  ca_fill_data(ap, ptr);
}

/* ------------------------------------------------------------------- */

/* subroutines for CArray.attach, CArray.attach!
                   CArray#attach, CArray#attach! */

static void
rb_ca_attach_i (VALUE self)
{
  CArray *ca;
  if ( rb_obj_is_carray(self) ) {
    Data_Get_Struct(self, CArray, ca);
    ca_attach(ca);
    if ( ca_is_virtual(ca) ) {
      CAVIRTUAL(ca)->nosync += 1;
      if ( CAVIRTUAL(ca)->nosync > 64 ) {
        rb_raise(rb_eRuntimeError, "nosync count exceeds 64");
      }
    }
  }
}

static void
rb_ca_sync_i (VALUE self)
{
  CArray *ca;
  if ( rb_obj_is_carray(self) ) {
    Data_Get_Struct(self, CArray, ca);
    if ( ca_is_virtual(ca) ) {
      CAVIRTUAL(ca)->nosync -= 1;
      ca_sync(ca);
      CAVIRTUAL(ca)->nosync += 1;
    }
    else {
      ca_sync(ca);
    }
  }
}

static void
rb_ca_detach_i (VALUE self) 
{
  CArray *ca;
  if ( rb_obj_is_carray(self) ) {
    Data_Get_Struct(self, CArray, ca);
    if ( ca_is_virtual(ca) ) {   /* virtual array */
      CAVIRTUAL(ca)->nosync -= 1;
      ca_detach(ca);
    }
    else {                       /* entity array */
      ca_detach(ca);
    }
  }
}

/* ------------------------------------------------------------------- */

static VALUE
rb_ca_s_ensure_detach (VALUE list)
{
  volatile VALUE obj;
  int i;

  for (i=0; i<RARRAY_LEN(list); i++) {
    obj = rb_ary_entry(list, i);
    rb_ca_detach_i(obj);
  }

  return Qnil;
}

/* yard:
  def CArray.attach(*argv) # :nodoc:
    yield
  end
*/

static VALUE
rb_ca_s_attach (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE list, obj;
  int i;

  list = rb_ary_new4(argc, argv);

  for (i=0; i<RARRAY_LEN(list); i++) {
    obj = rb_ary_entry(list, i);
    rb_ca_attach_i(obj);
  }

  return rb_ensure(rb_yield_splat, list, rb_ca_s_ensure_detach, list);
}

static VALUE
rb_ca_s_ensure_sync_detach (VALUE list)
{
  volatile VALUE obj;
  int i;

  for (i=0; i<RARRAY_LEN(list); i++) {
    obj = rb_ary_entry(list, i);
    rb_ca_sync_i(obj);
    rb_ca_detach_i(obj);
  }

  return Qnil;
}

/* yard:
  def CArray.attach!(*argv) # :nodoc:
    yield
  end
*/

static VALUE
rb_ca_s_attach_bang (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE list, obj;
  int i;

  list = rb_ary_new4(argc, argv);

  for (i=0; i<RARRAY_LEN(list); i++) {
    obj = rb_ary_entry(list, i);
    rb_ca_modify(obj);
    rb_ca_attach_i(obj);
  }

  return rb_ensure(rb_yield_splat, list, rb_ca_s_ensure_sync_detach, list);
}

static VALUE
rb_ca_ensure_detach (VALUE self)
{
  rb_ca_detach_i(self);
  return Qnil;
}

/* yard:
  class CArray
    def attach () # :nodoc:
      yield
    end
  end
*/

static VALUE
rb_ca_attach (VALUE self)
{
  rb_ca_attach_i(self);
  return rb_ensure(rb_yield, self, rb_ca_ensure_detach, self);
}

static VALUE
rb_ca_ensure_sync_detach (VALUE self)
{
  rb_ca_sync_i(self);
  rb_ca_detach_i(self);
  return Qnil;
}

/* yard:
  class CArray
    def attach! () # :nodoc:
      yield
    end
  end
*/

static VALUE
rb_ca_attach_bang (VALUE self)
{
  rb_ca_modify(self);
  rb_ca_attach_i(self);
  return rb_ensure(rb_yield, self, rb_ca_ensure_sync_detach, self);
}

/* CArray#__attach__ */

static VALUE
rb_ca__attach__ (VALUE self)
{
  rb_ca_attach_i(self);
  return self;
}

/* CArray#__sync__ */

static VALUE
rb_ca__sync__ (VALUE self)
{
  rb_ca_modify(self);
  rb_ca_sync_i(self);
  return self;
}

/* CArray#__detach__ */

static VALUE
rb_ca__detach__ (VALUE self)
{
  rb_ca_detach_i(self);
  return self;
}

/* ------------------------------------------------------------------- */

static ID id_decode, id_encode;

VALUE
rb_ca_data_class_decode (VALUE self, VALUE str)
{
  if ( rb_ca_has_data_class(self) ) {
    volatile VALUE data_class = rb_ca_data_class(self);
    return rb_funcall(data_class, id_decode, 1, str);
  }
  else {
    return str;
  }
}

VALUE
rb_ca_data_class_encode (VALUE self, VALUE obj)
{
  if ( rb_ca_has_data_class(self) ) {
    volatile VALUE data_class = rb_ca_data_class(self);
    if ( rb_obj_is_kind_of(obj, data_class) ) {
      return rb_funcall(obj, id_encode, 0);
    }
  }
  return obj;
}

/* ------------------------------------------------------------------- */

/* yard:
  class CArray
    # Returns data class member names
    def members
    end
  end
*/

VALUE
rb_ca_members (VALUE self)
{
  VALUE data_class = rb_ca_data_class(self);
  if ( NIL_P(data_class) ) {
    rb_raise(rb_eRuntimeError, "carray doesn't have data class");
  }
  else {
    return rb_obj_clone(rb_const_get(data_class, rb_intern("MEMBERS")));
  }
}

VALUE
rb_ca_field_as_member (VALUE self, VALUE sym)
{
  VALUE data_class = rb_ca_data_class(self);
  VALUE member;
  VALUE obj;

  if ( NIL_P(data_class) ) {
    rb_raise(rb_eRuntimeError, "carray doesn't have data class");
  }

  member = rb_ivar_get(self, rb_intern("member"));

  if ( NIL_P(member) ) {
    rb_raise(rb_eRuntimeError,
             "[BUG] instance variable member doesn't defined "\
             "for data_class array");
  }

  if ( TYPE(sym) == T_SYMBOL ) {
    sym = rb_funcall(sym, rb_intern("to_s"), 0);
  }
  else if ( rb_obj_is_kind_of(sym, rb_cInteger) ) {
    VALUE member_names = rb_const_get(data_class, rb_intern("MEMBERS"));
    sym = rb_ary_entry(member_names, NUM2SIZE(sym));
  }

  obj = rb_hash_aref(member, sym);

  if ( rb_obj_is_carray(obj) ) {
    return obj;
  }
  else {
    VALUE MEMBER_TABLE = rb_const_get(data_class, rb_intern("MEMBER_TABLE"));
    VALUE info = rb_hash_aref(MEMBER_TABLE, sym);
    if ( NIL_P(info) ) {
      rb_raise(rb_eRuntimeError,
               "can't find data_member named <%s>", StringValuePtr(sym));
    }
    Check_Type(info, T_ARRAY);
    obj = rb_apply(self, rb_intern("field"), info);
    rb_hash_aset(member, sym, obj);
    return obj;
  }
}

/* yard:
  class CArray
    # Returns an array of data class members (fields)
    def fields
    end
  end
*/

VALUE
rb_ca_fields (VALUE self)
{
  VALUE data_class = rb_ca_data_class(self);
  volatile VALUE member_names, list;
  int i;
  if ( NIL_P(data_class) ) {
    rb_raise(rb_eRuntimeError, "carray doesn't have data class");
  }
  member_names = rb_const_get(data_class, rb_intern("MEMBERS"));
  list = rb_ary_new2(RARRAY_LEN(member_names));
  for (i=0; i<RARRAY_LEN(member_names); i++) {
    VALUE name = rb_ary_entry(member_names, i);
    rb_ary_store(list, i, rb_ca_field_as_member(self, name));
  }
  return list;
}

/* yard:
  class CArray
    # Returns an array of data class members (fields) with names specified 
    def fields_at (*names)
    end
  end
*/

VALUE
rb_ca_fields_at (int argc, VALUE *argv, VALUE self)
{
  VALUE data_class = rb_ca_data_class(self);
  volatile VALUE member_names, list;
  int i;
  if ( NIL_P(data_class) ) {
    rb_raise(rb_eRuntimeError, "carray doesn't have data class");
  }
  member_names = rb_ary_new4(argc, argv);
  list = rb_ary_new2(RARRAY_LEN(member_names));
  for (i=0; i<RARRAY_LEN(member_names); i++) {
    VALUE name = rb_ary_entry(member_names, i);
    rb_ary_store(list, i, rb_ca_field_as_member(self, name));
  }
  return list;
}

/* ------------------------------------------------------------------- */

void
Init_carray_core ()
{
  id_decode = rb_intern("decode");
  id_encode = rb_intern("encode");

  ca_init_obj_type();

  rb_define_singleton_method(rb_cCArray, "attach", rb_ca_s_attach, -1);
  rb_define_singleton_method(rb_cCArray, "attach!", rb_ca_s_attach_bang, -1);

  rb_define_method(rb_cCArray, "attach", rb_ca_attach, 0);
  rb_define_method(rb_cCArray, "attach!", rb_ca_attach_bang, 0);

  rb_define_method(rb_cCArray, "__attach__", rb_ca__attach__, 0);
  rb_define_method(rb_cCArray, "__sync__", rb_ca__sync__, 0);
  rb_define_method(rb_cCArray, "__detach__", rb_ca__detach__, 0);

  rb_define_method(rb_cCArray, "members", rb_ca_members, 0);

  rb_define_method(rb_cCArray, "fields", rb_ca_fields, 0);
  rb_define_method(rb_cCArray, "fields_at", rb_ca_fields_at, -1);
}

