/* ---------------------------------------------------------------------------

  ca_moncmp_dispatch.h

  PROPOSAL_LAZY_ELEMENTWISE_VIEW Phase 4 (P.4.1) — CAMonCmp dispatch API.

  rev2 §0.5 #3: integer is_nan / is_inf / is_finite use the existing
  per-data_type kernels (= no constant-fold).  The kernel for integer
  data_types writes all-false (is_nan, is_inf) or all-true (is_finite) and
  leaves masked cells untouched; the caller's output mask propagates
  via the normal create_mask path.

  P.4.1 scope: only :is_nan wired; remaining ops reserved.  P.4.2
  expands to 3 ops (= is_nan / is_inf / is_finite).

---------------------------------------------------------------------------- */

#ifndef CA_MONCMP_DISPATCH_H
#define CA_MONCMP_DISPATCH_H

#include "carray.h"

/* ------------------------------------------------------------------- */
/* op_id enum                                                           */
/* ------------------------------------------------------------------- */

enum {
  CA_MONCMP_IS_NAN     = 0,
  CA_MONCMP_IS_INF     = 1,
  CA_MONCMP_IS_FINITE  = 2,
  CA_MONCMP_IS_INVALID = 3,
  CA_MONCMP_SIGNBIT    = 4,  /* M.1: PyTorch alignment */

  CA_MONCMP_COUNT
};

/* ------------------------------------------------------------------- */
/* Kernel dispatch tables (per-data_type)                               */
/* ------------------------------------------------------------------- */

/* The per-data_type moncmp kernel tables (mkkernel-generated, write
   boolean8_t output).  Made public here (PROPOSAL_CARRAY_H_REORG H.2)
   so external math-backend gems can swap a slot through the carray.h
   umbrella with no hand-declared externs.  */
extern ca_moncmp_func_t ca_moncmp_is_nan     [CA_NTYPE];
extern ca_moncmp_func_t ca_moncmp_is_inf     [CA_NTYPE];
extern ca_moncmp_func_t ca_moncmp_is_finite  [CA_NTYPE];
extern ca_moncmp_func_t ca_moncmp_is_invalid [CA_NTYPE];
extern ca_moncmp_func_t ca_moncmp_signbit    [CA_NTYPE];

/* ------------------------------------------------------------------- */
/* Dispatch API                                                         */
/* ------------------------------------------------------------------- */

/* Look up the moncmp kernel for (op_id, in_dt).  Returns NULL if not
   implemented at the requested data_type.  All moncmp kernels write
   boolean8_t to ptr2.  No cast insertion needed (= kernel exists for
   all numeric data_types including integer, where it const-folds inside
   the kernel + preserves mask via skip semantics).                    */
ca_moncmp_func_t ca_moncmp_kernel_lookup (uint16_t op_id, int8_t in_dt);

#endif /* CA_MONCMP_DISPATCH_H */
