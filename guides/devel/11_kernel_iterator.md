# 11 The kernel iterator

> **Status: draft.** Written through once; not yet re-verified against a live
> build. See [README](README.md) for conventions.

The kernel iterator is the **default surface** for writing a per-axis
kernel. It feeds any of CArray's ~22 view kinds to your code through one
uniform interface, so you write the computation and nothing else — no
materialisation, no attach/detach, no outer-axis walk, no mask gather. This
chapter walks the engine surface end-to-end; the generator that emits the
typical kernel for you is [ch. 12](12_mkkernel_dsl.md).

> **Before touching the engine** (`ext/ca_kernel_iterator.c`), read the
> engine-internals memo first.
> This chapter covers the *author surface* — the freeze contract below
> insulates you from the engine internals' planned overhaul.

## The two-tier freeze contract

The surface is deliberately split into a **frozen** author-facing layer and
a **free-to-refactor** engine. The point is that the engine can be
re-implemented across all of 3.x without breaking a single ext-gem kernel.
`rake kernel_surface_check` (`utils/check_kernel_surface_freeze.rb`)
mechanically pins the frozen names.

**Frozen** (never rename / re-arity / change semantics — additions only):

- the author macros — `CA_FOR_EACH_SLAB` and the `_FIBER` family; the
  `CA_SLAB_REDUCE_T*` / `CA_SLAB_MAP_T` / `CA_SLAB_SCAN_T` / `CA_SLAB_SCAN_TA`
  suites; `CA_L2_FOR_EACH` and its UNMASKED variant; the `CA_FOR_EACH_UNMASKED`
  family;
- the raw entry points the macros expand to — `ca_iter_state_init_l1`,
  `ca_iter_state_init_l2`, `ca_iter_state_next_slab`,
  `ca_iter_state_next_slab_strided`, `ca_iter_state_next_slab_axes`,
  `ca_iter_state_sync_slab`, `ca_iter_state_finish`;
- the tokens authors write literally — `CA_SLAB_AXES`, `CA_SLAB_WHOLE`,
  `CA_SLAB_FREE`, `CA_KERNEL_WRITE`, `CA_KERNEL_NO_MASK`,
  `CA_KERNEL_FIBER_CONTIG`, `CA_KERNEL_CHUNK_HINT`, `CA_ITER_OK`,
  `CA_ITER_ERR_NOT_CHEAP`, `CA_ITER_ERR_POLICY`, `CA_ITER_ERR_FLAGS`,
  `CA_ITER_ERR_READONLY`, `CA_ITER_ERR_MASK`, `CA_ITER_ERR_MASK_NOT_ALLOWED`;
- the slab-delivery state fields a kernel reads — `slab_ndim`, `slab_dims`,
  `slab_strides`, `slab_mask_strides`, `slab_elements`, `outer_ndim`,
  `outer_axes`, `outer_dims`;
- the identifiers injected into the body-macro expressions — `v` (current
  element), `r` (output cell), `w` (parallel-array weight), `acc`
  (accumulator), `idx` (flat slab index), `first` (first-unmasked flag).

**Internal** (refactor freely): the state-machine bodies (`init_l1` /
`next_slab` / `next_slab_strided` / `ca_iter_route_source` /
`ca_iter_can_alias` internals), the `alias_mode` / `src_kind` routing
constants (`CA_ITER_ALIAS_*` / `CA_ITER_SRC_*`), and every non-frozen
`ca_iter_state` field (scratch, fiber-cache, descriptor cache, stack-tile
cache, …).

Adding new surface is fine and expected (a new flag bit, a new `_EX`
macro variant, a new catalog macro). Changing a frozen name is a 3.x
breaking change — update the doc contract and the guard in the same
commit.

## Fiber vs slab: the two grains

The iterator delivers data at one of two granularities:

- **`CA_FOR_EACH_SLAB`** hands you a contiguous *multi-dimensional*
  sub-block (a **slab**) per outer-axis position. You read it through the
  frozen `slab_*` fields. This is the general grain — multi-axis
  reductions, per-axis maps.
- **`CA_FOR_EACH_FIBER`** hands you a single 1-D run with the **data
  contiguity guaranteed**: you index `p[i]` with no stride arithmetic. It
  is the right grain for kernels that *require* contiguity — sort, search,
  per-axis SIMD, handing a fiber to libc `qsort`.

The four FIBER forms compose the contiguity guarantee with masking and an
output operand:

| Form | What it delivers |
|------|------------------|
| `CA_FOR_EACH_FIBER` | contig data (`p[i]`); NO_MASK only |
| `CA_FOR_EACH_FIBER_INOUT` | + a parallel contig output (`p_out[i]`) |
| `CA_FOR_EACH_FIBER_MASKED` | + contig mask (`m[i]`) |
| `CA_FOR_EACH_FIBER_INOUT_MASKED` | + both |

The engine picks alias (zero-copy when the fiber stride permits) or
per-fiber materialise (including per-fiber mask gather for non-innermost
axes) — invisibly to the kernel.

## The author-facing macros: signatures at a glance

The single-input slab walk:

```c
CA_FOR_EACH_SLAB(st, ca, axes, naxes, flags, p, m)
        /* ca_iter_state st; char *p; boolean8_t *m;
           int8_t axes[]; int8_t naxes; uint32_t flags;
           (policy = CA_SLAB_AXES is implicit) */
```

The input-output slab walk (map kernels):

```c
CA_FOR_EACH_SLAB_INOUT(st_in, st_out, ca_in, ca_out,
                       axes, naxes,
                       p_in, p_out, m_in, m_out)
```

The fiber family — contig 1-D delivery, axis pinned to a single value:

```c
CA_FOR_EACH_FIBER       (st, ca, axis, flags, p, n);
CA_FOR_EACH_FIBER_MASKED(st, ca, axis, flags, p, n, m);
CA_FOR_EACH_FIBER_INOUT (st_in, st_out, ca_in, ca_out, axis,
                         flags, p_in, p_out, n);
CA_FOR_EACH_FIBER_INOUT_MASKED(st_in, st_out, ca_in, ca_out, axis,
                               flags, p_in, p_out, n, m);
```

Each fiber macro auto-sets `CA_KERNEL_FIBER_CONTIG`; the engine guarantees
contig data delivery (gathers strided fibers into per-state scratch when
needed). The INOUT macros runtime-assert strict full-shape equality and
silently skip the body on mismatch (= same `ndim` and same `dim[axis]`). This
is deliberately *unlike* the sweep INOUT family
([ch. 13](13_sweep_author_surface.md)), which **raises** on a shape mismatch
(`ca_sweep_check_same_shape`) — the two engines differ here by design.

L2 inner-loop helpers — fast-path contig within a strided callback:

```c
CA_L2_FOR_EACH         (T, ptr, n, stride, p, body);
CA_L2_FOR_EACH_UNMASKED(T, ptr, mask, n, stride, p, body);
```

These wrap an L2 callback signature `(ptr, n, stride_bytes)` with a
`stride == sizeof(T)` fast-path branch. When the runtime stride matches
the element size, `body` runs against a `T *p` that the compiler can
autovectorise; otherwise `p` is recomputed per iteration.

## The four-block kernel skeleton

Every kernel — generated or hand-written — has the same shape. The single-
axis float64 sum below is what the macros expand to:

```c
static VALUE
rb_ca_sum_one_axis (VALUE self, VALUE vaxis)
{
  CArray *ca, *co;
  int8_t  slab_axes[1];

  /* Block 1: input */
  GetCArray(self, ca);
  slab_axes[0] = (int8_t) NUM2INT(vaxis);

  /* Block 2: output (dims derived from slab_axes) */
  VALUE vout = rb_ca_new_reduced(self, slab_axes, 1, CA_FLOAT64, 0);
  GetCArray(vout, co);

  /* Block 3: iter init */
  ca_iter_state st;
  int rc = ca_iter_state_init_l2(&st, ca, CA_SLAB_AXES, slab_axes, 1, 0);
  if ( rc != CA_ITER_OK ) rb_raise(rb_eRuntimeError, "init failed rc=%d", rc);

  /* Block 4: per-slab walk */
  double     *op = (double *) co->ptr;
  char       *p;
  boolean8_t *m;
  ca_size_t   out_i = 0;
  while ( ca_iter_state_next_slab_axes(&st, &p, &m) ) {
    double    acc    = 0.0;
    ca_size_t stride = st.slab_strides[0];
    ca_size_t n      = st.slab_dims[0];
    for ( ca_size_t j = 0; j < n; j++ ) {
      if ( m == NULL || !m[j * st.slab_mask_strides[0]] )
        acc += *(double *)(p + j * stride);
    }
    op[out_i++] = acc;
  }
  ca_iter_state_finish(&st);
  return vout;
}
```

What you wrote: the accumulation. What you did **not** write — and this is
the whole point — view materialisation (the source could be a transposed
view, a CAStride chain, a slice; same code works), parent attach/detach,
output dim calculation, the outer-axis walk, and the mask gather. The
iterator delivered all of it.

## The state machine: full entry-point reference

The five frozen entry points the macros expand to:

```c
int  ca_iter_state_init_l1 (ca_iter_state    *st,
                            struct _CArray   *src,
                            ca_slab_policy_t  policy,
                            int8_t           *axes,
                            int8_t            naxes,
                            uint32_t          flags);

int  ca_iter_state_init_l2 (ca_iter_state    *st,
                            struct _CArray   *src,
                            ca_slab_policy_t  policy,
                            int8_t           *axes,
                            int8_t            naxes,
                            uint32_t          flags);

int  ca_iter_state_next_slab         (ca_iter_state *st,
                                      char         **out_ptr,
                                      boolean8_t   **out_mask,
                                      ca_size_t     *out_n);

int  ca_iter_state_next_slab_strided (ca_iter_state *st,
                                      char         **out_ptr,
                                      boolean8_t   **out_mask,
                                      ca_size_t     *out_n,
                                      ca_size_t     *out_stride_bytes);

int  ca_iter_state_next_slab_axes    (ca_iter_state *st,
                                      char         **out_ptr,
                                      boolean8_t   **out_mask);

void ca_iter_state_sync_slab         (ca_iter_state *st);
void ca_iter_state_finish            (ca_iter_state *st);
```

Plus the alias-eligibility predicate:

```c
int  ca_iter_can_alias (void *ap, int level);   /* level = 1 | 2 | 3 */
```

### `init_l1` vs `init_l2` — picking a level

- **`init_l1`** prepares an **L1 contig** walk. The kernel sees one slab
  yielded by `ca_iter_state_next_slab` with stride implicit at `bytes`.
  Source routing: entity / CAStride-contig → alias; CAStride non-contig →
  scratch path (`ca_copy_data` compose-fold gathers into a malloc'd
  buffer); other sources → `CA_ITER_ERR_NOT_CHEAP` in step 1, extended in
  later phases.
- **`init_l2`** prepares an **L2 strided** walk. The kernel sees per-slab
  pointers with an explicit byte stride argument. Source routing covers
  entity / CAStride contig (alias, stride = `bytes`), CAStride non-contig
  (alias, multi-slab walk over prefix axes, no scratch), and the
  descriptor-framework views (CAGrid / CASelect / CAMapping / CAWindow /
  CAShift / CSA) via the per-axis-descriptor engine.

`init_l2` is the entry point modern kernels use; `init_l1` is kept for
strictly contig-only paths.

### The three `next_slab*` callees

The three pull variants correspond to three slab grains. **Use the one
that matches your init**:

- `ca_iter_state_next_slab` — paired with `init_l1`. Yields one whole
  contig 1-D slab (the whole array in step 1; later phases may chunk it).
- `ca_iter_state_next_slab_strided` — paired with `init_l2` for the
  legacy strided walk: the kernel walks `*out_n` cells stepping
  `*out_stride_bytes` per cell, mask in lockstep.
- `ca_iter_state_next_slab_axes` — paired with `init_l2(... CA_SLAB_AXES,
  axes, naxes, ...)`. This is the K-D slab API: the kernel reads
  `st.slab_dims[]` / `st.slab_strides[]` (constant across the walk) and
  walks slabs with a multi-dimensional offset computation.

A pull returns 1 with the cursor populated, or 0 to signal end-of-walk.
After a 0 return all subsequent calls return 0.

### `sync_slab` and `finish`

After each `next_slab*` + body, the caller invokes `sync_slab`
**unconditionally**. The state machine internally branches on `alias_mode`:

- READ walk (`!(flags & CA_KERNEL_WRITE)`) → no-op.
- alias path (no scratch) → no-op; the kernel wrote to parent storage
  directly through `alias_ptr`.
- scratch path → scatter back via `ca_sync_data(src, scratch)`.

`finish` releases everything: scratch buffers, attached parents, fiber
caches, the K-parent ptr cache for CAStack, the per-tile cache, the
descriptor-framework cache. Calling `finish` after a successful init is
mandatory; calling it after a failed init (`init_l2` returned an
`ERR_*`) is **not** required — the engine releases resources on the
error path.

## The slab-delivery contract (frozen kernel-readable state)

When `init_l2(... CA_SLAB_AXES ...)` succeeds, the kernel reads:

| Field | Type | Meaning |
|-------|------|---------|
| `st.slab_ndim` | `int8_t` | number of slab axes (= `naxes`) |
| `st.slab_dims[k]` | `ca_size_t` | size along slab axis k, k ∈ [0..slab_ndim) |
| `st.slab_strides[k]` | `ca_size_t` | data byte stride along slab axis k |
| `st.slab_mask_strides[k]` | `ca_size_t` | mask element stride (`boolean8_t` units) |
| `st.slab_elements` | `ca_size_t` | Π slab_dims |
| `st.outer_ndim` | `int8_t` | = `src->ndim - slab_ndim` |
| `st.outer_axes[k]` | `int8_t` | complement of `slab_axes` (= the iterator's outer walk) |
| `st.outer_dims[k]` | `ca_size_t` | dim along outer axis k |

The same fields are populated by the FIBER family with `slab_ndim == 1`
and `slab_dims[0] = n` (the fiber length).

### Walking a K-D slab

Within the body of one `next_slab_axes` call, the kernel walks the slab
with `slab_dims[]` and `slab_strides[]`. The canonical inner walk is:

```c
ca_size_t idx = 0;
ca_size_t s[CA_RANK_MAX] = {0};
for (ca_size_t i = 0; i < st.slab_elements; i++) {
  /* compute data and mask offsets from s[] */
  ca_size_t d_off = 0, m_off = 0;
  for (int8_t k = 0; k < st.slab_ndim; k++) {
    d_off += s[k] * st.slab_strides[k];
    m_off += s[k] * st.slab_mask_strides[k];
  }
  if (m == NULL || !m[m_off]) {
    T v = *(T *)(p + d_off);
    /* ... reduce, map, scan ... */
  }
  /* carry-walk s[] row-major */
  for (int8_t k = st.slab_ndim - 1; k >= 0; k--) {
    if (++s[k] < st.slab_dims[k]) break;
    s[k] = 0;
  }
  idx++;
}
```

In practice you never write this — the body-macro suite below expresses
the same walk in three lines.

## Slab policies

`policy` to `init_l2`:

```c
typedef enum {
  CA_SLAB_FREE  = 0,    /* engine-chosen chunk; reserved, step 2+ */
  CA_SLAB_AXES  = 1,    /* user-pinned slab axes (the default) */
  CA_SLAB_WHOLE = 2     /* whole array in one slab */
} ca_slab_policy_t;
```

`CA_SLAB_AXES` is the workhorse — it is what gives reductions / scans /
maps their per-axis semantics. `CA_SLAB_WHOLE` is the L1 entry point for
"give me everything as one contig run". `CA_SLAB_FREE` is reserved for
the future T2 chunk-hinted walk.

## Kernel flags

`flags` (bitfield) to `init_l1` / `init_l2`:

```c
#define CA_KERNEL_READ          0x0   /* default; no flag = READ */
#define CA_KERNEL_WRITE         0x1   /* kernel scatters back; sync timed */
#define CA_KERNEL_NO_MASK       0x2   /* reject masked source */
#define CA_KERNEL_CHUNK_HINT    0x4   /* T2 reserve */
#define CA_KERNEL_FIBER_CONTIG  0x8   /* gather strided fibers into scratch */
```

Choose them based on what the kernel needs:

- A pure reduction reads `CA_KERNEL_READ` (= no flag). The kernel writes
  to its own output entity, not the source.
- A per-axis transform that writes back into the source sets
  `CA_KERNEL_WRITE`. The engine then runs `sync_slab` to scatter each
  slab's results back through the view's access pattern, with sync timed
  correctly relative to the outer walk. Writing to a read-only view is
  rejected with `CA_ITER_ERR_READONLY`.
- A kernel that genuinely cannot accept a masked source declares
  `CA_KERNEL_NO_MASK`; the engine then rejects a masked source rather
  than silently dropping the mask. The `_FIBER` (non-masked) forms are
  NO_MASK by construction.
- `CA_KERNEL_FIBER_CONTIG` is set internally by the FIBER macros — direct
  callers leave it clear to get the legacy L2-strided semantic.

## Error codes

`init_l1` / `init_l2` return one of:

```c
#define CA_ITER_OK                     0
#define CA_ITER_ERR_NOT_CHEAP          1   /* src needs materialize */
#define CA_ITER_ERR_POLICY             2   /* policy not implemented */
#define CA_ITER_ERR_FLAGS              3   /* flag combination invalid */
#define CA_ITER_ERR_READONLY           4   /* WRITE on read-only view */
#define CA_ITER_ERR_MASK               5   /* masked src on path that lacks it */
#define CA_ITER_ERR_MASK_NOT_ALLOWED   6   /* NO_MASK + masked src */
#define CA_ITER_ERR_UNBOUND_SHAPE      7   /* unbound CAUbrep passed */
```

On error the engine releases anything it claimed; `finish` is not
required. Production kernels typically raise on any non-OK code; the
block-form macros silently skip the body and run `finish` (= no exception
path is needed for the common case).

## The body-macro suite

Hand-writing the K-D walk is rarely necessary. The frozen macros express
the common shapes with the injected identifiers (`v` = current value,
`acc` = accumulator, `r`/`w` = output / weight cells, `idx`, `first`).

### Reductions

The base reducer:

```c
CA_SLAB_REDUCE_T(T, st, p, m, acc, INIT, REDUCE);
        /* T:        element load type (double, int32_t, ...)
           acc:      lvalue (any numeric type) — receives the result
           INIT:     initial value expression (0, 0.0, -INFINITY, ...)
           REDUCE:   statement folding `v` (T) into `acc`. e.g.
                       acc += v                       (sum)
                       if (v > acc) acc = v           (max)
                       if (v == target) acc += 1      (count_equal) */
```

Convenience aliases for the four common load types:

```c
CA_SLAB_REDUCE_F64(st, p, m, acc, INIT, REDUCE);   /* T = double  */
CA_SLAB_REDUCE_F32(st, p, m, acc, INIT, REDUCE);   /* T = float   */
CA_SLAB_REDUCE_I32(st, p, m, acc, INIT, REDUCE);   /* T = int32_t */
CA_SLAB_REDUCE_I64(st, p, m, acc, INIT, REDUCE);   /* T = int64_t */
```

The "EX" form exposes a `masked_cnt` lvalue that the macro increments on
every skipped cell — needed when a kernel's mask policy depends on the
count of masked cells (e.g. variance's `min_count` policy):

```c
CA_SLAB_REDUCE_T_EX(T, st, p, m, acc, INIT, REDUCE, masked_cnt);
```

### SIMD-licensed reductions

Each base reducer has a kind-specific variant that licenses the
compiler to reassociate the accumulator (= ε-close, not bit-exact):

```c
CA_SLAB_REDUCE_T_PLUS(T, st, p, m, acc, INIT, REDUCE);  /* #pragma omp simd reduction(+:acc) */
CA_SLAB_REDUCE_T_MIN (T, st, p, m, acc, INIT, REDUCE);  /* reduction(min:acc) */
CA_SLAB_REDUCE_T_MAX (T, st, p, m, acc, INIT, REDUCE);  /* reduction(max:acc) */
CA_SLAB_REDUCE_T_STAR(T, st, p, m, acc, INIT, REDUCE);  /* reduction(*:acc) */
```

The `_EX` variants are again the masked-count-exposing forms. There is a
`CA_SLAB_REDUCE_T_VAR_EX` stub for future multi-accumulator output-buffered
work; currently it forwards to PLUS_EX (clang recognises sumsq as a
derived reduction).

The macros apply the SIMD pragma **only in the no-mask + innermost-contig
branch**. Masked or strided branches keep the byte-identical non-reassoc
walk so the contract degrades gracefully.

### Two-array (weighted) reductions

```c
CA_SLAB_REDUCE_ARRAY_T_EX(T, T_W, st, p, m, st_w, p_w,
                          acc, INIT, REDUCE, masked_cnt);
CA_SLAB_REDUCE_ARRAY_T_PLUS_EX(T, T_W, st, p, m, st_w, p_w,
                               acc, INIT, REDUCE, masked_cnt);
```

The two operands are driven by two parallel `ca_iter_state` machines,
yielding slab pointers in lockstep. The REDUCE expression binds both `v`
(source cell, T) and `w` (weights cell, T_W). The PLUS variant gets the
`+:acc` SIMD pragma. Used by `wsum` / `wmean` — and any future weighted
reduction the DSL knows how to emit.

### Element-wise transforms (maps)

```c
CA_SLAB_MAP_T(T_IN, T_OUT, st_in, p_in, st_out, p_out, MAP_EXPR);
        /* MAP_EXPR: statement binding `r` (T_OUT lvalue) given `v` (T_IN).
           e.g.  r = sqrt(v)
                 r = (T_OUT)(v * v + 1) */
CA_SLAB_MAP_F64(st_in, p_in, st_out, p_out, MAP_EXPR);   /* T_IN = T_OUT = double */
```

Both states must share slab geometry. The macro hoists the inner contig
fast-path for both sides. Mask handling is the caller's responsibility —
INOUT mask propagation is done outside the macro (typically via
`ca_copy_mask_overlay` at dispatcher time).

### Prefix scans

```c
CA_SLAB_SCAN_T(T_LOAD, T_OUT, st_in, p_in, m_in, st_out, p_out,
               INIT, STEP);
        /* STEP: statement binding `v` (T_LOAD, input), `r` (T_OUT lvalue,
                 output), and `acc` (T_OUT, running accumulator).
                   cumsum:   acc += v;        r = acc
                   cummax:   if (v > acc) acc = v;  r = acc
                   cumcount: (void) v;        r = ++acc */
```

The accumulator resets to `INIT` at the start of each outer iteration —
so per-fiber. Masked input cells skip the STEP and write the current
`acc` to the output (= "running aggregate excluding masked cell" — the
3.0 semantics chosen so downstream reductions stay continuous).

A wider variant decouples the accumulator type and exposes a `first` flag
to the STEP — used by adjacent-compare scans like `uniq_scan`:

```c
CA_SLAB_SCAN_TA(T_LOAD, T_OUT, T_ACC, st_in, p_in, m_in,
                st_out, p_out, INIT, STEP);
        /* STEP sees `v`, `r`, `acc` AND `first` (int, 1 on the first
           unmasked cell of each fiber, else 0). */
```

## Levels L1/L2/L3 and "deliver, materialising if needed"

The iterator drops to a dispatch *level* depending on what the source view
allows:

- **L1** — flat contiguous; the kernel writes a single inner loop with
  `p[i]`.
- **L2** — strided callback; the kernel walks per-slab with a byte
  stride. This is what the body-macro suite uses today.
- **L3** — multi-dimensional; reserved for a future K-D primitive.

A higher level can fall back to a lower one, **materialising** the data if
that is the only way to deliver it ([ch. 10](10_author_surface_overview.md)
"deliver the materials" principle). The kernel never learns whether its
data was aliased or materialised. If you need raw speed and the universal
path costs some SIMD inhibition, the lever is to *drop a level* (L2→L1) or
to use `CA_L2_FOR_EACH` to recover the contig fast-path within the L2
callback. The surface itself stays universal.

### `ca_iter_can_alias` and the level-aware decision

```c
int ca_iter_can_alias (void *ap, int level);
```

- `level == 1` — alias iff `parent->ptr` can be handed to the kernel as
  one contig run with stride implicit = `bytes`. True for entities and
  row-major-contig CAStride.
- `level == 2` — alias iff per-outer-axis slabs can be yielded as
  `parent->ptr + offset` with a native `stride_bytes`. Any CAStride-family
  view qualifies.
- `level == 3` — currently falls back to level-1 semantics.

`ca_attach_is_alias` (in [ch. 15](15_carray_h_helper_reference.md)) is the
level-1 oracle used by Tier-A delegate paths; new code in the
kernel_iterator path should call `ca_iter_can_alias` with an explicit
level.

## Masks: propagated by default

A kernel receives mask-aware iteration *by default* — masked input cells
produce masked output, automatically ([ch. 5](05_mask_and_undef.md)). The
`m` pointer in the body is the per-slab mask base (or `NULL` when the
source has no mask). To opt out — for a kernel that genuinely cannot
accept a masked source — declare `CA_KERNEL_NO_MASK`; the engine then
rejects a masked source with `CA_ITER_ERR_MASK_NOT_ALLOWED`. The `_FIBER`
(non-masked) forms are NO_MASK by construction.

### Mask helper macros

For kernels that read the mask directly:

```c
#define CA_MASK_GET(mask, i)            /* 0 if mask == NULL, else mask[i] */
#define CA_FOR_EACH_UNMASKED(p, mask, n, body)            /* skip masked cells */
#define CA_FOR_EACH_INDEX_UNMASKED(p, mask, n, i, body)   /* + iteration index */
#define CA_COUNT_UNMASKED(mask, n)      /* GCC statement-expr, returns cnt */
```

These are used by all the slab body macros internally; reach for them in
hand-written kernels when the body-macro suite doesn't fit.

## The WRITE path in detail

A kernel that writes back declares `CA_KERNEL_WRITE`. The engine then:

1. Validates the source is not read-only (`ca_is_readonly` → returns
   `CA_ITER_ERR_READONLY`).
2. On each `next_slab*` it yields the slab in the right alias mode (alias
   if the kernel can write directly through parent storage; scratch if
   the view's access pattern requires gather + scatter).
3. After the kernel's body, `sync_slab` either is a no-op (alias) or
   scatters the slab back via `ca_sync_data` (scratch path).
4. On `finish`, any remaining scratch is freed and the parent is detached.

The CA_KERNEL_FIBER_CONTIG path additionally caches a per-fiber data
offset (`last_data_off`) so `sync_slab` can compute the right scatter
destination without re-deriving it from `outer_idx`.

## Per-axis (`axis:`) computation — the project goal

`CA_SLAB_AXES` is what opens per-axis computation: it splits the array's
axes into *slab axes* (the inner ones the kernel reduces/scans over) and
*outer axes* (the ones it iterates). A reduce kernel accepts **multiple**
slab axes (`a.sum(1, 2)`); a scan kernel is **single-axis** (multi-axis
cumsum is semantically ambiguous — the user chains
`a.cumsum_ki(1).cumsum_ki(2)`). This is the mechanism behind the project
goal of opening per-axis capability to every stat method, while keeping
the flatten (no-arg) form.

## The one place `ca_attach` is right

The deliver principle says `ca_attach` is the last resort — but there is
one legitimate routine use: a **`CA_OBJECT` per-cell Ruby callback**
(CAObject). The iterator cannot transparently deliver a per-cell
`rb_funcall`, so CAObject kernels take the dedicated attach path.
Everything else goes through the iterator. Likewise, Faces are stripped on
entry (`ca_strip_face`) and re-lifted on the result, so a kernel never
sees a Face ([ch. 9](09_faces.md)).

## Internal routing (free-to-refactor)

These constants are **not** part of the freeze contract — they exist as
INTERNAL routing keys you might see in the engine and in `ca_iter_state`:

`src_kind`:

```c
CA_ITER_SRC_CASTRIDE             /* entity, CAStride family, CAUbrep */
CA_ITER_SRC_DESCRIPTOR           /* CAGrid / CASelect / CAMapping / CAWindow / CAShift / CSA */
CA_ITER_SRC_DESCRIPTOR_L2_ALIASABLE
CA_ITER_SRC_ATTACH               /* CAFake / CAByteSwap / CABitfield / CABitarray / CAReduce */
```

The classifier reads these off the source's op table, which only works for the
view classes compiled into the engine. A class installed from outside declares
its kind instead, with `ca_iter_register_source_kind(obj_type,
CA_ITER_SRC_ATTACH)` in its `Init_`; without it the source classifies as
`CA_ITER_SRC_NONE` and every kernel refuses it with `CA_ITER_ERR_NOT_CHEAP`. The
declaration is the one part of this routing an external author touches, so it is
additive rather than free-to-refactor. See [ch. 8](08_view_catalog.md), "Adding a
standalone view", step 6.

`alias_mode`:

```c
CA_ITER_ALIAS_NONE              /* scratch materialise */
CA_ITER_ALIAS_CONTIG            /* parent.ptr+offset, stride implicit */
CA_ITER_ALIAS_STRIDED           /* L2 stride-aware */
CA_ITER_ALIAS_ATTACH            /* view's own ca_attach materialised */
CA_ITER_ALIAS_PER_SLAB          /* T3 fallback via axis-dispatch gather */
CA_ITER_ALIAS_PER_SLAB_HOIST    /* T3 STRIDE-innermost specialisation */
CA_ITER_ALIAS_STACK             /* CAStack K-axis slab direct ptr access */
CA_ITER_ALIAS_STACK_OUTER_K     /* CAStack with K-axis in outer iter */
CA_ITER_ALIAS_PER_FIBER_FUSED   /* per-fiber fused xfer dispatch */
```

A kernel author never inspects these — they exist for the engine's own
routing decisions. If you find yourself comparing `st.alias_mode`
against a constant in kernel code, you have crossed into engine
territory; the right knob is almost certainly a higher-level flag (set
`CA_KERNEL_FIBER_CONTIG`, use `CA_L2_FOR_EACH`, …).

## Block-form macros (one-screen kernels)

The `CA_FOR_EACH_SLAB` and `CA_FOR_EACH_FIBER*` macros are wrappers around
the state-machine entry points; they handle `init` / `next` / `sync` /
`finish` so the kernel body shrinks to its essential statement.

Constraints (the same across the family):

- The kernel pre-declares the state struct (`ca_iter_state st;`), the
  slab cursor (`char *p`), and any mask cursor (`boolean8_t *m`) — C99
  does not allow two different-typed declarations in a `for` init clause,
  so they live in the surrounding scope.
- `break;` from the body exits cleanly (= the outer for's teardown clause
  runs `finish`).
- `return;` from the body LEAKS resources (scratch, parent attach). If
  you need early return, drop to the raw API.
- The macros are not statement-equivalent — they expand to nested `for`
  constructs. Don't follow them with `else`.
- INOUT macros runtime-assert strict full-shape equality (= same `ndim`
  and same `dim[axis]`); a mismatch silently skips the body. Authors that
  want broadcasting must drop to the raw API.

## Where to go next

- Generating typed coverage instead of hand-writing per type →
  [ch. 12](12_mkkernel_dsl.md).
- The element-wise sweep surface for whole-buffer transfers →
  [ch. 13](13_sweep_author_surface.md).
- The primitives the engine is built from →
  [ch. 15](15_carray_h_helper_reference.md).
- The engine internals memo (read before any engine-side refactor).

---
*When done, update the status row in [README](README.md).*
