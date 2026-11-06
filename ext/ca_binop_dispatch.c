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
#include "carray_internal.h"   /* CA_SCALAR_FOR_* */

/* ------------------------------------------------------------------- */
/* vv kernel lookup                                                     */
/* ------------------------------------------------------------------- */

/* The kernel table of each op id.  The eager operators hold the tables
   themselves; ca_binop_op_id_of_table maps one back to its op id, so that
   both ask ca_op_raises_on_cell the same question. */
static ca_binop_func_t * const ca_binop_tables[CA_BINOP_COUNT] = {
  [CA_BINOP_ADD]       = ca_binop_add,
  [CA_BINOP_SUB]       = ca_binop_sub,
  [CA_BINOP_MUL]       = ca_binop_mul,
  [CA_BINOP_DIV]       = ca_binop_div,
  [CA_BINOP_POW]       = ca_binop_power,
  [CA_BINOP_BIT_AND]   = ca_binop_bit_and_i,
  [CA_BINOP_BIT_OR]    = ca_binop_bit_or_i,
  [CA_BINOP_BIT_XOR]   = ca_binop_bit_xor_i,
  [CA_BINOP_BIT_LSHIFT]= ca_binop_bit_lshift,
  [CA_BINOP_BIT_RSHIFT]= ca_binop_bit_rshift,
  [CA_BINOP_MOD]       = ca_binop_mod,
  [CA_BINOP_QUO]       = ca_binop_quo_i,
  [CA_BINOP_RCP_MUL]   = ca_binop_rcp_mul,
  [CA_BINOP_IPOWER]    = ca_binop_ipower,
  [CA_BINOP_COPYSIGN]  = ca_binop_copysign,
  [CA_BINOP_LOGADDEXP] = ca_binop_logaddexp,
  [CA_BINOP_NEXTAFTER] = ca_binop_nextafter,
  [CA_BINOP_FMOD]      = ca_binop_fmod,
  [CA_BINOP_ATAN2]     = ca_binop_atan2,
  [CA_BINOP_HYPOT]     = ca_binop_hypot,
  [CA_BINOP_PMAX]      = ca_binop_pmax,
  [CA_BINOP_PMIN]      = ca_binop_pmin,
  [CA_BINOP_MAXIMUM]   = ca_binop_maximum,
  [CA_BINOP_MINIMUM]   = ca_binop_minimum,
  [CA_BINOP_AND]       = ca_binop_and,
  [CA_BINOP_OR]        = ca_binop_or,
  [CA_BINOP_XOR]       = ca_binop_xor,
};

ca_binop_func_t
ca_binop_kernel_lookup_vv (uint16_t op_id, int8_t common_dt)
{
  if ( op_id >= CA_BINOP_COUNT || ! ca_binop_tables[op_id] ) return NULL;
  return ca_binop_tables[op_id][common_dt];
}

/* The op id whose kernel table is `table`, or -1 for a table no op id
   names. */
int
ca_binop_op_id_of_table (ca_binop_func_t table[])
{
  int op_id;
  for ( op_id = 0; op_id < CA_BINOP_COUNT; op_id++ ) {
    if ( ca_binop_tables[op_id] == table ) return op_id;
  }
  return -1;
}

/* pmax, pmin, maximum and minimum pick one operand by order. */
int
ca_binop_picks_by_order (int op_id)
{
  return op_id == CA_BINOP_PMAX    || op_id == CA_BINOP_PMIN ||
         op_id == CA_BINOP_MAXIMUM || op_id == CA_BINOP_MINIMUM;
}

/* + - * & | ^ give an integer array the same answer modulo 2 ** bits
   whether a scalar operand is cut to the array's type first or not. */
int
ca_binop_is_ring (int op_id)
{
  return op_id == CA_BINOP_ADD     || op_id == CA_BINOP_SUB    ||
         op_id == CA_BINOP_MUL     || op_id == CA_BINOP_BIT_AND ||
         op_id == CA_BINOP_BIT_OR  || op_id == CA_BINOP_BIT_XOR;
}

/* How a scalar operand beside an integer array is taken by op_id
   (ca_scalar_operand_for_op). */
int
ca_binop_scalar_operand_mode (int op_id)
{
  if ( ca_binop_is_ring(op_id) ) {
    return CA_SCALAR_FOR_RING;
  }
  if ( op_id == CA_BINOP_PMIN || op_id == CA_BINOP_MINIMUM ) {
    return CA_SCALAR_FOR_MIN;
  }
  if ( op_id == CA_BINOP_PMAX || op_id == CA_BINOP_MAXIMUM ) {
    return CA_SCALAR_FOR_MAX;
  }
  return CA_SCALAR_FOR_ORDER;
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

