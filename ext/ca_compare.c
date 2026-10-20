/* ---------------------------------------------------------------------------

  Shared element comparators by data_type (see ca_compare.h).  The per-type
  comparators take the (const void *, const void *) prototype directly, so
  the dispatch table needs no function-pointer casts.

  Internal C API (no Ruby surface).  Indexed by data_type id via
  `ca_elem_cmp[data_type]`.  Callers include sort_addr_cmp
  (carray_sort.c) and the comparator-based ca_quickselect_bytes path
  (carray_partition.c).

--------------------------------------------------------------------------- */

#include "ruby.h"
#include "carray.h"
#include "ca_compare.h"
#include "carray_internal.h"   /* CA_FLOAT_ORDER_CMP, ca_obj_order_cmp */
#include <math.h>

#define DEFINE_ELEM_CMP(type)                          \
static int                                             \
elem_cmp_## type (const void *va, const void *vb)      \
{                                                      \
  const CA_U(type) *a = (const CA_U(type) *) va;       \
  const CA_U(type) *b = (const CA_U(type) *) vb;       \
  if ( *a > *b ) return  1;                            \
  if ( *a < *b ) return -1;                            \
  return 0;                                            \
}

/* Float order: NaN after every number (CA_FLOAT_ORDER_CMP). */
#define DEFINE_ELEM_CMP_FLOAT(type)                    \
static int                                             \
elem_cmp_## type (const void *va, const void *vb)      \
{                                                      \
  const type a = *(const CA_U(type) *) va;             \
  const type b = *(const CA_U(type) *) vb;             \
  return CA_FLOAT_ORDER_CMP(a, b);                     \
}

DEFINE_ELEM_CMP(boolean8_t)
DEFINE_ELEM_CMP(int8_t)
DEFINE_ELEM_CMP(uint8_t)
DEFINE_ELEM_CMP(int16_t)
DEFINE_ELEM_CMP(uint16_t)
DEFINE_ELEM_CMP(int32_t)
DEFINE_ELEM_CMP(uint32_t)
DEFINE_ELEM_CMP(int64_t)
DEFINE_ELEM_CMP(uint64_t)
DEFINE_ELEM_CMP_FLOAT(float32_t)
DEFINE_ELEM_CMP_FLOAT(float64_t)

/* CA_OBJECT: the object order (ca_obj_order_cmp). */
static int
elem_cmp_VALUE (const void *va, const void *vb)
{
  return ca_obj_order_cmp(*(const VALUE *) va, *(const VALUE *) vb);
}

/* FIXLEN / retired / otherwise unorderable data_types: callers must handle
   these themselves; reaching the table for them is a bug. */
static int
elem_cmp_unsupported (const void *va, const void *vb)
{
  (void) va; (void) vb;
  rb_raise(rb_eNotImpError,
           "element comparison is not implemented for the data type");
}

ca_cmp_func
ca_elem_cmp[CA_NTYPE] = {
  elem_cmp_unsupported,  /* CA_FIXLEN -- caller compares packed blobs itself */
  elem_cmp_boolean8_t,
  elem_cmp_int8_t,
  elem_cmp_uint8_t,
  elem_cmp_int16_t,
  elem_cmp_uint16_t,
  elem_cmp_int32_t,
  elem_cmp_uint32_t,
  elem_cmp_int64_t,
  elem_cmp_uint64_t,
  elem_cmp_float32_t,
  elem_cmp_float64_t,
  elem_cmp_unsupported,  /* float128_t -- not supported */
  elem_cmp_unsupported,
  elem_cmp_unsupported,
  elem_cmp_unsupported,  /* cmplx256_t -- not supported */
  elem_cmp_VALUE,
};
