/* ---------------------------------------------------------------------------

  Lazy monadic element-wise op view (CAMonOp).  Holds (parent, op_id,
  output_data_type).  Carries `CA_FLAG_READ_ONLY`; `[]=` raises, except
  the writable cast / byte_swap op_ids.

  ## In-place chain evaluation

  When materialising a chain `a.lazy.f.g.h.to_ca`, the xfer_stride does:

  1. iterative chain collect: walk this->parent->...->parent until a
     non-CAMonOp leaf is found, recording op_ids bottom-up
  2. pull leaf into the output buffer (= `data`) via ca_xfer_stride —
     or, when a cast node is at the innermost position (cast-before),
     pull into a small leaf-data_type scratch and ca_cast_block into output
  3. apply remaining ops in reverse order, in-place on `data` (=
     ptr1==ptr2==data, i1==i2==1)

  Chain-intermediate scratch count = 0, depth-independent.  At most one
  leaf-scratch (for the cast input) when a widening cast is required;
  this is also depth-independent.  monop is element-local, so in-place
  is safe; masked cells may be computed but are unobservable (mask
  propagates on a separate channel).

  ## Scope

  - 34 ops via dispatch table (`ext/ca_monop_dispatch.c`)
  - Cast nodes for widening monfunc on an integer parent (cast-before)
  - Per-(op, data_type) byte parity with the eager path

---------------------------------------------------------------------------- */

#include "carray.h"
#include "carray_internal.h"   /* ca_lazy_arena_*, ca_is_lazy_view */
#include "ca_monop_dispatch.h"

/* ca_cast_block (carray_cast.c) */
extern void ca_cast_block (ca_size_t n, void *ap1, void *ptr1,
                           void *ap2, void *ptr2);

/* byte_swap buffer-level helper (ext/ca_obj_byte_swap.c).  Handles CMPLX
   half-independent swap (CMPLX64 = 4-byte halves, CMPLX128 = 8-byte
   halves); other data_types = ca_swap_bytes(buf, bytes, elements).
   CA_FIXLEN+data_class is excluded. */
extern void ca_byte_swap_buffer (int8_t data_type, ca_size_t bytes,
                                  ca_size_t elements, char *buf);

/* ------------------------------------------------------------------- */
/* CAMonOp struct                                                       */
/* ------------------------------------------------------------------- */

int8_t CA_OBJ_MONOP;
VALUE rb_cCAMonOp;

/* Defined in ext/carray_lazy.c — needed for collapse-on-consume and
   chain-walk leaf detection.  */
extern int8_t CA_OBJ_LAZY_MARKER;

/* CABinOp / CABinCmp / CAMonCmp obj_type forward decls (defined in
   ext/ca_obj_*.c).  Used by ca_monop_view_is_single_cast to recognise
   lazy parents.  (Re-externed at the end of this file; a duplicate decl
   is safe.)  */
extern int8_t CA_OBJ_BINOP;
extern int8_t CA_OBJ_BINCMP;
extern int8_t CA_OBJ_MONCMP;

typedef struct CAMonOp {
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
  CArray   *parent;
  uint32_t  attach;
  uint8_t   nosync;
  /* CAMonOp-specific tail */
  uint16_t  op_id;
  /* data_class snapshot for cast op_id paths that need data_class
     metadata propagation (e.g. `as_type(MyStruct)` CA_FIXLEN + data_class
     field-recursive operations).  Stays Qnil for the non-cast or
     no-data_class case; mirrors the CAByteSwap pattern.  */
  VALUE     data_class;
} CAMonOp;

static size_t
ca_monop_dsize (const void *ap)
{
  const CAMonOp *ca = (const CAMonOp *) ap;
  return sizeof(CAMonOp) + ca->ndim * sizeof(ca_size_t);
}

/* Pool framework hooks: single ndim-sized tail (dim) in the _pool buffer
   (uniform alloc/free discipline). */
static size_t
ca_monop_pool_bytes (int8_t ndim)
{
  ca_size_t n = (ndim > 0) ? ndim : 1;
  return (size_t) n * sizeof(ca_size_t);
}

static void
ca_monop_pool_init (void *ap, int8_t ndim)
{
  CAMonOp *ca = (CAMonOp *) ap;
  ca->dim = (ca_size_t *) ca->_pool;
}

/* Custom dmark: mark the prefix (= parent ivar + mask + standard CArray
   VALUE refs) AND the tail data_class VALUE.  Mirrors ca_byte_swap_mark. */
static void
ca_monop_mark (void *ap)
{
  CAMonOp *ca = (CAMonOp *) ap;
  ca_mark(ca);                  /* prefix */
  rb_gc_mark(ca->data_class);   /* tail VALUE */
}

const rb_data_type_t camonop_data_type = {
    .parent = &caview_data_type,
    .wrap_struct_name = "CAMonOp",
    .function = {
        .dmark = ca_monop_mark,
        .dfree = ca_free,
        .dsize = ca_monop_dsize,
        .dcompact = NULL
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

/* ------------------------------------------------------------------- */
/* single-cast discrimination helper                                    */
/* ------------------------------------------------------------------- */

/* See ca_monop_dispatch.h for contract.  Returns 1 iff `view` is a
   CAMonOp instance whose op_id is a cast op AND whose parent is not also
   a CAMonOp (= single-node cast view, the structural successor of CAFake).
   This is the discrimination predicate used by ca_kernel_iterator's
   per-fiber fused gate to keep the transform-fused fast path live for
   single-cast views while chain CAMonOp (= depth >= 2) continues through
   the chain materialise path.  */
int
ca_monop_view_is_single_cast (CArray *view)
{
  CAMonOp *m;
  CArray *p;
  if ( view == NULL || view->obj_type != CA_OBJ_MONOP ) {
    return 0;
  }
  m = (CAMonOp *) view;
  if ( ! ca_monop_is_cast(m->op_id) ) {
    return 0;
  }
  p = m->parent;
  if ( p == NULL ) {
    return 0;
  }
  /* "single-cast" = cast over a NON-lazy parent.  When the parent is
     itself a lazy view family member, the cast contributes to a lazy
     chain and should NOT be excluded from ca_is_lazy_view (otherwise
     CArray.fuse chains break through the cast node, and `<=>` 1-pass fuse
     degenerates back to 3-pass).  Cast over entity / CAStride / CAFake /
     etc. (= NOT a lazy parent) stays single-cast → eager binop dispatch
     (so `1/zero` zero-check works).  */
  return ( p->obj_type != CA_OBJ_MONOP
        && p->obj_type != CA_OBJ_BINOP
        && p->obj_type != CA_OBJ_BINCMP
        && p->obj_type != CA_OBJ_MONCMP
        && p->obj_type != CA_OBJ_LAZY_MARKER );
}

/* ------------------------------------------------------------------- */
/* setup / new / free                                                   */
/* ------------------------------------------------------------------- */

static int
ca_monop_setup (CAMonOp *ca, CArray *parent, uint16_t op_id)
{
  int8_t out_dt = ca_lazy_promote_monop(op_id, parent->data_type);
  ca_size_t out_bytes = ca_sizeof[out_dt];

  ca->obj_type  = CA_OBJ_MONOP;
  ca->data_type = out_dt;
  /* A cast op_id encodes a value-converting cast (analogue of CAFake),
     which is writable — `rb_ca_wrap_writable` returns the cast view
     directly and write-back reverse-casts through ca_ptr2ptr.  Non-cast
     ops (= monop / monfunc) remain read-only.  This matches the CAFake /
     wrap_writable semantics.  */
  ca->flags     = ca_monop_is_writable_view(op_id) ? 0 : CA_FLAG_READ_ONLY;
  ca->ndim      = parent->ndim;
  ca->bytes     = out_bytes;
  ca->elements  = parent->elements;
  ca->ptr       = NULL;
  ca->mask      = NULL;
  if ( ! ca->_pool ) {
    ca->dim     = ALLOC_N(ca_size_t, parent->ndim);
  }
  ca->parent    = parent;
  ca->attach    = 0;
  ca->nosync    = 0;
  ca->op_id     = op_id;
  ca->data_class = Qnil;   /* set by the builder when rtype is a class */

  memcpy(ca->dim, parent->dim, parent->ndim * sizeof(ca_size_t));

  /* The mask is NOT built here: ca_has_mask creates a view's mask on
     demand from its parent's, so an expression whose mask nobody reads
     never allocates one. */

  if ( ca_is_scalar(parent) ) {
    ca_set_flag(ca, CA_FLAG_SCALAR);
  }

  return 0;
}

CAMonOp *
ca_monop_new (CArray *parent, uint16_t op_id)
{
  CAMonOp *ca = (CAMonOp *) ca_array_alloc(CA_OBJ_MONOP, parent->ndim);
  ca_monop_setup(ca, parent, op_id);
  return ca;
}

static void
free_ca_monop (void *ap)
{
  CAMonOp *ca = (CAMonOp *) ap;
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

/* Forward declarations (cross-references between slot functions).  */
static void ca_monop_func_xfer_stride (void *ap, ca_size_t *starts,
                                       ca_size_t *counts, ca_size_t *strides,
                                       void *data, int dir);

static void *
ca_monop_func_clone (void *ap)
{
  CAMonOp *ca = (CAMonOp *) ap;
  return ca_monop_new(ca->parent, ca->op_id);
}

/* per-cell access: walk the chain materialising 1 cell via per-cell
   xfer_index that triggers materialise through the parent chain.  This is
   not catastrophic at typical depths, but hot loops should use a `.to_ca`
   snapshot.

   PUT path: when this view is a writable cast view (= cast op_id),
   reverse-cast the incoming `data` (view data_type) to a per-cell scratch
   in parent data_type, then ca_store_index into parent.  Non-cast monop
   views remain read-only (rb_raise).  */
static void
ca_monop_func_xfer_index (void *ap, ca_size_t *idx, void *data, int dir)
{
  CAMonOp *ca = (CAMonOp *) ap;
  ca_size_t starts[CA_RANK_MAX];
  ca_size_t counts[CA_RANK_MAX];
  ca_size_t strides[CA_RANK_MAX];
  int8_t    k;
  ca_size_t s;

  if ( dir != CA_XFER_GET ) {
    /* PUT: only writable-view op_ids accept writes (cast, or byte_swap
       involution). */
    if ( ! ca_monop_is_writable_view(ca->op_id) ) {
      rb_raise(rb_eRuntimeError, "CAMonOp is read-only (xfer_index PUT)");
    }
    {
      char scratch[32];   /* max sizeof for any built-in numeric data_type */
      ca_size_t bytes_per_cell = (ca_monop_is_cast(ca->op_id))
                                  ? ca->parent->bytes : ca->bytes;
      char *p = (bytes_per_cell <= 32) ? scratch
                                       : (char *) ALLOC_N(char, bytes_per_cell);
      if ( ca_monop_is_cast(ca->op_id) ) {
        /* Reverse-cast view-data_type `data` to parent data_type scratch, then
           store into parent at idx[].  */
        ca_ptr2ptr((CArray *) ca, data, ca->parent, p);
      }
      else {
        /* byte_swap (involution): copy + byte_swap into parent-bytes
           layout (= same bytes since data_type-preserving).  */
        memcpy(p, data, ca->bytes);
        ca_byte_swap_buffer(ca->data_type, ca->bytes, 1, p);
      }
      ca_store_index(ca->parent, idx, p);
      if ( p != scratch ) xfree(p);
    }
    return;
  }

  /* Single-cell region: counts[k] = 1 for all axes, starts = idx[].  */
  s = ca->bytes;
  for ( k = ca->ndim - 1; k >= 0; k-- ) {
    starts[k]  = idx[k];
    counts[k]  = 1;
    strides[k] = s;
  }
  ca_monop_func_xfer_stride(ca, starts, counts, strides, data, CA_XFER_GET);
}

static void
ca_monop_func_xfer_addrs (void *ap, ca_size_t n, ca_size_t *addrs,
                          void *data, int dir)
{
  CAMonOp *ca = (CAMonOp *) ap;
  ca_size_t i;
  char *out = (char *) data;

  if ( dir != CA_XFER_GET ) {
    /* PUT: only writable-view op_ids accept writes.  */
    if ( ! ca_monop_is_writable_view(ca->op_id) ) {
      rb_raise(rb_eRuntimeError, "CAMonOp is read-only (xfer_addrs PUT)");
    }
    /* Per-cell loop: forward to xfer_index PUT (handles cast/byte_swap
       branch internally).  */
    for ( i = 0; i < n; i++ ) {
      ca_size_t idx[CA_RANK_MAX];
      ca_addr2index((CArray *)ca, addrs[i], idx);
      ca_monop_func_xfer_index(ca, idx, out + i * ca->bytes, CA_XFER_PUT);
    }
    return;
  }

  /* Naive per-addr loop: convert addr → idx, then xfer_index.  This path
     is not optimised. */
  for ( i = 0; i < n; i++ ) {
    ca_size_t idx[CA_RANK_MAX];
    ca_addr2index((CArray *)ca, addrs[i], idx);
    ca_monop_func_xfer_index(ca, idx, out + i * ca->bytes, CA_XFER_GET);
  }
}

/* ------------------------------------------------------------------- */
/* In-place chain eval (scratch = 0)                                    */
/* ------------------------------------------------------------------- */

/* Test counter: incremented every time xfer_stride allocates a leaf-side
   scratch buffer (for the cast-before pull).  Stays 0 across any depth
   chain when no cast is needed, and 1 (cast scratch) regardless of chain
   depth when the leaf needs widening.  Reset and read from Ruby for
   tests.  */
ca_size_t ca_monop_scratch_acquire_count = 0;

/* Test counter: incremented every time CAMonOp's xfer_stride entry is
   called.  Used to pin that `inspect` / `dump_tree` do NOT materialise
   (counter unchanged) while `each` / `to_a` / `sort` / `to_ca` etc. DO
   (counter increments).  */
ca_size_t ca_monop_materialise_call_count = 0;

#ifndef CA_MAX_LAZY_DEPTH
#define CA_MAX_LAZY_DEPTH 256
#endif

/* Apply a single op in-place on `data` (src == dst, unit element stride).
   Raises if the kernel is not implemented for the given input data_type.

   Unmask fast path:
   We always pass `mask == NULL` to the kernel, which selects the SIMD-
   friendly "no mask" branch in the existing eager kernels (see e.g.
   ca_monop_sqrt_float64_t in carray_math.c — `if (m) { ... } else
   { ...SIMD loop... }`).  Mask cells contain garbage after evaluation,
   but they are unobservable: the output mask is built separately via
   the attach lifecycle (ca_monop_func_create_mask + parent.mask
   CARefer), so reads of masked cells return UNDEF regardless of byte
   contents.  The mask marks cells as undefined; it does not guard their
   bytes, so writing garbage into a masked cell is licensed.

   A "partial mask slow path" (= a cell-wise branch to skip masked-cell
   compute) is a possible future micro-optimisation; it is not done
   because masked-cell compute does not affect correctness and the SIMD
   path is faster overall for typical mask densities.  */
static void
apply_monop_in_place (uint16_t op_id, int8_t cur_dt,
                      ca_size_t slab_n, void *data)
{
  ca_monop_func_t fn = ca_monop_kernel_lookup(op_id, cur_dt);
  if ( fn == NULL ) {
    rb_raise(rb_eRuntimeError,
             "CAMonOp: kernel not implemented (op_id=%u data_type=%d)",
             (unsigned) op_id, (int) cur_dt);
  }
  fn(slab_n, NULL, (char *) data, 1, (char *) data, 1);
}

/* Minimal CArray-shaped stub used as ca_cast_block's data_type-only carrier.
   ca_cast_block only reads data_type to index into ca_cast_func_table.  */
typedef struct {
  int16_t obj_type;
  int8_t  data_type;
} ca_data_type_stub_t;

/* Pull leaf into the output buffer.  Three paths:

   1. No size change (leaf.bytes == out.bytes): pull directly into
      `data` using the caller's `strides` (= output byte layout).
      Zero scratch; cur_dt = leaf.data_type.

   2. Size mismatch + cast at leaf (`has_cast_at_leaf == 1`): allocate
      a small scratch sized in leaf bytes, pull leaf into scratch with
      row-major leaf-byte strides, then ca_cast_block scratch → data
      (in the cast target's data_type).  Scratch count = 1.  cur_dt =
      cast target data_type.

   3. Size mismatch + cast mid-chain (`has_cast_at_leaf == 0`):
      allocate scratch sized in leaf bytes, pull leaf into scratch
      with leaf-byte strides, then memcpy scratch → start of `data`
      (compact leaf-byte layout at the head of the larger buffer).
      A later mid-chain cast op will expand it into the output layout.
      Scratch count = 1.  cur_dt = leaf.data_type.

   The shared property: when output.bytes != leaf.bytes, the caller's
   `strides` (= output byte layout) cannot be passed directly to
   ca_xfer_stride on the leaf because they don't match leaf's per-cell
   size.  Pulling into a leaf-sized compact scratch decouples leaf-
   layout from output-layout.  */
static int8_t
pull_leaf_with_optional_cast (CArray *leaf, uint16_t innermost_op,
                              int has_cast_at_leaf, int8_t out_bytes,
                              ca_size_t slab_n,
                              ca_size_t *starts, ca_size_t *counts,
                              ca_size_t *strides, void *data)
{
  ca_size_t leaf_bytes = leaf->bytes;

  /* Path 1: no size mismatch, no cast — direct pull.  */
  if ( leaf_bytes == out_bytes && ! has_cast_at_leaf ) {
    ca_xfer_stride(leaf, starts, counts, strides, data, CA_XFER_GET);
    return leaf->data_type;
  }

  /* Paths 2 & 3 both need a leaf-sized scratch + leaf-byte strides
     for the leaf pull.  */
  ca_size_t parent_strides[CA_RANK_MAX];
  ca_size_t total_bytes = slab_n * leaf_bytes;
  void *scratch;
  volatile VALUE holder;
  int8_t k;
  {
    ca_size_t s = leaf_bytes;
    for ( k = leaf->ndim - 1; k >= 0; k-- ) {
      parent_strides[k] = s;
      s *= counts[k];
    }
  }
  (void) holder;
  scratch = ( leaf->data_type == CA_OBJECT )
              ? ca_lazy_arena_acquire_object(slab_n)
              : ca_lazy_arena_acquire(total_bytes);
  ca_monop_scratch_acquire_count++;
  ca_xfer_stride(leaf, starts, counts, parent_strides, scratch, CA_XFER_GET);

  int8_t result_dt;
  if ( has_cast_at_leaf ) {
    /* Path 2: cast scratch → data with output layout in target data_type.  */
    int8_t target_dt = (int8_t)(innermost_op - CA_MONOP_CAST_BASE);
    ca_data_type_stub_t src_stub = { 0, leaf->data_type };
    ca_data_type_stub_t dst_stub = { 0, target_dt };
    ca_cast_block(slab_n, &src_stub, scratch, &dst_stub, data);
    result_dt = target_dt;
  } else {
    /* Path 3: memcpy scratch → start of data.  Mid-chain cast will
       expand to output layout later.  */
    memcpy(data, scratch, total_bytes);
    result_dt = leaf->data_type;
  }

  ca_lazy_arena_release(scratch);
  return result_dt;
}

static void
ca_monop_func_xfer_stride (void *ap, ca_size_t *starts, ca_size_t *counts,
                           ca_size_t *strides, void *data, int dir)
{
  CAMonOp *mo = (CAMonOp *) ap;
  uint16_t op_chain[CA_MAX_LAZY_DEPTH];
  int chain_len = 0;
  CArray  *leaf;
  ca_size_t slab_n;
  int8_t    k;
  int8_t    cur_dt;
  int       i;
  int       has_cast_at_leaf = 0;
  int       chain_apply_count;

  /* Writable-view op_ids (cast / byte_swap) use CAFake-style xfer_stride
     for both GET and PUT.  This avoids the chain-materialise inline path
     that fails for a narrowing cast (parent.bytes > ca.bytes → buffer
     overflow in the pull_leaf path 3).  Mirrors the CAFake xfer_stride
     fallback.
     - cast: pstrides = strides/ca.bytes * parent.bytes; ca_cast_block.
     - byte_swap: same data_type → pstrides = strides; involution apply.  */
  if ( ca_monop_is_writable_view(mo->op_id) ) {
    int is_cast = ca_monop_is_cast(mo->op_id);
    ca_size_t pstrides[CA_RANK_MAX];
    ca_size_t n = 1;
    ca_size_t parent_bytes = is_cast ? mo->parent->bytes : mo->bytes;
    int8_t    kk;
    char     *v;
    volatile VALUE holder;
    for ( kk = 0; kk < mo->ndim; kk++ ) {
      n *= counts[kk];
      pstrides[kk] = is_cast
                       ? (strides[kk] / mo->bytes * mo->parent->bytes)
                       : strides[kk];
    }
    v = ALLOCV_N(char, holder, n * parent_bytes);
    if ( dir == CA_XFER_GET ) {
      ca_xfer_stride(mo->parent, starts, counts, pstrides, v, CA_XFER_GET);
      if ( is_cast ) {
        ca_cast_block(n, mo->parent, v, (CArray *) mo, data);
      }
      else {
        /* byte_swap (involution): apply on scratch then memcpy → data. */
        ca_byte_swap_buffer(mo->data_type, mo->bytes, n, v);
        memcpy(data, v, n * mo->bytes);
      }
    }
    else {
      if ( is_cast ) {
        ca_cast_block(n, (CArray *) mo, data, mo->parent, v);
      }
      else {
        /* byte_swap PUT: copy data into scratch + byte_swap (involution).  */
        memcpy(v, data, n * mo->bytes);
        ca_byte_swap_buffer(mo->data_type, mo->bytes, n, v);
      }
      ca_xfer_stride(mo->parent, starts, counts, pstrides, v, CA_XFER_PUT);
    }
    ALLOCV_END(holder);
    return;
  }

  /* Writable-view op_id PUT/GET is handled above.  Below: non-writable
     monop/monfunc.  PUT is read-only.  */
  if ( dir != CA_XFER_GET ) {
    rb_raise(rb_eRuntimeError, "CAMonOp is read-only (xfer_stride PUT)");
  }
  ca_monop_materialise_call_count++;

  /* === 1. iterative chain collect ===
     Walk down through CAMonOp parents, recording op_ids bottom-up.
     Skip transparent CALazyMarker (collapse-on-consume already happened
     at construction, but defensive in case a marker is mid-chain).  */
  leaf = (CArray *) mo;
  while ( leaf->obj_type == CA_OBJ_MONOP ) {
    CAMonOp *node = (CAMonOp *) leaf;
    if ( chain_len >= CA_MAX_LAZY_DEPTH ) {
      rb_raise(rb_eRuntimeError,
               "CAMonOp chain depth exceeds CA_MAX_LAZY_DEPTH (%d)",
               CA_MAX_LAZY_DEPTH);
    }
    op_chain[chain_len++] = node->op_id;
    leaf = node->parent;
  }
  /* Skip a CALazyMarker leaf: transparent pass-through to its parent.  */
  while ( leaf->obj_type == CA_OBJ_LAZY_MARKER ) {
    leaf = ((CAView *) leaf)->parent;
  }

  /* Detect whether the innermost recorded op is a cast.  Cast nodes are
     always inserted adjacent to the leaf at construction (cast-before),
     so they appear at op_chain[chain_len - 1].  */
  chain_apply_count = chain_len;
  if ( chain_len > 0 && ca_monop_is_cast(op_chain[chain_len - 1]) ) {
    has_cast_at_leaf = 1;
    chain_apply_count = chain_len - 1;
  }

  /* === 2. pull leaf into output buffer (with optional cast) === */
  slab_n = 1;
  for ( k = 0; k < mo->ndim; k++ ) {
    slab_n *= counts[k];
  }
  cur_dt = pull_leaf_with_optional_cast(
    leaf,
    has_cast_at_leaf ? op_chain[chain_len - 1] : 0,
    has_cast_at_leaf,
    (int8_t) mo->bytes,
    slab_n, starts, counts, strides, data
  );

  /* === 3. apply remaining chain in reverse (leaf side → outermost) ===
     Cast nodes may appear mid-chain when preserve ops precede a
     widening monfunc (e.g. `int16.lazy.neg.sinh` inserts cast_f64
     between neg and sinh).  Handle them via ca_cast_block + scratch
     similar to pull_leaf_with_optional_cast.  */
  for ( i = chain_apply_count - 1; i >= 0; i-- ) {
    uint16_t op_id = op_chain[i];
    if ( ca_monop_is_cast(op_id) ) {
      int8_t target_dt = (int8_t)(op_id - CA_MONOP_CAST_BASE);
      ca_size_t src_bytes = ca_sizeof[cur_dt];
      ca_size_t total_bytes = slab_n * src_bytes;
      void *scratch;
      ca_data_type_stub_t src_stub = { 0, cur_dt };
      ca_data_type_stub_t dst_stub = { 0, target_dt };

      /* Copy current data → scratch (in src data_type), then cast scratch
         → data (in target data_type).  Required because in-place cast
         would overlap source/dest reads when target_bytes > src_bytes
         (forward-walk reads cells past their own write boundary). */
      scratch = ( cur_dt == CA_OBJECT )
                  ? ca_lazy_arena_acquire_object(slab_n)
                  : ca_lazy_arena_acquire(total_bytes);
      ca_monop_scratch_acquire_count++;
      memcpy(scratch, data, total_bytes);
      ca_cast_block(slab_n, &src_stub, scratch, &dst_stub, data);
      ca_lazy_arena_release(scratch);
      cur_dt = target_dt;
    } else {
      apply_monop_in_place(op_id, cur_dt, slab_n, data);
      cur_dt = ca_lazy_promote_monop(op_id, cur_dt);
    }
  }
}

static void
ca_monop_func_xfer_all (void *ap, void *data, int dir)
{
  CAMonOp *ca = (CAMonOp *) ap;
  ca_size_t starts[CA_RANK_MAX];
  ca_size_t native[CA_RANK_MAX];
  int8_t    k;
  ca_size_t s = ca->bytes;
  for ( k = ca->ndim - 1; k >= 0; k-- ) { native[k] = s; s *= ca->dim[k]; }
  for ( k = 0; k < ca->ndim; k++ ) starts[k] = 0;
  ca_xfer_stride(ca, starts, ca->dim, native, data, dir);
}

static void
ca_monop_func_allocate (void *ap)
{
  CAMonOp *ca = (CAMonOp *) ap;
  /* A writable cast view's allocate path also needs the parent attached
     so a later sync (sync slot → ca_cast_block(ca.ptr → parent.ptr))
     finds parent.ptr valid.  Caller pattern is `ca_allocate(view); fill
     view.ptr; ca_sync(view); ca_detach(view)` (a write-only buffer
     allocation that bypasses the parent data copy).

     CAREFUL but safe: ca_attach / ca_allocate slots fire only on the
     count 0→1 transition, so if both allocate and attach run on the same
     view only the first triggers the slot; the second just increments the
     count.  Total ca_attach(parent) calls per view lifecycle = 1.  CAFake
     uses this same pattern.  */
  if ( ca_monop_is_writable_view(ca->op_id) ) {
    ca_attach(ca->parent);
  }
  ca->ptr = xmalloc(ca_length(ca));
  /* CA_OBJECT initialisation for GC safety.  */
  if ( ca->data_type == CA_OBJECT ) {
    VALUE *p = (VALUE *) ca->ptr;
    VALUE zero = SIZE2NUM(0);
    ca_size_t i;
    for ( i = 0; i < ca->elements; i++ ) {
      *p++ = zero;
    }
  }
}

static void
ca_monop_func_attach (void *ap)
{
  /* CAREFUL: call the view-specific xfer_stride directly, bypassing the
     public ca_xfer_stride dispatcher.  A self-fill via the dispatcher
     would hit the self-memcpy fast path (data == ca->ptr → no-op) and
     leave the buffer as garbage. */
  CAMonOp *ca = (CAMonOp *) ap;
  ca_size_t starts[CA_RANK_MAX];
  ca_size_t native[CA_RANK_MAX];
  int8_t    k;
  ca_size_t s;

  /* A writable cast view uses the CAFake-style attach lifecycle
     (= ca_attach(parent); ca_cast_block(parent.ptr → ca.ptr)).  This
     avoids the chain-materialise inline path, which assumes the output
     buffer is at least as big as the leaf data and so fails for a
     narrowing cast like float64→int32.

     Non-cast (= chain materialise / read-only) uses the in-place chain
     eval path.  Its output buffer is in monop data_type; widening at the
     leaf is supported via path 3 (mid-chain cast scratch expansion).

     Mirrors CAFake.attach.  */
  if ( ca_monop_is_writable_view(ca->op_id) ) {
    ca_attach(ca->parent);
    ca->ptr = xmalloc(ca_length(ca));
    /* CA_OBJECT initialisation for GC safety (mirrors CAFake.allocate):
       zero-init the VALUE cells before any potential GC can observe
       them.  */
    if ( ca->data_type == CA_OBJECT ) {
      VALUE *p = (VALUE *) ca->ptr;
      VALUE zero = SIZE2NUM(0);
      ca_size_t i;
      for ( i = 0; i < ca->elements; i++ ) {
        *p++ = zero;
      }
    }
    if ( ca_monop_is_cast(ca->op_id) ) {
      /* Cast parent.ptr (parent data_type) → ca.ptr (cast target data_type).  */
      ca_cast_block(ca->elements, ca->parent, ca->parent->ptr,
                    (CArray *) ca, ca->ptr);
    }
    else {
      /* byte_swap: memcpy parent.ptr → ca.ptr (same data_type same bytes),
         then byte_swap in place.  */
      memcpy(ca->ptr, ca->parent->ptr, ca_length(ca));
      ca_byte_swap_buffer(ca->data_type, ca->bytes, ca->elements, ca->ptr);
    }
    return;
  }

  ca->ptr = xmalloc(ca_length(ca));

  s = ca->bytes;
  for ( k = ca->ndim - 1; k >= 0; k-- ) { native[k] = s; s *= ca->dim[k]; }
  for ( k = 0; k < ca->ndim; k++ ) starts[k] = 0;
  /* CA_OBJECT cells are VALUEs and this buffer is about to be marked as
     soon as the view is, so it must not be handed to the GC as raw
     xmalloc garbage. */
  if ( ca->data_type == CA_OBJECT ) {
    VALUE *p = (VALUE *) ca->ptr;
    ca_size_t i;
    for ( i = 0; i < ca->elements; i++ ) *p++ = Qnil;
  }
  ca_monop_func_xfer_stride(ca, starts, ca->dim, native, ca->ptr, CA_XFER_GET);
}

static void
ca_monop_func_sync (void *ap)
{
  CAMonOp *ca = (CAMonOp *) ap;
  /* Writable cast lifecycle.  A CABlock-on-CAMonOp(cast) sub-view fill
     propagates via this path:
       1. CABlock.attach pulls CAMonOp via xfer_stride GET into CABlock.ptr
       2. user fills CABlock.ptr region
       3. CABlock.sync writes CABlock.ptr back via xfer_stride PUT to CAMonOp
          (fills the CAMonOp.ptr region in cast data_type)
       4. CAMonOp.sync (= this) writes CAMonOp.ptr back to parent via a
          reverse-cast bulk (ca_cast_block) + parent.sync
     Non-cast (= chain materialise / read-only) skips this: no writes ever
     accumulate in ca->ptr, so sync would be redundant.  Mirrors the
     CAFake sync pattern.  */
  if ( ! ca_monop_is_writable_view(ca->op_id) ) {
    return;
  }
  if ( ca_monop_is_cast(ca->op_id) ) {
    /* Cast view → parent: reverse-cast bulk.  */
    ca_update_mask(ca);
    if ( ca->mask ) {
      ca_cast_block_with_mask(ca->elements, ca, ca->ptr,
                              ca->parent, ca->parent->ptr,
                              (boolean8_t *) ca->parent->mask->ptr);
    }
    else {
      ca_cast_block(ca->elements, ca, ca->ptr, ca->parent, ca->parent->ptr);
    }
  }
  else {
    /* byte_swap (involution): apply on ca.ptr in place (re-swap), then
       memcpy ca.ptr → parent.ptr.  Mirrors CAByteSwap sync.  */
    ca_byte_swap_buffer(ca->data_type, ca->bytes, ca->elements, ca->ptr);
    memcpy(ca->parent->ptr, ca->ptr, ca_length(ca));
  }
  ca_sync(ca->parent);
}

static void
ca_monop_func_detach (void *ap)
{
  CAMonOp *ca = (CAMonOp *) ap;
  xfree(ca->ptr);
  ca->ptr = NULL;
  /* A cast op_id attaches the parent in ca_monop_func_attach; pair it
     here with one ca_detach(parent), so the attach/detach on the parent
     balance across the view lifecycle.  Mirrors CAFake detach.  */
  if ( ca_monop_is_writable_view(ca->op_id) ) {
    ca_detach(ca->parent);
  }
}

static void
ca_monop_func_fill_data (void *ap, void *ptr)
{
  CAMonOp *ca = (CAMonOp *) ap;
  /* Writable-view op_id (cast / byte_swap) fill path — operate on the
     incoming scalar in view data_type, write the parent in parent
     data_type (= same bytes for byte_swap, reverse-cast for cast).
     Non-writable monop/monfunc remains read-only.  */
  if ( ! ca_monop_is_writable_view(ca->op_id) ) {
    rb_raise(rb_eRuntimeError, "CAMonOp is read-only (fill_data)");
  }
  {
    int is_cast = ca_monop_is_cast(ca->op_id);
    ca_size_t parent_bytes = is_cast ? ca->parent->bytes : ca->bytes;
    char stack_v[32];
    char *v = (parent_bytes <= 32) ? stack_v
                                   : (char *) xmalloc(parent_bytes);
    if ( is_cast ) {
      ca_ptr2ptr((CArray *) ca, ptr, ca->parent, v);
    }
    else {
      memcpy(v, ptr, ca->bytes);
      ca_byte_swap_buffer(ca->data_type, ca->bytes, 1, v);
    }
    ca_fill(ca->parent, v);
    if ( v != stack_v ) xfree(v);
  }
}

static void
ca_monop_func_create_mask (void *ap)
{
  CAMonOp *ca = (CAMonOp *) ap;
  if ( ! ca->parent->mask ) {
    ca_create_mask(ca->parent);
  }
  ca->mask =
    (CArray *) ca_refer_new(ca->parent->mask,
                            CA_BOOLEAN, ca->ndim, ca->dim, 0, 0);
}

ca_operation_function_t ca_monop_func = {
  -1, /* CA_OBJ_MONOP, set at install time */
  CA_VIEW_ARRAY,
  free_ca_monop,
  ca_monop_func_clone,
  ca_monop_func_allocate,
  ca_monop_func_attach,
  ca_monop_func_sync,
  ca_monop_func_detach,
  ca_monop_func_fill_data,
  ca_monop_func_create_mask,
  ca_monop_func_xfer_index,
  ca_monop_func_xfer_addrs,
  NULL,                       /* fold_stride: never-fold (op boundary) */
  ca_monop_func_xfer_stride,
  ca_monop_func_xfer_all,
};

/* ------------------------------------------------------------------- */
/* Public predicate + constructor                                       */
/* ------------------------------------------------------------------- */

/* CABinOp obj_type.  Declared in ca_obj_binop.c.  */
extern int8_t CA_OBJ_BINOP;
/* CATriOp obj_type.  Declared in ca_obj_triop.c.  */
extern int8_t CA_OBJ_TRIOP;
/* CABinCmp / CAMonCmp.  Declared in ca_obj_bincmp.c / ca_obj_moncmp.c.  */
extern int8_t CA_OBJ_BINCMP;
extern int8_t CA_OBJ_MONCMP;

int
ca_is_lazy_view (void *ap)
{
  CArray *ca = (CArray *) ap;
  /* A single-cast CAMonOp (= structural successor of the CAFake numeric
     view, see ca_monop_view_is_single_cast) is a value-converting
     type-adapt view, NOT a lazy chain.  Excluding it from is_lazy_view
     preserves eager binop semantics (e.g. `a.as_int32 / b` calls the
     eager div kernel with zero-check, not a CABinOp lazy build), matching
     CAFake behaviour.  Chain CAMonOp (depth >= 2) and non-cast
     monop/monfunc remain lazy.  */
  if ( ca->obj_type == CA_OBJ_MONOP ) {
    if ( ca_monop_view_is_single_cast(ca) ) {
      return 0;
    }
    return 1;
  }
  return ( ca->obj_type == CA_OBJ_LAZY_MARKER  ||
           ca->obj_type == CA_OBJ_BINOP        ||
           ca->obj_type == CA_OBJ_TRIOP        ||
           ca->obj_type == CA_OBJ_BINCMP       ||
           ca->obj_type == CA_OBJ_MONCMP );
}

/* Low-level CAMonOp constructor: wraps `cary` directly, no cast insertion.
   Used internally by the public builder below for the cast node and the
   final op node.  */
static VALUE
rb_ca_monop_new (VALUE cary, uint16_t op_id)
{
  volatile VALUE obj;
  CArray *parent;
  CAMonOp *ca;
  rb_check_carray_object(cary);
  TypedData_Get_Struct(cary, CArray, &carray_data_type, parent);
  ca  = ca_monop_new(parent, op_id);
  obj = ca_wrap_struct(ca);
  rb_ca_set_parent(obj, cary);
  return obj;
}

/* Public builder: build a CAMonOp tree node for `op_id` over `cary`,
   inserting a cast node if the existing eager kernel for op_id needs
   a different input data_type than cary provides (cast-before).

   If `cary` is a CALazyMarker, collapse-on-consume: use marker's parent
   as the actual node parent so the marker doesn't appear in the tree.  */
VALUE
rb_ca_monop_build (VALUE cary, uint16_t op_id)
{
  CArray *parent;
  VALUE  target = cary;
  int8_t parent_dt;
  int8_t kernel_in_dt;

  rb_check_carray_object(cary);
  TypedData_Get_Struct(cary, CArray, &carray_data_type, parent);

  /* Collapse-on-consume: if cary is a marker, replace it with its Ruby
     parent for both the CAMonOp parent and the data_type probe.  */
  if ( parent->obj_type == CA_OBJ_LAZY_MARKER ) {
    target = rb_ca_parent(cary);
    TypedData_Get_Struct(target, CArray, &carray_data_type, parent);
  }

  parent_dt    = parent->data_type;
  kernel_in_dt = ca_monop_kernel_input_data_type(op_id, parent_dt);

  /* Insert cast node if the kernel wants a different input data_type.  */
  if ( kernel_in_dt != parent_dt ) {
    uint16_t cast_op_id = CA_MONOP_CAST_BASE + (uint16_t) kernel_in_dt;
    target = rb_ca_monop_new(target, cast_op_id);
  }

  return rb_ca_monop_new(target, op_id);
}

/* Ruby surface: returns the configured CAMonOp.  lib/carray/lazy.rb
   invokes this from the per-op method redefinitions (`.lazy.<op>`).  */
static VALUE
rb_ca_monop_s_build (VALUE klass, VALUE cary, VALUE op_id_val)
{
  uint16_t op_id = (uint16_t) NUM2UINT(op_id_val);
  (void) klass;
  return rb_ca_monop_build(cary, op_id);
}

/* Ruby predicate: true if self is a lazy view (CAMonOp or CALazyMarker).  */
static VALUE
rb_ca_is_lazy_view_p (VALUE self)
{
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  return ca_is_lazy_view(ca) ? Qtrue : Qfalse;
}

/* Read CAMonOp's op_id for inspect/dump_tree consumers in Ruby.  */
static VALUE
rb_ca_monop_op_id (VALUE self)
{
  CAMonOp *mo;
  TypedData_Get_Struct(self, CAMonOp, &camonop_data_type, mo);
  return UINT2NUM(mo->op_id);
}

/* ------------------------------------------------------------------- */
/* Ruby surface helpers                                                 */
/* ------------------------------------------------------------------- */

/* Reset and read the scratch-acquire counter used by tests.  It stays 0
   because in-place chain eval allocates no scratch; only attach (xfer_all
   → output) and the parent's own xfer_stride alloc, neither of which we
   count here.  */
static VALUE
rb_ca_monop_s_reset_scratch_counter (VALUE klass)
{
  ca_monop_scratch_acquire_count = 0;
  return Qnil;
}

static VALUE
rb_ca_monop_s_scratch_count (VALUE klass)
{
  return SIZE2NUM(ca_monop_scratch_acquire_count);
}

static VALUE
rb_ca_monop_s_reset_materialise_counter (VALUE klass)
{
  ca_monop_materialise_call_count = 0;
  return Qnil;
}

static VALUE
rb_ca_monop_s_materialise_count (VALUE klass)
{
  return SIZE2NUM(ca_monop_materialise_call_count);
}

static VALUE
rb_ca_monop_s_allocate (VALUE klass)
{
  CAMonOp *ca;
  return TypedData_Make_Struct(klass, CAMonOp, &camonop_data_type, ca);
}

static VALUE
rb_ca_monop_initialize_copy (VALUE self, VALUE other)
{
  CAMonOp *ca, *cs;
  TypedData_Get_Struct(self,  CAMonOp, &camonop_data_type, ca);
  TypedData_Get_Struct(other, CAMonOp, &camonop_data_type, cs);
  if ( ca_func[CA_OBJ_MONOP].pool_init ) {
    ca_array_pool_alloc(ca, CA_OBJ_MONOP, cs->parent->ndim);
  }
  ca_monop_setup(ca, cs->parent, cs->op_id);
  return self;
}

void
Init_ca_obj_monop (void)
{
  rb_cCAMonOp = rb_define_class("CAMonOp", rb_cCAView);

  ca_monop_func.struct_size = sizeof(CAMonOp);
  ca_monop_func.pool_bytes  = ca_monop_pool_bytes;
  ca_monop_func.pool_init   = ca_monop_pool_init;

  CA_OBJ_MONOP = ca_install_obj_type(rb_cCAMonOp,
                                     &camonop_data_type,
                                     rb_cCArrayMask,
                                     &carray_mask_data_type, &ca_monop_func, sizeof(ca_monop_func));
  rb_define_const(rb_cObject, "CA_OBJ_MONOP", INT2NUM(CA_OBJ_MONOP));

  /* op_id constants (all 34 ops).  Cast op_ids are computed at
     call sites as CA_MONOP_CAST_BASE + data_type (no per-data_type constant).  */
  rb_define_const(rb_cCAMonOp, "OP_ZERO",    INT2NUM(CA_MONOP_ZERO));
  rb_define_const(rb_cCAMonOp, "OP_ONE",     INT2NUM(CA_MONOP_ONE));
  rb_define_const(rb_cCAMonOp, "OP_FRAC",    INT2NUM(CA_MONOP_FRAC));
  rb_define_const(rb_cCAMonOp, "OP_NEG",     INT2NUM(CA_MONOP_NEG));
  rb_define_const(rb_cCAMonOp, "OP_BIT_NEG", INT2NUM(CA_MONOP_BIT_NEG));
  rb_define_const(rb_cCAMonOp, "OP_ABS_I",   INT2NUM(CA_MONOP_ABS_I));
  rb_define_const(rb_cCAMonOp, "OP_CONJ",    INT2NUM(CA_MONOP_CONJ));
  rb_define_const(rb_cCAMonOp, "OP_NOT",     INT2NUM(CA_MONOP_NOT));
  rb_define_const(rb_cCAMonOp, "OP_CEIL",    INT2NUM(CA_MONOP_CEIL));
  rb_define_const(rb_cCAMonOp, "OP_FLOOR",   INT2NUM(CA_MONOP_FLOOR));
  rb_define_const(rb_cCAMonOp, "OP_ROUND",   INT2NUM(CA_MONOP_ROUND));
  rb_define_const(rb_cCAMonOp, "OP_RCP",     INT2NUM(CA_MONOP_RCP));
  rb_define_const(rb_cCAMonOp, "OP_RAD",     INT2NUM(CA_MONOP_RAD));
  rb_define_const(rb_cCAMonOp, "OP_DEG",     INT2NUM(CA_MONOP_DEG));
  rb_define_const(rb_cCAMonOp, "OP_SQRT",    INT2NUM(CA_MONOP_SQRT));
  rb_define_const(rb_cCAMonOp, "OP_EXP",     INT2NUM(CA_MONOP_EXP));
  rb_define_const(rb_cCAMonOp, "OP_EXP2",    INT2NUM(CA_MONOP_EXP2));
  rb_define_const(rb_cCAMonOp, "OP_EXP10",   INT2NUM(CA_MONOP_EXP10));
  rb_define_const(rb_cCAMonOp, "OP_LOG",     INT2NUM(CA_MONOP_LOG));
  rb_define_const(rb_cCAMonOp, "OP_LOG10",   INT2NUM(CA_MONOP_LOG10));
  rb_define_const(rb_cCAMonOp, "OP_LOG2",    INT2NUM(CA_MONOP_LOG2));
  rb_define_const(rb_cCAMonOp, "OP_LOGB",    INT2NUM(CA_MONOP_LOGB));
  rb_define_const(rb_cCAMonOp, "OP_SIN",     INT2NUM(CA_MONOP_SIN));
  rb_define_const(rb_cCAMonOp, "OP_COS",     INT2NUM(CA_MONOP_COS));
  rb_define_const(rb_cCAMonOp, "OP_TAN",     INT2NUM(CA_MONOP_TAN));
  rb_define_const(rb_cCAMonOp, "OP_ASIN",    INT2NUM(CA_MONOP_ASIN));
  rb_define_const(rb_cCAMonOp, "OP_ACOS",    INT2NUM(CA_MONOP_ACOS));
  rb_define_const(rb_cCAMonOp, "OP_ATAN",    INT2NUM(CA_MONOP_ATAN));
  rb_define_const(rb_cCAMonOp, "OP_SINH",    INT2NUM(CA_MONOP_SINH));
  rb_define_const(rb_cCAMonOp, "OP_COSH",    INT2NUM(CA_MONOP_COSH));
  rb_define_const(rb_cCAMonOp, "OP_TANH",    INT2NUM(CA_MONOP_TANH));
  rb_define_const(rb_cCAMonOp, "OP_ASINH",   INT2NUM(CA_MONOP_ASINH));
  rb_define_const(rb_cCAMonOp, "OP_ACOSH",   INT2NUM(CA_MONOP_ACOSH));
  rb_define_const(rb_cCAMonOp, "OP_ATANH",   INT2NUM(CA_MONOP_ATANH));
  rb_define_const(rb_cCAMonOp, "OP_IMAG_I",  INT2NUM(CA_MONOP_IMAG_I));
  /* M.1: PyTorch alignment additions */
  rb_define_const(rb_cCAMonOp, "OP_EXPM1",   INT2NUM(CA_MONOP_EXPM1));
  rb_define_const(rb_cCAMonOp, "OP_LOG1P",   INT2NUM(CA_MONOP_LOG1P));
  rb_define_const(rb_cCAMonOp, "OP_RSQRT",   INT2NUM(CA_MONOP_RSQRT));
  rb_define_const(rb_cCAMonOp, "OP_TRUNC",   INT2NUM(CA_MONOP_TRUNC));
  rb_define_const(rb_cCAMonOp, "OP_SQUARE",  INT2NUM(CA_MONOP_SQUARE));
  /* M.4: angle normalisation migration */
  rb_define_const(rb_cCAMonOp, "OP_DEG_360", INT2NUM(CA_MONOP_DEG_360));
  rb_define_const(rb_cCAMonOp, "OP_DEG_180", INT2NUM(CA_MONOP_DEG_180));
  rb_define_const(rb_cCAMonOp, "OP_RAD_2PI", INT2NUM(CA_MONOP_RAD_2PI));
  rb_define_const(rb_cCAMonOp, "OP_RAD_PI",  INT2NUM(CA_MONOP_RAD_PI));
  rb_define_const(rb_cCAMonOp, "OP_SIGN",    INT2NUM(CA_MONOP_SIGN));
  rb_define_const(rb_cCAMonOp, "OP_ARG_I",   INT2NUM(CA_MONOP_ARG_I));
  rb_define_const(rb_cCAMonOp, "CAST_BASE",  INT2NUM(CA_MONOP_CAST_BASE));

  rb_define_alloc_func(rb_cCAMonOp, rb_ca_monop_s_allocate);
  rb_define_method(rb_cCAMonOp, "initialize_copy",
                                rb_ca_monop_initialize_copy, 1);

  /* Public builder (used by lib/carray/lazy.rb per-op method
     redefinitions).  Inserts a cast node if needed (cast-before).  */
  rb_define_singleton_method(rb_cCAMonOp, "__build__",
                             rb_ca_monop_s_build, 2);

  /* Lazy-view predicate exposed on CArray (covers CAMonOp and
     CALazyMarker).  */
  rb_define_method(rb_cCArray, "__lazy_view__?",
                   rb_ca_is_lazy_view_p, 0);

  /* op_id accessor for inspect / dump_tree consumers in Ruby.  */
  rb_define_method(rb_cCAMonOp, "__op_id__",
                   rb_ca_monop_op_id, 0);

  /* Test instrumentation (not user-facing API).  */
  rb_define_singleton_method(rb_cCAMonOp, "__reset_scratch_counter__",
                             rb_ca_monop_s_reset_scratch_counter, 0);
  rb_define_singleton_method(rb_cCAMonOp, "__scratch_count__",
                             rb_ca_monop_s_scratch_count, 0);
  rb_define_singleton_method(rb_cCAMonOp, "__reset_materialise_counter__",
                             rb_ca_monop_s_reset_materialise_counter, 0);
  rb_define_singleton_method(rb_cCAMonOp, "__materialise_count__",
                             rb_ca_monop_s_materialise_count, 0);
}
