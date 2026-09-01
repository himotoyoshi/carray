# 08 View catalog

> **Status: draft.** Written through once; the MemoryView-strategy column is
> verified for the types registered in `carray_memory_view.c`; a few runtime
> views are marked "(verify)" pending the `done` pass. See [README](README.md).

A reference entry per view kind: what it represents, its source file, whether it
is built on CAStride ([ch. 6](06_view_algebra_and_castride.md)), on the per-axis
descriptor framework ([ch. 7](07_axis_descriptor_framework.md)), or stands alone,
and its MemoryView export strategy ([ch. 18](18_memory_view_protocol.md)). Reach
for this when you touch a specific view.

The MemoryView strategies are: **direct** (contiguous, zero-copy), **strided**
(zero-copy via strides/offset), **attach** (materialise to a contiguous buffer
first), **reject** (not expressible).

## Entities and wrap

| Kind | obj_type | File | MV |
|------|----------|------|----|
| CArray | `CA_OBJ_ARRAY` | `ca_obj_array.c` | direct |
| CAWrap | `CA_OBJ_ARRAY_WRAP` | `ca_obj_array.c` | direct |
| CScalar | `CA_OBJ_SCALAR` | `ca_obj_array.c` | direct (0-D) |
| CASource | (abstract) | `ca_obj_source.c` | — |

The entity end ([ch. 2](02_core_data_structures.md)). CAWrap borrows foreign
memory; CScalar holds a single cell with an inline `_dim`. CASource has no
obj_type of its own — it is the class under which C extensions define arrays
that produce their own elements (recipe below).

## CAStride family (strided views)

All are the linear-stride remap of [ch. 6](06_view_algebra_and_castride.md);
attach aliases when contiguous. **MV: strided** (zero-copy) for all.

| Kind | obj_type | File | Pattern | Represents |
|------|----------|------|---------|------------|
| CAStride | `CA_OBJ_STRIDE` | `ca_obj_stride.c` | base | generic strided view (e.g. `reshape`) |
| CARefer | `CA_OBJ_REFER` | `ca_obj_refer.c` | prefix+tail (`mask0`) | reshape / byte-reinterpret / `value` |
| CABlock | `CA_OBJ_BLOCK` | `ca_obj_block.c` | prefix+tail (native spec) | slices `a[i..j, nil]` |
| CARepeat | `CA_OBJ_REPEAT` | `ca_obj_repeat.c` | pure typedef (`stride=0`) | repeated axes |
| CATranspose | `CA_OBJ_TRANSPOSE` | `ca_obj_transpose.c` | pure typedef | `transpose` |
| CAFarray | `CA_OBJ_FARRAY` | `ca_obj_farray.c` | pure typedef | column-major view |
| CAField | `CA_OBJ_FIELD` | `ca_obj_field.c` | pure typedef | fixlen field access (zero-copy) |

## Gather / scatter views

Element selection that is not a linear remap. CASelectAxis and CAGrid drive the
per-axis descriptor engine ([ch. 7](07_axis_descriptor_framework.md)).
**MV: attach** (must materialise — the access pattern isn't expressible as
strides).

| Kind | obj_type | File | Engine | Represents |
|------|----------|------|--------|------------|
| CASelect | `CA_OBJ_SELECT` | `ca_obj_select.c` | own | boolean / fancy indexing `a[a > 2]` |
| CAGrid | `CA_OBJ_GRID` | `ca_obj_grid.c` | descriptor | per-axis index grids; also the target of `a[mapper]` |
| CASelectAxis | (runtime) | `ca_obj_select_axis.c` | descriptor | per-axis selection |
| CARemap | (runtime) | `ca_obj_remap.c` | own | address remap (sort/partition consumption) |

> **CAMapping was retired in 3.0 (R.3).** `a[mapper]` now builds a CAGrid/CAStride
> chain instead. Do not reference `CAMapping` in new code or docs.

## Bounds-fill views

Shifted/windowed access with an out-of-bounds policy. Connected to the descriptor
engine via the SHIFT axis kind. **MV: attach.**

| Kind | obj_type | File | Represents |
|------|----------|------|------------|
| CAShift | `CA_OBJ_SHIFT` | `ca_obj_shift.c` | shift with fill |
| CAWindow | `CA_OBJ_WINDOW` | `ca_obj_window.c` | sliding window with bounds policy |
| CARoll | (runtime) | `ca_obj_roll.c` | circular shift (periodic policy) |

## Value-reinterpreting views

Convert the *value*, so not expressible as a byte remap. **MV: attach.**

| Kind | obj_type | File | Represents |
|------|----------|------|------------|
| CAFake | `CA_OBJ_FAKE` | `ca_obj_fake.c` | on-the-fly cast view (different data_type) |
| CAByteSwap | (runtime) | `ca_obj_byte_swap.c` | endianness swap |

## Sub-byte views

Packing smaller than one byte. **MV: reject** (no byte-addressable layout).

| Kind | obj_type | File | Represents |
|------|----------|------|------------|
| CABitarray | `CA_OBJ_BITARRAY` | `ca_obj_bitarray.c` | 1-bit-per-element boolean packing |
| CABitfield | `CA_OBJ_BITFIELD` | `ca_obj_bitfield.c` | bit-field extraction |

## Reduce / repeat

| Kind | obj_type | File | MV | Represents |
|------|----------|------|----|------------|
| CAReduce | `CA_OBJ_REDUCE` | `ca_obj_reduce.c` | attach | dimension reduction |

## Composite views

Combine multiple parents. **MV: attach (verify per type).**

| Kind | File | Represents |
|------|------|------------|
| CAStack | `ca_obj_stack.c` | stack along a new outer axis (multi-parent; refuse-to-materialise design) |
| CATile | `ca_obj_tile.c` | tiled repetition |

## Callback bridge

| Kind | obj_type | File | MV | Represents |
|------|----------|------|----|------------|
| CAObject | `CA_OBJ_OBJECT` | `ca_obj_object.c` | reject | per-cell Ruby callback; the one place `ca_attach` / `rb_funcall` is the right tool ([ch. 11](11_kernel_iterator.md)) |

## Lazy operation views

The unevaluated expression nodes ([ch. 17](17_lazy.md)).

| Kind | File | Represents |
|------|------|------------|
| CABinOp | `ca_obj_binop.c` | binary op (`a.lazy + b`) |
| CAMonOp | `ca_obj_monop.c` | unary op (`a.lazy.sin`) |
| CATriOp | `ca_obj_triop.c` | ternary op (`a.lazy.fma(b, c)`, `a.lazy.clip(lo, hi)`) |
| CABinCmp | `ca_obj_bincmp.c` | binary comparison |
| CAMonCmp | `ca_obj_moncmp.c` | unary comparison |

## Faces

Extended data types layered on a numeric/fixlen entity ([ch. 9](09_faces.md)).

| Kind | File | Represents |
|------|------|------------|
| (Face base) | `ca_obj_face.c` | the Face lift machinery |
| CATime | `ca_obj_time.c` | calendar timestamps |
| CATimedelta | `ca_obj_timedelta.c` | durations |
| CARecord | `ca_obj_record.c` | struct records over a CA_FIXLEN entity (MV: attach) |
| CAConstString | `ca_obj_const_string.c` | constant-string Face |

## Per-view notes

The tables above are the bird's-eye view; the entries below give the
details that don't fit in a table row — the constructor signature, the
struct tail (if any), and the subtleties an ext author will hit.

### Entities

**CArray (`CA_OBJ_ARRAY` = 0)** — the ordinary entity. Constructed via
`rb_carray_new(data_type, ndim, dim, bytes, mask)` /
`carray_new(...)`. Owns its `ptr` buffer; `free_object` xfrees both
the struct and the buffer. `bytes = 0` means "use the natural width";
`ca_sizeof[data_type]` is consulted.

**CScalar (`CA_OBJ_SCALAR` = 2)** — rank-0 entity. Layout = CArray
prefix + an inline `_dim` field that `dim` points at. **Never
xfree(ca->dim)** on a CScalar — `dim` is not separately allocated.
`rb_cscalar_new(data_type, bytes, mask)` /
`rb_cscalar_new_with_value(data_type, bytes, rval)`.

**CAWrap (`CA_OBJ_ARRAY_WRAP` = 1)** — `typedef CArray CAWrap`. Owns no
data buffer (its `ptr` is foreign); `free_object` xfrees the struct
but **not** `ptr`. The `refer` argument to `rb_carray_wrap_ptr` is the
GC anchor that keeps the underlying owner alive.

### The CAStride family

All inherit the four-level fast-path ladder (alias / P1 / P2 / P3), plus a
naive per-element fallback, and the compose-fold integration. The
subclass-specific notes:

**CARefer (`CA_OBJ_REFER` = 3)** — reshape (when
`ca->bytes == parent->bytes`) or byte-reinterpret (when they differ).
The `mask0` tail owns a CARepeat or CAReduce mask intermediate for the
byte-reinterpret modes; NULL otherwise. `rb_ca_refer_new(self,
data_type, ndim, dim, bytes, offset)`. The `.value` view (mask-
dropping) is a CARefer with `mask` left NULL.

**CABlock (`CA_OBJ_BLOCK` = 4)** — sliced view. Tail carries the
native spec (`offset` / `start[]` / `step[]` / `count[]` / `size0[]`)
backing the public Ruby accessors and the block / dimension iterators.
After mutating `start[]` (an iterator step), call
`ca_block_sync_base_offset(cb)` to resync the prefix.
`rb_ca_block_new(cary, ndim, dim, start, step, count, offset)`.

**CARepeat (`CA_OBJ_REPEAT` = 7)** — `typedef CAStride CARepeat`. The
"repeat" semantics are entirely encoded by `strides[k] == 0` on the
repeated axes; no separate code path. `rb_ca_repeat_new(cary, ndim,
count)` builds the view.

**CATranspose** (runtime), **CAFarray** (runtime), **CAField**
(runtime) — pure typedefs. `rb_ca_farray(self)` flips to column-major
without copy; `rb_ca_field_new(cary, offset, data_type, bytes)` builds
a fixlen field view (this is zero-copy strided).

### Scatter views

**CASelect (`CA_OBJ_SELECT` = 5)** — boolean / fancy indexing. Builds
a 1-D output addressed by a flat-index list against the parent's
elements. `rb_ca_select_new(cary, select)` / `rb_ca_select_new_share`.
Its access pattern is not a linear remap so it cannot alias parent
storage; attach materialises into a fresh contig buffer.

**CAGrid** (runtime) — per-axis index grids. Drives the descriptor
framework via `ca_grid_describe_axes`. The internal model is
`cag_axis_t *axes`, a per-axis tagged kind (INDEX / STRIDE / nil) —
a Range-typed axis emits a STRIDE
descriptor, so a `nil`-only axis costs no ALLOC. `rb_ca_grid(*args)` is
the Ruby method.

**CASelectAxis** (runtime) — per-axis selection. Drives the descriptor
framework via `ca_select_axis_describe_axes`. `rb_ca_select_axis(*args)`
/ `rb_ca_select_axis_eligible_p` (predicate).

**CARemap** (runtime) — flat-address remap. Consumed by the sort /
partition family (`sort_addr` emits CARemap addresses); its access
pattern is "permutation of parent->elements" expressed as a flat
address list. Not a kernel-author surface; do not construct
CARemap directly.

> **CAMapping was retired in 3.0 (R.3).** `a[mapper]` now builds a
> CAGrid / CAStride normalize chain instead. Do not reference
> `CAMapping` in new code or docs; the `camapping_data_type` extern
> is gone.

### Bounds-fill views

**CAWindow (`CA_OBJ_WINDOW`)** / **CAShift (`CA_OBJ_SHIFT`)** — same
struct (`typedef CAWindow CAShift`), different obj_type. The per-axis
`bounds[]` policy can be `CA_BOUNDS_FILL` / `_PERIODIC` / `_REFLECT` /
`_NEAREST` / `_MASK` / `_STRICT` / `_RUBY` ([ch. 2](02_core_data_structures.md)).
For FILL / MASK bounds, the `embed_*` fields encode a one-alias-plus-
one-fill decomposition the attach uses to skip per-element bounds
checks. For PERIODIC / REFLECT / NEAREST, attach falls through to the
`ca_axis_dispatch_*` engine ([ch. 7](07_axis_descriptor_framework.md)).
The view also implements `fold_stride` — it is a "sometimes-fold"
participant in compose-fold ([ch. 4](04_attach_lifecycle.md)).

**CARoll** (runtime, `typedef CATile CARoll`) — circular shift. Built
on CATile's region-list machinery (= K tiles, each a full-parent
alias at an output offset). T.4 will add a `CARoll`-specific
constructor; until then the runtime path is identical to CATile.

### Value-reinterpreting views

**CAFake (`CA_OBJ_FAKE`)** — on-the-fly cast view (different
data_type). Used internally by `rb_ca_wrap_readonly` to coerce a
kernel input to a fixed type without copying — when the type already
matches it's pass-through. Attach materialises (the value conversion
is not byte-aligned). `rb_ca_fake_new(cary, data_type, bytes)`.

**CAByteSwap** (runtime) — endianness swap. The mask layout uses the
parent class's TypedData (= mask is a CAByteSwap with `mask->mask
== NULL`) — the GC cascade was historically the trickiest part to get
right ([ch. 5](05_mask_and_undef.md)). Attach materialises.

### Sub-byte views

**CABitarray (`CA_OBJ_BITARRAY`)** — 1-bit-per-element boolean
packing. Attach uses the `ca_bit_unpack` / `ca_bit_pack` primitives
([ch. 4](04_attach_lifecycle.md), bulk bit-unpack/pack). The bit order
within a byte is **LSB-first FIXED**; the parent element width and
optional multibyte byte-swap are parameters. MV strategy is **reject**
(no byte-addressable layout).

**CABitfield (`CA_OBJ_BITFIELD`)** — bit-field extraction from a
parent integer array. Attach materialises into a fresh contig buffer
of the chosen output integer width. MV reject.

### Reduce

**CAReduce (`CA_OBJ_REDUCE`)** — internal class used only in
`ca_obj_refer.c` for byte-reinterpret modes. Not a user-facing view;
user-facing reductions go through the kernel iterator
([ch. 11](11_kernel_iterator.md)) and produce fresh entities, not
CAReduce views.

### Composite (multi-parent) views

**CAStack** (runtime) — outer-axis-only stack view of K uniform-shape
parents. Layout = CAView prefix + `n_parents` + `parents[]` +
`k_axis`. Sets `CA_FLAG_MULTI_PARENTS` so generic `parent`-walking
code falls back to the `CAMultiParent` cast
([ch. 2](02_core_data_structures.md)). The Ruby wrapper holds
`@parents` (the GC anchor); the C `parents[]` is alias-only.
Constructed via `CArray.stack(list, axis: 0)` /
`CArray.merge(list, at: -1)`. Refuse-to-materialise design: as much
gather/scatter as possible runs per-parent via direct ptr aliases
(`CA_ITER_ALIAS_STACK` in the kernel iterator,
[ch. 11](11_kernel_iterator.md)). MV strategy depends on alias
state — typically attach.

**CATile** (runtime) — tiled repetition. `dim[k] = parent->dim[k] *
reps[k]`; total tiles = `Π reps`. Each tile is a full-parent alias at
an output offset. Attach iterates the tile list. MV attach.

### Callback bridge

**CAObject (`CA_OBJ_OBJECT` = 6)** — per-cell Ruby callback. Layout =
CAView prefix + `data` (a CArray) + `self` (the Ruby callback's
self). The one view kind whose data path goes through `rb_funcall` per
cell, and the one place a kernel author legitimately uses `ca_attach`
directly ([ch. 11](11_kernel_iterator.md), "the one place ca_attach is
right"). MV reject — VALUE has no portable byte layout. `CAObjectMask`
is the internal mask sibling — registered with its own TypedData but
ultimately backed by a Ruby `VALUE array`.

### Lazy operation views

The lazy-op tree ([ch. 17](17_lazy.md)). Four classes plus the
sentinel:

| Kind | obj_type | File | Body |
|---|---|---|---|
| CABinOp | runtime | `ca_obj_binop.c` | binary op (`a.lazy + b`) — children `lhs`, `rhs`, `opcode` |
| CAMonOp | runtime | `ca_obj_monop.c` | unary op (`a.lazy.sin`) — child `operand`, `opcode` |
| CATriOp | runtime | `ca_obj_triop.c` | ternary op (`a.lazy.fma(b, c)`, `a.lazy.clip(lo, hi)`) — children `op1`, `op2`, `op3`, `opcode` |
| CABinCmp | runtime | `ca_obj_bincmp.c` | binary comparison — produces boolean output |
| CAMonCmp | runtime | `ca_obj_moncmp.c` | unary comparison |
| CALazyMarker | runtime | `carray_lazy.c` | wraps a non-lazy CArray as a lazy leaf |

`ca_is_lazy_view(ca)` returns true for any of these — the
mkkernel-generated reduce kernels use it to dispatch to the streaming
branch.

### Faces

The Face family ([ch. 9](09_faces.md)). All runtime-installed:

| Kind | File | Storage | What it adds |
|---|---|---|---|
| CAFace base | `ca_obj_face.c` | — | the lift machinery + `CA_FLAG_IS_FACE` |
| CATime | `ca_obj_time.c` | int64 (epoch ticks) | calendar timestamps + unit (count × base) |
| CATimedelta | `ca_obj_timedelta.c` | int64 (ticks) | durations |
| CARecord | `ca_obj_record.c` | fixlen | struct records over CA_FIXLEN entity |
| CAConstString | `ca_obj_const_string.c` | fixlen | read-only variable-length string column — per-parent buffer, not portable |

MV strategy for Faces depends on storage transparency: Faces over a
numeric storage delegate to the storage's MV strategy
(typically strided); CARecord additionally exposes its struct format
via `ca_mv_format_for`.

## Adding a standalone view

Most new views are not standalone: a linearly-addressable view is a CAStride
subclass ([ch. 6](06_view_algebra_and_castride.md), emit `strides`), and a
per-axis gather/shift view drives the shared descriptor engine
([ch. 7](07_axis_descriptor_framework.md), emit a `ca_axis_desc_t`). A
**standalone** view is the third case — one whose access pattern is neither a
linear remap nor a per-axis descriptor, so it implements its own data movement in
its op table. CASelect (`ca_obj_select.c`) is the smallest self-contained
example; this recipe is grounded in it.

**1 — Define the struct.** Start with the full `CAView` prefix (byte-for-byte the
`CArray` layout plus `parent` / `attach` / `nosync`, [ch. 2](02_core_data_structures.md)),
then append the view's own tail. CASelect snapshots the boolean selector and
pre-computes the TRUE positions, so its tail is the snapshot plus a small
constant-step descriptor and an inline `_dim` (the output is 1-D, so `dim` points
at `_dim` and needs no separate allocation, like CScalar):

```c
typedef struct {
  /* … CAView prefix (obj_type … _pool, parent, attach, nosync) … */
  CArray    *select;      /* snapshot of the selector (owned) */
  ca_size_t *indices;     /* TRUE positions in flat parent order (owned) */
  uint8_t    stride_kind; /* 1 ⇒ TRUE positions are an arithmetic run */
  ca_size_t  stride_start, stride_step;
  ca_size_t  _dim;        /* inline axis length; dim points here */
} CASelect;
```

**2 — Fill the op table.** A standalone view supplies the op-table slots itself
([ch. 2](02_core_data_structures.md), `ca_operation_function_t`) — this is where
"a standalone view implements its own gather/scatter" lives. CASelect's table
(`ca_select_func`) is the canonical set:

```c
ca_operation_function_t ca_select_func = {
  CA_OBJ_SELECT, CA_VIEW_ARRAY,
  free_ca_select,               /* free_object — frees the snapshot + indices */
  ca_select_func_clone,         /* clone */
  ca_select_func_allocate,      /* allocate — attach parent, xmalloc ptr */
  ca_select_func_attach,        /* attach  — gather parent → ptr */
  ca_select_func_sync,          /* sync    — scatter ptr → parent */
  ca_select_func_detach,        /* detach  — free ptr, detach parent */
  ca_select_func_fill_data,     /* fill_data */
  ca_select_func_create_mask,   /* create_mask — same-class mask sibling */
  ca_select_func_xfer_index,    /* xfer_index */
  ca_select_func_xfer_addrs,    /* xfer_addrs */
  NULL,                         /* fold_stride — NULL: never fold, gather boundary */
  ca_select_func_xfer_stride,   /* xfer_stride */
  ca_select_func_xfer_all,      /* xfer_all */
};
```

`fold_stride = NULL` is the standalone marker: the view is a gather boundary that
compose-fold ([ch. 4](04_attach_lifecycle.md)) stops at, unlike a CAStride which
folds through. The pool hooks (`struct_size` / `pool_bytes` / `pool_init`) are
left unset, so the type stays on the legacy `ALLOC` path
([ch. 3](03_memory_management.md)) — CASelect allocates with `ALLOC(CASelect)`
and keeps `dim` inline. What the slots *do* is the view's business: CASelect
routes its attach / sync / xfer through the shared `ca_axis_dispatch_*` engine
via a one-axis `describe_axes` producer, whereas CAObject routes them through
`rb_funcall` per cell — either way the op table is the seam.

**3 — Write the setup and constructors.** `ca_select_setup` validates the
selector, snapshots it, computes `indices[]`, and wires the scalar fields
(`obj_type`, `data_type`, `ndim`, `bytes`, `ptr = NULL`, `parent`). `ca_select_new`
is the C constructor (`ALLOC` + setup); `rb_ca_select_new` is the VALUE wrapper —
it `TypedData_Get_Struct`s the parent, calls `ca_wrap_struct`, sets the Ruby-side
parent anchor with `rb_ca_set_parent`, and lifts a Face if the parent is one
(`CA_FACE_LIFT_IF_FACE`).

**4 — Register the obj_type and TypedData.** A *new* view is runtime-installed:
call `ca_install_obj_type` from your `Init_ca_obj_<mine>`, which returns the
assigned id (stash it in an `extern int8_t CA_OBJ_<MINE>;` global). The CAGrid
`Init_` is the pattern to copy:

```c
CA_OBJ_GRID = ca_install_obj_type(rb_cCAGrid,
                                  &cagrid_data_type,
                                  rb_cCAGridMask, &cagrid_mask_data_type,
                                  ca_grid_func);
rb_define_const(rb_cObject, "CA_OBJ_GRID", INT2NUM(CA_OBJ_GRID));
```

The two `rb_data_type_t`s follow the standard split: the view's own TypedData
uses `dfree = ca_free` (dispatches to `free_object`); its **mask** TypedData
parents off the view's and uses `dfree = ca_free_nop`, because a mask is owned by
its parent and must not be double-freed ([ch. 5](05_mask_and_undef.md)):

```c
const rb_data_type_t caselect_data_type = {
  .parent = &caview_data_type,   .wrap_struct_name = "CASelect",
  .function = { .dmark = ca_mark, .dfree = ca_free,     .dsize = ca_select_dsize },
};
const rb_data_type_t caselect_mask_data_type = {
  .parent = &caselect_data_type, .wrap_struct_name = "CASelectMask",
  .function = { .dmark = NULL,    .dfree = ca_free_nop, .dsize = ca_select_dsize },
};
```

(CASelect itself is one of the nine *fixed* obj_types, so it is wired directly in
`carray_core.c:ca_init_obj_type` — `ca_func[CA_OBJ_SELECT] = ca_select_func;` and
the matching `ca_class` / `ca_typeddata` / `ca_mask_*` rows — rather than through
`ca_install_obj_type`. New views take the runtime `ca_install_obj_type` path
above; do not extend the fixed enum.)

**5 — Define the Ruby class.** The view's Ruby class subclasses `CAView`, and its
mask class subclasses the view class. For CASelect these are defined in
`ruby_carray.c` (`rb_define_class("CASelect", rb_cCAView)` / `"CASelectMask"`
under it); a runtime view can define them in its own `Init_`. `Init_ca_obj_select`
then registers the allocator (`rb_define_alloc_func`) and `initialize_copy` (which
re-snapshots so a `dup` gets independent `indices`).

**6 — Tell the kernel iterator how to read it.** The classifier in
`ca_iter_classify_source` ([ch. 11](11_kernel_iterator.md)) recognises the core's
own views by comparing their op table against a list compiled into the engine. A
class you installed with `ca_install_obj_type` matches nothing on that list, so it
classifies as `CA_ITER_SRC_NONE` and **every kernel that goes through the iterator
refuses the array** — `sum`, `mean`, `cumsum`, `sort_index`, the lot, each raising
from init with `rc=1` (`CA_ITER_ERR_NOT_CHEAP`). The break is uneven and reads
like a bug elsewhere: a slice of the view still works (the CABlock is classified
on its own obj_type), and so does an entity underneath it, but the whole array
does not. Declare the routing in your `Init_`:

```c
CA_OBJ_MINE = ca_install_obj_type(rb_cCAMine, &camine_data_type,
                                  rb_cCAMineMask, &camine_mask_data_type,
                                  ca_mine_func);
ca_iter_register_source_kind(CA_OBJ_MINE, CA_ITER_SRC_ATTACH);
```

`CA_ITER_SRC_ATTACH` is the only kind you may register, and it asks for nothing
you have not already written: the iterator calls `ca_attach` on your view, reads
`ptr` as a flat contiguous slab, and on a writing kernel calls `ca_sync` to let
your `sync` slot scatter back. That is the same contract as CAFake and CAReduce.
The other kinds are not open to registration — `CA_ITER_SRC_CASTRIDE` asserts the
struct *is* a CAStride (and a view that really is one is already classified by its
inherited op table, ahead of this table, so a registration for it is ignored), and
`CA_ITER_SRC_DESCRIPTOR` needs a `describe_axes` the engine looks up in a table of
its own. Passing either raises rather than accepting a routing the iterator cannot
honour.

A `CA_REAL_ARRAY` source needs no registration: `ca_is_entity` is checked ahead of
everything else, so it already passes on the entity path.

**Contrast with the other two recipes.** The CAStride recipe
([ch. 6](06_view_algebra_and_castride.md)) writes *no* xfer slots — it inherits
`ca_stride_func` and only emits `strides` + `base_offset`. The descriptor recipe
([ch. 7](07_axis_descriptor_framework.md)) writes a `describe_axes` that emits a
`ca_axis_desc_t` per axis and lets the engine move the data. A standalone view
owns its op-table slots outright, which is why it is the most code but also the
only way to express an access pattern the other two frameworks can't.

## Adding a source

The three recipes above all derive from another CArray. A **source** does not:
it produces its elements itself. An image library's pixel cache, a `cv::Mat`, a
file-backed variable, an arithmetic progression — there is no parent to be a view
of, and no buffer CArray allocated to be an ordinary entity. These subclass
`CASource`.

`CASource` (`ca_obj_source.c`) is a marker and nothing more: a class under
CArray, an allocator that raises, and a TypedData chain entry. No op table, no
dispatch, no shared helper, no state — and it stays that way, because nothing in
the core asks "is this a CASource". Everything a source does, the subclass
writes. The steps are the standalone-view recipe above with three differences,
and `spec/spec_ai/ext_source_smoke/source_smoke.c` is the worked example (a
source over a buffer owned by a Ruby String, registered from outside the core the
way a companion gem would).

**Choose `entity_type` first — it decides the rest.**

| | `CA_REAL_ARRAY` | `CA_VIEW_ARRAY` |
|---|---|---|
| when | the buffer is already addressable | values must be produced on demand |
| struct prefix | plain CArray | CAView, with `parent = NULL` |
| the core sees | an entity, like CAWrap — no parent is ever read | a view — paths that walk parents must be taught to stop |
| status | works today | needs core work first (the parent-walking paths still assume a parent) |

Concretely, `ca_is_entity()` is checked ahead of the CAView branch in both
`ca_has_mask` ([ch. 5](05_mask_and_undef.md)) and the kernel-iterator's source
classifier ([ch. 11](11_kernel_iterator.md)), so a `CA_REAL_ARRAY` source passes
through the engine on the entity path and the parentless question never arises.

**1 — The op table is yours, all of it.** Same as a standalone view: fifteen
slots, `fold_stride = NULL` (a source is always a fold boundary — it *is* the
root). Write the xfer slots against your own buffer rather than delegating to
`ca_array_func_*`; the delegation would work for a contiguous buffer, but the
point of a source is that its access pattern is its own business.

**2 — Stay cold at rest if the backend can move the buffer.** This is the one
that bites, and it runs opposite to the intuition. `ca->ptr` is not what makes
your slots work — it is what makes the core *skip* them. While `ptr` is
non-NULL, `ca_xfer_stride_dispatch` and `ca_xfer_addrs_dispatch` move bytes
straight through it ([ch. 4](04_attach_lifecycle.md)); with `ptr` NULL every
path lands in a slot, including `xfer_index`, which always does. So if a slot
re-resolves the address from the backend on entry — and re-validates it while it
is there — leaving the array cold at rest is what makes that check run on every
path. Publishing `ptr` permanently turns it off for element access and region
transfer, silently: the reads still succeed, from an address nobody rechecked.

Cold at rest needs a hold count in your own struct, because entities carry no
attach reference count (only CAView does, [ch. 4](04_attach_lifecycle.md)):

- `attach` **and** `allocate` publish `ptr` and take a hold; `detach` releases
  one and clears `ptr` when the last one goes.
- `allocate` must publish — the core writes through `ca->ptr` after
  `ca_allocate` (`seq!` does) — and it must count, because the `detach` that
  follows it arrives with no matching `attach`. Leave `allocate` out of the
  count and the array silently stays warm, which is the failure above.
- Without any count, an inner attach/detach pair clears `ptr` under an outer
  holder — `v.attach! { src.sum; v.to_a }` — and the outer sync dies with
  `[BUG] tried to sync data to detached array`.
- Resolve into a **local** in the data slots; never assign `ca->ptr` there. That
  assignment leaks a published pointer into the next operation, which then
  bypasses the guard and returns a correct-looking answer.

What this buys is that a backend which re-shapes the buffer (an image resized,
a cache re-allocated) is refused on every path, including a view of the source
held across the change, rather than read through a stale address.

**Where those three rules come from.** They are not source-specific discoveries.
They are what `ca_attach` / `ca_allocate` / `ca_detach` already do for views — in
the branch that declaring `CA_REAL_ARRAY` opts out of. `ca_is_view()` reads
nothing but `entity_type`, so the counter and the guarded slot calls live on one
side of that test and your struct is on the other:

| | engine, view branch | your struct, entity branch |
|---|---|---|
| `ca_attach` | `attach += 1`; calls `func.attach` **only if `ptr` is NULL** | take a hold; publish on the first |
| `ca_allocate` | `attach += 1`; calls `func.allocate` **only if `ptr` is NULL** | `allocate` takes a hold too |
| `ca_detach` | calls `func.detach` **only when `attach == 1`**, then `-= 1` | release a hold; clear `ptr` on the last |
| entity branch | calls `func.attach` / `func.detach` unconditionally, no counter | — which is why you write the counter |

Read that way, the two failures above stop being surprises. The `detach` that
follows `allocate` is not unpaired — `ca_allocate` raised the same counter the
`detach` lowers; it only looks unpaired if you count calls to `func.attach` and
miss the hold `func.allocate` took. And overlapping attach windows cannot strand
a view, because `func.detach` runs for the last holder only.

So the `CA_VIEW_ARRAY` row of the table above comes with cold-at-rest and hold
counting already built: `func.attach` fires exactly at the publish point,
`func.detach` exactly at the clear point. Its cost is the other half of that row
— the paths that walk parents. Picking `CA_REAL_ARRAY` today trades that core
work for the counter in your own struct; it is a trade, not a free win, and
worth revisiting once the parent-walking paths learn to stop.

**3 — Define the allocator and `initialize_copy` yourself.** CASource seals its
allocator so it cannot be instantiated, and a subclass inherits that seal: without
`rb_define_alloc_func` + `TypedData_Make_Struct` of your own, `dup` and `clone`
raise TypeError. `free_object` follows the CAWrap rule — free the struct and your
tail, never the foreign buffer — and the foreign owner needs a GC anchor (an ivar
on the wrapper object, or a `dmark` over a `VALUE` in your tail).

Two things a source does not get. MemoryView export is unavailable to any
extension-defined obj_type: the strategy table is keyed by class name with no
registration hook, so `CArray.memory_view_available?` answers `false` and export
is declined — hand out `src.copy` instead. And compose-fold never folds through
a source, which is exactly right: it is the root of every chain built on it.

## The exact MV strategy table

For the canonical strategies (the ones declared in
`carray_memory_view.c`'s `ca_mv_runtime_types[]`):

| Strategy | Meaning | View kinds |
|---|---|---|
| **direct** | contiguous, zero-copy | CArray, CAWrap, CScalar |
| **strided** | strided, zero-copy | every CAStride descendant — CARefer (with `is_deformed ∈ {0,1}`), CABlock, CAFarray, CATranspose, CARepeat, CAStride, CAField |
| **attach** | materialise into contig buffer first | CASelect, CAGrid, CAWindow, CAShift, CAFake, CAByteSwap, CABitfield, CAReduce, CARecord, CARemap, CARoll, CATile, CAStack (alias state allowing) |
| **reject** | not expressible as bytes | CABitarray, CAObject, CAConstString (per-parent buffer) |

The full `ca_mv_runtime_types[]` decision is in
`ext/carray_memory_view.c`; [ch. 18](18_memory_view_protocol.md) walks
the protocol-level surface.

## Where to go next

- The strided family in depth → [ch. 6](06_view_algebra_and_castride.md).
- The descriptor engine the gather / shift views share →
  [ch. 7](07_axis_descriptor_framework.md).
- The MemoryView strategy table and what each export does →
  [ch. 18](18_memory_view_protocol.md).
- Faces → [ch. 9](09_faces.md).
- The lazy operation tree → [ch. 17](17_lazy.md).
- The kernel-iterator routing that picks `CA_ITER_SRC_*` based on view
  kind → [ch. 11](11_kernel_iterator.md).

---
*When done, update the status row in [README](README.md). Remaining
for the `done` pass: confirm MV strategy for CAByteSwap / CASelectAxis
/ CARemap / CARoll / CATile / CAStack / the Faces against
`carray_memory_view.c`.*
