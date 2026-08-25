/* ---------------------------------------------------------------------------

  Per-axis descriptor common engine.  Provides gather / scatter /
  fill_value / for_each_slab primitives shared by CSA, CAGrid, and
  other axis-descriptor-emitting views.

  Single-loop algorithm (shared by gather and scatter):
    0. Merge adjacent contig-mergeable STRIDE descriptor axes in
       place.  This reduces N-d strided iteration patterns that are
       internally contiguous to a single STRIDE axis spanning the
       merged span, before the slab detector or prefix iterator run.
    1. Identify the innermost run of consecutive STRIDE-step1 axes
       that form a contiguous sub-rectangle in parent row-major.
       That run is the "slab" — one memcpy per outer iteration.
    2. Iterate the remaining (prefix) axes row-major.  Each axis may
       be STRIDE or INDEX; both contribute to the parent offset
       uniformly.
    3. Output / input buffer is contiguous row-major over the view
       shape; the slab span is transferred per iteration.

  Slab degenerates naturally:
    - slab covers all axes        -> single memcpy from a single offset
    - slab covers no axes         -> per-cell memcpy (slab_bytes = bytes)
    - mixed                       -> per-iteration slab memcpy

  Contig criterion for the slab run: walking innermost -> outward
  through the run, once we see an axis with count < mdim[k], every
  outer axis in the run must have count == 1.  This guarantees the
  slab span is a tight prefix of a parent row.  (`mdim[k]` is the
  *effective* parent dim per axis after axis-merge — equal to
  parent->dim[k] for unmerged axes.)

  Scatter semantics:
    - Iteration order = output row-major
      (= axes[k].count outer-to-inner).
    - Duplicate INDEX values write the same parent cell multiple
      times; last-write-wins is the natural memcpy-based result.
      The engine does not check or assume uniqueness.

---------------------------------------------------------------------------- */

#include "carray.h"
#include "ca_iter_substrate.h"
#include "ca_composite_dispatch.h"

#include <string.h>

/* Compute parent row-major byte strides from a dimension array. */
static void
ca_axis_dispatch_build_pstrides (ca_size_t       *pstrides,
                                 const ca_size_t *dim,
                                 int8_t           ndim,
                                 ca_size_t        bytes)
{
  ca_size_t s = bytes;
  int8_t    k;
  for ( k = ndim - 1; k >= 0; k-- ) {
    pstrides[k] = s;
    s *= dim[k];
  }
}

/* In-place merge of adjacent contig-mergeable STRIDE descriptor
   axes.

   Inputs (all arrays sized CA_RANK_MAX):
     axes      - descriptor array
     pstrides  - parent byte stride per axis (derived from mdim/bytes)
     mdim      - effective parent dim per axis (parent->dim initially)
     ndim_inout - read and written

   Merge condition for adjacent k, k+1 (both must be STRIDE):
     step[k] * pstrides[k] == count[k+1] * step[k+1] * pstrides[k+1]
   i.e. one full traversal of axis k+1's `count` cells at its effective
   byte stride exactly equals one step of axis k.  Under this condition
   the two axes describe a single uniform-stride traversal of
   count[k]*count[k+1] cells representable as one STRIDE axis.

   Post-merge values for the surviving axis (placed at position k):
     start    = start[k] * mdim[k+1] + start[k+1]
     count    = count[k] * count[k+1]
     step     = step[k+1]
     pstride  = pstrides[k+1]
     mdim     = mdim[k] * mdim[k+1]

   INDEX axes act as fences (merge is not attempted across them).
   Sign-agnostic: works for negative steps as long as the equation
   holds.  Iterates to fixpoint. */
void
ca_axis_dispatch_merge (ca_axis_desc_t *axes,
                        ca_size_t      *pstrides,
                        ca_size_t      *mdim,
                        int8_t         *ndim_inout)
{
  int8_t ndim = *ndim_inout;
  int8_t k, j;
  int    changed;

  do {
    changed = 0;
    for ( k = 0; k + 1 < ndim; k++ ) {
      if ( axes[k].kind   != CA_AXIS_KIND_STRIDE ) continue;
      if ( axes[k+1].kind != CA_AXIS_KIND_STRIDE ) continue;

      ca_size_t ebs_k   = axes[k].step   * pstrides[k];
      ca_size_t ebs_kp1 = axes[k+1].step * pstrides[k+1];

      /* Defensive: a zero effective inner stride would make the
         equation degenerate; skip.  (Genuine stride-0 / CARepeat
         axes don't reach this engine - they go through CAStride.) */
      if ( ebs_kp1 == 0 ) continue;

      if ( ebs_k != axes[k+1].count * ebs_kp1 ) continue;

      /* Merge k and k+1 into a single STRIDE axis at position k. */
      axes[k].start   = axes[k].start * mdim[k+1] + axes[k+1].start;
      axes[k].count   = axes[k].count * axes[k+1].count;
      axes[k].step    = axes[k+1].step;
      axes[k].indices = NULL;
      pstrides[k]     = pstrides[k+1];
      mdim[k]         = mdim[k] * mdim[k+1];

      /* Shift remaining left. */
      for ( j = k + 1; j + 1 < ndim; j++ ) {
        axes[j]     = axes[j+1];
        pstrides[j] = pstrides[j+1];
        mdim[j]     = mdim[j+1];
      }
      ndim--;
      changed = 1;
      break;  /* restart scan from index 0 */
    }
  } while ( changed );

  *ndim_inout = ndim;
}

/* Slab detection: identify the innermost STRIDE-step1 contig run.
   Operates on the (possibly merged) axes and the matching `mdim`
   (effective parent dim per axis).

   On return:
     *slab_start   = innermost prefix axis index (exclusive); ndim if
                     no slab axis exists
     *slab_bytes   = product of slab axes' counts * bytes
     *slab_base    = sum of slab axes' (start * pstrides) - INDEX axes
                     never enter the slab, so this is well-defined */
void
ca_axis_dispatch_layout (ca_axis_desc_t  *axes,
                         const ca_size_t *pstrides,
                         const ca_size_t *mdim,
                         int8_t           ndim,
                         ca_size_t        bytes,
                         int8_t          *slab_start,
                         ca_size_t       *slab_bytes,
                         ca_size_t       *slab_base)
{
  int8_t k;

  /* Identify innermost slab run of STRIDE-step1 axes that's contig in
     parent.  saw_partial: once a partial axis (count < mdim[k]) is
     seen, every outer axis in the run must have count == 1. */
  int8_t    sstart = ndim;
  ca_size_t sbytes = bytes;
  {
    int saw_partial = 0;
    for ( k = ndim - 1; k >= 0; k-- ) {
      if ( axes[k].kind != CA_AXIS_KIND_STRIDE ) break;
      if ( axes[k].step != 1                  ) break;
      if ( saw_partial ) {
        if ( axes[k].count != 1 ) break;
      } else if ( axes[k].count != mdim[k] ) {
        saw_partial = 1;
      }
      sstart = k;
      sbytes *= axes[k].count;
    }
  }
  *slab_start = sstart;
  *slab_bytes = sbytes;

  /* Slab base offset in parent (sum of axes[k].start * pstrides[k]
     for axes in the slab run; INDEX axes never enter the slab). */
  ca_size_t base = 0;
  for ( k = sstart; k < ndim; k++ ) {
    base += axes[k].start * pstrides[k];
  }
  *slab_base = base;
}

/* Build merged layout from caller-provided axes/ndim/parent_axis_dims.
   Copies into the caller's out_* arrays (each must be sized
   CA_RANK_MAX), builds pstrides, runs the axis-merge pass to fixpoint,
   and writes the merged ndim into *out_ndim.  Subsequent code uses
   only the out_* arrays - parent->dim is intentionally NOT referenced;
   the producer's `parent_axis_dims[]` carries the effective per-axis
   dim.  This is what allows flat-index views to claim parent.ndim = 1
   even though parent->ndim > 1 physically. */
void
ca_axis_dispatch_prepare (const ca_size_t      *parent_axis_dims,
                          const ca_axis_desc_t *axes,
                          int8_t                ndim,
                          ca_size_t             bytes,
                          ca_axis_desc_t       *out_axes,
                          ca_size_t            *out_pstrides,
                          ca_size_t            *out_mdim,
                          int8_t               *out_ndim)
{
  int8_t k;
  for ( k = 0; k < ndim; k++ ) {
    out_axes[k] = axes[k];
    out_mdim[k] = parent_axis_dims[k];
  }
  ca_axis_dispatch_build_pstrides(out_pstrides, out_mdim, ndim, bytes);
  *out_ndim = ndim;
  ca_axis_dispatch_merge(out_axes, out_pstrides, out_mdim, out_ndim);
}

/* The prefix-axis typedefs (ca_op_axis_kind_t, ca_op_prefix_axis_t)
   and the inline offset helper (ca_axis_dispatch_prefix_offset) live
   in ca_iter_substrate.h.  See that header for declarations. */

/* Build pre-classified prefix axis array from the (post-merge, post-
   layout) axes/pstrides for indices [0..slab_start-1].  Algebraically
   equivalent to the raw inline computation; precomputes byte-unit
   start/step so the inner loop does one multiply per STRIDE axis and
   one indirect load + one multiply per INDEX axis (vs. two multiplies
   per STRIDE axis in the raw form).  SHIFT axes keep start/step in
   element units (for ca_bounds_normalize_index) and carry size0 /
   policy from the descriptor. */
void
ca_axis_dispatch_classify_prefix (const ca_axis_desc_t *axes,
                                  const ca_size_t      *pstrides,
                                  int8_t                slab_start,
                                  ca_op_prefix_axis_t  *prefix)
{
  int8_t k;
  for ( k = 0; k < slab_start; k++ ) {
    prefix[k].count = axes[k].count;
    if ( axes[k].kind == CA_AXIS_KIND_STRIDE ) {
      prefix[k].kind         = CA_OP_AXIS_STRIDE;
      prefix[k].byte_start   = axes[k].start * pstrides[k];
      prefix[k].byte_step    = axes[k].step  * pstrides[k];
      prefix[k].indices      = NULL;
      prefix[k].byte_pstride = 0;
    } else if ( axes[k].kind == CA_AXIS_KIND_INDEX ) {
      prefix[k].kind         = CA_OP_AXIS_INDEX;
      prefix[k].byte_start   = 0;
      prefix[k].byte_step    = 0;
      prefix[k].indices      = axes[k].indices;
      prefix[k].byte_pstride = pstrides[k];
    } else {  /* CA_AXIS_KIND_SHIFT */
      prefix[k].kind         = CA_OP_AXIS_SHIFT;
      prefix[k].byte_start   = 0;
      prefix[k].byte_step    = 0;
      prefix[k].indices      = NULL;
      prefix[k].byte_pstride = pstrides[k];
      prefix[k].shift_start  = axes[k].start;
      prefix[k].shift_step   = axes[k].step;
      prefix[k].size0        = axes[k].size0;
      prefix[k].policy       = axes[k].policy;
    }
  }
}

/* ca_axis_dispatch_prefix_offset moved to ca_iter_substrate.h
   (static inline so it inlines into _xfer / _fill_value below and into
   other consumer TUs such as ca_kernel_iterator.c). */

/* Fill every selected parent cell with `val` (bytes-wide).  Shares
   the slab layout helper with gather/scatter; the inner write is a
   per-element memcpy from `val` (the slab might be wider than one
   element, e.g. when consecutive STRIDE axes form a contig run, so we
   iterate within the slab).

   Used by func_fill_data (e.g. `view[nil] = scalar` / `view.fill(x)`)
   and by the per-slab callbacks below.

   Delegates to `ca_fill_typed` for SIMD-friendly typed-store loops
   (4-byte / 8-byte typed stores that the compiler autovectorises on
   NEON / SSE2), avoiding a per-element memcpy loop. */
static void
ca_axis_dispatch_fill_slab (char *dst, const void *val,
                            ca_size_t bytes, ca_size_t slab_bytes)
{
  ca_size_t n = slab_bytes / bytes;
  ca_fill_typed(dst, (const char *) val, bytes, n);
}

/* Generic per-slab driver (`ca_axis_dispatch_for_each_slab`) plus
   thin gather / scatter / fill_value callbacks around it.  The
   kernel_iterator descriptor path hooks into the driver for
   descriptor-routed slab walks.

   The all-slab fast path (slab_start == 0) is preserved as a single
   cb invocation — no special-casing; the same cb decides what to do
   with the slab. */

/* Callback context for gather / scatter (they share the layout - both
   carry a buf+off cursor and gather additionally carries bound_fill). */
typedef struct {
  char         *buf;
  ca_size_t     off;
  const void   *bound_fill;
  ca_size_t     bytes;
  char         *parent_ptr;
} ca_axis_xfer_ctx_t;

static void
ca_axis_dispatch_gather_cb (ca_size_t off, int oob, ca_size_t n, void *vctx)
{
  ca_axis_xfer_ctx_t *c = (ca_axis_xfer_ctx_t *) vctx;
  char *p = c->parent_ptr + off;
  if ( oob ) {
    /* gather + OOB: write bound_fill across the slab (if provided);
       otherwise leave the output cells untouched. */
    if ( c->bound_fill ) {
      ca_axis_dispatch_fill_slab(c->buf + c->off, c->bound_fill,
                                 c->bytes, n);
    }
  } else {
    memcpy(c->buf + c->off, p, n);
  }
  c->off += n;
}

static void
ca_axis_dispatch_scatter_cb (ca_size_t off, int oob, ca_size_t n, void *vctx)
{
  ca_axis_xfer_ctx_t *c = (ca_axis_xfer_ctx_t *) vctx;
  char *p = c->parent_ptr + off;
  /* scatter + OOB: skip parent write entirely. */
  if ( ! oob ) {
    memcpy(p, c->buf + c->off, n);
  }
  c->off += n;
}

/* Callback context for fill_value (broadcast a single value).  parent is set
   when the value goes through the parent's own fill_stride instead of a
   buffer this side has attached. */
typedef struct {
  const void *val;
  ca_size_t   bytes;
  char       *parent_ptr;
  CArray     *parent;
} ca_axis_fill_ctx_t;

static void
ca_axis_dispatch_fill_value_cb (ca_size_t off, int oob, ca_size_t n, void *vctx)
{
  ca_axis_fill_ctx_t *c = (ca_axis_fill_ctx_t *) vctx;
  if ( oob ) return;
  if ( c->parent ) {
    /* One slab is one contiguous run of parent cells, which is a region the
       parent can fill for itself -- no borrowed buffer, so nothing outside
       the run is read or written. */
    ca_size_t count = n / c->bytes;
    ca_size_t step  = 1;
    ca_fill_stride(c->parent, off / c->bytes, 1, &count, &step,
                   (void *) c->val);
  }
  else {
    ca_axis_dispatch_fill_slab(c->parent_ptr + off, c->val, c->bytes, n);
  }
}

/* Generic per-slab driver.  Walks the (post-merge / post-layout)
   prefix axes row-major and invokes `cb` once per slab iteration.
   The all-slab case degenerates to a single `cb` invocation with
   oob = 0.  Empty views (total_elements == 0) yield no callbacks.

   The callback advances its own buf/value cursor via `ctx` -- the
   driver carries no per-slab cursor state. */
void
ca_axis_dispatch_for_each_slab (CArray          *parent,
                                const ca_size_t *parent_axis_dims,
                                ca_axis_desc_t  *axes,
                                int8_t           ndim,
                                ca_size_t        bytes,
                                ca_size_t        total_elements,
                                ca_slab_cb_t     cb,
                                void            *ctx)
{
  ca_axis_desc_t      laxes[CA_RANK_MAX];
  ca_size_t           pstrides[CA_RANK_MAX];
  ca_size_t           mdim[CA_RANK_MAX];
  ca_size_t           idx[CA_RANK_MAX];
  ca_op_prefix_axis_t prefix[CA_RANK_MAX];
  int8_t              lndim;
  int8_t              slab_start;
  ca_size_t           slab_bytes, slab_base;
  int8_t              k;

  if ( total_elements == 0 ) {
    return;
  }

  ca_axis_dispatch_prepare(parent_axis_dims, axes, ndim, bytes,
                           laxes, pstrides, mdim, &lndim);
  ca_axis_dispatch_layout(laxes, pstrides, mdim, lndim, bytes,
                          &slab_start, &slab_bytes, &slab_base);

  /* All-slab fast path: single cb invocation.  Slab detection breaks
     on kind != STRIDE, so SHIFT axes never enter this branch and
     oob = 0 is guaranteed. */
  if ( slab_start == 0 ) {
    cb(slab_base, 0, slab_bytes, ctx);
    return;
  }

  /* Pre-classify prefix axes once.  Inner loop becomes branchless
     modulo a per-axis kind tag whose value is constant across
     iters. */
  ca_axis_dispatch_classify_prefix(laxes, pstrides, slab_start, prefix);

  /* General path: iterate prefix axes [0..slab_start-1] row-major,
     invoke cb per iteration. */
  for ( k = 0; k < slab_start; k++ ) idx[k] = 0;

  ca_size_t n_iters = total_elements / (slab_bytes / bytes);
  ca_size_t n;
  for ( n = 0; n < n_iters; n++ ) {
    int oob;
    ca_size_t poff = slab_base
                   + ca_axis_dispatch_prefix_offset(prefix, idx,
                                                    slab_start, &oob);
    cb(poff, oob, slab_bytes, ctx);

    /* Advance idx row-major over prefix axes. */
    for ( k = slab_start - 1; k >= 0; k-- ) {
      if ( ++idx[k] < prefix[k].count ) break;
      idx[k] = 0;
    }
  }
}

/* Per-cell gather/scatter fast path.

   When `ca_axis_dispatch_layout` cannot extend the innermost slab
   run (innermost axis is INDEX, or STRIDE with step != 1)
   `slab_bytes` degenerates to `bytes`.  The generic for_each_slab
   loop would then run `total_elements` callback invocations, each
   doing a runtime-size memcpy of one cell — the function-pointer cb
   blocks inlining and the runtime size blocks typed-store
   specialisation.

   When in per-cell mode AND the inner axis is STRIDE/INDEX, bypass
   the cb and hoist the innermost axis as a kind-specialised,
   bytes-typed inner loop.  Outer axes still ride the prefix
   odometer.  SHIFT inner falls back to for_each_slab (its OOB
   semantics live in the cb).  `bytes` not in {1,2,4,8} falls back to
   memcpy in the inner loop, still winning from removing cb dispatch
   and the outer-only odometer. */

static void
ca_axis_dispatch_percell_gather (CArray          *parent,
                                 ca_axis_desc_t  *laxes,
                                 const ca_size_t *pstrides,
                                 int8_t           lndim,
                                 ca_size_t        bytes,
                                 ca_size_t        slab_base,
                                 const void      *bound_fill,
                                 char            *out_buf)
{
  int8_t              inner    = lndim - 1;
  int8_t              outers_n = inner;
  ca_op_prefix_axis_t outer_prefix[CA_RANK_MAX];
  ca_size_t           outer_idx[CA_RANK_MAX];
  ca_size_t           n_outer = 1;
  int8_t              k;

  if ( outers_n > 0 ) {
    ca_axis_dispatch_classify_prefix(laxes, pstrides, outers_n, outer_prefix);
    for ( k = 0; k < outers_n; k++ ) {
      outer_idx[k] = 0;
      n_outer *= outer_prefix[k].count;
    }
  }

  ca_axis_kind_t   inner_kind     = laxes[inner].kind;
  ca_size_t        inner_count    = laxes[inner].count;
  ca_size_t        inner_pstride  = pstrides[inner];
  ca_size_t        inner_base     = laxes[inner].start * inner_pstride;
  ca_size_t        inner_step     = laxes[inner].step  * inner_pstride;
  const ca_size_t *inner_indices  = laxes[inner].indices;
  ca_size_t        row_dst_bytes  = inner_count * bytes;

  ca_size_t no;
  for ( no = 0; no < n_outer; no++ ) {
    int       oob = 0;
    ca_size_t outer_off = 0;
    if ( outers_n > 0 ) {
      outer_off = ca_axis_dispatch_prefix_offset(outer_prefix, outer_idx,
                                                  outers_n, &oob);
    }
    char *row_dst = out_buf + no * row_dst_bytes;

    if ( oob ) {
      if ( bound_fill ) {
        ca_axis_dispatch_fill_slab(row_dst, bound_fill, bytes, row_dst_bytes);
      }
    }
    else {
      char     *row_src_base = parent->ptr + slab_base + outer_off;
      ca_size_t j;
      if ( inner_kind == CA_AXIS_KIND_STRIDE ) {
        char *src = row_src_base + inner_base;
        switch ( bytes ) {
          case 1:
            for (j = 0; j < inner_count; j++)
              *(uint8_t  *)(row_dst + j)     = *(uint8_t  *)(src + j*inner_step);
            break;
          case 2:
            for (j = 0; j < inner_count; j++)
              *(uint16_t *)(row_dst + j*2)   = *(uint16_t *)(src + j*inner_step);
            break;
          case 4:
            for (j = 0; j < inner_count; j++)
              *(uint32_t *)(row_dst + j*4)   = *(uint32_t *)(src + j*inner_step);
            break;
          case 8:
            for (j = 0; j < inner_count; j++)
              *(uint64_t *)(row_dst + j*8)   = *(uint64_t *)(src + j*inner_step);
            break;
          default:
            for (j = 0; j < inner_count; j++)
              memcpy(row_dst + j*bytes, src + j*inner_step, bytes);
            break;
        }
      }
      else {  /* CA_AXIS_KIND_INDEX */
        switch ( bytes ) {
          case 1:
            for (j = 0; j < inner_count; j++)
              *(uint8_t  *)(row_dst + j) =
                *(uint8_t  *)(row_src_base + inner_indices[j]*inner_pstride);
            break;
          case 2:
            for (j = 0; j < inner_count; j++)
              *(uint16_t *)(row_dst + j*2) =
                *(uint16_t *)(row_src_base + inner_indices[j]*inner_pstride);
            break;
          case 4:
            for (j = 0; j < inner_count; j++)
              *(uint32_t *)(row_dst + j*4) =
                *(uint32_t *)(row_src_base + inner_indices[j]*inner_pstride);
            break;
          case 8:
            for (j = 0; j < inner_count; j++)
              *(uint64_t *)(row_dst + j*8) =
                *(uint64_t *)(row_src_base + inner_indices[j]*inner_pstride);
            break;
          default:
            for (j = 0; j < inner_count; j++)
              memcpy(row_dst + j*bytes,
                     row_src_base + inner_indices[j]*inner_pstride, bytes);
            break;
        }
      }
    }

    if ( outers_n > 0 ) {
      for ( k = outers_n - 1; k >= 0; k-- ) {
        if ( ++outer_idx[k] < outer_prefix[k].count ) break;
        outer_idx[k] = 0;
      }
    }
  }
}

/* Gather engine: fill a caller-provided buffer with the view's
   data.  Caller must have parent->ptr valid (parent attached) and
   `out_buf` large enough to hold total_elements * bytes.

   Generic path is a thin wrapper around `for_each_slab`; per-cell
   mode (slab_bytes == bytes, inner ∈ {STRIDE, INDEX}) dispatches to
   the specialised inner-axis-hoisted loop above. */
void
ca_axis_dispatch_gather (CArray          *parent,
                         const ca_size_t *parent_axis_dims,
                         ca_axis_desc_t  *axes,
                         int8_t           ndim,
                         ca_size_t        bytes,
                         ca_size_t        total_elements,
                         const void      *bound_fill,
                         char            *out_buf)
{
  ca_axis_desc_t laxes[CA_RANK_MAX];
  ca_size_t      pstrides[CA_RANK_MAX];
  ca_size_t      mdim[CA_RANK_MAX];
  int8_t         lndim, sstart;
  ca_size_t      sbytes, sbase;

  if ( total_elements == 0 ) return;

  ca_axis_dispatch_prepare(parent_axis_dims, axes, ndim, bytes,
                           laxes, pstrides, mdim, &lndim);
  ca_axis_dispatch_layout(laxes, pstrides, mdim, lndim, bytes,
                          &sstart, &sbytes, &sbase);

  if ( sstart == lndim && lndim >= 1
       && (laxes[lndim-1].kind == CA_AXIS_KIND_STRIDE
           || laxes[lndim-1].kind == CA_AXIS_KIND_INDEX) ) {
    ca_axis_dispatch_percell_gather(parent, laxes, pstrides, lndim, bytes,
                                     sbase, bound_fill, out_buf);
    return;
  }

  /* Row-select fast path: outer = single INDEX axis, slab inner
     promoted (row-major boolean/fancy select + materialise).  An
     inlined tight loop replaces `for_each_slab`'s function-pointer
     cb dispatch on the dataframe-like row-select idiom.
     Eligibility:
       - sstart == 1 (exactly one prefix axis outside the slab)
       - the prefix axis is INDEX (= no OOB, no SHIFT)
       - parent->ptr attached (cold path stays on for_each_slab). */
  if ( sstart == 1
       && laxes[0].kind == CA_AXIS_KIND_INDEX
       && parent->ptr != NULL ) {
    const ca_size_t *indices = laxes[0].indices;
    ca_size_t        n       = laxes[0].count;
    ca_size_t        pstride = pstrides[0];
    char            *base    = parent->ptr + sbase;
    ca_size_t        i;
    /* Hot bytes specializations using __builtin_memcpy with literal size
       so clang lowers to NEON ldp/stp directly (no libc memcpy call). */
    if ( sbytes == 8 ) {
      for ( i = 0; i < n; i++ ) {
        *(uint64_t *)(out_buf + i*8) =
          *(uint64_t *)(base + indices[i] * pstride);
      }
    } else if ( sbytes == 16 ) {
      for ( i = 0; i < n; i++ ) {
        __builtin_memcpy(out_buf + i*16, base + indices[i] * pstride, 16);
      }
    } else if ( sbytes == 32 ) {
      for ( i = 0; i < n; i++ ) {
        __builtin_memcpy(out_buf + i*32, base + indices[i] * pstride, 32);
      }
    } else if ( sbytes == 64 ) {
      for ( i = 0; i < n; i++ ) {
        __builtin_memcpy(out_buf + i*64, base + indices[i] * pstride, 64);
      }
    } else if ( sbytes == 128 ) {
      for ( i = 0; i < n; i++ ) {
        __builtin_memcpy(out_buf + i*128, base + indices[i] * pstride, 128);
      }
    } else if ( sbytes == 256 ) {
      for ( i = 0; i < n; i++ ) {
        __builtin_memcpy(out_buf + i*256, base + indices[i] * pstride, 256);
      }
    } else {
      for ( i = 0; i < n; i++ ) {
        memcpy(out_buf + i * sbytes, base + indices[i] * pstride, sbytes);
      }
    }
    return;
  }

  {
    ca_axis_xfer_ctx_t ctx = {
      .buf = out_buf, .off = 0, .bound_fill = bound_fill, .bytes = bytes,
      .parent_ptr = parent->ptr
    };
    ca_axis_dispatch_for_each_slab(parent, parent_axis_dims, axes, ndim,
                                   bytes, total_elements,
                                   ca_axis_dispatch_gather_cb, &ctx);
  }
}

/* Allocate-and-gather wrapper.  Returns a malloced buffer of size
   total_elements * bytes (or a 1-byte placeholder when total_elements
   == 0; avoids malloc(0) implementation variance).  Caller must xfree. */
char *
ca_axis_dispatch_attach (CArray          *parent,
                         const ca_size_t *parent_axis_dims,
                         ca_axis_desc_t  *axes,
                         int8_t           ndim,
                         ca_size_t        bytes,
                         ca_size_t        total_elements,
                         const void      *bound_fill)
{
  ca_size_t out_len = total_elements * bytes;
  char *out = xmalloc(out_len > 0 ? out_len : 1);
  ca_axis_dispatch_gather(parent, parent_axis_dims, axes, ndim, bytes,
                          total_elements, bound_fill, out);
  return out;
}

/* Scatter engine: write the caller-provided buffer back into
   parent.  Caller must have parent->ptr valid (parent attached) and
   `in_buf` sized total_elements * bytes.

   Semantics: output row-major iteration order; duplicate INDEX
   values produce last-write-wins.  Thin wrapper around for_each_slab
   + scatter_cb; per-cell mode dispatches to
   `ca_axis_dispatch_percell_scatter` below. */
/* Mirror of percell_gather: per-cell PUT path used when slab_bytes ==
   bytes and inner ∈ {STRIDE, INDEX}.  OOB outer rows are skipped (scatter
   semantics). */
static void
ca_axis_dispatch_percell_scatter (CArray          *parent,
                                  ca_axis_desc_t  *laxes,
                                  const ca_size_t *pstrides,
                                  int8_t           lndim,
                                  ca_size_t        bytes,
                                  ca_size_t        slab_base,
                                  const char      *in_buf)
{
  int8_t              inner    = lndim - 1;
  int8_t              outers_n = inner;
  ca_op_prefix_axis_t outer_prefix[CA_RANK_MAX];
  ca_size_t           outer_idx[CA_RANK_MAX];
  ca_size_t           n_outer = 1;
  int8_t              k;

  if ( outers_n > 0 ) {
    ca_axis_dispatch_classify_prefix(laxes, pstrides, outers_n, outer_prefix);
    for ( k = 0; k < outers_n; k++ ) {
      outer_idx[k] = 0;
      n_outer *= outer_prefix[k].count;
    }
  }

  ca_axis_kind_t   inner_kind     = laxes[inner].kind;
  ca_size_t        inner_count    = laxes[inner].count;
  ca_size_t        inner_pstride  = pstrides[inner];
  ca_size_t        inner_base     = laxes[inner].start * inner_pstride;
  ca_size_t        inner_step     = laxes[inner].step  * inner_pstride;
  const ca_size_t *inner_indices  = laxes[inner].indices;
  ca_size_t        row_src_bytes  = inner_count * bytes;

  ca_size_t no;
  for ( no = 0; no < n_outer; no++ ) {
    int       oob = 0;
    ca_size_t outer_off = 0;
    if ( outers_n > 0 ) {
      outer_off = ca_axis_dispatch_prefix_offset(outer_prefix, outer_idx,
                                                  outers_n, &oob);
    }

    if ( !oob ) {
      const char *row_src      = in_buf + no * row_src_bytes;
      char       *row_dst_base = parent->ptr + slab_base + outer_off;
      ca_size_t   j;
      if ( inner_kind == CA_AXIS_KIND_STRIDE ) {
        char *dst = row_dst_base + inner_base;
        switch ( bytes ) {
          case 1:
            for (j = 0; j < inner_count; j++)
              *(uint8_t  *)(dst + j*inner_step) = *(uint8_t  *)(row_src + j);
            break;
          case 2:
            for (j = 0; j < inner_count; j++)
              *(uint16_t *)(dst + j*inner_step) = *(uint16_t *)(row_src + j*2);
            break;
          case 4:
            for (j = 0; j < inner_count; j++)
              *(uint32_t *)(dst + j*inner_step) = *(uint32_t *)(row_src + j*4);
            break;
          case 8:
            for (j = 0; j < inner_count; j++)
              *(uint64_t *)(dst + j*inner_step) = *(uint64_t *)(row_src + j*8);
            break;
          default:
            for (j = 0; j < inner_count; j++)
              memcpy(dst + j*inner_step, row_src + j*bytes, bytes);
            break;
        }
      }
      else {  /* CA_AXIS_KIND_INDEX */
        switch ( bytes ) {
          case 1:
            for (j = 0; j < inner_count; j++)
              *(uint8_t  *)(row_dst_base + inner_indices[j]*inner_pstride) =
                *(uint8_t  *)(row_src + j);
            break;
          case 2:
            for (j = 0; j < inner_count; j++)
              *(uint16_t *)(row_dst_base + inner_indices[j]*inner_pstride) =
                *(uint16_t *)(row_src + j*2);
            break;
          case 4:
            for (j = 0; j < inner_count; j++)
              *(uint32_t *)(row_dst_base + inner_indices[j]*inner_pstride) =
                *(uint32_t *)(row_src + j*4);
            break;
          case 8:
            for (j = 0; j < inner_count; j++)
              *(uint64_t *)(row_dst_base + inner_indices[j]*inner_pstride) =
                *(uint64_t *)(row_src + j*8);
            break;
          default:
            for (j = 0; j < inner_count; j++)
              memcpy(row_dst_base + inner_indices[j]*inner_pstride,
                     row_src + j*bytes, bytes);
            break;
        }
      }
    }

    if ( outers_n > 0 ) {
      for ( k = outers_n - 1; k >= 0; k-- ) {
        if ( ++outer_idx[k] < outer_prefix[k].count ) break;
        outer_idx[k] = 0;
      }
    }
  }
}

void
ca_axis_dispatch_scatter (CArray          *parent,
                          const ca_size_t *parent_axis_dims,
                          ca_axis_desc_t  *axes,
                          int8_t           ndim,
                          ca_size_t        bytes,
                          ca_size_t        total_elements,
                          const char      *in_buf)
{
  ca_axis_desc_t laxes[CA_RANK_MAX];
  ca_size_t      pstrides[CA_RANK_MAX];
  ca_size_t      mdim[CA_RANK_MAX];
  int8_t         lndim, sstart;
  ca_size_t      sbytes, sbase;

  if ( total_elements == 0 ) return;

  ca_axis_dispatch_prepare(parent_axis_dims, axes, ndim, bytes,
                           laxes, pstrides, mdim, &lndim);
  ca_axis_dispatch_layout(laxes, pstrides, mdim, lndim, bytes,
                          &sstart, &sbytes, &sbase);

  if ( sstart == lndim && lndim >= 1
       && (laxes[lndim-1].kind == CA_AXIS_KIND_STRIDE
           || laxes[lndim-1].kind == CA_AXIS_KIND_INDEX) ) {
    ca_axis_dispatch_percell_scatter(parent, laxes, pstrides, lndim, bytes,
                                      sbase, in_buf);
    return;
  }

  {
    /* scatter_cb only reads from buf, so the const_cast is safe.
       bound_fill is irrelevant on scatter (OOB cells are skipped). */
    ca_axis_xfer_ctx_t ctx = {
      .buf = (char *) in_buf, .off = 0, .bound_fill = NULL, .bytes = bytes,
      .parent_ptr = parent->ptr
    };
    ca_axis_dispatch_for_each_slab(parent, parent_axis_dims, axes, ndim,
                                   bytes, total_elements,
                                   ca_axis_dispatch_scatter_cb, &ctx);
  }
}

/* Broadcast-fill engine: write the single value `val` (bytes wide)
   into every selected parent cell.  Caller must have parent->ptr
   valid.

   Semantics: same iteration as scatter (output row-major).  For
   duplicate INDEX values the same value is written N times — the
   end-state is identical to a single write, so last-write-wins is
   trivially satisfied.  Thin wrapper around for_each_slab +
   fill_value_cb. */
void
ca_axis_dispatch_fill_value (CArray          *parent,
                             const ca_size_t *parent_axis_dims,
                             ca_axis_desc_t  *axes,
                             int8_t           ndim,
                             ca_size_t        bytes,
                             ca_size_t        total_elements,
                             const void      *val)
{
  ca_axis_fill_ctx_t ctx = { .val = val, .bytes = bytes,
                             .parent_ptr = parent->ptr, .parent = NULL };
  ca_axis_dispatch_for_each_slab(parent, parent_axis_dims, axes, ndim,
                                 bytes, total_elements,
                                 ca_axis_dispatch_fill_value_cb, &ctx);
}

/* Same walk, but each slab is handed to the parent as a region of its own
   rather than written through a pointer into it.  A gather view whose parent
   has to be materialised to be addressed can then write the cells it selected
   without the parent being pulled in whole and pushed back. */
void
ca_axis_dispatch_fill_value_via_parent (CArray          *parent,
                                        const ca_size_t *parent_axis_dims,
                                        ca_axis_desc_t  *axes,
                                        int8_t           ndim,
                                        ca_size_t        bytes,
                                        ca_size_t        total_elements,
                                        const void      *val)
{
  ca_axis_fill_ctx_t ctx = { .val = val, .bytes = bytes,
                             .parent_ptr = NULL, .parent = parent };
  ca_axis_dispatch_for_each_slab(parent, parent_axis_dims, axes, ndim,
                                 bytes, total_elements,
                                 ca_axis_dispatch_fill_value_cb, &ctx);
}

/* ==========================================================================
   Innermost-STRIDE L2 alias helpers for kernel_iterator descriptor
   source routing.  Called from ca_kernel_iterator.c to decide
   whether the descriptor source can alias into an L2-strided walk.
   ========================================================================== */

int
ca_axis_dispatch_is_innermost_stride (const ca_axis_desc_t *descs,
                                      int8_t                ndim)
{
  if ( ndim <= 0 ) return 0;
  return descs[ndim - 1].kind == CA_AXIS_KIND_STRIDE;
}

int
ca_axis_dispatch_outer_has_shift (const ca_axis_desc_t *descs,
                                  int8_t                ndim)
{
  int8_t k;
  if ( ndim <= 1 ) return 0;
  for ( k = 0; k < ndim - 1; k++ ) {
    if ( descs[k].kind == CA_AXIS_KIND_SHIFT ) return 1;
  }
  return 0;
}
