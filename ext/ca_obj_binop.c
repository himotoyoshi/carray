/* ---------------------------------------------------------------------------

  Lazy binadic element-wise arithmetic view: holds (left, right,
  op_id) and materialises the promoted result on attach.  Carries
  CA_FLAG_READ_ONLY; there is no bang path and `[]=` raises.

  Sibling of ca_obj_monop.c (unary arithmetic) and ca_obj_bincmp.c
  (comparison → boolean); dispatched by ca_binop_kernel_lookup_vv
  from ca_binop_dispatch.h.  Casts to the common data_type are
  inserted as CAMonOp nodes by the public builder before the
  CABinOp is constructed.

  xfer_stride model:
    1. Pull left into `data` (the output buffer).  Left and output
       share data_type (cast-before invariant), so this is safe as
       an in-place gather.
    2. Pull right into an arena scratch (per-node).
    3. Call the eager 1-D kernel with src1 == dst == data (in-place
       left) and src2 == scratch.

  Mask handling: non-trapping ops always pass m=NULL (SIMD fast
  path).  Trapping ops (integer DIV / MOD / QUO) build a per-slab
  mask from `left->mask | right->mask` when either operand has a
  mask, using the operand-side masks directly to avoid a
  create_mask ordering dependency on the output view.

  Cross-ndim promotion: intentional design rejection, not a
  deferred feature.  Implicit trailing-align (`(M, N) + (N,)` etc.)
  is permanently excluded; callers must reshape.

---------------------------------------------------------------------------- */

#include "carray.h"
#include "carray_internal.h"   /* ca_lazy_arena_* */
#include "ca_binop_dispatch.h"
#include "ca_monop_dispatch.h"  /* CA_MONOP_CAST_BASE */

/* carray_broadcast.c */
extern VALUE ca_broadcast_view (VALUE src, int8_t ndim,
                                ca_size_t *target_dim);

int8_t CA_OBJ_BINOP;
VALUE rb_cCABinOp;

/* CALazyMarker obj_type — collapse-on-consume marker checked by
   the public builder below. */
extern int8_t CA_OBJ_LAZY_MARKER;

/* Defined in carray_lazy.c: wrap a non-CArray Ruby value as a
   CScalar carrying the other operand's natural data_type. */
extern VALUE ca_lazy_wrap_scalar (VALUE other, CArray *self_ca);

/* ------------------------------------------------------------------- */
/* CABinOp struct                                                       */
/* ------------------------------------------------------------------- */

typedef struct CABinOp {
  int16_t   obj_type;
  int8_t    data_type;
  int8_t    ndim;
  int32_t   flags;
  ca_size_t bytes;
  ca_size_t elements;
  ca_size_t *dim;
  char     *ptr;
  CArray   *mask;
  char     *_pool;         /* framework-managed pool buffer (NULL = legacy ALLOC_N path). */
  CArray   *parent;       /* = left (so generic walk machinery treats
                             left as the primary parent for marker
                             collapse and attach lifecycle traversal) */
  uint32_t  attach;
  uint8_t   nosync;
  /* CABinOp-specific tail */
  CArray   *right;
  uint16_t  op_id;
  uint8_t   right_is_scalar;  /* 1 ⇒ right has elements == 1, walk
                                 with element-stride 0 (= broadcast) */
} CABinOp;

static size_t
ca_binop_dsize (const void *ap)
{
  const CABinOp *ca = (const CABinOp *) ap;
  return sizeof(CABinOp) + ca->ndim * sizeof(ca_size_t);
}

/* Pool framework hooks: single ndim-sized tail (dim) in the _pool
   buffer.  See ca_array_pool.c for the shared alloc/free discipline. */
static size_t
ca_binop_pool_bytes (int8_t ndim)
{
  ca_size_t n = (ndim > 0) ? ndim : 1;
  return (size_t) n * sizeof(ca_size_t);
}

static void
ca_binop_pool_init (void *ap, int8_t ndim)
{
  CABinOp *ca = (CABinOp *) ap;
  ca->dim = (ca_size_t *) ca->_pool;
}

const rb_data_type_t cabinop_data_type = {
    .parent = &caview_data_type,
    .wrap_struct_name = "CABinOp",
    .function = {
        .dmark = ca_mark,
        .dfree = ca_free,
        .dsize = ca_binop_dsize,
        .dcompact = NULL
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

/* ------------------------------------------------------------------- */
/* setup / new / free                                                   */
/* ------------------------------------------------------------------- */

static int
ca_binop_setup (CABinOp *ca, CArray *left, CArray *right, uint16_t op_id)
{
  int8_t out_dt = ca_lazy_promote_binop(op_id, left->data_type,
                                                right->data_type);
  ca_size_t out_bytes = ca_sizeof[out_dt];

  ca->obj_type  = CA_OBJ_BINOP;
  ca->data_type = out_dt;
  ca->flags     = CA_FLAG_READ_ONLY;
  ca->ndim      = left->ndim;
  ca->bytes     = out_bytes;
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
  /* right_is_scalar fast path: when right holds a single element,
     xfer_stride pulls only that cell into scratch and walks the
     kernel with element-stride 0 (broadcast).  The symmetric
     left_is_scalar case is currently handled by wrapping left in
     a broadcast view of right's shape (correct but slower). */
  ca->right_is_scalar = ( right->elements == 1 && left->elements > 1 ) ? 1 : 0;

  memcpy(ca->dim, left->dim, left->ndim * sizeof(ca_size_t));

  if ( ca_has_mask(left) || ca_has_mask(right) ) {
    ca_create_mask(ca);
  }

  if ( ca_is_scalar(left) && ca_is_scalar(right) ) {
    ca_set_flag(ca, CA_FLAG_SCALAR);
  }

  return 0;
}

CABinOp *
ca_binop_new (CArray *left, CArray *right, uint16_t op_id)
{
  CABinOp *ca = (CABinOp *) ca_array_alloc(CA_OBJ_BINOP, left->ndim);
  ca_binop_setup(ca, left, right, op_id);
  return ca;
}

static void
free_ca_binop (void *ap)
{
  CABinOp *ca = (CABinOp *) ap;
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

static void ca_binop_func_xfer_stride (void *ap, ca_size_t *starts,
                                       ca_size_t *counts, ca_size_t *strides,
                                       void *data, int dir);

static void *
ca_binop_func_clone (void *ap)
{
  CABinOp *ca = (CABinOp *) ap;
  return ca_binop_new(ca->parent, ca->right, ca->op_id);
}

/* Per-cell get: dispatched through the same xfer_stride machinery
   with counts == 1 on every axis.  Not the hot path — a hot loop
   should call `.to_ca` and read the entity directly. */
static void
ca_binop_func_xfer_index (void *ap, ca_size_t *idx, void *data, int dir)
{
  CABinOp *ca = (CABinOp *) ap;
  ca_size_t starts[CA_RANK_MAX];
  ca_size_t counts[CA_RANK_MAX];
  ca_size_t strides[CA_RANK_MAX];
  int8_t    k;
  ca_size_t s;

  if ( dir != CA_XFER_GET ) {
    rb_raise(rb_eRuntimeError, "CABinOp is read-only (xfer_index PUT)");
  }

  s = ca->bytes;
  for ( k = ca->ndim - 1; k >= 0; k-- ) {
    starts[k]  = idx[k];
    counts[k]  = 1;
    strides[k] = s;
  }
  ca_binop_func_xfer_stride(ca, starts, counts, strides, data, CA_XFER_GET);
}

static void
ca_binop_func_xfer_addrs (void *ap, ca_size_t n, ca_size_t *addrs,
                          void *data, int dir)
{
  CABinOp *ca = (CABinOp *) ap;
  ca_size_t i;
  char *out = (char *) data;

  if ( dir != CA_XFER_GET ) {
    rb_raise(rb_eRuntimeError, "CABinOp is read-only (xfer_addrs PUT)");
  }

  for ( i = 0; i < n; i++ ) {
    ca_size_t idx[CA_RANK_MAX];
    ca_addr2index((CArray *)ca, addrs[i], idx);
    ca_binop_func_xfer_index(ca, idx, out + i * ca->bytes, CA_XFER_GET);
  }
}

/* Test / observability counters bumped from the xfer_stride hot
   path so specs can assert scratch acquisition (one per node,
   independent of left-chain depth) and materialise vs
   non-materialise behaviour without attaching the view. */
ca_size_t ca_binop_scratch_acquire_count = 0;
ca_size_t ca_binop_materialise_call_count = 0;

static void
ca_binop_func_xfer_stride (void *ap, ca_size_t *starts, ca_size_t *counts,
                            ca_size_t *strides, void *data, int dir)
{
  CABinOp *bo = (CABinOp *) ap;
  ca_size_t slab_n;
  int8_t    k;
  void     *scratch;
  volatile VALUE holder;
  ca_size_t right_bytes;
  ca_size_t right_step;            /* element-stride for the kernel walk */

  if ( dir != CA_XFER_GET ) {
    rb_raise(rb_eRuntimeError, "CABinOp is read-only (xfer_stride PUT)");
  }
  ca_binop_materialise_call_count++;

  slab_n = 1;
  for ( k = 0; k < bo->ndim; k++ ) slab_n *= counts[k];

  /* === 1. Pull left into the output buffer ===
     CAREFUL: left.data_type == output.data_type by the cast-before
     invariant, so the caller's `strides` (output byte layout) is
     also valid for left.  A mismatch would silently write past the
     output row. */
  ca_xfer_stride(bo->parent, starts, counts, strides, data, CA_XFER_GET);

  /* === 2. Pull right into an arena scratch === */
  right_bytes = bo->right->bytes;
  (void) holder;  /* Kept for stack-shape compatibility with the
                     surrounding code; arena replaces the ALLOCV. */
  if ( bo->right_is_scalar ) {
    /* CScalar-shaped right: pull exactly 1 element and walk it in
       the kernel with element-stride 0. */
    ca_size_t one_starts[CA_RANK_MAX] = {0};
    ca_size_t one_counts[CA_RANK_MAX];
    ca_size_t one_strides[CA_RANK_MAX];
    for ( k = 0; k < bo->right->ndim; k++ ) {
      one_counts[k]  = 1;
      one_strides[k] = right_bytes;
    }
    scratch = ca_lazy_arena_acquire(right_bytes);
    ca_binop_scratch_acquire_count++;
    ca_xfer_stride(bo->right, one_starts, one_counts, one_strides,
                   scratch, CA_XFER_GET);
    right_step = 0;
  }
  else {
    /* Same-shape right.  Pull with the same byte layout the caller
       requested for the output; right.bytes matches output.bytes
       because right.data_type == out.data_type by cast-before. */
    ca_size_t right_strides[CA_RANK_MAX];
    ca_size_t s = right_bytes;
    for ( k = bo->ndim - 1; k >= 0; k-- ) {
      right_strides[k] = s;
      s *= counts[k];
    }
    scratch = ca_lazy_arena_acquire(slab_n * right_bytes);
    ca_binop_scratch_acquire_count++;
    ca_xfer_stride(bo->right, starts, counts, right_strides, scratch,
                   CA_XFER_GET);
    right_step = 1;
  }

  /* === 3. Apply the kernel: data (src1 == dst) op scratch (src2) → data ===
   *
   * Kernel signature (ext/carray.h):
   *   fn(n, m, ptr1=src1, i1, ptr2=src2, i2, ptr3=dst, i3)
   *
   * Mask handling:
   *   - non-trapping op → m = NULL (SIMD fast path; garbage compute
   *     on masked cells is allowed).
   *   - trapping op with any operand mask → build a per-slab OR
   *     mask from the operand-side masks.
   *
   * CAREFUL: the trapping-op mask is built from left.mask and
   * right.mask directly, NOT from out->mask.  The output's mask
   * comes from create_mask (called separately on view
   * construction), and reading it here would introduce an
   * ordering dependency that reversed the invariant "the mask is
   * always available before kernels run".
   *
   * CAREFUL: ptr1 == ptr3 == data (in-place left) is safe because
   * each cell reads src1, reads src2, and writes dst atomically
   * before the loop advances. */
  {
    boolean8_t *slab_mask = NULL;
    void *mscratch = NULL;
    volatile VALUE mholder = Qnil;
    int is_trapping = ca_binop_is_trapping(bo->op_id, bo->data_type);

    if ( is_trapping && ( ca_has_mask(bo->parent) ||
                          ca_has_mask(bo->right) ) ) {
      /* Build a slab-shaped mask = left.slab_mask | right.slab_mask.
         Pull each operand's mask (or fill with 0 if absent) into the
         output-shaped layout, then OR them in place.                */
      ca_size_t k_;
      ca_size_t right_mask_strides[CA_RANK_MAX];
      (void) mholder;  /* Kept for stack-shape compatibility; arena
                          replaces the ALLOCV path here. */

      mscratch = ca_lazy_arena_acquire(slab_n);
      slab_mask = (boolean8_t *) mscratch;

      if ( ca_has_mask(bo->parent) ) {
        ca_size_t mstrides[CA_RANK_MAX];
        ca_size_t s = 1;
        for ( k_ = bo->ndim - 1; k_ >= 0; k_-- ) {
          mstrides[k_] = s; s *= counts[k_];
        }
        ca_xfer_stride(bo->parent->mask, starts, counts, mstrides,
                       slab_mask, CA_XFER_GET);
      }
      else {
        memset(slab_mask, 0, slab_n);
      }

      if ( ca_has_mask(bo->right) ) {
        boolean8_t *rm = NULL;
        ca_size_t i_;
        if ( bo->right_is_scalar ) {
          /* CScalar right: pull the single mask bit and broadcast OR. */
          ca_size_t one_starts[CA_RANK_MAX] = {0};
          ca_size_t one_counts[CA_RANK_MAX];
          ca_size_t one_strides[CA_RANK_MAX];
          boolean8_t one_bit = 0;
          for ( k_ = 0; k_ < bo->right->ndim; k_++ ) {
            one_counts[k_]  = 1;
            one_strides[k_] = 1;
          }
          ca_xfer_stride(bo->right->mask, one_starts, one_counts,
                         one_strides, &one_bit, CA_XFER_GET);
          if ( one_bit ) {
            for ( i_ = 0; i_ < slab_n; i_++ ) slab_mask[i_] = 1;
          }
        }
        else {
          ca_size_t s = 1;
          for ( k_ = bo->ndim - 1; k_ >= 0; k_-- ) {
            right_mask_strides[k_] = s; s *= counts[k_];
          }
          /* Small mask-scratch for right; OR into slab_mask in
             place to avoid a persistent second buffer. */
          rm = (boolean8_t *) ALLOCA_N(boolean8_t, slab_n);
          ca_xfer_stride(bo->right->mask, starts, counts,
                         right_mask_strides, rm, CA_XFER_GET);
          for ( i_ = 0; i_ < slab_n; i_++ ) slab_mask[i_] |= rm[i_];
        }
      }
    }

    ca_binop_func_t fn = ca_binop_kernel_lookup_vv(bo->op_id, bo->data_type);
    if ( fn == NULL ) {
      if ( mscratch ) ca_lazy_arena_release(mscratch);
      ca_lazy_arena_release(scratch);
      rb_raise(rb_eNotImpError,
               "CABinOp: kernel not implemented (op_id=%u data_type=%d)",
               (unsigned) bo->op_id, (int) bo->data_type);
    }
    fn(slab_n, slab_mask,
       (char *)data,    1,             /* src1 == dst (left, in-place) */
       (char *)scratch, right_step,    /* src2 (right) */
       (char *)data,    1);            /* dst */

    if ( mscratch ) ca_lazy_arena_release(mscratch);
  }

  ca_lazy_arena_release(scratch);
}

static void
ca_binop_func_xfer_all (void *ap, void *data, int dir)
{
  CABinOp *ca = (CABinOp *) ap;
  ca_size_t starts[CA_RANK_MAX];
  ca_size_t native[CA_RANK_MAX];
  int8_t    k;
  ca_size_t s = ca->bytes;
  for ( k = ca->ndim - 1; k >= 0; k-- ) { native[k] = s; s *= ca->dim[k]; }
  for ( k = 0; k < ca->ndim; k++ ) starts[k] = 0;
  ca_xfer_stride(ca, starts, ca->dim, native, data, dir);
}

static void
ca_binop_func_allocate (void *ap)
{
  CABinOp *ca = (CABinOp *) ap;
  ca->ptr = xmalloc(ca_length(ca));
}

static void
ca_binop_func_attach (void *ap)
{
  /* CAREFUL: call the view-specific xfer_stride directly here,
     not the public ca_xfer_stride dispatcher.  The dispatcher's
     self-memcpy fast path detects data == ca->ptr and returns
     without materialising, so the freshly-allocated buffer would
     still hold garbage. */
  CABinOp *ca = (CABinOp *) ap;
  ca_size_t starts[CA_RANK_MAX];
  ca_size_t native[CA_RANK_MAX];
  int8_t    k;
  ca_size_t s;

  ca->ptr = xmalloc(ca_length(ca));

  s = ca->bytes;
  for ( k = ca->ndim - 1; k >= 0; k-- ) { native[k] = s; s *= ca->dim[k]; }
  for ( k = 0; k < ca->ndim; k++ ) starts[k] = 0;
  ca_binop_func_xfer_stride(ca, starts, ca->dim, native, ca->ptr, CA_XFER_GET);
}

static void
ca_binop_func_sync (void *ap)
{
  /* read-only */
}

static void
ca_binop_func_detach (void *ap)
{
  CABinOp *ca = (CABinOp *) ap;
  xfree(ca->ptr);
  ca->ptr = NULL;
}

NORETURN(static void ca_binop_func_fill_data (void *ap, void *ptr));
static void
ca_binop_func_fill_data (void *ap, void *ptr)
{
  rb_raise(rb_eRuntimeError, "CABinOp is read-only (fill_data)");
}

/* Build out.mask.  When either parent has a mask, materialise a
   freshly-allocated boolean8_t buffer.  For most ops this is the blind
   OR `left.mask | right.mask`.

   Boolean AND / OR are three-valued (Kleene): a masked cell is resolved by
   the *known* side (`unknown | true = true`, `unknown & false = false`), so
   it is NOT masked in the result.  This needs operand VALUES, not just
   masks, so both operands are attached; the blind value the value kernel
   later writes is already correct on a resolved cell because the absorbing
   element (true for OR, false for AND) dominates whatever garbage sits on
   the masked side.  Nested trees compose: an inner boolean `&`/`|` node's
   mask is already Kleene-resolved by the time an outer node reads it.

   Not memory-optimal (a CARepeat-like view would share pages), but correct
   and decoupled from xfer_stride ordering. */
static void
ca_binop_func_create_mask (void *ap)
{
  CABinOp *bo = (CABinOp *) ap;
  CArray *l = bo->parent;
  CArray *r = bo->right;
  boolean8_t *dst;
  ca_size_t i, n;
  int has_l, has_r, kleene, need_l, need_r, is_or;
  boolean8_t *lm, *rm, *lv, *rv;

  has_l = ca_has_mask(l);
  has_r = ca_has_mask(r);
  if ( ! has_l && ! has_r ) return;

  kleene = ( bo->data_type == CA_BOOLEAN &&
             ( bo->op_id == CA_BINOP_BIT_AND || bo->op_id == CA_BINOP_BIT_OR ) );
  is_or  = ( bo->op_id == CA_BINOP_BIT_OR );

  bo->mask = (CArray *) carray_new(CA_BOOLEAN, bo->ndim, bo->dim, 0, NULL);
  dst = (boolean8_t *) bo->mask->ptr;
  n = bo->elements;

  /* Kleene needs operand values even where an operand is unmasked. */
  need_l = has_l || kleene;
  need_r = has_r || kleene;
  if ( need_l ) ca_attach(l);
  if ( need_r ) ca_attach(r);

  lm = has_l ? (boolean8_t *) l->mask->ptr : NULL;
  rm = has_r ? (boolean8_t *) r->mask->ptr : NULL;
  lv = kleene ? (boolean8_t *) l->ptr : NULL;
  rv = kleene ? (boolean8_t *) r->ptr : NULL;

  for ( i = 0; i < n; i++ ) {
    /* right broadcast: repeat element 0 when right was a scalar. */
    ca_size_t ri = bo->right_is_scalar ? 0 : i;
    boolean8_t am = lm ? lm[i]  : 0;
    boolean8_t bm = rm ? rm[ri] : 0;
    boolean8_t m  = (boolean8_t)( am | bm );
    if ( kleene && m ) {
      boolean8_t av = lv[i], bv = rv[ri];
      if ( is_or ) {
        if ( ( ! am && av ) || ( ! bm && bv ) ) m = 0;      /* known TRUE */
      }
      else {
        if ( ( ! am && ! av ) || ( ! bm && ! bv ) ) m = 0;  /* known FALSE */
      }
    }
    dst[i] = m;
  }

  if ( need_l ) ca_detach(l);
  if ( need_r ) ca_detach(r);
}

ca_operation_function_t ca_binop_func = {
  -1, /* CA_OBJ_BINOP, set at install time */
  CA_VIEW_ARRAY,
  free_ca_binop,
  ca_binop_func_clone,
  ca_binop_func_allocate,
  ca_binop_func_attach,
  ca_binop_func_sync,
  ca_binop_func_detach,
  ca_binop_func_fill_data,
  ca_binop_func_create_mask,
  ca_binop_func_xfer_index,
  ca_binop_func_xfer_addrs,
  NULL,                       /* fold_stride: never fold — op boundary */
  ca_binop_func_xfer_stride,
  ca_binop_func_xfer_all,
};

/* ------------------------------------------------------------------- */
/* Public builder (= lib/carray/lazy.rb dispatch entry)                 */
/* ------------------------------------------------------------------- */

/* Marker collapse helper: if cary wraps a CALazyMarker, replace with
   the marker's stored Ruby parent so the marker does not appear in
   the constructed CABinOp tree.                                       */
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

/* Low-level constructor: wraps l_cary (left) and r_cary (right)
   into a CABinOp.  Does NOT insert cast nodes; the caller must
   have promoted both operands to the common data_type. */
static VALUE
rb_ca_binop_new (VALUE l_cary, VALUE r_cary, uint16_t op_id)
{
  volatile VALUE obj;
  CArray *l, *r;
  CABinOp *ca;
  rb_check_carray_object(l_cary);
  rb_check_carray_object(r_cary);
  TypedData_Get_Struct(l_cary, CArray, &carray_data_type, l);
  TypedData_Get_Struct(r_cary, CArray, &carray_data_type, r);
  ca  = ca_binop_new(l, r, op_id);
  obj = ca_wrap_struct(ca);
  rb_ca_set_parent(obj, l_cary);
  /* Pin right via an ivar so GC keeps it alive.  parent slot already
     pins left.  */
  rb_ivar_set(obj, rb_intern("__binop_right__"), r_cary);
  return obj;
}

/* Public builder: build a CABinOp tree node for op_id over
   (l_cary, r_cary).  Inserts cast nodes when either operand's
   data_type differs from the common data_type, then resolves
   same-ndim size-1 broadcast via ca_broadcast_pair.  The cast
   nodes are inserted BEFORE broadcast so the cast acts on the
   smallest possible element count.

   Broadcast scope (bound-dimension only):
     same shape         → no-op
     same ndim + size-1 → ca_broadcast_pair wraps the size-1 axis
                          operand in a stride-0 CAStride
     CScalar vs array   → xfer_stride walks with element_step = 0
     different ndim     → ArgumentError

   CAREFUL: the different-ndim raise is an intentional design
   rejection, not a deferred feature.  Implicit cross-ndim
   promotion (`(M, N) + (N,)` etc.) is permanently excluded from
   CArray; callers must reshape explicitly.  The eager CArray path
   enforces the same rule, and re-introducing a silent
   trailing-align here would diverge the lazy path from it. */
VALUE
rb_ca_binop_build (VALUE l_cary, VALUE r_cary, uint16_t op_id)
{
  CArray *l, *r;
  int8_t  l_in_dt, r_in_dt;
  volatile VALUE l_resolved, r_resolved;

  /* Collapse markers on both sides. */
  l_resolved = collapse_marker(l_cary);
  r_resolved = collapse_marker(r_cary);

  /* Promote a non-CArray Ruby value to a CScalar carrying the
     other side's natural data_type. */
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

  /* === Step 1: insert cast nodes.  Applied to each operand before
     broadcast so the cast acts on the smallest element count. */
  ca_binop_kernel_input_data_types(op_id, l->data_type, r->data_type,
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

  /* === Step 2: broadcast via ca_broadcast_pair (same-ndim size-1
     expansion).  No-op when shapes already match or either operand
     is scalar; also a no-op for incompatible shapes, which the
     final elements-mismatch check below catches. */
  ca_broadcast_pair(&l_resolved, &r_resolved);
  TypedData_Get_Struct(l_resolved, CArray, &carray_data_type, l);
  TypedData_Get_Struct(r_resolved, CArray, &carray_data_type, r);

  /* === Step 3: shape sanity.  After broadcast_pair, accept:
       (a) equal elements (matched shape, common case),
       (b) right is a 1-element CScalar (xfer_stride uses
           element_step = 0),
       (c) left is a 1-element CScalar — swap operands when the
           op commutes (ADD / MUL / BIT_*).  Non-commutative +
           left scalar wraps left in a broadcast view of right's
           shape so the kernel sees matched shapes; cost is N
           reads of the scalar cell with stride 0. */
  if ( l->elements != r->elements ) {
    if ( r->elements == 1 && l->elements > 1 ) {
      /* CScalar-vs-array, right.  xfer_stride handles this with
         right_step = 0. */
    }
    else if ( l->elements == 1 && r->elements > 1 ) {
      int commutes = ( op_id == CA_BINOP_ADD     ||
                       op_id == CA_BINOP_MUL     ||
                       op_id == CA_BINOP_BIT_AND ||
                       op_id == CA_BINOP_BIT_OR  ||
                       op_id == CA_BINOP_BIT_XOR );
      if ( commutes ) {
        VALUE tmp = l_resolved; l_resolved = r_resolved; r_resolved = tmp;
      }
      else {
        /* Non-commutative + left scalar: broadcast the left operand
           (CScalar with ndim=1 dim=[1]) up to right's shape.
           ca_repeat_setup signature:
             count[i] > 0  → repeat (stride-0) axis of size count[i]
             count[i] == 0 → data axis (inherits from parent)
           Total data axes must equal parent->ndim.
           For lifting a CScalar (parent.ndim=1, dim=[1]) to right's
           ndim N: count = {1, 1, ..., 1, 0} (N-1 leading dummy 1s,
           1 trailing data axis), then broadcast that (1,1,...,1)
           shape to right's dim via ca_broadcast_view.                */
        ca_size_t count[CA_RANK_MAX];
        int8_t k;
        if ( r->ndim > l->ndim ) {
          for ( k = 0; k < r->ndim - 1; k++ ) count[k] = 1;  /* dummy */
          count[r->ndim - 1] = 0;                            /* data  */
          l_resolved = rb_ca_repeat_new(l_resolved, r->ndim, count);
          TypedData_Get_Struct(l_resolved, CArray, &carray_data_type, l);
        }
        l_resolved = ca_broadcast_view(l_resolved, r->ndim, r->dim);
        TypedData_Get_Struct(l_resolved, CArray, &carray_data_type, l);
      }
    }
    else {
      /* Cross-ndim or otherwise incompatible shapes; see the
         builder header comment for why CArray rejects implicit
         cross-ndim promotion. */
      rb_raise(rb_eArgError,
               "CABinOp: shape mismatch (%lld vs %lld) — only same-"
               "ndim size-1 broadcast is supported; cross-ndim "
               "promotion is not adopted in CArray "
               "(reshape explicitly)",
               (long long) l->elements, (long long) r->elements);
    }
  }

  return rb_ca_binop_new(l_resolved, r_resolved, op_id);
}

static VALUE
rb_ca_binop_s_build (VALUE klass, VALUE l_cary, VALUE r_cary, VALUE op_id_val)
{
  uint16_t op_id = (uint16_t) NUM2UINT(op_id_val);
  (void) klass;
  return rb_ca_binop_build(l_cary, r_cary, op_id);
}

/* op_id accessor for inspect / dump_tree consumers in Ruby. */
static VALUE
rb_ca_binop_op_id (VALUE self)
{
  CABinOp *bo;
  TypedData_Get_Struct(self, CABinOp, &cabinop_data_type, bo);
  return UINT2NUM(bo->op_id);
}

/* Right-operand accessor — needed by inspect / dump_tree because
   the right reference lives off the prefix and is not reachable
   via .parent. */
static VALUE
rb_ca_binop_right (VALUE self)
{
  return rb_ivar_get(self, rb_intern("__binop_right__"));
}

/* Test instrumentation (mirrors CAMonOp counters). */
static VALUE
rb_ca_binop_s_reset_scratch_counter (VALUE klass)
{
  ca_binop_scratch_acquire_count = 0;
  return Qnil;
}

static VALUE
rb_ca_binop_s_scratch_count (VALUE klass)
{
  return SIZE2NUM(ca_binop_scratch_acquire_count);
}

static VALUE
rb_ca_binop_s_reset_materialise_counter (VALUE klass)
{
  ca_binop_materialise_call_count = 0;
  return Qnil;
}

static VALUE
rb_ca_binop_s_materialise_count (VALUE klass)
{
  return SIZE2NUM(ca_binop_materialise_call_count);
}

static VALUE
rb_ca_binop_s_allocate (VALUE klass)
{
  CABinOp *ca;
  return TypedData_Make_Struct(klass, CABinOp, &cabinop_data_type, ca);
}

static VALUE
rb_ca_binop_initialize_copy (VALUE self, VALUE other)
{
  CABinOp *ca, *cs;
  TypedData_Get_Struct(self,  CABinOp, &cabinop_data_type, ca);
  TypedData_Get_Struct(other, CABinOp, &cabinop_data_type, cs);
  if ( ca_func[CA_OBJ_BINOP].pool_init ) {
    ca_array_pool_alloc(ca, CA_OBJ_BINOP, cs->parent->ndim);
  }
  ca_binop_setup(ca, cs->parent, cs->right, cs->op_id);
  return self;
}

void
Init_ca_obj_binop (void)
{
  rb_cCABinOp = rb_define_class("CABinOp", rb_cCAView);

  ca_binop_func.struct_size = sizeof(CABinOp);
  ca_binop_func.pool_bytes  = ca_binop_pool_bytes;
  ca_binop_func.pool_init   = ca_binop_pool_init;

  CA_OBJ_BINOP = ca_install_obj_type(rb_cCABinOp,
                                     &cabinop_data_type,
                                     rb_cCArrayMask,
                                     &carray_mask_data_type, &ca_binop_func, sizeof(ca_binop_func));
  rb_define_const(rb_cObject, "CA_OBJ_BINOP", INT2NUM(CA_OBJ_BINOP));

  /* op_id constants shared with lib/carray/lazy.rb. */
  rb_define_const(rb_cCABinOp, "OP_ADD",        INT2NUM(CA_BINOP_ADD));
  rb_define_const(rb_cCABinOp, "OP_SUB",        INT2NUM(CA_BINOP_SUB));
  rb_define_const(rb_cCABinOp, "OP_MUL",        INT2NUM(CA_BINOP_MUL));
  rb_define_const(rb_cCABinOp, "OP_DIV",        INT2NUM(CA_BINOP_DIV));
  rb_define_const(rb_cCABinOp, "OP_POW",        INT2NUM(CA_BINOP_POW));
  rb_define_const(rb_cCABinOp, "OP_BIT_AND",    INT2NUM(CA_BINOP_BIT_AND));
  rb_define_const(rb_cCABinOp, "OP_BIT_OR",     INT2NUM(CA_BINOP_BIT_OR));
  rb_define_const(rb_cCABinOp, "OP_BIT_XOR",    INT2NUM(CA_BINOP_BIT_XOR));
  rb_define_const(rb_cCABinOp, "OP_BIT_LSHIFT", INT2NUM(CA_BINOP_BIT_LSHIFT));
  rb_define_const(rb_cCABinOp, "OP_BIT_RSHIFT", INT2NUM(CA_BINOP_BIT_RSHIFT));
  rb_define_const(rb_cCABinOp, "OP_MOD",        INT2NUM(CA_BINOP_MOD));
  rb_define_const(rb_cCABinOp, "OP_QUO",        INT2NUM(CA_BINOP_QUO));
  rb_define_const(rb_cCABinOp, "OP_RCP_MUL",    INT2NUM(CA_BINOP_RCP_MUL));
  rb_define_const(rb_cCABinOp, "OP_IPOWER",     INT2NUM(CA_BINOP_IPOWER));
  rb_define_const(rb_cCABinOp, "OP_COPYSIGN",   INT2NUM(CA_BINOP_COPYSIGN));
  rb_define_const(rb_cCABinOp, "OP_LOGADDEXP",  INT2NUM(CA_BINOP_LOGADDEXP));
  rb_define_const(rb_cCABinOp, "OP_NEXTAFTER",  INT2NUM(CA_BINOP_NEXTAFTER));
  rb_define_const(rb_cCABinOp, "OP_FMOD",       INT2NUM(CA_BINOP_FMOD));
  rb_define_const(rb_cCABinOp, "OP_ATAN2",      INT2NUM(CA_BINOP_ATAN2));
  rb_define_const(rb_cCABinOp, "OP_HYPOT",      INT2NUM(CA_BINOP_HYPOT));
  rb_define_const(rb_cCABinOp, "OP_PMAX",       INT2NUM(CA_BINOP_PMAX));
  rb_define_const(rb_cCABinOp, "OP_PMIN",       INT2NUM(CA_BINOP_PMIN));
  rb_define_const(rb_cCABinOp, "OP_MAXIMUM",    INT2NUM(CA_BINOP_MAXIMUM));
  rb_define_const(rb_cCABinOp, "OP_MINIMUM",    INT2NUM(CA_BINOP_MINIMUM));
  rb_define_const(rb_cCABinOp, "OP_AND",        INT2NUM(CA_BINOP_AND));
  rb_define_const(rb_cCABinOp, "OP_OR",         INT2NUM(CA_BINOP_OR));
  rb_define_const(rb_cCABinOp, "OP_XOR",        INT2NUM(CA_BINOP_XOR));

  rb_define_alloc_func(rb_cCABinOp, rb_ca_binop_s_allocate);
  rb_define_method(rb_cCABinOp, "initialize_copy",
                                rb_ca_binop_initialize_copy, 1);

  rb_define_singleton_method(rb_cCABinOp, "__build__",
                             rb_ca_binop_s_build, 3);

  rb_define_method(rb_cCABinOp, "__op_id__",
                                rb_ca_binop_op_id, 0);
  rb_define_method(rb_cCABinOp, "__binop_right__",
                                rb_ca_binop_right, 0);

  /* Test instrumentation, not user-facing. */
  rb_define_singleton_method(rb_cCABinOp, "__reset_scratch_counter__",
                             rb_ca_binop_s_reset_scratch_counter, 0);
  rb_define_singleton_method(rb_cCABinOp, "__scratch_count__",
                             rb_ca_binop_s_scratch_count, 0);
  rb_define_singleton_method(rb_cCABinOp, "__reset_materialise_counter__",
                             rb_ca_binop_s_reset_materialise_counter, 0);
  rb_define_singleton_method(rb_cCABinOp, "__materialise_count__",
                             rb_ca_binop_s_materialise_count, 0);
}
