/* ---------------------------------------------------------------------------

  CAGrid -- a coordinate-selected view: each axis independently picks a
  set of parent indices (whole axis, a contiguous range, or an arbitrary
  index list) and the view is their Cartesian product.

  Gather / scatter / fill_value all go through the shared per-axis
  descriptor engine in ca_axis_dispatch.c; this file emits the per-axis
  descriptor (ca_grid_describe_axes) and holds the region-delivery
  (xfer_stride / xfer_addrs) and fold_stride paths.  Sibling of
  ca_obj_select_axis.c (CASelectAxis), which rb_ca_grid routes to for the
  single-boolean-axis slab-copy fast path.

---------------------------------------------------------------------------- */

#include "carray.h"

/* Per-axis tagged kind.  Each axis is either STRIDE (start/step/count,
   no allocation) or INDEX (an owned ca_size_t index snapshot).  A Range
   argument is detected at rb_ca_grid and stored as STRIDE, so its
   arithmetic-progression structure is available to axis-merge; a nil-arg
   axis is STRIDE(0, dim, 1) and allocates nothing. */
typedef enum {
  CAG_AXIS_STRIDE = 0,
  CAG_AXIS_INDEX  = 1
} cag_axis_kind_t;

typedef struct {
  cag_axis_kind_t  kind;
  ca_size_t        count;     /* = ca->dim[k] (view's output size along axis) */
  /* STRIDE-only */
  ca_size_t        start;
  ca_size_t        step;
  /* INDEX-only.  Owned in the non-share case (xfree'd by free_ca_grid),
     aliased in the share case (parent owns; CA_FLAG_SHARE_INDEX). */
  ca_size_t       *indices;
} cag_axis_t;

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
  char     *_pool;         /* framework-managed pool buffer (NULL = legacy ALLOC_N path). */
  CArray   *parent;
  uint32_t  attach;
  uint8_t   nosync;
  /* -------------*/
  cag_axis_t  *axes;     /* [ndim], owned (non-share) or aliased (share) */
} CAGrid;

static size_t
ca_grid_dsize (const void *ap)
{
  const CAGrid *ca = (const CAGrid *) ap;
  size_t total = sizeof(CAGrid)
               + ca->ndim * sizeof(ca_size_t)        /* dim */
               + ca->ndim * sizeof(cag_axis_t);      /* axes */
  /* indices for INDEX axes (variable per-axis count; STRIDE axes
     contribute 0 — the big win vs. the legacy identity-allocation
     pattern). */
  int8_t k;
  for (k = 0; k < ca->ndim; k++) {
    if (ca->axes[k].kind == CAG_AXIS_INDEX && ca->axes[k].indices) {
      total += ca->axes[k].count * sizeof(ca_size_t);
    }
  }
  return total;
}

/* Pool framework hooks: CAGrid owns dim (ndim ca_size_t), axes (ndim
   cag_axis_t), and per-INDEX-axis indices buffers.  Only `dim` is always
   owned and ndim-sized, so only dim moves into the _pool; `axes` is
   sometimes aliased (CA_FLAG_SHARE_INDEX) and the per-axis `indices`
   buffers are variable-size, so both stay on their own ALLOC_N path
   (cf. CAWindow's fill). */
static size_t
ca_grid_pool_bytes (int8_t ndim)
{
  ca_size_t n = (ndim > 0) ? ndim : 1;
  return (size_t) n * sizeof(ca_size_t);
}

static void
ca_grid_pool_init (void *ap, int8_t ndim)
{
  CAGrid *ca = (CAGrid *) ap;
  ca->dim = (ca_size_t *) ca->_pool;
}

const rb_data_type_t cagrid_data_type = {
    .parent = &caview_data_type,
    .wrap_struct_name = "CAGrid",
    .function = {
        .dmark = ca_mark,
        .dfree = ca_free,
        .dsize = ca_grid_dsize,
        .dcompact = NULL
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

const rb_data_type_t cagrid_mask_data_type = {
    .parent = &cagrid_data_type,
    .wrap_struct_name = "CAGridMask",
    .function = {
        .dmark = NULL,
        .dfree = ca_free_nop,
        .dsize = ca_grid_dsize,
        .dcompact = NULL
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

static VALUE rb_cCAGrid;
static VALUE rb_cCAGridMask;

static int8_t CA_OBJ_GRID;

/* Setup: caller passes ndim + per-axis protos (cag_axis_t).  Copies the
   fields and, for INDEX axes, snapshots the indices into an owned buffer.
   The share path (share=1, from initialize_copy and create_mask) aliases
   the caller's protos buffer instead, tying its lifetime to the source
   CAGrid (free_ca_grid skips the xfree under CA_FLAG_SHARE_INDEX). */
int
ca_grid_setup (CAGrid *ca, CArray *parent, int8_t ndim,
               cag_axis_t *protos, int share)
{
  int8_t k;
  int8_t data_type;
  ca_size_t elements, bytes;
  double  length;
  ca_size_t *dim0;

  CA_ASSUME(ndim >= 0 && ndim <= CA_RANK_MAX);   /* bound loops/allocs over [CA_RANK_MAX] arrays */
  data_type = parent->data_type;
  bytes     = parent->bytes;
  dim0      = parent->dim;

  /* parent->ndim should equal ndim (= number of axes provided).
     rb_ca_grid pads with nil when fewer args are given, so by the
     time we get here ndim == parent->ndim. */
  if ( ndim != parent->ndim ) {
    rb_raise(rb_eArgError,
             "CAGrid: ndim mismatch (%d args vs parent->ndim %d)",
             (int) ndim, (int) parent->ndim);
  }

  elements = 1;
  length = bytes;
  for (k = 0; k < ndim; k++) {
    if (protos[k].count < 0) {
      rb_raise(rb_eRuntimeError, "negative size for %d-th dimension", k);
    }
    elements *= protos[k].count;
    length *= protos[k].count;
  }
  if (length > CA_LENGTH_MAX) {
    rb_raise(rb_eRuntimeError, "too large byte length");
  }

  ca->obj_type  = CA_OBJ_GRID;
  ca->data_type = data_type;
  ca->flags     = 0;
  ca->ndim      = ndim;
  ca->bytes     = bytes;
  ca->elements  = elements;
  ca->ptr       = NULL;
  ca->mask      = NULL;
  if ( ! ca->_pool ) {
    ca->dim     = ALLOC_N(ca_size_t, ndim);
  }
  ca->parent    = parent;
  ca->attach    = 0;
  ca->nosync    = 0;

  for (k = 0; k < ndim; k++) ca->dim[k] = protos[k].count;

  if ( share ) {
    /* Alias the protos buffer; lifetime tied to the source CAGrid
       (initialize_copy and create_mask call sites).  free_ca_grid
       skips the axes / indices xfree under SHARE_INDEX. */
    ca_set_flag(ca, CA_FLAG_SHARE_INDEX);
    ca->axes = protos;
  } else {
    ca->axes = ALLOC_N(cag_axis_t, ndim);
    for (k = 0; k < ndim; k++) {
      ca->axes[k].kind  = protos[k].kind;
      ca->axes[k].count = protos[k].count;
      if (protos[k].kind == CAG_AXIS_STRIDE) {
        ca->axes[k].start   = protos[k].start;
        ca->axes[k].step    = protos[k].step;
        ca->axes[k].indices = NULL;
        /* Bounds check: first and last parent index must be in range. */
        if (protos[k].count > 0) {
          ca_size_t first = protos[k].start;
          ca_size_t last  = first + (protos[k].count - 1) * protos[k].step;
          CA_CHECK_INDEX(first, dim0[k]);
          if (protos[k].count > 1) CA_CHECK_INDEX(last, dim0[k]);
        }
      } else {
        ca->axes[k].start   = 0;
        ca->axes[k].step    = 0;
        ca->axes[k].indices = ALLOC_N(ca_size_t,
                                      protos[k].count > 0 ? protos[k].count : 1);
        ca_size_t j;
        for (j = 0; j < protos[k].count; j++) {
          ca_size_t v = protos[k].indices[j];
          CA_CHECK_INDEX(v, dim0[k]);
          ca->axes[k].indices[j] = v;
        }
      }
    }
  }

  if ( ca_has_mask(parent) ) {
    ca_create_mask(ca);
  }

  return 0;
}

CAGrid *
ca_grid_new (CArray *parent, int8_t ndim, cag_axis_t *protos)
{
  CAGrid *ca = (CAGrid *) ca_array_alloc(CA_OBJ_GRID, ndim);
  ca_grid_setup(ca, parent, ndim, protos, 0);
  return ca;
}

CAGrid *
ca_grid_new_share (CArray *parent, int8_t ndim, cag_axis_t *protos)
{
  CAGrid *ca = (CAGrid *) ca_array_alloc(CA_OBJ_GRID, ndim);
  ca_grid_setup(ca, parent, ndim, protos, 1);
  return ca;
}

static void
free_ca_grid (void *ap)
{
  CAGrid *ca = (CAGrid *) ap;
  if ( ca != NULL ) {
    ca_free(ca->mask);
    if ( ! (ca->flags & CA_FLAG_SHARE_INDEX) ) {
      int8_t k;
      for (k = 0; k < ca->ndim; k++) {
        if ( ca->axes[k].kind == CAG_AXIS_INDEX && ca->axes[k].indices ) {
          xfree(ca->axes[k].indices);
        }
      }
      xfree(ca->axes);
    }
    /* dim is the only field in the pool; axes/indices freed above. */
    if ( ca->_pool ) {
      ca_array_free(ca);          /* dim + struct */
    }
    else {
      xfree(ca->dim);
      xfree(ca);
    }
  }
}

/* ------------------------------------------------------------------- */

/* gather, scatter, and broadcast-fill all run through the shared
   descriptor engine in ca_axis_dispatch.c via the func_* dispatchers
   below; this file only translates CAGrid state into the descriptor
   (ca_grid_describe_axes). */

static void *
ca_grid_func_clone (void *ap)
{
  CAGrid *ca = (CAGrid *) ap;
  return ca_grid_new_share(ca->parent, ca->ndim, ca->axes);
}

/* Per-axis parent-index lookup.  STRIDE = one multiply, INDEX = one
   indirect load. */
static inline ca_size_t
cag_parent_index_for (const cag_axis_t *ax, ca_size_t i)
{
  if (ax->kind == CAG_AXIS_STRIDE) {
    return ax->start + i * ax->step;
  }
  return ax->indices[i];
}

/* per-cell logic lives in ca_grid_func_xfer_index; forward-declared for
   the region-delivery paths below. */
static void ca_grid_func_xfer_index (void *ap, ca_size_t *idx, void *data, int dir);

/* dir-unified per-cell: translate per-axis idx via the grid descriptors,
   then re-delegate to the parent's xfer_index. */
static void
ca_grid_func_xfer_index (void *ap, ca_size_t *idx, void *data, int dir)
{
  CAGrid *ca = (CAGrid *) ap;
  ca_size_t idx0[CA_RANK_MAX];
  int8_t i;
  for (i = 0; i < ca->ndim; i++) {
    idx0[i] = cag_parent_index_for(&ca->axes[i], idx[i]);
  }
  ca_xfer_index(ca->parent, idx0, data, dir);
}

/* Batched address gather/scatter.  Per-axis index remap
   (cag_parent_index_for), always in-bounds; duplicate parent addrs
   (duplicate grid indices) scatter last-write-wins.  ONE parent
   ca_xfer_addrs call -- no whole-view attach.

   Fast path: when addrs form the whole-view sequential run
   [0..elements-1] and parent.ptr is present, rebuild the full sub_axes
   descriptor via ca_grid_describe_axes and dispatch through
   ca_axis_dispatch_gather/_scatter directly, skipping the per-cell remap
   loop. */
static void
ca_grid_func_xfer_addrs (void *ap, ca_size_t n, ca_size_t *addrs,
                         void *data, int dir)
{
  CAGrid   *ca = (CAGrid *) ap;
  CArray   *parent = ca->parent;
  ca_size_t *paddrs;
  ca_size_t  i, base;
  int8_t     k;
  volatile VALUE holder;

  /* Opportunistic fast path.  ca_resolve_attached_root_via_identity lifts
     parent->ptr through an identity CAStride compose-fold (handles a
     flatten[idx].reshape(*) chain etc.). */
  if ( n == ca->elements
       && ca_xfer_addrs_is_sequential_run(n, addrs, &base) && base == 0 ) {
    CArray *eff_parent = ca_resolve_attached_root_via_identity(parent);
    if ( eff_parent->ptr ) {
      ca_axis_desc_t sub_axes[CA_RANK_MAX];
      ca_size_t      parent_axis_dims[CA_RANK_MAX];
      ca_grid_describe_axes(ca, sub_axes, parent_axis_dims);
      if ( dir == CA_XFER_GET ) {
        ca_axis_dispatch_gather(eff_parent, parent_axis_dims, sub_axes, ca->ndim,
                                ca->bytes, ca->elements, NULL, (char *) data);
      } else {
        ca_axis_dispatch_scatter(eff_parent, parent_axis_dims, sub_axes, ca->ndim,
                                 ca->bytes, ca->elements, (char *) data);
      }
      return;
    }
  }

  /* Per-cell remap fallback (arbitrary addrs, view parent, partial). */
  paddrs = ALLOCV_N(ca_size_t, holder, n);
  for (i = 0; i < n; i++) {
    ca_size_t vidx[CA_RANK_MAX], pidx[CA_RANK_MAX];
    ca_addr2index((CArray *) ca, addrs[i], vidx);
    for (k = 0; k < ca->ndim; k++) pidx[k] = cag_parent_index_for(&ca->axes[k], vidx[k]);
    paddrs[i] = ca_index2addr(ca->parent, pidx);
  }
  ca_xfer_addrs(ca->parent, n, paddrs, data, dir);
  ALLOCV_END(holder);
}

/* fold_stride: a CAGrid folds into the stride chain when every axis is
   STRIDE or singleton-INDEX (count == 1).  STRIDE axis k contributes
   stride step_k*pstride_k and base start_k*pstride_k; a singleton INDEX
   axis bakes indices_k[0]*pstride_k into the base (count 1 -> no stride).
   A multi-element INDEX axis is a true gather -> decline (the grid
   becomes the fold boundary, delivered by the descriptor engine).
   Synthesises a CAStride over grid->parent and composes f through it. */
static int
ca_grid_func_fold_stride (void *ap, ca_fold_t *f, void **next_parent)
{
  CAGrid   *g = (CAGrid *) ap;
  CArray   *parent = g->parent;
  ca_size_t pstride[CA_RANK_MAX];
  ca_size_t synth_strides[CA_RANK_MAX];
  ca_size_t synth_base = 0;
  ca_size_t next_strides[CA_RANK_MAX];
  ca_size_t next_base;
  ca_size_t s;
  CAStride  tmp, synth;
  int8_t    k;

  for (k = 0; k < g->ndim; k++) {
    if (g->axes[k].kind == CAG_AXIS_INDEX && g->axes[k].count != 1) {
      return 0;   /* multi-INDEX axis -> true gather, decline */
    }
  }

  /* parent row-major byte strides (g->bytes == parent->bytes) */
  s = g->bytes;
  for (k = g->ndim - 1; k >= 0; k--) {
    pstride[k] = s;
    s *= parent->dim[k];
  }

  for (k = 0; k < g->ndim; k++) {
    if (g->axes[k].kind == CAG_AXIS_STRIDE) {
      synth_strides[k] = g->axes[k].step * pstride[k];
      synth_base      += g->axes[k].start * pstride[k];
    }
    else {   /* singleton INDEX: count == 1, position baked into base */
      synth_strides[k] = 0;
      synth_base      += g->axes[k].indices[0] * pstride[k];
    }
  }

  tmp.ndim = f->ndim;
  tmp.bytes = g->bytes;
  tmp.dim = f->counts;
  tmp.strides = f->strides;
  tmp.base_offset = f->base;

  synth.ndim = g->ndim;
  synth.bytes = g->bytes;
  synth.dim = g->dim;
  synth.strides = synth_strides;
  synth.base_offset = synth_base;

  if (!ca_stride_compose_through(&tmp, &synth, next_strides, &next_base)) {
    return 0;
  }

  for (k = 0; k < f->ndim; k++) f->strides[k] = next_strides[k];
  f->base = next_base;
  *next_parent = parent;
  return 1;
}

/* xfer_stride: structural region delivery when CAGrid is the (declining)
   fold boundary -- a multi-element INDEX axis.  Instead of materialising
   the whole grid, deliver only the requested region using the per-axis
   kind:

     - iterate the OUTER axes [0..ndim-2] with an odometer, computing the parent
       byte base and the contiguous data offset for each combination;
     - deliver the INNERMOST axis as one batched run into the contiguous data
       sub-block at data+offset:
         * STRIDE inner axis -> parent.xfer_stride (one strided run; entity
           parent delivers a contiguous/strided memcpy);
         * INDEX  inner axis -> parent.xfer_addrs (gather the selected cells).

   strides[] = src access byte strides into the grid (semantics b); data is
   contiguous row-major over counts.  g->bytes == parent->bytes (no reinterpret).
   No whole-view attach -- only the requested cells touch the parent. */
static void
ca_grid_func_xfer_stride (void *ap, ca_size_t *starts, ca_size_t *counts,
                          ca_size_t *strides, void *data, int dir)
{
  CAGrid   *g = (CAGrid *) ap;
  CArray   *parent = g->parent;
  int8_t    ndim = g->ndim;
  int8_t    inner = ndim - 1;
  ca_size_t pnative[CA_RANK_MAX];   /* parent row-major byte strides */
  ca_size_t gnative[CA_RANK_MAX];   /* grid  row-major byte strides */
  ca_size_t dstride[CA_RANK_MAX];   /* data row-major byte strides over counts */
  ca_size_t src_step[CA_RANK_MAX];  /* element step into grid per axis (request) */
  ca_size_t o[CA_RANK_MAX];         /* odometer over outer axes */
  ca_size_t s;
  int8_t    k;
  int       aligned = 1;
  char     *d = (char *) data;

  s = parent->bytes;
  for (k = ndim - 1; k >= 0; k--) { pnative[k] = s; s *= parent->dim[k]; }
  s = g->bytes;
  for (k = ndim - 1; k >= 0; k--) { gnative[k] = s; s *= g->dim[k]; }
  s = g->bytes;
  for (k = ndim - 1; k >= 0; k--) { dstride[k] = s; s *= counts[k]; }

  /* The structural decomposition assumes the request is axis-aligned: each
     axis k is accessed by a stride that is a whole multiple of the grid's own
     axis-k stride (src_step[k] = strides[k]/gnative[k]).  A reshaped or
     transposed leaf breaks this (cross-axis / non-multiple strides); fall back
     to per-cell delivery (correct, still no whole-view attach).  The wiring
     guards ndim == grid->ndim, so counts/strides have ndim entries here. */
  for (k = 0; k < ndim; k++) {
    if (strides[k] % gnative[k] != 0) { aligned = 0; break; }
    src_step[k] = strides[k] / gnative[k];
  }

  if (!aligned) {
    ca_size_t idx[CA_RANK_MAX], doff = 0, base = 0;
    for (k = 0; k < ndim; k++) base += starts[k] * gnative[k];
    for (k = 0; k < ndim; k++) idx[k] = 0;
    while (1) {
      ca_size_t goff = base, gidx[CA_RANK_MAX];
      for (k = 0; k < ndim; k++) goff += idx[k] * strides[k];
      ca_addr2index((CArray *) g, goff / g->bytes, gidx);
      ca_grid_func_xfer_index(g, gidx, d + doff, dir);
      doff += g->bytes;
      k = ndim - 1;
      while (k >= 0) { if (++idx[k] < counts[k]) break; idx[k] = 0; k--; }
      if (k < 0) break;
    }
    return;
  }

  /* Fast path: when parent is attached (ptr != NULL), translate the
     sub-region request (starts/counts/src_step) into a transient
     ca_axis_desc_t[] sub-descriptor and call
     ca_axis_dispatch_gather/_scatter directly.  This is the same engine
     entry that ca_grid_func_xfer_all uses (minus the ca_attach(parent)
     call, which per-region functions must not do).  Collapses N
     outer-row dispatch calls into 1.

     INDEX axis with src_step==1: zero-copy pointer offset into
     g->axes[k].indices.  INDEX axis with src_step!=1: materialise a
     sub-indices array via ALLOCV (per-call, not per-row).  STRIDE axis:
     trivially fold starts/src_step into start/step.

     Parent unattached falls through to the legacy per-row outer loop. */
  if (parent->ptr) {
    ca_axis_desc_t sub_axes[CA_RANK_MAX];
    ca_size_t      parent_axis_dims[CA_RANK_MAX];
    ca_size_t     *index_bufs[CA_RANK_MAX];
    volatile VALUE holders[CA_RANK_MAX];
    ca_size_t      total_elements = 1;
    ca_size_t      j;
    int8_t         have_alloc = 0;

    for (k = 0; k < ndim; k++) { index_bufs[k] = NULL; holders[k] = Qnil; }

    for (k = 0; k < ndim; k++) {
      parent_axis_dims[k] = parent->dim[k];
      total_elements *= counts[k];
      if (g->axes[k].kind == CAG_AXIS_STRIDE) {
        sub_axes[k].kind    = CA_AXIS_KIND_STRIDE;
        sub_axes[k].count   = counts[k];
        sub_axes[k].start   = g->axes[k].start + starts[k] * g->axes[k].step;
        sub_axes[k].step    = g->axes[k].step * src_step[k];
        sub_axes[k].indices = NULL;
      } else {
        sub_axes[k].kind    = CA_AXIS_KIND_INDEX;
        sub_axes[k].count   = counts[k];
        sub_axes[k].start   = 0;
        sub_axes[k].step    = 0;
        if (src_step[k] == 1) {
          /* zero-copy: pointer offset into the original indices */
          sub_axes[k].indices = g->axes[k].indices + starts[k];
        } else {
          /* sub-sampled or reversed: materialise sub-indices */
          index_bufs[k] = ALLOCV_N(ca_size_t, holders[k], counts[k]);
          for (j = 0; j < counts[k]; j++) {
            index_bufs[k][j] =
              g->axes[k].indices[starts[k] + j * src_step[k]];
          }
          sub_axes[k].indices = index_bufs[k];
          have_alloc = 1;
        }
      }
    }

    if (dir == CA_XFER_GET) {
      ca_axis_dispatch_gather(parent, parent_axis_dims, sub_axes, ndim,
                              g->bytes, total_elements, NULL, d);
    } else {
      ca_axis_dispatch_scatter(parent, parent_axis_dims, sub_axes, ndim,
                               g->bytes, total_elements, d);
    }

    if (have_alloc) {
      for (k = 0; k < ndim; k++) {
        if (index_bufs[k] != NULL) ALLOCV_END(holders[k]);
      }
    }
    return;
  }

  /* Fallback (parent unattached): per-row outer loop + per-row
     ca_xfer_stride/ca_xfer_addrs. */
  for (k = 0; k < ndim; k++) o[k] = 0;

  while (1) {
    ca_size_t pbase = 0, doff = 0;
    for (k = 0; k < inner; k++) {
      ca_size_t gpos = starts[k] + o[k] * src_step[k];
      ca_size_t ppos = (g->axes[k].kind == CAG_AXIS_STRIDE)
                       ? (g->axes[k].start + gpos * g->axes[k].step)
                       : g->axes[k].indices[gpos];
      pbase += ppos * pnative[k];
      doff  += o[k] * dstride[k];
    }

    if (g->axes[inner].kind == CAG_AXIS_STRIDE) {
      ca_size_t pstarts[CA_RANK_MAX], pcounts[CA_RANK_MAX], pstrides[CA_RANK_MAX];
      ca_size_t inner_pbase =
        (g->axes[inner].start + starts[inner] * g->axes[inner].step) * pnative[inner];
      ca_addr2index((CArray *) parent, (pbase + inner_pbase) / parent->bytes, pstarts);
      for (k = 0; k < ndim; k++) { pcounts[k] = 1; pstrides[k] = 0; }
      pcounts[inner]  = counts[inner];
      pstrides[inner] = src_step[inner] * g->axes[inner].step * pnative[inner];
      ca_xfer_stride(parent, pstarts, pcounts, pstrides, d + doff, dir);
    }
    else {
      ca_size_t *addrs;
      ca_size_t  j, n = counts[inner];
      volatile VALUE holder;
      addrs = ALLOCV_N(ca_size_t, holder, n);
      for (j = 0; j < n; j++) {
        ca_size_t gpos = starts[inner] + j * src_step[inner];
        ca_size_t ppos = g->axes[inner].indices[gpos];
        addrs[j] = (pbase + ppos * pnative[inner]) / parent->bytes;
      }
      ca_xfer_addrs(parent, n, addrs, d + doff, dir);
      ALLOCV_END(holder);
    }

    k = inner - 1;
    while (k >= 0) { if (++o[k] < counts[k]) break; o[k] = 0; k--; }
    if (k < 0) break;
  }
}

static void
ca_grid_func_allocate (void *ap)
{
  CAGrid *ca = (CAGrid *) ap;
  ca_attach(ca->parent);
  ca->ptr = xmalloc(ca_length(ca));
}

/* attach / sync / copy_data / sync_data / fill_data all go through the
   descriptor engine (ca_axis_dispatch.c).  This file supplies only
   describe_axes; the engine does the rest. */

static void
ca_grid_func_attach (void *ap)
{
  CAGrid *ca = (CAGrid *) ap;
  ca_axis_desc_t desc[CA_RANK_MAX];
  ca_size_t      pdims[CA_RANK_MAX];
  ca_attach(ca->parent);
  ca_grid_describe_axes(ca, desc, pdims);
  ca->ptr = ca_axis_dispatch_attach(ca->parent, pdims, desc, ca->ndim,
                                    ca->bytes, ca->elements, NULL);
}

static void
ca_grid_func_sync (void *ap)
{
  CAGrid *ca = (CAGrid *) ap;
  ca_axis_desc_t desc[CA_RANK_MAX];
  ca_size_t      pdims[CA_RANK_MAX];
  ca_grid_describe_axes(ca, desc, pdims);
  ca_axis_dispatch_scatter(ca->parent, pdims, desc, ca->ndim, ca->bytes,
                           ca->elements, ca->ptr);
  ca_sync(ca->parent);
}

static void
ca_grid_func_detach (void *ap)
{
  CAGrid *ca = (CAGrid *) ap;
  xfree(ca->ptr);
  ca->ptr = NULL;
  ca_detach(ca->parent);
}

/* xfer_all: fast path on parent->ptr, with no silent transitive attach
   of the parent.  A cold parent uses a proper 2-pass -- materialise the
   parent into scratch via ca_xfer_all, temporarily expose it as
   parent->ptr, run the fast path, then (for PUT) write scratch back. */
static void
ca_grid_func_run_fast_path (CAGrid *ca, char *data, int dir)
{
  ca_axis_desc_t desc[CA_RANK_MAX];
  ca_size_t      pdims[CA_RANK_MAX];
  ca_grid_describe_axes(ca, desc, pdims);
  if ( dir == CA_XFER_GET ) {
    ca_axis_dispatch_gather(ca->parent, pdims, desc, ca->ndim, ca->bytes,
                            ca->elements, NULL, data);
  } else {
    ca_axis_dispatch_scatter(ca->parent, pdims, desc, ca->ndim, ca->bytes,
                             ca->elements, data);
  }
}

static void
ca_grid_func_xfer_all (void *ap, void *data, int dir)
{
  CAGrid *ca = (CAGrid *) ap;
  if ( ca->parent->ptr ) {
    ca_grid_func_run_fast_path(ca, (char *) data, dir);
    return;
  }
  /* Proper 2-pass cold fallback. */
  {
    volatile VALUE holder;
    CArray   *parent = ca->parent;
    ca_size_t plen   = parent->elements * parent->bytes;
    char     *parent_scratch = ALLOCV_N(char, holder, plen);
    char     *parent_ptr_saved = parent->ptr;
    ca_xfer_all(parent, parent_scratch, CA_XFER_GET);
    parent->ptr = parent_scratch;
    ca_grid_func_run_fast_path(ca, (char *) data, dir);
    if ( dir == CA_XFER_PUT ) {
      ca_xfer_all(parent, parent_scratch, CA_XFER_PUT);
    }
    parent->ptr = parent_ptr_saved;
    ALLOCV_END(holder);
  }
}

static void
ca_grid_func_fill_data (void *ap, void *ptr)
{
  CAGrid *ca = (CAGrid *) ap;
  ca_axis_desc_t desc[CA_RANK_MAX];
  ca_size_t      pdims[CA_RANK_MAX];

  ca_grid_describe_axes(ca, desc, pdims);

  /* Writing the selected cells used to go through a whole-parent attach and
     sync.  Where that attach is a gather rather than an alias, the cells this
     view did not select make the round trip for nothing -- and through a
     lossy layer they do not come back the same.  Hand each slab to the parent
     as a region instead.  (PROPOSAL_PARTIAL_FILL_WHOLE_ROOT_WRITEBACK.md) */
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
ca_grid_func_create_mask (void *ap)
{
  CAGrid *ca = (CAGrid *) ap;

  ca_update_mask(ca->parent);
  if ( ! ca->parent->mask ) {
    ca_create_mask(ca->parent);
  }

  ca->mask = (CArray *) ca_grid_new_share(ca->parent->mask,
                                          ca->ndim, ca->axes);
}

ca_operation_function_t ca_grid_func = {
  -1, /* CA_OBJ_GRID */
  CA_VIEW_ARRAY,
  free_ca_grid,
  ca_grid_func_clone,
  ca_grid_func_allocate,
  ca_grid_func_attach,
  ca_grid_func_sync,
  ca_grid_func_detach,
  ca_grid_func_fill_data,
  ca_grid_func_create_mask,
  ca_grid_func_xfer_index,
  ca_grid_func_xfer_addrs,
  ca_grid_func_fold_stride,
  ca_grid_func_xfer_stride,
  ca_grid_func_xfer_all,
};

/* ------------------------------------------------------------------- */

VALUE
rb_ca_grid_new (VALUE cary, int8_t ndim, cag_axis_t *protos)
{
  volatile VALUE obj;
  CArray *parent;
  CAGrid *ca;
  rb_check_carray_object(cary);
  TypedData_Get_Struct(cary, CArray, &carray_data_type, parent);
  ca = ca_grid_new(parent, ndim, protos);
  obj = ca_wrap_struct(ca);
  rb_ca_set_parent(obj, cary);
  return obj;
}

/* Detect a plain Ruby Range (Integer first/last, exclude_end?, step=1
   implicit) and convert it to STRIDE (start, count, step=1).
   Returns 1 on success (fills *out_start, *out_count), 0 on fallback
   (caller should materialise to INDEX).  Negative endpoints are
   normalised against dim_size like everywhere else in CArray. */
static int
cag_range_to_stride (VALUE range, ca_size_t dim_size,
                     ca_size_t *out_start, ca_size_t *out_count)
{
  VALUE rb_first, rb_last;
  ca_size_t first, last, count;
  int exclude_end;

  if ( ! rb_obj_is_kind_of(range, rb_cRange) ) return 0;
  rb_first = rb_funcall(range, rb_intern("first"), 0);
  rb_last  = rb_funcall(range, rb_intern("last"),  0);
  if ( ! FIXNUM_P(rb_first) || ! FIXNUM_P(rb_last) ) return 0;
  exclude_end = RTEST(rb_funcall(range, rb_intern("exclude_end?"), 0));

  first = NUM2SIZE(rb_first);
  last  = NUM2SIZE(rb_last);
  if (first < 0) first += dim_size;
  if (last  < 0) last  += dim_size;
  if (exclude_end) last -= 1;

  if (first < 0 || first >= dim_size) return 0;
  if (last  < first - 1)              return 0;   /* empty range */
  if (last  >= dim_size)              return 0;
  count = last - first + 1;

  *out_start = first;
  *out_count = count;
  return 1;
}

VALUE
rb_ca_grid (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE obj, ridx, rval;
  volatile VALUE list = rb_ary_new();
  CArray *ca;
  CArray *ci[CA_RANK_MAX];          /* CAWrap holders for INDEX axes; NULL for STRIDE */
  cag_axis_t protos[CA_RANK_MAX];
  ca_size_t i;

  /* Dispatch hook: route mixed AP + single boolean to CASelectAxis
     (slab-copy optimised path).  Falls through to per-cell CAGrid gather
     when not eligible (integer index, multiple INDIRECT axes, indirect
     not on axis 0).  Inline argv[0] type check avoids the function call
     when axis 0 is nil/Integer (most patterns with INDIRECT on inner axes). */
  extern int ca_csa_dispatch_bypass;
  if ( ! ca_csa_dispatch_bypass && argc > 0 && TYPE(argv[0]) == T_DATA ) {
    if ( rb_ca_select_axis_eligible_p(argc, argv, self) ) {
      return rb_ca_select_axis(argc, argv, self);
    }
  }

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  ridx = rb_ary_new4(argc, argv);

  if ( RARRAY_LEN(ridx) > ca->ndim ) {
    rb_raise(rb_eArgError, "# of arguments doesn't equal to the ndim");
  }
  else if ( RARRAY_LEN(ridx) < ca->ndim ) {
    volatile VALUE ref;
    CArray *cv;
    ca_size_t rdim[CA_RANK_MAX];
    ca_size_t rndim = RARRAY_LEN(ridx);
    ca_size_t j = 0, k;
    for (i=0; i<rndim; i++) {
      rval = rb_ary_entry(ridx, i);
      if ( rb_obj_is_carray(rval) ) {
        TypedData_Get_Struct(rval, CArray, &carray_data_type, cv);
        rdim[i] = 1;
        for (k=0; k<cv->ndim; k++) {
          rdim[i] *= ca->dim[j];
          j += 1;
        }
      }
      else {
        rdim[i] = ca->dim[j];
        j += 1;
      }
    }
    if ( j != ca->ndim ) {
      rb_raise(rb_eArgError, "invalid total ndim of args");
    }
    ref = rb_ca_refer_new(self, ca->data_type, rndim, rdim, ca->bytes, 0);
    return rb_ca_grid(argc, argv, ref);
  }

  /* Build per-axis protos:
     nil    -> STRIDE(0, parent.dim, 1), no CArray
     Range  -> STRIDE if plain integer Range, else fall through to INDEX
     CArray -> INDEX with indices = (ca_size_t*)ca_wrap_readonly(...)->ptr */
  for (i = 0; i < ca->ndim; i++) {
    ca_size_t dim_size = ca->dim[i];
    rval = rb_ary_entry(ridx, i);
    ci[i] = NULL;
    if ( NIL_P(rval) ) {
      protos[i].kind    = CAG_AXIS_STRIDE;
      protos[i].count   = dim_size;
      protos[i].start   = 0;
      protos[i].step    = 1;
      protos[i].indices = NULL;
      continue;
    }
    if ( rb_obj_is_kind_of(rval, rb_cRange) ) {
      ca_size_t start, count;
      if ( cag_range_to_stride(rval, dim_size, &start, &count) ) {
        protos[i].kind    = CAG_AXIS_STRIDE;
        protos[i].count   = count;
        protos[i].start   = start;
        protos[i].step    = 1;
        protos[i].indices = NULL;
        continue;
      }
      /* fallback: materialise to integer array */
      rval = rb_funcall(rb_mKernel, rb_intern("CA_SIZE"), 1, rval);
    }
    else if ( rb_obj_is_carray(rval) ) {
      if ( rb_ca_is_boolean_type(rval) ) {
        rval = rb_ca_where(rval);
      }
    }
    else if ( TYPE(rval) == T_ARRAY ) {
      rb_raise(rb_eRuntimeError, "not implemented for this index");
    }

    /* INDEX axis */
    ci[i] = ca_wrap_readonly(rval, CA_SIZE);
    rb_ary_push(list, rval);
    ca_attach(ci[i]);

    protos[i].kind = CAG_AXIS_INDEX;
    if ( ca_is_any_masked(ci[i]) ) {
      /* mask-filtered snapshot: skip masked cells.  We point protos[i]
         .indices at a temp buffer alloc'd here and freed after setup
         copies it (setup snapshots into its own ALLOC).  Caller-side
         lifetime: the temp lives until ca_grid_new returns. */
      ca_size_t gsize = ci[i]->elements - ca_count_masked(ci[i]);
      ca_size_t *src  = (ca_size_t *) ci[i]->ptr;
      boolean8_t *m   = (boolean8_t *) ci[i]->mask->ptr;
      ca_size_t *tmp  = ALLOC_N(ca_size_t, gsize > 0 ? gsize : 1);
      ca_size_t j, n = 0;
      for (j = 0; j < ci[i]->elements; j++) {
        if ( ! m[j] ) tmp[n++] = src[j];
      }
      protos[i].count   = gsize;
      protos[i].indices = tmp;
    } else {
      protos[i].count   = ci[i]->elements;
      protos[i].indices = (ca_size_t *) ci[i]->ptr;
    }
    protos[i].start = 0;
    protos[i].step  = 0;
  }

  obj = rb_ca_grid_new(self, ca->ndim, protos);

  /* Cleanup: detach CAWraps + free temp masked-snapshot buffers (setup
     has already copied indices into its own ALLOC). */
  for (i = 0; i < ca->ndim; i++) {
    if ( ci[i] ) {
      if ( ca_is_any_masked(ci[i]) ) {
        xfree(protos[i].indices);
      }
      ca_detach(ci[i]);
    }
  }

  return obj;
}

static VALUE
rb_ca_grid_s_allocate (VALUE klass)
{
  CAGrid *ca;
  return TypedData_Make_Struct(klass, CAGrid, &cagrid_data_type, ca);
}

static VALUE
rb_ca_grid_initialize_copy (VALUE self, VALUE other)
{
  CAGrid *ca, *cs;

  TypedData_Get_Struct(self,  CAGrid, &cagrid_data_type, ca);
  TypedData_Get_Struct(other, CAGrid, &cagrid_data_type, cs);

  if ( ca_func[CA_OBJ_GRID].pool_init ) {
    ca_array_pool_alloc(ca, CA_OBJ_GRID, cs->ndim);
  }
  /* Share the source's axes buffer (CA_FLAG_SHARE_INDEX semantics:
     source CAGrid owns the lifetime; clone aliases it). */
  ca_grid_setup(ca, cs->parent, cs->ndim, cs->axes, 1);

  return self;
}



/* ------------------------------------------------------------------- */
/* Producer interface: emit the per-axis descriptor array -- a 1:1
   mechanical mapping from CAGrid's internal tagged storage to the
   framework descriptor.

   STRIDE axes (= nil-arg or arithmetic-progression Range) carry their
   actual start/step, so axis-merge can fire on these axes when they
   neighbour other STRIDE axes.  INDEX axes borrow the owned
   ca->axes[k].indices snapshot. */

void
ca_grid_describe_axes (void *ap, ca_axis_desc_t *out,
                       ca_size_t *out_parent_dims)
{
  CAGrid *ca = (CAGrid *) ap;
  int8_t k;
  for ( k = 0; k < ca->ndim; k++ ) {
    out_parent_dims[k] = ca->parent->dim[k];
    if ( ca->axes[k].kind == CAG_AXIS_STRIDE ) {
      out[k].kind    = CA_AXIS_KIND_STRIDE;
      out[k].count   = ca->axes[k].count;
      out[k].start   = ca->axes[k].start;
      out[k].step    = ca->axes[k].step;
      out[k].indices = NULL;
    } else {
      out[k].kind    = CA_AXIS_KIND_INDEX;
      out[k].count   = ca->axes[k].count;
      out[k].start   = 0;
      out[k].step    = 0;
      out[k].indices = ca->axes[k].indices;
    }
  }
}

#ifdef CARRAY_DEV_BUILD
/* ============================================================
 * Debug accessors (dev-only, stripped in release)
 *
 * Gated by CARRAY_DEV_BUILD (enabled via `extconf.rb --enable-dev-build`
 * or `CARRAY_DEV=1 rake build_ext`).  They expose the per-axis descriptor
 * and the engine's raw output to Ruby so spec_ai can pin them; nothing in
 * lib/ or the rest of ext/ consumes them.  CASelectAxis carries the same
 * four under the same fence.
 * ============================================================ */

/* Returns the per-axis descriptor as an Array, one entry per axis:
   [:stride, count, start, step] or [:index, count, indices]. */
static VALUE
rb_ca_grid_describe_axes (VALUE self)
{
  CAGrid *ca;
  ca_axis_desc_t desc[CA_RANK_MAX];
  VALUE arr, entry, idx_ary;
  int8_t k;
  ca_size_t i;

  ca_size_t pdims[CA_RANK_MAX];
  TypedData_Get_Struct(self, CAGrid, &cagrid_data_type, ca);
  ca_grid_describe_axes(ca, desc, pdims);

  arr = rb_ary_new_capa(ca->ndim);
  for ( k = 0; k < ca->ndim; k++ ) {
    if ( desc[k].kind == CA_AXIS_KIND_STRIDE ) {
      entry = rb_ary_new_capa(4);
      rb_ary_push(entry, ID2SYM(rb_intern("stride")));
      rb_ary_push(entry, SIZE2NUM(desc[k].count));
      rb_ary_push(entry, SIZE2NUM(desc[k].start));
      rb_ary_push(entry, SIZE2NUM(desc[k].step));
    } else {
      entry = rb_ary_new_capa(3);
      rb_ary_push(entry, ID2SYM(rb_intern("index")));
      rb_ary_push(entry, SIZE2NUM(desc[k].count));
      idx_ary = rb_ary_new_capa(desc[k].count);
      for ( i = 0; i < desc[k].count; i++ ) {
        rb_ary_push(idx_ary, SIZE2NUM(desc[k].indices[i]));
      }
      rb_ary_push(entry, idx_ary);
    }
    rb_ary_push(arr, entry);
  }
  return arr;
}

/* Returns the attach engine's gathered buffer as a String. */
static VALUE
rb_ca_grid_dispatch_attach_debug (VALUE self)
{
  CAGrid *ca;
  ca_axis_desc_t desc[CA_RANK_MAX];
  char *buf;
  VALUE str;

  ca_size_t pdims[CA_RANK_MAX];
  TypedData_Get_Struct(self, CAGrid, &cagrid_data_type, ca);
  ca_grid_describe_axes(ca, desc, pdims);

  ca_attach(ca->parent);
  buf = ca_axis_dispatch_attach(ca->parent, pdims, desc, ca->ndim, ca->bytes,
                                ca->elements, NULL);
  ca_detach(ca->parent);

  str = rb_str_new(buf, ca->elements * ca->bytes);
  xfree(buf);
  return str;
}

/* Drives the scatter engine with a view-shaped input String. */
static VALUE
rb_ca_grid_dispatch_scatter_debug (VALUE self, VALUE in_str)
{
  CAGrid *ca;
  ca_axis_desc_t desc[CA_RANK_MAX];
  ca_size_t expected;

  Check_Type(in_str, T_STRING);
  TypedData_Get_Struct(self, CAGrid, &cagrid_data_type, ca);

  expected = ca->elements * ca->bytes;
  if ( (ca_size_t) RSTRING_LEN(in_str) != expected ) {
    rb_raise(rb_eArgError,
             "CAGrid#_dispatch_scatter_debug: input string length %lld "
             "!= expected %lld",
             (long long) RSTRING_LEN(in_str), (long long) expected);
  }
  ca_size_t pdims[CA_RANK_MAX];
  ca_grid_describe_axes(ca, desc, pdims);

  ca_attach(ca->parent);
  ca_axis_dispatch_scatter(ca->parent, pdims, desc, ca->ndim, ca->bytes,
                           ca->elements, RSTRING_PTR(in_str));
  ca_sync(ca->parent);
  ca_detach(ca->parent);
  return Qnil;
}

/* Drives the fill_value engine with a one-element String. */
static VALUE
rb_ca_grid_dispatch_fill_value_debug (VALUE self, VALUE val_str)
{
  CAGrid *ca;
  ca_axis_desc_t desc[CA_RANK_MAX];

  Check_Type(val_str, T_STRING);
  TypedData_Get_Struct(self, CAGrid, &cagrid_data_type, ca);

  if ( (ca_size_t) RSTRING_LEN(val_str) != ca->bytes ) {
    rb_raise(rb_eArgError,
             "CAGrid#_dispatch_fill_value_debug: value string length %lld "
             "!= bytes %lld",
             (long long) RSTRING_LEN(val_str), (long long) ca->bytes);
  }
  ca_size_t pdims[CA_RANK_MAX];
  ca_grid_describe_axes(ca, desc, pdims);

  ca_attach(ca->parent);
  ca_axis_dispatch_fill_value(ca->parent, pdims, desc, ca->ndim, ca->bytes,
                              ca->elements, RSTRING_PTR(val_str));
  ca_sync(ca->parent);
  ca_detach(ca->parent);
  return Qnil;
}
#endif /* CARRAY_DEV_BUILD */

/* ------------------------------------------------------------------- */

void
Init_ca_obj_grid (void)
{
  rb_cCAGrid = rb_define_class("CAGrid", rb_cCAView);
  rb_cCAGridMask = rb_define_class("CAGridMask", rb_cCAGrid);

  ca_grid_func.struct_size = sizeof(CAGrid);
  ca_grid_func.pool_bytes  = ca_grid_pool_bytes;
  ca_grid_func.pool_init   = ca_grid_pool_init;

  CA_OBJ_GRID = ca_install_obj_type(rb_cCAGrid,
                                    &cagrid_data_type, 
				    rb_cCAGridMask,
				    &cagrid_mask_data_type, &ca_grid_func, sizeof(ca_grid_func));
  rb_define_const(rb_cObject, "CA_OBJ_GRID", INT2NUM(CA_OBJ_GRID));

  rb_define_method(rb_cCArray, "grid", rb_ca_grid, -1);

  rb_define_alloc_func(rb_cCAGrid, rb_ca_grid_s_allocate);
  rb_define_method(rb_cCAGrid, "initialize_copy",
                                      rb_ca_grid_initialize_copy, 1);

#ifdef CARRAY_DEV_BUILD
  /* debug accessors (dev-only, stripped in release) */
  rb_define_method(rb_cCAGrid, "_describe_axes",
                   rb_ca_grid_describe_axes, 0);
  rb_define_method(rb_cCAGrid, "_dispatch_attach_debug",
                   rb_ca_grid_dispatch_attach_debug, 0);
  rb_define_method(rb_cCAGrid, "_dispatch_scatter_debug",
                   rb_ca_grid_dispatch_scatter_debug, 1);
  rb_define_method(rb_cCAGrid, "_dispatch_fill_value_debug",
                   rb_ca_grid_dispatch_fill_value_debug, 1);
#endif
}

