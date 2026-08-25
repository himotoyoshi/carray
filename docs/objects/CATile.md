# CATile — tiled-repetition view of a parent array

`CATile` is the view class behind `CArray#tile`. It presents a parent
array **repeated a whole number of times along every axis**, as one
larger array. No data is copied: a `CATile` gathers from its single
parent on demand, and writes flow back to the parent's cells.

```
a = [0 1 2]          shape [3]

a.tile(3)            shape [9]

  ┌───────────────────────┐
  │ 0 1 2 │ 0 1 2 │ 0 1 2 │   ← 3 tiles, each a full-parent alias
  └───────────────────────┘
    tile 0   tile 1   tile 2
```

Along each axis `k`, the output length is `parent.dim[k] * reps[k]`, and
each of the `product(reps)` tiles is a **full-parent alias** — every tile
reads the same parent block. This document is the reference for the
`CATile` view class itself: its shape rule, view/write semantics, masks,
and the cost model. For the wider composition cheat-sheet (`stack` vs
`meld` vs `montage`), see [Composition.md](../topics/Composition.md).

---

## 1. What a CATile is

`CATile` wraps **one parent CArray** and a per-axis repetition count
`reps`. It keeps the parent's `ndim`, `data_type`, and byte width, and
scales each axis length:

```
result.ndim  == parent.ndim
result.shape == [ parent.dim[k] * reps[k]  for each axis k ]
```

The repetition is a regular grid of tiles. Tile coordinate
`(i_0, i_1, ...)` sits at output offset
`(i_0 * parent.dim[0], i_1 * parent.dim[1], ...)`, and each tile is a
complete copy of the parent laid out in the same axis order. A read at
view position `p` maps to the parent by modulo:

```
parent_index[k] = p[k] % parent.dim[k]
```

```ruby
require "carray"

a = CA_INT([[1, 2, 3],
            [4, 5, 6]])          # shape [2, 3]

v = a.tile(2, 2)
puts v.inspect
#=> <CATile.int32(4,6): elem=24 mem=96b
#   [ [ 1, 2, 3, 1, 2, 3 ],
#     [ 4, 5, 6, 4, 5, 6 ],
#     [ 1, 2, 3, 1, 2, 3 ],
#     [ 4, 5, 6, 4, 5, 6 ] ]>
```

`a.tile(1, 1, ...)` (all reps `1`) is the identity — the output equals
the parent element for element.

---

## 2. Creating a CATile — `CArray#tile`

```ruby
a.tile(*reps)          # positional args
a.tile([*reps])        # single Array of Integer
```

The number of reps **must equal `ndim`** — there is no implicit
dimension prepending or trailing-axis fill. Both call forms are
equivalent.

```ruby
a = CArray.int32(5).seq       # shape [5]

a.tile(3)                     # shape [15]  — 1-D, 1 rep
a.tile([3])                   # shape [15]  — Array form, equivalent

b = CArray.int32(2, 3).seq    # shape [2, 3]

b.tile(2, 4)                  # shape [4, 12]
b.tile([2, 4])                # same

b.tile(3)                     # ArgumentError: expected 2 args (= ndim), got 1
b.tile([2])                   # ArgumentError: array length (1) does not match ndim (2)
```

Every rep must be **positive** (a tile count of at least 1):

```ruby
a.tile(0)                     # IndexError
a.tile(-1)                    # IndexError
```

> **Why `argc == ndim` is required.** CArray follows *explicit over
> implicit* everywhere; it does not adopt NumPy's trailing-axis
> broadcasting, where `np.tile(a, 3)` on a 2-D array silently tiles only
> the last axis. Each axis's repetition is stated explicitly.

---

## 3. It is a view — reads and writes reach the parent

`CATile` copies nothing. Reads gather live from the parent, so changes to
the parent are visible through the view:

```ruby
a = CA_INT([1, 2, 3])
v = a.tile(3)                 # [1, 2, 3, 1, 2, 3, 1, 2, 3]

a[0] = 99
v.to_a                        #=> [99, 2, 3, 99, 2, 3, 99, 2, 3]
```

### 3.1 Writing back is last-write-wins across tiles

Because every tile aliases the **same** parent block, several view cells
map to one parent cell. Writing through the view lands in the parent, and
when tiles overlap the parent cell keeps the **last** value written:

```ruby
a = CA_INT([0, 1, 2])         # parent
v = a.tile(2)                 # [0, 1, 2, 0, 1, 2]; v[0] and v[3] both map to a[0]

v[0] = 100
a[0]                          #=> 100

v[3] = 200                    # v[3] also maps to a[0]
a[0]                          #=> 200   (overwrites v[0]'s effect)
```

This is the natural consequence of tiles being aliases, not independent
copies. When you want an independent, materialised array with no
write-back, take a copy (§4).

---

## 4. Materialising — `to_ca` / `copy`

`CATile` is a `CAView`, so the usual view-vs-owned distinction applies
(see the semantics table in the project docs):

- **`v.copy`** — always a fresh, independent CArray entity. Detached from
  the parent; later writes to the parent are not seen.
- **`v.to_ca`** — evaluates the view into a new entity as well (a view has
  no contiguous buffer of its own to hand back).

```ruby
a = CA_INT([1, 2, 3])
v = a.tile(3)

c = v.copy                    # independent snapshot
a[0] = 0
c.to_a                        #=> [1, 2, 3, 1, 2, 3, 1, 2, 3]  (unchanged)
```

The equivalent eager construction is `CArray.montage` with a grid of
identical pieces — `tile` is the single-parent view specialisation:

```ruby
a = CA_INT([[1, 2, 3], [4, 5, 6]])

a.tile(2, 2).to_a ==
  CArray.montage([a, a, a, a], [2, 2], axis: 0).to_a   #=> true
```

---

## 5. Masks

A masked parent produces a masked view: the mask tiles exactly like the
data.

```ruby
b = CArray.int32(3).seq
b[1] = UNDEF                  # [0, _, 2]

v = b.tile(2)
v.has_mask?                   #=> true
v.is_masked.to_a             #=> [0, 1, 0, 0, 1, 0]
```

The mask companion class is `CATileMask`; it is created automatically and
tracks the parent's mask through the same tiling.

---

## 6. Data types

`tile` is type-agnostic — it works on any `data_type`, preserving the
parent's byte width (no reinterpret):

```ruby
CArray.float64(3).seq.mul!(1.5).tile(2).to_a
#=> [0.0, 1.5, 3.0, 0.0, 1.5, 3.0]

CArray.boolean(3).tap { |x| x[] = [true, false, true] }.tile(2).to_a
#=> [1, 0, 1, 1, 0, 1]
```

---

## 7. Cost model

- **Construction** is O(1): the view stores only `reps` and the parent
  reference.
- **Reading a cell** costs one modulo per axis plus a parent fetch.
- **Materialising** (`to_ca` / `copy` / passing to a kernel) gathers each
  tile as a contiguous parent run where the layout allows, so the total
  work is proportional to the output size (`product(reps)` copies of the
  parent), done tile by tile without allocating any intermediate view
  buffers beyond the destination.
- **Memory**: the view itself holds no data; only materialisation
  allocates the `product(reps) * parent.elements` result.

Because tiles overlap on write, `CATile` never folds into a plain strided
view (the modulo wrap is not a linear stride). It is delivered through the
composite-region gather/scatter path shared with the other N-region views.

---

## 8. Quick reference

| operation | result |
|---|---|
| `a.tile(*reps)` | `CATile` view, shape `a.dim[k] * reps[k]` per axis |
| `a.tile([*reps])` | same (Array form) |
| reps count | must equal `a.ndim` (else `ArgumentError`) |
| each rep | must be `>= 1` (else `IndexError`) |
| read | gathers live from the parent (modulo wrap) |
| write | lands in the parent; last-write-wins across overlapping tiles |
| `v.copy` / `v.to_ca` | independent materialised CArray |
| masked parent | masked `CATile` (mask tiles identically) |
| eager equivalent | `CArray.montage([a] * n, tdim, axis: 0)` |

## See also

- [Composition.md](../topics/Composition.md) — `stack` / `meld` / `montage` and the
  full composition cheat-sheet.
- [CAStack.md](CAStack.md) — the K-axis stacking view for multiple
  uniform parents.
