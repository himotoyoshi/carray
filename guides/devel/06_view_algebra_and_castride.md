# 06 View algebra and CAStride

> **Status: draft.** Written through once; not yet re-verified against a live
> build. See [README](README.md) for conventions.

This chapter opens Part II. It covers the CAStride family — the base for every
linearly-strided view — how six historical view classes were unified onto it,
the two subclass patterns, the gather fast-path ladder, and how to add a new
strided view.

## What CAStride expresses

A CAStride view computes each element's address with one linear formula:

```
addr(idx) = parent->ptr + base_offset + Σ_k idx[k] · strides[k]
```

where `strides[k]` is a **byte** stride (negative and zero allowed) and
`base_offset` is the byte offset from the parent's buffer to `view[0,…,0]`. That
single formula covers a remarkable range of views:

- **slices** — non-unit `base_offset`, a subset of axes;
- **transposes** — permuted `strides`;
- **reshapes** — recomputed `strides` over the same buffer;
- **repeats** — a `stride == 0` axis (the same data seen many times);
- **byte reinterpretations** — `strides`/`bytes` scaled to a different element
  size.

Because all of these are "the same buffer, addressed differently", they are all
CAStride subclasses: **CARefer, CABlock, CARepeat, CATranspose, CAFarray,
CAField**. The CAStride unification collapsed roughly 2,100 lines of
near-duplicate per-class gather/scatter code into the one CAStride engine.

What CAStride deliberately does **not** express is anything that is not a linear
address remap of the parent: gather/scatter by index list
(CASelect/CAGrid/CARemap), bounds-filled shifts (CAWindow/CAShift), value
conversion (CAFake), sub-byte packing (CABitarray/CABitfield), reduction
(CAReduce), or Ruby callbacks (CAObject). Those have their own implementations
([ch. 8](08_view_catalog.md)).

## The two subclass patterns

### Pattern 1 — pure typedef

A subclass that adds **no fields**. Its struct is byte-for-byte a `CAStride`; the
class exists only to give the view a name and a Ruby identity. CATranspose,
CAFarray, CARepeat, CAField are pure typedefs. Setup is a thin function that
computes the strides and calls `ca_stride_setup` (signature in the CAStride C API
section below).

Nothing else to override — `clone`, the allocator, `dsize`, `create_mask` all use
the CAStride defaults. This chapter builds a `CAFlip` (reverse along axis 0) as a
worked example below: identity strides except `strides[0] = -strides_parent[0]`,
with `base_offset` pointing at the last row.

### Pattern 2 — prefix + tail

A subclass that appends native state after the CAStride prefix. CARefer
(`mask0`) and CABlock (`offset`, `start`, `step`, `count`, `size0`) are the two
examples ([ch. 2](02_core_data_structures.md) shows the structs). The tail exists
because something needs to read it: CABlock's tail backs the public accessors
(`#offset`, `#start`, …) and the block/dimension iterators that mutate `start[]`
in place.

A tail-bearing subclass **must** override four op-table slots, or it crashes or
silently misbehaves: **`clone`** and **the allocator** (so `ca_clone` and `dup`
allocate and copy the whole subclass struct, not just the CAStride prefix),
**`dsize`** (so GC accounting includes the tail), and **`create_mask`** (so the
mask is a same-class sibling — CABlockMask, CAReferMask — that can address the
parent's mask through the same tail; pure typedefs use the default). It must also
maintain one invariant: **after mutating the tail, resync the prefix** — an
iterator that advances `start[]` recomputes `base_offset` via
`ca_block_sync_base_offset`, or the view silently reads wrong data. The failure
symptom for getting each of these wrong is in "Common pitfalls" below.

## The gather fast-path ladder

When a CAStride view is attached and must gather (or scatter) its data, the
engine in `ca_obj_stride.c` picks the most efficient of several paths per call.
From most to least preferred:

| Path | Condition | Action |
|------|-----------|--------|
| **alias** | fully contiguous row-major run | no copy — `ptr` aliases `parent->ptr + base_offset` ([ch. 4](04_attach_lifecycle.md)) |
| **P1** | whole view is one contiguous run | a single `memcpy` of `elements · bytes` |
| **P2** | innermost dim contiguous (`strides[ndim-1] == bytes`) | outer loop with carried offset, each row `memcpy`'d — covers col-slices, negative outer strides |
| **P3** | innermost stride a positive multiple of `bytes` | element-strided copy (`mcopy_step`) |
| **naive** | anything else (negative innermost stride, byte-misaligned) | per-element copy over a flat index walk |

The alias case is the difference between O(1) and O(n): `ca_stride_is_contiguous`
is the gate, and it is non-static precisely because the kernel iterator and the
Tier A overlay path consult it to decide whether `ca_attach` will be cheap. A
`dim[k] == 1` axis contributes no displacement, so its stride is a don't-care in
the contiguity test.

This ladder is also why a deep view chain stays cheap: compose-fold
([ch. 4](04_attach_lifecycle.md)) folds the chain's strides down to the root, and
the folded view then takes one of these paths against the root in a single pass.

## Adding a new strided view

For a pure typedef (≈ 9/10 cases):

1. **Decide** the strides and `base_offset` your view imposes on the parent.
2. **Write** a thin setup function that computes them and calls `ca_stride_setup`
   (signatures in the CAStride C API section below):
   ```c
   int ca_<mine>_setup (CAStride *ca, CArray *parent, ...) {
     ca_size_t strides[CA_RANK_MAX];
     ca_size_t base_offset;
     /* compute strides[] and base_offset from your view's params */
     return ca_stride_setup(ca, CA_OBJ_<MINE>, parent,
                            parent->data_type, parent->bytes,
                            ndim, dim, strides, base_offset);
   }
   ```
3. **Construction path**: `ca_<mine>_new` allocates the CAStride struct via
   `ca_array_alloc(CA_OBJ_<MINE>, ndim)` ([ch. 3](03_memory_management.md)) and
   calls `ca_<mine>_setup`. `rb_ca_<mine>_new` is the VALUE wrapper.
4. **Register the obj_type**. Built-in obj_types (CARefer, CABlock, CARepeat) are
   installed in `carray_core.c:Init_carray_core`; runtime obj_types (CATranspose,
   CAFarray, …) via `ca_install_obj_type` in your `Init_ca_obj_<mine>`. The
   install function returns the assigned id and you typically stash it in an
   `extern int8_t CA_OBJ_<MINE>;` global.
5. **Register the Ruby class** as a subclass of `CAStride` in `ruby_carray.c` —
   **after** `CAStride` itself is defined (the `Init_carray_ext` ordering
   constraint).

`ca_install_obj_type` signature:

```c
int ca_install_obj_type (VALUE klass,
                         const rb_data_type_t *typeddata,
                         VALUE mask_klass,
                         const rb_data_type_t *mask_typeddata,
                         ca_operation_function_t func);
        /* Returns the assigned obj_type id. The `func` argument is
           passed by value — the function sets func.obj_type = id on
           the stored copy, so you can pass `ca_stride_func` directly
           under several obj_types without making a local copy first. */
```

For a **tail-bearing** subclass, also override `clone`, the allocator, `dsize`,
and `create_mask`, and maintain the prefix-resync invariant:

6. **Override `clone`** to copy the tail (the CAStride default copies only
   `sizeof(CAStride)`).
7. **Override the allocator** so `initialize_copy` allocates the right subclass
   struct (`sizeof(CABlock)` etc.).
8. **Override `dsize`** to account for the tail bytes.
9. **Override `create_mask`** so the mask is a same-class sibling (CABlockMask,
   CAReferMask) that addresses the parent's mask through the same tail. A
   CAStride subclass's mask is itself a CAStride subclass with
   `mask->mask == NULL`, so the free cascade terminates.
10. **Maintain the prefix-resync invariant**: any code that mutates `start[]`
    (block / dimension iterators) calls `ca_block_sync_base_offset` (or your
    subclass's equivalent) **before** the next data access through the prefix.

The failure symptom for each of these — segfault, `dup` type mismatch,
undercounted memory, wrong-class mask, silently wrong data — is in this chapter's
"Common pitfalls" section; read it before touching a tail-bearing subclass.

## The CAStride C API

All declared in `ext/carray.h` (group is reproduced here so you can
read the surface without flipping back to [ch. 15](15_carray_h_helper_reference.md)).

### Construction

```c
int       ca_stride_setup (CAStride *ca, int8_t obj_type, CArray *parent,
                           int8_t data_type, ca_size_t bytes,
                           int8_t ndim, ca_size_t *dim,
                           ca_size_t *strides, ca_size_t base_offset);
        /* Initialise an already-allocated CAStride. Returns 0 on
           success, raises on validation failure. Used by every
           CAStride-subclass setup function. */

CAStride *ca_stride_new   (int8_t obj_type, CArray *parent,
                           int8_t data_type, ca_size_t bytes,
                           int8_t ndim, ca_size_t *dim,
                           ca_size_t *strides, ca_size_t base_offset);
        /* C-level allocate + setup. */

VALUE     rb_ca_stride_new (VALUE cary,
                            int8_t data_type, ca_size_t bytes,
                            int8_t ndim, ca_size_t *dim,
                            ca_size_t *strides, ca_size_t base_offset);
        /* Ruby-level construction (returns a VALUE). Use this from
           any rb_ca_* method that creates a CAStride view. */
```

`obj_type` is the runtime-assigned `CA_OBJ_STRIDE` (external global) for
the base class, or the subclass's installed id for typedef descendants.

### Compose-fold

```c
void ca_stride_compose_to_root (CAStride *leaf,
                                CArray  **out_root,
                                ca_size_t *out_strides,
                                ca_size_t *out_base);
        /* Walk leaf -> parent -> ... -> root (the first non-CAStride
           ancestor or the entity), composing strides and base
           down the chain. Used by attach to skip per-link materialise. */

int       ca_stride_compose_through (CAStride *leaf, CAStride *parent,
                                     ca_size_t *out_strides,
                                     ca_size_t *out_base);
        /* One compose hop. Non-static so non-CAStride participants
           (CAWindow::fold_stride) can compose through a synthetic
           CAStride layer. */
```

### Subclass-tail helpers

For tail-bearing CAStride subclasses, the tail must be kept consistent
with the prefix. CABlock provides:

```c
void ca_block_sync_base_offset (CABlock *cb);
        /* Recompute base_offset from offset + start[] + size0[] +
           bytes after a caller mutates start[] in place. Forget this
           and the view silently reads wrong data. (The historical
           callers were the retired 2.0 C iterators, but the invariant
           binds any future code that mutates the tail.) */
```

### Layout-aware xfer (descriptor-framework integration)

```c
void ca_stride_xfer_with_layout (CAStride *ca, int scatter, char *base,
                                 /* … layout args … */);
        /* Internal: lets the descriptor engine reuse the CAStride
           xfer fast-path ladder while supplying its own destination
           layout. Called from ca_axis_dispatch_* when a descriptor
           is innermost-STRIDE. */

void ca_stride_merge_axes (ca_size_t *strides,
                           /* … */);
        /* Collapse adjacent contig-mergeable axes in-place — the
           CAStride-side counterpart to ca_axis_dispatch_merge. */
```

The full signatures are in `ext/ca_iter_substrate.h` (= the non-static
"substrate" exported for the kernel iterator and descriptor engine to
share).

## The xfer slot hookup (per CAStride subclass)

A CAStride descendant inherits the entire `xfer_*` family from
`ca_stride_func` — the base op table installed in
`carray_core.c:Init_ca_obj_stride`:

```c
ca_func[CA_OBJ_STRIDE].xfer_index  = ca_stride_func_xfer_index;
ca_func[CA_OBJ_STRIDE].xfer_addrs  = ca_stride_func_xfer_addrs;
ca_func[CA_OBJ_STRIDE].xfer_stride = ca_stride_func_xfer_stride;
ca_func[CA_OBJ_STRIDE].xfer_all    = ca_stride_func_xfer_all;
ca_func[CA_OBJ_STRIDE].fill_data   = ca_stride_func_fill_data;
ca_func[CA_OBJ_STRIDE].create_mask = ca_stride_func_create_mask;
/* attach / sync / detach forward to the same fast-path ladder via
   the alias / P1 / P2 / P3 / naive branch inside ca_stride_*. */
```

A pure-typedef subclass installs the **same** `ca_stride_func` under
its own obj_type — no overrides needed. A tail-bearing subclass
copies the table, overrides `clone` / `allocate` / `free_object` /
`dsize` (the four lifecycle slots that touch the tail), and installs
that. The xfer slots stay inherited because the tail does not affect
how data is gathered — only how the public Ruby accessors read the
view's parameters.

## The subclass map

| Subclass | obj_type | Pattern | What its strides encode |
|---|---|---|---|
| CAStride | `CA_OBJ_STRIDE` (runtime) | base | generic strided remap (`reshape`, hand-built views) |
| CARefer | `CA_OBJ_REFER` (fixed = 3) | prefix + `mask0` tail | reshape, byte-reinterpret, `.value` |
| CABlock | `CA_OBJ_BLOCK` (fixed = 4) | prefix + native spec tail (`offset` / `start` / `step` / `count` / `size0`) | slices `a[i..j, nil]` |
| CARepeat | `CA_OBJ_REPEAT` (fixed = 7) | pure typedef (`stride == 0` axis) | repeated axes (`a.repeat(k)`) |
| CATranspose | runtime | pure typedef | `a.transpose` |
| CAFarray | runtime | pure typedef | column-major view |
| CAField | runtime | pure typedef | fixlen field access (zero-copy) |
| CAUnboundRepeat | `CA_OBJ_UNBOUND_REPEAT` (fixed = 8) | prefix + `rep_dim` tail | `:*` unbound axis (pre-broadcast) |

`CARepeat` is technically `typedef CAStride CARepeat;` — the
"repeat" semantics are entirely encoded by `strides[k] == 0` on the
repeated axes. No separate code path.

## A pure-typedef walkthrough: CAFlip

> **`CAFlip` / `CA_OBJ_FLIP` is a pedagogical example only** — it is not a real
> obj_type in the tree, so don't grep for it. It illustrates the shape of a
> pure-typedef setup.

CAFlip (reverse along axis 0) is a one-screen example of a pure
typedef. The setup just inverts the parent's axis-0 stride:

```c
static int
ca_flip_setup (CAStride *ca, CArray *parent)
{
  ca_size_t strides[CA_RANK_MAX];
  ca_size_t base_offset = 0;
  /* CAStride parent's row-major strides; we'll override axis 0. */
  ca_stride_compute_row_major_strides(parent, strides);
  strides[0]  = -strides[0];
  base_offset = -strides[0] * (parent->dim[0] - 1);
  return ca_stride_setup(ca, CA_OBJ_FLIP, parent,
                         parent->data_type, parent->bytes,
                         parent->ndim, parent->dim,
                         strides, base_offset);
}
```

No tail, no overrides — `clone` / `allocate` / `dsize` use the CAStride
defaults. Two lines of math, one call to `ca_stride_setup`, and you
have a complete view that benefits from the entire fast-path ladder,
compose-fold, and the descriptor framework's STRIDE-axis recognition.

## The `create_mask` skeleton

`create_mask` is the op-table slot that builds a view's **mask sibling** — the
view that a masked parent projects onto the mask array ([ch. 5](05_mask_and_undef.md)).
The contract is uniform: ensure the parent has a mask, then build a *same-class*
view over `parent->mask` with the *same geometry* this view imposes on
`parent`. The signature is always the op-table shape, `void (*)(void *ap)`:

```c
static void
ca_block_func_create_mask (void *ap)
{
  CABlock *ca = (CABlock *) ap;
  ca_create_mask(ca->parent);                 /* parent now has a mask */
  ca->mask =
    (CArray *) ca_block_new(ca->parent->mask,  /* same class, over the mask */
                            ca->ndim, ca->size0,
                            ca->start, ca->step, ca->count, ca->offset);
}
```

A tail-bearing subclass reuses its own constructor with the tail parameters
verbatim, so the mask addresses the parent's mask through the identical block
spec. The CAStride base does the same thing at the raw stride level, converting
element geometry into the mask's byte units (`ca_obj_stride.c`):

```c
static void
ca_stride_func_create_mask (void *ap)
{
  CAStride *ca = (CAStride *) ap;
  ca_create_mask(ca->parent);
  /* Rescale strides from parent element bytes to mask element bytes,
     then build a CAStride of ca->obj_type over parent->mask so the
     mask of a CATranspose is a CATranspose, etc. */
  ca_size_t mask_strides[CA_RANK_MAX], mask_offset;
  ca_size_t parent_bytes = ca->parent->bytes;
  ca_size_t mask_bytes   = ca->parent->mask->bytes;
  for (int8_t k = 0; k < ca->ndim; k++)
    mask_strides[k] = (ca->strides[k] / parent_bytes) * mask_bytes;
  mask_offset = (ca->base_offset / parent_bytes) * mask_bytes;
  ca->mask =
    (CArray *) ca_stride_new(ca->obj_type, ca->parent->mask,
                             ca->parent->mask->data_type,
                             ca->parent->mask->bytes,
                             ca->ndim, ca->dim, mask_strides, mask_offset);
}
```

Two invariants make this safe: passing `ca->obj_type` (not a hard-coded
`CA_OBJ_STRIDE`) keeps the mask the *subclass's* mask class (so a CATranspose's
mask is a CATransMask, picked up via `ca_mask_class[obj_type]`), and the produced
mask is itself a view whose `mask->mask == NULL`, so the free cascade terminates
([ch. 2](02_core_data_structures.md), TypedData wiring; [ch. 5](05_mask_and_undef.md)).
Pure typedefs inherit `ca_stride_func_create_mask` and need nothing of their own;
a tail-bearing subclass **must** override it (pitfall #5 below), or the mask comes
back as a generic CAStride mask that reads the wrong bytes.

## Common pitfalls (the short list)

These are the six pitfalls in full; the ones most often missed:

1. **Tail-bearing subclass + missing `clone` override** → segfault in
   iteration (the default `clone` reads past the prefix).
2. **Tail-bearing subclass + missing allocator override** → `dup` raises
   "wrong argument type CAStride (expected CABlock)".
3. **Tail mutated, prefix not resynced** → silently wrong data. Always
   call `ca_block_sync_base_offset` after mutating `start[]`.
4. **Subclass struct prefix bytes don't match CAStride exactly** →
   field offsets shift, everything reads wrong. Order, types, and
   names must match.
5. **`create_mask` not overridden** → the mask is a generic CAStride
   mask instead of the subclass mask (e.g. CABlockMask), so iterators
   read the wrong bytes.
6. **`xfree(ca->dim)` on a CScalar** → crash. CScalar's `dim` is
   inline (`&ca->_dim`); the pool-aware `free_object` already handles
   this, but a hand-written cleanup that bypasses the table will trip.

## Where to go next

- Views that are *not* strided — gather/scatter by descriptor →
  [ch. 7](07_axis_descriptor_framework.md).
- The full per-view reference → [ch. 8](08_view_catalog.md).
- The attach fast path and compose-fold these paths build on →
  [ch. 4](04_attach_lifecycle.md).
- The kernel-iterator routing that uses `ca_attach_is_alias` /
  `ca_iter_can_alias` to pick its dispatch level →
  [ch. 11](11_kernel_iterator.md).

---
*When done, update the status row in [README](README.md).*
