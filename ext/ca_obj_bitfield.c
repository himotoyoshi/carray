/* ---------------------------------------------------------------------------

  CABitfield view: extract a contiguous bit field from each parent
  cell, exposing it as an unsigned-integer (or boolean, when
  bitlen == 1) CArray of the same shape as the parent.

  Byte-straddling fields are handled by loading up to 8 bytes from
  the parent starting at `byte_offset`, masking with `bit_mask`, and
  shifting by `bit_offset`.  Big-endian hosts adjust byte_offset /
  bit_offset so the field selection is invariant to host byte order.

---------------------------------------------------------------------------- */

#include "carray.h"

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
  ca_size_t   byte_offset;
  ca_size_t   bit_offset;
  uint64_t  bit_mask;
  ca_size_t   bit_start;  /* original offset before endian adjustment */
} CABitfield;

static size_t
ca_bitfield_dsize (const void *ap)
{
  const CABitfield *ca = (const CABitfield *) ap;
  return sizeof(CABitfield) + ca->ndim * sizeof(ca_size_t);
}

/* Pool framework hooks: single ndim-sized tail (dim) in the _pool
   buffer.  See ca_array_pool.c for the shared alloc/free discipline. */
static size_t
ca_bitfield_pool_bytes (int8_t ndim)
{
  ca_size_t n = (ndim > 0) ? ndim : 1;
  return (size_t) n * sizeof(ca_size_t);
}

static void
ca_bitfield_pool_init (void *ap, int8_t ndim)
{
  CABitfield *ca = (CABitfield *) ap;
  ca->dim = (ca_size_t *) ca->_pool;
}

const rb_data_type_t cabitfield_data_type = {
    .parent = &caview_data_type,
    .wrap_struct_name = "CABitfield",
    .function = {
        .dmark = ca_mark,
        .dfree = ca_free,
        .dsize = ca_bitfield_dsize,
        .dcompact = NULL
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

static int8_t CA_OBJ_BITFIELD;

static VALUE rb_cCABitfield;

static ca_size_t
bitfield_bitlen (uint64_t bit_mask, ca_size_t bytes)
{
  ca_size_t bitsize = bytes * 8;
  ca_size_t count = 0;
  ca_size_t i;
  for (i=0; i<bitsize; i++) {
    if ( ( bit_mask >> i ) & 1 ) {
      count++;
    }
  }
  return count;
}

/* Generic per-cell fetch: load up to 8 bytes from src starting at
   byte_offset, mask with bit_mask, shift down by bit_offset, and
   write the low `dwrite` bytes of the result to dst.
 *
 * CAREFUL: the read goes through a uint64 with dynamic `span` /
 * `dwrite` deliberately, so that a byte-straddling field (e.g. an
 * 8-bit field starting at bit 4 of a 2-byte parent) sees the full
 * bit_mask.  A dbytes-typed cast would silently truncate bit_mask
 * to `1 << (dbytes * 8)`, dropping the upper bits of the field. */
static void
bitfield_fetch(char *dst, ca_size_t dbytes,
                   char *src, ca_size_t sbytes,
                   ca_size_t byte_offset, ca_size_t bit_offset, uint64_t bit_mask,
                   ca_size_t elements)
{
  ca_size_t k;
  ca_size_t span = sbytes - byte_offset;
  if (span > 8) span = 8;
  ca_size_t dwrite = (dbytes > 8) ? 8 : dbytes;
  for (k = 0; k < elements; k++) {
    uint64_t tmp = 0;
    memcpy(&tmp, src + k * sbytes + byte_offset, (size_t) span);
    uint64_t result = (tmp & bit_mask) >> bit_offset;
    memcpy(dst + k * dbytes, &result, (size_t) dwrite);
  }
}

static void
bitfield_store(char *src, ca_size_t sbytes,
                   char *dst, ca_size_t dbytes,
                   ca_size_t byte_offset, ca_size_t bit_offset, uint64_t bit_mask,
                   ca_size_t elements)
{
  /* Mirror of bitfield_fetch with scatter direction: reads sbytes
     from src, reads dbytes of dst starting at byte_offset, masks
     the field bits in, writes back.  The uint64 read/write span
     preserves bit_mask for byte-straddling fields (see
     bitfield_fetch CAREFUL). */
  ca_size_t k;
  ca_size_t span = dbytes - byte_offset;
  if (span > 8) span = 8;
  ca_size_t sread = (sbytes > 8) ? 8 : sbytes;
  for (k = 0; k < elements; k++) {
    uint64_t srcv = 0;
    memcpy(&srcv, src + k * sbytes, (size_t) sread);
    uint64_t tmp = 0;
    memcpy(&tmp, dst + k * dbytes + byte_offset, (size_t) span);
    tmp = (tmp & ~bit_mask) | ((srcv << bit_offset) & bit_mask);
    memcpy(dst + k * dbytes + byte_offset, &tmp, (size_t) span);
  }
}


/* ------------------------------------------------------------------- */

int
ca_bitfield_setup (CABitfield *ca, CArray *parent,
                   ca_size_t offset, ca_size_t bitlen)
{
  int8_t ndim;
  int8_t data_type;
  ca_size_t bytes = 0, elements;
  ca_size_t bitsize;
  ca_size_t  byte_offset;
  ca_size_t  bit_offset;
  uint64_t bit_mask;
  ca_size_t i;

  ndim     = parent->ndim;
  bitsize  = parent->bytes * 8;
  elements = parent->elements;

  if ( bitlen <= 0 || bitlen > 64 ) {
    rb_raise(rb_eIndexError, "invalid bit length specified for bit field");
  }

  if ( offset + bitlen -1 >= bitsize ) {
    rb_raise(rb_eIndexError, "invalid offset for bit field");
  }

  if ( bitlen == 1 ) {
    data_type = CA_BOOLEAN;
  }
  else if ( bitlen <= 8 ) {
    data_type = CA_UINT8;
  }
  else if ( bitlen <= 16 ) {
    data_type = CA_UINT16;
  }
  else if ( bitlen <= 32 ) {
    data_type = CA_UINT32;
  }
  else {
    data_type = CA_UINT64;
  }

  CA_CHECK_BYTES(data_type, bytes);

  if ( bitlen > bytes * 8 ) {
    rb_raise(rb_eArgError, "invalid bit length for specified data_type");
  }

  if ( ( data_type == CA_BOOLEAN ) && ( bitlen > 1 ) ) {
    rb_raise(rb_eArgError, "invalid bit length for specified data_type");
  }

  if ( ca_endian == CA_BIG_ENDIAN ) {
    byte_offset = parent->bytes - offset/8 - bytes;
    bit_offset  = offset % 8;
    bit_mask    = 0;
    for (i=0; i<bitlen; i++) {
      bit_mask += 1ULL << ( bit_offset + i );
    }
    if ( byte_offset < 0 ) {
      for (i=0; i<-byte_offset; i++) {
        bit_mask = bit_mask << 8;
        bit_offset += 8;
      }
      byte_offset = 0;
    }
  }
  else {
    byte_offset = offset / 8;
    bit_offset  = offset % 8;
    bit_mask    = 0;
    for (i=0; i<bitlen; i++) {
      bit_mask += 1ULL << ( bit_offset + i );
    }
  }

  ca->obj_type  = CA_OBJ_BITFIELD;
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

  ca->byte_offset = byte_offset;
  ca->bit_offset  = bit_offset;
  ca->bit_mask    = bit_mask;
  ca->bit_start   = offset;  /* preserve original offset for clone/copy */

  memcpy(ca->dim, parent->dim, ndim * sizeof(ca_size_t));

  if ( ca_has_mask(parent) ) {
    ca_create_mask(ca);
  }

  return 0;
}

CABitfield *
ca_bitfield_new (CArray *parent, ca_size_t offset, ca_size_t bitlen)
{
  CABitfield *ca = (CABitfield *) ca_array_alloc(CA_OBJ_BITFIELD, parent->ndim);
  ca_bitfield_setup(ca, parent, offset, bitlen);
  return ca;
}

static void
free_ca_bitfield (void *ap)
{
  CABitfield *ca = (CABitfield *) ap;
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

static void ca_bitfield_attach (CABitfield *ca);
static void ca_bitfield_sync (CABitfield *ca);
static void ca_bitfield_fill (CABitfield *ca, char *ptr);

/* ------------------------------------------------------------------- */

static void *
ca_bitfield_func_clone (void *ap)
{
  CABitfield *ca = (CABitfield *) ap;
  return ca_bitfield_new(ca->parent,
                         ca->bit_start,
                         bitfield_bitlen(ca->bit_mask, ca->bytes));
}

/* Per-cell get/put: fetch the parent cell into a scratch buffer,
   then extract or splice the bit field with bitfield_fetch /
   bitfield_store on a single element. */
static void
ca_bitfield_func_xfer_index (void *ap, ca_size_t *idx, void *data, int dir)
{
  CABitfield *ca = (CABitfield *) ap;
  char *v = xmalloc(ca->parent->bytes);
  ca_fetch_index(ca->parent, idx, v);
  if ( dir == CA_XFER_GET ) {
    memset(data, 0, ca->bytes);
    bitfield_fetch(data, ca->bytes, v, ca->parent->bytes,
                   ca->byte_offset, ca->bit_offset, ca->bit_mask, 1);
  }
  else {
    bitfield_store(data, ca->bytes, v, ca->parent->bytes,
                   ca->byte_offset, ca->bit_offset, ca->bit_mask, 1);
    ca_store_index(ca->parent, idx, v);
  }
  xfree(v);
}

/* Batched gather / scatter.  CABitfield is a 1:1 view (each parent
   cell carries exactly one field position) so the incoming view
   addresses are also parent addresses.  GET gathers parent cells in
   one call then extracts bits; PUT reads, splices field bits, then
   writes back.  Each cell touches its own bits, so there is no
   shared-cell hazard between concurrent scatters.

   Fast path: when `addrs` covers the whole view sequentially and
   the effective attached parent (via identity compose-fold) is
   live, drive bitfield_fetch / bitfield_store directly against
   parent->ptr — no scratch, no double xfer_addrs round-trip. */
static void
ca_bitfield_func_xfer_addrs (void *ap, ca_size_t n, ca_size_t *addrs,
                             void *data, int dir)
{
  CABitfield *ca = (CABitfield *) ap;
  CArray    *parent = ca->parent;
  char      *d = (char *) data;
  ca_size_t  pbytes = parent->bytes;
  ca_size_t  i, base;
  char      *v;
  volatile VALUE holder;

  if ( n == ca->elements
       && ca_xfer_addrs_is_sequential_run(n, addrs, &base) && base == 0 ) {
    CArray *eff_parent = ca_resolve_attached_root_via_identity(parent);
    if ( eff_parent->ptr
         && eff_parent->elements == parent->elements
         && eff_parent->bytes    == parent->bytes ) {
      if ( dir == CA_XFER_GET ) {
        /* Zero the output buffer, then bulk-extract n field values
           directly from the attached parent. */
        memset(d, 0, n * ca->bytes);
        bitfield_fetch(d, ca->bytes, eff_parent->ptr, pbytes,
                       ca->byte_offset, ca->bit_offset, ca->bit_mask, n);
      } else {
        /* Bulk RMW directly against parent memory (bitfield_store
           preserves non-field bits). */
        bitfield_store(d, ca->bytes, eff_parent->ptr, pbytes,
                       ca->byte_offset, ca->bit_offset, ca->bit_mask, n);
      }
      return;
    }
  }

  v = ALLOCV_N(char, holder, n * pbytes);
  if ( dir == CA_XFER_GET ) {
    ca_xfer_addrs(parent, n, addrs, v, CA_XFER_GET);
    for (i = 0; i < n; i++) {
      memset(d + i * ca->bytes, 0, ca->bytes);
      bitfield_fetch(d + i * ca->bytes, ca->bytes, v + i * pbytes, pbytes,
                     ca->byte_offset, ca->bit_offset, ca->bit_mask, 1);
    }
  }
  else {
    ca_xfer_addrs(parent, n, addrs, v, CA_XFER_GET);   /* RMW: read first */
    for (i = 0; i < n; i++) {
      bitfield_store(d + i * ca->bytes, ca->bytes, v + i * pbytes, pbytes,
                     ca->byte_offset, ca->bit_offset, ca->bit_mask, 1);
    }
    ca_xfer_addrs(parent, n, addrs, v, CA_XFER_PUT);
  }
  ALLOCV_END(holder);
}

/* CABitfield is a per-cell bit transform with no axis structure to
   preserve, so the incoming region reduces to a flat address list
   over the view.  We materialise that list from starts / counts /
   strides and delegate to the view's own xfer_addrs, which handles
   the gather + bit RMW + batched parent delivery. */
static void
ca_bitfield_func_xfer_stride (void *ap, ca_size_t *starts, ca_size_t *counts,
                              ca_size_t *strides, void *data, int dir)
{
  CABitfield *ca = (CABitfield *) ap;
  int8_t     ndim = ca->ndim;
  ca_size_t  native[CA_RANK_MAX], idx[CA_RANK_MAX];
  ca_size_t *vaddrs;
  ca_size_t  base = 0, n = 1, i, s;
  int8_t     k;
  volatile VALUE holder;

  s = ca->bytes;
  for (k = ndim - 1; k >= 0; k--) { native[k] = s; s *= ca->dim[k]; }
  for (k = 0; k < ndim; k++) { base += starts[k] * native[k]; n *= counts[k]; }

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
ca_bitfield_func_allocate (void *ap)
{
  CABitfield *ca = (CABitfield *) ap;
  ca_attach(ca->parent);
  ca->ptr = xmalloc(ca_length(ca));
}

static void
ca_bitfield_func_attach (void *ap)
{
  CABitfield *ca = (CABitfield *) ap;
  ca_attach(ca->parent);
  ca->ptr = xmalloc(ca_length(ca));
  ca_bitfield_attach(ca);
}

static void
ca_bitfield_func_sync (void *ap)
{
  CABitfield *ca = (CABitfield *) ap;
  ca_bitfield_sync(ca);
  ca_sync(ca->parent);
}

static void
ca_bitfield_func_detach (void *ap)
{
  CABitfield *ca = (CABitfield *) ap;
  xfree(ca->ptr);
  ca->ptr = NULL;
  ca_detach(ca->parent);
}

/* Whole-view transfer.  Fast path: drive bitfield_fetch /
   bitfield_store directly against the effective attached parent
   (via identity compose-fold), bypassing the addrs[] allocation
   and sequential-run scan that xfer_addrs would perform.

   Cold parent falls back to a scratch 2-pass (gather parent into a
   local buffer via xfer_stride, apply the bitfield primitive, and
   for PUT scatter the buffer back).  Deliberately does not call
   ca_attach(parent) — that would re-introduce the silent transitive
   attach the fast path exists to avoid. */
static void
ca_bitfield_func_xfer_all (void *ap, void *data, int dir)
{
  CABitfield *ca = (CABitfield *) ap;
  CArray     *parent = ca->parent;
  ca_size_t   pbytes = parent->bytes;
  ca_size_t   n = ca->elements;
  char       *d = (char *) data;
  CArray     *eff_parent = ca_resolve_attached_root_via_identity(parent);

  if ( eff_parent->ptr
       && eff_parent->elements == parent->elements
       && eff_parent->bytes    == parent->bytes ) {
    if ( dir == CA_XFER_GET ) {
      memset(d, 0, n * ca->bytes);
      bitfield_fetch(d, ca->bytes, eff_parent->ptr, pbytes,
                     ca->byte_offset, ca->bit_offset, ca->bit_mask, n);
    } else {
      bitfield_store(d, ca->bytes, eff_parent->ptr, pbytes,
                     ca->byte_offset, ca->bit_offset, ca->bit_mask, n);
    }
    return;
  }

  /* Cold-parent fallback: materialise into scratch via xfer_stride
     (no ca_attach(parent)), apply the bitfield primitive, and for
     PUT scatter back. */
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
      memset(d, 0, n * ca->bytes);
      bitfield_fetch(d, ca->bytes, scratch, pbytes,
                     ca->byte_offset, ca->bit_offset, ca->bit_mask, n);
    } else {
      /* CAREFUL: gather parent into scratch before splicing so the
         non-field bits are preserved across the RMW. */
      ca_xfer_stride(parent, pstarts, parent->dim, pnative, scratch, CA_XFER_GET);
      bitfield_store(d, ca->bytes, scratch, pbytes,
                     ca->byte_offset, ca->bit_offset, ca->bit_mask, n);
      ca_xfer_stride(parent, pstarts, parent->dim, pnative, scratch, CA_XFER_PUT);
    }
    ALLOCV_END(holder);
  }
}

static void
ca_bitfield_func_fill_data (void *ap, void *ptr)
{
  CABitfield *ca = (CABitfield *) ap;
  ca_attach(ca->parent);
  ca_bitfield_fill(ca, ptr);
  ca_sync(ca->parent);
  ca_detach(ca->parent);
}


/* A fill here is a read-modify-write: the cell also carries bits this view
   does not own, so there is nothing to hand down as a region.  The batched
   address slot already reads and writes a run in one call each; broadcasting
   the value into it is all that is left, and it saves the descent that a
   per-cell walk would pay for every cell. */
static void
ca_bitfield_func_fill_addrs (void *ap, ca_size_t n, ca_size_t *addrs, void *ptr)
{
  CABitfield *ca = (CABitfield *) ap;
  volatile VALUE holder;
  char     *buf = ALLOCV_N(char, holder, (size_t) n * ca->bytes);
  ca_size_t i;

  for ( i = 0; i < n; i++ ) {
    memcpy(buf + i * ca->bytes, ptr, ca->bytes);
  }
  ca_bitfield_func_xfer_addrs(ca, n, addrs, buf, CA_XFER_PUT);
  ALLOCV_END(holder);
}

static void
ca_bitfield_func_fill_stride (void *ap, ca_size_t base, int8_t ndim,
    ca_size_t *counts, ca_size_t *steps, void *ptr)
{
  ca_fill_stride_via_addrs(ap, base, ndim, counts, steps, ptr);
}

static void
ca_bitfield_func_create_mask (void *ap)
{
  CABitfield *ca = (CABitfield *) ap;

  ca_update_mask(ca->parent);
  if ( ! ca->parent->mask ) {
    ca_create_mask(ca->parent);
  }

  ca->mask = (CArray *) ca_refer_new(ca->parent->mask,
                                     CA_BOOLEAN, ca->ndim, ca->dim, 0, 0);
}

ca_operation_function_t ca_bitfield_func = {
  -1, /* CA_OBJ_BITFIELD */
  CA_VIEW_ARRAY,
  free_ca_bitfield,
  ca_bitfield_func_clone,
  ca_bitfield_func_allocate,
  ca_bitfield_func_attach,
  ca_bitfield_func_sync,
  ca_bitfield_func_detach,
  ca_bitfield_func_fill_data,
  ca_bitfield_func_create_mask,
  ca_bitfield_func_xfer_index,
  ca_bitfield_func_xfer_addrs,
  NULL,                       /* fold_stride: never fold — per-cell bit transform */
  ca_bitfield_func_xfer_stride,
  ca_bitfield_func_xfer_all,
  .fill_addrs   = ca_bitfield_func_fill_addrs,
  .fill_stride  = ca_bitfield_func_fill_stride,
};

/* ------------------------------------------------------------------- */

static void
ca_bitfield_attach (CABitfield *ca)
{
  memset(ca->ptr, 0, ca_length(ca));
  bitfield_fetch(ca->ptr, ca->bytes, ca->parent->ptr, ca->parent->bytes,
                 ca->byte_offset, ca->bit_offset, ca->bit_mask, ca->elements);
}

static void
ca_bitfield_sync (CABitfield *ca)
{
  bitfield_store(ca->ptr, ca->bytes, ca->parent->ptr, ca->parent->bytes,
                 ca->byte_offset, ca->bit_offset, ca->bit_mask, ca->elements);
}

static void
ca_bitfield_fill (CABitfield *ca, char *ptr)
{
  char *q = ca->parent->ptr;
  ca_size_t bytesp = ca->bytes;
  ca_size_t bytesq = ca->parent->bytes;
  ca_size_t byte_offset = ca->byte_offset;
  ca_size_t bit_offset = ca->bit_offset;
  uint64_t bit_mask = ca->bit_mask;
  ca_size_t i;

  for (i=0; i<ca->elements; i++) {
    bitfield_store(ptr, bytesp, q, bytesq, 
                   byte_offset, bit_offset, bit_mask, 1);
    q += bytesq;
  }
}

/* ------------------------------------------------------------------- */

VALUE
rb_ca_bitfield_new (VALUE cary, ca_size_t offset, ca_size_t bitlen)
{
  volatile VALUE obj;
  CArray *parent;
  CABitfield *ca;
  rb_check_carray_object(cary);
  TypedData_Get_Struct(cary, CArray, &carray_data_type, parent);
  ca = ca_bitfield_new(parent, offset, bitlen);
  obj = ca_wrap_struct(ca);
  rb_ca_set_parent(obj, cary);
  return obj;
}

VALUE
rb_ca_bitfield (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE rrange, rtype;
  CArray *ca;
  ca_size_t offset, bitlen, step;
  ca_size_t bitsize;

  rb_scan_args(argc, argv, "11", (VALUE *) &rrange, (VALUE *) &rtype);

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  if ( TYPE(rrange) == T_FIXNUM ) {
    offset = NUM2INT(rrange);
    bitlen = 1;
  }
  else {
    bitsize = ca->bytes * 8;
    ca_parse_range(rrange, bitsize, &offset, &bitlen, &step);
    if ( step != 1 ) {
      rb_raise(rb_eIndexError, "invalid bit range specified for bit field");
    }
  }

  return rb_ca_bitfield_new(self, offset, bitlen);
}

static VALUE
rb_ca_bitfield_s_allocate (VALUE klass)
{
  CABitfield *ca;
  return TypedData_Make_Struct(klass, CABitfield, &cabitfield_data_type, ca);
}

static VALUE
rb_ca_bitfield_initialize_copy (VALUE self, VALUE other)
{
  CABitfield *ca, *cs;

  TypedData_Get_Struct(self,  CABitfield, &cabitfield_data_type, ca);
  TypedData_Get_Struct(other, CABitfield, &cabitfield_data_type, cs);

  if ( ca_func[CA_OBJ_BITFIELD].pool_init ) {
    ca_array_pool_alloc(ca, CA_OBJ_BITFIELD, cs->parent->ndim);
  }
  ca_bitfield_setup(ca, cs->parent,
                    cs->bit_start,
                    bitfield_bitlen(cs->bit_mask, cs->bytes));

  return self;
}

void
Init_ca_obj_bitfield (void)
{
  rb_cCABitfield = rb_define_class("CABitfield", rb_cCAView);

  ca_bitfield_func.struct_size = sizeof(CABitfield);
  ca_bitfield_func.pool_bytes  = ca_bitfield_pool_bytes;
  ca_bitfield_func.pool_init   = ca_bitfield_pool_init;

  CA_OBJ_BITFIELD = ca_install_obj_type(rb_cCABitfield,
  	                                &cabitfield_data_type,
					rb_cCArrayMask,
					&carray_mask_data_type, &ca_bitfield_func, sizeof(ca_bitfield_func));
  rb_define_const(rb_cObject, "CA_OBJ_BITFIELD", INT2NUM(CA_OBJ_BITFIELD));

  rb_define_method(rb_cCArray, "bitfield", rb_ca_bitfield, -1);

  rb_define_alloc_func(rb_cCABitfield, rb_ca_bitfield_s_allocate);
  rb_define_method(rb_cCABitfield, "initialize_copy",
                                      rb_ca_bitfield_initialize_copy, 1);
}

