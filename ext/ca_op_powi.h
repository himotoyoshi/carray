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

#define op_powi(type) \
static inline type \
op_powi_## type (type x, int64_t p) \
{ \
  type r=1; \
\
  switch(p) { \
  case 2: return x*x; \
  case 3: return x*x*x; \
  case 0: return 1; \
  case 1: return x; \
  } \
  if (p<0) { \
    type den = op_powi_## type(x, -p); \
    if (den==0) ca_zerodiv(); \
    return 1/den; \
  }\
  while (p) { \
    if ( (p%2) == 1 ) r *= x; \
    x *= x; \
    p /= 2; \
  } \
  return r; \
}

#define op_powi_fc(type) \
static inline type \
op_powi_## type (type x, int64_t p) \
{ \
  type r=1; \
\
  switch(p) { \
  case 2: return x*x; \
  case 3: return x*x*x; \
  case 0: return 1; \
  case 1: return x; \
  } \
  if (p<0) { \
    type den = op_powi_## type(x, -p); \
    return 1/den; \
  }\
  while (p) { \
    if ( (p%2) == 1 ) r *= x; \
    x *= x; \
    p /= 2; \
  } \
  return r; \
}

op_powi(int8_t)
op_powi(uint8_t)
op_powi(int16_t)
op_powi(uint16_t)
op_powi(int32_t)
op_powi(uint32_t)
op_powi(int64_t)
op_powi(uint64_t)
op_powi_fc(float32_t)
op_powi_fc(float64_t)
op_powi_fc(cmplx64_t)
op_powi_fc(cmplx128_t)

#endif /* CA_OP_POWI_H */
