/* ---------------------------------------------------------------------------

  carray.h

  This file is part of Ruby/CArray extension library.

  Copyright (C) 2005-2020 Hiroki Motoyoshi

---------------------------------------------------------------------------- */

#ifndef CARRAY_H
#define CARRAY_H

#include "ruby.h"

#ifdef HAVE_RB_ARITHMETIC_SEQUENCE_EXTRACT
extern VALUE rb_cArithSeq;
#endif

/* -------------------------------------------------------------------- */

#include "carray_config.h"

/* -------------------------------------------------------------------- */

#ifndef RSTRING_PTR
#  define RSTRING_PTR(s) (RSTRING(s)->ptr)
#endif
#ifndef RSTRING_LEN
#  define RSTRING_LEN(s) (RSTRING(s)->len)
#endif

#ifndef RARRAY_PTR
#  define RARRAY_PTR(a) (RARRAY(a)->ptr)
#endif
#ifndef RARRAY_LEN
#  define RARRAY_LEN(a) (RARRAY(a)->len)
#endif

#ifndef NUM2ULL
#  define NUM2ULL(x) NUM2LL(x)
#endif

/* -------------------------------------------------------------------- */

#include <float.h>

#ifdef HAVE_SYS_TYPES_H
#  include <sys/types.h>
#endif

#ifdef HAVE_STDINT_H
#  include <stdint.h>
#endif

typedef char      dummy_t;

#ifndef HAVE_TYPE_INT8_T
#  define HAVE_TYPE_INT8_T 1
   typedef signed char   int8_t;
#endif

typedef int8_t boolean8_t;

#ifndef HAVE_TYPE_UINT8_T
#  define HAVE_TYPE_UINT8_T 1
   typedef unsigned char uint8_t;
#endif

#ifndef HAVE_TYPE_INT16_T
#  if SIZEOF_SHORT == 2
#    define HAVE_TYPE_INT16_T 1
     typedef short     int16_t;
#  else
     typedef dummy_t   int16_t;
#  endif
#endif

#ifndef HAVE_TYPE_UINT16_T
#  if SIZEOF_SHORT == 2
#    define HAVE_TYPE_UINT16_T 1
     typedef unsigned short uint16_t;
#  else
     typedef dummy_t   uint16_t;
#  endif
#endif

#ifndef HAVE_TYPE_INT32_T
#  if SIZEOF_LONG == 4
#    define HAVE_TYPE_INT32_T 1
     typedef long int32_t;
#  else
#    if SIZEOF_INT == 4
#      define HAVE_TYPE_INT32_T 1
       typedef int  int32_t;
#    else
       typedef dummy_t   uint32_t;
#    endif
#  endif
#endif

#ifndef HAVE_TYPE_UINT32_T
#  if SIZEOF_LONG == 4
#    define HAVE_TYPE_UINT32_T 1
     typedef unsigned long uint32_t;
#  else
#    if SIZEOF_INT == 4
#      define HAVE_TYPE_UINT32_T 1
       typedef unsigned int  uint32_t;
#    else
       typedef dummy_t   uint32_t;
#    endif
#  endif
#endif

#ifndef HAVE_TYPE_INT64_T
#  if HAVE_LONG_LONG == 1 && SIZEOF_LONG_LONG == 8
#    define HAVE_TYPE_INT64_T 1
     typedef long long int64_t;
#  else
     typedef dummy_t   int64_t;
#  endif
#endif

#ifndef HAVE_TYPE_UINT64_T
#  if HAVE_LONG_LONG == 1 && SIZEOF_LONG_LONG == 8
#    define HAVE_TYPE_UINT64_T 1
     typedef unsigned long long uint64_t;
#  else
     typedef dummy_t   uint64_t;
#  endif
#endif

#if HAVE_TYPE_FLOAT == 1 && SIZEOF_FLOAT == 4
#  define HAVE_TYPE_FLOAT32_T 1
   typedef float float32_t;
#else
   typedef dummy_t float32_t;
#endif

#if HAVE_TYPE_DOUBLE == 1 && SIZEOF_DOUBLE == 8
#  define HAVE_TYPE_FLOAT64_T 1
   typedef double float64_t;
#else
   typedef dummy_t float64_t;
#endif

/* float128_t is currently disabled in extconf.rb */

#if HAVE_TYPE_LONG_DOUBLE == 1 && SIZEOF_LONG_DOUBLE == 16
#  define HAVE_TYPE_FLOAT128_T 1
   typedef long double float128_t;
#else
   typedef dummy_t float128_t;
#endif

#ifdef HAVE_COMPLEX_H
#  include <complex.h>
#endif

#ifdef HAVE_TYPE_FLOAT_COMPLEX
#  define HAVE_TYPE_CMPLX64_T 1
   typedef float complex cmplx64_t;
#else
   typedef dummy_t  cmplx64_t;
#endif

#ifdef HAVE_TYPE_DOUBLE_COMPLEX
#  define HAVE_TYPE_CMPLX128_T 1
   typedef double complex cmplx128_t;
#else
   typedef dummy_t  cmplx128_t;
#endif

/* cmplx256_t is currently disabled in extconf.rb */

#if HAVE_TYPE_LONG_DOUBLE_COMPLEX == 1 && SIZEOF_LONG_DOUBLE_COMPLEX == 32
#  define HAVE_TYPE_CMPLX256_T 1
   typedef long double complex cmplx256_t;
#else
   typedef dummy_t  cmplx256_t;
#endif


#include <stddef.h>

#define CA_ALIGN_VOIDP    offsetof(struct { char c; void   *x; }, x)
#define CA_ALIGN_INT8     offsetof(struct { char c; int8_t  x; }, x)
#define CA_ALIGN_INT16    offsetof(struct { char c; int16_t x; }, x)
#define CA_ALIGN_INT32    offsetof(struct { char c; int32_t x; }, x)
#define CA_ALIGN_INT64    offsetof(struct { char c; int64_t x; }, x)
#define CA_ALIGN_FLOAT32  offsetof(struct { char c; float32_t  x; }, x)
#define CA_ALIGN_FLOAT64  offsetof(struct { char c; float64_t  x; }, x)
#define CA_ALIGN_FLOAT128 offsetof(struct { char c; float128_t x; }, x)
#define CA_ALIGN_CMPLX64  offsetof(struct { char c; cmplx64_t  x; }, x)
#define CA_ALIGN_CMPLX128 offsetof(struct { char c; cmplx128_t x; }, x)
#define CA_ALIGN_CMPLX256 offsetof(struct { char c; cmplx256_t x; }, x)
#define CA_ALIGN_OBJECT   offsetof(struct { char c; VALUE      x; }, x)

/* -------------------------------------------------------------------- */

#define CA_OBJ_TYPE_MAX  256
#define CA_DIM_MAX       16
#define CA_RANK_MAX      CA_DIM_MAX
#define CA_ATTACH_MAX    0x80000000

#define CA_FLAG_SCALAR           1
#define CA_FLAG_MASK_ARRAY       2
#define CA_FLAG_VALUE_ARRAY      4
#define CA_FLAG_READ_ONLY        8
#define CA_FLAG_SHARE_INDEX     16
#define CA_FLAG_NOT_DATA_CLASS  32
#define CA_FLAG_CYCLE_CHECK     64

enum {
  CA_LITTLE_ENDIAN = 0,
  CA_BIG_ENDIAN = 1
};

enum {
  CA_REAL_ARRAY,
  CA_VIRTUAL_ARRAY
};

enum {
  CA_OBJ_ARRAY,
  CA_OBJ_ARRAY_WRAP,
  CA_OBJ_SCALAR,
  CA_OBJ_REFER,
  CA_OBJ_BLOCK,
  CA_OBJ_SELECT,
  CA_OBJ_OBJECT,
  CA_OBJ_REPEAT,
  CA_OBJ_UNBOUND_REPEAT,
};

enum {
  CA_NONE = -1, /* -1 */
  CA_FIXLEN,  /* 0 */
  CA_BOOLEAN,   /* 1 */
  CA_INT8,      /* 2 */
  CA_UINT8,     /* 3 */
  CA_INT16,     /* 4 */
  CA_UINT16,    /* 5 */
  CA_INT32,     /* 6 */
  CA_UINT32,    /* 7 */
  CA_INT64,     /* 8 */
  CA_UINT64,    /* 9 */
  CA_FLOAT32,   /* 10 */
  CA_FLOAT64,   /* 11 */
  CA_FLOAT128,  /* 12 */
  CA_CMPLX64,   /* 13 */
  CA_CMPLX128,  /* 14 */
  CA_CMPLX256,  /* 15 */
  CA_OBJECT,    /* 16 */
  CA_NTYPE,     /* 17 */
  CA_BYTE     = CA_UINT8,
  CA_SHORT    = CA_INT16,
  CA_INT      = CA_INT32,
  CA_FLOAT    = CA_FLOAT32,
  CA_DOUBLE   = CA_FLOAT64,
  CA_COMPLEX  = CA_CMPLX64,
  CA_DCOMPLEX = CA_CMPLX128,
}; /* CA_DATA_TYPE */

enum {
  CA_BOUNDS_RUBY = 1,
  CA_BOUNDS_STRICT,
  CA_BOUNDS_NEAREST,
  CA_BOUNDS_PERIODIC,
  CA_BOUNDS_REFLECT,
  CA_BOUNDS_FILL,
  CA_BOUNDS_MASK,
}; /* CA_BOUNDS_TYPE for CAWindow */

/* -------------------------------------------------------------------- */

#ifdef HAVE_TYPE_INT64_T
   typedef int64_t ca_size_t;
   #define CA_SIZE CA_INT64
   #define NUM2SIZE(x) NUM2LL(x)
   #define SIZE2NUM(x) LL2NUM(x)
   #define CA_LENGTH_MAX    0x7fffffffffffffff
#else
   typedef int32_t ca_size_t;
   #define CA_SIZE CA_INT32
   #define NUM2SIZE(x) NUM2LONG(x)
   #define SIZE2NUM(x) LONG2NUM(x)
   #define CA_LENGTH_MAX    0x7fffffff 
#endif

/* -------------------------------------------------------------------- */


typedef struct {
  int32_t obj_type;
  int32_t entity_type;
  void   (*free_object)  (void *ap);
  void * (*clone)        (void *ap);
  char * (*ptr_at_addr)  (void *ap, ca_size_t addr);
  char * (*ptr_at_index) (void *ap, ca_size_t *idx);
  void   (*fetch_addr)   (void *ap, ca_size_t addr, void *data);
  void   (*fetch_index)  (void *ap, ca_size_t *idx, void *data);
  void   (*store_addr)   (void *ap, ca_size_t addr, void *data);
  void   (*store_index)  (void *ap, ca_size_t *idx, void *data);
  void   (*allocate)     (void *ap);
  void   (*attach)       (void *ap);
  void   (*sync)         (void *ap);
  void   (*detach)       (void *ap);
  void   (*copy_data)    (void *ap, void *data);
  void   (*sync_data)    (void *ap, void *data);
  void   (*fill_data)    (void *ap, void *data);
  void   (*create_mask)  (void *ap);
} ca_operation_function_t;

/* default operation_function */

void * ca_array_func_clone        (void *ap);
char * ca_array_func_ptr_at_addr  (void *ap, ca_size_t addr);
char * ca_array_func_ptr_at_index (void *ap, ca_size_t *idx);
void   ca_array_func_fetch_addr   (void *ap, ca_size_t addr, void *ptr);
void   ca_array_func_fetch_index  (void *ap, ca_size_t *idx, void *ptr);
void   ca_array_func_store_addr   (void *ap, ca_size_t addr, void *ptr);
void   ca_array_func_store_index  (void *ap, ca_size_t *idx, void *ptr);
void   ca_array_func_allocate     (void *ap);
void   ca_array_func_attach       (void *ap);
void   ca_array_func_sync         (void *ap);
void   ca_array_func_detach       (void *ap);
void   ca_array_func_copy_data    (void *ap, void *ptr);
void   ca_array_func_sync_data    (void *ap, void *ptr);
void   ca_array_func_fill_data    (void *ap, void *val);
void   ca_array_func_create_mask  (void *ap);

/* -------------------------------------------------------------------- */

/* CArray : base class of all carray object */

typedef struct _CArray CArray;

struct _CArray {
  int16_t   obj_type;
  int8_t    data_type;
  int8_t    ndim;
  int32_t   flags;
  ca_size_t   bytes;
  ca_size_t   elements;
  ca_size_t  *dim;
  char     *ptr;
  CArray   *mask;
};                         /* 28 + 4*ndim (bytes) */

typedef CArray CAWrap;

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
  ca_size_t  _dim;
} CScalar;                 /* 32 (bytes) */

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
} CAVirtual;               /* 40 + 4*(ndim) (bytes) */

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
  /* ---------- */
  int8_t    is_deformed; /* 0  : not deformed */
                         /* 1  : deformed */
                         /* -2 : divided */
                         /* 2  : spanned  */
  ca_size_t   ratio;
  ca_size_t   offset;
  CArray   *mask0;
} CARefer;                 /* 52 + 4*(ndim) (bytes) */

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
  /* ---------- */
  int8_t    maxdim_index;
  ca_size_t   maxdim_step;
  ca_size_t   maxdim_step0;
  ca_size_t   offset;
  ca_size_t  *start;
  ca_size_t  *step;
  ca_size_t  *count;
  ca_size_t  *size0;
} CABlock;                 /* 68 + 20*(ndim) (bytes) */

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
  /* ---------- */
  uint8_t   bounds;
  ca_size_t  *start;
  ca_size_t  *count;
  ca_size_t  *size0;
  char     *fill;
} CAWindow;                /* 56 + 16*(ndim) + 1*(bytes) (bytes) */

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
  CArray   *data;
  VALUE     self;
} CAObject;                /* 48 + 4*(ndim) (bytes) */

/* 
  CAObjectMask is an internal class 
  used only as mask array of CAObject.
*/

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
  /* -------------*/
  VALUE     array;
} CAObjectMask;

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
  ca_size_t  *count;
  ca_size_t   repeat_level;
  ca_size_t   repeat_num;
  ca_size_t   contig_level;
  ca_size_t   contig_num;
} CARepeat;                /* 60 + 8*(ndim) (bytes) */

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
  int8_t    rep_ndim;
  ca_size_t  *rep_dim;
} CAUnboundRepeat;         /* 44 + 8*(ndim) (bytes) */

/* 
   CAReduce is an internal class 
   used only in ca_obj_refer.c.
*/

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
  /* ---- */
  ca_size_t   count;
  ca_size_t   offset;
} CAReduce;

/* -------------------------------------------------------------------- */

typedef struct {
  int8_t  ndim;
  ca_size_t dim[CA_RANK_MAX];
  CArray *reference;
  CArray * (*kernel_at_addr)(void *, ca_size_t, CArray *);
  CArray * (*kernel_at_index)(void *, ca_size_t *, CArray *);
  CArray * (*kernel_move_to_addr)(void *, ca_size_t, CArray *);
  CArray * (*kernel_move_to_index)(void *, ca_size_t *, CArray *);
} CAIterator;

/* -------------------------------------------------------------------- */

extern VALUE rb_cCArray;
extern VALUE rb_cCAVirtual;
extern VALUE rb_cCScalar;
extern VALUE rb_cCAWrap;
extern VALUE rb_cCARefer;
extern VALUE rb_cCABlock;
extern VALUE rb_cCASelect;
extern VALUE rb_cCAObject;
extern VALUE rb_cCARepeat;
extern VALUE rb_cCAUnboundRepeat;
extern VALUE rb_cCAIterator;

extern VALUE rb_mCA;
extern VALUE rb_mCAMath;
extern VALUE rb_eCADataTypeError;

extern VALUE rb_cCArrayBoolean;
extern VALUE rb_cCArrayUInt8;
extern VALUE rb_cCArrayUInt16;
extern VALUE rb_cCArrayUInt32;
extern VALUE rb_cCArrayUInt64;
extern VALUE rb_cCArrayInt8;
extern VALUE rb_cCArrayInt16;
extern VALUE rb_cCArrayInt32;
extern VALUE rb_cCArrayInt64;
extern VALUE rb_cCArrayFloat32;
extern VALUE rb_cCArrayFloat64;
extern VALUE rb_cCArrayFloat128;
extern VALUE rb_cCArrayCmplx64;
extern VALUE rb_cCArrayCmplx128;
extern VALUE rb_cCArrayCmplx256;
extern VALUE rb_cCArrayObject;

/* -------------------------------------------------------------------- */

extern const int ca_endian;
extern const int32_t ca_valid[CA_NTYPE];
extern const int32_t ca_sizeof[CA_NTYPE];
extern const char *  ca_type_name[CA_NTYPE];
extern const int ca_cast_table[CA_NTYPE][CA_NTYPE];
extern const int ca_cast_table2[CA_NTYPE][CA_NTYPE];

extern VALUE ca_class[CA_OBJ_TYPE_MAX];
extern ca_operation_function_t ca_func[CA_OBJ_TYPE_MAX];
extern int ca_obj_num;

#define CAVIRTUAL(x) ((CAVirtual *)(x))

#define ca_set_flag(ca, flag)   ( ca->flags |= flag )
#define ca_unset_flag(ca, flag) ( ca->flags &= ~flag )
#define ca_test_flag(ca, flag) (( ca->flags & flag ) ? 1 : 0)

/* -------------------------------------------------------------------- */

#define CA_CHECK_DATA_TYPE(data_type) \
  if ( data_type <= CA_NONE || data_type >= CA_NTYPE ) { \
    rb_raise(rb_eRuntimeError, "invalid data_type id %i", data_type);     \
  } \
  if ( ! ca_valid[data_type] ) { \
    rb_raise(rb_eRuntimeError, "data_type %s is disabled", ca_type_name[data_type]);    \
  }

#define CA_CHECK_DATA_TYPE_NUMERIC(data_type) \
  if ( data_type <= CA_NONE || data_type >= CA_NTYPE || !ca_valid[data_type] || data_type == CA_FIXLEN || data_type == CA_OBJECT ) { \
    rb_raise(rb_eRuntimeError, "invalid numeric data type"); \
  }

#define CA_CHECK_RANK(ndim) \
  if ( ndim <= 0 || ndim > CA_RANK_MAX ) { \
    rb_raise(rb_eRuntimeError, "invalid ndim"); \
  }

#define CA_CHECK_DIM(ndim, dim)     \
  { \
    int8_t i_; \
    for (i_=0; i_<ndim; i_++) { \
      if ( dim[i_] < 0 ) { \
        rb_raise(rb_eRuntimeError, "negative size dimension at %i-dim", i_);  \
      } \
    } \
  }

#define CA_CHECK_BYTES(data_type, bytes) \
  if ( data_type == CA_FIXLEN ) { \
    if ( bytes < 0 ) {                             \
      rb_raise(rb_eRuntimeError, "invalid bytes"); \
    } \
  } \
  else { \
    bytes = ca_sizeof[data_type]; \
    if ( bytes <= 0 ) {           \
      rb_raise(rb_eRuntimeError, "invalid bytes"); \
    } \
  } 

#define CA_CHECK_INDEX(index, dim) \
  if ( index < 0 ) {       \
    index += (dim);     \
  } \
  if ( index < 0 || index >= (dim) ) { \
    rb_raise(rb_eIndexError, "index out of range ( %lld <=> 0..%lld )", (ca_size_t) index, (ca_size_t) dim-1); \
  }

#define CA_CHECK_BOUND(ca, idx) \
  { \
    int8_t i; \
    for (i=0; i<ca->ndim; i++) { \
      if ( idx[i] < 0 || idx[i] >= ca->dim[i] )  { \
        rb_raise(rb_eRuntimeError, "index out of range at %i-dim ( %i <=> 0..%i )", i, idx[i], ca->dim[i]-1); \
      } \
    } \
  }

/* -------------------------------------------------------------------- */

/* class CComplex */

#ifdef HAVE_COMPLEX_H
   extern VALUE rb_cCComplex;
   double complex rb_num2cc(VALUE num);
   VALUE  rb_ccomplex_new (double complex c);
   VALUE  rb_ccomplex_new2 (double re, double im);
#  define NUM2CC rb_num2cc
#  define CC2NUM rb_ccomplex_new
#else
#  define rb_ccomplex_new(c) \
          (rb_raise(rb_eRuntimeError, "CComplex not defined"), Qnil)
#  define rb_ccomplex_new2(re,im) \
          (rb_raise(rb_eRuntimeError, "CComplex not defined"), Qnil)
#  define NUM2CC(n) \
          (rb_raise(rb_eRuntimeError, "CComplex not defined"), 0)
#  define CC2NUM(c) \
          (rb_raise(rb_eRuntimeError, "CComplex not defined"), Qnil)
#endif

VALUE     BOOL2OBJ (boolean8_t x);
boolean8_t OBJ2BOOL (VALUE v);

unsigned long rb_obj2ulong (VALUE);
long          rb_obj2long (VALUE);
#define   OBJ2LONG(x)  rb_obj2long((VALUE)x)
#define   OBJ2ULONG(x) rb_obj2ulong((VALUE)x)

long long          rb_obj2ll (VALUE);
unsigned long long rb_obj2ull (VALUE);
#define   OBJ2LL(x)  rb_obj2ll((VALUE)x)
#define   OBJ2ULL(x) rb_obj2ull((VALUE)x)

double    OBJ2DBL (VALUE v);

/* -------------------------------------------------------------------- */

/* index parsing */

enum {
  CA_REG_NONE,
  CA_REG_ALL,
  CA_REG_ADDRESS,
  CA_REG_FLATTEN,
  CA_REG_ADDRESS_COMPLEX,
  CA_REG_POINT,
  CA_REG_BLOCK,
  CA_REG_SELECT,
  CA_REG_ITERATOR,
  CA_REG_REPEAT,
  CA_REG_GRID,
  CA_REG_MAPPING,
  CA_REG_METHOD_CALL,
  CA_REG_UNBOUND_REPEAT,
  CA_REG_MEMBER,
  CA_REG_ATTRIBUTE,
}; /* CA_REGION_TYPE */

enum {
  CA_IDX_SCALAR,
  CA_IDX_ALL,
  CA_IDX_BLOCK,
  CA_IDX_SYMBOL,
  CA_IDX_REPEAT
}; /* CA_INDEX_TYPE */

typedef union {
  ca_size_t scalar;
  struct {
    ca_size_t start;
    ca_size_t step;
    ca_size_t count;
  } block;
  struct {
    ID id;
    VALUE spec;
  } symbol;
} CAIndex;

typedef struct {
  int16_t  type;
  int16_t  ndim;
  int32_t  index_type[CA_RANK_MAX];
  CAIndex  index[CA_RANK_MAX];
  CArray  *select;
  VALUE    block;
  VALUE    symbol;
  int8_t   range_check;
} CAIndexInfo;

/* -------------------------------------------------------------------- */

typedef void (*ca_monop_func_t)(ca_size_t n, boolean8_t *m, 
                                char *ptr1, ca_size_t i1, 
                                char *ptr2, ca_size_t i2);
typedef void (*ca_binop_func_t)(ca_size_t n, boolean8_t *m, 
                                char *ptr1, ca_size_t i1, 
                                char *ptr2, ca_size_t i2, 
                                char *ptr3, ca_size_t i3);
typedef void (*ca_moncmp_func_t)(ca_size_t n, boolean8_t *m, 
                                 char *ptr1, ca_size_t i1, 
                                 boolean8_t *ptr2, ca_size_t i2);
typedef void (*ca_bincmp_func_t)(ca_size_t n, boolean8_t *m, 
                                 char *ptr1, ca_size_t b1, ca_size_t i1, 
                                 char *ptr2, ca_size_t b2, ca_size_t i2, 
                                 char *ptr3, ca_size_t b3, ca_size_t i3);

VALUE rb_ca_call_monop (VALUE self, ca_monop_func_t func[]);
VALUE rb_ca_call_monop_bang (VALUE self, ca_monop_func_t func[]);
VALUE rb_ca_call_binop (VALUE self, VALUE other, ca_binop_func_t func[]);
VALUE rb_ca_call_binop_bang (VALUE self, VALUE other, ca_binop_func_t func[]);
VALUE rb_ca_call_moncmp (VALUE self, ca_moncmp_func_t func[]);
VALUE rb_ca_call_bincmp (VALUE self, VALUE other, ca_bincmp_func_t func[]);
void  ca_monop_not_implement(ca_size_t n, char *ptr1, char *ptr2) __attribute__((noreturn));
void  ca_binop_not_implement(ca_size_t n, char *ptr1, char *ptr2, char *ptr3) __attribute__((noreturn));
void  ca_moncmp_not_implement(ca_size_t n, char *ptr1, char *ptr2) __attribute__((noreturn));
void  ca_bincmp_not_implement(ca_size_t n, char *ptr1, char *ptr2, char *ptr3) __attribute__((noreturn));
VALUE ca_math_call (VALUE mod, VALUE arg, ID id);

/* -------------------------------------------------------------------- */

/* --- ca_obj_array.c --- */

int  carray_setup (CArray *ca,
                   int8_t data_type, int8_t ndim, ca_size_t *dim, 
                   ca_size_t bytes, CArray *mask);

int  carray_safe_setup (CArray *ca,
                   int8_t data_type, int8_t ndim, ca_size_t *dim, 
                   ca_size_t bytes, CArray *mask);

int  ca_wrap_setup_null (CArray *ca,
                   int8_t data_type, int8_t ndim, ca_size_t *dim, 
                   ca_size_t bytes, CArray *mask);

void free_carray (void *ap);
void free_ca_wrap (void *ap);

CArray  *carray_new (int8_t data_type,
                     int8_t ndim, ca_size_t *dim, ca_size_t bytes, CArray *ma);
CArray  *carray_new_safe (int8_t data_type,
                          int8_t ndim, ca_size_t *dim, ca_size_t bytes, CArray *mask);
VALUE    rb_carray_new (int8_t data_type,
                        int8_t ndim, ca_size_t *dim, ca_size_t bytes, CArray *mask);
VALUE    rb_carray_new_safe (int8_t data_type,
                             int8_t ndim, ca_size_t *dim, ca_size_t bytes, CArray *mask);

VALUE    rb_ca_wrap_new (int8_t data_type,
                         int8_t ndim, ca_size_t *dim, ca_size_t bytes, CArray *mask, char *ptr);

CAWrap  *ca_wrap_new (int8_t data_type,
                      int8_t ndim, ca_size_t *dim, ca_size_t bytes,
                      CArray *mask, char *ptr);

CAWrap  *ca_wrap_new_null (int8_t data_type,
                          int8_t ndim, ca_size_t *dim, ca_size_t bytes,
                          CArray *mask);

CScalar *cscalar_new (int8_t data_type, ca_size_t bytes, CArray *ma);
CScalar *cscalar_new2 (int8_t data_type, ca_size_t bytes, char *val);
VALUE    rb_cscalar_new (int8_t data_type, ca_size_t bytes, CArray *mask);
VALUE    rb_cscalar_new_with_value (int8_t data_type, ca_size_t bytes, VALUE rval);

/* --- ca_obj_refer.c --- */

CARefer *ca_refer_new (CArray *ca,
                       int8_t data_type, int8_t ndim, ca_size_t *dim,
                       ca_size_t bytes, ca_size_t offset);
VALUE    rb_ca_refer_new (VALUE self,
                       int8_t data_type, int8_t ndim, ca_size_t *dim,
                       ca_size_t bytes, ca_size_t offset);

/* --- ca_obj_farray.c --- */

VALUE    rb_ca_farray (VALUE self);

/* --- ca_obj_block.c --- */

CABlock *ca_block_new (CArray *carray,
                       int8_t ndim, ca_size_t *dim,
                       ca_size_t *start, ca_size_t *step, ca_size_t *count,
                       ca_size_t offset);
VALUE    rb_ca_block_new (VALUE cary, int8_t ndim, ca_size_t *dim,
                       ca_size_t *start, ca_size_t *step, ca_size_t *count,
                       ca_size_t offset);

/* --- ca_obj_select.c --- */

VALUE    rb_ca_select_new (VALUE cary, VALUE select);
VALUE    rb_ca_select_new_share (VALUE cary, VALUE select);

/* --- ca_obj_grid.c --- */

VALUE   rb_ca_grid_new (VALUE cary, ca_size_t *dim, CArray **grid);
VALUE   rb_ca_grid (int argc, VALUE *argv, VALUE self);

/* --- ca_obj_mapping.c --- */

VALUE   rb_ca_mapping_new (VALUE cary, CArray *mapper);
VALUE   rb_ca_mapping (int argc, VALUE *argv, VALUE self);

/* --- ca_obj_field.c --- */

VALUE   rb_ca_field_new (VALUE cary,
                        ca_size_t offset, int8_t data_type, ca_size_t bytes);
VALUE   rb_ca_field (int argc, VALUE *argv, VALUE self);

/* --- ca_obj_fake.c --- */

VALUE   rb_ca_fake_new (VALUE cary, int8_t data_type, ca_size_t bytes);
VALUE   rb_ca_fake_type (VALUE self, VALUE rtype, VALUE rbytes);

/* --- ca_obj_repeat.c --- */

CARepeat *ca_repeat_new (CArray *carray, int8_t ndim, ca_size_t *count);

VALUE   rb_ca_repeat_new (VALUE cary, int8_t ndim, ca_size_t *count);
VALUE   rb_ca_repeat (int argc, VALUE *argv, VALUE self);

/* --- ca_obj_unbound_repeat.c --- */

VALUE   rb_ca_ubrep_shave (VALUE self, VALUE other);
VALUE   rb_ca_ubrep_new (VALUE cary, int32_t rep_ndim, ca_size_t *rep_dim);
VALUE   ca_ubrep_bind_with (VALUE self, VALUE other);

/* --- ca_obj_reduce.c --- */

CAReduce *ca_reduce_new (CArray *carray, ca_size_t count, ca_size_t offset);

/* --- ca_iter_dimension --- */

VALUE   rb_dim_iter_new (VALUE vca, CAIndexInfo *info);

/* -------------------------------------------------------------------- */

/* API : defining new array */

void * malloc_with_check(size_t size);

int     ca_install_obj_type (VALUE klass, ca_operation_function_t func);
VALUE   ca_data_type_class (int8_t data_type);

void    ca_mark (void *ap);
void    ca_free (void *ap);
void    ca_free_nop (void *ap);

#define ca_length(ca) ((ca)->elements * (ca)->bytes)

/* API : query of array properties */

int     ca_is_scalar (void *ap);
#define ca_is_entity(ca) ( ca_func[(ca)->obj_type].entity_type == CA_REAL_ARRAY )
int     ca_is_virtual (void *ap);
int     ca_is_readonly (void *ap);
int     ca_is_value_array (void *ap);
int     ca_is_mask_array (void *ap);

#define ca_is_attached(ca) ( (ca)->ptr != NULL )
#define ca_is_empty(ca) ( (ca)->elements == 0 )

#define ca_is_caobject(ca) ( (ca)->obj_type == CA_OBJ_OBJECT )

int     ca_is_fixlen_type (void *ap);
int     ca_is_boolean_type (void *ap);
int     ca_is_numeric_type (void *ap);
int     ca_is_integer_type (void *ap);
int     ca_is_unsigned_type (void *ap);
int     ca_is_float_type (void *ap);
int     ca_is_complex_type (void *ap);
int     ca_is_object_type (void *ap);

/* API : check of array properties */

void    ca_check_type (void *ap, int8_t data_type);
#define ca_check_data_type(ap, data_type) ca_check_type(ap, data_type)
void    ca_check_ndim (void *ap, int ndim);
void    ca_check_shape (void *ap, int ndim, ca_size_t *dim);
void    ca_check_same_data_type (void *ap1, void *ap2);
void    ca_check_same_ndim (void *ap1, void *ap2);
void    ca_check_same_elements (void *ap1, void *ap2);
void    ca_check_same_shape (void *ap1, void *ap2);
void    ca_check_index (void *ap, ca_size_t *idx);
void    ca_check_data_class (VALUE rtype);
int     ca_is_valid_index (void *ap, ca_size_t *idx);

#define ca_ndim(ca) ((ca)->ndim)
#define ca_shape(ca) ((ca)->dim)

/* API : allocate, attach, update, sync, detach */

void    ca_allocate (void *ap);
void    ca_attach (void *ca);
void    ca_update (void *ca);
void    ca_sync (void *ca);
void    ca_detach (void *ca);

void    ca_allocate_n (int n, ...);
void    ca_attach_n (int n, ...);
void    ca_update_n (int n, ...);
void    ca_sync_n (int n, ...);
void    ca_detach_n (int n, ...);

/* API : copying */

void   *ca_clone (void *ap);          /* use rb_obj_clone() */
CArray *ca_copy (void *ap);           /* use rb_ca_copy() */
CArray *ca_template (void *ap);       /* use rb_ca_template() */
CArray *ca_template_safe (void *ap);  /* use rb_ca_template() */
CArray *ca_template_safe2 (void *ap, int8_t data_type, ca_size_t bytes);
                                      /* use rb_ca_template() */

void    ca_paste (void *ap, ca_size_t *idx, void *sp);
void    ca_cut (void *ap, ca_size_t *offset, void *sp);
void    ca_fill (void *ap, void *ptr);

/* API : fetch, store */

void    ca_addr2index (void *ap, ca_size_t addr, ca_size_t *idx);
ca_size_t ca_index2addr (void *ap, ca_size_t *idx);

void   *ca_ptr_at_index (void *ap, ca_size_t *idx);
void   *ca_ptr_at_addr (void *ap, ca_size_t addr);

void    ca_fetch_index (void *ap, ca_size_t *idx, void *ptr);
void    ca_fetch_addr (void *ap, ca_size_t addr, void *ptr);
void    ca_store_index (void *ap, ca_size_t *idx, void *ptr);
void    ca_store_addr (void *ap, ca_size_t addr, void *ptr);

void    ca_copy_data (void *ap, char *ptr);
void    ca_sync_data (void *ap, char *ptr);
void    ca_fill_data (void *ap, void *ptr);

/* API : mask handling */

extern VALUE CA_UNDEF;
extern VALUE CA_NIL;

boolean8_t *ca_mask_ptr (void *ap);
int     ca_has_mask (void *ap);
int     ca_is_any_masked (void *ap);
int     ca_is_all_masked (void *ap);
void    ca_update_mask (void *ap);
void    ca_create_mask (void *ap);
void    ca_clear_mask (void *ap);
void    ca_setup_mask (void *ap, CArray *mask);
void    ca_copy_mask (void *ap, void *ao);
void    ca_copy_mask_overlay_n (void *ap, ca_size_t elements, int n, CArray **slist);
void    ca_copy_mask_overlay (void *ap, ca_size_t elements, int n, ...);
void    ca_copy_mask_overwrite_n (void *ap, ca_size_t elements, int n, CArray **slist);
void    ca_copy_mask_overwrite (void *ap, ca_size_t elements, int n, ...);
ca_size_t ca_count_masked (void *ap);
ca_size_t ca_count_not_masked (void *ap);
void    ca_unmask (void *ap, char *fill_value);
CArray *ca_unmasked_copy (void *ap, char *fill_value);

/* API : cast, conversion */

typedef void (*ca_cast_func_t)(ca_size_t, CArray *, void *, CArray *, void *, boolean8_t *);
extern  ca_cast_func_t ca_cast_func_table[CA_NTYPE][CA_NTYPE];
void    ca_cast_block(ca_size_t n, void *a1, void *ptr1, void *a2, void *ptr2);
void    ca_cast_block_with_mask (ca_size_t n, void *ap1, void *ptr1,
                                 void *ap2, void *ptr2, boolean8_t *m);
void    ca_ptr2ptr   (void *ca1, void *ptr1, void *ca2, void *ptr2);
void    ca_ptr2val (void *ap1, void *ptr1, int8_t data_type2, void *ptr2);
void    ca_val2ptr (int8_t data_type1, void *ptr1, void *ap2, void *ptr2);
void    ca_val2val (int8_t data_type1, void *ptr1, int8_t data_type2, void *ptr2);
VALUE   ca_ptr2obj (void *ap, void *ptr);            /* use rb_ca_ptr2obj() */
void    ca_obj2ptr (void *ap, VALUE obj, void *ptr); /* use rb_ca_ptr2obj() */

void    ca_block_from_carray(CArray *cs,
                    ca_size_t *start, ca_size_t *step, ca_size_t *count, CArray *ca);

#define ca_wrap_writable(obj, data_type) \
  (obj = rb_ca_wrap_writable(obj, INT2NUM(data_type)), (CArray*) DATA_PTR(obj))
#define ca_wrap_readonly(obj, data_type) \
  (obj = rb_ca_wrap_readonly(obj, INT2NUM(data_type)), (CArray*) DATA_PTR(obj))

VALUE   rb_carray_wrap_ptr (int8_t data_type,
                            int8_t ndim, ca_size_t *dim, ca_size_t bytes,
                            CArray *mask, char *ptr, VALUE refer);

void * ca_to_cptr (void *ap);

/* API : utils */

boolean8_t *ca_allocate_mask_iterator (int n, ...);
boolean8_t *ca_allocate_mask_iterator_n (int n, CArray **slist);

ca_size_t ca_get_loop_count (int n, ...);
ca_size_t ca_set_iterator (int n, ...);

void    ca_swap_bytes (char *p, ca_size_t bytes, ca_size_t elements);
void    ca_parse_range (VALUE vrange, ca_size_t size,
                        ca_size_t *offset, ca_size_t *count, ca_size_t *step);
void    ca_parse_range_without_check (VALUE arg, ca_size_t size,
                        ca_size_t *offset, ca_size_t *count, ca_size_t *step);

int     ca_equal (void *ap, void *bp);
void    ca_zerodiv(void)  __attribute__((noreturn));
int32_t ca_rand (double rmax);
ca_size_t ca_bounds_normalize_index (int8_t bounds, ca_size_t size0, ca_size_t k);

/* API : high level */

/* parsing options */
VALUE   rb_pop_options (int *argc, VALUE **argv);
void    rb_scan_options (VALUE opt, const char *spec_in, ...);
void    rb_set_options (VALUE opt, const char *spec_in, ...);

/* predicates for check object is carray or cscalar */
#define rb_obj_is_carray(obj) rb_obj_is_kind_of(obj, rb_cCArray)
VALUE   rb_obj_is_cscalar (VALUE obj);
void    rb_check_carray_object (VALUE arg);

/* specific Data_Wrap_Struct for carray */
VALUE   ca_wrap_struct (void *ap);

/* query data_type */
int8_t  rb_ca_guess_type (VALUE obj);
void    rb_ca_guess_type_and_bytes (VALUE rtype, VALUE rbytes,
                                    int8_t *data_type, ca_size_t *bytes);
int     rb_ca_is_type (VALUE arg, int type);

/* scan index */ 
void    rb_ca_scan_index (int ca_ndim, ca_size_t *ca_dim, ca_size_t elements,
                          long argc, VALUE *argv, CAIndexInfo *info);


/* cast */
int     rb_ca_test_castable (VALUE other);
VALUE   rb_ca_binop_pass_to_other (VALUE self, VALUE other, ID method);
void    rb_ca_cast_self (volatile VALUE *self);
void    rb_ca_cast_self_or_other (volatile VALUE *self, volatile VALUE *other);
void    rb_ca_cast_other (VALUE *self, volatile VALUE *other);

VALUE   rb_ca_wrap_writable (VALUE obj, VALUE vtype);
VALUE   rb_ca_wrap_readonly (VALUE obj, VALUE vtype);

/* inheritance */
VALUE   rb_ca_data_type_inherit (VALUE self, VALUE other);
VALUE   rb_ca_data_type_import (VALUE self, VALUE data_type);
VALUE   rb_ca_set_parent (VALUE self, VALUE obj);
                             /* call once for a virtual carray */

/* freeze and decraration of modifing contents of carray */
VALUE   rb_ca_freeze (VALUE self);
void    rb_ca_modify (VALUE self);

/* attributes */
VALUE   rb_ca_obj_type (VALUE self);
VALUE   rb_ca_data_type (VALUE self);
VALUE   rb_ca_ndim (VALUE self);
VALUE   rb_ca_bytes (VALUE self);
VALUE   rb_ca_elements (VALUE self);
VALUE   rb_ca_dim (VALUE self);
VALUE   rb_ca_dim0 (VALUE self);
VALUE   rb_ca_dim1 (VALUE self);
VALUE   rb_ca_dim2 (VALUE self);
VALUE   rb_ca_dim3 (VALUE self);
VALUE   rb_ca_data_type_name (VALUE self);
VALUE   rb_ca_parent (VALUE self);

VALUE   rb_ca_is_fixlen_type (VALUE self);
VALUE   rb_ca_is_boolean_type (VALUE self);
VALUE   rb_ca_is_integer_type (VALUE self);
VALUE   rb_ca_is_unsigned_type (VALUE self);
VALUE   rb_ca_is_float_type (VALUE self);
VALUE   rb_ca_is_complex_type (VALUE self);
VALUE   rb_ca_is_object_type (VALUE self);

VALUE   rb_ca_is_entity (VALUE self);
VALUE   rb_ca_is_virtual (VALUE self);
VALUE   rb_ca_is_attached (VALUE self);
VALUE   rb_ca_is_empty (VALUE self);
VALUE   rb_ca_is_read_only (VALUE self);
VALUE   rb_ca_is_mask_array (VALUE self);
VALUE   rb_ca_is_value_array (VALUE self);

VALUE   rb_ca_is_scalar (VALUE self);

/* data class access (struct) */
VALUE   rb_obj_is_data_class (VALUE rtype);
VALUE   rb_ca_has_data_class (VALUE self);
VALUE   rb_ca_data_class (VALUE self);
VALUE   rb_ca_data_class_decode (VALUE self, VALUE str);
VALUE   rb_ca_data_class_encode (VALUE self, VALUE obj);
VALUE   rb_ca_members (VALUE self);
VALUE   rb_ca_field_as_member (VALUE self, VALUE sym);
VALUE   rb_ca_fields_at (int argc, VALUE *argv, VALUE self);
VALUE   rb_ca_fields (VALUE self);

/* mask */

VALUE   rb_ca_has_mask (VALUE self);
VALUE   rb_ca_is_any_masked (VALUE self);
VALUE   rb_ca_is_all_masked (VALUE self);
VALUE   rb_ca_value_array (VALUE self);
VALUE   rb_ca_mask_array (VALUE self);
VALUE   rb_ca_set_mask (VALUE self, VALUE val);
VALUE   rb_ca_is_masked (VALUE self);
VALUE   rb_ca_is_not_masked (VALUE self);
VALUE   rb_ca_count_masked (VALUE self);
VALUE   rb_ca_count_not_masked (VALUE self);
VALUE   rb_ca_unmask (VALUE self);
VALUE   rb_ca_mask_fill (VALUE self, VALUE fval);
VALUE   rb_ca_unmask_copy (VALUE self);
VALUE   rb_ca_mask_fill_copy (VALUE self, VALUE fval);
VALUE   rb_ca_inherit_mask_replace_n (VALUE self, int argc, VALUE *argv);
VALUE   rb_ca_inherit_mask_replace (VALUE self, int n, ...);
VALUE   rb_ca_inherit_mask_n (VALUE self, int argc, VALUE *argv);
VALUE   rb_ca_inherit_mask (VALUE self, int n, ...);

/* copy */

VALUE   rb_ca_copy (VALUE self);
VALUE   rb_ca_template (VALUE self);
VALUE   rb_ca_template_with_type (VALUE self, VALUE rtype, VALUE rbytes);
VALUE   rb_ca_template_n (int n, ...);

VALUE   rb_ca_fill (VALUE self, VALUE val);
VALUE   rb_ca_fill_copy (VALUE self, VALUE val);

/* address calculation */
VALUE   rb_ca_addr2index (VALUE self, VALUE raddr);

/* elemental access like ca[i,j,k] or ca[addr] */
VALUE   rb_ca_ptr2obj (VALUE self, void *ptr);
#define rb_ca_fetch_ptr(self, ptr) rb_ca_ptr2obj(self, ptr)
VALUE   rb_ca_fetch_index (VALUE self, ca_size_t *idx);
VALUE   rb_ca_fetch_addr (VALUE self, ca_size_t addr);
VALUE   rb_ca_fetch (VALUE self, VALUE index);
VALUE   rb_ca_fetch2 (VALUE self, int n, VALUE *vindex);

VALUE   rb_ca_obj2ptr (VALUE self, VALUE val, void *ptr);
#define rb_ca_store_ptr(self, ptr, val) rb_ca_obj2ptr(self, val, ptr)
VALUE   rb_ca_store_index (VALUE self, ca_size_t *idx, VALUE val);
VALUE   rb_ca_store_addr (VALUE self, ca_size_t addr, VALUE val);
VALUE   rb_ca_store (VALUE self, VALUE index, VALUE val);
VALUE   rb_ca_store2 (VALUE self, int n, VALUE *vindex, VALUE val);
VALUE   rb_ca_store_all (VALUE self, VALUE val);

/* elemental operations */
VALUE   rb_ca_elem_swap (VALUE self, VALUE vidx1, VALUE vidx2);
VALUE   rb_ca_elem_copy (VALUE self, VALUE vidx1, VALUE vidx2);
VALUE   rb_ca_elem_store (VALUE self, VALUE vidx, VALUE obj);
VALUE   rb_ca_elem_fetch (VALUE self, VALUE vidx);
VALUE   rb_ca_elem_incr (VALUE self, VALUE vidx1);
VALUE   rb_ca_elem_decr (VALUE self, VALUE vidx1);
VALUE   rb_ca_elem_test_masked (VALUE self, VALUE vidx1);

/* data type conversion */
VALUE   rb_ca_ptr2ptr (VALUE ra1, void *ptr1, VALUE ra2, void *ptr2);
#define rb_ca_cast_ptr (VALUE ra1, void *ptr1, VALUE ra2, void *ptr2);
VALUE   rb_ca_cast_block (ca_size_t n, VALUE ra1, void *ptr1,
                          VALUE ra2, void *ptr2);

VALUE   rb_ca_to_type (VALUE self, VALUE rtype, VALUE rbytes);
VALUE   rb_ca_to_boolean (VALUE self);
VALUE   rb_ca_to_int8 (VALUE self);
VALUE   rb_ca_to_uint8 (VALUE self);
VALUE   rb_ca_to_int16 (VALUE self);
VALUE   rb_ca_to_uint16 (VALUE self);
VALUE   rb_ca_to_int32 (VALUE self);
VALUE   rb_ca_to_uint32 (VALUE self);
VALUE   rb_ca_to_int64 (VALUE self);
VALUE   rb_ca_to_uint64 (VALUE self);
VALUE   rb_ca_to_float32 (VALUE self);
VALUE   rb_ca_to_float64 (VALUE self);
VALUE   rb_ca_to_float128 (VALUE self);
VALUE   rb_ca_to_cmplx64 (VALUE self);
VALUE   rb_ca_to_cmplx128 (VALUE self);
VALUE   rb_ca_to_cmplx256 (VALUE self);
VALUE   rb_ca_to_VALUE (VALUE self);
#define rb_ca_to_object(self) rb_ca_to_VALUE(self)

/* to ruby's array */
VALUE   rb_ca_to_a (VALUE self);

/* generation */
VALUE   rb_ca_seq_bang (VALUE self, VALUE offset, VALUE step);
VALUE   rb_ca_seq_bang2 (VALUE self, int n, VALUE *args);
VALUE   rb_ca_seq (VALUE self, VALUE offset, VALUE step);
VALUE   rb_ca_seq2 (VALUE self, int n, VALUE *args);
VALUE   rb_ca_where (VALUE self);

/* elemental byte swap */
VALUE   rb_ca_swap_bytes_bang (VALUE self);
VALUE   rb_ca_swap_bytes (VALUE self);

/* API : CAMath functions */
VALUE   ca_call_cfunc_1 (void (*func)(void *p0),
                         const char *fsync,
                        VALUE rcx0);

VALUE   ca_call_cfunc_2 (void (*func)(void*,void*), 
                         const char *fsync,
                         VALUE rcy, 
                         VALUE rcx1);

VALUE   ca_call_cfunc_3 (void (*func)(void*,void*,void*), 
                         const char *fsync,
                         VALUE rcy, 
                         VALUE rcx1, 
                         VALUE rcx2);

VALUE   ca_call_cfunc_4 (void (*func)(void*,void*,void*,void*), 
                         const char *fsync,
                         VALUE rcy, 
                         VALUE rcx1, 
                         VALUE rcx2, 
                         VALUE rcx3);
                         
VALUE   ca_call_cfunc_5 (void (*func)(void*,void*,void*,void*,void*), 
                         const char *fsync,
                         VALUE rcy, 
                         VALUE rcx1, 
                         VALUE rcx2, 
                         VALUE rcx3, 
                         VALUE rcx4);
                         
VALUE   ca_call_cfunc_6 (void (*func)(void*,void*,void*,void*,void*,void*), 
                         const char *fsync,
                         VALUE rcy, 
                         VALUE rcx1, 
                         VALUE rcx2, 
                         VALUE rcx3, 
                         VALUE rcx4, 
                         VALUE rcx5);
                         
VALUE   ca_call_cfunc_7 (void (*func)(void*,void*,void*,void*,void*,void*,void*), 
                         const char *fsync,
                         VALUE rcy, 
                         VALUE rcx1, 
                         VALUE rcx2, 
                         VALUE rcx3, 
                         VALUE rcx4, 
                         VALUE rcx5, 
                         VALUE rcx6);

VALUE   ca_call_cfunc_1_1 (int8_t dty, 
                           int8_t dtx, 
                           void (*mathfunc)(void*,void*), VALUE rx);

VALUE   ca_call_cfunc_1_2 (int8_t dty, 
                           int8_t dtx1, 
                           int8_t dtx2, 
                           void (*mathfunc)(void*,void*,void*), 
                           volatile VALUE rx1, volatile VALUE rx2);

VALUE   ca_call_cfunc_1_3 (int8_t dty, 
                           int8_t dtx1, 
                           int8_t dtx2, 
                           int8_t dtx3, 
                           void (*mathfunc)(void*,void*,void*,void*), 
                           volatile VALUE rx1, 
                           volatile VALUE rx2, 
                           volatile VALUE rx3);

VALUE   ca_call_cfunc_1_4 (int8_t dty, 
                           int8_t dtx1, 
                           int8_t dtx2, 
                           int8_t dtx3, 
                           int8_t dtx4, 
                           void (*mathfunc)(void*,void*,void*,void*,void*), 
                           volatile VALUE rx1, 
                           volatile VALUE rx2, 
                           volatile VALUE rx3,
                           volatile VALUE rx4); 

VALUE   ca_call_cfunc_1_5 (int8_t dty, 
                           int8_t dtx1, 
                           int8_t dtx2, 
                           int8_t dtx3, 
                           int8_t dtx4, 
                           int8_t dtx5, 
                           void (*mathfunc)(void*,void*,void*,void*,void*,void*), 
                           volatile VALUE rx1, 
                           volatile VALUE rx2, 
                           volatile VALUE rx3,
                           volatile VALUE rx4,
                           volatile VALUE rx5);

VALUE   ca_call_cfunc_1_6 (int8_t dty, 
                           int8_t dtx1, 
                           int8_t dtx2, 
                           int8_t dtx3, 
                           int8_t dtx4, 
                           int8_t dtx5, 
                           int8_t dtx6, 
                           void (*mathfunc)(void*,void*,void*,void*,void*,void*,void*), 
                           volatile VALUE rx1, 
                           volatile VALUE rx2, 
                           volatile VALUE rx3,
                           volatile VALUE rx4,
                           volatile VALUE rx5,
                           volatile VALUE rx6);

VALUE   ca_call_cfunc_2_1 (int8_t dty1, 
                          int8_t dty2, 
                          int8_t dtx1, 
                          void (*mathfunc)(void*,void*,void*), 
                          volatile VALUE rx1);

VALUE   ca_call_cfunc_2_2 (int8_t dty1, 
                           int8_t dty2, 
                           int8_t dtx1, 
                           int8_t dtx2, 
                           void (*mathfunc)(void*,void*,void*,void*), 
                           volatile VALUE rx1, 
                           volatile VALUE rx2);

VALUE   ca_call_cfunc_2_3 (int8_t dty1, 
                           int8_t dty2, 
                           int8_t dtx1, 
                           int8_t dtx2, 
                           int8_t dtx3, 
                           void (*mathfunc)(void*,void*,void*,void*,void*), 
                           volatile VALUE rx1, 
                           volatile VALUE rx2, 
                           volatile VALUE rx3);

VALUE   ca_call_cfunc_2_4 (int8_t dty1, 
                           int8_t dty2, 
                           int8_t dtx1, 
                           int8_t dtx2, 
                           int8_t dtx3, 
                           int8_t dtx4, 
                           void (*mathfunc)(void*,void*,void*,void*,void*,void*), 
                           volatile VALUE rx1, 
                           volatile VALUE rx2, 
                           volatile VALUE rx3,
                           volatile VALUE rx4) ;

VALUE   ca_call_cfunc_3_1 (int8_t dty1, 
                           int8_t dty2, 
                           int8_t dty3, 
                           int8_t dtx1, 
                           void (*mathfunc)(void*,void*,void*,void*), 
                           volatile VALUE rx1);

VALUE   ca_call_cfunc_3_2 (int8_t dty1, 
                           int8_t dty2, 
                           int8_t dty3, 
                           int8_t dtx1, 
                           int8_t dtx2, 
                           void (*mathfunc)(void*,void*,void*,void*,void*), 
                           volatile VALUE rx1, 
                           volatile VALUE rx2);

VALUE   ca_call_cfunc_3_3 (int8_t dty1, 
                           int8_t dty2, 
                           int8_t dty3, 
                           int8_t dtx1, 
                           int8_t dtx2, 
                           int8_t dtx3, 
                           void (*mathfunc)(void*,void*,void*,void*,void*,void*), 
                           volatile VALUE rx1, 
                           volatile VALUE rx2,                       
                           volatile VALUE rx3);

/* -------------------------------------------------------------------- */

void ca_debug ();

/* -------------------------------------------------------------------- */

#endif
