# Block iteration

The reductions in [Reduction and statistics](04_reduction_and_statistics.md)
collapse a whole axis. The [slab iterator](11_slab_iteration.md) folds a 1-D
fiber. The [window iterator](22_window_iteration.md) folds an *overlapping*
window that slides one cell at a time. The **block iterator** folds a
*non-overlapping* tile: the array is cut into fixed-size tiles, each tile is
reduced to one value, and the result is a small grid — one cell per tile.

This is **pooling**, the operation you use to downsample: mean-pool or max-pool
a 2-D grid, shrink an image, aggregate a fine grid into a coarse one.

A *tile* here is a rectangular block of cells of a fixed per-axis size. Tiles do
not overlap and together they cover the whole array. Contrast the family:

* a **slab** is a 1-D fiber — you pick an axis, the rest index which fiber;
* a **window** overlaps its neighbours — anchor at every cell, output stays the
  source shape;
* a **tile** is disjoint — the output is a coarse **grid**, much smaller than the
  source.

## Building a block iterator

`a.blocks(sz0, sz1, …)` takes **one tile size per axis** and returns a
`CABlockIterator`. The axis is bound at construction, so the reductions below
take no axis argument.

```ruby
a = CArray.int32(4, 4).seq
#  => [ [  0,  1,  2,  3 ],
#       [  4,  5,  6,  7 ],
#       [  8,  9, 10, 11 ],
#       [ 12, 13, 14, 15 ] ]

a.blocks(2, 2).mean
#  => [ [  2.5,  4.5 ],
#       [ 10.5, 12.5 ] ]
```

The `4×4` array splits into four `2×2` tiles, and the output is a `2×2` grid of
their means. The top-left tile is `[[0,1],[4,5]]`, mean `2.5`; the top-right is
`[[2,3],[6,7]]`, mean `4.5`; and so on.

Max-pooling is the same call with a different reduction:

```ruby
a.blocks(2, 2).max
#  => [ [  5,  7 ],
#       [ 13, 15 ] ]
```

You give one size per axis — `blocks(2, 2)` for a 2-D array, `blocks(2)` for a
1-D array, `blocks(4, 4, 4)` for a 3-D array. Passing the wrong number of sizes
raises `ArgumentError`.

```ruby
CArray.int32(6).seq.blocks(2).sum
#  => [ 1.0, 5.0, 9.0 ]        three tiles: [0,1] [2,3] [4,5]

CArray.int32(6).seq.blocks(3).mean
#  => [ 1.0, 4.0 ]             two tiles:  [0,1,2] [3,4,5]
```

## The reduction surface

Every named reduction is the ordinary `CArray` reduction **lifted to one tile**.
It inherits the core's element type, its mask handling, its empty / all-masked
rule (identity for `sum` / `prod` / `count`, `UNDEF` for ratios and extrema), and
its ε-close numeric contract — the iterator adds no new behaviour of its own.

```ruby
img = CA_DOUBLE([[ 1,  2,  3,  4],
                 [ 5,  6,  7,  8],
                 [ 9, 10, 11, 12],
                 [13, 14, 15, 16]])

img.blocks(2, 2).mean
#  => [ [  3.5,  5.5 ],
#       [ 11.5, 13.5 ] ]

img.blocks(2, 2).min
#  => [ [  1.0,  3.0 ],
#       [  9.0, 11.0 ] ]
```

`minmax` returns both extremes of each tile in a single pass, as two grids:

```ruby
lo, hi = CArray.int32(4, 4).seq.blocks(2, 2).minmax
lo   #  => [ [ 0,  2 ], [  8, 10 ] ]
hi   #  => [ [ 5,  7 ], [ 13, 15 ] ]
```

`median`, `percentile`, and `quantile` are the order statistics per tile:

```ruby
CArray.int32(4, 4).seq.blocks(2, 2).percentile(50)
#  => [ [  2.5,  4.5 ],
#       [ 10.5, 12.5 ] ]
```

`min_index` / `max_index` report the position of the winner **within its tile**
as a flat tile-local index (row-major over the tile), not a source address:

```ruby
CArray.int32(4, 4).seq.blocks(2, 2).max_index
#  => [ [ 3, 3 ],
#       [ 3, 3 ] ]        the max is the last cell of every 2x2 tile
```

## The count family

`count_not_masked` counts the present (non-masked) cells of each tile;
`count_masked` counts the masked ones. `elements` is the structural tile size
`Π sz_i` — how many cells a full tile has — as a grid. `count` with no argument
is `count_not_masked`; `count(v)` counts cells equal to `v`; `count(UNDEF)`
counts masked cells.

```ruby
CArray.int32(4, 4).seq.blocks(2, 2).elements
#  => [ [ 4, 4 ],
#       [ 4, 4 ] ]        each 2x2 tile holds 4 cells
```

## Weighted reductions

`wsum(weights)` and `wmean(weights)` weight each cell before summing. The
`weights` array is shaped like **one full tile** (`sz0 × sz1 × …`):

```ruby
w = CArray.double(2, 2)
w[] = 1.0
w[0, 0] = 2.0                     # weight the tile's top-left cell double

CArray.double(4, 4).seq.blocks(2, 2).wsum(w)
#  => [ [ 10.0, 20.0 ],
#       [ 50.0, 60.0 ] ]          top-left tile: 2*0 + 1 + 4 + 5 = 10
```

Passing weights of the wrong shape raises `ArgumentError`.

## Partial edge tiles

When a dimension is not an exact multiple of the tile size, the last tile along
that axis is **partial** — it carries only the cells that are left over. Nothing
is dropped and nothing is required to be a full multiple: every cell belongs to a
tile, and the output grid uses **ceil division**, so a leftover row or column
adds one more grid cell.

```ruby
a = CArray.int32(5, 5).seq
#  => [ [  0,  1,  2,  3,  4 ],
#       [  5,  6,  7,  8,  9 ],
#       [ 10, 11, 12, 13, 14 ],
#       [ 15, 16, 17, 18, 19 ],
#       [ 20, 21, 22, 23, 24 ] ]

bi = a.blocks(2, 2)
bi.shape                          #  => [3, 3]   ceil(5/2) = 3 on each axis
```

The `5×5` array does not divide by `2`, so the grid is `3×3`. The last column of
tiles is one cell wide, the last row one cell tall, and the bottom-right tile is
a single cell.

A partial tile is reduced over **just the cells it holds** — there is no padding
and no fill under the reductions:

```ruby
bi.sum
#  => [ [ 12.0, 20.0, 13.0 ],     13 is the lone cell 4 (0-based [0,4]) plus 9
#       [ 52.0, 60.0, 33.0 ],
#       [ 41.0, 45.0, 24.0 ] ]

bi.mean
#  => [ [  3.0,  5.0,  6.5 ],     right column tiles average 2 cells
#       [ 13.0, 15.0, 16.5 ],
#       [ 20.5, 22.5, 24.0 ] ]    bottom-right tile is the single cell 24
```

`count_not_masked` shows how many real cells each tile actually folded, and
`elements` still reports the full structural size — so at a partial tile
`count_masked` (which counts the missing cells) is non-zero:

```ruby
bi.count_not_masked
#  => [ [ 4, 4, 2 ],              interior tiles hold 4, edge tiles fewer
#       [ 4, 4, 2 ],
#       [ 2, 2, 1 ] ]

bi.elements
#  => [ [ 4, 4, 4 ],             structural size — always the full tile
#       [ 4, 4, 4 ],
#       [ 4, 4, 4 ] ]

bi.count_masked
#  => [ [ 0, 0, 2 ],             elements - count_not_masked
#       [ 0, 0, 2 ],
#       [ 2, 2, 3 ] ]
```

### Requiring full tiles — `min_count:`

If you want a partial tile to report **no answer** rather than a value from too
few cells, pass `min_count:` — a tile with fewer present cells than that becomes
`UNDEF`. It passes straight through to the core reduction.

```ruby
CArray.int32(5, 5).seq.blocks(2, 2).mean(min_count: 4)
#  => [ [  3.0,  5.0, UNDEF ],
#       [ 13.0, 15.0, UNDEF ],
#       [ UNDEF, UNDEF, UNDEF ] ]
```

`fill_value:` is the companion knob — it replaces the would-be `UNDEF` cells with
a value instead. Both are accepted by `sum`, `prod`, `mean`, `min`, `max`,
`variance`, `stddev`, `variancep`, `stddevp`, and `minmax`.

### "Valid" pooling — slice first

If you would rather **drop** the remainder entirely and pool only over full
tiles (a floor grid), there is no boundary knob for it — express it explicitly by
slicing the source before you tile:

```ruby
a = CArray.int32(5).seq
a[0...4].blocks(2).sum
#  => [ 1.0, 5.0 ]               only the two full tiles, cell 4 discarded
```

## Masks

A masked source is passed straight through: each tile carries the mask, and the
per-tile reduction skips the masked cells exactly as it would on a whole array
(see [Masks and missing values](05_masks.md)).

```ruby
a = CArray.double(4, 4).seq
a[1, 1] = UNDEF

a.blocks(2, 2).mean
#  => [ [ 1.6666666666666667, 4.5 ],    top-left folds 3 present cells
#       [ 10.5,               12.5 ] ]

a.blocks(2, 2).count_not_masked
#  => [ [ 3, 4 ],
#       [ 4, 4 ] ]
```

To work on the raw stored values instead, strip the mask first with `.value`:

```ruby
a.value.blocks(2, 2).mean       # masked cell treated as its stored value
```

> **Order statistics and masks.** `median` / `percentile` / `quantile` do not yet
> accept a masked source; strip the mask with `.value` first if you hit that
> limitation.

## `map` — transform each tile, scatter back

`map` is the shape-preserving cousin of the reductions. The block receives each
tile and returns a same-shaped tile (or a scalar to broadcast); the transformed
tiles are scattered back into a **new array shaped like the source**. Because
tiles do not overlap, this is well-defined and unambiguous. The source is not
modified.

```ruby
a = CArray.double(4, 4).seq
a.blocks(2, 2).map { |tile| tile - tile.mean }    # centre each tile
#  => [ [ -2.5, -1.5, -2.5, -1.5 ],
#       [  1.5,  2.5,  1.5,  2.5 ],
#       [ -2.5, -1.5, -2.5, -1.5 ],
#       [  1.5,  2.5,  1.5,  2.5 ] ]
```

Each tile the block sees is a uniform `Π sz_i`-shaped CArray. At a partial edge
tile the out-of-bounds cells are masked (so the block always sees a full-shaped
tile), and when the result is scattered back those out-of-bounds cells are simply
dropped. Without a block, `map` returns an enumerator.

## `each` / `reduce` — the escape hatch

For a per-tile statistic not in the named surface, `each` and `reduce` hand you
each tile as a plain CArray and let you write the body in Ruby. This is the slow
path — it materialises each tile — so prefer a named reduction when one fits.

`reduce { |tile| … }` folds each tile to one value with the block:

```ruby
CArray.int32(4, 4).seq.blocks(2, 2).reduce { |tile| tile.max - tile.min }
#  => [ [ 5, 5 ],
#       [ 5, 5 ] ]              per-tile range
```

`reduce(init) { |acc, x| … }` fiber-folds each tile element by element, like
Ruby's `Enumerable#inject` (masked cells are skipped). `each { |tile| … }` runs
the block for side-effects and returns `self`; without a block it returns an
enumerator.

At a partial edge tile these forms see a uniform full-shaped tile whose
out-of-bounds cells are masked — you never get a ragged shape, the remainder is
absorbed into the mask.

## A leading offset

Any tile size may be given as a `lo..hi` **range** instead of an integer. The
range's length is the tile size and its start is a leading offset applied before
tiling — the cells before `lo` on that axis are skipped:

```ruby
CArray.int32(6).seq.blocks(1..2).sum   # offset 1, tile size 2
#  => [ 3.0, 7.0, 5.0 ]                # skip cell 0, tile [1,2] [3,4] [5]
```

The plain integer form `blocks(2)` is the common case (offset `0`); the range
form is there when you need to align tiles to a boundary other than the start.

## Method reference

Built with `a.blocks(sz0, sz1, …)` — one tile size per axis (an Integer, or a
`lo..hi` Range whose length is the size and whose start is a leading offset).
The output is the ceil tile grid; every reduction returns a grid-shaped CArray
unless noted.

| method | what it returns per tile |
|---|---|
| `sum` | sum of the tile's cells |
| `prod` | product |
| `mean` | mean |
| `min` / `max` | minimum / maximum |
| `minmax` | `[min, max]` — two grids, one fused pass |
| `variance` / `stddev` | sample variance / standard deviation |
| `variancep` / `stddevp` | population variance / standard deviation |
| `all` / `any` | boolean fold (needs a boolean payload) |
| `median` | median |
| `percentile(*p)` | percentile(s) — one grid, or an array of grids for several `p` |
| `quantile` | five-number summary `[min, Q1, median, Q3, max]` (five grids) |
| `min_index` / `max_index` | tile-local flat position of the winner |
| `wsum(weights)` | weighted sum (`weights` shaped like one full tile) |
| `wmean(weights)` | weighted mean |
| `count` | present-cell count (same as `count_not_masked`) |
| `count(v)` | count of cells equal to `v` (`count(UNDEF)` counts masked cells) |
| `count_not_masked` | count of present cells (fewer at a partial edge tile) |
| `count_masked` | count of masked cells (`elements - count_not_masked`) |
| `elements` | structural tile size `Π sz_i` (mask-independent) |
| `map { \|tile\| … }` | per-tile transform scattered back to a source-shaped array |
| `each { \|tile\| … }` | run the block per tile for side-effects; returns `self` |
| `reduce { \|tile\| … }` | custom per-tile fold to one value |
| `reduce(init) { \|acc, x\| … }` | per-tile element-by-element fold |
| `source` | the array being tiled (leading offset already applied) |
| `shape` / `ndim` | the tile-grid shape / its rank |

Reduction keywords (accepted by `sum`, `prod`, `mean`, `min`, `max`,
`variance`, `stddev`, `variancep`, `stddevp`, `minmax`):

| keyword | effect |
|---|---|
| `min_count:` | a tile with fewer present cells than this becomes `UNDEF` |
| `fill_value:` | replace a would-be `UNDEF` tile with this value |

## Where block iteration fits

`blocks` is one member of the [iterator family](21_iterator_family.md) — the same
reduction names (`sum`, `mean`, `minmax`, `median`, the count family, `map`,
`each` / `reduce`) appear on every member, and each differs only in what a
*piece* is. Reach for the block iterator when you want to **pool or downsample**
into non-overlapping tiles; for a rolling statistic use the
[window iterator](22_window_iteration.md), and for a statistic per row or column
of the full extent use the [slab iterator](11_slab_iteration.md).
