/* ---------------------------------------------------------------------------

  ca_iter_substrate.h

  Internal substrate shared between the descriptor framework
  (ca_axis_dispatch.c), the CAStride family (ca_obj_stride.c), and the
  future kernel_iterator (ca_kernel_iterator.c).

  Status: INTERNAL, but installed and unavoidable.  ca_kernel_iterator.h
  includes this header for ca_axis_desc_t / ca_op_prefix_axis_t, so every
  kernel author gets these declarations whether they want them or not --
  "do not include this" is not an instruction anyone can follow.  What
  holds instead: nothing declared here is a downstream contract, and the
  signatures may change across 3.x as the engine evolves.  Calling one of
  these from an ext gem is reaching past the author surface
  (ca_kernel_iterator.h's frozen macros and entry points), and nothing
  will be done to keep such a call working.

  The helpers were `static` inside ca_axis_dispatch.c / ca_obj_stride.c
  until ca_kernel_iterator.c needed them; only the linkage changed, not
  the bodies.  The inline helper is defined here so it still inlines into
  each consumer TU.

  --------------------------------------------------------------------------- */

#ifndef CA_ITER_SUBSTRATE_H
#define CA_ITER_SUBSTRATE_H 1

#include "carray.h"

/* ==========================================================================
   ca_axis_dispatch.c substrate
   ========================================================================== */

/* S2 / PROPOSAL_OPERAND_DESCRIPTOR Phase 1: pre-classified prefix axis.

   Inner per-iteration offset contribution for prefix axis k:
     STRIDE: poff += byte_start + idx[k] * byte_step
     INDEX : poff += indices[idx[k]] * byte_pstride
     SHIFT : (bound-checked, see ca_axis_dispatch_prefix_offset)

   Quantities are pre-multiplied by pstrides[k] at setup time so the
   inner loop spends one multiply per axis. */

typedef enum {
  CA_OP_AXIS_STRIDE = 0,
  CA_OP_AXIS_INDEX  = 1,
  CA_OP_AXIS_SHIFT  = 2    /* Tier 2.B: bound-aware (CAWindow/CAShift) */
} ca_op_axis_kind_t;

typedef struct {
  ca_op_axis_kind_t  kind;
  ca_size_t          count;
  /* STRIDE / SHIFT modes */
  ca_size_t          byte_start;   /* = start * pstride */
  ca_size_t          byte_step;    /* = step  * pstride */
  /* INDEX-mode (kind == CA_OP_AXIS_INDEX) */
  const ca_size_t   *indices;
  ca_size_t          byte_pstride; /* = pstride */
  /* SHIFT-only fields (Tier 2.B) */
  ca_size_t          shift_start;
  ca_size_t          shift_step;
  ca_size_t          size0;        /* parent dim along this axis */
  uint8_t            policy;       /* CA_BOUNDS_FILL / PERIODIC / ... */
} ca_op_prefix_axis_t;

/* D8 (PROPOSAL_AXIS_MERGE Phase 2): in-place merge of adjacent STRIDE
   axes when their effective byte strides line up.  Operates on
   (axes, pstrides, mdim, *ndim_inout) and writes the merged ndim back. */
void ca_axis_dispatch_merge (ca_axis_desc_t *axes,
                             ca_size_t      *pstrides,
                             ca_size_t      *mdim,
                             int8_t         *ndim_inout);

/* Slab detection: identify the innermost STRIDE-step1 contig run.
   Sets *slab_start, *slab_bytes, *slab_base. */
void ca_axis_dispatch_layout (ca_axis_desc_t  *axes,
                              const ca_size_t *pstrides,
                              const ca_size_t *mdim,
                              int8_t           ndim,
                              ca_size_t        bytes,
                              int8_t          *slab_start,
                              ca_size_t       *slab_bytes,
                              ca_size_t       *slab_base);

/* Build merged layout from caller-provided axes / parent_axis_dims.
   Runs the D8 merge pass to fixpoint, writes results into out_*. */
void ca_axis_dispatch_prepare (const ca_size_t      *parent_axis_dims,
                               const ca_axis_desc_t *axes,
                               int8_t                ndim,
                               ca_size_t             bytes,
                               ca_axis_desc_t       *out_axes,
                               ca_size_t            *out_pstrides,
                               ca_size_t            *out_mdim,
                               int8_t               *out_ndim);

/* Build pre-classified prefix axis array from the (post-merge, post-
   layout) axes/pstrides for indices [0..slab_start-1]. */
void ca_axis_dispatch_classify_prefix (const ca_axis_desc_t *axes,
                                       const ca_size_t      *pstrides,
                                       int8_t                slab_start,
                                       ca_op_prefix_axis_t  *prefix);

/* Inline inner offset computation from pre-classified prefix.  Kept as
   `static inline` in the header so any consumer TU (ca_axis_dispatch.c,
   future ca_kernel_iterator.c) inlines it directly.  SHIFT axes apply
   ca_bounds_normalize_index; if the normalised index is still OOB,
   *oob is set to 1 and 0 is returned (caller decides skip vs fill). */
static inline ca_size_t
ca_axis_dispatch_prefix_offset (const ca_op_prefix_axis_t *prefix,
                                const ca_size_t           *idx,
                                int8_t                     slab_start,
                                int                       *oob)
{
  ca_size_t off = 0;
  int8_t    k;
  *oob = 0;
  for ( k = 0; k < slab_start; k++ ) {
    if ( prefix[k].kind == CA_OP_AXIS_STRIDE ) {
      off += prefix[k].byte_start + idx[k] * prefix[k].byte_step;
    } else if ( prefix[k].kind == CA_OP_AXIS_INDEX ) {
      off += prefix[k].indices[idx[k]] * prefix[k].byte_pstride;
    } else {  /* SHIFT */
      ca_size_t pi = prefix[k].shift_start + idx[k] * prefix[k].shift_step;
      if ( pi < 0 || pi >= prefix[k].size0 ) {
        pi = ca_bounds_normalize_index(prefix[k].policy,
                                       prefix[k].size0, pi);
        if ( pi < 0 || pi >= prefix[k].size0 ) {
          *oob = 1;
          return 0;
        }
      }
      off += pi * prefix[k].byte_pstride;
    }
  }
  return off;
}

/* Per-slab callback driver (T1 Phase 0 P3, 2026-05-25).  The engine
   walks the (post-merge / post-layout) prefix axes row-major and for
   each iteration invokes `cb` with:
     slab_ptr  = parent->ptr + composed_offset
     oob       = SHIFT-axis out-of-bounds flag (0 = in-bounds)
     slab_n    = slab span in bytes (constant across iters)
     ctx       = caller cookie (callback advances its own buf position)

   gather / scatter / fill_value are now thin callback wrappers around
   this driver; future ca_kernel_iterator.c will use the same primitive
   (with its own user-kernel-wrapping callback) for descriptor-routed
   slab walks. */
/* slab_off is the slab's byte offset into the parent, not a pointer into it:
   a fill that means to write through the parent's own slots rather than a
   borrowed buffer has no parent->ptr to offset from.  Callbacks that do want
   the pointer add parent->ptr themselves, from their own ctx. */
typedef void (*ca_slab_cb_t) (ca_size_t   slab_off,
                              int         oob,
                              ca_size_t   slab_n,
                              void       *ctx);

void ca_axis_dispatch_for_each_slab (CArray          *parent,
                                     const ca_size_t *parent_axis_dims,
                                     ca_axis_desc_t  *axes,
                                     int8_t           ndim,
                                     ca_size_t        bytes,
                                     ca_size_t        total_elements,
                                     ca_slab_cb_t     cb,
                                     void            *ctx);

/* ==========================================================================
   ca_obj_stride.c substrate
   ========================================================================== */

/* Strided gather/scatter with caller-provided strides+base (used by the
   compose-fold copy_data/sync_data path and by future kernel_iterator
   non-contig CAStride scratch path). */
void ca_stride_xfer_with_layout (CAStride *ca, int scatter, char *base,
                                 const ca_size_t *strides);

/* Shared strided-region walker for ca_xfer_stride_dispatch (carray_core.c)
   and ca_stride_func_xfer_stride (ca_obj_stride.c).  Caller computes any
   base offset into src_base and supplies byte strides in src_strides[];
   the helper applies slab merge, 2-D tile-block transpose at the inner
   pair, and a general outer-prefix odometer with per-iter slab memcpy.
   `data` is the contig side (row-major over counts in `bytes` per cell).
   `dir` is CA_XFER_GET (src -> data) or CA_XFER_PUT (data -> src).
   XFER_REFORM_DEFERRED C.2 sub-A, 2026-05-31. */
void ca_xfer_strided_walk (char            *src_base,
                           ca_size_t        bytes,
                           int8_t           ndim,
                           const ca_size_t *counts,
                           const ca_size_t *src_strides,
                           char            *data,
                           int              dir);

/* In-place merge of adjacent CAStride axes whose strides compose to a
   contig run. PROPOSAL_AXIS_MERGE Phase 1 (CAStride 0a). */
void ca_stride_merge_axes (ca_size_t *strides,
                           ca_size_t *dim,
                           int8_t    *ndim_inout);

/* Typed strided gather/scatter for one row of n cells of `bytes` width.
   strided_step is byte stride (may be negative).  Moved to the header as
   `static inline` (PROPOSAL_TRANSFORM_FUSED_XFER 2026-05-31 + T10 perf fix):
   both ca_obj_stride.c (xfer_with_layout general driver) and
   ca_transform_common.c (fused walk) need this hot, so keep the typed
   inner loops inlinable at every call site. */
#define CA_STRIDE_GATHER_TYPED(T)                                     \
  do {                                                                \
    T *dp = (T *) contig;                                             \
    const char *sp = strided;                                         \
    ca_size_t i;                                                      \
    for (i = 0; i < n; i++) {                                         \
      T v;                                                            \
      memcpy(&v, sp, sizeof(T));                                      \
      *dp++ = v;                                                      \
      sp += strided_step;                                             \
    }                                                                 \
  } while (0)

#define CA_STRIDE_SCATTER_TYPED(T)                                    \
  do {                                                                \
    char *dp = strided;                                               \
    const T *sp = (const T *) contig;                                 \
    ca_size_t i;                                                      \
    for (i = 0; i < n; i++) {                                         \
      T v = *sp++;                                                    \
      memcpy(dp, &v, sizeof(T));                                      \
      dp += strided_step;                                             \
    }                                                                 \
  } while (0)

static inline void
ca_stride_gather_run (char *contig, const char *strided,
                      ca_size_t bytes, ca_size_t n, ca_size_t strided_step)
{
  if (strided_step == bytes) {
    memcpy(contig, strided, n * bytes);
    return;
  }
  switch (bytes) {
  case 1:  CA_STRIDE_GATHER_TYPED(int8_t);  return;
  case 2:  CA_STRIDE_GATHER_TYPED(int16_t); return;
  case 4:  CA_STRIDE_GATHER_TYPED(int32_t); return;
  case 8:  CA_STRIDE_GATHER_TYPED(int64_t); return;
  default: break;
  }
  ca_size_t i;
  for (i = 0; i < n; i++) {
    memcpy(contig, strided, bytes);
    contig += bytes;
    strided += strided_step;
  }
}

static inline void
ca_stride_scatter_run (char *strided, const char *contig,
                       ca_size_t bytes, ca_size_t n, ca_size_t strided_step)
{
  if (strided_step == bytes) {
    memcpy(strided, contig, n * bytes);
    return;
  }
  switch (bytes) {
  case 1:  CA_STRIDE_SCATTER_TYPED(int8_t);  return;
  case 2:  CA_STRIDE_SCATTER_TYPED(int16_t); return;
  case 4:  CA_STRIDE_SCATTER_TYPED(int32_t); return;
  case 8:  CA_STRIDE_SCATTER_TYPED(int64_t); return;
  default: break;
  }
  ca_size_t i;
  for (i = 0; i < n; i++) {
    memcpy(strided, contig, bytes);
    strided += strided_step;
    contig += bytes;
  }
}

/* ==========================================================================
   ca_transform_common.c substrate
   (PROPOSAL_TRANSFORM_FUSED_XFER rev3, 2026-05-31)
   ========================================================================== */

/* Per-view transform callback for a contig row of n cells (GET or PUT).
   `src` is parent_bytes per cell, `dst` is view_bytes per cell (or swapped
   for PUT).  Used by ca_xfer_stride_transform_fused. */
typedef void (*ca_transform_row_fn)(
    ca_size_t n,
    CArray *src_arr, char *src_row,
    CArray *dst_arr, char *dst_row);

/* Fused walk: compose to root, then per-inner-row gather + transform (GET)
   or transform + scatter (PUT).  No whole-view scratch, no ca_attach.
   Returns 1 on success, 0 if eligibility check fails (caller falls back). */
int ca_xfer_stride_transform_fused (
    CArray   *view,
    CArray   *parent,
    ca_size_t *starts,
    ca_size_t *counts,
    ca_size_t *strides,
    char     *data,
    int       dir,
    ca_transform_row_fn xform_get,
    ca_transform_row_fn xform_put);

/* ==========================================================================
   F-2 (PROPOSAL_F2_KERNEL_ITERATOR_ALIAS rev6): innermost-STRIDE L2 alias
   ========================================================================== */

/* Predicate: innermost axis (= descs[ndim-1]) is STRIDE kind.  This is the
   minimum requirement for L2 strided alias of a descriptor-routed view
   (CAWindow / CAShift / CSA / CAGrid).  Outer axes may be any kind
   (STRIDE / INDEX / SHIFT); they are walked by the prefix iterator and
   per-iter offset is computed via ca_axis_dispatch_prefix_offset. */
int ca_axis_dispatch_is_innermost_stride (const ca_axis_desc_t *descs,
                                          int8_t                ndim);

/* Predicate: any outer axis (= descs[0..ndim-2]) is SHIFT kind.  When
   true, the L2 alias init must allocate a fill-slab scratch buffer so
   OOB cells in the outer prefix walk yield a contig fill slab instead
   of an out-of-bounds alias pointer.  When false, alias mode can yield
   parent.ptr + offset directly for every outer iteration. */
int ca_axis_dispatch_outer_has_shift (const ca_axis_desc_t *descs,
                                      int8_t                ndim);

#endif /* CA_ITER_SUBSTRATE_H */
