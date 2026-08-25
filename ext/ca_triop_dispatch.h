/* ---------------------------------------------------------------------------

  ca_triop_dispatch.h

  CATriOp dispatch API — sibling of ca_binop_dispatch.h.  Routes a
  triop op id (`CA_TRIOP_*`) to the per-data_type kernel and computes
  the 3-way input promotion.

  Kernel signature: fn(n, mask, src1, i1, src2, i2, src3, i3, dst, i4)
  All 3 operands are cast to the common data_type before the kernel
  runs (cast-before invariant, mirrors CABinOp).  Output data_type is
  always the common data_type (preserve).

  Scope: fma / fms / clip (see ext/mkkernel.rb :fma / :fms / :clip).
  None of the currently-defined triops trap on integer zero divisor.

---------------------------------------------------------------------------- */

#ifndef CA_TRIOP_DISPATCH_H
#define CA_TRIOP_DISPATCH_H

#include "carray.h"

/* ------------------------------------------------------------------- */
/* op_id enum                                                           */
/* ------------------------------------------------------------------- */

enum {
  CA_TRIOP_FMA  = 0,   /* a * b + c  (single-rounding on float)     */
  CA_TRIOP_FMS  = 1,   /* a * b - c  (single-rounding on float)     */
  CA_TRIOP_CLIP = 2,   /* min(max(a, lo), hi), NaN-preserving        */

  CA_TRIOP_COUNT
};

/* ------------------------------------------------------------------- */
/* Kernel dispatch tables (per-data_type)                               */
/* ------------------------------------------------------------------- */

extern ca_triop_func_t ca_triop_fma        [CA_NTYPE];
extern ca_triop_func_t ca_triop_fms        [CA_NTYPE];
extern ca_triop_func_t ca_triop_clip       [CA_NTYPE];

/* ------------------------------------------------------------------- */
/* Dispatch API                                                         */
/* ------------------------------------------------------------------- */

/* Look up the triop kernel for (op_id, common_dt).  Returns NULL if
   not implemented at the requested data_type. */
ca_triop_func_t ca_triop_kernel_lookup_vvv (uint16_t op_id, int8_t common_dt);

/* 3-way promotion: common data_type of (dt1, dt2, dt3).                 */
int8_t ca_lazy_promote_triop (uint16_t op_id, int8_t dt1, int8_t dt2, int8_t dt3);

/* Each operand's cast-target data_type (= common data_type for all three,
   the cast-before invariant).                                           */
void ca_triop_kernel_input_data_types (uint16_t op_id,
                                       int8_t dt1, int8_t dt2, int8_t dt3,
                                       int8_t *out_dt1, int8_t *out_dt2,
                                       int8_t *out_dt3);

#endif /* CA_TRIOP_DISPATCH_H */
