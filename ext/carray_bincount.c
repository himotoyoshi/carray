/* ---------------------------------------------------------------------------

  carray_bincount.c — dedicated bincount kernels (count-only + weighted)

  Tight per-element scatter into a pre-sized 1-D output buffer.  The
  inner loop reads labels in their native integer data type (no cast to
  int64), skips per-iteration bounds checking (caller validates label
  range), and emits the output data type directly.

  Output data type:
    - count-only:   UInt32 if length < 2^32, else UInt64.
    - weighted:     weights.data_type.

  Mask: a masked label is skipped; for the weighted kernel a masked
  weight is also skipped (its label contributes 0).

  Caller contract (= lib/carray/methods/bincount.rb's CArray#bincount):
    - self is integer data type.
    - length is the output size, pre-sized to max(length, label_max+1)
      with label_min >= 0 already verified.

  Public Ruby surface is CArray#bincount(weights:, length:) in
  lib/carray/methods/bincount.rb; this file provides the private
  kernels __bincount_count__(length) and
  __bincount_weighted__(weights, length).

  Design: devel/PROPOSAL_BINCOUNT_DEDICATED_KERNEL.md.

--------------------------------------------------------------------------- */

#include "carray.h"

/* Tight inner loop: 2 mask-aware variants × 8 label data types × 2 output
   data types = 32 specializations.  Generated via macro expansion.

   Layout:
     COUNT_KERNEL(LABEL_T, OUT_T)
       no-mask path: for i; out[label[i]]++
       label-mask path: for i; if (mlabel[i]) continue; out[label[i]]++
*/

#define COUNT_KERNEL(LABEL_T, OUT_T) do { \
  const LABEL_T *lp = (const LABEL_T *) cl->ptr; \
  OUT_T         *op = (OUT_T *)         co->ptr; \
  if ( mlabel ) { \
    for (i = 0; i < n; i++) { \
      if ( mlabel[i] ) continue; \
      op[(size_t) lp[i]]++; \
    } \
  } \
  else { \
    for (i = 0; i < n; i++) { \
      op[(size_t) lp[i]]++; \
    } \
  } \
} while (0)

#define COUNT_DISPATCH_LABEL(OUT_T) do { \
  switch ( cl->data_type ) { \
  case CA_INT8:    COUNT_KERNEL(int8_t,   OUT_T); break; \
  case CA_INT16:   COUNT_KERNEL(int16_t,  OUT_T); break; \
  case CA_INT32:   COUNT_KERNEL(int32_t,  OUT_T); break; \
  case CA_INT64:   COUNT_KERNEL(int64_t,  OUT_T); break; \
  case CA_UINT8:   COUNT_KERNEL(uint8_t,  OUT_T); break; \
  case CA_UINT16:  COUNT_KERNEL(uint16_t, OUT_T); break; \
  case CA_UINT32:  COUNT_KERNEL(uint32_t, OUT_T); break; \
  case CA_UINT64:  COUNT_KERNEL(uint64_t, OUT_T); break; \
  default: \
    rb_raise(rb_eCADataTypeError, \
             "bincount: integer label array required (got %d)", \
             cl->data_type); \
  } \
} while (0)

/* __bincount_count__(length) -- count occurrences of each label in
   self.  Allocates a zero-filled UInt32 (or UInt64 if length >= 2^32)
   output of size `length`, then runs the 8-way label dispatch. */
static VALUE
rb_ca_bincount_count_kernel (VALUE self, VALUE rlength)
{
  CArray   *cl, *co;
  VALUE     vout;
  ca_size_t i, n, length;
  ca_size_t shape_out[1];
  boolean8_t *mlabel;
  int out_type;

  TypedData_Get_Struct(self, CArray, &carray_data_type, cl);
  length = (ca_size_t) NUM2SIZET(rlength);
  if ( length < 0 ) {
    rb_raise(rb_eArgError, "bincount: length must be non-negative");
  }

  /* Output data type: UInt32 default; UInt64 if length doesn't fit. */
  out_type = (length > 0xFFFFFFFFLL) ? CA_UINT64 : CA_UINT32;
  shape_out[0] = length;
  vout = rb_carray_new(out_type, 1, shape_out, 0, NULL);
  TypedData_Get_Struct(vout, CArray, &carray_data_type, co);

  /* Zero-fill output (we own it, just allocated). */
  memset(co->ptr, 0, (size_t) co->bytes * (size_t) co->elements);

  if ( cl->elements == 0 ) {
    return vout;
  }

  ca_attach(cl);
  n      = cl->elements;
  mlabel = cl->mask ? (boolean8_t *) cl->mask->ptr : NULL;

  if ( out_type == CA_UINT32 ) {
    COUNT_DISPATCH_LABEL(uint32_t);
  }
  else {
    COUNT_DISPATCH_LABEL(uint64_t);
  }

  ca_detach(cl);

  return vout;
}

#undef COUNT_KERNEL
#undef COUNT_DISPATCH_LABEL

/* --------------------------------------------------------------- */

/* Weighted variant: output data type = weights data type.
   Inner: out[label[i]] += weight[i].
   Mask: skip if label[i] masked OR weight[i] masked. */

#define WEIGHTED_KERNEL(LABEL_T, W_T) do { \
  const LABEL_T *lp = (const LABEL_T *) cl->ptr; \
  const W_T     *wp = (const W_T *)     cw->ptr; \
  W_T           *op = (W_T *)           co->ptr; \
  if ( mlabel && mweight ) { \
    for (i = 0; i < n; i++) { \
      if ( mlabel[i] || mweight[i] ) continue; \
      op[(size_t) lp[i]] += wp[i]; \
    } \
  } \
  else if ( mlabel ) { \
    for (i = 0; i < n; i++) { \
      if ( mlabel[i] ) continue; \
      op[(size_t) lp[i]] += wp[i]; \
    } \
  } \
  else if ( mweight ) { \
    for (i = 0; i < n; i++) { \
      if ( mweight[i] ) continue; \
      op[(size_t) lp[i]] += wp[i]; \
    } \
  } \
  else { \
    for (i = 0; i < n; i++) { \
      op[(size_t) lp[i]] += wp[i]; \
    } \
  } \
} while (0)

#define WEIGHTED_DISPATCH_LABEL(W_T) do { \
  switch ( cl->data_type ) { \
  case CA_INT8:    WEIGHTED_KERNEL(int8_t,   W_T); break; \
  case CA_INT16:   WEIGHTED_KERNEL(int16_t,  W_T); break; \
  case CA_INT32:   WEIGHTED_KERNEL(int32_t,  W_T); break; \
  case CA_INT64:   WEIGHTED_KERNEL(int64_t,  W_T); break; \
  case CA_UINT8:   WEIGHTED_KERNEL(uint8_t,  W_T); break; \
  case CA_UINT16:  WEIGHTED_KERNEL(uint16_t, W_T); break; \
  case CA_UINT32:  WEIGHTED_KERNEL(uint32_t, W_T); break; \
  case CA_UINT64:  WEIGHTED_KERNEL(uint64_t, W_T); break; \
  default: \
    rb_raise(rb_eCADataTypeError, \
             "bincount: integer label array required (got %d)", \
             cl->data_type); \
  } \
} while (0)

/* __bincount_weighted__(weights, length) -- sum `weights[i]` into
   `out[label[i]]`.  Allocates a zero-filled output of weights.data_type
   and size `length`, then runs the 8 label × 10 weight dispatch
   (integer + float; the inner WEIGHTED_KERNEL macro branches over the
   four mask combinations). */
static VALUE
rb_ca_bincount_weighted_kernel (VALUE self, VALUE rweights, VALUE rlength)
{
  CArray   *cl, *cw, *co;
  VALUE     vout;
  ca_size_t i, n, length;
  ca_size_t shape_out[1];
  boolean8_t *mlabel, *mweight;
  int w_type;

  TypedData_Get_Struct(self, CArray, &carray_data_type, cl);
  TypedData_Get_Struct(rweights, CArray, &carray_data_type, cw);
  length = (ca_size_t) NUM2SIZET(rlength);
  if ( length < 0 ) {
    rb_raise(rb_eArgError, "bincount: length must be non-negative");
  }
  if ( cw->elements != cl->elements ) {
    rb_raise(rb_eArgError,
             "bincount: weights length (%lld) doesn't match labels length (%lld)",
             (long long) cw->elements, (long long) cl->elements);
  }

  w_type = cw->data_type;
  shape_out[0] = length;
  vout = rb_carray_new(w_type, 1, shape_out, 0, NULL);
  TypedData_Get_Struct(vout, CArray, &carray_data_type, co);

  memset(co->ptr, 0, (size_t) co->bytes * (size_t) co->elements);

  if ( cl->elements == 0 ) {
    return vout;
  }

  ca_attach_n(2, cl, cw);
  n       = cl->elements;
  mlabel  = cl->mask ? (boolean8_t *) cl->mask->ptr : NULL;
  mweight = cw->mask ? (boolean8_t *) cw->mask->ptr : NULL;

  switch ( w_type ) {
  case CA_FLOAT64: WEIGHTED_DISPATCH_LABEL(double);   break;
  case CA_FLOAT32: WEIGHTED_DISPATCH_LABEL(float);    break;
  case CA_INT64:   WEIGHTED_DISPATCH_LABEL(int64_t);  break;
  case CA_INT32:   WEIGHTED_DISPATCH_LABEL(int32_t);  break;
  case CA_INT16:   WEIGHTED_DISPATCH_LABEL(int16_t);  break;
  case CA_INT8:    WEIGHTED_DISPATCH_LABEL(int8_t);   break;
  case CA_UINT64:  WEIGHTED_DISPATCH_LABEL(uint64_t); break;
  case CA_UINT32:  WEIGHTED_DISPATCH_LABEL(uint32_t); break;
  case CA_UINT16:  WEIGHTED_DISPATCH_LABEL(uint16_t); break;
  case CA_UINT8:   WEIGHTED_DISPATCH_LABEL(uint8_t);  break;
  default:
    ca_detach_n(2, cl, cw);
    rb_raise(rb_eCADataTypeError,
             "bincount: weights must be numeric (got %d)", w_type);
  }

  ca_detach_n(2, cl, cw);

  return vout;
}

#undef WEIGHTED_KERNEL
#undef WEIGHTED_DISPATCH_LABEL

/* --------------------------------------------------------------- */

void
Init_carray_bincount (void)
{
  rb_define_private_method(rb_cCArray, "__bincount_count__",
                           rb_ca_bincount_count_kernel, 1);
  rb_define_private_method(rb_cCArray, "__bincount_weighted__",
                           rb_ca_bincount_weighted_kernel, 2);
}
