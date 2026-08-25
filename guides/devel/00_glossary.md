# Glossary (developer vocabulary)

The terms a CArray *developer* meets in the C source. The user's guide
covers the same surface words (entity, view, address, mask, `data_type`,
Face) from the Ruby side; here we define the implementation-level terms. Read it
first or use it as a lookup; later chapters link back to these entries.

Entries are grouped, not alphabetised, so related terms sit together.

---

## Objects and types

**entity** — an array that owns its data buffer. `obj_type == CA_OBJ_ARRAY`
(plus `CScalar`, `CAWrap`). In C, an entity's `ptr` points to memory it is
responsible for. Contrast *view*.

**view** — an array that owns no data and refers to another array (its
*parent*). Every view's struct begins with the `CAView` prefix
(`parent`, `attach`, `nosync`). A view materialises its parent's data on demand
through the [attach lifecycle](04_attach_lifecycle.md). See the
[view catalog](08_view_catalog.md) for the full list.

**parent** — the array a view refers to (`ca->parent`). May itself be a view,
forming a *chain* down to a root entity.

**root** — the entity at the bottom of a view chain. `resolve_to_root` and
compose-fold walk to it.

**obj_type** — the integer tag identifying an array's concrete kind
(`CA_OBJ_ARRAY`, `CA_OBJ_REFER`, `CA_OBJ_BLOCK`, …). The first ~20 values are
fixed in the `carray.h` enum; the rest (`CAStride`, `CATranspose`, `CAGrid`,
`CAWindow`, all Faces, …) are assigned **at runtime** by `ca_install_obj_type()`.
`CA_OBJ_TYPE_MAX == 256`. Every per-type behaviour is dispatched on this tag.

**data_type** — the *element* type (`CA_INT32`, `CA_FLOAT64`, `CA_OBJECT`, …).
Orthogonal to `obj_type`: a `CABlock` view (obj_type) can hold `float64`
elements (data_type). The user-facing word is `data_type`; never "dtype".

**CA_OBJECT** — the `data_type` for cells holding arbitrary Ruby `VALUE`s. Such
arrays must be marked by `dmark`/`ca_mark` so the GC sees the contained objects.
Numeric kernels reach CA_OBJECT through the mkkernel `:object` branch
(see [ch. 12](12_mkkernel_dsl.md)).

## Dispatch tables

CArray dispatches per-type behaviour through parallel arrays indexed by
`obj_type`:

**`ca_func[obj_type]`** — the operation table (`ca_operation_function_t`,
`carray.h`): `free_object`, `clone`, `allocate`, `attach`, `sync`, `detach`,
`fill_data`, `create_mask`, the xfer-protocol hooks (`xfer_index`, `xfer_addrs`,
`fold_stride`, `xfer_stride`, `xfer_all`), and the `struct_size` / `pool_bytes`
/ `pool_init` pool hooks. The heart of the type system — most "what does this
view do" questions end here. (The historical `copy_data` / `sync_data` are being
unified into `xfer_all`.)

**`ca_class[obj_type]`** — the Ruby class object (`CABlock`, `CATranspose`, …).

**`ca_typeddata[obj_type]`** — the `rb_data_type_t` for the array.
**`ca_mask_class[obj_type]`** / **`ca_mask_typeddata[obj_type]`** — the same two
for the *mask* sibling of that type (e.g. `CABlockMask`).

## Memory

**xmalloc / xfree** — Ruby's accounted allocator. CArray uses these (and `ALLOC`
/ `ALLOC_N`, which wrap `xmalloc`) for all allocation; **`free()` is forbidden**
because it desyncs Ruby's malloc counters. See [ch. 3](03_memory_management.md).

**pool** — the per-instance `char *_pool` buffer that holds all of a view's
small metadata arrays (`dim`, `strides`, …) in one allocation, instead of many
separate `ALLOC_N`s. Allocated by `ca_array_pool_alloc`; the primitives live in
`ext/ca_array_pool.c`. A `NULL` `_pool` means the instance uses the legacy
separate-allocation path; the two coexist per-instance. See
[ch. 3](03_memory_management.md).

**TypedData** — Ruby's wrapped-C-struct mechanism. Each obj_type registers a
`rb_data_type_t` with a `dmark` (`ca_mark`), `dfree` (`ca_free`, dispatching to
`ca_func[obj_type].free_object`), and a `dsize`. Mask siblings use
`dfree = ca_free_nop` because the parent owns the mask's storage.

## The attach lifecycle

**attach** — make a view's `ptr` valid: allocate, then gather the parent's data
into it. `ca_is_attached(ca)` is defined as `(ca->ptr != NULL)` and used as the
ownership marker. The contract is R1–R4 (see [ch. 4](04_attach_lifecycle.md)):
attach is **not transitive** — attaching a child does not attach its parent.

**sync** — write a view's `ptr` data back to its parent. Suppressed by `nosync`;
a no-op while aliasing.

**detach** — free a view's `ptr` and detach its parent.

**alias (fast path)** — when a CAStride view is fully contiguous, attach just
points `ptr` at `parent->ptr + base_offset` instead of allocating and copying.
Writes land directly in parent memory; sync and detach do no work. This is what
makes `reshape` and row slices O(1).

**compose-fold** — when copying/syncing a chain of CAStride views, the strides
are composed so only the root is attached, skipping materialisation of the
intermediate views. See [ch. 4](04_attach_lifecycle.md).

**`attach!`** — a public block-form convenience that wraps an
attach/sync/detach in `rb_ensure`. Minor: it is barely used internally (a few
sites in `lib/carray/iterator.rb`) and is kept mainly as insurance, not as a
load-bearing part of the lifecycle. The real machinery is `ca_attach`/`ca_sync`/
`ca_detach`. `__attach__` / `__sync__` / `__detach__` (double underscore) are
internal-only.

## Kernels and the author surface

**kernel** — a unit of per-element or per-axis computation written by a C ext
author (reduce, map, scan, binop, search, sort). Kernels are *delivered* their
data by the kernel iterator and do not touch view structure themselves.

**kernel iterator** — the engine (`ext/ca_kernel_iterator.c`) and macro surface
(`ext/ca_kernel_iterator.h`) that feeds any of the ~22 views to a kernel through
one uniform interface. The **default** way to write a kernel; `ca_attach` is the
last resort. See [ch. 11](11_kernel_iterator.md).

**fiber** — a one-dimensional run of elements handed to a kernel by
`CA_FOR_EACH_FIBER`. The finest-grained iteration unit.

**slab** — a contiguous multi-dimensional sub-block handed to a kernel by
`CA_FOR_EACH_SLAB`. The `CA_SLAB_AXES` policy splits axes into slab axes (inner)
and outer axes, which is how per-axis (`axis:`) computation is expressed.

**level (L1 / L2 / L3)** — the dispatch tier the iterator drops to. L1 = flat
contiguous, L2 = strided callback, L3 = multi-dimensional. Higher levels can
fall back to lower ones, materialising if needed ("delivering" the data).

**mkkernel** — the Ruby DSL (`ext/mkkernel.rb`) that emits typed kernel coverage
(all data_types) for a kernel family into `carray_kernels.c`. The default
landing spot for a new operation. See [ch. 12](12_mkkernel_dsl.md).

**call_cfunc** — the older path (`ext/carray_call_cfunc.c`) that vectorises a
scalar C function over an array. Still used by companion-gem bridges. See
[ch. 14](14_call_cfunc.md).

**sweep** — the element-wise `xfer_all`-family macros for whole-array transfers.
See [ch. 13](13_sweep_author_surface.md).

**SIMD license** — permission for a reduction kernel to reassociate (reorder)
floating-point accumulation for vectorisation. Makes results ε-close, not
bit-exact; `_strict`/`_safe` variants opt out. See [ch. 12](12_mkkernel_dsl.md).

## Views and axes

**CAStride** — the base class for all linearly-strided views
(`parent->ptr + base_offset + Σ idx[k]·strides[k]`). CARefer, CABlock, CARepeat,
CATranspose, CAFarray, CAField are all CAStride subclasses, either *pure typedef*
(no extra fields) or *prefix+tail* (CAStride prefix + extra native state). See
[ch. 6](06_view_algebra_and_castride.md).

**pure typedef** — a CAStride subclass that adds no fields; its setup just calls
`ca_stride_setup`. **prefix+tail** — a subclass that appends native state
(e.g. CABlock's `start[]`/`step[]`/`count[]`); it must override `clone`, the
allocator, and `dsize`, and resync its prefix after mutating the tail.

**descriptor (per-axis)** — the `ca_axis_desc_t` that CASelectAxis and CAGrid
both emit, letting a shared engine (`ca_axis_dispatch_gather` / `_attach` /
`_scatter` / `_fill_value` in `ext/ca_axis_dispatch.c`) drive gather/scatter/fill
for any per-axis view. See [ch. 7](07_axis_descriptor_framework.md).

**axis-merge** — a pure pass that collapses adjacent contiguous-mergeable axes
into one, shrinking ndim so a slab fast path can fire.

## Masks and special values

**mask** — a child CArray (boolean storage, `uint8`) hanging off the parent's
`mask` field, recording which elements are missing. Mask propagation through
operations is part of every kernel's contract. See [ch. 5](05_mask_and_undef.md).

**UNDEF** — the singleton constant assigned to mark an element missing. Pinned
against compacting GC by `rb_gc_register_mark_object` in `Init_carray_undef`.

## Faces

**Face** — an extended data type layered on top of a numeric CArray that
reinterprets the raw bytes (a date, a duration, a struct record). Implemented as
a runtime-installed obj_type. CATime, CATimedelta, CARecord, CAConstString
are Faces. See [ch. 9](09_faces.md).

**portable table** — `face_state_portable_table[obj_type]`: whether a Face's
state can cross process/parent boundaries (Marshal, MemoryView, multi-parent
constructors). CAConstString is `0` (its buffer is per-parent), which is why it
is rejected by CAStack et al.

## C conventions at a glance

The hard style rules every CArray C file follows. Each links to its deep home;
this table is the single lookup, so you don't have to remember which chapter owns
which rule.

| Rule | In short | Deep home |
|---|---|---|
| **Prefix decides the type** | `rb_ca_*` / `rb_carray_*` take and return a Ruby `VALUE`; `ca_*` / `CA_*` take and return a `CArray *`. The name tells you how to call it without reading the body; a function that violates its prefix is a rename target. | [ch. 15](15_carray_h_helper_reference.md) |
| **`xmalloc` / `xfree` only** | All allocation goes through `xmalloc` / `ALLOC` / `ALLOC_N`; **`free()` is forbidden** — it desyncs Ruby's malloc counters. | [ch. 3](03_memory_management.md) |
| **`volatile VALUE`** | Mark any `VALUE` local that lives across a possibly-allocating call (`rb_funcall`, `rb_scan_options`, an allocation) `volatile`, so the compacting GC can't strand a stale register copy. When in doubt, mark it. | [ch. 15a](15a_common_idioms.md) |
| **`data_type`, never "dtype"** | The element-type word is `data_type` everywhere — code, comments, prose, error messages. "dtype" does not appear. | *data_type*, above |
| **`*_index`, not `arg*`** | A method that returns a position uses the `_index` suffix (`min_index`, `sort_index`); there is no `argmin` / `argsort`. A genuine flat address uses `_addr`. | [ch. 12](12_mkkernel_dsl.md) |
| **Don't grow the vocabulary** | Never wrap a CArray primitive in a new gem-local name (`cn_gather_to_buf` for `ca_copy_data`). Call the primitive; a new name earns its keep only by adding genuine semantic value. | [ch. 15](15_carray_h_helper_reference.md) |

**Comments.** C source comments are
English, present tense, explaining *why* the code looks the way it does — no phase
IDs, rev numbers, dates, bench numbers, or boasting; a `CAREFUL:` prefix marks a
load-bearing invariant; C89 `/* */` blocks only (no `//`). The Ruby-facing YARD
stubs follow the companion `yard-stubs/STYLE.md`, and
the two are applied together when a change touches both sides. Source comments are
English only.

---

*This glossary grows as chapters land. When a chapter introduces an
implementation term worth a one-line definition, add it here and link back.*
