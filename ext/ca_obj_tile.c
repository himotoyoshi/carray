/* ---------------------------------------------------------------------------

  CATile — N-region expansion view (tiled repetition of the parent).
  Output shape = parent.dim[k] * reps[k] per axis; each tile at output
  offset (i_0 * parent.dim[0], ...) is a full-parent alias.  Total
  tiles = product(reps).

  Attach / sync iterate all tiles, calling
  ca_composite_region_gather / _region_scatter (from
  ca_composite_dispatch.c) for each tile region.

  CARoll shares this file's struct + operation table (only obj_type
  differs); its constructor emits a 2-region minimal layout instead
  of N-tile expansion, but attach/sync is identical.

---------------------------------------------------------------------------- */

#include "carray.h"
#include "ca_composite_dispatch.h"
#include "ca_obj_face.h"  /* CA_FACE_LIFT_IF_FACE */

/* ------------------------------------------------------------------- */
/* TypedData                                                            */
/* ------------------------------------------------------------------- */

static size_t
ca_tile_dsize (const void *ap)
{
  const CATile *ca = (const CATile *) ap;
  /* dim is ALLOC_N(ndim), reps is ALLOC_N(ndim). */
  return sizeof(CATile) + 2 * ca->ndim * sizeof(ca_size_t);
}

const rb_data_type_t catile_data_type = {
    .parent = &caview_data_type,
    .wrap_struct_name = "CATile",
    .function = {
        .dmark = ca_mark,
        .dfree = ca_free,
        .dsize = ca_tile_dsize,
        .dcompact = NULL
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

const rb_data_type_t catile_mask_data_type = {
    .parent = &catile_data_type,
    .wrap_struct_name = "CATileMask",
    .function = {
        .dmark = ca_mark,
        .dfree = ca_free_nop,
        .dsize = ca_tile_dsize,
        .dcompact = NULL
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

int8_t CA_OBJ_TILE;

VALUE rb_cCATile;
VALUE rb_cCATileMask;

/* ------------------------------------------------------------------- */
/* setup / new / free / clone                                           */
/* ------------------------------------------------------------------- */

int
ca_tile_setup (CATile *ca, CArray *parent, ca_size_t *reps)
{
  int8_t  data_type, ndim;
  ca_size_t bytes, elements;
  int8_t i;

  data_type = parent->data_type;
  ndim      = parent->ndim;
  bytes     = parent->bytes;

  elements = 1;
  for (i = 0; i < ndim; i++) {
    if ( reps[i] <= 0 ) {
      rb_raise(rb_eIndexError,
               "invalid reps for %d-th dimension (must be positive)", i);
    }
    if ( parent->dim[i] <= 0 ) {
      rb_raise(rb_eIndexError,
               "invalid parent dim for %d-th dimension", i);
    }
    elements *= parent->dim[i] * reps[i];
  }

  ca->obj_type  = CA_OBJ_TILE;
  ca->data_type = data_type;
  ca->flags     = 0;
  ca->ndim      = ndim;
  ca->bytes     = bytes;
  ca->elements  = elements;
  ca->ptr       = NULL;
  ca->mask      = NULL;

  ca->parent    = parent;
  ca->attach    = 0;
  ca->nosync    = 0;
  ca->reps      = ALLOC_N(ca_size_t, ndim);
  ca->dim       = ALLOC_N(ca_size_t, ndim);

  for (i = 0; i < ndim; i++) {
    ca->reps[i] = reps[i];
    ca->dim[i]  = parent->dim[i] * reps[i];
  }

  if ( ca_has_mask(parent) ) {
    ca_create_mask(ca);
  }

  return 0;
}

CATile *
ca_tile_new (CArray *parent, ca_size_t *reps)
{
  CATile *ca = ALLOC(CATile);
  ca_tile_setup(ca, parent, reps);
  return ca;
}

static void
free_ca_tile (void *ap)
{
  CATile *ca = (CATile *) ap;
  if ( ca != NULL ) {
    ca_free(ca->mask);
    xfree(ca->reps);
    xfree(ca->dim);
    xfree(ca);
  }
}

static void *
ca_tile_func_clone (void *ap)
{
  CATile *ca = (CATile *) ap;
  return ca_tile_new(ca->parent, ca->reps);
}

/* ------------------------------------------------------------------- */
/* fetch / store                                                        */
/* ------------------------------------------------------------------- */

/* xfer_index: view[i_0, ...] = parent[i_0 % parent.dim[0], ...].
   PUT is last-write-wins when tiles overlap. */
static void
ca_tile_func_xfer_index (void *ap, ca_size_t *idx, void *data, int dir)
{
  CATile *ca = (CATile *) ap;
  ca_size_t pidx[CA_RANK_MAX];
  int8_t i;
  for (i = 0; i < ca->ndim; i++) {
    pidx[i] = idx[i] % ca->parent->dim[i];
  }
  ca_xfer_index(ca->parent, pidx, data, dir);
}

/* Batched address gather/scatter: translate each view addr to a
   parent flat addr (modulo wrap, always in-bounds) and hand the
   whole list to the parent in one ca_xfer_addrs call — no whole-view
   attach. */
static void
ca_tile_func_xfer_addrs (void *ap, ca_size_t n, ca_size_t *addrs,
                         void *data, int dir)
{
  CATile *ca = (CATile *) ap;
  ca_size_t *paddrs;
  ca_size_t  i;
  int8_t     k;
  volatile VALUE holder;
  paddrs = ALLOCV_N(ca_size_t, holder, n);
  for (i = 0; i < n; i++) {
    ca_size_t vidx[CA_RANK_MAX], pidx[CA_RANK_MAX];
    ca_addr2index((CArray *) ca, addrs[i], vidx);
    for (k = 0; k < ca->ndim; k++) pidx[k] = vidx[k] % ca->parent->dim[k];
    paddrs[i] = ca_index2addr(ca->parent, pidx);
  }
  ca_xfer_addrs(ca->parent, n, paddrs, data, dir);
  ALLOCV_END(holder);
}

/* Structural region delivery for CATile.  Each axis maps to the
   parent by modulo (view_pos % parent.dim), so a contiguous inner
   run wraps at tile boundaries — split into per-tile segments, each
   a contiguous parent run delivered via parent.xfer_stride.  Outer
   axes iterate cell by cell (one modulo per parent position).  The
   structural path requires axis-aligned + unit src step; otherwise a
   per-cell fallback runs.  data is contiguous (semantics b); no
   whole-view attach.  bytes == parent.bytes (no reinterpret). */
static void
ca_tile_func_xfer_stride (void *ap, ca_size_t *starts, ca_size_t *counts,
                          ca_size_t *strides, void *data, int dir)
{
  CATile   *ca = (CATile *) ap;
  CArray   *parent = ca->parent;
  int8_t    ndim = ca->ndim;
  int8_t    inner = ndim - 1;
  ca_size_t pnative[CA_RANK_MAX], tnative[CA_RANK_MAX], dstride[CA_RANK_MAX];
  ca_size_t o[CA_RANK_MAX];
  ca_size_t s;
  int8_t    k;
  int       structural = 1;
  char     *d = (char *) data;

  s = parent->bytes;
  for (k = ndim - 1; k >= 0; k--) { pnative[k] = s; s *= parent->dim[k]; }
  s = ca->bytes;
  for (k = ndim - 1; k >= 0; k--) { tnative[k] = s; s *= ca->dim[k]; }
  s = ca->bytes;
  for (k = ndim - 1; k >= 0; k--) { dstride[k] = s; s *= counts[k]; }

  for (k = 0; k < ndim; k++) {
    if (strides[k] % tnative[k] != 0 || strides[k] / tnative[k] != 1) {
      structural = 0;
      break;
    }
  }

  if (!structural) {
    ca_size_t idx[CA_RANK_MAX], doff = 0, base = 0;
    for (k = 0; k < ndim; k++) base += starts[k] * tnative[k];
    for (k = 0; k < ndim; k++) idx[k] = 0;
    while (1) {
      ca_size_t toff = base, tidx[CA_RANK_MAX];
      for (k = 0; k < ndim; k++) toff += idx[k] * strides[k];
      ca_addr2index((CArray *) ca, toff / ca->bytes, tidx);
      ca_tile_func_xfer_index(ca, tidx, d + doff, dir);
      doff += ca->bytes;
      k = ndim - 1;
      while (k >= 0) { if (++idx[k] < counts[k]) break; idx[k] = 0; k--; }
      if (k < 0) break;
    }
    return;
  }

  for (k = 0; k < ndim; k++) o[k] = 0;
  while (1) {
    ca_size_t pbase = 0, doff = 0, i;
    for (k = 0; k < inner; k++) {
      pbase += ((starts[k] + o[k]) % parent->dim[k]) * pnative[k];
      doff  += o[k] * dstride[k];
    }
    i = 0;
    while (i < counts[inner]) {
      ca_size_t ppos = (starts[inner] + i) % parent->dim[inner];
      ca_size_t seg = parent->dim[inner] - ppos;   /* until the tile boundary */
      ca_size_t pstarts[CA_RANK_MAX], pcounts[CA_RANK_MAX], pstrides[CA_RANK_MAX];
      if (seg > counts[inner] - i) seg = counts[inner] - i;
      ca_addr2index((CArray *) parent, (pbase + ppos * pnative[inner]) / parent->bytes, pstarts);
      for (k = 0; k < ndim; k++) { pcounts[k] = 1; pstrides[k] = 0; }
      pcounts[inner]  = seg;
      pstrides[inner] = pnative[inner];
      ca_xfer_stride(parent, pstarts, pcounts, pstrides, d + doff + i * dstride[inner], dir);
      i += seg;
    }
    k = inner - 1;
    while (k >= 0) { if (++o[k] < counts[k]) break; o[k] = 0; k--; }
    if (k < 0) break;
  }
}

/* ------------------------------------------------------------------- */
/* attach / sync / detach via per-tile region helpers                   */
/* ------------------------------------------------------------------- */

static void
ca_tile_compute_strides (CATile *ca,
                         ca_size_t *parent_strides,
                         ca_size_t *output_strides)
{
  ca_size_t s;
  int8_t k;
  s = ca->bytes;
  for ( k = ca->ndim - 1; k >= 0; k-- ) {
    parent_strides[k] = s;
    s *= ca->parent->dim[k];
  }
  s = ca->bytes;
  for ( k = ca->ndim - 1; k >= 0; k-- ) {
    output_strides[k] = s;
    s *= ca->dim[k];
  }
}

/* Iterate tiles row-major over reps[] and invoke a per-tile callback.
   tile_idx[k] is the tile coordinate in [0, reps[k]).  The callback
   computes per-tile output_offset[k] = tile_idx[k] * parent->dim[k]
   and calls ca_composite_region_gather / _scatter. */
static void
ca_tile_attach_into (CATile *ca, char *out_ptr)
{
  ca_size_t parent_strides[CA_RANK_MAX];
  ca_size_t output_strides[CA_RANK_MAX];
  ca_size_t parent_start[CA_RANK_MAX];
  ca_size_t output_offset[CA_RANK_MAX];
  ca_size_t tile_idx[CA_RANK_MAX];
  ca_size_t total_tiles;
  int8_t    ndim = ca->ndim;
  int8_t    k;
  ca_size_t t;

  ca_tile_compute_strides(ca, parent_strides, output_strides);

  for ( k = 0; k < ndim; k++ ) {
    parent_start[k] = 0;       /* always full-parent gather */
    tile_idx[k] = 0;
    output_offset[k] = 0;
  }

  total_tiles = 1;
  for ( k = 0; k < ndim; k++ ) total_tiles *= ca->reps[k];

  for ( t = 0; t < total_tiles; t++ ) {
    ca_composite_region_gather(ca->parent->ptr, parent_strides,
                               parent_start,
                               out_ptr, output_strides, output_offset,
                               ca->parent->dim, ndim, ca->bytes);

    /* Advance tile_idx row-major; output_offset[k] = tile_idx[k] * parent->dim[k]. */
    for ( k = ndim - 1; k >= 0; k-- ) {
      tile_idx[k]++;
      if ( tile_idx[k] < ca->reps[k] ) {
        output_offset[k] += ca->parent->dim[k];
        break;
      }
      tile_idx[k] = 0;
      output_offset[k] = 0;
    }
  }
}

/* Reverse: scatter all tiles back to parent.  All tiles alias the same
   parent block, so writes overlap; last-tile-scattered wins for any
   given parent cell. */
static void
ca_tile_sync_from (CATile *ca, char *in_ptr)
{
  ca_size_t parent_strides[CA_RANK_MAX];
  ca_size_t input_strides[CA_RANK_MAX];
  ca_size_t parent_start[CA_RANK_MAX];
  ca_size_t input_offset[CA_RANK_MAX];
  ca_size_t tile_idx[CA_RANK_MAX];
  ca_size_t total_tiles;
  int8_t    ndim = ca->ndim;
  int8_t    k;
  ca_size_t t;

  ca_tile_compute_strides(ca, parent_strides, input_strides);

  for ( k = 0; k < ndim; k++ ) {
    parent_start[k] = 0;
    tile_idx[k] = 0;
    input_offset[k] = 0;
  }

  total_tiles = 1;
  for ( k = 0; k < ndim; k++ ) total_tiles *= ca->reps[k];

  for ( t = 0; t < total_tiles; t++ ) {
    ca_composite_region_scatter(ca->parent->ptr, parent_strides,
                                parent_start,
                                in_ptr, input_strides, input_offset,
                                ca->parent->dim, ndim, ca->bytes);

    for ( k = ndim - 1; k >= 0; k-- ) {
      tile_idx[k]++;
      if ( tile_idx[k] < ca->reps[k] ) {
        input_offset[k] += ca->parent->dim[k];
        break;
      }
      tile_idx[k] = 0;
      input_offset[k] = 0;
    }
  }
}

static void
ca_tile_func_allocate (void *ap)
{
  CATile *ca = (CATile *) ap;
  ca_attach(ca->parent);
  ca->ptr = xmalloc(ca_length(ca));
}

static void
ca_tile_func_attach (void *ap)
{
  CATile *ca = (CATile *) ap;
  ca_attach(ca->parent);
  ca->ptr = xmalloc(ca_length(ca));
  ca_tile_attach_into(ca, ca->ptr);
}

static void
ca_tile_func_sync (void *ap)
{
  CATile *ca = (CATile *) ap;
  ca_tile_sync_from(ca, ca->ptr);
  ca_sync(ca->parent);
}

static void
ca_tile_func_detach (void *ap)
{
  CATile *ca = (CATile *) ap;
  xfree(ca->ptr);
  ca->ptr = NULL;
  ca_detach(ca->parent);
}

/* xfer_all: fast path when the parent has a live ptr — reuse
 * attach_into / sync_from directly, no operand attach.  Cold parent
 * falls back to a 2-pass gather-then-run over a scratch buffer. */
static void
ca_tile_func_xfer_all (void *ap, void *data, int dir)
{
  CATile *ca = (CATile *) ap;
  if ( ca->parent->ptr ) {
    if ( dir == CA_XFER_GET ) ca_tile_attach_into(ca, (char *) data);
    else                       ca_tile_sync_from(ca, (char *) data);
    return;
  }
  /* Cold parent: gather into a scratch, alias parent->ptr to it for
     the duration of the tile walk, then scatter back on PUT. */
  {
    volatile VALUE holder;
    CArray   *parent = ca->parent;
    ca_size_t plen   = parent->elements * parent->bytes;
    char     *parent_scratch = ALLOCV_N(char, holder, plen);
    char     *parent_ptr_saved = parent->ptr;
    ca_xfer_all(parent, parent_scratch, CA_XFER_GET);
    parent->ptr = parent_scratch;
    if ( dir == CA_XFER_GET ) ca_tile_attach_into(ca, (char *) data);
    else                       ca_tile_sync_from(ca, (char *) data);
    if ( dir == CA_XFER_PUT ) {
      ca_xfer_all(parent, parent_scratch, CA_XFER_PUT);
    }
    parent->ptr = parent_ptr_saved;
    ALLOCV_END(holder);
  }
}

/* fill_data: broadcast scalar to all view cells = write scalar to parent
   once (= the value lands in every tile alias since they all share). */
static void
ca_tile_func_fill_data (void *ap, void *ptr)
{
  CATile *ca = (CATile *) ap;
  ca_fill(ca->parent, ptr);
}

static void
ca_tile_func_create_mask (void *ap)
{
  CATile *ca = (CATile *) ap;
  ca_update_mask(ca->parent);
  if ( ! ca->parent->mask ) {
    ca_create_mask(ca->parent);
  }
  ca->mask = (CArray *) ca_tile_new(ca->parent->mask, ca->reps);
}

ca_operation_function_t ca_tile_func = {
  -1, /* CA_OBJ_TILE */
  CA_VIEW_ARRAY,
  free_ca_tile,
  ca_tile_func_clone,
  ca_tile_func_allocate,
  ca_tile_func_attach,
  ca_tile_func_sync,
  ca_tile_func_detach,
  ca_tile_func_fill_data,
  ca_tile_func_create_mask,
  ca_tile_func_xfer_index,
  ca_tile_func_xfer_addrs,
  NULL,                       /* fold_stride: never-fold (modulo wrap) */
  ca_tile_func_xfer_stride,
  ca_tile_func_xfer_all,
};

/* ------------------------------------------------------------------- */
/* Ruby surface                                                         */
/* ------------------------------------------------------------------- */

VALUE
rb_ca_tile_new (VALUE cary, ca_size_t *reps)
{
  volatile VALUE obj;
  CArray *parent;
  CATile *ca;
  rb_check_carray_object(cary);
  TypedData_Get_Struct(cary, CArray, &carray_data_type, parent);
  ca  = ca_tile_new(parent, reps);
  obj = ca_wrap_struct(ca);
  rb_ca_set_parent(obj, cary);
  return obj;
}

/* CArray#tile(*reps) — multi-arg primary, Array of Integer accepted.
   argc == ndim required (no implicit dimension prepending).

   Examples:
     a.tile(3)         # 1D, OK
     a.tile([3])       # 1D, OK (Array form)
     a.tile(2, 3)      # 2D, OK
     a.tile([2, 3])    # 2D, OK (Array form, single arg)
     a.tile(3)         # 2D, raises ArgumentError (argc != ndim) */
static VALUE
rb_ca_tile (int argc, VALUE *argv, VALUE self)
{
  CArray *ca;
  ca_size_t reps[CA_RANK_MAX];
  int8_t i;

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  /* Single-arg Array form: a.tile([2, 3]) */
  if ( argc == 1 && rb_obj_is_kind_of(argv[0], rb_cArray) ) {
    VALUE ary = argv[0];
    long len = RARRAY_LEN(ary);
    if ( len != ca->ndim ) {
      rb_raise(rb_eArgError,
               "tile: array length (%ld) does not match ndim (%d)",
               len, ca->ndim);
    }
    for ( i = 0; i < ca->ndim; i++ ) {
      reps[i] = NUM2SIZE(rb_ary_entry(ary, i));
    }
  }
  else {
    /* Multi-arg form: a.tile(2, 3, ...). */
    if ( argc != ca->ndim ) {
      rb_raise(rb_eArgError,
               "tile: expected %d args (= ndim), got %d",
               ca->ndim, argc);
    }
    for ( i = 0; i < ca->ndim; i++ ) {
      reps[i] = NUM2SIZE(argv[i]);
    }
  }

  {
    VALUE obj = rb_ca_tile_new(self, reps);
    CA_WRAPPER_LIFT(obj, self, ca);
    return obj;
  }
}

static VALUE
rb_ca_tile_s_allocate (VALUE klass)
{
  CATile *ca;
  return TypedData_Make_Struct(klass, CATile, &catile_data_type, ca);
}

static VALUE
rb_ca_tile_initialize_copy (VALUE self, VALUE other)
{
  CATile *ca, *cs;
  TypedData_Get_Struct(self,  CATile, &catile_data_type, ca);
  TypedData_Get_Struct(other, CATile, &catile_data_type, cs);
  ca_tile_setup(ca, cs->parent, cs->reps);
  return self;
}

/* Debug-only accessor returning the tile descriptor as a Hash.
   Naming: leading underscore signals internal use. */
static VALUE
rb_ca_tile_descriptor (VALUE self)
{
  CATile *ca = (CATile *) DATA_PTR(self);
  VALUE hash, reps_ary;
  int8_t k;
  ca_size_t total = 1;

  reps_ary = rb_ary_new_capa(ca->ndim);
  for ( k = 0; k < ca->ndim; k++ ) {
    rb_ary_push(reps_ary, SIZE2NUM(ca->reps[k]));
    total *= ca->reps[k];
  }
  hash = rb_hash_new();
  rb_hash_aset(hash, ID2SYM(rb_intern("reps")), reps_ary);
  rb_hash_aset(hash, ID2SYM(rb_intern("total_tiles")), SIZE2NUM(total));
  rb_hash_aset(hash, ID2SYM(rb_intern("ndim")), INT2NUM(ca->ndim));
  return hash;
}

void
Init_ca_obj_tile (void)
{
  rb_cCATile = rb_define_class("CATile", rb_cCAView);
  rb_cCATileMask = rb_define_class("CATileMask", rb_cCATile);

  CA_OBJ_TILE = ca_install_obj_type(rb_cCATile,
                                    &catile_data_type,
                                    rb_cCATileMask,
                                    &catile_mask_data_type, &ca_tile_func, sizeof(ca_tile_func));
  rb_define_const(rb_cObject, "CA_OBJ_TILE", INT2NUM(CA_OBJ_TILE));

  rb_define_method(rb_cCArray, "tile", rb_ca_tile, -1);

  rb_define_alloc_func(rb_cCATile, rb_ca_tile_s_allocate);
  rb_define_method(rb_cCATile, "initialize_copy",
                                      rb_ca_tile_initialize_copy, 1);

  /* Debug-only descriptor accessor. */
  rb_define_method(rb_cCATile, "_tile_descriptor",
                                      rb_ca_tile_descriptor, 0);
}
