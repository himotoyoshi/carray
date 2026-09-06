/* ---------------------------------------------------------------------------

  CATranspose: a CAStride view that permutes the parent's dimension
  order.  Pure typedef of CAStride; only the dim / stride layout
  differs (no extra state).

---------------------------------------------------------------------------- */

#include "carray.h"
#include "ca_obj_face.h"  /* CA_FACE_LIFT_IF_FACE */

extern ca_operation_function_t ca_stride_func;

static int8_t CA_OBJ_TRANSPOSE;

VALUE rb_cCATrans;
VALUE rb_cCATransMask;

/* ------------------------------------------------------------------- */

int
ca_trans_setup (CAStride *ca, CArray *parent, ca_size_t *imap)
{
  int8_t ndim;
  ca_size_t *dim0;
  ca_size_t newdim[CA_RANK_MAX];
  ca_size_t strides[CA_RANK_MAX];
  ca_size_t parent_byte_stride[CA_RANK_MAX];
  ca_size_t map[CA_RANK_MAX];
  int8_t i;
  ca_size_t idim, s;

  ndim = parent->ndim;
  dim0 = parent->dim;

  for (i = 0; i < ndim; i++) map[i] = -1;
  for (i = 0; i < ndim; i++) {
    idim = imap[i];
    if (idim < 0 || idim >= ndim) {
      rb_raise(rb_eRuntimeError,
               "specified %i-th dimension number out of range", i);
    }
    if (map[idim] != -1) {
      rb_raise(rb_eRuntimeError,
               "specified %i-th dimension number is duplicated", i);
    }
    map[idim] = i;
    newdim[i] = dim0[idim];
  }

  /* parent_byte_stride[k] = bytes * Π_{j>k} parent->dim[j] */
  s = parent->bytes;
  for (i = ndim - 1; i >= 0; i--) {
    parent_byte_stride[i] = s;
    s *= dim0[i];
  }
  for (i = 0; i < ndim; i++) {
    strides[i] = parent_byte_stride[imap[i]];
  }

  ca_stride_setup(ca, CA_OBJ_TRANSPOSE, parent,
                  parent->data_type, parent->bytes,
                  ndim, newdim, strides, 0);
  return 0;
}

CAStride *
ca_trans_new (CArray *parent, ca_size_t *imap)
{
  CAStride *ca = (CAStride *) ca_array_alloc(CA_OBJ_TRANSPOSE, parent->ndim);
  ca_trans_setup(ca, parent, imap);
  return ca;
}

/* ------------------------------------------------------------------- */

VALUE
rb_ca_trans_new (VALUE cary, ca_size_t *imap)
{
  volatile VALUE obj;
  CArray *parent;
  CAStride *ca;
  rb_check_carray_object(cary);
  TypedData_Get_Struct(cary, CArray, &carray_data_type, parent);
  ca = ca_trans_new(parent, imap);
  obj = ca_wrap_struct(ca);
  rb_ca_set_parent(obj, cary);
  return obj;
}

/* CArray#transpose(*imap) -- returns a CATranspose view.  With no
   args, reverses the dimension order (= same as `.T`).  With argc
   == ndim, uses imap as the per-axis permutation. */
static VALUE
rb_ca_trans (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE obj, ropt;
  CArray *ca;
  ca_size_t imap[CA_RANK_MAX];
  int8_t i;

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  /* The axis order is positional only.  Reject a trailing Hash here so a
     keyword argument does not read as an argument-count mismatch. */
  ropt = rb_pop_options(&argc, &argv);
  rb_reject_options(ropt);

  if (argc == 0) {
    for (i = 0; i < ca->ndim; i++) imap[i] = ca->ndim - i - 1;
  }
  else if (argc == ca->ndim) {
    for (i = 0; i < ca->ndim; i++) imap[i] = NUM2SIZE(argv[i]);
  }
  else {
    rb_raise(rb_eArgError, "# of arguments should be equal to ndim");
  }

  obj = rb_ca_trans_new(self, imap);
  CA_WRAPPER_LIFT(obj, self, ca);
  return obj;
}

static VALUE
rb_ca_trans_initialize_copy (VALUE self, VALUE other)
{
  CAStride *ca, *cs;
  TypedData_Get_Struct(self,  CAStride, &castride_data_type, ca);
  TypedData_Get_Struct(other, CAStride, &castride_data_type, cs);
  if ( ca_func[CA_OBJ_TRANSPOSE].pool_init ) {
    ca_array_pool_alloc(ca, CA_OBJ_TRANSPOSE, cs->ndim);
  }
  ca_stride_setup(ca, CA_OBJ_TRANSPOSE, cs->parent,
                  cs->data_type, cs->bytes,
                  cs->ndim, cs->dim, cs->strides, cs->base_offset);
  return self;
}

void
Init_ca_obj_transpose (void)
{
  rb_cCATrans = rb_define_class("CATranspose", rb_cCAStride);
  rb_cCATransMask = rb_define_class("CATransposeMask", rb_cCATrans);

  CA_OBJ_TRANSPOSE = ca_install_obj_type(rb_cCATrans,
                                         &castride_data_type,
                                         rb_cCATransMask,
                                         &castride_mask_data_type,
                                         &ca_stride_func, sizeof(ca_stride_func));
  rb_define_const(rb_cObject, "CA_OBJ_TRANSPOSE", INT2NUM(CA_OBJ_TRANSPOSE));

  rb_define_method(rb_cCArray, "transpose", rb_ca_trans, -1);
  rb_define_alias(rb_cCArray, "T", "transpose");
  rb_define_method(rb_cCATrans, "initialize_copy",
                                      rb_ca_trans_initialize_copy, 1);
}
