/* ---------------------------------------------------------------------------

  CABinCmp dispatch: routes a bincmp op id (`CA_BINCMP_*`) to the
  per-data_type kernel, and computes the input promotion type for the
  two operands.

  Sibling of ca_obj_bincmp.c (the CABinCmp view), ca_moncmp_dispatch.c
  (unary counterpart), and ca_binop_dispatch.c (arithmetic binop
  family).  Per-data_type kernel tables are declared in
  ca_bincmp_dispatch.h.

  The bincmp kernels assume both operands already share data_type.  The
  CABinCmp builder inserts a CAMonOp(`:cast_<common>`) before reaching
  CABinCmp so both operands arrive at the common (promoted) type.  Use
  `ca_bincmp_kernel_input_data_types` to obtain that common type.

  Dispatched ops (all kernels return CArray<:bool>):
    CA_BINCMP_LT       -> ca_bincmp_lt       [dt]   ( <  )
    CA_BINCMP_GT       -> ca_bincmp_gt       [dt]   ( >  )
    CA_BINCMP_LE       -> ca_bincmp_le       [dt]   ( <= )
    CA_BINCMP_GE       -> ca_bincmp_ge       [dt]   ( >= )
    CA_BINCMP_EQ       -> ca_bincmp_eq       [dt]   ( == )
    CA_BINCMP_NE       -> ca_bincmp_ne       [dt]   ( != )
    CA_BINCMP_FEQ      -> ca_bincmp_feq      [dt]   (float equality with
                                                     a built-in tolerance)
    CA_BINCMP_IS_CLOSE -> ca_bincmp_is_close [dt]   (|a - b| <= tol)
    CA_BINCMP_IS_EQUIV -> ca_bincmp_is_equiv [dt]   (is_close with
                                                     relative tolerance)

---------------------------------------------------------------------------- */

#include "carray.h"
#include "ca_bincmp_dispatch.h"

/* ------------------------------------------------------------------- */
/* bincmp kernel lookup                                                 */
/* ------------------------------------------------------------------- */

ca_bincmp_func_t
ca_bincmp_kernel_lookup (uint16_t op_id, int8_t common_dt)
{
  switch (op_id) {
    case CA_BINCMP_LT:       return ca_bincmp_lt       [common_dt];
    case CA_BINCMP_GT:       return ca_bincmp_gt       [common_dt];
    case CA_BINCMP_LE:       return ca_bincmp_le       [common_dt];
    case CA_BINCMP_GE:       return ca_bincmp_ge       [common_dt];
    case CA_BINCMP_EQ:       return ca_bincmp_eq       [common_dt];
    case CA_BINCMP_NE:       return ca_bincmp_ne       [common_dt];
    case CA_BINCMP_FEQ:      return ca_bincmp_feq      [common_dt];
    case CA_BINCMP_IS_CLOSE: return ca_bincmp_is_close [common_dt];
    case CA_BINCMP_IS_EQUIV: return ca_bincmp_is_equiv [common_dt];
    default:                 return NULL;
  }
}

/* ------------------------------------------------------------------- */
/* Input promotion: both operands cast to common data_type before the   */
/* kernel runs.  bincmp output is always boolean and independent of    */
/* operand types.                                                       */
/* ------------------------------------------------------------------- */

int8_t
ca_lazy_bincmp_promote (uint16_t op_id, int8_t l_dt, int8_t r_dt)
{
  (void) op_id;
  return (int8_t) ca_promote_type(l_dt, r_dt);
}

void
ca_bincmp_kernel_input_data_types (uint16_t op_id, int8_t l_dt, int8_t r_dt,
                                int8_t *out_l_in_dt, int8_t *out_r_in_dt)
{
  int8_t common = ca_lazy_bincmp_promote(op_id, l_dt, r_dt);
  if ( out_l_in_dt ) *out_l_in_dt = common;
  if ( out_r_in_dt ) *out_r_in_dt = common;
}
