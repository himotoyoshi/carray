/* ---------------------------------------------------------------------------
 *
 *  ca_for_each_element.h -- sweep ELEMENT macro family (single-array, lexical
 *                            scope body) for ext authors.
 *
 *  PROPOSAL_L0_AUTHOR_SURFACE L0.2a (2026-06-11).  Builds on the sweep engine
 *  helper (ca_sweep_engine.{c,h}, L0.1) for the xfer_all-aware acquire/release
 *  lifecycle.  Provides 5 macro forms for single-array element-wise loops
 *  with author-inline body and lexical-scope state capture.
 *
 *  Forms (Q2 = gamma: READ by-value, INOUT / OUT by-lvalue):
 *
 *    CA_FOR_EACH_ELEMENT(st1, ca, T, x)
 *      Read-only loop; per-iter x = cell value (T rvalue convention but
 *      declared lvalue for assignment).  Mask policy: NO_MASK (raises if
 *      INPUT has mask; use _MASKED form to handle).
 *
 *    CA_FOR_EACH_ELEMENT_MASKED(st1, ca, T, x, m)
 *      Read-only with mask byte m (1 = masked).  Author inspects m and
 *      decides; m == 0 if source has no mask.
 *
 *    CA_FOR_EACH_ELEMENT_INOUT(st2, ca_in, ca_out, T_IN, T_OUT, in, out)
 *      Map kernel; per-iter in = read input, body assigns to out (lvalue),
 *      out is written back to ca_out.  Strict same-shape check on init
 *      (raises on mismatch).  NO_MASK on input.
 *
 *    CA_FOR_EACH_ELEMENT_INOUT_MASKED(st2, ca_in, ca_out, T_IN, T_OUT,
 *                                      in, out, m_in, m_out)
 *      Map kernel with mask; per-iter m_in = input mask byte (or 0 if no
 *      input mask), author writes m_out (1 = mark output cell masked) and
 *      out.  m_out written back to ca_out's mask.
 *
 *    CA_FOR_EACH_ELEMENT_OUT(st1, ca_out, T, out)
 *      Write-only; body assigns to out (lvalue).  Use for init / iota /
 *      fill patterns.  NO_MASK (output mask cleared).
 *
 *  Usage pattern:
 *
 *      ca_each_state_t st;
 *      double x;
 *      CA_FOR_EACH_ELEMENT(st, ca, double, x) {
 *        accumulator += x;
 *      }
 *
 *  Constraints (same as CA_FOR_EACH_FIBER family):
 *    - State (st1 / st2) is author-declared on the stack.
 *    - `break;` from body exits cleanly (release runs in outer for's
 *      teardown clause).
 *    - `return;` from body LEAKS scratch buffers / attached views — do
 *      not return early from the macro body; restructure to break.
 *    - Macros are NOT statement-equivalent (expand to nested for); no
 *      trailing `else`.
 *    - `T` must be the data_type of `ca` (matched via ca->data_type and
 *      ca->bytes — engine does not auto-cast; use rb_ca_wrap_readonly /
 *      rb_ca_template_with_type at the call site if cast needed).
 *
 *  --------------------------------------------------------------------------- */

#ifndef CA_FOR_EACH_ELEMENT_H
#define CA_FOR_EACH_ELEMENT_H

#include "carray.h"
#include "ca_sweep_engine.h"

/* Stack-allocated state holders for 1- and 2-operand sweep ELEMENT macros.
 * Embeds the per-op bookkeeping arrays + the core ca_sweep_state_t in one
 * struct so authors declare just one variable. */

typedef struct {
  CArray       *cx[1];
  char         *base[1];
  ca_size_t     stride[1];
  char         *owned_buf[1];
  int           attached[1];
  char         *base_orig[1];
  ca_sweep_state_t core;
} ca_each_state_t;

typedef struct {
  CArray       *cx[2];
  char         *base[2];
  ca_size_t     stride[2];
  char         *owned_buf[2];
  int           attached[2];
  char         *base_orig[2];
  ca_sweep_state_t core;
} ca_each_map_state_t;

/* Internal init helpers: wire the embedded arrays into core, set fsync /
 * no_mask / src_label.  Called via comma-expression inside the macro
 * for-loop init clause. */

#define CA_SWEEP_WIRE_1_(_st1, _ca0, _fsync, _no_mask, _label) (   \
    (_st1).cx[0]           = (CArray *)(_ca0),                  \
    (_st1).core.n_ops      = 1,                                 \
    (_st1).core.fsync      = (_fsync),                          \
    (_st1).core.cx         = (_st1).cx,                         \
    (_st1).core.base       = (_st1).base,                       \
    (_st1).core.stride     = (_st1).stride,                     \
    (_st1).core.owned_buf  = (_st1).owned_buf,                  \
    (_st1).core.attached   = (_st1).attached,                   \
    (_st1).core.base_orig  = (_st1).base_orig,                  \
    (_st1).core.no_mask    = (_no_mask),                        \
    (_st1).core.src_label  = (_label))

#define CA_SWEEP_WIRE_2_(_st2, _ca0, _ca1, _fsync, _no_mask, _label) ( \
    (_st2).cx[0]           = (CArray *)(_ca0),                  \
    (_st2).cx[1]           = (CArray *)(_ca1),                  \
    (_st2).core.n_ops      = 2,                                 \
    (_st2).core.fsync      = (_fsync),                          \
    (_st2).core.cx         = (_st2).cx,                         \
    (_st2).core.base       = (_st2).base,                       \
    (_st2).core.stride     = (_st2).stride,                     \
    (_st2).core.owned_buf  = (_st2).owned_buf,                  \
    (_st2).core.attached   = (_st2).attached,                   \
    (_st2).core.base_orig  = (_st2).base_orig,                  \
    (_st2).core.no_mask    = (_no_mask),                        \
    (_st2).core.src_label  = (_label))

/* ---------- 5 author-facing macro forms ----------
 *
 * All 5 forms expand to a 3-level nested for:
 *   outer  : acquire_chunked / release_chunked (= lifecycle scope)
 *   middle : ca_sweep_next_chunk loop (= chunk iteration)
 *   inner  : per-cell loop within chunk_n
 *
 * Memory peak per AC2: INPUT non-alias views materialise into a single
 * chunk scratch (~32KB at f64).  m0 (= masked form) is full size (=
 * n_kernel bytes) for simplicity; macro reads at m0[chunk_off + k].
 *
 * For MASKED forms (m / m_in / m_out): when source has no mask, m0 is
 * NULL and m / m_in == 0 always.  m_out writes during INOUT_MASKED are
 * silently dropped if no INPUT mask exists (= AC4 mask-creation on
 * INOUT MASKED with no source mask is a future enhancement; current
 * convention follows the FIBER family's MASKED form).
 */

/* (1) READ-only, NO_MASK */
#define CA_FOR_EACH_ELEMENT(_st1, _ca, T, x)                            \
  for ( int __cfe_init = (CA_SWEEP_WIRE_1_((_st1), (_ca), "0", 1,          \
                                        "CA_FOR_EACH_ELEMENT"),         \
                          ca_sweep_acquire_chunked(&(_st1).core), 1);      \
        __cfe_init;                                                     \
        __cfe_init = 0, ca_sweep_release_chunked(&(_st1).core) )           \
    for ( ; ca_sweep_next_chunk(&(_st1).core); )                           \
      for ( ca_size_t __cfe_k = 0;                                      \
            __cfe_k < (_st1).core.chunk_n                               \
              && (((x) = *(T *)((_st1).core.base[0]                     \
                                + __cfe_k * (_st1).core.stride[0])), 1); \
            __cfe_k++ )

/* (2) READ-only, MASKED (m is 1 if masked, 0 otherwise; 0 if no source mask) */
#define CA_FOR_EACH_ELEMENT_MASKED(_st1, _ca, T, x, m)                  \
  for ( int __cfem_init = (CA_SWEEP_WIRE_1_((_st1), (_ca), "0", 0,         \
                                         "CA_FOR_EACH_ELEMENT_MASKED"), \
                           ca_sweep_acquire_chunked(&(_st1).core), 1);     \
        __cfem_init;                                                    \
        __cfem_init = 0, ca_sweep_release_chunked(&(_st1).core) )          \
    for ( ; ca_sweep_next_chunk(&(_st1).core); )                           \
      for ( ca_size_t __cfem_k = 0;                                     \
            __cfem_k < (_st1).core.chunk_n                              \
              && (((x) = *(T *)((_st1).core.base[0]                     \
                                + __cfem_k * (_st1).core.stride[0])),   \
                  ((m) = (_st1).core.m0                                 \
                            ? (_st1).core.m0[(_st1).core.chunk_off      \
                                             + __cfem_k]                \
                            : (boolean8_t)0),                           \
                  1);                                                   \
            __cfem_k++ )

/* (3) INOUT map (NO_MASK).  Strict same-shape check pre-acquire.        */
#define CA_FOR_EACH_ELEMENT_INOUT(_st2, _ca_in, _ca_out,                \
                                  T_IN, T_OUT, in, out)                 \
  for ( int __cfei_init = (                                             \
            ca_sweep_check_same_shape((CArray *)(_ca_in),                  \
                                   (CArray *)(_ca_out),                 \
                                   "CA_FOR_EACH_ELEMENT_INOUT"),        \
            CA_SWEEP_WIRE_2_((_st2), (_ca_in), (_ca_out), "01", 1,         \
                          "CA_FOR_EACH_ELEMENT_INOUT"),                 \
            ca_sweep_acquire_chunked(&(_st2).core),                        \
            1);                                                         \
        __cfei_init;                                                    \
        __cfei_init = 0, ca_sweep_release_chunked(&(_st2).core) )          \
    for ( ; ca_sweep_next_chunk(&(_st2).core); )                           \
      for ( ca_size_t __cfei_k = 0;                                     \
            __cfei_k < (_st2).core.chunk_n                              \
              && (((in) = *(T_IN *)((_st2).core.base[0]                 \
                                    + __cfei_k * (_st2).core.stride[0])), \
                  1);                                                   \
            (*(T_OUT *)((_st2).core.base[1]                             \
                        + __cfei_k * (_st2).core.stride[1]) = (out)),   \
            __cfei_k++ )

/* (4) INOUT map (MASKED).  Author writes m_out per cell. */
#define CA_FOR_EACH_ELEMENT_INOUT_MASKED(_st2, _ca_in, _ca_out,         \
                                         T_IN, T_OUT,                   \
                                         in, out, m_in, m_out)          \
  for ( int __cfeim_init = (                                            \
            ca_sweep_check_same_shape((CArray *)(_ca_in),                  \
                                   (CArray *)(_ca_out),                 \
                                   "CA_FOR_EACH_ELEMENT_INOUT_MASKED"), \
            CA_SWEEP_WIRE_2_((_st2), (_ca_in), (_ca_out), "01", 0,         \
                          "CA_FOR_EACH_ELEMENT_INOUT_MASKED"),          \
            ca_sweep_acquire_chunked(&(_st2).core),                        \
            1);                                                         \
        __cfeim_init;                                                   \
        __cfeim_init = 0, ca_sweep_release_chunked(&(_st2).core) )         \
    for ( ; ca_sweep_next_chunk(&(_st2).core); )                           \
      for ( ca_size_t __cfeim_k = 0;                                    \
            __cfeim_k < (_st2).core.chunk_n                             \
              && (((in) = *(T_IN *)((_st2).core.base[0]                 \
                                    + __cfeim_k * (_st2).core.stride[0])), \
                  ((m_in) = (_st2).core.m0                              \
                              ? (_st2).core.m0[(_st2).core.chunk_off    \
                                               + __cfeim_k]             \
                              : (boolean8_t)0),                         \
                  ((m_out) = (m_in)),                                   \
                  1);                                                   \
            (*(T_OUT *)((_st2).core.base[1]                             \
                        + __cfeim_k * (_st2).core.stride[1]) = (out)),  \
            (((_st2).core.m0)                                           \
                ? ((_st2).core.m0[(_st2).core.chunk_off + __cfeim_k]    \
                     = (m_out))                                         \
                : (boolean8_t)0),                                       \
            __cfeim_k++ )

/* (5) WRITE-only (init / iota / fill). */
#define CA_FOR_EACH_ELEMENT_OUT(_st1, _ca_out, T, out)                  \
  for ( int __cfeo_init = (CA_SWEEP_WIRE_1_((_st1), (_ca_out), "1", 0,     \
                                         "CA_FOR_EACH_ELEMENT_OUT"),    \
                           ca_sweep_acquire_chunked(&(_st1).core), 1);     \
        __cfeo_init;                                                    \
        __cfeo_init = 0, ca_sweep_release_chunked(&(_st1).core) )          \
    for ( ; ca_sweep_next_chunk(&(_st1).core); )                           \
      for ( ca_size_t __cfeo_k = 0;                                     \
            __cfeo_k < (_st1).core.chunk_n;                             \
            (*(T *)((_st1).core.base[0]                                 \
                    + __cfeo_k * (_st1).core.stride[0]) = (out)),       \
            __cfeo_k++ )

#endif /* CA_FOR_EACH_ELEMENT_H */
