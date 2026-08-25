/* ---------------------------------------------------------------------------

  CAWindow: a sliding rectangular view of the parent whose cells may fall
  outside it.  Each axis carries a start / count and a bounds policy that says
  what an out-of-range (OOB) cell means: FILL / MASK give it `ca->fill` (or
  mask it), NEAREST / RUBY / STRICT normalise or reject the index.

  CAShift is a typedef of this struct (ca_obj_shift.c) and shares the whole
  operation table, so every path here serves both.

  Two internal models coexist, chosen per view by ca_window_recompute_embed:

    embed model (FILL / MASK on every axis, embed_eligible)
      The view decomposes into one alias rectangle (the part of the parent it
      actually addresses, embed_*) plus its fill complement (the OOB part).
      Attach / xfer are then "1 typed fill + 1 strided memcpy", with no
      per-cell bound check.  A window whose inner axes are full and which sits
      entirely inside the parent (embed_alias_eligible) skips even that and
      aliases the parent's buffer.

    descriptor engine (any other bounds policy)
      ca_window_describe_axes emits a per-axis descriptor and the shared engine
      (ca_axis_dispatch.c) applies the policy per cell.

  Region-copy helpers shared with CATile / CAStack live in
  ca_composite_dispatch.c (included above).

--------------------------------------------------------------------------- */

#include "carray.h"
#include "ca_composite_dispatch.h"
#include "ca_obj_face.h"  /* CA_FACE_LIFT_IF_FACE, used by rb_ca_window */

/* should not be static variable as used by CAIteratorWindow */

static size_t
ca_window_dsize (const void *ap)
{
  const CAWindow *ca = (const CAWindow *) ap;
  /* dim points to count; start, count, size0 are each ALLOC_N(ndim);
     bounds is ALLOC_N(uint8_t, ndim) (per-axis);
     fill is ALLOC_N(bytes);
     embed_{parent_start,count,output_offset} are each ALLOC_N(ndim). */
  return sizeof(CAWindow) + 6 * ca->ndim * sizeof(ca_size_t)
       + ca->ndim * sizeof(uint8_t) + ca->bytes;
}

/* Pool framework hooks for CAWindow.  CAWindow owns eight variable-size tail
   fields; seven of them are ndim-sized and move into a single _pool buffer:

     6 * ndim ca_size_t : start, count, size0,
                          embed_parent_start, embed_count, embed_output_offset
     1 * ndim uint8_t   : bounds

   `dim` aliases `count` (no allocation).  The eighth field, `fill`, is
   `bytes`-sized (element width, not ndim) and the ndim-only pool_bytes/
   pool_init signature cannot size it; it stays on its own ALLOC_N inside
   ca_window_setup.  CAShift shares this struct and reuses these hooks via
   the ca_window_func copy in Init_ca_obj_shift. */
static size_t
ca_window_pool_bytes (int8_t ndim)
{
  ca_size_t n = (ndim > 0) ? ndim : 1;
  return 6 * (size_t) n * sizeof(ca_size_t) + (size_t) n * sizeof(uint8_t);
}

static void
ca_window_pool_init (void *ap, int8_t ndim)
{
  CAWindow  *ca   = (CAWindow *) ap;
  ca_size_t  n    = (ndim > 0) ? ndim : 1;
  ca_size_t *base = (ca_size_t *) ca->_pool;
  /* six ca_size_t arrays first (8-byte aligned), then the uint8_t bounds
     array after them. */
  ca->start               = base + 0 * n;
  ca->count               = base + 1 * n;
  ca->size0               = base + 2 * n;
  ca->embed_parent_start  = base + 3 * n;
  ca->embed_count         = base + 4 * n;
  ca->embed_output_offset = base + 5 * n;
  ca->bounds              = (uint8_t *) (base + 6 * n);
  ca->dim                 = ca->count;   /* alias; ca_window_setup re-sets */
}

const rb_data_type_t cawindow_data_type = {
    .parent = &caview_data_type,
    .wrap_struct_name = "CAWindow",
    .function = {
        .dmark = ca_mark,
        .dfree = ca_free,
        .dsize = ca_window_dsize,
        .dcompact = NULL
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

/* CAREFUL: the mask TypedData must keep dfree = ca_free_nop.  The mask CArray
   is owned by the parent CAWindow's `ca->mask` field and freed by
   free_ca_window's ca_free(ca->mask); if the wrapped Ruby VALUE (from the
   `ca.mask` accessor / rb_ca_mask_array) freed it as well, GC stress would
   double-free it. */
const rb_data_type_t cawindow_mask_data_type = {
    .parent = &cawindow_data_type,
    .wrap_struct_name = "CAWindowMask",
    .function = {
        .dmark = ca_mark,
        .dfree = ca_free_nop,
        .dsize = ca_window_dsize,
        .dcompact = NULL
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

int8_t CA_OBJ_WINDOW;

VALUE rb_cCAWindow;
VALUE rb_cCAWindowMask;


/* ------------------------------------------------------------------- */

/* Computes the embed descriptor for a CAWindow / CAShift view.  The
   descriptor decomposes the view into "1 alias region (the part of parent
   that is actually addressable) + 1 fill complement (the OOB part)".

   Inputs: parent_dim[ndim], start[ndim], count[ndim].  step is
   implicitly 1 for CAWindow (enforced in rb_ca_window).
   bounds[] is not read here — the embed shape is policy-independent
   (policy decides what to put in the fill complement, not which cells
    are in the alias).

   Outputs (written into ca->embed_*):
     embed_parent_start[k] = max(0, start[k])
     embed_count[k]        = min(start[k]+count[k], parent_dim[k])
                             - embed_parent_start[k]    (clamped to >= 0)
     embed_output_offset[k]= embed_parent_start[k] - start[k]
     embed_is_empty        = 1 if any axis has embed_count[k] <= 0
     embed_covers_all      = 1 if every axis has start[k] >= 0
                                   AND start[k]+count[k] <= parent_dim[k]

   Called only through ca_window_recompute_embed, which also derives the
   eligibility flags from the result. */
static void
ca_compute_embed_descriptor (int8_t ndim,
                             ca_size_t *parent_dim,
                             ca_size_t *start,
                             ca_size_t *count,
                             ca_size_t *embed_parent_start,
                             ca_size_t *embed_count,
                             ca_size_t *embed_output_offset,
                             uint8_t   *embed_is_empty,
                             uint8_t   *embed_covers_all)
{
  int8_t k;
  uint8_t any_empty   = 0;
  uint8_t all_interior = 1;

  for ( k = 0; k < ndim; k++ ) {
    ca_size_t s   = start[k];
    ca_size_t c   = count[k];
    ca_size_t pd  = parent_dim[k];
    ca_size_t ps, pe, oo, ec;

    ps = (s > 0) ? s : 0;            /* clamp low */
    pe = (s + c < pd) ? (s + c) : pd;/* clamp high */
    ec = pe - ps;                    /* alias count this axis */
    if ( ec < 0 ) ec = 0;            /* fully outside */
    oo = ps - s;                     /* output-side offset */

    embed_parent_start[k]  = ps;
    embed_count[k]         = ec;
    embed_output_offset[k] = oo;

    if ( ec <= 0 ) any_empty = 1;
    if ( s < 0 || s + c > pd ) all_interior = 0;
  }

  *embed_is_empty   = any_empty;
  *embed_covers_all = all_interior;
}

/* ------------------------------------------------------------------- */

/* [MOVED] ca_fill_typed / ca_composite_region_gather / _scatter /
   ca_composite_fill_complement -> ca_composite_dispatch.c (shared with
   CATile / CAStack); reached via the include at the top of this file. */

/* Exposes CAWindow as a synthetic CAStride for compose-fold purposes.  Used
   by ca_stride_compose_to_root to walk *through* an interior-only CAWindow
   without materialising it, enabling a full zero-copy chain when CAStride
   family children wrap an interior-only CAWindow.

   On success (interior-only + embed_eligible):
     - synth_strides[k] = row-major byte stride of window->parent
       (= bytes * Π window->parent->dim[k+1..ndim-1])
     - synth_base       = Σ embed_parent_start[k] * synth_strides[k]
                          (byte offset of embedded region start in
                           window->parent's byte space)
     - synth_dim        = pointer to window->dim (window's logical shape)
     - synth_bytes      = window->bytes
     - synth_ndim       = window->ndim
     - next_parent      = window->parent
   Returns 1.

   Caller assembles a CAStride struct from these fields and feeds it to
   ca_stride_compose_through; the loop continues with next_parent.

   Returns 0 if not foldable (= not a CAWindow / not embed_eligible /
   not embed_covers_all).  Callers must then break out of the
   compose-fold loop and accept window as the root (= materialise via
   ca_attach).

   ndim invariant: synth_ndim equals window->ndim equals the leaf's
   ndim by construction (CAStride children inherit ndim from parent).
   No reshaping. */
int
ca_window_compose_fold (void *win_ap,
                        ca_size_t *synth_strides,
                        ca_size_t *synth_base,
                        ca_size_t **synth_dim,
                        ca_size_t *synth_bytes,
                        int8_t    *synth_ndim,
                        CArray   **next_parent)
{
  CAWindow *w = (CAWindow *) win_ap;
  ca_size_t s;
  int8_t    k;

  if ( ! w->embed_eligible )    return 0;
  if ( ! w->embed_covers_all )  return 0;

  /* synth_strides = row-major byte stride over window->parent->dim */
  s = w->bytes;
  for ( k = w->ndim - 1; k >= 0; k-- ) {
    synth_strides[k] = s;
    s *= w->parent->dim[k];
  }

  /* synth_base = embedded region origin in window->parent's byte space */
  *synth_base = 0;
  for ( k = 0; k < w->ndim; k++ ) {
    *synth_base += w->embed_parent_start[k] * synth_strides[k];
  }

  *synth_dim    = w->dim;
  *synth_bytes  = w->bytes;
  *synth_ndim   = w->ndim;
  *next_parent  = w->parent;
  return 1;
}

/* fold_stride slot: compose the fold state f (leaf coords in this window's
   byte space) through the interior
   window into window->parent's byte space.  Synthesises a CAStride layer
   for the window-over-parent mapping (ca_window_compose_fold) and composes
   f through it (ca_stride_compose_through).  Declines (returns 0) when the
   window is not interior-only, making the window the fold boundary. */
static int
ca_window_func_fold_stride (void *ap, ca_fold_t *f, void **next_parent)
{
  CAWindow *w = (CAWindow *) ap;
  ca_size_t synth_strides[CA_RANK_MAX];
  ca_size_t synth_base;
  ca_size_t *synth_dim;
  ca_size_t synth_bytes;
  int8_t    synth_ndim;
  CArray   *win_parent;
  CAStride  tmp, synth;
  ca_size_t next_strides[CA_RANK_MAX];
  ca_size_t next_base;
  int8_t    k;

  if (!ca_window_compose_fold(w, synth_strides, &synth_base, &synth_dim,
                              &synth_bytes, &synth_ndim, &win_parent)) {
    return 0;
  }

  tmp.ndim = f->ndim;
  tmp.bytes = synth_bytes;
  tmp.dim = f->counts;            /* leaf extent in this window's space */
  tmp.strides = f->strides;
  tmp.base_offset = f->base;

  synth.ndim = synth_ndim;
  synth.bytes = synth_bytes;
  synth.dim = synth_dim;
  synth.strides = synth_strides;
  synth.base_offset = synth_base;

  if (!ca_stride_compose_through(&tmp, &synth, next_strides, &next_base)) {
    return 0;
  }

  for (k = 0; k < f->ndim; k++) f->strides[k] = next_strides[k];
  f->base = next_base;
  *next_parent = win_parent;
  return 1;
}

static void ca_window_func_xfer_index (void *ap, ca_size_t *idx, void *data, int dir);

/* xfer_stride: structural region delivery when a boundary-crossing CAWindow is
   the (declining) fold boundary.  The window fills the OOB cells itself and
   hands the in-bound region to the parent via parent.xfer_stride, so no whole
   view is materialised.

   Structural path requires: FILL/MASK bounds (so OOB is a contiguous edge),
   axis-aligned access, and unit src step (the natural window region / a
   contiguous window slice).  Other cases (PERIODIC/REFLECT/NEAREST bounds,
   transposed / sub-sampled leaf) fall back to per-cell delivery (correct,
   no whole-view attach).  data is contiguous (semantics b).  The wiring
   guards ndim == window ndim.  window.bytes == parent.bytes (no reinterpret). */
static void
ca_window_func_xfer_stride (void *ap, ca_size_t *starts, ca_size_t *counts,
                            ca_size_t *strides, void *data, int dir)
{
  CAWindow *w = (CAWindow *) ap;
  CArray   *parent = w->parent;
  int8_t    ndim = w->ndim;
  int8_t    inner = ndim - 1;
  ca_size_t pnative[CA_RANK_MAX], wnative[CA_RANK_MAX], dstride[CA_RANK_MAX];
  ca_size_t base_pos[CA_RANK_MAX];   /* window.start[k] + starts[k] (parent pos at o=0) */
  ca_size_t lo[CA_RANK_MAX], hi[CA_RANK_MAX], o[CA_RANK_MAX];
  ca_size_t s, n = 1, i;
  int8_t    k;
  int       structural = 1;
  char     *d = (char *) data;

  s = parent->bytes;
  for (k = ndim - 1; k >= 0; k--) { pnative[k] = s; s *= parent->dim[k]; }
  s = w->bytes;
  for (k = ndim - 1; k >= 0; k--) { wnative[k] = s; s *= w->dim[k]; }
  s = w->bytes;
  for (k = ndim - 1; k >= 0; k--) { dstride[k] = s; s *= counts[k]; }
  for (k = 0; k < ndim; k++) n *= counts[k];

  for (k = 0; k < ndim; k++) {
    if ( (w->bounds[k] != CA_BOUNDS_FILL && w->bounds[k] != CA_BOUNDS_MASK)
         || strides[k] % wnative[k] != 0
         || strides[k] / wnative[k] != 1 ) {
      structural = 0;
      break;
    }
  }

  if (!structural) {
    ca_size_t idx[CA_RANK_MAX], doff = 0, base = 0;
    for (k = 0; k < ndim; k++) base += starts[k] * wnative[k];
    for (k = 0; k < ndim; k++) idx[k] = 0;
    while (1) {
      ca_size_t woff = base, widx[CA_RANK_MAX];
      for (k = 0; k < ndim; k++) woff += idx[k] * strides[k];
      ca_addr2index((CArray *) w, woff / w->bytes, widx);
      ca_window_func_xfer_index(w, widx, d + doff, dir);
      doff += w->bytes;
      k = ndim - 1;
      while (k >= 0) { if (++idx[k] < counts[k]) break; idx[k] = 0; k--; }
      if (k < 0) break;
    }
    return;
  }

  /* Intersect sub-region [starts, starts+counts) with the in-bound region.
     lo[k]/hi[k] are offsets within the sub-region (= output-coordinate)
     where the parent is in-bound.  Same algebra as the per-row loop below,
     hoisted up so the embed-based path can share it. */
  for (k = 0; k < ndim; k++) {
    ca_size_t l, h;
    base_pos[k] = w->start[k] + starts[k];
    l = -base_pos[k];               if (l < 0) l = 0;
    h = w->size0[k] - base_pos[k];   if (h > counts[k]) h = counts[k];
    if (h < 0) h = 0;
    if (l > h) l = h;
    lo[k] = l; hi[k] = h;
  }

  /* Fast path: when the parent is attached (ptr != NULL), drive
     ca_composite_region_* + fill_complement directly with the sub-region
     intersection geometry.  This collapses the outer per-row dispatch loop
     (one ca_xfer_stride per inner row) into a single batched routine.  An
     unattached parent falls through to the per-row loop below, which is
     equivalent but slower. */
  if ( parent->ptr ) {
    ca_size_t any_empty = 0;
    ca_size_t alias_parent_start[CA_RANK_MAX];
    ca_size_t alias_count[CA_RANK_MAX];
    ca_size_t alias_output_offset[CA_RANK_MAX];
    ca_size_t parent_strides[CA_RANK_MAX];

    for (k = 0; k < ndim; k++) {
      if (lo[k] >= hi[k]) { any_empty = 1; break; }
      alias_output_offset[k] = lo[k];
      alias_count[k]         = hi[k] - lo[k];
      alias_parent_start[k]  = base_pos[k] + lo[k];
    }

    if (dir == CA_XFER_GET) {
      if (any_empty) {
        ca_fill_typed(d, w->fill, w->bytes, n);
      } else {
        ca_composite_fill_complement(d, dstride, counts,
                                     alias_output_offset, alias_count,
                                     w->fill, w->bytes, ndim);
        /* parent_strides = row-major byte stride over parent->dim */
        s = parent->bytes;
        for (k = ndim - 1; k >= 0; k--) { parent_strides[k] = s; s *= parent->dim[k]; }
        ca_composite_region_gather(parent->ptr, parent_strides,
                                   alias_parent_start,
                                   d, dstride, alias_output_offset,
                                   alias_count, ndim, w->bytes);
      }
    } else { /* CA_XFER_PUT */
      /* complement silent skip (no parent storage for fill region) */
      if (!any_empty) {
        s = parent->bytes;
        for (k = ndim - 1; k >= 0; k--) { parent_strides[k] = s; s *= parent->dim[k]; }
        ca_composite_region_scatter(parent->ptr, parent_strides,
                                    alias_parent_start,
                                    d, dstride, alias_output_offset,
                                    alias_count, ndim, w->bytes);
      }
    }
    return;
  }

  /* Parent unattached: per-row outer loop + ca_xfer_stride(parent)
     recursion. */
  if (dir == CA_XFER_GET) {
    for (i = 0; i < n; i++) memcpy(d + i * w->bytes, w->fill, w->bytes);
  }

  for (k = 0; k < ndim; k++) {
    if (lo[k] >= hi[k]) return;     /* no in-bound cells (GET: filled; PUT: skip) */
  }

  for (k = 0; k < ndim; k++) o[k] = lo[k];
  while (1) {
    ca_size_t pbase = 0, doff = 0;
    ca_size_t pstarts[CA_RANK_MAX], pcounts[CA_RANK_MAX], pstrides[CA_RANK_MAX];
    ca_size_t inner_pbase;
    for (k = 0; k < inner; k++) {
      pbase += (base_pos[k] + o[k]) * pnative[k];
      doff  += o[k] * dstride[k];
    }
    inner_pbase = (base_pos[inner] + lo[inner]) * pnative[inner];
    ca_addr2index((CArray *) parent, (pbase + inner_pbase) / parent->bytes, pstarts);
    for (k = 0; k < ndim; k++) { pcounts[k] = 1; pstrides[k] = 0; }
    pcounts[inner]  = hi[inner] - lo[inner];
    pstrides[inner] = pnative[inner];
    ca_xfer_stride(parent, pstarts, pcounts, pstrides,
                   d + doff + lo[inner] * dstride[inner], dir);

    k = inner - 1;
    while (k >= 0) { o[k]++; if (o[k] < hi[k]) break; o[k] = lo[k]; k--; }
    if (k < 0) break;
  }
}

/* Executes the "1 typed fill + 1 strided memcpy" embed path on a
   pre-allocated output buffer.  Requires the parent to be attached (the
   caller's responsibility).

   Pre-conditions (must hold; not validated here):
     - ca->embed_eligible == 1 (all axes FILL or MASK)
     - ca->parent->ptr != NULL (parent attached)
     - out_ptr points to ca->elements * ca->bytes writable bytes

   Behaviour:
     - if embed_covers_all: skip fill (alias overwrites every cell)
     - else: fill the entire output with ca->fill (typed loop)
     - if embed_is_empty: skip alias copy
     - else: strided memcpy from parent[embed_parent_*] rectangle to
             out_ptr[embed_output_*] rectangle.  Inner contig run =
             embed_count[ndim-1] * bytes.  Outer axes iterate row-major
             via a multi-dim cursor; per-axis offsets are precomputed in
             bytes for both parent and output.

   The strided copy itself is ca_composite_region_gather
   (ca_composite_dispatch.c), shared with CATile / CAStack. */
static void
ca_window_attach_embed (CAWindow *ca, char *out_ptr)
{
  int8_t    ndim = ca->ndim;
  ca_size_t bytes = ca->bytes;
  ca_size_t parent_strides[CA_RANK_MAX];
  ca_size_t output_strides[CA_RANK_MAX];
  ca_size_t s;
  int8_t    k;

  /* Row-major byte strides for output (used by fill-complement and
     region-gather both). */
  s = bytes;
  for ( k = ndim - 1; k >= 0; k-- ) {
    output_strides[k] = s;
    s *= ca->count[k];
  }

  /* Step 1: fill the complement of the alias rectangle only — filling the
     whole output first would write the alias area twice.  For
     embed_is_empty (= alias is empty, whole output is fill) short-circuit
     to a full-output typed fill since the complement is the whole output;
     for embed_covers_all (= alias is the whole output, no fill) skip. */
  if ( ! ca->embed_covers_all ) {
    if ( ca->embed_is_empty ) {
      ca_fill_typed(out_ptr, ca->fill, bytes, ca->elements);
    } else {
      ca_composite_fill_complement(out_ptr, output_strides, ca->count,
                                   ca->embed_output_offset,
                                   ca->embed_count,
                                   ca->fill, bytes, ndim);
    }
  }

  /* Step 2: strided memcpy from parent alias rectangle to output rectangle. */
  if ( ca->embed_is_empty ) return;

  s = bytes;
  for ( k = ndim - 1; k >= 0; k-- ) {
    parent_strides[k] = s;
    s *= ca->parent->dim[k];
  }

  ca_composite_region_gather(ca->parent->ptr, parent_strides,
                             ca->embed_parent_start,
                             out_ptr, output_strides,
                             ca->embed_output_offset,
                             ca->embed_count, ndim, bytes);
}

/* Executes the reverse of ca_window_attach_embed on a caller-provided source
   buffer.  Strided memcpy from the alias sub-rectangle of in_ptr (= the
   view's data layout) back into the parent's alias rectangle.  The fill
   region is ignored: writes in the OOB area have no parent cell to land in
   and are dropped, matching ca_axis_dispatch_scatter's SHIFT-kind OOB.

   Pre-conditions:
     - ca->embed_eligible == 1
     - ca->parent->ptr != NULL (parent attached)
     - in_ptr points to ca->elements * ca->bytes valid bytes

   The reverse strided copy is ca_composite_region_scatter
   (ca_composite_dispatch.c), shared with the CATile / CAStack sync paths. */
static void
ca_window_sync_embed (CAWindow *ca, char *in_ptr)
{
  int8_t    ndim = ca->ndim;
  ca_size_t bytes = ca->bytes;
  ca_size_t parent_strides[CA_RANK_MAX];
  ca_size_t input_strides[CA_RANK_MAX];
  ca_size_t s;
  int8_t    k;

  if ( ca->embed_is_empty ) return;   /* nothing of in_ptr maps back */

  /* Row-major byte strides for parent and the view-shaped source. */
  s = bytes;
  for ( k = ndim - 1; k >= 0; k-- ) {
    parent_strides[k] = s;
    s *= ca->parent->dim[k];
  }
  s = bytes;
  for ( k = ndim - 1; k >= 0; k-- ) {
    input_strides[k] = s;
    s *= ca->count[k];
  }

  ca_composite_region_scatter(ca->parent->ptr, parent_strides,
                              ca->embed_parent_start,
                              in_ptr, input_strides,
                              ca->embed_output_offset,
                              ca->embed_count, ndim, bytes);
}

/* ------------------------------------------------------------------- */

/* Recomputes the embed descriptor + eligibility flags from the current
   (start, count, bounds).  The recompute is unconditional — no eligibility
   pre-check — so callers never have to reason about which flags are stale.
   Called by ca_window_setup.
 *
 * CAREFUL: any code path that mutates ca->start[] in place (e.g.
 * ca_window_move, which is why this is not static) must call this
 * afterwards.  Otherwise embed_* keeps describing the OLD start and the
 * embed-model attach / copy_data reads the wrong parent rectangle — wrong
 * data, no error. */
void
ca_window_recompute_embed (CAWindow *ca)
{
  int8_t ndim = ca->ndim;
  int8_t i;

  ca_compute_embed_descriptor(ndim, ca->parent->dim, ca->start, ca->count,
                              ca->embed_parent_start,
                              ca->embed_count,
                              ca->embed_output_offset,
                              &ca->embed_is_empty,
                              &ca->embed_covers_all);

  /* embed path eligibility = all axes use FILL or MASK bounds. */
  ca->embed_eligible = 1;
  for (i = 0; i < ndim; i++) {
    if ( ca->bounds[i] != CA_BOUNDS_FILL
      && ca->bounds[i] != CA_BOUNDS_MASK ) {
      ca->embed_eligible = 0;
      break;
    }
  }

  /* direct-attach alias eligibility (see ca_window_func_attach). */
  ca->embed_alias_eligible = 0;
  if ( ca->embed_eligible && ca->embed_covers_all ) {
    int alias_ok = 1;
    for (i = 1; i < ndim; i++) {
      if ( ca->start[i] != 0 || ca->count[i] != ca->parent->dim[i] ) {
        alias_ok = 0;
        break;
      }
    }
    if ( alias_ok ) ca->embed_alias_eligible = 1;
  }
}

/* `bounds` is a per-axis uint8_t array.  CAWindow's Ruby surface
   (rb_ca_window) receives a single scalar policy and fans it out to all axes;
   the per-axis form is what lets CAShift be a CAWindow specialisation. */
int
ca_window_setup (CAWindow *ca, CArray *parent,
               ca_size_t *start, ca_size_t *count, uint8_t *bounds, char *fill)
{
  int8_t  data_type, ndim;
  ca_size_t *dim;
  ca_size_t bytes, elements;
  int i;
  int any_mask;

  data_type = parent->data_type;
  ndim      = parent->ndim;
  bytes     = parent->bytes;
  dim       = parent->dim;

  elements = 1;
  for (i=0; i<ndim; i++) {
    if ( count[i] <= 0 ) {
      rb_raise(rb_eIndexError,
               "invalid size for %i-th dimension (negative or zero)", i);
    }
    elements *= count[i];
  }

  ca->obj_type  = CA_OBJ_WINDOW;
  ca->data_type = data_type;
  ca->flags     = 0;
  ca->ndim      = ndim;
  ca->bytes     = bytes;
  ca->elements  = elements;
  ca->ptr       = NULL;
  ca->mask      = NULL;
  /* ca->dim will set as ca->count below */

  ca->parent    = parent;
  ca->attach    = 0;
  ca->nosync    = 0;
  /* Pool path: bounds/start/count/size0/embed_* are already wired into
     ca->_pool by ca_window_pool_init.  Legacy path: ALLOC_N each.  `fill`
     is bytes-sized (not ndim) so it stays on its own ALLOC_N in both
     branches. */
  if ( ! ca->_pool ) {
    ca->bounds    = ALLOC_N(uint8_t, ndim);
    ca->start     = ALLOC_N(ca_size_t, ndim);
    ca->count     = ALLOC_N(ca_size_t, ndim);
    ca->size0     = ALLOC_N(ca_size_t, ndim);
    ca->embed_parent_start  = ALLOC_N(ca_size_t, ndim);
    ca->embed_count         = ALLOC_N(ca_size_t, ndim);
    ca->embed_output_offset = ALLOC_N(ca_size_t, ndim);
  }
  ca->fill      = ALLOC_N(char, ca->bytes);
  ca->embed_is_empty      = 0;
  ca->embed_covers_all    = 0;

  ca->dim = ca->count;

  memcpy(ca->bounds, bounds, ndim * sizeof(uint8_t));
  memcpy(ca->start, start, ndim * sizeof(ca_size_t));
  memcpy(ca->count, count, ndim * sizeof(ca_size_t));
  memcpy(ca->size0,  dim,  ndim * sizeof(ca_size_t));

  /* Compute the embed descriptor + eligibility flags from the current
     (start, count, bounds).  See ca_window_recompute_embed below. */
  ca_window_recompute_embed(ca);

  if ( fill ) {
    memcpy(ca->fill, fill, ca->bytes);
  }
  else {
    if ( ca_is_object_type(ca) ) {
      *(VALUE *)ca->fill = INT2NUM(0);
    }
    else {
      memset(ca->fill, 0, ca->bytes);
    }
  }

  /* Mask is needed if ANY axis uses MASK policy (per-axis). */
  any_mask = 0;
  for (i=0; i<ndim; i++) {
    if ( ca->bounds[i] == CA_BOUNDS_MASK ) {
      any_mask = 1;
      break;
    }
  }
  if ( any_mask ) {
    ca_create_mask(ca);
  }

  return 0;
}

CAWindow *
ca_window_new (CArray *parent,
               ca_size_t *start, ca_size_t *count, uint8_t *bounds, char *fill)
{
  CAWindow *ca = (CAWindow *) ca_array_alloc(CA_OBJ_WINDOW, parent->ndim);
  ca_window_setup(ca, parent, start, count, bounds, fill);
  return ca;
}

static void
free_ca_window (void *ap)
{
  CAWindow *ca = (CAWindow *) ap;
  if ( ca != NULL ) {
    ca_free(ca->mask);
    xfree(ca->fill);              /* always separate (bytes-sized) */
    if ( ca->_pool ) {
      /* bounds/start/count/size0/embed_* all live in ca->_pool. */
      ca_array_free(ca);          /* one xfree pool + one xfree struct */
    }
    else {
      xfree(ca->bounds);
      xfree(ca->start);
      xfree(ca->count);
      xfree(ca->size0);
      xfree(ca->embed_parent_start);
      xfree(ca->embed_count);
      xfree(ca->embed_output_offset);
      /* xfree(ca->dim); */
      xfree(ca);
    }
  }
}

/* Path selection for attach / sync / copy_data / sync_data below.

   embed_eligible (= all axes use FILL or MASK bounds) takes the embed path:
   "1 typed fill + 1 strided memcpy" with no per-cell bound check (see
   ca_window_attach_embed / ca_window_sync_embed above).

   Everything else (PERIODIC — still reached through CAShift's roll form —
   REFLECT / NEAREST / RUBY / STRICT) goes through the descriptor engine,
   ca_axis_dispatch_* fed by ca_window_describe_axes (defined below), which
   still promotes interior axes to STRIDE kind.

   fill_data is the exception: it has its own split (see
   ca_window_func_fill_data). */

/* ------------------------------------------------------------------- */

static void *
ca_window_func_clone (void *ap)
{
  CAWindow *ca = (CAWindow *) ap;
  return ca_window_new(ca->parent, ca->start, ca->count, ca->bounds, ca->fill);
}

/* Per-cell access.  GET and PUT share the bound-normalised index walk; an OOB
   cell is filled on GET and skipped on PUT.  CAShift inherits this via the
   ca_shift_func copy of the operation table. */
static void
ca_window_func_xfer_index (void *ap, ca_size_t *idx, void *data, int dir)
{
  CAWindow *ca = (CAWindow *) ap;
  ca_size_t *start = ca->start;
  ca_size_t *size0 = ca->size0;
  ca_size_t idx0[CA_RANK_MAX];
  int8_t  i;
  ca_size_t k;
  for (i=0; i<ca->ndim; i++) {
    k = start[i] + idx[i];
    k = ca_bounds_normalize_index(ca->bounds[i], size0[i], k);
    if ( k < 0 || k >= size0[i] ) {
      if ( dir == CA_XFER_GET ) memcpy(data, ca->fill, ca->bytes);
      return;   /* PUT to out-of-bounds cell: skip */
    }
    idx0[i] = k;
  }
  ca_xfer_index(ca->parent, idx0, data, dir);
}

/* Batched address gather/scatter.  Bound-normalises each view addr; OOB cells are handled inline (GET fills,
   PUT skips) and the in-bounds cells are delivered to the parent in ONE
   ca_xfer_addrs call.  When some cells are OOB the in-bounds set is packed
   into a contiguous temp (the parent's contig-buf contract), gathered/
   scattered, then unpacked.  No whole-view attach.
   CAShift inherits via ca_shift_func copy. */
static void
ca_window_func_xfer_addrs (void *ap, ca_size_t n, ca_size_t *addrs,
                           void *data, int dir)
{
  CAWindow *ca = (CAWindow *) ap;
  ca_size_t *start = ca->start;
  ca_size_t *size0 = ca->size0;
  char      *d = (char *) data;
  ca_size_t *paddrs;
  ca_size_t *pos;
  ca_size_t  m = 0, i, base;
  int8_t     k;
  volatile VALUE h1, h2;

  /* Fast path: an embed-eligible window (interior alias rectangle + OOB
     strips for FILL mode) over a parent that resolves to a ptr-bearing root.
     Whole-view sequential addrs let us drive ca_composite_region_gather /
     ca_composite_fill_complement directly (= the same helpers
     ca_window_attach_embed / _sync_embed use), skipping the per-cell
     bounds-normalise + OOB-pack two-pass.  Covers both interior-only windows
     and boundary-crossing ones (CAShift included): the OOB strip fill is
     batched through ca_composite_fill_complement. */
  if ( ca->embed_eligible
       && n == ca->elements
       && ca_xfer_addrs_is_sequential_run(n, addrs, &base) && base == 0 ) {
    CArray *eff_parent = ca_resolve_attached_root_via_identity(ca->parent);
    if ( eff_parent->ptr ) {
      ca_size_t output_strides[CA_RANK_MAX];
      ca_size_t parent_strides[CA_RANK_MAX];
      ca_size_t s;
      s = ca->bytes;
      for ( k = ca->ndim - 1; k >= 0; k-- ) {
        output_strides[k] = s;
        s *= ca->count[k];
      }
      s = eff_parent->bytes;
      for ( k = ca->ndim - 1; k >= 0; k-- ) {
        parent_strides[k] = s;
        s *= ca->parent->dim[k];   /* logical shape from immediate parent */
      }
      if ( dir == CA_XFER_GET ) {
        /* Step 1: fill OOB complement (no-op when covers_all). */
        if ( ! ca->embed_covers_all ) {
          if ( ca->embed_is_empty ) {
            ca_fill_typed((char *) data, ca->fill, ca->bytes, ca->elements);
          } else {
            ca_composite_fill_complement((char *) data, output_strides, ca->count,
                                         ca->embed_output_offset,
                                         ca->embed_count,
                                         ca->fill, ca->bytes, ca->ndim);
          }
        }
        /* Step 2: gather interior alias rectangle from parent. */
        if ( ! ca->embed_is_empty ) {
          ca_composite_region_gather(eff_parent->ptr, parent_strides,
                                     ca->embed_parent_start,
                                     (char *) data, output_strides,
                                     ca->embed_output_offset,
                                     ca->embed_count, ca->ndim, ca->bytes);
        }
      } else {  /* CA_XFER_PUT */
        /* Scatter the input rectangle back to the parent's alias
           rectangle.  Writes to OOB cells are dropped — same as
           ca_window_sync_embed and the engine's SHIFT-kind scatter. */
        if ( ! ca->embed_is_empty ) {
          ca_composite_region_scatter(eff_parent->ptr, parent_strides,
                                      ca->embed_parent_start,
                                      (char *) data, output_strides,
                                      ca->embed_output_offset,
                                      ca->embed_count, ca->ndim, ca->bytes);
        }
      }
      return;
    }
  }

  paddrs = ALLOCV_N(ca_size_t, h1, n);
  pos    = ALLOCV_N(ca_size_t, h2, n);

  for (i = 0; i < n; i++) {
    ca_size_t vidx[CA_RANK_MAX], pidx[CA_RANK_MAX];
    int oob = 0;
    ca_addr2index((CArray *) ca, addrs[i], vidx);
    for (k = 0; k < ca->ndim; k++) {
      ca_size_t kk = start[k] + vidx[k];
      kk = ca_bounds_normalize_index(ca->bounds[k], size0[k], kk);
      if (kk < 0 || kk >= size0[k]) { oob = 1; break; }
      pidx[k] = kk;
    }
    if (oob) {
      if (dir == CA_XFER_GET) memcpy(d + i * ca->bytes, ca->fill, ca->bytes);
      /* PUT to OOB cell: skip */
    }
    else {
      paddrs[m] = ca_index2addr(ca->parent, pidx);
      pos[m]    = i;
      m++;
    }
  }

  if (m == n) {                 /* no OOB: deliver in place, contiguous */
    ca_xfer_addrs(ca->parent, n, paddrs, data, dir);
  }
  else if (m > 0) {             /* some OOB: pack the in-bounds set */
    volatile VALUE h3;
    char *packed = ALLOCV_N(char, h3, m * ca->bytes);
    if (dir == CA_XFER_GET) {
      ca_xfer_addrs(ca->parent, m, paddrs, packed, CA_XFER_GET);
      for (i = 0; i < m; i++)
        memcpy(d + pos[i] * ca->bytes, packed + i * ca->bytes, ca->bytes);
    }
    else {
      for (i = 0; i < m; i++)
        memcpy(packed + i * ca->bytes, d + pos[i] * ca->bytes, ca->bytes);
      ca_xfer_addrs(ca->parent, m, paddrs, packed, CA_XFER_PUT);
    }
    ALLOCV_END(h3);
  }

  ALLOCV_END(h2);
  ALLOCV_END(h1);
}

static void
ca_window_func_allocate (void *ap)
{
  CAWindow *ca = (CAWindow *) ap;
  ca_attach(ca->parent);
  /* ca->ptr = ALLOC_N(char, ca_length(ca)); */
  ca->ptr = xmalloc(ca_length(ca));  
}

/* The engine paths below emit a per-axis descriptor (ca_window_describe_axes)
   and let the shared engine's SHIFT-kind handling apply the boundary policy
   and the OOB cell fill.  CAShift inherits all of it through
   ca_shift_func = a copy of ca_window_func. */

void ca_window_describe_axes (void *ap, ca_axis_desc_t *out,
                              ca_size_t *out_parent_dims);

static void
ca_window_func_attach (void *ap)
{
  CAWindow *ca = (CAWindow *) ap;
  ca_attach(ca->parent);
  if ( ca->embed_alias_eligible ) {
    /* Alias path: inner axes full + interior, so the embedded region is a
       contiguous run of parent storage.  Skip malloc/memcpy and point
       ca->ptr into the parent's buffer.
       CAREFUL: sync and detach must agree with this — sync has nothing to
       scatter back (the writes already landed in the parent) and detach must
       not xfree a pointer it does not own. */
    ca_size_t parent_row_stride = ca->bytes;
    int8_t k;
    for (k = ca->ndim - 1; k >= 1; k--) parent_row_stride *= ca->parent->dim[k];
    ca->ptr = ca->parent->ptr + ca->start[0] * parent_row_stride;
  } else if ( ca->embed_eligible ) {
    /* Embed path: allocate, then 1 fill + 1 strided memcpy. */
    ca_size_t out_len = ca->elements * ca->bytes;
    ca->ptr = xmalloc(out_len > 0 ? out_len : 1);
    ca_window_attach_embed(ca, ca->ptr);
  } else {
    /* Fallback: PERIODIC / REFLECT / NEAREST / RUBY / STRICT go through
       the descriptor engine. */
    ca_axis_desc_t desc[CA_RANK_MAX];
    ca_size_t      pdims[CA_RANK_MAX];
    ca_window_describe_axes(ca, desc, pdims);
    ca->ptr = ca_axis_dispatch_attach(ca->parent, pdims, desc, ca->ndim,
                                      ca->bytes, ca->elements, ca->fill);
  }
}

static void
ca_window_func_sync (void *ap)
{
  CAWindow *ca = (CAWindow *) ap;
  if ( ca->embed_alias_eligible ) {
    /* Alias path: ca->ptr aliases the parent, so the writes already landed
       in parent storage.  Nothing to scatter back. */
  } else if ( ca->embed_eligible ) {
    /* Embed path: write back the alias region only. */
    ca_window_sync_embed(ca, ca->ptr);
  } else {
    ca_axis_desc_t desc[CA_RANK_MAX];
    ca_size_t      pdims[CA_RANK_MAX];
    ca_window_describe_axes(ca, desc, pdims);
    ca_axis_dispatch_scatter(ca->parent, pdims, desc, ca->ndim, ca->bytes,
                             ca->elements, ca->ptr);
  }
  ca_sync(ca->parent);
}

static void
ca_window_func_detach (void *ap)
{
  CAWindow *ca = (CAWindow *) ap;
  /* Alias path: ca->ptr aliases parent storage; it is not ours to xfree. */
  if ( ! ca->embed_alias_eligible ) {
    xfree(ca->ptr);
  }
  ca->ptr = NULL;
  ca_detach(ca->parent);
}

/* Fast path body for xfer_all, shared by the warm and the cold-parent case.
   Both the embed path and the engine dispatch read ca->parent->ptr directly,
   so the caller must have made it available.

   CAREFUL: neither this nor ca_window_func_xfer_all may call
   ca_attach(parent).  A transfer slot that silently attaches its parent
   materialises the whole parent behind the caller's back — the cold case
   below instead materialises a parent-shaped scratch through ca_xfer_all,
   which recurses under the same rule. */
static void
ca_window_func_run_fast_path (CAWindow *ca, char *data, int dir)
{
  if ( dir == CA_XFER_GET ) {
    if ( ca->embed_eligible ) {
      ca_window_attach_embed(ca, data);
    } else {
      ca_axis_desc_t desc[CA_RANK_MAX];
      ca_size_t      pdims[CA_RANK_MAX];
      ca_window_describe_axes(ca, desc, pdims);
      ca_axis_dispatch_gather(ca->parent, pdims, desc, ca->ndim, ca->bytes,
                              ca->elements, ca->fill, data);
    }
  } else {
    if ( ca->embed_eligible ) {
      ca_window_sync_embed(ca, data);
    } else {
      ca_axis_desc_t desc[CA_RANK_MAX];
      ca_size_t      pdims[CA_RANK_MAX];
      ca_window_describe_axes(ca, desc, pdims);
      ca_axis_dispatch_scatter(ca->parent, pdims, desc, ca->ndim, ca->bytes,
                               ca->elements, data);
    }
  }
}

static void
ca_window_func_xfer_all (void *ap, void *data, int dir)
{
  CAWindow *ca = (CAWindow *) ap;
  if ( ca->parent->ptr ) {
    ca_window_func_run_fast_path(ca, (char *) data, dir);
    return;
  }
  /* Cold parent: materialise it into a scratch buffer via ca_xfer_all, then
     run the normal fast path with the scratch standing in for parent->ptr. */
  {
    volatile VALUE holder;
    CArray   *parent = ca->parent;
    ca_size_t plen   = parent->elements * parent->bytes;
    char     *parent_scratch = ALLOCV_N(char, holder, plen);
    char     *parent_ptr_saved = parent->ptr;

    /* GET path needs parent data; PUT path will overwrite parent so we
       still need to read existing parent state if the view's fast path
       does partial writes (e.g., embed_sync overwrites only the embed
       rectangle, OOB cells untouched in parent).  Safe default: always
       GET first. */
    ca_xfer_all(parent, parent_scratch, CA_XFER_GET);
    parent->ptr = parent_scratch;

    ca_window_func_run_fast_path(ca, (char *) data, dir);

    if ( dir == CA_XFER_PUT ) {
      /* Push back scratch (modified by scatter) to parent. */
      ca_xfer_all(parent, parent_scratch, CA_XFER_PUT);
    }

    parent->ptr = parent_ptr_saved;
    ALLOCV_END(holder);
  }
}

/* fill_data (= view.fill(scalar) / view[] = scalar).

   Wrapping the window in a CAStride and filling that is markedly faster than
   the engine path, because compose-fold reaches the entity and the inner loop
   collapses to a per-row memset.  So for an embed-eligible window we do the
   same thing directly: build a transient CAStride header matching
   ca_window_compose_fold's synthetic strides and dispatch to CAStride's
   fill_data, which continues compose-fold (covering
   CAStride-of-CAWindow-of-CAStride chains) and runs the merge + tight-fill
   inner loop.  PERIODIC / REFLECT windows fall through to the engine path. */
static void
ca_window_func_fill_data (void *ap, void *ptr)
{
  CAWindow *ca = (CAWindow *) ap;

  /* embed_eligible (= no PERIODIC/REFLECT) covers both interior-only
     windows (embed_covers_all == 1) and OOB-bearing ones such as a CAShift
     with a fill_value (embed_covers_all == 0, embed_is_empty == 0).  In the
     OOB case the synth is restricted to the interior region (embed_count
     cells starting at embed_parent_start in the parent): the view's OOB
     cells have no parent cell and must be skipped, which the restricted
     synth does by construction.  A wholly-OOB window (embed_is_empty == 1)
     is a no-op. */
  if ( ca->embed_eligible && ! ca->embed_is_empty ) {
    ca_size_t synth_strides[CA_RANK_MAX];
    ca_size_t synth_base;
    ca_size_t s;
    int8_t k;
    ca_size_t synth_elements;

    /* Row-major byte strides over parent. */
    s = ca->bytes;
    for ( k = ca->ndim - 1; k >= 0; k-- ) {
      synth_strides[k] = s;
      s *= ca->parent->dim[k];
    }

    /* Origin: embedded region start in parent's byte space. */
    synth_base = 0;
    for ( k = 0; k < ca->ndim; k++ ) {
      synth_base += ca->embed_parent_start[k] * synth_strides[k];
    }

    /* synth dims = interior count per axis (= the cells we actually
       write to; OOB view cells are skipped by construction). */
    synth_elements = 1;
    for ( k = 0; k < ca->ndim; k++ ) {
      synth_elements *= ca->embed_count[k];
    }

    /* Stack-allocated transient CAStride header.  Dispatched via the
       op table since ca_stride_func_fill_data is static in
       ca_obj_stride.c.  It reads only struct fields (parent, ndim,
       dim, strides, base_offset, bytes, elements) and never
       registers / persists this pointer. */
    CAStride synth;
    memset(&synth, 0, sizeof(synth));
    synth.obj_type    = CA_OBJ_STRIDE;
    synth.data_type   = ca->data_type;
    synth.ndim        = ca->ndim;
    synth.bytes       = ca->bytes;
    synth.elements    = synth_elements;
    synth.dim         = ca->embed_count;
    synth.parent      = ca->parent;
    synth.strides     = synth_strides;
    synth.base_offset = synth_base;
    ca_func[CA_OBJ_STRIDE].fill_data(&synth, ptr);
    return;
  }

  /* Engine path: PERIODIC / REFLECT, or pure-OOB window (no-op via
     engine's OOB-skip).  Bound_fill writes to view's OOB cells are
     not propagated to parent (no cells to write to). */
  ca_axis_desc_t desc[CA_RANK_MAX];
  ca_size_t      pdims[CA_RANK_MAX];

  ca_window_describe_axes(ca, desc, pdims);

  /* A wrapping window writes the cells it lands on, but a whole-parent attach
     and sync carries the rest of the parent with it — and over a lossy layer
     those cells do not come back the same.  Hand each slab to the parent as a
     region instead, as the other views on the descriptor engine do. */
  if ( !ca_is_attached(ca->parent) && !ca_attach_is_alias(ca->parent) ) {
    ca_axis_dispatch_fill_value_via_parent(ca->parent, pdims, desc, ca->ndim,
                                           ca->bytes, ca->elements, ptr);
    return;
  }

  ca_attach(ca->parent);
  ca_axis_dispatch_fill_value(ca->parent, pdims, desc, ca->ndim, ca->bytes,
                              ca->elements, ptr);
  ca_sync(ca->parent);
  ca_detach(ca->parent);
}

static void
ca_window_func_create_mask (void *ap)
{
  CAWindow *ca = (CAWindow *) ap;
  boolean8_t fill;
  uint8_t mbounds[CA_RANK_MAX];
  int8_t i;
  int any_mask;

  ca_update_mask(ca->parent);
  if ( ! ca->parent->mask ) {
    ca_create_mask(ca->parent);
  }

  /* Any MASK axis of the view becomes FILL in the mask sub-view, with the
     mask cell forced to 1 (= "masked").  Other axes keep their policy.  When
     every axis shares MASK this is exactly "OOB cells are masked". */
  any_mask = 0;
  for (i = 0; i < ca->ndim; i++) {
    if ( ca->bounds[i] == CA_BOUNDS_MASK ) {
      mbounds[i] = CA_BOUNDS_FILL;
      any_mask = 1;
    } else {
      mbounds[i] = ca->bounds[i];
    }
  }
  fill = any_mask ? 1 : 0;

  ca->mask = (CArray *) ca_window_new(ca->parent->mask,
                                    ca->start, ca->count, mbounds, (char*)&fill);
}

ca_operation_function_t ca_window_func = {
  -1, /* CA_OBJ_WINDOW */
  CA_VIEW_ARRAY,
  free_ca_window,
  ca_window_func_clone,
  ca_window_func_allocate,
  ca_window_func_attach,
  ca_window_func_sync,
  ca_window_func_detach,
  ca_window_func_fill_data,
  ca_window_func_create_mask,
  ca_window_func_xfer_index,
  ca_window_func_xfer_addrs,
  ca_window_func_fold_stride,
  ca_window_func_xfer_stride,
  ca_window_func_xfer_all,
};

/* ------------------------------------------------------------------- */
/* Producer interface: emits one descriptor per axis.  The engine
   (ca_axis_dispatch.c) consumes these and applies the per-axis bounds policy
   via ca_bounds_normalize_index, writing ca->fill for cells that resolve
   out of range.

   CAWindow's step is implicitly 1 (count cells starting at start, sliding by
   1); the engine's SHIFT-axis offset computation is parent_index = start + i,
   with bounds normalisation per policy.

   Reached only from the non-embed paths: an embed_eligible view attaches and
   syncs through ca_window_attach_embed / _sync_embed and never gets here. */
void
ca_window_describe_axes (void *ap, ca_axis_desc_t *out,
                         ca_size_t *out_parent_dims)
{
  CAWindow *ca = (CAWindow *) ap;
  int8_t k;
  for ( k = 0; k < ca->ndim; k++ ) {
    out_parent_dims[k] = ca->parent->dim[k];
    /* Interior-only axes are promoted to STRIDE kind.  An axis touches no
       boundary cell iff start[k] >= 0 and start[k] + count[k] <=
       parent->dim[k] (step is implicitly 1); it is then a pure strided slice
       of the parent, so emitting STRIDE lets the engine take its strided fast
       paths (slab fusion, axis-merge, alias) and skip the per-cell
       ca_bounds_normalize_index + OOB check that SHIFT costs. */
    if ( ca->start[k] >= 0
         && ca->start[k] + ca->count[k] <= ca->parent->dim[k] ) {
      out[k].kind    = CA_AXIS_KIND_STRIDE;
      out[k].count   = ca->count[k];
      out[k].start   = ca->start[k];
      out[k].step    = 1;
      out[k].indices = NULL;
      /* size0 / policy unused for STRIDE — set defaults for hygiene. */
      out[k].size0   = ca->size0[k];
      out[k].policy  = ca->bounds[k];
    } else {
      out[k].kind    = CA_AXIS_KIND_SHIFT;
      out[k].count   = ca->count[k];
      out[k].start   = ca->start[k];
      out[k].step    = 1;
      out[k].indices = NULL;
      out[k].size0   = ca->size0[k];
      out[k].policy  = ca->bounds[k];
    }
  }
}

/* ------------------------------------------------------------------- */

VALUE
rb_ca_window_new (VALUE cary,
                ca_size_t *start, ca_size_t *count, int8_t bounds, char *fill)
{
  /* Scalar-bounds wrapper for the Ruby surface: fan the single policy out
     to a per-axis array before calling ca_window_new. */
  volatile VALUE obj;
  CArray *parent;
  CAWindow *ca;
  uint8_t bounds_arr[CA_RANK_MAX];
  int8_t i;
  rb_check_carray_object(cary);
  TypedData_Get_Struct(cary, CArray, &carray_data_type, parent);
  for (i = 0; i < parent->ndim; i++) bounds_arr[i] = (uint8_t) bounds;
  ca = ca_window_new(parent, start, count, bounds_arr, fill);
  obj = ca_wrap_struct(ca);
  rb_ca_set_parent(obj, cary);
  return obj;
}

VALUE
rb_ca_window (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE obj, ropt, rfval = CA_NIL, rbounds = Qnil, rcs;
  CArray *ca;
  CScalar *cs;
  ca_size_t start[CA_RANK_MAX];
  ca_size_t count[CA_RANK_MAX];
  int32_t bounds = CA_BOUNDS_FILL;
  char *fill = NULL; 
  char *cbounds;
  ca_size_t i;

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  ropt = rb_pop_options(&argc, &argv);
  rb_scan_options(ropt, "bounds,fill_value", &rbounds, &rfval);

  if ( argc != ca->ndim ) {
    rb_raise(rb_eArgError, "ndim mismatch");
  }

  for (i=0; i<argc; i++) {
    ca_size_t offset, len, step;
    volatile VALUE arg = argv[i];
    ca_parse_range_without_check(arg, ca->dim[i], &offset, &len, &step);
    if ( step != 1 || len < 0 ) {
      rb_raise(rb_eArgError, 
               "first index should smaller than last index. "
               "The index range notation such as 0..-1 can't be used in CArray#window");
    }
    start[i] = offset;
    count[i] = len;
  }

  if ( rb_block_given_p() ) {
    rb_raise(rb_eArgError,
             "window: block form for fill value removed in 3.0; "
             "use fill_value: kwarg (e.g. window(-1..1, fill_value: UNDEF))");
  }

  if ( rfval == CA_NIL ) {
    ;
  }
  else if ( rfval == CA_UNDEF ) {
    bounds = CA_BOUNDS_MASK;
  }
  else {
    rcs = rb_cscalar_new_with_value(ca->data_type, ca->bytes, rfval);
    TypedData_Get_Struct(rcs, CScalar, &cscalar_data_type, cs);
    fill = cs->ptr;
  }

  if ( ! NIL_P(rbounds) ) {
    switch ( TYPE(rbounds) ) {
    case T_STRING:
      cbounds = StringValuePtr(rbounds);
      if ( rfval == CA_UNDEF && strncmp(cbounds, "fill", 4) 
                             && strncmp(cbounds, "mask", 4) ) {
        rb_raise(rb_eRuntimeError, "conflicted bounds and fill_value");
      }
      if ( ! strncmp(cbounds, "ruby", 4) ) {
        bounds = CA_BOUNDS_RUBY;
      }
      else if ( ! strncmp(cbounds, "strict", 6) ) {
        bounds = CA_BOUNDS_STRICT;
      }
      else if ( ! strncmp(cbounds, "nearest", 7) ) {
        bounds = CA_BOUNDS_NEAREST;
      }
      else if ( ! strncmp(cbounds, "periodic", 8) ) {
        rb_raise(rb_eArgError,
                 "bounds=>'periodic' removed in 3.0; "
                 "use CArray#roll(...) for cyclic shift "
                 "(returns a CARoll view)");
      }
      else if ( ! strncmp(cbounds, "reflect", 7) ) {
        rb_raise(rb_eArgError,
                 "bounds=>'reflect' removed in 3.0; "
                 "there is no view-based alternative");
      }
      else if ( ! strncmp(cbounds, "mask", 4) ) {
        rb_warn("CAWindow option :bounds=>\"mask\" will be obsolete");
        rb_warn("use ca.window(..., fill_value: UNDEF)");
        bounds = CA_BOUNDS_MASK;
      }
      else if ( ! strncmp(cbounds, "fill", 4) ) {
        bounds = CA_BOUNDS_FILL;
      }
      else {
        rb_raise(rb_eRuntimeError, 
                 "unknown option value '%s' for :bounds", cbounds);        
      }
      break;
    case T_FIXNUM:
      bounds = NUM2INT(rbounds);
      break;
    default:
      rb_raise(rb_eRuntimeError, "invalid option value for :bounds");
    }
  }

  obj = rb_ca_window_new(self, start, count, bounds, fill);

  CA_FACE_LIFT_IF_FACE(obj, self, ca);
  return obj;
}

/* ------------------------------------------------------------------- */

static VALUE
rb_ca_window_s_allocate (VALUE klass)
{
  CAWindow *ca;
  return TypedData_Make_Struct(klass, CAWindow, &cawindow_data_type, ca);
}

static VALUE
rb_ca_window_initialize_copy (VALUE self, VALUE other)
{
  CAWindow *ca, *cs;

  TypedData_Get_Struct(self,  CAWindow, &cawindow_data_type, ca);
  TypedData_Get_Struct(other, CAWindow, &cawindow_data_type, cs);

  /* `self` came from rb_ca_window_s_allocate (TypedData_Make_Struct,
     _pool == NULL).  Attach the pool before setup so the ndim-sized
     tail fields skip ALLOC_N. */
  if ( ca_func[CA_OBJ_WINDOW].pool_init ) {
    ca_array_pool_alloc(ca, CA_OBJ_WINDOW, cs->ndim);
  }
  ca_window_setup(ca, cs->parent, cs->start, cs->count, cs->bounds, cs->fill);

  return self;
}

static VALUE
rb_ca_window_idx2addr0 (int argc, VALUE *argv, VALUE self)
{
  CAWindow *cw;
  ca_size_t addr;
  int8_t i;
  ca_size_t idxi;

  TypedData_Get_Struct(self, CAWindow, &cawindow_data_type, cw);

  if ( argc != cw->ndim ) {
    rb_raise(rb_eArgError,
             "invalid # of arguments (should be <%i>)", cw->ndim);
  }

  addr = 0;
  for (i=0; i<cw->ndim; i++) {
    idxi = NUM2SIZE(argv[i]);
    CA_CHECK_INDEX(idxi, cw->dim[i]);
    addr = cw->size0[i] * addr + cw->start[i] + idxi;
  }

  if ( addr < 0 || addr >= cw->parent->elements ) {
    return Qnil;
  }
  else {
    return SIZE2NUM(addr);
  }
}

static VALUE
rb_ca_window_addr2addr0 (VALUE self, VALUE raddr)
{
  CAWindow *cw;
  ca_size_t addr = NUM2SIZE(raddr);
  ca_size_t idx[CA_RANK_MAX];
  int8_t i;

  TypedData_Get_Struct(self, CAWindow, &cawindow_data_type, cw);

  ca_addr2index((CArray*)cw, addr, idx);

  addr = 0;
  for (i=0; i<cw->ndim; i++) {
    addr *= cw->size0[i];
    addr += cw->start[i] + idx[i];
  }

  if ( addr < 0 || addr >= cw->parent->elements ) {
    return Qnil;
  }

  return SIZE2NUM(addr);
}


static VALUE
rb_ca_window_set_fill_value (VALUE self, VALUE rfval)
{
  CAWindow *cw;
  TypedData_Get_Struct(self, CAWindow, &cawindow_data_type, cw);
  rb_ca_obj2ptr(self, rfval, cw->fill);
  return Qnil;
}

static VALUE
rb_ca_window_get_fill_value (VALUE self)
{
  CAWindow *cw;
  TypedData_Get_Struct(self, CAWindow, &cawindow_data_type, cw);
  return rb_ca_ptr2obj(self, cw->fill);
}

static VALUE
rb_ca_window_get_bounds (VALUE self)
{
  /* bounds is per-axis, but the Ruby surface always constructs with a single
     scalar policy fanned out across all axes, so axis 0 reproduces the value
     that was passed in. */
  CAWindow *cw;
  TypedData_Get_Struct(self, CAWindow, &cawindow_data_type, cw);
  return SIZE2NUM(cw->bounds[0]);
}

#define rb_cw_get_attr_ary(name)    \
  rb_cw_## name (VALUE self)        \
  {                                 \
    volatile VALUE ary;             \
    CAWindow *cw;                    \
    int8_t i;                              \
    TypedData_Get_Struct(self, CAWindow, &cawindow_data_type, cw);     \
    ary = rb_ary_new2(cw->ndim);            \
    for (i=0; i<cw->ndim; i++) {                    \
      rb_ary_store(ary, i, SIZE2NUM(cw->name[i]));  \
    }                                               \
    return ary;                                     \
}

static VALUE rb_cw_get_attr_ary(start);
static VALUE rb_cw_get_attr_ary(count);
static VALUE rb_cw_get_attr_ary(size0);

#ifdef CARRAY_DEV_BUILD
/* Debug accessor (dev-only, stripped in release), returning the embed
   descriptor as a Hash.  The descriptor is an internal implementation detail
   with no user-facing meaning; this exists so spec_ai can pin its geometry,
   which nothing else can observe (a stale descriptor produces wrong data, not
   an error).  Gated by CARRAY_DEV_BUILD, enabled via
   `extconf.rb --enable-dev-build` or `CARRAY_DEV=1 rake build_ext`.

   Polymorphic over CAWindow / CAShift: both share the same C struct layout
   (CAShift is a typedef of CAWindow) but use distinct TypedData types.
   DATA_PTR is safe here because Ruby method dispatch has already restricted
   self to one of those two classes. */
VALUE
rb_ca_window_embed_descriptor (VALUE self)
{
  CAWindow *ca = (CAWindow *) DATA_PTR(self);
  VALUE hash, ps_ary, ec_ary, oo_ary;
  int8_t k;

  ps_ary = rb_ary_new_capa(ca->ndim);
  ec_ary = rb_ary_new_capa(ca->ndim);
  oo_ary = rb_ary_new_capa(ca->ndim);
  for ( k = 0; k < ca->ndim; k++ ) {
    rb_ary_push(ps_ary, SIZE2NUM(ca->embed_parent_start[k]));
    rb_ary_push(ec_ary, SIZE2NUM(ca->embed_count[k]));
    rb_ary_push(oo_ary, SIZE2NUM(ca->embed_output_offset[k]));
  }

  hash = rb_hash_new();
  rb_hash_aset(hash, ID2SYM(rb_intern("parent_start")),  ps_ary);
  rb_hash_aset(hash, ID2SYM(rb_intern("count")),         ec_ary);
  rb_hash_aset(hash, ID2SYM(rb_intern("output_offset")), oo_ary);
  rb_hash_aset(hash, ID2SYM(rb_intern("is_empty")),
               ca->embed_is_empty ? Qtrue : Qfalse);
  rb_hash_aset(hash, ID2SYM(rb_intern("covers_all")),
               ca->embed_covers_all ? Qtrue : Qfalse);
  rb_hash_aset(hash, ID2SYM(rb_intern("eligible")),
               ca->embed_eligible ? Qtrue : Qfalse);
  rb_hash_aset(hash, ID2SYM(rb_intern("alias_eligible")),
               ca->embed_alias_eligible ? Qtrue : Qfalse);
  return hash;
}
#endif /* CARRAY_DEV_BUILD */

void
Init_ca_obj_window (void)
{    

  rb_cCAWindow = rb_define_class("CAWindow", rb_cCAView);
  rb_cCAWindowMask = rb_define_class("CAWindowMask", rb_cCAWindow);

  /* Pool framework: seven ndim-sized tail fields live in one _pool buffer
     (fill stays separate, bytes-sized).  Set on the global ca_window_func
     before ca_install_obj_type copies it into ca_func[], and before
     Init_ca_obj_shift copies ca_window_func into ca_shift_func. */
  ca_window_func.struct_size = sizeof(CAWindow);
  ca_window_func.pool_bytes  = ca_window_pool_bytes;
  ca_window_func.pool_init   = ca_window_pool_init;

  CA_OBJ_WINDOW = ca_install_obj_type(rb_cCAWindow,
  		                      &cawindow_data_type, 
				      rb_cCAWindowMask,
				      &cawindow_mask_data_type, &ca_window_func, sizeof(ca_window_func));
  rb_define_const(rb_cObject, "CA_OBJ_WINDOW", INT2NUM(CA_OBJ_WINDOW));

  rb_define_method(rb_cCArray, "window", rb_ca_window, -1);

  rb_define_alloc_func(rb_cCAWindow, rb_ca_window_s_allocate);
  rb_define_method(rb_cCAWindow, "initialize_copy",
                                      rb_ca_window_initialize_copy, 1);


  rb_define_method(rb_cCAWindow, "index2addr0",  rb_ca_window_idx2addr0, -1);
  rb_define_method(rb_cCAWindow, "addr2addr0", rb_ca_window_addr2addr0, 1);

  rb_define_method(rb_cCAWindow, "fill_value", rb_ca_window_get_fill_value, 0);
  rb_define_method(rb_cCAWindow, "fill_value=", rb_ca_window_set_fill_value, 1);

  rb_define_method(rb_cCAWindow, "bounds", rb_ca_window_get_bounds, 0);

  rb_define_method(rb_cCAWindow, "start",  rb_cw_start, 0);
  rb_define_method(rb_cCAWindow, "count",  rb_cw_count, 0);
  rb_define_method(rb_cCAWindow, "size0",  rb_cw_size0, 0);

#ifdef CARRAY_DEV_BUILD
  /* debug accessor (dev-only, stripped in release) */
  rb_define_method(rb_cCAWindow, "_embed_descriptor",
                                      rb_ca_window_embed_descriptor, 0);
#endif

}

