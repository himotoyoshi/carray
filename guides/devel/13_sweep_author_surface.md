# 13 The sweep author surface

> **Status: draft.** Written through once; not yet re-verified against a live
> build. See [README](README.md) for conventions.

The sweep surface is for work that touches **every element** of an array
with no per-axis structure — element-wise work over one or more arrays,
or handing a whole contiguous buffer to an external C library. It sits
beside the kernel iterator: where the iterator is about *per-axis*
delivery (reduce / scan / map along axes, [ch. 11](11_kernel_iterator.md)),
sweep is about *whole-array* delivery. This chapter describes the engine
underneath and the whole-buffer function; the element-wise families that
call the engine are in [ch. 14](14_call_cfunc.md).

The engine — `ca_sweep_engine.c` — holds the xfer_all-aware acquire /
release lifecycle that had been duplicated seven times in
`carray_call_cfunc.c`. Both call_cfunc families run on it: the per-cell
`ca_call_cfunc_*` on the whole-buffer path, the per-chunk
`ca_call_cslab_*` on the chunked path.

## When to use sweep vs the kernel iterator

| Task | Use |
|---|---|
| Per-axis work (reduce along axis 1, cumulative scan, per-row sort) | kernel iterator ([ch. 11](11_kernel_iterator.md)) |
| Element-wise work, per cell or per chunk | `ca_call_cfunc_*_r` / `ca_call_cslab_*_r` ([ch. 14](14_call_cfunc.md)) |
| Hand the whole buffer to a library (FFTW, fitpack, BLAS) | `rb_ca_call_with_buffer` |

Both are built on the same `xfer_all` whole-view
transfer ([ch. 2](02_core_data_structures.md) /
[ch. 4](04_attach_lifecycle.md)), so they deliver any view kind — aliasing
when contiguous, materialising when not — just like the kernel iterator.

## The shared engine: `ca_sweep_state_t`

Every caller of the engine declares a small state struct on its stack and
fills in the operands. The struct holds the per-operand bookkeeping the
engine fills in during acquire (base pointer, stride, attach flag, mask
`m0`):

```c
typedef struct ca_sweep_state {
  int          n_ops;
  const char  *fsync;           /* per-op '0'/'1' string, length n_ops */
  CArray     **cx;              /* operand pointers (caller fills) */
  char       **base;            /* per-op base ptr (engine fills) */
  ca_size_t   *stride;          /* per-cell stride in bytes */
  char       **owned_buf;       /* xmalloc'd scratch, NULL if alias */
  int         *attached;        /* 1 if engine called ca_attach */
  boolean8_t  *m0;              /* mask byte array (engine-allocated) */
  ca_size_t    n_kernel;        /* broadcast element count */
  const char  *src_label;       /* for [BUG] error messages */
  /* chunked path fields ... */
  char       **base_orig;
  ca_size_t    chunk_n, chunk_off, chunk_n_max, inner;
  int          chunked_state;
} ca_sweep_state_t;
```

### Engine entry points (whole-buffer path)

```c
void ca_sweep_acquire (ca_sweep_state_t *st);
        /* Validate fsync, attach OUTPUTs, alias / xfer_all INPUTs into
           per-op buffers, compute broadcast shape + strides, build mask
           m0 via OR-fold across INPUTs, propagate mask to OUTPUTs. */

void ca_sweep_release (ca_sweep_state_t *st);
        /* Reverse-order release: sync OUTPUTs, detach attached, xfree
           owned_buf, xfree m0. State is single-use. */
```

### Engine entry points (chunked path, `ca_call_cslab_*`)

The chunked path keeps INPUT memory peak bounded to chunk size (~32 KB
at f64) — the AC2 memory-peak guarantee. Shrinking views materialise
into chunk scratch sized to inner-axis multiples, not full operand
size:

```c
void ca_sweep_acquire_chunked (ca_sweep_state_t *st);
int  ca_sweep_next_chunk      (ca_sweep_state_t *st);   /* 1 = chunk ready, 0 = done */
void ca_sweep_release_chunked (ca_sweep_state_t *st);
```

The caller's pattern:

```c
ca_sweep_acquire_chunked(&st);
while (ca_sweep_next_chunk(&st)) {
  for (k = 0; k < st.chunk_n; k++) {
    T x = *(T *)(st.base[0] + k * st.stride[0]);
    ...
  }
}
ca_sweep_release_chunked(&st);
```

### Chunking helpers

```c
ca_size_t ca_chunk_inner_size (CArray *ca);
ca_size_t ca_chunk_compute_n  (ca_size_t total, ca_size_t inner,
                               ca_size_t bytes_per_cell);
void      ca_chunked_gather   (CArray *ca, ca_size_t off, ca_size_t n,
                               void *dest);
```

These extern-ify the chunking logic previously local to
`carray_operator.c`; they share the arena pool with
`ca_lazy_arena_acquire` / `_release` so per-chunk scratch reuses the
same backing memory across operator calls.

### Why xmalloc and not ALLOCV

The engine uses `xmalloc` / `xfree` rather than `ALLOCV_N`. `ALLOCV_N`
uses `alloca` for sizes below `RUBY_ALLOCV_LIMIT` (1024 B); that
allocation is bound to the calling C frame and would die when the
helper returns. Heap-based allocation is frame-independent and safe to
carry across the helper boundary; one heap call per non-alias INPUT
is negligible for arrays that warrant a kernel loop.

## `rb_ca_call_with_buffer`: the whole buffer to an external routine

Header: `ca_for_buffer.h`.

```c
typedef void (*ca_with_buffer_body_fn) (void *user_data, void *ptr,
                                        ca_size_t n_elements);

void rb_ca_call_with_buffer (VALUE r_ca, int writable,
                             ca_with_buffer_body_fn body,
                             void *user_data);
```

`ptr` is `ca->ptr` itself when the array is a contig entity, and a
materialised contig buffer when it is a view. A writable call writes the
buffer back to the view's storage when the body returns.

`rb_ca_call_with_buffer` closes the array however the body is left: a
writable array is written back first, so what the body wrote before
raising arrives, and the array is detached even if that write-back
raises. The body's exception is the one that propagates. The
function's own return is `Qnil`; thread your result back via
`user_data`. This is the right surface whenever the body might raise —
which, in Ruby C-extension code, is most things.

It takes a `VALUE` (`rb_ca_*` prefix signals VALUE in/out —
[ch. 15](15_carray_h_helper_reference.md)).

## A worked example: replacing 60 lines of attach plumbing

A typical pre-3.0 companion-gem kernel that handed a contig buffer to
a third-party library looked like this — manual attach lifecycle,
exception-unsafe, per-data-type branching:

```c
static VALUE
rb_camath_fft (VALUE self, VALUE r_a) {
  CArray *ca; GetCArray(r_a, ca);
  if (ca->data_type != CA_FLOAT64) rb_raise(rb_eArgError, "need f64");
  ca_attach(ca);
  fftw_plan plan = fftw_plan_dft_1d(ca->elements, ...);
  fftw_execute(plan);
  fftw_destroy_plan(plan);
  ca_sync(ca);
  ca_detach(ca);
  return r_a;
}
```

After adopting `rb_ca_call_with_buffer` the body shrinks to about
10 lines and is exception-safe:

```c
static void
fft_body (void *ud, void *ptr, ca_size_t n) {
  fftw_plan plan = fftw_plan_dft_1d(n, ptr, ptr, FFTW_FORWARD, FFTW_ESTIMATE);
  fftw_execute(plan);
  fftw_destroy_plan(plan);
}

static VALUE
rb_camath_fft (VALUE self, VALUE r_a) {
  rb_ca_call_with_buffer(r_a, /*writable=*/1, fft_body, NULL);
  return r_a;
}
```

What the surface does for you: attach lifecycle, alias-when-contig,
materialise-when-not, sync-on-exit, `rb_ensure` exception safety. This
"before/after" is the canonical case for adopting the surface.

## When NOT to use sweep

- **Per-axis** work (reduce along axis 1, cumulative scan per row,
  per-fiber sort) → the kernel iterator gives you `axis:` for free.
  The sweep surface flattens the array and cannot recover the axis
  structure.
- **A standard op across all data types** (sum, sqrt, `+`, sort, …)
  → the mkkernel DSL ([ch. 12](12_mkkernel_dsl.md)) generates the
  per-data-type coverage. Hand-writing a callback across N
  data types is exactly the redundancy the DSL eliminates.

The sweep surface is best fit when the operation is fundamentally
flat-element-wise with no per-axis structure to recover, or when you
are bridging a library that wants the whole contig buffer.

## Where to go next

- The per-axis surface this complements →
  [ch. 11 The kernel iterator](11_kernel_iterator.md).
- The `xfer_all` transfer underneath → [ch. 2](02_core_data_structures.md),
  [ch. 4](04_attach_lifecycle.md).
- The element-wise families on the engine →
  [ch. 14 call_cfunc](14_call_cfunc.md).
- The primitives (`ca_attach`, `ca_sync`, `ca_xfer_all`) the engine
  builds on → [ch. 15](15_carray_h_helper_reference.md).

---
*When done, update the status row in [README](README.md).*
