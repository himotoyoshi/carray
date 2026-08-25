/* ---------------------------------------------------------------------------

  ca_bincmp_dispatch.h

  PROPOSAL_LAZY_ELEMENTWISE_VIEW Phase 4 (P.4.1) — CABinCmp dispatch API.

  rev2 §0.5 #1 model: comparison output is always CA_BOOLEAN (boolean8_t,
  1 byte/cell).  Operands are cast to the common data_type via
  ca_promote_type, the kernel reads both operands and writes boolean
  output.  The binop in-place trick (= pull left into output buffer)
  does NOT work for comparison because output data_type != operand data_type.

  rev2 §0.5 #4: bitwise on boolean output is handled by Phase 2 CABinOp
  (= ca_binop_bit_and_i_boolean8_t exists).  This file is comparison-
  only.

  P.4.1 scope: only :lt wired with a kernel; other 6 op constants
  reserved and lookup returns NULL (caller detects not-implemented).
  P.4.2 expands to 7 ops (= eq / ne / lt / gt / le / ge / feq).

---------------------------------------------------------------------------- */

#ifndef CA_BINCMP_DISPATCH_H
#define CA_BINCMP_DISPATCH_H

#include "carray.h"

/* ------------------------------------------------------------------- */
/* op_id enum                                                           */
/* ------------------------------------------------------------------- */

enum {
  CA_BINCMP_LT       = 0,
  CA_BINCMP_GT       = 1,
  CA_BINCMP_LE       = 2,
  CA_BINCMP_GE       = 3,
  CA_BINCMP_EQ       = 4,
  CA_BINCMP_NE       = 5,
  CA_BINCMP_FEQ      = 6,   /* float ε-equal, eps stored in CABinCmp.tol tail */
  /* IC.2: tolerance-bearing predicates, tol stored in CABinCmp.tol tail */
  CA_BINCMP_IS_CLOSE = 7,   /* |a - b| <= tol (absolute) */
  CA_BINCMP_IS_EQUIV = 8,   /* |a - b| / max(|a|, |b|) <= tol (relative) */

  CA_BINCMP_COUNT
};

/* ------------------------------------------------------------------- */
/* Kernel dispatch tables (per-data_type)                               */
/* ------------------------------------------------------------------- */

/* The per-data_type bincmp kernel tables (mkkernel-generated, write
   boolean8_t output).  Made public here (PROPOSAL_CARRAY_H_REORG H.2)
   so external math-backend gems can swap a slot through the carray.h
   umbrella with no hand-declared externs.  */
extern ca_bincmp_func_t ca_bincmp_lt       [CA_NTYPE];
extern ca_bincmp_func_t ca_bincmp_gt       [CA_NTYPE];
extern ca_bincmp_func_t ca_bincmp_le       [CA_NTYPE];
extern ca_bincmp_func_t ca_bincmp_ge       [CA_NTYPE];
extern ca_bincmp_func_t ca_bincmp_eq       [CA_NTYPE];
extern ca_bincmp_func_t ca_bincmp_ne       [CA_NTYPE];
extern ca_bincmp_func_t ca_bincmp_feq      [CA_NTYPE];
extern ca_bincmp_func_t ca_bincmp_is_close [CA_NTYPE];
extern ca_bincmp_func_t ca_bincmp_is_equiv [CA_NTYPE];

/* ------------------------------------------------------------------- */
/* Dispatch API                                                         */
/* ------------------------------------------------------------------- */

/* Look up the bincmp kernel for (op_id, common_dt).  Returns NULL if
   not implemented at the requested data_type.  All bincmp kernels write
   boolean8_t to ptr3.                                                  */
ca_bincmp_func_t ca_bincmp_kernel_lookup (uint16_t op_id, int8_t common_dt);

/* Compute input common data_type via ca_promote_type.  Output data_type is
   always CA_BOOLEAN (NOT returned here; CABinCmp.data_type is set
   directly).                                                           */
int8_t ca_lazy_bincmp_promote (uint16_t op_id, int8_t l_dt, int8_t r_dt);

/* What data_type does each operand need to be cast to before reaching the
   kernel?  Returns common data_type for both (= cast-before route, same as
   Phase 2 CABinOp).                                                    */
void ca_bincmp_kernel_input_data_types (uint16_t op_id, int8_t l_dt, int8_t r_dt,
                                     int8_t *out_l_in_dt, int8_t *out_r_in_dt);

#endif /* CA_BINCMP_DISPATCH_H */
