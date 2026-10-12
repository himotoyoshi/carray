/* ---------------------------------------------------------------------------

   ca_op_powi.h -- shared `op_powi_<type>` integer-power helpers

   Used by:
     - ext/carray_kernels.c (generated from ext/mkkernel.rb)
         the `power` binop kernel's integer variants call
         `op_powi_<type>` to compute integer exponentiation by binary
         exponentiation (O(log p) vs pow's general path).
     - ext/carray_math.c (hand-written, P.5b.5)
         the `ipower` family (rb_ca_ipower, rb_ca_ipower_bang) uses
         `op_powi_<type>` for the Float**Integer / Complex**Integer
         fast path when invoked via CArray#pow with an Integer rhs.

   Both files include this header independently; each TU gets its own
   `static inline` copy with no linker conflicts.

   --------------------------------------------------------------------------- */

#ifndef CA_OP_POWI_H
#define CA_OP_POWI_H

#include "carray.h"
#include <stdint.h>

/* The text between the two markers below is also handed, as it stands, to
   an evaluator that compiles a kernel body calling op_powi_<type>
   (CArray.__kernel_helpers__, written into the build by mkkernel.rb).  It
   may use only <stdint.h>, float32_t / float64_t and ca_zerodiv: what such
   an evaluator's C declares.  The complex instantiations stay outside. */

/* BEGIN kernel helpers */

/* x raised to a non-negative power, by binary exponentiation.  The power
   is unsigned so that the magnitude of INT64_MIN is representable. */
#define op_powi_magnitude(type) \
static inline type \
op_powi_mag_## type (type x, uint64_t p) \
{ \
  type r=1; \
\
  switch(p) { \
  case 2: return x*x; \
  case 3: return x*x*x; \
  case 0: return 1; \
  case 1: return x; \
  } \
  while (p) { \
    if ( p & 1 ) r *= x; \
    x *= x; \
    p >>= 1; \
  } \
  return r; \
}

/* An integer to a negative power is 1/x^|p| in integer division, which is
   decided by x alone: 0 has no reciprocal, 1 and -1 keep their magnitude,
   anything larger truncates to 0.  Answering it that way, rather than by
   computing x^|p|, keeps a power that overflows -- 2 ** -64 -- from wrapping
   to a zero divisor. */
#define op_powi(type) \
op_powi_magnitude(type) \
static inline type \
op_powi_## type (type x, int64_t p) \
{ \
  if ( p < 0 ) { \
    if ( x == 0 ) ca_zerodiv(); \
    if ( x == 1 ) return 1; \
    if ( x == (type) -1 ) return ( p % 2 ) ? x : 1; \
    return 0; \
  } \
  return op_powi_mag_## type(x, (uint64_t) p); \
}

/* An unsigned x is never -1; (type) -1 is its largest value. */
#define op_powi_u(type) \
op_powi_magnitude(type) \
static inline type \
op_powi_## type (type x, int64_t p) \
{ \
  if ( p < 0 ) { \
    if ( x == 0 ) ca_zerodiv(); \
    return ( x == 1 ) ? 1 : 0; \
  } \
  return op_powi_mag_## type(x, (uint64_t) p); \
}

#define op_powi_fc(type) \
op_powi_magnitude(type) \
static inline type \
op_powi_## type (type x, int64_t p) \
{ \
  if ( p < 0 ) { \
    return 1 / op_powi_mag_## type(x, (uint64_t) 0 - (uint64_t) p); \
  } \
  return op_powi_mag_## type(x, (uint64_t) p); \
}

op_powi(int8_t)
op_powi_u(uint8_t)
op_powi(int16_t)
op_powi_u(uint16_t)
op_powi(int32_t)
op_powi_u(uint32_t)
op_powi(int64_t)
op_powi_u(uint64_t)
op_powi_fc(float32_t)
op_powi_fc(float64_t)

/* END kernel helpers */

op_powi_fc(cmplx64_t)
op_powi_fc(cmplx128_t)

#endif /* CA_OP_POWI_H */
