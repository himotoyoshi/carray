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
#  if HAVE_LONG_LONG && SIZEOF_LONG_LONG == 8
#    define HAVE_TYPE_INT64_T 1
     typedef long long int64_t;
#  else
     typedef dummy_t   int64_t;
#  endif
#endif

#ifndef HAVE_TYPE_UINT64_T
#  if HAVE_LONG_LONG && SIZEOF_LONG_LONG == 8
#    define HAVE_TYPE_UINT64_T 1
     typedef unsigned long long uint64_t;
#  else
     typedef dummy_t   uint64_t;
#  endif
#endif

#if HAVE_TYPE_FLOAT && SIZEOF_FLOAT == 4
#  define HAVE_TYPE_FLOAT32_T 1
   typedef float float32_t;
#else
   typedef dummy_t float32_t;
#endif

#if HAVE_TYPE_DOUBLE && SIZEOF_DOUBLE == 8
#  define HAVE_TYPE_FLOAT64_T 1
   typedef double float64_t;
#else
   typedef dummy_t float64_t;
#endif

/* float128_t / cmplx256_t were retired in carray-3.0 (DROP_LONGDOUBLE).
   The enum slots CA_FLOAT128 (=12) and CA_CMPLX256 (=15) are preserved
   as reserved holes so existing CA_NTYPE-sized tables keep their layout;
   ca_valid[12] and ca_valid[15] are 0, so no user can create a CArray of
   these types. */

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

#include <stddef.h>
#include <inttypes.h>   /* PRId64 for ca_size_t (= int64_t) formatting */

#define CA_ALIGN_VOIDP    offsetof(struct { char c; void   *x; }, x)
#define CA_ALIGN_INT8     offsetof(struct { char c; int8_t  x; }, x)
#define CA_ALIGN_INT16    offsetof(struct { char c; int16_t x; }, x)
#define CA_ALIGN_INT32    offsetof(struct { char c; int32_t x; }, x)
#define CA_ALIGN_INT64    offsetof(struct { char c; int64_t x; }, x)
#define CA_ALIGN_FLOAT32  offsetof(struct { char c; float32_t  x; }, x)
#define CA_ALIGN_FLOAT64  offsetof(struct { char c; float64_t  x; }, x)
#define CA_ALIGN_CMPLX64  offsetof(struct { char c; cmplx64_t  x; }, x)
#define CA_ALIGN_CMPLX128 offsetof(struct { char c; cmplx128_t x; }, x)
#define CA_ALIGN_OBJECT   offsetof(struct { char c; VALUE      x; }, x)

/* -------------------------------------------------------------------- */

#define CA_OBJ_TYPE_MAX  256
#define CA_DIM_MAX       16
#define CA_RANK_MAX      CA_DIM_MAX
#define CA_ATTACH_MAX    0x80000000

/* Assert an invariant to the optimizer (zero runtime cost).  Used to teach
   GCC's value-range propagation facts it cannot derive itself -- chiefly
   `ndim <= CA_RANK_MAX`, which bounds loops and allocations over fixed
   [CA_RANK_MAX] stack arrays.  Without this, GCC (11.x) emits false-positive
   -Wstringop-overflow / -Wmaybe-uninitialized / -Walloc-size-larger-than on
   those loops because `int8_t ndim` ranges up to 127 as far as it can see.
   The asserted conditions are hard invariants (CA_CHECK_RANK enforces them at
   array creation); a violation is genuinely unreachable. */
#if defined(__GNUC__) || defined(__clang__)
# define CA_ASSUME(cond)  do { if ( !(cond) ) __builtin_unreachable(); } while (0)
#else
# define CA_ASSUME(cond)  ((void)0)
#endif

#define CA_FLAG_SCALAR           1
#define CA_FLAG_MASK_ARRAY       2
#define CA_FLAG_VALUE_ARRAY      4
#define CA_FLAG_READ_ONLY        8
#define CA_FLAG_SHARE_INDEX     16
/* bit 32 (formerly CA_FLAG_NOT_DATA_CLASS, removed in 3.0) reused for the
   multi-parent view category (CAStack and any future fan-out view).  Generic
   routines that walk a single ->parent test this flag and instead fold over
   the parents[] exposed by the CAMultiParent layout convention. */
#define CA_FLAG_MULTI_PARENTS   32
#define CA_FLAG_CYCLE_CHECK     64
#define CA_FLAG_IS_FACE        128
/* Face opt-in ordering/search flags (PROPOSAL_FACE_ORDERING_GATE §Future work).
   A Face declares that its numeric storage may be descended to for kernel
   dispatch.  The two flags are on independent axes -- do not conflate:
     ORDERABLE_STORAGE: storage native order == surface <=> order (self-scope).
       Unlocks sort / sort_addr / sort_index / partition / rank.  A unit-bearing
       Face (CATime) is orderable because all elements share the array's
       unit metadata, so storage-direct comparison within self is always right.
     COMPARABLE_STORAGE: an external query may be compared against storage with
       no conversion (cross-scope).  Unlocks search / bsearch / find_value_index.
       CATime is ORDERABLE but NOT COMPARABLE: a :s array vs a :ns query
       would silent-wrong under raw int64 compare.
   The gates that read these flags key on CA_FLAG_IS_FACE alone and never look
   at the surface data_type, so a Face whose surface data_type equals its
   numeric storage (a Numeric Face, e.g. CATimedelta) needs them just as much
   as a CA_FIXLEN-surface one: without ORDERABLE it is refused at sort /
   search / count / value-hash entries.  Whether COMPARABLE holds is likewise
   not a question of being numeric but of carrying a unit -- CATimedelta is
   int64 on both sides and still sets ORDERABLE only. */
/* CALazyMarker.  A marker layers "read this as the leaf of a lazy chain"
   over storage that is identical to its parent's — the same premise as
   CA_FLAG_IS_FACE — so the two are asked about together wherever a
   storage-identical wrapper has to be seen through.  Kept as its own bit
   rather than folded into CA_FLAG_IS_FACE: ca_is_face is read in ~100
   places that mean the Face mechanism specifically. */
#define CA_FLAG_IS_LAZY_MARKER 1024

#define CA_FLAG_FACE_ORDERABLE_STORAGE  256
#define CA_FLAG_FACE_COMPARABLE_STORAGE 512
/* NOTE: `flags` is int32_t, so there is plenty of bit space left. */

enum {
  CA_LITTLE_ENDIAN = 0,
  CA_BIG_ENDIAN = 1
};

enum {
  CA_REAL_ARRAY,
  CA_VIEW_ARRAY
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
/* Per-axis descriptor framework (D1+D2+D3): types, producer interface,
   and common attach engine.  Lives in its own header so the carray.h
   preamble stays focused on basic types + struct definitions. */
#include "ca_axis_descriptor.h"

/* xfer protocol direction flags (PROPOSAL_XFER_PROTOCOL.md §3) */
#define CA_XFER_GET 0   /* target -> data (gather) */
#define CA_XFER_PUT 1   /* data -> target (scatter) */

/* compose-fold state threaded through ca_stride_compose_to_root
   (PROPOSAL_XFER_PROTOCOL.md §5.5).  strides / base / counts are expressed
   in the *current parent*'s byte space; ndim is invariant through the walk.
   counts[] is the leaf's per-dim extent (== leaf->dim), used by
   ca_stride_compose_through's bounds check and by sometimes-fold
   participants for their per-request fold decision. */
typedef struct {
  int8_t    ndim;
  ca_size_t base;
  ca_size_t strides[CA_RANK_MAX];
  ca_size_t counts[CA_RANK_MAX];
} ca_fold_t;

typedef struct {
  int32_t obj_type;
  int32_t entity_type;
  void   (*free_object)  (void *ap);
  void * (*clone)        (void *ap);
  void   (*allocate)     (void *ap);
  void   (*attach)       (void *ap);
  void   (*sync)         (void *ap);
  void   (*detach)       (void *ap);
  void   (*fill_data)    (void *ap, void *data);
  void   (*create_mask)  (void *ap);
  /* xfer protocol (PROPOSAL_XFER_PROTOCOL.md). Added at struct end so existing
     positional initializers leave it NULL automatically.  dir = CA_XFER_GET /
     CA_XFER_PUT. */
  void   (*xfer_index)   (void *ap, ca_size_t *idx, void *data, int dir);
  void   (*xfer_addrs)   (void *ap, ca_size_t n, ca_size_t *addrs,
                          void *data, int dir);
  /* fold_stride (PROPOSAL_XFER_PROTOCOL.md §5.2/§5.5): one compose-fold hop
     for sometimes-fold participants (CAWindow now; CAGrid/CSA/CATile later).
     Compose *f into next_parent's byte space and return 1, or decline
     (leave *f / *next_parent untouched) and return 0 -> this view is the
     fold boundary.  CAStride family leaves this NULL (handled open-inline
     by ca_stride_compose_to_root). */
  int    (*fold_stride)  (void *ap, ca_fold_t *f, void **next_parent);
  /* xfer_stride (PROPOSAL_XFER_PROTOCOL.md §3/§4.4): deliver a region of
     counts[k] cells per axis to/from a caller buffer.  Local materialise of
     the requested region only (never the whole view).

     All three of starts/counts/strides describe the region in *this view's*
     own address space: the first cell is at Sigma starts[k]*native[k] (native =
     this view's row-major byte layout) and successive cells along axis k sit
     strides[k] bytes apart, so strides[k] / native[k] is the index step and
     the region need not be contiguous.  `data` is the caller buffer, holding
     the Pi counts[k] selected cells packed row-major -- it is NOT laid out
     with strides[].  dir = CA_XFER_GET / CA_XFER_PUT. */
  void   (*xfer_stride)  (void *ap, ca_size_t *starts, ca_size_t *counts,
                          ca_size_t *strides, void *data, int dir);
  /* xfer_all (PROPOSAL_XFER_PROTOCOL.md §6 / §7 step 4): whole-view transfer,
     direction-unified replacement of copy_data / sync_data.  Holds the view's
     optimal whole-domain delivery (compose-fold, partial materialise, etc.);
     copy_data / sync_data become thin forwarders (removed in step 5).
     dir = CA_XFER_GET (gather: view -> data) / CA_XFER_PUT (scatter). */
  void   (*xfer_all)     (void *ap, void *data, int dir);
  /* Pool framework (PROPOSAL_CARRAY_POOL_STANDARDIZATION.md).  Optional;
     unfilled slots leave the obj_type on the legacy ALLOC_N path.  When
     populated, framework primitives in ca_array_pool.c manage a single
     contiguous `_pool` buffer that holds dim/strides/<subclass tail>. */
  size_t struct_size;                              /* sizeof(<concrete struct>) */
  size_t (*pool_bytes)   (int8_t ndim);            /* required if struct_size != 0 */
  void   (*pool_init)    (void *ap, int8_t ndim);  /* required if struct_size != 0 */
  /* fill_addrs / fill_stride (PROPOSAL_PARTIAL_FILL_WHOLE_ROOT_WRITEBACK.md
     section 6.3): write one value into part of the view.  fill_data carries no
     region and so can only say "fill everything I cover"; without a region the
     only way left to fill part of a view was to borrow a pointer, which
     materialises a non-foldable root and writes it all back.  `ptr` is a
     single element's worth of bytes, as for fill_data, since the value does
     not scale with the region.

     fill_stride describes the region over the view's own *linear addresses*:
     `base` is where it starts and steps[k] is the address step along axis k,
     counts[k] axes deep.  Addresses rather than an index box because a view
     hands its region to its parent, and the two need not agree on ndim -- a
     dimension-dropping view has no box in its parent's index space.  This is
     the shape ca_xfer_stride composes to internally before it walks.

     Leave NULL to take the per-cell default in ca_fill_addrs / ca_fill_stride. */
  void   (*fill_addrs)   (void *ap, ca_size_t n, ca_size_t *addrs, void *ptr);
  void   (*fill_stride)  (void *ap, ca_size_t base, int8_t ndim,
                          ca_size_t *counts, ca_size_t *steps, void *ptr);
} ca_operation_function_t;

/* default operation_function */

void * ca_array_func_clone        (void *ap);
void   ca_array_func_allocate     (void *ap);
void   ca_array_func_attach       (void *ap);
void   ca_array_func_sync         (void *ap);
void   ca_array_func_detach       (void *ap);
void   ca_array_func_xfer_index   (void *ap, ca_size_t *idx, void *data, int dir);
void   ca_array_func_xfer_addrs   (void *ap, ca_size_t n, ca_size_t *addrs,
                                   void *data, int dir);
void   ca_array_func_xfer_all     (void *ap, void *data, int dir);
void   ca_array_func_fill_data    (void *ap, void *val);
void   ca_array_func_create_mask  (void *ap);

/* Pool framework primitives (PROPOSAL_CARRAY_POOL_STANDARDIZATION.md).
   - ca_array_alloc:       xmalloc(struct_size) + ca_array_pool_alloc().
                           For the C construction path (= replaces
                           TypedData_Make_Struct + per-field ALLOC_N).
   - ca_array_pool_alloc:  xmalloc(pool_bytes(ndim)) into ca->_pool, then
                           run pool_init.  For the initialize_copy path
                           where TypedData_Make_Struct has already
                           allocated the struct.  Both fields must be
                           registered in ca_func[obj_type].
   - ca_array_free:        xfree(ca->_pool) and xfree(ca).  Per-class
                           free_object callbacks call this branch when
                           ca->_pool != NULL; otherwise they fall through
                           to the legacy ALLOC_N free path. */
void * ca_array_alloc       (int8_t obj_type, int8_t ndim);
void   ca_array_pool_alloc  (void *ap, int8_t obj_type, int8_t ndim);
void   ca_array_free        (void *ap);

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
  char     *_pool;         /* framework-managed pool buffer (NULL = legacy ALLOC_N path).
                              Reserved for framework use; ext authors must not read,
                              write, or xfree this field directly.  See
                              ext/ca_array_pool.c. */
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
  char     *_pool;         /* framework-managed pool buffer (NULL = legacy ALLOC_N path).
                              Reserved for framework use; ext authors must not read,
                              write, or xfree this field directly.  See
                              ext/ca_array_pool.c. */
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
  char     *_pool;         /* framework-managed pool buffer (NULL = legacy ALLOC_N path).
                              Reserved for framework use; ext authors must not read,
                              write, or xfree this field directly.  See
                              ext/ca_array_pool.c. */
  CArray   *parent;
  uint32_t  attach;
  uint8_t   nosync;
} CAView;               /* 40 + 4*(ndim) (bytes) */

/* CARefer (Phase C): CAStride prefix + a `mask0` tail.
   - reshape (mode 0/1) and byte-reinterpret (modes ±2) are all
     expressed as a contiguous byte-aligned strided view; differences
     between modes collapse to (strides, base_offset).  The previous
     `is_deformed` flag is no longer stored -- it's implied by the
     comparison `ca->bytes vs ca->parent->bytes`.
   - `mask0` owns the CARepeat (divided) or CAReduce (spanned)
     intermediate that the user-visible mask is a refer-of, for the
     byte-reinterpret modes.  NULL for simple reshape and for
     parent-without-mask cases. */
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
  char     *_pool;         /* framework-managed pool buffer (NULL = legacy ALLOC_N path).
                              Reserved for framework use; ext authors must not read,
                              write, or xfree this field directly.  See
                              ext/ca_array_pool.c. */
  CArray   *parent;
  uint32_t  attach;
  uint8_t   nosync;
  /* --- CAStride prefix continues --- */
  ca_size_t  *strides;
  ca_size_t   base_offset;
  /* --- CARefer tail --- */
  CArray   *mask0;
} CARefer;

/* CABlock (Phase E): CAStride prefix + native-spec tail.
   The tail (offset, start, step, count, size0) is preserved for:
     - public Ruby accessors (#offset, #start, #step, #count, #size0)
     - #idx2addr0 / #addr2addr0 implementations
     - block / dimension iterators that mutate start[] in place
   After every mutation of `start[]`, base_offset must be
   recomputed to stay consistent with the CAStride prefix.

   The old maxdim_* gather-loop optimization fields are gone:
   CAStride's own gather/scatter (P1/P1.5/P2/P3) does the same job. */
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
  char     *_pool;         /* framework-managed pool buffer (NULL = legacy ALLOC_N path).
                              Reserved for framework use; ext authors must not read,
                              write, or xfree this field directly.  See
                              ext/ca_array_pool.c. */
  CArray   *parent;
  uint32_t  attach;
  uint8_t   nosync;
  /* --- CAStride prefix continues --- */
  ca_size_t  *strides;
  ca_size_t   base_offset;
  /* --- CABlock tail (native spec) --- */
  ca_size_t   offset;
  ca_size_t  *start;
  ca_size_t  *step;
  ca_size_t  *count;
  ca_size_t  *size0;
} CABlock;

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
  char     *_pool;         /* framework-managed pool buffer (NULL = legacy ALLOC_N path).
                              Reserved for framework use; ext authors must not read,
                              write, or xfree this field directly.  See
                              ext/ca_array_pool.c. */
  CArray   *parent;
  uint32_t  attach;
  uint8_t   nosync;
  /* ---------- */
  ca_size_t  *strides;     /* byte strides, negative allowed */
  ca_size_t   base_offset; /* byte offset from parent->ptr to view[0,...] */
} CAStride;              /* CA_OBJ_STRIDE: generic strided view  */

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
  char     *_pool;         /* framework-managed pool buffer (NULL = legacy ALLOC_N path).
                              Reserved for framework use; ext authors must not read,
                              write, or xfree this field directly.  See
                              ext/ca_array_pool.c. */
  CArray   *parent;
  uint32_t  attach;
  uint8_t   nosync;
  /* ---------- */
  uint8_t   *bounds;       /* [ndim] per-axis policy (PROPOSAL_CAWINDOW_UNIFICATION
                              Tier 2.G; scalar uint8_t before).  Allows
                              CAShift (per-axis roll[]) to be expressed as
                              a CAWindow specialisation. */
  ca_size_t  *start;
  ca_size_t  *count;
  ca_size_t  *size0;
  char     *fill;
  /* COMPOSITE_FAMILY Phase 1 (E.2): embed descriptor model.  Computed by
     ca_compute_embed_descriptor at setup time, immutable for view lifetime.
     Used by attach/sync (E.3-E.4) to skip per-element bound checks via
     "1 alias + 1 fill" decomposition.  Dormant in E.2 (no readers yet).
     See devel/PROPOSAL_COMPOSITE_FAMILY.md §4.1. */
  ca_size_t  *embed_parent_start;   /* [ndim] parent-side alias rectangle start */
  ca_size_t  *embed_count;          /* [ndim] alias rectangle size per axis */
  ca_size_t  *embed_output_offset;  /* [ndim] output-side alias rectangle start */
  uint8_t     embed_is_empty;       /* 1 = fully out of parent, alias is empty */
  uint8_t     embed_covers_all;     /* 1 = interior-only, fill is unused */
  uint8_t     embed_eligible;       /* 1 = all bounds in {FILL, MASK}, attach
                                       takes the embed fast path (E.3).  Other
                                       policies (PERIODIC/REFLECT/...) fall
                                       back to the ca_axis_dispatch_* engine. */
  uint8_t     embed_alias_eligible; /* 1 = direct ca_attach(window) can alias
                                       to parent->ptr without copy (Phase 1.5
                                       E.8 A-path).  Condition: embed_eligible
                                       + embed_covers_all + inner axes full
                                       (count[k] == parent->dim[k] && start[k]
                                       == 0 for k >= 1).  Embedded region
                                       must be contig in parent storage. */
} CAWindow;                /* 56 + 16*(ndim) + 1*(bytes) + 1*ndim + 24*ndim (bytes) */

/* Tier 2.G.2 (PROPOSAL_CAWINDOW_UNIFICATION): CAShift is a pure typedef
   of CAWindow.  CAShift construction maps (shift[], roll[], fill,
   fill_mask) onto CAWindow's (start = -shift, count = parent->dim,
   bounds = roll ? PERIODIC : (fill_mask ? MASK : FILL), fill).  The
   two views share the operation table (ca_window_func); only obj_type
   differs (CA_OBJ_SHIFT vs CA_OBJ_WINDOW) to preserve user-facing class
   distinction.  See devel/PROPOSAL_CAWINDOW_UNIFICATION.md. */
typedef CAWindow CAShift;

/* COMPOSITE_FAMILY Phase 2 (T.3, 2026-05-26): CATile = N-region
   expansion view (tiled repetition of the parent).  Output shape =
   parent.dim * reps per axis; total tiles = product(reps).  Each tile
   is a full-parent alias at output offset
   (i_0 * parent.dim[0], i_1 * parent.dim[1], ...). Attach iterates
   total_tiles regions, calling ca_composite_region_gather for each.
   See devel/PROPOSAL_CATILE.md §1.2 / §1.3.

   CARoll = typedef CATile (same pattern as the Phase G
   CAShift = CAWindow precedent); constructor parameters differ but the
   C struct layout is shared, and the attach/sync routine is identical
   (= dispatch the region list in order). */
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
  char     *_pool;         /* framework-managed pool buffer (NULL = legacy ALLOC_N path).
                              Reserved for framework use; ext authors must not read,
                              write, or xfree this field directly.  See
                              ext/ca_array_pool.c. */
  CArray   *parent;
  uint32_t  attach;
  uint8_t   nosync;
  /* ---------- */
  ca_size_t  *reps;        /* [ndim] number of tiles per axis.
                              Total tiles = product(reps).
                              dim[k] = parent->dim[k] * reps[k]. */
} CATile;                /* 56 + 8*(ndim) (bytes) */

typedef CATile CARoll;   /* T.4 will land CARoll-specific constructor +
                            obj_type CA_OBJ_ROLL.  Until then CARoll path
                            is just CATile (= typedef body identical). */

/* CAStack (COMPOSITE_FAMILY Phase 3, PROPOSAL_CASTACK.md): outer-axis-only
   stack view of K uniform-shape parents.  shape = (K, *parent_shape),
   axis 0 maps to parent index, axes 1..ndim-1 are per-parent contig.
   See devel/MEMO_CASTACK_DESIGN.md for design rationale.
   - parents stored as Ruby Array @parents on the wrapper object (= GC
     anchor); C-side tail `parents[]` is alias pointer array.
   - CAView.parent points to parents[0] (= legacy compat for paths that
     deref ca->parent without CAStack awareness).
   - dim[0] = n_parents; dim[1..ndim-1] = parents[0]->dim[0..ndim-2]. */
typedef struct {
  int16_t   obj_type;
  int8_t    data_type;
  int8_t    ndim;          /* = parents[0]->ndim + 1 */
  int32_t   flags;
  ca_size_t bytes;
  ca_size_t elements;      /* = n_parents * parents[0]->elements */
  ca_size_t *dim;          /* ALLOC_N(ndim) = [n_parents, *parent->dim] */
  char     *ptr;
  CArray   *mask;
  char     *_pool;         /* framework-managed pool buffer (NULL = legacy ALLOC_N path).
                              Reserved for framework use; ext authors must not read,
                              write, or xfree this field directly.  See
                              ext/ca_array_pool.c. */
  CArray   *parent;        /* = parents[0] (legacy CAView field) */
  uint32_t  attach;
  uint8_t   nosync;
  /* ---- CAStack tail ---- */
  int32_t   n_parents;     /* K = axis-0 size */
  CArray  **parents;       /* ALLOC_N(CArray*, n_parents); aliases, not owned */
  int8_t    k_axis;        /* K axis insertion position in view shape, [0, parent_ndim].
                              0 = outer-axis stack (legacy default).
                              parent_ndim = K innermost (= old merge at=-1).
                              Set by ca_stack_setup_with_axis / preserved on clone. */
} CAStack;

/* CAMeld (ragged concatenate view along an existing axis).  Unlike CAStack
   which introduces a new K axis, CAMeld welds K parents along one of their
   existing axes and may have uneven segment lengths there.
     shape[a]         = parents[0]->dim[a]      for a != meld_axis
     shape[meld_axis] = sum_k parents[k]->dim[meld_axis]
   All other axes must match across parents (uniform check at constructor).

   v0.1 stub: external-axis (meld_axis == 0) structural xfer_stride path only.
   Other paths raise NotImplementedError until fleshed out per staging plan
   in devel/MEMO_CAMELD_SEGMENT_MAJOR_ENGINE.md §4. */
typedef struct {
  int16_t   obj_type;
  int8_t    data_type;
  int8_t    ndim;          /* = parents[0]->ndim (no new axis) */
  int32_t   flags;
  ca_size_t bytes;
  ca_size_t elements;      /* = sum_k parents[k]->elements */
  ca_size_t *dim;          /* ALLOC_N(ndim); dim[meld_axis]=seg_offset[K], else parents[0]->dim */
  char     *ptr;
  CArray   *mask;
  char     *_pool;         /* framework-managed pool buffer; do not touch */
  CArray   *parent;        /* = parents[0] (legacy CAView field) */
  uint32_t  attach;
  uint8_t   nosync;
  /* ---- CAMeld tail (n_parents / parents kept adjacent to header for
         CAMultiParent layout convention) ---- */
  int32_t   n_parents;     /* K = number of segments */
  CArray  **parents;       /* ALLOC_N(CArray*, K); aliases, not owned */
  int8_t    meld_axis;     /* existing axis being welded, [0, parent_ndim) */
  ca_size_t *seg_offset;   /* ALLOC_N(ca_size_t, K+1); prefix sum along meld_axis.
                              seg_offset[0]=0, seg_offset[k+1]=seg_offset[k]+parents[k]->dim[meld_axis],
                              seg_offset[K]=dim[meld_axis]. */
} CAMeld;

/* Multi-parent view layout convention (CA_FLAG_MULTI_PARENTS).  A view that
   fans out to K parents must place `n_parents` + `parents[]` immediately after
   the CAView header (exactly as CAStack does) so generic routines that would
   otherwise walk a single ->parent can fold over all parents without knowing
   the concrete view type.  Cast `(CAMultiParent *) ca` only when the flag is
   set.  CAStack is the first conforming type (layout-checked in
   Init_ca_obj_stack via offsetof). */
typedef struct {
  CAView    header;        /* common view prefix (obj_type .. nosync) */
  int32_t   n_parents;
  CArray  **parents;
} CAMultiParent;

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
  char     *_pool;         /* framework-managed pool buffer (NULL = legacy ALLOC_N path).
                              Reserved for framework use; ext authors must not read,
                              write, or xfree this field directly.  See
                              ext/ca_array_pool.c. */
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
  char     *_pool;         /* framework-managed pool buffer (NULL = legacy ALLOC_N path).
                              Reserved for framework use; ext authors must not read,
                              write, or xfree this field directly.  See
                              ext/ca_array_pool.c. */
  /* -------------*/
  VALUE     array;
} CAObjectMask;

/* CARepeat (Phase R migration): structurally identical to CAStride.
   The "repeat" axes are encoded as strides[k] == 0. */
typedef CAStride CARepeat;

/* CAUnboundRepeat (Phase U.1: CAStride prefix + rep_dim tail).
   `rep_dim[i] == 0` marks an unbound (`*`) axis (size 1, stride 0);
   `rep_dim[i] != 0` marks a sized axis inheriting parent's stride.
   `ndim` replaces the former `rep_ndim` field (they are equal). */
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
  char     *_pool;         /* framework-managed pool buffer (NULL = legacy ALLOC_N path).
                              Reserved for framework use; ext authors must not read,
                              write, or xfree this field directly.  See
                              ext/ca_array_pool.c. */
  CArray   *parent;
  uint32_t  attach;
  uint8_t   nosync;
  /* --- CAStride prefix continues --- */
  ca_size_t  *strides;
  ca_size_t   base_offset;
  /* --- CAUnboundRepeat tail --- */
  ca_size_t  *rep_dim;
} CAUnboundRepeat;

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
  char     *_pool;         /* framework-managed pool buffer (NULL = legacy ALLOC_N path).
                              Reserved for framework use; ext authors must not read,
                              write, or xfree this field directly.  See
                              ext/ca_array_pool.c. */
  CArray   *parent;
  uint32_t  attach;
  uint8_t   nosync;
  /* ---- */
  ca_size_t   count;
  ca_size_t   offset;
} CAReduce;

/* -------------------------------------------------------------------- */

/* CAIterator is a form-only Ruby base (see ext/carray_iterator.c); the retired
   2.0 C struct (a kernel_at_addr dispatch slot) lives at
   samples/caiterator/iterator.c. */

/* -------------------------------------------------------------------- */

extern const int ca_endian;
extern const int32_t ca_valid[CA_NTYPE];
extern const int32_t ca_sizeof[CA_NTYPE];
extern const char *  ca_type_name[CA_NTYPE];
extern const int ca_cast_table[CA_NTYPE][CA_NTYPE];
extern const int ca_cast_table2[CA_NTYPE][CA_NTYPE];

/* data_type promotion reducer — pure function over ca_cast_table.  Used by
   CArray.result_type and (from PROPOSAL_LAZY_ELEMENTWISE_VIEW Phase 1)
   the lazy view layer.  See ext/carray_cast.c definition + comment, and
   devel/AUDIT_DTYPE_PROMOTION.md for the audit that confirmed single
   source. */
int8_t ca_promote_type (int8_t a, int8_t b);

/* Infer a data_type code from a Ruby *value* (literal Numeric, true/false,
   Complex, etc.) — distinct from rb_ca_guess_type which interprets the
   object as a data_type *representation* (e.g. T_FIXNUM as a data_type code).
   Used by then_else and by ca_lazy_wrap_scalar's bool-self corner case.
   CArray is not accepted (callers should use ca->data_type directly). */
int8_t ca_value_to_data_type (VALUE obj);

/* Infer a data_type code from a MemoryView producer by parsing its format,
   without importing the data.  Returns -1 when obj is not an MV producer or
   its format is not representable, so the caller falls back to value inference.
   Defined in ext/carray_memory_view.c. */
int8_t ca_mv_probe_data_type (VALUE obj);

/* Symbol cache for data_type code → Symbol lookup.  Initialized in
   Init_carray_class.  Indexed by data_type code (0 = CA_FIXLEN ...
   CA_NTYPE-1 = CA_OBJECT).  Use rb_ca_data_type_to_sym for the public
   conversion entry point (it validates the code first).
   PROPOSAL_DTYPE_SYMBOL_FLIP rev3 Q5=(Y). */
extern ID ca_data_type_sym[CA_NTYPE];
VALUE rb_ca_data_type_to_sym (int8_t data_type);

extern VALUE ca_class[CA_OBJ_TYPE_MAX];
extern const rb_data_type_t *ca_typeddata[CA_OBJ_TYPE_MAX];
extern VALUE ca_mask_class[CA_OBJ_TYPE_MAX];
extern const rb_data_type_t *ca_mask_typeddata[CA_OBJ_TYPE_MAX];
extern ca_operation_function_t ca_func[CA_OBJ_TYPE_MAX];
extern int ca_obj_num;

#define CAVIEW(x) ((CAView *)(x))

/* CAREFUL: `flag` is parenthesised.  Without it, ca_test_flag(ca, A | B)
   expands to `ca->flags & A | B`, and since & binds tighter than | the
   test is true for every array.  ca_unset_flag had the mirror hazard
   through ~. */
#define ca_set_flag(ca, flag)   ( (ca)->flags |= (flag) )
#define ca_unset_flag(ca, flag) ( (ca)->flags &= ~(flag) )
#define ca_test_flag(ca, flag) (( (ca)->flags & (flag) ) ? 1 : 0)

/* -------------------------------------------------------------------- */

extern const rb_data_type_t carray_data_type;
extern const rb_data_type_t cawrap_data_type;
extern const rb_data_type_t cscalar_data_type;
extern const rb_data_type_t caview_data_type;
extern const rb_data_type_t caface_data_type;
extern const rb_data_type_t casource_data_type;

extern const rb_data_type_t cabitarray_data_type;
extern const rb_data_type_t cabitfield_data_type;
extern const rb_data_type_t cablock_data_type;
extern const rb_data_type_t castride_data_type;
extern const rb_data_type_t castride_mask_data_type;
extern const rb_data_type_t cafake_data_type;
extern const rb_data_type_t cabyteswap_data_type;
/* cafield_data_type was retired in 3.0 (Phase F: CAField is now a
   CAStride subclass; use castride_data_type). */
extern const rb_data_type_t cagrid_data_type;
/* camapping_data_type was retired in 3.0 (R.3: CAMapping removed; a[mapper]
   now builds a CAGrid/CAStride normalize chain). */
extern const rb_data_type_t caobject_data_type;
extern const rb_data_type_t careduce_data_type;
extern const rb_data_type_t carefer_data_type;
extern const rb_data_type_t caselect_data_type;
extern const rb_data_type_t cashift_data_type;
extern const rb_data_type_t caunboundrepeat_data_type;
extern const rb_data_type_t cawindow_data_type;

extern const rb_data_type_t carray_mask_data_type;
extern const rb_data_type_t cablock_mask_data_type;
extern const rb_data_type_t cagrid_mask_data_type;
extern const rb_data_type_t camapping_mask_data_type;
extern const rb_data_type_t careduce_mask_data_type;
extern const rb_data_type_t carefer_mask_data_type;
extern const rb_data_type_t caselect_mask_data_type;
extern const rb_data_type_t cashift_mask_data_type;
extern const rb_data_type_t caunboundrepeat_mask_data_type;
extern const rb_data_type_t cawindow_mask_data_type;

/* -------------------------------------------------------------------- */

extern VALUE rb_cCArray;
extern VALUE rb_cCAView;
extern VALUE rb_cCAFace;
extern VALUE rb_cCASource;
extern VALUE rb_cCScalar;
extern VALUE rb_cCAWrap;
extern VALUE rb_cCARefer;
extern VALUE rb_cCABlock;
extern VALUE rb_cCAField;
extern VALUE rb_cCAByteSwap;
extern VALUE rb_cCAStride;
extern VALUE rb_cCAStrideMask;
extern VALUE rb_cCASelect;
extern VALUE rb_cCAObject;
extern VALUE rb_cCARepeat;
extern VALUE rb_cCAUnboundRepeat;
extern VALUE rb_cCAIterator;

extern VALUE rb_cCArrayMask;
extern VALUE rb_cCAReferMask;
extern VALUE rb_cCABlockMask;
extern VALUE rb_cCAFieldMask;
extern VALUE rb_cCASelectMask;
extern VALUE rb_cCAObjectMask;
extern VALUE rb_cCARepeatMask;
extern VALUE rb_cCAUnboundRepeatMask;

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
extern VALUE rb_cCArrayCmplx64;
extern VALUE rb_cCArrayCmplx128;
extern VALUE rb_cCArrayObject;

/* -------------------------------------------------------------------- */

#define CA_CHECK_DATA_TYPE(data_type) \
  do { \
    if ( data_type <= CA_NONE || data_type >= CA_NTYPE ) { \
      rb_raise(rb_eRuntimeError, "invalid data_type id %i", data_type);     \
    } \
    if ( ! ca_valid[data_type] ) { \
      rb_raise(rb_eRuntimeError, "data_type %s is disabled", ca_type_name[data_type]);    \
    } \
  } while (0)

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
  do { \
    if ( index < 0 ) {       \
      index += (dim);     \
    } \
    if ( index < 0 || index >= (dim) ) { \
      rb_raise(rb_eIndexError, "index out of range ( %" PRId64 " <=> 0..%" PRId64 " )", (int64_t) index, (int64_t) dim-1); \
    } \
  } while (0)

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

/* complex <-> Ruby Complex conversion
   (NUM2CC / CC2NUM kept as names for diff minimisation; the legacy
   CComplex class is gone in 3.0 -- the macros now produce and consume
   Ruby's built-in Complex.) */

#ifdef HAVE_COMPLEX_H

static inline double complex
rb_carray_num2cmplx (VALUE num)
{
  if ( RB_TYPE_P(num, T_COMPLEX) ) {
    return NUM2DBL(rb_complex_real(num)) + I * NUM2DBL(rb_complex_imag(num));
  }
  if ( RB_FLOAT_TYPE_P(num) || RB_INTEGER_TYPE_P(num) ) {
    return (double complex) NUM2DBL(num);
  }
  if ( rb_respond_to(num, rb_intern("to_c")) ) {
    VALUE c = rb_funcall(num, rb_intern("to_c"), 0);
    return NUM2DBL(rb_complex_real(c)) + I * NUM2DBL(rb_complex_imag(c));
  }
  if ( rb_respond_to(num, rb_intern("to_f")) ) {
    return (double complex) NUM2DBL(rb_funcall(num, rb_intern("to_f"), 0));
  }
  rb_raise(rb_eTypeError, "can not convert to complex");
}

static inline VALUE
rb_carray_cmplx2num (double complex c)
{
  return rb_complex_new(rb_float_new(creal(c)), rb_float_new(cimag(c)));
}

#  define NUM2CC rb_carray_num2cmplx
#  define CC2NUM rb_carray_cmplx2num

#else
#  define NUM2CC(n) \
          (rb_raise(rb_eRuntimeError, "complex not supported on this build"), 0)
#  define CC2NUM(c) \
          (rb_raise(rb_eRuntimeError, "complex not supported on this build"), Qnil)
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

/* Mask-aware object->numeric parsers: return 1 with *out set on success, or
   0 (no value; caller masks the cell) on parse failure.  Used by the
   object->int/float cast loop so an unparseable cell becomes UNDEF instead
   of a silent 0.0 (float) or a raise (int).  See ext/carray_cast.c. */
int   ca_obj2dbl_ok   (VALUE v, double *out);
int   rb_obj2long_ok  (VALUE v, long *out);
int   rb_obj2ulong_ok (VALUE v, unsigned long *out);
int   rb_obj2ll_ok    (VALUE v, long long *out);
int   rb_obj2ull_ok   (VALUE v, unsigned long long *out);

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

/* The element-wise kernel typedefs (ca_monop_func_t / ca_binop_func_t /
   ca_triop_func_t / ca_moncmp_func_t / ca_bincmp_func_t), the rb_ca_call_*
   drivers, ca_math_call, and the per-data_type dispatch tables now live in
   carray_math_kernel.h (PROPOSAL_CARRAY_H_REORG H.3), which this header
   includes at the bottom (umbrella).  Declarations only moved — definitions
   and ABI are unchanged. */

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

/* Create an entity that adopts (takes ownership of) a caller-provided
   data buffer instead of allocating its own -- for C extensions that
   already hold a freshly decoded buffer and want to avoid a copy.  The
   buffer must be ruby_xmalloc()'d and at least elements*bytes long; it
   is freed with xfree() when the array is collected.  data_type must not
   be CA_OBJECT. */
CArray  *carray_new_adopt (int8_t data_type,
                           int8_t ndim, ca_size_t *dim, ca_size_t bytes, char *ptr);
VALUE    rb_carray_new_adopt (int8_t data_type,
                              int8_t ndim, ca_size_t *dim, ca_size_t bytes, char *ptr);

/* Phase A capstone helper (PROPOSAL_CAPSTONE_PHASE_A.md A.3): allocate
   a reduction-output CArray for kernel_iterator authors.  Computes
   output shape = self.dim with slab axes removed (ascending order),
   collapses to shape [1] when fully reduced.  See
   ext/carray_core.c for docstring + semantics. */
VALUE    rb_ca_new_reduced (VALUE self, int8_t *slab_axes,
                            int8_t naxes, int32_t data_type, int keep_axis);
/* Same shape computation, but the output byte width is passed explicitly
   so a runtime-width output data_type (CA_FIXLEN) can be allocated. */
VALUE    rb_ca_new_reduced_bytes (VALUE self, int8_t *slab_axes, int8_t naxes,
                                  int32_t data_type, ca_size_t bytes, int keep_axis);

/* Phase B capstone helper (PROPOSAL_CAPSTONE_PHASE_B.md B.3): parse
   variadic axis argv into validated int8_t array.  Accepts Integer
   args or a single Array arg, normalises negative axes (Python-style),
   range / duplicate / overflow checks all raise ArgumentError.
   Returns the validated naxes. */
int8_t   rb_ca_parse_reduce_axes (int argc, VALUE *argv,
                                  CArray *ca, int8_t *out_axes);

/* Kwarg form: caller extracts axis: kwarg via rb_scan_args + rb_get_kwargs
   and passes the raw VALUE here.  Accepts Qnil/Qundef (= full reduction),
   Integer (= single axis), or Array of Integer (= multi axes in input
   order).  Validation identical to rb_ca_parse_reduce_axes; raises
   TypeError on other input. */
int8_t   rb_ca_parse_reduce_axes_kw (VALUE axis_val,
                                     CArray *ca, int8_t *out_axes);

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
VALUE    rb_ca_reshape (int argc, VALUE *argv, VALUE self);
VALUE    rb_ca_flatten (VALUE self);

/* --- ca_obj_farray.c --- */

VALUE    rb_ca_farray (VALUE self);

/* --- ca_obj_stride.c --- */

int       ca_stride_setup (CAStride *ca, int8_t obj_type, CArray *parent,
                           int8_t data_type, ca_size_t bytes,
                           int8_t ndim, ca_size_t *dim,
                           ca_size_t *strides, ca_size_t base_offset);
CAStride *ca_stride_new (int8_t obj_type, CArray *parent,
                         int8_t data_type, ca_size_t bytes,
                         int8_t ndim, ca_size_t *dim,
                         ca_size_t *strides, ca_size_t base_offset);
VALUE     rb_ca_stride_new (VALUE cary,
                            int8_t data_type, ca_size_t bytes,
                            int8_t ndim, ca_size_t *dim,
                            ca_size_t *strides, ca_size_t base_offset);
extern int8_t CA_OBJ_STRIDE;
void      ca_stride_compose_to_root (CAStride *leaf,
                                     CArray **out_root,
                                     ca_size_t *out_strides,
                                     ca_size_t *out_base);
/* one stride-composition hop: express leaf (in parent's byte space) into
   parent->parent's byte space.  Non-static so sometimes-fold participants
   (e.g. CAWindow::fold_stride) can compose through a synthetic stride layer. */
int       ca_stride_compose_through (CAStride *leaf, CAStride *parent,
                                     ca_size_t *out_strides, ca_size_t *out_base);

/* --- ca_obj_grid.c --- */

/* Tier 3 / C1 (PROPOSAL_CAGRID_REBUILD): rb_ca_grid_new signature
   changed to take a per-axis cag_axis_t proto array (private to
   ca_obj_grid.c).  No external callers exist so the declaration is
   removed from the public header. */
VALUE   rb_ca_grid (int argc, VALUE *argv, VALUE self);
int     rb_ca_select_axis_eligible_p (int argc, VALUE *argv, VALUE self);
VALUE   rb_ca_select_axis (int argc, VALUE *argv, VALUE self);

/* --- ca_obj_mapping.c --- */

VALUE   rb_ca_mapping (int argc, VALUE *argv, VALUE self);

/* --- ca_obj_field.c --- */

VALUE   rb_ca_field (int argc, VALUE *argv, VALUE self);

/* --- ca_obj_fake.c --- */

VALUE   rb_ca_fake_type (VALUE self, VALUE rtype, VALUE rbytes);

/* --- ca_obj_repeat.c --- */

VALUE   rb_ca_repeat (int argc, VALUE *argv, VALUE self);

/* --- ca_obj_unbound_repeat.c --- */

VALUE   rb_ca_ubrep_shave (VALUE self, VALUE other);
VALUE   rb_ca_rewrap_unbound_repeat (VALUE src, VALUE out);

/* --- carray_broadcast.c --- */

VALUE   ca_broadcast_view (VALUE src, int8_t ndim, ca_size_t *target_dim);
void    ca_broadcast_pair (volatile VALUE *self, volatile VALUE *other);
VALUE   ca_ubrep_bind_with (VALUE self, VALUE other);

/* --- ca_iter_dimension retired (SI.4): CADimensionIterator -> CASlabIterator,
   reference impl at samples/caiterator/dimension.c --- */

/* -------------------------------------------------------------------- */

/* API : defining new array */

/* Register an obj_type.  func_size is sizeof(*func) as the *caller* sees it:
   the table is copied by that length and the remainder zero-filled, so a
   caller built against an older header leaves later slots NULL and reaches
   the default handling for them instead of feeding the dispatcher whatever
   followed its shorter struct.  Pass sizeof of the table being installed:

     ca_install_obj_type(klass, &td, mask_klass, &mask_td,
                         &my_func, sizeof(my_func));

   A func_size larger than this build's struct means the caller was compiled
   against a newer carray; that is reported rather than truncated. */

int
ca_install_obj_type (VALUE klass,
                     const rb_data_type_t *typeddata,
		     VALUE mask_klass,
                     const rb_data_type_t *mask_typeddata,
		     const ca_operation_function_t *func,
		     size_t func_size);


VALUE   ca_data_type_class (int8_t data_type);

void    ca_mark (void *ap);
void    ca_free (void *ap);
void    ca_free_nop (void *ap);

#define ca_length(ca) ((ca)->elements * (ca)->bytes)

/* API : query of array properties */

int     ca_is_scalar (void *ap);

/* ca_is_entity indexes ca_func[], so expanding it inline compiles in the
   current sizeof(ca_operation_function_t) as the array stride.  Sources built
   with the rest of carray are recompiled whenever a slot is added and get the
   macro; anything built separately gets the function, so that a later slot
   addition cannot silently re-index the table underneath it.  (Reading
   ca_func[] directly carries the same coupling, and is left available to
   callers that ask for it deliberately.) */
#ifdef CARRAY_BUILD
#define ca_is_entity(ca) ( ca_func[(ca)->obj_type].entity_type == CA_REAL_ARRAY )
#else
int     ca_is_entity (const void *ap);
#endif

int     ca_is_view (void *ap);
int     ca_is_readonly (void *ap);
int     ca_is_value_array (void *ap);
int     ca_is_mask_array (void *ap);
#define ca_is_face(ca) ( ca_test_flag((ca), CA_FLAG_IS_FACE) )
#define ca_is_lazy_marker(ca) ( ca_test_flag((ca), CA_FLAG_IS_LAZY_MARKER) )

#define ca_is_attached(ca) ( (ca)->ptr != NULL )
#define ca_is_empty(ca) ( (ca)->elements == 0 )

/* Shorthand for TypedData_Get_Struct against the base CArray tag.
   Accepts any concrete subclass (CScalar / CAWrap / CAView subtypes)
   because their TypedData is registered with carray_data_type as parent. */
#define GetCArray(obj, ca) \
    TypedData_Get_Struct((obj), CArray, &carray_data_type, (ca))

/* True iff ca_attach(ca) is essentially O(1) — entity arrays (already
   attached), CAWrap, CScalar, and CAStride-family views whose composed
   strides are row-major contiguous (alias-attach path).  Used by
   kernel_iterator's L1 alias decision (ca_iter_can_alias level 1) and
   by Tier A (PROPOSAL_DELEGATE_COPY_DATA) overlay-view dispatch.
   Renamed 2026-05-25 (T1 step 9.4a): _is_cheap → _is_alias to express
   the structural property (= aliasable without materialise) rather
   than the perf characteristic. */
int     ca_attach_is_alias (void *ap);

/* C.3 (PROPOSAL_EAGER_SLOWPATH_CHUNKING_ARENA): OR operand masks into
   ca_out->mask without ca_attach on operand masks (= gathers via
   ca_xfer_all into arena scratch then byte OR-folds).  ca_out must be
   a freshly templated entity.  For bang variant where ca_out IS one of
   the operands, the existing mask is preserved as initial accumulator. */
void    ca_mask_overlay_safe (CArray *ca_out, int n, ...);

#define ca_is_caobject(ca) ( (ca)->obj_type == CA_OBJ_OBJECT )

int     ca_is_fixlen_type (void *ap);
int     ca_is_boolean_type (void *ap);
int     ca_is_numeric_type (void *ap);
int     ca_is_integer_type (void *ap);
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

/* ca_paste / ca_clip / ca_cut (sub-region copy in/out) removed in 3.0; see
   lib/extras/crop_paste.rb for the Ruby thin wrapper replacements. */
void    ca_fill (void *ap, void *ptr);

/* API : fetch, store */

void    ca_addr2index (void *ap, ca_size_t addr, ca_size_t *idx);
ca_size_t ca_index2addr (void *ap, ca_size_t *idx);


void    ca_fetch_index (void *ap, ca_size_t *idx, void *ptr);
void    ca_fetch_addr (void *ap, ca_size_t addr, void *ptr);
void    ca_store_index (void *ap, ca_size_t *idx, void *ptr);
void    ca_store_addr (void *ap, ca_size_t addr, void *ptr);
void    ca_xfer_index (void *ap, ca_size_t *idx, void *data, int dir);
void    ca_xfer_addrs (void *ap, ca_size_t n, ca_size_t *addrs, void *data, int dir);
/* Y.1/Y.2 (PROPOSAL_XFER_ADDRS_PER_REGION_GAPS.md §4.1) shared predicate:
   detect if addrs[] is a sequential run (addrs[i] == addrs[0]+i for all i).
   Used by ca_xfer_addrs_dispatch (Y.2) and view xfer_addrs slots (Y.1) for
   whole-view / sub-region run detection -> opportunistic engine dispatch. */
int     ca_xfer_addrs_is_sequential_run (ca_size_t n, ca_size_t *addrs,
                                         ca_size_t *base_out);
/* Y.1.e: resolve cand through identity CAStride compose-fold to find an
   attached root.  Returns cand if cand->ptr is set, cand is not CAStride
   family, or no identity compose-fold path exists; otherwise returns the
   resolved root (which has ptr).  Used by view xfer_addrs slots to lift
   parent->ptr gate through view CAStride layers (= chain pattern). */
CArray *ca_resolve_attached_root_via_identity (CArray *cand);

void    ca_xfer_stride (void *ap, ca_size_t *starts, ca_size_t *counts,
                        ca_size_t *strides, void *data, int dir);
void    ca_xfer_all (void *ap, void *data, int dir);

void    ca_copy_data (void *ap, char *ptr);
void    ca_sync_data (void *ap, char *ptr);
void    ca_fill_data (void *ap, void *ptr);

/* Write one value into part of a view.  ptr is one element's worth of bytes.
   Both describe the region over the view's own linear addresses; see the
   fill_stride slot comment for why addresses rather than an index box.
   A view without the matching slot gets a per-cell default that descends
   through xfer_index, so the region is still all that gets touched. */
void    ca_fill_stride (void *ap, ca_size_t base, int8_t ndim,
                        ca_size_t *counts, ca_size_t *steps, void *ptr);
void    ca_fill_addrs (void *ap, ca_size_t n, ca_size_t *addrs, void *ptr);

/* For slot implementations: the per-cell walk, to stand in for regions this
   view cannot pass on, and the test for the one region it always can. */
void    ca_fill_stride_default (void *ap, ca_size_t base, int8_t ndim,
                                ca_size_t *counts, ca_size_t *steps, void *ptr);
void    ca_fill_addrs_default (void *ap, ca_size_t n, ca_size_t *addrs, void *ptr);

/* For a view whose fill is a read-modify-write of its parent and so has no
   region to pass down: walk the region and feed its addresses to the batched
   address slot in windows, rather than descending the chain per cell. */
void    ca_fill_stride_via_addrs (void *ap, ca_size_t base, int8_t ndim,
                                  ca_size_t *counts, ca_size_t *steps,
                                  void *ptr);

/* The entity fill, against a buffer the caller resolved for itself.  A source
   that hands out its pointer on demand rather than keeping one at rest gets
   the same run-writing walk without having to write it again, and without
   publishing the pointer into ca->ptr to do so. */
void    ca_fill_stride_buffer (char *dst, ca_size_t bytes, ca_size_t base,
                               int8_t ndim, ca_size_t *counts,
                               ca_size_t *steps, void *ptr);
void    ca_fill_addrs_buffer (char *dst, ca_size_t bytes, ca_size_t n,
                              ca_size_t *addrs, void *ptr);
int     ca_fill_stride_is_whole (void *ap, ca_size_t base, int8_t ndim,
                                 ca_size_t *counts, ca_size_t *steps);

/* Fill the whole of `ca` by handing its own extent to ca_fill_stride: the
   region every caller means when it says "all of me".  Views use it to route
   a full-coverage fill_data into the region path. */
void    ca_fill_stride_whole (void *ap, void *ptr);

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

#define ca_wrap_writable(obj, data_type) \
  (obj = rb_ca_wrap_writable(obj, INT2NUM(data_type)), (CArray*) DATA_PTR(obj))
#define ca_wrap_readonly(obj, data_type) \
  (obj = rb_ca_wrap_readonly(obj, INT2NUM(data_type)), (CArray*) DATA_PTR(obj))

VALUE   rb_carray_wrap_ptr (int8_t data_type,
                            int8_t ndim, ca_size_t *dim, ca_size_t bytes,
                            CArray *mask, char *ptr, VALUE refer);

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
/* ca_rand removed in 3.0; use rb_random_real/rb_random_ulong_limited instead */
ca_size_t ca_bounds_normalize_index (int8_t bounds, ca_size_t size0, ca_size_t k);
int     rb_ca_normalize_axis_value (VALUE self, VALUE raxis, const char *name);
int     rb_ca_normalize_axis_for_ndim (long raw, int ndim, const char *name);
int8_t  rb_ca_parse_reduce_axes_kw_ctx (VALUE axis_val, CArray *ca,
                                        int8_t *out_axes, const char *ctx);

/* API : high level */

/* parsing options */
VALUE   rb_pop_options (int *argc, VALUE **argv);
void    rb_scan_options (VALUE opt, const char *spec_in, ...);
void    rb_reject_options (VALUE opt);
void    rb_set_options (VALUE opt, const char *spec_in, ...);

/* predicates for check object is carray or cscalar */
#define rb_obj_is_carray(obj) rb_obj_is_kind_of(obj, rb_cCArray)
VALUE   rb_obj_is_cscalar (VALUE obj);
void    rb_check_carray_object (VALUE arg);

/* specific Data_Wrap_Struct for carray */
VALUE   ca_wrap_struct (void *ap);
VALUE   ca_wrap_struct_as (void *ap, VALUE klass);

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
void    rb_ca_cast_self_or_other (volatile VALUE *self, volatile VALUE *other);
void    rb_ca_cast_other (VALUE *self, volatile VALUE *other);

VALUE   rb_ca_wrap_writable (VALUE obj, VALUE vtype);
VALUE   rb_ca_wrap_readonly (VALUE obj, VALUE vtype);

/* inheritance */
/* rb_ca_data_type_inherit / rb_ca_data_type_import were removed in 3.0
   (PROPOSAL_DEPRECATE_LEGACY_DATA_CLASS P.2/P.3). data_class lives on
   Face (CARecord) tail; view ctors no longer carry data_class via
   @data_class ivar — Face dispatch (CA_FACE_LIFT_IF_FACE) handles it. */
VALUE   rb_ca_set_parent (VALUE self, VALUE obj);
                             /* call once for a view carray */

/* freeze and decraration of modifing contents of carray */
VALUE   rb_ca_freeze (VALUE self);
VALUE   rb_ca_set_read_only_flag (VALUE self);
void    rb_ca_modify (VALUE self);  /* guard: rb_check_frozen(self) + ca_is_readonly */

/* attributes */
VALUE   rb_ca_obj_type (VALUE self);
VALUE   rb_ca_data_type (VALUE self);
VALUE   rb_ca_ndim (VALUE self);
VALUE   rb_ca_bytes (VALUE self);
VALUE   rb_ca_flags (VALUE self);
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
/* rb_ca_set_data_class was removed in 3.0
   (PROPOSAL_DEPRECATE_LEGACY_DATA_CLASS P.5). The Ruby method
   CArray#data_class= raises ArgumentError with migration message. */
VALUE   rb_ca_data_class_decode (VALUE self, VALUE str);
VALUE   rb_ca_data_class_encode (VALUE self, VALUE obj);
VALUE   rb_ca_members (VALUE self);
VALUE   rb_ca_face_field (VALUE self, VALUE sym);
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
VALUE   rb_ca_to_ca (int argc, VALUE *argv, VALUE self);
int     ca_to_ca_writable_arg (int argc, VALUE *argv);
NORETURN(void ca_to_ca_refuse_writable (VALUE self));
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
VALUE   rb_ca_to_cmplx64 (VALUE self);
VALUE   rb_ca_to_cmplx128 (VALUE self);
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

/* API : CAMath functions
 *
 * Declarations live in carray_call_cfunc.h, co-generated with
 * carray_call_cfunc.c by ext/mk_call_cfunc.rb to keep prototypes
 * and definitions in lockstep. */
#include "carray_call_cfunc.h"

/* -------------------------------------------------------------------- */

/* carray_loop.c — unified multi-dimensional index walk shared by
   each_index / each_with_index / map_index! / map_with_index! and by
   the construction-block sugar in rb_ca_initialize. */
#define CA_LOOP_WITH_VALUE 1
#define CA_LOOP_STORE      2

VALUE rb_ca_index_walk (VALUE self, CArray *ca, int8_t level,
                        ca_size_t *idx, VALUE ridx, int mode);

/* -------------------------------------------------------------------- */

void ca_debug ();

/* -------------------------------------------------------------------- */

/* PROPOSAL_PORTABLE_TEXTBOOK_SORT — portable textbook sort kernels.
   These are layer ③ true-internal (ca_sort_kernels.h self-describes as
   "ext-internal, signatures may change across 3.x").  They are NOT pulled
   into the carray.h umbrella and NOT installed (PROPOSAL_CARRAY_H_REORG
   H.4.1): the internal consumers (carray_sort_kernel.c / carray_sort.c /
   carray_partition.c / carray_kernels.c) include ca_sort_kernels.h
   directly. */

/* -------------------------------------------------------------------- */
/* Public umbrella (PROPOSAL_CARRAY_H_REORG H.3)                         */
/* -------------------------------------------------------------------- */

/* Pull the ext-author / math-backend surface in under the carray.h
   umbrella so a downstream gem reaches it with a single
   `#include "carray.h"`.  Placed at the bottom so these sub-headers see
   every type / enum / struct defined above (ca_size_t, CA_NTYPE, CArray,
   ...).  All sub-headers are include-guarded, so the carray.h re-entry
   from inside them is a no-op. */

#include "carray_math_kernel.h"   /* kernel typedefs + rb_ca_call_* + dispatch tables */
#include "ca_kernel_iterator.h"   /* CA_FOR_EACH_SLAB / CA_WITH_WHOLE_VIEW / CA_SLAB_*_T */

#endif
