/* ---------------------------------------------------------------------------
 *
 *  ca_for_buffer.h -- sweep WHOLE_BUFFER macro family (whole contig buffer
 *                    handed to author / third-party library)
 *
 *  PROPOSAL_L0_AUTHOR_SURFACE L0.2c (2026-06-11).  C-side counterpart of
 *  Ruby's `ca.attach! { |a| ... }` block: scope the ca_attach + ca_sync +
 *  ca_detach lifecycle to a block, hand the author a contig buffer ptr
 *  and element count, let the author do whatever (typically pass the
 *  ptr to a third-party library: FFTW, akima init, fitpack surf1, ...).
 *
 *  Two forms (Q8 = M1 alias-when-possible; non-contig source materialises
 *  into a transient buffer; writable form syncs back on exit):
 *
 *    CA_WITH_BUFFER(ca, T, ptr, n)
 *      Read-only access.  ptr : T const * pointing at native contig
 *      layout of `ca` (= ca->ptr alias when contig entity, scratch
 *      otherwise).  n : ca->elements.  No write-back on exit.
 *
 *    CA_WITH_BUFFER_WRITABLE(ca, T, ptr, n)
 *      Writable; same ptr/n semantics, plus ca_sync on block exit so
 *      author writes propagate back to the view's storage.
 *
 *  Author pattern:
 *
 *    double *ptr;
 *    ca_size_t n;
 *    CA_WITH_BUFFER_WRITABLE(ca, double, ptr, n) {
 *      fftw_execute_dft(plan, ptr, ptr);
 *    }
 *
 *  Constraints (same as CA_FOR_EACH_FIBER family):
 *    - `break;` from body exits cleanly (= outer for's advance clause
 *      runs ca_sync / ca_detach).
 *    - `return;` from body LEAKS the attach; restructure to break.
 *    - Macros are NOT statement-equivalent (= nested for); no trailing
 *      `else`.
 *    - For Ruby-exception-safe lifecycle (e.g. when calling Ruby code or
 *      anything that may raise from inside the body), use the function
 *      form `rb_ca_call_with_buffer` instead (= rb_ensure-protected).
 *
 *  --------------------------------------------------------------------------- */

#ifndef CA_FOR_BUFFER_H
#define CA_FOR_BUFFER_H

#include "carray.h"
#include "ca_sweep_engine.h"

/* ---------- macro forms ---------- */

/* Read-only: ca_attach (alias-when-possible) + author body + ca_detach. */
#define CA_WITH_BUFFER(_ca, T, _ptr, _n)                                  \
  for ( CArray *__cwv_ca = (CArray *)(_ca);                             \
        __cwv_ca;                                                       \
        ca_detach(__cwv_ca), __cwv_ca = NULL )                          \
    for ( int __cwv_once = (ca_attach(__cwv_ca),                        \
                            (_ptr) = (T *)__cwv_ca->ptr,                \
                            (_n)   = __cwv_ca->elements,                \
                            1);                                         \
          __cwv_once;                                                   \
          __cwv_once = 0 )

/* Writable: same as above + ca_sync on block exit. */
#define CA_WITH_BUFFER_WRITABLE(_ca, T, _ptr, _n)                         \
  for ( CArray *__cwvw_ca = (CArray *)(_ca);                            \
        __cwvw_ca;                                                      \
        ca_sync(__cwvw_ca), ca_detach(__cwvw_ca), __cwvw_ca = NULL )    \
    for ( int __cwvw_once = (ca_attach(__cwvw_ca),                      \
                             (_ptr) = (T *)__cwvw_ca->ptr,              \
                             (_n)   = __cwvw_ca->elements,              \
                             1);                                        \
          __cwvw_once;                                                  \
          __cwvw_once = 0 )

/* ---------- function form (rb_ensure-protected, AC8) ----------
 *
 * Use this when the body may raise a Ruby exception (= calling rb_funcall,
 * type-checking with rb_check_type, indirect Ruby code, etc.).  The
 * engine ca_attach's the view, runs body via rb_ensure, then guarantees
 * ca_sync (if writable) and ca_detach run before the exception
 * propagates.
 *
 *   body_fn(user_data, ptr, n_elements) -> may raise
 *
 * Returns whatever body_fn returns via its own propagation (= the
 * function itself returns Qnil since rb_ensure body must be VALUE).
 * For richer return semantics, box your result in user_data.
 */
typedef void (*ca_with_buffer_body_fn) (void *user_data, void *ptr,
                                      ca_size_t n_elements);

void rb_ca_call_with_buffer (VALUE r_ca, int writable,
                        ca_with_buffer_body_fn body, void *user_data);

#endif /* CA_FOR_BUFFER_H */
