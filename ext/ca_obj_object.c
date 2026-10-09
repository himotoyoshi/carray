/* ---------------------------------------------------------------------------

  CAObject: the per-element Ruby-callback bridge view.  Each cell read /
  write forwards to the user object's fetch_* / store_* (and optional
  bulk copy_* / sync_* / *_block) callbacks.  Also the base for Faces
  authored in Ruby (face: true wraps a storage parent).

---------------------------------------------------------------------------- */

/*
  CAObject's template methods

  * Initializer

      initialize(...)

        call super(type, dim, bytes) in this method

  * For readable array

      fetch_addr(addr)  ### at least one of these two methods
      fetch_index(idx)

      copy_data(data)

  * For writable array

      store_addr(addr, val) ### at lease one of these two methods
      store_index(idx, val)

      sync_data(data)
      fill_data(value)

 */

#include "carray.h"
#include "carray_internal.h"
#include "ca_obj_face.h"  /* ca_face_* helpers for Face mode shortcuts */

static size_t
ca_object_dsize (const void *ap)
{
  const CAObject *ca = (const CAObject *) ap;
  return sizeof(CAObject) + ca->ndim * sizeof(ca_size_t);
}

/* Pool framework hooks: single ndim-sized tail (dim) in the _pool buffer
   (uniform alloc/free discipline). */
static size_t
ca_object_pool_bytes (int8_t ndim)
{
  ca_size_t n = (ndim > 0) ? ndim : 1;
  return (size_t) n * sizeof(ca_size_t);
}

static void
ca_object_pool_init (void *ap, int8_t ndim)
{
  CAObject *ca = (CAObject *) ap;
  ca->dim = (ca_size_t *) ca->_pool;
}

const rb_data_type_t caobject_data_type = {
    .parent = &caview_data_type,
    .wrap_struct_name = "CAObject",
    .function = {
        .dmark = ca_mark,
        .dfree = ca_free,
        .dsize = ca_object_dsize,
        .dcompact = NULL
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

VALUE rb_cCAObject;

/* ---------------------------------------------------------------------- */

static size_t
ca_objectmask_dsize (const void *ap)
{
  const CAObjectMask *ca = (const CAObjectMask *) ap;
  return sizeof(CAObjectMask) + ca->ndim * sizeof(ca_size_t);
}

/* The mask reads and writes through its CAObject, and its cache is the
   CAObject's; it keeps the CAObject alive. */
static void
ca_objmask_mark (void *ap)
{
  CAObjectMask *ca = (CAObjectMask *) ap;
  rb_gc_mark(ca->array);
  ca_mark(ap);
}

const rb_data_type_t caobjectmask_data_type = {
    .parent = &carray_data_type,
    .wrap_struct_name = "CAObjectMask",
    .function = {
        .dmark = ca_objmask_mark,
        .dfree = ca_free,
        .dsize = ca_objectmask_dsize,
        .dcompact = NULL
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

static int8_t CA_OBJ_OBJECT_MASK;
VALUE rb_cCAObjectMask;

static CAObjectMask *
ca_objmask_new (VALUE array, int8_t ndim, ca_size_t *dim)
{
  CAObjectMask *ca = ALLOC(CAObjectMask);
  /* CA_OBJ_OBJECT_MASK registers no pool_init, so it lives on the legacy
     ALLOC_N path (dim allocated separately, freed via free_ca_wrap's else
     branch).  ALLOC leaves _pool uninitialized; carray_setup_i keys the
     dim allocation on _pool == NULL, so leaving it as garbage skips the
     allocation and crashes the memcpy.  Force the legacy path. */
  ca->_pool = NULL;
  ca_wrap_setup_null((CArray *)ca, CA_BOOLEAN, ndim, dim, 0, NULL);
  ca->obj_type = CA_OBJ_OBJECT_MASK;
  ca->array = array;
  ca->cache = NULL;
  ca->holds = 0;

  return ca;
}

static VALUE
ca_objmask_mask_data (void *ap)
{
  CAObjectMask *ca = (CAObjectMask *) ap;
  return rb_funcall(rb_ivar_get(ca->array, rb_intern("__data__")), 
                    rb_intern("mask"), 0);
}

/* Calls recv.mid(arg(ap)) with *slot pointing at a caller's buffer for
   the duration, and puts *slot back however the call leaves.  The bulk
   bridge lends the buffer this way so that copy_data / sync_data write
   straight into it; a raise that skipped the restore would leave the
   array pointing at a buffer its caller is about to free. */

typedef struct {
  char  **slot;
  char   *saved;
  VALUE   recv;
  ID      mid;
  VALUE (*arg)(void *);
  void   *ap;
} ca_object_lend_t;

static VALUE
ca_object_lend_body (VALUE varg)
{
  ca_object_lend_t *l = (ca_object_lend_t *) varg;
  return rb_funcall(l->recv, l->mid, 1, l->arg(l->ap));
}

static VALUE
ca_object_lend_restore (VALUE varg)
{
  ca_object_lend_t *l = (ca_object_lend_t *) varg;
  *l->slot = l->saved;
  return Qnil;
}

static void
ca_object_call_lending (char **slot, void *ptr, VALUE recv, const char *mid,
                        VALUE (*arg)(void *), void *ap)
{
  ca_object_lend_t l;
  l.slot  = slot;
  l.saved = *slot;
  l.recv  = recv;
  l.mid   = rb_intern(mid);
  l.arg   = arg;
  l.ap    = ap;
  *slot = (char *) ptr;
  rb_ensure(ca_object_lend_body, (VALUE) &l,
            ca_object_lend_restore, (VALUE) &l);
}

/* Calls recv.mid(*argv), where some of argv are transient wraps of a
   caller's buffer (ca_object_wrap_transient), and takes the buffer back
   from each of them however the call leaves.  The caller frees its buffer
   when it returns, and a wrap outlives the call: the collector scans the
   machine stack conservatively and still finds it there, and an object
   wrap is marked cell by cell -- through a buffer that is gone.  A wrap
   taken back points at nothing; a hook that kept it holds an empty
   handle, not a stale one. */

typedef struct {
  VALUE        recv;
  ID           mid;
  int          argc;
  const VALUE *argv;
  int          ntrans;
  const VALUE *trans;
} ca_object_hook_t;

static VALUE
ca_object_hook_body (VALUE varg)
{
  ca_object_hook_t *h = (ca_object_hook_t *) varg;
  return rb_funcallv(h->recv, h->mid, h->argc, h->argv);
}

static VALUE
ca_object_hook_release (VALUE varg)
{
  ca_object_hook_t *h = (ca_object_hook_t *) varg;
  int i;
  for ( i = 0; i < h->ntrans; i++ ) {
    ((CArray *) DATA_PTR(h->trans[i]))->ptr = NULL;
  }
  return Qnil;
}

static void
ca_object_call_transient (VALUE recv, const char *mid,
                          int argc, const VALUE *argv,
                          int ntrans, const VALUE *trans)
{
  ca_object_hook_t h;
  h.recv   = recv;
  h.mid    = rb_intern(mid);
  h.argc   = argc;
  h.argv   = argv;
  h.ntrans = ntrans;
  h.trans  = trans;
  rb_ensure(ca_object_hook_body, (VALUE) &h,
            ca_object_hook_release, (VALUE) &h);
}

static VALUE
ca_object_data_of (void *ap)
{
  return rb_ivar_get(((CAObject *) ap)->self, rb_intern("__data__"));
}


/* Forward declaration: ca_object_wrap_transient (defined further down,
   near the data-side xfer functions). */
static VALUE
ca_object_wrap_transient (int8_t data_type, ca_size_t bytes,
                          int8_t ndim, ca_size_t *dim, void *data, int dir);

static void *
ca_objmask_func_clone (void *ap)
{
  CAObjectMask *ca = (CAObjectMask *) ap;
  CAObjectMask *co = ca_objmask_new(ca->array, ca->ndim, ca->dim);
  co->cache = ca->cache;
  return co;
}

/* Whether the CAObject answers one of the mask hooks.  A copy made by dup
   holds its own bits and answers none (array is nil). */
static int
ca_objmask_answers (CAObjectMask *ca, const char *mid)
{
  return ! NIL_P(ca->array) && rb_obj_respond_to(ca->array, rb_intern(mid), Qtrue);
}

static VALUE
ca_objmask_index_of (CAObjectMask *ca, ca_size_t addr)
{
  ca_size_t idx[CA_RANK_MAX];
  VALUE ridx;
  int i;
  ca_addr2index((CArray *) ca, addr, idx);
  ridx = rb_ary_new2(ca->ndim);
  for (i=0; i<ca->ndim; i++) {
    rb_ary_store(ridx, i, SIZE2NUM(idx[i]));
  }
  return ridx;
}

/* The bit the per-cell hooks give for addr (1 / 0 / true / false), or -1
   when the object has neither mask_fetch_addr nor mask_fetch_index. */
static int
ca_objmask_fetch_one (CAObjectMask *ca, ca_size_t addr)
{
  volatile VALUE rval;
  if ( ca_objmask_answers(ca, "mask_fetch_addr") ) {
    rval = rb_funcall(ca->array, rb_intern("mask_fetch_addr"), 1, SIZE2NUM(addr));
  }
  else if ( ca_objmask_answers(ca, "mask_fetch_index") ) {
    rval = rb_funcall(ca->array, rb_intern("mask_fetch_index"), 1,
                      ca_objmask_index_of(ca, addr));
  }
  else {
    return -1;
  }
  if ( rval == Qtrue || rval == Qfalse ) {
    return RTEST(rval);
  }
  return NUM2INT(rval) != 0;
}

/* Hands one bit to the per-cell hooks; 0 when the object has neither
   mask_store_addr nor mask_store_index. */
static int
ca_objmask_store_one (CAObjectMask *ca, ca_size_t addr, boolean8_t bit)
{
  if ( ca_objmask_answers(ca, "mask_store_addr") ) {
    rb_funcall(ca->array, rb_intern("mask_store_addr"), 2,
               SIZE2NUM(addr), INT2NUM(bit ? 1 : 0));
    return 1;
  }
  if ( ca_objmask_answers(ca, "mask_store_index") ) {
    rb_funcall(ca->array, rb_intern("mask_store_index"), 2,
               ca_objmask_index_of(ca, addr), INT2NUM(bit ? 1 : 0));
    return 1;
  }
  return 0;
}

static int
ca_objmask_stores_cells (CAObjectMask *ca)
{
  return ca_objmask_answers(ca, "mask_store_addr") ||
         ca_objmask_answers(ca, "mask_store_index");
}

/* Brings the cache up to date from the hooks that give the mask: the bulk
   one, else the per-cell one.  With neither, the cache is the mask. */
static void
ca_objmask_refresh (CAObjectMask *ca)
{
  boolean8_t *c = (boolean8_t *) ca->cache;
  ca_size_t addr;
  int bit;
  if ( ca_objmask_answers(ca, "mask_copy_data") ) {
    rb_funcall(ca->array, rb_intern("mask_copy_data"), 1,
               ca_objmask_mask_data(ca));
    return;
  }
  for ( addr = 0; addr < ca->elements; addr++ ) {
    if ( ( bit = ca_objmask_fetch_one(ca, addr) ) < 0 ) {
      return;
    }
    c[addr] = (boolean8_t) bit;
  }
}

/* Hands the whole cache to the hooks that take the mask: the bulk one,
   else the per-cell one. */
static void
ca_objmask_push (CAObjectMask *ca)
{
  const boolean8_t *c = (const boolean8_t *) ca->cache;
  ca_size_t addr;
  if ( ca_objmask_answers(ca, "mask_sync_data") ) {
    rb_funcall(ca->array, rb_intern("mask_sync_data"), 1,
               ca_objmask_mask_data(ca));
    return;
  }
  for ( addr = 0; addr < ca->elements; addr++ ) {
    if ( ! ca_objmask_store_one(ca, addr, c[addr]) ) {
      return;
    }
  }
}

/* Reads n bits at addrs while the mask is closed: mask_copy_addrs, else
   the per-cell hooks, else the whole mask brought up to date. */
static void
ca_objmask_get_cells (CAObjectMask *ca, ca_size_t n, ca_size_t *addrs,
                      boolean8_t *bits)
{
  boolean8_t *c = (boolean8_t *) ca->cache;
  ca_size_t i;
  int bit;
  if ( n > 0 && ca_objmask_answers(ca, "mask_copy_addrs") ) {
    volatile VALUE raddrs, rdata;
    ca_size_t dim1[1] = { n };
    raddrs = ca_object_wrap_transient(CA_SIZE, sizeof(ca_size_t),
                                      1, dim1, addrs, CA_XFER_PUT);
    rdata  = ca_object_wrap_transient(CA_BOOLEAN, 1, 1, dim1, bits,
                                      CA_XFER_GET);
    {
      VALUE args[2];
      args[0] = raddrs;
      args[1] = rdata;
      ca_object_call_transient(ca->array, "mask_copy_addrs", 2, args, 2, args);
    }
    return;
  }
  if ( n > 0 && ( bit = ca_objmask_fetch_one(ca, addrs[0]) ) >= 0 ) {
    c[addrs[0]] = bits[0] = (boolean8_t) bit;
    for ( i = 1; i < n; i++ ) {
      c[addrs[i]] = bits[i] = (boolean8_t) ca_objmask_fetch_one(ca, addrs[i]);
    }
    return;
  }
  ca_objmask_refresh(ca);
  for ( i = 0; i < n; i++ ) {
    bits[i] = c[addrs[i]];
  }
}

/* Writes n bits at addrs while the mask is closed, and hands them over:
   one by one to the per-cell hooks, as a list to mask_sync_addrs, or else
   the whole mask to mask_sync_data -- brought up to date first, so that
   the cells not written go back as they were. */
static void
ca_objmask_put_cells (CAObjectMask *ca, ca_size_t n, ca_size_t *addrs,
                      const boolean8_t *bits)
{
  boolean8_t *c = (boolean8_t *) ca->cache;
  ca_size_t i;
  if ( ca_objmask_stores_cells(ca) ) {
    for ( i = 0; i < n; i++ ) {
      c[addrs[i]] = bits[i] ? 1 : 0;
      ca_objmask_store_one(ca, addrs[i], c[addrs[i]]);
    }
    return;
  }
  if ( n > 0 && ca_objmask_answers(ca, "mask_sync_addrs") ) {
    volatile VALUE raddrs, rdata;
    ca_size_t dim1[1] = { n };
    for ( i = 0; i < n; i++ ) {
      c[addrs[i]] = bits[i] ? 1 : 0;
    }
    raddrs = ca_object_wrap_transient(CA_SIZE, sizeof(ca_size_t),
                                      1, dim1, addrs, CA_XFER_PUT);
    rdata  = ca_object_wrap_transient(CA_BOOLEAN, 1, 1, dim1, (void *) bits,
                                      CA_XFER_PUT);
    {
      VALUE args[2];
      args[0] = raddrs;
      args[1] = rdata;
      ca_object_call_transient(ca->array, "mask_sync_addrs", 2, args, 2, args);
    }
    return;
  }
  if ( ca_objmask_answers(ca, "mask_sync_data") ) {
    ca_objmask_refresh(ca);
  }
  for ( i = 0; i < n; i++ ) {
    c[addrs[i]] = bits[i] ? 1 : 0;
  }
  ca_objmask_push(ca);
}

/* Open: the cache is published in ptr, and it is the mask until the sync
   hands it over.  The first attach reads the mask in; an allocate does
   not, since whoever allocates writes every cell. */
static void
ca_objmask_open (CAObjectMask *ca, int refresh)
{
  if ( ca->holds == 0 ) {
    if ( refresh ) {
      ca_objmask_refresh(ca);
    }
    ca->ptr = ca->cache;
  }
  ca->holds++;
}

static void
ca_objmask_func_allocate (void *ap)
{
  ca_objmask_open((CAObjectMask *) ap, 0);
}

static void
ca_objmask_func_attach (void *ap)
{
  ca_objmask_open((CAObjectMask *) ap, 1);
}

static void
ca_objmask_func_sync (void *ap)
{
  CAObjectMask *ca = (CAObjectMask *) ap;
  if ( ca->ptr ) {
    ca_objmask_push(ca);
  }
}

static void
ca_objmask_func_detach (void *ap)
{
  CAObjectMask *ca = (CAObjectMask *) ap;
  if ( ca->holds > 0 && --ca->holds == 0 ) {
    ca->ptr = NULL;
  }
}

static void
ca_objmask_func_xfer_all (void *ap, void *data, int dir)
{
  CAObjectMask *ca = (CAObjectMask *) ap;
  size_t len = (size_t) ca->elements * (size_t) ca->bytes;
  if ( dir == CA_XFER_GET ) {
    if ( ! ca->ptr ) {
      ca_objmask_refresh(ca);
    }
    memcpy(data, ca->cache, len);
  }
  else {
    memcpy(ca->cache, data, len);
    if ( ! ca->ptr ) {
      ca_objmask_push(ca);
    }
  }
}

static void
ca_objmask_func_xfer_addrs (void *ap, ca_size_t n, ca_size_t *addrs,
                            void *data, int dir)
{
  CAObjectMask *ca = (CAObjectMask *) ap;
  boolean8_t *c = (boolean8_t *) ca->cache;
  boolean8_t *d = (boolean8_t *) data;
  ca_size_t i;
  if ( ca->ptr ) {
    for ( i = 0; i < n; i++ ) {
      if ( dir == CA_XFER_GET ) { d[i] = c[addrs[i]]; }
      else                      { c[addrs[i]] = d[i] ? 1 : 0; }
    }
    return;
  }
  if ( dir == CA_XFER_GET ) {
    ca_objmask_get_cells(ca, n, addrs, d);
  }
  else {
    ca_objmask_put_cells(ca, n, addrs, d);
  }
}

static void
ca_objmask_func_xfer_index (void *ap, ca_size_t *idx, void *data, int dir)
{
  ca_size_t addr = ca_index2addr((CArray *) ap, idx);
  ca_objmask_func_xfer_addrs(ap, 1, &addr, data, dir);
}

static void
ca_objmask_func_fill_data (void *ap, void *val)
{
  CAObjectMask *ca = (CAObjectMask *) ap;
  boolean8_t bit = *(boolean8_t *) val ? 1 : 0;
  memset(ca->cache, bit, (size_t) ca->elements);
  if ( ca->ptr ) {
    return;
  }
  if ( ca_objmask_answers(ca, "mask_fill_data") ) {
    rb_funcall(ca->array, rb_intern("mask_fill_data"), 1, INT2NUM(bit));
    return;
  }
  ca_objmask_push(ca);
}

static void
ca_objmask_func_fill_addrs (void *ap, ca_size_t n, ca_size_t *addrs, void *val)
{
  CAObjectMask *ca = (CAObjectMask *) ap;
  volatile VALUE hold = 0;
  boolean8_t *bits = ALLOCV_N(boolean8_t, hold, n > 0 ? n : 1);
  memset(bits, *(boolean8_t *) val ? 1 : 0, (size_t) n);
  ca_objmask_func_xfer_addrs(ca, n, addrs, bits, CA_XFER_PUT);
  ALLOCV_END(hold);
}

/* Mask parallel of the partial-region path.  Same per-axis index-step
   gate; dispatches mask_copy_block / mask_sync_block when the gate passes
   and the callback is defined.  Otherwise falls back to flat-addr
   expansion -> mask xfer_addrs. */
static void
ca_objmask_func_xfer_stride (void *ap, ca_size_t *starts, ca_size_t *counts,
                             ca_size_t *strides, void *data, int dir)
{
  if ( ca_region_is_empty(((CArray *) ap)->ndim, counts) ) return;
  CAObjectMask *ca = (CAObjectMask *) ap;
  int8_t     ndim = ca->ndim;
  ca_size_t  native[CA_RANK_MAX], steps[CA_RANK_MAX], idx[CA_RANK_MAX];
  ca_size_t *vaddrs;
  ca_size_t  base = 0, n = 1, i, s;
  int8_t     k;
  volatile VALUE holder;
  ID         mid_block = (dir == CA_XFER_GET) ? rb_intern("mask_copy_block")
                                              : rb_intern("mask_sync_block");

  s = ca->bytes;
  for (k = ndim - 1; k >= 0; k--) { native[k] = s; s *= ca->dim[k]; }
  for (k = 0; k < ndim; k++) { base += starts[k] * native[k]; n *= counts[k]; }

  if ( n == 0 ) return;

  if ( ! ca->ptr && ca_objmask_answers(ca, dir == CA_XFER_GET ? "mask_copy_block"
                                                            : "mask_sync_block") ) {
    /* The request is over the view's addresses, so a transposed / flat
       request is legal; the per-axis copy_block dispatch below would
       misread it.  See ca_xfer_stride_request_is_axis_box (carray.h). */
    int aligned = ca_xfer_stride_request_is_axis_box(ca, starts, counts, strides);
    for ( k = 0; aligned && k < ndim; k++ ) {
      if ( strides[k] <= 0 || strides[k] % native[k] != 0 ) { aligned = 0; break; }
      steps[k] = strides[k] / native[k];
    }
    if ( aligned ) {
      volatile VALUE rstarts, rcounts, rsteps, rdata;
      rstarts = rb_ary_new_capa(ndim);
      rcounts = rb_ary_new_capa(ndim);
      rsteps  = rb_ary_new_capa(ndim);
      for ( k = 0; k < ndim; k++ ) {
        rb_ary_push(rstarts, SIZE2NUM(starts[k]));
        rb_ary_push(rcounts, SIZE2NUM(counts[k]));
        rb_ary_push(rsteps,  SIZE2NUM(steps[k]));
      }
      rdata = ca_object_wrap_transient(ca->data_type, ca->bytes,
                                       ndim, counts, data, dir);
      {
        VALUE args[4];
        args[0] = rstarts;
        args[1] = rcounts;
        args[2] = rsteps;
        args[3] = rdata;
        ca_object_call_transient(ca->array, rb_id2name(mid_block),
                                 4, args, 1, args + 3);
      }
      return;
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
  ca_objmask_func_xfer_addrs(ca, n, vaddrs, data, dir);
  ALLOCV_END(holder);
}

/* A mask copied by dup holds its own bits, and frees them. */
static void
ca_objmask_free (void *ap)
{
  CAObjectMask *ca = (CAObjectMask *) ap;
  if ( ca != NULL && NIL_P(ca->array) && ca->cache ) {
    xfree(ca->cache);
    ca->cache = NULL;
  }
  free_ca_wrap(ap);
}

static ca_operation_function_t ca_objmask_func = {
  -1, /* CA_OBJ_OBJECT_MASK */
  CA_REAL_ARRAY,
  ca_objmask_free,
  ca_objmask_func_clone,
  ca_objmask_func_allocate,
  ca_objmask_func_attach,
  ca_objmask_func_sync,
  ca_objmask_func_detach,
  ca_objmask_func_fill_data,
  ca_array_func_create_mask,
  ca_objmask_func_xfer_index,
  ca_objmask_func_xfer_addrs,
  NULL,                       /* fold_stride: never-fold (callback boundary) */
  ca_objmask_func_xfer_stride,
  ca_objmask_func_xfer_all,
  .fill_addrs = ca_objmask_func_fill_addrs,
};

static VALUE
rb_ca_objmask_s_allocate (VALUE klass)
{
  CAObjectMask *ca;
  return TypedData_Make_Struct(klass, CAObjectMask, &caobjectmask_data_type, ca);
}

static VALUE
rb_ca_objmask_initialize_copy (VALUE self, VALUE other)
{
  CAObjectMask *ca, *cs;

  TypedData_Get_Struct(self,  CAObjectMask, &caobjectmask_data_type, ca);
  ca_check_uninitialized(ca);
  TypedData_Get_Struct(other, CAObjectMask, &caobjectmask_data_type, cs);

  /* A copy of the mask as it reads now, with bits of its own: writing to
     it does not reach the CAObject's hooks. */
  carray_setup((CArray *)ca, CA_BOOLEAN, cs->ndim, cs->dim, 0, NULL);
  ca->obj_type = CA_OBJ_OBJECT_MASK;
  ca->array = Qnil;
  ca->cache = ca->ptr;
  ca->holds = 0;
  ca_copy_data((CArray *) cs, ca->cache);
  ca->ptr = NULL;

  return self;
}

/* -------------------------------------------------------------------- */

static int
ca_object_setup (CAObject *ca,
               int8_t data_type, int8_t ndim, ca_size_t *dim, ca_size_t bytes)
{
  ca_size_t elements;
  int8_t i;

  /* check arguments */

  CA_CHECK_DATA_TYPE(data_type);
  CA_CHECK_RANK(ndim);
  CA_CHECK_DIM(ndim, dim);
  CA_CHECK_BYTES(data_type, bytes);

  /* calculate total number of elements */

  elements = ca_shape_elements(ndim, dim, bytes);

  ca->obj_type  = CA_OBJ_OBJECT;
  ca->data_type = data_type;
  ca->flags     = 0;
  ca->ndim      = ndim;
  ca->bytes     = bytes;
  ca->elements  = elements;
  ca->ptr       = NULL;
  ca->mask      = NULL;
  ca->parent    = NULL;
  ca->attach    = 0;
  ca->nosync    = 0;

  if ( ! ca->_pool ) {
    ca->dim     = ALLOC_N(ca_size_t, ndim);
  }

  ca->data      = ca_wrap_new_null(data_type, ndim, dim, bytes, NULL);

  memcpy(ca->dim, dim, ndim * sizeof(ca_size_t));

  return 0;
}

static CAObject *
ca_object_new (int8_t data_type, int8_t ndim, ca_size_t *dim, ca_size_t bytes)
{
  CAObject *ca = (CAObject *) ca_array_alloc(CA_OBJ_OBJECT, ndim);
  ca_object_setup(ca, data_type, ndim, dim, bytes);
  return ca;
}

static void
free_ca_object (void *ap)
{
  CAObject *ca = (CAObject *) ap;
  if ( ca != NULL ) {
    /* ca->mask will be GC-ed by Ruby interpreter */
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
ca_object_func_clone (void *ap)
{
  CAObject *ca = (CAObject *) ap;
  return ca_object_new(ca->data_type, ca->ndim, ca->dim, ca->bytes);
}

#define ca_object_func_ptr_at_addr ca_array_func_ptr_at_addr
#define ca_object_func_ptr_at_index ca_array_func_ptr_at_index

/* The bytes of this array's mask.  A fetcher that answers UNDEF marks the
   cell there, whether or not the mask is open. */
static boolean8_t *
ca_object_mask_bytes (CAObject *ca)
{
  if ( ca->mask->obj_type == CA_OBJ_OBJECT_MASK ) {
    return (boolean8_t *) ((CAObjectMask *) ca->mask)->cache;
  }
  return (boolean8_t *) ca->mask->ptr;
}

/* per-cell cores: the addr- and index-primary Ruby-callback bridge logic,
   direction-unified.  The fetch_* / store_* slots below are thin
   forwarders onto these. */
static void
ca_object_xfer_addr_one (CAObject *ca, ca_size_t addr, void *ptr, int dir)
{
  volatile VALUE ridx, raddr, rval;
  int i;
  if ( dir == CA_XFER_GET ) {
    if ( rb_obj_respond_to(ca->self, rb_intern("fetch_addr"), Qtrue) ) {
      raddr = SIZE2NUM(addr);
      rval = rb_funcall(ca->self, rb_intern("fetch_addr"), 1, raddr);
      if ( rval == CA_UNDEF ) {
        ca_create_mask(ca);
        ca_object_mask_bytes(ca)[addr] = 1;
        if ( ca->data_type == CA_OBJECT ) {
          rb_ca_obj2ptr(ca->self, INT2NUM(0), ptr);
        }
      }
      else {
        if ( ca_has_mask(ca) ) {
          ca_object_mask_bytes(ca)[addr] = 0;
        }
        rb_ca_obj2ptr(ca->self, rval, ptr);
      }
    }
    else {
      ca_size_t idx[CA_RANK_MAX];
      ca_addr2index(ca, addr, idx);
      ridx = rb_ary_new2(ca->ndim);
      for (i=0; i<ca->ndim; i++) {
        rb_ary_store(ridx, i, SIZE2NUM(idx[i]));
      }
      rval = rb_funcall(ca->self, rb_intern("fetch_index"), 1, ridx);
      if ( rval == CA_UNDEF ) {
        ca_create_mask(ca);
        ca_object_mask_bytes(ca)[ca_index2addr(ca->mask, idx)] = 1;
        if ( ca->data_type == CA_OBJECT ) {
          rb_ca_obj2ptr(ca->self, INT2NUM(0), ptr);
        }
      }
      else {
        if ( ca_has_mask(ca) ) {
          ca_object_mask_bytes(ca)[ca_index2addr(ca->mask, idx)] = 0;
        }
        rb_ca_obj2ptr(ca->self, rval, ptr);
      }
    }
  }
  else {
    if ( rb_obj_respond_to(ca->self, rb_intern("store_addr"), Qtrue) ) {
      raddr = SIZE2NUM(addr);
      rval = rb_ca_ptr2obj(ca->self, ptr);
      rb_funcall(ca->self, rb_intern("store_addr"), 2, raddr, rval);
    }
    else {
      ca_size_t idx[CA_RANK_MAX];
      ca_addr2index(ca, addr, idx);
      ridx = rb_ary_new2(ca->ndim);
      for (i=0; i<ca->ndim; i++) {
        rb_ary_store(ridx, i, SIZE2NUM(idx[i]));
      }
      rval = rb_ca_ptr2obj(ca->self, ptr);
      rb_funcall(ca->self, rb_intern("store_index"), 2, ridx, rval);
    }
  }
}

static void
ca_object_xfer_index_one (CAObject *ca, ca_size_t *idx, void *ptr, int dir)
{
  volatile VALUE ridx, raddr, rval;
  int i;
  if ( dir == CA_XFER_GET ) {
    if ( rb_obj_respond_to(ca->self, rb_intern("fetch_index"), Qtrue) ) {
      ridx = rb_ary_new2(ca->ndim);
      for (i=0; i<ca->ndim; i++) {
        rb_ary_store(ridx, i, SIZE2NUM(idx[i]));
      }
      rval = rb_funcall(ca->self, rb_intern("fetch_index"), 1, ridx);
      if ( rval == CA_UNDEF ) {
        ca_create_mask(ca);
        ca_object_mask_bytes(ca)[ca_index2addr(ca->mask, idx)] = 1;
        if ( ca->data_type == CA_OBJECT ) {
          rb_ca_obj2ptr(ca->self, INT2NUM(0), ptr);
        }
      }
      else {
        if ( ca_has_mask(ca) ) {
          ca_object_mask_bytes(ca)[ca_index2addr(ca->mask, idx)] = 0;
        }
        rb_ca_obj2ptr(ca->self, rval, ptr);
      }
    }
    else {
      ca_size_t addr = ca_index2addr(ca, idx);
      raddr = SIZE2NUM(addr);
      rval = rb_funcall(ca->self, rb_intern("fetch_addr"), 1, raddr);
      if ( rval == CA_UNDEF ) {
        ca_create_mask(ca);
        ca_object_mask_bytes(ca)[addr] = 1;
        if ( ca->data_type == CA_OBJECT ) {
          rb_ca_obj2ptr(ca->self, INT2NUM(0), ptr);
        }
      }
      else {
        if ( ca_has_mask(ca) ) {
          ca_object_mask_bytes(ca)[addr] = 0;
        }
        rb_ca_obj2ptr(ca->self, rval, ptr);
      }
    }
  }
  else {
    if ( rb_obj_respond_to(ca->self, rb_intern("store_index"), Qtrue) ) {
      ridx = rb_ary_new2(ca->ndim);
      for (i=0; i<ca->ndim; i++) {
        rb_ary_store(ridx, i, SIZE2NUM(idx[i]));
      }
      rval = rb_ca_ptr2obj(ca->self, ptr);
      rb_funcall(ca->self, rb_intern("store_index"), 2, ridx, rval);
    }
    else {
      ca_size_t addr = ca_index2addr(ca, idx);
      raddr = SIZE2NUM(addr);
      rval = rb_ca_ptr2obj(ca->self, ptr);
      rb_funcall(ca->self, rb_intern("store_addr"), 2, raddr, rval);
    }
  }
}

static void
ca_object_func_allocate (void *ap)
{
  CAObject *ca = (CAObject *) ap;
  /* ca->data->ptr = ALLOC_N(char, ca_length(ca)); */
  ca->data->ptr = xmalloc(ca_length(ca));  
  if ( ca_is_object_type(ca->data) ) { /* GC safe */
    VALUE *p = (VALUE *) ca->data->ptr;
    VALUE zero = INT2NUM(0);
    ca_size_t i;
    for (i=0; i<ca->elements; i++) {
      *p++ = zero;
    }
  }
  ca->ptr = ca->data->ptr;
}

/* ca_object_dispatch_{copy,sync,fill}: bulk-path entry points used by
   func_attach / func_sync / func_{copy,sync,fill}_data.

   Contract: prefer user-supplied bulk methods (copy_data / sync_data /
   fill_data) when defined; otherwise fall back to per-element
   fetch_addr / store_addr loops, which themselves dispatch through the
   existing fetch_addr<->fetch_index and store_addr<->store_index mutual
   fallback at line 418/471/523/546.

   Net effect: a CAObject subclass that only defines fetch_addr (or
   only fetch_index) becomes fully usable -- to_ca, attach, sync,
   arithmetic all work via the slow per-element fallback. The fast bulk
   path is opt-in by defining copy_data / sync_data / fill_data. */

static void
ca_object_dispatch_copy (CAObject *ca, void *ptr)
{
  if ( rb_obj_respond_to(ca->self, rb_intern("copy_data"), Qtrue) ) {
    ca_object_call_lending(&ca->data->ptr, ptr, ca->self, "copy_data",
                           ca_object_data_of, ca);
  }
  else {
    ca_size_t addr;
    char *base = (char *) ptr;
    for ( addr = 0; addr < ca->elements; addr++ ) {
      ca_object_xfer_addr_one(ca, addr, base + addr * ca->bytes, CA_XFER_GET);
    }
  }
}

static void
ca_object_dispatch_sync (CAObject *ca, void *ptr)
{
  if ( rb_obj_respond_to(ca->self, rb_intern("sync_data"), Qtrue) ) {
    ca_object_call_lending(&ca->data->ptr, ptr, ca->self, "sync_data",
                           ca_object_data_of, ca);
  }
  else {
    ca_size_t addr;
    char *base = (char *) ptr;
    for ( addr = 0; addr < ca->elements; addr++ ) {
      ca_object_xfer_addr_one(ca, addr, base + addr * ca->bytes, CA_XFER_PUT);
    }
  }
}

static void
ca_object_dispatch_fill (CAObject *ca, void *ptr)
{
  if ( rb_obj_respond_to(ca->self, rb_intern("fill_data"), Qtrue) ) {
    volatile VALUE rval = rb_ca_ptr2obj(ca->self, ptr);
    rb_funcall(ca->self, rb_intern("fill_data"), 1, rval);
  }
  else if ( rb_obj_respond_to(ca->self, rb_intern("fill_block"), Qtrue)
            || rb_obj_respond_to(ca->self, rb_intern("fill_addrs"), Qtrue) ) {
    /* An author who wrote the region slots but not fill_data would otherwise
       get the per-cell default for the one request that is easiest to batch.
       Hand the whole extent to the region path, which reaches `fill_block` in
       one call or `fill_addrs` in address windows. */
    ca_fill_stride_whole(ca, ptr);
  }
  else {
    ca_size_t addr;
    for ( addr = 0; addr < ca->elements; addr++ ) {
      ca_object_xfer_addr_one(ca, addr, ptr, CA_XFER_PUT);
    }
  }
}

static void
ca_object_func_attach (void *ap)
{
  CAObject *ca = (CAObject *) ap;
  /* Face mode → thin-forward to parent (= bypass the Ruby callback; same
     semantic as ca_face_* helpers; CAObject prefix == CAView prefix so
     layout is compatible). */
  if ( ca_is_face(ca) ) {
    ca_face_attach(ap);
    return;
  }
  /* ca->data->ptr = ALLOC_N(char, ca_length(ca)); */
  ca->data->ptr = xmalloc(ca_length(ca));
  if ( ca_is_object_type(ca->data) ) { /* GC safe */
    VALUE *p = (VALUE *) ca->data->ptr;
    VALUE zero = INT2NUM(0);
    ca_size_t i;
    for (i=0; i<ca->elements; i++) {
      *p++ = zero;
    }
  }
  ca->ptr = ca->data->ptr;
  ca_object_dispatch_copy(ca, ca->ptr);
  if ( ca_has_mask(ca->data) ) {
    ca_create_mask(ca);
  }
}

static void
ca_object_func_sync (void *ap)
{
  CAObject *ca = (CAObject *) ap;
  if ( ca_is_face(ca) ) {
    ca_face_sync(ap);
    return;
  }
  ca_object_dispatch_sync(ca, ca->data->ptr);
}

static void
ca_object_func_detach (void *ap)
{
  CAObject *ca = (CAObject *) ap;
  if ( ca_is_face(ca) ) {
    ca_face_detach(ap);
    return;
  }
  xfree(ca->data->ptr);
  ca->data->ptr = NULL;
  ca->ptr = NULL;
}

/* xfer_*: CAObject is a per-element Ruby callback bridge -- a never-fold
   boundary with no axis structure.  GC
   protection (cyclic + rb_protect on GET) for CA_OBJECT element type is
   supplied by the central ca_xfer_* dispatchers, so these per-cell loops run
   raw. */

/* Build a transient borrowed-buffer CArray for partial-region callbacks.

   Used by ca_object_func_xfer_{stride,addrs} (and mask variants) to wrap the
   slot's `data` buffer in a Ruby-visible CArray (counts-shape for block,
   [n] for addrs) before invoking copy_block / sync_block / copy_addrs /
   sync_addrs.  Lifecycle: buffer is owned by the slot caller; the wrapper
   installs free_ca_wrap as dfree, so the underlying ptr is NOT freed when
   the wrapper is GC'd.  Call the hook through ca_object_call_transient,
   which takes the buffer back from the wrapper when the hook returns.

   Object data_type GC safety: for GET (dir == CA_XFER_GET) the buffer may be
   uninitialized garbage on entry, so we INT2NUM(0) zero-fill before
   wrapping (same idiom as ca_object_func_allocate).  PUT entries are
   already valid VALUEs and need no init. */
static VALUE
ca_object_wrap_transient (int8_t data_type, ca_size_t bytes,
                          int8_t ndim, ca_size_t *dim, void *data, int dir)
{
  CAWrap   *wrap;
  ca_size_t n = 1, i;

  for ( i = 0; i < ndim; i++ ) n *= dim[i];

  if ( dir == CA_XFER_GET && data_type == CA_OBJECT ) {
    VALUE *p = (VALUE *) data;
    VALUE zero = INT2NUM(0);
    for ( i = 0; i < n; i++ ) p[i] = zero;
  }

  wrap = ca_wrap_new(data_type, ndim, dim, bytes, NULL, (char *) data);
  return ca_wrap_struct(wrap);
}

static void
ca_object_func_xfer_index (void *ap, ca_size_t *idx, void *data, int dir)
{
  if ( ca_is_face((CAObject *) ap) ) {
    ca_face_xfer_index(ap, idx, data, dir);
    return;
  }
  ca_object_xfer_index_one((CAObject *) ap, idx, data, dir);
}

/* Bulk-addrs path.  When `copy_addrs` / `sync_addrs` is defined, dispatch
   the entire address list in one Ruby call (1-D transient wrappers for
   addrs and data).  Otherwise fall back to a per-cell loop. */
static void
ca_object_func_xfer_addrs (void *ap, ca_size_t n, ca_size_t *addrs,
                           void *data, int dir)
{
  CAObject  *ca = (CAObject *) ap;
  ID         mid;
  if ( ca_is_face(ca) ) {
    ca_face_xfer_addrs(ap, n, addrs, data, dir);
    return;
  }
  mid = (dir == CA_XFER_GET) ? rb_intern("copy_addrs")
                             : rb_intern("sync_addrs");

  if ( n > 0 && rb_obj_respond_to(ca->self, mid, Qtrue) ) {
    volatile VALUE raddrs, rdata;
    ca_size_t dim1[1] = { n };
    raddrs = ca_object_wrap_transient(CA_SIZE, sizeof(ca_size_t),
                                      1, dim1, addrs, CA_XFER_PUT);
    rdata  = ca_object_wrap_transient(ca->data_type, ca->bytes,
                                      1, dim1, data, dir);
    {
      VALUE args[2];
      args[0] = raddrs;
      args[1] = rdata;
      ca_object_call_transient(ca->self, rb_id2name(mid), 2, args, 2, args);
    }
    return;
  }

  {
    char     *d = (char *) data;
    ca_size_t i;
    for ( i = 0; i < n; i++ ) {
      ca_object_xfer_addr_one(ca, addrs[i], d + i * ca->bytes, dir);
    }
  }
}

/* Partial-region dispatch.

   Gate: if `copy_block` / `sync_block` is defined AND all per-axis byte
   strides represent an order-preserving, step >= 1 sub-region of self
   (i.e. strides[k] > 0 && strides[k] % native[k] == 0), invoke the
   high-level callback with index-space (starts, counts, steps) and a
   counts-shaped transient.  Empty region (any counts[k] == 0) returns
   early without invoking the callback.  Otherwise (negative/zero/non-
   aligned strides, or callback undefined) fall back to flat-addr
   expansion -> xfer_addrs (which itself may dispatch to copy_addrs /
   sync_addrs if defined, else per-cell).

   Gate proof: gate passes => for all k, strides[k] = m_k *
   native[k] with m_k >= 1.  If block axis k mapped to self axis pi(k),
   strides[k] = native[pi(k)] would force native[pi(k)] >= native[k] hence
   pi(k) <= k for all k.  native is strictly decreasing in k, so the only
   permutation satisfying pi(k) <= k for all k is identity.  Therefore gate
   passage <=> each block axis k traverses self axis k with step m_k.
   Transpose / fancy / sub-element / negative / zero stride all fail the
   gate and route to addrs path. */
static void
ca_object_func_xfer_stride (void *ap, ca_size_t *starts, ca_size_t *counts,
                            ca_size_t *strides, void *data, int dir)
{
  if ( ca_region_is_empty(((CArray *) ap)->ndim, counts) ) return;
  CAObject  *ca = (CAObject *) ap;
  int8_t     ndim;
  ca_size_t  native[CA_RANK_MAX], steps[CA_RANK_MAX], idx[CA_RANK_MAX];
  ca_size_t *vaddrs;
  ca_size_t  base = 0, n = 1, i, s;
  int8_t     k;
  volatile VALUE holder;
  ID         mid_block;

  if ( ca_is_face(ca) ) {
    ca_face_xfer_stride(ap, starts, counts, strides, data, dir);
    return;
  }

  ndim = ca->ndim;
  mid_block = (dir == CA_XFER_GET) ? rb_intern("copy_block")
                                   : rb_intern("sync_block");

  s = ca->bytes;
  for (k = ndim - 1; k >= 0; k--) { native[k] = s; s *= ca->dim[k]; }
  for (k = 0; k < ndim; k++) { base += starts[k] * native[k]; n *= counts[k]; }

  /* empty region: nothing to transfer */
  if ( n == 0 ) return;

  /* gate:
     - reject strides[k] <= 0 (negative / zero broadcast)
     - C99 makes (-native) % native == 0 true, so we must reject <= 0
       before the % check
     - given %==0 + >0, strides/native >= 1 holds automatically */
  if ( rb_obj_respond_to(ca->self, mid_block, Qtrue) ) {
    /* The request is over the view's addresses, so a transposed / flat
       request is legal; the per-axis copy_block dispatch below would
       misread it.  See ca_xfer_stride_request_is_axis_box (carray.h). */
    int aligned = ca_xfer_stride_request_is_axis_box(ca, starts, counts, strides);
    for ( k = 0; aligned && k < ndim; k++ ) {
      if ( strides[k] <= 0 || strides[k] % native[k] != 0 ) { aligned = 0; break; }
      steps[k] = strides[k] / native[k];   /* >= 1 by construction */
    }
    if ( aligned ) {
      /* high-level per-axis sub-region: dispatch copy_block / sync_block */
      volatile VALUE rstarts, rcounts, rsteps, rdata;
      rstarts = rb_ary_new_capa(ndim);
      rcounts = rb_ary_new_capa(ndim);
      rsteps  = rb_ary_new_capa(ndim);
      for ( k = 0; k < ndim; k++ ) {
        rb_ary_push(rstarts, SIZE2NUM(starts[k]));
        rb_ary_push(rcounts, SIZE2NUM(counts[k]));
        rb_ary_push(rsteps,  SIZE2NUM(steps[k]));
      }
      rdata = ca_object_wrap_transient(ca->data_type, ca->bytes,
                                       ndim, counts, data, dir);
      {
        VALUE args[4];
        args[0] = rstarts;
        args[1] = rcounts;
        args[2] = rsteps;
        args[3] = rdata;
        ca_object_call_transient(ca->self, rb_id2name(mid_block),
                                 4, args, 1, args + 3);
      }
      return;
    }
  }

  /* fallback: flat-addr expansion -> xfer_addrs (per-cell or copy_addrs).
     Handles negative strides, zero stride (broadcast), sub-element, and
     fancy permutations.  Same body as the non-block path. */
  vaddrs = ALLOCV_N(ca_size_t, holder, n);
  for (k = 0; k < ndim; k++) idx[k] = 0;
  for (i = 0; i < n; i++) {
    ca_size_t off = base;
    for (k = 0; k < ndim; k++) off += idx[k] * strides[k];
    vaddrs[i] = off / ca->bytes;
    k = ndim - 1;
    while (k >= 0) { if (++idx[k] < counts[k]) break; idx[k] = 0; k--; }
  }
  ca_object_func_xfer_addrs(ca, n, vaddrs, data, dir);
  ALLOCV_END(holder);
}

static void
ca_object_func_xfer_all (void *ap, void *data, int dir)
{
  if ( ca_is_face((CAObject *) ap) ) {
    ca_face_xfer_all(ap, data, dir);
    return;
  }
  if ( dir == CA_XFER_GET ) {
    ca_object_dispatch_copy((CAObject *) ap, data);
  }
  else {
    ca_object_dispatch_sync((CAObject *) ap, data);
  }
}

static void
ca_object_func_fill_data (void *ap, void *ptr)
{
  if ( ca_is_face((CAObject *) ap) ) {
    ca_face_fill_data(ap, ptr);
    return;
  }
  ca_object_dispatch_fill((CAObject *) ap, ptr);
}

/* Partial fill.  fill_data carries no region and can only say "fill
   everything I cover", so before these two slots existed the only way to
   fill part of a CAObject was the per-cell default -- one store_addr per
   cell.  The region arrives in the view's own address space.  With
   `fill_block` defined (and the region an axis-aligned forward sub-box of
   self) it becomes one call; with `fill_addrs` defined it becomes one call
   per address window.  With neither defined the behaviour is exactly the
   old default, so an existing subclass sees no change. */
static void
ca_object_func_fill_addrs (void *ap, ca_size_t n, ca_size_t *addrs, void *ptr)
{
  CAObject *ca = (CAObject *) ap;
  ID        mid = rb_intern("fill_addrs");

  if ( ca_is_face(ca) ) {
    ca_face_fill_addrs(ap, n, addrs, ptr);
    return;
  }

  if ( n > 0 && rb_obj_respond_to(ca->self, mid, Qtrue) ) {
    volatile VALUE raddrs, rval;
    ca_size_t dim1[1] = { n };
    raddrs = ca_object_wrap_transient(CA_SIZE, sizeof(ca_size_t),
                                      1, dim1, addrs, CA_XFER_PUT);
    rval = rb_ca_ptr2obj(ca->self, ptr);
    {
      VALUE args[2];
      args[0] = raddrs;
      args[1] = rval;
      ca_object_call_transient(ca->self, rb_id2name(mid), 2, args, 1, args);
    }
    return;
  }

  ca_fill_addrs_default(ap, n, addrs, ptr);
}

/* Gate: one region axis per view axis, forward, and a whole number of
   elements per step.  native is strictly decreasing, so steps[k] =
   m_k * native[k] with m_k >= 1 admits only the identity permutation --
   transpose, negative and zero (broadcast) steps, sub-element steps and
   dimension-dropping regions all fail it and take the addrs route.  The
   bound check then confirms the decomposed box lies inside self. */
static void
ca_object_func_fill_stride (void *ap, ca_size_t base, int8_t ndim,
                            ca_size_t *counts, ca_size_t *steps, void *ptr)
{
  CAObject  *ca = (CAObject *) ap;
  ca_size_t  native[CA_RANK_MAX], istep[CA_RANK_MAX], start[CA_RANK_MAX];
  ca_size_t  s;
  int8_t     k;
  ID         mid = rb_intern("fill_block");

  if ( ca_is_face(ca) ) {
    ca_face_fill_stride(ap, base, ndim, counts, steps, ptr);
    return;
  }

  if ( ndim == ca->ndim && rb_obj_respond_to(ca->self, mid, Qtrue) ) {
    int aligned = 1;
    s = 1;
    for ( k = ca->ndim - 1; k >= 0; k-- ) { native[k] = s; s *= ca->dim[k]; }
    for ( k = 0; k < ndim; k++ ) {
      if ( steps[k] <= 0 || steps[k] % native[k] != 0 ) { aligned = 0; break; }
      istep[k] = steps[k] / native[k];
      start[k] = ( base / native[k] ) % ca->dim[k];
      if ( start[k] + ( counts[k] - 1 ) * istep[k] >= ca->dim[k] ) {
        aligned = 0;
        break;
      }
    }
    if ( aligned ) {
      volatile VALUE rstarts, rcounts, rsteps, rval;
      rstarts = rb_ary_new_capa(ndim);
      rcounts = rb_ary_new_capa(ndim);
      rsteps  = rb_ary_new_capa(ndim);
      for ( k = 0; k < ndim; k++ ) {
        rb_ary_push(rstarts, SIZE2NUM(start[k]));
        rb_ary_push(rcounts, SIZE2NUM(counts[k]));
        rb_ary_push(rsteps,  SIZE2NUM(istep[k]));
      }
      rval = rb_ca_ptr2obj(ca->self, ptr);
      rb_funcall(ca->self, mid, 4, rstarts, rcounts, rsteps, rval);
      return;
    }
  }

  /* addrs route: address windows -> ca_fill_addrs -> `fill_addrs` when the
     author defined it, else the per-cell default. */
  ca_fill_stride_via_addrs(ap, base, ndim, counts, steps, ptr);
}

static void
ca_object_func_create_mask (void *ap)
{
  CAObject *ca = (CAObject *) ap;
  volatile VALUE rmask;
  if ( ca_is_face(ca) ) {
    /* Face: storage is the parent, so the mask is the parent's (as for the
       C-level Faces), not the internal __data__'s. */
    ca_view_func_create_mask(ca);
    return;
  }
  if ( rb_obj_respond_to(ca->self, rb_intern("create_mask"), Qtrue) ) {
    rb_funcall(ca->self, rb_intern("create_mask"), 0);
  }
  else {
    rb_raise(rb_eTypeError, "can't create mask for CAObject");
  }
  ca_create_mask(ca->data);
  {
    CAObjectMask *cm = ca_objmask_new(ca->self, ca->ndim, ca->dim);
    cm->cache = ca->data->mask->ptr;
    ca->mask = (CArray *) cm;
    rmask = ca_wrap_struct(ca->mask);
    rb_ivar_set(ca->self, rb_intern("mask"), rmask);
    /* Made while this array is attached, the mask joins it at its level:
       ca_create_mask attaches it once more when this returns. */
    if ( ca->attach > 1 ) {
      ca_objmask_refresh(cm);
      cm->ptr   = cm->cache;
      cm->holds = ca->attach - 1;
    }
  }
}

ca_operation_function_t ca_object_func = {
  -1, /* CA_OBJ_OBJECT */
  CA_VIEW_ARRAY,
  free_ca_object,
  ca_object_func_clone,
  ca_object_func_allocate,
  ca_object_func_attach,
  ca_object_func_sync,
  ca_object_func_detach,
  ca_object_func_fill_data,
  ca_object_func_create_mask,
  ca_object_func_xfer_index,
  ca_object_func_xfer_addrs,
  NULL,                       /* fold_stride: never-fold (callback boundary) */
  ca_object_func_xfer_stride,
  ca_object_func_xfer_all,
  .fill_addrs  = ca_object_func_fill_addrs,
  .fill_stride = ca_object_func_fill_stride,
};

/* ------------------------------------------------------------------- */

static VALUE
rb_ca_object_s_allocate (VALUE klass)
{
  CAObject *ca;
  return TypedData_Make_Struct(klass, CAObject, &caobject_data_type, ca);
}

static VALUE
rb_ca_object_initialize_copy (VALUE self, VALUE other)
{
  volatile VALUE data;
  CAObject *ca, *cs;

  TypedData_Get_Struct(self,  CAObject, &caobject_data_type, ca);
  ca_check_uninitialized(ca);
  TypedData_Get_Struct(other, CAObject, &caobject_data_type, cs);

  if ( ca_func[CA_OBJ_OBJECT].pool_init ) {
    ca_array_pool_alloc(ca, CA_OBJ_OBJECT, cs->ndim);
  }
  ca_object_setup(ca, cs->data_type, cs->ndim, cs->dim, cs->bytes);
  ca->self = self;

  /* preserve flags (e.g. CA_FLAG_READ_ONLY) and structural parent;
     ca_object_setup zeroed both, so restore from the source.
     Copy the @parent ivar directly rather than via rb_ca_set_parent --
     the latter would re-freeze self when parent is frozen, but
     dup/clone semantics for freezing are handled separately by Ruby. */
  ca->flags  = cs->flags;
  ca->parent = cs->parent;
  if ( cs->parent ) {
    volatile VALUE rparent = rb_ivar_get(other, rb_intern("parent"));
    if ( ! NIL_P(rparent) ) {
      rb_ivar_set(self, rb_intern("parent"), rparent);
    }
  }


  data = ca_wrap_struct(ca->data);
  rb_ivar_set(self, rb_intern("__data__"), data);

  ca_update_mask(cs);
  if ( cs->mask ) {
    ca->mask = cs->mask;
    rb_ivar_set(self, rb_intern("mask"),
                      rb_ivar_get(other, rb_intern("mask")));
  }

  return self;
}

static VALUE
rb_ca_object_initialize (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE rtype, rdim, ropt, rbytes = Qnil, rrdonly = Qnil,
                 rparent = Qnil, rface = Qnil, rstorage = Qnil, rdata,
                 rorderable = Qnil, rcomparable = Qnil;
  CAObject *ca;
  int8_t data_type, ndim;
  ca_size_t dim[CA_RANK_MAX];
  ca_size_t bytes;
  int i;

  rb_scan_args(argc, argv, "21", (VALUE *) &rtype, (VALUE *) &rdim, (VALUE *) &ropt);
  rb_scan_options(ropt, "bytes,read_only,parent,face,storage,orderable_storage,comparable_storage",
                  &rbytes, &rrdonly, &rparent, &rface, &rstorage,
                  &rorderable, &rcomparable);

  if ( ( ! NIL_P(rparent) ) && ( ! rb_obj_is_carray(rparent) ) ) {
    rb_raise(rb_eTypeError, "option :parent should be a carray");
  }

  /* :storage is meaningful only under face: true (= it documents the
     parent's storage data_type, which is otherwise inferred from
     parent.data_type).  Reject misuse loudly so the contract is explicit. */
  if ( ! NIL_P(rstorage) && ! RTEST(rface) ) {
    rb_raise(rb_eArgError,
             "CAObject: :storage is only meaningful with face: true "
             "(use the data_type argument for non-Face CAObject)");
  }

  /* Face ordering/search opt-in: a Ruby-defined Face wires the C flags via
     these kwargs instead of a Ruby callback, so a Face can still be
     authored C-only.  Both are meaningful only under face: true. */
  if ( ( RTEST(rorderable) || RTEST(rcomparable) ) && ! RTEST(rface) ) {
    rb_raise(rb_eArgError,
             "CAObject: :orderable_storage / :comparable_storage are only "
             "meaningful with face: true");
  }

  /* face: true requires :parent.  Under Face semantics the parent is the
     true storage owner and CAObject itself carries the semantic identity.
     The declared data_type is the SURFACE (= what dispatch sees);
     parent.data_type is the STORAGE.  They may differ (= NonNumeric Face
     declares surface = CA_FIXLEN to gate mkkernel numeric ops while
     storage stays e.g. int64). */
  if ( RTEST(rface) ) {
    if ( NIL_P(rparent) ) {
      rb_raise(rb_eArgError,
               "CAObject Face mode (= face: true) requires :parent option "
               "(= storage CArray)");
    }
  }

  rb_ca_guess_type_and_bytes(rtype, rbytes, &data_type, &bytes);

  Check_Type(rdim, T_ARRAY);
  CA_CHECK_RANK(RARRAY_LEN(rdim));     /* before dim[] is filled */

  ndim = RARRAY_LEN(rdim);
  for (i=0; i<ndim; i++) {
    dim[i] = NUM2SIZE(rb_ary_entry(rdim, i));
  }

  TypedData_Get_Struct(self, CAObject, &caobject_data_type, ca);
  ca_check_uninitialized(ca);
  ca_object_setup(ca, data_type, ndim, dim, bytes);
  ca->self = self;

  rdata = ca_wrap_struct(ca->data);

  rb_ivar_set(self, rb_intern("__data__"), rdata);

  if ( RTEST(rrdonly) ) {
    ca_set_flag(ca, CA_FLAG_READ_ONLY);
  }

  if ( ! NIL_P(rparent) ) {
    CArray *cp;
    TypedData_Get_Struct(rparent, CArray, &carray_data_type, cp);
    ca->parent = cp;
    rb_ca_set_parent(self, rparent);

    /* Face mode invariants.  The check the author opts into depends on
       whether :storage is explicit:
       - :storage omitted  → "surface == storage" contract:
                             surface (= declared data_type) must equal
                             parent.data_type.  This catches typos for
                             Numeric Face authors who didn't intend
                             surface/storage to differ.
       - :storage given    → "surface != storage" opted-in:
                             surface is free (= e.g. CA_FIXLEN for
                             NonNumeric Face), :storage must agree with
                             parent.data_type, and bytes must match. */
    if ( RTEST(rface) ) {
      if ( bytes != cp->bytes ) {
        rb_raise(rb_eTypeError,
                 "CAObject Face: bytes mismatch "
                 "(declared=%lld, parent=%lld)",
                 (long long) bytes, (long long) cp->bytes);
      }
      if ( NIL_P(rstorage) ) {
        /* surface == storage contract */
        if ( cp->data_type != data_type ) {
          rb_raise(rb_eTypeError,
                   "CAObject Face: parent data_type mismatch "
                   "(declared=%d, parent=%d).  Use :storage option to "
                   "opt into surface != storage (NonNumeric Face).",
                   (int) data_type, (int) cp->data_type);
        }
      }
      else {
        /* opted-in surface != storage: validate :storage against parent */
        int8_t declared_storage;
        ca_size_t declared_storage_bytes;
        rb_ca_guess_type_and_bytes(rstorage, Qnil,
                                   &declared_storage, &declared_storage_bytes);
        if ( cp->data_type != declared_storage ) {
          rb_raise(rb_eTypeError,
                   "CAObject Face: :storage mismatch "
                   "(declared=%d, parent.data_type=%d)",
                   (int) declared_storage, (int) cp->data_type);
        }
      }
      ca_set_flag(ca, CA_FLAG_IS_FACE);
      if ( RTEST(rorderable) ) {
        ca_set_flag(ca, CA_FLAG_FACE_ORDERABLE_STORAGE);
      }
      if ( RTEST(rcomparable) ) {
        ca_set_flag(ca, CA_FLAG_FACE_COMPARABLE_STORAGE);
      }
    }
  }

  ca_update_mask(ca);

  return Qnil;
}

void
Init_ca_obj_object (void)
{
  rb_cCAObjectMask = rb_define_class("CAObjectMask", rb_cCArray);

  CA_OBJ_OBJECT_MASK = ca_install_obj_type(rb_cCAObjectMask, 
  					   &caobjectmask_data_type, 
					   rb_cCArrayMask,
                                           &carray_data_type, &ca_objmask_func, sizeof(ca_objmask_func));
  rb_define_const(rb_cObject, "CA_OBJ_OBJECT_MASK", INT2NUM(CA_OBJ_OBJECT_MASK));

  rb_define_alloc_func(rb_cCAObjectMask, rb_ca_objmask_s_allocate);
  rb_define_method(rb_cCAObjectMask, "initialize_copy",
                                      rb_ca_objmask_initialize_copy, 1);
  

  rb_define_const(rb_cObject, "CA_OBJ_OBJECT", INT2NUM(CA_OBJ_OBJECT));

  /* CA_OBJ_OBJECT is a builtin obj_type: carray_core.c assigned
     ca_func[CA_OBJ_OBJECT] = ca_object_func (without pool hooks) before
     this runs.  Override the three pool slots in place (same pattern as
     CABlock overriding the CAStride baseline). */
  ca_func[CA_OBJ_OBJECT].struct_size = sizeof(CAObject);
  ca_func[CA_OBJ_OBJECT].pool_bytes  = ca_object_pool_bytes;
  ca_func[CA_OBJ_OBJECT].pool_init   = ca_object_pool_init;

  rb_define_alloc_func(rb_cCAObject, rb_ca_object_s_allocate);
  rb_define_method(rb_cCAObject, "initialize_copy",
                                      rb_ca_object_initialize_copy, 1);
  rb_define_method(rb_cCAObject, "initialize",
                                      rb_ca_object_initialize, -1);
                                      
}


