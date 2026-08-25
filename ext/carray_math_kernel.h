/* ---------------------------------------------------------------------------

  ---------------------------------------------------------------------------

  PROPOSAL_CARRAY_H_REORG (H.3): the ext-author / math-backend surface.

  This header carries the element-wise kernel calling-convention typedefs
  (ca_monop_func_t / ca_binop_func_t / ...), the rb_ca_call_* drivers, and
  (via the per-family dispatch headers it pulls in) the per-data_type kernel
  dispatch tables (ca_monop_sin[CA_NTYPE], ...).

  It is included by carray.h (the public umbrella), so an external gem that
  does `#include "carray.h"` reaches the whole math-kernel surface with no
  hand-declared externs — e.g. a vector-math backend gem can swap
  `ca_monop_sin[CA_FLOAT64] = my_vector_sin;`.

  Ordering invariant: the func typedefs below MUST precede the dispatch-header
  includes (the tables are typed with them).

---------------------------------------------------------------------------- */

#ifndef CARRAY_MATH_KERNEL_H
#define CARRAY_MATH_KERNEL_H

#include "carray.h"

/* -------------------------------------------------------------------- */
/* Element-wise kernel calling-convention typedefs                      */
/* -------------------------------------------------------------------- */

typedef void (*ca_monop_func_t)(ca_size_t n, boolean8_t *m,
                                char *ptr1, ca_size_t i1,
                                char *ptr2, ca_size_t i2);
typedef void (*ca_binop_func_t)(ca_size_t n, boolean8_t *m,
                                char *ptr1, ca_size_t i1,
                                char *ptr2, ca_size_t i2,
                                char *ptr3, ca_size_t i3);
typedef void (*ca_triop_func_t)(ca_size_t n, boolean8_t *m,
                                char *ptr1, ca_size_t i1,
                                char *ptr2, ca_size_t i2,
                                char *ptr3, ca_size_t i3,
                                char *ptr4, ca_size_t i4);
typedef void (*ca_moncmp_func_t)(ca_size_t n, boolean8_t *m,
                                 char *ptr1, ca_size_t i1,
                                 boolean8_t *ptr2, ca_size_t i2);
/* IC.1 (PROPOSAL_IS_CLOSE_BINCMP_MIGRATION rev1): runtime `double tol`
   slot added uniformly.  Non-tolerance ops (eq/ne/lt/gt/le/ge/feq, etc.)
   ignore it via `(void) tol;`.  Tolerance ops (is_close, is_equiv) read
   it in the comparison expression.  See PROPOSAL §3.1 Option A. */
typedef void (*ca_bincmp_func_t)(ca_size_t n, boolean8_t *m,
                                 char *ptr1, ca_size_t b1, ca_size_t i1,
                                 char *ptr2, ca_size_t b2, ca_size_t i2,
                                 char *ptr3, ca_size_t b3, ca_size_t i3,
                                 double tol);

/* -------------------------------------------------------------------- */
/* Kernel drivers (attach / cast / mask / output-alloc are handled here, */
/* so a kernel receives a contig stride-resolved buffer + element count) */
/* -------------------------------------------------------------------- */

VALUE rb_ca_call_monop (VALUE self, ca_monop_func_t func[]);
VALUE rb_ca_call_monop_bang (VALUE self, ca_monop_func_t func[]);
/* Dtype-changing monop dispatch: out_data_types[in_data_type] gives the output
   data_type for each input data_type (= -1 if not implemented).  Used by
   monops with output: { numeric: ..., complex: ... } Hash form (e.g. abs
   cmplx128 -> f64).  Allocates output array of out_data_types[in_data_type]. */
VALUE rb_ca_call_monop_typed (VALUE self, ca_monop_func_t func[], int8_t out_data_types[]);
VALUE rb_ca_call_binop (VALUE self, VALUE other, ca_binop_func_t func[]);
VALUE rb_ca_call_binop_bang (VALUE self, VALUE other, ca_binop_func_t func[]);

/* Kleene three-valued mask fixup for boolean AND (is_or=0) / OR (is_or=1),
   applied by the generated `&`/`|` wrappers after rb_ca_call_binop.  No-op
   unless the output is boolean with a mask. */
VALUE ca_kleene_bool_fixup (VALUE vout, VALUE vself, VALUE vother, int is_or);

/* Triop driver: applies a 3-input / 1-output kernel.  Operand 1 = self,
   operands 2/3 are passed in.  Common data_type promotion via
   rb_ca_cast_self_or_other applied pairwise.  Scalar / array
   combinations (= 2^3 = 8 cases) are handled uniformly via
   ca_set_iterator(3, ...) which collapses scalar operands to stride 0.  */
VALUE rb_ca_call_triop (VALUE self, VALUE other2, VALUE other3,
                        ca_triop_func_t func[]);
VALUE rb_ca_call_triop_bang (VALUE self, VALUE other2, VALUE other3,
                             ca_triop_func_t func[]);
VALUE rb_ca_call_moncmp (VALUE self, ca_moncmp_func_t func[]);
VALUE rb_ca_call_bincmp (VALUE self, VALUE other, ca_bincmp_func_t func[], double tol);
void  ca_monop_not_implement(ca_size_t n, boolean8_t *m,
                                char *ptr1, ca_size_t i1,
                                char *ptr2, ca_size_t i2) __attribute__((noreturn));
void  ca_binop_not_implement(ca_size_t n, boolean8_t *m,
                                char *ptr1, ca_size_t i1,
                                char *ptr2, ca_size_t i2,
                                char *ptr3, ca_size_t i3) __attribute__((noreturn));
void  ca_triop_not_implement(ca_size_t n, boolean8_t *m,
                                char *ptr1, ca_size_t i1,
                                char *ptr2, ca_size_t i2,
                                char *ptr3, ca_size_t i3,
                                char *ptr4, ca_size_t i4) __attribute__((noreturn));
void  ca_moncmp_not_implement(ca_size_t n, boolean8_t *m,
                                 char *ptr1, ca_size_t i1,
                                 boolean8_t *ptr2, ca_size_t i2) __attribute__((noreturn));
void  ca_bincmp_not_implement(ca_size_t n, boolean8_t *m,
                                 char *ptr1, ca_size_t b1, ca_size_t i1,
                                 char *ptr2, ca_size_t b2, ca_size_t i2,
                                 char *ptr3, ca_size_t b3, ca_size_t i3,
                                 double tol) __attribute__((noreturn));
VALUE ca_math_call (VALUE mod, VALUE arg, ID id);

/* -------------------------------------------------------------------- */
/* Per-data_type kernel dispatch tables + op_id enums + lookup APIs      */
/* (must come after the func typedefs above — the tables are typed       */
/* with them).                                                           */
/* -------------------------------------------------------------------- */

#include "ca_monop_dispatch.h"
#include "ca_binop_dispatch.h"
#include "ca_bincmp_dispatch.h"
#include "ca_moncmp_dispatch.h"

#endif /* CARRAY_MATH_KERNEL_H */
