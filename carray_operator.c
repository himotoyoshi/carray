/* ---------------------------------------------------------------------------

  carray_operator.c

  This file is part of Ruby/CArray extension library.
  You can redistribute it and/or modify it under the terms of
  the Ruby Licence.

  Copyright (C) 2005 Hiroki Motoyoshi

---------------------------------------------------------------------------- */

#include <math.h>

#include "carray.h"

VALUE rb_mCAMath;

extern ca_binop_func_t ca_binop_mul[CA_NTYPE];
extern ca_binop_func_t ca_binop_add[CA_NTYPE];

void
ca_zerodiv ()
{
  #ifdef _OPENMP
  #pragma omp master
  #endif
  rb_raise(rb_eZeroDivError, "divided by 0");
}


VALUE
rb_ca_call_monop (VALUE self, ca_monop_func_t func[])
{
  volatile VALUE out;
  CArray *ca1, *ca2;   /* ca2 = ca1.op */

  Data_Get_Struct(self, CArray, ca1);

  if ( ca_has_mask(ca1) ) {
    ca2 = ca_template_safe(ca1);              
  }
  else {
    ca2 = ca_template(ca1);        
  }

  ca2 = ca_template(ca1);
  out = ca_wrap_struct(ca2);

  ca_attach(ca1);
  ca_copy_mask_overlay(ca2, ca2->elements, 1, ca1);
  func[ca1->data_type](ca1->elements,
                       ( ca2->mask ) ? ca2->mask->ptr : NULL,
                       ca1->ptr, 1,
                       ca2->ptr, 1);
  ca_detach(ca1);

  /* unresolved unbound repeat array generates unbound repeat array again */
  if ( ca1->obj_type == CA_OBJ_UNBOUND_REPEAT ) {
    CAUnboundRepeat *cx = (CAUnboundRepeat *) ca1;
    out = rb_ca_ubrep_new(out, cx->rep_rank, cx->rep_dim);
  }

  return out;
}

VALUE
rb_ca_call_monop_bang (VALUE self, ca_monop_func_t func[])
{
  CArray *ca1;         /* ca1.op! */

  rb_ca_modify(self);

  Data_Get_Struct(self, CArray, ca1);

  ca_attach(ca1);
  func[ca1->data_type](ca1->elements,
                       ( ca1->mask ) ? ca1->mask->ptr : NULL,
                       ca1->ptr, 1,
                       ca1->ptr, 1);
  ca_sync(ca1);
  ca_detach(ca1);

  return self;
}

VALUE
rb_ca_call_binop (volatile VALUE self, volatile VALUE other,
                                         ca_binop_func_t func[])
{
  volatile VALUE out;
  CArray *ca1, *ca2, *ca3; /* ca3 = ca1.op(ca2) */

  /* do implicit casting and resolving unbound repeat array */
  rb_ca_cast_self_or_other(&self, &other);

  Data_Get_Struct(self, CArray, ca1);
  Data_Get_Struct(other, CArray, ca2);

  ca_attach_n(2, ca1, ca2);

  /* main operation */
  if ( rb_obj_is_cscalar(self) ) {
    if ( rb_obj_is_cscalar(other) ) { /* scalar vs scalar */
      if ( ca_has_mask(ca1) || ca_has_mask(ca2) ) {
        ca3 = ca_template_safe(ca1);              
      }
      else {
        ca3 = ca_template(ca1);        
      }
      out = ca_wrap_struct(ca3);

      ca_copy_mask_overlay(ca3, ca3->elements, 2, ca1, ca2);
      func[ca1->data_type](ca1->elements, ( ca3->mask ) ? ca3->mask->ptr : NULL,
                           ca1->ptr, 0,
                           ca2->ptr, 0,
                           ca3->ptr, 0);
    }
    else {                                         /* scalar vs array */
      if ( ca_has_mask(ca1) || ca_has_mask(ca2) ) {
        ca3 = ca_template_safe(ca2);              
      }
      else {
        ca3 = ca_template(ca2);        
      }
      out = ca_wrap_struct(ca3);

      ca_copy_mask_overlay(ca3, ca3->elements, 2, ca1, ca2);
      func[ca1->data_type](ca2->elements, ( ca3->mask ) ? ca3->mask->ptr : NULL,
                           ca1->ptr, 0,
                           ca2->ptr, 1,
                           ca3->ptr, 1);
    }
  }
  else {                                           /* array vs scalar */
    if ( rb_obj_is_cscalar(other) ) {
      if ( ca_has_mask(ca1) || ca_has_mask(ca2) ) {
        ca3 = ca_template_safe(ca1);              
      }
      else {
        ca3 = ca_template(ca1);        
      }
      out = ca_wrap_struct(ca3);

      ca_copy_mask_overlay(ca3, ca3->elements, 2, ca1, ca2);
      func[ca1->data_type](ca1->elements, ( ca3->mask ) ? ca3->mask->ptr : NULL,
                           ca1->ptr, 1,
                           ca2->ptr, 0,
                           ca3->ptr, 1);
    }
    else {                                         /* array vs array */
      if ( ca1->elements != ca2->elements ) {
        rb_raise(rb_eRuntimeError, "elements mismatch (%lld <-> %lld)",
                                   (ca_size_t) ca1->elements, (ca_size_t) ca2->elements);
      }
      if ( ca_has_mask(ca1) || ca_has_mask(ca2) ) {
        ca3 = ca_template_safe(ca1);              
      }
      else {
        ca3 = ca_template(ca1);        
      }
      out = ca_wrap_struct(ca3);

      ca_copy_mask_overlay(ca3, ca3->elements, 2, ca1, ca2);
      func[ca1->data_type](ca1->elements, ( ca3->mask ) ? ca3->mask->ptr : NULL,
                           ca1->ptr, 1,
                           ca2->ptr, 1,
                           ca3->ptr, 1);
    }
  }

  ca_detach_n(2, ca1, ca2);

  /* unresolved unbound repeat array generates unbound repeat array again */
  if ( ca1->obj_type == CA_OBJ_UNBOUND_REPEAT ) {
    CAUnboundRepeat *cx = (CAUnboundRepeat *) ca1;
    out = rb_ca_ubrep_new(out, cx->rep_rank, cx->rep_dim);
  }

  /* unresolved unbound repeat array generates unbound repeat array again */
  if ( ca2->obj_type == CA_OBJ_UNBOUND_REPEAT ) {
    CAUnboundRepeat *cx = (CAUnboundRepeat *) ca2;
    out = rb_ca_ubrep_new(out, cx->rep_rank, cx->rep_dim);
  }

  return out;
}

VALUE
rb_ca_call_binop_bang (VALUE self, VALUE other, ca_binop_func_t func[])
{
  CArray *ca1, *ca2;   /* ca1.op!(ca2) */

  rb_ca_modify(self);

  /* do implicit casting and resolving unbound repeat array */
  rb_ca_cast_other(&self, &other);

  Data_Get_Struct(self, CArray, ca1);
  Data_Get_Struct(other, CArray, ca2);

  ca_attach_n(2, ca1, ca2);

  /* main operation */
  if ( rb_obj_is_cscalar(self) ) {
    if ( rb_obj_is_cscalar(other) ) { /* scalar vs scalar */
      ca_copy_mask_overlay(ca1, ca1->elements, 2, ca1, ca2);
      func[ca1->data_type](ca1->elements, ( ca1->mask ) ? ca1->mask->ptr : NULL,
                           ca1->ptr, 0,
                           ca2->ptr, 0,
                           ca1->ptr, 0);
    }
    else {                                         /* scalar vs array */
      if ( ca1->elements != ca2->elements ) {
        rb_raise(rb_eRuntimeError, "elements mismatch (%lld <-> %lld)",
                                 (ca_size_t) ca1->elements, (ca_size_t) ca2->elements);
      }

      ca_copy_mask_overlay(ca1, ca1->elements, 2, ca1, ca2);
      func[ca1->data_type](ca1->elements, ( ca1->mask ) ? ca1->mask->ptr : NULL,
                           ca1->ptr, 0,
                           ca2->ptr, 0,
                           ca1->ptr, 0);
    }
  }
  else {
    if ( rb_obj_is_cscalar(other) ) { /* array vs scalar */
      ca_copy_mask_overlay(ca1, ca1->elements, 2, ca1, ca2);
      func[ca1->data_type](ca1->elements, ( ca1->mask ) ? ca1->mask->ptr : NULL,
                           ca1->ptr, 1,
                           ca2->ptr, 0,
                           ca1->ptr, 1);
    }
    else {                                          /* array vs array */
      if ( ca1->elements != ca2->elements ) {
        rb_raise(rb_eRuntimeError, "elements mismatch in binop (%lld <-> %lld)",
                                 (ca_size_t) ca1->elements, (ca_size_t) ca2->elements);
      }

      ca_copy_mask_overlay(ca1, ca1->elements, 2, ca1, ca2);
      func[ca1->data_type](ca1->elements, ( ca1->mask ) ? ca1->mask->ptr : NULL,
                           ca1->ptr, 1,
                           ca2->ptr, 1,
                           ca1->ptr, 1);
    }

  }

  ca_sync(ca1);
  ca_detach_n(2, ca1, ca2);

  return self;
}

VALUE
rb_ca_call_moncmp (VALUE self, ca_moncmp_func_t func[])
{
  volatile VALUE out;
  CArray *ca1, *ca2;    /* ca2 = ca1.op */

  Data_Get_Struct(self, CArray, ca1);

  if ( ca_is_scalar(ca1) ) {
    out = rb_cscalar_new(CA_BOOLEAN, 0, NULL);
  }
  else {
    out = rb_carray_new(CA_BOOLEAN, ca1->rank, ca1->dim, 0, NULL);
  }

  Data_Get_Struct(out, CArray, ca2);

  ca_attach(ca1);
  ca_copy_mask_overlay(ca2, ca2->elements, 1, ca1);
  func[ca1->data_type](ca1->elements, ( ca2->mask ) ? ca2->mask->ptr : NULL,
                       ca1->ptr, 1,
                       ca2->ptr, 1);
  ca_detach(ca1);

  /* unresolved unbound repeat array generates unbound repeat array again */
  if ( ca1->obj_type == CA_OBJ_UNBOUND_REPEAT ) {
    CAUnboundRepeat *cx = (CAUnboundRepeat *) ca1;
    out = rb_ca_ubrep_new(out, cx->rep_rank, cx->rep_dim);
  }

  return out;
}


extern ca_monop_func_t ca_bincmp_eq[CA_NTYPE];
extern ca_monop_func_t ca_bincmp_ne[CA_NTYPE];

VALUE
rb_ca_call_bincmp (volatile VALUE self, volatile VALUE other,
                                    ca_bincmp_func_t func[])
{
  volatile VALUE out = Qnil;
  CArray *ca1, *ca2, *ca3;  /* ca3 = ca1.op(ca2) */

  /* check for comparison with CA_UNDEF */
  if ( other == CA_UNDEF ) {
    if ( func == ca_bincmp_eq ) {      /* a.eq(UNDEF) -> a.is_masked */
      return rb_ca_is_masked(self);
    }
    else if ( func == ca_bincmp_ne ) { /* a.ne(UNDEF) -> a.is_not_masked */
      return rb_ca_is_not_masked(self);
    }
    else {
      rb_raise(rb_eRuntimeError, "array can not be compared with UNDEF");
    }
  }

  /* do implicit casting and resolving unbound repeat array */
  rb_ca_cast_self_or_other(&self, &other);

  Data_Get_Struct(self, CArray, ca1);
  Data_Get_Struct(other, CArray, ca2);

  ca_attach_n(2, ca1, ca2);

  /* main operation */
  if ( rb_obj_is_cscalar(self) ) {
    if ( rb_obj_is_cscalar(other) ) { /* scalar vs scalar */
      out = rb_cscalar_new(CA_BOOLEAN, 0, NULL);
      Data_Get_Struct(out, CArray, ca3);

      ca_copy_mask_overlay(ca3, ca3->elements, 2, ca1, ca2);
      func[ca1->data_type](ca1->elements, ( ca3->mask ) ? ca3->mask->ptr : NULL,
                           ca1->ptr, ca1->bytes, 0,
                           ca2->ptr, ca2->bytes, 0,
                           ca3->ptr, ca3->bytes, 0);
    }
    else {                                          /* scalar vs array */
      out = rb_carray_new(CA_BOOLEAN, ca2->rank, ca2->dim, 0, NULL);
      Data_Get_Struct(out, CArray, ca3);

      ca_copy_mask_overlay(ca3, ca3->elements, 2, ca1, ca2);
      func[ca1->data_type](ca2->elements, ( ca3->mask ) ? ca3->mask->ptr : NULL,
                           ca1->ptr, ca1->bytes, 0,
                           ca2->ptr, ca2->bytes, 1,
                           ca3->ptr, ca3->bytes, 1);
    }
  }
  else {
    if ( rb_obj_is_cscalar(other) ) {  /* array vs scalar */
      out = rb_carray_new(CA_BOOLEAN, ca1->rank, ca1->dim, 0, NULL);
      Data_Get_Struct(out, CArray, ca3);

      ca_copy_mask_overlay(ca3, ca3->elements, 2, ca1, ca2);
      func[ca1->data_type](ca1->elements, ( ca3->mask ) ? ca3->mask->ptr : NULL,
                           ca1->ptr, ca1->bytes, 1,
                           ca2->ptr, ca2->bytes, 0,
                           ca3->ptr, ca3->bytes, 1);
    }
    else {                                          /* array vs array */
      if ( ca1->elements != ca2->elements ) {
        rb_raise(rb_eRuntimeError, "elements mismatch in bincmp (%lld <-> %lld)",
                                 (ca_size_t) ca1->elements, (ca_size_t) ca2->elements);
      }
      out = rb_carray_new(CA_BOOLEAN, ca1->rank, ca1->dim, 0, NULL);
      Data_Get_Struct(out, CArray, ca3);

      ca_copy_mask_overlay(ca3, ca3->elements, 2, ca1, ca2);
      func[ca1->data_type](ca1->elements, ( ca3->mask ) ? ca3->mask->ptr : NULL,
                           ca1->ptr, ca1->bytes, 1,
                           ca2->ptr, ca2->bytes, 1,
                           ca3->ptr, ca3->bytes, 1);
    }
  }

  ca_detach_n(2, ca1, ca2);

  /* unresolved unbound repeat array generates unbound repeat array again */
  if ( ca1->obj_type == CA_OBJ_UNBOUND_REPEAT ) {
    CAUnboundRepeat *cx = (CAUnboundRepeat *) ca1;
    out = rb_ca_ubrep_new(out, cx->rep_rank, cx->rep_dim);
  }

  return out;
}

void
ca_monop_not_implement(ca_size_t n, char *ptr1, char *ptr2)
{
  rb_raise(rb_eCADataTypeError,
           "invalid data type for monop (not implemented)");
}

void
ca_binop_not_implement(ca_size_t n, char *ptr1, char *ptr2, char *ptr3)
{
  rb_raise(rb_eCADataTypeError,
           "invalid data_type for binop (not implemented)");
}

void
ca_moncmp_not_implement(ca_size_t n, char *ptr1, char *ptr2)
{
  rb_raise(rb_eCADataTypeError,
           "invalid data_type for moncmp (not implemented)");
}

void
ca_bincmp_not_implement (ca_size_t n, char *ptr1, char *ptr2, char *ptr3)
{
  rb_raise(rb_eTypeError, "invalid data_type for bincmp (not implemented)");
}

VALUE
ca_math_call (VALUE mod, VALUE arg, ID id)
{
  if ( rb_obj_is_carray(arg) ) {
    return rb_funcall(arg, id, 0);
  }
#ifdef HAVE_COMPLEX_H
  else if ( rb_obj_is_kind_of(arg, rb_cCComplex) ) {
    if ( rb_respond_to(arg, id) ) {
      return rb_funcall(arg, id, 0);
    }
    else if ( rb_respond_to(rb_mMath, id) ) {
      return rb_funcall(rb_mMath, id, 1, arg);
    }
    else {
      rb_raise(rb_eRuntimeError, "unknown method for Math");
    }
  }
#endif
  else {
    /* rb_funcall calls even for Math's private method -> infinite loop */
    if ( rb_respond_to(rb_mMath, id) ) {
      return rb_funcall(rb_mMath, id, 1, arg);
    }
    else {
      rb_raise(rb_eRuntimeError, "unknown method for Math");
    }
  }
}

/* rdoc:
  class CArray
    def coerce (other)
    end
  end
*/

static VALUE
rb_ca_coerce (VALUE self, VALUE other)
{
  CArray *ca;
  Data_Get_Struct(self, CArray, ca);

  if ( rb_obj_is_carray(other) ) {
    return Qnil;
  }
  else if ( rb_respond_to(other, rb_intern("ca")) ) {
    return rb_ca_coerce(self, rb_funcall(other,rb_intern("ca"),0));
  }
  else if ( rb_respond_to(other, rb_intern("to_ca")) ) {
    return rb_ca_coerce(self, rb_funcall(other,rb_intern("to_ca"),0));
  }
  else {
    /* do implicit casting and resolving unbound repeat array */
    rb_ca_cast_self_or_other(&self, &other);
    return rb_assoc_new(other, self);
  }
}


/* CArray#mul_add(other, min_count, fill) */

#define proc_mul_add(type, conv, to) \
  { \
    type *p1 = (type*)ca->ptr; \
    type *p2; \
    ca_size_t   s2; \
    boolean8_t *m = mi; \
    type sum  = 0; \
    ca_size_t count = 0; \
    ca_size_t i; \
    ca_set_iterator(1, cw, &p2, &s2); \
    if ( m ) { \
      count = 0; \
      for (i=ca->elements; i; i--, p1++, p2+=s2) { \
        if ( ! *m++ ) { \
          sum += (type)conv(*p1) * (type)conv(*p2); \
        } \
        else { \
          count++; \
        } \
      } \
    } \
    else { \
      for (i=ca->elements; i; i--, p1++, p2+=s2) { \
        sum += (type)conv(*p1) * (type)conv(*p2); \
      } \
    } \
    if ( ( ! NIL_P(rmin_count) ) && count > min_count )     {   \
      out = ( NIL_P(rfval) ) ? CA_UNDEF : rfval;\
    } \
    else { \
      out = to(sum); \
    } \
  }

static VALUE
rb_ca_mul_add (int argc, VALUE *argv, volatile VALUE self)
{
  volatile VALUE out;
  volatile VALUE weight = Qnil;
  volatile VALUE rmin_count = Qnil;
  volatile VALUE rfval = Qnil;
  CArray *ca, *cw;
  boolean8_t *mi = NULL;
  ca_size_t min_count;

  /* FIXME: to parse :mask_limit, :fill_value */
  rb_scan_args(argc, argv, "12", (VALUE *) &weight, (VALUE *) &rmin_count, (VALUE *) &rfval);

  /* do implicit casting and resolving unbound repeat array */
  rb_ca_cast_self_or_other(&self, &weight);

  Data_Get_Struct(self, CArray, ca);
  Data_Get_Struct(weight, CArray, cw);

  /* checking elements and data_type */
  ca_check_same_elements(ca, cw);
  ca_check_same_data_type(ca, cw);

  if ( ca->elements == 0 ) {
    return ( NIL_P(rfval) ) ? CA_UNDEF : rfval;
  }

  if ( ca_has_mask(ca) || ca_has_mask(cw) ) {
    mi = ca_allocate_mask_iterator(2, ca, cw);
  }

  min_count = ( NIL_P(rmin_count) || ( ! mi ) ) ?
                                   ca->elements - 1 : NUM2SIZE(rmin_count);

  if ( min_count < 0 ) {
    min_count += ca->elements;
  }

  ca_attach_n(2, ca, cw);

  switch ( ca->data_type ) {
  case CA_INT8:     proc_mul_add(int8_t, ,LONG2NUM);           break;
  case CA_UINT8:    proc_mul_add(uint8_t,,ULONG2NUM);         break;
  case CA_INT16:    proc_mul_add(int16_t,,LONG2NUM);           break;
  case CA_UINT16:   proc_mul_add(uint16_t,,ULONG2NUM);        break;
  case CA_INT32:    proc_mul_add(int32_t,,LONG2NUM);           break;
  case CA_UINT32:   proc_mul_add(uint32_t,,ULONG2NUM);        break;
  case CA_INT64:    proc_mul_add(int64_t,,LL2NUM);             break;
  case CA_UINT64:   proc_mul_add(uint64_t,,ULL2NUM);          break;
  case CA_FLOAT32:  proc_mul_add(float32_t,,rb_float_new);     break;
  case CA_FLOAT64:  proc_mul_add(float64_t,,rb_float_new);     break;
  case CA_FLOAT128: proc_mul_add(float128_t,,rb_float_new);    break;
#ifdef HAVE_COMPLEX_H
  case CA_CMPLX64:  proc_mul_add(cmplx64_t,,rb_ccomplex_new);  break;
  case CA_CMPLX128: proc_mul_add(cmplx128_t,,rb_ccomplex_new); break;
  case CA_CMPLX256: proc_mul_add(cmplx256_t,,rb_ccomplex_new); break;
#endif
/*  case CA_OBJECT:   proc_mul_add(VALUE,NUM2DBL,rb_float_new); break; */
  default: rb_raise(rb_eCADataTypeError, "invalid data type");
  }

  ca_detach_n(2, ca, cw);

  free(mi);

  return out;
}

void
Init_carray_operator ()
{
  rb_mCAMath = rb_define_module("CAMath");

  rb_define_method(rb_cCArray, "coerce", rb_ca_coerce, 1);
  rb_define_method(rb_cCArray, "mul_add", rb_ca_mul_add, -1);
}



