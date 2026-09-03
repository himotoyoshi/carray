# Composition

*Composition* means building one larger array out of several smaller ones. You already have some pieces — three monthly grids, the red/green/blue channels of an image, four image tiles arranged in a 2×2 mosaic — and you want to glue them together into a single array.

CArray's composition surface is a **3 × 2** matrix. The three rows ask *how* the pieces fit together; the two columns split the methods into view-default and eager:

|                                       | view (same data type) | eager (auto-casts) |
|---------------------------------------|------------------------|--------------------|
| **extend an existing axis** (ndim same)        | `meld`                 | `concatenate`      |
| **add a new axis** (ndim grows)                | `stack`                | *(impossible)*     |
| **tile into a grid, extending existing axes**  | `montage`              | `mosaic`           |

Two questions decide which one:

- Do the pieces line up along an axis the inputs already have, am I making a brand-new axis, or am I tiling into a grid?
- Do I want a view over the original pieces, or a fresh, independent entity?

**The view-default methods do not copy.** `meld`, `stack`, and `montage` return a view onto the original arrays — reads gather from the pieces on demand, and writes flow back to them. They require the pieces to share a data type (a mismatch raises; cast the pieces yourself first). Materialise with `.copy` when you want a fresh independent buffer.

**The eager methods materialise.** `concatenate` and `mosaic` allocate a destination, auto-cast mixed data types to a common one, and paste each piece in, so they always return a fresh owned CArray.

Along the axis being extended, the pieces need *not* be the same length — `meld` welds ragged pieces just as happily as uniform ones. The one composition that is uniform-only by definition is `stack`: putting pieces on a brand-new axis only makes sense when every piece has the same shape. (`montage` also requires uniform tiles; its ragged counterpart is `mosaic`.)

The rest of this page walks through each method. (For background on what "view" means, see [Views](06_views.md).)

## `meld` — concatenate along an existing axis (view)

`meld` welds a list of arrays together along one of their existing axes. The number of dimensions stays the same; one axis grows longer. *"Meld" = melt + weld: the pieces dissolve their boundary along the named axis and are regarded as one.* The result is a `CAMeld` view — no data is copied; reads gather from the pieces on demand and writes flow straight back to them.

```ruby
a = CArray.int32(2, 3).seq
#  => [ [ 0, 1, 2 ],
#       [ 3, 4, 5 ] ]

b = CArray.int32(2, 3).seq(10)
#  => [ [ 10, 11, 12 ],
#       [ 13, 14, 15 ] ]

CArray.meld([a, b], axis: 0)
#  => [ [  0,  1,  2 ],
#       [  3,  4,  5 ],
#       [ 10, 11, 12 ],
#       [ 13, 14, 15 ] ]
```

`axis:` defaults to `0`. With `axis: 1` the two arrays sit side by side instead of one above the other:

```ruby
CArray.meld([a, b], axis: 1)
#  => [ [ 0, 1, 2, 10, 11, 12 ],
#       [ 3, 4, 5, 13, 14, 15 ] ]
```

Both a splat and a single Array are accepted, and there is an instance form that takes the other pieces directly:

```ruby
CArray.meld(a, b, axis: 1)     #  same as CArray.meld([a, b], axis: 1)
a.meld(b, axis: 1)             #  ditto
```

### Ragged pieces are fine

The pieces must agree on `ndim`, on the data type, and on every axis length *except* the meld axis. Along the meld axis itself they may contribute different lengths — the result is still a view:

```ruby
x = CArray.int32(2, 3).seq            # [[0, 1, 2], [3, 4, 5]]
y = CArray.int32(1, 3).seq(100)       # [[100, 101, 102]]

CArray.meld([x, y], axis: 0)
#  => [ [   0,   1,   2 ],
#       [   3,   4,   5 ],
#       [ 100, 101, 102 ] ]           shape [3, 3], a CAMeld view
```

### The data type must match

`meld` is strict about data types: mixing `int32` pieces with `float64` pieces raises. Cast the pieces yourself when you mean it —

```ruby
i = CArray.int32(3).seq
f = CArray.float64(3).seq(0.5)

CArray.meld([i, f])                       #  ArgumentError (data_type mismatch)
CArray.meld([i.float64, f])               #  fine — both float64 now
```

— or reach for `concatenate` (below), the eager sibling that auto-casts.

A common mistake — melding twelve monthly `[lat, lon]` grids into a yearly array:

```ruby
# monthly_arrays : an Array of 12 CArrays, each shape [720, 360]
yearly = CArray.meld(monthly_arrays, axis: 0)
# resulting shape: [12 * 720, 360]  — not what you want!
```

`meld` extends an *existing* axis. If you want a brand-new time axis on top of the monthly grids, you want `stack`.

NumPy equivalent: `np.concatenate(list, axis=axis)` — except that `meld` returns a view.

## `stack` — push onto a brand-new axis (uniform, view)

`stack` introduces a new axis. The output has one more dimension than each input.

```ruby
CArray.stack([a, b], axis: 0)
#  => [ [ [  0,  1,  2 ],
#         [  3,  4,  5 ] ],
#       [ [ 10, 11, 12 ],
#         [ 13, 14, 15 ] ] ]
```

The new axis sits at position `0`, so the result has shape `[2, 2, 3]`: two slices of the original `[2, 3]` shape.

`axis:` can be negative to count from the end. The canonical case is the RGB-image pattern — stacking three `[H, W]` channels into an `[H, W, 3]` image:

```ruby
# r, g, b are each CArray[H, W]
rgb = CArray.stack([r, g, b], axis: -1)        #  shape [H, W, 3]
```

And the monthly-grids case from above, done correctly:

```ruby
yearly = CArray.stack(monthly_arrays, axis: 0)
#  shape [12, 720, 360] — the new time axis is axis 0
```

NumPy equivalent: `np.stack(list, axis=axis)`.

### Instance form: `a.stack(b, c, ...)`

There's also an instance method that takes the *other* parents directly:

```ruby
a.stack(b)               #  same as CArray.stack([a, b])
r.stack(g, b, axis: -1)  #  same as CArray.stack([r, g, b], axis: -1)
```

`self` is always treated as one parent of a new stack, even when it is itself the result of a previous `stack`. To flat-append more parents into an existing stack (extending the K axis in place), use `CAStack#append`:

```ruby
s = CArray.stack([a, b], axis: 1)   # 2-parent stack, k_axis = 1
s.append(c, d)                       # 4-parent stack, k_axis = 1
```

### `split` — the inverse of `stack`

`split` slices an array along one axis into a Ruby `Array` of `(ndim − 1)`-dimensional views. It is the exact inverse of `CArray.stack`:

```ruby
m = CA_INT([[1, 2, 3],
            [4, 5, 6],
            [7, 8, 9]])

rows = m.split(axis: 0)        #  => [ [1,2,3], [4,5,6], [7,8,9] ]  (3 views)
cols = m.split(axis: 1)        #  => [ [1,4,7], [2,5,8], [3,6,9] ]

CArray.stack(m.split(axis: 0), axis: 0) == m   #  => true (round-trip)
```

Each piece is a writable view — assigning into `rows[0]` changes `m`. Take `.copy` of a piece when you want it independent.

### Tiling into multiple new axes

`stack` plus `reshape` covers the case where you want the tile pattern to live on *new* outer axes rather than to extend existing ones. Four `[2, 2]` pieces arranged in a `2 × 2` grid, with the tile axes kept as brand-new outer axes:

```ruby
CArray.stack([a, b, c, d]).reshape(2, 2, 2, 2)
#  shape [2, 2, 2, 2] — outer two axes index the tile, inner two are the piece
```

This is still a view (both `stack` and `reshape` are view operations), so nothing is copied.

## How to choose between `meld` and `stack`

Ask: does each input array *already have* the axis I want to extend?

- The 12 monthly grids each have axes `[lat, lon]`. There is no "month" axis on any single grid — that axis only exists in the combined array. So you need `stack` to create it.
- If you had 12 *yearly* grids each of shape `[12, 720, 360]` (so the month axis is already present), and you wanted to splice them into a 144-month series, that's `meld` along axis 0.

## `montage` — tile into an N-D grid (uniform, view)

`montage` arranges a list of same-shape pieces into a regular grid that extends existing axes by the given factors. The number of dimensions stays the same. *(Named after ImageMagick's `montage`.)*

```ruby
a = CArray.int32(2, 2).seq          # [[ 0,  1], [ 2,  3]]
b = CArray.int32(2, 2).seq(10)      # [[10, 11], [12, 13]]
c = CArray.int32(2, 2).seq(20)      # [[20, 21], [22, 23]]
d = CArray.int32(2, 2).seq(30)      # [[30, 31], [32, 33]]

CArray.montage([a, b, c, d], [2, 2], axis: 0)
#  => [ [  0,  1, 10, 11 ],
#       [  2,  3, 12, 13 ],
#       [ 20, 21, 30, 31 ],
#       [ 22, 23, 32, 33 ] ]
```

The second positional argument `[2, 2]` is the tile pattern: two rows of two blocks. The pieces are taken from the list in row-major order. `tdim.product` must equal the number of pieces, and `axis:` selects which existing axes the tile pattern extends (the tile axes occupy positions `axis..axis+tdim.size-1`).

`montage` has no direct NumPy equivalent — `np.block` partially overlaps.

## `concatenate` and `mosaic` — the eager siblings

`concatenate` is the eager counterpart of `meld`, and `mosaic` of `montage`. They allocate a destination, paste each piece in, and return a fresh owned CArray. Reach for them when:

- you want an **independent entity** rather than a view over the pieces (the eager form does in one step what `meld(...).copy` does in two), or
- the pieces have **mixed data types** and you want the automatic promotion to a common type instead of casting each piece yourself.

```ruby
x = CArray.int32(2, 3).seq            # [[0, 1, 2], [3, 4, 5]]
y = CArray.int32(1, 3).seq(100)       # [[100, 101, 102]]

CArray.concatenate([x, y], axis: 0)
#  => [ [   0,   1,   2 ],
#       [   3,   4,   5 ],
#       [ 100, 101, 102 ] ]           an entity, not a view

i = CArray.int32(3).seq
f = CArray.float64(3).seq(0.5)
CArray.concatenate([i, f])
#  => [ 0.0, 1.0, 2.0, 0.5, 1.5, 2.5 ]   auto-promoted to float64
```

`concatenate` also has an instance form (`x.concatenate(y, axis: 0)`) and accepts `data_type:` to force the output type. Like `meld`, it takes ragged pieces — the non-glue axes must agree, the glue axis may differ.

`mosaic` extends the same idea to a grid: each tile-row and tile-column of the grid may have its own size, following block-matrix rules (pieces within one tile-row share a height; pieces within one tile-column share a width):

```ruby
A = CA_INT([[1, 2, 3], [4, 5, 6]])                # shape [2, 3]
B = CA_INT([[7, 8], [9, 10]])                     # shape [2, 2]
C = CA_INT([[11, 12, 13], [14, 15, 16], [17, 18, 19]])   # shape [3, 3]
D = CA_INT([[20, 21], [22, 23], [24, 25]])        # shape [3, 2]

CArray.mosaic([A, B, C, D], [2, 2])
#  => [ [  1,  2,  3,  7,  8 ],
#       [  4,  5,  6,  9, 10 ],
#       [ 11, 12, 13, 20, 21 ],
#       [ 14, 15, 16, 22, 23 ],
#       [ 17, 18, 19, 24, 25 ] ]      shape [5, 5]
```

There is no ragged counterpart of `stack`: stacking on a brand-new axis only makes sense when every piece has the same shape, so ragged stacking is impossible by definition.

NumPy: `concatenate` matches `np.concatenate(list, axis=axis)`. `mosaic` has no direct equivalent (`np.block` partially overlaps).

## `tabulate` — a 2-D table from columns

`tabulate` assembles a 2-D table by placing a list of columns side by side. Each entry is a 1-D array (one column of the table) or an already-2-D block; they must all have the same number of rows.

```ruby
c1 = CA_INT([1, 2, 3])
c2 = CA_DOUBLE([4.5, 5.5, 6.5])

CArray.tabulate([c1, c2])
#  => [ [ 1.0, 4.5 ],
#       [ 2.0, 5.5 ],
#       [ 3.0, 6.5 ] ]     shape [3, 2]
```

The columns are glued along axis 1, so a bare 1-D column of length `L` becomes one `[L, 1]` column of the result. Mixed data types are promoted to a common type (here `float64`); pass `data_type:` to force one:

```ruby
CArray.tabulate([c1, c2], data_type: :int32)
#  => [ [ 1, 4 ],
#       [ 2, 5 ],
#       [ 3, 6 ] ]
```

The rows must line up: columns of unequal length raise rather than being padded. `tabulate` is built on `concatenate`, so it returns an eager, materialised CArray.

## View or entity?

`meld`, `stack`, and `montage` return *views* — they do not copy the data of the input arrays. See [Views](06_views.md) for what this means in practice: writing through the result reaches back and changes the original pieces, and holding the result keeps the parents alive. Staying a view matters when you only need a subset of the result (`meld(files)[0..99, nil]`), when you feed the result straight into a reduction (`meld(monthly).sum(axis: 0)`), or when memory is tight and you want to avoid a peak allocation.

To get a separate, contiguous copy, ask for one explicitly with `.copy`:

```ruby
v = CArray.meld([a, b], axis: 0)      #  a view
v.entity?                             #  => false
v.virtual?                            #  => true

m = v.copy                            #  fresh, materialised CArray
m.entity?                             #  => true
```

(`.to_ca` is *not* the way to materialise: on a view it returns the view itself, unchanged. Use `.copy` when you need an independent buffer.)

`concatenate`, `mosaic`, and `tabulate` allocate a destination and paste each piece in, so they always return a fresh materialised CArray directly.

> **Known limitation.** Scalar indexing on a `stack`-rooted view (`CArray.stack(list)[k, ...]`) drops a dimension and triggers a full materialise fallback. Use range indexing (`stack(list)[k..k, ...]`) for partial-use perf, or `.copy` upfront to materialise eagerly.

## Mixing data types

The methods differ in how they treat mixed data types:

- **`meld` is strict.** The pieces must already share a data type; a mismatch raises. Cast the pieces yourself (`i.float64`) or use `concatenate`.
- **`stack` and `montage` promote.** The pieces are lifted to the type that can hold all of them, by the same rule the element-wise operations use; `data_type:` forces a target type. The promotion wraps each piece in a cast view, so the result is still a view and writes still reach the original pieces (converted back on the way in).
- **`concatenate`, `mosaic`, and `tabulate` promote too** — they are eager, so the promotion simply happens while pasting. All three accept `data_type:`.

```ruby
i = CArray.int32(3).seq               # [0, 1, 2]
f = CArray.float64(3).seq(0.5)        # [0.5, 1.5, 2.5]

CArray.stack([i, f]).data_type        #  => :float64   (promoted, still a view)
CArray.concatenate([i, f])
#  => [ 0.0, 1.0, 2.0, 0.5, 1.5, 2.5 ]                 (promoted, eager)
CArray.concatenate([i, f], data_type: :float32)        #  forced float32

CArray.meld([i, f])                   #  ArgumentError — cast first, or
                                      #  use concatenate
```

## Summary

| You want to ...                                              | Use            | Result   |
|--------------------------------------------------------------|----------------|----------|
| Weld arrays along an existing axis (uniform or ragged)       | `meld`         | view     |
| Stack same-shape arrays along a brand-new axis               | `stack`        | view     |
| Tile same-shape arrays into an N-D grid (existing axes)      | `montage`      | view     |
| Concatenate along an existing axis into an owned entity, auto-casting | `concatenate` | eager |
| Tile a ragged block-matrix into an N-D grid                  | `mosaic`       | eager    |
| Assemble a 2-D table from a list of columns                  | `tabulate`     | eager    |

The view methods keep you connected to the pieces; the eager methods hand you an independent entity and auto-cast mixed types along the way.
