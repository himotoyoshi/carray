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
#include "carray_internal.h"   /* ca_attach_window */

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
  /* INDEX-only, NULL when no cell is a hole.  holes[i] marks a position
     whose index cell was masked: it selects no parent cell.  Its entry in
     indices is 0 and is never range-checked.  Owned and aliased as
     indices is. */
  uint8_t         *holes;
} cag_axis_t;

typedef struct _CAGrid {
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
  /* A grid with holes (cag_axis_t.holes): set on its mask grid, whose
     holes read as masked.  The data grid's holes read the cell at index 0
     of each holed axis, as project and gather_nd do. */
  int8_t       holes_read_masked;
  /* A grid with holes over a parent that has no mask: the all-false mask
     its mask grid reads instead, so that showing the holes gives the
     parent no mask.  Owned by this grid; NULL otherwise. */
  CArray      *mask_standin;
  /* On a mask grid: the grid whose mask it is, which holds the stand-in
     and the parent whose mask replaces it.  A Ruby copy of the mask keeps
     that grid alive (rb_ca_mask_array sets masked_array). */
  struct _CAGrid *mask_owner;
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
    if (ca->axes[k].kind == CAG_AXIS_INDEX && ca->axes[k].holes) {
      total += ca->axes[k].count;
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

/* Raises when protos cannot describe a view of parent: an ndim that is
   not parent's, a negative count, a byte length over the limit, or a
   parent index out of range.  Nothing is allocated here, so the caller
   runs it before taking memory. */
static void
ca_grid_check_protos (CArray *parent, int8_t ndim, const cag_axis_t *protos)
{
  int8_t k;
  ca_size_t j;
  double length;

  /* rb_ca_grid pads with nil when fewer args are given, so ndim ==
     parent->ndim for every in-tree caller. */
  if ( ndim != parent->ndim ) {
    rb_raise(rb_eArgError,
             "CAGrid: ndim mismatch (%d args vs parent->ndim %d)",
             (int) ndim, (int) parent->ndim);
  }

  length = parent->bytes;
  for (k = 0; k < ndim; k++) {
    if (protos[k].count < 0) {
      rb_raise(rb_eArgError, "negative size for %d-th dimension", k);
    }
    length *= protos[k].count;
  }
  if (length > CA_LENGTH_MAX) {
    rb_raise(rb_eArgError, "too large byte length");
  }

  for (k = 0; k < ndim; k++) {
    if ( protos[k].count <= 0 ) {
      continue;
    }
    if (protos[k].kind == CAG_AXIS_STRIDE) {
      ca_size_t first = protos[k].start;
      ca_size_t last  = first + (protos[k].count - 1) * protos[k].step;
      ca_index_in_range_at(first, parent->dim[k], k);
      if (protos[k].count > 1) ca_index_in_range_at(last, parent->dim[k], k);
    }
    else {
      for (j = 0; j < protos[k].count; j++) {
        if ( protos[k].holes && protos[k].holes[j] ) {
          continue;
        }
        ca_index_in_range_at(protos[k].indices[j], parent->dim[k], k);
      }
    }
  }
}

/* Setup: caller passes ndim + per-axis protos (cag_axis_t) that
   ca_grid_check_protos has accepted.  Copies the fields and, for INDEX
   axes, snapshots the indices into an owned buffer.  The share path
   (share=1, used only by create_mask) aliases the caller's protos buffer
   instead: the mask grid is owned and freed by the grid whose axes it
   aliases (free_ca_grid skips the xfree under CA_FLAG_SHARE_INDEX). */
static int
ca_grid_setup (CAGrid *ca, CArray *parent, int8_t ndim,
               cag_axis_t *protos, int share)
{
  int8_t k;
  ca_size_t elements;

  CA_ASSUME(ndim >= 0 && ndim <= CA_RANK_MAX);   /* bound loops/allocs over [CA_RANK_MAX] arrays */

  {
    ca_size_t counts[CA_RANK_MAX];
    for (k = 0; k < ndim; k++) counts[k] = protos[k].count;
    elements = ca_shape_elements(ndim, counts, parent->bytes);
  }

  ca->obj_type  = CA_OBJ_GRID;
  ca->data_type = parent->data_type;
  ca->flags     = 0;
  ca->ndim      = ndim;
  ca->bytes     = parent->bytes;
  ca->elements  = elements;
  ca->ptr       = NULL;
  ca->mask      = NULL;
  if ( ! ca->_pool ) {
    ca->dim     = ALLOC_N(ca_size_t, ndim);
  }
  ca->parent    = parent;
  ca->attach    = 0;
  ca->nosync    = 0;
  ca->holes_read_masked = 0;
  ca->mask_standin      = NULL;
  ca->mask_owner        = NULL;

  for (k = 0; k < ndim; k++) ca->dim[k] = protos[k].count;

  if ( share ) {
    /* Alias the protos buffer; lifetime tied to the source CAGrid
       (initialize_copy and create_mask call sites).  free_ca_grid
       skips the axes / indices xfree under SHARE_INDEX. */
    ca_set_flag(ca, CA_FLAG_SHARE_INDEX);
    ca->axes = protos;
  } else {
    /* Zeroed: an axis's indices or holes that cannot be allocated raises
       with the later axes not yet copied, and free_ca_grid reads them. */
    ca->axes = ZALLOC_N(cag_axis_t, ndim);
    for (k = 0; k < ndim; k++) {
      ca->axes[k].kind  = protos[k].kind;
      ca->axes[k].count = protos[k].count;
      if (protos[k].kind == CAG_AXIS_STRIDE) {
        ca->axes[k].start   = protos[k].start;
        ca->axes[k].step    = protos[k].step;
        ca->axes[k].indices = NULL;
        ca->axes[k].holes   = NULL;
      } else {
        ca->axes[k].start   = 0;
        ca->axes[k].step    = 0;
        ca->axes[k].indices = ALLOC_N(ca_size_t,
                                      protos[k].count > 0 ? protos[k].count : 1);
        ca->axes[k].holes   = NULL;
        ca_size_t j;
        if ( protos[k].holes ) {
          for (j = 0; j < protos[k].count && ! protos[k].holes[j]; j++) ;
          if ( j < protos[k].count ) {
            ca->axes[k].holes = ALLOC_N(uint8_t, protos[k].count);
            memcpy(ca->axes[k].holes, protos[k].holes, protos[k].count);
          }
        }
        for (j = 0; j < protos[k].count; j++) {
          ca_size_t v = protos[k].indices[j];
          if ( ca->axes[k].holes && ca->axes[k].holes[j] ) {
            ca->axes[k].indices[j] = 0;
            continue;
          }
          ca->axes[k].indices[j] = ( v < 0 ) ? v + parent->dim[k] : v;
        }
      }
    }
  }

  return 0;
}

/* Whether any position of the grid is a hole (cag_axis_t.holes). */
static int
cag_has_holes (const CAGrid *ca)
{
  int8_t k;
  for (k = 0; k < ca->ndim; k++) {
    if ( ca->axes[k].kind == CAG_AXIS_INDEX && ca->axes[k].holes ) {
      return 1;
    }
  }
  return 0;
}

int
ca_grid_has_holes (void *ap)
{
  return cag_has_holes((const CAGrid *) ap);
}

/* A grid with holes has a mask from the start: its holes read as masked
   whatever the parent holds.  A mask grid (holes_read_masked) takes none.
   A view of a value array or a mask array can never carry a mask, so it
   can not show a hole. */
static VALUE
ca_grid_inherit_mask (VALUE view)
{
  CAGrid *ca = (CAGrid *) view;
  if ( cag_has_holes(ca) && ! ca->holes_read_masked ) {
    if ( ca_is_value_array(ca) || ca_is_mask_array(ca) ) {
      rb_raise(rb_eArgError,
               "a masked index cell reads as masked, which a view of the %s "
               "array can not hold", ca_is_value_array(ca) ? "value" : "mask");
    }
    ca_create_mask((CArray *) ca);
    return Qnil;
  }
  return ca_view_inherit_mask(view);
}

typedef struct {
  CAGrid     *ca;
  CArray     *parent;
  int8_t      ndim;
  cag_axis_t *protos;
} ca_grid_new_arg;

static VALUE
ca_grid_new_setup (VALUE varg)
{
  ca_grid_new_arg *a = (ca_grid_new_arg *) varg;
  ca_grid_setup(a->ca, a->parent, a->ndim, a->protos, 0);
  return Qnil;
}

/* holes_read_masked is the copied grid's: a copy of a mask grid is one.
   The setup allocates the axes after the struct and its pool: when that
   fails, the struct goes too. */
static CAGrid *
ca_grid_new_as (CArray *parent, int8_t ndim, cag_axis_t *protos,
                int8_t holes_read_masked, CAGrid *mask_owner)
{
  CAGrid *ca;
  ca_grid_new_arg a;
  ca_grid_check_protos(parent, ndim, protos);
  /* check: ca_grid_check_protos above */
  ca = (CAGrid *) ca_array_alloc(CA_OBJ_GRID, ndim);
  a.ca     = ca;
  a.parent = parent;
  a.ndim   = ndim;
  a.protos = protos;
  ca_fill_or_free((CArray *) ca, ca_grid_new_setup, (VALUE) &a);
  ca->holes_read_masked = holes_read_masked;
  ca->mask_owner        = mask_owner;
  ca_fill_or_free((CArray *) ca, ca_grid_inherit_mask, (VALUE) ca);
  return ca;
}

CAGrid *
ca_grid_new (CArray *parent, int8_t ndim, cag_axis_t *protos)
{
  return ca_grid_new_as(parent, ndim, protos, 0, NULL);
}

CAGrid *
ca_grid_new_share (CArray *parent, int8_t ndim, cag_axis_t *protos)
{
  /* check: the mask grid copies its own grid's checked axes */
  CAGrid *ca = (CAGrid *) ca_array_alloc(CA_OBJ_GRID, ndim);
  ca_grid_setup(ca, parent, ndim, protos, 1);
  ca_fill_or_free((CArray *) ca, ca_view_inherit_mask, (VALUE) ca);
  return ca;
}

static void
free_ca_grid (void *ap)
{
  CAGrid *ca = (CAGrid *) ap;
  if ( ca != NULL ) {
    ca_free(ca->mask);
    ca_free(ca->mask_standin);
    if ( ! (ca->flags & CA_FLAG_SHARE_INDEX) && ca->axes ) {
      int8_t k;
      for (k = 0; k < ca->ndim; k++) {
        if ( ca->axes[k].kind == CAG_AXIS_INDEX && ca->axes[k].indices ) {
          xfree(ca->axes[k].indices);
        }
        if ( ca->axes[k].kind == CAG_AXIS_INDEX && ca->axes[k].holes ) {
          xfree(ca->axes[k].holes);
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
  return ca_grid_new_as(ca->parent, ca->ndim, ca->axes, ca->holes_read_masked,
                        ca->mask_owner);
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

/* A mask grid over its owner's stand-in (ca_mask_standin_current): what
   it reads from now on. */
static void
cag_mask_current (CAGrid *m)
{
  CAGrid *o = m->mask_owner;
  if ( o != NULL ) {
    m->parent = ca_mask_standin_current((CArray *) m, m->parent, o->parent,
                                        o->mask_standin);
  }
}

/* After a write of n cells of `data` to a mask grid: a true that went
   into the stand-in goes on to the parent's mask. */
static void
cag_mask_settle_after (CAGrid *m, const void *data, ca_size_t n)
{
  CAGrid *o = m->mask_owner;
  if ( o != NULL && m->parent == o->mask_standin && ca_mask_any_true(data, n) ) {
    ca_mask_standin_settle(o->parent, o->mask_standin);
  }
}

/* What the GET of a hole writes when it reads no parent cell: true in a
   mask grid, an empty cell otherwise (a parent with no cell to read). */
static void
cag_hole_cells (const CAGrid *ca, char *data, ca_size_t n)
{
  ca_size_t i;
  if ( ca->holes_read_masked ) {
    memset(data, 1, (size_t) n);
  }
  else if ( ca->data_type == CA_OBJECT ) {
    for (i = 0; i < n; i++) ((VALUE *) data)[i] = INT2FIX(0);
  }
  else {
    memset(data, 0, (size_t) (n * ca->bytes));
  }
}

/* The parent address of the view cell at idx.  A hole takes index 0 on its
   holed axes; the return says whether the cell is one. */
static int
cag_parent_addr (const CAGrid *ca, const ca_size_t *idx, ca_size_t *paddr)
{
  ca_size_t pa = 0;
  int hole = 0;
  int8_t k;
  for (k = 0; k < ca->ndim; k++) {
    const cag_axis_t *ax = &ca->axes[k];
    if ( ax->kind == CAG_AXIS_INDEX && ax->holes && ax->holes[idx[k]] ) {
      hole = 1;
    }
    pa = pa * ca->parent->dim[k] + cag_parent_index_for(ax, idx[k]);
  }
  *paddr = pa;
  return hole;
}

/* The parent addresses (paddrs, may be NULL) and the hole marks of every
   view cell in address order: a walk over the outer axes with the
   innermost axis a run, its indices and holes read off the axis.  A 1-D
   index axis is its own index and hole arrays. */
static void
cag_parent_addrs_whole (const CAGrid *ca, ca_size_t *paddrs, uint8_t *hole)
{
  int8_t            ndim  = ca->ndim;
  int8_t            inner = ndim - 1;
  const cag_axis_t *last  = &ca->axes[inner];
  ca_size_t         count = last->count;
  ca_size_t         pdim  = ca->parent->dim[inner];
  ca_size_t         idx[CA_RANK_MAX];
  ca_size_t         i = 0, j;
  int8_t            k;

  if ( ndim == 1 && last->kind == CAG_AXIS_INDEX ) {
    if ( paddrs ) {
      memcpy(paddrs, last->indices, (size_t) count * sizeof(ca_size_t));
    }
    if ( last->holes ) {
      memcpy(hole, last->holes, (size_t) count);
    }
    else {
      memset(hole, 0, (size_t) count);
    }
    return;
  }
  if ( count == 0 || ca->elements == 0 ) {
    return;
  }
  for (k = 0; k < ndim; k++) {
    idx[k] = 0;
  }
  /* empty: returned above when the view has no cell */
  while ( 1 ) {
    ca_size_t base = 0;
    uint8_t   outer_hole = 0;
    for (k = 0; k < inner; k++) {
      const cag_axis_t *ax = &ca->axes[k];
      if ( ax->kind == CAG_AXIS_INDEX && ax->holes && ax->holes[idx[k]] ) {
        outer_hole = 1;
      }
      base = base * ca->parent->dim[k] + cag_parent_index_for(ax, idx[k]);
    }
    base *= pdim;
    if ( last->kind == CAG_AXIS_INDEX ) {
      const ca_size_t *ix = last->indices;
      const uint8_t   *hx = last->holes;
      for (j = 0; j < count; j++) {
        if ( paddrs ) {
          paddrs[i + j] = base + ix[j];
        }
        hole[i + j] = (uint8_t) (outer_hole | (hx ? hx[j] : 0));
      }
    }
    else {
      for (j = 0; j < count; j++) {
        if ( paddrs ) {
          paddrs[i + j] = base + last->start + j * last->step;
        }
        hole[i + j] = outer_hole;
      }
    }
    i += count;
    for (k = inner - 1; k >= 0; k--) {
      if ( ++idx[k] < ca->dim[k] ) break;
      idx[k] = 0;
    }
    if ( k < 0 ) break;
  }
}

/* The transfer of a grid with holes, for the view cells at addrs (NULL:
   the whole view in order, walked axis by axis).  The parent is asked
   for one batch of addresses.  A GET reads every cell, a hole reading the
   cell at index 0 of its holed axes (in a mask grid it is then set true); a
   PUT leaves the holes out.  A mask grid reading its owner's stand-in reads
   nothing: the stand-in is all false at rest (a write to it is settled
   into the parent's mask at once), so the holes are the whole answer. */
static void
ca_grid_holed_xfer (CAGrid *ca, ca_size_t n, const ca_size_t *addrs,
                    char *data, int dir)
{
  CArray        *parent;
  ca_size_t      bytes  = ca->bytes;
  volatile VALUE h_addr = 0, h_hole = 0, h_data = 0;
  ca_size_t     *paddrs;
  uint8_t       *hole;
  ca_size_t      i, m, idx[CA_RANK_MAX];

  if ( n <= 0 ) {
    return;
  }
  cag_mask_current(ca);
  parent = ca->parent;

  if ( dir == CA_XFER_GET && ca->holes_read_masked && ca->mask_owner != NULL
       && parent == ca->mask_owner->mask_standin ) {
    if ( ! addrs ) {
      cag_parent_addrs_whole(ca, NULL, (uint8_t *) data);
    }
    else {
      for (i = 0; i < n; i++) {
        ca_addr2index((CArray *) ca, addrs[i], idx);
        ((boolean8_t *) data)[i] = (boolean8_t) cag_parent_addr(ca, idx, &m);
      }
    }
    return;
  }

  if ( dir == CA_XFER_GET && ! addrs && ca->ndim == 1
       && ( parent->obj_type == CA_OBJ_ARRAY || parent->obj_type == CA_OBJ_ARRAY_WRAP
            || parent->obj_type == CA_OBJ_SCALAR ) ) {
    /* A 1-D grid read whole from an array of its own: its index axis's
       index and hole arrays are the batch as they are.  Another parent's
       transfer (a view, a CAObject's hook) takes a copy it may write on,
       as a PUT does, which compacts the batch. */
    paddrs = ca->axes[0].indices;
    hole   = ca->axes[0].holes;
  }
  else {
    paddrs = ALLOCV_N(ca_size_t, h_addr, n);
    hole   = ALLOCV_N(uint8_t, h_hole, n);
    if ( ! addrs ) {
      cag_parent_addrs_whole(ca, paddrs, hole);
    }
    else {
      for (i = 0; i < n; i++) {
        ca_addr2index((CArray *) ca, addrs[i], idx);
        hole[i] = (uint8_t) cag_parent_addr(ca, idx, &paddrs[i]);
      }
    }
  }

  if ( dir == CA_XFER_GET ) {
    if ( parent->elements == 0 ) {
      cag_hole_cells(ca, data, n);   /* every cell is a hole */
    }
    else {
      ca_xfer_addrs(parent, n, paddrs, data, CA_XFER_GET);
      if ( ca->holes_read_masked ) {
        for (i = 0; i < n; i++) {
          if ( hole[i] ) cag_hole_cells(ca, data + i * bytes, 1);
        }
      }
    }
  }
  else {
    char *pdata = ALLOCV_N(char, h_data, n * bytes);
    for (i = 0, m = 0; i < n; i++) {
      if ( hole[i] ) continue;
      paddrs[m] = paddrs[i];
      memcpy(pdata + m * bytes, data + i * bytes, (size_t) bytes);
      m++;
    }
    if ( m > 0 ) {
      ca_xfer_addrs(parent, m, paddrs, pdata, CA_XFER_PUT);
      cag_mask_settle_after(ca, pdata, m);
    }
    ALLOCV_END(h_data);
  }
  ALLOCV_END(h_hole);
  ALLOCV_END(h_addr);
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
  int hole = 0;
  for (i = 0; i < ca->ndim; i++) {
    const cag_axis_t *ax = &ca->axes[i];
    idx0[i] = cag_parent_index_for(ax, idx[i]);
    if ( ax->kind == CAG_AXIS_INDEX && ax->holes && ax->holes[idx[i]] ) {
      hole = 1;
    }
  }
  if ( hole ) {
    if ( dir == CA_XFER_PUT ) {
      return;
    }
    if ( ca->holes_read_masked || ca->parent->elements == 0 ) {
      cag_hole_cells(ca, (char *) data, 1);
      return;
    }
  }
  cag_mask_current(ca);
  ca_xfer_index(ca->parent, idx0, data, dir);
  if ( dir == CA_XFER_PUT ) {
    cag_mask_settle_after(ca, data, 1);
  }
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

  if ( cag_has_holes(ca) ) {
    ca_grid_holed_xfer(ca, n, addrs, (char *) data, dir);
    return;
  }

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
    if (g->axes[k].kind == CAG_AXIS_INDEX
        && (g->axes[k].count != 1 || g->axes[k].holes)) {
      return 0;   /* multi-INDEX axis -> true gather, decline; a hole is no stride */
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

/* A region of a grid with holes: its view addresses as one batch to the
   holed transfer, or none when the region is the whole view in order. */
static void
cag_holed_xfer_stride (CAGrid *g, const ca_size_t *starts, const ca_size_t *counts,
                       const ca_size_t *strides, char *data, int dir)
{
  int8_t         ndim = g->ndim;
  ca_size_t      gnative[CA_RANK_MAX], idx[CA_RANK_MAX];
  ca_size_t      n = 1, i, s, base = 0;
  ca_size_t     *addrs;
  volatile VALUE holder = 0;
  int            whole = 1;
  int8_t         k;

  s = g->bytes;
  for (k = ndim - 1; k >= 0; k--) { gnative[k] = s; s *= g->dim[k]; }
  for (k = 0; k < ndim; k++) {
    n    *= counts[k];
    base += starts[k] * gnative[k];
    if ( starts[k] != 0 || counts[k] != g->dim[k] || strides[k] != gnative[k] ) {
      whole = 0;
    }
    idx[k] = 0;
  }
  if ( whole ) {
    ca_grid_holed_xfer(g, n, NULL, data, dir);
    return;
  }
  addrs = ALLOCV_N(ca_size_t, holder, n);
  for (i = 0; i < n; i++) {
    ca_size_t goff = base;
    for (k = 0; k < ndim; k++) {
      goff += idx[k] * strides[k];
    }
    addrs[i] = goff / g->bytes;
    for (k = ndim - 1; k >= 0; k--) {
      if ( ++idx[k] < counts[k] ) break;
      idx[k] = 0;
    }
  }
  ca_grid_holed_xfer(g, n, addrs, data, dir);
  ALLOCV_END(holder);
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
  if ( ca_region_is_empty(((CArray *) ap)->ndim, counts) ) return;
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
  /* The request is over the view's addresses, so a transposed / flat request
     is legal and must not be composed axis-by-axis; see
     ca_xfer_stride_request_is_axis_box (carray.h). */
  if ( cag_has_holes(g) ) {
    cag_holed_xfer_stride(g, starts, counts, strides, d, dir);
    return;
  }
  if ( ! ca_xfer_stride_request_is_axis_box(g, starts, counts, strides) ) {
    aligned = 0;
  }
  else {
    for (k = 0; k < ndim; k++) {
      if (strides[k] % gnative[k] != 0) { aligned = 0; break; }
      src_step[k] = strides[k] / gnative[k];
    }
  }

  if (!aligned) {
    ca_size_t idx[CA_RANK_MAX], doff = 0, base = 0;
    for (k = 0; k < ndim; k++) base += starts[k] * gnative[k];
    for (k = 0; k < ndim; k++) idx[k] = 0;
    /* empty: the slot returns on an empty region at its entry */
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

  /* empty: the slot returns on an empty region at its entry */
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

/* attach / sync / copy_data / sync_data / fill_data all go through the
   descriptor engine (ca_axis_dispatch.c).  This file supplies only
   describe_axes; the engine does the rest.

   A parent with no memory to lend (ca_parent_lends_no_memory) is never
   attached: attaching it would produce all of its cells to serve the few
   this grid selects.  The grid then owns its buffer, filled and drained
   through xfer_all, which asks the parent for the selected cells only.
   The predicate asks what the parent is, not whether it is attached now,
   so attach, sync and detach all take the same branch. */

/* A grid with holes fills and writes back its buffer through its own
   transfers too: the descriptor engine has no hole. */
static int
cag_owns_buffer (CAGrid *ca)
{
  return cag_has_holes(ca) || ca_parent_lends_no_memory(ca->parent);
}

static void
ca_grid_func_allocate (void *ap)
{
  CAGrid *ca = (CAGrid *) ap;
  if ( ! cag_owns_buffer(ca) ) {
    ca_attach(ca->parent);
  }
  ca->ptr = ca_alloc_cells((CArray *) ca);
}

static void
ca_grid_func_attach (void *ap)
{
  CAGrid *ca = (CAGrid *) ap;
  ca_axis_desc_t desc[CA_RANK_MAX];
  ca_size_t      pdims[CA_RANK_MAX];

  if ( cag_owns_buffer(ca) ) {
    ca_axis_view_attach_owned(ca);
    return;
  }

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

  if ( cag_owns_buffer(ca) ) {
    ca_axis_view_sync_owned(ca);
    return;
  }

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
  if ( ! cag_owns_buffer(ca) ) {
    ca_detach(ca->parent);
  }
}

/* The transfer against parent->ptr, for ca_axis_view_xfer_all. */
static void
ca_grid_func_run_fast_path (void *ap, char *data, int dir)
{
  CAGrid *ca = (CAGrid *) ap;
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
  if ( cag_has_holes(ca) ) {
    ca_grid_holed_xfer(ca, ca->elements, NULL, (char *) data, dir);
    return;
  }
  ca_axis_view_xfer_all(ap, ca_grid_func_run_fast_path, 1, data, dir);
}

/* The fill of a grid with holes: the parent cells of the positions that
   are not holes, as one address batch. */
static void
ca_grid_holed_fill (CAGrid *ca, void *ptr)
{
  volatile VALUE holder = 0;
  ca_size_t *paddrs;
  ca_size_t  i, m = 0, pa, idx[CA_RANK_MAX];

  if ( ca->elements <= 0 ) {
    return;
  }
  cag_mask_current(ca);
  paddrs = ALLOCV_N(ca_size_t, holder, ca->elements);
  for (i = 0; i < ca->elements; i++) {
    ca_addr2index((CArray *) ca, i, idx);
    if ( ! cag_parent_addr(ca, idx, &pa) ) {
      paddrs[m++] = pa;
    }
  }
  if ( m > 0 ) {
    ca_fill_addrs(ca->parent, m, paddrs, ptr);
    cag_mask_settle_after(ca, ptr, 1);
  }
  ALLOCV_END(holder);
}

static void
ca_grid_func_fill_data (void *ap, void *ptr)
{
  CAGrid *ca = (CAGrid *) ap;
  ca_axis_desc_t desc[CA_RANK_MAX];
  ca_size_t      pdims[CA_RANK_MAX];

  if ( cag_has_holes(ca) ) {
    ca_grid_holed_fill(ca, ptr);
    return;
  }

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

  ca_attach(ca->parent);   /* window: nothing raises inside */
  ca_axis_dispatch_fill_value(ca->parent, pdims, desc, ca->ndim, ca->bytes,
                              ca->elements, ptr);
  ca_sync_detach(ca->parent);
}

/* The mask is a grid over the parent's mask with the same axes, holes
   included; there the holes read as masked. */
static void
ca_grid_func_create_mask (void *ap)
{
  CAGrid *ca = (CAGrid *) ap;
  CArray *mparent;
  int     holed = cag_has_holes(ca);

  /* A grid with holes shows them without giving a parent that has no mask
     one: its mask grid reads an all-false stand-in until a true is written
     outside the holes (ca_mask_standin_new). */
  if ( holed && ! ca_has_mask(ca->parent) ) {
    if ( ! ca->mask_standin ) {
      ca->mask_standin = ca_mask_standin_new(ca->parent);
    }
    mparent = ca->mask_standin;
  }
  else {
    ca_create_mask(ca->parent);
    mparent = ca->parent->mask;
  }

  ca->mask = (CArray *) ca_grid_new_share(mparent, ca->ndim, ca->axes);
  ((CAGrid *) ca->mask)->holes_read_masked = (int8_t) holed;
  ((CAGrid *) ca->mask)->mask_owner = holed ? ca : NULL;
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

/* The INDEX axes of rb_ca_grid, read with their index arrays attached,
   and the view built from them. */

typedef struct {
  VALUE        self;
  CArray      *ca;
  CArray     **ci;
  cag_axis_t  *protos;
} ca_grid_build_ctx_t;

static VALUE
ca_grid_build_body (VALUE arg)
{
  ca_grid_build_ctx_t *c = (ca_grid_build_ctx_t *) arg;
  int8_t i;

  for (i = 0; i < c->ca->ndim; i++) {
    CArray *ci = c->ci[i];
    if ( ! ci ) {
      continue;
    }
    c->protos[i].kind    = CAG_AXIS_INDEX;
    c->protos[i].count   = ci->elements;
    c->protos[i].indices = (ca_size_t *) ci->ptr;
    c->protos[i].holes   = NULL;
    if ( ca_is_any_masked(ci) ) {
      /* A masked index cell selects nothing: its position stays, as a hole
         (masked on read, skipped on write).  setup copies the mask into
         its own buffer. */
      c->protos[i].holes = (uint8_t *) ci->mask->ptr;
    }
    c->protos[i].start = 0;
    c->protos[i].step  = 0;
  }

  return rb_ca_grid_new(c->self, c->ca->ndim, c->protos);
}

/* A scalar key (an Integer or a Float) picks one cell along its axis, and that axis is
   not in the result -- as it is not in a block reference.  The view is
   built with the axis at length 1 and the axis then dropped. */
static VALUE
ca_grid_drop_scalar_axes (VALUE obj, int argc, VALUE *argv)
{
  VALUE idx[CA_RANK_MAX];
  int i, any = 0;
  for (i = 0; i < argc; i++) {
    if ( ca_index_key_is_scalar(argv[i]) ) {
      idx[i] = INT2FIX(0);
      any = 1;
    }
    else {
      idx[i] = Qnil;
    }
  }
  if ( ! any ) {
    return obj;
  }
  return rb_ca_fetch2(obj, argc, idx);
}

/* ca[k0, k1, ...] with a CArray among the keys.  An integer CArray picks
   the cells it lists along its axis, a boolean one the cells it marks (it
   must be as long as the axis).  Every other key is read as the indexer
   reads it (ca_index_axis_key): an Integer picks one cell and drops the
   axis, a Range / ArithmeticSequence / Array form a run, nil the axis. */
VALUE
rb_ca_grid (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE obj, rval;
  volatile VALUE list = rb_ary_new();
  CArray *ca;
  CArray *ci[CA_RANK_MAX];          /* CAWrap holders for INDEX axes; NULL for STRIDE */
  cag_axis_t protos[CA_RANK_MAX];
  VALUE expanded[CA_RANK_MAX];
  long n;
  ca_size_t i;

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  n = ca_index_expand_rubber(ca->ndim, argc, argv, expanded);
  if ( n >= 0 ) {
    argc = (int) n;
    argv = expanded;
  }

  if ( argc > ca->ndim ) {
    rb_raise(rb_eArgError, "# of arguments doesn't equal to the ndim");
  }
  else if ( argc < ca->ndim ) {
    volatile VALUE ref;
    CArray *cv;
    ca_size_t rdim[CA_RANK_MAX];
    ca_size_t rndim = argc;
    ca_size_t j = 0, k;
    for (i=0; i<rndim; i++) {
      rval = argv[i];
      if ( rb_obj_is_carray(rval) ) {
        TypedData_Get_Struct(rval, CArray, &carray_data_type, cv);
        rdim[i] = 1;
        for (k=0; k<cv->ndim; k++) {
          if ( j >= ca->ndim ) {
            rb_raise(rb_eArgError, "invalid total ndim of args");
          }
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
    /* An index array that spans several axes picks along the one axis
       they are joined into, so it is read flat there. */
    {
      VALUE flat[CA_RANK_MAX];
      for (i=0; i<rndim; i++) {
        flat[i] = rb_obj_is_carray(argv[i]) ? rb_ca_flatten(argv[i]) : argv[i];
      }
      return rb_ca_grid(argc, flat, ref);
    }
  }

  /* Dispatch hook: route a boolean on axis 0 with plain keys elsewhere to
     CASelectAxis (slab-copy optimised path).  Falls through to CAGrid when
     not eligible.  The inline argv[0] type check avoids the call when axis
     0 is nil / Integer (most patterns with the CArray on an inner axis). */
  extern int ca_csa_dispatch_bypass;
  if ( ! ca_csa_dispatch_bypass && argc > 0 && TYPE(argv[0]) == T_DATA ) {
    if ( rb_ca_select_axis_eligible_p(argc, argv, self) ) {
      return ca_grid_drop_scalar_axes(rb_ca_select_axis(argc, argv, self),
                                      argc, argv);
    }
  }

  for (i = 0; i < ca->ndim; i++) {
    ca_size_t dim_size = ca->dim[i];
    rval = argv[i];
    ci[i] = NULL;
    if ( ! rb_obj_is_carray(rval) ) {
      ca_size_t start, count, step;
      ca_index_axis_key(rval, dim_size, (int) i, &start, &count, &step);
      protos[i].kind    = CAG_AXIS_STRIDE;
      protos[i].count   = count;
      protos[i].start   = start;
      protos[i].step    = step;
      protos[i].indices = NULL;
      protos[i].holes   = NULL;
      continue;
    }
    {
      /* An index array picks cells along its one axis.  One of more axes
         states a shape the axis does not have. */
      CArray *cs;
      TypedData_Get_Struct(rval, CArray, &carray_data_type, cs);
      if ( cs->ndim > 1 ) {
        volatile VALUE sshape = rb_ary_new();
        int k;
        for (k = 0; k < cs->ndim; k++) rb_ary_push(sshape, SIZE2NUM(cs->dim[k]));
        rb_raise(rb_eArgError,
                 "%s: index array of shape %"PRIsVALUE" on axis %d (an index "
                 "array picks along one axis; use .flatten)",
                 ca_calling_method_name(), sshape, (int) i);
      }
    }
    if ( rb_ca_is_boolean_type(rval) ) {
      CArray *cb;
      TypedData_Get_Struct(rval, CArray, &carray_data_type, cb);
      if ( cb->elements != dim_size ) {
        rb_raise(rb_eArgError,
                 "mismatch of # of elements ( %lld <=> %lld ) in reference "
                 "by selection on axis %d",
                 (long long) cb->elements, (long long) dim_size, (int) i);
      }
      rval = rb_ca_where(rval);
    }

    /* INDEX axis: converted here, read once the window below opens */
    ca_check_index_array(rval);
    ci[i] = ca_wrap_readonly(rval, CA_SIZE);
    rb_ary_push(list, rval);
  }

  /* The index arrays are read with all of them attached, and building
     the view checks every index against the parent -- an index out of
     range raises there.  So the reads and the build are a window body,
     which detaches the caller's index arrays however it ends. */
  {
    ca_grid_build_ctx_t c;
    char modes[CA_RANK_MAX + 1];
    memset(modes, 'r', (size_t) ca->ndim);
    modes[ca->ndim] = '\0';
    c.self   = self;
    c.ca     = ca;
    c.ci     = ci;
    c.protos = protos;
    obj = ca_attach_window(ca->ndim, ci, modes, ca_grid_build_body,
                           (VALUE) &c);
  }

  return ca_grid_drop_scalar_axes(obj, argc, argv);
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
  ca_check_uninitialized(ca);
  TypedData_Get_Struct(other, CAGrid, &cagrid_data_type, cs);

  if ( ca_func[CA_OBJ_GRID].pool_init ) {
    ca_array_pool_alloc(ca, CA_OBJ_GRID, cs->ndim);
  }
  /* Copy the axes: the source may be collected before the copy. */
  ca_grid_setup(ca, cs->parent, cs->ndim, cs->axes, 0);
  ca->holes_read_masked = cs->holes_read_masked;
  ca->mask_owner        = cs->mask_owner;
  ca_grid_inherit_mask((VALUE) ca);

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

  ca_attach(ca->parent);   /* window: nothing raises inside */
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

  ca_attach(ca->parent);   /* window: nothing raises inside */
  ca_axis_dispatch_scatter(ca->parent, pdims, desc, ca->ndim, ca->bytes,
                           ca->elements, RSTRING_PTR(in_str));
  ca_sync_detach(ca->parent);
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

  ca_attach(ca->parent);   /* window: nothing raises inside */
  ca_axis_dispatch_fill_value(ca->parent, pdims, desc, ca->ndim, ca->bytes,
                              ca->elements, RSTRING_PTR(val_str));
  ca_sync_detach(ca->parent);
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
  ca_register_cell_moving_view(CA_OBJ_GRID);
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

