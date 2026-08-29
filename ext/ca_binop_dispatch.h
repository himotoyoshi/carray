/* ---------------------------------------------------------------------------

  ca_binop_dispatch.h

  PROPOSAL_LAZY_ELEMENTWISE_VIEW Phase 2 (P.2.1) — CABinOp dispatch API.

  rev3 §3.2: 1-D same-type table + cast-before route.  No 2-D mixed-type
  dispatch (= existing eager `ca_binop_<op>[CA_NTYPE]` is 1-D same-type,
  promotion handled by inserting CAMonOp(:cast_<common>) nodes before
  reaching CABinOp).

  P.2.1 scope: ADD only, vv only.  P.2.2 expands to 13 ops.

---------------------------------------------------------------------------- */

#ifndef CA_BINOP_DISPATCH_H
#define CA_BINOP_DISPATCH_H

#include "carray.h"

/* ------------------------------------------------------------------- */
/* op_id enum                                                           */
/* ------------------------------------------------------------------- */

enum {
  /* Arithmetic binop (5) — variants: vv/vs/sv (P.2.3 gate)            */
  CA_BINOP_ADD = 0,
  CA_BINOP_SUB = 1,
  CA_BINOP_MUL = 2,
  CA_BINOP_DIV = 3,
  CA_BINOP_POW = 4,

  /* Bitwise / logical (Q1 (b) verdict: 13 op total; full scope flesh
     out in P.2.2)                                                      */
  CA_BINOP_BIT_AND   = 5,
  CA_BINOP_BIT_OR    = 6,
  CA_BINOP_BIT_XOR   = 7,
  CA_BINOP_BIT_LSHIFT= 8,
  CA_BINOP_BIT_RSHIFT= 9,
  CA_BINOP_MOD       = 10,
  CA_BINOP_QUO       = 11,
  CA_BINOP_RCP_MUL   = 12,

  /* Float/Complex ** Integer fast path (binary exponentiation, O(log p)).
     Heterogeneous binop: left data_type is float32/float64/cmplx64/cmplx128,
     right is always int64 (CScalar carrying the exponent), output data_type
     = left data_type (preserve).  Bypasses the standard cast-before route
     (= no common-data_type promotion) since the integer semantics of the
     right operand is load-bearing.  See ext/ca_op_ipower.c for the
     hand-written kernel table.                                          */
  CA_BINOP_IPOWER    = 13,

  /* M.2 (PyTorch alignment): float-only binop family.  Integer input
     unsupported at this layer — caller must cast operands explicitly.
     ATAN2 / HYPOT migrate from hand-written CAMath wrappers (M.3).  */
  CA_BINOP_COPYSIGN  = 14,
  CA_BINOP_LOGADDEXP = 15,
  CA_BINOP_NEXTAFTER = 16,
  CA_BINOP_FMOD      = 17,
  CA_BINOP_ATAN2     = 18,
  CA_BINOP_HYPOT     = 19,

  /* Pair-wise max / min (NaN-skip semantics via C99 fmax / fmin on the
     float branch; comparison form on integer / object).  All numeric +
     object.  Ruby aliases `fmax` / `fmin` share the same kernel.       */
  CA_BINOP_PMAX      = 20,
  CA_BINOP_PMIN      = 21,

  /* Pair-wise max / min, NaN-propagate variant (if either operand is
     NaN the result is NaN).  Distinct kernel from PMAX/PMIN — the
     float branch short-circuits on isnan.  All numeric + object.       */
  CA_BINOP_MAXIMUM   = 22,
  CA_BINOP_MINIMUM   = 23,

  /* Boolean 3-value logic word forms (bool + object only, no numeric).
     Distinct from BIT_AND / BIT_OR / BIT_XOR: those carry the Kleene
     3-valued fixup on masked cells (see ca_obj_binop.c ~line 515);
     these word forms use plain mask-propagate semantics.              */
  CA_BINOP_AND       = 24,
  CA_BINOP_OR        = 25,
  CA_BINOP_XOR       = 26,

  CA_BINOP_COUNT
};

/* ------------------------------------------------------------------- */
/* Kernel dispatch tables (per-data_type)                               */
/* ------------------------------------------------------------------- */

/* The per-data_type binop kernel tables.  Defined in carray_kernels.c
   (mkkernel-generated), ext/ca_op_ipower.c (ipower).  Made public here
   (PROPOSAL_CARRAY_H_REORG H.2) so external math-backend gems can swap
   a slot through the carray.h umbrella with no hand-declared externs.  */
extern ca_binop_func_t ca_binop_add        [CA_NTYPE];
extern ca_binop_func_t ca_binop_sub        [CA_NTYPE];
extern ca_binop_func_t ca_binop_mul        [CA_NTYPE];
extern ca_binop_func_t ca_binop_div        [CA_NTYPE];
extern ca_binop_func_t ca_binop_power      [CA_NTYPE];
extern ca_binop_func_t ca_binop_bit_and_i  [CA_NTYPE];
extern ca_binop_func_t ca_binop_bit_or_i   [CA_NTYPE];
extern ca_binop_func_t ca_binop_bit_xor_i  [CA_NTYPE];
extern ca_binop_func_t ca_binop_bit_lshift [CA_NTYPE];
extern ca_binop_func_t ca_binop_bit_rshift [CA_NTYPE];
extern ca_binop_func_t ca_binop_mod        [CA_NTYPE];
extern ca_binop_func_t ca_binop_quo_i      [CA_NTYPE];
extern ca_binop_func_t ca_binop_rcp_mul    [CA_NTYPE];
/* Hand-written heterogeneous binop (left: float/cmplx, right: int64,
   output: left data_type).  Defined in ext/ca_op_ipower.c.  */
extern ca_binop_func_t ca_binop_ipower     [CA_NTYPE];
/* M.2 + M.3: PyTorch alignment additions (mkkernel-generated, float-only). */
extern ca_binop_func_t ca_binop_copysign   [CA_NTYPE];
extern ca_binop_func_t ca_binop_logaddexp  [CA_NTYPE];
extern ca_binop_func_t ca_binop_nextafter  [CA_NTYPE];
extern ca_binop_func_t ca_binop_fmod       [CA_NTYPE];
extern ca_binop_func_t ca_binop_atan2      [CA_NTYPE];
extern ca_binop_func_t ca_binop_hypot      [CA_NTYPE];
extern ca_binop_func_t ca_binop_pmax       [CA_NTYPE];
extern ca_binop_func_t ca_binop_pmin       [CA_NTYPE];
extern ca_binop_func_t ca_binop_maximum    [CA_NTYPE];
extern ca_binop_func_t ca_binop_minimum    [CA_NTYPE];
extern ca_binop_func_t ca_binop_and        [CA_NTYPE];
extern ca_binop_func_t ca_binop_or         [CA_NTYPE];
extern ca_binop_func_t ca_binop_xor        [CA_NTYPE];

/* ------------------------------------------------------------------- */
/* Dispatch API                                                         */
/* ------------------------------------------------------------------- */

/* Look up the same-type vv kernel for (op_id, common_dt).  Returns NULL
   if not implemented.  P.2.1: only ADD wired up; others NULL until P.2.2.  */
ca_binop_func_t ca_binop_kernel_lookup_vv (uint16_t op_id, int8_t common_dt);

/* Compute output (= common) data_type via the existing eager promotion rule
   (ca_promote_type).  Phase 0 audit landed extern visibility.            */
int8_t ca_lazy_promote_binop (uint16_t op_id, int8_t l_dt, int8_t r_dt);

/* What data_type does each operand need to be cast to before reaching the
   kernel?  Returns common data_type for both (= cast-before route).  When
   common != operand.data_type, caller inserts CAMonOp(:cast_<common>).      */
void ca_binop_kernel_input_data_types (uint16_t op_id, int8_t l_dt, int8_t r_dt,
                                    int8_t *out_l_in_dt, int8_t *out_r_in_dt);

/* True iff op_id is a trapping op for the given common_dt (= integer
   DIV / MOD on integer data_types).  Float DIV returns NaN/Inf and does
   not trap, so it is NOT classified trapping.

   When trapping AND either operand has a mask, xfer_stride must pass
   a slab mask to the kernel so masked cells are skipped (otherwise
   masked-zero divisors crash with SIGFPE).  See §3.4 rev3.            */
int ca_binop_is_trapping (uint16_t op_id, int8_t common_dt);

#endif /* CA_BINOP_DISPATCH_H */
