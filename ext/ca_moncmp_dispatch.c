/* ---------------------------------------------------------------------------

  CAMonCmp dispatch table: routes a moncmp op id (`CA_MONCMP_*`) to the
  per-data_type kernel function pointer.

  Sibling of ca_obj_moncmp.c (the CAMonCmp view) and ca_bincmp_dispatch.c
  (binary counterpart).  Per-data_type kernel tables are declared in
  ca_moncmp_dispatch.h.

  Dispatched ops:
    CA_MONCMP_IS_NAN     -> ca_moncmp_is_nan     [in_dt]
    CA_MONCMP_IS_INF     -> ca_moncmp_is_inf     [in_dt]
    CA_MONCMP_IS_FINITE  -> ca_moncmp_is_finite  [in_dt]
    CA_MONCMP_IS_INVALID -> ca_moncmp_is_invalid [in_dt]
    CA_MONCMP_SIGNBIT    -> ca_moncmp_signbit    [in_dt]

  Float-flavoured ops (is_nan / is_inf / is_finite) accept integer inputs
  too: the per-data_type kernel const-folds the predicate per cell (and
  skips masked cells), so every data_type x op combination is valid.

---------------------------------------------------------------------------- */

#include "carray.h"
#include "ca_moncmp_dispatch.h"

ca_moncmp_func_t
ca_moncmp_kernel_lookup (uint16_t op_id, int8_t in_dt)
{
  switch (op_id) {
    case CA_MONCMP_IS_NAN:     return ca_moncmp_is_nan     [in_dt];
    case CA_MONCMP_IS_INF:     return ca_moncmp_is_inf     [in_dt];
    case CA_MONCMP_IS_FINITE:  return ca_moncmp_is_finite  [in_dt];
    case CA_MONCMP_IS_INVALID: return ca_moncmp_is_invalid [in_dt];
    case CA_MONCMP_SIGNBIT:    return ca_moncmp_signbit    [in_dt];
    default:                   return NULL;
  }
}
