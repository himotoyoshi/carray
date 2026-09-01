# 01 Architecture overview

> **Status: draft.** Written through once; examples not yet re-verified against a
> live build. See [README](README.md) for conventions.

This chapter orients you before any deep dive. It answers four questions: what an
array *is* in the C source, how CArray decides what each array can *do*, how the
classes relate, and where to find things in `ext/`. Every later chapter assumes
this picture.

## Two kinds of array: entity and view

Every CArray is one of two things.

An **entity** owns its data. Its `ptr` field points at a block of memory the
array is responsible for allocating and freeing. `CArray` (the ordinary array),
`CScalar` (a single cell), and `CAWrap` (an array over memory owned by something
else) are entities.

A **view** owns no data. It refers to another array — its **parent** — and
presents that parent's storage in some rearranged form: a slice, a transpose, a
reshape, a type reinterpretation, a gather. A view's `ptr` is `NULL` until the
array is *attached* (see [ch. 4](04_attach_lifecycle.md)); the data is fetched
from the parent on demand. Slicing, reshaping, transposing, boolean indexing,
and many other operations all produce views, not copies.

A view is **structurally interchangeable** with an entity: its struct begins with
the same `CArray` layout (the `CAView` prefix, [ch. 2](02_core_data_structures.md)),
so every code path that dispatches on `obj_type` and reads the common fields
handles both without distinction — that structural uniformity is *why* the Ruby
surface treats a view and an entity identically. The difference lives in the **data
path**: a write to a view's buffer is scattered back to the parent on sync, or —
when the view aliases — lands directly in the parent's memory
([ch. 4](04_attach_lifecycle.md)). That write-through is the deliberate heart of
the design, not an accident to defend against. (The user-facing framing of the
same point is in the user's guide, 06_views.)

A parent may itself be a view, so views form a **chain** down to a **root**
entity. A great deal of CArray's cleverness is in collapsing such chains
efficiently (compose-fold, axis-merge) so that a deep chain still attaches in one
step against the root.

## What an array can do: the obj_type dispatch model

CArray does not use C++-style virtual tables or a Ruby method lookup to decide
how a particular kind of array attaches, frees, or transfers its data. It uses a
single integer tag and parallel dispatch arrays.

Every array struct begins with an `int16_t obj_type` field identifying its
concrete kind: `CA_OBJ_ARRAY`, `CA_OBJ_REFER`, `CA_OBJ_BLOCK`, `CA_OBJ_SELECT`,
and so on. Per-type behaviour is then looked up in arrays indexed by that tag
(all declared in `ext/carray.h`):

| Array | Indexed by obj_type, holds |
|-------|----------------------------|
| `ca_func[obj_type]` | the operation table — `attach`, `sync`, `detach`, `clone`, `free_object`, the xfer hooks, the pool hooks |
| `ca_class[obj_type]` | the Ruby class object (`CABlock`, `CATranspose`, …) |
| `ca_typeddata[obj_type]` | the `rb_data_type_t` for TypedData wrapping |
| `ca_mask_class[obj_type]` | the Ruby class of this type's *mask* sibling |
| `ca_mask_typeddata[obj_type]` | the `rb_data_type_t` for the mask sibling |

So "what does this view do when attached?" is answered by
`ca_func[ca->obj_type].attach(ca)`. The dispatch tables are the type system.
[Ch. 2](02_core_data_structures.md) walks the operation table field by field.

### Fixed vs runtime-assigned obj_types

Only a small core of obj_type values is fixed in the `carray.h` enum:

```c
enum {
  CA_OBJ_ARRAY,          /* 0 */
  CA_OBJ_ARRAY_WRAP,
  CA_OBJ_SCALAR,
  CA_OBJ_REFER,
  CA_OBJ_BLOCK,
  CA_OBJ_SELECT,
  CA_OBJ_OBJECT,
  CA_OBJ_REPEAT,
};
```

Everything else — `CAStride`, `CATranspose`, `CAFarray`, `CAGrid`, `CAWindow`,
`CAShift`, `CASelectAxis`, `CARemap`, every Face — is assigned a slot **at
runtime** by `ca_install_obj_type()` during initialisation. The ceiling is
`CA_OBJ_TYPE_MAX == 256`. This runtime-install mechanism is exactly what lets an
external gem add a new view or Face without recompiling the core: it installs a
new obj_type, registers its row in the dispatch tables, and the rest of CArray
treats it uniformly. (This is the implementation root of "a Face can be authored
outside and just work" — see [ch. 9](09_faces.md).)

## The orthogonal axis: data_type

`obj_type` is the array's *structure*. Orthogonal to it is `data_type`, the
*element* type — `CA_INT32`, `CA_FLOAT64`, `CA_OBJECT`, and so on (the full set
is in the `CA_DATA_TYPE` enum in `carray.h`). A `CABlock` view (an obj_type) can
hold `float64` elements (a data_type); a `CArray` entity can hold `int8`. The two
axes are independent, and most code dispatches on one without caring about the
other.

The user-facing word is always `data_type`, reported as a symbol (`:float64`);
never "dtype".

`CA_OBJECT` is the one data_type that holds arbitrary Ruby `VALUE`s rather than
raw numbers. Such arrays must be GC-marked (`ca_mark`) so the contained objects
survive; numeric kernels reach them through a dedicated `:object` branch (see
[ch. 12](12_mkkernel_dsl.md)).

## The class hierarchy

The Ruby classes mirror the C structs. A distinctive CArray trait is that **each
kind of view is its own named class** — `a[0, nil]` is a `CABlock`,
`a.transpose` is a `CATranspose` — so an array will tell you exactly what it is.

```
CArray (entity)
├── CScalar
├── CAWrap
├── CASource (abstract; sources defined by C extensions)
└── CAView (virtual-array base: parent, attach, nosync)
    ├── CAStride                 generic strided view
    │   ├── CARefer
    │   ├── CABlock
    │   ├── CARepeat
    │   ├── CATranspose
    │   ├── CAFarray
    │   └── CAField
    ├── CASelect / CAGrid / CASelectAxis / CARemap        (gather/scatter)
    ├── CAWindow / CAShift                              (bounds-fill)
    ├── CAFake / CAByteSwap                             (value reinterpret)
    ├── CABitarray / CABitfield                        (sub-byte)
    ├── CAReduce
    ├── CAObject                                        (Ruby callback bridge)
    └── … (CAStack and friends, Faces)
```

Each mask sibling sits under its array class: `CABlockMask < CABlock`,
`CARepeatMask < CARepeat`, and so on.

`CASource` is the odd one: an abstract class with no behaviour at all, sitting
next to CAWrap rather than under CAView. An array that produces its own elements
— an image library's pixel cache, a file-backed variable, a formula — has no
parent CArray to be a view of, and no buffer CArray allocated to be an ordinary
entity. Such classes are written by C extensions, which register their own
obj_type and their own op table; the core supplies only the class
([ch. 8](08_view_catalog.md)).

One initialisation ordering constraint matters: in `ruby_carray.c`, `CAStride`
must be defined **before** its subclasses (`CARefer`, `CABlock`, `CARepeat`, …),
because they are declared as Ruby subclasses of it. [Ch. 6](06_view_algebra_and_castride.md)
covers the CAStride family in depth.

## A map of `ext/`

The file naming is consistent enough to navigate by:

| Pattern | Holds | Examples |
|---------|-------|----------|
| `ca_obj_*.c` | one obj_type's view implementation | `ca_obj_block.c`, `ca_obj_grid.c`, `ca_obj_object.c` |
| `carray_*.c` | a CArray method/attribute/feature area | `carray_access.c` (`[]`), `carray_mask.c`, `carray_stat.c`, `carray_memory_view.c` |
| `ca_iter_*.c` | iterator implementations | `ca_iter_block.c`, `ca_iter_dimension.c` |
| `ruby_*.c` | Ruby bindings / initialisation | `ruby_carray.c` (`Init_carray_ext`) |
| `ca_kernel_iterator.{c,h}` | the kernel-author engine + macro surface | (Part III) |
| `ca_array_pool.c` | the metadata pool framework | (ch. 3) |
| `mkkernel.rb`, `mkmath.rb`, `mk_call_cfunc.rb` | code generators | (ch. 12, 14, 19) |

The single most important header is **`ext/carray.h`**: it declares the structs,
the obj_type enum, the dispatch-table externs, the public primitives, and the
`CA_*` macro suite. Grep it before adding any helper ([ch. 15](15_carray_h_helper_reference.md)).

## The two-axis matrix

Every CArray instance sits at a point in a two-dimensional space:

```
                 data_type →
                 FIXLEN  BOOLEAN  INT*   FLOAT*  CMPLX*  OBJECT
obj_type ↓
CA_OBJ_ARRAY      ✓        ✓       ✓      ✓       ✓      ✓
CA_OBJ_SCALAR     ✓        ✓       ✓      ✓       ✓      ✓
CA_OBJ_ARRAY_WRAP ✓        ✓       ✓      ✓       ✓      ✓
CA_OBJ_REFER      ✓        ✓       ✓      ✓       ✓      ✓
CA_OBJ_BLOCK      ✓        ✓       ✓      ✓       ✓      ✓
CA_OBJ_STRIDE     ✓        ✓       ✓      ✓       ✓      ✓
CA_OBJ_SELECT     ✓        ✓       ✓      ✓       ✓      ✓
CA_OBJ_GRID       ✓        ✓       ✓      ✓       ✓      ✓
CA_OBJ_FAKE       —        ✓       ✓      ✓       ✓      —    (value reinterpret;
                                                                  not fixlen/object)
CA_OBJ_BITARRAY   —        ✓       —      —       —      —    (boolean only)
CA_OBJ_BITFIELD   —        —       ✓      —       —      —    (integer only)
CA_OBJ_OBJECT     —        —       —      —       —      ✓    (the Ruby-callback bridge)
(Faces)           (storage data_type fixed per face)
```

Most code dispatches on one axis without caring about the other —
`ca_func[obj_type].xfer_all(ca, data, dir)` doesn't read `data_type`,
and per-data-type math kernels (in `carray_kernels.c`) don't read
`obj_type`. The kernel iterator is what makes that possible: it
abstracts over `obj_type` so the math kernel sees only a per-cell `T
*p`.

## The Init sequence (build-order constraints)

The C extension is initialised through one entry point:

```c
void Init_carray_ext (void);   /* in ruby_carray.c */
```

It runs in a fixed sequence because the dispatch tables and TypedData
registrations have inter-dependencies:

1. **Module / class declarations** — `rb_mCA`, `rb_cCArray`,
   `rb_cCAView`, then every concrete view class. CAStride must be
   declared **before** CARefer / CABlock / CARepeat (Ruby subclasses
   of CAStride).
2. **`Init_carray_undef`** — registers `CA_UNDEF` and pins it via
   `rb_gc_register_mark_object` ([ch. 5](05_mask_and_undef.md)). This
   must run before any code that compares against `CA_UNDEF`.
3. **Per-obj_type `Init_*`** — each `Init_ca_obj_<kind>` runs, calling
   `ca_install_obj_type` for runtime-assigned slots and populating
   `ca_func[obj_type]`. The order matters for the obj_type id
   assignment but not for correctness.
4. **`Init_carray_kernels`** — mkkernel-generated registration of every
   reduce / map / scan / sort / search / monop / binop / triop /
   moncmp / bincmp kernel ([ch. 12](12_mkkernel_dsl.md)). Runs after
   the view init so `rb_cCArray` and its kind classes are already
   defined.
5. **`Init_ca_kernel_iterator`** — registers the smoke-test stub for
   the kernel iterator surface.

The "Init order matters" constraint is the reason a forgotten
`ca_install_obj_type` shows up as a Ruby class hierarchy bug, not a
visible C crash — the table cell is empty but the class exists.

## The build pipeline

Three code generators run at `extconf` time before `make` compiles:

```
ext/extconf.rb runs:
  1. ruby carray_cast_func.rb     → ext/carray_cast_func.c
  2. ruby carray_stat_proc.rb     → (retired; stub remains for diff minimisation)
  3. ruby carray_math.rb          → ext/carray_math.c       (legacy mkmath)
  4. ruby mkkernel.rb             → ext/carray_kernels.c    (mkkernel DSL)
  5. ruby mk_call_cfunc.rb        → ext/carray_call_cfunc.c (+ .h)
ext/Makefile generated by mkmf
make compiles every *.c
```

The generators are themselves Ruby; they read `carray_config.h` for
type-availability flags (`HAVE_TYPE_INT64_T`, …) and emit
per-data-type C. The DSL inputs that drive them are at the bottom of
`mkkernel.rb`, `carray_math.rb`, and `mk_call_cfunc.rb` —
[ch. 12](12_mkkernel_dsl.md) and [ch. 14](14_call_cfunc.md) walk
those.

> ⚠️ When you edit a generator, always run a **full distclean rebuild**
> — `rake clean_ext && rake build_ext`. Incremental `make` has been
> observed to skip the recompile after generator edits in some
> setups.

## Where to go next

- The structs and dispatch tables in detail →
  [ch. 2](02_core_data_structures.md).
- How memory is allocated and pooled →
  [ch. 3](03_memory_management.md).
- How a view materialises its parent →
  [ch. 4](04_attach_lifecycle.md).
- The mask that every array carries →
  [ch. 5](05_mask_and_undef.md).
- The CAStride family that subsumes seven legacy view classes →
  [ch. 6](06_view_algebra_and_castride.md).
- The per-axis descriptor framework that drives the non-strided views
  → [ch. 7](07_axis_descriptor_framework.md).
- Writing a kernel that operates on any of these → Part III, starting
  at [ch. 10](10_author_surface_overview.md).

---
*When done, update the status row in [README](README.md).*
