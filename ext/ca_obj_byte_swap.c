/* ---------------------------------------------------------------------------

  CAByteSwap view: element-wise byte-order reversal of the parent.
  Same shape and byte width as the parent; materialises on attach
  with the byte swap applied.  Sibling of CAFake (both are
  value-conversion views under CAView).

  Numeric primitive parents route through CAMonOp(byte_swap) by
  `rb_ca_swap_bytes` — this file's CAByteSwap handles the residual
  cases (CA_FIXLEN with data_class field-recursive swap, bare
  fixlen buffers) that the monop kernel table does not cover.

---------------------------------------------------------------------------- */

#include "carray.h"
#include "ca_iter_substrate.h"  /* ca_xfer_stride_transform_fused */
#include "ca_monop_dispatch.h"  /* CA_MONOP_BYTE_SWAP dispatch id */
#include "ca_obj_face.h"        /* CA_FACE_LIFT_IF_FACE for CARecord parent */

/* CAStride family identification (used for fast-path eligibility). */
extern ca_operation_function_t ca_stride_func;

/* Reverse the byte order of each `bytes`-wide element in place.
   Element-local (no cross-element dependency), so the same routine
   serves both the internal recursion helper rb_ca_swap_bytes_bang
   and CAByteSwap's materialise — the caller just points it at the
   target buffer (self->ptr or a scratch). */
void
ca_swap_bytes (char *ptr, ca_size_t bytes, ca_size_t elements)
{
  char *p;
  char val;
  ca_size_t i;

#define SWAP_BYTE(a, b) (val = (a), (a) = (b), (b) = val)

  switch ( bytes ) {
  case 1:
    break;
  case 2:
    for (i=0; i<elements; i++) {
      p = ptr + 2*i;
      SWAP_BYTE(p[0], p[1]);
    }
    break;
  case 4:
    for (i=0; i<elements; i++) {
      p = ptr + 4*i;
      SWAP_BYTE(p[0], p[3]);
      SWAP_BYTE(p[1], p[2]);
    }
    break;
  case 8:
    for (i=0; i<elements; i++) {
      p = ptr + 8*i;
      SWAP_BYTE(p[0], p[7]);
      SWAP_BYTE(p[1], p[6]);
      SWAP_BYTE(p[2], p[5]);
      SWAP_BYTE(p[3], p[4]);
    }
    break;
  case 16:
    for (i=0; i<elements; i++) {
      p = ptr + 16*i;
      SWAP_BYTE(p[0], p[15]);
      SWAP_BYTE(p[1], p[14]);
      SWAP_BYTE(p[2], p[13]);
      SWAP_BYTE(p[3], p[12]);
      SWAP_BYTE(p[4], p[11]);
      SWAP_BYTE(p[5], p[10]);
      SWAP_BYTE(p[6], p[9]);
      SWAP_BYTE(p[7], p[8]);
    }
    break;
  default: {
    char *p1, *p2;
    for (i=0; i<elements; i++) {
      p = ptr + i*bytes;
      p1 = p;
      p2 = p+bytes-1;
      while (p1<p2) {
        SWAP_BYTE(*p1, *p2);
        p1++; p2--;
      }
    }
    break;
  }
  }

#undef SWAP_BYTE

}

/* Dispatch a byte-order swap of a buffer by data_type.  Complex
   types swap their two halves independently; everything else swaps
   `bytes`-wide elements directly.
 *
 * CAREFUL: CA_FIXLEN structs with a data_class are NOT handled
 * here — the caller must decompose them into their primitive
 * fields (see ca_byte_swap_apply / _one).
 *
 * extern-visible so CAMonOp(byte_swap) in ca_obj_monop.c can share
 * the same primitive for its writable lifecycle. */
void
ca_byte_swap_buffer (int8_t data_type, ca_size_t bytes, ca_size_t elements,
                     char *buf)
{
  switch ( data_type ) {
  case CA_CMPLX64:
    ca_swap_bytes(buf, 4, 2 * elements);
    break;
  case CA_CMPLX128:
    ca_swap_bytes(buf, 8, 2 * elements);
    break;
  default:
    ca_swap_bytes(buf, bytes, elements);
  }
}

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
  /* ----- tail (must be marked by dmark) ----- */
  VALUE     data_class;   /* parent's data_class, or Qnil if none.  Snapshot
                             at setup time so attach can do field-recursive
                             swap on CA_FIXLEN structs without access to a
                             Ruby self VALUE. */
} CAByteSwap;

static size_t
ca_byte_swap_dsize (const void *ap)
{
  const CAByteSwap *ca = (const CAByteSwap *) ap;
  return sizeof(CAByteSwap) + ca->ndim * sizeof(ca_size_t);
}

/* Pool framework hooks: single ndim-sized tail (dim) in the _pool
   buffer.  See ca_array_pool.c for the shared alloc/free discipline. */
static size_t
ca_byte_swap_pool_bytes (int8_t ndim)
{
  ca_size_t n = (ndim > 0) ? ndim : 1;
  return (size_t) n * sizeof(ca_size_t);
}

static void
ca_byte_swap_pool_init (void *ap, int8_t ndim)
{
  CAByteSwap *ca = (CAByteSwap *) ap;
  ca->dim = (ca_size_t *) ca->_pool;
}

/* Custom dmark: ca_mark walks the standard prefix; the data_class
   tail is a VALUE snapshot that must also be marked so the Class
   stays alive across GC while the view holds it. */
static void
ca_byte_swap_mark (void *ap)
{
  CAByteSwap *ca = (CAByteSwap *) ap;
  ca_mark(ca);
  rb_gc_mark(ca->data_class);
}

const rb_data_type_t cabyteswap_data_type = {
    .parent = &caview_data_type,
    .wrap_struct_name = "CAByteSwap",
    .function = {
        .dmark = ca_byte_swap_mark,
        .dfree = ca_free,
        .dsize = ca_byte_swap_dsize,
        .dcompact = NULL
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

static int8_t CA_OBJ_BYTE_SWAP;
VALUE rb_cCAByteSwap;

/* ------------------------------------------------------------------- */

int
ca_byte_swap_setup (CAByteSwap *ca, CArray *parent, VALUE data_class)
{
  CA_CHECK_DATA_TYPE(parent->data_type);

  if ( parent->data_type == CA_OBJECT ) {
    rb_raise(rb_eCADataTypeError, "object array can't be byte-swapped");
  }

  ca->obj_type  = CA_OBJ_BYTE_SWAP;
  ca->data_type = parent->data_type;
  ca->flags     = 0;
  ca->ndim      = parent->ndim;
  ca->bytes     = parent->bytes;
  ca->elements  = parent->elements;
  ca->ptr       = NULL;
  ca->mask      = NULL;
  if ( ! ca->_pool ) {
    ca->dim     = ALLOC_N(ca_size_t, ca->ndim);
  }
  memcpy(ca->dim, parent->dim, ca->ndim * sizeof(ca_size_t));

  ca->parent    = parent;
  ca->attach    = 0;
  ca->nosync    = 0;
  ca->data_class = data_class;   /* Qnil if parent has no data_class */

  if ( ca_has_mask(parent) ) {
    ca_create_mask(ca);
  }
  if ( ca_is_scalar(parent) ) {
    ca_set_flag(ca, CA_FLAG_SCALAR);
  }

  return 0;
}

CAByteSwap *
ca_byte_swap_new (CArray *parent, VALUE data_class)
{
  CAByteSwap *ca = (CAByteSwap *) ca_array_alloc(CA_OBJ_BYTE_SWAP, parent->ndim);
  ca_byte_swap_setup(ca, parent, data_class);
  return ca;
}

static void
free_ca_byte_swap (void *ap)
{
  CAByteSwap *ca = (CAByteSwap *) ap;
  if ( ca != NULL ) {
    ca_free(ca->mask);
    if ( ca->_pool ) {
      ca_array_free(ca);          /* dim lives in _pool */
    }
    else {
      xfree(ca->dim);
      xfree(ca);
    }
  }
}

/* ------------------------------------------------------------------- */

/* Apply the byte-swap transformation to a buffer in place.
   Three cases:
     - CA_FIXLEN + data_class: walk each record's fields recursively
       via a temporary CAWrap + rb_ca_swap_bytes_bang.
     - CA_CMPLX64 / CA_CMPLX128: swap each 4 / 8-byte half independently
       so the real / imaginary components are individually correct.
     - other primitives / bare fixlen: ca_swap_bytes(buf, bytes, elements). */
static void
ca_byte_swap_apply (CAByteSwap *ca, char *buf)
{
  if ( ca->data_type == CA_FIXLEN && RTEST(ca->data_class) ) {
    volatile VALUE wrap = rb_ca_wrap_new(CA_FIXLEN, ca->ndim, ca->dim,
                                         ca->bytes, NULL, buf);
    /* data_class travels on CARecord (Face), so wrap the transient
       into CARecord to let rb_ca_swap_bytes_bang see the fields. */
    wrap = rb_funcall(rb_const_get(rb_cObject, rb_intern("CARecord")),
                      rb_intern("wrap"), 2, wrap, ca->data_class);
    rb_ca_swap_bytes_bang(wrap);
    return;
  }
  ca_byte_swap_buffer(ca->data_type, ca->bytes, ca->elements, buf);
}

/* Swap a single element worth of bytes in place (for fetch / store /
   fill paths).  Always succeeds: CA_FIXLEN + data_class recurses via
   a transient CAWrap of width 1 (per-field swap, mirrors bulk path);
   bare FIXLEN does flat byte swap of one cell; primitives use their
   widths.  Per-cell paths never call ca_attach. */
static int
ca_byte_swap_apply_one (CAByteSwap *ca, char *buf)
{
  if ( ca->data_type == CA_FIXLEN && RTEST(ca->data_class) ) {
    ca_size_t one = 1;
    volatile VALUE wrap = rb_ca_wrap_new(CA_FIXLEN, 1, &one,
                                         ca->bytes, NULL, buf);
    /* Same CARecord-wrap trick as ca_byte_swap_apply, but for a
       single cell. */
    wrap = rb_funcall(rb_const_get(rb_cObject, rb_intern("CARecord")),
                      rb_intern("wrap"), 2, wrap, ca->data_class);
    rb_ca_swap_bytes_bang(wrap);
    return 1;
  }
  ca_byte_swap_buffer(ca->data_type, ca->bytes, 1, buf);
  return 1;
}

/* ------------------------------------------------------------------- */

static void *
ca_byte_swap_func_clone (void *ap)
{
  CAByteSwap *ca = (CAByteSwap *) ap;
  return ca_byte_swap_new(ca->parent, ca->data_class);
}

/* Per-cell get / put: fetch parent cell + swap into caller buffer
   (GET), or swap a caller copy + store it back (PUT).  Never calls
   ca_attach — the swap primitive works on any stack scratch. */
static void
ca_byte_swap_func_xfer_index (void *ap, ca_size_t *idx, void *data, int dir)
{
  CAByteSwap *ca = (CAByteSwap *) ap;
  if ( dir == CA_XFER_GET ) {
    ca_fetch_index(ca->parent, idx, data);
    ca_byte_swap_apply_one(ca, (char *) data);
  }
  else {
    char v[32];
    char *buf = (ca->bytes <= 32) ? v : xmalloc(ca->bytes);
    memcpy(buf, data, ca->bytes);
    ca_byte_swap_apply_one(ca, buf);
    ca_store_index(ca->parent, idx, buf);
    if ( buf != v ) xfree(buf);
  }
}

/* Batched gather / scatter.  CAByteSwap is 1:1 same-size with its
   parent, so the incoming address list is delivered as-is to the
   parent in one call; the byte swap is applied to the delivered
   buffer in place.  CA_FIXLEN + data_class cases swap field-
   recursively per cell; everything else uses the bulk primitive. */
static void
ca_byte_swap_func_xfer_addrs (void *ap, ca_size_t n, ca_size_t *addrs,
                              void *data, int dir)
{
  CAByteSwap *ca = (CAByteSwap *) ap;
  char      *d = (char *) data;
  int        is_struct = ( ca->data_type == CA_FIXLEN && RTEST(ca->data_class) );
  ca_size_t  i;

  if ( dir == CA_XFER_GET ) {
    ca_xfer_addrs(ca->parent, n, addrs, data, CA_XFER_GET);
    if ( is_struct ) {
      for (i = 0; i < n; i++) ca_byte_swap_apply_one(ca, d + i * ca->bytes);
    }
    else {
      ca_byte_swap_buffer(ca->data_type, ca->bytes, n, d);
    }
  }
  else {
    char *v;
    volatile VALUE holder;
    v = ALLOCV_N(char, holder, n * ca->bytes);
    memcpy(v, data, n * ca->bytes);
    if ( is_struct ) {
      for (i = 0; i < n; i++) ca_byte_swap_apply_one(ca, v + i * ca->bytes);
    }
    else {
      ca_byte_swap_buffer(ca->data_type, ca->bytes, n, v);
    }
    ca_xfer_addrs(ca->parent, n, addrs, v, CA_XFER_PUT);
    ALLOCV_END(holder);
  }
}

/* CAByteSwap is a never-fold transform boundary that is size-
   preserving (parent.bytes == view.bytes), so the incoming region
   recurses through parent.xfer_stride and the swap is applied to
   the contiguous delivered buffer.  Parent's own stride chain
   folds to entity inside the recursive call, so this file does not
   attach the parent directly. */

/* Per-row byte-swap transform callbacks for the shared fused
   xfer_stride helper.  src and dst share the same bytes (view is
   size-preserving), so a plain memcpy + ca_byte_swap_buffer in
   place is enough. */
static void
ca_byte_swap_xform_get (ca_size_t n, CArray *src_arr, char *src_row,
                        CArray *dst_arr, char *dst_row)
{
  CAByteSwap *cb = (CAByteSwap *) dst_arr;
  memcpy(dst_row, src_row, n * cb->bytes);
  ca_byte_swap_buffer(cb->data_type, cb->bytes, n, dst_row);
}

static void
ca_byte_swap_xform_put (ca_size_t n, CArray *src_arr, char *src_row,
                        CArray *dst_arr, char *dst_row)
{
  CAByteSwap *cb = (CAByteSwap *) src_arr;
  memcpy(dst_row, src_row, n * cb->bytes);
  ca_byte_swap_buffer(cb->data_type, cb->bytes, n, dst_row);
}

/* Fast path (non-struct): compose-fold walk with per-row byte
   swap, no scratch for the whole region.  CA_FIXLEN + data_class
   cases fall back to the scratch-and-swap 2-pass because they need
   per-cell field-recursive swap that the fused helper cannot
   express. */
static void
ca_byte_swap_func_xfer_stride (void *ap, ca_size_t *starts, ca_size_t *counts,
                               ca_size_t *strides, void *data, int dir)
{
  CAByteSwap *ca = (CAByteSwap *) ap;
  char      *d = (char *) data;
  int        is_struct = ( ca->data_type == CA_FIXLEN && RTEST(ca->data_class) );
  ca_size_t  n = 1, i;
  int8_t     k;

  if ( !is_struct ) {
    if ( ca_xfer_stride_transform_fused((CArray *)ca, ca->parent,
                                         starts, counts, strides,
                                         d, dir,
                                         ca_byte_swap_xform_get,
                                         ca_byte_swap_xform_put) ) {
      return;
    }
  }

  /* Fallback scratch-and-swap 2-pass (handles struct case + cold
     boundary parents). */
  for ( k = 0; k < ca->ndim; k++ ) n *= counts[k];
  if ( dir == CA_XFER_GET ) {
    ca_xfer_stride(ca->parent, starts, counts, strides, data, CA_XFER_GET);
    if ( is_struct ) {
      for (i = 0; i < n; i++) ca_byte_swap_apply_one(ca, d + i * ca->bytes);
    }
    else {
      ca_byte_swap_buffer(ca->data_type, ca->bytes, n, d);
    }
  }
  else {
    char *v;
    volatile VALUE holder;
    v = ALLOCV_N(char, holder, n * ca->bytes);
    memcpy(v, data, n * ca->bytes);
    if ( is_struct ) {
      for (i = 0; i < n; i++) ca_byte_swap_apply_one(ca, v + i * ca->bytes);
    }
    else {
      ca_byte_swap_buffer(ca->data_type, ca->bytes, n, v);
    }
    ca_xfer_stride(ca->parent, starts, counts, strides, v, CA_XFER_PUT);
    ALLOCV_END(holder);
  }
}

static void
ca_byte_swap_func_allocate (void *ap)
{
  CAByteSwap *ca = (CAByteSwap *) ap;
  ca_attach(ca->parent);
  ca->ptr = xmalloc(ca_length(ca));
}

static void
ca_byte_swap_func_attach (void *ap)
{
  CAByteSwap *ca = (CAByteSwap *) ap;
  ca_attach(ca->parent);
  ca->ptr = xmalloc(ca_length(ca));
  memcpy(ca->ptr, ca->parent->ptr, ca_length(ca));
  ca_byte_swap_apply(ca, ca->ptr);
}

static void
ca_byte_swap_func_sync (void *ap)
{
  CAByteSwap *ca = (CAByteSwap *) ap;
  /* Swap is involutive, so applying it once to the view buffer
     restores the parent byte order before the copy-back. */
  ca_byte_swap_apply(ca, ca->ptr);
  memcpy(ca->parent->ptr, ca->ptr, ca_length(ca));
  ca_sync(ca->parent);
}

static void
ca_byte_swap_func_detach (void *ap)
{
  CAByteSwap *ca = (CAByteSwap *) ap;
  xfree(ca->ptr);
  ca->ptr = NULL;
  ca_detach(ca->parent);
}

/* Whole-view transfer as a thin wrapper around xfer_stride.
   Deliberately does not call ca_attach(parent) — the underlying
   xfer_stride reaches the parent through the fused helper (or,
   for cold non-CAStride parents, its own scratch-and-swap 2-pass)
   without needing a whole-view attach here. */
static void
ca_byte_swap_func_xfer_all (void *ap, void *data, int dir)
{
  CAByteSwap *ca = (CAByteSwap *) ap;
  ca_size_t   starts[CA_RANK_MAX];
  ca_size_t   native[CA_RANK_MAX];
  int8_t      k;
  ca_size_t   s = ca->bytes;
  for ( k = ca->ndim - 1; k >= 0; k-- ) { native[k] = s; s *= ca->dim[k]; }
  for ( k = 0; k < ca->ndim; k++ ) starts[k] = 0;
  ca_xfer_stride(ca, starts, ca->dim, native, data, dir);
}

static void
ca_byte_swap_func_fill_data (void *ap, void *ptr)
{
  CAByteSwap *ca = (CAByteSwap *) ap;
  char v[32];
  char *buf = (ca->bytes <= 32) ? v : xmalloc(ca->bytes);
  memcpy(buf, ptr, ca->bytes);
  if ( !ca_byte_swap_apply_one(ca, buf) ) {
    /* Bare CA_FIXLEN fill: broadcast the raw bytes into the view
       buffer through attach/sync so the parent sees the correct
       byte order after mapping back. */
    ca_attach(ca);
    {
      ca_size_t i;
      for (i = 0; i < ca->elements; i++) {
        memcpy(ca->ptr + i * ca->bytes, ptr, ca->bytes);
      }
    }
    ca_sync(ca);
    ca_detach(ca);
    if ( buf != v ) xfree(buf);
    return;
  }
  ca_fill(ca->parent, buf);
  if ( buf != v ) xfree(buf);
}

/* fill_data with a region.  Swapping is per value, not per cell, so the one
   value is swapped once and the region passes to the parent as it stands --
   a swap view reorders bytes within a cell, never cells within the array, so
   its addresses are the parent's.  A bare CA_FIXLEN has no swap to apply and
   falls to the per-cell walk, which at least stays inside the region. */

static void
ca_byte_swap_func_fill_stride (void *ap, ca_size_t base, int8_t ndim,
                               ca_size_t *counts, ca_size_t *steps, void *ptr)
{
  CAByteSwap *ca = (CAByteSwap *) ap;
  char v[32];
  char *buf = (ca->bytes <= 32) ? v : xmalloc(ca->bytes);
  memcpy(buf, ptr, ca->bytes);
  if ( ca_byte_swap_apply_one(ca, buf) ) {
    ca_fill_stride(ca->parent, base, ndim, counts, steps, buf);
  }
  else {
    ca_fill_stride_default(ca, base, ndim, counts, steps, ptr);
  }
  if ( buf != v ) xfree(buf);
}

static void
ca_byte_swap_func_fill_addrs (void *ap, ca_size_t n, ca_size_t *addrs,
                              void *ptr)
{
  CAByteSwap *ca = (CAByteSwap *) ap;
  char v[32];
  char *buf = (ca->bytes <= 32) ? v : xmalloc(ca->bytes);
  memcpy(buf, ptr, ca->bytes);
  if ( ca_byte_swap_apply_one(ca, buf) ) {
    ca_fill_addrs(ca->parent, n, addrs, buf);
  }
  else {
    ca_fill_addrs_default(ca, n, addrs, ptr);
  }
  if ( buf != v ) xfree(buf);
}

static void
ca_byte_swap_func_create_mask (void *ap)
{
  CAByteSwap *ca = (CAByteSwap *) ap;
  ca_update_mask(ca->parent);
  if ( ! ca->parent->mask ) {
    ca_create_mask(ca->parent);
  }
  /* Mask is byte-wide (boolean), so the swap is a no-op for the
     mask itself.  Share the parent's mask via a CARefer to keep the
     two in lockstep. */
  ca->mask =
    (CArray *) ca_refer_new(ca->parent->mask,
                            CA_BOOLEAN, ca->ndim, ca->dim, 0, 0);
}

ca_operation_function_t ca_byte_swap_func = {
  -1, /* CA_OBJ_BYTE_SWAP */
  CA_VIEW_ARRAY,
  free_ca_byte_swap,
  ca_byte_swap_func_clone,
  ca_byte_swap_func_allocate,
  ca_byte_swap_func_attach,
  ca_byte_swap_func_sync,
  ca_byte_swap_func_detach,
  ca_byte_swap_func_fill_data,
  ca_byte_swap_func_create_mask,
  ca_byte_swap_func_xfer_index,
  ca_byte_swap_func_xfer_addrs,
  NULL,                       /* fold_stride: never fold — value-conversion boundary */
  ca_byte_swap_func_xfer_stride,
  ca_byte_swap_func_xfer_all,
  .fill_addrs   = ca_byte_swap_func_fill_addrs,
  .fill_stride  = ca_byte_swap_func_fill_stride,
};

/* ------------------------------------------------------------------- */

/* Defined in ca_obj_monop.c (single-op CAMonOp builder).
   Called below for primitive-numeric byte swap. */
extern VALUE rb_ca_monop_build (VALUE cary, uint16_t op_id);

VALUE
rb_ca_byte_swap_new (VALUE cary)
{
  volatile VALUE obj, data_class;
  CArray *parent;
  CAByteSwap *ca;
  rb_check_carray_object(cary);
  TypedData_Get_Struct(cary, CArray, &carray_data_type, parent);

  /* Primitive numeric routes to CAMonOp(byte_swap), which owns the
     numeric byte_swap kernel and its writable lifecycle.  CAByteSwap
     handles the residual cases the monop kernel table does not
     cover: CA_FIXLEN with data_class (field-recursive swap needs a
     Ruby callback), bare CA_FIXLEN (variable bytes-per-cell), and
     CA_OBJECT (rejected in setup). */
  if ( parent->data_type != CA_FIXLEN && parent->data_type != CA_OBJECT ) {
    return rb_ca_monop_build(cary, CA_MONOP_BYTE_SWAP);
  }

  /* Snapshot data_class (or Qnil) so attach can do the field-
     recursive swap without needing to resolve `self` again. */
  data_class = rb_ca_data_class(cary);
  ca  = ca_byte_swap_new(parent, data_class);
  obj = ca_wrap_struct(ca);
  rb_ca_set_parent(obj, cary);
  /* Lift back into a Face when `self` is a CARecord so field
     projection and data_class queries keep working through the
     swap_bytes view. */
  CA_FACE_LIFT_IF_FACE(obj, cary, parent);
  return obj;
}

static VALUE
rb_ca_byte_swap_s_allocate (VALUE klass)
{
  CAByteSwap *ca;
  return TypedData_Make_Struct(klass, CAByteSwap, &cabyteswap_data_type, ca);
}

static VALUE
rb_ca_byte_swap_initialize_copy (VALUE self, VALUE other)
{
  CAByteSwap *ca, *cs;
  TypedData_Get_Struct(self,  CAByteSwap, &cabyteswap_data_type, ca);
  TypedData_Get_Struct(other, CAByteSwap, &cabyteswap_data_type, cs);
  if ( ca_func[CA_OBJ_BYTE_SWAP].pool_init ) {
    ca_array_pool_alloc(ca, CA_OBJ_BYTE_SWAP, cs->parent->ndim);
  }
  ca_byte_swap_setup(ca, cs->parent, cs->data_class);
  return self;
}

/* CArray#swap_bytes — lazy CAByteSwap (or CAMonOp for primitive
   numeric) view whose cells are byte-swapped versions of self's
   cells; materialises on attach. */
VALUE
rb_ca_swap_bytes (VALUE self)
{
  return rb_ca_byte_swap_new(self);
}

/* CArray#endian(byte_order) — returns a view of self in the
   requested byte order.  Accepts :preserve / :native (both
   identity, since CArrays are stored host-endian), :big (identity
   on big-endian hosts, otherwise a byte-swap view), or :little
   (identity on little-endian hosts, otherwise a byte-swap view).
   The keyword set matches bulk-memory-view's
   `BulkMemoryView.from(producer, endian:)`. */
VALUE
rb_ca_endian (VALUE self, VALUE byte_order)
{
  ID sym;
  if ( !SYMBOL_P(byte_order) ) {
    rb_raise(rb_eArgError,
             "endian: must be :preserve, :native, :big, or :little");
  }
  sym = SYM2ID(byte_order);
  if ( sym == rb_intern("preserve") || sym == rb_intern("native") ) {
    return self;
  }
  if ( sym == rb_intern("big") ) {
    return (ca_endian == CA_BIG_ENDIAN) ? self : rb_ca_byte_swap_new(self);
  }
  if ( sym == rb_intern("little") ) {
    return (ca_endian == CA_LITTLE_ENDIAN) ? self : rb_ca_byte_swap_new(self);
  }
  rb_raise(rb_eArgError,
           "endian: must be :preserve, :native, :big, or :little");
}

/* Internal recursion helper for the bulk byte-swap path.  Not
   exposed as a Ruby method; the CA_FIXLEN + data_class branches in
   ca_byte_swap_apply / _one call this to walk into each field of a
   struct. */
VALUE
rb_ca_swap_bytes_bang (VALUE self)
{
  CArray *ca;

  rb_check_frozen(self);

  if ( rb_ca_is_object_type(self) ) {
    rb_raise(rb_eCADataTypeError, "object array can't swap bytes");
  }

  /* CA_FIXLEN with a data_class: decompose into its fields and swap each
     (the field views write back to self). */
  if ( rb_ca_is_fixlen_type(self) && rb_ca_has_data_class(self) ) {
    volatile VALUE members = rb_ca_fields(self);
    int i;
    Check_Type(members, T_ARRAY);
    for (i=0; i<RARRAY_LEN(members); i++) {
      rb_ca_swap_bytes_bang(rb_ary_entry(members, i));
    }
    return self;
  }

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  ca_attach(ca);
  ca_byte_swap_buffer(ca->data_type, ca->bytes, ca->elements, ca->ptr);
  ca_sync(ca);
  ca_detach(ca);
  return self;
}

void
Init_ca_obj_byte_swap (void)
{
  rb_cCAByteSwap = rb_define_class("CAByteSwap", rb_cCAView);

  ca_byte_swap_func.struct_size = sizeof(CAByteSwap);
  ca_byte_swap_func.pool_bytes  = ca_byte_swap_pool_bytes;
  ca_byte_swap_func.pool_init   = ca_byte_swap_pool_init;

  CA_OBJ_BYTE_SWAP = ca_install_obj_type(rb_cCAByteSwap,
                                          &cabyteswap_data_type,
                                          rb_cCArrayMask,
                                          &carray_mask_data_type,
                                          &ca_byte_swap_func, sizeof(ca_byte_swap_func));
  rb_define_const(rb_cObject, "CA_OBJ_BYTE_SWAP", INT2NUM(CA_OBJ_BYTE_SWAP));

  rb_define_method(rb_cCArray, "swap_bytes",  rb_ca_swap_bytes, 0);
  /* `swap_bytes!` intentionally absent; the in-place idiom is
     `ca[] = ca.swap_bytes`. */
  rb_define_method(rb_cCArray, "endian",      rb_ca_endian, 1);

  rb_define_alloc_func(rb_cCAByteSwap, rb_ca_byte_swap_s_allocate);
  rb_define_method(rb_cCAByteSwap, "initialize_copy",
                                      rb_ca_byte_swap_initialize_copy, 1);
}
