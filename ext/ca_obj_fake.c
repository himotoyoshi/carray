/* ---------------------------------------------------------------------------

  CAFake — data_type reinterpret / cast view.  Presents self.parent with
  a different data_type (and possibly bytes), casting values on read
  and write via ca_cast_block.  Ruby surface: CArray#fake (see
  yard-stubs).

---------------------------------------------------------------------------- */

#include "carray.h"
#include "carray_internal.h"   /* per-obj_type view constructors */
#include "ca_iter_substrate.h"   /* ca_xfer_stride_transform_fused */

extern ca_operation_function_t ca_stride_func;

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
} CAFake;

static size_t
ca_fake_dsize (const void *ap)
{
  const CAFake *ca = (const CAFake *) ap;
  return sizeof(CAFake) + ca->ndim * sizeof(ca_size_t);
}

/* Pool framework hooks: single ndim-sized tail (dim) in the _pool
   buffer, uniform with the other pool-migrated views. */
static size_t
ca_fake_pool_bytes (int8_t ndim)
{
  ca_size_t n = (ndim > 0) ? ndim : 1;
  return (size_t) n * sizeof(ca_size_t);
}

static void
ca_fake_pool_init (void *ap, int8_t ndim)
{
  CAFake *ca = (CAFake *) ap;
  ca->dim = (ca_size_t *) ca->_pool;
}

const rb_data_type_t cafake_data_type = {
    .parent = &caview_data_type,
    .wrap_struct_name = "CAFake",
    .function = {
        .dmark = ca_mark,
        .dfree = ca_free,
        .dsize = ca_fake_dsize,
        .dcompact = NULL
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

static int8_t CA_OBJ_FAKE;

static VALUE rb_cCAFake;

/* ------------------------------------------------------------------- */

int
ca_fake_setup (CAFake *ca, CArray *parent, int8_t data_type, ca_size_t bytes)
{
  int8_t ndim;
  ca_size_t *dim, elements;

  /* check arguments */

  CA_CHECK_DATA_TYPE(data_type);
  CA_CHECK_BYTES(data_type, bytes);

  ndim     = parent->ndim;
  dim      = parent->dim;
  elements = parent->elements;

  ca->obj_type  = CA_OBJ_FAKE;
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

  memcpy(ca->dim, dim, ndim * sizeof(ca_size_t));

  if ( ca_has_mask(parent) ) {
    ca_create_mask(ca);
  }

  if ( ca_is_scalar(parent) ) {
    ca_set_flag(ca, CA_FLAG_SCALAR);
  }

  return 0;
}

CAFake *
ca_fake_new (CArray *parent, int8_t data_type, ca_size_t bytes)
{
  CAFake *ca = (CAFake *) ca_array_alloc(CA_OBJ_FAKE, parent->ndim);
  ca_fake_setup(ca, parent, data_type, bytes);
  return ca;
}

static void
free_ca_fake (void *ap)
{
  CAFake *ca = (CAFake *) ap;
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

static void *
ca_fake_func_clone (void *ap)
{
  CAFake *ca = (CAFake *) ap;
  return ca_fake_new(ca->parent, ca->data_type, ca->bytes);
}

/* Per-cell GET/PUT via a parent-sized scratch cell — same code services
   both directions, casting through the parent data_type. */
static void
ca_fake_func_xfer_index (void *ap, ca_size_t *idx, void *data, int dir)
{
  CAFake *ca = (CAFake *) ap;
  char sbuf[32];
  char *v = (ca->parent->bytes <= 32) ? sbuf : xmalloc(ca->parent->bytes);
  if ( dir == CA_XFER_GET ) {
    ca_fetch_index(ca->parent, idx, v);
    ca_ptr2ptr(ca->parent, v, ca, data);
  }
  else {
    ca_ptr2ptr(ca, data, ca->parent, v);
    ca_store_index(ca->parent, idx, v);
  }
  if ( v != sbuf ) xfree(v);
}

/* Batched address gather/scatter.  CAFake is a 1:1 reinterpret-cast
   view, so its flat addr equals the parent's — the same addr list is
   handed to the parent in one call and the data_type cast is applied
   in flight over a parent-data_type scratch. */
static void
ca_fake_func_xfer_addrs (void *ap, ca_size_t n, ca_size_t *addrs,
                         void *data, int dir)
{
  CAFake *ca = (CAFake *) ap;
  CArray *parent = ca->parent;
  CArray *eff;
  ca_size_t base;
  char   *v;
  volatile VALUE holder;

  /* Sequential-run + live-ptr fast path: cast directly from
     parent->ptr + base*pbytes to data, no intermediate scratch. */
  eff = ca_resolve_attached_root_via_identity(parent);
  if ( eff->ptr && ca_xfer_addrs_is_sequential_run(n, addrs, &base) ) {
    char *p = eff->ptr + base * eff->bytes;
    if ( dir == CA_XFER_GET ) {
      ca_cast_block(n, eff, p, (CArray *) ca, data);
    } else {
      ca_cast_block(n, (CArray *) ca, data, eff, p);
    }
    return;
  }

  /* Fallback 2-pass (arbitrary addrs, non-identity parent): allocate
     a parent-data_type scratch and gather/cast via parent.xfer_addrs. */
  v = ALLOCV_N(char, holder, n * parent->bytes);
  if ( dir == CA_XFER_GET ) {
    ca_xfer_addrs(parent, n, addrs, v, CA_XFER_GET);
    ca_cast_block(n, parent, v, ca, data);
  }
  else {
    ca_cast_block(n, ca, data, parent, v);
    ca_xfer_addrs(parent, n, addrs, v, CA_XFER_PUT);
  }
  ALLOCV_END(holder);
}

/* Per-row transform callbacks for the fused-walk fast path.  CAFake
   is a byte-aligned data_type cast in both directions, so xform_get /
   xform_put are thin ca_cast_block wrappers with swapped src/dst
   array roles. */
static void
ca_fake_xform_get (ca_size_t n, CArray *src_arr, char *src_row,
                   CArray *dst_arr, char *dst_row)
{
  ca_cast_block(n, src_arr, src_row, dst_arr, dst_row);
}

static void
ca_fake_xform_put (ca_size_t n, CArray *src_arr, char *src_row,
                   CArray *dst_arr, char *dst_row)
{
  ca_cast_block(n, src_arr, src_row, dst_arr, dst_row);
}

/* xfer_stride — try the fused walk + cast fast path (compose the
   parent chain to its root, gather the inner row from root.ptr
   strided into a row scratch, cast to dst in one pass).  Falls back
   to the scratch + cast 2-pass when eligibility fails (non-CAStride
   parent, cold root, byte-mismatch reinterpret).  Mask is not
   consulted here — it propagates on a separate channel. */
static void
ca_fake_func_xfer_stride (void *ap, ca_size_t *starts, ca_size_t *counts,
                          ca_size_t *strides, void *data, int dir)
{
  CAFake   *ca = (CAFake *) ap;
  int8_t    ndim = ca->ndim;
  ca_size_t pstrides[CA_RANK_MAX];
  ca_size_t n = 1;
  int8_t    k;
  char     *v;
  volatile VALUE holder;

  /* Fast path: fused walk + cast for GET/PUT */
  if ( ca_xfer_stride_transform_fused((CArray *)ca, ca->parent,
                                       starts, counts, strides,
                                       (char *)data, dir,
                                       ca_fake_xform_get,
                                       ca_fake_xform_put) ) {
    return;
  }

  /* Fallback: legacy scratch + cast_block 2-pass */
  for ( k = 0; k < ndim; k++ ) {
    n *= counts[k];
    pstrides[k] = strides[k] / ca->bytes * ca->parent->bytes;
  }
  v = ALLOCV_N(char, holder, n * ca->parent->bytes);
  if ( dir == CA_XFER_GET ) {
    ca_xfer_stride(ca->parent, starts, counts, pstrides, v, CA_XFER_GET);
    ca_cast_block(n, ca->parent, v, ca, data);
  }
  else {
    ca_cast_block(n, ca, data, ca->parent, v);
    ca_xfer_stride(ca->parent, starts, counts, pstrides, v, CA_XFER_PUT);
  }
  ALLOCV_END(holder);
}

static void
ca_fake_func_allocate (void *ap)
{
  CAFake *ca = (CAFake *) ap;
  ca_attach(ca->parent);
  ca->ptr = xmalloc(ca_length(ca));

  /* CAREFUL: CA_OBJECT storage must contain valid VALUEs before GC can
     scan it, so seed with Fixnum 0 rather than leaving raw xmalloc bytes. */
  if ( ca->data_type == CA_OBJECT ) {
    VALUE *p = (VALUE *) ca->ptr;
    VALUE zero = SIZE2NUM(0);
    ca_size_t i;
    for (i=0; i<ca->elements; i++) {
      *p++ = zero;
    }
  }
}

static void
ca_fake_func_attach (void *ap)
{
  CAFake *ca = (CAFake *) ap;
  ca_attach(ca->parent);
  ca->ptr = xmalloc(ca_length(ca));

  /* CAREFUL: same VALUE-seed rule as ca_fake_func_allocate. */
  if ( ca->data_type == CA_OBJECT ) {
    VALUE *p = (VALUE *) ca->ptr;
    VALUE zero = SIZE2NUM(0);
    ca_size_t i;
    for (i=0; i<ca->elements; i++) {
      *p++ = zero;
    }
  }

  if ( ca->parent->mask ) {
    ca_cast_block_with_mask(ca->elements, ca->parent, ca->parent->ptr, 
                            ca, ca->ptr, 
                            (boolean8_t*)ca->parent->mask->ptr);
  }
  else {
    ca_cast_block(ca->elements, ca->parent, ca->parent->ptr, ca, ca->ptr);
  }
}

static void
ca_fake_func_sync (void *ap)
{
  CAFake *ca = (CAFake *) ap;
  ca_update_mask(ca);
  if ( ca->mask ) {
    ca_cast_block_with_mask(ca->elements, ca, ca->ptr, ca->parent, ca->parent->ptr, 
                            (boolean8_t *)ca->parent->mask->ptr);
  }
  else {
    ca_cast_block(ca->elements, ca, ca->ptr, ca->parent, ca->parent->ptr);
  }
  ca_sync(ca->parent);
}

static void
ca_fake_func_detach (void *ap)
{
  CAFake *ca = (CAFake *) ap;
  xfree(ca->ptr);
  ca->ptr = NULL;
  ca_detach(ca->parent);
}

/* Thin wrapper around xfer_stride that walks native row-major
   strides.  xfer_stride itself picks the right rung via
   ca_xfer_stride_transform_fused:
     CAStride family parent            fused walk + cast in one pass
     Non-CAStride parent with live ptr fused via linear stride math
     Cold non-CAStride parent          scratch + xfer_stride + cast fallback */
static void
ca_fake_func_xfer_all (void *ap, void *data, int dir)
{
  CAFake   *ca = (CAFake *) ap;
  ca_size_t starts[CA_RANK_MAX];
  ca_size_t native[CA_RANK_MAX];
  int8_t    k;
  ca_size_t s = ca->bytes;
  for ( k = ca->ndim - 1; k >= 0; k-- ) { native[k] = s; s *= ca->dim[k]; }
  for ( k = 0; k < ca->ndim; k++ ) starts[k] = 0;
  ca_xfer_stride(ca, starts, ca->dim, native, data, dir);
}


static void
ca_fake_func_fill_data (void *ap, void *ptr)
{
  CAFake *ca = (CAFake *) ap;
  if ( ca->parent->bytes <= 32 ) {
    char v[32];
    ca_ptr2ptr(ca, ptr, ca->parent, v);
    ca_fill(ca->parent, v);
  }
  else {
    char *v = xmalloc(ca->parent->bytes);
    ca_ptr2ptr(ca, ptr, ca->parent, v);
    ca_fill(ca->parent, v);
    xfree(v);
  }
}

/* Same as fill_data, with a region: convert the one value once and pass the
   region on unchanged.  A fake reinterprets the type, not the shape, so its
   addresses are its parent's addresses and there is nothing to translate --
   which is the whole reason a partial fill through a lossy cast need not read
   anything back. */

static void
ca_fake_func_fill_stride (void *ap, ca_size_t base, int8_t ndim,
                          ca_size_t *counts, ca_size_t *steps, void *ptr)
{
  CAFake *ca = (CAFake *) ap;
  if ( ca->parent->bytes <= 32 ) {
    char v[32];
    ca_ptr2ptr(ca, ptr, ca->parent, v);
    ca_fill_stride(ca->parent, base, ndim, counts, steps, v);
  }
  else {
    char *v = xmalloc(ca->parent->bytes);
    ca_ptr2ptr(ca, ptr, ca->parent, v);
    ca_fill_stride(ca->parent, base, ndim, counts, steps, v);
    xfree(v);
  }
}

static void
ca_fake_func_fill_addrs (void *ap, ca_size_t n, ca_size_t *addrs, void *ptr)
{
  CAFake *ca = (CAFake *) ap;
  if ( ca->parent->bytes <= 32 ) {
    char v[32];
    ca_ptr2ptr(ca, ptr, ca->parent, v);
    ca_fill_addrs(ca->parent, n, addrs, v);
  }
  else {
    char *v = xmalloc(ca->parent->bytes);
    ca_ptr2ptr(ca, ptr, ca->parent, v);
    ca_fill_addrs(ca->parent, n, addrs, v);
    xfree(v);
  }
}

static void
ca_fake_func_create_mask (void *ap)
{
  CAFake *ca = (CAFake *) ap;
  ca_update_mask(ca->parent);
  if ( ! ca->parent->mask ) {
    ca_create_mask(ca->parent);
  }
  ca->mask =
    (CArray *) ca_refer_new(ca->parent->mask,
                            CA_BOOLEAN, ca->ndim, ca->dim, 0, 0);
}

ca_operation_function_t ca_fake_func = {
  -1, /* CA_OBJ_FAKE */
  CA_VIEW_ARRAY,
  free_ca_fake,
  ca_fake_func_clone,
  ca_fake_func_allocate,
  ca_fake_func_attach,
  ca_fake_func_sync,
  ca_fake_func_detach,
  ca_fake_func_fill_data,
  ca_fake_func_create_mask,
  ca_fake_func_xfer_index,
  ca_fake_func_xfer_addrs,
  NULL,                       /* fold_stride: never-fold (transform boundary) */
  ca_fake_func_xfer_stride,
  ca_fake_func_xfer_all,
  .fill_addrs   = ca_fake_func_fill_addrs,
  .fill_stride  = ca_fake_func_fill_stride,
};

/* ------------------------------------------------------------------- */

VALUE
rb_ca_fake_new (VALUE cary, int8_t data_type, ca_size_t bytes)
{
  volatile VALUE obj;
  CArray *parent;
  CAFake *ca;
  rb_check_carray_object(cary);
  TypedData_Get_Struct(cary, CArray, &carray_data_type, parent);
  if ( ca_is_face(parent) && ( data_type == CA_OBJECT
                               || parent->data_type == CA_FIXLEN ) ) {
    /* A Face's cells do not mean their storage bytes, so reading them
       under another data_type hands back what the surface exists to hide.
       Both ways down stay open and say which one they are.  A Numeric Face
       is not one of these: its surface is its storage. */
    rb_raise(rb_eTypeError,
             "%s has no view of its values in another data_type: "
             "#to_type gives the values, #parent.fake the raw storage",
             rb_obj_classname(cary));
  }
  ca  = ca_fake_new(parent, data_type, bytes);
  obj = ca_wrap_struct(ca);
  rb_ca_set_parent(obj, cary);
  return obj;
}

/* CArray#fake(data_type, bytes: 0) — return a CAFake view of self that
 * reinterprets each cell as the given data_type (fixlen needs `bytes:`).
 * Storage is shared with self via ca_cast_block on read/write. */
VALUE
rb_ca_fake (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE obj, rtype, ropt, rbytes = Qnil;
  int8_t  data_type;
  ca_size_t bytes;

  rb_scan_args(argc, argv, "11", (VALUE *) &rtype, (VALUE *) &ropt);
  rb_scan_options(ropt, "bytes", &rbytes);

  rb_ca_guess_type_and_bytes(rtype, rbytes, &data_type, &bytes);
  obj = rb_ca_fake_new(self, data_type, bytes);

  return obj;
}

VALUE
rb_ca_fake_type (VALUE self, VALUE rtype, VALUE rbytes)
{
  volatile VALUE obj;
  int8_t  data_type;
  ca_size_t bytes;
  rb_ca_guess_type_and_bytes(rtype, rbytes, &data_type, &bytes);
  obj = rb_ca_fake_new(self, data_type, bytes);
  return obj;
}

static VALUE
rb_ca_fake_s_allocate (VALUE klass)
{
  CAFake *ca;
  return TypedData_Make_Struct(klass, CAFake, &cafake_data_type, ca);
}

static VALUE
rb_ca_fake_initialize_copy (VALUE self, VALUE other)
{
  CAFake *ca, *cs;

  TypedData_Get_Struct(self,  CAFake, &cafake_data_type, ca);
  TypedData_Get_Struct(other, CAFake, &cafake_data_type, cs);

  if ( ca_func[CA_OBJ_FAKE].pool_init ) {
    ca_array_pool_alloc(ca, CA_OBJ_FAKE, cs->parent->ndim);
  }
  ca_fake_setup(ca, cs->parent, cs->data_type, cs->bytes);

  return self;
}

void
Init_ca_obj_fake (void)
{
  rb_cCAFake = rb_define_class("CAFake", rb_cCAView);

  ca_fake_func.struct_size = sizeof(CAFake);
  ca_fake_func.pool_bytes  = ca_fake_pool_bytes;
  ca_fake_func.pool_init   = ca_fake_pool_init;

  CA_OBJ_FAKE = ca_install_obj_type(rb_cCAFake,
                                    &cafake_data_type,
				    rb_cCArrayMask,
				    &carray_mask_data_type, &ca_fake_func, sizeof(ca_fake_func));
  rb_define_const(rb_cObject, "CA_OBJ_FAKE", INT2NUM(CA_OBJ_FAKE));

  rb_define_method(rb_cCArray, "fake", rb_ca_fake, -1);

  rb_define_alloc_func(rb_cCAFake, rb_ca_fake_s_allocate);
  rb_define_method(rb_cCAFake, "initialize_copy",
                                      rb_ca_fake_initialize_copy, 1);
}


