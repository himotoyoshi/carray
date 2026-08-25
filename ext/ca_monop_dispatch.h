/* ---------------------------------------------------------------------------

  ca_monop_dispatch.h

  PROPOSAL_LAZY_ELEMENTWISE_VIEW Phase 1 (P.1.2) — CAMonOp dispatch API.

---------------------------------------------------------------------------- */

#ifndef CA_MONOP_DISPATCH_H
#define CA_MONOP_DISPATCH_H

#include "carray.h"

/* ------------------------------------------------------------------- */
/* op_id enum                                                           */
/* ------------------------------------------------------------------- */

/* Three contiguous segments of normal op_ids, followed by a CAST segment
   offset at CA_MONOP_CAST_BASE.

   Numeric assignments are stable — callers and Ruby constants reference
   them by name only.  */
enum {
  /* Preserve-data_type monop (8) */
  CA_MONOP_ZERO    =  0,
  CA_MONOP_ONE     =  1,
  CA_MONOP_FRAC    =  2,
  CA_MONOP_NEG     =  3,
  CA_MONOP_BIT_NEG =  4,
  CA_MONOP_ABS_I   =  5,
  CA_MONOP_CONJ    =  6,
  CA_MONOP_NOT     =  7,

  /* Preserve-data_type monfunc (4) */
  CA_MONOP_CEIL    =  8,
  CA_MONOP_FLOOR   =  9,
  CA_MONOP_ROUND   = 10,
  CA_MONOP_RCP     = 11,

  /* Widening monfunc (22) */
  CA_MONOP_WIDENING_BEGIN = 12,
  CA_MONOP_RAD     = 12,
  CA_MONOP_DEG     = 13,
  CA_MONOP_SQRT    = 14,
  CA_MONOP_EXP     = 15,
  CA_MONOP_EXP2    = 16,
  CA_MONOP_EXP10   = 17,
  CA_MONOP_LOG     = 18,
  CA_MONOP_LOG10   = 19,
  CA_MONOP_LOG2    = 20,
  CA_MONOP_LOGB    = 21,
  CA_MONOP_SIN     = 22,
  CA_MONOP_COS     = 23,
  CA_MONOP_TAN     = 24,
  CA_MONOP_ASIN    = 25,
  CA_MONOP_ACOS    = 26,
  CA_MONOP_ATAN    = 27,
  CA_MONOP_SINH    = 28,
  CA_MONOP_COSH    = 29,
  CA_MONOP_TANH    = 30,
  CA_MONOP_ASINH   = 31,
  CA_MONOP_ACOSH   = 32,
  CA_MONOP_ATANH   = 33,
  CA_MONOP_WIDENING_END = 34,    /* exclusive sentinel */

  /* Phase 6 P.6.1 (Q3 Z): byte_swap is a single op_id with per-data_type
     kernel table (= data_type-preserving, output.bytes == input.bytes,
     CMPLX halves swapped independently inside the kernel).  Placed
     after WIDENING_END so the widening check (op_id < WIDENING_END)
     correctly classifies it as preserve.  kernel_lookup dispatches to
     ca_monop_byte_swap[in_data_type] (ext/ca_op_byte_swap.c).  */
  CA_MONOP_BYTE_SWAP = 35,

  /* imag_i (= cimag for complex stored into the same-data_type slot, 0 for
     numeric).  Same trick as abs_i: data_type-preserving kernel that puts
     the desired value in the real component so a downstream
     cast-to-float picks it up.  Powers the lazy `.imag` chain (= 2-node
     for complex parent, 1-node for non-complex).  */
  CA_MONOP_IMAG_I  = 36,

  /* M.1 (PyTorch alignment): additional monop / monfunc ops.  Placed
     after IMAG_I to preserve stable IDs of existing ops in the
     12..33 widening segment.  `ca_monop_is_widening` is extended to
     recognise EXPM1 / LOG1P / RSQRT.  */
  CA_MONOP_EXPM1   = 37,    /* widening:  exp(x) - 1 */
  CA_MONOP_LOG1P   = 38,    /* widening:  log(1 + x) */
  CA_MONOP_RSQRT   = 39,    /* widening:  1 / sqrt(x) */
  CA_MONOP_TRUNC   = 40,    /* preserve:  toward-zero (int identity, float trunc) */
  CA_MONOP_SQUARE  = 41,    /* preserve:  x * x */

  /* M.4 (angle normalisation migration from carray_mathfunc.c):
     widening monfunc — integer auto-casts to f64, float in / float out
     preserve.  */
  CA_MONOP_DEG_360 = 42,    /* widening:  fold into [0, 360)   */
  CA_MONOP_DEG_180 = 43,    /* widening:  fold into [-180, 180) */
  CA_MONOP_RAD_2PI = 44,    /* widening:  fold into [0, 2pi)    */
  CA_MONOP_RAD_PI  = 45,    /* widening:  fold into [-pi, pi)   */

  CA_MONOP_SIGN    = 46,    /* preserve:  sign function (-1/0/1 for real,
                               unit vector for complex, 0/1 for uint/bool) */
  CA_MONOP_ARG_I   = 47,    /* preserve:  writes carg(z) into the slot
                               (float in-place, complex real component).
                               A chain cast_<float> extracts the real part
                               for the user-facing `arg` result — same
                               pattern as abs_i / imag_i. */

  /* Cast ops live in a separate range so they cannot collide with the
     normal ops.  cast-to-data_type-X has op_id = CA_MONOP_CAST_BASE + X.  */
  CA_MONOP_CAST_BASE = 100,
};

/* ------------------------------------------------------------------- */
/* Kernel dispatch tables (per-data_type)                               */
/* ------------------------------------------------------------------- */

/* The per-data_type monop kernel tables.  Defined in carray_kernels.c
   (mkkernel-generated) and ext/ca_op_byte_swap.c (byte_swap).  Made
   public here (PROPOSAL_CARRAY_H_REORG H.2) so external math-backend
   gems (e.g. carray-vmath-vforce) can swap a slot — e.g.
   `ca_monop_sin[CA_FLOAT64] = my_vector_sin;` — through the carray.h
   umbrella with no hand-declared externs.  */

/* Preserve-data_type monop (8) */
extern ca_monop_func_t ca_monop_zero[CA_NTYPE];
extern ca_monop_func_t ca_monop_one[CA_NTYPE];
extern ca_monop_func_t ca_monop_frac[CA_NTYPE];
extern ca_monop_func_t ca_monop_neg[CA_NTYPE];
extern ca_monop_func_t ca_monop_bit_neg[CA_NTYPE];
extern ca_monop_func_t ca_monop_abs_i[CA_NTYPE];
extern ca_monop_func_t ca_monop_conj[CA_NTYPE];
extern ca_monop_func_t ca_monop_not[CA_NTYPE];

/* Preserve-data_type monfunc (4) */
extern ca_monop_func_t ca_monop_ceil[CA_NTYPE];
extern ca_monop_func_t ca_monop_floor[CA_NTYPE];
extern ca_monop_func_t ca_monop_round[CA_NTYPE];
extern ca_monop_func_t ca_monop_rcp[CA_NTYPE];

/* Widening monfunc (22) */
extern ca_monop_func_t ca_monop_rad[CA_NTYPE];
extern ca_monop_func_t ca_monop_deg[CA_NTYPE];
extern ca_monop_func_t ca_monop_sqrt[CA_NTYPE];
extern ca_monop_func_t ca_monop_exp[CA_NTYPE];
extern ca_monop_func_t ca_monop_exp2[CA_NTYPE];
extern ca_monop_func_t ca_monop_exp10[CA_NTYPE];
extern ca_monop_func_t ca_monop_log[CA_NTYPE];
extern ca_monop_func_t ca_monop_log10[CA_NTYPE];
extern ca_monop_func_t ca_monop_log2[CA_NTYPE];
extern ca_monop_func_t ca_monop_logb[CA_NTYPE];
extern ca_monop_func_t ca_monop_sin[CA_NTYPE];
extern ca_monop_func_t ca_monop_cos[CA_NTYPE];
extern ca_monop_func_t ca_monop_tan[CA_NTYPE];
extern ca_monop_func_t ca_monop_asin[CA_NTYPE];
extern ca_monop_func_t ca_monop_acos[CA_NTYPE];
extern ca_monop_func_t ca_monop_atan[CA_NTYPE];
extern ca_monop_func_t ca_monop_sinh[CA_NTYPE];
extern ca_monop_func_t ca_monop_cosh[CA_NTYPE];
extern ca_monop_func_t ca_monop_tanh[CA_NTYPE];
extern ca_monop_func_t ca_monop_asinh[CA_NTYPE];
extern ca_monop_func_t ca_monop_acosh[CA_NTYPE];
extern ca_monop_func_t ca_monop_atanh[CA_NTYPE];

/* byte_swap (hand-written, ext/ca_op_byte_swap.c) */
extern ca_monop_func_t ca_monop_byte_swap[CA_NTYPE];

/* imag_i: cimag for complex, 0 for numeric (mkkernel-generated) */
extern ca_monop_func_t ca_monop_imag_i[CA_NTYPE];

/* M.1: PyTorch-alignment additions (mkkernel-generated) */
extern ca_monop_func_t ca_monop_expm1 [CA_NTYPE];
extern ca_monop_func_t ca_monop_log1p [CA_NTYPE];
extern ca_monop_func_t ca_monop_rsqrt [CA_NTYPE];
extern ca_monop_func_t ca_monop_trunc [CA_NTYPE];
extern ca_monop_func_t ca_monop_square[CA_NTYPE];

/* M.4: angle normalisation migration (mkkernel-generated) */
extern ca_monop_func_t ca_monop_deg_360[CA_NTYPE];
extern ca_monop_func_t ca_monop_deg_180[CA_NTYPE];
extern ca_monop_func_t ca_monop_rad_2pi[CA_NTYPE];
extern ca_monop_func_t ca_monop_rad_pi [CA_NTYPE];

/* Preserve-data_type primitives added for lazy substrate coverage.       */
extern ca_monop_func_t ca_monop_sign   [CA_NTYPE];
extern ca_monop_func_t ca_monop_arg_i  [CA_NTYPE];

/* ------------------------------------------------------------------- */
/* Dispatch API                                                         */
/* ------------------------------------------------------------------- */

/* Look up the per-data_type kernel for a normal monop op_id.  Returns NULL
   for cast op_ids (caller handles cast via ca_cast_block).  */
ca_monop_func_t ca_monop_kernel_lookup (uint16_t op_id, int8_t in_data_type);

/* Returns true iff op_id encodes a cast operation.  */
int ca_monop_is_cast (uint16_t op_id);

/* Phase 6 P.6.3: returns true iff op_id is a "writable view" op
   (= cast or byte_swap).  These ops:
     - support writable view lifecycle (CA_FLAG_READ_ONLY not set)
     - have an inverse mapping for write-back (cast = reverse cast;
       byte_swap = involution = same op applied twice)
     - use CAFake-style attach/sync/detach lifecycle in CAMonOp
       (ca_attach(parent) in allocate/attach, op apply to fill ca.ptr,
       inverse op + memcpy to parent.ptr in sync, ca_detach(parent))
   Non-cast / non-byte_swap monop / monfunc remain read-only with
   chain materialise lifecycle.  */
int ca_monop_is_writable_view (uint16_t op_id);

/* Phase 6 P.6.2 (Q9 α / Q13 α foundational helper): Returns true iff
   `view` is a single-node CAMonOp with a cast op_id (= no further CAMonOp
   in the parent chain).  This is the discrimination predicate for the
   F.6.2 per-fiber fused fast path after CAFake → CAMonOp(cast) typedef
   migration: same architectural role as the current
   `attach == ca_fake_func.attach` check in ca_kernel_iterator.c:336.

   For chain CAMonOp (= depth ≥ 2, e.g. `a.lazy.sqrt.cast`), returns 0
   so the existing chain materialise path (= arena-pooled scratches)
   continues to handle the chain end-to-end.

   `view` must be a non-NULL CArray*.  Returns 0 for non-CAMonOp views.
   Defined in ca_obj_monop.c so it can access the CAMonOp struct internals
   (op_id tail field, parent pointer).  */
int ca_monop_view_is_single_cast (CArray *view);

/* Compute the output data_type for (op_id, parent_data_type).  Mirrors existing
   eager mkmath rules.  */
int8_t ca_lazy_promote_monop (uint16_t op_id, int8_t parent_data_type);

/* Compute the data_type the kernel expects as input.  When != parent_data_type,
   a CAMonOp(:cast_<data_type>) node must be inserted between this op and
   its parent (finding #1, cast-before).  For cast op_ids, returns
   parent_data_type unchanged.  */
int8_t ca_monop_kernel_input_data_type (uint16_t op_id, int8_t parent_data_type);

#endif /* CA_MONOP_DISPATCH_H */
