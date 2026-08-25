/* ---------------------------------------------------------------------------

  Per-data_type kernel table for the CAMonOp `byte_swap` op
  (`CA_MONOP_BYTE_SWAP`): reverses the byte order of each cell in place
  after copying src to dst.  byte_swap is data_type-preserving
  (output.bytes == input.bytes).

  Sibling of ca_monop_dispatch.c (looks up `ca_monop_byte_swap[in_dt]`)
  and ca_obj_byte_swap.c (the eager CAByteSwap view + `ca_swap_bytes`
  primitive that this file delegates to for the actual reversal).

  Dispatch by data_type:
    1-byte cells (boolean / int8 / uint8) -> 1byte kernel (memcpy only)
    fixed-width numeric (int16..float64)  -> nbyte kernel (memcpy + reverse)
    CA_CMPLX64 / CA_CMPLX128              -> cmplx kernel (half-independent)
    CA_FIXLEN / CA_FLOAT128 / CA_CMPLX256 -> not_impl trampoline
    CA_OBJECT                             -> not_impl trampoline

  CMPLX cells are byte-swapped as two independent halves (real / imag),
  not as one wide cell — this matches the eager `ca_byte_swap_buffer`
  contract in ca_obj_byte_swap.c.

  CA_FIXLEN is excluded here: bytes-per-cell is parent-specific and
  data_class field-recursion requires a Ruby callback path; the CAByteSwap
  view handles those.  CA_OBJECT byte-swap on VALUE refs is meaningless.

---------------------------------------------------------------------------- */

#include "carray.h"
#include "ca_monop_dispatch.h"
#include <string.h>

/* Reverses `bytes` bytes per cell across `elements` cells in place.
 * Defined in ca_obj_byte_swap.c. */
extern void ca_swap_bytes (char *ptr, ca_size_t bytes, ca_size_t elements);

/* ------------------------------------------------------------------- */
/* per-data_type kernels                                                */
/* ------------------------------------------------------------------- */

/* 1-byte cell: byte-swap is a no-op on a single byte.  The kernel just
   copies src to dst when they differ; included so boolean / int8 / uint8
   share the dispatch shape with the wider kernels.  */
#define DEFINE_BYTE_SWAP_1BYTE(name) \
  static void \
  name (ca_size_t n, boolean8_t *m, \
        char *ptr1, ca_size_t i1, char *ptr2, ca_size_t i2) \
  { \
    ca_size_t k; \
    if ( m ) { \
      for (k = 0; k < n; k++) { \
        if (!m[k]) { \
          *(ptr2 + k*i2) = *(ptr1 + k*i1); \
        } \
      } \
    } else { \
      for (k = 0; k < n; k++) { \
        *(ptr2 + k*i2) = *(ptr1 + k*i1); \
      } \
    } \
  }

/* N-byte cell: copy src to dst (if different) then reverse the N
   bytes within the cell.  */
#define DEFINE_BYTE_SWAP_NBYTE(name, BYTES) \
  static void \
  name (ca_size_t n, boolean8_t *m, \
        char *ptr1, ca_size_t i1, char *ptr2, ca_size_t i2) \
  { \
    ca_size_t k; \
    if ( m ) { \
      for (k = 0; k < n; k++) { \
        if (!m[k]) { \
          char *p1 = ptr1 + k*i1*(BYTES); \
          char *p2 = ptr2 + k*i2*(BYTES); \
          if (p2 != p1) memcpy(p2, p1, (BYTES)); \
          ca_swap_bytes(p2, (BYTES), 1); \
        } \
      } \
    } else { \
      for (k = 0; k < n; k++) { \
        char *p1 = ptr1 + k*i1*(BYTES); \
        char *p2 = ptr2 + k*i2*(BYTES); \
        if (p2 != p1) memcpy(p2, p1, (BYTES)); \
        ca_swap_bytes(p2, (BYTES), 1); \
      } \
    } \
  }

/* CMPLX cell (TOTAL bytes = 2 * HALF): swap the real half and the imag
   half independently rather than reversing the whole TOTAL-byte cell. */
#define DEFINE_BYTE_SWAP_CMPLX(name, TOTAL, HALF) \
  static void \
  name (ca_size_t n, boolean8_t *m, \
        char *ptr1, ca_size_t i1, char *ptr2, ca_size_t i2) \
  { \
    ca_size_t k; \
    if ( m ) { \
      for (k = 0; k < n; k++) { \
        if (!m[k]) { \
          char *p1 = ptr1 + k*i1*(TOTAL); \
          char *p2 = ptr2 + k*i2*(TOTAL); \
          if (p2 != p1) memcpy(p2, p1, (TOTAL)); \
          ca_swap_bytes(p2, (HALF), 2); \
        } \
      } \
    } else { \
      for (k = 0; k < n; k++) { \
        char *p1 = ptr1 + k*i1*(TOTAL); \
        char *p2 = ptr2 + k*i2*(TOTAL); \
        if (p2 != p1) memcpy(p2, p1, (TOTAL)); \
        ca_swap_bytes(p2, (HALF), 2); \
      } \
    } \
  }

DEFINE_BYTE_SWAP_1BYTE(ca_monop_byte_swap_boolean_t)
DEFINE_BYTE_SWAP_1BYTE(ca_monop_byte_swap_int8_t)
DEFINE_BYTE_SWAP_1BYTE(ca_monop_byte_swap_uint8_t)

DEFINE_BYTE_SWAP_NBYTE(ca_monop_byte_swap_int16_t,  2)
DEFINE_BYTE_SWAP_NBYTE(ca_monop_byte_swap_uint16_t, 2)

DEFINE_BYTE_SWAP_NBYTE(ca_monop_byte_swap_int32_t,  4)
DEFINE_BYTE_SWAP_NBYTE(ca_monop_byte_swap_uint32_t, 4)

DEFINE_BYTE_SWAP_NBYTE(ca_monop_byte_swap_int64_t,  8)
DEFINE_BYTE_SWAP_NBYTE(ca_monop_byte_swap_uint64_t, 8)

DEFINE_BYTE_SWAP_NBYTE(ca_monop_byte_swap_float32_t, 4)
DEFINE_BYTE_SWAP_NBYTE(ca_monop_byte_swap_float64_t, 8)

DEFINE_BYTE_SWAP_CMPLX(ca_monop_byte_swap_cmplx64_t,  8, 4)
DEFINE_BYTE_SWAP_CMPLX(ca_monop_byte_swap_cmplx128_t, 16, 8)

/* Trampoline installed at unsupported data_type slots in the dispatch
   table below.  Raises rather than returning so the caller never sees
   silent no-op behaviour on an out-of-scope data_type.  */
NORETURN(static void ca_monop_byte_swap_not_impl (ca_size_t n, boolean8_t *m,
                                                  char *ptr1, ca_size_t i1,
                                                  char *ptr2, ca_size_t i2));
static void
ca_monop_byte_swap_not_impl (ca_size_t n, boolean8_t *m,
                             char *ptr1, ca_size_t i1,
                             char *ptr2, ca_size_t i2)
{
  (void) n; (void) m; (void) ptr1; (void) i1; (void) ptr2; (void) i2;
  rb_raise(rb_eRuntimeError,
           "CAMonOp(byte_swap): not implemented for this data_type");
}

/* ------------------------------------------------------------------- */
/* dispatch table                                                       */
/* ------------------------------------------------------------------- */

ca_monop_func_t
ca_monop_byte_swap[CA_NTYPE] = {
  /* CA_FIXLEN   */ ca_monop_byte_swap_not_impl,
  /* CA_BOOLEAN  */ ca_monop_byte_swap_boolean_t,
  /* CA_INT8     */ ca_monop_byte_swap_int8_t,
  /* CA_UINT8    */ ca_monop_byte_swap_uint8_t,
  /* CA_INT16    */ ca_monop_byte_swap_int16_t,
  /* CA_UINT16   */ ca_monop_byte_swap_uint16_t,
  /* CA_INT32    */ ca_monop_byte_swap_int32_t,
  /* CA_UINT32   */ ca_monop_byte_swap_uint32_t,
  /* CA_INT64    */ ca_monop_byte_swap_int64_t,
  /* CA_UINT64   */ ca_monop_byte_swap_uint64_t,
  /* CA_FLOAT32  */ ca_monop_byte_swap_float32_t,
  /* CA_FLOAT64  */ ca_monop_byte_swap_float64_t,
  /* CA_FLOAT128 */ ca_monop_byte_swap_not_impl,  /* reserved hole */
  /* CA_CMPLX64  */ ca_monop_byte_swap_cmplx64_t,
  /* CA_CMPLX128 */ ca_monop_byte_swap_cmplx128_t,
  /* CA_CMPLX256 */ ca_monop_byte_swap_not_impl,  /* reserved hole */
  /* CA_OBJECT   */ ca_monop_byte_swap_not_impl,
};
