/* ---------------------------------------------------------------------------

  CAMonOp dispatch: hand-curated table-of-tables that maps a monop op id
  (`CA_MONOP_*`) to the per-data_type kernel function.

  Sibling of ca_obj_monop.c (the CAMonOp view), ca_binop_dispatch.c
  (binary counterpart), and ca_moncmp_dispatch.c (boolean-output
  unary).  The per-data_type kernel tables (`ca_monop_sqrt[CA_NTYPE]`
  etc.) are extern'd from the generated carray_kernels.c and declared
  in ca_monop_dispatch.h.

  ## Op categories (determines output data_type)

  - **preserve**       output = parent data_type.  Examples: zero, one,
                       neg, abs_i, conj, not, ceil, floor, round, rcp,
                       trunc, square, byte_swap.
  - **widening**       output = `CA_FLOAT64` for integer/boolean parent,
                       else parent data_type.  Examples: sqrt, exp,
                       log, sin, cos, atan, expm1, log1p, rsqrt,
                       deg_360, rad_2pi.
  - **cast**           `op_id >= CA_MONOP_CAST_BASE`.  Output data_type =
                       `op_id - CA_MONOP_CAST_BASE`.  Cast is handled
                       specially in xfer_stride via ca_cast_block; the
                       kernel lookup returns NULL.

  Membership is queried by `ca_monop_is_cast` and `ca_monop_is_widening`
  below.  The widening predicate enumerates the widening op_ids
  explicitly (= the WIDENING_BEGIN/END contiguous range plus a few ops
  added after IMAG_I; see the function body).

  ## Kernel input data_type

  Same as output data_type.  When kernel_input_data_type !=
  parent.data_type, the CAMonOp builder inserts a CAMonOp(`:cast_<dt>`)
  node between this op and parent (cast-before route).  Cast ops are
  the one exception: the kernel accepts whatever the upstream node
  provides without further coercion.

---------------------------------------------------------------------------- */

#include "carray.h"
#include "ca_monop_dispatch.h"

/* ------------------------------------------------------------------- */
/* op_id -> kernel table lookup                                         */
/* ------------------------------------------------------------------- */

/* Returns the kernel for the given input data_type.  Returns NULL for
   cast ops (op_id >= CA_MONOP_CAST_BASE) and unknown op_ids; cast is
   handled specially in xfer_stride via ca_cast_block. */
ca_monop_func_t
ca_monop_kernel_lookup (uint16_t op_id, int8_t in_data_type)
{
  switch (op_id) {
    case CA_MONOP_ZERO:    return ca_monop_zero[in_data_type];
    case CA_MONOP_ONE:     return ca_monop_one[in_data_type];
    case CA_MONOP_FRAC:    return ca_monop_frac[in_data_type];
    case CA_MONOP_NEG:     return ca_monop_neg[in_data_type];
    case CA_MONOP_BIT_NEG: return ca_monop_bit_neg[in_data_type];
    case CA_MONOP_ABS_I:   return ca_monop_abs_i[in_data_type];
    case CA_MONOP_CONJ:    return ca_monop_conj[in_data_type];
    case CA_MONOP_NOT:     return ca_monop_not[in_data_type];

    case CA_MONOP_CEIL:    return ca_monop_ceil[in_data_type];
    case CA_MONOP_FLOOR:   return ca_monop_floor[in_data_type];
    case CA_MONOP_ROUND:   return ca_monop_round[in_data_type];
    case CA_MONOP_RCP:     return ca_monop_rcp[in_data_type];

    case CA_MONOP_RAD:     return ca_monop_rad[in_data_type];
    case CA_MONOP_DEG:     return ca_monop_deg[in_data_type];
    case CA_MONOP_SQRT:    return ca_monop_sqrt[in_data_type];
    case CA_MONOP_EXP:     return ca_monop_exp[in_data_type];
    case CA_MONOP_EXP2:    return ca_monop_exp2[in_data_type];
    case CA_MONOP_EXP10:   return ca_monop_exp10[in_data_type];
    case CA_MONOP_LOG:     return ca_monop_log[in_data_type];
    case CA_MONOP_LOG10:   return ca_monop_log10[in_data_type];
    case CA_MONOP_LOG2:    return ca_monop_log2[in_data_type];
    case CA_MONOP_LOGB:    return ca_monop_logb[in_data_type];
    case CA_MONOP_SIN:     return ca_monop_sin[in_data_type];
    case CA_MONOP_COS:     return ca_monop_cos[in_data_type];
    case CA_MONOP_TAN:     return ca_monop_tan[in_data_type];
    case CA_MONOP_ASIN:    return ca_monop_asin[in_data_type];
    case CA_MONOP_ACOS:    return ca_monop_acos[in_data_type];
    case CA_MONOP_ATAN:    return ca_monop_atan[in_data_type];
    case CA_MONOP_SINH:    return ca_monop_sinh[in_data_type];
    case CA_MONOP_COSH:    return ca_monop_cosh[in_data_type];
    case CA_MONOP_TANH:    return ca_monop_tanh[in_data_type];
    case CA_MONOP_ASINH:   return ca_monop_asinh[in_data_type];
    case CA_MONOP_ACOSH:   return ca_monop_acosh[in_data_type];
    case CA_MONOP_ATANH:   return ca_monop_atanh[in_data_type];

    case CA_MONOP_BYTE_SWAP: return ca_monop_byte_swap[in_data_type];

    case CA_MONOP_IMAG_I:  return ca_monop_imag_i[in_data_type];

    case CA_MONOP_EXPM1:   return ca_monop_expm1 [in_data_type];
    case CA_MONOP_LOG1P:   return ca_monop_log1p [in_data_type];
    case CA_MONOP_RSQRT:   return ca_monop_rsqrt [in_data_type];
    case CA_MONOP_TRUNC:   return ca_monop_trunc [in_data_type];
    case CA_MONOP_SQUARE:  return ca_monop_square[in_data_type];

    case CA_MONOP_DEG_360: return ca_monop_deg_360[in_data_type];
    case CA_MONOP_DEG_180: return ca_monop_deg_180[in_data_type];
    case CA_MONOP_RAD_2PI: return ca_monop_rad_2pi[in_data_type];
    case CA_MONOP_RAD_PI:  return ca_monop_rad_pi [in_data_type];

    case CA_MONOP_SIGN:    return ca_monop_sign   [in_data_type];
    case CA_MONOP_ARG_I:   return ca_monop_arg_i  [in_data_type];

    default:
      /* Cast ops or unknown — caller handles cast specially.  */
      return NULL;
  }
}

/* ------------------------------------------------------------------- */
/* op category predicates                                               */
/* ------------------------------------------------------------------- */

/* True if op widens integer / boolean parent to CA_FLOAT64.  False for
   preserve ops and cast ops.  Widening ops are enumerated explicitly
   because they were added in multiple groups outside the original
   contiguous WIDENING_BEGIN..WIDENING_END range. */
static int
ca_monop_is_widening (uint16_t op_id)
{
  if ( op_id >= CA_MONOP_WIDENING_BEGIN && op_id < CA_MONOP_WIDENING_END ) {
    return 1;
  }
  /* Additional widening monfunc placed after IMAG_I. */
  if ( op_id == CA_MONOP_EXPM1 ||
       op_id == CA_MONOP_LOG1P ||
       op_id == CA_MONOP_RSQRT ) {
    return 1;
  }
  /* Angle normalisation widening monfunc. */
  if ( op_id == CA_MONOP_DEG_360 ||
       op_id == CA_MONOP_DEG_180 ||
       op_id == CA_MONOP_RAD_2PI ||
       op_id == CA_MONOP_RAD_PI  ) {
    return 1;
  }
  return 0;
}

int
ca_monop_is_cast (uint16_t op_id)
{
  return (op_id >= CA_MONOP_CAST_BASE &&
          op_id <  CA_MONOP_CAST_BASE + CA_NTYPE);
}

/* True if this op produces a view that can be written through (= the
   inverse operation is well-defined and used by store_into).  Cast
   and byte_swap qualify; pure functions like sqrt or sin do not. */
int
ca_monop_is_writable_view (uint16_t op_id)
{
  return ca_monop_is_cast(op_id) || op_id == CA_MONOP_BYTE_SWAP;
}

/* ------------------------------------------------------------------- */
/* output data_type rule                                                    */
/* ------------------------------------------------------------------- */

int8_t
ca_lazy_promote_monop (uint16_t op_id, int8_t in_data_type)
{
  if ( ca_monop_is_cast(op_id) ) {
    return (int8_t)(op_id - CA_MONOP_CAST_BASE);
  }
  if ( ca_monop_is_widening(op_id) ) {
    /* integer → f64, else preserve.  Boolean (CA_BOOLEAN = 1) is also
       widened to f64 (existing eager behaviour via wrap_readonly).  */
    if ( in_data_type < CA_FLOAT32 ) return CA_FLOAT64;
    return in_data_type;
  }
  /* preserve */
  return in_data_type;
}

/* ------------------------------------------------------------------- */
/* kernel input data_type rule (cast-before route)                      */
/* ------------------------------------------------------------------- */

/* Returns the data_type the kernel expects as input.  For widening ops,
   integer parent must be cast to f64 first because the kernel only has
   f64/cmplx slots.  For preserve ops, parent.data_type passes through.
   For cast ops, the kernel accepts whatever the upstream node provides
   (no further coercion).  If the returned data_type differs from the
   parent's real data_type, the caller inserts a CAMonOp(`:cast_<dt>`)
   node. */
int8_t
ca_monop_kernel_input_data_type (uint16_t op_id, int8_t parent_data_type)
{
  if ( ca_monop_is_cast(op_id) ) {
    return parent_data_type;
  }
  return ca_lazy_promote_monop(op_id, parent_data_type);
}
