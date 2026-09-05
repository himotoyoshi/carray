/* ---------------------------------------------------------------------------

   ca_op_cmplx64.h -- the cmplx64 products and quotients, computed in
                      double and rounded once

   Used by:
     - ext/carray_kernels_binop.c and ext/carray_kernels_monop.c
       (generated from ext/mkkernel.rb): the `*`, `/`, `rcp` and
       `rcp_mul` kernels for CA_CMPLX64.

   Why these are not just `x * y` and `x / y`.  Both the product and the
   quotient of two complex numbers subtract two products of the parts, so
   the result cancels whenever those two are close.  Done at the operands'
   own width there are no bits left underneath to absorb the cancellation.
   Divide has a second cost: the compiler turns a `float _Complex` divide
   into a call to `__divsc3`, which is Smith's algorithm (scale by the
   larger component so the intermediate squares cannot overflow) plus the
   C99 Annex G recovery for infinities -- branches and a call per cell.

   For a cmplx64 the scaling is not needed at all: the operands are
   floats, so a product of two parts reaches about 1.2e77 where a double
   reaches 1.8e308.  Computing the textbook formulas in double therefore
   cannot overflow, and the double carries 29 extra mantissa bits, which
   is what the cancellation needs.  Measured against an exact rational
   reference, the double route was correctly rounded on every sample
   where the width-native route was off by up to 1806 ulp (divide) and
   1679 ulp (multiply).

   The two are not the same trade.  Divide gets faster as well, because
   the call and the scaling both go away.  Multiply gets slower, because
   the compiler already inlines a naive float product and only calls
   `__mulsc3` when a NaN appears -- so the wider arithmetic is pure cost
   there, and is paid for the accuracy alone.

   Annex G is preserved by falling back rather than by reimplementing it.
   The fallback is chosen from the *result*, not from a classification of
   the inputs: if the quick answer is not an ordinary number, hand the
   pair to the compiler's helper and return whatever it says.  Writing an
   input classification here would mean transcribing the Annex G table,
   and a transcription drifts from what the runtime actually does.

   cmplx128 has no wider type to borrow (`long double` is a double on
   Apple ARM64 and a slow 80-bit on x86-64), so it keeps `__mulsc3` /
   `__divdc3`.

   --------------------------------------------------------------------------- */

#ifndef CA_OP_CMPLX64_H
#define CA_OP_CMPLX64_H

#include "carray.h"
#include <math.h>

#ifdef HAVE_COMPLEX_H

/* CMPLXF is the float sibling of the CMPLX defined in carray.h, and is
   here for the same reason: `re + I * im` evaluates `I * im` first, so an
   im of +0.0 loses the sign of a -0.0 real part.  CMPLXF is C11; provide
   it when the toolchain predates that. */
#ifndef CMPLXF
#  if defined(__clang__) || (defined(__GNUC__) && (__GNUC__ > 4 || (__GNUC__ == 4 && __GNUC_MINOR__ >= 7)))
#    define CMPLXF(re, im) __builtin_complex((float)(re), (float)(im))
#  else
#    define CMPLXF(re, im) \
       (((union { float _parts[2]; float complex _value; }) \
           { { (float)(re), (float)(im) } })._value)
#  endif
#endif

/* The real part is `xr*yr - xi*yi`, which cancels when the two products
   are close; the double keeps the bits that cancellation eats.  Only a
   NaN can appear here that the naive form gets wrong, since a product of
   two floats cannot overflow a double -- an infinite part in the answer
   is the true answer.  */
static inline cmplx64_t
op_cmul_cmplx64 (cmplx64_t x, cmplx64_t y)
{
  double xr = crealf(x), xi = cimagf(x);
  double yr = crealf(y), yi = cimagf(y);
  float  rr = (float) (xr * yr - xi * yi);
  float  ri = (float) (xr * yi + xi * yr);
  if ( isnan(rr) || isnan(ri) ) {
    return x * y;   /* __mulsc3: an infinity met a zero (Annex G) */
  }
  return CMPLXF(rr, ri);
}

static inline cmplx64_t
op_cdiv_cmplx64 (cmplx64_t x, cmplx64_t y)
{
  double yr = crealf(y), yi = cimagf(y);
  double d  = yr * yr + yi * yi;
  if ( d > 0.0 && d < INFINITY ) {
    double xr = crealf(x), xi = cimagf(x);
    float  rr = (float) ((xr * yr + xi * yi) / d);
    float  ri = (float) ((xi * yr - xr * yi) / d);
    if ( isfinite(rr) && isfinite(ri) ) {
      return CMPLXF(rr, ri);
    }
  }
  return x / y;   /* __divsc3: zero, infinite or NaN operands (Annex G) */
}

/* 1 / y.  Same shape with the numerator's parts folded in, so that
   `rcp` and `1 / z` keep giving the same answer. */
static inline cmplx64_t
op_crcp_cmplx64 (cmplx64_t y)
{
  double yr = crealf(y), yi = cimagf(y);
  double d  = yr * yr + yi * yi;
  if ( d > 0.0 && d < INFINITY ) {
    float rr = (float) (yr / d);
    float ri = (float) (-yi / d);
    if ( isfinite(rr) && isfinite(ri) ) {
      return CMPLXF(rr, ri);
    }
  }
  return 1 / y;
}

#endif /* HAVE_COMPLEX_H */

#endif /* CA_OP_CMPLX64_H */
