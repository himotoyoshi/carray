/* ---------------------------------------------------------------------------

  CATriOp dispatch: routes a triop op id (`CA_TRIOP_*`) to the per-
  data_type kernel and computes the 3-way promotion.

  Sibling of ca_binop_dispatch.c (binary counterpart) and
  ca_obj_triop.c (the CATriOp view).  Per-data_type kernel tables
  are declared in ca_triop_dispatch.h.

  All 3 operands are cast to the common promoted data_type before the
  kernel runs (cast-before invariant, same as CABinOp).  Output data_type
  is the common promoted data_type.

---------------------------------------------------------------------------- */

#include "carray.h"
#include "ca_triop_dispatch.h"

/* ------------------------------------------------------------------- */
/* vvv kernel lookup                                                    */
/* ------------------------------------------------------------------- */

ca_triop_func_t
ca_triop_kernel_lookup_vvv (uint16_t op_id, int8_t common_dt)
{
  switch (op_id) {
    case CA_TRIOP_FMA:  return ca_triop_fma  [common_dt];
    case CA_TRIOP_FMS:  return ca_triop_fms  [common_dt];
    case CA_TRIOP_CLIP: return ca_triop_clip [common_dt];
    default:            return NULL;
  }
}

/* ------------------------------------------------------------------- */
/* 3-way promotion                                                      */
/* ------------------------------------------------------------------- */

int8_t
ca_lazy_promote_triop (uint16_t op_id, int8_t dt1, int8_t dt2, int8_t dt3)
{
  (void) op_id;   /* uniform 3-way promote across all currently-defined triops */
  return (int8_t) ca_promote_type(ca_promote_type(dt1, dt2), dt3);
}

void
ca_triop_kernel_input_data_types (uint16_t op_id,
                                  int8_t dt1, int8_t dt2, int8_t dt3,
                                  int8_t *out_dt1, int8_t *out_dt2,
                                  int8_t *out_dt3)
{
  int8_t common = ca_lazy_promote_triop(op_id, dt1, dt2, dt3);
  if ( out_dt1 ) *out_dt1 = common;
  if ( out_dt2 ) *out_dt2 = common;
  if ( out_dt3 ) *out_dt3 = common;
}
