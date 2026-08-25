/* ---------------------------------------------------------------------------

  Attribute and predicate accessors for CArray (obj_type / data_type
  / ndim / shape / dim / bytes / elements + entity? / virtual? /
  fixlen? / boolean? / read_only? / mask_array? / etc.) plus the
  view-chain navigators parent / root_array / ancestors.

  The corresponding YARD documentation lives in
  yard-stubs/carray_attribute.rb; this file carries only the
  implementation.

---------------------------------------------------------------------------- */

#include "carray.h"
#include "ca_obj_face.h"   /* CA_OBJ_RECORD + rb_ca_record_get_data_class */

/* ------------------------------------------------------------------- */

VALUE
rb_ca_obj_type (VALUE self)
{
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  return INT2NUM(ca->obj_type);
}

VALUE
rb_ca_data_type (VALUE self)
{
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  /* Return a Symbol via the pre-computed ID cache; the C internal
     int8_t representation is unchanged. */
  return ID2SYM(ca_data_type_sym[ca->data_type]);
}

VALUE
rb_ca_ndim (VALUE self)
{
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  return INT2NUM(ca->ndim);
}

VALUE
rb_ca_bytes (VALUE self)
{
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  return SIZE2NUM(ca->bytes);
}

VALUE
rb_ca_flags (VALUE self)
{
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  return INT2NUM(ca->flags);
}

VALUE
rb_ca_elements (VALUE self)
{
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  return SIZE2NUM(ca->elements);
}

VALUE
rb_ca_dim (VALUE self)
{
  volatile VALUE dim;
  CArray *ca;
  int i;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  dim = rb_ary_new2(ca->ndim);
  for (i=0; i<ca->ndim; i++) {
    rb_ary_store(dim, i, SIZE2NUM(ca->dim[i]));
  }
  return dim;
}

VALUE
rb_ca_dim0 (VALUE self)
{
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  return SIZE2NUM(ca->dim[0]);
}

VALUE
rb_ca_dim1 (VALUE self)
{
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  return ( ca->ndim >= 2 ) ? SIZE2NUM(ca->dim[1]) : Qnil;
}

VALUE
rb_ca_dim2 (VALUE self)
{
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  return ( ca->ndim >= 3 ) ? SIZE2NUM(ca->dim[2]) : Qnil;
}

VALUE
rb_ca_dim3 (VALUE self)
{
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  return ( ca->ndim >= 4 ) ? SIZE2NUM(ca->dim[3]) : Qnil;
}

VALUE
rb_ca_data_type_name (VALUE self)
{
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  return rb_str_new2(ca_type_name[ca->data_type]);
}

/* ------------------------------------------------------------------- */

int
ca_is_scalar (void *ap)
{
  CArray *ca = (CArray *) ap;
  return ca_test_flag(ca, CA_FLAG_SCALAR);
}

VALUE
rb_ca_is_scalar (VALUE self)
{
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  return ( ca_is_scalar(ca) ) ? Qtrue : Qfalse;
}

VALUE
rb_obj_is_cscalar (VALUE obj)
{
  CArray *ca;
  if ( rb_obj_is_carray(obj) ) {
    TypedData_Get_Struct(obj, CArray, &carray_data_type, ca);
    return ( ca_is_scalar(ca) ) ? Qtrue : Qfalse;
  }
  return Qfalse;
}

/* ------------------------------------------------------------------- */

int
ca_is_view (void *ap)
{
  CArray *ca = (CArray *) ap;
  return ( ca_func[ca->obj_type].entity_type == CA_VIEW_ARRAY ) ? 1 : 0;
}

VALUE
rb_ca_is_entity (VALUE self)
{
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  return ( ca_is_view(ca) ) ? Qfalse : Qtrue;
}

VALUE
rb_ca_is_virtual (VALUE self)
{
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  return ( ca_is_view(ca) ) ? Qtrue : Qfalse;
}

/* ------------------------------------------------------------------- */

VALUE
rb_ca_is_attached (VALUE self)
{
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  return ( ca_is_attached(ca) ) ? Qtrue : Qfalse;
}

/* ------------------------------------------------------------------- */

VALUE
rb_ca_is_empty (VALUE self)
{
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  return ( ca->elements == 0 ) ? Qtrue : Qfalse;
}

/* ------------------------------------------------------------------- */

int
ca_is_readonly (void *ap)
{
  CArray *ca = (CArray *) ap;
  if ( ca_test_flag(ca, CA_FLAG_READ_ONLY) ) {           /* test -> true */
    return 1;
  }
  else if ( ca_test_flag(ca, CA_FLAG_MULTI_PARENTS) ) {
    /* multi-parent view: read-only iff ANY parent is (a whole-view write
       cannot be honoured if any backing parent rejects writes). */
    CAMultiParent *mp = (CAMultiParent *) ca;
    int32_t k;
    for ( k = 0; k < mp->n_parents; k++ ) {
      if ( ca_is_readonly(mp->parents[k]) ) {
        ca_set_flag(ca, CA_FLAG_READ_ONLY);
        return 1;
      }
    }
    return 0;
  }
  else {                                                 /* test -> false */
    if ( ca_is_view(ca) && CAVIEW(ca)->parent ) {
      if ( ca_is_readonly(CAVIEW(ca)->parent) ) {     /* test -> true */
        ca_set_flag(ca, CA_FLAG_READ_ONLY);
        return 1;
      }
    }
    return 0;                                            /* all test -> false */
  }
}

VALUE
rb_ca_is_read_only (VALUE self)
{
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  return ( ca_is_readonly(ca) ) ? Qtrue : Qfalse;
}

/* ------------------------------------------------------------------- */

int
ca_is_mask_array (void *ap)
{
  CArray *ca = (CArray *) ap;
  if ( ca_test_flag(ca, CA_FLAG_MASK_ARRAY) ) {           /* test -> true */
    return 1;
  }
  else {                                                   /* test -> false */
    /* Identity property: a CAStack is not a mask array unless
       flagged directly (the internal CAStackMask is).  Do not
       inherit the property across a multi-parent fan-out — stop at
       the boundary. */
    if ( ca_is_view(ca) && CAVIEW(ca)->parent
         && ! ca_test_flag(ca, CA_FLAG_MULTI_PARENTS) ) {
      if ( ca_is_mask_array(CAVIEW(ca)->parent) ) {     /* test -> true */
        ca_set_flag(ca, CA_FLAG_MASK_ARRAY);
        return 1;
      }
    }
    return 0;                                            /* all test -> false */
  }
}

VALUE
rb_ca_is_mask_array (VALUE self)
{
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  return ( ca_is_mask_array(ca) ) ? Qtrue : Qfalse;
}

/* ------------------------------------------------------------------- */

int
ca_is_value_array (void *ap)
{
  CArray *ca = (CArray *) ap;
  if ( ca_test_flag(ca, CA_FLAG_VALUE_ARRAY) ) {           /* test -> true */
    return 1;
  }
  else {                                                   /* test -> false */
    /* Identity property: a CAStack is never "the .value of" a
       single array (s.value wraps it in a flagged CARefer).  Do
       not inherit across a multi-parent fan-out — stop at the
       boundary. */
    if ( ca_is_view(ca) && CAVIEW(ca)->parent
         && ! ca_test_flag(ca, CA_FLAG_MULTI_PARENTS) ) {
      if ( ca_is_value_array(CAVIEW(ca)->parent) ) {     /* test -> true */
        ca_set_flag(ca, CA_FLAG_VALUE_ARRAY);
        return 1;
      }
    }
    return 0;                                            /* all test -> false */
  }
}

VALUE
rb_ca_is_value_array (VALUE self)
{
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  return ( ca_is_value_array(ca) ) ? Qtrue : Qfalse;
}

/* ------------------------------------------------------------------- */

VALUE
rb_ca_is_face (VALUE self)
{
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  return ( ca_is_face(ca) ) ? Qtrue : Qfalse;
}

/* ------------------------------------------------------------------- */

int
ca_is_fixlen_type (void *ap)
{
  CArray *ca = (CArray *) ap;
  return ( ca->data_type == CA_FIXLEN );
}

VALUE
rb_ca_is_fixlen_type (VALUE self)
{
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  return ca_is_fixlen_type(ca) ? Qtrue : Qfalse;
}

/* ------------------------------------------------------------------- */

int
ca_is_boolean_type (void *ap)
{
  CArray *ca = (CArray *) ap;
  return ( ca->data_type == CA_BOOLEAN );
}

VALUE
rb_ca_is_boolean_type (VALUE self)
{
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  return ca_is_boolean_type(ca) ? Qtrue : Qfalse;
}

/* ------------------------------------------------------------------- */

int
ca_is_numeric_type (void *ap)
{
  CArray *ca = (CArray *) ap;
  return ( ( ca->data_type >= CA_INT8 ) &&
           ( ca->data_type <= CA_CMPLX256 ) );
}

VALUE
rb_ca_is_numeric_type (VALUE self)
{
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  return ca_is_numeric_type(ca) ? Qtrue : Qfalse;
}

/* ------------------------------------------------------------------- */

int
ca_is_integer_type (void *ap)
{
  CArray *ca = (CArray *) ap;
  return ( ( ca->data_type >= CA_INT8 ) &&
           ( ca->data_type <= CA_UINT64 ) );
}

VALUE
rb_ca_is_integer_type (VALUE self)
{
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  return ca_is_integer_type(ca) ? Qtrue : Qfalse;
}

/* ------------------------------------------------------------------- */

int
ca_is_float_type (void *ap)
{
  CArray *ca = (CArray *) ap;
  return ( ( ca->data_type >= CA_FLOAT32 ) &&
           ( ca->data_type <= CA_FLOAT128 ) );
}

VALUE
rb_ca_is_float_type (VALUE self)
{
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  return ca_is_float_type(ca) ? Qtrue : Qfalse;
}

/* ------------------------------------------------------------------- */

int
ca_is_complex_type (void *ap)
{
  CArray *ca = (CArray *) ap;
  return ( ( ca->data_type >= CA_CMPLX64 ) &&
           ( ca->data_type <= CA_CMPLX256 ) );
}

VALUE
rb_ca_is_complex_type (VALUE self)
{
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  return ca_is_complex_type(ca) ? Qtrue : Qfalse;
}

/* ------------------------------------------------------------------- */

int
ca_is_object_type (void *ap)
{
  CArray *ca = (CArray *) ap;
  return ( ca->data_type == CA_OBJECT );
}

VALUE
rb_ca_is_object_type (VALUE self)
{
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  return ca_is_object_type(ca) ? Qtrue : Qfalse;
}

/* ------------------------------------------------------------------- */

static ID id_parent;

VALUE
rb_ca_parent (VALUE self)
{
  return rb_ivar_get(self, id_parent);
}

VALUE
rb_ca_set_parent (VALUE self, VALUE obj)
{
  rb_ivar_set(self, id_parent, obj);
  if ( OBJ_FROZEN(obj) ) {
    rb_ca_freeze(self);
  }
  return obj;
}

/* ------------------------------------------------------------------- */

VALUE
rb_ca_data_class (VALUE self)
{
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  /* Only a Face carries data_class; a non-Face CArray is always
     Qnil.  CARecord stores it in its tail (reached directly via
     obj_type, no Ruby roundtrip); numeric Faces such as
     CATime / CATimedelta have no data_class. */
  if ( ! ca_test_flag(ca, CA_FLAG_IS_FACE) ) {
    return Qnil;
  }
  if ( ca->obj_type == CA_OBJ_RECORD ) {
    return rb_ca_record_get_data_class(ca);
  }
  return Qnil;
}

VALUE
rb_ca_has_data_class (VALUE self)
{
  return RTEST(rb_ca_data_class(self)) ? Qtrue : Qfalse;
}

/* ------------------------------------------------------------------- */

/* data_class= is defined but always raises.  data_class now lives
   on the Face (CARecord) tail; there is no way to attach one to a
   non-Face CArray in-place.  The setter is kept only so a call
   surfaces the migration message rather than NoMethodError.
   NORETURN: rb_raise never returns, so neither does this function. */
NORETURN(VALUE rb_ca_set_data_class(VALUE self, VALUE klass));
VALUE
rb_ca_set_data_class (VALUE self, VALUE klass)
{
  rb_raise(rb_eArgError,
    "CArray#data_class= was removed in 3.0. "
    "Use `CARecord.new(klass, *shape)` or `CARecord.wrap(entity, klass)`.");
}

/* ------------------------------------------------------------------- */

CArray *
ca_root_array (void *ap)
{
  CArray *ca = (CArray *)ap;
  if ( ca_is_entity(ca) ) {
    return ca;
  }
  else if ( ca_test_flag(ca, CA_FLAG_MULTI_PARENTS) ) {
    /* Multi-parent view fans out to K roots, so the single-
       reference chain terminates here — the view itself is the
       root boundary. */
    return ca;
  }
  else {
    CAView *cr = (CAView *)ca;
    if ( ! cr->parent ) {
      return ca;
    }
    else {
      return ca_root_array(cr->parent);
    }
  }
}

static VALUE
rb_ca_root_array (VALUE self)
{
  volatile VALUE refary;
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  if ( ca_is_entity(ca) ) {
    return self;
  }
  else if ( ca_test_flag(ca, CA_FLAG_MULTI_PARENTS) ) {
    return self;   /* Multi-parent: root boundary (fans out to K roots). */
  }
  else {
    refary = rb_ca_parent(self);
    if ( NIL_P(refary) ) {
      return self;
    }
    else {
      return rb_ca_root_array(refary);
    }
  }
}

/* ------------------------------------------------------------------- */

static VALUE
rb_ca_ancestors_loop (VALUE self, VALUE list)
{
  volatile VALUE refary;
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  rb_ary_unshift(list, self);
  if ( ca_is_entity(ca) ) {
    return list;
  }
  else if ( ca_test_flag(ca, CA_FLAG_MULTI_PARENTS) ) {
    return list;   /* Multi-parent: chain terminates here (fans out to K). */
  }
  else {
    refary = rb_ca_parent(self);
    if ( rb_obj_is_carray(refary) ) {
      return rb_ca_ancestors_loop(refary, list);
    }
    else {
      return list;
    }
  }
}

static VALUE
rb_ca_ancestors (VALUE self)
{
  volatile VALUE list;
  list = rb_ary_new();
  return rb_ca_ancestors_loop(self, list);
}

/* ------------------------------------------------------------------- */

void
Init_carray_attribute (void)
{
  id_parent     = rb_intern("parent");

  rb_define_method(rb_cCArray, "obj_type", rb_ca_obj_type, 0);
  rb_define_method(rb_cCArray, "data_type", rb_ca_data_type, 0);
  rb_define_method(rb_cCArray, "bytes", rb_ca_bytes, 0);
  rb_define_method(rb_cCArray, "flags", rb_ca_flags, 0);
  rb_define_method(rb_cCArray, "ndim", rb_ca_ndim, 0);
  rb_define_method(rb_cCArray, "rank", rb_ca_ndim, 0);
  rb_define_method(rb_cCArray, "shape", rb_ca_dim, 0);
  rb_define_method(rb_cCArray, "dim", rb_ca_dim, 0);
  rb_define_method(rb_cCArray, "dim0", rb_ca_dim0, 0);
  rb_define_method(rb_cCArray, "dim1", rb_ca_dim1, 0);
  rb_define_method(rb_cCArray, "dim2", rb_ca_dim2, 0);
  rb_define_method(rb_cCArray, "dim3", rb_ca_dim3, 0);
  rb_define_method(rb_cCArray, "elements", rb_ca_elements, 0);
  rb_define_method(rb_cCArray, "length", rb_ca_elements, 0); 
  rb_define_method(rb_cCArray, "size", rb_ca_elements, 0); 
  
  rb_define_method(rb_cCArray, "data_type_name", rb_ca_data_type_name, 0);

  rb_define_method(rb_cCArray, "parent", rb_ca_parent, 0);

  rb_define_method(rb_cCArray, "data_class", rb_ca_data_class, 0);
  rb_define_method(rb_cCArray, "data_class=", rb_ca_set_data_class, 1);

  rb_define_method(rb_cCArray, "scalar?", rb_ca_is_scalar, 0);

  rb_define_method(rb_cCArray, "entity?", rb_ca_is_entity, 0);
  rb_define_method(rb_cCArray, "virtual?", rb_ca_is_virtual, 0);
  rb_define_method(rb_cCArray, "value_array?", rb_ca_is_value_array, 0);
  rb_define_method(rb_cCArray, "mask_array?", rb_ca_is_mask_array, 0);
  rb_define_method(rb_cCArray, "face?", rb_ca_is_face, 0);

  rb_define_method(rb_cCArray, "empty?", rb_ca_is_empty, 0);
  rb_define_method(rb_cCArray, "read_only?", rb_ca_is_read_only, 0);
  rb_define_method(rb_cCArray, "attached?", rb_ca_is_attached, 0);

  rb_define_method(rb_cCArray, "has_data_class?", rb_ca_has_data_class, 0);

  rb_define_method(rb_cCArray, "fixlen?",   rb_ca_is_fixlen_type, 0);
  rb_define_method(rb_cCArray, "boolean?",  rb_ca_is_boolean_type, 0);
  rb_define_method(rb_cCArray, "numeric?",  rb_ca_is_numeric_type, 0);
  rb_define_method(rb_cCArray, "integer?",  rb_ca_is_integer_type, 0);
  rb_define_method(rb_cCArray, "float?",    rb_ca_is_float_type, 0);
  rb_define_method(rb_cCArray, "complex?",  rb_ca_is_complex_type, 0);
  rb_define_method(rb_cCArray, "object?",   rb_ca_is_object_type, 0);

  rb_define_method(rb_cCArray, "root_array", rb_ca_root_array, 0);
  rb_define_method(rb_cCArray, "ancestors", rb_ca_ancestors, 0);
}

