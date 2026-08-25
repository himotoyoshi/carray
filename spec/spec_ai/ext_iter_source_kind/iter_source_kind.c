/* ---------------------------------------------------------------------------

  iter_source_kind.c

  Test fixture for ca_iter_register_source_kind (kernel_iterator source-kind
  registration for externally installed obj_types).

  Defines two view classes that are byte-for-byte the same view — a
  conversion layer over an int32 parent that adds a constant on the way out
  and subtracts it on the way back in, the shape a bridge gem's pixel
  conversion layer takes:

    CAIterOffset             registers CA_ITER_SRC_ATTACH
    CAIterOffsetUnregistered does not

  A third class, CAIterStrideRegistered, is a CAStride-family view that
  registers anyway, with attach overridden to raise.  It pins where the
  lookup sits: the classifier must still recognise it structurally and
  read it directly, so the registration is a no-op and nothing attaches.

  The pair is the point.  Neither class is known to the classifier's
  built-in list, so the unregistered one reproduces what a companion gem
  sees today (every kernel refuses the array with rc=1) and the registered
  one shows that one line in Init is the whole fix.

  Both are installed from outside the core exactly the way a companion gem
  installs one: ca_install_obj_type() plus a complete operation table
  written here.

  Usage:
    v = CAIterOffset.wrap(parent, 100)   # v[i] == parent[i] + 100
    v.sum                                # goes through the iterator
    v[0] = 5                             # parent[0] becomes -95

---------------------------------------------------------------------------- */

#include "carray.h"
#include "ca_kernel_iterator.h"

static int8_t CA_OBJ_ITER_OFFSET;
static int8_t CA_OBJ_ITER_OFFSET_UNREG;

static VALUE rb_cCAIterOffset;
static VALUE rb_cCAIterOffsetMask;
static VALUE rb_cCAIterOffsetUnreg;
static VALUE rb_cCAIterOffsetUnregMask;

typedef struct {
  /* CAView prefix — field-for-field identical to the core's views */
  int16_t    obj_type;
  int8_t     data_type;
  int8_t     ndim;
  int32_t    flags;
  ca_size_t  bytes;
  ca_size_t  elements;
  ca_size_t *dim;
  char      *ptr;
  CArray    *mask;
  char      *_pool;
  CArray    *parent;
  uint32_t   attach;
  uint8_t    nosync;
  /* tail */
  int32_t    offset;
} CAIterOffset;

/* --- value transform ------------------------------------------------ */

/* The conversion itself: n int32 cells, in place. */
static void
offset_apply (CAIterOffset *ca, void *data, ca_size_t n, int dir)
{
  int32_t *p = (int32_t *) data;
  int32_t  d = (dir == CA_XFER_GET) ? ca->offset : -ca->offset;
  ca_size_t i;
  for (i = 0; i < n; i++) {
    p[i] += d;
  }
}

/* --- operation table ------------------------------------------------ */

static void
offset_func_free_object (void *ap)
{
  CAIterOffset *ca = (CAIterOffset *) ap;
  if ( ca != NULL ) {
    ca_free(ca->mask);
    xfree(ca->dim);
    xfree(ca);
  }
}

static CAIterOffset *offset_new (int8_t obj_type, CArray *parent,
                                 int32_t offset);

static void *
offset_func_clone (void *ap)
{
  CAIterOffset *ca = (CAIterOffset *) ap;
  return offset_new(ca->obj_type, ca->parent, ca->offset);
}

static void
offset_func_allocate (void *ap)
{
  CAIterOffset *ca = (CAIterOffset *) ap;
  ca_attach(ca->parent);
  ca->ptr = xmalloc(ca_length((CArray *) ca));
}

/* The SRC_ATTACH contract: materialise the whole view into ptr. */
static void
offset_func_attach (void *ap)
{
  CAIterOffset *ca = (CAIterOffset *) ap;
  ca_attach(ca->parent);
  ca->ptr = xmalloc(ca_length((CArray *) ca));
  memcpy(ca->ptr, ca->parent->ptr, ca_length((CArray *) ca));
  offset_apply(ca, ca->ptr, ca->elements, CA_XFER_GET);
}

/* ... and scatter it back. */
static void
offset_func_sync (void *ap)
{
  CAIterOffset *ca = (CAIterOffset *) ap;
  ca_update_mask((CArray *) ca);
  memcpy(ca->parent->ptr, ca->ptr, ca_length((CArray *) ca));
  offset_apply(ca, ca->parent->ptr, ca->elements, CA_XFER_PUT);
  ca_sync(ca->parent);
}

static void
offset_func_detach (void *ap)
{
  CAIterOffset *ca = (CAIterOffset *) ap;
  xfree(ca->ptr);
  ca->ptr = NULL;
  ca_detach(ca->parent);
}

static void
offset_func_fill_data (void *ap, void *val)
{
  CAIterOffset *ca = (CAIterOffset *) ap;
  int32_t v = *(int32_t *) val - ca->offset;
  ca_fill(ca->parent, &v);
}

static void
offset_func_create_mask (void *ap)
{
  CAIterOffset *ca = (CAIterOffset *) ap;
  ca_create_mask(ca->parent);
  ca->mask = (CArray *) ca_refer_new(ca->parent->mask, CA_BOOLEAN,
                                     ca->ndim, ca->dim, 0, 0);
}

static void
offset_func_xfer_index (void *ap, ca_size_t *idx, void *data, int dir)
{
  CAIterOffset *ca = (CAIterOffset *) ap;
  if ( dir == CA_XFER_GET ) {
    ca_fetch_index(ca->parent, idx, data);
    offset_apply(ca, data, 1, CA_XFER_GET);
  }
  else {
    int32_t v = *(int32_t *) data - ca->offset;
    ca_store_index(ca->parent, idx, &v);
  }
}

static void
offset_func_xfer_addrs (void *ap, ca_size_t n, ca_size_t *addrs,
                        void *data, int dir)
{
  CAIterOffset *ca = (CAIterOffset *) ap;
  if ( dir == CA_XFER_GET ) {
    ca_xfer_addrs(ca->parent, n, addrs, data, CA_XFER_GET);
    offset_apply(ca, data, n, CA_XFER_GET);
  }
  else {
    offset_apply(ca, data, n, CA_XFER_PUT);
    ca_xfer_addrs(ca->parent, n, addrs, data, CA_XFER_PUT);
    offset_apply(ca, data, n, CA_XFER_GET);   /* leave the caller's buffer alone */
  }
}

/* Apply the transform over the caller buffer of a region request.  strides[]
   describes where the cells sit in *this view's* address space, not in the
   caller buffer -- the buffer holds the Pi counts[k] selected cells packed
   row-major, so the transform runs straight down it. */
static void
offset_apply_region (CAIterOffset *ca, ca_size_t *counts, void *data, int dir)
{
  ca_size_t n = 1;
  int8_t j;
  for (j = 0; j < ca->ndim; j++) { n *= counts[j]; }
  offset_apply(ca, data, n, dir);
}

/* Same shape, data_type and bytes as the parent, so the region request
   passes through unchanged.  On PUT the caller's buffer is converted to
   storage values, handed down, and converted back, so the caller sees it
   unchanged. */
static void
offset_func_xfer_stride (void *ap, ca_size_t *starts, ca_size_t *counts,
                         ca_size_t *strides, void *data, int dir)
{
  CAIterOffset *ca = (CAIterOffset *) ap;
  if ( dir == CA_XFER_GET ) {
    ca_xfer_stride(ca->parent, starts, counts, strides, data, CA_XFER_GET);
    offset_apply_region(ca, counts, data, CA_XFER_GET);
  }
  else {
    offset_apply_region(ca, counts, data, CA_XFER_PUT);
    ca_xfer_stride(ca->parent, starts, counts, strides, data, CA_XFER_PUT);
    offset_apply_region(ca, counts, data, CA_XFER_GET);
  }
}

static void
offset_func_xfer_all (void *ap, void *data, int dir)
{
  CAIterOffset *ca = (CAIterOffset *) ap;
  if ( dir == CA_XFER_GET ) {
    ca_copy_data(ca->parent, data);
    offset_apply(ca, data, ca->elements, CA_XFER_GET);
  }
  else {
    offset_apply(ca, data, ca->elements, CA_XFER_PUT);
    ca_xfer_all(ca->parent, data, CA_XFER_PUT);
    offset_apply(ca, data, ca->elements, CA_XFER_GET);
  }
}

static ca_operation_function_t offset_func = {
  0,                          /* obj_type, filled in at install time */
  CA_VIEW_ARRAY,
  offset_func_free_object,
  offset_func_clone,
  offset_func_allocate,
  offset_func_attach,
  offset_func_sync,
  offset_func_detach,
  offset_func_fill_data,
  offset_func_create_mask,
  offset_func_xfer_index,
  offset_func_xfer_addrs,
  .fold_stride = NULL,        /* value transform: never fold through */
  .xfer_stride = offset_func_xfer_stride,
  .xfer_all    = offset_func_xfer_all,
};

/* --- TypedData ------------------------------------------------------ */

static size_t
offset_dsize (const void *ap)
{
  (void) ap;
  return sizeof(CAIterOffset);
}

#define OFFSET_DATA_TYPE(name, str, parent_dt, free_fn)      \
  static const rb_data_type_t name = {                       \
      .wrap_struct_name = str,                               \
      .parent = &parent_dt,                                  \
      .function = {                                          \
          .dmark = ca_mark,                                  \
          .dfree = free_fn,                                  \
          .dsize = offset_dsize,                             \
      },                                                     \
      .flags = RUBY_TYPED_FREE_IMMEDIATELY,                  \
  };

OFFSET_DATA_TYPE(caiteroffset_data_type, "CAIterOffset",
                 caview_data_type, ca_free)
OFFSET_DATA_TYPE(caiteroffset_mask_data_type, "CAIterOffsetMask",
                 caiteroffset_data_type, ca_free_nop)
OFFSET_DATA_TYPE(caiteroffsetunreg_data_type, "CAIterOffsetUnregistered",
                 caview_data_type, ca_free)
OFFSET_DATA_TYPE(caiteroffsetunreg_mask_data_type,
                 "CAIterOffsetUnregisteredMask",
                 caiteroffsetunreg_data_type, ca_free_nop)

/* --- constructor ---------------------------------------------------- */

static CAIterOffset *
offset_new (int8_t obj_type, CArray *parent, int32_t offset)
{
  CAIterOffset *ca = ALLOC(CAIterOffset);

  /* ALLOC does not zero the struct and the pool framework keys on
     _pool; take the legacy path explicitly (see CLAUDE.md). */
  ca->_pool     = NULL;
  ca->obj_type  = obj_type;
  ca->data_type = CA_INT32;
  ca->flags     = 0;
  ca->ndim      = parent->ndim;
  ca->bytes     = parent->bytes;
  ca->elements  = parent->elements;
  ca->ptr       = NULL;
  ca->mask      = NULL;
  ca->dim       = ALLOC_N(ca_size_t, parent->ndim);
  memcpy(ca->dim, parent->dim, parent->ndim * sizeof(ca_size_t));
  ca->parent    = parent;
  ca->attach    = 0;
  ca->nosync    = 0;
  ca->offset    = offset;

  if ( ca_has_mask(parent) ) {
    ca_create_mask((CArray *) ca);
  }
  return ca;
}

static VALUE
rb_offset_wrap (VALUE klass, VALUE parent_obj, VALUE roffset)
{
  CArray *parent;
  CAIterOffset *ca;
  VALUE obj;

  rb_check_carray_object(parent_obj);
  TypedData_Get_Struct(parent_obj, CArray, &carray_data_type, parent);
  if ( parent->data_type != CA_INT32 ) {
    rb_raise(rb_eArgError, "parent must be int32");
  }

  ca = offset_new((klass == rb_cCAIterOffset) ? CA_OBJ_ITER_OFFSET
                                              : CA_OBJ_ITER_OFFSET_UNREG,
                  parent, (int32_t) NUM2INT(roffset));
  obj = ca_wrap_struct(ca);
  rb_ca_set_parent(obj, parent_obj);
  return obj;
}

/* --- CAStride-family view that registers anyway ---------------------- */

extern ca_operation_function_t ca_stride_func;

static int8_t CA_OBJ_ITER_STRIDE_REG;
static VALUE rb_cCAIterStrideReg;
static VALUE rb_cCAIterStrideRegMask;
static ca_operation_function_t stride_reg_func;

/* Registering must not divert a CAStride-family view onto the
   materialising path, so nothing here may ever be called. */
NORETURN(static void stride_reg_func_attach (void *ap));

static void
stride_reg_func_attach (void *ap)
{
  (void) ap;
  rb_raise(rb_eRuntimeError,
           "CAIterStrideRegistered: attach() must not be called "
           "(a CAStride-family source is classified structurally, "
           "ahead of the registration table)");
}

static VALUE
rb_stride_reg_wrap (VALUE klass, VALUE parent_obj)
{
  CArray   *parent;
  CAStride *ca;
  ca_size_t strides[CA_RANK_MAX];
  ca_size_t s;
  int8_t    i, ndim;
  VALUE     obj;

  (void) klass;
  rb_check_carray_object(parent_obj);
  TypedData_Get_Struct(parent_obj, CArray, &carray_data_type, parent);

  ndim = parent->ndim;
  s = parent->bytes;
  for (i = ndim - 1; i >= 0; i--) { strides[i] = s; s *= parent->dim[i]; }

  ca = ALLOC(CAStride);
  ca->_pool = NULL;           /* legacy allocation path; see CLAUDE.md */
  ca_stride_setup(ca, CA_OBJ_ITER_STRIDE_REG, parent,
                  parent->data_type, parent->bytes,
                  ndim, parent->dim, strides, 0);

  obj = ca_wrap_struct(ca);
  rb_ca_set_parent(obj, parent_obj);
  return obj;
}

/* Thin passthrough so the registration guards (out-of-range obj_type,
   non-ATTACH kind) can be pinned from Ruby. */
static VALUE
rb_offset_register (VALUE klass, VALUE robj_type, VALUE rkind)
{
  (void) klass;
  ca_iter_register_source_kind(NUM2INT(robj_type),
                               (uint8_t) NUM2INT(rkind));
  return Qnil;
}

/* --- Init ----------------------------------------------------------- */

void
Init_iter_source_kind (void)
{
  rb_cCAIterOffset     = rb_define_class("CAIterOffset", rb_cCAView);
  rb_cCAIterOffsetMask = rb_define_class("CAIterOffsetMask",
                                         rb_cCAIterOffset);
  rb_cCAIterOffsetUnreg     = rb_define_class("CAIterOffsetUnregistered",
                                              rb_cCAView);
  rb_cCAIterOffsetUnregMask = rb_define_class("CAIterOffsetUnregisteredMask",
                                              rb_cCAIterOffsetUnreg);

  CA_OBJ_ITER_OFFSET = ca_install_obj_type(rb_cCAIterOffset,
                                           &caiteroffset_data_type,
                                           rb_cCAIterOffsetMask,
                                           &caiteroffset_mask_data_type,
                                           &offset_func, sizeof(offset_func));
  CA_OBJ_ITER_OFFSET_UNREG =
    ca_install_obj_type(rb_cCAIterOffsetUnreg,
                        &caiteroffsetunreg_data_type,
                        rb_cCAIterOffsetUnregMask,
                        &caiteroffsetunreg_mask_data_type,
                        &offset_func, sizeof(offset_func));

  stride_reg_func = ca_stride_func;
  stride_reg_func.attach   = stride_reg_func_attach;
  stride_reg_func.allocate = stride_reg_func_attach;

  rb_cCAIterStrideReg     = rb_define_class("CAIterStrideRegistered",
                                            rb_cCAStride);
  rb_cCAIterStrideRegMask = rb_define_class("CAIterStrideRegisteredMask",
                                            rb_cCAIterStrideReg);
  CA_OBJ_ITER_STRIDE_REG = ca_install_obj_type(rb_cCAIterStrideReg,
                                               &castride_data_type,
                                               rb_cCAIterStrideRegMask,
                                               &castride_mask_data_type,
                                               &stride_reg_func, sizeof(stride_reg_func));

  /* The one line a companion gem adds.  Its twin above deliberately
     omits it. */
  ca_iter_register_source_kind(CA_OBJ_ITER_OFFSET, CA_ITER_SRC_ATTACH);

  /* Registered too, and must be ignored: a CAStride-family source is
     recognised from its struct before this table is read. */
  ca_iter_register_source_kind(CA_OBJ_ITER_STRIDE_REG, CA_ITER_SRC_ATTACH);

  rb_define_const(rb_cObject, "CA_OBJ_ITER_OFFSET",
                  INT2NUM(CA_OBJ_ITER_OFFSET));
  rb_define_const(rb_cObject, "CA_OBJ_ITER_OFFSET_UNREG",
                  INT2NUM(CA_OBJ_ITER_OFFSET_UNREG));
  rb_define_const(rb_cObject, "CA_ITER_SRC_ATTACH",
                  INT2NUM(CA_ITER_SRC_ATTACH));
  rb_define_const(rb_cObject, "CA_ITER_SRC_DESCRIPTOR",
                  INT2NUM(CA_ITER_SRC_DESCRIPTOR));
  rb_define_const(rb_cObject, "CA_OBJ_TYPE_MAX_CONST",
                  INT2NUM(CA_OBJ_TYPE_MAX));

  rb_define_singleton_method(rb_cCAIterOffset, "wrap", rb_offset_wrap, 2);
  rb_define_singleton_method(rb_cCAIterOffsetUnreg, "wrap",
                             rb_offset_wrap, 2);
  rb_define_singleton_method(rb_cCAIterStrideReg, "wrap",
                             rb_stride_reg_wrap, 1);

  /* Expose the raise paths so the registration guards can be pinned from
     Ruby without a second fixture. */
  rb_define_singleton_method(rb_cCAIterOffset, "register",
                             rb_offset_register, 2);
}
