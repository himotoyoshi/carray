/* ---------------------------------------------------------------------------

  ca_obj_array.c

  This file is part of Ruby/CArray extension library.
  You can redistribute it and/or modify it under the terms of
  the Ruby Licence.

  Copyright (C) 2005 Hiroki Motoyoshi

---------------------------------------------------------------------------- */

#include "carray.h"
#if RUBY_VERSION_CODE < 190
#include "rubysig.h"
#endif

/* ------------------------------------------------------------------- */

VALUE rb_cCArray, rb_cCAWrap, rb_cCScalar, rb_cCAVirtual;

/* rdoc:
  class CArray
  end
  class CAWrap < CArray   # :nodoc:
  end
  class CScalar < CArray
  end
  class CAVirtual < CArray # :nodoc:
  end
*/

/* ------------------------------------------------------------------- */

/* Monitering newly allocated memory size to do gc at appropreate timing */
/* This GC technique is based on NArray library.                         */

/* monitoring memory usage */

double ca_mem_usage = 0.0;
double ca_mem_count = 0.0;

/* Threshold for forced garbage collection and its default value */
double ca_gc_interval; 
const double ca_default_gc_interval = 100.0; /* 100MB */

#define MB (1024*1024)

static void
ca_check_mem_count()
{
  VALUE is_gc_disabled = rb_gc_enable();
  if ( is_gc_disabled ) {
    rb_gc_disable();
    return;
  }
  else if ( ca_mem_count > (ca_gc_interval * MB) ) {
    rb_gc();
    ca_mem_count = 0;
  }
}

/* rdoc:
  # returns the threshold of incremented memory (MB) used by carray object 
  # until start GC.
  def CArray.gc_interval ()
  end
  # set the threshold of incremented memory (MB) used by carray object
  # until start GC.
  def CArray.gc_interval= (val)
  end
  # reset the counter for the GC start when the incremented memory 
  # get larger than `CArray.gc_interval`.
  def CArray.reset_gc_interval ()
  end
*/

static VALUE
rb_ca_get_gc_interval (VALUE self)
{
  return rb_float_new(ca_gc_interval);
}

static VALUE
rb_ca_set_gc_interval (VALUE self, VALUE rth)
{
  double th = NUM2INT(rth);
  if ( th <= 0 ) {
    th = 0;
  }
  ca_gc_interval = th;
  return rb_float_new(ca_gc_interval);
}

static VALUE
rb_ca_reset_gc_interval (VALUE self)
{
  ca_gc_interval = ca_default_gc_interval;
  return rb_float_new(ca_gc_interval);
}


/* ------------------------------------------------------------------- */

/*
  internal routine for carray_setup, carray_safe_setup,
  carray_wrap_setup

    flag for    CArray   CArray(Safe)  CAWrap
   =========== ======== ============= =========
    allocate       1           1          0
    use_calloc     0           1          0
   =========== ======== ============= =========

   safe -> filled by 0
*/

static int
carray_setup_i (CArray *ca,
                int8_t data_type, int8_t ndim, ca_size_t *dim, ca_size_t bytes,
                CArray *mask, int allocate, int use_calloc)
{
  ca_size_t elements;
  double  length;
  int8_t i;
  ca_size_t k;

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
    length *= dim[i];
  }

  if ( length > CA_LENGTH_MAX ) {
    rb_raise(rb_eRuntimeError, "too large byte length");
  }

  /* set values to the struct members */
  if ( allocate ) {
    ca->obj_type = CA_OBJ_ARRAY;
  }
  else {
    ca->obj_type = CA_OBJ_ARRAY_WRAP;
  }

  ca->data_type = data_type;
  ca->flags     = 0;
  ca->ndim      = ndim;
  ca->bytes     = bytes;
  ca->elements  = elements;
  ca->dim       = ALLOC_N(ca_size_t, ndim);
  memcpy(ca->dim, dim, ndim*sizeof(ca_size_t));

  if ( allocate ) {                                      /* allocate == true */

    /* allocate memory for entity */
    if ( use_calloc ) {
      /* ca->ptr = ALLOC_N(char, elements * bytes); */
      ca->ptr = malloc_with_check(elements * bytes);
      MEMZERO(ca->ptr, char, elements * bytes);
    }
    else {
      /* ca->ptr = ALLOC_N(char, elements * bytes); */
      ca->ptr = malloc_with_check(elements * bytes);
    }

    ca_mem_count += (double)(ca_length(ca));
    ca_mem_usage += (double)(ca_length(ca));

    /* initialize elements with Qnil for CA_OBJECT data_type */
    if ( allocate && data_type == CA_OBJECT ) {
      volatile VALUE zero = SIZE2NUM(0);
      VALUE *p = (VALUE *) ca->ptr;
      for (k=0; k<elements; k++) {
        *p++ = zero;
      }
    }

  }
  else {                                                 /* allocate == false */
    ca->ptr = NULL;
  }

  ca->mask = NULL;
  if ( mask ) {
    ca_setup_mask(ca, mask);
  }

  ca_check_mem_count();

  return 0;
}

int
carray_setup (CArray *ca,
  int8_t data_type, int8_t ndim, ca_size_t *dim, ca_size_t bytes, CArray *mask)
{
  return carray_setup_i(ca, data_type, ndim, dim, bytes, mask, 1, 0);
}

int
carray_safe_setup (CArray *ca,
  int8_t data_type, int8_t ndim, ca_size_t *dim, ca_size_t bytes, CArray *mask)
{
  return carray_setup_i(ca, data_type, ndim, dim, bytes, mask, 1, 1);
}

int
ca_wrap_setup (CArray *ca,
               int8_t data_type, int8_t ndim, ca_size_t *dim, ca_size_t bytes,
               CArray *mask, char *ptr)
{
  int ret;

  ret = carray_setup_i(ca, data_type, ndim, dim, bytes, mask, 0, 0);
  if ( (!ptr) && (ca->elements != 0) ) {
    rb_raise(rb_eRuntimeError, "wrapping NULL pointer with an non-empty array");
  }
  ca->ptr = ptr;
  return ret;
}

int
ca_wrap_setup_null (CArray *ca,
                    int8_t data_type, int8_t ndim, ca_size_t *dim, ca_size_t bytes,
                    CArray *mask)
{
  int ret;

  ret = carray_setup_i(ca, data_type, ndim, dim, bytes, mask, 0, 0);
  ca->ptr = NULL;
  return ret;
}

CArray *
carray_new (int8_t data_type, int8_t ndim, ca_size_t *dim, ca_size_t bytes,
            CArray *mask)
{
  CArray *ca  = ALLOC(CArray);
  carray_setup(ca, data_type, ndim, dim, bytes, mask);
  return ca;
}

CArray *
carray_new_safe (int8_t data_type, int8_t ndim, ca_size_t *dim, ca_size_t bytes,
            CArray *mask)
{
  CArray *ca  = ALLOC(CArray);
  carray_safe_setup(ca, data_type, ndim, dim, bytes, mask);
  return ca;
}

CAWrap *
ca_wrap_new (int8_t data_type, int8_t ndim, ca_size_t *dim, ca_size_t bytes,
            CArray *mask, char *ptr)
{
  CAWrap *ca  = ALLOC(CAWrap);
  ca_wrap_setup(ca, data_type, ndim, dim, bytes, mask, ptr);
  return ca;
}

CAWrap *
ca_wrap_new_null (int8_t data_type, int8_t ndim, ca_size_t *dim, ca_size_t bytes,
                  CArray *mask)
{
  CAWrap *ca  = ALLOC(CAWrap);
  ca_wrap_setup_null(ca, data_type, ndim, dim, bytes, mask);
  return ca;
}

void
free_carray (void *ap)
{
  CArray *ca = (CArray *) ap;
  if ( ca != NULL ) {
    ca_mem_usage -= (double)(ca_length(ca));
    ca_free(ca->mask);
    free(ca->ptr);
    xfree(ca->dim);
    xfree(ca);
  }
}

void
free_ca_wrap (void *ap)
{
  CArray *ca = (CArray *) ap;
  if ( ca != NULL ) {
    /* free(ca->ptr); */ /* don't free ca->ptr for CAWrap */
    ca_free(ca->mask);
    xfree(ca->dim);
    xfree(ca);
  }
}

/* ------------------------------------------------------------------- */

static int
cscalar_setup (CScalar *ca,
               int8_t data_type, ca_size_t bytes, CArray *mask)
{
  CA_CHECK_DATA_TYPE(data_type);
  CA_CHECK_BYTES(data_type, bytes);

  ca->obj_type  = CA_OBJ_SCALAR;
  ca->data_type = data_type;
  ca->flags     = 0;
  ca->ndim      = 1;
  ca->bytes     = bytes;
  ca->elements  = 1;
  ca->dim       = &(ca->_dim);
  ca->ptr       = xmalloc(bytes);
  ca->mask      = NULL;

  ca->dim[0] = 1;

  ca_mem_usage += (double)(ca->bytes);

  if ( data_type == CA_OBJECT ) {
    *((VALUE*) ca->ptr) = SIZE2NUM(0);
  }
  else {
    MEMZERO(ca->ptr, char, ca->bytes);
  }

  if ( mask ) {
    ca_setup_mask((CArray *)ca, mask);
  }

  ca_set_flag(ca, CA_FLAG_SCALAR);

  return 0;
}

/*
 * constructs a CScalar struct without initialization
 */

CScalar *
cscalar_new (int8_t data_type, ca_size_t bytes, CArray *mask)
{
  CScalar *ca = ALLOC(CScalar);
  cscalar_setup(ca, data_type, bytes, mask);
  return ca;
}

/*
 * constructs a CScalar struct initialized with a value
 */

CScalar *
cscalar_new2 (int8_t data_type, ca_size_t bytes, char *val)
{
  CScalar *ca = ALLOC(CScalar);
  cscalar_setup(ca, data_type, bytes, NULL);
  memcpy(ca->ptr, val, ca->bytes);
  return ca;
}

/*
 * free a CScalar struct
 */

static void
free_cscalar (void *ap)
{
  CScalar *ca = (CScalar *) ap;
  if ( ca != NULL ) {
    ca_mem_usage -= (double)(ca->bytes);
    free(ca->ptr);
    ca_free(ca->mask);
    xfree(ca);
  }
}

/* ------------------------------------------------------------------- */

void *
ca_array_func_clone (void *ap)
{
  CArray *ca = (CArray *) ap;
  CArray *co;
  co = carray_new(ca->data_type, ca->ndim, ca->dim, ca->bytes, ca->mask);
  memcpy(co->ptr, ca->ptr, ca_length(ca));
  return co;
}

char *
ca_array_func_ptr_at_addr (void *ap, ca_size_t addr)
{
  CArray *ca = (CArray *) ap;
  return ca->ptr + ca->bytes * addr;
}

char *
ca_array_func_ptr_at_index (void *ap, ca_size_t *idx)
{
  CArray  *ca  = (CArray *) ap;
  ca_size_t *dim = ca->dim;
  int8_t     i;
  ca_size_t  n;
  n = idx[0];                  /* n = idx[0]*dim[1]*dim[2]*...*dim[ndim-1] */
  for (i=1; i<ca->ndim; i++) { /*    + idx[1]*dim[1]*dim[2]*...*dim[ndim-1] */
    n = dim[i]*n+idx[i];       /*    ... + idx[ndim-2]*dim[1] + idx[ndim-1] */
  }
  return ca->ptr + ca->bytes * n;
}

void
ca_array_func_fetch_addr (void *ap, ca_size_t addr, void *ptr)
{
  CArray  *ca  = (CArray *) ap;
  memcpy(ptr, ca->ptr + ca->bytes * addr, ca->bytes);
}

void
ca_array_func_fetch_index (void *ap, ca_size_t *idx, void *ptr)
{
  CArray  *ca  = (CArray *) ap;
  ca_size_t *dim = ca->dim;
  int8_t     i;
  ca_size_t  n;
  n = idx[0];
  for (i=1; i<ca->ndim; i++) {
    n = dim[i]*n+idx[i];
  }
  memcpy(ptr, ca->ptr + ca->bytes * n, ca->bytes);
}

void
ca_array_func_store_addr (void *ap, ca_size_t addr, void *ptr)
{
  CArray  *ca  = (CArray *) ap;
  memcpy(ca->ptr + ca->bytes * addr, ptr, ca->bytes);
}

void
ca_array_func_store_index (void *ap, ca_size_t *idx, void *ptr)
{
  CArray  *ca  = (CArray *) ap;
  ca_size_t *dim = ca->dim;
  int8_t     i;
  ca_size_t  n;
  n = idx[0];
  for (i=1; i<ca->ndim; i++) {
    n = dim[i]*n+idx[i];
  }
  memcpy(ca->ptr + ca->bytes * n, ptr, ca->bytes);
}

void
ca_array_func_allocate (void *ap)
{
  /* no operation */
}

void
ca_array_func_attach (void *ap)
{
  /* no operation */
}

void
ca_array_func_sync (void *ap)
{
  /* no operation */
}


void
ca_array_func_detach (void *ap)
{
  /* no operation */
}

void
ca_array_func_copy_data (void *ap, void *ptr)
{
  CArray *ca = (CArray *) ap;
  memmove(ptr, ca->ptr, ca_length(ca));
}

void
ca_array_func_sync_data (void *ap, void *ptr)
{
  CArray *ca = (CArray *) ap;
  memmove(ca->ptr, ptr, ca_length(ca));
}

#define proc_fill_bang_fixlen()                 \
  {                                             \
    ca_size_t i;                                  \
    ca_size_t bytes = ca->bytes;                  \
    char *p = ca->ptr;                          \
    for (i=ca->elements; i; i--, p+=bytes) {    \
      memcpy(p, val, bytes);                    \
    }                                           \
  }

#define proc_fill_bang(type)                    \
  {                                             \
    ca_size_t i;                                  \
    type *p = (type *)ca->ptr;                  \
    type  v = *(type *)val;                     \
    for (i=ca->elements; i; i--, p++) {         \
      *p = v;                                   \
    }                                           \
  }

void
ca_array_func_fill_data (void *ap, void *val)
{
  CArray *ca = (CArray *) ap;
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
}

void
ca_array_func_create_mask (void *ap)
{
  CArray *ca = (CArray *) ap;
  ca->mask = carray_new_safe(CA_BOOLEAN, ca->ndim, ca->dim, 0, NULL);
}

ca_operation_function_t ca_array_func = {
  CA_OBJ_ARRAY,
  CA_REAL_ARRAY,
  free_carray,
  ca_array_func_clone,
  ca_array_func_ptr_at_addr,
  ca_array_func_ptr_at_index,
  NULL,
  ca_array_func_fetch_index,
  NULL,
  ca_array_func_store_index,
  ca_array_func_allocate,
  ca_array_func_attach,
  ca_array_func_sync,
  ca_array_func_detach,
  ca_array_func_copy_data,
  ca_array_func_sync_data,
  ca_array_func_fill_data,
  ca_array_func_create_mask,
};

ca_operation_function_t ca_wrap_func = {
  CA_OBJ_ARRAY_WRAP,
  CA_REAL_ARRAY,
  free_ca_wrap,
  ca_array_func_clone,
  ca_array_func_ptr_at_addr,
  ca_array_func_ptr_at_index,
  NULL,
  ca_array_func_fetch_index,
  NULL,
  ca_array_func_store_index,
  ca_array_func_allocate,
  ca_array_func_attach,
  ca_array_func_sync,
  ca_array_func_detach,
  ca_array_func_copy_data,
  ca_array_func_sync_data,
  ca_array_func_fill_data,
  ca_array_func_create_mask,
};

/* ------------------------------------------------------------------- */

static void *
ca_scalar_func_clone (void *ap)
{
  CScalar *ca = (CScalar *) ap;
  CScalar *co;
  ca_update_mask(ca);
  co = cscalar_new(ca->data_type, ca->bytes, ca->mask);
  memcpy(co->ptr, ca->ptr, ca->bytes);
  return co;
}

char *
ca_scalar_func_ptr_at_addr (void *ap, ca_size_t addr)
{
  CArray *ca = (CArray *) ap;
  return ca->ptr;
}

char *
ca_scalar_func_ptr_at_index (void *ap, ca_size_t *idx)
{
  CArray  *ca  = (CArray *) ap;
  return ca->ptr;
}

#define ca_scalar_func_fetch_index    ca_array_func_fetch_index
#define ca_scalar_func_store_index  ca_array_func_store_index
#define ca_scalar_func_allocate      ca_array_func_allocate
#define ca_scalar_func_attach        ca_array_func_attach
#define ca_scalar_func_sync          ca_array_func_sync
#define ca_scalar_func_detach        ca_array_func_detach
#define ca_scalar_func_copy_data   ca_array_func_copy_data
#define ca_scalar_func_sync_data ca_array_func_sync_data
#define ca_scalar_func_fill_data          ca_array_func_fill_data
#define ca_scalar_func_create_mask   ca_array_func_create_mask

ca_operation_function_t ca_scalar_func = {
  CA_OBJ_SCALAR,
  CA_REAL_ARRAY,
  free_cscalar,
  ca_scalar_func_clone,
  ca_scalar_func_ptr_at_addr,
  ca_scalar_func_ptr_at_index,
  NULL,
  ca_scalar_func_fetch_index,
  NULL,
  ca_scalar_func_store_index,
  ca_scalar_func_allocate,
  ca_scalar_func_attach,
  ca_scalar_func_sync,
  ca_scalar_func_detach,
  ca_scalar_func_copy_data,
  ca_scalar_func_sync_data,
  ca_scalar_func_fill_data,
  ca_scalar_func_create_mask,
};

/* ------------------------------------------------------------------- */

VALUE
rb_carray_new (int8_t data_type, int8_t ndim, ca_size_t *dim, ca_size_t bytes,
               CArray *mask)
{
  CArray *ca = carray_new(data_type, ndim, dim, bytes, mask);
  return ca_wrap_struct(ca);
}

VALUE
rb_carray_new_safe (int8_t data_type, int8_t ndim, ca_size_t *dim, ca_size_t bytes,
                    CArray *mask)
{
  CArray *ca = carray_new_safe(data_type, ndim, dim, bytes, mask);
  return ca_wrap_struct(ca);
}

VALUE
rb_cscalar_new (int8_t data_type, ca_size_t bytes, CArray *mask)
{
  CScalar *ca = cscalar_new(data_type, bytes, mask);
  return ca_wrap_struct(ca);
}

VALUE
rb_cscalar_new_with_value (int8_t data_type, ca_size_t bytes, VALUE rval)
{
  volatile VALUE obj;
  obj = rb_cscalar_new(data_type, bytes, NULL);
  rb_ca_store_addr(obj, 0, rval);
  return obj;
}

/* ------------------------------------------------------------------- */

/*
 *  CArray.allocate()
 */

static VALUE
rb_ca_s_allocate (VALUE klass)
{
  CArray *ca;
  ca_check_mem_count();  
  return Data_Make_Struct(klass, CArray, ca_mark, ca_free, ca);
}

/* rdoc:
  #  call-seq:
  #     CArray.new(data_type, dim, bytes=0) { ... }
  #
  #  Constructs a new CArray object of <i>data_type</i>, which has the
  #  ndim and the dimensions specified by an <code>Array</code> of
  #  <code>Integer</code> or an argument list of <code>Integer</code>.
  #  The byte size of each element for the fixed length data type
  #  (<code>data_type == CA_FIXLEN</code>) is specified optional argument
  #  <i>bytes</i>. Otherwise, this optional argument has no
  #  effect. If the block is given, the new CArray
  #  object will be initialized by the value returned from the block.
  def CArray.new(data_type, dim, bytes=0)
  end
*/

static VALUE
rb_ca_initialize (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE rtype, rdim, ropt, rbytes = Qnil;
  CArray *ca;
  int8_t data_type, ndim;
  ca_size_t dim[CA_RANK_MAX];
  ca_size_t bytes;
  int8_t i;

  rb_scan_args(argc, argv, "21", (VALUE *)&rtype, (VALUE *) &rdim, (VALUE *) &ropt);
  rb_scan_options(ropt, "bytes", &rbytes);

  rb_ca_guess_type_and_bytes(rtype, rbytes, &data_type, &bytes);
  rb_ca_data_type_import(self, rtype);

  Check_Type(rdim, T_ARRAY);
  ndim = RARRAY_LEN(rdim);
  for (i=0; i<ndim; i++) {
    dim[i] = NUM2SIZE(rb_ary_entry(rdim, i));
  }

  Data_Get_Struct(self, CArray, ca);
  carray_safe_setup(ca, data_type, ndim, dim, bytes, NULL);

  if ( rb_block_given_p() ) {
    volatile VALUE rval = rb_yield(self);
    if ( rval != self ) {
      rb_ca_store_all(self, rval);
    }
  }

  return Qnil;
}

static VALUE
rb_ca_s_fixlen (int argc, VALUE *argv, VALUE klass)  
{                                                     
  volatile VALUE ropt = rb_pop_options(&argc, &argv); 
  volatile VALUE rdim = rb_ary_new4(argc, argv);      
  VALUE args[3] = { INT2NUM(CA_FIXLEN), rdim, ropt };      
  return rb_class_new_instance(3, args, klass);       
}

#define rb_ca_s_type(type, code)                        \
rb_ca_s_## type (int argc, VALUE *argv, VALUE klass)    \
{                                                       \
  if ( argc == 0 ) {                                    \
    return ca_data_type_class(code);                    \
  }                                                     \
  else {                                                \
    volatile VALUE ropt = rb_pop_options(&argc, &argv); \
    volatile VALUE rdim = rb_ary_new4(argc, argv);      \
    VALUE args[3] = { INT2NUM(code), rdim, ropt };      \
    return rb_class_new_instance(3, args, klass);       \
  }                                                     \
}

/*
 *  call-seq:
 *     CArray.int8(dim0, dim1, ...) { ... }     -> CArray
 *     CArray.uint8(dim0, dim1, ...) { ... }    -> CArray
 *     CArray.int16(dim0, dim1, ...) { ... }    -> CArray
 *     CArray.uint16(dim0, dim1, ...) { ... }   -> CArray
 *     CArray.int32(dim0, dim1, ...) { ... }    -> CArray
 *     CArray.uint32(dim0, dim1, ...) { ... }   -> CArray
 *     CArray.int64(dim0, dim1, ...) { ... }    -> CArray
 *     CArray.uint64(dim0, dim1, ...) { ... }   -> CArray
 *     CArray.float32(dim0, dim1, ...) { ... }  -> CArray
 *     CArray.float64(dim0, dim1, ...) { ... }  -> CArray
 *     CArray.float128(dim0, dim1, ...) { ... } -> CArray
 *     CArray.cmplx64(dim0, dim1, ...) { ... }  -> CArray
 *     CArray.cmplx128(dim0, dim1, ...) { ... } -> CArray
 *     CArray.cmplx256(dim0, dim1, ...) { ... } -> CArray
 *     CArray.object(dim0, dim1, ...) { ... }   -> CArray
 *
 */

static VALUE rb_ca_s_VALUE();

static VALUE rb_ca_s_type(boolean,  CA_BOOLEAN);
static VALUE rb_ca_s_type(int8,     CA_INT8);
static VALUE rb_ca_s_type(uint8,    CA_UINT8);
static VALUE rb_ca_s_type(int16,    CA_INT16);
static VALUE rb_ca_s_type(uint16,   CA_UINT16);
static VALUE rb_ca_s_type(int32,    CA_INT32);
static VALUE rb_ca_s_type(uint32,   CA_UINT32);
static VALUE rb_ca_s_type(int64,    CA_INT64);
static VALUE rb_ca_s_type(uint64,   CA_UINT64);
static VALUE rb_ca_s_type(float32,  CA_FLOAT32);
static VALUE rb_ca_s_type(float64,  CA_FLOAT64);
static VALUE rb_ca_s_type(float128, CA_FLOAT128);
#ifdef HAVE_COMPLEX_H
static VALUE rb_ca_s_type(cmplx64,  CA_CMPLX64);
static VALUE rb_ca_s_type(cmplx128, CA_CMPLX128);
static VALUE rb_ca_s_type(cmplx256, CA_CMPLX256);
#endif
static VALUE rb_ca_s_type(VALUE,    CA_OBJECT);

static VALUE
rb_ca_initialize_copy (VALUE self, VALUE other)
{
  CArray *ca, *cs;

  rb_call_super(1, &other);

  Data_Get_Struct(self,  CArray, ca);
  Data_Get_Struct(other, CArray, cs);

  ca_update_mask(cs);
  carray_setup(ca, cs->data_type, cs->ndim, cs->dim, cs->bytes, cs->mask);

  memcpy(ca->ptr, cs->ptr, ca_length(cs));

  return self;
}

/* rdoc:
   def CArray.wrap (data_type, dim, bytes=0) # { wrapped_object }
   end
*/

static VALUE
rb_ca_s_wrap (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE obj, target, rtype, rdim, ropt, rbytes = Qnil;
  CArray *ca;
  int8_t data_type, ndim;
  ca_size_t dim[CA_RANK_MAX];
  ca_size_t bytes;
  int8_t i;

  rb_scan_args(argc, argv, "21", (VALUE *) &rtype, (VALUE *) &rdim, (VALUE *) &ropt);
  rb_scan_options(ropt, "bytes", &rbytes);

  rb_ca_guess_type_and_bytes(rtype, rbytes, &data_type, &bytes);

  Check_Type(rdim, T_ARRAY);
  ndim = RARRAY_LEN(rdim);
  for (i=0; i<ndim; i++) {
    dim[i] = NUM2SIZE(rb_ary_entry(rdim, i));
  }

  target = rb_yield_values(0);

  obj = Data_Make_Struct(rb_cCAWrap, CAWrap, ca_mark, ca_free, ca);
  ca_wrap_setup_null(ca, data_type, ndim, dim, bytes, NULL);

  rb_funcall(target, rb_intern("wrap_as_carray"), 1, obj);
  rb_ivar_set(obj, rb_intern("referred_object"), target);

  return obj;
}

VALUE
rb_carray_wrap_ptr (int8_t data_type, int8_t ndim, ca_size_t *dim,
        ca_size_t bytes, CArray *mask, char *ptr, VALUE refer)
{
  volatile VALUE obj;
  CArray *ca;

  ca  = ca_wrap_new(data_type, ndim, dim, bytes, mask, ptr);
  obj = ca_wrap_struct(ca);

  rb_ivar_set(obj, rb_intern("referred_object"), refer);

  return obj;
}

/* ------------------------------------------------------------------- */

static VALUE
rb_cs_s_allocate (VALUE klass)
{
  CScalar *ca;
  return Data_Make_Struct(klass, CScalar, ca_mark, ca_free, ca);
}

/* rdoc:
  #  call-seq:
  #     CScalar.new(data_type, bytes=0) { ... }
  #
  #  Constructs a new CScalar object of <i>data_type</i>.
  #  The byte size of each element for the fixed length data type
  #  (<code>data_type == CA_FIXLEN</code>) is specified optional argument
  #  <i>bytes</i>. Otherwise, this optional argument has no
  #  effect. If the block is given, the new CScalar
  #  object will be initialized by the value returned from the block.
  def CScalar.new(data_type,bytes=0)
  end
*/

static VALUE
rb_cs_initialize (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE rtype, ropt, rbytes = Qnil;
  CScalar *ca;
  int8_t data_type;
  ca_size_t bytes;

  rb_scan_args(argc, argv, "11", (VALUE *) &rtype, (VALUE *) &ropt);
  rb_scan_options(ropt, "bytes", &rbytes);

  rb_ca_guess_type_and_bytes(rtype, rbytes, &data_type, &bytes);
  rb_ca_data_type_import(self, rtype);

  Data_Get_Struct(self, CScalar, ca);
  cscalar_setup(ca, data_type, bytes, NULL);

  if ( rb_block_given_p() ) {
    volatile VALUE rval = rb_yield(self);
    if ( rval != self ) {
      rb_ca_store_addr(self, 0, rval);
    }
  }

  return Qnil;
}

static VALUE
rb_cs_s_fixlen (int argc, VALUE *argv, VALUE klass)  
{                                                     
  volatile VALUE ropt = rb_pop_options(&argc, &argv); 
  VALUE args[2] = { INT2NUM(CA_FIXLEN), ropt };      
  if ( argc > 0 ) {                                   
    rb_raise(rb_eArgError, "invalid number of arguments"); 
  }                                                   
  return rb_class_new_instance(2, args, klass);       
}

#define rb_cs_s_type(type, code)                      \
rb_cs_s_## type (int argc, VALUE *argv, VALUE klass)  \
{                                                     \
  volatile VALUE ropt = rb_pop_options(&argc, &argv); \
  VALUE args[2] = { INT2NUM(code), ropt };            \
  if ( argc > 0 ) {                                   \
    rb_raise(rb_eArgError, "invalid number of arguments"); \
  }                                                   \
  return rb_class_new_instance(2, args, klass);       \
}

static VALUE rb_cs_s_type(boolean,  CA_BOOLEAN);
static VALUE rb_cs_s_type(int8,     CA_INT8);
static VALUE rb_cs_s_type(uint8,    CA_UINT8);
static VALUE rb_cs_s_type(int16,    CA_INT16);
static VALUE rb_cs_s_type(uint16,   CA_UINT16);
static VALUE rb_cs_s_type(int32,    CA_INT32);
static VALUE rb_cs_s_type(uint32,   CA_UINT32);
static VALUE rb_cs_s_type(int64,    CA_INT64);
static VALUE rb_cs_s_type(uint64,   CA_UINT64);
static VALUE rb_cs_s_type(float32,  CA_FLOAT32);
static VALUE rb_cs_s_type(float64,  CA_FLOAT64);
static VALUE rb_cs_s_type(float128, CA_FLOAT128);
#ifdef HAVE_COMPLEX_H
static VALUE rb_cs_s_type(cmplx64,  CA_CMPLX64);
static VALUE rb_cs_s_type(cmplx128, CA_CMPLX128);
static VALUE rb_cs_s_type(cmplx256, CA_CMPLX256);
#endif
static VALUE rb_cs_s_type(VALUE,    CA_OBJECT);

/*
 *  call-seq:
 *     CScalar.int8() { ... }     -> CScalar
 *     CScalar.uint8() { ... }    -> CScalar
 *     CScalar.int16() { ... }    -> CScalar
 *     CScalar.uint16() { ... }   -> CScalar
 *     CScalar.int32() { ... }    -> CScalar
 *     CScalar.uint32() { ... }   -> CScalar
 *     CScalar.int64() { ... }    -> CScalar
 *     CScalar.uint64() { ... }   -> CScalar
 *     CScalar.float32() { ... }  -> CScalar
 *     CScalar.float64() { ... }  -> CScalar
 *     CScalar.float128() { ... } -> CScalar
 *     CScalar.cmplx64() { ... }  -> CScalar
 *     CScalar.cmplx128() { ... } -> CScalar
 *     CScalar.cmplx256() { ... } -> CScalar
 *     CScalar.object() { ... }   -> CScalar
 *
 */

static VALUE
rb_cs_s_VALUE();

static VALUE
rb_cs_initialize_copy (VALUE self, VALUE other)
{
  CScalar *ca, *cs;

  Data_Get_Struct(self,  CScalar, ca);
  Data_Get_Struct(other, CScalar, cs);

  cscalar_setup(ca, cs->data_type, cs->bytes, NULL);
  memcpy(ca->ptr, cs->ptr, ca->bytes);

  rb_ca_data_type_inherit(self, other);

  return self;
}

/*
 *  call-seq:
 *     cs.coerce(o)  -> array
 *
 */

/*
static VALUE
rb_cs_coerce (VALUE self, VALUE other)
{
  CScalar *ca;
  Data_Get_Struct(self, CScalar, ca);
  return rb_assoc_new(rb_cscalar_new_with_value(ca->data_type, ca->bytes, other), 
                      self);
}
*/

static VALUE
rb_ca_mem_usage (VALUE self)
{
  return rb_float_new(ca_mem_usage);
}

void
Init_ca_obj_array ()
{
  /* rb_cCArray,  CA_OBJ_ARRAY are defined in rb_carray.c */
  /* rb_cCAWrap,  CA_OBJ_ARRAY_WRAP are defined in rb_carray.c */
  /* rb_cCScalar, CA_OBJ_SCALAR are defined in rb_carray.c */

  /* ------------------------------------------------------------------- */
  ca_gc_interval = ca_default_gc_interval;
  rb_define_const(rb_cCArray, "DEFAULT_GC_INTERVAL", rb_float_new(ca_default_gc_interval));
  rb_define_singleton_method(rb_cCArray, "gc_interval", rb_ca_get_gc_interval, 0);
  rb_define_singleton_method(rb_cCArray, "gc_interval=", rb_ca_set_gc_interval, 1);
  rb_define_singleton_method(rb_cCArray, "reset_gc_interval", rb_ca_reset_gc_interval, 0);

  rb_define_alloc_func(rb_cCArray, rb_ca_s_allocate);
  rb_define_method(rb_cCArray, "initialize", rb_ca_initialize, -1);

  rb_define_singleton_method(rb_cCArray, "fixlen", rb_ca_s_fixlen, -1);
  rb_define_singleton_method(rb_cCArray, "boolean", rb_ca_s_boolean, -1);
  rb_define_singleton_method(rb_cCArray, "int8", rb_ca_s_int8, -1);
  rb_define_singleton_method(rb_cCArray, "uint8", rb_ca_s_uint8, -1);
  rb_define_singleton_method(rb_cCArray, "int16", rb_ca_s_int16, -1);
  rb_define_singleton_method(rb_cCArray, "uint16", rb_ca_s_uint16, -1);
  rb_define_singleton_method(rb_cCArray, "int32", rb_ca_s_int32, -1);
  rb_define_singleton_method(rb_cCArray, "uint32", rb_ca_s_uint32, -1);
  rb_define_singleton_method(rb_cCArray, "int64", rb_ca_s_int64, -1);
  rb_define_singleton_method(rb_cCArray, "uint64", rb_ca_s_uint64, -1);
  rb_define_singleton_method(rb_cCArray, "float32", rb_ca_s_float32, -1);
  rb_define_singleton_method(rb_cCArray, "float64", rb_ca_s_float64, -1);
  rb_define_singleton_method(rb_cCArray, "float128", rb_ca_s_float128, -1);
#ifdef HAVE_COMPLEX_H
  rb_define_singleton_method(rb_cCArray, "cmplx64", rb_ca_s_cmplx64, -1);
  rb_define_singleton_method(rb_cCArray, "cmplx128", rb_ca_s_cmplx128, -1);
  rb_define_singleton_method(rb_cCArray, "cmplx256", rb_ca_s_cmplx256, -1);
#endif
  rb_define_singleton_method(rb_cCArray, "object", rb_ca_s_VALUE, -1);

  rb_define_singleton_method(rb_cCArray, "byte", rb_ca_s_uint8, -1);
  rb_define_singleton_method(rb_cCArray, "short", rb_ca_s_int16, -1);
  rb_define_singleton_method(rb_cCArray, "int", rb_ca_s_int32, -1);
  rb_define_singleton_method(rb_cCArray, "float", rb_ca_s_float32, -1);
  rb_define_singleton_method(rb_cCArray, "double", rb_ca_s_float64, -1);
#ifdef HAVE_COMPLEX_H
  rb_define_singleton_method(rb_cCArray, "complex", rb_ca_s_cmplx64, -1);
  rb_define_singleton_method(rb_cCArray, "dcomplex", rb_ca_s_cmplx128, -1);
#endif

  rb_define_method(rb_cCArray, "initialize_copy", rb_ca_initialize_copy, 1);
  rb_define_singleton_method(rb_cCArray, "wrap", rb_ca_s_wrap, -1);

  /* ------------------------------------------------------------------- */

  /* CScalar creation */
  rb_define_alloc_func(rb_cCScalar, rb_cs_s_allocate);
  rb_define_method(rb_cCScalar, "initialize", rb_cs_initialize, -1);

  rb_define_singleton_method(rb_cCScalar, "fixlen", rb_cs_s_fixlen, -1);
  rb_define_singleton_method(rb_cCScalar, "boolean", rb_cs_s_boolean, -1);
  rb_define_singleton_method(rb_cCScalar, "int8", rb_cs_s_int8, -1);
  rb_define_singleton_method(rb_cCScalar, "uint8", rb_cs_s_uint8, -1);
  rb_define_singleton_method(rb_cCScalar, "int16", rb_cs_s_int16, -1);
  rb_define_singleton_method(rb_cCScalar, "uint16", rb_cs_s_uint16, -1);
  rb_define_singleton_method(rb_cCScalar, "int32", rb_cs_s_int32, -1);
  rb_define_singleton_method(rb_cCScalar, "uint32", rb_cs_s_uint32, -1);
  rb_define_singleton_method(rb_cCScalar, "int64", rb_cs_s_int64, -1);
  rb_define_singleton_method(rb_cCScalar, "uint64", rb_cs_s_uint64, -1);
  rb_define_singleton_method(rb_cCScalar, "float32", rb_cs_s_float32, -1);
  rb_define_singleton_method(rb_cCScalar, "float64", rb_cs_s_float64, -1);
  rb_define_singleton_method(rb_cCScalar, "float128", rb_cs_s_float128, -1);
#ifdef HAVE_COMPLEX_H
  rb_define_singleton_method(rb_cCScalar, "cmplx64", rb_cs_s_cmplx64, -1);
  rb_define_singleton_method(rb_cCScalar, "cmplx128", rb_cs_s_cmplx128, -1);
  rb_define_singleton_method(rb_cCScalar, "cmplx256", rb_cs_s_cmplx256, -1);
#endif
  rb_define_singleton_method(rb_cCScalar, "object", rb_cs_s_VALUE, -1);

  rb_define_singleton_method(rb_cCScalar, "byte", rb_cs_s_uint8, -1);
  rb_define_singleton_method(rb_cCScalar, "short", rb_cs_s_int16, -1);
  rb_define_singleton_method(rb_cCScalar, "int", rb_cs_s_int32, -1);
  rb_define_singleton_method(rb_cCScalar, "float", rb_cs_s_float32, -1);
  rb_define_singleton_method(rb_cCScalar, "double", rb_cs_s_float64, -1);
#ifdef HAVE_COMPLEX_H
  rb_define_singleton_method(rb_cCScalar, "complex", rb_cs_s_cmplx64, -1);
  rb_define_singleton_method(rb_cCScalar, "dcomplex", rb_cs_s_cmplx128, -1);
#endif

  rb_define_method(rb_cCScalar, "initialize_copy", rb_cs_initialize_copy, 1);
//  rb_define_method(rb_cCScalar, "coerce", rb_cs_coerce, 1);

  rb_define_const(rb_cObject, "CA_OBJ_ARRAY",   INT2NUM(CA_OBJ_ARRAY));
  rb_define_const(rb_cObject, "CA_OBJ_ARRAY_WRAP", INT2NUM(CA_OBJ_ARRAY_WRAP));
  rb_define_const(rb_cObject, "CA_OBJ_SCALAR",  INT2NUM(CA_OBJ_SCALAR));

  rb_define_singleton_method(rb_cCArray, "mem_usage", rb_ca_mem_usage, 0);

}


/* rdoc:
  # call-seq:
  #    CArray.boolean(...) { init_value }
  #    CArray.int8(...) { init_value }
  #    CArray.uint8(...) { init_value }
  #    CArray.int16(...) { init_value }
  #    CArray.uint16(...) { init_value }
  #    CArray.int32(...) { init_value }
  #    CArray.uint32(...) { init_value }
  #    CArray.int64(...) { init_value }
  #    CArray.uint64(...) { init_value }
  #    CArray.float32(...) { init_value }
  #    CArray.float64(...) { init_value }
  #    CArray.float128(...) { init_value }
  #    CArray.cmplx64(...) { init_value }
  #    CArray.cmplx128(...) { init_value }
  #    CArray.cmplx256(...) { init_value }
  #    CArray.fixlen(...) { init_value }
  #    CArray.object(...) { init_value }
  #    CArray.byte(...) { init_value }
  #    CArray.short(...) { init_value }
  #    CArray.int(...) { init_value }
  #    CArray.float(...) { init_value }
  #    CArray.double(...) { init_value }
  #    CArray.complex(...) { init_value }
  #    CArray.dcomplex(...) { init_value }
  #
  def CArray.type
  end

  # call-seq:
  #    CScalar.boolean { init_value }
  #    CScalar.int8 { init_value }
  #    CScalar.uint8 { init_value }
  #    CScalar.int16 { init_value }
  #    CScalar.uint16 { init_value }
  #    CScalar.int32 { init_value }
  #    CScalar.uint32 { init_value }
  #    CScalar.int64 { init_value }
  #    CScalar.uint64 { init_value }
  #    CScalar.float32 { init_value }
  #    CScalar.float64 { init_value }
  #    CScalar.float128 { init_value }
  #    CScalar.cmplx64 { init_value }
  #    CScalar.cmplx128 { init_value }
  #    CScalar.cmplx256 { init_value }
  #    CScalar.fixlen { init_value }
  #    CScalar.object { init_value }
  #    CScalar.byte { init_value }
  #    CScalar.short { init_value }
  #    CScalar.int { init_value }
  #    CScalar.float { init_value }
  #    CScalar.double { init_value }
  #    CScalar.complex { init_value }
  #    CScalar.dcomplex { init_value }
  #
  def CScalar.type
  end
*/
