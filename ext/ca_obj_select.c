/* ---------------------------------------------------------------------------

  CASelect view: 1-D gather of the parent through a boolean selector.
  The view snapshots the selector at construction time and pre-computes
  `indices[]` (the flat parent positions where the selector is TRUE).

  Sibling of ca_axis_dispatch.c (the per-axis descriptor engine).
  attach / sync / xfer_all / xfer_stride / fill_data all dispatch
  through `ca_axis_dispatch_*` with a single 1-D INDEX descriptor over
  a flattened parent (parent_axis_dims = {parent->elements}).  When
  the TRUE positions form a constant-step run, the descriptor is
  promoted to STRIDE kind so the engine's contig-memcpy fast path
  becomes available.

---------------------------------------------------------------------------- */

#include "carray.h"
#include "carray_internal.h"   /* per-obj_type view constructors */
#include "ca_obj_face.h"

typedef struct {
  int16_t   obj_type;
  int8_t    data_type;
  int8_t    ndim;
  int32_t   flags;
  ca_size_t   bytes;
  ca_size_t   elements;
  ca_size_t  *dim;  /* point to _dim */
  char     *ptr;
  CArray   *mask;
  char     *_pool;         /* framework-managed pool buffer (NULL = legacy ALLOC_N path). */
  CArray   *parent;
  uint32_t  attach;
  uint8_t   nosync;
  /* ---------- */
  CArray    *select;    /* snapshot of selector (boolean array, owned) */
  ca_size_t *indices;   /* snapshot of TRUE positions in flat parent
                           (length = ca->elements; engine consumes this) */
  /* Constant-step detection on indices[].  When TRUE positions form
     an arithmetic progression (consecutive TRUE block, all-TRUE,
     equally spaced), the descriptor is emitted as STRIDE kind
     instead of INDEX to unlock the engine's contig-memcpy path. */
  uint8_t    stride_kind;
  ca_size_t  stride_start;
  ca_size_t  stride_step;
  ca_size_t  _dim;
} CASelect;

static size_t
ca_select_dsize (const void *ap)
{
  /* CASelect: dim points to _dim inside struct, no separate allocation */
  return sizeof(CASelect);
}

const rb_data_type_t caselect_data_type = {
    .parent = &caview_data_type,
    .wrap_struct_name = "CASelect",
    .function = {
        .dmark = ca_mark,
        .dfree = ca_free,
        .dsize = ca_select_dsize,
        .dcompact = NULL
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

const rb_data_type_t caselect_mask_data_type = {
    .parent = &caselect_data_type,
    .wrap_struct_name = "CASelectMask",
    .function = {
        .dmark = NULL,
        .dfree = ca_free_nop,
        .dsize = ca_select_dsize,
        .dcompact = NULL
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

VALUE rb_cCASelect;
VALUE rb_cCASelectMask;


/* ------------------------------------------------------------------- */

/* Snapshot the selector into ca->select (always a copy) and pre-compute
   ca->indices (TRUE positions in flat parent order).  Masked selector
   cells become false in the snapshot.  After construction, mutating
   the caller's live selector does not affect the view. */
static int
ca_select_setup (CASelect *ca, CArray *parent, CArray *select, int share)
{
  int8_t data_type;
  ca_size_t bytes;
  ca_size_t i;

  if ( ! ca_is_boolean_type(select) ) {
    rb_raise(rb_eRuntimeError,
             "selection array for CASelect should be have "
             "the data_type of CA_BOOLEAN");
  }

  data_type = parent->data_type;
  bytes     = parent->bytes;

  ca->obj_type  = CA_OBJ_SELECT;
  ca->data_type = data_type;
  ca->flags     = 0;
  ca->ndim      = 1;
  ca->bytes     = bytes;
  ca->ptr       = NULL;
  ca->mask      = NULL;
  ca->parent    = parent;
  ca->attach    = 0;
  ca->nosync    = 0;
  ca->indices   = NULL;

  /* The `share` argument is preserved for source compatibility but
     no longer toggles a live-reference path; both paths copy.
     Masked selector cells become false in the snapshot. */
  (void) share;
  if ( ca_has_mask(select) ) {
    boolean8_t *p, *q, *m;
    ca->select = ca_template(select);
    ca_attach(select);
    q = (boolean8_t *) ca->select->ptr;
    p = (boolean8_t *) select->ptr;
    m = (boolean8_t *) select->mask->ptr;
    for (i = 0; i < select->elements; i++) {
      *q = ( *m ) ? 0 : *p;
      q++; p++; m++;
    }
    ca_detach(select);
  } else {
    ca->select = ca_copy(select);
  }

  /* Count TRUE positions and snapshot them into ca->indices. */
  {
    boolean8_t *s = (boolean8_t *) ca->select->ptr;
    ca_size_t count = 0;
    for (i = 0; i < ca->select->elements; i++) {
      if ( s[i] ) count++;
    }
    ca->elements = count;
    /* Placeholder 1-element allocation when count == 0 to avoid
       malloc(0) implementation variance; the engine treats
       elements==0 as a no-op so the contents are irrelevant. */
    ca->indices  = (ca_size_t *) xmalloc(
                     sizeof(ca_size_t) * (count > 0 ? count : 1));
    {
      ca_size_t j = 0;
      for (i = 0; i < ca->select->elements; i++) {
        if ( s[i] ) ca->indices[j++] = i;
      }
    }
    /* Constant-step detection: promotes to STRIDE descriptor kind
       when TRUE positions form an arithmetic progression. */
    ca->stride_kind  = 0;
    ca->stride_start = 0;
    ca->stride_step  = 1;
    if ( count >= 2 ) {
      ca_size_t step = ca->indices[1] - ca->indices[0];
      ca_size_t k;
      int is_const = 1;
      for ( k = 2; k < count; k++ ) {
        if ( ca->indices[k] - ca->indices[k-1] != step ) { is_const = 0; break; }
      }
      if ( is_const ) {
        ca->stride_kind  = 1;
        ca->stride_start = ca->indices[0];
        ca->stride_step  = step;
      }
    } else if ( count == 1 ) {
      ca->stride_kind  = 1;
      ca->stride_start = ca->indices[0];
      ca->stride_step  = 1;
    }
  }

  ca->dim       = &(ca->_dim);
  ca->dim[0]    = ca->elements;

  if ( ca_is_scalar(select) ) {
    ca_set_flag(ca, CA_FLAG_SCALAR);
  }

  return 0;
}

CArray *
ca_select_new (CArray *parent, CArray *select)
{
  CASelect *ca = ALLOC(CASelect);
  ca_select_setup(ca, parent, select, 0);
  return (CArray*) ca;
}

/* Alias for source compatibility.  Both constructors produce a
   snapshot view; the `share` name is retained because a handful of
   internal call sites still pass a `share` flag. */
CArray *
ca_select_new_share (CArray *parent, CArray *select)
{
  CASelect *ca = ALLOC(CASelect);
  ca_select_setup(ca, parent, select, 1);
  return (CArray*) ca;
}

static void
free_ca_select (void *ap)
{
  CASelect *ca = (CASelect *) ap;
  if ( ca != NULL ) {
    ca_free(ca->mask);
    ca_free(ca->select);   /* the snapshot is always owned */
    if ( ca->indices ) xfree(ca->indices);
    xfree(ca);
  }
}

/* ------------------------------------------------------------------- */
/* Producer for the per-axis descriptor engine: emit a single 1-D axis.
   Writes 1 entry into `out` and `out_parent_dims`.  parent_axis_dims[0]
   is the flattened parent length, so the engine treats the parent as
   1-D regardless of its original shape. */

void
ca_select_describe_axes (void *ap, ca_axis_desc_t *out,
                         ca_size_t *out_parent_dims)
{
  CASelect *ca = (CASelect *) ap;
  out_parent_dims[0] = ca->parent->elements;
  if ( ca->stride_kind ) {
    /* Constant-step run: emit STRIDE so the engine's contig-memcpy
       fast path is available (all-TRUE, block-TRUE, equally-spaced). */
    out[0].kind    = CA_AXIS_KIND_STRIDE;
    out[0].count   = ca->elements;
    out[0].start   = ca->stride_start;
    out[0].step    = ca->stride_step;
    out[0].indices = NULL;
  } else {
    out[0].kind    = CA_AXIS_KIND_INDEX;
    out[0].count   = ca->elements;
    out[0].start   = 0;
    out[0].step    = 0;
    out[0].indices = ca->indices;
  }
}

/* ------------------------------------------------------------------- */

static void *
ca_select_func_clone (void *ap)
{
  CASelect *ca = (CASelect *) ap;
  return ca_select_new_share(ca->parent, ca->select);
}

static void ca_select_func_xfer_addrs (void *ap, ca_size_t n, ca_size_t *addrs, void *data, int dir);

static void
ca_select_func_xfer_index (void *ap, ca_size_t *idx, void *data, int dir)
{
  ca_select_func_xfer_addrs(ap, 1, &idx[0], data, dir);
}

/* Translate the incoming address list through ca->indices and deliver
   to the parent in one call.

   Fast path: when `addrs` covers the whole view sequentially and the
   parent is attached, the pre-built ca->indices is handed straight to
   the descriptor engine (zero copy, no ALLOCV).  This is the same
   1-D-INDEX-over-flat-parent dispatch attach / sync use, so a chain
   like `a[idx_2d]` (which reshape/CAGrid folds down to whole-view
   sequential addrs on CASelect) also lands on the fast path. */
static void
ca_select_func_xfer_addrs (void *ap, ca_size_t n, ca_size_t *addrs,
                           void *data, int dir)
{
  CASelect  *ca = (CASelect *) ap;
  CArray    *parent = ca->parent;
  ca_size_t *paddrs;
  ca_size_t  i, base;
  volatile VALUE holder;

  if ( n == ca->elements
       && ca_xfer_addrs_is_sequential_run(n, addrs, &base) && base == 0 ) {
    CArray *eff_parent = ca_resolve_attached_root_via_identity(parent);
    if ( eff_parent->ptr ) {
      ca_axis_desc_t sub_axes[1];
      ca_size_t      parent_axis_dims[1];
      parent_axis_dims[0] = parent->elements;
      if ( ca->stride_kind ) {
        sub_axes[0].kind    = CA_AXIS_KIND_STRIDE;
        sub_axes[0].count   = ca->elements;
        sub_axes[0].start   = ca->stride_start;
        sub_axes[0].step    = ca->stride_step;
        sub_axes[0].indices = NULL;
      } else {
        sub_axes[0].kind    = CA_AXIS_KIND_INDEX;
        sub_axes[0].count   = ca->elements;
        sub_axes[0].start   = 0;
        sub_axes[0].step    = 0;
        sub_axes[0].indices = ca->indices;
      }
      if ( dir == CA_XFER_GET ) {
        ca_axis_dispatch_gather(eff_parent, parent_axis_dims, sub_axes, 1,
                                ca->bytes, ca->elements, NULL, (char *) data);
      } else {
        ca_axis_dispatch_scatter(eff_parent, parent_axis_dims, sub_axes, 1,
                                 ca->bytes, ca->elements, (char *) data);
      }
      return;
    }
  }

  /* Per-cell remap fallback (arbitrary addrs or unattached parent). */
  paddrs = ALLOCV_N(ca_size_t, holder, n);
  for ( i = 0; i < n; i++ ) {
    paddrs[i] = ca->indices[addrs[i]];
  }
  ca_xfer_addrs(ca->parent, n, paddrs, data, dir);
  ALLOCV_END(holder);
}

/* CASelect is the never-fold gather boundary: the incoming strided
   region request describes a 1-D access into the selection, which
   the view translates to a parent address list and delegates in one
   call.  `data` is contiguous (row-major over counts).

   Access into the selection is
     position = starts[0] + i * (strides[0] / bytes)
   and ca->indices[position] is the parent address.  ca->indices is a
   construction-time snapshot, so no attach is required. */
static void
ca_select_func_xfer_stride (void *ap, ca_size_t *starts, ca_size_t *counts,
                            ca_size_t *strides, void *data, int dir)
{
  CASelect  *ca = (CASelect *) ap;
  CArray    *parent = ca->parent;
  ca_size_t  n = counts[0];
  ca_size_t  step = strides[0] / ca->bytes;   /* element step (may be negative) */
  ca_size_t  start = starts[0];

  /* Attached-parent fast path: translate the sub-region request
     (start / n / step over the 1-D INDEX view) into a transient
     ca_axis_desc_t[1] and dispatch through the engine directly,
     without calling ca_attach(parent).  Collapses the per-cell
     ca_xfer_addrs loop into a single batched engine call. */
  if ( parent->ptr ) {
    ca_axis_desc_t sub_axes[1];
    ca_size_t      parent_axis_dims[1];
    ca_size_t     *index_buf = NULL;
    volatile VALUE index_holder = Qnil;

    parent_axis_dims[0] = parent->elements;  /* parent flattened */
    sub_axes[0].kind  = CA_AXIS_KIND_INDEX;
    sub_axes[0].count = n;
    sub_axes[0].start = 0;
    sub_axes[0].step  = 0;

    if ( step == 1 ) {
      /* zero-copy pointer offset into precomputed indices[] */
      sub_axes[0].indices = ca->indices + start;
    } else {
      /* sub-sampled or reversed: materialise sub-indices */
      ca_size_t i;
      index_buf = ALLOCV_N(ca_size_t, index_holder, n);
      for ( i = 0; i < n; i++ ) {
        index_buf[i] = ca->indices[start + i * step];
      }
      sub_axes[0].indices = index_buf;
    }

    if ( dir == CA_XFER_GET ) {
      ca_axis_dispatch_gather(parent, parent_axis_dims, sub_axes, 1,
                              ca->bytes, n, NULL, (char *)data);
    } else {
      ca_axis_dispatch_scatter(parent, parent_axis_dims, sub_axes, 1,
                               ca->bytes, n, (char *)data);
    }

    if ( index_buf != NULL ) ALLOCV_END(index_holder);
    return;
  }

  /* Fallback for unattached parent: per-cell ca_xfer_addrs. */
  {
    ca_size_t *paddrs;
    ca_size_t  i;
    volatile VALUE holder;
    paddrs = ALLOCV_N(ca_size_t, holder, n);
    for ( i = 0; i < n; i++ ) {
      paddrs[i] = ca->indices[start + i * step];
    }
    ca_xfer_addrs(parent, n, paddrs, data, dir);
    ALLOCV_END(holder);
  }
}

static void
ca_select_func_allocate (void *ap)
{
  CASelect *ca = (CASelect *) ap;
  ca_attach(ca->parent);
  ca->ptr = xmalloc(ca_length(ca));
}

/* Every attach / sync / xfer_all / xfer_stride / fill_data path
   dispatches through the descriptor engine with the same shape
   CASelectAxis uses: one axis over a flattened parent. */

static void
ca_select_func_attach (void *ap)
{
  CASelect *ca = (CASelect *) ap;
  ca_axis_desc_t desc[CA_RANK_MAX];
  ca_size_t      pdims[CA_RANK_MAX];
  ca_attach(ca->parent);
  ca_select_describe_axes(ca, desc, pdims);
  ca->ptr = ca_axis_dispatch_attach(ca->parent, pdims, desc, ca->ndim,
                                    ca->bytes, ca->elements, NULL);
}

static void
ca_select_func_sync (void *ap)
{
  CASelect *ca = (CASelect *) ap;
  ca_axis_desc_t desc[CA_RANK_MAX];
  ca_size_t      pdims[CA_RANK_MAX];
  ca_select_describe_axes(ca, desc, pdims);
  ca_axis_dispatch_scatter(ca->parent, pdims, desc, ca->ndim, ca->bytes,
                           ca->elements, ca->ptr);
  ca_sync(ca->parent);
}

static void
ca_select_func_detach (void *ap)
{
  CASelect *ca = (CASelect *) ap;
  xfree(ca->ptr);
  ca->ptr = NULL;
  ca_detach(ca->parent);
}

/* Fast-path core used by xfer_all's attached-parent branch and the
   cold-parent 2-pass scratch branch below. */
static void
ca_select_func_run_fast_path (CASelect *ca, char *data, int dir)
{
  ca_axis_desc_t desc[CA_RANK_MAX];
  ca_size_t      pdims[CA_RANK_MAX];
  ca_select_describe_axes(ca, desc, pdims);
  if ( dir == CA_XFER_GET ) {
    ca_axis_dispatch_gather(ca->parent, pdims, desc, ca->ndim, ca->bytes,
                            ca->elements, NULL, data);
  } else {
    ca_axis_dispatch_scatter(ca->parent, pdims, desc, ca->ndim, ca->bytes,
                             ca->elements, data);
  }
}

/* Cold parent is served by a 2-pass scratch (gather parent into a
   local buffer, dispatch through the fast path against the buffer,
   scatter back on PUT).  Deliberately avoids ca_attach(parent) so
   that a silent transitive attach cannot re-enter through here. */
static void
ca_select_func_xfer_all (void *ap, void *data, int dir)
{
  CASelect *ca = (CASelect *) ap;
  if ( ca->parent->ptr ) {
    ca_select_func_run_fast_path(ca, (char *) data, dir);
    return;
  }
  {
    volatile VALUE holder;
    CArray   *parent = ca->parent;
    ca_size_t plen   = parent->elements * parent->bytes;
    char     *parent_scratch = ALLOCV_N(char, holder, plen);
    char     *parent_ptr_saved = parent->ptr;
    ca_xfer_all(parent, parent_scratch, CA_XFER_GET);
    parent->ptr = parent_scratch;
    ca_select_func_run_fast_path(ca, (char *) data, dir);
    if ( dir == CA_XFER_PUT ) {
      ca_xfer_all(parent, parent_scratch, CA_XFER_PUT);
    }
    parent->ptr = parent_ptr_saved;
    ALLOCV_END(holder);
  }
}

static void
ca_select_func_fill_data (void *ap, void *ptr)
{
  CASelect *ca = (CASelect *) ap;
  ca_axis_desc_t desc[CA_RANK_MAX];
  ca_size_t      pdims[CA_RANK_MAX];

  /* Writing only the selected cells still went through a whole-parent
     attach and sync.  Where that attach is a gather rather than an alias,
     the unselected cells make the round trip for nothing -- and through a
     lossy transform layer they do not come back the same.  Descend per cell
     instead; the cost then follows the selection.  Kept in step with the
     CAStride form, so both spellings of a partial fill behave alike.
     (PROPOSAL_PARTIAL_FILL_WHOLE_ROOT_WRITEBACK.md sections 3.3 / 6.2) */
  if ( !ca_is_attached(ca->parent) && !ca_attach_is_alias(ca->parent) ) {
    /* indices[] are already the selected positions in the parent's flat
       space, so the selection passes down as it stands -- one hop, no
       attach, and the unselected cells are never named. */
    ca_fill_addrs(ca->parent, ca->elements, ca->indices, ptr);
    return;
  }

  ca_attach(ca->parent);
  ca_select_describe_axes(ca, desc, pdims);
  ca_axis_dispatch_fill_value(ca->parent, pdims, desc, ca->ndim, ca->bytes,
                              ca->elements, ptr);
  ca_sync(ca->parent);
  ca_detach(ca->parent);
}

static void
ca_select_func_create_mask (void *ap)
{
  CASelect *ca = (CASelect *) ap;
  ca_update_mask(ca->parent);
  if ( ! ca->parent->mask ) {
    ca_create_mask(ca->parent);
  }
  ca->mask = (CArray *) ca_select_new_share(ca->parent->mask, ca->select);
}

ca_operation_function_t ca_select_func = {
  CA_OBJ_SELECT,
  CA_VIEW_ARRAY,
  free_ca_select,
  ca_select_func_clone,
  ca_select_func_allocate,
  ca_select_func_attach,
  ca_select_func_sync,
  ca_select_func_detach,
  ca_select_func_fill_data,
  ca_select_func_create_mask,
  ca_select_func_xfer_index,
  ca_select_func_xfer_addrs,
  NULL,                       /* fold_stride: never fold — gather boundary */
  ca_select_func_xfer_stride,
  ca_select_func_xfer_all,
};

/* ------------------------------------------------------------------- */

VALUE
rb_ca_select_new (VALUE cary, VALUE select)
{
  volatile VALUE obj;
  CArray *parent, *cselect;
  CASelect *ca;
  rb_check_carray_object(cary);
  rb_check_carray_object(select);
  TypedData_Get_Struct(cary, CArray, &carray_data_type, parent);
  TypedData_Get_Struct(select, CArray, &carray_data_type, cselect);
  ca = (CASelect *) ca_select_new(parent, cselect);
  if ( ! ca ) {
    return Qnil;
  }
  obj = ca_wrap_struct(ca);
  rb_ca_set_parent(obj, cary);
  CA_FACE_LIFT_IF_FACE(obj, cary, parent);
  return obj;
}

VALUE
rb_ca_select_new_share (VALUE cary, VALUE select)
{
  /* Alias of the snapshot constructor.  The `referred_index` ivar is
     set so consumers that expect the original selector to be
     reachable from the view object continue to find it. */
  volatile VALUE obj;
  CArray *parent, *cselect;
  CASelect *ca;
  rb_check_carray_object(cary);
  rb_check_carray_object(select);
  TypedData_Get_Struct(cary, CArray, &carray_data_type, parent);
  TypedData_Get_Struct(select, CArray, &carray_data_type, cselect);
  ca = (CASelect *) ca_select_new_share(parent, cselect);
  if ( ! ca ) {
    return Qnil;
  }
  obj = ca_wrap_struct(ca);
  rb_ca_set_parent(obj, cary);
  rb_ivar_set(obj, rb_intern("referred_index"), select);
  return obj;
}

/* -------------------------------------------------------------------- */

static VALUE
rb_cm_s_allocate (VALUE klass)
{
  CASelect *ca;
  return TypedData_Make_Struct(klass, CASelect, &caselect_data_type, ca);
}

static VALUE
rb_cm_initialize_copy (VALUE self, VALUE other)
{
  CASelect *ca, *cs;

  TypedData_Get_Struct(self,  CASelect, &caselect_data_type, ca);
  TypedData_Get_Struct(other, CASelect, &caselect_data_type, cs);

  /* Re-snapshot from the source's selector copy so the two views
     end up with independent indices buffers. */
  ca_select_setup(ca, cs->parent, cs->select, 1);

  return self;
}

void
Init_ca_obj_select (void)
{
  /* rb_cCASelect and CA_OBJ_SELECT are defined in ruby_carray.c;
     this file only registers the constant + allocator. */
  rb_define_const(rb_cObject, "CA_OBJ_SELECT", INT2NUM(CA_OBJ_SELECT));

  rb_define_alloc_func(rb_cCASelect, rb_cm_s_allocate);
  rb_define_method(rb_cCASelect, "initialize_copy", rb_cm_initialize_copy, 1);
}
