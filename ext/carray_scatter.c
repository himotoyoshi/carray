/* ---------------------------------------------------------------------------

  scatter_*! family (per-position mutation primitives): scatter_add /
  sub / mul / min / max in-place, docs in yard-stubs/carray_scatter.rb.

  Shared contract (load-bearing across all five methods):
    addrs      CArray or Ruby Array; coerced to ca_size_t, OOB raises IndexError
    vals       CArray of length(addrs) OR Numeric scalar (broadcast)
    duplicates unbuffered (sequential) — collisions accumulate
    mask       pair skipped when any of addrs[i] / vals[i] / self[addrs[i]] is masked
    cast       vals silently cast to self.data_type
    dtype      arithmetic (add / sub / mul / min / max): numeric only
               (boolean / object / fixlen → CADataTypeError; the bang
               cannot widen self, same rationale as fma! / fms!)
               replace: numeric or boolean (assignment, no widening)

--------------------------------------------------------------------------- */

#include "carray.h"

/* ---------- common kernel macros ----------

   Scalar broadcast path: `vs` already cast to T at entry.
   Vector path: `r[i]` already in self.data_type (silent cast via wrap).

   APPLY(qp, v) := one of:
     OP_ADD  *(qp) += (v)
     OP_SUB  *(qp) -= (v)
     OP_MIN_FLT  if ((v) < *(qp) || *(qp) != *(qp)) *(qp) = (v)   (fmin policy)
     OP_MAX_FLT  if ((v) > *(qp) || *(qp) != *(qp)) *(qp) = (v)
     OP_MIN_INT  if ((v) < *(qp)) *(qp) = (v)
     OP_MAX_INT  if ((v) > *(qp)) *(qp) = (v)
*/

#define OP_ADD(qp, v)     (*(qp) += (v))
#define OP_SUB(qp, v)     (*(qp) -= (v))
#define OP_MUL(qp, v)     (*(qp) *= (v))
#define OP_REPLACE(qp, v) (*(qp)  = (v))
#define OP_MIN_FLT(qp, v) do { if ((v) < *(qp) || *(qp) != *(qp)) *(qp) = (v); } while (0)
#define OP_MAX_FLT(qp, v) do { if ((v) > *(qp) || *(qp) != *(qp)) *(qp) = (v); } while (0)
#define OP_MIN_INT(qp, v) do { if ((v) < *(qp)) *(qp) = (v); } while (0)
#define OP_MAX_INT(qp, v) do { if ((v) > *(qp)) *(qp) = (v); } while (0)

#define LOOP_SCALAR(T, APPLY) do { \
  T *q = (T *) ca->ptr; \
  T  vs = (T) (v_is_float ? (double)vd : (double)vl); \
  if ( mself ) { \
    for (i = 0; i < n; i++) { \
      if ( maddrs && maddrs[i] ) continue; \
      addr = p[i]; \
      CA_CHECK_INDEX(addr, elements); \
      if ( mself[addr] ) continue; \
      APPLY(q + addr, vs); \
    } \
  } \
  else { \
    for (i = 0; i < n; i++) { \
      if ( maddrs && maddrs[i] ) continue; \
      addr = p[i]; \
      CA_CHECK_INDEX(addr, elements); \
      APPLY(q + addr, vs); \
    } \
  } \
} while (0)

#define LOOP_VEC(T, APPLY) do { \
  T *q = (T *) ca->ptr; \
  T *r = (T *) cv->ptr; \
  if ( mself ) { \
    for (i = 0; i < n; i++) { \
      if ( maddrs && maddrs[i] ) continue; \
      if ( mvals  && mvals[i]  ) continue; \
      addr = p[i]; \
      CA_CHECK_INDEX(addr, elements); \
      if ( mself[addr] ) continue; \
      APPLY(q + addr, r[i]); \
    } \
  } \
  else { \
    for (i = 0; i < n; i++) { \
      if ( maddrs && maddrs[i] ) continue; \
      if ( mvals  && mvals[i]  ) continue; \
      addr = p[i]; \
      CA_CHECK_INDEX(addr, elements); \
      APPLY(q + addr, r[i]); \
    } \
  } \
} while (0)

/* REPLACE variant: last-write semantics.  Differs from the accumulate
   family on mask handling:
     - target's prior mask is NOT a skip signal; the write overwrites
       both value and mask (indexer contract, `self[addrs] = vals`).
     - masked vals[i] flips target to masked (writes UNDEF); valid
       vals[i] writes value and clears the target's mask bit.
   Scalar vals is always valid (Fixnum / Float), so scalar path just
   writes and clears target mask. */

#define LOOP_SCALAR_REPLACE(T) do { \
  T *q = (T *) ca->ptr; \
  T  vs = (T) (v_is_float ? (double)vd : (double)vl); \
  for (i = 0; i < n; i++) { \
    if ( maddrs && maddrs[i] ) continue; \
    addr = p[i]; \
    CA_CHECK_INDEX(addr, elements); \
    q[addr] = vs; \
    if ( mself ) mself[addr] = 0; \
  } \
} while (0)

#define LOOP_VEC_REPLACE(T) do { \
  T *q = (T *) ca->ptr; \
  T *r = (T *) cv->ptr; \
  for (i = 0; i < n; i++) { \
    if ( maddrs && maddrs[i] ) continue; \
    addr = p[i]; \
    CA_CHECK_INDEX(addr, elements); \
    if ( mvals && mvals[i] ) { \
      if ( mself ) mself[addr] = 1; \
    } else { \
      q[addr] = r[i]; \
      if ( mself ) mself[addr] = 0; \
    } \
  } \
} while (0)

#define DISPATCH_NUMERIC_REPLACE() do { \
  switch ( ca->data_type ) { \
  case CA_BOOLEAN: if (vals_scalar) LOOP_SCALAR_REPLACE(uint8_t);  else LOOP_VEC_REPLACE(uint8_t);  break; \
  case CA_FLOAT64: if (vals_scalar) LOOP_SCALAR_REPLACE(double);   else LOOP_VEC_REPLACE(double);   break; \
  case CA_FLOAT32: if (vals_scalar) LOOP_SCALAR_REPLACE(float);    else LOOP_VEC_REPLACE(float);    break; \
  case CA_INT64:   if (vals_scalar) LOOP_SCALAR_REPLACE(int64_t);  else LOOP_VEC_REPLACE(int64_t);  break; \
  case CA_INT32:   if (vals_scalar) LOOP_SCALAR_REPLACE(int32_t);  else LOOP_VEC_REPLACE(int32_t);  break; \
  case CA_INT16:   if (vals_scalar) LOOP_SCALAR_REPLACE(int16_t);  else LOOP_VEC_REPLACE(int16_t);  break; \
  case CA_INT8:    if (vals_scalar) LOOP_SCALAR_REPLACE(int8_t);   else LOOP_VEC_REPLACE(int8_t);   break; \
  case CA_UINT64:  if (vals_scalar) LOOP_SCALAR_REPLACE(uint64_t); else LOOP_VEC_REPLACE(uint64_t); break; \
  case CA_UINT32:  if (vals_scalar) LOOP_SCALAR_REPLACE(uint32_t); else LOOP_VEC_REPLACE(uint32_t); break; \
  case CA_UINT16:  if (vals_scalar) LOOP_SCALAR_REPLACE(uint16_t); else LOOP_VEC_REPLACE(uint16_t); break; \
  case CA_UINT8:   if (vals_scalar) LOOP_SCALAR_REPLACE(uint8_t);  else LOOP_VEC_REPLACE(uint8_t);  break; \
  default: \
    rb_bug("carray_scatter: unsupported data_type %d after numeric check", ca->data_type); \
  } \
} while (0)

#define DISPATCH_NUMERIC(APPLY_INT, APPLY_FLT) do { \
  switch ( ca->data_type ) { \
  case CA_FLOAT64: if (vals_scalar) LOOP_SCALAR(double,   APPLY_FLT); else LOOP_VEC(double,   APPLY_FLT); break; \
  case CA_FLOAT32: if (vals_scalar) LOOP_SCALAR(float,    APPLY_FLT); else LOOP_VEC(float,    APPLY_FLT); break; \
  case CA_INT64:   if (vals_scalar) LOOP_SCALAR(int64_t,  APPLY_INT); else LOOP_VEC(int64_t,  APPLY_INT); break; \
  case CA_INT32:   if (vals_scalar) LOOP_SCALAR(int32_t,  APPLY_INT); else LOOP_VEC(int32_t,  APPLY_INT); break; \
  case CA_INT16:   if (vals_scalar) LOOP_SCALAR(int16_t,  APPLY_INT); else LOOP_VEC(int16_t,  APPLY_INT); break; \
  case CA_INT8:    if (vals_scalar) LOOP_SCALAR(int8_t,   APPLY_INT); else LOOP_VEC(int8_t,   APPLY_INT); break; \
  case CA_UINT64:  if (vals_scalar) LOOP_SCALAR(uint64_t, APPLY_INT); else LOOP_VEC(uint64_t, APPLY_INT); break; \
  case CA_UINT32:  if (vals_scalar) LOOP_SCALAR(uint32_t, APPLY_INT); else LOOP_VEC(uint32_t, APPLY_INT); break; \
  case CA_UINT16:  if (vals_scalar) LOOP_SCALAR(uint16_t, APPLY_INT); else LOOP_VEC(uint16_t, APPLY_INT); break; \
  case CA_UINT8:   if (vals_scalar) LOOP_SCALAR(uint8_t,  APPLY_INT); else LOOP_VEC(uint8_t,  APPLY_INT); break; \
  default: \
    /* numeric check passed before dispatch; complex types fall through to bug */ \
    rb_bug("carray_scatter: unsupported data_type %d after numeric check", ca->data_type); \
  } \
} while (0)

/* Setup boilerplate: parse args, wrap addrs/vals, attach.

   Outputs into caller's locals:
     ca, ci, cv (CArray*), n, elements (ca_size_t),
     p, maddrs, mvals, mself (pointers),
     vals_scalar (int), v_is_float (int), vd (double), vl (long).

   Caller must `ca_sync(ca); ca_detach_n(...);` after kernel.
*/
/* Body shared by arithmetic and replace setups.  Caller precondition:
   the data_type gate has already run (arithmetic = numeric only, replace
   = numeric or boolean).  For the replace variant, `true` / `false`
   scalars are accepted as vals (bridged as vl = 1 / 0). */
#define AT_SETUP_BODY(name, allow_bool_scalar) \
  raddrs = rb_ca_wrap_readonly(raddrs, INT2NUM(CA_SIZE)); \
  TypedData_Get_Struct(raddrs, CArray, &carray_data_type, ci); \
  n = ci->elements; \
  if ( n == 0 ) return self; \
  vals_scalar = (RB_FLOAT_TYPE_P(rvals) || FIXNUM_P(rvals) \
                 || ((allow_bool_scalar) && (rvals == Qtrue || rvals == Qfalse))); \
  if ( vals_scalar ) { \
    if ( RB_FLOAT_TYPE_P(rvals) ) { vd = RFLOAT_VALUE(rvals); v_is_float = 1; } \
    else if ( FIXNUM_P(rvals) )   { vl = FIX2LONG(rvals);     v_is_float = 0; } \
    else                          { vl = (rvals == Qtrue) ? 1 : 0; v_is_float = 0; } \
  } \
  else { \
    rvals = rb_ca_wrap_readonly(rvals, INT2NUM(ca->data_type)); \
    TypedData_Get_Struct(rvals, CArray, &carray_data_type, cv); \
    if ( cv->elements != n ) { \
      rb_raise(rb_eArgError, \
        name ": vals length (%lld) doesn't match addrs length (%lld)", \
        (long long)cv->elements, (long long)n); \
    } \
  } \
  if ( vals_scalar ) ca_attach_n(2, ca, ci); \
  else               ca_attach_n(3, ca, ci, cv); \
  p        = (ca_size_t *) ci->ptr; \
  maddrs   = ci->mask ? (boolean8_t *) ci->mask->ptr : NULL; \
  mvals    = (cv && cv->mask) ? (boolean8_t *) cv->mask->ptr : NULL; \
  mself    = ca->mask ? (boolean8_t *) ca->mask->ptr : NULL; \
  elements = ca->elements;

#define AT_SETUP_OR_RETURN(name) \
  CArray  *ca, *ci, *cv = NULL; \
  ca_size_t i, n, addr, elements; \
  ca_size_t *p; \
  boolean8_t *maddrs, *mvals = NULL, *mself; \
  int vals_scalar, v_is_float = 0; \
  double vd = 0.0; long vl = 0; \
  rb_ca_modify(self); \
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca); \
  if ( ! ca_is_numeric_type(ca) ) { \
    rb_raise(rb_eCADataTypeError, name " requires a numeric array"); \
  } \
  AT_SETUP_BODY(name, 0)

/* replace variant: accepts boolean self (assignment, no widening) and
   Ruby true / false as scalar vals. */
#define AT_SETUP_OR_RETURN_REPLACE(name) \
  CArray  *ca, *ci, *cv = NULL; \
  ca_size_t i, n, addr, elements; \
  ca_size_t *p; \
  boolean8_t *maddrs, *mvals = NULL, *mself; \
  int vals_scalar, v_is_float = 0; \
  double vd = 0.0; long vl = 0; \
  rb_ca_modify(self); \
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca); \
  if ( ! ca_is_numeric_type(ca) && ca->data_type != CA_BOOLEAN ) { \
    rb_raise(rb_eCADataTypeError, \
      name " requires a numeric or boolean array"); \
  } \
  AT_SETUP_BODY(name, 1)

#define AT_TEARDOWN() do { \
  ca_sync(ca); \
  if ( vals_scalar ) ca_detach_n(2, ca, ci); \
  else               ca_detach_n(3, ca, ci, cv); \
} while (0)

/* --------------------------------------------------------------- */

/* CArray#scatter_add!(addrs, vals) — for each i, self[addrs[i]] +=
 * vals[i] (or += vals when scalar).  Duplicate addrs accumulate
 * (unbuffered), unlike self[addrs] += vals which is last-wins. */
static VALUE
rb_ca_scatter_add_bang (VALUE self, VALUE raddrs, VALUE rvals)
{
  AT_SETUP_OR_RETURN("scatter_add!");
  DISPATCH_NUMERIC(OP_ADD, OP_ADD);
  AT_TEARDOWN();
  return self;
}

/* --------------------------------------------------------------- */

/* CArray#scatter_sub!(addrs, vals) — for each i, self[addrs[i]] -=
 * vals[i].  Same mask/cast/bounds policy as scatter_add!. */
static VALUE
rb_ca_scatter_sub_bang (VALUE self, VALUE raddrs, VALUE rvals)
{
  AT_SETUP_OR_RETURN("scatter_sub!");
  DISPATCH_NUMERIC(OP_SUB, OP_SUB);
  AT_TEARDOWN();
  return self;
}

/* --------------------------------------------------------------- */

/* CArray#scatter_mul!(addrs, vals) — for each i, self[addrs[i]] *=
 * vals[i].  NaN/inf follow standard C arithmetic (no fmin-style
 * missing-value rule); integer overflow wraps.  Otherwise identical
 * to scatter_add! (mask / cast / bounds). */
static VALUE
rb_ca_scatter_mul_bang (VALUE self, VALUE raddrs, VALUE rvals)
{
  AT_SETUP_OR_RETURN("scatter_mul!");
  DISPATCH_NUMERIC(OP_MUL, OP_MUL);
  AT_TEARDOWN();
  return self;
}

/* --------------------------------------------------------------- */

/* CArray#scatter_min!(addrs, vals) — for each i, self[addrs[i]] =
 * min(self[addrs[i]], vals[i]).  Float types follow the fmin rule
 * (NaN is treated as missing).  Same mask/cast/bounds policy as
 * scatter_add!. */
static VALUE
rb_ca_scatter_min_bang (VALUE self, VALUE raddrs, VALUE rvals)
{
  AT_SETUP_OR_RETURN("scatter_min!");
  DISPATCH_NUMERIC(OP_MIN_INT, OP_MIN_FLT);
  AT_TEARDOWN();
  return self;
}

/* --------------------------------------------------------------- */

/* CArray#scatter_max!(addrs, vals) — for each i, self[addrs[i]] =
 * max(self[addrs[i]], vals[i]).  Float types follow the fmax rule.
 * Otherwise identical to scatter_add!. */
static VALUE
rb_ca_scatter_max_bang (VALUE self, VALUE raddrs, VALUE rvals)
{
  AT_SETUP_OR_RETURN("scatter_max!");
  DISPATCH_NUMERIC(OP_MAX_INT, OP_MAX_FLT);
  AT_TEARDOWN();
  return self;
}

/* --------------------------------------------------------------- */

/* CArray#scatter_replace!(addrs, vals) — for each i, self[addrs[i]] =
 * vals[i] (or = vals when scalar).  Semantically equivalent to
 * self[addrs] = vals (last-write-wins on duplicate addrs) but bypasses
 * the CAGrid view chain (snapshot copy of addrs + view alloc + store_all
 * dispatch).  Mask policy follows the indexer contract: target's prior
 * mask is overwritten (masked vals[i] flips target to masked, valid
 * vals[i] clears target's mask). */
static VALUE
rb_ca_scatter_replace_bang (VALUE self, VALUE raddrs, VALUE rvals)
{
  /* Pre-scan: if vals is a masked CArray and self isn't yet masked,
     promote self so the kernel can flip target cells to masked (indexer
     `self[addrs] = vals` establishes self.mask lazily the same way). */
  if ( ! (RB_FLOAT_TYPE_P(rvals) || FIXNUM_P(rvals))
       && rb_obj_is_carray(rvals) ) {
    CArray *cv_pre;
    TypedData_Get_Struct(rvals, CArray, &carray_data_type, cv_pre);
    if ( ca_has_mask(cv_pre) ) {
      CArray *ca_pre;
      TypedData_Get_Struct(self, CArray, &carray_data_type, ca_pre);
      if ( ! ca_has_mask(ca_pre) ) {
        ca_create_mask(ca_pre);
      }
    }
  }
  AT_SETUP_OR_RETURN_REPLACE("scatter_replace!");
  DISPATCH_NUMERIC_REPLACE();
  AT_TEARDOWN();
  return self;
}

/* --------------------------------------------------------------- */

void
Init_carray_scatter (void)
{
  rb_define_method(rb_cCArray, "scatter_add!", rb_ca_scatter_add_bang, 2);
  rb_define_method(rb_cCArray, "scatter_sub!", rb_ca_scatter_sub_bang, 2);
  rb_define_method(rb_cCArray, "scatter_mul!", rb_ca_scatter_mul_bang, 2);
  rb_define_method(rb_cCArray, "scatter_min!", rb_ca_scatter_min_bang, 2);
  rb_define_method(rb_cCArray, "scatter_max!", rb_ca_scatter_max_bang, 2);
  rb_define_method(rb_cCArray, "scatter_replace!", rb_ca_scatter_replace_bang, 2);
}
