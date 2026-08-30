/* ---------------------------------------------------------------------------

  CARoll view: same-shape cyclic shift of the parent.  Per-axis shift
  is passed as multi-arg to `CArray#roll`.

  Sibling of ca_obj_tile.c (CARoll is a `typedef CATile CARoll`; the
  operation table is built by copying ca_tile_func and overriding the
  slots that need shift-specific behavior).

  Storage reuse: CATile's `reps[]` field is reinterpreted in CARoll as
  `shift[]` (= normalised to `[0, parent.dim[k])`).

  Region enumeration: each shifted axis contributes 2 stripes, so the
  cartesian product yields 2^K regions where K counts non-zero shift
  axes.  Non-shifted axes give a single full-parent stripe.

---------------------------------------------------------------------------- */

#include "carray.h"
#include "ca_composite_dispatch.h"
#include "ca_obj_face.h"

/* ------------------------------------------------------------------- */
/* External: CATile's data type + base operation table (typedef shared). */
/* ------------------------------------------------------------------- */

extern const rb_data_type_t catile_data_type;
extern ca_operation_function_t ca_tile_func;
extern VALUE rb_cCATile;

/* ------------------------------------------------------------------- */
/* TypedData                                                            */
/* ------------------------------------------------------------------- */

static size_t
ca_roll_dsize (const void *ap)
{
  const CARoll *ca = (const CARoll *) ap;
  /* Layout inherited from CATile: dim + reps, each ALLOC_N(ndim). */
  return sizeof(CARoll) + 2 * ca->ndim * sizeof(ca_size_t);
}

const rb_data_type_t caroll_data_type = {
    .parent = &catile_data_type,
    .wrap_struct_name = "CARoll",
    .function = {
        .dmark = ca_mark,
        .dfree = ca_free,
        .dsize = ca_roll_dsize,
        .dcompact = NULL
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

const rb_data_type_t caroll_mask_data_type = {
    .parent = &caroll_data_type,
    .wrap_struct_name = "CARollMask",
    .function = {
        .dmark = ca_mark,
        .dfree = ca_free_nop,
        .dsize = ca_roll_dsize,
        .dcompact = NULL
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

int8_t CA_OBJ_ROLL;

VALUE rb_cCARoll;
VALUE rb_cCARollMask;

ca_operation_function_t ca_roll_func;

/* ------------------------------------------------------------------- */
/* setup / new / free / clone                                           */
/* ------------------------------------------------------------------- */

/* shift[] semantics:
     shift[k] > 0 : shift right (last shift[k] elements wrap to front)
     shift[k] < 0 : shift left
     shift[k] is normalised into [0, parent.dim[k]) modulo dim[k].
     Missing axes (argc < ndim from Ruby): treated as shift = 0. */
int
ca_roll_setup (CARoll *ca, CArray *parent, ca_size_t *shift)
{
  int8_t ndim = parent->ndim;
  ca_size_t bytes = parent->bytes;
  ca_size_t elements;
  int8_t i;

  elements = 1;
  for (i = 0; i < ndim; i++) {
    if ( parent->dim[i] <= 0 ) {
      rb_raise(rb_eIndexError, "invalid parent dim for %d-th dimension", i);
    }
    elements *= parent->dim[i];
  }

  ca->obj_type  = CA_OBJ_ROLL;
  ca->data_type = parent->data_type;
  ca->flags     = 0;
  ca->ndim      = ndim;
  ca->bytes     = bytes;
  ca->elements  = elements;
  ca->ptr       = NULL;
  ca->mask      = NULL;

  ca->parent    = parent;
  ca->attach    = 0;
  ca->nosync    = 0;
  ca->reps      = ALLOC_N(ca_size_t, ndim);  /* repurposed as shift[] */
  ca->dim       = ALLOC_N(ca_size_t, ndim);

  for (i = 0; i < ndim; i++) {
    ca->dim[i] = parent->dim[i];
    /* Normalise: ((shift[i] % dim[i]) + dim[i]) % dim[i] ∈ [0, dim[i]). */
    ca_size_t s = shift[i] % parent->dim[i];
    if ( s < 0 ) s += parent->dim[i];
    ca->reps[i] = s;
  }

  if ( ca_has_mask(parent) ) {
    ca_create_mask(ca);
  }

  return 0;
}

CARoll *
ca_roll_new (CArray *parent, ca_size_t *shift)
{
  CARoll *ca = ALLOC(CARoll);
  ca_roll_setup(ca, parent, shift);
  return ca;
}

static void
free_ca_roll (void *ap)
{
  CARoll *ca = (CARoll *) ap;
  if ( ca != NULL ) {
    ca_free(ca->mask);
    xfree(ca->reps);
    xfree(ca->dim);
    xfree(ca);
  }
}

static void *
ca_roll_func_clone (void *ap)
{
  CARoll *ca = (CARoll *) ap;
  return ca_roll_new(ca->parent, ca->reps);  /* reps[] is already normalised shift[] */
}

/* ------------------------------------------------------------------- */
/* xfer_index / xfer_addrs / xfer_stride — periodic index map           */
/*                                                                      */
/*   view[i_0, i_1, ...] = parent[(i_0 - shift_0 + dim_0) % dim_0, ...]  */
/*                                                                      */
/* CARoll inherits ca_tile_func by copy, so every xfer slot below must  */
/* be re-registered in Init_ca_obj_roll to override the CATile version. */
/* ------------------------------------------------------------------- */

static void
ca_roll_func_xfer_index (void *ap, ca_size_t *idx, void *data, int dir)
{
  CARoll *ca = (CARoll *) ap;
  ca_size_t pidx[CA_RANK_MAX];
  int8_t i;
  for (i = 0; i < ca->ndim; i++) {
    /* output[idx] = parent[(idx - shift + dim) % dim]. */
    ca_size_t k = idx[i] - ca->reps[i];
    if ( k < 0 ) k += ca->parent->dim[i];
    pidx[i] = k;
  }
  ca_xfer_index(ca->parent, pidx, data, dir);
}

/* Batched address gather/scatter.  The periodic shift is 1:1 and
   always in-bounds, so all addrs collapse to a single parent
   ca_xfer_addrs call. */
static void
ca_roll_func_xfer_addrs (void *ap, ca_size_t n, ca_size_t *addrs,
                         void *data, int dir)
{
  CARoll *ca = (CARoll *) ap;
  ca_size_t *paddrs;
  ca_size_t  i;
  int8_t     k;
  volatile VALUE holder;
  paddrs = ALLOCV_N(ca_size_t, holder, n);
  for (i = 0; i < n; i++) {
    ca_size_t vidx[CA_RANK_MAX], pidx[CA_RANK_MAX];
    ca_addr2index((CArray *) ca, addrs[i], vidx);
    for (k = 0; k < ca->ndim; k++) {
      ca_size_t j = vidx[k] - ca->reps[k];
      if ( j < 0 ) j += ca->parent->dim[k];
      pidx[k] = j;
    }
    paddrs[i] = ca_index2addr(ca->parent, pidx);
  }
  ca_xfer_addrs(ca->parent, n, paddrs, data, dir);
  ALLOCV_END(holder);
}

/* Structural region delivery for CARoll.  The parent position along
   each axis is `(view_pos - shift) mod parent.dim[k]`.  view.dim ==
   parent.dim, so a contiguous inner run wraps at most once and the
   per-segment loop handles the wrap.  Structural path requires
   axis-aligned unit src step along the inner axis; otherwise falls
   back to per-cell xfer_index. */
static void
ca_roll_func_xfer_stride (void *ap, ca_size_t *starts, ca_size_t *counts,
                          ca_size_t *strides, void *data, int dir)
{
  CARoll   *ca = (CARoll *) ap;
  CArray   *parent = ca->parent;
  int8_t    ndim = ca->ndim;
  int8_t    inner = ndim - 1;
  ca_size_t pnative[CA_RANK_MAX], rnative[CA_RANK_MAX], dstride[CA_RANK_MAX];
  ca_size_t o[CA_RANK_MAX];
  ca_size_t s;
  int8_t    k;
  int       structural = 1;
  char     *d = (char *) data;

  s = parent->bytes;
  for (k = ndim - 1; k >= 0; k--) { pnative[k] = s; s *= parent->dim[k]; }
  s = ca->bytes;
  for (k = ndim - 1; k >= 0; k--) { rnative[k] = s; s *= ca->dim[k]; }
  s = ca->bytes;
  for (k = ndim - 1; k >= 0; k--) { dstride[k] = s; s *= counts[k]; }

  for (k = 0; k < ndim; k++) {
    if (strides[k] % rnative[k] != 0 || strides[k] / rnative[k] != 1) {
      structural = 0;
      break;
    }
  }

  if (!structural) {
    ca_size_t idx[CA_RANK_MAX], doff = 0, base = 0;
    for (k = 0; k < ndim; k++) base += starts[k] * rnative[k];
    for (k = 0; k < ndim; k++) idx[k] = 0;
    while (1) {
      ca_size_t roff = base, ridx[CA_RANK_MAX];
      for (k = 0; k < ndim; k++) roff += idx[k] * strides[k];
      ca_addr2index((CArray *) ca, roff / ca->bytes, ridx);
      ca_roll_func_xfer_index(ca, ridx, d + doff, dir);
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
      ca_size_t j = (starts[k] + o[k]) - ca->reps[k];
      if (j < 0) j += parent->dim[k];
      pbase += j * pnative[k];
      doff  += o[k] * dstride[k];
    }
    i = 0;
    while (i < counts[inner]) {
      ca_size_t ppos = (starts[inner] + i) - ca->reps[inner];
      if (ppos < 0) ppos += parent->dim[inner];
      ca_size_t seg = parent->dim[inner] - ppos;
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
/* attach / sync — enumerate 2^K stripe regions                        */
/*                                                                      */
/* Per axis k:                                                          */
/*   shift[k] == 0 :                                                    */
/*     one full-axis stripe (parent_start=0, count=dim, off=0)          */
/*   shift[k]  > 0 :                                                    */
/*     stripe A (last shift[k] parent cells wrap to output front):      */
/*       parent_start[k] = dim[k] - shift[k]                            */
/*       count[k]        = shift[k]                                     */
/*       output_offset[k]= 0                                            */
/*     stripe B (remaining cells):                                      */
/*       parent_start[k] = 0                                            */
/*       count[k]        = dim[k] - shift[k]                            */
/*       output_offset[k]= shift[k]                                     */
/*                                                                      */
/* Total regions = 2^K where K = number of axes with shift != 0.        */
/* ------------------------------------------------------------------- */

static void
ca_roll_compute_strides (CARoll *ca,
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

/* Walk regions via a bitmap over the K shifted axes.  For each region
   (bitmap value 0..2^K-1), build parent_start[] / count[] /
   output_offset[] and call ca_composite_region_gather (attach) or
   ca_composite_region_scatter (sync). */
static void
ca_roll_iterate_regions (CARoll *ca, char *out_ptr, int direction)
{
  ca_size_t parent_strides[CA_RANK_MAX];
  ca_size_t output_strides[CA_RANK_MAX];
  ca_size_t parent_start[CA_RANK_MAX];
  ca_size_t output_offset[CA_RANK_MAX];
  ca_size_t count[CA_RANK_MAX];
  int8_t shifted_axes[CA_RANK_MAX];
  int8_t  n_shifted = 0;
  int8_t  k;
  ca_size_t bytes = ca->bytes;
  int8_t  ndim = ca->ndim;
  int region, total_regions;

  ca_roll_compute_strides(ca, parent_strides, output_strides);

  /* Identify shifted axes; set baseline (= stripe B for shifted, full for non-shifted). */
  for ( k = 0; k < ndim; k++ ) {
    if ( ca->reps[k] != 0 ) {
      shifted_axes[n_shifted++] = k;
    }
  }

  total_regions = 1 << n_shifted;

  for ( region = 0; region < total_regions; region++ ) {
    /* Initialise: non-shifted axes = full. */
    for ( k = 0; k < ndim; k++ ) {
      if ( ca->reps[k] == 0 ) {
        parent_start[k]  = 0;
        count[k]         = ca->parent->dim[k];
        output_offset[k] = 0;
      }
    }
    /* For each shifted axis, pick stripe based on region bit. */
    for ( int b = 0; b < n_shifted; b++ ) {
      int8_t  ax = shifted_axes[b];
      ca_size_t shift = ca->reps[ax];
      ca_size_t pdim  = ca->parent->dim[ax];
      if ( (region >> b) & 1 ) {
        /* Stripe B: remaining elements after the wrapped tail. */
        parent_start[ax]  = 0;
        count[ax]         = pdim - shift;
        output_offset[ax] = shift;
      } else {
        /* Stripe A: last `shift` elements wrap to front. */
        parent_start[ax]  = pdim - shift;
        count[ax]         = shift;
        output_offset[ax] = 0;
      }
    }

    if ( direction == 0 ) {
      ca_composite_region_gather(ca->parent->ptr, parent_strides,
                                 parent_start,
                                 out_ptr, output_strides, output_offset,
                                 count, ndim, bytes);
    } else {
      ca_composite_region_scatter(ca->parent->ptr, parent_strides,
                                  parent_start,
                                  out_ptr, output_strides, output_offset,
                                  count, ndim, bytes);
    }
  }
}

static void
ca_roll_func_allocate (void *ap)
{
  CARoll *ca = (CARoll *) ap;
  ca_attach(ca->parent);
  ca->ptr = xmalloc(ca_length(ca));
}

static void
ca_roll_func_attach (void *ap)
{
  CARoll *ca = (CARoll *) ap;
  ca_attach(ca->parent);
  ca->ptr = xmalloc(ca_length(ca));
  ca_roll_iterate_regions(ca, ca->ptr, 0);
}

static void
ca_roll_func_sync (void *ap)
{
  CARoll *ca = (CARoll *) ap;
  ca_roll_iterate_regions(ca, ca->ptr, 1);
  ca_sync(ca->parent);
}

static void
ca_roll_func_detach (void *ap)
{
  CARoll *ca = (CARoll *) ap;
  xfree(ca->ptr);
  ca->ptr = NULL;
  ca_detach(ca->parent);
}

/* Fast path (hot parent): drive the region walk directly against
   parent->ptr.  Cold parent: fall back to a scratch 2-pass (gather
   parent into scratch, walk regions against the scratch, scatter
   back on PUT).  Deliberately does not call ca_attach(parent) — that
   would re-introduce the silent transitive attach the fast path was
   built to avoid. */
static void
ca_roll_func_xfer_all (void *ap, void *data, int dir)
{
  CARoll *ca = (CARoll *) ap;
  if ( ca->parent->ptr ) {
    ca_roll_iterate_regions(ca, (char *) data, dir == CA_XFER_PUT);
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
    ca_roll_iterate_regions(ca, (char *) data, dir == CA_XFER_PUT);
    if ( dir == CA_XFER_PUT ) {
      ca_xfer_all(parent, parent_scratch, CA_XFER_PUT);
    }
    parent->ptr = parent_ptr_saved;
    ALLOCV_END(holder);
  }
}

static void
ca_roll_func_fill_data (void *ap, void *ptr)
{
  CARoll *ca = (CARoll *) ap;
  /* Each parent cell appears exactly once in the view, so a broadcast
     fill is equivalent to filling the parent once. */
  ca_fill(ca->parent, ptr);
}

static void
ca_roll_func_create_mask (void *ap)
{
  CARoll *ca = (CARoll *) ap;
  ca_update_mask(ca->parent);
  if ( ! ca->parent->mask ) {
    ca_create_mask(ca->parent);
  }
  ca->mask = (CArray *) ca_roll_new(ca->parent->mask, ca->reps);
}

/* ------------------------------------------------------------------- */
/* Ruby surface                                                         */
/* ------------------------------------------------------------------- */

VALUE
rb_ca_roll_new (VALUE cary, ca_size_t *shift)
{
  volatile VALUE obj;
  CArray *parent;
  CARoll *ca;
  rb_check_carray_object(cary);
  TypedData_Get_Struct(cary, CArray, &carray_data_type, parent);
  ca  = ca_roll_new(parent, shift);
  obj = ca_wrap_struct(ca);
  rb_ca_set_parent(obj, cary);
  return obj;
}

/* CArray#roll(*shifts) — cyclic shift along each axis.
     argc < ndim : missing axes take shift = 0.
     argc > ndim : ArgumentError. */
static VALUE
rb_ca_roll (int argc, VALUE *argv, VALUE self)
{
  CArray *ca;
  volatile VALUE ropt;
  ca_size_t shift[CA_RANK_MAX];
  int8_t i;

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  /* Shifts are positional only.  A trailing Hash is a keyword argument
     that would otherwise reach NUM2SIZE and surface as a TypeError. */
  ropt = rb_pop_options(&argc, &argv);
  rb_reject_options(ropt);

  if ( argc > ca->ndim ) {
    rb_raise(rb_eArgError,
             "roll: too many args (%d), expected at most %d (= ndim)",
             argc, ca->ndim);
  }
  for ( i = 0; i < ca->ndim; i++ ) {
    if ( i < argc ) {
      shift[i] = NUM2SIZE(argv[i]);
    } else {
      shift[i] = 0;
    }
  }
  {
    VALUE obj = rb_ca_roll_new(self, shift);
    CA_WRAPPER_LIFT(obj, self, ca);
    return obj;
  }
}

/* `roll!` intentionally absent.  Canonical in-place idiom is
   `ca[] = ca.roll(...)`. */

static VALUE
rb_ca_roll_s_allocate (VALUE klass)
{
  CARoll *ca;
  return TypedData_Make_Struct(klass, CARoll, &caroll_data_type, ca);
}

static VALUE
rb_ca_roll_initialize_copy (VALUE self, VALUE other)
{
  CARoll *ca, *cs;
  TypedData_Get_Struct(self,  CARoll, &caroll_data_type, ca);
  TypedData_Get_Struct(other, CARoll, &caroll_data_type, cs);
  ca_roll_setup(ca, cs->parent, cs->reps);
  return self;
}

/* Debug-only accessor returning the roll descriptor as a Hash
   (`shifts`, `n_regions`, `ndim`).  Not part of the public surface. */
static VALUE
rb_ca_roll_descriptor (VALUE self)
{
  CARoll *ca = (CARoll *) DATA_PTR(self);
  VALUE hash, shifts_ary;
  int8_t k;
  int n_shifted = 0;

  shifts_ary = rb_ary_new_capa(ca->ndim);
  for ( k = 0; k < ca->ndim; k++ ) {
    rb_ary_push(shifts_ary, SIZE2NUM(ca->reps[k]));
    if ( ca->reps[k] != 0 ) n_shifted++;
  }
  hash = rb_hash_new();
  rb_hash_aset(hash, ID2SYM(rb_intern("shifts")), shifts_ary);
  rb_hash_aset(hash, ID2SYM(rb_intern("n_regions")), INT2NUM(1 << n_shifted));
  rb_hash_aset(hash, ID2SYM(rb_intern("ndim")), INT2NUM(ca->ndim));
  return hash;
}

void
Init_ca_obj_roll (void)
{
  /* Build ca_roll_func by copying ca_tile_func and overriding the
     slots that need CARoll-specific behavior. */
  ca_roll_func = ca_tile_func;
  ca_roll_func.free_object   = free_ca_roll;
  ca_roll_func.clone         = ca_roll_func_clone;
  ca_roll_func.allocate      = ca_roll_func_allocate;
  ca_roll_func.attach        = ca_roll_func_attach;
  ca_roll_func.sync          = ca_roll_func_sync;
  ca_roll_func.detach        = ca_roll_func_detach;
  ca_roll_func.fill_data     = ca_roll_func_fill_data;
  ca_roll_func.create_mask   = ca_roll_func_create_mask;
  ca_roll_func.xfer_index    = ca_roll_func_xfer_index;
  ca_roll_func.xfer_addrs    = ca_roll_func_xfer_addrs;
  ca_roll_func.xfer_stride   = ca_roll_func_xfer_stride;
  ca_roll_func.xfer_all      = ca_roll_func_xfer_all;

  rb_cCARoll = rb_define_class("CARoll", rb_cCATile);
  rb_cCARollMask = rb_define_class("CARollMask", rb_cCARoll);

  CA_OBJ_ROLL = ca_install_obj_type(rb_cCARoll,
                                    &caroll_data_type,
                                    rb_cCARollMask,
                                    &caroll_mask_data_type, &ca_roll_func, sizeof(ca_roll_func));
  rb_define_const(rb_cObject, "CA_OBJ_ROLL", INT2NUM(CA_OBJ_ROLL));

  rb_define_method(rb_cCArray, "roll", rb_ca_roll, -1);

  rb_define_alloc_func(rb_cCARoll, rb_ca_roll_s_allocate);
  rb_define_method(rb_cCARoll, "initialize_copy",
                                      rb_ca_roll_initialize_copy, 1);

  /* Debug accessor, not part of the public surface. */
  rb_define_method(rb_cCARoll, "_roll_descriptor",
                                      rb_ca_roll_descriptor, 0);
}
