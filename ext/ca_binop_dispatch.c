/* ---------------------------------------------------------------------------

  CABinOp dispatch: routes a binop op id (`CA_BINOP_*`) to the per-
  data_type kernel, computes the input promotion + output data_type
  rule, and tags ops that can trap on integer zero divisor.

  Sibling of ca_obj_binop.c (the CABinOp view), ca_bincmp_dispatch.c
  (comparison binop family), and ca_monop_dispatch.c (unary
  counterpart).  Per-data_type kernel tables are declared in
  ca_binop_dispatch.h.

  The binop kernels assume both operands already share data_type.  The
  CABinOp builder inserts CAMonOp(`:cast_<common>`) nodes so both
  operands arrive at the common type.  Two ops break the uniform rule:

    QUO    -- only has a CA_OBJECT kernel; both operands promoted to
              CA_OBJECT regardless of input data types
    IPOWER -- heterogeneous (left: float/cmplx preserved, right: int64);
              output preserves left data type.  See ca_op_ipower.c.

---------------------------------------------------------------------------- */

#include "carray.h"
#include "ca_binop_dispatch.h"

/* ------------------------------------------------------------------- */
/* vv kernel lookup                                                     */
/* ------------------------------------------------------------------- */

ca_binop_func_t
ca_binop_kernel_lookup_vv (uint16_t op_id, int8_t common_dt)
{
  switch (op_id) {
    case CA_BINOP_ADD:        return ca_binop_add        [common_dt];
    case CA_BINOP_SUB:        return ca_binop_sub        [common_dt];
    case CA_BINOP_MUL:        return ca_binop_mul        [common_dt];
    case CA_BINOP_DIV:        return ca_binop_div        [common_dt];
    case CA_BINOP_POW:        return ca_binop_power      [common_dt];
    case CA_BINOP_BIT_AND:    return ca_binop_bit_and_i  [common_dt];
    case CA_BINOP_BIT_OR:     return ca_binop_bit_or_i   [common_dt];
    case CA_BINOP_BIT_XOR:    return ca_binop_bit_xor_i  [common_dt];
    case CA_BINOP_BIT_LSHIFT: return ca_binop_bit_lshift [common_dt];
    case CA_BINOP_BIT_RSHIFT: return ca_binop_bit_rshift [common_dt];
    case CA_BINOP_MOD:        return ca_binop_mod        [common_dt];
    case CA_BINOP_QUO:        return ca_binop_quo_i      [common_dt];
    case CA_BINOP_RCP_MUL:    return ca_binop_rcp_mul    [common_dt];
    case CA_BINOP_IPOWER:     return ca_binop_ipower     [common_dt];
    case CA_BINOP_COPYSIGN:   return ca_binop_copysign   [common_dt];
    case CA_BINOP_LOGADDEXP:  return ca_binop_logaddexp  [common_dt];
    case CA_BINOP_NEXTAFTER:  return ca_binop_nextafter  [common_dt];
    case CA_BINOP_FMOD:       return ca_binop_fmod       [common_dt];
    case CA_BINOP_ATAN2:      return ca_binop_atan2      [common_dt];
    case CA_BINOP_HYPOT:      return ca_binop_hypot      [common_dt];
    case CA_BINOP_PMAX:       return ca_binop_pmax       [common_dt];
    case CA_BINOP_PMIN:       return ca_binop_pmin       [common_dt];
    case CA_BINOP_MAXIMUM:    return ca_binop_maximum    [common_dt];
    case CA_BINOP_MINIMUM:    return ca_binop_minimum    [common_dt];
    case CA_BINOP_AND:        return ca_binop_and        [common_dt];
    case CA_BINOP_OR:         return ca_binop_or         [common_dt];
    case CA_BINOP_XOR:        return ca_binop_xor        [common_dt];
    case CA_BINOP_REMINDER:   return ca_binop_reminder   [common_dt];
    default:                  return NULL;
  }
}

/* ------------------------------------------------------------------- */
/* output data_type rule                                                    */
/* ------------------------------------------------------------------- */

/* Returns the output data_type for op_id applied to operands of types
   (l_dt, r_dt).  For most ops this is ca_promote_type(l_dt, r_dt) (=
   the common promoted type).  Broadcast / scalar wrap are handled by
   the caller, not here.                                              */
int8_t
ca_lazy_promote_binop (uint16_t op_id, int8_t l_dt, int8_t r_dt)
{
  /* QUO has only a CA_OBJECT kernel: force both operands to CA_OBJECT
     so the rb_funcall dispatch path runs (matches eager behaviour). */
  if ( op_id == CA_BINOP_QUO ) return CA_OBJECT;
  /* IPOWER preserves the left data_type as output (right is coerced
     to int64 separately by ca_binop_kernel_input_data_types below). */
  if ( op_id == CA_BINOP_IPOWER ) return l_dt;
  return (int8_t) ca_promote_type(l_dt, r_dt);
}

void
ca_binop_kernel_input_data_types (uint16_t op_id, int8_t l_dt, int8_t r_dt,
                              int8_t *out_l_in_dt, int8_t *out_r_in_dt)
{
  /* IPOWER: heterogeneous (left preserves, right -> int64).  Skip the
     cast-before common-data_type unification.                              */
  if ( op_id == CA_BINOP_IPOWER ) {
    if ( out_l_in_dt ) *out_l_in_dt = l_dt;
    if ( out_r_in_dt ) *out_r_in_dt = CA_INT64;
    (void) r_dt;
    return;
  }
  int8_t common = ca_lazy_promote_binop(op_id, l_dt, r_dt);
  if ( out_l_in_dt ) *out_l_in_dt = common;
  if ( out_r_in_dt ) *out_r_in_dt = common;
}

/* ------------------------------------------------------------------- */
/* trapping-op predicate                                                */
/* ------------------------------------------------------------------- */

int
ca_binop_is_trapping (uint16_t op_id, int8_t common_dt)
{
  /* Integer DIV / MOD / QUO / FMOD can SIGFPE on a zero divisor.  Float
     DIV returns NaN/Inf and does NOT trap, so it is not classified
     trapping.                                                          */
  int is_integer = ( common_dt >= CA_INT8 && common_dt <= CA_UINT64 );
  if ( ! is_integer ) return 0;

  switch (op_id) {
    case CA_BINOP_DIV:
    case CA_BINOP_MOD:
    case CA_BINOP_QUO:
    case CA_BINOP_FMOD:
    case CA_BINOP_REMINDER:
      return 1;
    default:
      return 0;
  }
}
