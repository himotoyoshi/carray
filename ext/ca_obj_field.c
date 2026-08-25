/* ---------------------------------------------------------------------------

  CAField: a CAStride view that exposes one field of a fixlen-record
  parent as an array of that field's type.  Pure typedef of CAStride
  (no extra state); shape matches the parent, with:
    - base_offset = field offset in bytes within one record
    - strides[k]  = parent->bytes * Π_{i>k} parent->dim[i]
                    (row-major stride scaled by record size)
    - data_type   = field's element type (independent of parent's)
    - bytes       = field's element size

---------------------------------------------------------------------------- */

#include "carray.h"
#include "carray_internal.h"   /* per-obj_type view constructors */

extern ca_operation_function_t ca_stride_func;

int8_t CA_OBJ_FIELD;
VALUE rb_cCAField;
VALUE rb_cCAFieldMask;

/* ------------------------------------------------------------------- */

/* Build row-major byte-strides over the parent's record layout and
   delegate to ca_stride_setup.  `offset` becomes the CAStride
   base_offset (in bytes). */
int
ca_field_setup (CAStride *ca, CArray *parent,
                ca_size_t offset, int8_t data_type, ca_size_t bytes)
{
  ca_size_t strides[CA_RANK_MAX];
  int8_t i;

  CA_CHECK_DATA_TYPE(data_type);
  CA_CHECK_BYTES(data_type, bytes);

  if ( offset < 0 ) {
    rb_raise(rb_eRuntimeError, "negative offset");
  }
  if ( data_type == CA_OBJECT ) {
    rb_raise(rb_eCADataTypeError,
             "CA_OBJECT can not to be a data_type for CAField");
  }
  if ( parent->bytes < offset + bytes ) {
    rb_raise(rb_eRuntimeError, "offset or bytes out of range");
  }

  /* strides[k] = parent->bytes × Π_{i>k} parent->dim[i].  Same shape
     as parent because each output element corresponds 1:1 to a
     parent record. */
  {
    ca_size_t s = parent->bytes;
    for (i = parent->ndim - 1; i >= 0; i--) {
      strides[i] = s;
      s *= parent->dim[i];
    }
  }

  ca_stride_setup(ca, CA_OBJ_FIELD, parent,
                  data_type, bytes,
                  parent->ndim, parent->dim, strides, offset);

  return 0;
}

CAStride *
ca_field_new (CArray *parent, ca_size_t offset, int8_t data_type, ca_size_t bytes)
{
  CAStride *ca = (CAStride *) ca_array_alloc(CA_OBJ_FIELD, parent->ndim);
  ca_field_setup(ca, parent, offset, data_type, bytes);
  return ca;
}

/* ------------------------------------------------------------------- */

VALUE
rb_ca_field_new (VALUE cary, ca_size_t offset, int8_t data_type, ca_size_t bytes)
{
  volatile VALUE obj;
  CArray *parent;
  CAStride *ca;
  rb_check_carray_object(cary);
  TypedData_Get_Struct(cary, CArray, &carray_data_type, parent);
  ca  = ca_field_new(parent, offset, data_type, bytes);
  obj = ca_wrap_struct(ca);
  rb_ca_set_parent(obj, cary);
  return obj;
}

/* CArray#field(offset, data_type, bytes: nil) -- returns a CAField view of
   the field at `offset` (in bytes) within each record of `self`.  If
   `data_type` is a CArray, the result is wrapped in a CARefer that
   adopts its element type and trailing dimensions (= struct-of-array
   subview).  If it is a data_class (e.g. CAStruct subclass), the
   CAField is wrapped in a CARecord so encode/decode dispatch is
   carried.  One-arg form delegates to rb_ca_face_field. */
VALUE
rb_ca_field (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE obj, voffset, rtype, ropt, rbytes = Qnil;
  CArray *ca;
  int8_t  data_type;
  ca_size_t offset, bytes;

  if ( argc == 1 ) {
    return rb_ca_face_field(self, argv[0]);
  }

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  /* CArray#field(offset, data_type[, :bytes=>bytes]) */
  /* CArray#field(offset, data_class) */
  /* CArray#field(offset, template) */

  rb_scan_args(argc, argv, "21", (VALUE *) &voffset, (VALUE *) &rtype, (VALUE *) &ropt);
  rb_scan_options(ropt, "bytes", &rbytes);

  offset = NUM2SIZE(voffset);

  if ( rb_obj_is_carray(rtype) ) {
    CArray *ct;
    ca_size_t dim[CA_RANK_MAX];
    int8_t ndim;
    int8_t i, j;
    TypedData_Get_Struct(rtype, CArray, &carray_data_type, ct);
    data_type = CA_FIXLEN;
    bytes     = ct->bytes * ct->elements;
    obj = rb_ca_field_new(self, offset, data_type, bytes);
    ndim = ca->ndim + ct->ndim;
    for (i=0; i<ca->ndim; i++) {
      dim[i] = ca->dim[i];
    }
    for (j=0; j<ct->ndim; j++, i++) {
      dim[i] = ct->dim[j];
    }
    obj = rb_ca_refer_new(obj, ct->data_type, ndim, dim, ct->bytes, 0);
  }
  else {
    rb_ca_guess_type_and_bytes(rtype, rbytes, &data_type, &bytes);
    obj = rb_ca_field_new(self, offset, data_type, bytes);
    /* When rtype is a data_class, wrap the CAField in a CARecord so the
       view carries the encode/decode dispatch. */
    if ( rb_obj_is_data_class(rtype) ) {
      obj = rb_funcall(rb_const_get(rb_cObject, rb_intern("CARecord")),
                       rb_intern("wrap"), 2, obj, rtype);
    }
  }

  return obj;
}

/* Pure CAStride subclasses share castride_data_type, so no custom
   allocator is needed — ALLOC(CAStride) via rb_cs_s_allocate is
   already correct for CAField too. */

static VALUE
rb_ca_field_initialize_copy (VALUE self, VALUE other)
{
  CAStride *ca, *cs;

  TypedData_Get_Struct(self,  CAStride, &castride_data_type, ca);
  TypedData_Get_Struct(other, CAStride, &castride_data_type, cs);

  if ( ca_func[CA_OBJ_FIELD].pool_init ) {
    ca_array_pool_alloc(ca, CA_OBJ_FIELD, cs->parent->ndim);
  }
  /* Reconstruct from the source's base_offset / data_type / bytes;
     ca_field_setup recomputes strides from parent's shape. */
  ca_field_setup(ca, cs->parent, cs->base_offset, cs->data_type, cs->bytes);

  return self;
}

void
Init_ca_obj_field (void)
{
  /* rb_cCAField and rb_cCAFieldMask are declared upfront in
     ruby_carray.c so their inheritance chain (CAField < CAStride <
     CAView < CArray) is established before this Init runs. */

  CA_OBJ_FIELD = ca_install_obj_type(rb_cCAField,
                                     &castride_data_type,
                                     rb_cCAFieldMask,
                                     &castride_mask_data_type,
                                     &ca_stride_func, sizeof(ca_stride_func));
  rb_define_const(rb_cObject, "CA_OBJ_FIELD", INT2NUM(CA_OBJ_FIELD));

  rb_define_method(rb_cCArray, "field", rb_ca_field, -1);

  rb_define_method(rb_cCAField, "initialize_copy",
                                      rb_ca_field_initialize_copy, 1);
}
