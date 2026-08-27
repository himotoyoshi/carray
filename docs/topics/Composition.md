# Array composition

CArray provides methods for assembling multiple arrays into one.
The key concepts are:

- **View vs eager**: view-default methods return a `CAStack` or `CAMeld`
  view (no copy until `.copy`); eager methods materialise immediately.
- **New axis vs existing axis**: does the assembly introduce a new dimension,
  or extend a dimension that already exists?
- **Single direction vs grid**: one axis changes, or multiple axes at once?
- **Uniform vs ragged**: do all pieces agree on the axis being extended,
  or do they contribute different lengths?

---

## At a glance

```
                    | view (same data type)          | eager (auto-cast)
--------------------+--------------------------------+-------------------------
new axis added      | stack           (CAStack view) | (ragged impossible)
existing axis grows | meld            (CAMeld view)  | concatenate (materialised)
grid of tiles       | montage                        | mosaic (materialised)
```

- {CArray.meld} — welds K arrays along an existing axis; returns a `CAMeld`
  view.  Both uniform and ragged pieces work; parents must agree on
  `data_type`, `ndim`, byte width, and every axis length except the meld
  axis (mismatch raises).  Also available as an instance method
  (`a.meld(b, c, axis: 0)`).
- {CArray.concatenate} — eager materialised copy along an existing axis;
  auto-casts to the common `data_type` (or an explicit `data_type:` kwarg).
  Reach for this when you want an owned entity, or when pieces have mixed
  data type and you don't want to cast them yourself.

See [CAMeld.md](../objects/CAMeld.md) for the meld view and
[CAStack.md](../objects/CAStack.md) for the K-axis stack view.

---

## `CArray.stack` — new axis, single direction

`stack` takes K arrays of the same shape and stacks them along a **brand-new
axis** inserted at position `axis:` (default 0).  The result has `ndim + 1`
dimensions.

```
a = [A B C D]    shape [4]      (each letter is one element)
b = [E F G H]    shape [4]
c = [I J K L]    shape [4]

CArray.stack([a, b, c])          # axis: 0 (default)

result shape: [3, 4]

  axis 0 ↓   axis 1 →
  ┌─────────────────┐
  │  A   B   C   D  │  ← a
  │  E   F   G   H  │  ← b
  │  I   J   K   L  │  ← c
  └─────────────────┘
```

The new axis is where the "which source array?" question lives.

Placing the new axis at the end (`axis: -1`) is the common pattern for
channel data:

```
r = [R0 R1 R2]   shape [3]       (red channel)
g = [G0 G1 G2]   shape [3]       (green channel)
b = [B0 B1 B2]   shape [3]       (blue channel)

CArray.stack([r, g, b], axis: -1)   # or axis: 1 for 1-D parents

result shape: [3, 3]

  pixel ↓   channel (R/G/B) →
  ┌──────────────┐
  │ R0   G0  B0  │  pixel 0
  │ R1   G1  B1  │  pixel 1
  │ R2   G2  B2  │  pixel 2
  └──────────────┘
```

For 2-D parents `[H, W]` the RGB result is `[H, W, 3]` with `axis: -1`.

```ruby
# 12 monthly grids, each [720, 360]
year = CArray.stack(monthly, axis: 0)   # view, shape [12, 720, 360]

# RGB image channels [H, W]
rgb  = CArray.stack([r, g, b], axis: -1)  # view, shape [H, W, 3]

# materialise when needed
year.copy     # fresh contiguous CArray [12, 720, 360]
```

---

## `CArray.meld` — existing axis grows, single direction

`meld` (melt + weld) concatenates K arrays along an axis that **already
exists**.  The result has the same `ndim` as the inputs; the chosen axis
grows by factor K.

```
a = [A B C D]   shape [4]
b = [E F G H]   shape [4]
c = [I J K L]   shape [4]

CArray.meld([a, b, c])   # axis: 0 (default)

result shape: [12]

  [ A  B  C  D  E  F  G  H  I  J  K  L ]
  └────a────┘└────b────┘└────c────┘
```

For 2-D arrays:

```
a  shape [3, 4]   b  shape [3, 4]   c  shape [3, 4]

CArray.meld([a, b, c], axis: 0)    →  shape [9, 4]

  ┌──────────────┐
  │              │  ← rows of a
  │   a (3×4)   │
  │              │
  ├──────────────┤
  │              │  ← rows of b
  │   b (3×4)   │
  │              │
  ├──────────────┤
  │              │  ← rows of c
  │   c (3×4)   │
  │              │
  └──────────────┘

CArray.meld([a, b, c], axis: 1)    →  shape [3, 12]

  ┌──────────┬──────────┬──────────┐
  │  a (3×4) │  b (3×4) │  c (3×4) │
  └──────────┴──────────┴──────────┘
```

`meld` returns a **view**.  To obtain a contiguous copy, call `.copy`.

```ruby
# Concatenate 12 monthly layers along time axis 0
year = CArray.meld(monthly, axis: 0)    # view, shape [12, 720, 360]
year.copy                                # materialised, independent copy

# Concatenate along columns
wide = CArray.meld([a, b, c], axis: 1)  # view, shape [3, 12]

# data_type coercion
result = CArray.meld([int_a, float_b], data_type: :float64)
```

---

## `stack` vs `meld` — the key difference

```
a  shape [3, 4]   b  shape [3, 4]   c  shape [3, 4]

CArray.stack([a, b, c])           CArray.meld([a, b, c])
  new axis at 0                     axis 0 grows
  shape: [3, 3, 4]                  shape: [9, 4]

  ┌─────────────┐                   ┌──────────────┐
  │  a (3×4)   │  plane 0          │              │
  ├─────────────┤                   │   a (3×4)   │
  │  b (3×4)   │  plane 1          │              │
  ├─────────────┤                   ├──────────────┤
  │  c (3×4)   │  plane 2          │   b (3×4)   │
  └─────────────┘                   ├──────────────┤
                                    │   c (3×4)   │
                                    └──────────────┘

  meld[k, :]  == a/b/c[:]          meld[0:3, :]  == a
  (slice along new axis 0)         (slice along existing axis 0)
```

Rule of thumb: if you later want `result[k]` to give back one of the
original arrays, use `stack`.  If you want the result to look like one
long array, use `meld`.

---

## `CArray.montage` — existing axes grow, grid of tiles

`montage` generalises `meld` from a single direction to a rectangular grid.
You supply a `tdim` array that describes the grid shape (e.g. `[2, 3]` for
2 rows × 3 columns of tiles).  The axes `axis..axis+tdim.size-1` are
extended; ndim stays the same.

```
a b c d e f   each shape [3, 4]   tdim = [2, 3]

CArray.montage([a, b, c, d, e, f], [2, 3])   shape [6, 12]

  ┌──────┬──────┬──────┐
  │  a   │  b   │  c   │   rows  0..2
  │ 3×4  │ 3×4  │ 3×4  │
  ├──────┼──────┼──────┤
  │  d   │  e   │  f   │   rows  3..5
  │ 3×4  │ 3×4  │ 3×4  │
  └──────┴──────┴──────┘
  col 0..3  4..7  8..11
```

The tiles fill row-major order (first tile axis varies slowest).

```ruby
# 2×3 mosaic of image patches, each [H, W]
view = CArray.montage(patches, [2, 3])        # shape [2*H, 3*W]

# 3-D: tile along axes 1 and 2 (axis: 1), leave axis 0 (channels) alone
CArray.montage(tiles, [2, 2], axis: 1)        # tiles along [rows, cols]

# materialise
view.copy
```

`montage` returns a **view**.  The tile count product must equal `list.size`.

---

## Ragged eager methods

When the pieces differ in size along the assembly axis, the view-default
methods cannot be used (they require uniform shapes).  The eager methods
accept non-uniform pieces and materialise immediately.

### `CArray.concatenate` — ragged 1-axis concat

`concatenate` is like `meld` but the pieces may differ in size along the
assembly axis.  Always returns a fresh, owned CArray.

```
a  shape [2, 4]   b  shape [5, 4]   c  shape [3, 4]   (axis 0 differs)

CArray.concatenate([a, b, c], axis: 0)    shape [10, 4]

  ┌──────────────┐
  │   a (2×4)   │
  ├──────────────┤
  │              │
  │   b (5×4)   │
  │              │
  ├──────────────┤
  │   c (3×4)   │
  └──────────────┘
```

The non-tile axes must agree across all pieces (same column count here).

```ruby
# Variable-length time series, each [T_i, features]
full = CArray.concatenate(series_list, axis: 0)

# Uniform inputs: meld returns a view, concatenate always materialises
CArray.meld([a, b]).copy == CArray.concatenate([a, b])   # equivalent result
```

### `CArray.mosaic` — ragged grid assembly

`mosaic` is like `montage` but each row and each column of the tile grid
may have different sizes (block-matrix semantics).  Always materialises.

```
A shape [2, 3]   B shape [2, 5]
C shape [4, 3]   D shape [4, 5]     tdim = [2, 2]

CArray.mosaic([A, B, C, D], [2, 2])    shape [6, 8]

  ┌──────────┬──────────────┐
  │  A (2×3) │   B (2×5)   │
  ├──────────┼──────────────┤
  │          │              │
  │  C (4×3) │   D (4×5)   │
  │          │              │
  └──────────┴──────────────┘

Row sizes: [2, 4]   Col sizes: [3, 5]
```

Pieces within the same tile-row must share the same height; pieces within
the same tile-column must share the same width.

```ruby
# Block-matrix assembly
m = CArray.mosaic([A, B, C, D], [2, 2])

# Uniform tiles: montage returns a view, mosaic always materialises
CArray.montage(tiles, [2, 2]).copy == CArray.mosaic(tiles, [2, 2])
```

### `CArray.tabulate` — 1-D columns into a 2-D table

`tabulate` bundles a list of 1-D arrays (columns) or 2-D column blocks into
a single 2-D table.  All entries must have the same row count.  Bare 1-D
columns are promoted to `(L, 1)` automatically before concatenating along
the column axis.

```
col1 = [1 2 3]         shape [3]
col2 = [4 5 6]         shape [3]
col3 = [[a b] [c d] [e f]]   shape [3, 2]

CArray.tabulate([col1, col2, col3])   shape [3, 4]

  row ↓   col →
  ┌──────────────────┐
  │  1   4   a   b  │
  │  2   5   c   d  │
  │  3   6   e   f  │
  └──────────────────┘
```

```ruby
# Build a typed table from separate columns
table = CArray.tabulate([x, y, z])                          # inferred type
table = CArray.tabulate([x, y], data_type: :float64)        # forced type
```

---

## Instance-side helpers

### `CArray#stack` — stack self with others

```ruby
c = a.stack(b)               # CArray.stack([a, b])
c = a.stack(b, axis: -1)     # CArray.stack([a, b], axis: -1)
```

### `CArray#split` — inverse of stack

`split` slices `self` along one axis into an Array of `(ndim-1)`-D views.
It is the exact inverse of `CArray.stack`.

```
a  shape [3, 4]

a.split(axis: 0)   #=> [a[0,nil], a[1,nil], a[2,nil]]
                   #   each shape [4], writable CABlock view

CArray.stack(a.split(axis: 0), axis: 0)   # back to [3, 4]
```

```ruby
planes = volume.split(axis: 0)      # [D] views of shape [H, W]
first  = planes[0]                  # CABlock view, writes go back to volume
copy   = planes[0].copy             # independent copy
```

### `CAStack#append` — extend an existing stack

`append` adds more parents to an existing `CAStack`, preserving `k_axis`.

```ruby
s = CArray.stack([a, b], axis: 1)   # 2-parent stack, k_axis=1
s = s.append(c, d)                  # 4-parent stack, k_axis=1
```

---

## `data_type` promotion

All methods infer a common data type from the inputs unless `data_type:` is
given explicitly.  Mixed numeric types are promoted (e.g. `int32` + `float64`
→ `float64`).

```ruby
CArray.stack([int_a, float_b])                   # float64 (inferred)
CArray.meld([a, b], data_type: :float32)         # forced float32
```

`data_type:` accepts primitive type symbols (`:int32`, `:float64`, …).
It cannot be used when the list contains Face instances
(`CATime`, `CARecord`, etc.); in that case, type is always inferred.

---

## View or copy?

The view-default methods return a `CAStack`-backed view.  No data is copied
until you call `.copy`.  This matters when:

- You only need a subset of the result (e.g. `meld(files)[0..99, nil]`).
- You want to pass the result to a reduce method (`meld(monthly).sum(axis: 0)`).
- Memory is tight and you want to avoid a peak allocation.

The result is already a CArray, so `.to_ca` is a **no-op** here — it returns
the view unchanged (self, no copy).  Use it only when you just need "a CArray
to read or pass".  Call `.copy` when downstream code requires an independent,
contiguous buffer (binary I/O, MemoryView export, C extension that calls
`ca_attach`).

```ruby
view = CArray.meld(monthly, axis: 0)   # no allocation yet
mean = view.mean(axis: 0)              # still no full materialise
arr  = view.copy                       # materialise now, independent buffer
```

Known limitation: scalar indexing on a `CAStack`-rooted view
(e.g. `meld(...)[k, nil]`) triggers a full materialise.  Use range
indexing (`meld(...)[k..k, nil]`) to stay in view mode, or materialise
upfront with `.copy`.

---

## Quick reference

| Method | Returns | ndim | Uniform? | Single dir? |
|---|---|---|---|---|
| `stack(list, axis:)` | view | ndim + 1 | required | yes |
| `meld(list, axis:)` | view | same | required | yes |
| `montage(list, tdim, axis:)` | view | same | required | grid |
| `concatenate(list, axis:)` | eager | same | ok ragged | yes |
| `mosaic(list, tdim, axis:)` | eager | same | ok ragged | grid |
| `tabulate(columns)` | eager | 2 | same row count | columns |

---

## 3.0 vocabulary changes

The 3.0 surface renames the 20-year-old API:

| Pre-3.0 | 3.0 |
|---|---|
| `bind(type, list, at)` | `meld(list, axis:)` |
| `merge(type, list, at)` | `stack(list, axis:)` |
| `combine(type, tdim, list, at)` | `montage(list, tdim, axis:)` |
| `composite(type, tdim, list, at)` | (covered by `stack` + reshape) |
| `concat(type, list, at)` | `concatenate(list, axis:)` |
| `join(nested_array)` | `mosaic(list, tdim, axis:)` |
| — | `tabulate(columns)` (new) |

Note: `CArray#join` now behaves like `Array#join` (string concatenation).

---

## Concrete examples with small arrays

All examples are self-contained and runnable.  Output is shown in CArray's
own `inspect` format (`puts obj.inspect`), so you can paste the code and
compare directly.

### `stack` — 1-D inputs

```ruby
require "carray"

a = CA_INT([1, 2, 3])
b = CA_INT([4, 5, 6])
c = CA_INT([7, 8, 9])
```

`axis: 0` (default) — K axis outermost.  Each row is one source array.

```ruby
puts CArray.stack([a, b, c]).inspect
#=> <CAStack.int32(3,3): elem=9 mem=36b
#   [ [ 1, 2, 3 ],
#     [ 4, 5, 6 ],
#     [ 7, 8, 9 ] ]>
```

`axis: -1` — K axis innermost.  Each column is one source array (transpose
of the above).

```ruby
puts CArray.stack([a, b, c], axis: -1).inspect
#=> <CAStack.int32(3,3): elem=9 mem=36b
#   [ [ 1, 4, 7 ],
#     [ 2, 5, 8 ],
#     [ 3, 6, 9 ] ]>
```

### `stack` — 2-D inputs, three axis positions

```ruby
a = CA_INT([[1, 2, 3],
            [4, 5, 6]])   # shape [2, 3]

b = CA_INT([[7,  8,  9],
            [10, 11, 12]])
```

`axis: 0` — "which source" becomes the outermost axis.

```ruby
puts CArray.stack([a, b], axis: 0).inspect
#=> <CAStack.int32(2,2,3): elem=12 mem=48b
#   [ [ [ 1, 2, 3 ],
#       [ 4, 5, 6 ] ],
#     [ [ 7, 8, 9 ],
#       [ 10, 11, 12 ] ] ]>
#                                   result[0,nil,nil] == a
#                                   result[1,nil,nil] == b
```

`axis: 1` — K axis inserted between the row axis and the column axis.
Each pair along axis 1 is (row i of a, row i of b).

```ruby
puts CArray.stack([a, b], axis: 1).inspect
#=> <CAStack.int32(2,2,3): elem=12 mem=48b
#   [ [ [ 1, 2, 3 ],
#       [ 7, 8, 9 ] ],    ← row 0 of a / row 0 of b
#     [ [ 4, 5, 6 ],
#       [ 10, 11, 12 ] ] ]>  ← row 1 of a / row 1 of b
```

`axis: -1` — K axis innermost.  Each pair along the last axis is
(same-position element from a, same-position element from b).

```ruby
puts CArray.stack([a, b], axis: -1).inspect
#=> <CAStack.int32(2,3,2): elem=12 mem=48b
#   [ [ [ 1, 7 ],
#       [ 2, 8 ],
#       [ 3, 9 ] ],
#     [ [ 4, 10 ],
#       [ 5, 11 ],
#       [ 6, 12 ] ] ]>
#                                   result[nil,nil,0] == a
#                                   result[nil,nil,1] == b
```

### `meld` — concatenate along an existing axis

```ruby
a = CA_INT([[1, 2, 3],
            [4, 5, 6]])   # shape [2, 3]

b = CA_INT([[7,  8,  9],
            [10, 11, 12]])
```

`axis: 0` (default) — rows of b are appended below rows of a.

```ruby
puts CArray.meld([a, b]).inspect
#=> <CARefer.int32(4,3): elem=12 mem=48b
#   [ [ 1, 2, 3 ],
#     [ 4, 5, 6 ],
#     [ 7, 8, 9 ],
#     [ 10, 11, 12 ] ]>
```

`axis: 1` — columns of b are appended to the right of a.

```ruby
puts CArray.meld([a, b], axis: 1).inspect
#=> <CARefer.int32(2,6): elem=12 mem=48b
#   [ [ 1, 2, 3, 7, 8, 9 ],
#     [ 4, 5, 6, 10, 11, 12 ] ]>
```

### `stack` vs `meld` — side by side

```ruby
a = CA_INT([[1, 2],
            [3, 4]])   # shape [2, 2]

b = CA_INT([[5, 6],
            [7, 8]])
```

`stack` adds a new axis; `meld` extends an existing one.

```ruby
puts CArray.stack([a, b]).inspect
#=> <CAStack.int32(2,2,2): elem=8 mem=32b
#   [ [ [ 1, 2 ],
#       [ 3, 4 ] ],    ← plane 0 == a
#     [ [ 5, 6 ],
#       [ 7, 8 ] ] ]>  ← plane 1 == b

puts CArray.meld([a, b]).inspect
#=> <CARefer.int32(4,2): elem=8 mem=32b
#   [ [ 1, 2 ],
#     [ 3, 4 ],        ← rows of a
#     [ 5, 6 ],
#     [ 7, 8 ] ]>      ← rows of b (boundary invisible)

puts CArray.meld([a, b], axis: 1).inspect
#=> <CARefer.int32(2,4): elem=8 mem=32b
#   [ [ 1, 2, 5, 6 ],
#     [ 3, 4, 7, 8 ] ]>
```

Recovering the originals:

```ruby
s = CArray.stack([a, b])
puts s[0, nil, nil].inspect   # == a
#=> <CABlock.int32(2,2): elem=4 mem=16b
#   [ [ 1, 2 ],
#     [ 3, 4 ] ]>

m = CArray.meld([a, b])
puts m[0..1, nil].inspect     # == a  (need to know the split point)
#=> <CABlock.int32(2,2): elem=4 mem=16b
#   [ [ 1, 2 ],
#     [ 3, 4 ] ]>
```

### `montage` — uniform tile grid

```ruby
a = CA_INT([[1,  2 ], [3,  4 ]])
b = CA_INT([[5,  6 ], [7,  8 ]])
c = CA_INT([[9,  10], [11, 12]])
d = CA_INT([[13, 14], [15, 16]])
```

`[2, 2]` tile grid: a=top-left, b=top-right, c=bottom-left, d=bottom-right.

```ruby
puts CArray.montage([a, b, c, d], [2, 2]).inspect
#=> <CARefer.int32(4,4): elem=16 mem=64b
#   [ [ 1,  2,  5,  6 ],    ← top rows of a | b
#     [ 3,  4,  7,  8 ],    ← bot rows of a | b
#     [ 9,  10, 13, 14 ],   ← top rows of c | d
#     [ 11, 12, 15, 16 ] ]> ← bot rows of c | d
```

### `concatenate` — ragged 1-axis concat

Pieces may differ in size along the assembly axis.

```ruby
a = CA_INT([[1, 2, 3],
            [4, 5, 6]])           # shape [2, 3]

b = CA_INT([[7,  8,  9 ],
            [10, 11, 12],
            [13, 14, 15]])        # shape [3, 3]  ← different row count
```

```ruby
puts CArray.concatenate([a, b], axis: 0).inspect
#=> <CArray.int32(5,3): elem=15 mem=60b
#   [ [ 1,  2,  3  ],
#     [ 4,  5,  6  ],
#     [ 7,  8,  9  ],
#     [ 10, 11, 12 ],
#     [ 13, 14, 15 ] ]>
```

Non-tile axes (columns here) must match across all pieces.

### `mosaic` — ragged block-matrix

Pieces may differ in both row height and column width, following block-matrix
rules (consistent within each tile-row and tile-column).

```ruby
A = CA_INT([[1,  2,  3],
            [4,  5,  6]])         # shape [2, 3]

B = CA_INT([[7,  8 ],
            [9,  10]])            # shape [2, 2]

C = CA_INT([[11, 12, 13],
            [14, 15, 16],
            [17, 18, 19]])        # shape [3, 3]

D = CA_INT([[20, 21],
            [22, 23],
            [24, 25]])            # shape [3, 2]
```

```ruby
puts CArray.mosaic([A, B, C, D], [2, 2]).inspect
#=> <CArray.int32(5,5): elem=25 mem=100b
#   [ [ 1,  2,  3,  7,  8  ],   ← row 0 of A | B
#     [ 4,  5,  6,  9,  10 ],   ← row 1 of A | B
#     [ 11, 12, 13, 20, 21 ],   ← row 0 of C | D
#     [ 14, 15, 16, 22, 23 ],
#     [ 17, 18, 19, 24, 25 ] ]>
```

### `tabulate` — 1-D columns into a 2-D table

```ruby
id   = CA_INT([101, 102, 103])
flag = CA_INT([[1, 0],
               [0, 1],
               [1, 1]])           # 2-column block, shape [3, 2]
```

Bare 1-D columns are automatically promoted to `(L, 1)`.

```ruby
puts CArray.tabulate([id, flag], data_type: :int32).inspect
#=> <CArray.int32(3,3): elem=9 mem=36b
#   [ [ 101, 1, 0 ],
#     [ 102, 0, 1 ],
#     [ 103, 1, 1 ] ]>
```

Mixed numeric types are promoted when `data_type:` is omitted:

```ruby
puts CArray.tabulate([CA_INT([1, 2, 3]), CA_FLOAT64([0.5, 1.5, 2.5])]).inspect
#=> <CArray.float64(3,2): elem=6 mem=48b
#   [ [ 1.0, 0.5 ],
#     [ 2.0, 1.5 ],
#     [ 3.0, 2.5 ] ]>
```

### `split` — inverse of `stack`

```ruby
m = CA_INT([[1, 2, 3],
            [4, 5, 6],
            [7, 8, 9]])
```

`split(axis: 0)` returns an Array of row views (CABlock, writable):

```ruby
rows = m.split(axis: 0)
puts rows[0].inspect
#=> <CABlock.int32(3): elem=3 mem=12b
#   [ 1, 2, 3 ]>
puts rows[1].inspect
#=> <CABlock.int32(3): elem=3 mem=12b
#   [ 4, 5, 6 ]>
puts rows[2].inspect
#=> <CABlock.int32(3): elem=3 mem=12b
#   [ 7, 8, 9 ]>
```

`split(axis: 1)` returns column views:

```ruby
cols = m.split(axis: 1)
puts cols[0].inspect   #=> <CABlock.int32(3): ...  [ 1, 4, 7 ]>
puts cols[1].inspect   #=> <CABlock.int32(3): ...  [ 2, 5, 8 ]>
puts cols[2].inspect   #=> <CABlock.int32(3): ...  [ 3, 6, 9 ]>
```

Round-trip:

```ruby
CArray.stack(m.split(axis: 0), axis: 0) == m   # true
CArray.stack(m.split(axis: 1), axis: 1) == m   # true
```

Views write back to the original — use `.copy` for an independent copy:

```ruby
rows[0][] = CA_INT([10, 20, 30])
puts m.inspect
#=> <CArray.int32(3,3): elem=9 mem=36b
#   [ [ 10, 20, 30 ],
#     [ 4,  5,  6  ],
#     [ 7,  8,  9  ] ]>
```

### `CAStack#append` — grow an existing stack

```ruby
a = CA_INT([[1,  2 ], [3,  4 ]])
b = CA_INT([[5,  6 ], [7,  8 ]])
c = CA_INT([[9,  10], [11, 12]])

s = CArray.stack([a, b])
puts s.inspect
#=> <CAStack.int32(2,2,2): elem=8 mem=32b
#   [ [ [ 1, 2 ],
#       [ 3, 4 ] ],
#     [ [ 5, 6 ],
#       [ 7, 8 ] ] ]>

s = s.append(c)
puts s.inspect
#=> <CAStack.int32(3,2,2): elem=12 mem=48b
#   [ [ [ 1, 2 ],
#       [ 3, 4 ] ],
#     [ [ 5, 6 ],
#       [ 7, 8 ] ],
#     [ [ 9,  10 ],
#       [ 11, 12 ] ] ]>
```

### `data_type` promotion

```ruby
puts CA_INT([1, 2, 3]).inspect
#=> <CArray.int32(3): elem=3 mem=12b
#   [ 1, 2, 3 ]>

puts CA_FLOAT64([0.5, 1.5, 2.5]).inspect
#=> <CArray.float64(3): elem=3 mem=24b
#   [ 0.5, 1.5, 2.5 ]>

# int32 + float64 → float64 (automatic)
puts CArray.stack([CA_INT([1, 2, 3]), CA_FLOAT64([0.5, 1.5, 2.5])]).inspect
#=> <CAStack.float64(2,3): elem=6 mem=48b
#   [ [ 1.0, 2.0, 3.0 ],
#     [ 0.5, 1.5, 2.5 ] ]>
```
