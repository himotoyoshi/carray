# 16 Indexing and access

> **Status: draft.** Written through once; not yet re-verified against a live
> build. See [README](README.md) for conventions.

This chapter opens Part IV. It explains the C machinery behind `[]` / `[]=`: how
an index argument list is *classified* and how that classification *selects which
view obj_type to construct*. The Ruby-facing "what does each index form do"
catalogue is in the user's guide (ch. 16). Here we explain the dispatch
that surface rests on. The implementation is `ext/carray_access.c`.

## The shape of the problem

`a[...]` has to turn a heterogeneous argument list — integers, `nil`, ranges,
index arrays, boolean arrays, symbols like `:_` / `:*` — into either a **scalar
read** or a **concrete view object**. The mechanism is a two-stage classifier
(`scan_index`) followed by view construction keyed on the classification result.

## Stage 1: classification into a region type

`scan_index` inspects the argument list and produces an `info` record carrying a
**region type** (`CA_REG_*`) and, for the per-axis case, a per-axis **index type**
(`CA_IDX_*`). The region type is the decision: it names *what kind of access* the
index list expresses, which in turn names *which view* will be built.

The classifier dispatches first on arity:

- **`argc == 0`** → `CA_REG_ALL` (`a[]` — the whole array).
- **`argc == 1`** has shape-independent special cases evaluated in order, first
  match wins: a long symbol → `METHOD_CALL`; an integer index array → a grid/scatter
  region; a boolean array of matching element count → `CA_REG_SELECT`; a `String`
  → member/attribute access; `:*` → `CA_REG_UNBOUND_REPEAT`; and so on. A boolean
  array whose count doesn't match, or a CArray of a non-index data_type, raises
  here.
- **`argc == 1, ndim > 1`** → flat addressing: an `Integer` is `CA_REG_ADDRESS`,
  `nil` is `CA_REG_FLATTEN`, anything else (a range over the flattened array) is
  `CA_REG_ADDRESS_COMPLEX`, whose `[start, count, step]` triple is found by a
  recursive scan in flat address space (`CArray.scan_index`).
- **`argc >= 1`, general** → the main loop: a pre-scan pins `:%` → `CA_REG_REPEAT`
  or `:*` → `CA_REG_UNBOUND_REPEAT`; otherwise each axis argument is classified
  (`CA_IDX_SCALAR` / `CA_IDX_ALL` / `CA_IDX_BLOCK` / `CA_IDX_SYMBOL` /
  `CA_IDX_REPEAT`), and the combination resolves to `CA_REG_POINT` (all scalar →
  a scalar access), `CA_REG_BLOCK`, `CA_REG_GRID`, or `CA_REG_ITERATOR`.

Arity is validated against `ndim` unless a "rubber" axis (`false` / `:~`) is
present to absorb the difference.

## Stage 2: region type → view obj_type

The region type is the bridge from syntax to structure. Each maps to a concrete
construction:

| Region | Builds |
|--------|--------|
| `CA_REG_ALL` / `CA_REG_FLATTEN` | a CARefer/CAStride over the whole buffer ([ch. 6](06_view_algebra_and_castride.md)) |
| `CA_REG_POINT` (all axes scalar) | a **scalar read** — returns a plain Ruby object, not a view (below) |
| `CA_REG_BLOCK` | a `CABlock` slice view |
| `CA_REG_SELECT` | a `CASelect` (boolean / fancy selection) |
| `CA_REG_GRID` | a `CAGrid` ([ch. 7](07_axis_descriptor_framework.md)) |
| `CA_REG_REPEAT` / `CA_REG_UNBOUND_REPEAT` | `CARepeat` / `CAUnboundRepeat` |
| `CA_REG_ADDRESS` / `CA_REG_ADDRESS_COMPLEX` | flat addressing into the buffer |

> **Note.** Older reference material still names a `MAPPING` region for an
> index array of non-grid shape. **CAMapping was retired in 3.0 (R.3)**
> ([ch. 8](08_view_catalog.md)); an index-array index now builds a
> `CAGrid`/`CAStride` chain. Trust the code.

## The scalar boundary

`CA_REG_POINT` with every axis pinned to an integer is the one region that does
*not* build a view: it resolves to a single element and returns a **plain Ruby
object** (`Integer`, `Float`, `Complex`, …) via the element fetch path, not a 0-D
array. The boundary is structural: the moment *any* axis is expressed with `nil`
or a range, the region becomes `BLOCK` (or another view region) and the result is
a CArray. This is why `a[1, 2]` is an `Integer` but `a[1, nil]` is a `CABlock` —
the classifier took different branches, not the same branch with a different
shape.

## The newaxis / unbound sigils

Two symbol indices are handled specially because they change rank rather than
select within it:

- **`:_`** (newaxis) inserts a size-1 axis. It is the **only** way to line up
  shapes for broadcasting — CArray never adds an axis implicitly
  ([ch. 6](06_view_algebra_and_castride.md)). An
  index array index, by contrast, now builds a `CAGrid`/`CAStride` chain.
- **`:*`** (`CA_REG_UNBOUND_REPEAT`) marks an unbound-shape repeat whose extent is
  resolved later by the operation it feeds.

## Writes: `[]=`

`[]=` runs the same classifier to decide the target region, then routes by region.
A scalar region stores one element; a view region constructs the view and stores
through it — which, via the attach/sync/alias machinery
([ch. 4](04_attach_lifecycle.md)), writes back to the parent. Assigning a view to
a slice (`a[...] = a.sort`) is the canonical in-place idiom and goes through the
whole-array store path (`rb_ca_store_all`), which is itself routed through
`ca_xfer_all` to avoid a catastrophic `ca_attach` on size-mismatched virtual
roots (the V.1 rewire).

## Where to go next

- The views the regions build → [ch. 6](06_view_algebra_and_castride.md),
  [ch. 7](07_axis_descriptor_framework.md), [ch. 8](08_view_catalog.md).
- How a constructed view stores back to its parent → [ch. 4](04_attach_lifecycle.md).

---
*When done, update the status row in [README](README.md).*
