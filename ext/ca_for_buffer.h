/* ---------------------------------------------------------------------------
 *
 *  ca_for_buffer.h -- whole contig buffer handed to author / third-party
 *                     library
 *
 *  C-side counterpart of Ruby's `ca.attach! { |a| ... }` block: the
 *  attach / sync / detach lifecycle is scoped to a body function, which
 *  receives a contig buffer ptr and element count and may do whatever
 *  (typically pass the ptr to a third-party library: FFTW, akima init,
 *  fitpack surf1, ...).
 *
 *  The buffer aliases ca->ptr when the array is a contig entity and is a
 *  materialised scratch otherwise.  A writable call syncs the buffer back
 *  to the array's storage when the body returns.
 *
 *  The body may raise.  The view is closed however the body is left: a
 *  writable view is synced first, so what the body wrote before raising
 *  reaches the view's storage, and the view is detached even if that sync
 *  raises.  The body's exception is the one that propagates.
 *
 *  Author pattern:
 *
 *    static void
 *    fft_body (void *user_data, void *ptr, ca_size_t n)
 *    {
 *      fftw_plan plan = (fftw_plan) user_data;
 *      fftw_execute_dft(plan, ptr, ptr);
 *    }
 *
 *    rb_ca_call_with_buffer(rca, 1, fft_body, plan);
 *
 *  --------------------------------------------------------------------------- */

#ifndef CA_FOR_BUFFER_H
#define CA_FOR_BUFFER_H

#include "carray.h"
#include "ca_sweep_engine.h"

/*   body_fn(user_data, ptr, n_elements) -> may raise
 *
 * Returns nothing; box a result in user_data. */
typedef void (*ca_with_buffer_body_fn) (void *user_data, void *ptr,
                                      ca_size_t n_elements);

void rb_ca_call_with_buffer (VALUE r_ca, int writable,
                        ca_with_buffer_body_fn body, void *user_data);

#endif /* CA_FOR_BUFFER_H */
