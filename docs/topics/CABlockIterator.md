# CABlockIterator — non-overlapping tile reductions and pooling (`blocks`)

`a.blocks(*sizes)` returns a **`CABlockIterator`** that tiles `a` into
**non-overlapping** blocks of a fixed per-axis size and folds each tile to one
value. The result is a **tile grid** — one cell per tile — so this is the
pooling / downsampling / block-statistics member of the family: `mean` is
average pooling, `max` is max pooling, and so on.

It is the **block member of the 3.0 iterator family**, a sibling of
[`CASlabIterator`](SlabIterator.md), [`CAWindowIterator`](CAWindowIterator.md)
and [`CACategoricalIterator`](CACategoricalIterator.md). Where a window iterator
folds an *overlapping* window per anchor cell, a block iterator folds each
*disjoint* tile once.

```ruby
require "carray"

a = CArray.int32(4, 4).seq            # 0..15 in a 4×4 grid

a.blocks(2, 2).mean                   # 2×2 average pooling -> a 2×2 grid (mean promotes to float)
#=> [[ 2.5,  4.5],
#    [10.5, 12.5]]

a.blocks(2, 2).max                    # 2×2 max pooling
#=> [[ 5,  7],
#    [13, 15]]
```

## How the engine works

The source is split into regions and each region is reduced by a **`block_view`**
— a zero-copy strided view of the tiles — over its trailing tile axes:

- the **interior** (the size-divisible part of every axis) is one `block_view`
  laid **directly over the source** (no copy; it rides the CAStride compose-fold
  path), reduced in a single vectorized core pass;
- each **boundary region** (a partial edge tile, see [remainder](#the-remainder-is-not-your-concern))
  is a smaller `block_view` of the same kind.

Because tiles do **not** overlap, the interior never has to be materialized (a
window iterator, whose windows overlap, must build a padded copy — a block
iterator does not). A named reduction therefore inherits the core data type / mask
/ empty / epsilon contracts unchanged, and runs at core-reduction speed
regardless of how many tiles there are — see [performance](#performance).

## Construction

```ruby
a.blocks(b0, b1, ...)      # integer tile size per axis (offset 0)
a.blocks([b0, b1, ...])    # ... or one Array of sizes
a.blocks(lo..hi, ...)      # a range: size = hi - lo + 1, start = lo (a leading offset)
```

Give one size (or range) per axis. A range block spec carries both a **size**
(its length) and a **leading offset** (its start), kept for compatibility with
2.0:

```ruby
CArray.int32(10).seq.blocks(2..4).sum   # size-3 tiles starting at index 2
#=> [9, 18, 17]                          # (2+3+4), (5+6+7), (8+9)
```

The offset is absorbed by a zero-copy pre-slice, so the tiling below always
starts at index 0.

## The remainder is not your concern

When an axis length is not a multiple of the tile size, the leftover cells are
**covered by a present-only edge tile** — the tile grid is the *ceil* of the
division, and a partial edge tile simply folds the cells it has. There is no
boundary-policy knob: full coverage is the sole behaviour, and the remainder is
absorbed into the mask.

```ruby
CArray.float64(7).seq.blocks(3).mean    # tiles [0,1,2], [3,4,5], [6]
#=> [1.0, 4.0, 6.0]                       # the last tile averages its one cell
```

- **Every cell belongs to exactly one tile.** The grid shape is
  `ceil(Nᵢ / bᵢ)` per axis.
- **`each` / `reduce` yield a uniform `b0×b1×…` tile** whose out-of-bounds cells
  are **masked**, so you never see a ragged shape — the remainder shows up as a
  mask, which reductions skip.
- **`min_count:` gives you "full tiles only".** A partial edge tile has fewer
  than a full tile's cells, so the core reduction marks it `UNDEF`:

  ```ruby
  CArray.float64(7).seq.blocks(3).mean(min_count: 3)
  #=> [1.0, 4.0, UNDEF]                    # the 1-cell edge tile is undefined
  ```

- **Valid pooling** — drop the remainder and keep only complete tiles (a *floor*
  grid) — is an explicit pre-slice, not a knob:

  ```ruby
  a[0...6, 0...6].blocks(3, 3)             # a 7×7 source, complete 3×3 tiles only
  ```

## Named reductions

Each named reduction folds every tile to one value and returns a tile-grid-shaped
array:

| family | methods |
|---|---|
| arithmetic | `sum` `prod` `mean` |
| extrema | `min` `max` `minmax` |
| spread | `variance` `stddev` (sample) · `variancep` `stddevp` (population) |
| boolean | `all` `any` |
| position | `min_index` `max_index` (flat index within the tile) |
| weighted | `wsum(weights)` `wmean(weights)` (weights shaped like one full tile) |
| order statistics | `median` `percentile(*p)` `quantile` |
| counting | `count` / `count_not_masked` / `count_masked` / `count(v)` · `elements` |

- `elements` is the (constant) tile size `Π bᵢ`; `count_not_masked` is the number
  of real cells in a tile (fewer at a partial edge). The invariant
  `elements = count_not_masked + count_masked` holds per tile, the masked count
  being the out-of-bounds cells of an edge tile.
- All reductions accept `min_count:` / `fill_value:`, passed straight to the core.
- `min_index` / `max_index` return the position **within the tile** (a flat index
  into its cells).
- `wsum` / `wmean` take a weight kernel shaped like one full tile; at a partial
  edge tile the kernel is sliced to the present cells.
- Order statistics take a single axis in the core, so a 1-D tile delegates
  directly and a multi-axis tile is materialized per region and its tile axes
  flattened into one before the core call.

## `map`, `each`, `reduce`

Because the tiles are disjoint, an element-wise transform has a well-defined
scatter-back, so — unlike a window iterator — a block iterator **has `map`**:

```ruby
img = CArray.float64(4, 4).seq
img.blocks(2, 2).map { |tile| tile - tile.mean }   # subtract each tile's mean
#=> a new source-shaped CArray (the source is not modified)
```

`map` applies the block to each tile and scatters the result back into a
source-shaped array (the out-of-bounds cells of a partial edge tile are dropped).

`each` / `reduce` are the generic escape hatch for a statistic not in the named
surface (they yield each tile, so they are the slow, general path):

```ruby
a.blocks(2, 2).each { |tile| ... }               # side effects; Enumerator with no block
a.blocks(2, 2).reduce { |tile| tile.max - tile.min }   # a tile-grid result
```

`reduce { |tile| ... }` folds each tile to one value; `reduce(init) { |acc, x| ... }`
is the element-wise fold. Each yielded tile is a uniform `b0×b1×…` CArray with
out-of-bounds cells masked.

## Winner address and sorting

Because tiles do not overlap, every tile cell is a real source cell, so the
source-address surface is available (as it is for a slab):

- **`min_addr` / `max_addr`** — the flat *source* address of a tile's winning
  cell (tile-grid shaped), so `source.reshape(source.elements)[bi.min_addr]` are
  the tile minima. Unlike `min_index` / `max_index` (the within-tile position)
  these index back into the original array. An all-masked tile is a masked cell.
- **`sort_addr`** — a per-tile sort returning source addresses, *source-shaped*:
  each tile's cells hold that tile's source addresses in ascending-value order
  (reading the tile row-major gives the sorted addresses). Multi-axis tiles are
  flattened, and a partial edge tile sorts only its present cells.

## Migration from 2.0

In 2.0, `a.blocks(...)` walked a `CABlock` kernel over the source: `.each`
yielded a `CABlock`, the iterator carried an indexed-kernel surface
(`it[i]` / `pick` / `put` / `kernel_at_addr`), and a non-dividing remainder was
**silently truncated**. In 3.0:

- `.each` yields a **tile (a CArray)**, not a `CABlock`; the indexed-kernel
  surface is gone — use the named reductions or `each` / `map` / `reduce`;
- the **remainder is covered** (present-only edge tiles, ceil grid) instead of
  truncated — for the old behaviour slice first (`a[0...q*b].blocks(b)`).

## Performance

The 3.0 engine replaces 2.0's per-tile kernel walk (relocate the kernel,
materialize one tile, reduce it — once per tile) with a single vectorized core
reduction over a zero-copy `block_view`. The 2.0 cost grows with the **number of
tiles** (a per-tile dispatch each); the 3.0 cost tracks the element count and is
almost insensitive to tile count.

Measured with `a.blocks(...).mean` (average pooling), median of 7 samples
(20 iters each, warm-up + GC between samples). Absolute numbers are
machine-specific; the **ratios** are the point, and both engines return identical
results:

| case | tiles | 2.0 (C kernel walk) | 3.0 (`block_view`) | speed-up |
|---|---:|---:|---:|---:|
| 1-D 2000, tile 4 | 500 | 0.210 ms | 0.007 ms | ~30× |
| 2-D 600×600, tile 4×4 | 22,500 | 8.577 ms | 0.350 ms | ~24× |
| 2-D 1000×1000, tile 10×10 | 10,000 | 4.073 ms | 0.275 ms | ~15× |
| 2-D 600×600, tile 20×20 | 900 | 0.424 ms | 0.061 ms | ~7× |

The gap widens as tiles get smaller (more tiles = more 2.0 per-tile dispatch
overhead) and narrows for few, large tiles (where per-element reduction work
dominates on both engines).

## See also

- [`IteratorFamily.md`](IteratorFamily.md) — the shared iterator surface and how the members differ.
- [`CAWindowIterator.md`](CAWindowIterator.md) — the overlapping-window sibling.
- [`SlabIterator.md`](SlabIterator.md) — the per-axis slab sibling.
