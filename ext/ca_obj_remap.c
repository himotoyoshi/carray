/* ---------------------------------------------------------------------------

  CARemap — internal-only per-element gather view.  Each output cell
  (k0, k1, ..., k_{n-1}) reads the input cell at
  parent.flatten[idx.flatten[k]].

  Constraints:
  - ref.dim == idx.dim (same shape, same ndim, per-axis dim match)
  - idx.data_type == CA_SIZE (caller responsible)
  - No public constructor — there is no `CArray#remap(idx)` or
    `CARemap.new` surface; the class is only reachable via internal
    helpers and the `ca[idx]` same-shape indexer fast path.
  - The CARemap Ruby class IS rb_define_class'd: visibility lets users
    see "this view came from a same-shape gather" when they inspect
    `.class`.  CA_OBJ_REMAP integer remains unexported as a Ruby
    constant — it is an internal type tag.

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
  CArray   *parent;   /* = ref */
  uint32_t  attach;
  uint8_t   nosync;
  /* ---------- */
  CArray   *idx;      /* shared reference; data_type = CA_SIZE, same shape as parent */
} CARemap;

static int8_t CA_OBJ_REMAP;

/* Ruby classes — rb_define_class'd in Init so users see the right
   class name on .class inspection.  No constructor is bound (no
   rb_define_method "initialize" or alloc), so the class is unreachable
   from Ruby code; only internal C helpers can construct CARemap. */
static VALUE rb_cCARemap;
static VALUE rb_cCARemapMask;

static size_t
ca_remap_dsize (const void *ap)
{
  const CARemap *ca = (const CARemap *) ap;
  return sizeof(CARemap) + ca->ndim * sizeof(ca_size_t);
}

/* Pool framework hooks: single ndim-sized tail (dim) in the _pool buffer. */
static size_t
ca_remap_pool_bytes (int8_t ndim)
{
  ca_size_t n = (ndim > 0) ? ndim : 1;
  return (size_t) n * sizeof(ca_size_t);
}

static void
ca_remap_pool_init (void *ap, int8_t ndim)
{
  CARemap *ca = (CARemap *) ap;
  ca->dim = (ca_size_t *) ca->_pool;
}

const rb_data_type_t caremap_data_type = {
    .parent = &caview_data_type,
    .wrap_struct_name = "CARemap",
    .function = {
        .dmark = ca_mark,
        .dfree = ca_free,
        .dsize = ca_remap_dsize,
        .dcompact = NULL
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

const rb_data_type_t caremap_mask_data_type = {
    .parent = &caremap_data_type,
    .wrap_struct_name = "CARemapMask",
    .function = {
        .dmark = NULL,
        .dfree = ca_free_nop,
        .dsize = ca_remap_dsize,
        .dcompact = NULL
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

/* ------------------------------------------------------------------- */
/* Constraint enforcement: idx is CA_SIZE and ref.dim == idx.dim.       */

static void
ca_remap_check_constraints (CArray *ref, CArray *idx)
{
  int k;

  if ( idx->data_type != CA_SIZE ) {
    rb_raise(rb_eArgError,
             "CARemap: idx data_type must be CA_SIZE (got %d)",
             (int) idx->data_type);
  }
  if ( ref->ndim != idx->ndim ) {
    rb_raise(rb_eArgError,
             "CARemap: ref.ndim (%d) != idx.ndim (%d)",
             (int) ref->ndim, (int) idx->ndim);
  }
  for ( k = 0; k < ref->ndim; k++ ) {
    if ( ref->dim[k] != idx->dim[k] ) {
      rb_raise(rb_eArgError,
               "CARemap: shape mismatch at axis %d (ref=%lld, idx=%lld)",
               k,
               (long long) ref->dim[k],
               (long long) idx->dim[k]);
    }
  }
}

/* ------------------------------------------------------------------- */

int
ca_remap_setup (CARemap *ca, CArray *ref, CArray *idx)
{
  ca_remap_check_constraints(ref, idx);

  ca->obj_type  = CA_OBJ_REMAP;
  ca->data_type = ref->data_type;
  ca->flags     = 0;
  ca->ndim      = ref->ndim;
  ca->bytes     = ref->bytes;
  ca->elements  = ref->elements;
  ca->ptr       = NULL;
  ca->mask      = NULL;
  if ( ! ca->_pool ) {
    ca->dim     = ALLOC_N(ca_size_t, ref->ndim);
  }
  memcpy(ca->dim, ref->dim, ref->ndim * sizeof(ca_size_t));

  ca->parent    = ref;
  ca->attach    = 0;
  ca->nosync    = 0;
  ca->idx       = idx;

  if ( ca_has_mask(ref) ) {
    ca_create_mask(ca);
  }

  if ( ca_is_scalar(ref) ) {
    ca_set_flag(ca, CA_FLAG_SCALAR);
  }

  return 0;
}

CARemap *
ca_remap_new (CArray *ref, CArray *idx)
{
  CARemap *ca = (CARemap *) ca_array_alloc(CA_OBJ_REMAP, ref->ndim);
  ca_remap_setup(ca, ref, idx);
  return ca;
}

static void
free_ca_remap (void *ap)
{
  CARemap *ca = (CARemap *) ap;
  if ( ca != NULL ) {
    ca_free(ca->mask);
    /* ca->idx is a shared reference owned by the caller; no free here.
       The Ruby-side parent linkage (rb_ca_set_parent on idx wrapper)
       keeps it reachable for GC. */
    if ( ca->_pool ) {
      ca_array_free(ca);          /* dim lives in _pool */
    }
    else {
      xfree(ca->dim);
      xfree(ca);
    }
  }
}

/* Forward declarations for the xfer slot implementations, used by the
   lifecycle slots above them in the dispatch table.                  */
static void ca_remap_func_xfer_addrs (void *ap, ca_size_t n,
                                      ca_size_t *addrs, void *data, int dir);
static void ca_remap_func_xfer_all   (void *ap, void *data, int dir);

/* ------------------------------------------------------------------- */

static void *
ca_remap_func_clone (void *ap)
{
  CARemap *ca = (CARemap *) ap;
  return ca_remap_new(ca->parent, ca->idx);
}

/* Lifecycle (xfer contract):
     attach   = allocate ptr + xfer_all(GET)
     sync     = xfer_all(PUT)
     detach   = xfree(ptr)
   No ca_attach(parent) / ca_attach(idx) here — xfer_all resolves both
   per-cell through the per-region ca_xfer_addrs dispatchers. */

static void
ca_remap_func_allocate (void *ap)
{
  CARemap *ca = (CARemap *) ap;
  ca->ptr = xmalloc(ca_length(ca));
}

static void
ca_remap_func_attach (void *ap)
{
  CARemap *ca = (CARemap *) ap;
  ca->ptr = xmalloc(ca_length(ca));
  ca_remap_func_xfer_all(ca, ca->ptr, CA_XFER_GET);
}

static void
ca_remap_func_sync (void *ap)
{
  CARemap *ca = (CARemap *) ap;
  ca_remap_func_xfer_all(ca, ca->ptr, CA_XFER_PUT);
}

static void
ca_remap_func_detach (void *ap)
{
  CARemap *ca = (CARemap *) ap;
  xfree(ca->ptr);
  ca->ptr = NULL;
}

/* fill_data: broadcast a single cell (`data` is one cell of size
   ca->bytes) to every view position.  Implementation = build a
   row-major scratch of `data` repeated `elements` times, then route
   through xfer_all(PUT).  With repeats in idx this writes the same
   parent cell multiple times — value is identical so the result is
   well-defined (parent.flat[idx[k]] = value for each unique k). */
static void
ca_remap_func_fill_data (void *ap, void *data)
{
  CARemap   *ca = (CARemap *) ap;
  ca_size_t  n = ca->elements;
  char      *scratch;
  ca_size_t  i;
  volatile VALUE holder;

  if ( n == 0 ) return;

  scratch = ALLOCV_N(char, holder, n * ca->bytes);
  for ( i = 0; i < n; i++ ) {
    memcpy(scratch + i * ca->bytes, data, ca->bytes);
  }
  ca_remap_func_xfer_all(ca, scratch, CA_XFER_PUT);
  ALLOCV_END(holder);
}

static void
ca_remap_func_create_mask (void *ap)
{
  CARemap *ca = (CARemap *) ap;
  ca_update_mask(ca->parent);
  if ( ! ca->parent->mask ) {
    ca_create_mask(ca->parent);
  }
  /* Mask is a CARemap over (parent->mask, idx) — same shape, boolean. */
  ca->mask = (CArray *) ca_remap_new(ca->parent->mask, ca->idx);
}

/* xfer_addrs: batched gather/scatter over a list of view flat addresses.

   Per the same-shape invariant the view-flat addresses index ca->idx
   identically (both have the same elements layout).  Steps:

     1. ALLOCV paddrs[n].
     2. ca_xfer_addrs(ca->idx, n, addrs, paddrs, GET)  — one batched
        read of the parent flat addresses through ca->idx's own
        xfer_addrs dispatcher (entity, view, view chain — all
        transparent).
     3. ca_xfer_addrs(ca->parent, n, paddrs, data, dir) — one batched
        gather/scatter of the user payload against parent.

   No ca_attach() of parent or idx; both reads are per-region dispatch.
   This is the natural batched form of xfer_index (and xfer_index
   routes through it). */
static void
ca_remap_func_xfer_addrs (void *ap, ca_size_t n, ca_size_t *addrs,
                          void *data, int dir)
{
  CARemap   *ca = (CARemap *) ap;
  ca_size_t *paddrs;
  volatile VALUE holder;

  if ( n == 0 ) return;

  paddrs = ALLOCV_N(ca_size_t, holder, n);
  ca_xfer_addrs(ca->idx,    n, addrs,  paddrs, CA_XFER_GET);
  ca_xfer_addrs(ca->parent, n, paddrs, data,   dir);
  ALLOCV_END(holder);
}

/* xfer_index — single-cell form delegated to xfer_addrs after
   converting the view N-D index to a view flat address.  Same-shape
   invariant: ca_index2addr on ca itself (using ca->dim) yields the
   right view flat that equally indexes ca->idx. */
static void
ca_remap_func_xfer_index (void *ap, ca_size_t *idx, void *data, int dir)
{
  ca_size_t view_addr = ca_index2addr(ap, idx);
  ca_remap_func_xfer_addrs(ap, 1, &view_addr, data, dir);
}

/* xfer_stride: CARemap is a never-fold per-element gather boundary --
   no STRIDE structure to preserve.  The region [starts[k],
   starts[k]+counts[k]) is enumerated cell-by-cell, each cell resolved
   to its view-flat address through the strides[] byte step, and
   delivered through CARemap's own xfer_addrs (which then walks through
   ca->idx to the parent addresses in two batched calls).  data is
   contiguous row-major over counts.

   Same shape as CAReduce's xfer_stride (ca_obj_reduce.c). */
static void
ca_remap_func_xfer_stride (void *ap, ca_size_t *starts, ca_size_t *counts,
                           ca_size_t *strides, void *data, int dir)
{
  CARemap   *ca = (CARemap *) ap;
  int8_t     ndim = ca->ndim;
  ca_size_t  native[CA_RANK_MAX], idx[CA_RANK_MAX];
  ca_size_t *vaddrs;
  ca_size_t  base = 0, n = 1, i, s;
  int8_t     k;
  volatile VALUE holder;

  s = ca->bytes;
  for ( k = ndim - 1; k >= 0; k-- ) { native[k] = s; s *= ca->dim[k]; }
  for ( k = 0; k < ndim; k++ ) { base += starts[k] * native[k]; n *= counts[k]; }

  if ( n == 0 ) return;

  vaddrs = ALLOCV_N(ca_size_t, holder, n);
  for ( k = 0; k < ndim; k++ ) idx[k] = 0;
  for ( i = 0; i < n; i++ ) {
    ca_size_t off = base;
    for ( k = 0; k < ndim; k++ ) off += idx[k] * strides[k];
    vaddrs[i] = off / ca->bytes;
    k = ndim - 1;
    while ( k >= 0 ) { if ( ++idx[k] < counts[k] ) break; idx[k] = 0; k--; }
  }
  ca_remap_func_xfer_addrs(ca, n, vaddrs, data, dir);
  ALLOCV_END(holder);
}

/* xfer_all: whole-view delivery.  Sequential view-flat addresses
   [0..elements) routed through xfer_addrs -- one ALLOCV for the addr
   list, then two batched ca_xfer_addrs calls inside xfer_addrs.

   No ca_attach(parent) / ca_attach(idx). */
static void
ca_remap_func_xfer_all (void *ap, void *data, int dir)
{
  CARemap   *ca = (CARemap *) ap;
  ca_size_t  n = ca->elements;
  ca_size_t *vaddrs;
  ca_size_t  i;
  volatile VALUE holder;

  if ( n == 0 ) return;

  vaddrs = ALLOCV_N(ca_size_t, holder, n);
  for ( i = 0; i < n; i++ ) vaddrs[i] = i;
  ca_remap_func_xfer_addrs(ca, n, vaddrs, data, dir);
  ALLOCV_END(holder);
}

ca_operation_function_t ca_remap_func = {
  -1,                          /* obj_type — assigned by ca_install_obj_type */
  CA_VIEW_ARRAY,
  free_ca_remap,
  ca_remap_func_clone,
  ca_remap_func_allocate,
  ca_remap_func_attach,
  ca_remap_func_sync,
  ca_remap_func_detach,
  ca_remap_func_fill_data,
  ca_remap_func_create_mask,
  ca_remap_func_xfer_index,
  ca_remap_func_xfer_addrs,
  NULL,                        /* fold_stride: never-fold (per-element gather boundary) */
  ca_remap_func_xfer_stride,
  ca_remap_func_xfer_all,
};


/* ------------------------------------------------------------------- */
/* Ruby wrapper for ca_remap_new.  Validates the (ref, idx) shape /
   data_type invariants at the Ruby boundary, builds the view via
   ca_remap_new, wraps as a CARemap VALUE, and sets the parent linkage.

   Called from the `ca[idx]` same-shape indexer routing (carray_access.c)
   and the sort / partition along-axis gather (carray_sort.c,
   carray_partition.c).  Callers are expected to have already checked the
   routing preconditions (same shape, idx data_type == CA_SIZE);
   ca_remap_setup raises ArgumentError on mismatch as a defensive
   fallback. */
VALUE
rb_ca_remap_new (VALUE cary, VALUE rmapper)
{
  volatile VALUE obj;
  CArray  *ref, *idx;
  CARemap *ca;

  rb_check_carray_object(cary);
  rb_check_carray_object(rmapper);
  TypedData_Get_Struct(cary,    CArray, &carray_data_type, ref);
  TypedData_Get_Struct(rmapper, CArray, &carray_data_type, idx);

  ca  = ca_remap_new(ref, idx);
  obj = ca_wrap_struct(ca);
  rb_ca_set_parent(obj, cary);
  /* Hold a Ruby-side reference to the idx VALUE so its GC lifetime
     covers the view's.  ca->idx is a raw pointer into idx's struct;
     keeping rmapper reachable through the view keeps it alive. */
  rb_ivar_set(obj, rb_intern("remap_idx"), rmapper);
  return obj;
}

/* Read-only accessor for the per-cell index CArray that defines this
   CARemap's mapping.  Returns the same CArray VALUE the caller passed
   to ca[mapper] (= shared reference, not a copy).  Companion to
   CABlock#start / CAStride#strides / CAWindow#count etc. — the view
   hierarchy is preserved so each named view class exposes its own
   defining semantic state. */
static VALUE
rb_ca_remap_mapper (VALUE self)
{
  return rb_ivar_get(self, rb_intern("remap_idx"));
}


void
Init_ca_obj_remap (void)
{
  /* CARemap is a proper Ruby class so users can see "this view is a
     per-element gather" on .class.  No allocator, no initialize, no
     `new` reachable from Ruby — construction is C-internal only.
     CA_OBJ_REMAP integer remains unexported (it's an internal type
     tag, not user-meaningful). */
  rb_cCARemap     = rb_define_class("CARemap",     rb_cCAView);
  rb_cCARemapMask = rb_define_class("CARemapMask", rb_cCARemap);
  rb_undef_alloc_func(rb_cCARemap);
  rb_undef_alloc_func(rb_cCARemapMask);

  ca_remap_func.struct_size = sizeof(CARemap);
  ca_remap_func.pool_bytes  = ca_remap_pool_bytes;
  ca_remap_func.pool_init   = ca_remap_pool_init;

  CA_OBJ_REMAP = ca_install_obj_type(rb_cCARemap,
                                     &caremap_data_type,
                                     rb_cCARemapMask,
                                     &caremap_mask_data_type,
                                     &ca_remap_func, sizeof(ca_remap_func));

  /* Defining semantic state accessor — companion to CABlock#start /
     CAStride#strides / CAWindow#count.  The hierarchy-preserving
     design implies each named view class exposes its own defining
     state so user / test / debugger can ask "how is this view
     mapping?" through ordinary Ruby. */
  rb_define_method(rb_cCARemap, "mapper", rb_ca_remap_mapper, 0);
}
