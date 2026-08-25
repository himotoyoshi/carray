# 10 Author surface overview

> **Status: draft.** Written through once; not yet re-verified against a live
> build. See [README](README.md) for conventions.

This chapter opens Part III, the part about *writing kernels* — the C code
that computes over arrays. It is the gateway: it maps the four entry
points, says when to use each, and states the design principles every
extension author inherits. Chapters 11–15 are the details; read this
first.

It sits alongside the whole-picture material: how to accept, produce, and
operate on CArrays from C, and the end-to-end kernel walkthrough.

## The four entry points

CArray gives a C author four distinct surfaces. Picking the right one is
most of the battle:

| Surface | Header(s) | Use it for | Builds on |
|---|---|---|---|
| **kernel iterator** ([ch. 11](11_kernel_iterator.md)) | `ext/ca_kernel_iterator.h` | the **default** — any per-element or per-axis kernel; receives all ~22 view kinds uniformly | `ca_iter_state` + `ca_axis_descriptor` + per-view xfer ops |
| **mkkernel DSL** ([ch. 12](12_mkkernel_dsl.md)) | `ext/mkkernel.rb` → `ext/carray_kernels.c` | the **default landing for a new standard operation** — emits typed coverage for every data type at once | the kernel iterator macros |
| **sweep author surface** ([ch. 13](13_sweep_author_surface.md)) | `ext/ca_for_each_element.h`, `ext/ca_for_buffer.h`, `ext/ca_sweep_engine.h` | flat element-wise loops; whole-buffer delivery to external libraries | `ca_sweep_state_t` engine; same `xfer_all` plumbing |
| **call_cfunc** ([ch. 14](14_call_cfunc.md)) | `ext/carray_call_cfunc.h` (generated) | vectorising an existing scalar C function | `ca_sweep_state_t` engine (typed wrapper) |

A non-surface for the same reason it shows up in conversations:

| Lookalike | Where | Why **not** a C kernel surface |
|---|---|---|
| `each_slab` / `map_slab` / `reduce_slab` | Ruby surface (user-facing) | These are Ruby end-user features — they call back into a Ruby block per slab. You cannot write a C kernel against them. |

### The category-error trap

The last row is the one that catches people. `each_slab` and friends look
like "per-axis iteration", so it is tempting to reach for them when
implementing a C extension that needs per-axis work. **That is a category
error.** `each_slab` is a Ruby block bridge for end users; it is not how
you write a C kernel. The C answer for per-axis work is `CA_FOR_EACH_SLAB`
+ kernel-iterator state. If you find yourself naming `each_slab` while
designing a C extension, stop — you are looking at the wrong surface and
should return to this table.

## The decision flow

```
                ┌────────────────────────────────────────────────┐
                │ What are you writing?                          │
                └────────────────────────────────────────────────┘
                                  │
       ┌──────────────────────────┼──────────────────────────────┐
       ▼                          ▼                              ▼
  standard op                bespoke kernel              already-scalar C func
  across all dtypes          (fused multi-output,         (lgamma, GSL fn,
  (sum, sqrt, +, sort)        domain-specific scan)        PROJ transform)
       │                          │                              │
       ▼                          ▼                              ▼
  ┌─────────┐                ┌─────────────┐               ┌────────────┐
  │ mkkernel│                │   kernel    │               │ call_cfunc │
  │   DSL   │ ─────uses────▶ │  iterator   │               │  (ch. 14)  │
  │ (ch.12) │                │  (ch. 11)   │               └────────────┘
  └─────────┘                └─────────────┘
                                  │
              flat element-wise / whole-buffer
                                  ▼
                          ┌──────────────────┐
                          │ sweep author     │
                          │ surface (ch. 13) │
                          └──────────────────┘
```

In words:

- **"I want a new reduce / map / scan / binop / monop / sort / search
  over all data types"** → **mkkernel DSL** ([ch. 12](12_mkkernel_dsl.md)).
  Don't hand-write per-type wrappers in `carray_math.c`.
- **"I want a bespoke kernel the DSL doesn't cover"** (a fused
  multi-output, a domain-specific scan, a custom-policy reduction) →
  write it directly on the **kernel iterator**
  ([ch. 11](11_kernel_iterator.md)) using `CA_FOR_EACH_SLAB` /
  `CA_FOR_EACH_FIBER` / `CA_SLAB_REDUCE_T*`.
- **"I want to sweep every element of a contig buffer"** (element-wise,
  no per-axis structure) → the **sweep ELEMENT family** in
  [ch. 13](13_sweep_author_surface.md) (`CA_FOR_EACH_ELEMENT*`).
- **"I want to hand the whole contig buffer to an external library"**
  (FFTW, fitpack, BLAS) → sweep's **buffer family**
  ([ch. 13](13_sweep_author_surface.md)),
  `CA_WITH_BUFFER` / `rb_ca_call_with_buffer`.
- **"I already have a scalar C function and just want it vectorised"** →
  **call_cfunc** ([ch. 14](14_call_cfunc.md)).
- **"I need a primitive to gather / scatter / wrap / template /
  attach"** → look in `carray.h` first
  ([ch. 15](15_carray_h_helper_reference.md)); the helper almost
  certainly exists.

## Surface comparison at a glance

A quick cross-cut so you can pick by property rather than by task:

| Property | kernel iterator | mkkernel DSL | sweep | call_cfunc |
|---|---|---|---|---|
| Granularity | slab or fiber (axis-aware) | (delegates to iterator) | per-element or whole-buffer | per-element |
| Layer | C macros + state machine | Ruby DSL → C generator | C macros + engine | typed C dispatcher |
| Per-axis (`axis:`) | yes (`CA_SLAB_AXES`) | yes (axes variadic) | no (flat) | no |
| Mask propagation | by default (declare NO_MASK to opt out) | by default | by default | by default |
| Auto data-type coverage | one type per kernel | all source types in one declaration | one type per macro instantiation | per-call (declared) |
| Broadcast inputs | not directly | via `array_arg:` | no | yes |
| External library hand-off | no (per-cell delivery) | no | **yes** (`CA_WITH_BUFFER`) | no (per-cell only) |
| Reentrancy with outer state | manual | the `value_arg` / `array_arg` slots | manual | **yes** (`_r` variants) |
| Output allocation | author (`rb_ca_new_reduced`) | generator | author | generator |
| Ruby method binding | author | generator | author | author |

This is the cheat-sheet. The full per-surface details live in
[ch. 11](11_kernel_iterator.md) through [ch. 14](14_call_cfunc.md).

## The principles every author inherits

These are not style preferences; they are the contract the whole view
system depends on. Here is the operative summary.

### 1. Deliver the materials

A kernel is *handed* its data through one uniform interface and writes
computation logic only. It never inspects or special-cases the source
view's structure. The iterator delivers — aliasing, striding, or
materialising as needed. Reject only the *physically impossible*: write
to a read-only view, shape mismatch, an explicit `CA_KERNEL_NO_MASK`
opt-out met with a masked source.

### 2. Universal dispatch, and its accepted cost

The same kernel receives every view kind. That universality sometimes
costs SIMD (a strided callback the compiler can't vectorise). The cost
is *accepted* — the alternative is writing one specialised helper per
view (18 helpers for 6 views × 3 ops), which defeats the surface. If you
need speed, change *level* (drop L2→L1) or recover contig fast-path
inside an L2 callback with `CA_L2_FOR_EACH` ([ch. 11](11_kernel_iterator.md));
don't specialise the surface itself.

### 3. Chain composability is the value

Views compose into chains (a transposed slice of a strided block of a
reshape of a select…); that composability is CArray's identity. Don't
add a restriction that forces a materialise and breaks the chain. A
user who wants a materialised copy says `.copy`.

### 4. The attach lifecycle is library-internal API

Never push per-cell hot-path workarounds onto the user (`"call attach!
first"` is not an answer). The lifecycle (`ca_attach` / `ca_sync` /
`ca_detach`) is the **library author's** internal API — solve
performance inside the library; the Ruby-facing surface should stay
clean.

### 5. kernel iterator is default; `ca_attach` is the last resort

`ca_attach` force-materialises every view — it is the nuclear option.
Reaching for it at a kernel's entry ("entity-ify everything first") is
exactly the mistake the kernel iterator exists to prevent. The only
routine justification is a `CA_OBJECT` per-cell Ruby callback, which
the iterator can't transparently deliver ([ch. 11](11_kernel_iterator.md)).

### 6. Don't grow the vocabulary

Do not wrap a CArray primitive in a new gem-local name
(`cn_gather_to_buf` for `ca_copy_data`, `mygem_new_f64_ca` for
`rb_carray_new`). Call the primitive directly; a new name earns its keep
only by adding genuine semantic value
([ch. 15](15_carray_h_helper_reference.md)). The full rationale (and the
precedent of the carray-numerics `cn_*` wrappers that were deleted) is that
every parallel name forces readers to learn the CArray vocabulary twice.

## The vocabulary boundary

The four surfaces share a small, settled vocabulary you carry across all
of them:

| Identifier | What it means |
|---|---|
| `CArray *ca` | the view or entity you operate on |
| `ca->data_type`, `ca->ndim`, `ca->dim[]`, `ca->bytes`, `ca->elements` | shape and type metadata |
| `ca->ptr` | the data buffer, **non-NULL iff attached** |
| `ca->mask` | child CArray (`CA_BOOLEAN`) or NULL |
| `boolean8_t *m` | a contiguous mask byte run (1 = masked) |
| `v` / `r` / `acc` / `w` / `idx` / `first` | reduce / map / scan body identifiers ([ch. 11](11_kernel_iterator.md)) |
| `#1` / `#2` / `#3` | mkmath-style positional placeholders in monop / binop / triop / moncmp / bincmp bodies ([ch. 12](12_mkkernel_dsl.md)) |
| `CA_KERNEL_*` / `CA_SLAB_*` / `CA_ITER_*` | frozen author-facing tokens you write literally |
| `CA_FOR_EACH_*` / `CA_SLAB_REDUCE_T*` / `CA_L2_FOR_EACH` / `CA_WITH_BUFFER*` | the macro families |

Anything *not* in this list (an `alias_mode`, a `src_kind`, a routing
helper) is internal: refactor-free territory you should not read or write
from kernel code.

## The bench / smoke discipline

Any new kernel needs a benchmark and a smoke test, both run under `CARRAY_DEV=1`.
The rules — generate bench data with `{ |i| rand(...) }` (never the arity-0
`{ rand(...) }` broadcast trap), use enough iterations (50+/sample, median-of-7,
warmup, GC.start interleave), show the measured numbers rather than self-grading,
and verify across data types (not just `f64`) — are in
[ch. 19](19_build_generators_testing.md), which owns this discipline.

## Inheriting the discipline: the ext author's reading list

Before you write *any* new C extension that touches CArray, follow a
reading order that has already saved several sessions of rework. The
minimal set:

- this chapter (the four-surface map);
- the surface you intend to use ([ch. 11](11_kernel_iterator.md),
  [ch. 12](12_mkkernel_dsl.md), [ch. 13](13_sweep_author_surface.md), or
  [ch. 14](14_call_cfunc.md));
- [ch. 15](15_carray_h_helper_reference.md) for the primitives.

For touches to the kernel-iterator **engine** itself (not the surface),
there is a designated engine-internals memo to re-read so engine
refactors don't reinvent rejected alternatives.

## Where to go next

- The default surface in depth → [ch. 11](11_kernel_iterator.md).
- Generating typed coverage → [ch. 12](12_mkkernel_dsl.md).
- Whole-buffer / flat-element loops →
  [ch. 13](13_sweep_author_surface.md).
- Bridging a scalar C function → [ch. 14](14_call_cfunc.md).
- The primitives and the no-wrapper rule →
  [ch. 15](15_carray_h_helper_reference.md).

---
*When done, update the status row in [README](README.md).*
