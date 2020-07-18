/* ---------------------------------------------------------------------------

  carray_element.c

  This file is part of Ruby/CArray extension library.

  Copyright (C) 2005-2020 Hiroki Motoyoshi

---------------------------------------------------------------------------- */

#include "ruby.h"
#include "carray.h"

/* ------------------------------------------------------------------- */

/* yard:
  class CArray
    def elem_swap
    end
  end
*/

VALUE
rb_ca_elem_swap (VALUE self, VALUE ridx1, VALUE ridx2)
{
  CArray *ca;
  ca_size_t idx1[CA_RANK_MAX], idx2[CA_RANK_MAX];
  ca_size_t addr1 = 0, addr2 = 0;
  int8_t  i;
  ca_size_t k;
  int     has_mask, has_index1, has_index2;
  char   _val1[32], _val2[32];
  char   *val1 = _val1, *val2 = _val2;
  boolean8_t m1 = 0, m2 = 0;

  rb_ca_modify(self);

  Data_Get_Struct(self, CArray, ca);

  ca_update_mask(ca);
  has_mask = ( ca->mask ) ? 1 : 0;

  if ( ca->bytes > 32 ) {
    val1 = malloc_with_check(ca->bytes);
    val2 = malloc_with_check(ca->bytes);
  }

  if ( TYPE(ridx1) == T_ARRAY ) {
    for (i=0; i<ca->ndim; i++) {
      k = NUM2SIZE(rb_ary_entry(ridx1, i));
      CA_CHECK_INDEX(k, ca->dim[i]);
      idx1[i] = k;
    }
    has_index1 = 1;
    ca_fetch_index(ca, idx1, val1);
    if ( has_mask ) {
      ca_fetch_index(ca->mask, idx1, &m1);
    }
  }
  else {
    k = NUM2SIZE(ridx1);
    CA_CHECK_INDEX(k, ca->elements);
    addr1 = k;
    has_index1 = 0;
    ca_fetch_addr(ca, addr1, val1);
    if ( has_mask ) {
      ca_fetch_addr(ca->mask, addr1, &m1);
    }
  }

  if ( TYPE(ridx2) == T_ARRAY ) {
    for (i=0; i<ca->ndim; i++) {
      k = NUM2SIZE(rb_ary_entry(ridx2, i));
      CA_CHECK_INDEX(k, ca->dim[i]);
      idx2[i] = k;
    }
    has_index2 = 1;
    ca_fetch_index(ca, idx2, val2);
    if ( has_mask ) {
      ca_fetch_index(ca->mask, idx2, &m2);
    }
  }
  else {
    k = NUM2SIZE(ridx2);
    CA_CHECK_INDEX(k, ca->elements);
    addr2 = k;
    has_index2 = 0;
    ca_fetch_addr(ca, addr2, val2);
    if ( has_mask ) {
      ca_fetch_addr(ca->mask, addr2, &m2);
    }
  }

  if ( has_index1 ) {
    ca_store_index(ca, idx1, val2);
    if ( has_mask ) {
      ca_store_index(ca->mask, idx1, &m2);
    }
  }
  else {
    ca_store_addr(ca, addr1, val2);
    if ( has_mask ) {
      ca_store_addr(ca->mask, addr1, &m2);
    }
  }

  if ( has_index2 ) {
    ca_store_index(ca, idx2, val1);
    if ( has_mask ) {
      ca_store_index(ca->mask, idx2, &m1);
    }
  }
  else {
    ca_store_addr(ca, addr2, val1);
    if ( has_mask ) {
      ca_store_addr(ca->mask, addr2, &m1);
    }
  }

  if ( ca->bytes > 32 ) {
    free(val1);
    free(val2);
  }

  return self;
}

/* yard:
  class CArray
    def elem_copy
    end
  end
*/

VALUE
rb_ca_elem_copy (VALUE self, VALUE ridx1, VALUE ridx2)
{
  CArray *ca;
  ca_size_t idx1[CA_RANK_MAX], idx2[CA_RANK_MAX];
  ca_size_t addr1 = 0, addr2 = 0;
  int8_t  i;
  ca_size_t k;
  int     has_mask;
  char   _val[32];
  char   *val = _val;
  boolean8_t m = 0;

  rb_ca_modify(self);

  Data_Get_Struct(self, CArray, ca);

  ca_update_mask(ca);
  has_mask = ( ca->mask ) ? 1 : 0;

  if ( ca->bytes > 32 ) {
    val = malloc_with_check(ca->bytes);
  }

  if ( TYPE(ridx1) == T_ARRAY ) {
    for (i=0; i<ca->ndim; i++) {
      k = NUM2SIZE(rb_ary_entry(ridx1, i));
      CA_CHECK_INDEX(k, ca->dim[i]);
      idx1[i] = k;
    }
    ca_fetch_index(ca, idx1, val);
    if ( has_mask ) {
      ca_fetch_index(ca->mask, idx1, &m);
    }
  }
  else {
    k = NUM2SIZE(ridx1);
    CA_CHECK_INDEX(k, ca->elements);
    addr1 = k;
    ca_fetch_addr(ca, addr1, val);
    if ( has_mask ) {
      ca_fetch_addr(ca->mask, addr1, &m);
    }
  }

  if ( TYPE(ridx2) == T_ARRAY ) {
    for (i=0; i<ca->ndim; i++) {
      k = NUM2SIZE(rb_ary_entry(ridx2, i));
      CA_CHECK_INDEX(k, ca->dim[i]);
      idx2[i] = k;
    }
    ca_store_index(ca, idx2, val);
    if ( has_mask ) {
      ca_store_index(ca->mask, idx2, &m);
    }
  }
  else {
    k = NUM2SIZE(ridx2);
    CA_CHECK_INDEX(k, ca->elements);
    addr2 = k;
    ca_store_addr(ca, addr2, val);
    if ( has_mask ) {
      ca_store_addr(ca->mask, addr2, &m);
    }
  }

  if ( ca->bytes > 32 ) {
    free(val);
  }

  return self;
}

/* yard:
  class CArray
    def elem_store
    end
  end
*/

VALUE
rb_ca_elem_store (VALUE self, VALUE ridx, VALUE obj)
{
  CArray *ca;
  ca_size_t idx[CA_RANK_MAX];
  ca_size_t addr = 0;
  int8_t  i;
  ca_size_t k;

  rb_ca_modify(self);

  Data_Get_Struct(self, CArray, ca);

  if ( TYPE(ridx) == T_ARRAY ) {
    for (i=0; i<ca->ndim; i++) {
      k = NUM2SIZE(rb_ary_entry(ridx, i));
      CA_CHECK_INDEX(k, ca->dim[i]);
      idx[i] = k;
    }
    rb_ca_store_index(self, idx, obj);
  }
  else {
    k = NUM2SIZE(ridx);
    CA_CHECK_INDEX(k, ca->elements);
    addr = k;
    rb_ca_store_addr(self, addr, obj);
  }

  return obj;
}

/* yard:
  class CArray
    def elem_fetch
    end
  end
*/

VALUE
rb_ca_elem_fetch (VALUE self, VALUE ridx)
{
  CArray *ca;
  ca_size_t idx[CA_RANK_MAX];
  ca_size_t addr = 0;
  int8_t  i;
  ca_size_t k;

  Data_Get_Struct(self, CArray, ca);

  if ( TYPE(ridx) == T_ARRAY ) {
    for (i=0; i<ca->ndim; i++) {
      k = NUM2SIZE(rb_ary_entry(ridx, i));
      CA_CHECK_INDEX(k, ca->dim[i]);
      idx[i] = k;
    }
    return rb_ca_fetch_index(self, idx);
  }
  else {
    k = NUM2SIZE(ridx);
    CA_CHECK_INDEX(k, ca->elements);
    addr = k;
    return rb_ca_fetch_addr(self, addr);
  }
}

/* yard:
  class CArray
    def elem_incr
    end
  end
*/

VALUE
rb_ca_elem_incr (VALUE self, VALUE ridx1)
{
  volatile VALUE out;
  CArray *ca;
  ca_size_t idx1[CA_RANK_MAX];
  ca_size_t addr1 = 0;
  int8_t  i;
  ca_size_t k;
  int     has_index1 = 0;
  int     has_mask;
  char   _val[8];
  char   *val = _val;
  boolean8_t m = 0;

  rb_ca_modify(self);

  Data_Get_Struct(self, CArray, ca);

  if ( ! ca_is_integer_type(ca) ) {
    rb_raise(rb_eCADataTypeError,
             "incremented array should be an integer array");
  }

  ca_update_mask(ca);
  has_mask = ( ca->mask ) ? 1 : 0;

  if ( TYPE(ridx1) == T_ARRAY ) {
    for (i=0; i<ca->ndim; i++) {
      k = NUM2SIZE(rb_ary_entry(ridx1, i));
      CA_CHECK_INDEX(k, ca->dim[i]);
      idx1[i] = k;
    }
    if ( has_mask ) {
      ca_fetch_index(ca->mask, idx1, &m);
    }
    if ( m ) {
      return Qnil;
    }
    else {
      ca_fetch_index(ca, idx1, val);
    }
    has_index1 = 1;
  }
  else {
    k = NUM2SIZE(ridx1);
    CA_CHECK_INDEX(k, ca->elements);
    addr1 = k;
    if ( has_mask ) {
      ca_fetch_addr(ca->mask, addr1, &m);
    }
    if ( m ) {
      return Qnil;
    }
    else {
      ca_fetch_addr(ca, addr1, val);
    }
  }

  switch ( ca->data_type ) {
  case CA_INT8:   out = INT2NUM(++*((int8_t*)  val)); break;
  case CA_UINT8:  out = UINT2NUM(++*((uint8_t*)  val)); break;
  case CA_INT16:  out = INT2NUM(++*((int16_t*) val)); break;
  case CA_UINT16: out = UINT2NUM(++*((uint16_t*) val)); break;
  case CA_INT32:  out = INT2NUM(++*((int32_t*) val)); break;
  case CA_UINT32: out = UINT2NUM(++*((uint32_t*) val)); break;
  case CA_INT64:  out = LL2NUM(++*((int64_t*) val)); break;
  case CA_UINT64: out = ULL2NUM(++*((uint64_t*) val)); break;
  }

  if ( has_index1 ) {
    ca_store_index(ca, idx1, val);
  }
  else {
    ca_store_addr(ca, addr1, val);
  }

  return out;
}

/* yard:
  class CArray
    def elem_decr
    end
  end
*/

VALUE
rb_ca_elem_decr (VALUE self, VALUE ridx1)
{
  volatile VALUE out;
  CArray *ca;
  ca_size_t idx1[CA_RANK_MAX];
  ca_size_t addr1 = 0;
  int8_t  i;
  ca_size_t k;
  int     has_index1 = 0;
  int     has_mask;
  char   _val[8];
  char   *val = _val;
  boolean8_t m = 0;

  rb_ca_modify(self);

  Data_Get_Struct(self, CArray, ca);

  if ( ! ca_is_integer_type(ca) ) {
    rb_raise(rb_eCADataTypeError,
             "decremented array should be an integer array");
  }

  ca_update_mask(ca);
  has_mask = ( ca->mask ) ? 1 : 0;

  if ( TYPE(ridx1) == T_ARRAY ) {
    for (i=0; i<ca->ndim; i++) {
      k = NUM2SIZE(rb_ary_entry(ridx1, i));
      CA_CHECK_INDEX(k, ca->dim[i]);
      idx1[i] = k;
    }
    if ( has_mask ) {
      ca_fetch_index(ca->mask, idx1, &m);
    }
    if ( m ) {
      return Qnil;
    }
    else {
      ca_fetch_index(ca, idx1, val);
    }
    has_index1 = 1;
  }
  else {
    k = NUM2SIZE(ridx1);
    CA_CHECK_INDEX(k, ca->elements);
    addr1 = k;
    if ( has_mask ) {
      ca_fetch_addr(ca->mask, addr1, &m);
    }
    if ( m ) {
      return Qnil;
    }
    else {
      ca_fetch_addr(ca, addr1, val);
    }
  }

  switch ( ca->data_type ) {
  case CA_INT8:   out = INT2NUM(--*((int8_t*)  val)); break;
  case CA_UINT8:  out = UINT2NUM(--*((uint8_t*)  val)); break;
  case CA_INT16:  out = INT2NUM(--*((int16_t*) val)); break;
  case CA_UINT16: out = UINT2NUM(--*((uint16_t*) val)); break;
  case CA_INT32:  out = INT2NUM(--*((int32_t*) val)); break;
  case CA_UINT32: out = UINT2NUM(--*((uint32_t*) val)); break;
  case CA_INT64:  out = INT2NUM(--*((int64_t*) val)); break;
  case CA_UINT64: out = UINT2NUM(--*((uint64_t*) val)); break;
  }

  if ( has_index1 ) {
    ca_store_index(ca, idx1, val);
  }
  else {
    ca_store_addr(ca, addr1, val);
  }

  return out;
}

/* yard:
  class CArray
    def elem_masked?
    end
  end
*/

VALUE
rb_ca_elem_test_masked (VALUE self, VALUE ridx1)
{
  CArray *ca;
  ca_size_t idx1[CA_RANK_MAX];
  ca_size_t addr1 = 0;
  int8_t  i;
  ca_size_t k;
  boolean8_t m = 0;

  Data_Get_Struct(self, CArray, ca);

  ca_update_mask(ca);

  if ( TYPE(ridx1) == T_ARRAY ) {
    for (i=0; i<ca->ndim; i++) {
      k = NUM2SIZE(rb_ary_entry(ridx1, i));
      CA_CHECK_INDEX(k, ca->dim[i]);
      idx1[i] = k;
    }
    if ( ca->mask ) {
      ca_fetch_index(ca->mask, idx1, &m);
    }
  }
  else {
    k = NUM2SIZE(ridx1);
    CA_CHECK_INDEX(k, ca->elements);
    addr1 = k;
    if ( ca->mask ) {
      ca_fetch_addr(ca->mask, addr1, &m);
    }
  }

  return m ? Qtrue : Qfalse;
}

/* ----------------------------------------------------------------- */

/* yard:
  class CArray
    # used in CAHistogram.
    def incr_addr
    end
  end
*/

static VALUE
rb_ca_incr_addr (volatile VALUE self, volatile VALUE raddr)
{
  CArray  *ca, *ci;
  int64_t *q, *p;
  ca_size_t k, elements;
  ca_size_t i;
  boolean8_t *m;

  rb_ca_modify(self);

  self = rb_ca_wrap_writable(self, INT2NUM(CA_INT64));
  raddr = rb_ca_wrap_readonly(raddr, INT2NUM(CA_INT64));
  
  Data_Get_Struct(self, CArray, ca);
  Data_Get_Struct(raddr, CArray, ci);

  ca_attach_n(2, ca, ci);

  q = (int64_t *) ca->ptr;
  p = (int64_t *) ci->ptr;
  m = ( ci->mask ) ? (boolean8_t *) ci->mask->ptr : NULL;

  elements = ca->elements;

  if ( m ) {
    #ifdef _OPENMP
    #pragma omp parallel for 
    #endif
    for (i=0; i<ci->elements; i++) {
      if ( ! *(m+i) ) {
        k = *(p+i);
        CA_CHECK_INDEX(k, elements);
        *(q + k) += 1;
      }
    }
  }
  else {
    #ifdef _OPENMP
    #pragma omp parallel for 
    #endif
    for (i=0; i<ci->elements; i++) {
      k = *(p+i);
      CA_CHECK_INDEX(k, elements);
      *(q + k) += 1;
    }
  }

  ca_sync(ca);
  ca_detach_n(2, ca, ci);

  return Qnil;
}

/* ----------------------------------------------------------------- */

void
Init_carray_element ()
{
  rb_define_method(rb_cCArray,  "elem_swap",  rb_ca_elem_swap,  2);
  rb_define_method(rb_cCArray,  "elem_copy",  rb_ca_elem_copy,  2);
  rb_define_method(rb_cCArray,  "elem_store", rb_ca_elem_store, 2);
  rb_define_method(rb_cCArray,  "elem_fetch", rb_ca_elem_fetch, 1);

  rb_define_method(rb_cCArray,  "elem_incr",  rb_ca_elem_incr,  1);
  rb_define_method(rb_cCArray,  "elem_decr",  rb_ca_elem_decr,  1);

  rb_define_method(rb_cCArray,  "elem_masked?", rb_ca_elem_test_masked, 1);

  rb_define_method(rb_cCArray,  "incr_addr", rb_ca_incr_addr, 1);
}

