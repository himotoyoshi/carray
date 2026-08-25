#include "carray.h"
#include "carray_internal.h"   /* per-obj_type view constructors */

static size_t
ca_reduce_dsize (const void *ap)
{
  const CAReduce *ca = (const CAReduce *) ap;
  return sizeof(CAReduce) + ca->ndim * sizeof(ca_size_t);
}

const rb_data_type_t careduce_data_type = {
    .parent = &caview_data_type,
    .wrap_struct_name = "CAReduce",
    .function = {
        .dmark = ca_mark,
        .dfree = ca_free,
        .dsize = ca_reduce_dsize,
        .dcompact = NULL
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

const rb_data_type_t careduce_mask_data_type = {
    .parent = &careduce_data_type,
    .wrap_struct_name = "CAReduceMask",
    .function = {
        .dmark = NULL,
        .dfree = ca_free_nop,
        .dsize = ca_reduce_dsize,
        .dcompact = NULL
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY
};

static int8_t CA_OBJ_REDUCE;

VALUE rb_cCAReduce;
VALUE rb_cCAReduceMask;

/* yard:
  class CAReduce < CAView # :nodoc:
  end
*/

/* ------------------------------------------------------------------- */

int
ca_reduce_setup (CAReduce *ca, CArray *parent, ca_size_t count, ca_size_t offset)
{
  ca_size_t elements;

  /* check arguments */

  if ( ! ca_is_boolean_type(parent) ) {
    rb_raise(rb_eRuntimeError, 
             "[BUG] CAReduce can't inherit other than boolean array");
  }

  elements  = parent->elements / count;

  ca->obj_type  = CA_OBJ_REDUCE;
  ca->data_type = CA_BOOLEAN;     /* data type is fixed to boolean */
  ca->flags     = 0;
  ca->ndim      = 1;
  ca->bytes     = ca_sizeof[CA_BOOLEAN];
  ca->elements  = elements;
  ca->ptr       = NULL;
  ca->mask      = NULL;
  ca->dim       = &ca->elements;

  ca->parent    = parent;
  ca->attach    = 0;
  ca->nosync    = 0;

  ca->count     = count;
  ca->offset    = offset;

  if ( ca_has_mask(parent) ) {
    ca_create_mask(ca);
  }

  if ( ca_is_scalar(parent) ) {
    ca_set_flag(ca, CA_FLAG_SCALAR);
  }

  return 0;
}

CAReduce *
ca_reduce_new (CArray *parent, ca_size_t count, ca_size_t offset)
{
  CAReduce *ca = ALLOC(CAReduce);
  ca_reduce_setup(ca, parent, count, offset);
  return ca;
}

static void
free_ca_reduce (void *ap)
{
  CAReduce *ca = (CAReduce *) ap;
  if ( ca != NULL ) {
    ca_free(ca->mask);
    /* xfree(ca->dim); */
    xfree(ca);
  }
}

/* ------------------------------------------------------------------- */

static void *
ca_reduce_func_clone (void *ap)
{
  CAReduce *ca = (CAReduce *) ap;
  return ca_reduce_new(ca->parent, ca->count, ca->offset);
}

/* addr-list logic lives in xfer_addrs: GET = OR-reduce `count` adjacent parent
   bytes per addr; PUT = broadcast the value to all `count` parent cells.
   fetch_addr/store_addr forward (n==1), xfer_index = index2addr then xfer_addrs.
   All forward to a single home; the legacy slots are removed at step 5. */
static void
ca_reduce_func_xfer_addrs (void *ap, ca_size_t n, ca_size_t *addrs,
                           void *data, int dir)
{
  CAReduce *ca = (CAReduce *) ap;
  char *d = (char *) data;
  ca_size_t k, i;
  for (k=0; k<n; k++) {
    ca_size_t addr = addrs[k];
    char *cell = d + k * ca->bytes;
    if ( dir == CA_XFER_GET ) {
      char q, v = 0;
      for (i=0; i<ca->count; i++) {
        ca_fetch_addr(ca->parent, addr*ca->count + i + ca->offset, &q);
        if ( q ) { v = 1; break; }
      }
      *(char*)cell = v;
    }
    else {
      for (i=0; i<ca->count; i++) {
        ca_store_addr(ca->parent, addr*ca->count + i + ca->offset, cell);
      }
    }
  }
}

static void
ca_reduce_func_xfer_index (void *ap, ca_size_t *idx, void *data, int dir)
{
  ca_size_t addr = ca_index2addr(ap, idx);
  ca_reduce_func_xfer_addrs(ap, 1, &addr, data, dir);
}

/* xfer_stride (PROPOSAL_XFER_PROTOCOL.md §3/§4.4): CAReduce's view dimension
   differs from its parent (each output cell reduces a window of ca->count
   parent cells).  The reduce (GET) / broadcast (PUT) is inherently per-output-
   cell -- there is no STRIDE structure to preserve -- so the region reduces to
   the view's flat output address list and is delivered through CAReduce's own
   xfer_addrs, which encapsulates the parent-window mapping (addr*count+offset).
   data is contiguous (semantics b); no whole-view attach. */
static void
ca_reduce_func_xfer_stride (void *ap, ca_size_t *starts, ca_size_t *counts,
                            ca_size_t *strides, void *data, int dir)
{
  CAReduce  *ca = (CAReduce *) ap;
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
ca_reduce_func_allocate (void *ap)
{
  CAReduce *ca = (CAReduce *) ap;
  ca_attach(ca->parent);
  /* ca->ptr = ALLOC_N(char, ca->elements); */
  ca->ptr = xmalloc(ca_length(ca));  
}

static void
ca_reduce_func_attach (void *ap)
{
  CAReduce *ca = (CAReduce *) ap;
  char *p;
  ca_size_t i;
  ca_attach(ca->parent);
  /* ca->ptr = ALLOC_N(char, ca->elements); */
  ca->ptr = xmalloc(ca_length(ca));  
  p = ca->ptr;
  for (i=0; i<ca->elements; i++) {
    ca_reduce_func_xfer_addrs(ca, 1, &i, p, CA_XFER_GET);
    p++;
  }
}

static void
ca_reduce_func_sync (void *ap)
{
  CAReduce *ca = (CAReduce *) ap;
  char *p;
  ca_size_t i;
  p = ca->ptr;
  ca_attach(ca->parent);
  for (i=0; i<ca->elements; i++) {
    ca_reduce_func_xfer_addrs(ca, 1, &i, p, CA_XFER_PUT);
    p++;
  }
  ca_sync(ca->parent);
  ca_detach(ca->parent);
}

static void
ca_reduce_func_detach (void *ap)
{
  CAReduce *ca = (CAReduce *) ap;
  xfree(ca->ptr);
  ca->ptr = NULL;
  ca_detach(ca->parent);
}

/* xfer_all (PROPOSAL_CHEAP_ATTACH.md rev5 W.5, 2026-06-01):
   Removed ca_attach(parent) silent transitive attach.  The per-cell loop
   uses ca_fetch_addr/ca_store_addr (via xfer_addrs) which dispatch through
   parent's xfer_index slot -- no parent.ptr requirement, §2.5 compliant.
   For cold parent, each cell access traverses parent's view chain (slower
   but correct). */
static void
ca_reduce_func_xfer_all (void *ap, void *data, int dir)
{
  CAReduce *ca = (CAReduce *) ap;
  ca_size_t i;
  char *p = (char *) data;
  for (i=0; i<ca->elements; i++) {
    ca_reduce_func_xfer_addrs(ca, 1, &i, p, dir);
    p++;
  }
}

static void
ca_reduce_func_fill_data (void *ap, void *ptr)
{
  CAReduce *ca = (CAReduce *) ap;
  ca_size_t i;
  ca_attach(ca->parent);
  for (i=0; i<ca->elements; i++) {
    ca_reduce_func_xfer_addrs(ca, 1, &i, ptr, CA_XFER_PUT);
  }
  ca_sync(ca->parent);
  ca_detach(ca->parent);
}

static void
ca_reduce_func_create_mask (void *ap)
{
  CAReduce *ca = (CAReduce *) ap;

  ca_update_mask(ca->parent);
  if ( ! ca->parent->mask ) {
    ca_create_mask(ca->parent);
  }

  ca->mask = (CArray *) ca_reduce_new(ca->parent->mask, ca->count, ca->offset);
}

ca_operation_function_t ca_reduce_func = {
  -1, /* CA_OBJ_REDUCE */
  CA_VIEW_ARRAY,
  free_ca_reduce,
  ca_reduce_func_clone,
  ca_reduce_func_allocate,
  ca_reduce_func_attach,
  ca_reduce_func_sync,
  ca_reduce_func_detach,
  ca_reduce_func_fill_data,
  ca_reduce_func_create_mask,
  ca_reduce_func_xfer_index,
  ca_reduce_func_xfer_addrs,
  NULL,                       /* fold_stride: never-fold (reduce window) */
  ca_reduce_func_xfer_stride,
  ca_reduce_func_xfer_all,
};

/* ------------------------------------------------------------------- */

static VALUE
rb_ca_reduce_s_allocate (VALUE klass)
{
  CAReduce *ca;
  return TypedData_Make_Struct(klass, CAReduce, &careduce_data_type, ca);
}

static VALUE
rb_ca_reduce_initialize_copy (VALUE self, VALUE other)
{
  CAReduce *ca, *cs;

  TypedData_Get_Struct(self,  CAReduce, &careduce_data_type, ca);
  TypedData_Get_Struct(other, CAReduce, &careduce_data_type, cs);

  ca_reduce_setup(ca, cs->parent, cs->count, cs->offset);

  return self;
}

void
Init_ca_obj_reduce (void)
{
  rb_cCAReduce = rb_define_class("CAReduce", rb_cCAView);
  rb_cCAReduceMask = rb_define_class("CAReduceMask", rb_cCAReduce);

  CA_OBJ_REDUCE = ca_install_obj_type(rb_cCAReduce, 
                                      &careduce_data_type, 
				      rb_cCAReduceMask,
				      &careduce_mask_data_type, &ca_reduce_func, sizeof(ca_reduce_func));
  rb_define_const(rb_cObject, "CA_OBJ_REDUCE", INT2NUM(CA_OBJ_REDUCE));

  rb_define_alloc_func(rb_cCAReduce, rb_ca_reduce_s_allocate);
  rb_define_method(rb_cCAReduce, "initialize_copy",
                                      rb_ca_reduce_initialize_copy, 1);
}


