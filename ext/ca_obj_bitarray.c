/* ---------------------------------------------------------------------------

  CABitarray view: fan every parent cell out into 8 * parent->bytes
  boolean cells, one per bit.  The view adds a trailing bit axis of
  length `bitlen = parent->bytes * 8` after the parent's own axes.

  Big-endian hosts (non-fixlen parents only) walk parent bytes in
  reverse within each element so the bit axis reflects network byte
  order regardless of host endianness.  Single-byte parents are
  linear in either case.

---------------------------------------------------------------------------- */

#include "carray.h"
#include "carray_internal.h"   /* ca_bit_pack / ca_bit_unpack */

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
  ca_size_t   bytelen;
  ca_size_t   bitlen;
} CABitarray;

static size_t
ca_bitarray_dsize (const void *ap)
{
  const CABitarray *ca = (const CABitarray *) ap;
  return sizeof(CABitarray) + ca->ndim * sizeof(ca_size_t);
}

/* Pool framework hooks: single ndim-sized tail (dim) in the _pool
   buffer.  See ca_array_pool.c for the shared alloc/free discipline.
   CABitarray's ndim is parent->ndim + 1 (the trailing bit axis). */
static size_t
ca_bitarray_pool_bytes (int8_t ndim)
{
  ca_size_t n = (ndim > 0) ? ndim : 1;
  return (size_t) n * sizeof(ca_size_t);
}

static void
ca_bitarray_pool_init (void *ap, int8_t ndim)
{
  CABitarray *ca = (CABitarray *) ap;
  ca->dim = (ca_size_t *) ca->_pool;
}

const rb_data_type_t cabitarray_data_type = {
    .parent = &caview_data_type,
    .wrap_struct_name = "CABitarray",
    .function = {
        .dmark = ca_mark,
        .dfree = ca_free,
        .dsize = ca_bitarray_dsize,
        .dcompact = NULL
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

static int8_t CA_OBJ_BITARRAY;

static VALUE rb_cCABitarray;

static uint8_t bits[8] = {
  1,
  2,
  4,
  8,
  16,
  32,
  64,
  128
};

/* ------------------------------------------------------------------- */

int
ca_bitarray_setup (CABitarray *ca, CArray *parent)
{
  int8_t ndim;
  ca_size_t bitlen, elements;

  if ( ca_is_complex_type(parent) || ( ca_is_object_type(parent) ) ) {
    rb_raise(rb_eCADataTypeError, "invalid data_type for bitarray");
  }

  ndim     = parent->ndim + 1;
  bitlen   = 8 * parent->bytes;
  elements = bitlen * parent->elements;

  ca->obj_type  = CA_OBJ_BITARRAY;
  ca->data_type = CA_BOOLEAN;
  ca->flags     = 0;
  ca->ndim      = ndim;
  ca->bytes     = 1;
  ca->elements  = elements;
  ca->ptr       = NULL;
  ca->mask      = NULL;
  if ( ! ca->_pool ) {
    ca->dim     = ALLOC_N(ca_size_t, ndim);
  }

  ca->parent    = parent;
  ca->attach    = 0;
  ca->nosync    = 0;

  ca->bytelen   = parent->bytes;
  ca->bitlen    = bitlen;

  memcpy(ca->dim, parent->dim, (ndim-1) * sizeof(ca_size_t));
  ca->dim[ndim-1] = bitlen;

  if ( ca_has_mask(parent) ) {
    ca_create_mask(ca);
  }

  return 0;
}

CABitarray *
ca_bitarray_new (CArray *parent)
{
  CABitarray *ca = (CABitarray *) ca_array_alloc(CA_OBJ_BITARRAY, parent->ndim + 1);
  ca_bitarray_setup(ca, parent);
  return ca;
}

static void
free_ca_bitarray (void *ap)
{
  CABitarray *ca = (CABitarray *) ap;
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

static void ca_bitarray_attach (CABitarray *ca);
static void ca_bitarray_sync (CABitarray *ca);
static void ca_bitarray_fill (CABitarray *ca, char *ptr);

/* ------------------------------------------------------------------- */

static void *
ca_bitarray_func_clone (void *ap)
{
  CABitarray *ca = (CABitarray *) ap;
  return ca_bitarray_new(ca->parent);
}

/* Per-cell get / put: fetch the parent cell into a scratch buffer,
   locate the target byte + bit (major / minor), and either extract
   the bit into the output or RMW the parent cell.  Big-endian
   non-fixlen parents flip the major-byte index so the bit axis
   observes network byte order. */
static void
ca_bitarray_func_xfer_index (void *ap, ca_size_t *idx, void *data, int dir)
{
  CABitarray *ca = (CABitarray *) ap;
  ca_size_t bytes  = ca->parent->bytes;
  ca_size_t offset = idx[ca->ndim-1];
  ca_size_t major, minor;
  uint8_t sbuf[32];
  uint8_t *v;

  if ( ca_endian == CA_BIG_ENDIAN &&
       ca->parent->bytes != 1 &&
       ( ! ca_is_fixlen_type(ca->parent) ) ) {
    major = bytes - 1 - offset / 8;
  }
  else {
    major = offset / 8;
  }
  minor = offset % 8;

  v = (ca->parent->bytes <= 32) ? sbuf : xmalloc(ca->parent->bytes);

  if ( dir == CA_XFER_GET ) {
    ca_fetch_index(ca->parent, idx, v);
    *(char*) data = ( ( v[major] & bits[minor] ) != 0 );
  }
  else {
    uint8_t test = *(uint8_t *) data;
    ca_fetch_index(ca->parent, idx, v);
    if ( test ) {
      v[major] = ( v[major] & ~bits[minor] ) | bits[minor];
    }
    else {
      v[major] = ( v[major] & ~bits[minor] );
    }
    ca_store_index(ca->parent, idx, v);
  }

  if ( v != sbuf ) xfree(v);
}

/* Batched gather / scatter.
 *
 * CAREFUL: the trailing bit axis means many view cells (different
 * bits of one byte) map to the SAME parent cell.  GET batches the
 * parent gather freely — read-only sharing is harmless.  Arbitrary
 * PUT must stay per-cell (a batched scatter with duplicate parent
 * addresses would drop earlier bit writes into the same byte).
 *
 * Fast path: when `addrs` covers the whole view sequentially and
 * the effective attached parent (via identity compose-fold) is
 * live, drive ca_bit_unpack / ca_bit_pack directly against
 * parent->ptr.  Whole-view PUT rewrites every bit of every parent
 * byte, so no RMW is needed on that branch. */
static void
ca_bitarray_func_xfer_addrs (void *ap, ca_size_t n, ca_size_t *addrs,
                             void *data, int dir)
{
  CABitarray *ca = (CABitarray *) ap;
  char      *d = (char *) data;
  CArray    *parent = ca->parent;
  ca_size_t  pbytes = parent->bytes;
  ca_size_t  i, base;
  int8_t     k;

  if ( n == ca->elements
       && ca_xfer_addrs_is_sequential_run(n, addrs, &base) && base == 0 ) {
    CArray *eff_parent = ca_resolve_attached_root_via_identity(parent);
    if ( eff_parent->ptr
         && eff_parent->elements == parent->elements
         && eff_parent->bytes    == parent->bytes ) {
      int multibyte_byteswap = ( ca_endian == CA_BIG_ENDIAN
                                 && pbytes != 1
                                 && ( ! ca_is_fixlen_type(parent) ) );
      if ( dir == CA_XFER_GET ) {
        ca_bit_unpack((const uint8_t *) eff_parent->ptr,
                      parent->elements, pbytes,
                      multibyte_byteswap, (boolean8_t *) d);
      } else {
        /* Whole-view PUT rewrites every bit, so ca_bit_pack replaces
           the whole parent byte with no RMW. */
        ca_bit_pack((const boolean8_t *) d,
                    parent->elements, pbytes,
                    multibyte_byteswap, (uint8_t *) eff_parent->ptr);
      }
      return;
    }
  }

  if ( dir == CA_XFER_PUT ) {
    for (i = 0; i < n; i++) {
      ca_size_t idx[CA_RANK_MAX];
      ca_addr2index((CArray *) ca, addrs[i], idx);
      ca_bitarray_func_xfer_index(ca, idx, d + i * ca->bytes, CA_XFER_PUT);
    }
    return;
  }

  {
    ca_size_t *paddrs;
    ca_size_t *offs;
    char      *v;
    volatile VALUE h1, h2, h3;
    paddrs = ALLOCV_N(ca_size_t, h1, n);
    offs   = ALLOCV_N(ca_size_t, h2, n);
    v      = ALLOCV_N(char,      h3, n * pbytes);
    for (i = 0; i < n; i++) {
      ca_size_t idx[CA_RANK_MAX], pidx[CA_RANK_MAX];
      ca_addr2index((CArray *) ca, addrs[i], idx);
      for (k = 0; k < ca->parent->ndim; k++) pidx[k] = idx[k];
      paddrs[i] = ca_index2addr(ca->parent, pidx);
      offs[i]   = idx[ca->ndim - 1];
    }
    ca_xfer_addrs(ca->parent, n, paddrs, v, CA_XFER_GET);
    for (i = 0; i < n; i++) {
      ca_size_t offset = offs[i];
      ca_size_t major, minor;
      if ( ca_endian == CA_BIG_ENDIAN && pbytes != 1 &&
           ( ! ca_is_fixlen_type(ca->parent) ) ) {
        major = pbytes - 1 - offset / 8;
      }
      else {
        major = offset / 8;
      }
      minor = offset % 8;
      *(char *)(d + i * ca->bytes) =
        ( ( ((uint8_t *)(v + i * pbytes))[major] & bits[minor] ) != 0 );
    }
    ALLOCV_END(h3);
    ALLOCV_END(h2);
    ALLOCV_END(h1);
  }
}

/* CABitarray is a per-cell bit transform with no STRIDE structure
   to preserve, so a generic strided region reduces to the view's
   own flat address list.  Whole-view requests short-circuit
   directly through ca_bit_unpack / ca_bit_pack (same fast path as
   xfer_addrs); anything else materialises the address list and
   delegates to the view's own xfer_addrs. */
static void
ca_bitarray_func_xfer_stride (void *ap, ca_size_t *starts, ca_size_t *counts,
                              ca_size_t *strides, void *data, int dir)
{
  CABitarray *ca = (CABitarray *) ap;
  int8_t     ndim = ca->ndim;
  ca_size_t  native[CA_RANK_MAX], idx[CA_RANK_MAX];
  ca_size_t *vaddrs;
  ca_size_t  base = 0, n = 1, i, s;
  int8_t     k;
  volatile VALUE holder;

  s = ca->bytes;
  for (k = ndim - 1; k >= 0; k--) { native[k] = s; s *= ca->dim[k]; }
  for (k = 0; k < ndim; k++) { base += starts[k] * native[k]; n *= counts[k]; }

  /* Whole-view fast path: starts == 0, counts == view.dim, strides
     == native row-major.  Skips the vaddrs[] odometer and delegates
     straight to the bit primitive. */
  {
    int is_whole_view = (n == ca->elements);
    if ( is_whole_view ) {
      for ( k = 0; k < ndim; k++ ) {
        if ( starts[k] != 0 || counts[k] != ca->dim[k] || strides[k] != native[k] ) {
          is_whole_view = 0;
          break;
        }
      }
    }
    if ( is_whole_view ) {
      CArray *parent = ca->parent;
      CArray *eff_parent = ca_resolve_attached_root_via_identity(parent);
      if ( eff_parent->ptr
           && eff_parent->elements == parent->elements
           && eff_parent->bytes    == parent->bytes ) {
        int multibyte_byteswap = ( ca_endian == CA_BIG_ENDIAN
                                   && parent->bytes != 1
                                   && ( ! ca_is_fixlen_type(parent) ) );
        if ( dir == CA_XFER_GET ) {
          ca_bit_unpack((const uint8_t *) eff_parent->ptr,
                        parent->elements, parent->bytes,
                        multibyte_byteswap, (boolean8_t *) data);
        } else {
          ca_bit_pack((const boolean8_t *) data,
                      parent->elements, parent->bytes,
                      multibyte_byteswap, (uint8_t *) eff_parent->ptr);
        }
        return;
      }
    }
  }

  vaddrs = ALLOCV_N(ca_size_t, holder, n);
  for (k = 0; k < ndim; k++) idx[k] = 0;
  for (i = 0; i < n; i++) {
    ca_size_t off = base;
    for (k = 0; k < ndim; k++) off += idx[k] * strides[k];
    vaddrs[i] = off / ca->bytes;
    k = ndim - 1;
    while (k >= 0) { if (++idx[k] < counts[k]) break; idx[k] = 0; k--; }
  }
  ca_xfer_addrs(ca, n, vaddrs, data, dir);
  ALLOCV_END(holder);
}

static void
ca_bitarray_func_allocate (void *ap)
{
  CABitarray *ca = (CABitarray *) ap;
  ca_attach(ca->parent);
  ca->ptr = xmalloc(ca_length(ca));
}

static void
ca_bitarray_func_attach (void *ap)
{
  CABitarray *ca = (CABitarray *) ap;
  ca_attach(ca->parent);
  ca->ptr = xmalloc(ca_length(ca));
  ca_bitarray_attach(ca);
}

static void
ca_bitarray_func_sync (void *ap)
{
  CABitarray *ca = (CABitarray *) ap;
  ca_bitarray_sync(ca);
  ca_sync(ca->parent);
}

static void
ca_bitarray_func_detach (void *ap)
{
  CABitarray *ca = (CABitarray *) ap;
  xfree(ca->ptr);
  ca->ptr = NULL;
  ca_detach(ca->parent);
}

/* Whole-view transfer.  Fast path: drive ca_bit_unpack /
   ca_bit_pack directly against the effective attached parent (via
   identity compose-fold), bypassing the addrs[] allocation the
   xfer_addrs path would otherwise perform.

   Cold parent (eff_parent without live ptr, e.g. CABitarray over a
   CAFake chain) falls back to a scratch 2-pass: gather the parent
   through xfer_stride into a byte buffer, apply the bit primitive,
   and for PUT scatter the buffer back.  Deliberately does not call
   ca_attach(parent) — that would re-introduce the silent transitive
   attach the fast path exists to avoid. */
static void
ca_bitarray_func_xfer_all (void *ap, void *data, int dir)
{
  CABitarray *ca = (CABitarray *) ap;
  CArray     *parent = ca->parent;
  ca_size_t   pbytes = parent->bytes;
  CArray     *eff_parent = ca_resolve_attached_root_via_identity(parent);
  int         multibyte_byteswap = ( ca_endian == CA_BIG_ENDIAN
                                     && pbytes != 1
                                     && ( ! ca_is_fixlen_type(parent) ) );

  if ( eff_parent->ptr
       && eff_parent->elements == parent->elements
       && eff_parent->bytes    == parent->bytes ) {
    if ( dir == CA_XFER_GET ) {
      ca_bit_unpack((const uint8_t *) eff_parent->ptr,
                    parent->elements, pbytes,
                    multibyte_byteswap, (boolean8_t *) data);
    } else {
      ca_bit_pack((const boolean8_t *) data,
                  parent->elements, pbytes,
                  multibyte_byteswap, (uint8_t *) eff_parent->ptr);
    }
    return;
  }

  /* Cold-parent fallback: materialise into scratch via xfer_stride
     (no ca_attach(parent)), apply the bit primitive, and for PUT
     scatter back. */
  {
    volatile VALUE holder;
    char     *scratch = ALLOCV_N(char, holder, parent->elements * pbytes);
    ca_size_t pstarts[CA_RANK_MAX];
    ca_size_t pnative[CA_RANK_MAX];
    ca_size_t s = pbytes;
    int8_t    k;
    for ( k = parent->ndim - 1; k >= 0; k-- ) { pnative[k] = s; s *= parent->dim[k]; }
    for ( k = 0; k < parent->ndim; k++ ) pstarts[k] = 0;
    if ( dir == CA_XFER_GET ) {
      ca_xfer_stride(parent, pstarts, parent->dim, pnative, scratch, CA_XFER_GET);
      ca_bit_unpack((const uint8_t *) scratch, parent->elements, pbytes,
                    multibyte_byteswap, (boolean8_t *) data);
    } else {
      ca_bit_pack((const boolean8_t *) data, parent->elements, pbytes,
                  multibyte_byteswap, (uint8_t *) scratch);
      ca_xfer_stride(parent, pstarts, parent->dim, pnative, scratch, CA_XFER_PUT);
    }
    ALLOCV_END(holder);
  }
}

static void
ca_bitarray_func_fill_data (void *ap, void *ptr)
{
  CABitarray *ca = (CABitarray *) ap;
  ca_attach(ca->parent);
  ca_bitarray_fill(ca, ptr);
  ca_sync(ca->parent);
  ca_detach(ca->parent);
}

static void
ca_bitarray_func_create_mask (void *ap)
{
  CABitarray *ca = (CABitarray *) ap;
  ca_size_t count[CA_RANK_MAX];
  int8_t i;

  for (i=0; i<ca->ndim-1; i++) {
    count[i] = 0;
  }
  count[ca->ndim-1] = ca->bitlen;

  ca_update_mask(ca->parent);
  if ( ! ca->parent->mask ) {
    ca_create_mask(ca->parent);
  }
  ca->mask = (CArray *) ca_repeat_new(ca->parent->mask, ca->ndim, count);

  ca_unset_flag(ca->mask, CA_FLAG_READ_ONLY);
}

ca_operation_function_t ca_bitarray_func = {
  -1, /* CA_OBJ_BITARRAY */
  CA_VIEW_ARRAY,
  free_ca_bitarray,
  ca_bitarray_func_clone,
  ca_bitarray_func_allocate,
  ca_bitarray_func_attach,
  ca_bitarray_func_sync,
  ca_bitarray_func_detach,
  ca_bitarray_func_fill_data,
  ca_bitarray_func_create_mask,
  ca_bitarray_func_xfer_index,
  ca_bitarray_func_xfer_addrs,
  NULL,                       /* fold_stride: never fold — per-cell bit transform */
  ca_bitarray_func_xfer_stride,
  ca_bitarray_func_xfer_all,
};

/* ------------------------------------------------------------------- */

/* Bulk bit-unpack primitive: expand `elements * pbytes` parent
   bytes into `elements * pbytes * 8` boolean cells via LSB-first
   per-byte fan-out.  With `multibyte_byteswap` set, walks bytes
   within each parent element in reverse (network byte order);
   otherwise linear.  Single-byte parents ignore the flag.
 *
 * Called by ca_bitarray_attach and by the whole-view fast paths in
 * ca_bitarray_func_xfer_addrs / _xfer_stride / _xfer_all. */
void
ca_bit_unpack (const uint8_t *src, ca_size_t elements, ca_size_t pbytes,
               int multibyte_byteswap, boolean8_t *dst)
{
  const uint8_t *q = src;
  boolean8_t    *p = dst;
  ca_size_t      n;
  if ( multibyte_byteswap && pbytes != 1 ) {
    const uint8_t *r;
    uint8_t        rr;
    ca_size_t      m;
    n = elements;
    while ( n-- ) {
      m = pbytes;
      r = q + pbytes - 1;
      while ( m-- ) {
        rr = *r;
        *p++ = (rr & 1);
        *p++ = (rr & 2)   >> 1;
        *p++ = (rr & 4)   >> 2;
        *p++ = (rr & 8)   >> 3;
        *p++ = (rr & 16)  >> 4;
        *p++ = (rr & 32)  >> 5;
        *p++ = (rr & 64)  >> 6;
        *p++ = (rr & 128) >> 7;
        r--;
      }
      q += pbytes;
    }
  }
  else {
    uint8_t rr;
    n = elements * pbytes;
    while ( n-- ) {
      rr = *q++;
      *p++ = (rr & 1);
      *p++ = (rr & 2)   >> 1;
      *p++ = (rr & 4)   >> 2;
      *p++ = (rr & 8)   >> 3;
      *p++ = (rr & 16)  >> 4;
      *p++ = (rr & 32)  >> 5;
      *p++ = (rr & 64)  >> 6;
      *p++ = (rr & 128) >> 7;
    }
  }
}

static void
ca_bitarray_attach (CABitarray *ca)
{
  int multibyte_byteswap = ( ca_endian == CA_BIG_ENDIAN
                             && ca->parent->bytes != 1
                             && ( ! ca_is_fixlen_type(ca->parent) ) );
  ca_bit_unpack((const uint8_t *) ca->parent->ptr,
                ca->parent->elements, ca->parent->bytes,
                multibyte_byteswap,
                (boolean8_t *) ca->ptr);
}

/* Bulk bit-pack primitive (inverse of ca_bit_unpack): pack
   `elements * pbytes * 8` boolean cells into `elements * pbytes`
   bytes via LSB-first per-byte gather.  multibyte_byteswap handling
   mirrors ca_bit_unpack.
 *
 * CAREFUL: the caller must supply ALL 8 bits for every parent byte
 * (whole-byte overwrite, no RMW).  Partial-bit writes must go
 * through the per-cell RMW path in ca_bitarray_func_xfer_index.
 *
 * Called by ca_bitarray_sync and by the whole-view PUT branches in
 * ca_bitarray_func_xfer_addrs / _xfer_stride / _xfer_all. */
void
ca_bit_pack (const boolean8_t *src, ca_size_t elements, ca_size_t pbytes,
             int multibyte_byteswap, uint8_t *dst)
{
  const boolean8_t *p = src;
  uint8_t          *q = dst;
  ca_size_t         n, i;
  if ( multibyte_byteswap && pbytes != 1 ) {
    uint8_t  *r;
    ca_size_t m;
    n = elements;
    while ( n-- ) {
      m = pbytes;
      r = q + pbytes - 1;
      while ( m-- ) {
        *r = 0;
        for ( i = 0; i < 8; i++ ) {
          *r += (*p) * bits[i];
          p++;
        }
        r--;
      }
      q += pbytes;
    }
  }
  else {
    n = elements * pbytes;
    while ( n-- ) {
      *q = 0;
      for ( i = 0; i < 8; i++ ) {
        *q += (*p) * bits[i];
        p++;
      }
      q++;
    }
  }
}

static void
ca_bitarray_sync (CABitarray *ca)
{
  int multibyte_byteswap = ( ca_endian == CA_BIG_ENDIAN
                             && ca->parent->bytes != 1
                             && ( ! ca_is_fixlen_type(ca->parent) ) );
  ca_bit_pack((const boolean8_t *) ca->ptr,
              ca->parent->elements, ca->parent->bytes,
              multibyte_byteswap,
              (uint8_t *) ca->parent->ptr);
}

static void
ca_bitarray_fill (CABitarray *ca, char *ptr)
{
  uint8_t *q = (uint8_t *)ca->parent->ptr;
  uint8_t val = *(uint8_t *)ptr;
  if ( val ) {
    memset(q, 255, ca_length(ca->parent));
  }
  else {
    memset(q, 0, ca_length(ca->parent));
  }
}

/* ------------------------------------------------------------------- */

VALUE
rb_ca_bitarray_new (VALUE cary)
{
  volatile VALUE obj;
  CArray *parent;
  CABitarray *ca;
  rb_check_carray_object(cary);
  TypedData_Get_Struct(cary, CArray, &carray_data_type, parent);
  ca = ca_bitarray_new(parent);
  obj = ca_wrap_struct(ca);
  rb_ca_set_parent(obj, cary);
  return obj;
}

VALUE
rb_ca_bitarray (VALUE self)
{
  volatile VALUE obj;

  obj = rb_ca_bitarray_new(self);

  return obj;
}

static VALUE
rb_ca_bitarray_s_allocate (VALUE klass)
{
  CABitarray *ca;
  return TypedData_Make_Struct(klass, CABitarray, &cabitarray_data_type, ca);
}

static VALUE
rb_ca_bitarray_initialize_copy (VALUE self, VALUE other)
{
  CABitarray *ca, *cs;

  TypedData_Get_Struct(self,  CABitarray, &cabitarray_data_type, ca);
  TypedData_Get_Struct(other, CABitarray, &cabitarray_data_type, cs);

  if ( ca_func[CA_OBJ_BITARRAY].pool_init ) {
    ca_array_pool_alloc(ca, CA_OBJ_BITARRAY, cs->parent->ndim + 1);
  }
  ca_bitarray_setup(ca, cs->parent);

  return self;
}

void
Init_ca_obj_bitarray (void)
{
  rb_cCABitarray = rb_define_class("CABitarray", rb_cCAView);

  ca_bitarray_func.struct_size = sizeof(CABitarray);
  ca_bitarray_func.pool_bytes  = ca_bitarray_pool_bytes;
  ca_bitarray_func.pool_init   = ca_bitarray_pool_init;

  CA_OBJ_BITARRAY = ca_install_obj_type(rb_cCABitarray,
                                        &cabitarray_data_type,
					rb_cCArrayMask,
					&carray_mask_data_type, &ca_bitarray_func, sizeof(ca_bitarray_func));
  rb_define_const(rb_cObject, "CA_OBJ_BITARRAY", INT2NUM(CA_OBJ_BITARRAY));

  rb_define_method(rb_cCArray, "bitarray", rb_ca_bitarray, 0);
  rb_define_alias(rb_cCArray, "bits", "bitarray");

  rb_define_alloc_func(rb_cCABitarray, rb_ca_bitarray_s_allocate);
  rb_define_method(rb_cCABitarray, "initialize_copy",
                                      rb_ca_bitarray_initialize_copy, 1);
}

