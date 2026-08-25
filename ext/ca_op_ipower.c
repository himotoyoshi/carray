/* ---------------------------------------------------------------------------

  Float/Complex ** Integer integer-exponent fast path via
  binary exponentiation (O(log p)).

  Contents:
    (1) LAZY kernel table `ca_binop_ipower[CA_NTYPE]` — CABinOp dispatch
        entry taken when lazy `**` sees an Integer exponent on a
        Float / Complex receiver.  Called from ca_binop_dispatch.c.
    (2) EAGER kernels + Ruby surface `pow` / `pow!` (alias `**`).
        `rb_ca_pow{,_bang}` dispatch between ipower (Float/Complex **
        Integer) and mkkernel-generated `rb_ca_power` (general pow).

  Both paths share `op_powi_<type>` from ca_op_powi.h (= repeated
  squaring, ~1-3 mul/cell for typical p).

---------------------------------------------------------------------------- */

#include "carray.h"
#include "ca_binop_dispatch.h"
#include "ca_op_powi.h"

/* Defined in ext/carray_kernels.c (mkkernel-generated general pow /
   cpow binop).  Called by rb_ca_pow{,_bang} when the fast path does
   not apply (rhs not Integer, or lhs not Float/Complex). */
extern VALUE rb_ca_power (VALUE self, VALUE other);
extern VALUE rb_ca_power_bang (VALUE self, VALUE other);

/* ========================================================================== */
/* (1) LAZY kernel table — CABinOp ipower dispatch                            */
/* ========================================================================== */

/* Kernel template: T = source/output data_type; right operand is
   int64_t.  Signature (n, m, ptr1, i1, ptr2, i2, ptr3, i3) mirrors
   the mkkernel binop kernels so the CABinOp xfer_stride dispatcher
   calls it uniformly.

   Heterogeneous binop:
     ptr1 = left  (float32/float64/cmplx64/cmplx128, vector)
     ptr2 = right (int64,                            scalar via i2=0)
     ptr3 = dst   (same data_type as left,           vector)

   Output data_type preserves the left data_type (= no cast-before
   promotion).  CAREFUL: cast-before / promo are overridden for
   CA_BINOP_IPOWER in ca_binop_dispatch.c; changing this file's
   dispatch table shape without matching that override leaks integer
   promotion into the output.

   Non-Float / non-Complex slots are NULL: lazy `**` routes only
   Float / Complex parents through IPOWER; Integer parents stay on
   the general CA_BINOP_POW path. */

#define DEFINE_LAZY_IPOWER_KERNEL(T)                                    \
static void                                                             \
ca_binop_ipower_##T (ca_size_t n, boolean8_t *m,                        \
                     char *ptr1, ca_size_t i1,                          \
                     char *ptr2, ca_size_t i2,                          \
                     char *ptr3, ca_size_t i3)                          \
{                                                                       \
  T       *q1 = (T *) ptr1, *q3 = (T *) ptr3;                           \
  int64_t *q2 = (int64_t *) ptr2;                                       \
  T       *p1, *p3;                                                     \
  int64_t *p2;                                                          \
  ca_size_t k;                                                          \
  (void) i2;  /* right is scalar broadcast (i2 == 0), q2 stays put */   \
  if ( m ) {                                                            \
    boolean8_t *pm;                                                     \
    for (k = 0; k < n; k++) {                                           \
      pm = m + k;                                                       \
      if ( ! *pm ) {                                                    \
        p1 = q1 + k*i1;                                                 \
        p2 = q2 + k*i2;                                                 \
        p3 = q3 + k*i3;                                                 \
        *p3 = op_powi_##T(*p1, *p2);                                    \
      }                                                                 \
    }                                                                   \
  } else {                                                              \
    for (k = 0; k < n; k++) {                                           \
      p1 = q1 + k*i1;                                                   \
      p2 = q2 + k*i2;                                                   \
      p3 = q3 + k*i3;                                                   \
      *p3 = op_powi_##T(*p1, *p2);                                      \
    }                                                                   \
  }                                                                     \
}

DEFINE_LAZY_IPOWER_KERNEL(float32_t)
DEFINE_LAZY_IPOWER_KERNEL(float64_t)
DEFINE_LAZY_IPOWER_KERNEL(cmplx64_t)
DEFINE_LAZY_IPOWER_KERNEL(cmplx128_t)

#undef DEFINE_LAZY_IPOWER_KERNEL

/* Per-data_type dispatch table — NULL for slots not covered (= integer /
   bool / object / fixlen / VL).  Indexed by CA_FLOAT32 .. CA_CMPLX128. */
ca_binop_func_t ca_binop_ipower[CA_NTYPE] = {
  [CA_FLOAT32]  = ca_binop_ipower_float32_t,
  [CA_FLOAT64]  = ca_binop_ipower_float64_t,
  [CA_CMPLX64]  = ca_binop_ipower_cmplx64_t,
  [CA_CMPLX128] = ca_binop_ipower_cmplx128_t,
};

/* ========================================================================== */
/* (2) EAGER kernels + Ruby surface                                            */
/* ========================================================================== */

/* Per-data_type eager kernel: writes ipower(p1[k], ipow) → p2[k] for each
   unmasked cell, using stride 1 on both input and output (= eager
   driver materialises inputs to contig before calling). */

static void
ca_ipower_float32_t (ca_size_t n, boolean8_t *m,
                     char *ptr1, int32_t ipow, char *ptr2)
{
  float32_t *p1 = (float32_t *) ptr1, *p2 = (float32_t *) ptr2;
  if ( m ) {
    while (n--) {
      if ( ! *m++ ) { *p2 = op_powi_float32_t(*p1, ipow); }
      p1++; p2++;
    }
  }
  else
    while (n--) { (*p2) = op_powi_float32_t(*p1, ipow); p1++; p2++; }
}

static void
ca_ipower_float64_t (ca_size_t n, boolean8_t *m,
                     char *ptr1, int32_t ipow, char *ptr2)
{
  float64_t *p1 = (float64_t *) ptr1, *p2 = (float64_t *) ptr2;
  if ( m ) {
    while (n--) {
      if ( ! *m++ ) { *p2 = op_powi_float64_t(*p1, ipow); }
      p1++; p2++;
    }
  }
  else
    while (n--) { (*p2) = op_powi_float64_t(*p1, ipow); p1++; p2++; }
}

static void
ca_ipower_cmplx64_t (ca_size_t n, boolean8_t *m,
                     char *ptr1, int32_t ipow, char *ptr2)
{
  cmplx64_t *p1 = (cmplx64_t *) ptr1, *p2 = (cmplx64_t *) ptr2;
  if ( m ) {
    while (n--) {
      if ( ! *m++ ) { *p2 = op_powi_cmplx64_t(*p1, ipow); }
      p1++; p2++;
    }
  }
  else
    while (n--) { (*p2) = op_powi_cmplx64_t(*p1, ipow); p1++; p2++; }
}

static void
ca_ipower_cmplx128_t (ca_size_t n, boolean8_t *m,
                     char *ptr1, int32_t ipow, char *ptr2)
{
  cmplx128_t *p1 = (cmplx128_t *) ptr1, *p2 = (cmplx128_t *) ptr2;
  if ( m ) {
    while (n--) {
      if ( ! *m++ ) { *p2 = op_powi_cmplx128_t(*p1, ipow); }
      p1++; p2++;
    }
  }
  else
    while (n--) { (*p2) = op_powi_cmplx128_t(*p1, ipow); p1++; p2++; }
}

/* Eager Float/Complex ** Integer producing a fresh entity output.
 * ca is input-only, co is the write target.  Mirrors rb_ca_call_monop
 * (see carray_math* / carray_kernels.c) so operand attach is elided:
 *   alias-cheap ca -> 1-shot ca_attach, use ca->ptr directly
 *   otherwise     -> ALLOCV + ca_xfer_all(CA_XFER_GET) into a scratch
 *                    buffer, no operand attach
 * Mask goes through ca_mask_overlay_safe (also without an operand
 * mask attach).  Called by rb_ca_pow when the fast-path predicate
 * matches. */
static VALUE
rb_ca_ipower (VALUE self, VALUE other)
{
  volatile VALUE obj;
  CArray *ca, *co;
  int32_t ipow;
  boolean8_t *m;

  ipow = NUM2INT(other);

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  co = ca_has_mask(ca) ? ca_template_safe(ca) : ca_template(ca);
  obj = ca_wrap_struct(co);

  ca_mask_overlay_safe(co, 1, ca);
  m = ( co->mask ) ? (boolean8_t *)co->mask->ptr : NULL;

  if ( ca_attach_is_alias(ca) ) {
    ca_attach(ca);
    switch ( ca->data_type ) {
    case CA_FLOAT32:
      ca_ipower_float32_t(ca->elements, m, ca->ptr, ipow, co->ptr);  break;
    case CA_FLOAT64:
      ca_ipower_float64_t(ca->elements, m, ca->ptr, ipow, co->ptr);  break;
    case CA_CMPLX64:
      ca_ipower_cmplx64_t(ca->elements, m, ca->ptr, ipow, co->ptr);  break;
    case CA_CMPLX128:
      ca_ipower_cmplx128_t(ca->elements, m, ca->ptr, ipow, co->ptr); break;
    default:
      rb_raise(rb_eCADataTypeError, "invalid data type for ipower");
    }
    ca_detach(ca);
  }
  else {
    volatile VALUE h1 = Qnil;
    char *p1;
    (void) h1;
    p1 = ALLOCV_N(char, h1, ca->elements * ca->bytes);
    ca_xfer_all(ca, p1, CA_XFER_GET);
    switch ( ca->data_type ) {
    case CA_FLOAT32:
      ca_ipower_float32_t(ca->elements, m, p1, ipow, co->ptr);  break;
    case CA_FLOAT64:
      ca_ipower_float64_t(ca->elements, m, p1, ipow, co->ptr);  break;
    case CA_CMPLX64:
      ca_ipower_cmplx64_t(ca->elements, m, p1, ipow, co->ptr);  break;
    case CA_CMPLX128:
      ca_ipower_cmplx128_t(ca->elements, m, p1, ipow, co->ptr); break;
    default:
      ALLOCV_END(h1);
      rb_raise(rb_eCADataTypeError, "invalid data type for ipower");
    }
    ALLOCV_END(h1);
  }

  obj = rb_ca_rewrap_unbound_repeat(self, obj);

  return obj;
}

static VALUE
rb_ca_ipower_bang (VALUE self, VALUE other)
{
  CArray *ca;
  int32_t ipow;
  boolean8_t *m;

  ipow = NUM2INT(other);

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);

  ca_attach(ca);

  m = ( ca->mask ) ? (boolean8_t *)ca->mask->ptr : NULL;

  switch ( ca->data_type ) {
  case CA_FLOAT32:
    ca_ipower_float32_t(ca->elements, m, ca->ptr, ipow, ca->ptr);  break;
  case CA_FLOAT64:
    ca_ipower_float64_t(ca->elements, m, ca->ptr, ipow, ca->ptr);  break;
  case CA_CMPLX64:
    ca_ipower_cmplx64_t(ca->elements, m, ca->ptr, ipow, ca->ptr);  break;
  case CA_CMPLX128:
    ca_ipower_cmplx128_t(ca->elements, m, ca->ptr, ipow, ca->ptr); break;
  default:
    rb_raise(rb_eRuntimeError, "invalid data type for ipower");
  }

  ca_sync(ca);
  ca_detach(ca);

  return self;
}

/* CArray#pow(other) (alias `**`) — Float/Complex ** Integer takes the
 * ipower fast path in this file; everything else falls through to the
 * mkkernel-generated general pow/cpow (rb_ca_power in
 * ext/carray_kernels.c).  Non-bang variant preserves UnboundRepeat
 * wrapping on the result. */
static VALUE rb_ca_pow (VALUE self, VALUE other)
{
  volatile VALUE obj;
  CArray *ca;

  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  if ( ( ca_is_float_type(ca) || ca_is_complex_type(ca) ) &&
       rb_obj_is_kind_of(other, rb_cInteger) ) {
    return rb_ca_ipower(self, other);
  }
  else {
    obj = rb_ca_power(self, other);
    obj = rb_ca_rewrap_unbound_repeat(self, obj);
    return obj;
  }
}

/* CArray#pow!(other) — in-place variant of #pow.  Dispatch mirrors
 * rb_ca_pow (fast path for Float/Complex ** Integer, otherwise
 * general rb_ca_power_bang). */
static VALUE rb_ca_pow_bang (VALUE self, VALUE other)
{
  CArray *ca;
  TypedData_Get_Struct(self, CArray, &carray_data_type, ca);
  if ( ( ca_is_float_type(ca) || ca_is_complex_type(ca) ) &&
       rb_obj_is_kind_of(other, rb_cInteger) ) {
    return rb_ca_ipower_bang(self, other);
  }
  else {
    return rb_ca_power_bang(self, other);
  }
}

void
Init_ca_op_ipower (void)
{
  rb_define_method(rb_cCArray, "pow",  rb_ca_pow,      1);
  rb_define_method(rb_cCArray, "pow!", rb_ca_pow_bang, 1);
  rb_define_alias(rb_cCArray, "**", "pow");
}
