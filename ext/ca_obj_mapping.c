/* ---------------------------------------------------------------------------

  ca_obj_mapping.c

  This file is part of Ruby/CArray extension library.

  Copyright (C) 2005-2020 Hiroki Motoyoshi

---------------------------------------------------------------------------- */

/*
  CAMapping
  * index array should not have mask
  * index array's value should be within the range of the referred array's index
*/

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
  CArray   *mapper;
} CAMapping;

static int8_t CA_OBJ_MAPPING;

static VALUE rb_cCAMapping;

/* yard:
  class CAMapping < CAVirtual # :nodoc: 
  end
*/

/* ------------------------------------------------------------------- */

int
ca_mapping_setup (CAMapping *ca, CArray *parent, CArray *mapper, int share)
{
  int8_t ndim, data_type;
  ca_size_t elements, bytes;
  ca_size_t *p;
  ca_size_t i;

  ca_check_type(mapper, CA_SIZE);

  data_type = parent->data_type;
  bytes     = parent->bytes;
  
  ca->obj_type  = CA_OBJ_MAPPING;
  ca->data_type = data_type;
  ca->flags     = 0;

  ca->bytes     = bytes;
  ca->ptr       = NULL;

  ndim          = mapper->ndim;
  elements      = mapper->elements;

  ca->ndim      = ndim;
  ca->elements  = elements;
  ca->mask      = NULL;
  ca->dim       = ALLOC_N(ca_size_t, ndim);

  ca->parent    = parent;
  ca->attach    = 0;
  ca->nosync    = 0;

  memcpy(ca->dim, mapper->dim, ndim * sizeof(ca_size_t));

  if ( share ) {
    ca_set_flag(ca, CA_FLAG_SHARE_INDEX);
    ca->mapper = mapper;
  }
  else {
    if ( ca_is_any_masked(mapper) ) {
      rb_raise(rb_eArgError, "mapper in ca[mapper] should not be masked");
    }
    else {
      ca->mapper = ca_copy(mapper);
    }
  }

  if ( ca_has_mask(parent) )  {
    ca_create_mask(ca);
  }

  p = (ca_size_t*)ca->mapper->ptr;
  for (i=0; i<ca->elements; i++) {
    CA_CHECK_INDEX(*p, parent->elements);
    p++;
  }

  if ( ca->elements == 1 && ca_is_scalar(mapper) ) {
    ca_set_flag(ca, CA_FLAG_SCALAR);
  }

  return 0;
}

CAMapping *
ca_mapping_new (CArray *parent, CArray *mapper)
{
  CAMapping *ca = ALLOC(CAMapping);
  ca_mapping_setup(ca, parent, mapper, 0);
  return ca;
}

CAMapping *
ca_mapping_new_share (CArray *parent, CArray *mapper)
{
  CAMapping *ca = ALLOC(CAMapping);
  ca_mapping_setup(ca, parent, mapper, 1);
  return ca;
}

static void
free_ca_mapping (void *ap)
{
  CAMapping *ca = (CAMapping *) ap;
  if ( ca != NULL ) {
    ca_free(ca->mask);
    if ( ! (ca->flags & CA_FLAG_SHARE_INDEX) ) {
      ca_free(ca->mapper);
    }
    xfree(ca->dim);
    xfree(ca);
  }
}

static void ca_mapping_attach (CAMapping *ca);
static void ca_mapping_sync (CAMapping *ca);
static void ca_mapping_fill (CAMapping *ca, char *ptr);

/* ------------------------------------------------------------------- */

static void *
ca_mapping_func_clone (void *ap)
{
  CAMapping *ca = (CAMapping *) ap;
  return ca_mapping_new_share(ca->parent, ca->mapper);
}

static char *
ca_mapping_func_ptr_at_addr (void *ap, ca_size_t addr)
{
  CAMapping *ca = (CAMapping *) ap;
  if ( ! ca->ptr ) {
    ca_size_t idx[CA_RANK_MAX];
    ca_addr2index((CArray *)ca, addr, idx);
    return ca_ptr_at_index(ca, idx);
  }
  else {
    return ca->ptr + ca->bytes * addr;
  }
}

static char *
ca_mapping_func_ptr_at_index (void *ap, ca_size_t *idx)
{
  CAMapping *ca = (CAMapping *) ap;
  if ( ! ca->ptr ) {
    ca_size_t *dim = ca->dim;
    int8_t   i;
    ca_size_t  n;
    n = idx[0];
    for (i=1; i<ca->ndim; i++) {
      n = dim[i]*n+idx[i];
    }
    n = *(ca_size_t*) ca_ptr_at_addr(ca->mapper, n);
    if ( ca->parent->ptr == NULL ) {
      return ca_ptr_at_addr(ca->parent, n);
    }
    else {
      return ca->parent->ptr + ca->bytes * n;
    }
  }
  else {
    return ca_func[CA_OBJ_ARRAY].ptr_at_index(ca, idx);
  }
}

static void
ca_mapping_func_fetch_index (void *ap, ca_size_t *idx, void *ptr)
{
  CAMapping *ca = (CAMapping *) ap;
  ca_size_t *dim = ca->dim;
  int8_t   i;
  ca_size_t  n;
  n = idx[0];
  for (i=1; i<ca->ndim; i++) {
    n = dim[i]*n+idx[i];
  }
  n = *(ca_size_t*) ca_ptr_at_addr(ca->mapper, n);
  ca_fetch_addr(ca->parent, n, ptr);
}

static void
ca_mapping_func_store_index (void *ap, ca_size_t *idx, void *ptr)
{
  CAMapping *ca = (CAMapping *) ap;
  ca_size_t *dim = ca->dim;
  int8_t   i;
  ca_size_t  n;
  n = idx[0];
  for (i=1; i<ca->ndim; i++) {
    n = dim[i]*n+idx[i];
  }
  n = *(ca_size_t*) ca_ptr_at_addr(ca->mapper, n);
  ca_store_addr(ca->parent, n, ptr);
}

static void
ca_mapping_func_allocate (void *ap)
{
  CAMapping *ca = (CAMapping *) ap;
  ca_attach(ca->parent);
  /* ca->ptr = ALLOC_N(char, ca_length(ca)); */
  ca->ptr = malloc_with_check(ca_length(ca));  
}

static void
ca_mapping_func_attach (void *ap)
{
  CAMapping *ca = (CAMapping *) ap;
  ca_attach(ca->parent);
  /* ca->ptr = ALLOC_N(char, ca_length(ca)); */
  ca->ptr = malloc_with_check(ca_length(ca));  
  ca_mapping_attach(ca);
}

static void
ca_mapping_func_sync (void *ap)
{
  CAMapping *ca = (CAMapping *) ap;
  ca_mapping_sync(ca);
  ca_sync(ca->parent);
}

static void
ca_mapping_func_detach (void *ap)
{
  CAMapping *ca = (CAMapping *) ap;
  free(ca->ptr);
  ca->ptr = NULL;
  ca_detach(ca->parent);
}

static void
ca_mapping_func_copy_data (void *ap, void *ptr)
{
  CAMapping *ca = (CAMapping *) ap;
  char *ptr0 = ca->ptr;
  ca_attach(ca->parent);
  ca->ptr = ptr;
  ca_mapping_attach(ca);
  ca->ptr = ptr0;
  ca_detach(ca->parent);
}

static void
ca_mapping_func_sync_data (void *ap, void *ptr)
{
  CAMapping *ca = (CAMapping *) ap;
  char *ptr0 = ca->ptr;
  ca_attach(ca->parent);
  ca->ptr = ptr;
  ca_mapping_sync(ca);
  ca->ptr = ptr0;
  ca_sync(ca->parent);
  ca_detach(ca->parent);
}

static void
ca_mapping_func_fill_data (void *ap, void *ptr)
{
  CAMapping *ca = (CAMapping *) ap;
  ca_attach(ca->parent);
  ca_mapping_fill(ca, ptr);
  ca_sync(ca->parent);
  ca_detach(ca->parent);
}

static void
ca_mapping_func_create_mask (void *ap)
{
  CAMapping *ca = (CAMapping *) ap;

  ca_update_mask(ca->parent);
  if ( ! ca->parent->mask ) {
    ca_create_mask(ca->parent);
  }

  ca->mask = (CArray *) ca_mapping_new_share(ca->parent->mask, ca->mapper);

  return;
}

ca_operation_function_t ca_mapping_func = {
  -1, /* CA_OBJ_MAPPING */
  CA_VIRTUAL_ARRAY,
  free_ca_mapping,
  ca_mapping_func_clone,
  ca_mapping_func_ptr_at_addr,
  ca_mapping_func_ptr_at_index,
  NULL,
  ca_mapping_func_fetch_index,
  NULL,
  ca_mapping_func_store_index,
  ca_mapping_func_allocate,
  ca_mapping_func_attach,
  ca_mapping_func_sync,
  ca_mapping_func_detach,
  ca_mapping_func_copy_data,
  ca_mapping_func_sync_data,
  ca_mapping_func_fill_data,
  ca_mapping_func_create_mask,
};

/* ------------------------------------------------------------------- */

static void
ca_mapping_attach (CAMapping *ca)
{
  ca_size_t *ip = (ca_size_t*) ca_ptr_at_addr(ca->mapper, 0);
  ca_size_t i;

#define proc_mapping_attach(type) \
  { \
    type *p = (type*)ca_ptr_at_addr(ca, 0); \
    type *q = (type*)ca_ptr_at_addr(ca->parent, 0); \
    for (i=0; i<ca->elements; i++) { \
      *(p+i) = *(q+(*(ip+i))); \
    } \
  }
  
  switch ( ca->bytes ) {
  case 1: 
    { 
      int8_t *p = (int8_t *)ca_ptr_at_addr(ca, 0); 
      int8_t *q = (int8_t *)ca_ptr_at_addr(ca->parent, 0); 
      #ifdef _OPENMP
      #pragma omp parallel for
      #endif
      for (i=0; i<ca->elements; i++) { 
        *(p+i) = *(q+(*(ip+i))); 
      }
      break;
    }
  case 2: 
    { 
      int16_t *p = (int16_t *)ca_ptr_at_addr(ca, 0); 
      int16_t *q = (int16_t *)ca_ptr_at_addr(ca->parent, 0); 
      #ifdef _OPENMP
      #pragma omp parallel for
      #endif
      for (i=0; i<ca->elements; i++) { 
        *(p+i) = *(q+(*(ip+i))); 
      } 
      break;
    }
  case 4: 
    { 
      int32_t *p = (int32_t *)ca_ptr_at_addr(ca, 0); 
      int32_t *q = (int32_t *)ca_ptr_at_addr(ca->parent, 0); 
      #ifdef _OPENMP
      #pragma omp parallel for
      #endif
      for (i=0; i<ca->elements; i++) { 
        *(p+i) = *(q+(*(ip+i))); 
      } 
      break;
    }
  case 8: 
    { 
      float64_t *p = (float64_t *)ca_ptr_at_addr(ca, 0); 
      float64_t *q = (float64_t *)ca_ptr_at_addr(ca->parent, 0); 
      #ifdef _OPENMP
      #pragma omp parallel for
      #endif
      for (i=0; i<ca->elements; i++) { 
        *(p+i) = *(q+(*(ip+i))); 
      } 
      break;
    }
  default:
    {
      char *p = ca_ptr_at_addr(ca, 0);
      char *q = ca_ptr_at_addr(ca->parent, 0);
      #ifdef _OPENMP
      #pragma omp parallel for
      #endif
      for (i=0; i<ca->elements; i++) {
        memcpy(p + i * ca->bytes, q + (*(ip+i)) * ca->bytes, ca->bytes);
      }
    }
  }
}

static void
ca_mapping_sync (CAMapping *ca)
{
  ca_size_t *ip = (ca_size_t*) ca_ptr_at_addr(ca->mapper, 0);
  ca_size_t i;

  switch ( ca->bytes ) {
  case 1: 
    { 
      int8_t *p = (int8_t *)ca_ptr_at_addr(ca, 0); 
      int8_t *q = (int8_t *)ca_ptr_at_addr(ca->parent, 0); 
      #ifdef _OPENMP
      #pragma omp parallel for
      #endif
      for (i=0; i<ca->elements; i++) { 
        *(q+*(ip+i)) = *(p+i); 
      } 
      break;
    }
  case 2: 
    { 
      int16_t *p = (int16_t *)ca_ptr_at_addr(ca, 0); 
      int16_t *q = (int16_t *)ca_ptr_at_addr(ca->parent, 0); 
      #ifdef _OPENMP
      #pragma omp parallel for
      #endif
      for (i=0; i<ca->elements; i++) { 
        *(q+*(ip+i)) = *(p+i); 
      } 
      break;
    }
  case 4: 
    { 
      int32_t *p = (int32_t *)ca_ptr_at_addr(ca, 0); 
      int32_t *q = (int32_t *)ca_ptr_at_addr(ca->parent, 0); 
      #ifdef _OPENMP
      #pragma omp parallel for
      #endif
      for (i=0; i<ca->elements; i++) { 
        *(q+*(ip+i)) = *(p+i); 
      } 
      break;
    }
  case 8: 
    { 
      float64_t *p = (float64_t *)ca_ptr_at_addr(ca, 0); 
      float64_t *q = (float64_t *)ca_ptr_at_addr(ca->parent, 0); 
      #ifdef _OPENMP
      #pragma omp parallel for
      #endif
      for (i=0; i<ca->elements; i++) { 
        *(q+*(ip+i)) = *(p+i); 
      } 
      break;
    }
  default:
    {
      char *p = ca_ptr_at_addr(ca, 0);
      char *q = ca_ptr_at_addr(ca->parent, 0);
      #ifdef _OPENMP
      #pragma omp parallel for
      #endif
      for (i=0; i<ca->elements; i++) {
        memcpy(q + (*(ip+i)) * ca->bytes, p + i * ca->bytes, ca->bytes);
      }
    }
  }
}

static void
ca_mapping_fill (CAMapping *ca, char *ptr)
{
  ca_size_t *ip = (ca_size_t*) ca_ptr_at_addr(ca->mapper, 0);
  ca_size_t i;

  switch ( ca->bytes ) {
  case 1: 
    { 
      int8_t *q = (int8_t *)ca_ptr_at_addr(ca->parent, 0); 
      int8_t fval = *(int8_t *)ptr; 
      #ifdef _OPENMP
      #pragma omp parallel for
      #endif
      for (i=0; i<ca->elements; i++) { 
        *(q+*(ip+i)) = fval; 
      } 
      break;
    }
  case 2: 
    { 
      int16_t *q = (int16_t *)ca_ptr_at_addr(ca->parent, 0); 
      int16_t fval = *(int16_t *)ptr; 
      #ifdef _OPENMP
      #pragma omp parallel for
      #endif
      for (i=0; i<ca->elements; i++) { 
        *(q+*(ip+i)) = fval; 
      } 
      break;
    }
  case 4: 
    { 
      int32_t *q = (int32_t *)ca_ptr_at_addr(ca->parent, 0); 
      int32_t fval = *(int32_t *)ptr; 
      #ifdef _OPENMP
      #pragma omp parallel for
      #endif
      for (i=0; i<ca->elements; i++) { 
        *(q+*(ip+i)) = fval; 
      } 
      break;
    }
  case 8: 
    { 
      float64_t *q = (float64_t *)ca_ptr_at_addr(ca->parent, 0); 
      float64_t fval = *(float64_t *)ptr; 
      #ifdef _OPENMP
      #pragma omp parallel for
      #endif
      for (i=0; i<ca->elements; i++) { 
        *(q+*(ip+i)) = fval; 
      } 
      break;
    }
  default:
    {
      char *q = ca_ptr_at_addr(ca->parent, 0);
      #ifdef _OPENMP
      #pragma omp parallel for
      #endif
      for (i=0; i<ca->elements; i++) {
        memcpy(q + (*(ip+i)) * ca->bytes, ptr, ca->bytes);
      }
    }
  }
}

/* ------------------------------------------------------------------- */

VALUE
rb_ca_mapping_new (VALUE cary, CArray *mapper)
{
  volatile VALUE obj;
  CArray *parent;
  CAMapping *ca;
  rb_check_carray_object(cary);
  Data_Get_Struct(cary, CArray, parent);
  ca = ca_mapping_new(parent, mapper);
  obj = ca_wrap_struct(ca);
  rb_ca_set_parent(obj, cary);
  rb_ca_data_type_inherit(obj, cary);
  return obj;
}

VALUE
rb_ca_mapping (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE rmapper;
  volatile VALUE obj;
  CArray *ca;
  CArray *mapper;
  Data_Get_Struct(self, CArray, ca);

  rb_scan_args(argc, argv, "1", (VALUE *) &rmapper);
  rb_check_carray_object(rmapper);

  mapper = ca_wrap_readonly(rmapper, CA_SIZE);

  obj = rb_ca_mapping_new(self, mapper);

  return obj;
}

static VALUE
rb_ca_mapping_s_allocate (VALUE klass)
{
  CAMapping *ca;
  return Data_Make_Struct(klass, CAMapping, ca_mark, ca_free, ca);
}

static VALUE
rb_ca_mapping_initialize_copy (VALUE self, VALUE other)
{
  CAMapping *ca, *cs;

  Data_Get_Struct(self,  CAMapping, ca);
  Data_Get_Struct(other, CAMapping, cs);

  /* share mapper info */
  ca_mapping_setup(ca, cs->parent, cs->mapper, 1);

  return self;
}

void
Init_ca_obj_mapping ()
{
  rb_cCAMapping = rb_define_class("CAMapping", rb_cCAVirtual);

  CA_OBJ_MAPPING = ca_install_obj_type(rb_cCAMapping, ca_mapping_func);
  rb_define_const(rb_cObject, "CA_OBJ_MAPPING", INT2NUM(CA_OBJ_MAPPING));

  rb_define_alloc_func(rb_cCAMapping, rb_ca_mapping_s_allocate);
  rb_define_method(rb_cCAMapping, "initialize_copy",
                                      rb_ca_mapping_initialize_copy, 1);
}
