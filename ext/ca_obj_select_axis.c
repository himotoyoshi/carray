/* ---------------------------------------------------------------------------

  CASelectAxis: per-axis boolean selection view (sister of CAGrid for integer
  index).  Mixes AP-axes (nil/Integer/Range) with one boolean-INDIRECT axis,
  and gathers each per-INDIRECT slab using row-major byte strides.

  Sibling of ca_obj_grid.c (CAGrid, the integer-index counterpart); both
  emit a per-axis descriptor consumed by the shared engine in
  ca_axis_dispatch.c.

  Scope:
    - single INDIRECT axis (boolean), other axes AP (nil/Integer/Range)
    - parent must be an entity CArray (no CAStride parent)
    - selector copied at construction (fully static, fragility-free)
    - selector must not have a mask (hard reject)
    - slab copy uses straightforward nested-loop memcpy (no SIMD fast paths)

---------------------------------------------------------------------------- */

#include "carray.h"

typedef struct {
  /* CAView prefix (mirrors carray.h ca_virtual layout) */
  int16_t    obj_type;
  int8_t     data_type;
  int8_t     ndim;
  int32_t    flags;
  ca_size_t  bytes;
  ca_size_t  elements;
  ca_size_t *dim;
  char      *ptr;
  CArray    *mask;
  char     *_pool;         /* framework-managed pool buffer (NULL = legacy ALLOC_N path). */
  CArray    *parent;
  uint32_t   attach;
  uint8_t    nosync;
  /* --- CASelectAxis tail ---
     Single INDIRECT axis (boolean); the other axes are AP. */
  int8_t     indirect_axis;     /* axis index of the boolean-selected axis */
  CArray    *selector;          /* owned copy of boolean CArray (no mask) */
  ca_size_t *ap_start;          /* per axis (size ndim); unused for indirect axis */
  ca_size_t *ap_count;          /* per axis (size ndim); = dim[k] for AP axes */
  ca_size_t *ap_step;           /* per axis (size ndim); unused for indirect axis */
  /* Derived at attach time; freed at detach. */
  ca_size_t *indices;           /* resolved indices for indirect axis (length = dim[indirect_axis]) */
  /* Constant-step detection on indices.  When indices form a constant-step
     sequence (= consecutive TRUE block, full-TRUE mask, equally-spaced
     mask), describe_axes emits STRIDE kind instead of INDEX, letting the
     engine's STRIDE fast path (contiguous memcpy when step==1) replace
     per-cell INDEX lookups. */
  uint8_t    stride_kind;       /* 1 if indices form constant-step run */
  ca_size_t  stride_start;
  ca_size_t  stride_step;
} CASelectAxis;

static size_t
ca_select_axis_dsize (const void *ap)
{
  const CASelectAxis *ca = (const CASelectAxis *) ap;
  return sizeof(CASelectAxis)
       + ca->ndim * sizeof(ca_size_t)        /* dim */
       + 3 * ca->ndim * sizeof(ca_size_t);   /* ap_start, ap_count, ap_step */
}

/* Pool framework hooks: the four ndim-sized arrays (dim, ap_start,
   ap_count, ap_step) move into one _pool buffer.  The variable-size
   `indices` (count_true) and the `selector` CArray copy stay separate. */
static size_t
ca_select_axis_pool_bytes (int8_t ndim)
{
  ca_size_t n = (ndim > 0) ? ndim : 1;
  return 4 * (size_t) n * sizeof(ca_size_t);
}

static void
ca_select_axis_pool_init (void *ap, int8_t ndim)
{
  CASelectAxis *ca = (CASelectAxis *) ap;
  ca_size_t    n   = (ndim > 0) ? ndim : 1;
  ca_size_t   *base = (ca_size_t *) ca->_pool;
  ca->dim      = base + 0 * n;
  ca->ap_start = base + 1 * n;
  ca->ap_count = base + 2 * n;
  ca->ap_step  = base + 3 * n;
}

const rb_data_type_t caselectaxis_data_type = {
    .parent = &caview_data_type,
    .wrap_struct_name = "CASelectAxis",
    .function = {
        .dmark = ca_mark,
        .dfree = ca_free,
        .dsize = ca_select_axis_dsize,
        .dcompact = NULL
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

const rb_data_type_t caselectaxis_mask_data_type = {
    .parent = &caselectaxis_data_type,
    .wrap_struct_name = "CASelectAxisMask",
    .function = {
        .dmark = NULL,
        .dfree = ca_free_nop,
        .dsize = ca_select_axis_dsize,
        .dcompact = NULL
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

static int8_t CA_OBJ_SELECT_AXIS;

/* Benchmark-only bypass flag: when non-zero, rb_ca_grid skips the
   CASelectAxis dispatch hook and falls through to the pre-CSA CAGrid path.
   Exposed to Ruby as CArray._csa_bypass=.  Production code never touches it. */
int ca_csa_dispatch_bypass = 0;

static VALUE
rb_ca_s_csa_bypass_eq (VALUE klass, VALUE val)
{
  (void) klass;
  ca_csa_dispatch_bypass = RTEST(val) ? 1 : 0;
  return val;
}

static VALUE
rb_ca_s_csa_bypass_p (VALUE klass)
{
  (void) klass;
  return ca_csa_dispatch_bypass ? Qtrue : Qfalse;
}

static VALUE rb_cCASelectAxis;
static VALUE rb_cCASelectAxisMask;

/* Forward declarations of internal helpers */
static CArray *ca_select_axis_new (CArray *parent, int8_t indirect_axis,
                                   CArray *selector,
                                   ca_size_t *ap_start,
                                   ca_size_t *ap_count,
                                   ca_size_t *ap_step);

/* ------------------------------------------------------------------- */
/* Setup / constructor / destructor                                    */
/* ------------------------------------------------------------------- */

static int
ca_select_axis_setup (CASelectAxis *ca, CArray *parent, int8_t indirect_axis,
                      CArray *selector,
                      ca_size_t *ap_start, ca_size_t *ap_count, ca_size_t *ap_step)
{
  int8_t k;
  int8_t ndim = parent->ndim;

  /* Validate indirect axis range */
  if ( indirect_axis < 0 || indirect_axis >= ndim ) {
    rb_raise(rb_eArgError,
             "CASelectAxis: indirect_axis %d out of range [0, %d)",
             indirect_axis, ndim);
  }

  /* Validate selector */
  if ( ! ca_is_boolean_type(selector) ) {
    rb_raise(rb_eArgError,
             "CASelectAxis: selector must be a boolean CArray");
  }
  if ( selector->ndim != 1 ) {
    rb_raise(rb_eArgError,
             "CASelectAxis: selector must be 1-D");
  }
  if ( selector->dim[0] != parent->dim[indirect_axis] ) {
    rb_raise(rb_eArgError,
             "CASelectAxis: selector length (%lld) != parent dim[%d] (%lld)",
             (long long) selector->dim[0],
             (int) indirect_axis,
             (long long) parent->dim[indirect_axis]);
  }
  if ( ca_has_mask(selector) ) {
    rb_raise(rb_eArgError,
             "CASelectAxis: selector boolean array must not have a mask. "
             "Use `selector.strip_mask(false)` etc. to flatten first.");
  }

  /* Validate AP axes */
  for ( k = 0; k < ndim; k++ ) {
    if ( k == indirect_axis ) continue;
    if ( ap_step[k] == 0 ) {
      rb_raise(rb_eArgError, "CASelectAxis: ap_step[%d] is 0", (int) k);
    }
    if ( ap_count[k] <= 0 ) {
      rb_raise(rb_eArgError, "CASelectAxis: ap_count[%d] must be positive", (int) k);
    }
    {
      ca_size_t start_v = ap_start[k];
      ca_size_t last_v  = ap_start[k] + (ap_count[k] - 1) * ap_step[k];
      if ( start_v < 0 || start_v >= parent->dim[k] ) {
        rb_raise(rb_eIndexError,
                 "CASelectAxis: ap_start[%d]=%lld out of range [0, %lld)",
                 (int) k, (long long) start_v, (long long) parent->dim[k]);
      }
      if ( last_v < 0 || last_v >= parent->dim[k] ) {
        rb_raise(rb_eIndexError,
                 "CASelectAxis: ap last index at axis %d (%lld) out of range [0, %lld)",
                 (int) k, (long long) last_v, (long long) parent->dim[k]);
      }
    }
  }

  /* Initialise struct */
  ca->obj_type      = CA_OBJ_SELECT_AXIS;
  ca->data_type     = parent->data_type;
  ca->flags         = 0;
  ca->ndim          = ndim;
  ca->bytes         = parent->bytes;
  ca->ptr           = NULL;
  ca->mask          = NULL;
  ca->parent        = parent;
  ca->attach        = 0;
  ca->nosync        = 0;
  ca->indirect_axis = indirect_axis;
  ca->indices       = NULL;

  /* Copy selector (view owns its own copy; immune to external mutation).
     The selector is small (1 axis length), so the copy cost is acceptable,
     and it avoids the fragility CASelect has from live references. */
  ca->selector = ca_copy(selector);

  /* Allocate dim and AP arrays (pool path: already wired by pool_init). */
  if ( ! ca->_pool ) {
    ca->dim      = ALLOC_N(ca_size_t, ndim);
    ca->ap_start = ALLOC_N(ca_size_t, ndim);
    ca->ap_count = ALLOC_N(ca_size_t, ndim);
    ca->ap_step  = ALLOC_N(ca_size_t, ndim);
  }

  /* Walk selector twice: first to count (auto-vectorisable), then to
     snapshot TRUE positions into exactly-sized indices[].  Allocating to
     the exact count avoids large over-allocations for sparse selectors.
     This is the SOLE selector-walk phase in the view's lifecycle. */
  ca_size_t count_true = 0;
  ca_size_t n_input = ca->selector->elements;
  {
    boolean8_t *s = (boolean8_t *) ca->selector->ptr;
    ca_size_t i;
    for ( i = 0; i < n_input; i++ ) {
      count_true += s[i];   /* boolean stored as 0/1, no branch */
    }
  }
  ca->indices = ALLOC_N(ca_size_t, count_true > 0 ? count_true : 1);
  {
    boolean8_t *s = (boolean8_t *) ca->selector->ptr;
    ca_size_t i, j = 0;
    for ( i = 0; i < n_input; i++ ) {
      if ( s[i] ) ca->indices[j++] = i;
    }
  }

  /* Constant-step detection: do indices[] form a constant-step sequence?
     When YES, describe_axes emits STRIDE kind (start/step/count) instead of INDEX,
     unlocking the engine's contig-memcpy fast path for common patterns
     (all-TRUE mask, contiguous TRUE block, equally-spaced mask).  */
  ca->stride_kind  = 0;
  ca->stride_start = 0;
  ca->stride_step  = 1;
  if ( count_true >= 2 ) {
    ca_size_t step = ca->indices[1] - ca->indices[0];
    ca_size_t i;
    int is_const = 1;
    for ( i = 2; i < count_true; i++ ) {
      if ( ca->indices[i] - ca->indices[i-1] != step ) { is_const = 0; break; }
    }
    if ( is_const ) {
      ca->stride_kind  = 1;
      ca->stride_start = ca->indices[0];
      ca->stride_step  = step;
    }
  } else if ( count_true == 1 ) {
    /* single TRUE: degenerate STRIDE (count=1, step irrelevant) */
    ca->stride_kind  = 1;
    ca->stride_start = ca->indices[0];
    ca->stride_step  = 1;
  }

  /* Populate dim and AP arrays */
  for ( k = 0; k < ndim; k++ ) {
    if ( k == indirect_axis ) {
      ca->dim[k]      = count_true;
      ca->ap_start[k] = 0;
      ca->ap_count[k] = count_true;
      ca->ap_step[k]  = 1;
    } else {
      ca->dim[k]      = ap_count[k];
      ca->ap_start[k] = ap_start[k];
      ca->ap_count[k] = ap_count[k];
      ca->ap_step[k]  = ap_step[k];
    }
  }

  /* Compute total elements */
  ca->elements = 1;
  for ( k = 0; k < ndim; k++ ) {
    ca->elements *= ca->dim[k];
  }

  return 0;
}

static CArray *
ca_select_axis_new (CArray *parent, int8_t indirect_axis,
                    CArray *selector,
                    ca_size_t *ap_start, ca_size_t *ap_count, ca_size_t *ap_step)
{
  CASelectAxis *ca = (CASelectAxis *) ca_array_alloc(CA_OBJ_SELECT_AXIS, parent->ndim);
  ca_select_axis_setup(ca, parent, indirect_axis, selector,
                       ap_start, ap_count, ap_step);
  return (CArray *) ca;
}

static void
free_ca_select_axis (void *ap)
{
  CASelectAxis *ca = (CASelectAxis *) ap;
  if ( ca != NULL ) {
    ca_free(ca->mask);
    if ( ca->selector ) ca_free(ca->selector);
    if ( ca->indices  ) xfree(ca->indices);   /* variable-size, separate */
    if ( ca->_pool ) {
      /* dim/ap_start/ap_count/ap_step all live in _pool. */
      ca_array_free(ca);
    }
    else {
      if ( ca->ap_start ) xfree(ca->ap_start);
      if ( ca->ap_count ) xfree(ca->ap_count);
      if ( ca->ap_step  ) xfree(ca->ap_step);
      if ( ca->dim ) xfree(ca->dim);
      xfree(ca);
    }
  }
}

/* ------------------------------------------------------------------- */
/* Operation functions                                                 */
/*                                                                     */
/* All gather / scatter / fill paths delegate to the common descriptor */
/* engine in ext/ca_axis_dispatch.c.  This file holds only view-specific */
/* concerns: setup, describe_axes, mask, lifecycle.                    */
/* ------------------------------------------------------------------- */

static void *
ca_select_axis_func_clone (void *ap)
{
  CASelectAxis *ca = (CASelectAxis *) ap;
  return ca_select_axis_new(ca->parent, ca->indirect_axis, ca->selector,
                            ca->ap_start, ca->ap_count, ca->ap_step);
}

/* Compute parent index for a single output index, without requiring attach.
   Uses the pre-computed ca->indices[] snapshot (built once at setup) for the
   indirect axis -- O(1) indirect load. */
static void
ca_select_axis_output_to_parent_idx (CASelectAxis *ca, ca_size_t *out_idx,
                                     ca_size_t *parent_idx)
{
  int8_t k;
  int8_t iax = ca->indirect_axis;
  for ( k = 0; k < ca->ndim; k++ ) {
    if ( k == iax ) {
      parent_idx[k] = ca->indices[out_idx[k]];
    } else {
      parent_idx[k] = ca->ap_start[k] + out_idx[k] * ca->ap_step[k];
    }
  }
}

/* per-cell logic lives in ca_select_axis_func_xfer_index; forward-declared
   for the region-delivery paths below. */
static void ca_select_axis_func_xfer_index (void *ap, ca_size_t *idx, void *data, int dir);

/* dir-unified per-cell.  Direct addressing when attached; otherwise
   translate the output index to
   parent's index and delegate to ca_xfer_index (which handles boundary-view
   parents safely -- replaces the old ptr_at_index-based path). */
static void
ca_select_axis_func_xfer_index (void *ap, ca_size_t *idx, void *data, int dir)
{
  CASelectAxis *ca = (CASelectAxis *) ap;
  if ( ca->ptr ) {
    ca_size_t addr = ca_index2addr((CArray *) ca, idx);
    char *p = ca->ptr + ca->bytes * addr;
    if (dir == CA_XFER_GET) memcpy(data, p, ca->bytes);
    else                    memcpy(p, data, ca->bytes);
    return;
  }
  /* Not attached: compute parent's index, delegate. */
  ca_size_t pidx[CA_RANK_MAX];
  ca_select_axis_output_to_parent_idx(ca, idx, pidx);
  ca_xfer_index(ca->parent, pidx, data, dir);
}

/* Batched address gather/scatter.  Per-axis output->parent index remap,
   always in-bounds.  ONE parent ca_xfer_addrs call -- no whole-view attach.

   Fast path: when the addrs are a whole-view sequential run
   [0..elements-1] and parent.ptr is present, bypass the ALLOCV per-cell
   remap loop and dispatch directly to ca_axis_dispatch_gather/_scatter
   (same engine xfer_all uses).  This fires for the hot pattern
   ca[:is_not_masked] / ca[mostly_true_mask], which degenerates to
   whole-view sequential addrs through this slot.  Sub-region sequential
   addrs are not lifted (would require row-major rectangular
   reconstruction); the per-cell path handles them.  No ca_attach added;
   parent.ptr is opportunistic. */
static void
ca_select_axis_func_xfer_addrs (void *ap, ca_size_t n, ca_size_t *addrs,
                                void *data, int dir)
{
  CASelectAxis *ca = (CASelectAxis *) ap;
  CArray   *parent = ca->parent;
  ca_size_t *paddrs;
  ca_size_t  i, base;
  volatile VALUE holder;

  /* Opportunistic fast path.  ca_resolve_attached_root_via_identity lifts
     parent->ptr through an identity CAStride compose-fold (= a CARefer
     reshape view over an entity, etc.). */
  if ( n == ca->elements
       && ca_xfer_addrs_is_sequential_run(n, addrs, &base) && base == 0 ) {
    CArray *eff_parent = ca_resolve_attached_root_via_identity(parent);
    if ( eff_parent->ptr ) {
      ca_axis_desc_t sub_axes[CA_RANK_MAX];
      ca_size_t      parent_axis_dims[CA_RANK_MAX];
      int8_t         k, iax = ca->indirect_axis;
      for ( k = 0; k < ca->ndim; k++ ) {
        parent_axis_dims[k] = parent->dim[k];
        if ( k == iax ) {
          sub_axes[k].kind    = CA_AXIS_KIND_INDEX;
          sub_axes[k].count   = ca->dim[k];
          sub_axes[k].start   = 0;
          sub_axes[k].step    = 0;
          sub_axes[k].indices = ca->indices;   /* pre-computed TRUE positions */
        } else {
          sub_axes[k].kind    = CA_AXIS_KIND_STRIDE;
          sub_axes[k].count   = ca->dim[k];
          sub_axes[k].start   = ca->ap_start[k];
          sub_axes[k].step    = ca->ap_step[k];
          sub_axes[k].indices = NULL;
        }
      }
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
    ca_select_axis_output_to_parent_idx(ca, vidx, pidx);
    paddrs[i] = ca_index2addr(ca->parent, pidx);
  }
  ca_xfer_addrs(ca->parent, n, paddrs, data, dir);
  ALLOCV_END(holder);
}

/* fold_stride: a CSA folds when every axis is stride-expressible.  AP
   (non-indirect) axes always are
   (start_k + i*step_k).  The boolean-selected (indirect) axis folds only when
   it selects exactly one element (dim == 1): the single TRUE position bakes
   into the base.  A multi-element selection is a true gather -> decline.
   Synthesises a CAStride over parent and composes f through it. */
static int
ca_select_axis_func_fold_stride (void *ap, ca_fold_t *f, void **next_parent)
{
  CASelectAxis *ca = (CASelectAxis *) ap;
  CArray   *parent = ca->parent;
  int8_t    iax = ca->indirect_axis;
  ca_size_t pstride[CA_RANK_MAX];
  ca_size_t synth_strides[CA_RANK_MAX];
  ca_size_t synth_base = 0;
  ca_size_t next_strides[CA_RANK_MAX];
  ca_size_t next_base;
  ca_size_t s;
  CAStride  tmp, synth;
  int8_t    k;

  if ( ca->dim[iax] != 1 ) {
    return 0;   /* multi-element boolean selection -> true gather, decline */
  }

  /* parent row-major byte strides (ca->bytes == parent->bytes) */
  s = ca->bytes;
  for (k = ca->ndim - 1; k >= 0; k--) {
    pstride[k] = s;
    s *= parent->dim[k];
  }

  for (k = 0; k < ca->ndim; k++) {
    if ( k == iax ) {
      /* single TRUE position (dim==1 case) -> baked into base (count 1).
         Pre-computed in ca->indices[0] at setup; no re-scan of selector. */
      synth_strides[k] = 0;
      synth_base      += ca->indices[0] * pstride[k];
    }
    else {
      synth_strides[k] = ca->ap_step[k] * pstride[k];
      synth_base      += ca->ap_start[k] * pstride[k];
    }
  }

  tmp.ndim = f->ndim;
  tmp.bytes = ca->bytes;
  tmp.dim = f->counts;
  tmp.strides = f->strides;
  tmp.base_offset = f->base;

  synth.ndim = ca->ndim;
  synth.bytes = ca->bytes;
  synth.dim = ca->dim;
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

/* xfer_stride: structural region delivery when a multi-select CSA is the
   (declining) fold boundary.  Mirrors CAGrid:
   the indirect (boolean-selected) axis behaves like INDEX, the AP axes like
   STRIDE.  Iterate the outer axes; deliver the innermost axis as one run --
   parent.xfer_stride for an AP inner axis, parent.xfer_addrs for the indirect
   inner axis.  data is contiguous (semantics b, no whole-view attach).
   The indirect axis's TRUE positions are resolved once from the selector
   (snapshot, no attach).  Non-axis-aligned / unexpected requests fall back to
   per-cell delivery (the wiring guards ndim == parent ndim). */
static void
ca_select_axis_func_xfer_stride (void *ap, ca_size_t *starts, ca_size_t *counts,
                                 ca_size_t *strides, void *data, int dir)
{
  CASelectAxis *ca = (CASelectAxis *) ap;
  CArray   *parent = ca->parent;
  int8_t    ndim = ca->ndim;
  int8_t    inner = ndim - 1;
  int8_t    iax = ca->indirect_axis;
  ca_size_t pnative[CA_RANK_MAX];   /* parent row-major byte strides */
  ca_size_t cnative[CA_RANK_MAX];   /* CSA row-major byte strides */
  ca_size_t dstride[CA_RANK_MAX];   /* data row-major byte strides over counts */
  ca_size_t src_step[CA_RANK_MAX];
  ca_size_t o[CA_RANK_MAX];
  const ca_size_t *tpos;            /* TRUE positions of indirect axis (= ca->indices) */
  ca_size_t  s;
  int8_t     k;
  int        aligned = 1;
  char      *d = (char *) data;

  s = parent->bytes;
  for (k = ndim - 1; k >= 0; k--) { pnative[k] = s; s *= parent->dim[k]; }
  s = ca->bytes;
  for (k = ndim - 1; k >= 0; k--) { cnative[k] = s; s *= ca->dim[k]; }
  s = ca->bytes;
  for (k = ndim - 1; k >= 0; k--) { dstride[k] = s; s *= counts[k]; }

  /* The request is over the view's addresses, so a transposed / flat request
     is legal and must not be composed axis-by-axis; see
     ca_xfer_stride_request_is_axis_box (carray.h). */
  if ( ! ca_xfer_stride_request_is_axis_box(ca, starts, counts, strides) ) {
    aligned = 0;
  }
  else {
    for (k = 0; k < ndim; k++) {
      if (strides[k] % cnative[k] != 0) { aligned = 0; break; }
      src_step[k] = strides[k] / cnative[k];
    }
  }

  if (!aligned) {
    ca_size_t idx[CA_RANK_MAX], doff = 0, base = 0;
    for (k = 0; k < ndim; k++) base += starts[k] * cnative[k];
    for (k = 0; k < ndim; k++) idx[k] = 0;
    while (1) {
      ca_size_t coff = base, cidx[CA_RANK_MAX];
      for (k = 0; k < ndim; k++) coff += idx[k] * strides[k];
      ca_addr2index((CArray *) ca, coff / ca->bytes, cidx);
      ca_select_axis_func_xfer_index(ca, cidx, d + doff, dir);
      doff += ca->bytes;
      k = ndim - 1;
      while (k >= 0) { if (++idx[k] < counts[k]) break; idx[k] = 0; k--; }
      if (k < 0) break;
    }
    return;
  }

  /* TRUE positions of the indirect axis are pre-computed in ca->indices[]
     at setup (length = ca->dim[iax] = count_true). */
  tpos = ca->indices;

  /* Fast path: when parent is attached (ptr != NULL), translate the
     sub-region request (starts/counts/src_step) into a transient
     ca_axis_desc_t[] sub-descriptor and call
     ca_axis_dispatch_gather/_scatter directly.  Same engine entry
     ca_select_axis_func_xfer_all uses (minus the ca_attach(parent) call,
     which per-region functions must not do).  Collapses count_true
     outer-dispatch calls into 1 batched engine call.  Mirrors the CAGrid
     xfer_stride fast path, with indirect_axis playing the role of an INDEX
     axis.

     Parent unattached (= view parent) falls through to the per-row loop
     below. */
  if ( parent->ptr ) {
    ca_axis_desc_t sub_axes[CA_RANK_MAX];
    ca_size_t      parent_axis_dims[CA_RANK_MAX];
    ca_size_t     *index_buf = NULL;
    volatile VALUE index_holder = Qnil;
    ca_size_t      total_elements = 1;
    ca_size_t      j;

    for ( k = 0; k < ndim; k++ ) {
      parent_axis_dims[k] = parent->dim[k];
      total_elements     *= counts[k];
      if ( k == iax ) {
        /* INDIRECT axis */
        sub_axes[k].kind    = CA_AXIS_KIND_INDEX;
        sub_axes[k].count   = counts[k];
        sub_axes[k].start   = 0;
        sub_axes[k].step    = 0;
        if ( src_step[k] == 1 ) {
          /* zero-copy pointer offset */
          sub_axes[k].indices = (ca_size_t *)(tpos + starts[k]);
        } else {
          /* sub-sampled or reversed: materialise sub-indices */
          index_buf = ALLOCV_N(ca_size_t, index_holder, counts[k]);
          for ( j = 0; j < counts[k]; j++ ) {
            index_buf[j] = tpos[starts[k] + j * src_step[k]];
          }
          sub_axes[k].indices = index_buf;
        }
      } else {
        /* AP / STRIDE axis */
        sub_axes[k].kind    = CA_AXIS_KIND_STRIDE;
        sub_axes[k].count   = counts[k];
        sub_axes[k].start   = ca->ap_start[k] + starts[k] * ca->ap_step[k];
        sub_axes[k].step    = ca->ap_step[k] * src_step[k];
        sub_axes[k].indices = NULL;
      }
    }

    if ( dir == CA_XFER_GET ) {
      ca_axis_dispatch_gather(parent, parent_axis_dims, sub_axes, ndim,
                              ca->bytes, total_elements, NULL, d);
    } else {
      ca_axis_dispatch_scatter(parent, parent_axis_dims, sub_axes, ndim,
                               ca->bytes, total_elements, d);
    }

    if ( index_buf != NULL ) ALLOCV_END(index_holder);
    return;
  }

  /* Fallback (parent unattached): per-row outer loop + per-row
     ca_xfer_stride/ca_xfer_addrs. */
  for (k = 0; k < ndim; k++) o[k] = 0;

  while (1) {
    ca_size_t pbase = 0, doff = 0;
    for (k = 0; k < inner; k++) {
      ca_size_t gpos = starts[k] + o[k] * src_step[k];
      ca_size_t ppos = (k == iax) ? tpos[gpos]
                                  : (ca->ap_start[k] + gpos * ca->ap_step[k]);
      pbase += ppos * pnative[k];
      doff  += o[k] * dstride[k];
    }

    if (inner != iax) {   /* AP inner axis -> STRIDE run */
      ca_size_t pstarts[CA_RANK_MAX], pcounts[CA_RANK_MAX], pstrides[CA_RANK_MAX];
      ca_size_t inner_pbase =
        (ca->ap_start[inner] + starts[inner] * ca->ap_step[inner]) * pnative[inner];
      ca_addr2index((CArray *) parent, (pbase + inner_pbase) / parent->bytes, pstarts);
      for (k = 0; k < ndim; k++) { pcounts[k] = 1; pstrides[k] = 0; }
      pcounts[inner]  = counts[inner];
      pstrides[inner] = src_step[inner] * ca->ap_step[inner] * pnative[inner];
      ca_xfer_stride(parent, pstarts, pcounts, pstrides, d + doff, dir);
    }
    else {                /* indirect inner axis -> gather */
      ca_size_t *addrs;
      ca_size_t  j, n = counts[inner];
      volatile VALUE holder;
      addrs = ALLOCV_N(ca_size_t, holder, n);
      for (j = 0; j < n; j++) {
        ca_size_t gpos = starts[inner] + j * src_step[inner];
        addrs[j] = (pbase + tpos[gpos] * pnative[inner]) / parent->bytes;
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
ca_select_axis_func_allocate (void *ap)
{
  CASelectAxis *ca = (CASelectAxis *) ap;
  ca_attach(ca->parent);
  ca->ptr = xmalloc(ca_length(ca));
}

/* attach / sync / copy_data / sync_data / fill_data all go through the
   common descriptor engine.  This file holds only describe_axes for
   translating CSA state into the shared descriptor; the engine in
   ext/ca_axis_dispatch.c does the rest. */

static void
ca_select_axis_func_attach (void *ap)
{
  CASelectAxis *ca = (CASelectAxis *) ap;
  ca_axis_desc_t desc[CA_RANK_MAX];
  ca_size_t      pdims[CA_RANK_MAX];
  ca_attach(ca->parent);
  ca_select_axis_describe_axes(ca, desc, pdims);
  ca->ptr = ca_axis_dispatch_attach(ca->parent, pdims, desc, ca->ndim,
                                    ca->bytes, ca->elements, NULL);
}

static void
ca_select_axis_func_sync (void *ap)
{
  CASelectAxis *ca = (CASelectAxis *) ap;
  ca_axis_desc_t desc[CA_RANK_MAX];
  ca_size_t      pdims[CA_RANK_MAX];
  ca_select_axis_describe_axes(ca, desc, pdims);
  ca_axis_dispatch_scatter(ca->parent, pdims, desc, ca->ndim, ca->bytes,
                           ca->elements, ca->ptr);
  ca_sync(ca->parent);
}

static void
ca_select_axis_func_detach (void *ap)
{
  CASelectAxis *ca = (CASelectAxis *) ap;
  if ( ca->ptr ) {
    xfree(ca->ptr);
    ca->ptr = NULL;
  }
  /* indices[] lives for the view's lifetime; freed in free_ca_select_axis. */
  ca_detach(ca->parent);
}

/* xfer_all: fast path on parent->ptr, with no silent transitive attach
   of the parent.  A cold parent uses a proper 2-pass (materialise the
   parent into scratch, expose it as parent->ptr, run the fast path, then
   write scratch back for PUT). */
static void
ca_select_axis_func_run_fast_path (CASelectAxis *ca, char *data, int dir)
{
  ca_axis_desc_t desc[CA_RANK_MAX];
  ca_size_t      pdims[CA_RANK_MAX];
  ca_select_axis_describe_axes(ca, desc, pdims);
  if ( dir == CA_XFER_GET ) {
    ca_axis_dispatch_gather(ca->parent, pdims, desc, ca->ndim, ca->bytes,
                            ca->elements, NULL, data);
  } else {
    ca_axis_dispatch_scatter(ca->parent, pdims, desc, ca->ndim, ca->bytes,
                             ca->elements, data);
  }
}

static void
ca_select_axis_func_xfer_all (void *ap, void *data, int dir)
{
  CASelectAxis *ca = (CASelectAxis *) ap;
  if ( ca->parent->ptr ) {
    ca_select_axis_func_run_fast_path(ca, (char *) data, dir);
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
    ca_select_axis_func_run_fast_path(ca, (char *) data, dir);
    if ( dir == CA_XFER_PUT ) {
      ca_xfer_all(parent, parent_scratch, CA_XFER_PUT);
    }
    parent->ptr = parent_ptr_saved;
    ALLOCV_END(holder);
  }
}

static void
ca_select_axis_func_fill_data (void *ap, void *val)
{
  CASelectAxis *ca = (CASelectAxis *) ap;
  ca_axis_desc_t desc[CA_RANK_MAX];
  ca_size_t      pdims[CA_RANK_MAX];

  ca_select_axis_describe_axes(ca, desc, pdims);

  /* Writing the selected cells used to go through a whole-parent attach and
     sync.  Where that attach is a gather rather than an alias, the cells this
     view did not select make the round trip for nothing -- and through a
     lossy layer they do not come back the same.  Hand each slab to the parent
     as a region instead.  (PROPOSAL_PARTIAL_FILL_WHOLE_ROOT_WRITEBACK.md) */
  if ( !ca_is_attached(ca->parent) && !ca_attach_is_alias(ca->parent) ) {
    ca_axis_dispatch_fill_value_via_parent(ca->parent, pdims, desc, ca->ndim,
                                           ca->bytes, ca->elements, val);
    return;
  }

  ca_attach(ca->parent);
  ca_axis_dispatch_fill_value(ca->parent, pdims, desc, ca->ndim, ca->bytes,
                              ca->elements, val);
  ca_sync(ca->parent);
  ca_detach(ca->parent);
}

static void
ca_select_axis_func_create_mask (void *ap)
{
  CASelectAxis *ca = (CASelectAxis *) ap;
  ca_update_mask(ca->parent);
  if ( ! ca->parent->mask ) {
    ca_create_mask(ca->parent);
  }
  ca->mask = ca_select_axis_new(ca->parent->mask, ca->indirect_axis,
                                ca->selector,
                                ca->ap_start, ca->ap_count, ca->ap_step);
}

ca_operation_function_t ca_select_axis_func = {
  -1, /* CA_OBJ_SELECT_AXIS, populated at install time */
  CA_VIEW_ARRAY,
  free_ca_select_axis,
  ca_select_axis_func_clone,
  ca_select_axis_func_allocate,
  ca_select_axis_func_attach,
  ca_select_axis_func_sync,
  ca_select_axis_func_detach,
  ca_select_axis_func_fill_data,
  ca_select_axis_func_create_mask,
  ca_select_axis_func_xfer_index,
  ca_select_axis_func_xfer_addrs,
  ca_select_axis_func_fold_stride,
  ca_select_axis_func_xfer_stride,
  ca_select_axis_func_xfer_all,
};

/* ------------------------------------------------------------------- */
/* Ruby surface (debug constructor + indexer dispatch)                 */
/* ------------------------------------------------------------------- */

static VALUE
rb_ca_select_axis_s_allocate (VALUE klass)
{
  CASelectAxis *ca;
  return TypedData_Make_Struct(klass, CASelectAxis, &caselectaxis_data_type, ca);
}

static VALUE
rb_ca_select_axis_initialize_copy (VALUE self, VALUE other)
{
  CASelectAxis *ca, *cs;
  TypedData_Get_Struct(self,  CASelectAxis, &caselectaxis_data_type, ca);
  TypedData_Get_Struct(other, CASelectAxis, &caselectaxis_data_type, cs);
  if ( ca_func[CA_OBJ_SELECT_AXIS].pool_init ) {
    ca_array_pool_alloc(ca, CA_OBJ_SELECT_AXIS, cs->parent->ndim);
  }
  ca_select_axis_setup(ca, cs->parent, cs->indirect_axis, cs->selector,
                       cs->ap_start, cs->ap_count, cs->ap_step);
  return self;
}

/* Debug-only Ruby ctor:
   CASelectAxis._new_debug(parent, indirect_axis, selector,
                            ap_start_arr, ap_count_arr, ap_step_arr)

   ap_*_arr are Arrays of size parent.ndim.  Entries for the indirect axis
   are ignored.  Intended for testing only; production dispatch runs
   through rb_ca_select_axis (from the `[]` indexer in carray_access.c). */
static VALUE
rb_ca_select_axis_s_new_debug (VALUE klass, VALUE rparent, VALUE rindirect,
                                VALUE rselector, VALUE rap_start,
                                VALUE rap_count, VALUE rap_step)
{
  CArray *parent, *selector;
  int8_t indirect_axis = (int8_t) NUM2INT(rindirect);
  int8_t ndim;
  int8_t k;
  VALUE obj;
  CASelectAxis *ca;

  Check_Type(rap_start, T_ARRAY);
  Check_Type(rap_count, T_ARRAY);
  Check_Type(rap_step,  T_ARRAY);

  TypedData_Get_Struct(rparent,   CArray, &carray_data_type, parent);
  TypedData_Get_Struct(rselector, CArray, &carray_data_type, selector);

  ndim = parent->ndim;
  if ( RARRAY_LEN(rap_start) != ndim ||
       RARRAY_LEN(rap_count) != ndim ||
       RARRAY_LEN(rap_step)  != ndim ) {
    rb_raise(rb_eArgError,
             "CASelectAxis._new_debug: ap_* arrays must have length %d", ndim);
  }

  ca_size_t ap_start_buf[CA_RANK_MAX];
  ca_size_t ap_count_buf[CA_RANK_MAX];
  ca_size_t ap_step_buf[CA_RANK_MAX];
  for ( k = 0; k < ndim; k++ ) {
    ap_start_buf[k] = (ca_size_t) NUM2LL(rb_ary_entry(rap_start, k));
    ap_count_buf[k] = (ca_size_t) NUM2LL(rb_ary_entry(rap_count, k));
    ap_step_buf[k]  = (ca_size_t) NUM2LL(rb_ary_entry(rap_step,  k));
  }

  obj = TypedData_Make_Struct(klass, CASelectAxis, &caselectaxis_data_type, ca);
  ca_select_axis_setup(ca, parent, indirect_axis, selector,
                       ap_start_buf, ap_count_buf, ap_step_buf);
  rb_ca_set_parent(obj, rparent);
  rb_ivar_set(obj, rb_intern("_selector"), rselector);
  return obj;
}

/* ------------------------------------------------------------------- */
/* Indexer dispatch hook: called from rb_ca_grid                       */
/* ------------------------------------------------------------------- */

/* Eligibility check: route ca[*spec] to CASelectAxis only when CSA's
   slab fast path applies AND CSA is expected to outperform CAGrid:
   - argc == ca->ndim
   - exactly one boolean CArray argument; rest are nil / Integer / Range
   - the boolean is on axis 0 (outermost) — slab fast path criterion

   Pattern A (mask outer + AP inner) is the only configuration where CSA's
   single-walk slab xfer beats CAGrid's recursive innermost-contig attach.
   Other configurations (interleaved AP+INDIRECT, indirect inner, AP with
   step != 1) are routed to CAGrid to avoid regressions. */
int
rb_ca_select_axis_eligible_p (int argc, VALUE *argv, VALUE self)
{
  CArray *ca;
  int i;

  /* Cheapest rejection first: argv[0] must be T_DATA (CArray-shaped).
     Everything else (nil, Fixnum, Range, ...) fails TYPE check in O(1). */
  if ( argc < 1 ) return 0;
  if ( TYPE(argv[0]) != T_DATA ) return 0;

  /* Now the slower checks: is it a CArray, is it boolean. */
  if ( ! rb_obj_is_carray(argv[0]) ) return 0;
  if ( ! rb_ca_is_boolean_type(argv[0]) ) return 0;

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  if ( argc != ca->ndim ) return 0;

  /* axis 0 is the boolean (indirect).  Walk rest; require nil/Integer/Range. */
  for ( i = 1; i < argc; i++ ) {
    VALUE arg = argv[i];
    if ( NIL_P(arg) ) continue;
    if ( FIXNUM_P(arg) ) continue;
    if ( TYPE(arg) == T_DATA ) return 0;   /* CArray at axis > 0 → bail */
    if ( rb_obj_is_kind_of(arg, rb_cRange) ) continue;
    if ( rb_obj_is_kind_of(arg, rb_cInteger) ) continue;
    return 0;
  }

  return 1;
}

/* Construct a CASelectAxis from the indexer's argc/argv.  Assumes
   rb_ca_select_axis_eligible_p has already returned 1. */
VALUE
rb_ca_select_axis (int argc, VALUE *argv, VALUE self)
{
  CArray *parent;
  CArray *selector = NULL;
  ca_size_t ap_start[CA_RANK_MAX];
  ca_size_t ap_count[CA_RANK_MAX];
  ca_size_t ap_step[CA_RANK_MAX];
  int8_t indirect_axis = -1;
  VALUE rselector_keep = Qnil;
  VALUE obj;
  CASelectAxis *ca;
  int i;

  TypedData_Get_Struct(self, CArray, &carray_data_type, parent);

  if ( argc != parent->ndim ) {
    rb_raise(rb_eArgError,
             "CASelectAxis dispatch: argc (%d) != ndim (%d)", argc, parent->ndim);
  }

  for ( i = 0; i < argc; i++ ) {
    VALUE arg = argv[i];

    if ( NIL_P(arg) ) {
      ap_start[i] = 0;
      ap_count[i] = parent->dim[i];
      ap_step[i]  = 1;
    }
    else if ( FIXNUM_P(arg) || rb_obj_is_kind_of(arg, rb_cInteger) ) {
      ca_size_t n = NUM2LL(arg);
      if ( n < 0 ) n += parent->dim[i];
      if ( n < 0 || n >= parent->dim[i] ) {
        rb_raise(rb_eIndexError,
                 "CASelectAxis: index %lld out of range at axis %d",
                 (long long) n, i);
      }
      ap_start[i] = n;
      ap_count[i] = 1;
      ap_step[i]  = 1;
    }
    else if ( rb_obj_is_kind_of(arg, rb_cRange) ) {
      VALUE rfirst = rb_funcall(arg, rb_intern("first"), 0);
      VALUE rlast  = rb_funcall(arg, rb_intern("last"),  0);
      int exclusive = RTEST(rb_funcall(arg, rb_intern("exclude_end?"), 0));
      ca_size_t a = NUM2LL(rfirst);
      ca_size_t b = NUM2LL(rlast);
      if ( a < 0 ) a += parent->dim[i];
      if ( b < 0 ) b += parent->dim[i];
      ca_size_t cnt = exclusive ? (b - a) : (b - a + 1);
      if ( cnt <= 0 ) {
        rb_raise(rb_eIndexError,
                 "CASelectAxis: empty range at axis %d", i);
      }
      if ( a < 0 || a >= parent->dim[i] ||
           (a + cnt - 1) < 0 || (a + cnt - 1) >= parent->dim[i] ) {
        rb_raise(rb_eIndexError,
                 "CASelectAxis: range [%lld..%lld] out of bounds at axis %d",
                 (long long) a, (long long) (a + cnt - 1), i);
      }
      ap_start[i] = a;
      ap_count[i] = cnt;
      ap_step[i]  = 1;
    }
    else if ( rb_obj_is_carray(arg) && rb_ca_is_boolean_type(arg) ) {
      TypedData_Get_Struct(arg, CArray, &carray_data_type, selector);
      indirect_axis = (int8_t) i;
      rselector_keep = arg;
      ap_start[i] = 0;
      ap_count[i] = 0;        /* unused for indirect axis */
      ap_step[i]  = 1;
    }
    else {
      rb_raise(rb_eArgError,
               "CASelectAxis: unsupported index type at axis %d", i);
    }
  }

  if ( indirect_axis < 0 ) {
    rb_raise(rb_eRuntimeError,
             "CASelectAxis dispatch: no boolean axis found (eligibility bug)");
  }

  obj = TypedData_Make_Struct(rb_cCASelectAxis, CASelectAxis,
                              &caselectaxis_data_type, ca);
  ca_select_axis_setup(ca, parent, indirect_axis, selector,
                       ap_start, ap_count, ap_step);

  /* Keep Ruby objects alive (parent and selector references).  The parent
     goes through rb_ca_set_parent so #parent, #root_array and #ancestors
     read the same link here as they do through every other view. */
  rb_ca_set_parent(obj, self);
  rb_ivar_set(obj, rb_intern("_selector"), rselector_keep);
  return obj;
}

/* ------------------------------------------------------------------- */
/* Producer interface: emit the per-axis descriptor array.
   Writes ca->ndim entries into `out` (caller-allocated) and the
   matching effective parent dim into `out_parent_dims` (caller-
   allocated, sized CA_RANK_MAX).  CSA is a per-axis view (descriptor.
   ndim == parent.ndim), so out_parent_dims is just parent->dim
   copied through. */

void
ca_select_axis_describe_axes (void *ap, ca_axis_desc_t *out,
                              ca_size_t *out_parent_dims)
{
  CASelectAxis *ca = (CASelectAxis *) ap;
  int8_t k;
  for ( k = 0; k < ca->ndim; k++ ) {
    out_parent_dims[k] = ca->parent->dim[k];
    if ( k == ca->indirect_axis ) {
      if ( ca->stride_kind ) {
        /* constant-step run -> STRIDE kind. */
        out[k].kind    = CA_AXIS_KIND_STRIDE;
        out[k].count   = ca->dim[k];
        out[k].start   = ca->stride_start;
        out[k].step    = ca->stride_step;
        out[k].indices = NULL;
      } else {
        out[k].kind    = CA_AXIS_KIND_INDEX;
        out[k].count   = ca->dim[k];
        out[k].start   = 0;
        out[k].step    = 0;
        out[k].indices = ca->indices;
      }
    } else {
      out[k].kind    = CA_AXIS_KIND_STRIDE;
      out[k].count   = ca->ap_count[k];
      out[k].start   = ca->ap_start[k];
      out[k].step    = ca->ap_step[k];
      out[k].indices = NULL;
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
 * lib/ or the rest of ext/ consumes them.  CAGrid carries the same four
 * under the same fence.
 * ============================================================ */

/* Returns an Array of per-axis Arrays:
     STRIDE axis -> [:stride, count, start, step]
     INDEX  axis -> [:index,  count, [indices...]] */
static VALUE
rb_ca_select_axis_describe_axes (VALUE self)
{
  CASelectAxis *ca;
  ca_axis_desc_t desc[CA_RANK_MAX];
  VALUE arr, entry, idx_ary;
  int8_t k;
  ca_size_t i;

  ca_size_t pdims[CA_RANK_MAX];
  TypedData_Get_Struct(self, CASelectAxis, &caselectaxis_data_type, ca);
  ca_select_axis_describe_axes(ca, desc, pdims);

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

/* Returns the raw bytes produced by ca_axis_dispatch_attach as a String.
   Compared against `view.to_ca.dump_binary` in tests to verify binary
   equality with the existing attach path. */
static VALUE
rb_ca_select_axis_dispatch_attach_debug (VALUE self)
{
  CASelectAxis *ca;
  ca_axis_desc_t desc[CA_RANK_MAX];
  char *buf;
  VALUE str;

  ca_size_t pdims[CA_RANK_MAX];
  TypedData_Get_Struct(self, CASelectAxis, &caselectaxis_data_type, ca);
  ca_select_axis_describe_axes(ca, desc, pdims);

  ca_attach(ca->parent);
  buf = ca_axis_dispatch_attach(ca->parent, pdims, desc, ca->ndim, ca->bytes,
                                ca->elements, NULL);
  ca_detach(ca->parent);

  str = rb_str_new(buf, ca->elements * ca->bytes);
  xfree(buf);
  return str;
}

/* Feeds a String of bytes (length == elements * bytes) through
   ca_axis_dispatch_scatter and returns nil.  Mutates the parent; tests
   compare the resulting parent state against the same scatter performed
   through the view's sync path. */
static VALUE
rb_ca_select_axis_dispatch_scatter_debug (VALUE self, VALUE in_str)
{
  CASelectAxis *ca;
  ca_axis_desc_t desc[CA_RANK_MAX];
  ca_size_t expected;

  Check_Type(in_str, T_STRING);
  TypedData_Get_Struct(self, CASelectAxis, &caselectaxis_data_type, ca);

  expected = ca->elements * ca->bytes;
  if ( (ca_size_t) RSTRING_LEN(in_str) != expected ) {
    rb_raise(rb_eArgError,
             "CASelectAxis#_dispatch_scatter_debug: input string length %lld "
             "!= expected %lld",
             (long long) RSTRING_LEN(in_str), (long long) expected);
  }
  ca_size_t pdims[CA_RANK_MAX];
  ca_select_axis_describe_axes(ca, desc, pdims);

  ca_attach(ca->parent);
  ca_axis_dispatch_scatter(ca->parent, pdims, desc, ca->ndim, ca->bytes,
                           ca->elements, RSTRING_PTR(in_str));
  ca_sync(ca->parent);
  ca_detach(ca->parent);
  return Qnil;
}

/* Broadcasts a String of length == bytes (one value) into every selected
   parent cell through ca_axis_dispatch_fill_value. */
static VALUE
rb_ca_select_axis_dispatch_fill_value_debug (VALUE self, VALUE val_str)
{
  CASelectAxis *ca;
  ca_axis_desc_t desc[CA_RANK_MAX];

  Check_Type(val_str, T_STRING);
  TypedData_Get_Struct(self, CASelectAxis, &caselectaxis_data_type, ca);

  if ( (ca_size_t) RSTRING_LEN(val_str) != ca->bytes ) {
    rb_raise(rb_eArgError,
             "CASelectAxis#_dispatch_fill_value_debug: value string length %lld "
             "!= bytes %lld",
             (long long) RSTRING_LEN(val_str), (long long) ca->bytes);
  }
  ca_size_t pdims[CA_RANK_MAX];
  ca_select_axis_describe_axes(ca, desc, pdims);

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
Init_ca_obj_select_axis (void)
{
  rb_cCASelectAxis     = rb_define_class("CASelectAxis",     rb_cCAView);
  rb_cCASelectAxisMask = rb_define_class("CASelectAxisMask", rb_cCASelectAxis);

  ca_select_axis_func.struct_size = sizeof(CASelectAxis);
  ca_select_axis_func.pool_bytes  = ca_select_axis_pool_bytes;
  ca_select_axis_func.pool_init   = ca_select_axis_pool_init;

  CA_OBJ_SELECT_AXIS = ca_install_obj_type(rb_cCASelectAxis,
                                           &caselectaxis_data_type,
                                           rb_cCASelectAxisMask,
                                           &caselectaxis_mask_data_type,
                                           &ca_select_axis_func, sizeof(ca_select_axis_func));
  rb_define_const(rb_cObject, "CA_OBJ_SELECT_AXIS", INT2NUM(CA_OBJ_SELECT_AXIS));

  rb_define_alloc_func(rb_cCASelectAxis, rb_ca_select_axis_s_allocate);
  rb_define_method(rb_cCASelectAxis, "initialize_copy",
                                     rb_ca_select_axis_initialize_copy, 1);
  /* Debug-only ctor for testing; not part of the public API. */
  rb_define_singleton_method(rb_cCASelectAxis, "_new_debug",
                             rb_ca_select_axis_s_new_debug, 6);

#ifdef CARRAY_DEV_BUILD
  /* debug accessors (dev-only, stripped in release).
     _dispatch_attach_debug returns the raw ca_axis_dispatch_attach bytes
     as a Ruby String so tests can assert binary equality with the
     existing attach output. */
  rb_define_method(rb_cCASelectAxis, "_describe_axes",
                   rb_ca_select_axis_describe_axes, 0);
  rb_define_method(rb_cCASelectAxis, "_dispatch_attach_debug",
                   rb_ca_select_axis_dispatch_attach_debug, 0);
  rb_define_method(rb_cCASelectAxis, "_dispatch_scatter_debug",
                   rb_ca_select_axis_dispatch_scatter_debug, 1);
  rb_define_method(rb_cCASelectAxis, "_dispatch_fill_value_debug",
                   rb_ca_select_axis_dispatch_fill_value_debug, 1);
#endif

  /* Benchmark-only bypass setter on CArray class. */
  rb_define_singleton_method(rb_cCArray, "_csa_bypass=", rb_ca_s_csa_bypass_eq, 1);
  rb_define_singleton_method(rb_cCArray, "_csa_bypass?", rb_ca_s_csa_bypass_p, 0);
}
