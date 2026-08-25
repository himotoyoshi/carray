/* ---------------------------------------------------------------------------

  CAFarray: a CAStride view that exposes a row-major parent in
  column-major (Fortran) order.  Pure typedef of CAStride
  (no extra state); only the dim / stride layout differs.

---------------------------------------------------------------------------- */

#include "carray.h"

extern ca_operation_function_t ca_stride_func;

static int8_t CA_OBJ_FARRAY;

VALUE rb_cCAFarray;
VALUE rb_cCAFarrayMask;

/* ------------------------------------------------------------------- */

/* CAFarray = column-major (Fortran) view of a row-major parent.
   For a parent of shape (d_0, d_1, ..., d_{n-1}) and byte size B, the
   view has shape (d_{n-1}, ..., d_1, d_0) and reads parent's memory in
   column-major order:

       view dim[k]     = parent->dim[n-1-k]
       view strides[k] = parent_byte_stride[n-1-k]
       view base_offset = 0

   where parent_byte_stride[j] = B * Π_{i>j} parent->dim[i]. */
int
ca_farray_setup (CAStride *ca, CArray *parent)
{
  int8_t ndim = parent->ndim;
  ca_size_t parent_byte_stride[CA_RANK_MAX];
  ca_size_t newdim[CA_RANK_MAX];
  ca_size_t strides[CA_RANK_MAX];
  ca_size_t s = parent->bytes;
  int8_t i;

  for (i = ndim - 1; i >= 0; i--) {
    parent_byte_stride[i] = s;
    s *= parent->dim[i];
  }
  for (i = 0; i < ndim; i++) {
    newdim[i]  = parent->dim[ndim - 1 - i];
    strides[i] = parent_byte_stride[ndim - 1 - i];
  }

  ca_stride_setup(ca, CA_OBJ_FARRAY, parent,
                  parent->data_type, parent->bytes,
                  ndim, newdim, strides, 0);

  if (ca_is_scalar(parent)) {
    ca_set_flag(ca, CA_FLAG_SCALAR);
  }
  return 0;
}

CAStride *
ca_farray_new (CArray *parent)
{
  CAStride *ca = (CAStride *) ca_array_alloc(CA_OBJ_FARRAY, parent->ndim);
  ca_farray_setup(ca, parent);
  return ca;
}

/* ------------------------------------------------------------------- */

VALUE
rb_ca_farray_new (VALUE cary)
{
  volatile VALUE obj;
  CArray *parent;
  CAStride *ca;
  rb_check_carray_object(cary);
  TypedData_Get_Struct(cary, CArray, &carray_data_type, parent);
  ca  = ca_farray_new(parent);
  obj = ca_wrap_struct(ca);
  rb_ca_set_parent(obj, cary);
  return obj;
}

/* CArray#farray -- column-major view (dimension order reversed). */
VALUE
rb_ca_farray (VALUE self)
{
  return rb_ca_farray_new(self);
}

static VALUE
rb_ca_farray_initialize_copy (VALUE self, VALUE other)
{
  CAStride *ca, *cs;
  TypedData_Get_Struct(self,  CAStride, &castride_data_type, ca);
  TypedData_Get_Struct(other, CAStride, &castride_data_type, cs);
  if ( ca_func[CA_OBJ_FARRAY].pool_init ) {
    ca_array_pool_alloc(ca, CA_OBJ_FARRAY, cs->ndim);
  }
  ca_stride_setup(ca, CA_OBJ_FARRAY, cs->parent,
                  cs->data_type, cs->bytes,
                  cs->ndim, cs->dim, cs->strides, cs->base_offset);
  return self;
}

void
Init_ca_obj_farray (void)
{
  rb_cCAFarray = rb_define_class("CAFarray", rb_cCAStride);
  rb_cCAFarrayMask = rb_define_class("CAFarrayMask", rb_cCAFarray);

  CA_OBJ_FARRAY = ca_install_obj_type(rb_cCAFarray,
                                      &castride_data_type,
                                      rb_cCAFarrayMask,
                                      &castride_mask_data_type,
                                      &ca_stride_func, sizeof(ca_stride_func));
  rb_define_const(rb_cObject, "CA_OBJ_FARRAY", INT2NUM(CA_OBJ_FARRAY));

  rb_define_method(rb_cCArray, "farray", rb_ca_farray, 0);

  rb_define_method(rb_cCAFarray, "initialize_copy",
                                      rb_ca_farray_initialize_copy, 1);
}
