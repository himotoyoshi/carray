/* ---------------------------------------------------------------------------

  CARepeat: a CAStride view that broadcasts the parent over additional
  axes by giving those axes stride 0 (so multiple output positions
  alias the same parent cell).  Pure CAStride typedef; the only extra
  shape rule is the "repeat" vs "data" axis split documented at
  ca_repeat_setup below.  Read-only (writes through a stride-0 axis
  are ambiguous).

---------------------------------------------------------------------------- */

#include "carray.h"
#include "carray_internal.h"   /* per-obj_type view constructors */
#include "ca_obj_face.h"  /* CA_FACE_LIFT_IF_FACE */

extern ca_operation_function_t ca_stride_func;

VALUE rb_cCARepeat;
VALUE rb_cCARepeatMask;

/* CARepeat builds a broadcasting view: for each output axis k,
       count[k] >  0  => "repeat" axis;  view dim[k] = count[k], stride = 0
       count[k] == 0  => "data"   axis;  view dim[k] = parent->dim[j],
                                          stride = parent_byte_stride[j],
                                          where j is the running data-axis index.
   The total number of data axes must equal parent->ndim.

   The result is marked CA_FLAG_READ_ONLY: writing through a stride-0
   axis is ambiguous, since several output positions alias the same
   parent element. */
int
ca_repeat_setup (CAStride *ca, CArray *parent, int8_t ndim, ca_size_t *count)
{
  ca_size_t parent_byte_stride[CA_RANK_MAX];
  ca_size_t newdim[CA_RANK_MAX];
  ca_size_t strides[CA_RANK_MAX];
  ca_size_t total_elements_d = (double) parent->elements;
  ca_size_t nrpt = 1;
  int8_t data_ndim = 0;
  int8_t i, j;

  for (i = 0; i < ndim; i++) {
    if (count[i] < 0) {
      rb_raise(rb_eRuntimeError,
               "negative size for %i-th dimension specified", i);
    }
    if (count[i]) nrpt *= count[i];
    else          data_ndim += 1;
  }
  if (data_ndim != parent->ndim) {
    rb_raise(rb_eRuntimeError,
             "mismatch in ndim between original array and determined by # of dummies");
  }
  if (((double) parent->elements) * nrpt > CA_LENGTH_MAX) {
    rb_raise(rb_eRuntimeError, "too large byte length");
  }
  (void) total_elements_d;

  /* parent_byte_stride[k] = bytes * Π_{i>k} parent->dim[i] */
  {
    ca_size_t s = parent->bytes;
    for (i = parent->ndim - 1; i >= 0; i--) {
      parent_byte_stride[i] = s;
      s *= parent->dim[i];
    }
  }

  j = 0;
  for (i = 0; i < ndim; i++) {
    if (count[i] > 0) {
      newdim[i]  = count[i];
      strides[i] = 0;
    } else {
      newdim[i]  = parent->dim[j];
      strides[i] = parent_byte_stride[j];
      j++;
    }
  }

  ca_stride_setup(ca, CA_OBJ_REPEAT, parent,
                  parent->data_type, parent->bytes,
                  ndim, newdim, strides, 0);

  ca_set_flag(ca, CA_FLAG_READ_ONLY);
  if (ca->mask) {
    ca_set_flag(ca->mask, CA_FLAG_READ_ONLY);
  }
  return 0;
}

CAStride *
ca_repeat_new (CArray *parent, int8_t ndim, ca_size_t *count)
{
  CAStride *ca = (CAStride *) ca_array_alloc(CA_OBJ_REPEAT, ndim);
  ca_repeat_setup(ca, parent, ndim, count);
  return ca;
}

/* ------------------------------------------------------------------- */

VALUE
rb_ca_repeat_new (VALUE cary, int8_t ndim, ca_size_t *count)
{
  volatile VALUE obj;
  CArray *parent;
  CAStride *ca;
  rb_check_carray_object(cary);
  TypedData_Get_Struct(cary, CArray, &carray_data_type, parent);
  ca = ca_repeat_new(parent, ndim, count);
  obj = ca_wrap_struct(ca);
  rb_ca_set_parent(obj, cary);
  return obj;
}

/* rb_ca_repeat -- build a broadcasting view of self.  Each argv[k]
   is either an Integer (= repeat count for that output axis, gets
   stride 0) or the symbol :% (= "data axis", pulls the next
   parent->dim[j] / parent_byte_stride[j] in order).  The number of
   :% positions must equal parent->ndim.

   Two-arg shorthand `repeat(:%, template)` or `repeat(template, :%)`
   matches the receiver's non-singleton axes to `template.shape` and
   fills the rest with explicit repeat counts; used by broadcast
   helpers.

   Single-call no-op (= repeat == 1, every count is 0 or 1) returns a
   CARefer reshape instead of a CARepeat, keeping the chain flat.

   Called by carray_access.c indexer dispatch when the index includes
   the :% symbol (e.g. `a[:%, nil, :%, 3]`). */
VALUE
rb_ca_repeat (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE obj;
  CArray *ca;
  ca_size_t count[CA_RANK_MAX];
  ca_size_t repeat;
  ca_size_t i;

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  if ( argc == 2 &&
       (
         ( argv[0] == ID2SYM(rb_intern("%")) && rb_obj_is_carray(argv[1]) ) ||
         ( argv[1] == ID2SYM(rb_intern("%")) && rb_obj_is_carray(argv[0]) )
       ) ) {
    volatile VALUE args;
    CArray *ct;
    ca_size_t ndim, dim[CA_RANK_MAX];
    int k;
    if ( argv[0] == ID2SYM(rb_intern("%") ) ) {
      TypedData_Get_Struct(argv[1], CArray, &carray_data_type, ct);
    }
    else {
      TypedData_Get_Struct(argv[0], CArray, &carray_data_type, ct);
    }
    if ( ct->ndim < ca->ndim ) {
      rb_raise(rb_eRuntimeError, "invalid ndim to template");
    }
    args = rb_ary_new();
    ndim = 0;
    if ( argv[0] == ID2SYM(rb_intern("%") ) ) {
      k = 0;
      for (i=0; i<ct->ndim; i++) {
        if ( ca->dim[k] == 1 ) {
          rb_ary_push(args, SIZE2NUM(ct->dim[i]));
          k++;
        }
        else if ( ct->dim[i] == ca->dim[k] ) {
          rb_ary_push(args, ID2SYM(rb_intern("%")));
          dim[ndim] = ca->dim[k];
          k++; ndim++;
        }
        else {
          rb_ary_push(args, SIZE2NUM(ct->dim[i]));
        }
      }
      if ( ndim != ca->ndim ) {
        self = rb_ca_refer_new(self, ca->data_type, ndim, dim, ca->bytes, 0);
      }
    }
    else {
      k = ca->ndim - 1;
      for (i=ct->ndim-1; i>=0; i--) {
        if ( ca->dim[k] == 1 ) {
          rb_ary_unshift(args, SIZE2NUM(ct->dim[i]));
          k--;
        }
        else if ( ct->dim[i] == ca->dim[k] ) {
          rb_ary_unshift(args, ID2SYM(rb_intern("%")));
          k--;
        }
        else {
          rb_ary_unshift(args, SIZE2NUM(ct->dim[i]));
        }
      }
      if ( k != 0 ) {
        ndim = 0;
        for (i=0; i<ca->ndim; i++) {
          if ( ca->dim[i] != 1 ) {
            dim[ndim] = ca->dim[i];
            ndim++;
          }
        }
        self = rb_ca_refer_new(self, ca->data_type, ndim, dim, ca->bytes, 0);
      }
    }
    return rb_ca_repeat((int)RARRAY_LEN(args), (VALUE *)RARRAY_CONST_PTR(args), self);
  }

  repeat = 1;
  for (i=0; i<argc; i++) {
    if ( rb_obj_is_kind_of(argv[i], rb_cSymbol) ) {
      if ( argv[i] == ID2SYM(rb_intern("%")) ) {
        count[i] = 0;
      }
      else {
        rb_raise(rb_eArgError, "unknown symbol (!= ':%%') in arguments");
      }
    }
    else {
      count[i] = NUM2SIZE(argv[i]);
      if ( count[i] == 0 ) {
        rb_raise(rb_eArgError,
                 "zero repeat count specified in creating CARepeat object");
      }
      repeat *= count[i];
    }
  }

  if ( repeat == 1 ) {
    ca_size_t dim[CA_RANK_MAX];
    int8_t j = 0;
    for (i=0; i<argc; i++) {
      if ( count[i] == 0 ) {
        dim[i] = ca->dim[j];
        j++;
      }
      else {
        dim[i] = 1;
      }
    }
    obj = rb_ca_refer_new(self, ca->data_type, argc, dim, ca->bytes, 0);
  }
  else {
    obj = rb_ca_repeat_new(self, argc, count);
  }

  CA_FACE_LIFT_IF_FACE(obj, self, ca);
  return obj;
}

static VALUE
rb_ca_repeat_initialize_copy (VALUE self, VALUE other)
{
  CAStride *ca, *cs;
  TypedData_Get_Struct(self,  CAStride, &castride_data_type, ca);
  TypedData_Get_Struct(other, CAStride, &castride_data_type, cs);
  if ( ca_func[CA_OBJ_REPEAT].pool_init ) {
    ca_array_pool_alloc(ca, CA_OBJ_REPEAT, cs->ndim);
  }
  ca_stride_setup(ca, CA_OBJ_REPEAT, cs->parent,
                  cs->data_type, cs->bytes,
                  cs->ndim, cs->dim, cs->strides, cs->base_offset);
  ca_set_flag(ca, CA_FLAG_READ_ONLY);
  if (ca->mask) ca_set_flag(ca->mask, CA_FLAG_READ_ONLY);
  return self;
}

void
Init_ca_obj_repeat (void)
{
  /* rb_cCARepeat, CA_OBJ_REPEAT are defined in ruby_carray.c / carray_core.c */

  rb_define_const(rb_cObject, "CA_OBJ_REPEAT", INT2NUM(CA_OBJ_REPEAT));

  rb_define_method(rb_cCARepeat, "initialize_copy",
                                      rb_ca_repeat_initialize_copy, 1);
}
