/* ---------------------------------------------------------------------------

  carray_copy.c

  This file is part of Ruby/CArray extension library.
  You can redistribute it and/or modify it under the terms of
  the Ruby Licence.

  Copyright (C) 2005 Hiroki Motoyoshi

---------------------------------------------------------------------------- */

#include "carray.h"
#include <stdarg.h>

/* ------------------------------------------------------------------- */

CArray *
ca_copy (void *ap)
{
  CArray *ca = (CArray *) ap;
  CArray *co;

  if ( ca_is_scalar(ca) ) {             /* create scalar without mask */
    co = (CArray *) cscalar_new(ca->data_type, ca->bytes, 0);
  }
  else {                                /* create array without mask */
    co = carray_new(ca->data_type, ca->rank, ca->dim, ca->bytes, 0);
  }

  if ( ca_is_attached(ca) ) {
    memcpy(co->ptr, ca->ptr, ca_length(ca));
  }
  else {
    ca_copy_data(ca, co->ptr);
  }

  ca_update_mask(ca);
  if ( ca->mask ) {
    ca_copy_mask(co, ca);
  }

  return co;
}

/* rdoc:
  class CArray
    # create CArray object from `self` with same contents includes mask state.
    def to_ca
    end
  end
*/

VALUE
rb_ca_copy (VALUE self)
{
  volatile VALUE obj;
  CArray *ca;
  Data_Get_Struct(self, CArray, ca);
  obj = ca_wrap_struct(ca_copy(ca));
  rb_ca_data_type_inherit(obj, self);
  return obj;
}

/* ------------------------------------------------------------------- */

CArray *
ca_template (void *ap)
{
  CArray *ca = (CArray *) ap;
  if ( ca_is_scalar(ca) ) {    /* create scalar without mask */
    return (CArray*) cscalar_new(ca->data_type, ca->bytes, NULL);
  }
  else {                       /* create array without mask */
    return carray_new(ca->data_type, ca->rank, ca->dim, ca->bytes, NULL);
  }
}

CArray *
ca_template_safe (void *ap)
{
  CArray *ca = (CArray *) ap;
  if ( ca_is_scalar(ca) ) {   /* create scalar without mask */
    return (CArray*) cscalar_new(ca->data_type, ca->bytes, NULL);
  }
  else {                       /* create array filled with 0, without mask */
    return carray_new_safe(ca->data_type, ca->rank, ca->dim, ca->bytes, NULL);
  }
}

CArray *
ca_template_safe2 (void *ap, int8_t data_type, int32_t bytes)
{
  CArray *ca = (CArray *) ap;
  CA_CHECK_DATA_TYPE(data_type);
  if ( ca_is_scalar(ca) ) { /* create scalar without mask */
    return (CArray*) cscalar_new(data_type, bytes, NULL);
  }
  else {                   /* create array filled with 0, without mask */
    return carray_new_safe(data_type, ca->rank, ca->dim, bytes, NULL);
  }
}

/* rdoc:
  class CArray
    # returns CArray object with same dimension with `self`
    # The data type of the new carray object can be specified by `data_type`.
    # For fixlen data type, the option `:bytes` is used to specified the
    # data length.
    def template(data_type=self.data_type, options={:bytes=>0})
    end
  end
*/

static VALUE
rb_ca_template_method (int argc, VALUE *argv, VALUE self)
{
  volatile VALUE ropt = rb_pop_options(&argc, &argv);
  volatile VALUE obj, rtype, rbytes = Qnil;
  CArray *ca, *co;
  int8_t data_type;
  int32_t bytes;

  rb_scan_args(argc, argv, "01", &rtype);
  rb_scan_options(ropt, "bytes", &rbytes);

  Data_Get_Struct(self, CArray, ca);

  if ( NIL_P(rtype) ) {                  /* data_type not given */
    co  = ca_template_safe(ca);
    obj = ca_wrap_struct(co);
    rb_ca_data_type_inherit(obj, self);
  }
  else {
    rb_ca_guess_type_and_bytes(rtype, rbytes, &data_type, &bytes);
    co  = ca_template_safe2(ca, data_type, bytes);
    obj = ca_wrap_struct(co);
    rb_ca_data_type_import(obj, rtype);
  }

  if ( rb_block_given_p() ) {                   /* block given */
    volatile VALUE rval = rb_yield_values(0);
    if ( rval != self ) {
      rb_ca_store_all(obj, rval);
    }
  }

  return obj;
}

VALUE
rb_ca_template (VALUE self)
{
  return rb_ca_template_method(0, NULL, self);
}

VALUE
rb_ca_template_with_type (VALUE self, VALUE rtype, VALUE rbytes)
{
  VALUE ropt = rb_hash_new();
  VALUE args[2] = { rtype, ropt };
  rb_set_options(ropt, "bytes", rbytes);
  return rb_ca_template_method(2, args, self);
}

VALUE
rb_ca_template_n (int n, ...)
{
  volatile VALUE varg, obj;
  CArray *ca;
  int32_t elements = -1;
  va_list vargs;
  int i;

  va_start(vargs, n);
  for (i=0; i<n; i++) {
    varg = va_arg(vargs, VALUE);
    if ( ! rb_obj_is_carray(varg) ) {
      rb_raise(rb_eRuntimeError, "[BUG] not-carray object given to rb_ca_template_n");
    }
    Data_Get_Struct(varg, CArray, ca);
    if ( i == 0 ) {
      obj = varg;
      elements = ca->elements;
    }
    else {
      if ( rb_obj_is_cscalar(varg) ) {
        continue;
      }
      if ( rb_obj_is_cscalar(obj) ) {
        obj = varg;
        elements = ca->elements;
      }
      else if ( ca->elements != elements ) {
        rb_raise(rb_eRuntimeError, "size mismatch");
      }
    }
  }
  va_end(vargs);

  return rb_ca_template(obj);
}

/* ------------------------------------------------------------------- */

static void
ca_paste_loop (CArray *ca, int32_t *offset, int32_t *offset0,
               int32_t *size, CArray *cs,
               int32_t level, int32_t *idx, int32_t *idx0)
{
  int32_t i;
  if ( level == ca->rank - 1 ) {
    idx[level] = offset[level];
    idx0[level] = offset0[level];
    memcpy(ca_ptr_at_index(ca, idx), ca_ptr_at_index(cs, idx0), size[level]*ca->bytes);
    if ( ca->mask ) {
      memset(ca_ptr_at_index(ca->mask, idx), 0, size[level]*sizeof(boolean8_t));
    }
  }
  else {
    for (i=0; i<size[level]; i++) {
      idx[level] = offset[level] + i;
      idx0[level] = offset0[level] + i;
      ca_paste_loop(ca, offset, offset0, size, cs, level+1, idx, idx0);
    }
  }
}

/* ------------------------------------------------------------------- */

void
ca_paste (void *ap, int32_t *offset, void *sp)
{
  CArray *ca = (CArray *) ap;
  CArray *cs = (CArray *) sp;
  int32_t size[CA_RANK_MAX];
  int32_t offset0[CA_RANK_MAX];
  int32_t idx[CA_RANK_MAX];
  int32_t idx0[CA_RANK_MAX];
  int32_t i;

  ca_check_same_data_type(ca, cs);
  ca_check_same_rank(ca, cs);

  for (i=0; i<ca->rank; i++) {
    if ( offset[i] >= 0 ) {
      if ( ca->dim[i] <= cs->dim[i] + offset[i] ) {
        size[i] = ca->dim[i] - offset[i];
      }
      else {
        size[i] = cs->dim[i];
      }
      offset0[i] = 0;
    }
    else {
      if ( ca->dim[i] <= cs->dim[i] + offset[i] ) {
        size[i] = ca->dim[i];
      }
      else {
        size[i] = cs->dim[i] + offset[i];
      }
      offset0[i] = -offset[i];
      offset[i] = 0;
    }
  }

  for (i=0; i<ca->rank; i++) {
    CA_CHECK_INDEX(offset[i], ca->dim[i]);
  }

  if ( ca_has_mask(cs) ) {
    ca_create_mask(ca);
  }

  ca_attach_n(2, ca, cs);

  ca_paste_loop(ca, offset, offset0, size, cs, 0, idx, idx0);

  if ( ca_has_mask(cs) ) {
    ca_paste_loop(ca->mask, offset, offset0, size, cs->mask, 0, idx, idx0);
  }

  ca_sync(ca);
  ca_detach_n(2, ca, cs);
}

/* rdoc:
  class CArray
    # pastes `ary` to `self` at the index `idx`.
    # `idx` should be Array object with the length same as `self.rank`.
    # `ary` should have same shape with `self`.
    def paste (idx, ary)
    end
  end
*/

static VALUE
rb_ca_paste (VALUE self, VALUE roffset, VALUE rsrc)
{
  CArray *ca, *cs;
  int32_t offset[CA_RANK_MAX];
  int i;

  rb_ca_modify(self);

  Data_Get_Struct(self, CArray, ca);

  Check_Type(roffset, T_ARRAY);

  if ( RARRAY_LEN(roffset) != ca->rank ) {
    rb_raise(rb_eArgError,
             "# of arguments should equal to the rank");
  }

  for (i=0; i<ca->rank; i++) {
    offset[i] = NUM2INT(rb_ary_entry(roffset,i));
  }

  cs = ca_wrap_readonly(rsrc, ca->data_type);

  ca_paste(ca, offset, cs);

  return self;
}


static void
ca_clip_loop (CArray *ca, int32_t *offset, int32_t *offset0,
               int32_t *size, CArray *cs,
               int32_t level, int32_t *idx, int32_t *idx0)
{
  int32_t i;
  if ( level == ca->rank - 1 ) {
    idx[level] = offset[level];
    idx0[level] = offset0[level];
    memcpy(ca_ptr_at_index(cs, idx0), ca_ptr_at_index(ca, idx), size[level]*ca->bytes);
  }
  else {
    for (i=0; i<size[level]; i++) {
      idx[level] = offset[level] + i;
      idx0[level] = offset0[level] + i;
      ca_clip_loop(ca, offset, offset0, size, cs, level+1, idx, idx0);
    }
  }
}

/* ------------------------------------------------------------------- */

void
ca_clip (void *ap, int32_t *offset, void *sp)
{
  CArray *ca = (CArray *) ap;
  CArray *cs = (CArray *) sp;
  int32_t size[CA_RANK_MAX];
  int32_t offset0[CA_RANK_MAX];
  int32_t idx[CA_RANK_MAX];
  int32_t idx0[CA_RANK_MAX];
  int i;

  ca_check_same_data_type(ca, cs);
  ca_check_same_rank(ca, cs);

  for (i=0; i<ca->rank; i++) {
    if ( offset[i] >= 0 ) {
      if ( ca->dim[i] <= cs->dim[i] + offset[i] ) {
        size[i] = ca->dim[i] - offset[i];
      }
      else {
        size[i] = cs->dim[i];
      }
      offset0[i] = 0;
    }
    else {
      if ( ca->dim[i] <= cs->dim[i] + offset[i] ) {
        size[i] = ca->dim[i];
      }
      else {
        size[i] = cs->dim[i] + offset[i];
      }
      offset0[i] = -offset[i];
      offset[i] = 0;
    }
  }

  for (i=0; i<ca->rank; i++) {
    CA_CHECK_INDEX(offset[i], ca->dim[i]);
  }

  if ( ca_has_mask(cs) ) {
    ca_create_mask(ca);
  }

  ca_attach_n(2, ca, cs);

  ca_clip_loop(ca, offset, offset0, size, cs, 0, idx, idx0);

  if ( ca_has_mask(cs) ) {
    ca_clip_loop(ca->mask, offset, offset0, size, cs->mask, 0, idx, idx0);
  }

  ca_sync(ca);
  ca_detach_n(2, ca, cs);
}

/* rdoc:
  class CArray
    # clips the data at `idx` from `self` to `ary`.
    def clip (idx, ary)
    end
  end
*/

static VALUE
rb_ca_clip (VALUE self, VALUE roffset, VALUE rsrc)
{
  CArray *ca, *cs;
  int32_t offset[CA_RANK_MAX];
  int i;

  Data_Get_Struct(self, CArray, ca);

  Check_Type(roffset, T_ARRAY);

  if ( RARRAY_LEN(roffset) != ca->rank ) {
    rb_raise(rb_eArgError,
             "# of arguments should equal to the rank");
  }

  for (i=0; i<ca->rank; i++) {
    offset[i] = NUM2INT(rb_ary_entry(roffset, i));
  }

  cs = ca_wrap_writable(rsrc, ca->data_type);

  ca_clip(ca, offset, cs);

  return rsrc;
}

/* ------------------------------------------------------------------- */

void
Init_carray_copy ()
{
  /* CArray duplication, conversion */

  rb_define_method(rb_cCArray, "to_ca", rb_ca_copy, 0);
  rb_define_method(rb_cCArray, "template", rb_ca_template_method, -1);

  rb_define_method(rb_cCArray, "clip", rb_ca_clip, 2);
  rb_define_method(rb_cCArray, "paste", rb_ca_paste, 2);
}

