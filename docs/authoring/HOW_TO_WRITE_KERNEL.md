# How to Write a Kernel for CArray

*A walkthrough for C extension authors who want to write CArray-aware
numerical kernels (= reductions, element-wise transforms, per-axis
operations) using the kernel_iterator surface introduced in CArray 3.0.*

> **Which author surface do I want?** This guide covers the **per-axis**
> kernel_iterator surface (`CA_FOR_EACH_SLAB` / `CA_FOR_EACH_FIBER` +
> `CA_SLAB_*` body helpers) — for reductions, scans, and per-axis loops.
> If instead you want a **whole-array flat element loop**
> (`CA_FOR_EACH_ELEMENT`) or to **hand a whole contiguous buffer to a
> third-party C library** (`CA_WITH_BUFFER` / `rb_ca_call_with_buffer`,
> e.g. FFTW / fitpack), see the **sweep author surface** in
> [`docs/Sweep_Author_Surface.md`](Sweep_Author_Surface.md).

## Table of Contents

0. [Macro catalog — author surface contract](#0-macro-catalog--author-surface-contract)
1. [Why kernel_iterator](#1-why-kernel_iterator)
2. [The four building blocks](#2-the-four-building-blocks)
3. [A minimal sum kernel](#3-a-minimal-sum-kernel)
4. [Multi-axis reduction with CA_SLAB_AXES](#4-multi-axis-reduction-with-ca_slab_axes)
5. [Map kernels — element-wise transforms](#5-map-kernels--element-wise-transforms)
6. [Block macros: CA_FOR_EACH_SLAB / _INOUT / _FIBER + macro suite + SIMD reduction license](#6-block-macros-ca_for_each_slab--_inout--_fiber--macro-suite)
7. [Cookbook: kernel pattern catalog](#7-cookbook-kernel-pattern-catalog)
8. [Mask handling](#8-mask-handling)
9. [L1 vs L2: which level to choose](#9-l1-vs-l2-which-level-to-choose) — *implementer note, will be folded into §0 in a later pass*
10. [Argument helpers (Phase B)](#10-argument-helpers-phase-b)
11. [What you don't have to write](#11-what-you-dont-have-to-write)
12. [Common pitfalls](#12-common-pitfalls)
13. [Status and what's next](#13-status-and-whats-next)

---

## 0. Macro catalog — author surface contract

This catalog is the **author-facing contract** for the kernel_iterator
surface. Author code selects a macro based on the kernel pattern; the
macro name encodes its delivery semantics. **You do not need to know
about internal dispatch levels (L1 / L2 / `init_l*`) or policy enums
(`CA_SLAB_WHOLE` / `CA_SLAB_AXES`) to write kernels** — those are
implementer vocabulary and may be refactored freely without affecting
this catalog.

When adding a new kernel author surface, **extend this catalog**; do
not invent ad-hoc macros outside it. The catalog discipline is what
keeps the author surface stable across engine refactors.

### 0.1 Catalog

| Macro | Delivery semantics | Use case | Status |
|---|---|---|---|
| `CA_FOR_EACH_SLAB` | per-slab strided delivery (general purpose, peak efficiency) | per-axis reduction / map / sort / any per-slab loop kernel | ✓ Landed (§6.1) |
| `CA_FOR_EACH_SLAB_INOUT` | per-slab strided delivery, input + output in parallel | element-wise transform with input / output in distinct views | ✓ Landed (§6.2) |
| `CA_FOR_EACH_FIBER` | per-axis fiber, **data contig-guaranteed**, NO_MASK only | single-axis specialization for contig-required kernels (sort, search, per-axis SIMD, libc `qsort`) — removes both stride arithmetic and the `axes[]` boilerplate | ✓ Landed (§6.3) |
| `CA_FOR_EACH_FIBER_INOUT` | per-axis fiber, data contig, INOUT in parallel, NO_MASK only | `sort_copy` / `search_copy` / per-fiber map | ✓ Landed (§6.3) |
| `CA_FOR_EACH_FIBER_MASKED` | per-axis fiber, **data contig** and **mask contig** — author writes `m[i]` directly | mask-aware per-fiber reduction / WRITE | ✓ Landed (§6.3) |
| `CA_FOR_EACH_FIBER_INOUT_MASKED` | per-axis fiber, data contig, INOUT, mask contig | mask-aware per-fiber map | ✓ Landed (§6.3) |

**Note on contig guarantee**: All four `_FIBER` forms deliver contig
buffers — data, mask (MASKED forms), and output (INOUT forms). Author
uses `p[i]` / `m[i]` / `p_out[i]` with no stride arithmetic. The engine
handles alias selection (zero-copy when fiber stride permits) and
per-fiber materialise (including per-fiber mask gather for non-innermost
axes) transparently. INOUT forms require **strict full shape equality**
of input and output views (= same ndim, same `elements`, same
`dim[axis]`); mismatched pairs are silently skipped (= body does not
run) to plug the rev4 silent-corruption seam.
| `CA_SLAB_REDUCE_T` | single-expression reduction kernel (1 line init + REDUCE) | sum / count / min / max / mean / variance | ✓ Landed (§6.5) |
| `CA_SLAB_REDUCE_T_PLUS_EX` / `_MIN_EX` / `_MAX_EX` / `_STAR_EX` | SIMD-licensed reduction variants (`#pragma omp simd reduction(+/min/max/*:acc)` on contig no-mask path) | sum / mean / variance / prod with 8x throughput on f64 entity | ✓ Landed (§6.7, SL.1.x 2026-06-12) |
| `CA_SLAB_REDUCE_ARRAY_T_PLUS_EX` | SIMD-licensed weighted reduction (FMA `fmla.2d` + reassoc, dual-stream) | wsum / wmean | ✓ Landed (§6.7, SL.1.4b) |
| `CA_SLAB_MAP_T` | single-expression element-wise map kernel | sqrt / sin / cos / abs / negate | ✓ Landed (§6.5) |
| `CA_SLAB_SCAN_T` | single-expression prefix-scan kernel | cumsum / cumprod / cummax / cummin / cumcount | ✓ Landed (§6.5) |
| `CA_SLAB_SEARCH_T` | single-expression search-by-eq kernel | `bsearch` / `search_nearest` family | **Not built** as a one-expression macro. The search family (`find_value_index` / `bsearch` / `search` / `search_nearest` + `_addr`) ships via the mkkernel `MkKernel.search` DSL with an author-written per-slab C body — see [`MkKernelDSL.md`](MkKernelDSL.md) |

### 0.2 How to pick

Pick by what your kernel **does with the data**, not just by axis
count (the engine handles view structure transparently):

- **Single-axis kernel that USES a contig buffer in-place** — e.g.
  the body sorts / FFTs / runs SIMD on the FIBER-provided buffer
  directly → `CA_FOR_EACH_FIBER` family.  Examples:
  - `qsort(po, n, bytes, cmp)` in `sort_copy` (= sort happens on po)
  - per-axis FFT writing back to the same buffer
  - SIMD intrinsics walking `buf[i]` contig
  These are exactly the kernels that gain from FIBER's contig
  guarantee.  F.7 phase A.3 measured 11-45% speedup for sort_copy
  / partition_copy on non-innermost axes via this path.
- **Single-axis kernel that BUILDS its own intermediate buffer** — e.g.
  the body creates a `pair {value, index}` array, or returns a
  single scalar via early-break.  Use `CA_FOR_EACH_SLAB` with
  `slab_strides[0]` stride math.  Examples:
  - `sort_index` builds a pair {v, i} buffer then sorts it
  - `bsearch` returns immediately on match (O(log n), scalar output)
  - `search_nearest` walks once tracking min distance (scalar output)
  For these, FIBER's gather is redundant work or pure overhead.
  F.7 phase A.1/A.2 audit measured 9-62% slower with FIBER, so the
  catalog explicitly does NOT recommend FIBER for them.
- **Multi-axis kernel (any combination of axes)** → `CA_FOR_EACH_SLAB`.
  Required when slab spans >1 axis (= reduction along multiple axes,
  K-D map / convolution).
- **Reduction expressible in a single REDUCE expression** → `CA_SLAB_REDUCE_T`.
- **Element-wise transform** → `CA_SLAB_MAP_T`.
- **Cumulative / prefix-scan** → `CA_SLAB_SCAN_T`.
- **Search by equality / nearest** → the mkkernel `MkKernel.search`
  DSL (author-written per-slab body), see [`MkKernelDSL.md`](MkKernelDSL.md).

**The FIBER question reduces to a single test**: does your kernel body
*write to* (or sort / FFT in place on) the FIBER-provided pointer?
If yes → FIBER.  If the body reads the data through a stride and
stores to a different place (= intermediate buffer or single scalar)
→ SLAB.

**Differentiation axes of `_FIBER` vs `_SLAB`**: (a) data + mask both
contig-guaranteed, (b) single `int axis` argument (no `axes[]` array
construction), (c) NO_MASK vs MASKED forms separated so the macro
signature transparently reflects whether mask is in play. (a) only
matters when the kernel body uses the contig buffer; if the body
copies into its own buffer anyway, (a) is wasted work and SLAB is
the right tool.

If your kernel pattern does not fit any catalog entry, that is a signal
that the catalog needs an explicit extension — propose the new entry
rather than inventing a one-off macro outside this catalog.

### 0.3 Frozen vs implementer vocabulary (skip if you are writing kernels, not refactoring the engine)

The surface is a **two-tier freeze contract** (3.0 onward): author-facing
names are FROZEN so ext-gem kernels keep compiling and the engine can be
re-implemented behind them (a planned engine overhaul is exactly what this
insulates against); everything else is INTERNAL and refactors freely.
The full FROZEN list is in [§13](#13-status-and-whats-next); the
mechanical pin is `rake kernel_surface_check`.

**FROZEN — author writes these literally, so they cannot be renamed
without a 3.x breaking change** (a common trap is to mistake them for
internal because they look like enums):

- **`CA_SLAB_AXES`** — passed as the `policy` arg in raw-API
  `init_l2` calls (the block macros hardcode it internally, so kernels
  that use `CA_FOR_EACH_SLAB` / `_INOUT` never type it; raw-API kernels
  still do).
- **`CA_KERNEL_WRITE` / `CA_KERNEL_NO_MASK`** — passed as the `flags` arg.
- **`CA_ITER_OK` / `CA_ITER_ERR_*`** — compared against `init_l2`'s return
  code in raw-API kernels (`if (rc != CA_ITER_OK) …`).
- **`ca_iter_state_init_l2` / `next_slab_axes` / `sync_slab` / `finish`** —
  the raw-API entry points the macros expand to; also called directly by
  kernels that need explicit error reporting (§6.3).

**INTERNAL — engine-only, may be renamed / restructured by engine
refactors without touching the catalog:**

- **L1 / L2 / L3** — internal dispatch levels. `CA_FOR_EACH_SLAB` and
  `CA_FOR_EACH_FIBER` (+ their `_INOUT` / `_MASKED` siblings) both
  expand to L2; the FIBER forms add an internal opt-in flag
  (`CA_KERNEL_FIBER_CONTIG`) that tells the engine to gather strided
  fibers into per-state scratch (`fiber_data_scratch`,
  `fiber_mask_scratch`) so author sees contig `p[i]` / `m[i]`.
- **`ca_iter_state_init_l1` / `next_slab` / `next_slab_strided` /
  `ca_iter_can_alias`** — alternate entry points not used by the catalog
  macros (the L1 contig path; see §9). Not part of the author contract.
- **`CA_SLAB_WHOLE` / `CA_SLAB_FREE`** — engine policy enums authors never
  pass (`CA_SLAB_AXES` is the only policy a kernel writes).
- **`CA_ITER_ALIAS_*` / `CA_ITER_SRC_*` / `CA_KERNEL_FIBER_CONTIG`** —
  engine internal flags / enums.

**Section 9 below still uses L1/L2 vocabulary directly for historical
reasons; folding into §0 is deferred.**

### 0.4 Performance note — per-source dispatch (F.6 phase)

The author-facing catalog is unchanged, but the engine internally
picks one of three materialisation paths per source kind:

| Engine path | Action | When chosen |
|---|---|---|
| **A. Alias** | `parent.ptr + offset` direct yield, no materialise | entity, contig CAStride, interior-only CAWindow (= F-1 STRIDE promotion) |
| **B. Whole-view scratch** | `xfer_all` into scratch, slice from scratch | most SRC_DESCRIPTOR / SRC_ATTACH sources |
| **C. Per-fiber fused** | `xfer_stride` per fiber, routes into the view's per-region fused fast path (X.1 / X.4) | CAFake / CAByteSwap with fiber-axis stride match; CAShift / CAWindow on the materialise path |

The F.6 phase (2026-06-06) added path C to replace B for source
kinds whose view has a fused per-region path (X.1 OOB-fused
for CAShift / CAWindow, X.4 transform-fused for CAFake / CAByteSwap).
Measured speedups: CAShift fiber sum 7.65x, CAByteSwap innermost
1.34x, CAFake innermost 1.67x.  Path A is never substituted (=
already materialise-free; adding C would only add call overhead).

You do not need to think about which path the engine picks; the
`_FIBER` catalog macros deliver the contig guarantee regardless.
The note is here so authors of performance-critical kernels can
predict why their code accelerates on certain source kinds.

---

## 1. Why kernel_iterator

CArray gives C extension authors **two generations** of "gift": the
framework hides view/lifecycle complexity so authors can write only the
essential kernel logic.

| Generation | Gift | What you no longer have to write |
|---|---|---|
| **First generation** (`ca_attach` / `ca_sync` / `ca_detach`) | view materialise / sync-back / lifecycle | you only write a kernel against a *contig 1-D buffer* — the framework handles view materialisation |
| **Second generation** (`ca_iter_state` + helpers, this doc) | multi-dimensional slab yield, mask passthrough, view chain transparency | you only write the *per-slab kernel body* — the framework handles K-D iteration, mask gather, view chain compose-fold |

The first-generation API still exists and is documented in
[WritingCExtensions.md](WritingCExtensions.md). Think of
kernel_iterator as the **multi-dimensional successor** to the
`ca_attach` family — same design philosophy (framework handles
complexity, author writes essence), generalised from 1-D contig
buffers to K-D slabs with mask + view chain transparency.

**What kernel_iterator gives you:**

- **View algebra transparency**: your kernel receives a slab pointer
  + stride metadata regardless of whether the source is an entity,
  a transposed view, a 5-deep CAStride chain, or a Boolean-masked
  filter. You write one kernel; it works on all of them.
- **Mask passthrough**: masked sources hand your kernel a mask
  pointer alongside the data slab. You skip masked cells; the
  framework handled the gather.
- **Lifetime management**: `ca_attach` / `ca_detach` are called by
  the iterator. You don't manage parent attach state, scratch
  allocation, or sync timing.
- **K-D slab yield**: you specify which axes form the slab (= the
  axes your kernel iterates over per call), and the iterator walks
  the remaining axes for you.

## 2. The four building blocks

Every kernel written on top of kernel_iterator has the same four
blocks. Here's the skeleton — replace `<KERNEL_LOGIC>` with the
domain-specific work:

```c
static VALUE
rb_my_kernel (int argc, VALUE *argv, VALUE self)
{
  CArray *ca, *co;
  int8_t  slab_axes[CA_RANK_MAX];
  int8_t  naxes;

  /* === Block 1: input — receive + validate the source ============= */
  GetCArray(self, ca);
  /* data_type / shape / argument validation as needed */

  /* === Block 2: output — allocate result array ==================== */
  /* fill slab_axes[] from argv, then: */
  VALUE vout = rb_ca_new_reduced(self, slab_axes, naxes, OUT_DTYPE);
  GetCArray(vout, co);

  /* === Block 3: iter init — open the slab walk ==================== */
  ca_iter_state st;
  int rc = ca_iter_state_init_l2(&st, ca, CA_SLAB_AXES,
                                 slab_axes, naxes, 0);
  if ( rc != CA_ITER_OK ) {
    rb_raise(rb_eRuntimeError, "kernel_iterator init failed rc=%d", rc);
  }

  /* === Block 4: per-slab kernel — write the actual work =========== */
  char *p; boolean8_t *m;
  ca_size_t out_i = 0;
  while ( ca_iter_state_next_slab_axes(&st, &p, &m) ) {
    /* <KERNEL_LOGIC>: walk the slab, write op[out_i++] */
  }
  ca_iter_state_finish(&st);

  return vout;
}
```

The four blocks are:

1. **Input**: `GetCArray(self, ca)` unwraps the Ruby `VALUE` to a
   `CArray *`. Validate data_type / shape / arguments as needed.
2. **Output**: `rb_ca_new_reduced` allocates a fresh CArray whose
   shape equals the input shape with `slab_axes` removed.
3. **Iter init**: `ca_iter_state_init_l2` opens a K-D slab walk
   over the input. `CA_SLAB_AXES` policy tells the iterator which
   axes form each slab.
4. **Per-slab kernel**: `next_slab_axes` yields one slab at a time
   (pointer + mask). Your kernel walks the slab K-dimensionally
   using metadata from the state struct (`st.slab_dims`,
   `st.slab_strides`).

`ca_iter_state_finish` releases iterator resources (detaches parent,
frees scratch). Call it exactly once after `init`.

## 3. A minimal sum kernel

Let's build a `sum_ki` that reduces a single axis of a float64
CArray. (This is an illustrative hand-written form; the production
`sum` is generated by the mkkernel DSL — see §6.6 — but the same
four-block shape underlies the generated code.)

```c
#include "carray.h"
#include "ca_kernel_iterator.h"

static VALUE
rb_ca_sum_one_axis (VALUE self, VALUE vaxis)
{
  CArray *ca, *co;
  int8_t  slab_axes[1];

  /* Block 1: input */
  GetCArray(self, ca);
  if ( ca->data_type != CA_FLOAT64 ) {
    rb_raise(rb_eRuntimeError, "sum: float64 only");
  }
  slab_axes[0] = (int8_t) NUM2INT(vaxis);

  /* Block 2: output */
  VALUE vout = rb_ca_new_reduced(self, slab_axes, 1, CA_FLOAT64);
  GetCArray(vout, co);

  /* Block 3: iter init */
  ca_iter_state st;
  int rc = ca_iter_state_init_l2(&st, ca, CA_SLAB_AXES,
                                 slab_axes, 1, 0);
  if ( rc != CA_ITER_OK ) {
    rb_raise(rb_eRuntimeError, "init failed rc=%d", rc);
  }

  /* Block 4: per-slab — slab is 1-D, walk linearly */
  double     *op = (double *) co->ptr;
  char       *p;
  boolean8_t *m;
  ca_size_t   out_i = 0;
  while ( ca_iter_state_next_slab_axes(&st, &p, &m) ) {
    double acc = 0.0;
    ca_size_t stride = st.slab_strides[0];
    ca_size_t n      = st.slab_dims[0];
    for ( ca_size_t j = 0; j < n; j++ ) {
      if ( m == NULL || !m[j * st.slab_mask_strides[0]] ) {
        acc += *(double *)(p + j * stride);
      }
    }
    op[out_i++] = acc;
  }
  ca_iter_state_finish(&st);

  return vout;
}
```

**What you wrote:** the per-cell accumulation `acc += *(double *)(p + j*stride)`.

**What you didn't write:**
- View materialisation (your source can be a transposed view, a
  CAStride chain, a slice — same kernel code works)
- Parent `ca_attach` / `ca_detach`
- Output dim calculation (`rb_ca_new_reduced` derived it from `slab_axes`)
- Outer axis walk (the iterator yields one slab per non-slab cell)
- Mask gather (`scratch_mask` materialisation is hidden)

## 4. Multi-axis reduction with CA_SLAB_AXES

`CA_SLAB_AXES` accepts any subset of axes via `slab_axes[]`. The slab
is then K-dimensional, and the iterator yields one K-D slab per
combination of the remaining (outer) axes.

For `ca.sum(axis: [2, 3])` on a 4-D array shape (2, 3, 4, 5):

```c
int8_t slab_axes[] = {2, 3};
ca_iter_state_init_l2(&st, ca, CA_SLAB_AXES, slab_axes, 2, 0);
```

The state struct is populated with:

| field | value | meaning |
|---|---|---|
| `st.slab_ndim` | `2` | K-D slab |
| `st.slab_dims` | `{4, 5}` | size along slab axis 0 (=ca axis 2), slab axis 1 (=ca axis 3) |
| `st.slab_strides` | `{20, 4}` | byte strides through `p` for the K-D walk |
| `st.slab_elements` | `20` | `Π slab_dims` |
| `st.outer_ndim` | `2` | outer walk axes |
| `st.outer_dims` | `{2, 3}` | walked by the iterator, not by you |

Your kernel walks each yielded slab using `slab_dims` /
`slab_strides`. A general K-D walk:

```c
while ( ca_iter_state_next_slab_axes(&st, &p, &m) ) {
  double acc = 0.0;
  ca_size_t idx[CA_RANK_MAX] = { 0 };
  for ( ca_size_t c = 0; c < st.slab_elements; c++ ) {
    ca_size_t data_off = 0;
    ca_size_t mask_off = 0;
    for ( int8_t k = 0; k < st.slab_ndim; k++ ) {
      data_off += idx[k] * st.slab_strides[k];
      mask_off += idx[k] * st.slab_mask_strides[k];
    }
    if ( m == NULL || !m[mask_off] ) {
      acc += *(double *)(p + data_off);
    }
    /* advance idx row-major */
    for ( int8_t k = st.slab_ndim - 1; k >= 0; k-- ) {
      if ( ++idx[k] < st.slab_dims[k] ) break;
      idx[k] = 0;
    }
  }
  op[out_i++] = acc;
}
```

**Note on SIMD performance.** The naïve all-flat K-D walk shown above
is *correct* but the runtime-bound `slab_ndim` prevents compiler
auto-vectorisation. A better pattern that handles all `slab_ndim`
uniformly while preserving SIMD on the inner loop:

- Walk the **outer K-1 slab axes** with a carry-style `idx[]`
- Make the **innermost slab axis** a tight inner loop with a constant
  stride hoisted out — this is the SIMD candidate

```c
while ( ca_iter_state_next_slab_axes(&st, &p, &m) ) {
  double acc = 0.0;
  int8_t K       = st.slab_ndim;
  int8_t outer_K = K - 1;
  ca_size_t inner_n = st.slab_dims[K-1];
  ca_size_t inner_s = st.slab_strides[K-1];

  ca_size_t outer_count = 1;
  for ( int8_t k = 0; k < outer_K; k++ ) outer_count *= st.slab_dims[k];

  ca_size_t idx[CA_RANK_MAX] = { 0 };
  for ( ca_size_t o = 0; o < outer_count; o++ ) {
    ca_size_t data_off = 0;
    for ( int8_t k = 0; k < outer_K; k++ ) {
      data_off += idx[k] * st.slab_strides[k];
    }
    const char *q = p + data_off;

    /* Tight inner loop — SIMD candidate when inner_s == sizeof(double) */
    if ( inner_s == (ca_size_t) sizeof(double) ) {
      const double *src = (const double *) q;
      for ( ca_size_t j = 0; j < inner_n; j++ ) acc += src[j];
    } else {
      for ( ca_size_t j = 0; j < inner_n; j++ ) {
        acc += *(const double *)(q + j * inner_s);
      }
    }

    /* Advance outer idx row-major (no-op when outer_K == 0) */
    for ( int8_t k = outer_K - 1; k >= 0; k-- ) {
      if ( ++idx[k] < st.slab_dims[k] ) break;
      idx[k] = 0;
    }
  }
  op[out_i++] = acc;
}
```

This pattern is **structurally equivalent to manually transposing the
source so the reduce axis is innermost, then running a 1-D strided
sum** — but it's expressed within the K-D yield framework, so no
view transformation is needed. The kernel handles `slab_ndim` = 1, 2,
3, ..., uniformly with the same code.

For `slab_ndim == 1`, the outer walk runs exactly once and the inner
loop is the entire kernel — matching the simplest tight 1-D sum
verbatim.

The `CA_SLAB_REDUCE_*` macro suite (§6.5) collapses this pattern
into a single line and adds per-data_type expansion, but the shape above is
exactly what the macros generate.

**Order convention.** `slab_axes` are canonicalised to ascending
order internally, regardless of input order. `{3, 0, 2}` and
`{0, 2, 3}` produce identical iteration. Slab layout reflects the
input array's row-major ordering of the (sorted) slab axes.

**All-axes case.** When `slab_axes` covers all axes, `outer_ndim = 0`
and the iterator yields a single slab equal to the whole array
(equivalent to `CA_SLAB_WHOLE` policy). The output is a shape `[1]`
1-D CArray; you write `op[0] = acc` and unwrap to a Ruby Float at the
end if desired (this is what `sum_ki` does to match `CArray#sum`'s
full-reduction surface).

## 5. Map kernels — element-wise transforms

A **map kernel** applies a per-cell transform to every element, producing
an output with the same shape as the input (e.g. `sqrt`, `exp`, `clamp`).
This is the second canonical shape for kernel_iterator authors (the
first being reduction, §3-4).

### 5.1 The two-iter pattern

A map kernel walks **both** the input and the output K-D-wise. The
cleanest pattern uses two `ca_iter_state` instances in lockstep —
one for the input view, one for the output entity:

```c
static VALUE
rb_ca_sqrt_along (int argc, VALUE *argv, VALUE self)
{
  CArray *ca, *co;
  int8_t  slab_axes[CA_RANK_MAX];
  int8_t  naxes;

  /* Block 1: input + axis: kwarg parsing */
  VALUE vsrc = rb_ca_wrap_readonly(self, INT2NUM(CA_FLOAT64));
  GetCArray(vsrc, ca);
  volatile VALUE ropt = rb_pop_options(&argc, &argv);
  volatile VALUE raxis = Qnil;
  rb_scan_options(ropt, "axis", &raxis);
  naxes = rb_ca_parse_reduce_axes_kw(raxis, ca, slab_axes);

  /* Block 2: output — same shape as input for map */
  VALUE vout = rb_carray_new(CA_FLOAT64, ca->ndim, ca->dim,
                             sizeof(double), NULL);
  GetCArray(vout, co);

  /* Block 3: dual iter init — input READ, output WRITE */
  ca_iter_state st_in, st_out;
  int rc;
  rc = ca_iter_state_init_l2(&st_in,  ca, CA_SLAB_AXES,
                             slab_axes, naxes, 0);
  if ( rc != CA_ITER_OK ) {
    rb_raise(rb_eRuntimeError, "sqrt_along: input init failed rc=%d", rc);
  }
  rc = ca_iter_state_init_l2(&st_out, co, CA_SLAB_AXES,
                             slab_axes, naxes, CA_KERNEL_WRITE);
  if ( rc != CA_ITER_OK ) {
    ca_iter_state_finish(&st_in);
    rb_raise(rb_eRuntimeError, "sqrt_along: output init failed rc=%d", rc);
  }

  /* Block 4: per-slab kernel — paired walk */
  char *pi, *po;
  boolean8_t *mi, *mo;
  while ( ca_iter_state_next_slab_axes(&st_in,  &pi, &mi) &&
          ca_iter_state_next_slab_axes(&st_out, &po, &mo) ) {
    int8_t    K  = st_in.slab_ndim;
    int8_t    OK = K - 1;
    ca_size_t in_inner_n  = st_in.slab_dims[K-1];
    ca_size_t in_inner_s  = st_in.slab_strides[K-1];
    ca_size_t out_inner_s = st_out.slab_strides[K-1];

    ca_size_t outer_count = 1;
    for ( int8_t k = 0; k < OK; k++ ) outer_count *= st_in.slab_dims[k];

    ca_size_t idx[CA_RANK_MAX] = { 0 };
    for ( ca_size_t o = 0; o < outer_count; o++ ) {
      ca_size_t in_off = 0, out_off = 0;
      for ( int8_t k = 0; k < OK; k++ ) {
        in_off  += idx[k] * st_in.slab_strides[k];
        out_off += idx[k] * st_out.slab_strides[k];
      }
      const char *qi = pi + in_off;
      char       *qo = po + out_off;
      for ( ca_size_t j = 0; j < in_inner_n; j++ ) {
        double v = *(const double *)(qi + j * in_inner_s);
        *(double *)(qo + j * out_inner_s) = sqrt(v);
      }
      /* advance idx */
      for ( int8_t k = OK - 1; k >= 0; k-- ) {
        if ( ++idx[k] < st_in.slab_dims[k] ) break;
        idx[k] = 0;
      }
    }
    ca_iter_state_sync_slab(&st_out);
  }
  ca_iter_state_finish(&st_in);
  ca_iter_state_finish(&st_out);
  return vout;
}
```

The kernel logic is the inner `sqrt` call. Everything else is the
same shape as the reduction template (§4).

### 5.2 Why two iters?

For a map kernel where input shape == output shape, why not just
use one iter and compute the output ptr manually?

**One-iter pattern (= simpler when output is a fresh entity)**:

```c
VALUE vout = rb_carray_new(CA_FLOAT64, ca->ndim, ca->dim,
                           sizeof(double), NULL);
GetCArray(vout, co);
double *op_base = (double *) co->ptr;
ca_size_t out_row_stride[CA_RANK_MAX];
{
  ca_size_t s = 1;
  for ( int8_t k = ca->ndim - 1; k >= 0; k-- ) {
    out_row_stride[k] = s;
    s *= ca->dim[k];
  }
}
ca_iter_state st;
ca_iter_state_init_l2(&st, ca, CA_SLAB_AXES, slab_axes, naxes, 0);

char *pi; boolean8_t *mi;
while ( ca_iter_state_next_slab_axes(&st, &pi, &mi) ) {
  /* compute output ptr from outer_idx and slab_axes_buf */
  ca_size_t out_off_el = 0;
  for ( int8_t m = 0; m < st.outer_ndim; m++ ) {
    out_off_el += st.outer_idx[m] * out_row_stride[st.outer_axes[m]];
  }
  /* ...inner walk... */
}
```

This works because the output is a freshly allocated entity — its
layout is row-major and we own it. **For Phase B, this one-iter
pattern is acceptable** when input shape == output shape AND output
is freshly allocated. The two-iter pattern (§5.1) is more general
(= input and output can have different stride layouts, e.g., output
into a pre-existing strided view).

Note that `outer_idx[]` is the *iterator's* internal cursor — it
advances inside `next_slab_axes` *after* yielding the current slab,
so reading it inside the loop gives the index for **the next** slab.
To get the current outer index, decrement `slabs_emitted` mentally
(= the slab just yielded was at logical-position `slabs_emitted - 1`).
The two-iter pattern (§5.1) avoids this gotcha because each iter
maintains its own cursor.

### 5.3 Mask propagation

For map kernels with a masked input, the output should inherit the
mask: cells where the input is UNDEF should be UNDEF in the output.

```c
/* inside the per-cell loop */
ca_size_t mi_off = ...;  /* mask element offset for this cell */
if ( mi && mi[mi_off] ) {
  /* input UNDEF: write 0 to data, set mask bit in output */
  *(double *)(qo + j * out_inner_s) = 0.0;
  /* mark output as masked too — see §6.2 for the mask layout */
} else {
  *(double *)(qo + j * out_inner_s) = sqrt(*(const double *)(qi + j * in_inner_s));
}
```

The output mask write requires the output to have a mask allocated
(= `rb_carray_new(..., mask)` with a non-NULL mask). For most map
kernels, the simplest path is: if input has mask, propagate it via
`ca_copy(src->mask, co->mask)` after allocation, then your kernel
only needs to skip masked cells on **read** (= the propagated mask
already marks them as UNDEF in the output).

## 6. Block macros: CA_FOR_EACH_SLAB / _INOUT / _FIBER + macro suite

CArray 3.0 ships block macros that wrap the init / next / sync / finish
lifecycle for the common kernel patterns, so you write the kernel body in
a single block scope without manual plumbing. Two families of delivery
macros — the slab forms (`CA_FOR_EACH_SLAB` / `_INOUT`, §6.1–6.2) and the
contig-fiber forms (`CA_FOR_EACH_FIBER` family, §6.3) — plus the
one-expression `CA_SLAB_*` suite (§6.5), the mkkernel generator (§6.6),
and the SIMD reduction license (§6.7).

### 6.1 CA_FOR_EACH_SLAB (single-iter, reduction or in-place WRITE)

```c
ca_iter_state st;
char       *p;
boolean8_t *m;
CA_FOR_EACH_SLAB(st, ca, slab_axes, naxes, 0, p, m) {
  /* per-slab kernel body — p is data, m is mask (or NULL) */
}
```

The macro expands to:
- `ca_iter_state_init_l2(&st, ca, CA_SLAB_AXES, axes, naxes, flags)` (once at entry; the policy is fixed internally)
- `while (ca_iter_state_next_slab_axes(&st, &p, &m))` (loop)
- `ca_iter_state_sync_slab(&st)` (after each iter, no-op when READ)
- `ca_iter_state_finish(&st)` (on natural exit or `break`)

`p` and `m` must be pre-declared (C99 doesn't permit different-typed
declarations inside `for` init, so the cursors live in the surrounding
scope).

### 6.2 CA_FOR_EACH_SLAB_INOUT (parallel iter, map kernel)

```c
ca_iter_state st_in, st_out;
char       *p_in, *p_out;
boolean8_t *m_in, *m_out;
CA_FOR_EACH_SLAB_INOUT(st_in, st_out, ca_in, ca_out,
                       slab_axes, naxes,
                       p_in, p_out, m_in, m_out) {
  /* per-slab map body — p_in -> p_out cell by cell */
}
```

Runs two iterators in lockstep — input is READ, output is WRITE — with
`sync_slab` on the output after each iteration. Shape match between
`ca_in` and `ca_out` is **not validated** by the macro (caller responsibility,
typically `ca_out = rb_ca_template_with_type(ca_in, data_type, Qnil)`).

### 6.3 CA_FOR_EACH_FIBER family — contig-delivery block macros

When a kernel needs a **contiguous buffer along one axis** (libc
`qsort` / `bsearch`, per-axis SIMD, FFT-along-axis — anything that walks
`p[i]` without stride math), the `CA_FOR_EACH_FIBER` family is the right
block macro. It pins a single axis as the slab and **guarantees contig
delivery**: the engine gathers strided fibers into per-state scratch when
`slab_strides[0] != bytes`, so your body never sees a stride argument.
`CA_KERNEL_FIBER_CONTIG` is auto-set; for INOUT forms `CA_KERNEL_WRITE`
is auto-set on the output.

Four forms (worked examples in §7.5):

| Macro | Signature | Delivers |
|---|---|---|
| `CA_FOR_EACH_FIBER` | `(st, ca, axis, flags, p, n)` | contig data `p[0..n-1]` |
| `CA_FOR_EACH_FIBER_MASKED` | `(st, ca, axis, flags, p, n, m)` | + contig mask `m` (NULL if no-mask source) |
| `CA_FOR_EACH_FIBER_INOUT` | `(st_in, st_out, ca_in, ca_out, axis, flags, p_in, p_out, n)` | contig input + output, in parallel |
| `CA_FOR_EACH_FIBER_INOUT_MASKED` | `(st_in, st_out, ca_in, ca_out, axis, flags, p_in, p_out, n, m)` | + contig input mask `m` |

`n` is set to the fiber length (`= slab_dims[0]`, constant for the walk).
`axis` and the `ca` operands are each evaluated once at init.

```c
ca_iter_state st;
double     *p;
boolean8_t *m;
ca_size_t   n;
CA_FOR_EACH_FIBER_MASKED(st, ca, axis, 0, p, n, m) {
  for ( ca_size_t i = 0; i < n; i++ ) {
    if ( !m || !m[i] ) { /* p[i] is contig — no stride math */ }
  }
}
```

Contract / constraints:

- **Contig delivery is the whole point.** Use the FIBER family only when
  the body actually *uses* the contig buffer (sorts / FFTs it, runs SIMD
  on `p[i]`). If the body just reads through a stride into its own buffer
  or returns a scalar, the gather is wasted work — use `CA_FOR_EACH_SLAB`
  instead (see §0.2 "How to pick").
- **INOUT requires strict full shape equality** of `ca_in` / `ca_out`
  (same ndim, same `elements`, same `dim[axis]`). The macro runtime-
  asserts this in the loop condition and **silently skips** the body on
  mismatch (= plugs the silent-corruption seam where two iterators would
  otherwise short-circuit on the shorter fiber count). Broadcasting needs
  the raw API.
- Same lifecycle constraints as the SLAB family (§6.4): `break;` exits
  cleanly (finish runs); `return;` from the body **leaks** scratch +
  parent attach (drop to the raw API); the macros are not statement-
  equivalent (no trailing `else`).
- Single-axis only. For multiple slab axes or K-D slab geometry, use
  `CA_FOR_EACH_SLAB` (§6.1).

### 6.4 When the macros are NOT appropriate

The macros silently discard init errors (= body runs zero times, `finish`
called as if init succeeded). For production kernels that need explicit
error reporting like `sum_ki` raising `"rc=%d"`, drop down to the raw
API:

```c
int rc = ca_iter_state_init_l2(&st, ca, policy, axes, naxes, flags);
if ( rc != CA_ITER_OK ) {
  rb_raise(rb_eRuntimeError, "kernel init failed rc=%d", rc);
}
/* manual while + finish */
```

Other constraints:
- `break;` from inside the block correctly triggers `finish` (= outer
  for's increment clause runs once on natural exit; `break` from the
  inner while breaks both loops).
- `return;` inside the block **leaks** scratch buffers and the parent
  attach. Drop to raw API if early return is needed.
- The macros are NOT statement-equivalent — don't follow them with
  `else` etc.

For new simple kernels (= no exotic error handling), prefer the macros.
The reference `sum_ki` retains the raw API for backward-compatible error
messages; new kernels are encouraged to start from the macro form.

### 6.5 Phase D macro suite: 1-expression reduction and map

Phase D lifts the **inner walk** (= K-1 outer carry + innermost
SIMD-friendly inner + mask + contig-stride dispatch hoist) out of the
hand-written body in §3/§4/§5 into a single block macro. The author
supplies only the init expression and the per-cell reduction or
transform expression — everything else, including stride/mask
dispatch, is engine-supplied.

#### 6.5.1 CA_SLAB_REDUCE_T — reduction in one expression

```c
/* The reference shape from §4, lifted to the macro: */
while ( ca_iter_state_next_slab_axes(&st, &p, &m) ) {
  double acc;
  CA_SLAB_REDUCE_T(double, st, p, m, acc, 0.0, acc += v);
  /*               ^load   ^state  ^acc  ^INIT ^REDUCE expression
                                                 — `v` bound per cell */
  op[out_i++] = acc;
}
```

The macro generates the same canonical walk (= outer K-1 carry +
innermost SIMD inner, with mask/contig hoisted out) as the §4
walkthrough. You supply:

- `T_LOAD`: element load type (`double`, `float`, `int32_t`, …).
  `sizeof(T_LOAD)` is used for the contig-stride check.
- `acc`: caller-declared lvalue; may be wider than `T_LOAD` (e.g.,
  `double acc` reducing `int32_t` source — implicit widening in
  `acc += v` handles the cast per cell).
- `INIT`: initial value (`0.0`, `0`, `INFINITY`, `-INFINITY`, …).
- `REDUCE`: statement folding `v` (the current element, type `T_LOAD`)
  into `acc`. Examples:
    - sum:  `acc += v`
    - prod: `acc *= v`
    - max:  `if (v > acc) acc = v`
    - mean: `(acc += v, cnt++)`  (caller declares `cnt`)

Convenience aliases for the four standard numeric data_types:

| Macro                | Forwards to                          |
|----------------------|--------------------------------------|
| `CA_SLAB_REDUCE_F64` | `CA_SLAB_REDUCE_T(double, ...)`      |
| `CA_SLAB_REDUCE_F32` | `CA_SLAB_REDUCE_T(float, ...)`       |
| `CA_SLAB_REDUCE_I32` | `CA_SLAB_REDUCE_T(int32_t, ...)`     |
| `CA_SLAB_REDUCE_I64` | `CA_SLAB_REDUCE_T(int64_t, ...)`     |

Use `CA_SLAB_REDUCE_T` directly for non-standard element types
(`boolean8_t`, `int8_t`, `uint16_t`, complex, …).

Mask semantics: when `m != NULL`, masked cells are skipped (REDUCE is
not invoked). When `m == NULL`, every cell contributes.

#### 6.5.2 The reduction family at the macro surface

Sibling reductions reuse the same surface — only the init and REDUCE
expression change:

```c
/* sum  */ CA_SLAB_REDUCE_F64(st, p, m, acc, 0.0,        acc += v);
/* mean */ CA_SLAB_REDUCE_F64(st, p, m, acc, 0.0,        (acc += v, cnt++));
/* min  */ CA_SLAB_REDUCE_F64(st, p, m, acc,  INFINITY,  if (v < acc) acc = v);
/* max  */ CA_SLAB_REDUCE_F64(st, p, m, acc, -INFINITY,  if (v > acc) acc = v);
/* prod */ CA_SLAB_REDUCE_F64(st, p, m, acc, 1.0,        acc *= v);
/* var  */ /* needs second-moment accumulator; same shape */
```

The canonical `sum_ki` kernel is now ~6 lines of per-slab body. The
surrounding boilerplate (input wrap, axis parse, output alloc, iter
init, full-vs-partial return) is exactly what the mkkernel DSL (§6.6)
generates for you; for a hand-written reduction, the §10 argument
helpers cover the same input/output blocks.

#### 6.5.3 CA_SLAB_MAP_T — element-wise transform in one expression

```c
ca_iter_state st_in, st_out;
/* ...init both with CA_SLAB_AXES + slab_axes = all axes... */

char       *p_in, *p_out;
boolean8_t *m_in, *m_out;
while ( ca_iter_state_next_slab_axes(&st_in,  &p_in,  &m_in)  &&
        ca_iter_state_next_slab_axes(&st_out, &p_out, &m_out) ) {
  CA_SLAB_MAP_T(double, double, st_in, p_in, st_out, p_out,
                r = sqrt(v));
  /*            ^T_IN   ^T_OUT  ...                  ^MAP_EXPR
                                                       — `v` in,
                                                         `r` out lvalue */
  ca_iter_state_sync_slab(&st_out);
}
```

The macro walks both states in lockstep with outer K-1 carry +
innermost SIMD inner and independent contig checks on input/output.
You supply:

- `T_IN`, `T_OUT`: element types (independent, allowing widening
  maps like `int32_t → double`).
- `MAP_EXPR`: statement binding `r` (output lvalue) from `v` (input
  element). Examples:
    - sqrt: `r = sqrt(v)`
    - square: `r = v * v`
    - cast + clamp: `r = (T_OUT) (v < 0 ? 0 : (v > MAX ? MAX : v))`

Convenience alias `CA_SLAB_MAP_F64` = `CA_SLAB_MAP_T(double, double, ...)`.

Mask handling is **not** done by `CA_SLAB_MAP_T` itself. If the input
is masked, MAP_EXPR is still evaluated for every cell; the caller is
responsible for propagating the input mask to the output (e.g. via
`ca_copy_mask` after output allocation, so masked input cells produce
masked output cells regardless of what the inner expression wrote).

Map kernels use **`CA_SLAB_AXES` with all axes** (`slab_axes = [0..ndim-1]`,
`naxes = ndim`) for pure element-wise transforms. `CA_SLAB_WHOLE`
is **not compatible** with `next_slab_axes` — it uses the flat
`next_slab` path which does not populate `slab_dims` (pin to remember
when prototyping new map kernels).

#### 6.5.4 Native per-data-type dispatch

For source data_types outside the accumulator type, the
`rb_ca_wrap_readonly` helper (§10.1) auto-casts via `CAFake` —
convenient but it pays a per-element cast on the hot path. The faster
pattern is **native dispatch**: a `switch (src->data_type)` that calls a
per-data-type helper using `CA_SLAB_REDUCE_T(T_LOAD, ...)` to read the
source type directly (accumulating in a wider type), with the
`wrap_readonly` path kept only as the fallback for data_types without a
native helper.

This is exactly what the mkkernel DSL emits for every `MkKernel.reduce`
declaration — one native helper per `source:` data_type plus the
dispatcher and the fallback (`fallback: :wrap_to_f64` or `:raise`). In
other words, you almost never hand-write the dispatch: declare the
kernel in the DSL (§6.6) and the generator produces the native
per-data-type `switch` for you. Hand-write it only for a kernel the DSL
can't express, following the same shape (per-type helper +
`CA_SLAB_REDUCE_T` body + dispatcher).

### 6.6 Generator-driven codegen with `mkkernel.rb`

> This section explains how the generated kernels relate to the §6.5
> macros. For the **full DSL reference** — every entry point
> (reduce / map / scan / sort / search / monop / binop / moncmp /
> bincmp), every option, the `:object` branch, output resolution, the
> SIMD license — see [`MkKernelDSL.md`](MkKernelDSL.md).

Writing one `CA_SLAB_REDUCE_T` body per source data type by hand is
tolerable for one kernel and unbearable for a family (sum / prod / min /
max across ~10 data types, each with its own accumulator init and Ruby
scalar wrapper). `ext/mkkernel.rb` is the code generator that owns that
boilerplate: you declare the *shape* of a kernel in a compact Ruby DSL,
and it emits the per-data-type helpers (each built on the `CA_SLAB_*`
macros from §6.5), the data-type dispatcher, and the `rb_define_method`
registration into `ext/carray_kernels.c`. It is a sibling to the legacy
`mkmath.rb` (which targets the 2.x eager operators) but built clean for
the kernel_iterator surface.

```ruby
MkKernel.reduce :sum,
  init:        "0",
  reduce:      "acc += v",          # the CA_SLAB_REDUCE_T body, per data type
  source:      MkKernel::ALL_NUMERIC,
  output:      :f64,
  ruby_scalar: :rb_float_new,
  fallback:    :wrap_to_f64
```

Each DSL form maps onto one of the §6.5 macros (or, for sort/search, a
fiber/slab walk):

| DSL form | emits per data type | underlying surface |
|---|---|---|
| `MkKernel.reduce` | a reduction helper + dispatcher | `CA_SLAB_REDUCE_T` (or the SIMD-licensed `_PLUS/_MIN/_MAX/_STAR_EX` variants when `reduction_kind:` is set; `CA_SLAB_REDUCE_ARRAY_T*` for `array_arg` weighted reductions) |
| `MkKernel.map` | an element-wise helper | `CA_SLAB_MAP_T` |
| `MkKernel.scan` | a prefix-scan helper | `CA_SLAB_SCAN_T` / `CA_SLAB_SCAN_TA` |
| `MkKernel.sort` | a per-fiber position kernel (argsort / partition / rank) | `CA_FOR_EACH_FIBER` + a hand-rolled stable sort / quickselect |
| `MkKernel.search` | a per-slab search (author-written C body) | `CA_FOR_EACH_SLAB` walk |
| `MkKernel.monop / binop / triop / moncmp / bincmp` | eager element-wise math / compare helpers | the mkmath-convention element loop (run via the `rb_ca_call_*` bridges) |

**Regenerating.** The generator runs at build time when `mkkernel.rb`
is newer than `carray_kernels.c` (`ext/extconf.rb` + the Makefile rule).
To regenerate by hand: `cd ext && ruby mkkernel.rb > carray_kernels.c`.
`CARRAY_DEV=1 rake build_ext` picks up DSL edits automatically.

#### 6.6.1 When to use the generator vs hand-writing

- **Generator (`MkKernel.*`)** — the default landing point for any new
  op that fits one of the forms above. Do not hand-write a kernel
  wrapper into `carray_math.c` / `carray_stat.c`; that bypasses the DSL
  (a discipline violation, see [`MkKernelDSL.md`](MkKernelDSL.md)).
- **Hand-written with the §6.5 macros** — kernels whose inner loop the
  DSL can't express (exotic per-cell control flow, multi-source fusion
  no DSL form covers). Rare; justify it.
- **Hand-written without macros** — only for inner loops that don't fit
  the slab / fiber walk at all.

The reduce / map / scan / sort / search families, the full math /
compare family, and the `:object` (per-cell Ruby) branch all ship
through the generator today — the kernel author surface is "one DSL
block per kernel". See [`MkKernelDSL.md`](MkKernelDSL.md) for the
complete option reference.


### 6.7 SIMD reduction license (SL.1.x, 2026-06-12)

CArray 3.0 ships with `-fopenmp-simd` enabled at build time (probed
in `ext/extconf.rb`, graceful fallback when unsupported). This unlocks
`#pragma omp simd reduction(<kind>:<var>)` for any reduction loop in
ext code, with measured 8-14x throughput gains on contig hot paths
(sum 8x, variance 8.2x, prod 8.5x, weighted sum/mean 4.5-6x via
FMA).

There are **two ways** an ext author can get the license:

#### 6.7.1 Automatic (via mkkernel DSL)

When you register a reduction kernel through `MkKernel.reduce`, add
`reduction_kind:` to declare the OpenMP reduction class. The generator
routes the kernel through the SIMD-licensed macro variant
(`CA_SLAB_REDUCE_T_PLUS_EX` / `_MIN_EX` / `_MAX_EX` / `_STAR_EX` for
single-acc, `CA_SLAB_REDUCE_ARRAY_T_PLUS_EX` for parallel-array
weighted reductions). No author-side pragma needed.

```ruby
MkKernel.reduce :sum,
  init:            "0",
  reduce:          "acc += v",
  reduction_kind:  :plus,         # ← unlocks _CA_SIMD_PLUS(acc) in the loop
  source:          MkKernel::ALL_NUMERIC + MkKernel::CMPLX_DTYPES,
  output:          { numeric: :f64, complex: :cmplx128 }
```

Accepted values:

| `reduction_kind:` | OpenMP clause                  | macro variant                  | typical REDUCE |
|-------------------|--------------------------------|--------------------------------|----------------|
| `:none` (default) | (no pragma)                    | `CA_SLAB_REDUCE_T_EX`          | argmin / argmax / sort-by-state / any control flow |
| `:plus`           | `reduction(+:acc)`             | `CA_SLAB_REDUCE_T_PLUS_EX`     | sum, mean, count, accumulate, wsum (FMA) |
| `:min`            | `reduction(min:acc)`           | `CA_SLAB_REDUCE_T_MIN_EX`      | integer min (auto-vec'd anyway); float min limited on Apple clang |
| `:max`            | `reduction(max:acc)`           | `CA_SLAB_REDUCE_T_MAX_EX`      | symmetric to min |
| `:star`           | `reduction(*:acc)`             | `CA_SLAB_REDUCE_T_STAR_EX`     | prod (float/real); complex prod stays at baseline |
| `{a: :plus, b: :plus, c: :induction}` | (Hash form, kind of `state.keys.first`) | (PLUS for the primary acc) | variance / stddev / wmean — clang chains derived accumulators via idiom recognition, single pragma is sufficient |

Default `:none` keeps the kernel on the legacy `_EX` path with no
SIMD license — this is the right choice for argmin/argmax (lane
tracking can't be expressed as OpenMP reduction), any/all (real win
is short-circuit, not vectorization), `_strict` / `_safe` family
(bit-exact contract), and anything with hard-to-vectorize control
flow inside the body.

#### 6.7.2 Manual (hand-written `CA_FOR_EACH_SLAB` body)

When you write a custom inner loop inside `CA_FOR_EACH_SLAB` instead
of using the `CA_SLAB_REDUCE_*` macro family, the SIMD license is
**not** applied automatically — but you can still write the pragma
yourself directly above the inner loop:

```c
double acc = 0;
CA_FOR_EACH_SLAB(st, self, slab_axes, naxes, 0, p, m) {
  ca_size_t innerN = st.slab_dims[st.slab_ndim - 1];
  ca_size_t innerS = st.slab_strides[st.slab_ndim - 1];
  if ( m == NULL && innerS == (ca_size_t)sizeof(double) ) {
    const double *src = (const double *)p;
    #pragma omp simd reduction(+:acc)
    for ( ca_size_t j = 0; j < innerN; j++ ) {
      acc += src[j];
    }
  } else {
    /* fall back to scalar masked/non-contig path */
  }
}
```

The `_CA_SIMD_PLUS(var)` / `_MIN` / `_MAX` / `_STAR` helper macros in
`ext/ca_kernel_iterator.h` encode the same pragma with parameter
substitution (= `_Pragma + _CA_XSTR(...)` trick) so the accumulator
lvalue can be supplied at use time. They're prefixed `_` to flag
internal-status — usable from ext code if you want the symmetry with
the substrate, but the public escape hatch is the explicit `#pragma`
above which doesn't depend on the prefix being stable.

#### 6.7.3 When SIMD won't help (= keep `:none` / skip the pragma)

Empirically observed from the SL.1.x landed measurements:

- **Float min/max on Apple clang**: `reduction(min:)` / `(max:)` is
  parsed but the vectorizer rejects with `loop not vectorized: the
  optimizer was unable to perform the requested transformation`. Gain
  is zero. Integer min/max auto-vec'd at -O3 anyway (4-lane `smin.4s`
  on int32, etc.), so `reduction_kind: :min` doesn't hurt — it just
  doesn't help on this compiler. gcc-15 honors the clause but ARM
  `fminnm` latency caps f64 min/max at ~25 GB/s regardless.
- **Complex multiplication** (`cmplx64_t` / `cmplx128_t` prod):
  clang `reduction(*:)` doesn't extend the SIMD treatment to complex
  multiplication primitive. Emits `loop not vectorized` warning.
  Stays at baseline ~6.3 GB/s. Float real prod vectorizes fine.
- **Constant-folded loops**: kernels like `:count` whose REDUCE is
  `(void)v; acc += 1` get folded to `acc = N` by clang well before
  vectorization. The pragma is documentation-only.
- **`acc += !v` (count_false)**: predication adds compare + select
  steps; measured ~2.5x slower than `acc += v` (count_true) on
  identical bool inputs. `:plus` still applies, just less payoff
  than the no-negation form.

#### 6.7.4 ε-close contract

Hot-path reductions (sum / mean / variance / stddev / prod / wsum /
wmean / accumulate) return ε-close values (rel_err < 1e-14 typical
on f64), not bit-exact. SIMD lane parallelization makes the final
addition order input-shape-dependent — same input, different
environment may differ in the last ULP. This is IEEE 754 well-defined
floating-point arithmetic, not a bug. The `_strict` / `_safe`
variants keep bit-exact ordering by staying on the legacy non-SIMD
path. Pin: don't use `assert_equal` for f64 reduction parity in spec
tests; use rel_err comparisons.

## 7. Cookbook: kernel pattern catalog

This section catalogues five typical kernel patterns. Each is a
standalone recipe; you can read them in any order. The earlier sections
(§3-§5) walk through reduction and map patterns in detail; this section
provides a unified index and adds the convolve / sort / fiber patterns
that weren't covered earlier.

The five patterns:

| # | Pattern | Macro | Section |
|---|---|---|---|
| 1 | Reduction | `CA_FOR_EACH_SLAB` / `CA_SLAB_REDUCE_T` | §7.1 |
| 2 | Map (element-wise) | `CA_FOR_EACH_SLAB_INOUT` / `CA_SLAB_MAP_T` | §7.2 |
| 3 | Convolve (windowed) | `CA_FOR_EACH_SLAB` on CAWindow source | §7.3 |
| 4 | Sort (in-place WRITE) | `CA_FOR_EACH_SLAB` with WRITE flag | §7.4 |
| 5 | Per-axis fiber (contig) | `CA_FOR_EACH_FIBER` family (4 forms) | §7.5 |

### 7.1 Reduction

A reduction kernel collapses one or more axes into a smaller output.
`a.sum(axis)` is the canonical example. See:

- §3 — minimal sum kernel (single axis, slab_ndim = 1)
- §4 — multi-axis reduction with K-1 outer carry + innermost SIMD inner
- §6.1 — CA_FOR_EACH_SLAB form

Key structural points:
- Output shape = input shape minus `slab_axes` (`rb_ca_new_reduced`
  derives this).
- Per-slab accumulator → `op[out_i++] = acc`.
- Innermost slab axis = SIMD-candidate inner loop; outer K-1 slab axes
  walk via carry.

### 7.2 Map (element-wise transform)

A map kernel applies a per-cell transform producing same-shape output.
`sqrt(a)` and `clamp(a, lo, hi)` are typical examples. See:

- §5.1 — two-iter pattern (most general)
- §5.2 — one-iter pattern (when output is a fresh entity)
- §5.3 — mask propagation
- §6.2 — CA_FOR_EACH_SLAB_INOUT form

Key structural points:
- Output shape == input shape; use `rb_ca_template_with_type` to
  allocate.
- `slab_axes` typically the innermost (= per-row map); for
  element-wise-only ops, you can pick any axis or all axes.
- WRITE flag on the output iter; `sync_slab` (auto in macro) handles
  per-slab write-back when the iterator chose materialise instead of
  alias.

### 7.3 Convolve (windowed reduction)

A convolve kernel uses a `CAWindow` view to gather per-cell neighborhoods,
then reduces each neighborhood to a single output cell. The view algebra
handles boundary cells via `bound_fill`; your kernel sees a clean
neighborhood slab per output cell.

Example: 5-point 2-D Laplacian (`(L[i,j] = a[i-1,j] + a[i+1,j] +
a[i,j-1] + a[i,j+1] - 4*a[i,j]`) using a 3×3 window centered on each
cell.

```c
static VALUE
rb_ca_laplacian (VALUE self)
{
  CArray *ca;
  GetCArray(self, ca);
  if ( ca->ndim != 2 || ca->data_type != CA_FLOAT64 ) {
    rb_raise(rb_eRuntimeError, "laplacian: 2-D float64 only");
  }

  /* Window: 3×3 centered, with FILL bound policy (default 0.0).  The
     window's outer axes match the input shape; inner axes are the
     3×3 neighborhood for each output cell.  This is a 4-D virtual
     view of shape (H, W, 3, 3). */
  VALUE vwin = /* ... a.window(-1..1, -1..1, fill_value: 0.0) ... */;
  CArray *win;
  GetCArray(vwin, win);

  VALUE vout = rb_ca_template_with_type(self, INT2NUM(CA_FLOAT64), Qnil);
  CArray *co;
  GetCArray(vout, co);

  /* Reduce over the inner 2 axes (= the 3×3 window). */
  int8_t slab_axes[] = { 2, 3 };
  double *op = (double *) co->ptr;
  ca_size_t out_i = 0;

  ca_iter_state st;
  char       *p;
  boolean8_t *m;
  CA_FOR_EACH_SLAB(st, win, slab_axes, 2, 0, p, m) {
    /* p points at a 3×3 slab.  Row-major: p[0..8] are the 9 cells.
       For a 5-point Laplacian we use indices 1, 3, 4, 5, 7. */
    double *cells = (double *) p;
    op[out_i++] = cells[1] + cells[3] + cells[5] + cells[7]
                - 4.0 * cells[4];
  }
  return vout;
}
```

Key structural points:
- The `CAWindow` view contributes K_window slab axes (= dimensions of
  the neighborhood); these are the user-visible "innermost" axes of
  the window view. Slab over them yields one neighborhood per output
  cell.
- Boundary cells appear with `bound_fill` already substituted at the
  appropriate positions — your kernel reads them as ordinary data.
- For Phase C T3 SHIFT slab (= window with negative range slab),
  the iterator routes through the T3 fallback path automatically.
  The kernel body is unchanged.

### 7.4 Sort (in-place WRITE per slab)

A sort kernel applies an in-place permutation to each slab. The
canonical example is per-row sort: `a.sort_along_axis(-1)`.

```c
static int
cmp_double (const void *a, const void *b)
{
  double da = *(const double *) a;
  double db = *(const double *) b;
  return (da > db) - (da < db);
}

static VALUE
rb_ca_sort_rows (VALUE self)
{
  CArray *ca;
  GetCArray(self, ca);
  if ( ca->data_type != CA_FLOAT64 ) {
    rb_raise(rb_eRuntimeError, "sort_rows: float64 only");
  }
  /* Innermost axis = the row to sort. */
  int8_t slab_axes[] = { (int8_t) (ca->ndim - 1) };

  ca_iter_state st;
  char       *p;
  boolean8_t *m;
  /* WRITE flag enables in-place modification; sync_slab handles
     write-back when iter chose materialise (= for descriptor views
     where the slab isn't a parent.ptr alias). */
  CA_FOR_EACH_SLAB(st, ca, slab_axes, 1,
                   CA_KERNEL_WRITE, p, m) {
    /* Inner stride must equal sizeof(double) for qsort to work
       (= the row is contig in scratch when iter materialised, OR a
       contig run in parent when alias).  For the data_type/view
       combinations where qsort's contig assumption holds, the
       below works directly.  Other cases would need a strided sort
       implementation, or use the CA_FOR_EACH_FIBER family (§6.3 / §7.5)
       which delivers a contig buffer regardless of axis position. */
    qsort(p, st.slab_dims[0], sizeof(double), cmp_double);
    (void) m;  /* sort doesn't propagate mask — UNDEF cells are
                  sorted by their raw value, which may not be
                  meaningful; production kernels should reject
                  masked input or filter UNDEF first. */
  }
  return self;
}
```

Key structural points:
- `CA_KERNEL_WRITE` flag enables write-back; `sync_slab` (auto in macro)
  handles scatter when the iter materialised instead of aliasing parent.
- For descriptor views (e.g., a CSA slice), the iterator may materialise
  the row into scratch and scatter back on sync — your kernel doesn't
  see the difference.
- Phase C T3 INDEX/SHIFT slab + WRITE is currently NOT supported (=
  init_l2 returns `CA_ITER_ERR_FLAGS`). WRITE on T3 fallback / HOIST
  paths is a future sub-step (= per-slab scatter-back semantics need
  design). For C.1 scope, sort kernels run on Phase A/B accept patterns
  only.

### 7.5 Per-axis fiber (contig-guaranteed) — `CA_FOR_EACH_FIBER`

When your kernel needs a **contiguous data buffer along one specific
axis** (libc `qsort` / `bsearch`, per-axis SIMD intrinsics, FFT-along-
axis, any algorithm that walks `p[i]` without stride math), the
`CA_FOR_EACH_FIBER` family is the most ergonomic surface. The engine
gathers strided fibers into a per-state contig scratch when needed
(= `slab_strides[0] != bytes`), so your kernel **never sees a stride
argument**.

The catalog has four forms (= §0.1): plain `CA_FOR_EACH_FIBER` (single
input, NO_MASK), `_INOUT` (input + same-shape output, NO_MASK), and
`_MASKED` / `_INOUT_MASKED` variants where the engine also delivers a
contig boolean mask `m`.

#### 7.5.1 Sort-copy via `_INOUT` form

```c
static int
cmp_double (const void *a, const void *b)
{
  double da = *(const double *) a;
  double db = *(const double *) b;
  return (da > db) - (da < db);
}

static VALUE
rb_ca_sort_along (VALUE self, VALUE vaxis)
{
  CArray *src;
  GetCArray(self, src);
  if ( src->data_type != CA_FLOAT64 ) {
    rb_raise(rb_eRuntimeError, "sort_along: float64 only");
  }
  int axis = NUM2INT(vaxis);
  VALUE vout = rb_ca_template(self);   /* same shape, freshly allocated */
  CArray *out;
  GetCArray(vout, out);

  ca_iter_state st_in, st_out;
  double       *p_in, *p_out;
  ca_size_t     n;

  CA_FOR_EACH_FIBER_INOUT(st_in, st_out, src, out, axis,
                          CA_KERNEL_NO_MASK, p_in, p_out, n) {
    /* p_in / p_out are contig double[n] regardless of axis position.
       Engine handles per-fiber gather (for non-innermost axes) and
       per-fiber scatter (for the output side) transparently. */
    memcpy(p_out, p_in, n * sizeof(double));
    qsort(p_out, n, sizeof(double), cmp_double);
  }
  return vout;
}
```

What you do **not** write:

- A second `for` loop to gather fiber elements from strided positions.
- A scratch buffer + size computation (engine owns `fiber_data_scratch`).
- Stride arithmetic (`p[k * stride]`) — author writes `p[k]`.
- An `axes[]` array (single `int axis` is the macro argument).
- A `slab_strides[0] == bytes` fast-path branch (engine picks alias
  vs gather under the hood).

#### 7.5.2 Mask-aware per-fiber reduction via `_MASKED` form

```c
static VALUE
rb_ca_unmasked_sum_along (VALUE self, VALUE vaxis)
{
  CArray *src;
  GetCArray(self, src);
  int axis = NUM2INT(vaxis);

  ca_iter_state st;
  double       *p;
  boolean8_t   *m;        /* contig boolean8_t per fiber, OR NULL */
  ca_size_t     n;
  double        total = 0.0;

  CA_FOR_EACH_FIBER_MASKED(st, src, axis, 0, p, n, m) {
    for ( ca_size_t i = 0; i < n; i++ ) {
      if ( !m || !m[i] ) total += p[i];   /* m == NULL = no-mask source */
    }
  }
  return rb_float_new(total);
}
```

Mask delivery semantics: `m` is **contig** at every iteration —
`m[0..n-1]` covers the current fiber, in fiber order. The engine
gathers from `slab_mask_strides[0]` when needed; the author never
touches that stride. No-mask sources yield `m == NULL`; author
NULL-checks first.

#### 7.5.3 Shape requirement for INOUT forms

`CA_FOR_EACH_FIBER_INOUT` / `_INOUT_MASKED` require **strict full
shape equality** between input and output (= same `ndim`, same total
`elements`, same `dim[axis]`). The macros runtime-assert this in the
inner `for` condition; mismatched pairs are silently skipped (body
never executes).

This is intentional. Without the check, the two iterators walk the
prefix axes independently and `&&`-short-circuit on the shorter of
the two fiber counts — leaking some output fibers and silently
mis-pairing the remainder. (See `PROPOSAL_FIBER_DELIVERY.md` §2.3 +
§9.6 for the silent-corruption seam this plugs.)

Authors that need broadcasting / non-axis-dim variation must drop to
the raw API or compose `_FIBER` with explicit shape handling.

#### 7.5.4 When to fall back to `CA_FOR_EACH_SLAB`

- Multiple slab axes simultaneously (e.g. reduce over (axis=0, axis=2)
  in 3-D).
- Kernels that prefer strided access (= no contig requirement, save
  the gather cost on non-innermost fibers).
- Algorithms operating on K-D slab geometry (e.g. 2-D convolution).

For these, `CA_FOR_EACH_SLAB` (§6.1) or `CA_FOR_EACH_SLAB_INOUT`
(§6.2) remains the right primitive.

## 8. Mask handling

If the source carries a mask (= `ca_has_mask(ca)` is true), the
iterator gathers the mask into a contiguous `boolean8_t *` scratch
buffer and yields a non-NULL pointer to it alongside each slab.

```c
while ( ca_iter_state_next_slab_axes(&st, &p, &m) ) {
  /* m == NULL    : source has no mask, all cells are valid
     m != NULL    : per-slab mask base ptr; mask[mask_off] != 0 means masked */
  ...
}
```

Skip masked cells in your kernel logic. Reduction kernels typically
just skip the cell (= it contributes 0 to a sum); map kernels may
need to propagate UNDEF to the output mask (covered in Phase B's
template doc extension).

**Why mask uses separate strides** (`slab_mask_strides` /
`outer_mask_strides`): the mask scratch is laid out in *view*
row-major order, whereas the data slab is yielded through the
*composed* byte strides of the parent entity. For non-contig
CAStride sources (e.g. transposed views), these two stride spaces
differ. Always use `slab_mask_strides[k]` for mask access, not
`slab_strides[k] / src->bytes`.

**Kernel character: NO_MASK opt-out.** If your kernel fundamentally
cannot handle mask (= the operation is meaningless on UNDEF cells,
e.g. a bit operation), pass `CA_KERNEL_NO_MASK` flag at init:

```c
ca_iter_state_init_l2(&st, ca, CA_SLAB_AXES, slab_axes, naxes,
                      CA_KERNEL_NO_MASK);
```

The iterator then rejects masked sources at init time
(`CA_ITER_ERR_MASK_NOT_ALLOWED`), so callers must peel the mask via
`ca.value` or `ca.unmask_copy(fill)` before calling your kernel.
This is preferable to silently producing wrong output.

## 9. L1 vs L2: which level to choose

The iterator supports three dispatch levels (Phase A implements L1
and L2):

| Level | Slab shape | Init / yield API |
|---|---|---|
| **L1** (contig kernel) | 1-D contig run, stride implicit = bytes | `init_l1` / `next_slab` |
| **L2** (strided kernel) | 1-D or K-D, explicit strides | `init_l2` / `next_slab_strided` or `next_slab_axes` |
| L3 (multi-D kernel) | reserved, Phase 1+ | future work |

**Choose L1 when:**
- Your kernel processes the whole array as a flat 1-D contig run
  (`CA_SLAB_WHOLE` policy)
- You don't need per-axis structure
- The source can be aliased cheaply (entity or CAStride contig)

**Choose L2 when:**
- You need per-axis reduction or transformation (`CA_SLAB_AXES`)
- The source is potentially non-contig (CAStride family with
  transpose, slice, etc.) — L2 handles this transparently via
  compose-fold
- You want explicit stride control for SIMD-friendly inner loops

For new kernels in CArray 3.0, **default to L2 with CA_SLAB_AXES**.
It's the most flexible surface; L1 is an optimisation path for
specific cases where slab structure isn't needed.

### 9.1 Source view coverage by phase

L2 with `CA_SLAB_AXES` accepts the following source kinds:

| Source kind | Phase | Path | Notes |
|---|---|---|---|
| Entity (`CArray.float64(...)`) | A | alias (= row-major) | trivial |
| CAStride family (transpose / slice / reshape) | A | alias (= compose-fold) | non-contig chain → SIMD inner via K-1 outer carry |
| Descriptor view (CSA / CAGrid) with outer-{STRIDE,INDEX} + slab-STRIDE | B | alias (= K-D strided yield from parent) | `a[mask, nil, nil].sum_ki(1,2)` |
| Descriptor view with outer-SHIFT (CAWindow neg / CAShift) + slab-STRIDE | B.1.5 | materialise (= row-major scratch) | OOB cells use `bound_fill` |
| Overlay view (CAFake / CAByteSwap / CABitfield / CABitarray / CAReduce) | B | attach (= view's own materialise) | auto-cast via `rb_ca_wrap_readonly` lands here |
| Descriptor view with INDEX inside the slab (e.g., `csa.sum_ki(0,2)`) | C | per-slab materialise (= HOIST when innermost STRIDE + no SHIFT, else FALLBACK) | T3 path — completes the "deliver" principle |
| Descriptor view with SHIFT inside the slab (e.g., `cawindow_neg.sum_ki(0)`) | C | per-slab materialise (FALLBACK with bound_fill) | T3 path |
| CASelect 1-D filter (`a[mask].sum_ki(0)`) | C | per-slab materialise (single-slab walk) | T3 path |

**With Phase C T3 landed, the "deliver" principle is complete**: any
descriptor view × any slab configuration produces correct output.  For
kernels using the §10 helpers, the source kind is fully invisible — the
same kernel body works regardless of which path the iterator takes
internally.

(Historical note: CAMapping previously appeared here as an explicit
reject because its descriptor.ndim differed from view.ndim.  The class
was removed in 3.0 (R.3, PROPOSAL_CAMAPPING_REMOVAL); `a[mapper]` now
normalises to a CAGrid/CAStride chain whose layers each satisfy
descriptor.ndim == view.ndim, so the reject is gone.)

## 10. Argument helpers (Phase B)

Phase B (CArray 3.0 Coverage) ships two helpers that compress the
input boilerplate in kernel authoring:

### 10.1 `rb_ca_wrap_readonly` — data_type adaptation

```c
VALUE vsrc = rb_ca_wrap_readonly(self, INT2NUM(CA_FLOAT64));
GetCArray(vsrc, ca);
```

- **data_type match**: returns the original VALUE unchanged. No allocation,
  no view created. Zero-cost when the source already has the target data_type.
- **data_type mismatch**: returns a `CAFake` view providing per-element
  cast on read. Your kernel sees the target data_type.

This is the foundation for the "any numeric data_type source" capability
of Phase B kernels (e.g., `int_array.sum_ki(0)` returning a `float64`
result via auto-cast).

When the source is a CAFake (= data_type-mismatch path), `kernel_iterator`
takes the **SRC_ATTACH** path: `ca_attach(src)` populates `src->ptr`
with the cast values in view row-major layout, then K-D walks proceed
as if the source were a row-major entity (§4 pattern).

### 10.2 `rb_ca_parse_reduce_axes_kw` — kwarg axis parser

```c
volatile VALUE ropt = rb_pop_options(&argc, &argv);
volatile VALUE raxis = Qnil;
rb_scan_options(ropt, "axis", &raxis);
int8_t slab_axes[CA_RANK_MAX];
int8_t naxes = rb_ca_parse_reduce_axes_kw(raxis, ca, slab_axes);
```

Accepts the `axis:` kwarg value extracted by the dispatcher from the
trailing options Hash:
- `Qnil` / `Qundef` (= `axis:` omitted)        → full reduction (all axes)
- Integer (= `axis: 0`)                        → single axis (negative normalised)
- Array of Integer (= `axis: [0, 2]`)          → multi-axis in input order
- Range / Float / String / etc.                → raises TypeError
- out-of-range / duplicate / overflow          → raises ArgumentError / IndexError

The returned `naxes` is the count; `slab_axes[]` is filled in input
order (canonicalisation to ascending happens inside `init_l2`).

The legacy variadic counterpart `rb_ca_parse_reduce_axes(argc, argv,
ca, out_axes)` is still exported but no longer used by kernel
dispatchers (= API harmonisation phase, 2026-06-08).  New kernels and
new manual dispatchers use the `_kw` form.

### 10.3 `rb_ca_new_reduced` — reduction output allocator

(Carried over from Phase A.) Allocates a CArray whose shape is the
input shape with `slab_axes` removed in ascending order, collapsing
to shape `[1]` for full reduction. Mask = NULL. data_type = your choice
(commonly `CA_FLOAT64` for accumulator-style reductions).

### 10.4 `rb_ca_template_with_type` — map output allocator

For map kernels where the output has the same shape as the input but
possibly a different data_type:

```c
VALUE vout = rb_ca_template_with_type(self, INT2NUM(CA_FLOAT64), Qnil);
GetCArray(vout, co);
```

Mirrors the input's shape. data_type defaults to the input's if `Qnil` is
passed as the second arg. Used heavily inside `ext/carray_call_cfunc.c`
for the cfunc vectorize bridge — the same helper that powers
`int_ary.sin` style operations is available to your kernel.

### 10.5 The four together

The four-block kernel skeleton (§2) becomes:

```c
VALUE vsrc = rb_ca_wrap_readonly(self, INT2NUM(CA_FLOAT64));
GetCArray(vsrc, ca);
volatile VALUE ropt = rb_pop_options(&argc, &argv);
volatile VALUE raxis = Qnil;
rb_scan_options(ropt, "axis", &raxis);
int8_t slab_axes[CA_RANK_MAX];
int8_t naxes = rb_ca_parse_reduce_axes_kw(raxis, ca, slab_axes);
VALUE vout = rb_ca_new_reduced(vsrc, slab_axes, naxes, CA_FLOAT64);
GetCArray(vout, co);
/* ... init_l2 + per-slab kernel ... */
```

Seven lines of boilerplate (= the "input" + "output" blocks) cover
data_type adaptation, `axis:` kwarg parsing, and output allocation — all
robust to user input variations.

## 11. What you don't have to write

Compared to writing the same kernel with the first-generation
`ca_attach` API alone, the second-generation surface eliminates:

| What | Why |
|---|---|
| `ca_attach(ca->parent)` | iterator handles parent attach in `init_l2` |
| `ca_attach_is_alias` checks + contig/scratch branching | iterator unifies via alias_mode internally |
| View kind dispatch (CSA / CAGrid / CAStride / chain) | iterator's `route_source` handles classification |
| Output dim calculation | `rb_ca_new_reduced` derives from `slab_axes` |
| Transpose-to-innermost hack for multi-axis reduction | `CA_SLAB_AXES` makes axes first-class |
| Per-call `malloc` / `memcpy` for scratch | iterator owns scratch lifecycle |
| Mask gather + per-cell mask offset bookkeeping | `scratch_mask` + `slab_mask_strides` |
| `ca_detach` / `xfree` cleanup | `ca_iter_state_finish` |
| compose-fold for N-deep CAStride chains | iterator's `route_source` walks chain to root |
| Per-slab materialise for INDEX/SHIFT slab axes (Phase C T3) | iterator routes through HOIST or FALLBACK gather path |
| `init` / `next` / `sync` / `finish` lifecycle plumbing (when error reporting isn't critical) | `CA_FOR_EACH_SLAB` / `_INOUT` block macros (§6) |

What remains is the **essential per-slab kernel logic** — the
domain-specific work that no framework can write for you (= the
accumulator step in reduction, the transform step in map, the
neighborhood reduction in convolve, the in-place sort in sort).

## 12. Common pitfalls

**Pitfall 1: assuming alias_mode in your kernel.** Don't read
`st.alias_mode` or `st.scratch_ptr` from your kernel. The framework
chooses alias vs scratch internally based on source kind. Your
kernel sees only `p` / `m` / `slab_dims` / `slab_strides`. If you
branch on alias_mode, you've broken the universal dispatch contract
and your kernel will behave differently across view kinds.

**Pitfall 2: using data strides for mask access.** Mask uses
`slab_mask_strides` (element units), not `slab_strides`
(byte units). For entity sources these happen to coincide
(`slab_mask_strides[k] = slab_strides[k] / src->bytes`), but for
CAStride non-contig (transposed views) the two stride spaces differ.
Always use the explicit `slab_mask_strides[]`.

**Pitfall 3: forgetting `ca_iter_state_finish`.** The iterator owns
scratch buffers, mask buffers, parent attach refcounts. Always call
`finish` exactly once after a successful `init`, even on error paths.
Phase C's `CA_FOR_EACH_SLAB` block macro (§6) guarantees this
automatically for kernels that don't need explicit error reporting.

**Pitfall 4: writing past the slab.** `slab_dims[k]` is the *exact*
extent; walking `slab_dims[k] + 1` cells reads past the slab into
either another slab's territory (alias path) or a heap boundary
(scratch path). Stick to `[0, slab_dims[k])` per axis.

**Pitfall 5: assuming `slab_n == slab_elements`.** Both fields exist
for legacy/consistency reasons. For `CA_SLAB_AXES`, the K-D
"element count per slab" is `slab_elements`. The `slab_n` field is
populated as a mirror but should not be used for K-D walks.

**Pitfall 6: input axis order leaking into iteration order.** User
passes `{3, 0, 2}`; the iterator stores `{0, 2, 3}` (ascending).
Your kernel sees slab_axes in source-axis-ascending order, so don't
write logic assuming the user's input order.

## 13. Status and what's next

The kernel author surface for CArray 3.0 is **landed and complete** for
its core scope. The full progression (Phases A–E of
`ROADMAP_KERNEL_AUTHOR_SURFACE.md`) shipped:

- **The iterator engine** delivers any source view × any slab
  configuration to a kernel with universal byte parity — entity,
  CAStride chains, descriptor views (CSA / CAGrid), overlay views
  (CAFake / CAByteSwap / …), bounds-fill views (CAWindow / CAShift),
  and 1-D filters (CASelect). The "deliver" principle is complete (§9.1).
- **Block macros** (§6): the `CA_FOR_EACH_SLAB` / `_INOUT` and
  `CA_FOR_EACH_FIBER` families wrap the full lifecycle; the
  `CA_SLAB_REDUCE_T` / `CA_SLAB_MAP_T` / `CA_SLAB_SCAN_T` suite collapses
  the K-D walk into a single expression.
- **The mkkernel DSL** (§6.6, full reference
  [`MkKernelDSL.md`](MkKernelDSL.md)): the reduce / map / scan / sort /
  search families, the full math / compare family, and the `:object`
  (per-cell Ruby) branch all ship through one DSL block per kernel. The
  legacy hand-written `stat_proc` generator is retired.
- **The SIMD reduction license** (§6.7): `reduction_kind:` unlocks
  `#pragma omp simd reduction(...)` on the contig hot path under the
  ε-close contract.

The API contracts in this guide are **stable from 3.0 onward**: a kernel
you write today keeps working unchanged. Hand-written explicit walks
remain valid for kernels whose inner loop the DSL can't express.

### 13.1 The frozen surface (two-tier contract)

CArray 3.0 freezes the author surface so the iterator engine can be
re-implemented across 3.x (a planned engine overhaul) **without breaking a
single kernel you compile against this header**. Because these are
C *header* macros, the engine may freely rewrite what a macro *expands
to* — what is pinned is the name + argument list + the semantics
observed inside your `REDUCE` / `MAP` / `STEP` expression.

The complete FROZEN set (mirrored by the banner in
`ext/ca_kernel_iterator.h` and enforced by
`rake kernel_surface_check`):

| Category | Frozen names |
|---|---|
| **Block macros** | `CA_FOR_EACH_SLAB`, `CA_FOR_EACH_SLAB_INOUT`, `CA_FOR_EACH_FIBER`, `CA_FOR_EACH_FIBER_MASKED`, `CA_FOR_EACH_FIBER_INOUT`, `CA_FOR_EACH_FIBER_INOUT_MASKED` |
| **Body macros** | `CA_SLAB_REDUCE_T` (+ `_EX` / `_PLUS_EX` / `_MIN_EX` / `_MAX_EX` / `_STAR_EX` and the `_PLUS` / `_MIN` / `_MAX` / `_STAR` wrappers), `CA_SLAB_REDUCE_F64` / `_F32` / `_I32` / `_I64`, `CA_SLAB_REDUCE_ARRAY_T` (+ `_EX` / `_PLUS` / `_PLUS_EX`), `CA_SLAB_MAP_T`, `CA_SLAB_MAP_F64`, `CA_SLAB_SCAN_T`, `CA_SLAB_SCAN_TA`, `CA_FOR_EACH_UNMASKED`, `CA_FOR_EACH_INDEX_UNMASKED`, `CA_COUNT_UNMASKED`, `CA_MASK_GET`, `CA_L2_FOR_EACH`, `CA_L2_FOR_EACH_UNMASKED` |
| **Raw-API entry points** | `ca_iter_state_init_l2`, `ca_iter_state_next_slab_axes`, `ca_iter_state_sync_slab`, `ca_iter_state_finish` |
| **Enum / status tokens** | `CA_SLAB_AXES`, `CA_KERNEL_WRITE`, `CA_KERNEL_NO_MASK`, `CA_ITER_OK`, `CA_ITER_ERR_*` |
| **Slab-delivery representation** (`ca_iter_state` fields a kernel reads) | `slab_ndim`, `slab_dims[]`, `slab_strides[]`, `slab_mask_strides[]`, `slab_elements`, `outer_ndim`, `outer_axes[]`, `outer_dims[]` |
| **Injected expression identifiers** | `v`, `r`, `w`, `acc`, `idx`, `first` |

The slab-delivery representation is frozen deliberately: a hand-written
kernel may read `st.slab_dims[k]` / `st.slab_strides[k]` /
`st.slab_mask_strides[k]` directly (§4) and stay correct across any
engine re-implementation, because the engine is obliged to keep *yielding*
this representation even as it changes *how* it computes it. The engine's
own freedom (always-contig delivery, fused gather, …) is exercised through
the `_FIBER` family and `flags`, not by changing this representation.

**Everything else is INTERNAL and refactors freely**: the state-machine
function bodies, `init_l1` / `next_slab` / `next_slab_strided` /
`ca_iter_can_alias`, the `alias_mode` / `src_kind` routing
(`CA_ITER_ALIAS_*` / `CA_ITER_SRC_*` / `CA_KERNEL_FIBER_CONTIG` /
`CA_SLAB_WHOLE` / `CA_SLAB_FREE`), every non-frozen `ca_iter_state` field,
and the physical struct layout.

**How the surface still evolves within 3.x** — additively, never by
mutation:

- a new behavior → a new `flags` bit (the bitmask absorbs it; no arity
  change);
- a body macro that needs another parameter → a new `_EX` variant plus a
  thin wrapper forwarding the default (exactly how `CA_SLAB_REDUCE_T`
  already forwards to `CA_SLAB_REDUCE_T_EX`);
- a new kernel pattern → a new catalog macro (§0.1).

Renaming or removing a frozen name is a 3.x breaking change: update this
section, the header banner, and `utils/check_kernel_surface_freeze.rb` in
the same commit so the freeze stays honest.

**Genuinely open (demand-driven, not blockers):**

- **`:object` coverage gaps** — a few mkkernel families don't yet have
  the `:object` branch (variance / stddev, wsum / wmean, search_nearest,
  median / percentile / quantile).
- **Ruby-surface ergonomics** — higher-level per-row / per-slab Ruby
  block surfaces (`map_slab` / `reduce_slab`, see
  [`SlabIterator.md`](../topics/SlabIterator.md)) are an end-user layer on top of
  this C surface, not part of it.
- **L3 multi-D kernel level** (§9) remains reserved / future work.

## References

- [`docs/MkKernelDSL.md`](MkKernelDSL.md) — the full mkkernel DSL
  reference (all entry points, options, the `:object` branch)
- [`docs/WritingCExtensions.md`](WritingCExtensions.md) — the
  first-generation C extension guide (`ca_attach` / `ca_sync` etc)
- [`docs/CAObject.md`](../topics/CAObject.md) — building custom CArray subclasses
  in Ruby (orthogonal: subclass authoring vs kernel authoring)
- [`ext/carray_kernels.c`](../../ext/carray_kernels.c) — the generated
  kernel implementations (from `ext/mkkernel.rb`)
- [`ext/ca_kernel_iterator.h`](../../ext/ca_kernel_iterator.h) — full
  state struct + macro suite + API declarations with inline documentation
