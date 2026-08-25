/* ---------------------------------------------------------------------------

  The concrete entity implementations: CArray (owns its buffer), CScalar
  (single-cell, dim inline), and CAWrap (wraps external memory, does not
  own it).  Holds their TypedData descriptors, the entity ca_func table,
  allocation / setup, CArray.new, and the typed factory constructors
  (CArray.int32(...) etc.).

---------------------------------------------------------------------------- */

#include "carray.h"

/* -------------------------------------------------------------------- */

static size_t
ca_dsize (const void *ap)
{
  const CArray *ca = (const CArray *) ap;
  size_t size;

  if ( ca == NULL ) return 0;

  /* struct size (approximate for view subtypes) */
  switch ( ca->obj_type ) {
    case CA_OBJ_ARRAY:
    case CA_OBJ_ARRAY_WRAP:
      size = sizeof(CArray);
      size += ca->ndim * sizeof(ca_size_t);
      break;
    case CA_OBJ_SCALAR:
      size = sizeof(CScalar);
      /* CScalar: dim points to _dim inside struct, no separate allocation */
      size += ca->bytes; /* ptr: 1 element */
      break;
    default:
      /* CAView and its subtypes (CARefer, CABlock, etc.)
         Use sizeof(CAView) as a lower bound; actual subtypes may be
         larger, but the exact size varies by obj_type. */
      size = sizeof(CAView);
      size += ca->ndim * sizeof(ca_size_t);
      break;
  }

  /* data buffer (only for entity arrays that own their ptr) */
  if ( ca->ptr != NULL && ca->obj_type != CA_OBJ_ARRAY_WRAP ) {
    size += (size_t)ca->elements * (size_t)ca->bytes;
  }

  /* Note: mask memory is accounted for by the mask's own dsize */

  return size;
}

const rb_data_type_t carray_data_type = {
    .parent = NULL,
    .wrap_struct_name = "CArray",
    .function = {
        .dmark = ca_mark,
        .dfree = ca_free,
        .dsize = ca_dsize,
        .dcompact = NULL
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY,
};

const rb_data_type_t cawrap_data_type = {
    .parent = &carray_data_type,
    .wrap_struct_name = "CAWrap",
    .function = {
        .dmark = ca_mark,
        .dfree = ca_free,
        .dsize = ca_dsize,
        .dcompact = NULL
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

const rb_data_type_t cscalar_data_type = {
    .parent = &carray_data_type,
    .wrap_struct_name = "CScalar",
    .function = {
        .dmark = ca_mark,
        .dfree = ca_free,
        .dsize = ca_dsize,
        .dcompact = NULL
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

const rb_data_type_t caview_data_type = {
    .parent = &carray_data_type,
    .wrap_struct_name = "CAView",
    .function = {
        .dmark = ca_mark,
        .dfree = ca_free,
        .dsize = ca_dsize,
        .dcompact = NULL
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

const rb_data_type_t carray_mask_data_type = {
    .parent = &carray_data_type,
    .wrap_struct_name = "CArrayMask",
    .function = {
        .dmark = NULL,
        .dfree = ca_free_nop,
        .dsize = ca_dsize,
        .dcompact = NULL
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY,
};

/* ------------------------------------------------------------------- */

VALUE rb_cCArray, rb_cCAWrap, rb_cCScalar, rb_cCAView;
VALUE rb_cCArrayMask;

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
                CArray *mask, int allocate, int use_calloc, char *adopt_ptr)
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

  /* calculate total byte length using double to detect overflow */
  length = bytes;
  for (i=0; i<ndim; i++) {
    length *= dim[i];
  }

  if ( length > CA_LENGTH_MAX ) {
    rb_raise(rb_eRuntimeError, "too large byte length");
  }

  /* calculate total number of elements (safe after length check above) */
  elements = 1;
  for (i=0; i<ndim; i++) {
    elements *= dim[i];
  }

  /* An adopted buffer produces an owning entity (CA_OBJ_ARRAY), not a
     wrap: free_carray xfree()s ca->ptr, so the caller's buffer must be
     ruby_xmalloc()'d and its ownership transfers here.  A raw buffer
     cannot be adopted as CA_OBJECT (ca_mark would walk uninitialised
     VALUEs). */
  if ( adopt_ptr && data_type == CA_OBJECT ) {
    rb_raise(rb_eRuntimeError,
             "cannot adopt a raw buffer as a CA_OBJECT array");
  }

  /* set values to the struct members */
  if ( allocate || adopt_ptr ) {
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
  if ( ! ca->_pool ) {
    ca->dim     = ALLOC_N(ca_size_t, ndim);
  }
  memcpy(ca->dim, dim, ndim*sizeof(ca_size_t));

  if ( adopt_ptr ) {                    /* adopt: take ownership of buffer */
    ca->ptr = adopt_ptr;
  }
  else if ( allocate ) {                                 /* allocate == true */

    /* allocate memory for entity */
    if ( use_calloc ) {
      /* ca->ptr = ALLOC_N(char, elements * bytes); */
      ca->ptr = xmalloc(elements * bytes);
      MEMZERO(ca->ptr, char, elements * bytes);
    }
    else {
      /* ca->ptr = ALLOC_N(char, elements * bytes); */
      ca->ptr = xmalloc(elements * bytes);
    }

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

  return 0;
}

int
carray_setup (CArray *ca,
  int8_t data_type, int8_t ndim, ca_size_t *dim, ca_size_t bytes, CArray *mask)
{
  return carray_setup_i(ca, data_type, ndim, dim, bytes, mask, 1, 0, NULL);
}

int
carray_safe_setup (CArray *ca,
  int8_t data_type, int8_t ndim, ca_size_t *dim, ca_size_t bytes, CArray *mask)
{
  return carray_setup_i(ca, data_type, ndim, dim, bytes, mask, 1, 1, NULL);
}

int
ca_wrap_setup (CArray *ca,
               int8_t data_type, int8_t ndim, ca_size_t *dim, ca_size_t bytes,
               CArray *mask, char *ptr)
{
  int ret;

  ret = carray_setup_i(ca, data_type, ndim, dim, bytes, mask, 0, 0, NULL);
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

  ret = carray_setup_i(ca, data_type, ndim, dim, bytes, mask, 0, 0, NULL);
  ca->ptr = NULL;
  return ret;
}

CArray *
carray_new (int8_t data_type, int8_t ndim, ca_size_t *dim, ca_size_t bytes,
            CArray *mask)
{
  CArray *ca  = (CArray *) ca_array_alloc(CA_OBJ_ARRAY, ndim);
  carray_setup(ca, data_type, ndim, dim, bytes, mask);
  return ca;
}

CArray *
carray_new_safe (int8_t data_type, int8_t ndim, ca_size_t *dim, ca_size_t bytes,
            CArray *mask)
{
  CArray *ca  = (CArray *) ca_array_alloc(CA_OBJ_ARRAY, ndim);
  carray_safe_setup(ca, data_type, ndim, dim, bytes, mask);
  return ca;
}

/* Create an entity that adopts a caller-provided data buffer instead of
   allocating its own.  Ownership transfers: the buffer must be
   ruby_xmalloc()'d and at least elements*bytes long, and is freed with
   xfree() when the array is collected.  data_type must not be CA_OBJECT
   (a raw buffer holds no valid VALUEs for the GC to mark). */
CArray *
carray_new_adopt (int8_t data_type, int8_t ndim, ca_size_t *dim, ca_size_t bytes,
                  char *ptr)
{
  CArray *ca;
  if ( ! ptr ) {
    rb_raise(rb_eRuntimeError, "carray_new_adopt: NULL data pointer");
  }
  ca = (CArray *) ca_array_alloc(CA_OBJ_ARRAY, ndim);
  carray_setup_i(ca, data_type, ndim, dim, bytes, NULL, 0, 0, ptr);
  return ca;
}

CAWrap *
ca_wrap_new (int8_t data_type, int8_t ndim, ca_size_t *dim, ca_size_t bytes,
            CArray *mask, char *ptr)
{
  CAWrap *ca  = (CAWrap *) ca_array_alloc(CA_OBJ_ARRAY_WRAP, ndim);
  ca_wrap_setup(ca, data_type, ndim, dim, bytes, mask, ptr);
  return ca;
}

CAWrap *
ca_wrap_new_null (int8_t data_type, int8_t ndim, ca_size_t *dim, ca_size_t bytes,
                  CArray *mask)
{
  CAWrap *ca  = (CAWrap *) ca_array_alloc(CA_OBJ_ARRAY_WRAP, ndim);
  ca_wrap_setup_null(ca, data_type, ndim, dim, bytes, mask);
  return ca;
}

void
free_carray (void *ap)
{
  CArray *ca = (CArray *) ap;
  if ( ca != NULL ) {
    ca_free(ca->mask);
    xfree(ca->ptr);              /* entity owns its data buffer */
    if ( ca->_pool ) {
      ca_array_free(ca);        /* dim lives in _pool */
    }
    else {
      xfree(ca->dim);
      xfree(ca);
    }
  }
}

void
free_ca_wrap (void *ap)
{
  CArray *ca = (CArray *) ap;
  if ( ca != NULL ) {
    /* don't free ca->ptr for CAWrap (borrowed external memory) */
    ca_free(ca->mask);
    if ( ca->_pool ) {
      ca_array_free(ca);        /* dim lives in _pool */
    }
    else {
      xfree(ca->dim);
      xfree(ca);
    }
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
    xfree(ca->ptr);
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

void
ca_array_func_xfer_index (void *ap, ca_size_t *idx, void *data, int dir)
{
  CArray  *ca  = (CArray *) ap;
  ca_size_t *dim = ca->dim;
  int8_t     i;
  ca_size_t  n;
  char      *p;
  n = idx[0];
  for (i=1; i<ca->ndim; i++) {
    n = dim[i]*n+idx[i];
  }
  p = ca->ptr + ca->bytes * n;
  if ( dir == CA_XFER_GET ) {
    memcpy(data, p, ca->bytes);
  }
  else {
    memcpy(p, data, ca->bytes);
  }
}

void
ca_array_func_xfer_addrs (void *ap, ca_size_t n, ca_size_t *addrs,
                          void *data, int dir)
{
  CArray  *ca = (CArray *) ap;
  char    *d  = (char *) data;
  ca_size_t i;
  for (i=0; i<n; i++) {
    char *p = ca->ptr + ca->bytes * addrs[i];
    if ( dir == CA_XFER_GET ) {
      memcpy(d + i * ca->bytes, p, ca->bytes);
    }
    else {
      memcpy(p, d + i * ca->bytes, ca->bytes);
    }
  }
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
ca_array_func_xfer_all (void *ap, void *data, int dir)
{
  CArray *ca = (CArray *) ap;
  if ( dir == CA_XFER_GET ) {
    memmove(data, ca->ptr, ca_length(ca));
  }
  else {
    memmove(ca->ptr, data, ca_length(ca));
  }
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
#ifdef HAVE_COMPLEX_H
  case CA_CMPLX64:  proc_fill_bang(cmplx64_t);  break;
  case CA_CMPLX128: proc_fill_bang(cmplx128_t);  break;
#endif
  case CA_OBJECT:   proc_fill_bang(VALUE);  break;
  default: rb_bug("array has an unknown data type");
  }
}

/* The bottom of the fill_stride descent: the value is already in this
   array's data_type and the region is in its own addresses, so all that is
   left is to write it.  The innermost axis runs contiguously whenever its
   step is 1, which is the usual case once a view has composed down to here,
   so that axis is written as a run rather than a cell at a time. */

void
ca_fill_stride_buffer (char *dst, ca_size_t bytes, ca_size_t base, int8_t ndim,
                       ca_size_t *counts, ca_size_t *steps, void *ptr)
{
  ca_size_t idx[CA_RANK_MAX];
  ca_size_t inner_count, inner_step;
  int8_t    outer_ndim, k;

  if ( ndim <= 0 ) {
    memcpy(dst + base * bytes, ptr, bytes);
    return;
  }

  inner_count = counts[ndim - 1];
  inner_step  = steps[ndim - 1];
  outer_ndim  = ndim - 1;

  for ( k = 0; k < outer_ndim; k++ ) idx[k] = 0;
  while ( 1 ) {
    ca_size_t addr = base;
    char     *p;
    ca_size_t i;
    for ( k = 0; k < outer_ndim; k++ ) addr += idx[k] * steps[k];
    p = dst + addr * bytes;
    /* The width is known per array, not per cell, so hoist it out of the run
       rather than paying a memcpy call for every element.  A step of 1 gets
       its own loop because that is the shape the compiler can widen; a wider
       step still gets the typed store, which is where a view that composed
       down to a strided run lands -- an interleaved channel, say. */
#define CA_FILL_RUN(T)                                                    \
    { T v = *(T *)ptr, *q = (T *)p;                                       \
      if ( inner_step == 1 ) { for ( i = 0; i < inner_count; i++ ) q[i] = v; } \
      else { for ( i = 0; i < inner_count; i++ ) { *q = v; q += inner_step; } } \
      break; }
    switch ( bytes ) {
    case 1: CA_FILL_RUN(uint8_t)
    case 2: CA_FILL_RUN(uint16_t)
    case 4: CA_FILL_RUN(uint32_t)
    case 8: CA_FILL_RUN(uint64_t)
    default:
      for ( i = 0; i < inner_count; i++ ) {
        memcpy(p, ptr, bytes);
        p += inner_step * bytes;
      }
    }
#undef CA_FILL_RUN
    if ( outer_ndim == 0 ) break;
    k = outer_ndim - 1;
    while ( k >= 0 ) { if ( ++idx[k] < counts[k] ) break; idx[k] = 0; k--; }
    if ( k < 0 ) break;
  }
}

void
ca_fill_addrs_buffer (char *dst, ca_size_t bytes, ca_size_t n,
                      ca_size_t *addrs, void *ptr)
{
  ca_size_t i;
  for ( i = 0; i < n; i++ ) {
    memcpy(dst + addrs[i] * bytes, ptr, bytes);
  }
}

void
ca_array_func_fill_stride (void *ap, ca_size_t base, int8_t ndim,
                           ca_size_t *counts, ca_size_t *steps, void *ptr)
{
  CArray *ca = (CArray *) ap;
  ca_fill_stride_buffer(ca->ptr, ca->bytes, base, ndim, counts, steps, ptr);
}

void
ca_array_func_fill_addrs (void *ap, ca_size_t n, ca_size_t *addrs, void *ptr)
{
  CArray *ca = (CArray *) ap;
  ca_fill_addrs_buffer(ca->ptr, ca->bytes, n, addrs, ptr);
}

void
ca_array_func_create_mask (void *ap)
{
  CArray *ca = (CArray *) ap;
  ca->mask = carray_new_safe(CA_BOOLEAN, ca->ndim, ca->dim, 0, NULL);
}

/* Pool framework hooks for the CArray entity (and CAWrap, which shares the
   struct + carray_setup_i).  Single ndim-sized tail (dim) lives in _pool.
   These are set in the static func-table literals below so the hooks are
   present the instant ca_func[CA_OBJ_ARRAY] is assigned -- carray_new runs
   during Init, before any per-class Init_* would have a chance to register
   them. */
static size_t
carray_pool_bytes (int8_t ndim)
{
  ca_size_t n = (ndim > 0) ? ndim : 1;
  return (size_t) n * sizeof(ca_size_t);
}

static void
carray_pool_init (void *ap, int8_t ndim)
{
  CArray *ca = (CArray *) ap;
  ca->dim = (ca_size_t *) ca->_pool;
}

ca_operation_function_t ca_array_func = {
  CA_OBJ_ARRAY,
  CA_REAL_ARRAY,
  free_carray,
  ca_array_func_clone,
  ca_array_func_allocate,
  ca_array_func_attach,
  ca_array_func_sync,
  ca_array_func_detach,
  ca_array_func_fill_data,
  ca_array_func_create_mask,
  ca_array_func_xfer_index,
  ca_array_func_xfer_addrs,
  .xfer_all     = ca_array_func_xfer_all,
  .fill_addrs   = ca_array_func_fill_addrs,
  .fill_stride  = ca_array_func_fill_stride,
  .struct_size  = sizeof(CArray),
  .pool_bytes   = carray_pool_bytes,
  .pool_init    = carray_pool_init,
};

ca_operation_function_t ca_wrap_func = {
  CA_OBJ_ARRAY_WRAP,
  CA_REAL_ARRAY,
  free_ca_wrap,
  ca_array_func_clone,
  ca_array_func_allocate,
  ca_array_func_attach,
  ca_array_func_sync,
  ca_array_func_detach,
  ca_array_func_fill_data,
  ca_array_func_create_mask,
  ca_array_func_xfer_index,
  ca_array_func_xfer_addrs,
  .xfer_all     = ca_array_func_xfer_all,
  .fill_addrs   = ca_array_func_fill_addrs,
  .fill_stride  = ca_array_func_fill_stride,
  .struct_size  = sizeof(CArray),   /* CAWrap is a typedef of CArray */
  .pool_bytes   = carray_pool_bytes,
  .pool_init    = carray_pool_init,
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

#define ca_scalar_func_allocate      ca_array_func_allocate
#define ca_scalar_func_attach        ca_array_func_attach
#define ca_scalar_func_sync          ca_array_func_sync
#define ca_scalar_func_detach        ca_array_func_detach
#define ca_scalar_func_fill_data          ca_array_func_fill_data
#define ca_scalar_func_create_mask   ca_array_func_create_mask
#define ca_scalar_func_xfer_index    ca_array_func_xfer_index

ca_operation_function_t ca_scalar_func = {
  CA_OBJ_SCALAR,
  CA_REAL_ARRAY,
  free_cscalar,
  ca_scalar_func_clone,
  ca_scalar_func_allocate,
  ca_scalar_func_attach,
  ca_scalar_func_sync,
  ca_scalar_func_detach,
  ca_scalar_func_fill_data,
  ca_scalar_func_create_mask,
  ca_scalar_func_xfer_index,
  ca_array_func_xfer_addrs,
  .xfer_all = ca_array_func_xfer_all,
  .fill_addrs   = ca_array_func_fill_addrs,
  .fill_stride  = ca_array_func_fill_stride,
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
rb_carray_new_adopt (int8_t data_type, int8_t ndim, ca_size_t *dim,
                     ca_size_t bytes, char *ptr)
{
  CArray *ca = carray_new_adopt(data_type, ndim, dim, bytes, ptr);
  return ca_wrap_struct(ca);
}


VALUE
rb_ca_wrap_new (int8_t data_type, int8_t ndim, ca_size_t *dim, ca_size_t bytes,
               CArray *mask, char *ptr)
{
  CAWrap *ca = ca_wrap_new(data_type, ndim, dim, bytes, mask, ptr);
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
  return TypedData_Make_Struct(klass, CArray, &carray_data_type, ca);
}

/* @overload  initialize(data_type, dim, bytes=0) { ... }

Constructs a new CArray object of <i>data_type</i>, which has the
ndim and the dimensions specified by an <code>Array</code> of
<code>Integer</code> or an argument list of <code>Integer</code>.
The byte size of each element for the fixed length data type
(<code>data_type == CA_FIXLEN</code>) is specified optional argument
<i>bytes</i>. Otherwise, this optional argument has no
effect. If the block is given, the new CArray
object will be initialized by the value returned from the block.
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

  /* data_class may only be attached to a CARecord (= Face), so
     constructing a data_class-bearing entity with `CArray.new(MyStruct,
     [N])` is not offered: a Class first argument raises with migration
     guidance.  (View-side data_class propagation, e.g. refer(MyStruct,
     [N]), is handled elsewhere via the data_class inherit path.) */
  if ( TYPE(rtype) == T_CLASS ) {
    rb_raise(rb_eArgError,
             "CArray.new(%"PRIsVALUE", ...) was removed in 3.0. "
             "Use `CARecord.new(%"PRIsVALUE", *shape)` or define "
             "`class MyArr < CARecord; data_class %"PRIsVALUE"; end`.",
             rtype, rtype, rtype);
  }

  rb_ca_guess_type_and_bytes(rtype, rbytes, &data_type, &bytes);

  Check_Type(rdim, T_ARRAY);
  ndim = RARRAY_LEN(rdim);
  for (i=0; i<ndim; i++) {
    dim[i] = NUM2SIZE(rb_ary_entry(rdim, i));
  }

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  if ( ca_func[CA_OBJ_ARRAY].pool_init ) {
    ca_array_pool_alloc(ca, CA_OBJ_ARRAY, ndim);
  }
  carray_safe_setup(ca, data_type, ndim, dim, bytes, NULL);

  if ( rb_block_given_p() ) {
    /* Two block forms:
       - arity == 0 (`{ 1.0 }`): the block is called *once* and its
         return value is broadcast to the whole array via
         `rb_ca_store_all` (= scalar-fill fast path).  This matches
         the dominant `CArray.<type>(n) { value }` idiom and avoids
         the O(n) call overhead of per-cell yield for what is really
         a constant fill.
       - arity != 0 (`{ |i, j| ... }` etc.): per-cell subscript walk
         (= map_index! semantics).  The block is called once per cell
         with the multi-dimensional subscript yielded as individual
         integer arguments, so |i|, |i,j|, |i,j,k| all work uniformly
         across ranks.  Block forms that want the whole subscript as
         an Array should write |*idx|. */
    if ( rb_proc_arity(rb_block_proc()) == 0 ) {
      volatile VALUE rval = rb_yield_values2(0, NULL);
      rb_ca_store_all(self, rval);
    }
    else if ( ca->ndim > 0 ) {
      ca_size_t idx[CA_RANK_MAX];
      volatile VALUE ridx = rb_ary_new2(ca->ndim);
      ca_attach(ca);
      rb_ca_index_walk(self, ca, 0, idx, ridx, CA_LOOP_STORE);
      ca_sync(ca);
      ca_detach(ca);
    }
    else {
      /* 0-D safety net (rare from CArray.new path): yield no args. */
      volatile VALUE rval = rb_yield_values2(0, NULL);
      rb_ca_store_addr(self, 0, rval);
    }
  }

  return Qnil;
}

/* @overload  fixlen(*dim, bytes: ) { ... } 

(Construction)
Short-Hand of `CArray.new(:fixlen, dim, bytes: ) { ... }`
*/

static VALUE
rb_ca_s_fixlen (int argc, VALUE *argv, VALUE klass)  
{                                                     
  volatile VALUE ropt = rb_pop_options(&argc, &argv); 
  volatile VALUE rdim = rb_ary_new4(argc, argv);      
  VALUE args[3] = { INT2NUM(CA_FIXLEN), rdim, ropt };      
  return rb_class_new_instance(3, args, klass);       
}

#define rb_ca_s_body(code)                              \
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

/* @overload  boolean(*dim) { ... } 

(Construction)
Short-Hand of `CArray.new(:boolean, dim, bytes: bytes) { ... }`
*/
static VALUE rb_ca_s_boolean (int argc, VALUE *argv, VALUE klass)
{
  rb_ca_s_body(CA_BOOLEAN);
}

/* @overload  int8(*dim) { ... } 

(Construction)
Short-Hand of `CArray.new(:int8, dim, bytes: bytes) { ... }`
*/
static VALUE rb_ca_s_int8 (int argc, VALUE *argv, VALUE klass)
{
  rb_ca_s_body(CA_INT8);
}

/* @overload  uint8(*dim) { ... } 

(Construction)
Short-Hand of `CArray.new(:uint8, dim, bytes: bytes) { ... }`
*/
static VALUE rb_ca_s_uint8 (int argc, VALUE *argv, VALUE klass)
{
  rb_ca_s_body(CA_UINT8);
}

/* @overload  int16(*dim) { ... } 

(Construction)
Short-Hand of `CArray.new(:int16, dim, bytes: bytes) { ... }`
*/
static VALUE rb_ca_s_int16 (int argc, VALUE *argv, VALUE klass)
{
  rb_ca_s_body(CA_INT16);
}

/* @overload  uint16(*dim) { ... } 

(Construction)
Short-Hand of `CArray.new(:uint16, dim, bytes: bytes) { ... }`
*/
static VALUE rb_ca_s_uint16 (int argc, VALUE *argv, VALUE klass)
{
  rb_ca_s_body(CA_UINT16);
}

/* @overload  int32(*dim) { ... } 

(Construction)
Short-Hand of `CArray.new(:int32, dim, bytes: bytes) { ... }`
*/
static VALUE rb_ca_s_int32 (int argc, VALUE *argv, VALUE klass)
{
  rb_ca_s_body(CA_INT32);
}

/* @overload  uint32(*dim) { ... } 

(Construction)
Short-Hand of `CArray.new(:uint32, dim, bytes: bytes) { ... }`
*/
static VALUE rb_ca_s_uint32 (int argc, VALUE *argv, VALUE klass)
{
  rb_ca_s_body(CA_UINT32);
}

/* @overload  int64(*dim) { ... } 

(Construction)
Short-Hand of `CArray.new(:int64, dim, bytes: bytes) { ... }`
*/
static VALUE rb_ca_s_int64 (int argc, VALUE *argv, VALUE klass)
{
  rb_ca_s_body(CA_INT64);
}

/* @overload  uint64(*dim) { ... } 

(Construction)
Short-Hand of `CArray.new(:uint64, dim, bytes: bytes) { ... }`
*/
static VALUE rb_ca_s_uint64 (int argc, VALUE *argv, VALUE klass)
{
  rb_ca_s_body(CA_UINT64);
}

/* @overload  float32(*dim) { ... } 

(Construction)
Short-Hand of `CArray.new(:float32, dim, bytes: bytes) { ... }`
*/
static VALUE rb_ca_s_float32 (int argc, VALUE *argv, VALUE klass)
{
  rb_ca_s_body(CA_FLOAT32);
}

/* @overload  float64(*dim) { ... } 

(Construction)
Short-Hand of `CArray.new(:float64, dim, bytes: bytes) { ... }`
*/
static VALUE rb_ca_s_float64 (int argc, VALUE *argv, VALUE klass)
{
  rb_ca_s_body(CA_FLOAT64);
}

#ifdef HAVE_COMPLEX_H
/* @overload  cmplx64(*dim) { ... } 

(Construction)
Short-Hand of `CArray.new(:cmplx64, dim, bytes: bytes) { ... }`
*/
static VALUE rb_ca_s_cmplx64 (int argc, VALUE *argv, VALUE klass)
{
  rb_ca_s_body(CA_CMPLX64);
}

/* @overload  cmplx128(*dim) { ... } 

(Construction)
Short-Hand of `CArray.new(:cmplx128, dim, bytes: bytes) { ... }`
*/
static VALUE rb_ca_s_cmplx128 (int argc, VALUE *argv, VALUE klass)
{
  rb_ca_s_body(CA_CMPLX128);
}

#endif

/* @overload  object(*dim) { ... } 

(Construction)
Short-Hand of `CArray.new(:object, dim, bytes: bytes) { ... }`
*/
static VALUE rb_ca_s_VALUE (int argc, VALUE *argv, VALUE klass)
{
  rb_ca_s_body(CA_OBJECT);
}

/* @overload  initialize_copy(other)

*/
static VALUE
rb_ca_initialize_copy (VALUE self, VALUE other)
{
  CArray *ca, *cs;

  rb_call_super(1, &other);

  TypedData_Get_Struct(self,  CArray, &carray_data_type, ca);
  TypedData_Get_Struct(other, CArray, &carray_data_type, cs);

  ca_update_mask(cs);
  if ( ca_func[CA_OBJ_ARRAY].pool_init ) {
    ca_array_pool_alloc(ca, CA_OBJ_ARRAY, cs->ndim);
  }
  carray_setup(ca, cs->data_type, cs->ndim, cs->dim, cs->bytes, cs->mask);

  memcpy(ca->ptr, cs->ptr, ca_length(cs));

  return self;
}

/* @overload wrap (data_type, dim, bytes=0) { target }

[TBD] (Construction)
target should have method "wrap_as_carray(obj)"
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

  obj = TypedData_Make_Struct(rb_cCAWrap, CAWrap, &cawrap_data_type, ca);
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
  return TypedData_Make_Struct(klass, CScalar, &cscalar_data_type, ca);
}

/* 
 call-seq:
     CScalar.new(data_type, bytes=0) { ... }

  Constructs a new CScalar object of <i>data_type</i>.
  The byte size of each element for the fixed length data type
  (<code>data_type == CA_FIXLEN</code>) is specified optional argument
  <i>bytes</i>. Otherwise, this optional argument has no
  effect. If the block is given, the new CScalar
  object will be initialized by the value returned from the block.
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

  TypedData_Get_Struct(self, CScalar, &cscalar_data_type, ca);
  cscalar_setup(ca, data_type, bytes, NULL);

  if ( rb_block_given_p() ) {
    volatile VALUE rval = rb_yield(self);
    if ( rval != self ) {
      rb_ca_store_addr(self, 0, rval);
    }
  }

  return Qnil;
}

/* @overload  fixlen(*dim, bytes: ) { ... } 

(Construction)
Short-Hand of `CScalar.new(:fixlen, bytes: ) { ... }`
*/

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

#define rb_cs_s_body(code)                      \
{                                                     \
  volatile VALUE ropt = rb_pop_options(&argc, &argv); \
  VALUE args[2] = { INT2NUM(code), ropt };            \
  if ( argc > 0 ) {                                   \
    rb_raise(rb_eArgError, "invalid number of arguments"); \
  }                                                   \
  return rb_class_new_instance(2, args, klass);       \
}

/* @overload  boolean() { ... } 

(Construction)
Short-Hand of `CArray.new(:boolean) { ... }`
*/
static VALUE 
rb_cs_s_boolean (int argc, VALUE *argv, VALUE klass) {
  rb_cs_s_body(CA_BOOLEAN);
}

/* @overload  int8() { ... } 

(Construction)
Short-Hand of `CScalar.new(:int8) { ... }`
*/
static VALUE 
rb_cs_s_int8 (int argc, VALUE *argv, VALUE klass) {
  rb_cs_s_body(CA_INT8);
}

/* @overload uint8() { ... } 

(Construction)
Short-Hand of `CScalar.new(:uint8) { ... }`
*/
static VALUE 
rb_cs_s_uint8 (int argc, VALUE *argv, VALUE klass) {
  rb_cs_s_body(CA_UINT8);
}


/* @overload int16() { ... } 

(Construction)
Short-Hand of `CScalar.new(:int16) { ... }`
*/
static VALUE 
rb_cs_s_int16 (int argc, VALUE *argv, VALUE klass) {
  rb_cs_s_body(CA_INT16);
}

/* @overload uint16() { ... } 

(Construction)
Short-Hand of `CScalar.new(:uint16) { ... }`
*/
static VALUE 
rb_cs_s_uint16 (int argc, VALUE *argv, VALUE klass) {
  rb_cs_s_body(CA_UINT16);
}

/* @overload int32() { ... } 

(Construction)
Short-Hand of `CScalar.new(:int32) { ... }`
*/
static VALUE 
rb_cs_s_int32 (int argc, VALUE *argv, VALUE klass) {
  rb_cs_s_body(CA_INT32);
}

/* @overload uint32() { ... } 

(Construction)
Short-Hand of `CScalar.new(:uint32) { ... }`
*/
static VALUE 
rb_cs_s_uint32 (int argc, VALUE *argv, VALUE klass) {
  rb_cs_s_body(CA_UINT32);
}

/* @overload int64() { ... } 

(Construction)
Short-Hand of `CScalar.new(:int64) { ... }`
*/
static VALUE 
rb_cs_s_int64 (int argc, VALUE *argv, VALUE klass) {
  rb_cs_s_body(CA_INT64);
}

/* @overload uint64() { ... } 

(Construction)
Short-Hand of `CScalar.new(:uint64) { ... }`
*/
static VALUE 
rb_cs_s_uint64 (int argc, VALUE *argv, VALUE klass) {
  rb_cs_s_body(CA_UINT64);
}

/* @overload float32() { ... } 

(Construction)
Short-Hand of `CScalar.new(:float32) { ... }`
*/
static VALUE 
rb_cs_s_float32 (int argc, VALUE *argv, VALUE klass) {
  rb_cs_s_body(CA_FLOAT32);
}

/* @overload float64() { ... } 

(Construction)
Short-Hand of `CScalar.new(:float64) { ... }`
*/
static VALUE 
rb_cs_s_float64 (int argc, VALUE *argv, VALUE klass) {
  rb_cs_s_body(CA_FLOAT64);
}

#ifdef HAVE_COMPLEX_H
/* @overload cmplx64() { ... } 

(Construction)
Short-Hand of `CScalar.new(:cmplx64) { ... }`
*/
static VALUE 
rb_cs_s_cmplx64 (int argc, VALUE *argv, VALUE klass) {
  rb_cs_s_body(CA_CMPLX64);
}

/* @overload cmplx128() { ... } 

(Construction)
Short-Hand of `CScalar.new(:cmplx128) { ... }`
*/
static VALUE 
rb_cs_s_cmplx128 (int argc, VALUE *argv, VALUE klass) {
  rb_cs_s_body(CA_CMPLX128);
}

#endif

/* @overload object() { ... } 

(Construction)
Short-Hand of `CScalar.new(:object) { ... }`
*/
static VALUE 
rb_cs_s_VALUE (int argc, VALUE *argv, VALUE klass) {
  rb_cs_s_body(CA_OBJECT);
}

/* @overload  initialize_copy(other)

*/

static VALUE
rb_cs_initialize_copy (VALUE self, VALUE other)
{
  CScalar *ca, *cs;

  TypedData_Get_Struct(self,  CScalar, &cscalar_data_type, ca);
  TypedData_Get_Struct(other, CScalar, &cscalar_data_type, cs);

  cscalar_setup(ca, cs->data_type, cs->bytes, NULL);
  memcpy(ca->ptr, cs->ptr, ca->bytes);


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
  TypedData_Get_Struct(self, CScalar, &cscalar_data_type, ca);
  return rb_assoc_new(rb_cscalar_new_with_value(ca->data_type, ca->bytes, other), 
                      self);
}
*/

/* Internal primitive that wraps rb_carray_new (= uninit alloc) for the
   Ruby-side CArray.empty factory in lib/carray/data_type_extension.rb.
   Bypasses the explicit MEMZERO that CArray.new (= rb_carray_new_safe)
   pays for safety. CA_OBJECT silently falls through to the zero-VALUE
   init inside carray_setup_i (= required for GC), so it is safe to
   call this with any data_type. */
static VALUE
rb_ca_s_alloc_uninit (VALUE klass, VALUE rtype, VALUE rshape)
{
  int8_t data_type;
  ca_size_t bytes;
  ca_size_t dim[CA_RANK_MAX];
  int8_t ndim;
  int8_t i;
  rb_ca_guess_type_and_bytes(rtype, Qnil, &data_type, &bytes);
  Check_Type(rshape, T_ARRAY);
  ndim = (int8_t) RARRAY_LEN(rshape);
  for (i = 0; i < ndim; i++) dim[i] = NUM2SIZE(rb_ary_entry(rshape, i));
  return rb_carray_new(data_type, ndim, dim, bytes, NULL);
}

void
Init_ca_obj_array (void)
{
  /* rb_cCArray,  CA_OBJ_ARRAY are defined in rb_carray.c */
  /* rb_cCAWrap,  CA_OBJ_ARRAY_WRAP are defined in rb_carray.c */
  /* rb_cCScalar, CA_OBJ_SCALAR are defined in rb_carray.c */

  rb_define_alloc_func(rb_cCArray, rb_ca_s_allocate);
  rb_define_method(rb_cCArray, "initialize", rb_ca_initialize, -1);
  rb_define_singleton_method(rb_cCArray, "__alloc_uninit__",
                             rb_ca_s_alloc_uninit, 2);

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
#ifdef HAVE_COMPLEX_H
  rb_define_singleton_method(rb_cCArray, "cmplx64", rb_ca_s_cmplx64, -1);
  rb_define_singleton_method(rb_cCArray, "cmplx128", rb_ca_s_cmplx128, -1);
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
#ifdef HAVE_COMPLEX_H
  rb_define_singleton_method(rb_cCScalar, "cmplx64", rb_cs_s_cmplx64, -1);
  rb_define_singleton_method(rb_cCScalar, "cmplx128", rb_cs_s_cmplx128, -1);
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

}
