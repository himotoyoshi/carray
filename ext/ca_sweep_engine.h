/* ---------------------------------------------------------------------------
 *
 *  ca_sweep_engine.h -- sweep (xfer_all) author surface engine, shared helper
 *
 *  Established in PROPOSAL_L0_AUTHOR_SURFACE L0.1 (2026-06-11).  Extracts
 *  the xfer_all-aware lifecycle template previously duplicated 7-times in
 *  ext/carray_call_cfunc.c (= one body per arity 1..7) into a single shared
 *  helper.  Same helper will back the forthcoming CA_FOR_EACH_ELEMENT macro
 *  family (L0.2a) and the WHOLE_BUFFER family (L0.2c).
 *
 *  Lifecycle template:
 *    (1) per-operand acquire
 *          OUTPUT (fsync=='1') -> ca_attach + use ca->ptr (sync on release)
 *          INPUT  (fsync=='0') alias-able -> ca_attach + use ca->ptr
 *          INPUT  (fsync=='0') non-alias  -> xmalloc + ca_xfer_all(GET)
 *    (2) broadcast shape check (scalar collapse + n_kernel agreement)
 *    (3) mask OR across INPUT operands -> m0 (xmalloc, NULL if none)
 *    (4) mask propagate to OUTPUT operands (overwrite output->mask)
 *    (5) caller runs the per-cell loop using base[] + stride[]
 *    (6) per-operand release (reverse order):
 *          sync OUTPUTs, detach attached or xfree owned_buf, xfree m0
 *
 *  Why xmalloc instead of ALLOCV_N:
 *    ALLOCV_N uses alloca() for sizes < RUBY_ALLOCV_LIMIT (1024 B); the
 *    allocation is bound to the calling C frame.  When the engine is
 *    extracted to a helper function, the alloca'd region would die on
 *    helper return.  xmalloc/xfree is frame-independent and safe to
 *    carry across the helper boundary.  Cost: one heap call per non-alias
 *    INPUT.  For arrays that warrant a kernel loop the cost is negligible.
 *
 *  --------------------------------------------------------------------------- */

#ifndef CA_SWEEP_ENGINE_H
#define CA_SWEEP_ENGINE_H

#include "carray.h"

/* Caller-allocated arrays of length n_ops:
 *   - cx[]        IN:  CArray pointers (caller fills before ca_sweep_acquire)
 *   - base[]      OUT: per-op base ptr for the per-cell loop
 *   - stride[]    OUT: per-cell stride in bytes (0 for scalar broadcast)
 *   - owned_buf[] OUT: xmalloc'd buffer (NULL if alias or OUTPUT path)
 *   - attached[]  OUT: 1 if ca_attach was called (= release must ca_detach)
 *
 * Engine-allocated:
 *   - m0          OUT: xmalloc'd mask byte array, NULL if no INPUT has mask
 *   - n_kernel    OUT: broadcast element count
 *
 * fsync: per-op '0'/'1' string of length n_ops.  Lifetime must cover both
 *        ca_sweep_acquire and ca_sweep_release (caller-owned, typically a string
 *        literal or stack-stored).
 *
 * src_label: optional, included in [BUG] error message if fsync length
 *            mismatches; NULL falls back to "ca_sweep_acquire".
 */
typedef struct ca_sweep_state {
  int             n_ops;
  const char     *fsync;
  CArray        **cx;
  char          **base;
  ca_size_t      *stride;
  char          **owned_buf;
  int            *attached;
  boolean8_t     *m0;
  ca_size_t       n_kernel;
  const char     *src_label;
  /* no_mask: if non-zero, ca_sweep_acquire raises when any INPUT operand has
   * a mask.  Used by the NO_MASK macro forms (CA_FOR_EACH_ELEMENT etc.) to
   * implement Q3=(ii) runtime error policy.  Default 0 (= masked INPUT OK,
   * m0 built as usual).  Caller sets before calling ca_sweep_acquire. */
  int             no_mask;

  /* === chunked path fields (L0.1 chunk, PROPOSAL_L0_AUTHOR_SURFACE) === */
  /* Used by ca_sweep_acquire_chunked / ca_sweep_next_chunk / ca_sweep_release_chunked
   * (= the sweep ELEMENT macro family).  Unused by the whole-materialise path
   * (ca_sweep_acquire / ca_sweep_release) — cfunc and other whole-buffer callers
   * leave these zero. */
  char          **base_orig;     /* per-op original ptr (= ca->ptr for
                                    alias/output; NULL for non-alias INPUT
                                    that uses an arena chunk scratch).
                                    Caller-allocated, length n_ops. */
  ca_size_t       chunk_n;       /* current chunk element count */
  ca_size_t       chunk_off;     /* current chunk start in flat addr */
  ca_size_t       chunk_n_max;   /* max chunk size from ca_chunk_compute_n */
  ca_size_t       inner;         /* product of dims except outermost (= row
                                    size in elements for outer-axis chunking) */
  int             chunked_state; /* 0=pre-init, 1=active, 2=done */
  boolean8_t     *mask_scratch;  /* chunk-sized staging for the per-chunk
                                    mask OR; NULL when no INPUT is masked */
} ca_sweep_state_t;

/* Validate fsync length, acquire per-op buffers, compute broadcast shape +
 * strides, build mask m0, propagate mask to OUTPUTs.  May raise (fsync
 * length mismatch, shape mismatch). */
void ca_sweep_acquire (ca_sweep_state_t *st);

/* Reverse-order release: sync OUTPUTs, detach attached / xfree owned_buf,
 * xfree m0.  State is single-use; do not call acquire again on the same
 * state without re-initializing the caller-owned arrays. */
void ca_sweep_release (ca_sweep_state_t *st);

/* Strict full-shape equality check used by INOUT macros (AC5: silent-
 * corruption seam prevention).  Raises if ndim differs or any dim[k]
 * differs.  Returns void; raises on mismatch. */
void ca_sweep_check_same_shape (CArray *ca_in, CArray *ca_out,
                             const char *src_label);

/* ===== Chunked path API (sweep ELEMENT macro family, L0.1 chunk) =====
 *
 * Unlike ca_sweep_acquire / ca_sweep_release (= whole-buffer materialise used
 * by cfunc), the chunked path keeps INPUT memory peak bounded to chunk
 * size (~32KB at f64 by default).  AC2 ancestor cascade prevention plus
 * memory peak guarantee: shrinking views materialise into chunk scratch
 * sized to inner-axis multiples, not full operand size.
 *
 * Usage shape (inside a macro):
 *   ca_sweep_acquire_chunked(&st);
 *   while (ca_sweep_next_chunk(&st)) {
 *     for (k = 0; k < st.chunk_n; k++) {
 *       T x = *(T*)(st.base[0] + k * st.stride[0]);
 *       ...
 *     }
 *   }
 *   ca_sweep_release_chunked(&st);
 *
 * OUTPUT operand semantics:
 *   OUTPUT is ca_attach'd whole (= self IS write target, legitimate per
 *   E.7 invariant), and base[k] is rewritten per chunk as base_orig[k] +
 *   chunk_off * stride[k] so author writes land in the correct region.
 *   Final ca_sync runs in release_chunked.  Output memory peak = entity
 *   size (= unavoidable; output buffer must exist).
 *
 * INPUT operand semantics:
 *   alias INPUT: base[k] = ca->ptr + chunk_off * stride[k], no gather.
 *   non-alias INPUT: arena scratch of size chunk_n_max * bytes is held
 *     for the entire walk; ca_chunked_gather rewrites it per chunk.
 *
 * Mask handling (m0):
 *   Chunk-sized (= chunk_n_max bytes), re-gathered per chunk in
 *   ca_sweep_next_chunk.  Read it at m0[k] for k < chunk_n -- it is
 *   indexed within the chunk, NOT by the flat cell index.  (This differs
 *   from the whole-buffer path, where m0 spans n_kernel.)
 *
 *   An author may WRITE m0[k] during the chunk loop (= the INOUT_MASKED
 *   forms' m_out).  Those writes are flushed into the OUTPUT operands'
 *   masks when the chunk finishes -- at the top of the following
 *   ca_sweep_next_chunk, and once more in ca_sweep_release_chunked for
 *   the last chunk -- so the OUTPUT masks are created up front in
 *   acquire_chunked rather than propagated in one go at release.
 */
void ca_sweep_acquire_chunked (ca_sweep_state_t *st);
int  ca_sweep_next_chunk      (ca_sweep_state_t *st); /* 1 = chunk ready, 0 = done */
void ca_sweep_release_chunked (ca_sweep_state_t *st);

/* ===== Chunking helpers (extern-ified from carray_operator.c) ===== */
ca_size_t ca_chunk_inner_size (CArray *ca);
ca_size_t ca_chunk_compute_n  (ca_size_t total, ca_size_t inner,
                               ca_size_t bytes_per_cell);
void      ca_chunked_gather   (CArray *ca, ca_size_t off, ca_size_t n,
                               void *dest);

/* Arena pool (extern-ified earlier by lazy substrate; reused here). */
extern void *ca_lazy_arena_acquire (ca_size_t bytes);
extern void  ca_lazy_arena_release (void *ptr);

#endif /* CA_SWEEP_ENGINE_H */
