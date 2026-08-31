/* ---------------------------------------------------------------------------

  Shared substrate for byte-level 1:1 value-transform views (CAFake /
  CAByteSwap).  Implements the "compose to root + walk + transform in
  flight" fast path used by xfer_stride (and indirectly by xfer_all via
  thin-wrapper delegation).

  Design and rationale: devel/PROPOSAL_TRANSFORM_FUSED_XFER.md.

---------------------------------------------------------------------------- */

#include "carray.h"
#include "ca_iter_substrate.h"
#include <string.h>

/* CAStride compose helper (ca_obj_stride.c). */
extern void ca_stride_compose_to_root (CAStride *leaf, CArray **out_root,
                                        ca_size_t *out_strides,
                                        ca_size_t *out_base);
extern ca_operation_function_t ca_stride_func;

/* ---------------------------------------------------------------------------
   ca_xfer_stride_transform_fused

   Walk parent's CAStride chain to its root (an entity with live ptr), then
   for each inner row gather one strided run from root.ptr into a row scratch
   in parent data_type and apply the per-view transform callback to write that
   row to dst in view data_type.  No whole-view scratch, no ca_attach -- a true
   1-pass fused walk for both GET and PUT.

   PUT is symmetric to GET: cast dst (view data_type) into row scratch (parent
   data_type) via xform_put, then scatter row scratch into root.ptr strided.

   Eligibility (returns 0 = fail, caller falls back to its existing path):
     - parent is in the CAStride family (= ca_func[].attach matches)
     - ndim >= 1
     - compose_to_root yields a root with live ptr (= entity / attached)

   Mask: not consulted.  Post-xfer-reform data paths are mask-blind by
   design; mask is propagated on a separate channel.  See
   PROPOSAL_TRANSFORM_FUSED_XFER.md for the audit.

   row scratch sizing: stack 16 KB first, ALLOCV (alloca-like) for larger.

   Callers (= the two transform views that wire xform_get/_put):
     - ext/ca_obj_fake.c       (CAFake; xform = type cast)
     - ext/ca_obj_byte_swap.c  (CAByteSwap; xform = endian swap)
   The ca_transform_row_fn callback contract is declared in
   ext/ca_iter_substrate.h.
--------------------------------------------------------------------------- */

#define CA_TRANSFORM_ROW_STACK_BYTES 16384

int
ca_xfer_stride_transform_fused (CArray   *view,
                                CArray   *parent,
                                ca_size_t *starts,
                                ca_size_t *counts,
                                ca_size_t *strides,
                                char     *data,
                                int       dir,
                                ca_transform_row_fn xform_get,
                                ca_transform_row_fn xform_put)
{
  CArray   *root;
  ca_size_t composed_strides[CA_RANK_MAX];
  ca_size_t composed_base;
  ca_size_t parent_bytes, view_bytes;
  int8_t    ndim, k;
  ca_size_t inner_count, inner_stride;
  ca_size_t row_bytes;
  char     *row_buf;
  char      row_stack[CA_TRANSFORM_ROW_STACK_BYTES];
  volatile VALUE holder = Qnil;
  ca_size_t idx[CA_RANK_MAX];
  ca_size_t outer_total, n, doff;

  /* ---- Eligibility ---- */
  if ( view->ndim < 1 ) return 0;
  if ( dir != CA_XFER_GET && dir != CA_XFER_PUT ) return 0;

  parent_bytes = parent->bytes;
  view_bytes   = view->bytes;
  ndim         = view->ndim;
  /* CAREFUL: must use counts[ndim-1] (the sub-region width), not
     view->dim[ndim-1] (the full view width).  Caller's data buffer is
     sized for counts[], so a sub-region PUT through a CATranspose-of-
     CAFake chain overflows the buffer if the full view dim is used. */
  inner_count  = counts[ndim - 1];
  if ( inner_count == 0 ) return 1;   /* trivially complete */

  /* Compute view's natural row-major byte strides in view byte space. */
  ca_size_t view_native[CA_RANK_MAX];
  {
    ca_size_t s = view_bytes;
    for ( k = ndim - 1; k >= 0; k-- ) {
      view_native[k] = s;
      s *= view->dim[k];
    }
  }

  ca_size_t eff_root_step[CA_RANK_MAX];

  /* ---- Resolve parent's data source: two cases ---- */
  if ( ca_func[parent->obj_type].attach == ca_stride_func.attach ) {
    /* (A) CAStride family parent: compose stride chain down to root.
       composed_strides[k] = root bytes per ONE view cell on axis k
       (already accounts for parent's possibly-permuted layout).
       Requires caller's strides to be natural multiples of view_native[]
       so req_step is integer; otherwise fallback. */
    ca_stride_compose_to_root((CAStride *)parent, &root,
                              composed_strides, &composed_base);
    if ( !root->ptr ) return 0;
    if ( parent->bytes != root->bytes ) return 0;
    /* Per-axis composition below is only meaningful for a request that walks
       our own axes; a transposed / flat request over the view's addresses
       (legal -- see ca_xfer_stride_request_is_axis_box in carray.h) declines
       to the caller's per-cell path. */
    if ( ! ca_xfer_stride_request_is_axis_box(view, starts, counts, strides) ) {
      return 0;
    }

    for ( k = 0; k < ndim; k++ ) {
      if ( view_native[k] == 0 ) return 0;
      if ( strides[k] % view_native[k] != 0 ) return 0;  /* non-natural */
      ca_size_t req_step = strides[k] / view_native[k];
      composed_base    += starts[k] * composed_strides[k];
      eff_root_step[k]  = req_step * composed_strides[k];
    }
  } else if ( parent->ptr ) {
    /* (B) Non-CAStride parent with live ptr (= entity / attached view).
       Parent has linear row-major byte layout: bytes scale uniformly with
       cells via parent_bytes/view_bytes ratio (CAFake is 1:1 shape
       preserving).  Use the universal "OLD CAFake" formula:
         root byte step per axis-k iter = strides[k] * parent_bytes / view_bytes
         root base contribution = starts[k] * parent_native[k]
       This naturally handles transposed/sub-sampled caller strides. */
    root = parent;
    composed_base = 0;
    if ( view_bytes == 0 ) return 0;
    if ( parent_bytes % view_bytes != 0 && view_bytes % parent_bytes != 0 ) return 0;

    ca_size_t parent_native[CA_RANK_MAX];
    {
      ca_size_t s = parent_bytes;
      for ( k = parent->ndim - 1; k >= 0; k-- ) {
        parent_native[k] = s;
        s *= parent->dim[k];
      }
    }
    for ( k = 0; k < ndim; k++ ) {
      composed_base    += starts[k] * parent_native[k];
      eff_root_step[k]  = strides[k] * parent_bytes / view_bytes;
    }
  } else {
    /* Cold non-CAStride boundary (= CASelect etc. without ptr) -- fallback. */
    return 0;
  }

  inner_stride = eff_root_step[ndim - 1];

  /* When the inner row is contig in root (= inner_stride == parent_bytes),
     the scratch gather/scatter is redundant -- xform_get/_put can read or
     write root->ptr+soff directly, saving the row_buf allocation and one
     of the two memory passes per outer row.  Transposed access through
     CATranspose-of-CAFake has inner_stride != parent_bytes and falls
     through to the scratch+gather path.  See
     PROPOSAL_XFER_STRIDE_PER_REGION_GAPS.md. */
  int inner_contig = (inner_stride == parent_bytes);

  /* A 2D tile-cache + bulk-cast variant of this loop was explored and
     reverted: the existing per-row walker already streams source through
     L2/L3, and the tile path loses to per-call cast dispatch overhead
     and an extra untranspose pass.  See
     PROPOSAL_TRANSFORM_FUSED_XFER.md for the rejected-direction record.
     A typed (src,dst)-specialised inner loop is the next candidate. */

  /* ---- Row scratch (parent data_type, inner_count cells) ----
     Skipped when inner_contig is true (= every outer iter uses the
     direct fast path below). */
  row_bytes = inner_count * parent_bytes;
  row_buf   = NULL;
  if ( !inner_contig ) {
    if ( row_bytes <= (ca_size_t)CA_TRANSFORM_ROW_STACK_BYTES ) {
      row_buf = row_stack;
    } else {
      row_buf = ALLOCV_N(char, holder, row_bytes);
    }
  }

  /* ---- Walk outer (ndim-1) axes on odometer ---- */
  outer_total = 1;
  for ( k = 0; k < ndim - 1; k++ ) outer_total *= counts[k];
  for ( k = 0; k < ndim - 1; k++ ) idx[k] = 0;
  doff = 0;

  for ( n = 0; n < outer_total; n++ ) {
    /* Outer offset into root for this inner row. */
    ca_size_t soff = composed_base;
    for ( k = 0; k < ndim - 1; k++ ) soff += idx[k] * eff_root_step[k];

    if ( inner_contig ) {
      /* Inner-row contig in root; no scratch needed. */
      if ( dir == CA_XFER_GET ) {
        xform_get(inner_count, parent, root->ptr + soff,
                  view, data + doff);
      } else {
        xform_put(inner_count, view, data + doff,
                  parent, root->ptr + soff);
      }
    } else if ( dir == CA_XFER_GET ) {
      /* root.ptr+soff strided -> row_buf contig (parent data_type). */
      ca_stride_gather_run(row_buf, root->ptr + soff,
                           parent_bytes, inner_count, inner_stride);
      /* row_buf (parent data_type) -> data+doff (view data_type). */
      xform_get(inner_count, parent, row_buf, view, data + doff);
    } else {
      /* data+doff (view data_type) -> row_buf contig (parent data_type). */
      xform_put(inner_count, view, data + doff, parent, row_buf);
      /* row_buf contig -> root.ptr+soff strided (parent data_type). */
      ca_stride_scatter_run(root->ptr + soff, row_buf,
                            parent_bytes, inner_count, inner_stride);
    }
    doff += inner_count * view_bytes;

    /* Odometer advance over the outer (ndim-1) axes. */
    if ( ndim < 2 ) break;
    k = ndim - 2;
    while ( k >= 0 ) { if ( ++idx[k] < counts[k] ) break; idx[k] = 0; k--; }
    if ( k < 0 ) break;
  }

  if ( holder != Qnil ) ALLOCV_END(holder);
  return 1;
}
