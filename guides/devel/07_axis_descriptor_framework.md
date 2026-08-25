# 07 The per-axis descriptor framework

> **Status: draft.** Written through once; not yet re-verified against a live
> build. See [README](README.md) for conventions.

CAStride ([ch. 6](06_view_algebra_and_castride.md)) covers views that are a
*linear remap* of the parent. Some views are not: they pick parent elements by an
**index list** per axis, or by a **shifted/bounds-filled** mapping. The per-axis
descriptor framework is the shared engine that drives gather/scatter/fill for
those views, so each one emits a descriptor instead of writing its own attach
path. The authoritative source is the header
`ext/ca_axis_descriptor.h` (the D2/D3 interface
is documented inline there).
If this chapter and the code disagree, trust the code.

## The idea: describe axes, share the engine

Instead of every per-axis view implementing its own loop over the parent, a view
**describes each of its axes** with a small tagged record, and a common engine
reads those records to do the actual data movement. Two halves:

- **D2, the producer interface** — each view fills an array of descriptors, one
  per axis. The two producers are `ca_select_axis_describe_axes` (CASelectAxis)
  and `ca_grid_describe_axes` (CAGrid).
- **D3, the engine** — `ca_axis_dispatch_gather` / `_attach` / `_scatter` /
  `_fill_value` (plus `_merge`) in `ext/ca_axis_dispatch.c` consume the descriptor
  array and move bytes.

The payoff is the same "deliver, don't special-case" principle as the kernel
iterator: a new per-axis view connects to all of gather, scatter, and fill by
emitting a descriptor; it writes no transfer code of its own.

## The descriptor

```c
typedef enum {
  CA_AXIS_KIND_STRIDE = 0,
  CA_AXIS_KIND_INDEX  = 1,
  CA_AXIS_KIND_SHIFT  = 2
} ca_axis_kind_t;

typedef struct {
  ca_axis_kind_t  kind;
  ca_size_t       count;    /* output size contributed by this axis */
  /* STRIDE / SHIFT */
  ca_size_t       start;
  ca_size_t       step;
  /* INDEX only (NULL otherwise; borrowed from the producer view) */
  ca_size_t      *indices;
  /* SHIFT only */
  ca_size_t       size0;    /* parent dim along this axis (bounds check) */
  uint8_t         policy;   /* CA_BOUNDS_FILL / PERIODIC / REFLECT / NEAREST / … */
} ca_axis_desc_t;
```

Each axis is one of three kinds:

- **STRIDE** — parent index = `start + i·step`. The same affine mapping CAStride
  uses, expressed per axis so it can sit beside the other kinds; it subsumes Ruby
  slice arguments (`nil`, Integer, Range). An axis-merge can collapse a chain of
  contiguous STRIDE axes into one.
- **INDEX** — parent index = `indices[i]`, an arbitrary gather list (boolean /
  fancy / integer-array indexing). The `indices` pointer is **borrowed** from the
  producing view; the engine must not free or mutate it (its lifetime is tied to
  the view).
- **SHIFT** — parent index = `start + i·step` normalised by `policy`
  (`CA_BOUNDS_FILL` / `PERIODIC` / `REFLECT` / `NEAREST` / …) against `size0`;
  this covers CAWindow / CAShift. If normalisation still lands out of range (e.g.
  FILL policy beyond bounds), the engine writes the caller-supplied `bound_fill`
  value into the gather buffer, and skips the parent write on scatter.

That three-kind vocabulary is what lets one engine cover index-gather views,
bounds-filled shift views, and ordinary strided axes uniformly.

## The engine

`ext/ca_axis_dispatch.c` provides a symmetric set — `ca_axis_dispatch_gather` /
`_attach` / `_scatter` / `_fill_value` (full signatures under "The full engine
API" below). A few engine properties worth knowing:

- **It never reads `parent->dim`.** The caller passes `parent_axis_dims[]`, the
  *effective* parent dim per descriptor axis. For CASelectAxis / CAGrid that is
  just `parent->dim[k]`, but for flat-index views (CASelect under the
  flat-index work) it is `{parent->elements}` — a single-axis flat view of the
  parent. This decouples `descriptor.ndim` from `parent.ndim`, so a view can drive
  iteration over axes that don't match the parent's physical shape.
- **It reads only `parent->ptr` for data**, so the caller must have the parent
  attached first.
- **`bound_fill`** is the bytes-wide value written for OOB SHIFT cells; pass
  `NULL` when no SHIFT axis is present and the engine ignores it.

## Axis-merge inside the engine

`ca_axis_dispatch_merge` collapses adjacent **STRIDE** axes whose strides are
contiguous-compatible into a single STRIDE axis, shrinking the descriptor `ndim`
before the transfer loop. This is the descriptor-side counterpart to CAStride's
own axis-merge: fewer axes means a tighter inner loop and a better chance of
hitting a contiguous fast path. INDEX and SHIFT axes are never merged (their
mapping isn't affine in a mergeable way); genuine stride-0 / CARepeat axes never
reach this engine — they go through CAStride.

## Adding a per-axis view

To connect a new index/shift-style view:

1. Write a `*_describe_axes` producer that fills one `ca_axis_desc_t` per axis
   (choosing STRIDE / INDEX / SHIFT per axis) plus the effective parent dims.
2. Route the view's attach / sync / fill through `ca_axis_dispatch_attach` /
   `_scatter` / `_fill_value`.
3. You inherit gather, scatter, fill, and axis-merge for free — no transfer loop
   of your own.

This unification is also a worked instance of "universal dispatch and its accepted
cost" — the per-axis callback signature can inhibit some SIMD, and that cost is
accepted in exchange for one engine across all per-axis views.

## The full engine API

`ext/ca_axis_descriptor.h` declares the producer interface and the
dispatch engine. The engine entry points (all in
`ext/ca_axis_dispatch.c`):

```c
/* Gather: parent + descriptor → contig out_buf (caller-allocated). */
void  ca_axis_dispatch_gather  (CArray          *parent,
                                const ca_size_t *parent_axis_dims,
                                ca_axis_desc_t  *axes,
                                int8_t           ndim,
                                ca_size_t        bytes,
                                ca_size_t        total_elements,
                                const void      *bound_fill,
                                char            *out_buf);

/* Attach: same as gather, but mallocs the buffer; caller xfrees. */
char *ca_axis_dispatch_attach  (CArray          *parent,
                                const ca_size_t *parent_axis_dims,
                                ca_axis_desc_t  *axes,
                                int8_t           ndim,
                                ca_size_t        bytes,
                                ca_size_t        total_elements,
                                const void      *bound_fill);

/* Scatter: contig in_buf → parent (selected cells; SHIFT OOB skipped). */
void  ca_axis_dispatch_scatter (CArray          *parent,
                                const ca_size_t *parent_axis_dims,
                                ca_axis_desc_t  *axes,
                                int8_t           ndim,
                                ca_size_t        bytes,
                                ca_size_t        total_elements,
                                const char      *in_buf);

/* Broadcast scatter: write `val` (bytes wide) into every selected cell. */
void  ca_axis_dispatch_fill_value (CArray          *parent,
                                   const ca_size_t *parent_axis_dims,
                                   ca_axis_desc_t  *axes,
                                   int8_t           ndim,
                                   ca_size_t        bytes,
                                   ca_size_t        total_elements,
                                   const void      *val);
```

The four are symmetric: gather and scatter use the same descriptor
walk in opposite directions; attach is `gather` plus the malloc;
fill_value is a degenerate scatter that broadcasts one value.

### Engine helpers (substrate-level)

Declared in `ext/ca_iter_substrate.h` (non-static so the kernel
iterator can share them):

```c
void ca_axis_dispatch_merge          (ca_axis_desc_t *axes,
                                      int8_t *inout_ndim,
                                      ca_size_t *parent_axis_dims);
        /* Collapse adjacent contig-mergeable STRIDE axes into one,
           shrinking ndim. Run BEFORE the transfer loop. INDEX and
           SHIFT axes never merge. */

void ca_axis_dispatch_layout         (ca_axis_desc_t  *axes,
                                      int8_t           ndim,
                                      ca_size_t        bytes,
                                      ca_size_t       *strides_out);
        /* Compute the output buffer's row-major byte strides from
           the descriptor's count[]. */

void ca_axis_dispatch_prepare        (const ca_size_t      *parent_axis_dims,
                                      const ca_axis_desc_t *axes,
                                      int8_t                ndim,
                                      ca_size_t             bytes,
                                      ca_size_t            *pstrides_out);
        /* Compute the parent's byte strides from parent_axis_dims +
           bytes (= naive row-major; the engine may layer-fold). */

void ca_axis_dispatch_classify_prefix (const ca_axis_desc_t *axes,
                                       int8_t ndim,
                                       ca_op_prefix_axis_t *prefix_out,
                                       int8_t *slab_start_out);
        /* Pre-classify the descriptor into a prefix-walking schedule:
           outer (driven by per-cell index decode) vs slab (driven by
           contig byte-step). Hoists the per-cell switch out of the
           innermost loop — NumPy "Operand Descriptor" pattern. */

int  ca_axis_dispatch_is_innermost_stride (const ca_axis_desc_t *descs,
                                           int8_t ndim);
        /* True iff the innermost descriptor axis is STRIDE kind —
           the kernel-iterator alias gate for descriptor sources. */

int  ca_axis_dispatch_outer_has_shift     (const ca_axis_desc_t *descs,
                                           int8_t ndim);
        /* True iff any non-innermost axis is SHIFT kind (needs
           bounds check per outer iter). */

void ca_axis_dispatch_for_each_slab   (CArray            *parent,
                                       const ca_size_t   *parent_axis_dims,
                                       ca_axis_desc_t    *axes,
                                       /* ... per-slab callback ... */);
        /* Used by kernel_iterator's L1 descriptor entry point —
           walks the descriptor's outer axes, yielding one contig
           slab per outer position. */
```

The kernel iterator's descriptor source path uses
`ca_axis_dispatch_classify_prefix` + `_for_each_slab` to yield slabs
without re-walking the descriptor per outer iter.

## The descriptor producer interface (D2)

Each non-strided view exports a single function that fills the
descriptor array from its private state. The two current producers:

```c
void ca_select_axis_describe_axes (void *ca,
                                   ca_axis_desc_t *out,
                                   ca_size_t *out_parent_dims);

void ca_grid_describe_axes        (void *ca,
                                   ca_axis_desc_t *out,
                                   ca_size_t *out_parent_dims);
```

Both write `ndim` entries into `out` (caller-allocated, sized
`CA_RANK_MAX`) and `out_parent_dims`. The `void *` first argument is a
`CASelectAxis *` / `CAGrid *` respectively — the type is opaque in the
header to avoid pulling private struct definitions into the umbrella.
Each impl casts to its concrete type inside its `.c` file.

The **effective parent dim** in `out_parent_dims[k]` is the per-axis
parent size *as the descriptor sees it* — see "The engine" above for
why it can differ from `parent->dim[k]` (and how flat-index views use
`{parent->elements}` to drive iteration over a single flat axis).

## When NOT to use the framework

Some views deliberately stay off the descriptor engine:

| View | Why off-framework |
|---|---|
| CAStride family | Its own faster fast-path ladder; the descriptor STRIDE axis is a generalisation of the same idea |
| CASelect | 1-D output indexed by flat parent address; the per-axis decomposition doesn't apply |
| CARemap | Same — flat address remap |
| CAFake / CAByteSwap | Value reinterpretation, not address remap |
| CABitarray / CABitfield | Sub-byte packing |
| CAObject | Per-cell `rb_funcall` — must attach |
| CAReduce | Internal class; user-facing reductions go through the kernel iterator |

Use the framework when the view can describe each axis independently
in STRIDE / INDEX / SHIFT terms. Anything else has its own path —
[ch. 8](08_view_catalog.md) lists them.

## Where to go next

- The strided views this complements →
  [ch. 6](06_view_algebra_and_castride.md).
- The full per-view reference, including which views use this engine
  → [ch. 8](08_view_catalog.md).
- The kernel-iterator routing
  (`CA_ITER_SRC_DESCRIPTOR`) that dispatches descriptor sources →
  [ch. 11](11_kernel_iterator.md).
- The CAStride compose-fold the descriptor STRIDE axis shares ground
  with → [ch. 4](04_attach_lifecycle.md).

---
*When done, update the status row in [README](README.md).*
