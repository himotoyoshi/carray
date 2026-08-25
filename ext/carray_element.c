/* ---------------------------------------------------------------------------

  Per-cell (`elem_*`) hot-path family for tight scalar loops
  (histogram increment, scatter writes, per-cell swap / mask).

  These skip the indexer front-end (`ca[i,j,k]` -> scan_index_v2 ->
  ref_point) and land at the same `rb_ca_fetch_index` backend with
  the front-end dispatcher removed.  Inline helpers below collapse
  the remaining per-call overheads (double TypedData_Get_Struct,
  T_ARRAY bounds check, NUM2SIZE Bignum branch, ca_update_mask
  function-call for the entity + no-mask common case).  Semantics
  match the indexer path.

  YARD signatures live in yard-stubs/carray_element.rb.

---------------------------------------------------------------------------- */

#include "ruby.h"
#include "carray.h"
#include "ca_obj_face.h"

/* T_ARRAY index parser.  ridx is assumed already known to be T_ARRAY.
   Direct VALUE * access + FIXNUM_P fast path eliminates rb_ary_entry
   bounds check and NUM2SIZE Bignum branching for the common case. */
static inline void
elem_parse_idx_array (CArray *ca, VALUE rary, ca_size_t *idx)
{
  const VALUE *iarr = RARRAY_CONST_PTR(rary);
  int8_t ndim = ca->ndim;
  int8_t i;
  for (i=0; i<ndim; i++) {
    VALUE v = iarr[i];
    ca_size_t k = FIXNUM_P(v) ? (ca_size_t)FIX2LONG(v) : NUM2SIZE(v);
    CA_CHECK_INDEX(k, ca->dim[i]);
    idx[i] = k;
  }
}

/* Scalar index parser (flat addr).  FIXNUM_P fast path. */
static inline ca_size_t
elem_parse_idx_scalar (CArray *ca, VALUE ridx)
{
  ca_size_t k = FIXNUM_P(ridx) ? (ca_size_t)FIX2LONG(ridx) : NUM2SIZE(ridx);
  CA_CHECK_INDEX(k, ca->elements);
  return k;
}

/* Mask-existence probe with inline skip for the entity+no-mask common
   case.  Equivalent to `ca_update_mask(ca); has_mask = (ca->mask != NULL);`
   but avoids the function call when the result is statically known. */
static inline int
elem_probe_mask (CArray *ca)
{
  if ( ca->mask ) return 1;             /* mask already materialised */
  if ( ca_is_entity(ca) ) return 0;     /* entity + no mask: definitely none */
  ca_update_mask(ca);                   /* view: may need to materialise */
  return ( ca->mask != NULL );
}

/* Entity-array fast path: compute flat addr from idx[] and access ptr directly.
   Bypasses ca_func[ARRAY].xfer_index function-pointer dispatch.
   Caller must ensure ca_is_entity(ca) and ca->ptr is attached (= entity
   arrays are always attached by definition). */
static inline ca_size_t
elem_entity_addr (CArray *ca, ca_size_t *idx)
{
  ca_size_t n = idx[0];
  int8_t i;
  for (i=1; i<ca->ndim; i++) {
    n = ca->dim[i] * n + idx[i];
  }
  return n;
}

/* ------------------------------------------------------------------- */

/* `elem_swap(idx1, idx2)` — exchanges the values (and mask states,
 * if any) at cells `idx1` and `idx2` in place.  `idx*` accept either
 * a flat Integer address or an Array<Integer> of per-axis indices. */

VALUE
rb_ca_elem_swap (VALUE self, VALUE ridx1, VALUE ridx2)
{
  CArray *ca;
  ca_size_t idx1[CA_RANK_MAX], idx2[CA_RANK_MAX];
  ca_size_t addr1 = 0, addr2 = 0;
  int     has_mask, has_index1, has_index2;
  char   _val1[64], _val2[64];
  char   *val1 = _val1, *val2 = _val2;
  boolean8_t m1 = 0, m2 = 0;

  rb_ca_modify(self);

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  has_mask = elem_probe_mask(ca);

  if ( ca->bytes > 64 ) {
    val1 = xmalloc(ca->bytes);
    val2 = xmalloc(ca->bytes);
  }

  if ( TYPE(ridx1) == T_ARRAY ) {
    elem_parse_idx_array(ca, ridx1, idx1);
    has_index1 = 1;
    ca_fetch_index(ca, idx1, val1);
    if ( has_mask ) {
      ca_fetch_index(ca->mask, idx1, &m1);
    }
  }
  else {
    addr1 = elem_parse_idx_scalar(ca, ridx1);
    has_index1 = 0;
    ca_fetch_addr(ca, addr1, val1);
    if ( has_mask ) {
      ca_fetch_addr(ca->mask, addr1, &m1);
    }
  }

  if ( TYPE(ridx2) == T_ARRAY ) {
    elem_parse_idx_array(ca, ridx2, idx2);
    has_index2 = 1;
    ca_fetch_index(ca, idx2, val2);
    if ( has_mask ) {
      ca_fetch_index(ca->mask, idx2, &m2);
    }
  }
  else {
    addr2 = elem_parse_idx_scalar(ca, ridx2);
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

  if ( ca->bytes > 64 ) {
    xfree(val1);
    xfree(val2);
  }

  return self;
}

/* `elem_copy(idx1, idx2)` — copies the value (and mask state) at
 * `idx1` into the cell at `idx2`; source cell is left unchanged. */

VALUE
rb_ca_elem_copy (VALUE self, VALUE ridx1, VALUE ridx2)
{
  CArray *ca;
  ca_size_t idx1[CA_RANK_MAX], idx2[CA_RANK_MAX];
  ca_size_t addr1 = 0, addr2 = 0;
  int     has_mask;
  char   _val[64];
  char   *val = _val;
  boolean8_t m = 0;

  rb_ca_modify(self);

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  has_mask = elem_probe_mask(ca);

  if ( ca->bytes > 64 ) {
    val = xmalloc(ca->bytes);
  }

  if ( TYPE(ridx1) == T_ARRAY ) {
    elem_parse_idx_array(ca, ridx1, idx1);
    ca_fetch_index(ca, idx1, val);
    if ( has_mask ) {
      ca_fetch_index(ca->mask, idx1, &m);
    }
  }
  else {
    addr1 = elem_parse_idx_scalar(ca, ridx1);
    ca_fetch_addr(ca, addr1, val);
    if ( has_mask ) {
      ca_fetch_addr(ca->mask, addr1, &m);
    }
  }

  if ( TYPE(ridx2) == T_ARRAY ) {
    elem_parse_idx_array(ca, ridx2, idx2);
    ca_store_index(ca, idx2, val);
    if ( has_mask ) {
      ca_store_index(ca->mask, idx2, &m);
    }
  }
  else {
    addr2 = elem_parse_idx_scalar(ca, ridx2);
    ca_store_addr(ca, addr2, val);
    if ( has_mask ) {
      ca_store_addr(ca->mask, addr2, &m);
    }
  }

  if ( ca->bytes > 64 ) {
    xfree(val);
  }

  return self;
}

/* `elem_store(idx, obj)` — stores `obj` (cast to `self.data_type`)
 * at cell `idx`, clearing any mask state there.  Passing `UNDEF`
 * masks the cell. */

VALUE
rb_ca_elem_store (VALUE self, VALUE ridx, VALUE obj)
{
  CArray *ca;
  ca_size_t idx[CA_RANK_MAX];
  ca_size_t addr;
  int from_array;

  rb_ca_modify(self);

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  if ( TYPE(ridx) == T_ARRAY ) {
    elem_parse_idx_array(ca, ridx, idx);
    from_array = 1;
  }
  else {
    addr = elem_parse_idx_scalar(ca, ridx);
    from_array = 0;
  }

  /* Super-hot path: entity + no mask + common numeric dtype + Numeric obj.
     Bypasses rb_ca_store_index/addr -> ca_update_mask + rb_ca_obj2ptr ->
     cast_table dispatch.  Falls through to general path for: views,
     existing mask, non-numeric dtype, UNDEF, or non-Numeric obj. */
  if ( ca_is_entity(ca) && ! ca->mask && obj != CA_UNDEF ) {
    int8_t dt = ca->data_type;
    if ( dt == CA_FLOAT64 || dt == CA_FLOAT32 ||
         dt == CA_INT64   || dt == CA_INT32  ||
         dt == CA_INT16   || dt == CA_INT8   ||
         dt == CA_UINT64  || dt == CA_UINT32 ||
         dt == CA_UINT16  || dt == CA_UINT8  ||
         dt == CA_BOOLEAN ) {
      /* Compute flat addr if T_ARRAY index path. */
      if ( from_array ) addr = elem_entity_addr(ca, idx);
      char *p = ca->ptr + ca->bytes * addr;
      /* Convert obj to dtype + store.  Restrict to Fixnum / Float / true
         / false to avoid Bignum / Rational / Complex coercion that the
         cast_table handles in the general path. */
      switch ( dt ) {
      case CA_FLOAT64:
        if ( RB_FLOAT_TYPE_P(obj) )      { *(double *)p = RFLOAT_VALUE(obj); return obj; }
        if ( FIXNUM_P(obj) )             { *(double *)p = (double)FIX2LONG(obj); return obj; }
        break;
      case CA_FLOAT32:
        if ( RB_FLOAT_TYPE_P(obj) )      { *(float *)p = (float)RFLOAT_VALUE(obj); return obj; }
        if ( FIXNUM_P(obj) )             { *(float *)p = (float)FIX2LONG(obj); return obj; }
        break;
      case CA_INT64:
        if ( FIXNUM_P(obj) )             { *(int64_t *)p = (int64_t)FIX2LONG(obj); return obj; }
        break;
      case CA_INT32:
        if ( FIXNUM_P(obj) )             { *(int32_t *)p = (int32_t)FIX2LONG(obj); return obj; }
        break;
      case CA_INT16:
        if ( FIXNUM_P(obj) )             { *(int16_t *)p = (int16_t)FIX2LONG(obj); return obj; }
        break;
      case CA_INT8:
        if ( FIXNUM_P(obj) )             { *(int8_t *)p = (int8_t)FIX2LONG(obj); return obj; }
        break;
      case CA_UINT64:
        if ( FIXNUM_P(obj) )             { *(uint64_t *)p = (uint64_t)FIX2LONG(obj); return obj; }
        break;
      case CA_UINT32:
        if ( FIXNUM_P(obj) )             { *(uint32_t *)p = (uint32_t)FIX2LONG(obj); return obj; }
        break;
      case CA_UINT16:
        if ( FIXNUM_P(obj) )             { *(uint16_t *)p = (uint16_t)FIX2LONG(obj); return obj; }
        break;
      case CA_UINT8:
        if ( FIXNUM_P(obj) )             { *(uint8_t *)p = (uint8_t)FIX2LONG(obj); return obj; }
        break;
      case CA_BOOLEAN:
        if ( obj == Qtrue )              { *(uint8_t *)p = 1; return obj; }
        if ( obj == Qfalse )             { *(uint8_t *)p = 0; return obj; }
        if ( FIXNUM_P(obj) )             { *(uint8_t *)p = (FIX2LONG(obj) != 0); return obj; }
        break;
      }
      /* Fall through: dtype matches but obj kind needs general coercion. */
    }
  }

  /* General path: dispatch through rb_ca_store_index/addr. */
  if ( from_array ) {
    rb_ca_store_index(self, idx, obj);
  }
  else {
    rb_ca_store_addr(self, addr, obj);
  }

  return obj;
}

/* `elem_fetch(idx)` — returns the value at cell `idx` (cast to a
 * Ruby object).  Returns `UNDEF` if the cell is masked, `nil` if
 * `self` is empty. */

VALUE
rb_ca_elem_fetch (VALUE self, VALUE ridx)
{
  CArray *ca;
  ca_size_t idx[CA_RANK_MAX];

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  if ( ca_is_empty(ca) ) return Qnil;

  if ( TYPE(ridx) == T_ARRAY ) {
    volatile VALUE out;
    elem_parse_idx_array(ca, ridx, idx);

    /* Super-hot path: entity + common numeric dtype + no mask.
       Bypass ca_fetch_index dispatch AND rb_ca_ptr2obj cast-table dispatch.
       Covers the bench's float64 / int64 / int32 cases. */
    if ( ca_is_entity(ca) && ! ca->mask ) {
      ca_size_t addr = elem_entity_addr(ca, idx);
      char *p = ca->ptr + ca->bytes * addr;
      switch ( ca->data_type ) {
      case CA_FLOAT64: return rb_float_new(*(double *)p);
      case CA_INT64:   return LL2NUM(*(int64_t *)p);
      case CA_INT32:   return INT2NUM(*(int32_t *)p);
      case CA_FLOAT32: return rb_float_new((double)*(float *)p);
      case CA_INT16:   return INT2FIX(*(int16_t *)p);
      case CA_INT8:    return INT2FIX(*(int8_t *)p);
      case CA_UINT8:   return INT2FIX(*(uint8_t *)p);
      case CA_UINT16:  return INT2FIX(*(uint16_t *)p);
      case CA_UINT32:  return UINT2NUM(*(uint32_t *)p);
      case CA_UINT64:  return ULL2NUM(*(uint64_t *)p);
      case CA_BOOLEAN: return (*(uint8_t *)p) ? Qtrue : Qfalse;
      /* default: fall through to general path below */
      }
    }

    /* General path: inlined rb_ca_fetch_index body (avoid duplicate
       TypedData_Get_Struct).  Semantics identical to rb_ca_fetch_index. */
    if ( ca->bytes <= 64 ) {
      char v[64];
      if ( ca_is_entity(ca) ) {
        ca_size_t addr = elem_entity_addr(ca, idx);
        memcpy(v, ca->ptr + ca->bytes * addr, ca->bytes);
      }
      else {
        ca_fetch_index(ca, idx, v);
      }
      out = rb_ca_ptr2obj(self, v);
    }
    else {
      char *v = xmalloc(ca->bytes);
      ca_fetch_index(ca, idx, v);
      out = rb_ca_ptr2obj(self, v);
      xfree(v);
    }

    /* Mask check with inline skip for the entity+no-mask common case. */
    if ( ca->mask ) {
      boolean8_t mval;
      ca_fetch_index(ca->mask, idx, &mval);
      if ( mval ) return CA_UNDEF;
    }
    else if ( ! ca_is_entity(ca) ) {
      ca_update_mask(ca);
      if ( ca->mask ) {
        boolean8_t mval;
        ca_fetch_index(ca->mask, idx, &mval);
        if ( mval ) return CA_UNDEF;
      }
    }

    CA_FACE_STORAGE_TO_SCALAR_IF_FACE(out, self, ca);
    return out;
  }
  else {
    ca_size_t addr = elem_parse_idx_scalar(ca, ridx);
    /* Super-hot flat-addr path: entity + numeric + no mask. */
    if ( ca_is_entity(ca) && ! ca->mask ) {
      char *p = ca->ptr + ca->bytes * addr;
      switch ( ca->data_type ) {
      case CA_FLOAT64: return rb_float_new(*(double *)p);
      case CA_INT64:   return LL2NUM(*(int64_t *)p);
      case CA_INT32:   return INT2NUM(*(int32_t *)p);
      case CA_FLOAT32: return rb_float_new((double)*(float *)p);
      case CA_INT16:   return INT2FIX(*(int16_t *)p);
      case CA_INT8:    return INT2FIX(*(int8_t *)p);
      case CA_UINT8:   return INT2FIX(*(uint8_t *)p);
      case CA_UINT16:  return INT2FIX(*(uint16_t *)p);
      case CA_UINT32:  return UINT2NUM(*(uint32_t *)p);
      case CA_UINT64:  return ULL2NUM(*(uint64_t *)p);
      case CA_BOOLEAN: return (*(uint8_t *)p) ? Qtrue : Qfalse;
      }
    }
    return rb_ca_fetch_addr(self, addr);
  }
}

/* `elem_incr(idx)` — increments the integer cell at `idx` by 1 in
 * place, returning the new value.  Masked cells are skipped (returns
 * `nil`).  Raises for non-integer data_type. */

VALUE
rb_ca_elem_incr (VALUE self, VALUE ridx1)
{
  volatile VALUE out;
  CArray *ca;
  ca_size_t idx1[CA_RANK_MAX];
  ca_size_t addr1 = 0;
  int     has_index1 = 0;
  int     has_mask;
  char    val[8];
  boolean8_t m = 0;

  rb_ca_modify(self);

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  if ( ! ca_is_integer_type(ca) ) {
    rb_raise(rb_eCADataTypeError,
             "incremented array should be an integer array");
  }

  has_mask = elem_probe_mask(ca);

  /* Super-hot path: entity + no mask + integer dtype.
     Reads p directly, modifies in place — no separate fetch/store dispatch. */
  if ( ca_is_entity(ca) && ! has_mask ) {
    ca_size_t addr;
    if ( TYPE(ridx1) == T_ARRAY ) {
      elem_parse_idx_array(ca, ridx1, idx1);
      addr = elem_entity_addr(ca, idx1);
    }
    else {
      addr = elem_parse_idx_scalar(ca, ridx1);
    }
    void *p = ca->ptr + ca->bytes * addr;
    switch ( ca->data_type ) {
    case CA_INT8:   return INT2FIX(++*((int8_t  *)p));
    case CA_UINT8:  return INT2FIX(++*((uint8_t *)p));
    case CA_INT16:  return INT2FIX(++*((int16_t *)p));
    case CA_UINT16: return INT2FIX(++*((uint16_t*)p));
    case CA_INT32:  return INT2NUM(++*((int32_t *)p));
    case CA_UINT32: return UINT2NUM(++*((uint32_t*)p));
    case CA_INT64:  return LL2NUM(++*((int64_t *)p));
    case CA_UINT64: return ULL2NUM(++*((uint64_t*)p));
    }
  }

  /* General path: view array or masked. */
  if ( TYPE(ridx1) == T_ARRAY ) {
    elem_parse_idx_array(ca, ridx1, idx1);
    if ( has_mask ) {
      ca_fetch_index(ca->mask, idx1, &m);
      if ( m ) return Qnil;
    }
    ca_fetch_index(ca, idx1, val);
    has_index1 = 1;
  }
  else {
    addr1 = elem_parse_idx_scalar(ca, ridx1);
    if ( has_mask ) {
      ca_fetch_addr(ca->mask, addr1, &m);
      if ( m ) return Qnil;
    }
    ca_fetch_addr(ca, addr1, val);
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

/* `elem_decr(idx)` — decrements the integer cell at `idx` by 1 in
 * place, returning the new value.  Masked cells are skipped (returns
 * `nil`).  Raises for non-integer data_type. */

VALUE
rb_ca_elem_decr (VALUE self, VALUE ridx1)
{
  volatile VALUE out;
  CArray *ca;
  ca_size_t idx1[CA_RANK_MAX];
  ca_size_t addr1 = 0;
  int     has_index1 = 0;
  int     has_mask;
  char    val[8];
  boolean8_t m = 0;

  rb_ca_modify(self);

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  if ( ! ca_is_integer_type(ca) ) {
    rb_raise(rb_eCADataTypeError,
             "decremented array should be an integer array");
  }

  has_mask = elem_probe_mask(ca);

  /* Super-hot path: mirror of elem_incr. */
  if ( ca_is_entity(ca) && ! has_mask ) {
    ca_size_t addr;
    if ( TYPE(ridx1) == T_ARRAY ) {
      elem_parse_idx_array(ca, ridx1, idx1);
      addr = elem_entity_addr(ca, idx1);
    }
    else {
      addr = elem_parse_idx_scalar(ca, ridx1);
    }
    void *p = ca->ptr + ca->bytes * addr;
    switch ( ca->data_type ) {
    case CA_INT8:   return INT2FIX(--*((int8_t  *)p));
    case CA_UINT8:  return INT2FIX(--*((uint8_t *)p));
    case CA_INT16:  return INT2FIX(--*((int16_t *)p));
    case CA_UINT16: return INT2FIX(--*((uint16_t*)p));
    case CA_INT32:  return INT2NUM(--*((int32_t *)p));
    case CA_UINT32: return UINT2NUM(--*((uint32_t*)p));
    case CA_INT64:  return LL2NUM(--*((int64_t *)p));
    case CA_UINT64: return ULL2NUM(--*((uint64_t*)p));
    }
  }

  if ( TYPE(ridx1) == T_ARRAY ) {
    elem_parse_idx_array(ca, ridx1, idx1);
    if ( has_mask ) {
      ca_fetch_index(ca->mask, idx1, &m);
      if ( m ) return Qnil;
    }
    ca_fetch_index(ca, idx1, val);
    has_index1 = 1;
  }
  else {
    addr1 = elem_parse_idx_scalar(ca, ridx1);
    if ( has_mask ) {
      ca_fetch_addr(ca->mask, addr1, &m);
      if ( m ) return Qnil;
    }
    ca_fetch_addr(ca, addr1, val);
  }

  switch ( ca->data_type ) {
  case CA_INT8:   out = INT2NUM(--*((int8_t*)  val)); break;
  case CA_UINT8:  out = UINT2NUM(--*((uint8_t*)  val)); break;
  case CA_INT16:  out = INT2NUM(--*((int16_t*) val)); break;
  case CA_UINT16: out = UINT2NUM(--*((uint16_t*) val)); break;
  case CA_INT32:  out = INT2NUM(--*((int32_t*) val)); break;
  case CA_UINT32: out = UINT2NUM(--*((uint32_t*) val)); break;
  case CA_INT64:  out = LL2NUM(--*((int64_t*) val)); break;
  case CA_UINT64: out = ULL2NUM(--*((uint64_t*) val)); break;
  }

  if ( has_index1 ) {
    ca_store_index(ca, idx1, val);
  }
  else {
    ca_store_addr(ca, addr1, val);
  }

  return out;
}

/* `elem_masked?(idx)` — returns `true` if the cell at `idx` is
 * masked. */

VALUE
rb_ca_elem_test_masked (VALUE self, VALUE ridx1)
{
  CArray *ca;
  ca_size_t idx1[CA_RANK_MAX];
  boolean8_t m = 0;

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  /* Super-hot path: entity.  Covers both no-mask (Qfalse fast) and masked
     (direct ca->mask->ptr read) cases without dispatch.  Mask itself is
     always a boolean8_t entity (= 1 byte / element, same shape as ca),
     so flat addr from elem_entity_addr applies directly. */
  if ( ca_is_entity(ca) ) {
    ca_size_t addr;
    if ( TYPE(ridx1) == T_ARRAY ) {
      elem_parse_idx_array(ca, ridx1, idx1);
      addr = elem_entity_addr(ca, idx1);
    }
    else {
      addr = elem_parse_idx_scalar(ca, ridx1);
    }
    if ( ! ca->mask ) return Qfalse;
    return ((boolean8_t *)ca->mask->ptr)[addr] ? Qtrue : Qfalse;
  }

  /* General path: view array.  Walk parent chain to materialise mask. */
  ca_update_mask(ca);

  if ( TYPE(ridx1) == T_ARRAY ) {
    elem_parse_idx_array(ca, ridx1, idx1);
    if ( ca->mask ) {
      ca_fetch_index(ca->mask, idx1, &m);
    }
  }
  else {
    ca_size_t addr1 = elem_parse_idx_scalar(ca, ridx1);
    if ( ca->mask ) {
      ca_fetch_addr(ca->mask, addr1, &m);
    }
  }

  return m ? Qtrue : Qfalse;
}

/* `elem_mask(idx)` — sets the mask bit at cell `idx`.  Unlike
 * `a[idx] = UNDEF`, this preserves the underlying stored value, so a
 * later `elem_unmask(idx)` restores it. */

VALUE
rb_ca_elem_mask (VALUE self, VALUE ridx)
{
  CArray *ca;
  ca_size_t idx[CA_RANK_MAX];

  rb_ca_modify(self);

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  /* Super-hot path: entity.  Materialise mask on first call (one-time per
     array), then direct ptr write. */
  if ( ca_is_entity(ca) ) {
    ca_size_t addr;
    if ( TYPE(ridx) == T_ARRAY ) {
      elem_parse_idx_array(ca, ridx, idx);
      addr = elem_entity_addr(ca, idx);
    }
    else {
      addr = elem_parse_idx_scalar(ca, ridx);
    }
    if ( ! ca->mask ) {
      ca_create_mask(ca);  /* raises for value-array / mask-array */
    }
    ((boolean8_t *)ca->mask->ptr)[addr] = 1;
    return self;
  }

  /* General path: view array.  Walk parent chain + dispatch. */
  {
    boolean8_t one = 1;
    ca_update_mask(ca);
    if ( ! ca->mask ) {
      ca_create_mask(ca);
    }
    if ( TYPE(ridx) == T_ARRAY ) {
      elem_parse_idx_array(ca, ridx, idx);
      ca_store_index(ca->mask, idx, &one);
    }
    else {
      ca_size_t addr = elem_parse_idx_scalar(ca, ridx);
      ca_store_addr(ca->mask, addr, &one);
    }
  }

  return self;
}

/* `elem_unmask(idx)` — clears the mask bit at cell `idx`, leaving
 * the stored data unchanged.  No-op if `self` has no mask. */

VALUE
rb_ca_elem_unmask (VALUE self, VALUE ridx)
{
  CArray *ca;
  ca_size_t idx[CA_RANK_MAX];

  rb_ca_modify(self);

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  /* Super-hot path: entity.  If no mask exists, nothing to clear. */
  if ( ca_is_entity(ca) ) {
    if ( ! ca->mask ) return self;
    ca_size_t addr;
    if ( TYPE(ridx) == T_ARRAY ) {
      elem_parse_idx_array(ca, ridx, idx);
      addr = elem_entity_addr(ca, idx);
    }
    else {
      addr = elem_parse_idx_scalar(ca, ridx);
    }
    ((boolean8_t *)ca->mask->ptr)[addr] = 0;
    return self;
  }

  /* General path: view array. */
  {
    boolean8_t zero = 0;
    ca_update_mask(ca);
    if ( ! ca->mask ) return self;
    if ( TYPE(ridx) == T_ARRAY ) {
      elem_parse_idx_array(ca, ridx, idx);
      ca_store_index(ca->mask, idx, &zero);
    }
    else {
      ca_size_t addr = elem_parse_idx_scalar(ca, ridx);
      ca_store_addr(ca->mask, addr, &zero);
    }
  }

  return self;
}

/* `elem_min(idx, v)` — updates the cell at `idx` to `min(self[idx],
 * v)` in place.  Masked cells are skipped.  NaN follows the `fmin`
 * rule (NaN is treated as missing: `min(NaN, v)` returns `v`,
 * `min(x, NaN)` returns `x`).  Raises for non-numeric data_type. */

#define ELEM_MINMAX_BODY(OP) do { \
  if ( ca_is_entity(ca) ) { \
    ca_size_t addr; \
    if ( TYPE(ridx) == T_ARRAY ) { \
      elem_parse_idx_array(ca, ridx, idx); \
      addr = elem_entity_addr(ca, idx); \
    } \
    else { \
      addr = elem_parse_idx_scalar(ca, ridx); \
    } \
    if ( ca->mask && ((boolean8_t *)ca->mask->ptr)[addr] ) return self; \
    void *p = ca->ptr + ca->bytes * addr; \
    if ( RB_FLOAT_TYPE_P(rval) ) { \
      double v = RFLOAT_VALUE(rval); \
      switch ( ca->data_type ) { \
      case CA_FLOAT64: { double *q=(double *)p;  if (v OP *q || *q != *q) *q = v; return self; } \
      case CA_FLOAT32: { float  *q=(float  *)p;  float vf=(float)v; if (vf OP *q || *q != *q) *q = vf; return self; } \
      case CA_INT64:   { int64_t *q=(int64_t *)p; if ((int64_t)v OP *q) *q = (int64_t)v; return self; } \
      case CA_INT32:   { int32_t *q=(int32_t *)p; if ((int32_t)v OP *q) *q = (int32_t)v; return self; } \
      case CA_INT16:   { int16_t *q=(int16_t *)p; if ((int16_t)v OP *q) *q = (int16_t)v; return self; } \
      case CA_INT8:    { int8_t  *q=(int8_t  *)p; if ((int8_t )v OP *q) *q = (int8_t )v; return self; } \
      case CA_UINT64:  { uint64_t *q=(uint64_t*)p; if ((uint64_t)v OP *q) *q = (uint64_t)v; return self; } \
      case CA_UINT32:  { uint32_t *q=(uint32_t*)p; if ((uint32_t)v OP *q) *q = (uint32_t)v; return self; } \
      case CA_UINT16:  { uint16_t *q=(uint16_t*)p; if ((uint16_t)v OP *q) *q = (uint16_t)v; return self; } \
      case CA_UINT8:   { uint8_t  *q=(uint8_t *)p; if ((uint8_t )v OP *q) *q = (uint8_t )v; return self; } \
      } \
    } \
    else if ( FIXNUM_P(rval) ) { \
      long v = FIX2LONG(rval); \
      switch ( ca->data_type ) { \
      case CA_FLOAT64: { double *q=(double *)p; double vd=(double)v; if (vd OP *q || *q != *q) *q = vd; return self; } \
      case CA_FLOAT32: { float  *q=(float  *)p; float  vf=(float )v; if (vf OP *q || *q != *q) *q = vf; return self; } \
      case CA_INT64:   { int64_t *q=(int64_t *)p; if ((int64_t)v OP *q) *q = (int64_t)v; return self; } \
      case CA_INT32:   { int32_t *q=(int32_t *)p; if ((int32_t)v OP *q) *q = (int32_t)v; return self; } \
      case CA_INT16:   { int16_t *q=(int16_t *)p; if ((int16_t)v OP *q) *q = (int16_t)v; return self; } \
      case CA_INT8:    { int8_t  *q=(int8_t  *)p; if ((int8_t )v OP *q) *q = (int8_t )v; return self; } \
      case CA_UINT64:  { uint64_t *q=(uint64_t*)p; if ((uint64_t)v OP *q) *q = (uint64_t)v; return self; } \
      case CA_UINT32:  { uint32_t *q=(uint32_t*)p; if ((uint32_t)v OP *q) *q = (uint32_t)v; return self; } \
      case CA_UINT16:  { uint16_t *q=(uint16_t*)p; if ((uint16_t)v OP *q) *q = (uint16_t)v; return self; } \
      case CA_UINT8:   { uint8_t  *q=(uint8_t *)p; if ((uint8_t )v OP *q) *q = (uint8_t )v; return self; } \
      } \
    } \
  } \
} while (0)

VALUE
rb_ca_elem_min (VALUE self, VALUE ridx, VALUE rval)
{
  CArray *ca;
  ca_size_t idx[CA_RANK_MAX];

  rb_ca_modify(self);

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  if ( ! ca_is_numeric_type(ca) ) {
    rb_raise(rb_eCADataTypeError,
             "elem_min requires a numeric array");
  }

  /* Super-hot path: entity + numeric dtype + Fixnum/Float rval. */
  ELEM_MINMAX_BODY(<);

  /* General path: view / Bignum-Rational-Complex rval / fall-through.
     fetch, compare via Ruby, store back. */
  {
    VALUE cur;
    boolean8_t m = 0;
    ca_size_t addr;
    int from_array = (TYPE(ridx) == T_ARRAY);

    if ( from_array ) {
      elem_parse_idx_array(ca, ridx, idx);
    }
    else {
      addr = elem_parse_idx_scalar(ca, ridx);
    }

    /* Probe mask (view may need ca_update_mask). */
    if ( ! ca->mask && ! ca_is_entity(ca) ) ca_update_mask(ca);
    if ( ca->mask ) {
      if ( from_array ) ca_fetch_index(ca->mask, idx, &m);
      else              ca_fetch_addr(ca->mask, addr, &m);
      if ( m ) return self;
    }

    cur = from_array ? rb_ca_fetch_index(self, idx) : rb_ca_fetch_addr(self, addr);
    if ( cur == CA_UNDEF ) return self;
    if ( RTEST(rb_funcall(rval, rb_intern("<"), 1, cur)) ) {
      if ( from_array ) rb_ca_store_index(self, idx, rval);
      else              rb_ca_store_addr(self, addr, rval);
    }
  }

  return self;
}

/* `elem_max(idx, v)` — updates the cell at `idx` to `max(self[idx],
 * v)` in place.  Masked cells are skipped.  NaN follows the `fmax`
 * rule.  Raises for non-numeric data_type. */

VALUE
rb_ca_elem_max (VALUE self, VALUE ridx, VALUE rval)
{
  CArray *ca;
  ca_size_t idx[CA_RANK_MAX];

  rb_ca_modify(self);

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  if ( ! ca_is_numeric_type(ca) ) {
    rb_raise(rb_eCADataTypeError,
             "elem_max requires a numeric array");
  }

  ELEM_MINMAX_BODY(>);

  /* General path: view / Bignum-Rational-Complex rval. */
  {
    VALUE cur;
    boolean8_t m = 0;
    ca_size_t addr;
    int from_array = (TYPE(ridx) == T_ARRAY);

    if ( from_array ) {
      elem_parse_idx_array(ca, ridx, idx);
    }
    else {
      addr = elem_parse_idx_scalar(ca, ridx);
    }

    if ( ! ca->mask && ! ca_is_entity(ca) ) ca_update_mask(ca);
    if ( ca->mask ) {
      if ( from_array ) ca_fetch_index(ca->mask, idx, &m);
      else              ca_fetch_addr(ca->mask, addr, &m);
      if ( m ) return self;
    }

    cur = from_array ? rb_ca_fetch_index(self, idx) : rb_ca_fetch_addr(self, addr);
    if ( cur == CA_UNDEF ) return self;
    if ( RTEST(rb_funcall(rval, rb_intern(">"), 1, cur)) ) {
      if ( from_array ) rb_ca_store_index(self, idx, rval);
      else              rb_ca_store_addr(self, addr, rval);
    }
  }

  return self;
}

#undef ELEM_MINMAX_BODY

/* ----------------------------------------------------------------- */

void
Init_carray_element (void)
{
  rb_define_method(rb_cCArray,  "elem_swap",  rb_ca_elem_swap,  2);
  rb_define_method(rb_cCArray,  "elem_copy",  rb_ca_elem_copy,  2);
  rb_define_method(rb_cCArray,  "elem_store", rb_ca_elem_store, 2);
  rb_define_method(rb_cCArray,  "elem_fetch", rb_ca_elem_fetch, 1);

  rb_define_method(rb_cCArray,  "elem_incr",  rb_ca_elem_incr,  1);
  rb_define_method(rb_cCArray,  "elem_decr",  rb_ca_elem_decr,  1);

  rb_define_method(rb_cCArray,  "elem_masked?", rb_ca_elem_test_masked, 1);
  rb_define_method(rb_cCArray,  "elem_mask",    rb_ca_elem_mask,        1);
  rb_define_method(rb_cCArray,  "elem_unmask",  rb_ca_elem_unmask,      1);

  rb_define_method(rb_cCArray,  "elem_min",     rb_ca_elem_min,         2);
  rb_define_method(rb_cCArray,  "elem_max",     rb_ca_elem_max,         2);
}

