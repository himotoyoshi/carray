/* ---------------------------------------------------------------------------

  scatter_*! family (per-position mutation primitives): scatter_add /
  sub / mul / min / max in-place, docs in yard-stubs/carray_scatter.rb.

  Shared contract (load-bearing across all five methods):
    addrs      CArray or Ruby Array; coerced to ca_size_t, OOB raises IndexError
    vals       CArray of length(addrs) OR Numeric scalar (broadcast)
    duplicates unbuffered (sequential) — collisions accumulate
    mask       pair skipped when any of addrs[i] / vals[i] / self[addrs[i]] is masked
    cast       vals silently cast to self.data_type
    data type  add / sub / mul: numeric, complex included
               min / max: real numeric only (complex has no order)
               (boolean / object / fixlen → CADataTypeError; the bang
               cannot widen self, same rationale as fma! / fms!)
               replace: numeric or boolean (assignment, no widening)
    scalar     Integer / Float, and Complex when self is complex

--------------------------------------------------------------------------- */

#include "carray.h"
#include "carray_internal.h"   /* ca_attach_window */

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

/* The scalar operand as T.  An Integer goes to T directly, not through
   double, so an int64 above 2**53 is exact.  A complex self also takes a
   Ruby Complex scalar, whose parts sit in vd / vi; an Integer or Float
   scalar leaves vi at 0. */
#define SCALAR_REAL(T)  (v_is_float ? (T) vd : (T) vl)
#define SCALAR_CMPLX(T) ((T) ((v_is_float ? (double)vd : (double)vl) + vi * I))

#define LOOP_SCALAR(T, APPLY) LOOP_SCALAR_V(T, APPLY, SCALAR_REAL(T))

#define LOOP_SCALAR_V(T, APPLY, VS) do { \
  T *q = (T *) qbase; \
  T  vs = VS; \
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
  T *q = (T *) qbase; \
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

#define LOOP_SCALAR_REPLACE(T) LOOP_SCALAR_REPLACE_V(T, SCALAR_REAL(T))

#define LOOP_SCALAR_REPLACE_V(T, VS) do { \
  T *q = (T *) qbase; \
  T  vs = VS; \
  for (i = 0; i < n; i++) { \
    if ( maddrs && maddrs[i] ) continue; \
    addr = p[i]; \
    CA_CHECK_INDEX(addr, elements); \
    q[addr] = vs; \
    if ( mself ) mself[addr] = 0; \
  } \
} while (0)

#define LOOP_VEC_REPLACE(T) do { \
  T *q = (T *) qbase; \
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
  CASES_CMPLX_REPLACE \
  default: \
    rb_bug("carray_scatter: unsupported data_type %d after numeric check", ca->data_type); \
  } \
} while (0)

#define CASES_REAL(APPLY_INT, APPLY_FLT) \
  case CA_FLOAT64: if (vals_scalar) LOOP_SCALAR(double,   APPLY_FLT); else LOOP_VEC(double,   APPLY_FLT); break; \
  case CA_FLOAT32: if (vals_scalar) LOOP_SCALAR(float,    APPLY_FLT); else LOOP_VEC(float,    APPLY_FLT); break; \
  case CA_INT64:   if (vals_scalar) LOOP_SCALAR(int64_t,  APPLY_INT); else LOOP_VEC(int64_t,  APPLY_INT); break; \
  case CA_INT32:   if (vals_scalar) LOOP_SCALAR(int32_t,  APPLY_INT); else LOOP_VEC(int32_t,  APPLY_INT); break; \
  case CA_INT16:   if (vals_scalar) LOOP_SCALAR(int16_t,  APPLY_INT); else LOOP_VEC(int16_t,  APPLY_INT); break; \
  case CA_INT8:    if (vals_scalar) LOOP_SCALAR(int8_t,   APPLY_INT); else LOOP_VEC(int8_t,   APPLY_INT); break; \
  case CA_UINT64:  if (vals_scalar) LOOP_SCALAR(uint64_t, APPLY_INT); else LOOP_VEC(uint64_t, APPLY_INT); break; \
  case CA_UINT32:  if (vals_scalar) LOOP_SCALAR(uint32_t, APPLY_INT); else LOOP_VEC(uint32_t, APPLY_INT); break; \
  case CA_UINT16:  if (vals_scalar) LOOP_SCALAR(uint16_t, APPLY_INT); else LOOP_VEC(uint16_t, APPLY_INT); break; \
  case CA_UINT8:   if (vals_scalar) LOOP_SCALAR(uint8_t,  APPLY_INT); else LOOP_VEC(uint8_t,  APPLY_INT); break;

#ifdef HAVE_COMPLEX_H
#define CASES_CMPLX(APPLY) \
  case CA_CMPLX64:  if (vals_scalar) LOOP_SCALAR_V(cmplx64_t,  APPLY, SCALAR_CMPLX(cmplx64_t)); \
                    else LOOP_VEC(cmplx64_t,  APPLY); break; \
  case CA_CMPLX128: if (vals_scalar) LOOP_SCALAR_V(cmplx128_t, APPLY, SCALAR_CMPLX(cmplx128_t)); \
                    else LOOP_VEC(cmplx128_t, APPLY); break;
#define CASES_CMPLX_REPLACE \
  case CA_CMPLX64:  if (vals_scalar) LOOP_SCALAR_REPLACE_V(cmplx64_t,  SCALAR_CMPLX(cmplx64_t)); \
                    else LOOP_VEC_REPLACE(cmplx64_t);  break; \
  case CA_CMPLX128: if (vals_scalar) LOOP_SCALAR_REPLACE_V(cmplx128_t, SCALAR_CMPLX(cmplx128_t)); \
                    else LOOP_VEC_REPLACE(cmplx128_t); break;
#else
#define CASES_CMPLX(APPLY)
#define CASES_CMPLX_REPLACE
#endif

/* add / sub / mul: every numeric type, complex included. */
#define DISPATCH_ARITH(APPLY) do { \
  switch ( ca->data_type ) { \
  CASES_REAL(APPLY, APPLY) \
  CASES_CMPLX(APPLY) \
  default: \
    rb_bug("carray_scatter: unsupported data_type %d after numeric check", ca->data_type); \
  } \
} while (0)

/* min / max: real types only; the setup has already refused complex. */
#define DISPATCH_ORDERED(APPLY_INT, APPLY_FLT) do { \
  switch ( ca->data_type ) { \
  CASES_REAL(APPLY_INT, APPLY_FLT) \
  default: \
    rb_bug("carray_scatter: unsupported data_type %d after numeric check", ca->data_type); \
  } \
} while (0)

/* Setup boilerplate: parse args and wrap addrs/vals.

   Outputs into caller's locals:
     ca, ci, cv (CArray*), n (ca_size_t),
     vals_scalar (int), v_is_float (int), vd, vi (double), vl (long).

   The kernel then runs through AT_RUN, and an address out of range
   raising part way still leaves the cells already written.
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
                 || ((allow_bool_scalar) && (rvals == Qtrue || rvals == Qfalse)) \
                 || (ca_is_complex_type(ca) && RB_TYPE_P(rvals, T_COMPLEX))); \
  if ( vals_scalar ) { \
    if ( RB_TYPE_P(rvals, T_COMPLEX) ) { \
      vd = NUM2DBL(rb_complex_real(rvals)); \
      vi = NUM2DBL(rb_complex_imag(rvals)); \
      v_is_float = 1; \
    } \
    else if ( RB_FLOAT_TYPE_P(rvals) ) { vd = RFLOAT_VALUE(rvals); v_is_float = 1; } \
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
  }

#define AT_SETUP_LOCALS \
  CArray  *ca, *ci, *cv = NULL; \
  ca_size_t n; \
  int vals_scalar, v_is_float = 0; \
  double vd = 0.0, vi = 0.0; long vl = 0;

#define AT_SETUP_OR_RETURN(name, ordered) \
  AT_SETUP_LOCALS \
  rb_ca_modify(self); \
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca); \
  if ( ! ca_is_numeric_type(ca) ) { \
    rb_raise(rb_eCADataTypeError, name " requires a numeric array"); \
  } \
  if ( (ordered) && ca_is_complex_type(ca) ) { \
    rb_raise(rb_eCADataTypeError, \
      name " requires a real array (complex values have no order)"); \
  } \
  AT_SETUP_BODY(name, 0)

/* replace variant: accepts boolean self (assignment, no widening) and
   Ruby true / false as scalar vals. */
#define AT_SETUP_OR_RETURN_REPLACE(name) \
  AT_SETUP_LOCALS \
  rb_ca_modify(self); \
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca); \
  if ( ! ca_is_numeric_type(ca) && ca->data_type != CA_BOOLEAN ) { \
    rb_raise(rb_eCADataTypeError, \
      name " requires a numeric or boolean array"); \
  } \
  AT_SETUP_BODY(name, 1)

/* The kernel works either on self's own memory or on a compact region:
   the distinct cells the addresses touch, read out of self and written
   back to the same cells.  In the region form `region` is set, the
   addresses are replaced by slots into it, and skip marks the pairs the
   kernel must pass over (a masked address, or any pair at or after the
   first address out of range). */
typedef struct {
  char       *data;
  boolean8_t *mask;
  ca_size_t   m;
  ca_size_t  *slots;
  boolean8_t *skip;
  ca_size_t   n;
} ca_scatter_region_t;

typedef struct {
  CArray    *ca, *ci, *cv;
  ca_size_t  n;
  int        vals_scalar, v_is_float;
  double     vd, vi;
  long       vl;
  ca_scatter_region_t *region;
} ca_scatter_ctx_t;

/* Defines fname, the kernel body running DISPATCH with the names the
   loop macros expect. */
#define AT_BODY(fname, DISPATCH) \
static VALUE \
fname (VALUE arg) \
{ \
  ca_scatter_ctx_t *c_ = (ca_scatter_ctx_t *) arg; \
  ca_scatter_region_t *rg_ = c_->region; \
  CArray     *ca = c_->ca, *ci = c_->ci, *cv = c_->cv; \
  ca_size_t   i, addr; \
  ca_size_t   n        = rg_ ? rg_->n : c_->n; \
  ca_size_t   elements = rg_ ? rg_->m : ca->elements; \
  char       *qbase    = rg_ ? rg_->data : ca->ptr; \
  ca_size_t  *p        = rg_ ? rg_->slots : (ca_size_t *) ci->ptr; \
  boolean8_t *maddrs   = rg_ ? rg_->skip \
                             : (ci->mask ? (boolean8_t *) ci->mask->ptr : NULL); \
  boolean8_t *mvals    = (cv && cv->mask) ? (boolean8_t *) cv->mask->ptr : NULL; \
  boolean8_t *mself    = rg_ ? rg_->mask \
                             : (ca->mask ? (boolean8_t *) ca->mask->ptr : NULL); \
  int         vals_scalar = c_->vals_scalar, v_is_float = c_->v_is_float; \
  double      vd = c_->vd, vi = c_->vi; \
  long        vl = c_->vl; \
  (void) cv; (void) mvals; (void) v_is_float; (void) vd; (void) vi; (void) vl; \
  DISPATCH; \
  return Qnil; \
}

static int
ca_scatter_cmp_addr (const void *a, const void *b)
{
  ca_size_t x = *(const ca_size_t *) a, y = *(const ca_size_t *) b;
  return (x > y) - (x < y);
}

typedef struct {
  ca_scatter_ctx_t *ctx;
  VALUE (*kernel)(VALUE);
} ca_scatter_region_arg_t;

/* Window body for a self that does not lend its memory (a selection, a
   converting view, ...).  Attaching such a self would materialise every
   cell and push every cell back, so cells the addresses never name would
   make a round trip through the view -- and come back changed when the
   view converts lossily.  Only the cells named are read and written.

   The pairs before the first address out of range are applied, then the
   range error is raised, as in the direct form. */
static VALUE
ca_scatter_region_body (VALUE varg)
{
  ca_scatter_region_arg_t *a = (ca_scatter_region_arg_t *) varg;
  ca_scatter_ctx_t *c = a->ctx;
  CArray     *ca = c->ca, *ci = c->ci;
  ca_size_t   n = c->n, elements = ca->elements;
  ca_size_t  *p = (ca_size_t *) ci->ptr;
  boolean8_t *maddrs = ci->mask ? (boolean8_t *) ci->mask->ptr : NULL;
  ca_scatter_region_t rg;
  ca_size_t  *addrs, *uniq, i, nv, m, bad = 0;
  boolean8_t *skip;
  int         self_masked = ca_has_mask(ca);
  volatile VALUE h1 = 0, h2 = 0, h3 = 0, h4 = 0, h5 = 0;

  addrs = ALLOCV_N(ca_size_t,  h1, n);
  skip  = ALLOCV_N(boolean8_t, h2, n);
  uniq  = ALLOCV_N(ca_size_t,  h3, n);

  /* Normalise the addresses up to the first one out of range. */
  m = 0;
  for (nv = 0; nv < n; nv++) {
    ca_size_t addr = p[nv];
    if ( maddrs && maddrs[nv] ) {
      skip[nv] = 1;
      continue;
    }
    if ( addr < 0 ) {
      addr += elements;
    }
    if ( addr < 0 || addr >= elements ) {
      bad = p[nv];
      break;
    }
    skip[nv]  = 0;
    addrs[nv] = addr;
    uniq[m++] = addr;
  }

  qsort(uniq, (size_t) m, sizeof(ca_size_t), ca_scatter_cmp_addr);
  if ( m > 0 ) {
    ca_size_t k = 1;
    for (i = 1; i < m; i++) {
      if ( uniq[i] != uniq[k-1] ) {
        uniq[k++] = uniq[i];
      }
    }
    m = k;
  }

  /* Each address becomes its slot in uniq. */
  for (i = 0; i < nv; i++) {
    if ( ! skip[i] ) {
      ca_size_t *hit = bsearch(&addrs[i], uniq, (size_t) m, sizeof(ca_size_t),
                               ca_scatter_cmp_addr);
      addrs[i] = hit - uniq;
    }
  }

  rg.m     = m;
  rg.slots = addrs;
  rg.skip  = skip;
  rg.n     = nv;
  rg.data  = ALLOCV(h4, (size_t) (m > 0 ? m : 1) * ca->bytes);
  rg.mask  = NULL;

  if ( m > 0 ) {
    ca_xfer_addrs(ca, m, uniq, rg.data, CA_XFER_GET);
    if ( self_masked ) {
      ca_update_mask(ca);
      rg.mask = ALLOCV_N(boolean8_t, h5, m);
      ca_xfer_addrs(ca->mask, m, uniq, rg.mask, CA_XFER_GET);
    }
    c->region = &rg;
    a->kernel((VALUE) c);
    c->region = NULL;
    ca_xfer_addrs(ca, m, uniq, rg.data, CA_XFER_PUT);
    if ( rg.mask ) {
      ca_xfer_addrs(ca->mask, m, uniq, rg.mask, CA_XFER_PUT);
    }
  }

  if ( nv < n ) {
    CA_CHECK_INDEX(bad, elements);   /* raises */
  }

  if ( h5 ) { ALLOCV_END(h5); }
  ALLOCV_END(h4);
  ALLOCV_END(h3);
  ALLOCV_END(h2);
  ALLOCV_END(h1);
  return Qnil;
}

/* Self is written ('w'); the addresses and the values are read ('r').
   A self that lends its memory is written in place; any other self goes
   through the region form above, with only the addresses and the values
   opened. */
#define AT_RUN(body) do { \
  ca_scatter_ctx_t c_; \
  CArray *list_[3]; \
  c_.ca = ca; c_.ci = ci; c_.cv = cv; c_.n = n; \
  c_.vals_scalar = vals_scalar; c_.v_is_float = v_is_float; \
  c_.vd = vd; c_.vi = vi; c_.vl = vl; \
  c_.region = NULL; \
  if ( ca_attach_is_alias(ca) ) { \
    list_[0] = ca; list_[1] = ci; list_[2] = cv; \
    ca_attach_window(vals_scalar ? 2 : 3, list_, "wrr", body, (VALUE) &c_); \
  } \
  else { \
    ca_scatter_region_arg_t ra_; \
    ra_.ctx = &c_; ra_.kernel = body; \
    list_[0] = ci; list_[1] = cv; \
    ca_attach_window(vals_scalar ? 1 : 2, list_, "rr", \
                     ca_scatter_region_body, (VALUE) &ra_); \
  } \
} while (0)

/* --------------------------------------------------------------- */

AT_BODY(ca_scatter_add_body, DISPATCH_ARITH(OP_ADD))

/* CArray#scatter_add!(addrs, vals) — for each i, self[addrs[i]] +=
 * vals[i] (or += vals when scalar).  Duplicate addrs accumulate
 * (unbuffered), unlike self[addrs] += vals which is last-wins. */
static VALUE
rb_ca_scatter_add_bang (VALUE self, VALUE raddrs, VALUE rvals)
{
  AT_SETUP_OR_RETURN("scatter_add!", 0);
  AT_RUN(ca_scatter_add_body);
  return self;
}

/* --------------------------------------------------------------- */

AT_BODY(ca_scatter_sub_body, DISPATCH_ARITH(OP_SUB))

/* CArray#scatter_sub!(addrs, vals) — for each i, self[addrs[i]] -=
 * vals[i].  Same mask/cast/bounds policy as scatter_add!. */
static VALUE
rb_ca_scatter_sub_bang (VALUE self, VALUE raddrs, VALUE rvals)
{
  AT_SETUP_OR_RETURN("scatter_sub!", 0);
  AT_RUN(ca_scatter_sub_body);
  return self;
}

/* --------------------------------------------------------------- */

AT_BODY(ca_scatter_mul_body, DISPATCH_ARITH(OP_MUL))

/* CArray#scatter_mul!(addrs, vals) — for each i, self[addrs[i]] *=
 * vals[i].  NaN/inf follow standard C arithmetic (no fmin-style
 * missing-value rule); integer overflow wraps.  Otherwise identical
 * to scatter_add! (mask / cast / bounds). */
static VALUE
rb_ca_scatter_mul_bang (VALUE self, VALUE raddrs, VALUE rvals)
{
  AT_SETUP_OR_RETURN("scatter_mul!", 0);
  AT_RUN(ca_scatter_mul_body);
  return self;
}

/* --------------------------------------------------------------- */

AT_BODY(ca_scatter_min_body, DISPATCH_ORDERED(OP_MIN_INT, OP_MIN_FLT))

/* CArray#scatter_min!(addrs, vals) — for each i, self[addrs[i]] =
 * min(self[addrs[i]], vals[i]).  Float types follow the fmin rule
 * (NaN is treated as missing).  Same mask/cast/bounds policy as
 * scatter_add!. */
static VALUE
rb_ca_scatter_min_bang (VALUE self, VALUE raddrs, VALUE rvals)
{
  AT_SETUP_OR_RETURN("scatter_min!", 1);
  AT_RUN(ca_scatter_min_body);
  return self;
}

/* --------------------------------------------------------------- */

AT_BODY(ca_scatter_max_body, DISPATCH_ORDERED(OP_MAX_INT, OP_MAX_FLT))

/* CArray#scatter_max!(addrs, vals) — for each i, self[addrs[i]] =
 * max(self[addrs[i]], vals[i]).  Float types follow the fmax rule.
 * Otherwise identical to scatter_add!. */
static VALUE
rb_ca_scatter_max_bang (VALUE self, VALUE raddrs, VALUE rvals)
{
  AT_SETUP_OR_RETURN("scatter_max!", 1);
  AT_RUN(ca_scatter_max_body);
  return self;
}

/* --------------------------------------------------------------- */

AT_BODY(ca_scatter_replace_body, DISPATCH_NUMERIC_REPLACE())

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
  AT_RUN(ca_scatter_replace_body);
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
