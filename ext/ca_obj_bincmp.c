/* ---------------------------------------------------------------------------

  Lazy binadic element-wise comparison view: holds (left, right,
  op_id, eps) and materialises a boolean result on attach.  Carries
  CA_FLAG_READ_ONLY; there is no bang path and `[]=` raises.

  Sibling of ca_obj_binop.c (element-wise arithmetic) and
  ca_obj_moncmp.c (unary comparisons); dispatched by
  ca_bincmp_kernel_lookup from ca_bincmp_dispatch.h.

  Dispatch by data_type:
    numeric (i8..f64, +complex) -> ca_bincmp_<op>_<type> kernel
    boolean / fixlen / object   -> not implemented (raise)

  CAREFUL: the binop in-place trick (= pull left into the output
  buffer) is structurally unavailable here — the output is
  boolean8_t (1 byte per cell) while operands live at the common
  data_type (typically 8 bytes at f64), so a pull-into-output would
  overflow.  xfer_stride therefore holds two operand-typed scratch
  slabs and writes the boolean result directly to `data`.

  Comparison ops never trap, so the kernel is called with m=NULL
  (SIMD fast path).  The output mask is computed by create_mask as
  `left.mask | right.mask` and propagated through the standard
  CArray mask machinery.

---------------------------------------------------------------------------- */

#include "carray.h"
#include "carray_internal.h"   /* ca_lazy_arena_* */
#include "ca_bincmp_dispatch.h"
#include "ca_monop_dispatch.h"  /* CA_MONOP_CAST_BASE */

extern VALUE ca_broadcast_view (VALUE src, int8_t ndim,
                                ca_size_t *target_dim);
extern VALUE ca_lazy_wrap_scalar (VALUE other, CArray *self_ca);
extern void *ca_lazy_arena_acquire (ca_size_t bytes);
extern void  ca_lazy_arena_release (void *ptr);

int8_t CA_OBJ_BINCMP;
VALUE rb_cCABinCmp;

extern int8_t CA_OBJ_LAZY_MARKER;

/* ------------------------------------------------------------------- */
/* CABinCmp struct                                                      */
/* ------------------------------------------------------------------- */

typedef struct CABinCmp {
  int16_t   obj_type;
  int8_t    data_type;       /* always CA_BOOLEAN */
  int8_t    ndim;
  int32_t   flags;
  ca_size_t bytes;           /* always 1 */
  ca_size_t elements;
  ca_size_t *dim;
  char     *ptr;
  CArray   *mask;
  char     *_pool;         /* framework-managed pool buffer (NULL = legacy ALLOC_N path). */
  CArray   *parent;          /* = left */
  uint32_t  attach;
  uint8_t   nosync;
  /* CABinCmp-specific tail */
  CArray   *right;
  uint16_t  op_id;
  uint8_t   right_is_scalar;
  int8_t    common_dt;       /* operand-data_type after promote (= cast
                                target of both left & right, also the
                                kernel lookup key) */
  double    eps;             /* Runtime tolerance slot for IS_CLOSE /
                                IS_EQUIV; ignored for other ops.  The
                                `eps` name is retained to keep the
                                `__eps__` Ruby accessor stable across
                                the dual purpose. */
} CABinCmp;

static size_t
ca_bincmp_dsize (const void *ap)
{
  const CABinCmp *ca = (const CABinCmp *) ap;
  return sizeof(CABinCmp) + ca->ndim * sizeof(ca_size_t);
}

/* Pool framework hooks: single ndim-sized tail (dim) in the _pool
   buffer.  See ca_array_pool.c for the shared alloc/free discipline. */
static size_t
ca_bincmp_pool_bytes (int8_t ndim)
{
  ca_size_t n = (ndim > 0) ? ndim : 1;
  return (size_t) n * sizeof(ca_size_t);
}

static void
ca_bincmp_pool_init (void *ap, int8_t ndim)
{
  CABinCmp *ca = (CABinCmp *) ap;
  ca->dim = (ca_size_t *) ca->_pool;
}

const rb_data_type_t cabincmp_data_type = {
    .parent = &caview_data_type,
    .wrap_struct_name = "CABinCmp",
    .function = {
        .dmark = ca_mark,
        .dfree = ca_free,
        .dsize = ca_bincmp_dsize,
        .dcompact = NULL
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

/* ------------------------------------------------------------------- */
/* setup / new / free                                                   */
/* ------------------------------------------------------------------- */

static int
ca_bincmp_setup (CABinCmp *ca, CArray *left, CArray *right, uint16_t op_id,
                 double eps)
{
  ca->obj_type  = CA_OBJ_BINCMP;
  ca->data_type = CA_BOOLEAN;          /* output is always boolean */
  ca->flags     = CA_FLAG_READ_ONLY;
  ca->ndim      = left->ndim;
  ca->bytes     = 1;                   /* boolean8_t */
  ca->elements  = left->elements;
  ca->ptr       = NULL;
  ca->mask      = NULL;
  if ( ! ca->_pool ) {
    ca->dim     = ALLOC_N(ca_size_t, left->ndim);
  }
  ca->parent    = left;
  ca->attach    = 0;
  ca->nosync    = 0;
  ca->right     = right;
  ca->op_id     = op_id;
  ca->right_is_scalar = ( right->elements == 1 && left->elements > 1 ) ? 1 : 0;
  /* Builder has already cast both operands to common data_type.  */
  ca->common_dt = left->data_type;
  ca->eps       = eps;

  memcpy(ca->dim, left->dim, left->ndim * sizeof(ca_size_t));

  if ( ca_has_mask(left) || ca_has_mask(right) ) {
    ca_create_mask(ca);
  }

  if ( ca_is_scalar(left) && ca_is_scalar(right) ) {
    ca_set_flag(ca, CA_FLAG_SCALAR);
  }

  return 0;
}

CABinCmp *
ca_bincmp_new (CArray *left, CArray *right, uint16_t op_id, double eps)
{
  CABinCmp *ca = (CABinCmp *) ca_array_alloc(CA_OBJ_BINCMP, left->ndim);
  ca_bincmp_setup(ca, left, right, op_id, eps);
  return ca;
}

static void
free_ca_bincmp (void *ap)
{
  CABinCmp *ca = (CABinCmp *) ap;
  if ( ca != NULL ) {
    ca_free(ca->mask);
    if ( ca->_pool ) {
      ca_array_free(ca);          /* dim lives in _pool */
    }
    else {
      xfree(ca->dim);
      xfree(ca);
    }
  }
}

/* ------------------------------------------------------------------- */
/* operation function table                                             */
/* ------------------------------------------------------------------- */

static void ca_bincmp_func_xfer_stride (void *ap, ca_size_t *starts,
                                         ca_size_t *counts,
                                         ca_size_t *strides,
                                         void *data, int dir);

static void *
ca_bincmp_func_clone (void *ap)
{
  CABinCmp *ca = (CABinCmp *) ap;
  return ca_bincmp_new(ca->parent, ca->right, ca->op_id, ca->eps);
}

static void
ca_bincmp_func_xfer_index (void *ap, ca_size_t *idx, void *data, int dir)
{
  CABinCmp *ca = (CABinCmp *) ap;
  ca_size_t starts[CA_RANK_MAX];
  ca_size_t counts[CA_RANK_MAX];
  ca_size_t strides[CA_RANK_MAX];
  int8_t    k;

  if ( dir != CA_XFER_GET ) {
    rb_raise(rb_eRuntimeError, "CABinCmp is read-only (xfer_index PUT)");
  }

  for ( k = ca->ndim - 1; k >= 0; k-- ) {
    starts[k]  = idx[k];
    counts[k]  = 1;
    strides[k] = 1;                  /* boolean8_t */
  }
  ca_bincmp_func_xfer_stride(ca, starts, counts, strides, data, CA_XFER_GET);
}

static void
ca_bincmp_func_xfer_addrs (void *ap, ca_size_t n, ca_size_t *addrs,
                            void *data, int dir)
{
  CABinCmp *ca = (CABinCmp *) ap;
  ca_size_t i;
  char *out = (char *) data;

  if ( dir != CA_XFER_GET ) {
    rb_raise(rb_eRuntimeError, "CABinCmp is read-only (xfer_addrs PUT)");
  }

  for ( i = 0; i < n; i++ ) {
    ca_size_t idx[CA_RANK_MAX];
    ca_addr2index((CArray *)ca, addrs[i], idx);
    ca_bincmp_func_xfer_index(ca, idx, out + i, CA_XFER_GET);
  }
}

/* Test / observability counters — bumped from the xfer_stride hot
   path so specs can assert scratch acquisition and leaf in-place
   hit rates without materialising the view. */
ca_size_t ca_bincmp_scratch_acquire_count = 0;
ca_size_t ca_bincmp_materialise_call_count = 0;
ca_size_t ca_bincmp_leaf_inplace_count    = 0;

/* Leaf-operand in-place read eligibility.  When the operand has a
   valid contiguous backing buffer at the common data_type, we can
   use operand->ptr + byte_offset directly, skipping the arena
   acquire and the ca_xfer_stride pull.
 *
 * Eligible cases:
 *   - entity (CA_OBJ_ARRAY / CA_OBJ_SCALAR / CA_OBJ_ARRAY_WRAP) at
 *     the common data_type
 *   - already-attached view at the common data_type with a
 *     contiguous ptr
 *
 * The request must be a row-major slab over the operand (what
 * xfer_all sends, which is the dominant to_ca path). */
static int
ca_bincmp_try_leaf_inplace (CArray *op, int8_t common_dt,
                             ca_size_t *starts, ca_size_t *counts,
                             ca_size_t expected_inner_byte_stride,
                             char **out_ptr)
{
  ca_size_t row_strides[CA_RANK_MAX];
  ca_size_t s, byte_off;
  int8_t k;

  if ( op->data_type != common_dt ) return 0;
  if ( op->ptr == NULL )            return 0;
  if ( op->bytes != expected_inner_byte_stride ) return 0;

  /* Compute row-major byte offset from starts[].  We rely on the
     caller (ca_xfer_all) providing row-major counts == op->dim or a
     contig sub-region.  byte_off = sum(starts[k] * row_stride_k)
     where row_stride_k = product of dim[k+1..ndim-1] * bytes.       */
  s = op->bytes;
  for ( k = op->ndim - 1; k >= 0; k-- ) {
    row_strides[k] = s;
    s *= op->dim[k];
  }
  byte_off = 0;
  for ( k = 0; k < op->ndim; k++ ) {
    /* require sub-region fits within parent dim (= no OOB)           */
    if ( starts[k] < 0 || starts[k] + counts[k] > op->dim[k] ) return 0;
    byte_off += starts[k] * row_strides[k];
  }

  *out_ptr = op->ptr + byte_off;
  return 1;
}

static void
ca_bincmp_func_xfer_stride (void *ap, ca_size_t *starts, ca_size_t *counts,
                             ca_size_t *strides, void *data, int dir)
{
  CABinCmp *bc = (CABinCmp *) ap;
  ca_size_t slab_n;
  int8_t    k;
  void     *left_scratch, *right_scratch;
  ca_size_t operand_bytes;
  ca_size_t right_step;
  int       left_is_inplace  = 0;   /* skip release for leaf-opt path */
  int       right_is_inplace = 0;

  if ( dir != CA_XFER_GET ) {
    rb_raise(rb_eRuntimeError, "CABinCmp is read-only (xfer_stride PUT)");
  }
  ca_bincmp_materialise_call_count++;

  slab_n = 1;
  for ( k = 0; k < bc->ndim; k++ ) slab_n *= counts[k];

  operand_bytes = ca_sizeof[bc->common_dt];

  /* === 1. pull LEFT (leaf in-place read or arena scratch) === */
  {
    char *left_inplace = NULL;
    if ( ca_bincmp_try_leaf_inplace(bc->parent, bc->common_dt,
                                     starts, counts, operand_bytes,
                                     &left_inplace) ) {
      /* Leaf-opt path: use parent->ptr + byte_offset directly. */
      left_scratch = left_inplace;
      left_is_inplace = 1;
      ca_bincmp_leaf_inplace_count++;
    }
    else {
      ca_size_t left_strides[CA_RANK_MAX];
      ca_size_t s = operand_bytes;
      for ( k = bc->ndim - 1; k >= 0; k-- ) {
        left_strides[k] = s;
        s *= counts[k];
      }
      left_scratch = ca_lazy_arena_acquire(slab_n * operand_bytes);
      ca_bincmp_scratch_acquire_count++;
      ca_xfer_stride(bc->parent, starts, counts, left_strides, left_scratch,
                     CA_XFER_GET);
    }
  }

  /* === 2. pull RIGHT (right_is_scalar + leaf-opt) === */
  if ( bc->right_is_scalar ) {
    /* CScalar right: pull the single value into a 1-cell scratch
       and walk the kernel with right_step=0.  Leaf-opt applies when
       right is an entity-shaped CScalar at the common data_type;
       the gain per call is small but the code path stays uniform
       with the same-shape case. */
    char *right_inplace = NULL;
    ca_size_t one_starts[CA_RANK_MAX] = {0};
    ca_size_t one_counts[CA_RANK_MAX];
    for ( k = 0; k < bc->right->ndim; k++ ) one_counts[k] = 1;

    if ( ca_bincmp_try_leaf_inplace(bc->right, bc->common_dt,
                                     one_starts, one_counts, operand_bytes,
                                     &right_inplace) ) {
      right_scratch = right_inplace;
      right_is_inplace = 1;
      ca_bincmp_leaf_inplace_count++;
    }
    else {
      ca_size_t one_strides[CA_RANK_MAX];
      for ( k = 0; k < bc->right->ndim; k++ ) one_strides[k] = operand_bytes;
      right_scratch = ca_lazy_arena_acquire(operand_bytes);
      ca_bincmp_scratch_acquire_count++;
      ca_xfer_stride(bc->right, one_starts, one_counts, one_strides,
                     right_scratch, CA_XFER_GET);
    }
    right_step = 0;
  }
  else {
    /* Same-shape right: full slab pull or leaf-opt. */
    char *right_inplace = NULL;
    if ( ca_bincmp_try_leaf_inplace(bc->right, bc->common_dt,
                                     starts, counts, operand_bytes,
                                     &right_inplace) ) {
      right_scratch = right_inplace;
      right_is_inplace = 1;
      ca_bincmp_leaf_inplace_count++;
    }
    else {
      ca_size_t right_strides[CA_RANK_MAX];
      ca_size_t s = operand_bytes;
      for ( k = bc->ndim - 1; k >= 0; k-- ) {
        right_strides[k] = s;
        s *= counts[k];
      }
      right_scratch = ca_lazy_arena_acquire(slab_n * operand_bytes);
      ca_bincmp_scratch_acquire_count++;
      ca_xfer_stride(bc->right, starts, counts, right_strides, right_scratch,
                     CA_XFER_GET);
    }
    right_step = 1;
  }

  /* === 3. apply bincmp kernel ===
   *
   * Kernel signature (ext/carray.h):
   *   fn(n, m, ptr1, b1, i1, ptr2, b2, i2, ptr3, b3, i3)
   *
   * Per inspection of generated ca_bincmp_<op>_<data_type>, the `b*` args
   * are declared but unused (kernel computes ptr + k*i*sizeof(T)).  We
   * pass 0 for the base arguments.
   *
   * Non-trapping: m=NULL (= SIMD fast path).  Mask propagation handled
   * by create_mask at view construction time.
   */
  {
    ca_bincmp_func_t fn = ca_bincmp_kernel_lookup(bc->op_id, bc->common_dt);
    if ( fn == NULL ) {
      if ( ! right_is_inplace ) ca_lazy_arena_release(right_scratch);
      if ( ! left_is_inplace  ) ca_lazy_arena_release(left_scratch);
      rb_raise(rb_eNotImpError,
               "CABinCmp: kernel not implemented (op_id=%u data_type=%d)",
               (unsigned) bc->op_id, (int) bc->common_dt);
    }
    fn(slab_n, NULL,
       (char *) left_scratch,  0, 1,
       (char *) right_scratch, 0, right_step,
       (char *) data,          0, 1,
       bc->eps);   /* Runtime tolerance for IS_CLOSE / IS_EQUIV. */
  }

  if ( ! right_is_inplace ) ca_lazy_arena_release(right_scratch);
  if ( ! left_is_inplace  ) ca_lazy_arena_release(left_scratch);
}

static void
ca_bincmp_func_xfer_all (void *ap, void *data, int dir)
{
  CABinCmp *ca = (CABinCmp *) ap;
  ca_size_t starts[CA_RANK_MAX];
  ca_size_t native[CA_RANK_MAX];
  int8_t    k;
  ca_size_t s = 1;     /* output stride = 1 byte */
  for ( k = ca->ndim - 1; k >= 0; k-- ) { native[k] = s; s *= ca->dim[k]; }
  for ( k = 0; k < ca->ndim; k++ ) starts[k] = 0;
  ca_xfer_stride(ca, starts, ca->dim, native, data, dir);
}

static void
ca_bincmp_func_allocate (void *ap)
{
  CABinCmp *ca = (CABinCmp *) ap;
  ca->ptr = xmalloc(ca_length(ca));
}

static void
ca_bincmp_func_attach (void *ap)
{
  /* CAREFUL: call the view-specific xfer_stride directly here,
     not the public ca_xfer_stride dispatcher.  The dispatcher's
     self-memcpy fast path detects data == ca->ptr and returns
     without materialising, so the freshly-allocated buffer would
     still hold garbage. */
  CABinCmp *ca = (CABinCmp *) ap;
  ca_size_t starts[CA_RANK_MAX];
  ca_size_t native[CA_RANK_MAX];
  int8_t    k;
  ca_size_t s;

  ca->ptr = xmalloc(ca_length(ca));

  s = ca->bytes;
  for ( k = ca->ndim - 1; k >= 0; k-- ) { native[k] = s; s *= ca->dim[k]; }
  for ( k = 0; k < ca->ndim; k++ ) starts[k] = 0;
  ca_bincmp_func_xfer_stride(ca, starts, ca->dim, native, ca->ptr, CA_XFER_GET);
}

static void
ca_bincmp_func_sync (void *ap)
{
  /* read-only */
}

static void
ca_bincmp_func_detach (void *ap)
{
  CABinCmp *ca = (CABinCmp *) ap;
  xfree(ca->ptr);
  ca->ptr = NULL;
}

NORETURN(static void ca_bincmp_func_fill_data (void *ap, void *ptr));
static void
ca_bincmp_func_fill_data (void *ap, void *ptr)
{
  rb_raise(rb_eRuntimeError, "CABinCmp is read-only (fill_data)");
}

/* mask = left.mask | right.mask, materialised as boolean8_t.
   Mirrors CABinOp's create_mask policy. */
static void
ca_bincmp_func_create_mask (void *ap)
{
  CABinCmp *bc = (CABinCmp *) ap;
  CArray *l = bc->parent;
  CArray *r = bc->right;
  CArray *lm = NULL, *rm = NULL;
  boolean8_t *dst;
  ca_size_t i, n;
  int has_l, has_r;

  has_l = ca_has_mask(l);
  has_r = ca_has_mask(r);
  if ( ! has_l && ! has_r ) return;

  if ( has_l ) lm = l->mask;
  if ( has_r ) rm = r->mask;

  bc->mask = (CArray *) carray_new(CA_BOOLEAN, bc->ndim, bc->dim, 0, NULL);
  dst = (boolean8_t *) bc->mask->ptr;
  n = bc->elements;

  if ( has_l ) ca_attach(lm);
  if ( has_r ) ca_attach(rm);

  for ( i = 0; i < n; i++ ) {
    boolean8_t a = has_l ? ((boolean8_t *) lm->ptr)[i] : 0;
    boolean8_t b = 0;
    if ( has_r ) {
      ca_size_t ri = bc->right_is_scalar ? 0 : i;
      b = ((boolean8_t *) rm->ptr)[ri];
    }
    dst[i] = (boolean8_t)( a | b );
  }

  if ( has_l ) ca_detach(lm);
  if ( has_r ) ca_detach(rm);
}

ca_operation_function_t ca_bincmp_func = {
  -1,
  CA_VIEW_ARRAY,
  free_ca_bincmp,
  ca_bincmp_func_clone,
  ca_bincmp_func_allocate,
  ca_bincmp_func_attach,
  ca_bincmp_func_sync,
  ca_bincmp_func_detach,
  ca_bincmp_func_fill_data,
  ca_bincmp_func_create_mask,
  ca_bincmp_func_xfer_index,
  ca_bincmp_func_xfer_addrs,
  NULL,
  ca_bincmp_func_xfer_stride,
  ca_bincmp_func_xfer_all,
};

/* ------------------------------------------------------------------- */
/* Public builder (= lib/carray/lazy.rb dispatch entry)                 */
/* ------------------------------------------------------------------- */

static VALUE
collapse_marker (VALUE cary)
{
  CArray *ca;
  if ( ! rb_obj_is_carray(cary) ) return cary;
  TypedData_Get_Struct(cary, CArray, &carray_data_type, ca);
  if ( ca->obj_type == CA_OBJ_LAZY_MARKER ) {
    return rb_ca_parent(cary);
  }
  return cary;
}

static VALUE
rb_ca_bincmp_new (VALUE l_cary, VALUE r_cary, uint16_t op_id, double eps)
{
  volatile VALUE obj;
  CArray *l, *r;
  CABinCmp *ca;
  rb_check_carray_object(l_cary);
  rb_check_carray_object(r_cary);
  TypedData_Get_Struct(l_cary, CArray, &carray_data_type, l);
  TypedData_Get_Struct(r_cary, CArray, &carray_data_type, r);
  ca  = ca_bincmp_new(l, r, op_id, eps);
  obj = ca_wrap_struct(ca);
  rb_ca_set_parent(obj, l_cary);
  rb_ivar_set(obj, rb_intern("__bincmp_right__"), r_cary);
  return obj;
}

VALUE
rb_ca_bincmp_build (VALUE l_cary, VALUE r_cary, uint16_t op_id, double eps)
{
  CArray *l, *r;
  int8_t  l_in_dt, r_in_dt;
  volatile VALUE l_resolved, r_resolved;

  l_resolved = collapse_marker(l_cary);
  r_resolved = collapse_marker(r_cary);

  /* Scalar wrap — same policy as CABinOp. */
  if ( ! rb_obj_is_carray(l_resolved) ) {
    rb_check_carray_object(r_resolved);
    TypedData_Get_Struct(r_resolved, CArray, &carray_data_type, r);
    l_resolved = ca_lazy_wrap_scalar(l_resolved, r);
  }
  if ( ! rb_obj_is_carray(r_resolved) ) {
    rb_check_carray_object(l_resolved);
    TypedData_Get_Struct(l_resolved, CArray, &carray_data_type, l);
    r_resolved = ca_lazy_wrap_scalar(r_resolved, l);
  }

  TypedData_Get_Struct(l_resolved, CArray, &carray_data_type, l);
  TypedData_Get_Struct(r_resolved, CArray, &carray_data_type, r);

  /* Cast both operands to the common data_type. */
  ca_bincmp_kernel_input_data_types(op_id, l->data_type, r->data_type,
                                 &l_in_dt, &r_in_dt);

  if ( l_in_dt != l->data_type ) {
    VALUE cast_op = INT2NUM(CA_MONOP_CAST_BASE + l_in_dt);
    l_resolved = rb_funcall(rb_const_get(rb_cObject, rb_intern("CAMonOp")),
                            rb_intern("__build__"), 2,
                            l_resolved, cast_op);
    TypedData_Get_Struct(l_resolved, CArray, &carray_data_type, l);
  }
  if ( r_in_dt != r->data_type ) {
    VALUE cast_op = INT2NUM(CA_MONOP_CAST_BASE + r_in_dt);
    r_resolved = rb_funcall(rb_const_get(rb_cObject, rb_intern("CAMonOp")),
                            rb_intern("__build__"), 2,
                            r_resolved, cast_op);
    TypedData_Get_Struct(r_resolved, CArray, &carray_data_type, r);
  }

  /* Broadcast — same size-1-expansion logic as CABinOp. */
  ca_broadcast_pair(&l_resolved, &r_resolved);
  TypedData_Get_Struct(l_resolved, CArray, &carray_data_type, l);
  TypedData_Get_Struct(r_resolved, CArray, &carray_data_type, r);

  if ( l->elements != r->elements ) {
    if ( r->elements == 1 && l->elements > 1 ) {
      /* CScalar right: handled via right_is_scalar */
    }
    else if ( l->elements == 1 && r->elements > 1 ) {
      /* Comparison ops commute under negation (LT/GT/LE/GE flip to
         their counterpart, EQ/NE are commutative), but here we
         broadcast the left scalar up instead of swapping, so op_id
         does not need a flip table. */
      ca_size_t count[CA_RANK_MAX];
      int8_t k;
      if ( r->ndim > l->ndim ) {
        for ( k = 0; k < r->ndim - 1; k++ ) count[k] = 1;
        count[r->ndim - 1] = 0;
        l_resolved = rb_ca_repeat_new(l_resolved, r->ndim, count);
        TypedData_Get_Struct(l_resolved, CArray, &carray_data_type, l);
      }
      l_resolved = ca_broadcast_view(l_resolved, r->ndim, r->dim);
      TypedData_Get_Struct(l_resolved, CArray, &carray_data_type, l);
    }
    else {
      rb_raise(rb_eArgError,
               "CABinCmp: shape mismatch (%lld vs %lld) — only same-"
               "ndim size-1 broadcast is supported; cross-ndim "
               "promotion is not adopted in CArray",
               (long long) l->elements, (long long) r->elements);
    }
  }

  return rb_ca_bincmp_new(l_resolved, r_resolved, op_id, eps);
}

static VALUE
rb_ca_bincmp_s_build (int argc, VALUE *argv, VALUE klass)
{
  VALUE l_cary, r_cary, op_id_val, eps_val;
  uint16_t op_id;
  double eps = 0.0;
  (void) klass;
  rb_scan_args(argc, argv, "31", &l_cary, &r_cary, &op_id_val, &eps_val);
  op_id = (uint16_t) NUM2UINT(op_id_val);
  if ( argc >= 4 ) eps = NUM2DBL(eps_val);
  return rb_ca_bincmp_build(l_cary, r_cary, op_id, eps);
}

static VALUE
rb_ca_bincmp_op_id (VALUE self)
{
  CABinCmp *bc;
  TypedData_Get_Struct(self, CABinCmp, &cabincmp_data_type, bc);
  return UINT2NUM(bc->op_id);
}

static VALUE
rb_ca_bincmp_right (VALUE self)
{
  return rb_ivar_get(self, rb_intern("__bincmp_right__"));
}

static VALUE
rb_ca_bincmp_eps (VALUE self)
{
  CABinCmp *bc;
  TypedData_Get_Struct(self, CABinCmp, &cabincmp_data_type, bc);
  return rb_float_new(bc->eps);
}

static VALUE
rb_ca_bincmp_s_reset_scratch_counter (VALUE klass)
{
  (void) klass;
  ca_bincmp_scratch_acquire_count = 0;
  return Qnil;
}

static VALUE
rb_ca_bincmp_s_scratch_count (VALUE klass)
{
  (void) klass;
  return SIZE2NUM(ca_bincmp_scratch_acquire_count);
}

static VALUE
rb_ca_bincmp_s_reset_materialise_counter (VALUE klass)
{
  (void) klass;
  ca_bincmp_materialise_call_count = 0;
  return Qnil;
}

static VALUE
rb_ca_bincmp_s_materialise_count (VALUE klass)
{
  (void) klass;
  return SIZE2NUM(ca_bincmp_materialise_call_count);
}

static VALUE
rb_ca_bincmp_s_reset_leaf_inplace_counter (VALUE klass)
{
  (void) klass;
  ca_bincmp_leaf_inplace_count = 0;
  return Qnil;
}

static VALUE
rb_ca_bincmp_s_leaf_inplace_count (VALUE klass)
{
  (void) klass;
  return SIZE2NUM(ca_bincmp_leaf_inplace_count);
}

static VALUE
rb_ca_bincmp_s_allocate (VALUE klass)
{
  CABinCmp *ca;
  return TypedData_Make_Struct(klass, CABinCmp, &cabincmp_data_type, ca);
}

static VALUE
rb_ca_bincmp_initialize_copy (VALUE self, VALUE other)
{
  CABinCmp *ca, *cs;
  TypedData_Get_Struct(self,  CABinCmp, &cabincmp_data_type, ca);
  TypedData_Get_Struct(other, CABinCmp, &cabincmp_data_type, cs);
  if ( ca_func[CA_OBJ_BINCMP].pool_init ) {
    ca_array_pool_alloc(ca, CA_OBJ_BINCMP, cs->parent->ndim);
  }
  ca_bincmp_setup(ca, cs->parent, cs->right, cs->op_id, cs->eps);
  return self;
}

void
Init_ca_obj_bincmp (void)
{
  rb_cCABinCmp = rb_define_class("CABinCmp", rb_cCAView);

  ca_bincmp_func.struct_size = sizeof(CABinCmp);
  ca_bincmp_func.pool_bytes  = ca_bincmp_pool_bytes;
  ca_bincmp_func.pool_init   = ca_bincmp_pool_init;

  CA_OBJ_BINCMP = ca_install_obj_type(rb_cCABinCmp,
                                     &cabincmp_data_type,
                                     rb_cCArrayMask,
                                     &carray_mask_data_type, &ca_bincmp_func, sizeof(ca_bincmp_func));
  rb_define_const(rb_cObject, "CA_OBJ_BINCMP", INT2NUM(CA_OBJ_BINCMP));

  /* op_id constants shared with lib/carray/lazy.rb. */
  rb_define_const(rb_cCABinCmp, "OP_LT",       INT2NUM(CA_BINCMP_LT));
  rb_define_const(rb_cCABinCmp, "OP_GT",       INT2NUM(CA_BINCMP_GT));
  rb_define_const(rb_cCABinCmp, "OP_LE",       INT2NUM(CA_BINCMP_LE));
  rb_define_const(rb_cCABinCmp, "OP_GE",       INT2NUM(CA_BINCMP_GE));
  rb_define_const(rb_cCABinCmp, "OP_EQ",       INT2NUM(CA_BINCMP_EQ));
  rb_define_const(rb_cCABinCmp, "OP_NE",       INT2NUM(CA_BINCMP_NE));
  rb_define_const(rb_cCABinCmp, "OP_FEQ",      INT2NUM(CA_BINCMP_FEQ));
  rb_define_const(rb_cCABinCmp, "OP_IS_CLOSE", INT2NUM(CA_BINCMP_IS_CLOSE));
  rb_define_const(rb_cCABinCmp, "OP_IS_EQUIV", INT2NUM(CA_BINCMP_IS_EQUIV));

  rb_define_alloc_func(rb_cCABinCmp, rb_ca_bincmp_s_allocate);
  rb_define_method(rb_cCABinCmp, "initialize_copy",
                                rb_ca_bincmp_initialize_copy, 1);

  /* __build__(left, right, op_id [, eps]) */
  rb_define_singleton_method(rb_cCABinCmp, "__build__",
                             rb_ca_bincmp_s_build, -1);

  rb_define_method(rb_cCABinCmp, "__op_id__",     rb_ca_bincmp_op_id, 0);
  rb_define_method(rb_cCABinCmp, "__bincmp_right__",
                                  rb_ca_bincmp_right, 0);
  rb_define_method(rb_cCABinCmp, "__eps__",       rb_ca_bincmp_eps, 0);

  rb_define_singleton_method(rb_cCABinCmp, "__reset_scratch_counter__",
                             rb_ca_bincmp_s_reset_scratch_counter, 0);
  rb_define_singleton_method(rb_cCABinCmp, "__scratch_count__",
                             rb_ca_bincmp_s_scratch_count, 0);
  rb_define_singleton_method(rb_cCABinCmp, "__reset_materialise_counter__",
                             rb_ca_bincmp_s_reset_materialise_counter, 0);
  rb_define_singleton_method(rb_cCABinCmp, "__materialise_count__",
                             rb_ca_bincmp_s_materialise_count, 0);
  rb_define_singleton_method(rb_cCABinCmp, "__reset_leaf_inplace_counter__",
                             rb_ca_bincmp_s_reset_leaf_inplace_counter, 0);
  rb_define_singleton_method(rb_cCABinCmp, "__leaf_inplace_count__",
                             rb_ca_bincmp_s_leaf_inplace_count, 0);
}
