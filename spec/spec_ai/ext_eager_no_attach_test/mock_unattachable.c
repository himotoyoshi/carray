/* ---------------------------------------------------------------------------

  mock_unattachable.c

  Test fixture for PROPOSAL_EAGER_ELEMENTWISE_NO_ATTACH (E.1, 2026-06-10).

  Defines a CArray view class `CAMockUnattachable < CAStride` whose
  `attach` / `allocate` op-table slots raise an exception when called.
  All other slots (`xfer_stride` / `xfer_addrs` / `xfer_index` / `xfer_all`
  / `sync` / `detach` / `fill_data` / `create_mask`) inherit from
  `ca_stride_func` and operate identically to a pass-through CAStride view
  (= identity stride mapping over the parent).

  Usage:
    mock = CAMockUnattachable.wrap(parent)
    a + mock   # E.2 pre: raises (ca_attach_n on mock invokes raising attach)
               # E.2 post: succeeds (driver consumes mock via xfer_stride
                            per-region, no operand attach)

  This pins the core invariant of PROPOSAL_EAGER_ELEMENTWISE_NO_ATTACH:
  "driver does not attach input-only operands".

---------------------------------------------------------------------------- */

#include "carray.h"

extern ca_operation_function_t ca_stride_func;

static int8_t CA_OBJ_MOCK_UNATTACHABLE;

static VALUE rb_cCAMockUnattachable;
static VALUE rb_cCAMockUnattachableMask;

/* --- raising op-table slots ----------------------------------------- */

static void
ca_mock_func_allocate (void *ap)
{
  (void) ap;
  rb_raise(rb_eRuntimeError,
           "CAMockUnattachable: allocate() must not be called "
           "(input-only operand should be consumed via xfer_stride)");
}

static void
ca_mock_func_attach (void *ap)
{
  (void) ap;
  rb_raise(rb_eRuntimeError,
           "CAMockUnattachable: attach() must not be called "
           "(input-only operand should be consumed via xfer_stride)");
}

/* --- op table = ca_stride_func with attach/allocate overridden ------- */

static ca_operation_function_t ca_mock_func;

/* --- constructor ---------------------------------------------------- */

/* Wrap a parent CArray as a CAMockUnattachable view with identity stride
   mapping (= same shape, same dtype, base_offset=0, strides[k] = bytes *
   Π_{i>k} parent.dim[i]).  Pure pass-through; only attach/allocate raise. */
static VALUE
rb_ca_mock_wrap (VALUE self_class, VALUE parent_obj)
{
  CArray   *parent;
  CAStride *ca;
  ca_size_t strides[CA_RANK_MAX];
  ca_size_t s;
  int8_t    i, ndim;
  VALUE     obj;

  (void) self_class;
  rb_check_carray_object(parent_obj);
  TypedData_Get_Struct(parent_obj, CArray, &carray_data_type, parent);

  ndim = parent->ndim;
  s = parent->bytes;
  for (i = ndim - 1; i >= 0; i--) {
    strides[i] = s;
    s *= parent->dim[i];
  }

  ca = ALLOC(CAStride);
  /* ALLOC does not zero the struct.  The pool framework keys on _pool
     (NULL = legacy ALLOC_N path); leaving it as garbage makes
     ca_stride_setup skip the dim/strides allocation and crash.  Take the
     legacy path explicitly. */
  ca->_pool = NULL;
  ca_stride_setup(ca, CA_OBJ_MOCK_UNATTACHABLE, parent,
                  parent->data_type, parent->bytes,
                  ndim, parent->dim, strides, 0);

  obj = ca_wrap_struct(ca);
  rb_ca_set_parent(obj, parent_obj);
  return obj;
}

/* --- Init ----------------------------------------------------------- */

void
Init_mock_unattachable (void)
{
  /* Copy ca_stride_func, override attach/allocate to raise. */
  ca_mock_func = ca_stride_func;
  ca_mock_func.attach   = ca_mock_func_attach;
  ca_mock_func.allocate = ca_mock_func_allocate;

  rb_cCAMockUnattachable     = rb_define_class("CAMockUnattachable",
                                               rb_cCAStride);
  rb_cCAMockUnattachableMask = rb_define_class("CAMockUnattachableMask",
                                               rb_cCAMockUnattachable);

  CA_OBJ_MOCK_UNATTACHABLE = ca_install_obj_type(rb_cCAMockUnattachable,
                                                 &castride_data_type,
                                                 rb_cCAMockUnattachableMask,
                                                 &castride_mask_data_type,
                                                 &ca_mock_func, sizeof(ca_mock_func));

  rb_define_const(rb_cObject, "CA_OBJ_MOCK_UNATTACHABLE",
                  INT2NUM(CA_OBJ_MOCK_UNATTACHABLE));

  rb_define_singleton_method(rb_cCAMockUnattachable, "wrap",
                             rb_ca_mock_wrap, 1);
}
