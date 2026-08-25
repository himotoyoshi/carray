# 13 The sweep author surface

> **Status: draft.** Written through once; not yet re-verified against a live
> build. See [README](README.md) for conventions.

The sweep surface is for kernels that touch **every element** of an array
with no per-axis structure — a flat element-wise loop, or handing a whole
contiguous buffer to an external C library. It sits beside the kernel
iterator: where the iterator is about *per-axis* delivery (reduce / scan /
map along axes, [ch. 11](11_kernel_iterator.md)), sweep is about
*whole-array* delivery. This chapter places the surface in context and
pins down the C signatures.

The sweep family was introduced as the **L0 author surface**. The three families below all
sit on one shared engine — `ca_sweep_engine.c` — which extracted the
xfer_all-aware acquire / release lifecycle that had been duplicated
seven times in `carray_call_cfunc.c`.

## When to use sweep vs the kernel iterator

| Task | Use |
|---|---|
| Per-axis work (reduce along axis 1, cumulative scan, per-row sort) | kernel iterator ([ch. 11](11_kernel_iterator.md)) |
| Flat element-wise work (apply `f` to every cell, fill, iota) | sweep `CA_FOR_EACH_ELEMENT` |
| Hand the whole buffer to a library (FFTW, fitpack, BLAS) | sweep `CA_WITH_BUFFER` / `rb_ca_call_with_buffer` |
| Vectorise a per-cell C function via the typed bridge | `call_cfunc` ([ch. 14](14_call_cfunc.md)) |

All three sweep families are built on the same `xfer_all` whole-view
transfer ([ch. 2](02_core_data_structures.md) /
[ch. 4](04_attach_lifecycle.md)), so they deliver any view kind — aliasing
when contiguous, materialising when not — just like the kernel iterator.

## The shared engine: `ca_sweep_state_t`

Every sweep macro expands to a small stack-allocated state struct plus a
call into the engine. The state struct holds the per-operand bookkeeping
the engine fills in during acquire (base pointer, stride, attach flag,
mask `m0`) and the macros wire it up via a comma-expression in their
init clause:

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
  int          no_mask;         /* 1 = raise if any INPUT has a mask */
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

void ca_sweep_check_same_shape (CArray *ca_in, CArray *ca_out,
                                const char *src_label);
        /* Strict full-shape equality check used by INOUT macros. */
```

### Engine entry points (chunked path, sweep-element family)

The chunked path keeps INPUT memory peak bounded to chunk size (~32 KB
at f64) — the AC2 memory-peak guarantee. Shrinking views materialise
into chunk scratch sized to inner-axis multiples, not full operand
size:

```c
void ca_sweep_acquire_chunked (ca_sweep_state_t *st);
int  ca_sweep_next_chunk      (ca_sweep_state_t *st);   /* 1 = chunk ready, 0 = done */
void ca_sweep_release_chunked (ca_sweep_state_t *st);
```

Author-level pattern (inside the macro expansion):

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

## Family 1: `CA_FOR_EACH_ELEMENT`

A single-array per-cell loop with the data delivered contiguous — you
index `p[i]` with no stride arithmetic. The five forms compose the same
way the kernel-iterator FIBER forms do:

```c
/* (1) read-only, NO_MASK */
CA_FOR_EACH_ELEMENT(st1, ca, T, x) {
  /* x is a T lvalue holding the current cell */
  accumulator += x;
}

/* (2) read-only with a mask byte (m == 0 if no source mask) */
CA_FOR_EACH_ELEMENT_MASKED(st1, ca, T, x, m) {
  if (!m) accumulator += x;
}

/* (3) input → output map (NO_MASK; strict same-shape check on init) */
CA_FOR_EACH_ELEMENT_INOUT(st2, ca_in, ca_out, T_IN, T_OUT, in, out) {
  out = (T_OUT) sqrt((double) in);
}

/* (4) input → output map with mask */
CA_FOR_EACH_ELEMENT_INOUT_MASKED(st2, ca_in, ca_out, T_IN, T_OUT,
                                  in, out, m_in, m_out) {
  if (!m_in) { out = some_transform(in); m_out = 0; }
  else       { out = (T_OUT) 0; m_out = 1; }
}

/* (5) write-only (init / iota / fill) */
CA_FOR_EACH_ELEMENT_OUT(st1, ca_out, T, out) {
  out = (T) __cfeo_k;          /* injected loop index — see below */
}
```

State struct (caller-declared on the stack):

```c
ca_each_state_t      st1;   /* 1-operand forms */
ca_each_map_state_t  st2;   /* 2-operand INOUT forms */
```

These embed the per-op `cx[]` / `base[]` / `stride[]` / … arrays plus
the shared `ca_sweep_state_t core` so the author declares only one
variable.

### Macro semantics in detail

Every form expands to a three-level nested `for`:

- **Outer** — `ca_sweep_acquire_chunked` / `ca_sweep_release_chunked`
  scope (= lifecycle).
- **Middle** — the `ca_sweep_next_chunk` loop (chunk iteration).
- **Inner** — per-cell loop within `chunk_n`.

The macros expose the data through the engine's per-op
`base[]` / `stride[]`: cell *k* of operand *o* is at
`*(T *)(st.core.base[o] + k * st.core.stride[o])`. The author body
sees only the bound name (`x`, `in`, `out`, …) — the indirection is
hidden.

### Constraints

Same set as the kernel-iterator FIBER family:

- The state struct (`st1` / `st2`) is author-declared on the stack.
- `break;` from the body exits cleanly (= release runs in the outer
  for's teardown clause).
- `return;` from the body LEAKS scratch buffers / attached views.
  Restructure to break, or drop to the engine API.
- The macros are NOT statement-equivalent — they expand to nested `for`
  constructs. No trailing `else`.
- `T` must be the data type of `ca` (matched via `ca->data_type` /
  `ca->bytes`). The engine does not auto-cast; use
  `rb_ca_wrap_readonly(obj, INT2NUM(CA_FLOAT64))` /
  `rb_ca_template_with_type(obj, ...)` at the call site if a cast is
  needed.

The INOUT macros call `ca_sweep_check_same_shape` at init and raise on
mismatch — there is no implicit broadcasting at this surface. This differs
from the kernel-iterator INOUT family ([ch. 11](11_kernel_iterator.md)), which
instead **silently skips** the body on mismatch (no validation) — a deliberate
difference between the two engines, not an oversight.

### Memory peak

INPUT non-alias views materialise into a **single chunk scratch**
(~32 KB at f64) instead of a full operand-size scratch — this is the
AC2 ancestor-cascade-prevention guarantee that distinguishes the
chunked path from the whole-buffer path. OUTPUT is `ca_attach`'d whole
(its buffer must exist for the kernel to write through), so output
memory peak is unavoidable. The mask byte array `m0` is full-size for
simplicity in the current implementation; per-chunk mask gather is a
future optimisation.

## Family 2: `CA_WITH_BUFFER` and `rb_ca_call_with_buffer`

For handing a whole contiguous buffer to an external routine:

```c
/* read-only */
CA_WITH_BUFFER(ca, T, ptr, n) {
  /* ptr is T * pointing at native contig layout of ca; n = ca->elements.
     Read freely; no write-back on exit. */
}

/* writable; ca_sync runs on block exit */
CA_WITH_BUFFER_WRITABLE(ca, T, ptr, n) {
  fftw_execute_dft(plan, ptr, ptr);
}
```

The macros expand to a two-level `for` that does `ca_attach` →
(body) → `ca_sync` (writable only) → `ca_detach`. The `_WRITABLE` form
runs `ca_sync` before `ca_detach`; the read-only form skips the sync.

### Exception safety: the function form

The macros are `break`-safe but **leak on a non-local `return`** out of
the block (the cleanup runs in the outer for's teardown, which `return`
skips). For any body that may raise — calling into Ruby code, calling
a fallible library with a Ruby exception path, etc. — use the function
form instead:

```c
typedef void (*ca_with_buffer_body_fn) (void *user_data, void *ptr,
                                        ca_size_t n_elements);

void rb_ca_call_with_buffer (VALUE r_ca, int writable,
                             ca_with_buffer_body_fn body,
                             void *user_data);
```

`rb_ca_call_with_buffer` uses `rb_ensure` to guarantee `ca_sync` (if
writable) and `ca_detach` run before any exception propagates. The
function's own return is `Qnil`; thread your result back via
`user_data`. This is the right surface whenever the body might raise —
which, in Ruby C-extension code, is most things.

### Naming

`rb_ca_call_with_buffer` takes a `VALUE` (`rb_ca_*` prefix signals
VALUE in/out — [ch. 15](15_carray_h_helper_reference.md), memory:
prefix-decides-input-type). The block-form macros take a `CArray *`
and follow the `CA_*` macro family naming.

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
  The sweep ELEMENT family flattens the array and cannot recover the
  axis structure.
- **A standard op across all data types** (sum, sqrt, `+`, sort, …)
  → the mkkernel DSL ([ch. 12](12_mkkernel_dsl.md)) generates the
  per-data-type coverage. Hand-writing a sweep ELEMENT body across N
  data types is exactly the redundancy the DSL eliminates.
- **Wrapping an already-scalar C function for vectorisation** —
  call_cfunc ([ch. 14](14_call_cfunc.md)) gives you mask propagation,
  broadcasting, and output allocation in one declarative call.

The sweep surface is best fit when (a) the operation is fundamentally
flat-element-wise with no per-axis structure to recover, (b) the body
is hand-written C with mask awareness, or (c) you are bridging a
library that wants the whole contig buffer.

## Where to go next

- The per-axis surface this complements →
  [ch. 11 The kernel iterator](11_kernel_iterator.md).
- The `xfer_all` transfer underneath → [ch. 2](02_core_data_structures.md),
  [ch. 4](04_attach_lifecycle.md).
- Vectorising a scalar C function (a related but distinct surface) →
  [ch. 14 call_cfunc](14_call_cfunc.md).
- The primitives (`ca_attach`, `ca_sync`, `ca_xfer_all`) the engine
  builds on → [ch. 15](15_carray_h_helper_reference.md).

---
*When done, update the status row in [README](README.md).*
