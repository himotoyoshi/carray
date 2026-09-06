# 02 Core data structures

> **Status: draft.** Written through once; not yet re-verified against a live
> build. See [README](README.md) for conventions.

This chapter is the field-by-field reference for the C structs and the dispatch
tables that drive them. After it you can open any `ca_obj_*.c` and know what
every field means and where its behaviour is wired. All declarations live in
`ext/carray.h`.

## `struct _CArray` — the entity

```c
struct _CArray {
  int16_t   obj_type;    /* concrete kind: CA_OBJ_ARRAY, … */
  int8_t    data_type;   /* element type: CA_FLOAT64, … */
  int8_t    ndim;        /* number of axes */
  int32_t   flags;       /* status bits (read-only, etc.) */
  ca_size_t bytes;       /* size of one element, in bytes */
  ca_size_t elements;    /* total element count = Π dim[k] */
  ca_size_t *dim;        /* axis lengths, length ndim */
  char     *ptr;         /* the data buffer (NULL until attached, for views) */
  CArray   *mask;        /* the mask sibling, or NULL */
  char     *_pool;       /* framework-managed metadata pool (NULL = legacy path) */
};
```

Notes on the fields:

- **`obj_type`** drives all per-type dispatch ([ch. 1](01_architecture_overview.md)).
- **`bytes` × `elements`** is the buffer size; `bytes` is per-element, not total.
- **`dim`** is a separately-managed array of axis lengths. For most arrays it
  lives in the `_pool` buffer; for `CScalar` it is inline (below) and must never
  be `xfree`d.
- **`ptr`** is the ownership marker for the attach lifecycle:
  `ca_is_attached(ca) == (ca->ptr != NULL)` ([ch. 4](04_attach_lifecycle.md)).
- **`mask`** points at a child boolean CArray; `NULL` means "no mask"
  ([ch. 5](05_mask_and_undef.md)).
- **`_pool`** is reserved for the framework. **Ext authors must not read, write,
  or `xfree` it directly** — the header says so explicitly ([ch. 3](03_memory_management.md)).

## The entity relatives: CScalar and CAWrap

**`CScalar`** has the identical layout plus one inline field:

```c
typedef struct {
  /* … identical CArray prefix … */
  ca_size_t  _dim;       /* the single inline axis length */
} CScalar;
```

Its `dim` field points at this inline `_dim`. The practical consequence:
**never `xfree(ca->dim)` on a CScalar** — `dim` is not separately allocated.

**`CAWrap`** is literally `typedef CArray CAWrap;`. It is structurally an entity,
but its `ptr` refers to memory owned by something *outside* CArray (a foreign
buffer, a MemoryView producer). CAWrap therefore does not free `ptr` on
collection. It is the entity end of zero-copy import ([ch. 18](18_memory_view_protocol.md)).

**`CASource`** is an abstract class with no struct of its own: a class under
CArray, a sealed allocator, a TypedData chain entry, nothing else. It is the
home for arrays that *produce* their elements rather than owning or deriving
them, and every such class is written by a C extension — its own obj_type, its
own op table, its own struct (the CArray prefix when the buffer is already
addressable, the CAView prefix with `parent = NULL` when values are produced on
demand). [Ch. 8](08_view_catalog.md) has the recipe.

## `CAView` — the virtual-array base

Every view's struct begins with the full `CArray` layout and then appends three
fields:

```c
typedef struct {
  /* … CArray prefix (obj_type … _pool) … */
  CArray   *parent;      /* the array this view refers to */
  uint32_t  attach;      /* attach refcount */
  uint8_t   nosync;      /* suppress write-back when set */
} CAView;
```

- **`parent`** is the referent — itself possibly a view, forming a chain.
- **`attach`** counts nested attaches so they nest safely
  ([ch. 4](04_attach_lifecycle.md), R4).
- **`nosync`** suppresses the write-back (sync) step — used when a view is known
  to be read-only or when sync would be wrong.

Because the prefix is byte-for-byte the `CArray` layout, any code that only
touches the common fields works uniformly on entities and views.

## `CAStride` — strided views, and the prefix+tail pattern

`CAStride` is the base for all linearly-strided views. It extends the `CAView`
prefix with two fields:

```c
typedef struct {
  /* … CAView prefix (… parent, attach, nosync) … */
  ca_size_t *strides;     /* byte strides per axis; negative allowed */
  ca_size_t  base_offset; /* byte offset from parent->ptr to view[0,…] */
} CAStride;
```

An element's address is `parent->ptr + base_offset + Σ idx[k]·strides[k]`. That
formula expresses slices, transposes, reshapes, repeats, and byte
reinterpretations — which is why CARefer, CABlock, CARepeat, CATranspose,
CAFarray, and CAField are all CAStride subclasses ([ch. 6](06_view_algebra_and_castride.md)).

Subclasses come in two shapes:

**Pure typedef** — adds no fields (e.g. CATranspose). Its setup just calls
`ca_stride_setup`; nothing else to override.

**Prefix + tail** — appends native state. Two examples:

```c
typedef struct {
  /* … CAStride prefix … */
  CArray   *mask0;        /* CARefer tail */
} CARefer;

typedef struct {
  /* … CAStride prefix … */
  ca_size_t  offset;
  ca_size_t *start, *step, *count, *size0;   /* CABlock native spec */
} CABlock;
```

The CABlock tail is kept so the public Ruby accessors (`#offset`, `#start`, …)
and the block/dimension iterators (which mutate `start[]` in place) have
something to read. **Invariant: after mutating `start[]`, `base_offset` must be
recomputed** to stay consistent with the prefix, or the view silently reads wrong
data. Tail-bearing subclasses must also override `clone`, the allocator, and
`dsize` — [ch. 6](06_view_algebra_and_castride.md) covers the pitfalls.

(Historical note: CARefer no longer stores an `is_deformed` flag; reshape vs
byte-reinterpret is now implied by comparing `ca->bytes` with
`ca->parent->bytes`. Don't reintroduce the flag.)

## The dispatch tables

Five arrays, each indexed by `obj_type` (declared in `carray.h`):

```c
extern VALUE                  ca_class[CA_OBJ_TYPE_MAX];
extern const rb_data_type_t  *ca_typeddata[CA_OBJ_TYPE_MAX];
extern VALUE                  ca_mask_class[CA_OBJ_TYPE_MAX];
extern const rb_data_type_t  *ca_mask_typeddata[CA_OBJ_TYPE_MAX];
extern ca_operation_function_t ca_func[CA_OBJ_TYPE_MAX];
```

### The operation table, `ca_operation_function_t`

This is where "what does this kind of array *do*" is answered. The fields, in
declaration order:

```c
typedef struct {
  int32_t obj_type;
  int32_t entity_type;
  void   (*free_object)(void *ap);
  void * (*clone)      (void *ap);
  void   (*allocate)   (void *ap);
  void   (*attach)     (void *ap);
  void   (*sync)       (void *ap);
  void   (*detach)     (void *ap);
  void   (*fill_data)  (void *ap, void *data);
  void   (*create_mask)(void *ap);
  /* xfer protocol */
  void   (*xfer_index) (void *ap, ca_size_t *idx, void *data, int dir);
  void   (*xfer_addrs) (void *ap, ca_size_t n, ca_size_t *addrs, void *data, int dir);
  int    (*fold_stride)(void *ap, ca_fold_t *f, void **next_parent);
  void   (*xfer_stride)(void *ap, ca_size_t *starts, ca_size_t *counts,
                        ca_size_t *strides, void *data, int dir);
  void   (*xfer_all)   (void *ap, void *data, int dir);
  /* pool framework */
  size_t struct_size;
  size_t (*pool_bytes) (int8_t ndim);
  void   (*pool_init)  (void *ap, int8_t ndim);
} ca_operation_function_t;
```

- **`free_object` / `clone` / `allocate`** — lifecycle of the C struct itself.
- **`attach` / `sync` / `detach`** — the materialise / write-back / release
  lifecycle ([ch. 4](04_attach_lifecycle.md)).
- **`fill_data`** — broadcast/fill a value across the array.
- **`create_mask`** — build this type's mask sibling (so a CABlock yields a
  `CABlockMask`, not a generic mask — [ch. 5](05_mask_and_undef.md)).
- **the `xfer_*` family** — the unifying transfer protocol. `xfer_all` is the
  whole-view gather/scatter that is replacing the historical `copy_data` /
  `sync_data`; `xfer_stride` delivers one contiguous region (used for partial
  materialise); `fold_stride` is the one-hop compose-fold for non-CAStride
  participants; `xfer_index` / `xfer_addrs` move single elements / address lists.
  The `dir` argument is `CA_XFER_GET` (view → buffer) or `CA_XFER_PUT` (scatter).
- **`struct_size` / `pool_bytes` / `pool_init`** — the pool hooks. When
  populated, the framework manages a single `_pool` buffer for the type's
  metadata; left `NULL`, the type stays on the legacy per-array `ALLOC_N` path
  ([ch. 3](03_memory_management.md)).

A `case CA_OBJECT:` style branch inside a generated kernel, and the per-view
`create_mask` overrides, are the two places you most often see this table read
explicitly.

## TypedData wiring

Each obj_type registers an `rb_data_type_t` (in `ca_typeddata[]`) with three hooks:

- **`dmark = ca_mark`** — marks contained `VALUE`s when `data_type == CA_OBJECT`,
  so the GC sees them. Numeric arrays have nothing to mark.
- **`dfree = ca_free`** — dispatches to `ca_func[obj_type].free_object`.
- **`dsize`** — returns the exact byte size; CAStride-family types have type-aware
  `dsize` functions that account for the tail.

The **mask siblings** register with **`dfree = ca_free_nop`**: a mask is owned by
its parent array, so freeing the parent frees the mask; the mask's own TypedData
must not double-free it ([ch. 5](05_mask_and_undef.md) — the single most common
mistake when adding a view).

## The life of an entity

Everything above describes the entity at rest. Here is how one is *born* and
*collected*. It is worth following once concretely, because **a view is this same
machinery minus its own data buffer** — so once you have the entity's lifecycle,
Part II only has to explain each view's *delta*, not re-explain allocation or
collection.

### Birth — `carray_setup_i` (`ext/ca_obj_array.c`)

`rb_carray_new` routes to `carray_setup_i`, which populates the struct in a fixed
order:

1. **Validate** data_type, rank, dims, and bytes (`CA_CHECK_*`).
2. **Compute size**: the total byte length is accumulated in a `double` first to
   detect overflow, then `elements = Π dim[k]`.
3. **Set the scalar fields**: `obj_type` (`CA_OBJ_ARRAY`, or `CA_OBJ_ARRAY_WRAP`
   for a wrap), `data_type`, `flags = 0`, `ndim`, `bytes`, `elements`.
4. **Wire `dim`**: when pooled, `dim` already points into `_pool` (set by
   `pool_init`, [ch. 3](03_memory_management.md)); otherwise it is `ALLOC_N`'d. The
   caller's dims are then `memcpy`'d in.
5. **Allocate the data buffer**: `ca->ptr = xmalloc(elements * bytes)` — `MEMZERO`'d
   on the calloc path, and for `CA_OBJECT` every slot is initialised to the Fixnum
   `SIZE2NUM(0)` so the GC never marks an uninitialised `VALUE`. (A *wrap* or a
   *view* takes the `allocate == false` branch instead and leaves `ptr = NULL`.)
6. **Mask**: `ca->mask = NULL` (lazy); a mask passed to the constructor is wired
   via `ca_setup_mask`.

### Death — `free_carray` via the GC

CArray installs no destructor of its own; collection is Ruby's GC reclaiming the
TypedData object. `dfree = ca_free` dispatches to `ca_func[obj_type].free_object`,
which for an entity is `free_carray`. It does four things in order: cascade into
the mask, `xfree` the data buffer, then free the struct + metadata, splitting on
`_pool` (pooled: `ca_array_free`; legacy: `xfree(dim) + xfree(struct)`). The full
skeleton and the CAWrap / CAStride variants are in
[ch. 3](03_memory_management.md), "The mark and free path".

Three points: the mask is freed by **cascade** — `ca_free` re-dispatches on the
mask's own obj_type, and the mask's `free_object` does not recurse into a
mask-of-mask ([ch. 5](05_mask_and_undef.md)); the data buffer is `xfree`'d
**unconditionally** because an entity owns it (a `CAWrap` overrides this — its
`ptr` is foreign and must not be freed); and the struct + `dim` split on `_pool`
exactly as [ch. 3](03_memory_management.md) describes.

### Views are the delta

A view reuses this whole birth/death machinery. The differences, and *only* these,
are what Part II explains per view:

- its setup takes the `allocate == false` path, so **`ptr` starts `NULL`** — there
  is no data buffer at construction. `ptr` is filled later by `ca_attach`
  ([ch. 4](04_attach_lifecycle.md)), and may *alias* the parent rather than own a
  buffer;
- the struct carries the extra `CAView` prefix (`parent`, `attach`, `nosync`) and,
  for some classes, a tail;
- its `free_object` frees whatever it actually *owns* (its `_pool`/tail, and a
  materialised non-alias `ptr`) but **never the parent**.

That is the payoff of reading this section first: from here on, "how is a view
allocated and freed?" has a one-line answer — the same as an entity, minus the
data buffer it doesn't own.

## CA_OBJECT and GC

When `data_type == CA_OBJECT`, `ptr` holds an array of `VALUE`s. The initial
fill is the Fixnum `SIZE2NUM(0)` (a deliberate zero, since the array is nominally
numeric — and a valid `VALUE` so marking is always safe). `ca_mark` walks all live
elements so the referenced objects are not collected. Compaction is disabled for
these arrays (`dcompact = NULL`) because marking already covers every element.

## The full obj_type catalog

Only nine `CA_OBJ_*` values are fixed in the `carray.h` enum (the ones
the core code references by name); everything else is assigned a runtime
slot by `ca_install_obj_type` during `Init_*` ([ch. 8](08_view_catalog.md)
for the per-kind narrative). The fixed nine:

```c
enum {
  CA_OBJ_ARRAY,           /* 0  entity (the ordinary CArray)         */
  CA_OBJ_ARRAY_WRAP,      /* 1  CAWrap — entity over foreign memory  */
  CA_OBJ_SCALAR,          /* 2  CScalar — rank-0 entity              */
  CA_OBJ_REFER,           /* 3  CARefer — reshape / byte reinterpret */
  CA_OBJ_BLOCK,           /* 4  CABlock — sliced view                */
  CA_OBJ_SELECT,          /* 5  CASelect — boolean / fancy indexing  */
  CA_OBJ_OBJECT,          /* 6  CAObject — per-cell Ruby callback    */
  CA_OBJ_REPEAT,          /* 7  CARepeat — stride-0 axes (legacy)    */
};
```

Runtime-installed slots typically include CAStride, CATranspose, CAFarray,
CAField, CAFake, CAByteSwap, CABitarray, CABitfield, CAReduce, CAGrid,
CAWindow, CAShift, CARoll, CATile, CAStack, CASelectAxis, CARemap, and
every Face (CATime / CATimedelta / CARecord / CAConstString) — see the
global `CA_OBJ_STRIDE`, `CA_OBJ_TRANSPOSE`, … externs
that hold the assigned values. The ceiling is `CA_OBJ_TYPE_MAX == 256`.

`ca_func[obj_type].entity_type` distinguishes:

```c
#define CA_REAL_ARRAY  0    /* an entity that owns its buffer */
#define CA_VIEW_ARRAY  1    /* a view that borrows its parent's buffer */
```

The `ca_is_entity(ca)` macro reads this; CArray / CScalar / CAWrap report
`CA_REAL_ARRAY`, every CAView descendant reports `CA_VIEW_ARRAY`. A CASource
subclass declares whichever fits it — the choice is what makes the core treat
the array as an entity or as a view, and it is the source author's to make.

## The data_type enum

Orthogonal to `obj_type` — what each element is:

```c
enum {
  CA_NONE     = -1,
  CA_FIXLEN,           /*  0  byte-wide opaque payload, width = ca->bytes */
  CA_BOOLEAN,          /*  1  uint8 0/1 */
  CA_INT8, CA_UINT8,   /*  2,3 */
  CA_INT16, CA_UINT16, /*  4,5 */
  CA_INT32, CA_UINT32, /*  6,7 */
  CA_INT64, CA_UINT64, /*  8,9 */
  CA_FLOAT32,          /* 10 */
  CA_FLOAT64,          /* 11 */
  CA_FLOAT128,         /* 12  RESERVED HOLE — retired in 3.0; ca_valid[12] = 0 */
  CA_CMPLX64,          /* 13 */
  CA_CMPLX128,         /* 14 */
  CA_CMPLX256,         /* 15  RESERVED HOLE — retired in 3.0; ca_valid[15] = 0 */
  CA_OBJECT,           /* 16  arbitrary Ruby VALUE per cell */
  CA_NTYPE,            /* 17  count sentinel */
  /* legacy aliases */
  CA_BYTE     = CA_UINT8,
  CA_SHORT    = CA_INT16,
  CA_INT      = CA_INT32,
  CA_FLOAT    = CA_FLOAT32,
  CA_DOUBLE   = CA_FLOAT64,
  CA_COMPLEX  = CA_CMPLX64,
  CA_DCOMPLEX = CA_CMPLX128,
};
```

`CA_FLOAT128` / `CA_CMPLX256` slot numbers (12 and 15) are preserved as
**reserved holes** so existing `CA_NTYPE`-sized tables keep their layout
after the `long double` family was retired in 3.0. `ca_valid[12]` and
`ca_valid[15]` are 0 — no user can create a CArray of these types — but
the indices are not reused.

The companion globals (all extern in `carray.h`):

```c
extern const int32_t  ca_valid    [CA_NTYPE];   /* 1 = enabled, 0 = reserved hole */
extern const int32_t  ca_sizeof   [CA_NTYPE];   /* element byte size (0 for FIXLEN/OBJECT) */
extern const char    *ca_type_name[CA_NTYPE];   /* "float64", "int32", … */
extern const int      ca_cast_table [CA_NTYPE][CA_NTYPE];
extern const int      ca_cast_table2[CA_NTYPE][CA_NTYPE];
```

`ca_promote_type(a, b)` reduces the cast table to a single result type
— the single source of CArray's data-type promotion rules
([ch. 15](15_carray_h_helper_reference.md)).

## Flag bits

```c
#define CA_FLAG_SCALAR         1     /* behaves as a scalar / broadcast operand */
#define CA_FLAG_MASK_ARRAY     2     /* this CArray IS a mask child */
#define CA_FLAG_VALUE_ARRAY    4     /* this CArray IS the value-only refer */
#define CA_FLAG_READ_ONLY      8     /* WRITE-path operations reject */
#define CA_FLAG_SHARE_INDEX   16     /* index / axis buffer is aliased, not owned */
#define CA_FLAG_MULTI_PARENTS 32     /* fan-out view (CAStack and friends) */
#define CA_FLAG_CYCLE_CHECK   64     /* re-entrancy guard for CA_OBJECT fetch/store */
#define CA_FLAG_IS_FACE      128     /* CAFace lift ([ch. 9](09_faces.md)) */
```

Accessors:

```c
#define ca_set_flag(ca, flag)    ((ca)->flags |=  (flag))
#define ca_unset_flag(ca, flag)  ((ca)->flags &= ~(flag))
#define ca_test_flag(ca, flag)   (((ca)->flags & (flag)) ? 1 : 0)
```

`CA_FLAG_MULTI_PARENTS` is the marker that lets generic single-parent
walks fall back to a `CAMultiParent` cast — the **layout convention** is
that any fan-out view (CAStack is the first conforming case) places
`n_parents` + `parents[]` immediately after the CAView header. The
convention struct:

```c
typedef struct {
  CAView    header;        /* common view prefix */
  int32_t   n_parents;
  CArray  **parents;
} CAMultiParent;
```

So `(CAMultiParent *) ca` is valid for any view with `CA_FLAG_MULTI_PARENTS`
set.

Three of the bits carry no behaviour in their name and are easy to misread:

- **`CA_FLAG_SCALAR` (1)** — marks an array that acts as a *scalar / broadcast
  operand* rather than a rank-N array. `ca_is_scalar(ca)` is exactly
  `ca_test_flag(ca, CA_FLAG_SCALAR)` (`carray_attribute.c`). It is set by the
  CScalar setup and by views built from a scalar source — for example
  `ca_select_setup` sets it when the boolean selector is itself a scalar
  (`ca_obj_select.c`). Downstream binop/monop code reads it to let a size-1
  operand broadcast without a temporary.
- **`CA_FLAG_SHARE_INDEX` (16)** — an *ownership* flag for views that carry an
  index or per-axis buffer (CAGrid; the CASelect-family share constructors). When
  set, that buffer is **aliased from a source view, not owned**, so `free_object`
  must not `xfree` it. In `ca_obj_grid.c`, `ca_grid_setup`'s `share` branch sets
  the flag and aliases `ca->axes = protos`; `free_ca_grid` then skips the
  per-axis `xfree` when the flag is present. `initialize_copy` and `create_mask`
  are the call sites that share a source's `axes` buffer this way.
- **`CA_FLAG_CYCLE_CHECK` (64)** — a *re-entrancy guard*, meaningful only for
  `CA_OBJECT` arrays (an object array can contain a reference to itself). During
  a fetch/store of an object array, `ca_set_cyclic_check` raises if the flag is
  already set on this array (a cycle) and otherwise sets it; `ca_clear_cyclic_check`
  clears it afterward; `ca_test_cyclic_check` raises if a nested CArray element
  already has the flag set (`carray_core.c`). It exists to turn what would be a
  system-stack overflow on a self-referential object array into a clean
  `RuntimeError` ([ch. 5](05_mask_and_undef.md)).

## The view struct catalog (extended)

Beyond CAStride and its tail-bearing subclasses already shown, the rest
of the view family appends its own tail after the CAView prefix. The
salient ones:

### CAWindow / CAShift

```c
typedef struct {
  /* … CAView prefix … */
  uint8_t   *bounds;          /* [ndim] per-axis CA_BOUNDS_* policy */
  ca_size_t *start, *count, *size0;
  char      *fill;            /* fill value bytes (when CA_BOUNDS_FILL) */
  /* COMPOSITE_FAMILY embed descriptor (computed once at setup) */
  ca_size_t *embed_parent_start, *embed_count, *embed_output_offset;
  uint8_t    embed_is_empty, embed_covers_all,
             embed_eligible, embed_alias_eligible;
} CAWindow;
typedef CAWindow CAShift;     /* same struct; obj_type differs */
```

The bounds-policy enum:

```c
enum {
  CA_BOUNDS_RUBY = 1,      /* Ruby slice semantics */
  CA_BOUNDS_STRICT,        /* raise on OOB */
  CA_BOUNDS_NEAREST,       /* clamp */
  CA_BOUNDS_PERIODIC,      /* wrap */
  CA_BOUNDS_REFLECT,       /* mirror */
  CA_BOUNDS_FILL,          /* write `fill` */
  CA_BOUNDS_MASK,          /* mark masked */
};
```

The `embed_*` fields encode a one-alias-plus-one-fill decomposition that
CAWindow's attach uses to skip per-element bounds checks when bounds are
purely FILL/MASK ([ch. 6](06_view_algebra_and_castride.md) fast-path
ladder applies; the descriptor framework handles non-FILL bounds).

### CATile / CARoll

```c
typedef struct {
  /* … CAView prefix … */
  ca_size_t *reps;       /* [ndim] tile count per axis;
                            dim[k] = parent->dim[k] * reps[k] */
} CATile;
typedef CATile CARoll;    /* same struct; obj_type differs */
```

### CAStack

```c
typedef struct {
  /* … CAView prefix … */
  int32_t   n_parents;       /* K = axis-0 size (or k_axis size) */
  CArray  **parents;         /* [K] alias pointer array, not owned */
  int8_t    k_axis;          /* 0 = outer-axis stack, parent_ndim = innermost */
} CAStack;
```

The Ruby wrapper holds the original parents in a `@parents` Array (the
GC anchor); the C-side `parents[]` is alias-only. `CA_FLAG_MULTI_PARENTS`
is set so generic single-parent walks fall back to `CAMultiParent`.

### CAObject

```c
typedef struct {
  /* … CAView prefix … */
  CArray   *data;
  VALUE     self;        /* Ruby self of the wrapping CAObject */
} CAObject;
```

The one view kind whose data path goes through `rb_funcall` per cell —
the kernel iterator cannot transparently deliver it
([ch. 11](11_kernel_iterator.md)).

### CAReduce

```c
typedef struct {
  /* … CAView prefix … */
  ca_size_t  count;          /* reduction size */
  ca_size_t  offset;         /* CAReduce — used only inside ca_obj_refer.c */
} CAReduce;
```

CAReduce is an *internal* class used only inside `ca_obj_refer.c` for
the byte-reinterpret modes; user-facing reductions go through the
kernel iterator.

## CAIterator — no C struct any more

`CAIterator` is *not* a C data structure in 3.0. It is a **form-only Ruby
base class** for the reduction-iterator family (slab / window / block /
categorical / group): the class object is created in `ext/ruby_carray.c`
(so that C-side consumers — the `:>` indexer dispatch and
`Init_ca_group_iter` — can reference the constant), and everything else
about it is plain Ruby in `lib/carray/iterator.rb`. See
[ch. 16a](16a_iterator_family.md).

The 2.0-era C struct (a `kernel_at_addr` / `kernel_at_index` dispatch
slot, with C-defined `CADimensionIterator` / `CABlockIterator` engines
that advanced by mutating the underlying view's tail in place) is
retired. The tail-mutation pattern it relied on is why the **prefix resync**
invariant in [ch. 6](06_view_algebra_and_castride.md) exists, and that
invariant still binds any code that mutates a view's tail.

## Validation macros

`carray.h` ships a uniform validation macro suite — use these instead
of writing the checks by hand:

```c
CA_CHECK_DATA_TYPE(data_type)        /* range + ca_valid[] */
CA_CHECK_DATA_TYPE_NUMERIC(data_type)/* same + reject FIXLEN/OBJECT */
CA_CHECK_RANK(ndim)                  /* 0 < ndim <= CA_RANK_MAX */
CA_CHECK_DIM(ndim, dim)              /* every dim[i] >= 0 */
CA_CHECK_BYTES(data_type, bytes)     /* resolves bytes for non-FIXLEN */
CA_CHECK_INDEX(index, dim)           /* normalises negative, range-checks */
CA_CHECK_BOUND(ca, idx)              /* multi-dim bounds check */
```

The two limits the macros enforce:

```c
#define CA_DIM_MAX     16            /* maximum ndim */
#define CA_RANK_MAX    CA_DIM_MAX    /* alias */
#define CA_ATTACH_MAX  0x80000000    /* attach refcount ceiling */
#define CA_LENGTH_MAX  0x7fffffffffffffff   /* INT64_MAX on 64-bit builds */
```

`ca_size_t` is `int64_t` on a 64-bit build and `int32_t` on a 32-bit
build; `CA_LENGTH_MAX` scales accordingly. `NUM2SIZE` / `SIZE2NUM`
convert between Ruby and `ca_size_t`.

## Where to go next

- How these structs are allocated and freed, and the pool that backs `dim` /
  `strides` / tails → [ch. 3](03_memory_management.md).
- How `attach` / `sync` / `detach` actually move data →
  [ch. 4](04_attach_lifecycle.md).
- The CAStride family in depth, including the subclass walkthrough →
  [ch. 6](06_view_algebra_and_castride.md).
- The full per-view reference for the views sketched above →
  [ch. 8](08_view_catalog.md).
- The primitives that construct, copy, and check these structs →
  [ch. 15](15_carray_h_helper_reference.md).

---
*When done, update the status row in [README](README.md).*
