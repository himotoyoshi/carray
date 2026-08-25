# Sort, search, and interpolation

This chapter covers the ordering, searching, and table-lookup methods. They
share a family resemblance: most of them take `axis:` and operate **per slab**
— each row (or column, or whichever axis you pick) is processed independently —
and most of them return *positions* (addresses into an array) rather than
values, so they compose with the indexer (see
[Indexing and slicing](02_indexing_and_slicing.md)) for round-trip workflows.

A recurring convention: a **miss** — a query with no answer — comes back as
`UNDEF` (masked), not as a sentinel number. That lets missing-ness propagate
through any arithmetic you do next; see [Masks and missing values](05_masks.md).

## Sorting

`sort(axis:)` returns a per-axis sorted **view**; the original is untouched
(see [Views](06_views.md) for why a sort is a view). Use `sort_copy(axis:)`
when you want an independent, materialised array instead of a view — it is
cheaper than `sort(axis:).copy` and clearer in intent.

```ruby
m = CA_INT([[3, 1, 4, 1, 5],
            [9, 2, 6, 5, 3]])

m.sort(axis: 1)
#  => [ [ 1, 1, 3, 4, 5 ],
#       [ 2, 3, 5, 6, 9 ] ]

m.sort_copy(axis: 1)
#  => [ [ 1, 1, 3, 4, 5 ],
#       [ 2, 3, 5, 6, 9 ] ]    an owned entity, not a view
```

`sort_index(axis:)` returns the axis-local **positions** that would sort each
slab, rather than the sorted values themselves — the CArray spelling of what
some libraries call `argsort` (CArray uses the `_index` suffix throughout;
there is no `argsort`).

```ruby
m.sort_index(axis: 1)
#  => [ [ 1, 3, 0, 2, 4 ],
#       [ 1, 4, 3, 2, 0 ] ]
```

The point of the index form is that you can use it to reorder a *parallel*
array — labels, weights, anything that lives in lock-step with `m`:

```ruby
labels = CA_INT([[10, 20, 30, 40, 50],
                 [10, 20, 30, 40, 50]])
idx    = m.sort_index(axis: 1)

labels[idx]
#  => [ [ 20, 40, 10, 30, 50 ],
#       [ 20, 50, 40, 30, 10 ] ]    labels reordered by m's per-row sort
```

When `idx` has the same leading axes as `labels`, the trailing axis is treated
as the position within each slab. `labels.project(idx)` is the named form of
the same `labels[idx]` operation, and reads more clearly in a method chain.

## Selecting by rank

### `partition_index` — the k-th element without a full sort

`partition_index(k, axis:)` returns the positions of a permutation in which the
k-th smallest element sits at position `k` of each slab: everything before
position `k` is no larger than it, everything after is no smaller. It is much
cheaper than a full sort when you only care about a small `k` (a top-K or a
median split).

```ruby
v = CA_INT([7, 3, 8, 1, 5, 2, 6, 4])

idx = v.partition_index(3, axis: 0)
#  => [ 3, 5, 1, 7, 4, 6, 0, 2 ]    positions of a partitioned permutation

v.project(idx)
#  => [ 1, 2, 3, 4, 5, 6, 7, 8 ]
#       ^^^^^^^^^^^^  4 is at position 3, the k-th smallest; before it sit the
#                     three smallest (in some order), after it the rest
```

Only the pivot guarantee holds — positions `[0..k-1]` ≤ `v.project(idx)[k]` ≤
positions `[k+1..]`. The exact order within each side depends on the algorithm.

### `rank_index` — the rank of each cell

`rank_index` gives the rank of each cell within its slab — `0` for the
smallest, `1` for the next, and so on. It is the natural building block for
percentile / quantile work.

```ruby
v = CA_INT([3, 1, 4, 1, 5])
v.rank_index
#  => [ 2, 0, 3, 1, 4 ]    3 is third-smallest; the two 1s rank 0 and 1
```

## Searching

### `bsearch` — binary search of a sorted array

`bsearch(query)` performs a binary search of each query value in self, which
must be sorted. Misses come back as `UNDEF` (masked), so the missing-ness
propagates through any downstream arithmetic:

```ruby
prices  = CA_INT([100, 200, 300, 400, 500])    # sorted
queries = CA_INT([200, 250, 400])

prices.bsearch(queries)
#  => [ 1, _, 3 ]    250 is not present → masked
```

For 2-D input, `axis:` chooses the search axis; the query is searched in each
slab. The result shape is the source shape with the search axis replaced by the
query length, and misses are masked the same way:

```ruby
m = CA_INT([[10, 20, 30, 40],
            [ 5, 15, 25, 35]])    # each row sorted

m.bsearch(CA_INT([25, 12]), axis: 1)
#  => [ [ _, _ ],
#       [ 2, _ ] ]    only row 1 contains 25
```

### `search` — linear scan of an unsorted array

`search(query, axis:)` does the same as `bsearch` but with a linear scan, so it
works when self is *not* sorted. Misses are masked just as in `bsearch`. Use
`bsearch` when self is sorted; `search` when it is not.

### `search_nearest` — closest cell, never a miss

`search_nearest(query, axis:)` always returns a valid position: the index of
the closest cell. There is no miss, so the output is never masked.

```ruby
grid = CA_DOUBLE([0.0, 1.0, 2.0, 4.0, 8.0])
qs   = CA_DOUBLE([0.4, 1.6, 3.0, 100.0])

grid.search_nearest(qs, axis: 0)
#  => [ 0, 2, 2, 4 ]    closest grid index for each query
```

## Linear interpolation

`linear_section` and `linear_fetch` are a complementary pair built around one
idea — the **fractional address**. A value's fractional address says *where
between two array positions it lies*: `2.5` means "halfway between element 2
and element 3". The one takes a value and returns its fractional address; the
other takes a fractional address and returns the interpolated value; and
because they are exact inverses on a monotone grid, chaining them does 1-D
piecewise-linear interpolation in one line.

```ruby
grid = CA_DOUBLE([0.0, 1.0, 2.0, 4.0, 8.0])

grid.linear_section(3.0)   # => 2.5     (3.0 is halfway between grid[2]=2 and grid[3]=4)
grid.linear_fetch(2.5)     # => 3.0     (back again)
```

### The canonical use — interpolate `y` at an arbitrary `x`

The pair earns its keep when you have two arrays sampled on the same grid —
an independent variable `x` and a dependent variable `y` — and you want `y`
at an `x` that falls between sample points. Two steps: find the fractional
address of the query along `x`, then read `y` at the same address.

```ruby
xs = CA_DOUBLE([10.0, 20.0, 30.0, 40.0, 50.0])   # the grid (monotonic)
ys = CA_DOUBLE([ 1.0,  4.0,  9.0, 16.0, 25.0])   # values on that grid

frac = xs.linear_section(35.0)   # => 2.5   (35 is halfway between xs[2] and xs[3])
ys.linear_fetch(frac)            # => 12.5
```

Piecewise-linear interpolation, decomposed into a **search** and a **gather**.
Keeping them separate is what lets each side vectorise independently over
whole arrays of queries and over array axes.

### `linear_section` — value to fractional address

`linear_section(val)` returns the fractional address `pos` such that linearly
interpolating between `grid[floor(pos)]` and `grid[floor(pos) + 1]` gives
back `val`. Both ascending and descending monotonic grids work:

```ruby
grid = CA_DOUBLE([0.0, 1.0, 2.0, 4.0, 8.0])
grid.linear_section(CA_DOUBLE([1.5, 3.0, 7.0]))
#  => [ 1.5, 2.5, 3.75 ]

d = CA_DOUBLE([10.0, 6.0, 3.0, 1.0, 0.0])
d.linear_section(4.0)       #  => 1.666...   (between d[1]=6 and d[2]=3)
```

Two search strategies compute the *same function* — pick by cost:

```ruby
grid.linear_section(3.0, method: :binary)   # default, O(log n) with O(1) fast
                                            #  path for equispaced grids
grid.linear_section(3.0, method: :linear)   # sequential scan, O(n)
```

Reach for `:linear` on a short grid or when a simple scan reads better than
a dispatch to binary search; the results agree exactly on every input. An
unknown `method:` raises.

The grid **must be monotonic** (ascending or descending). Interpolation on
non-monotonic data is undefined — no error is raised; you simply get the
bracket the search happens to land on.

### `linear_fetch` — fractional address to value

`linear_fetch(pos)` reads a value at a fractional position by blending the two
neighbouring elements:

```ruby
grid.linear_fetch(CA_DOUBLE([0.5, 1.5, 3.5]))
#  => [ 0.5, 1.5, 6.0 ]

grid.linear_fetch(2.5)     # => 3.0    (halfway between grid[2]=2 and grid[3]=4)
grid.linear_fetch(4.0)     # => 8.0    (n-1 is the last valid address)
```

### Out of range means no answer

Neither method extrapolates. A query outside the grid, or an address outside
`0..n-1`, has no interval to interpolate against, so:

```ruby
grid.linear_section(CA_DOUBLE([-100.0, 3.0, 1000.0]))
#  => [ NaN, 2.5, NaN ]

grid.linear_fetch(CA_DOUBLE([-1.0, 2.0, 100.0]))
#  => [ NaN, 2.0, NaN ]
```

In the array form the miss is `NaN`; in the 1-D scalar shortcut (a 1-D
`self` with a scalar query) it is `nil` instead. Either way the whole family
obeys one rule — **out of range → no answer, never extrapolate** — and the
domains of `linear_section` and `linear_fetch` match exactly, so values flow
through a `linear_section → linear_fetch` chain without a single range check
in your own code.

Lift the misses into the mask when downstream work should skip them:

```ruby
grid.linear_fetch(CA_DOUBLE([-1.0, 2.0, 100.0])).mask_invalid
#  => [ _, 2.0, _ ]
```

### Per-fiber interpolation over an axis

Both methods take an `axis:` keyword. Without it the array is flattened into
one 1-D sequence; with it the operation runs once per fiber, keeping every
other axis as an independent problem and consuming the named axis.

```ruby
g  = CA_DOUBLE([[0, 1, 2, 3],
                [0, 2, 4, 6]])
qs = CA_DOUBLE([1.5, 3.0])

g.linear_section(qs, axis: 1)
#  => [ [ 1.5,  3.0 ],
#       [ 0.75, 1.5 ] ]    each row interpolated against its own grid
```

This is the pattern for keeping a different lookup table per row — per-
distribution sampling, per-channel calibration, per-column regridding.
Negative axes count from the end (`axis: -1` is the last axis).

### Broadcast layouts of the query array

When the query itself is a CArray, four broadcast layouts are accepted,
picked by matching the query's shape against the array's *base shape* (every
axis except the searched one). Take `self` of shape `[4, 5, 6]` and
`axis: -1` — so the searched axis has length 6 and the base shape is
`[4, 5]`:

| layout   | query shape        | meaning                                   | result shape      |
|----------|--------------------|--------------------------------------------|-------------------|
| **A1**   | scalar             | one query for every fiber                  | `[4, 5]`          |
| **A2**   | `[M]` (1-D)        | the same `M` queries broadcast per fiber   | `[4, 5, M]`       |
| **A2.5** | `[4, 5]`           | one distinct query per fiber               | `[4, 5]`          |
| **A3**   | `[4, 5, M]`        | `M` distinct queries per fiber             | `[4, 5, M]`       |

```ruby
self_3d = CArray.float64(4, 5, 6) { |i, j, k| k.to_f }

self_3d.linear_fetch(2.5, axis: -1).shape          #  => [4, 5]        (A1)
self_3d.linear_section(CA_DOUBLE([1.5, 3.0, 4.5]),
                       axis: -1).shape             #  => [4, 5, 3]     (A2)

val = CArray.float64(4, 5) { |i, j| ((i + j) % 6).to_f }
self_3d.linear_fetch(val, axis: -1).shape          #  => [4, 5]        (A2.5)

val = CArray.float64(4, 5, 3) { |i, j, m| (m * 2 + 0.5).to_f }
self_3d.linear_fetch(val, axis: -1).shape          #  => [4, 5, 3]     (A3)
```

A3 is the workhorse for regridding: each `(i, j)` column of `self` is a
profile, `val[i, j, :]` are the `M` target positions for that column, and
one call produces the interpolated value of every target in every column
with no Ruby-level loop.

A2.5 needs a base shape with at least 2 axes (so it can't be confused with
A2 broadcast). For a 2-D `self` where you want one query per fiber, make
that intent explicit by reshaping the query to `[N, 1]` — which falls into
A3 with `M = 1`.

### Data types, masks, and return values

Everything computes in `Float64`. An integer (or other numeric) `self` is
coerced automatically; the result is always `Float64`:

```ruby
CA_INT64([0, 1, 2, 3, 4]).linear_section(2.5)   # => 2.5
```

A **masked cell in `self`** makes the monotonic grid ill-defined, so a
masked `self` is rejected outright:

```ruby
y = CA_DOUBLE([0.0, 1.0, 2.0]); y[1] = UNDEF
y.linear_section(1.0)   # => raises RuntimeError
```

If you need to interpolate across gaps, close them first — fill the mask
with `strip_mask(fill_value)`, or rebuild the grid from the unmasked entries
so it is contiguous and monotonic before calling these methods.

### Quick reference

```ruby
# value -> fractional address
arr.linear_section(value)                    # scalar or CArray query
arr.linear_section(value, method: :linear)   # :binary (default) | :linear
arr.linear_section(query, axis: k)           # per-fiber

# fractional address -> value
arr.linear_fetch(address)
arr.linear_fetch(query, axis: k)

# interpolate y on grid x at an arbitrary x_query
ys.linear_fetch(xs.linear_section(x_query))
```

| concern                     | behaviour                                     |
|-----------------------------|-----------------------------------------------|
| grid requirement            | monotonic ascending or descending             |
| out of range (whole family) | `nil` (scalar) / `NaN` (array); no extrapolation |
| `:binary` vs `:linear`      | same function, different cost                 |
| default search              | `:binary` (`O(log n)`; `O(1)` for equispaced grids) |
| compute / result type       | `Float64` (inputs coerced)                    |
| masked `self`               | raises                                        |
| `axis:`                     | per-fiber; named axis consumed; negatives allowed |

## Locating addresses in a reference array

`locate_addr(ref)` gives, for each element of self, the flat address into `ref`
where the value lives, or `UNDEF` where it is not present. Internally it sorts
`ref` once, `bsearch`es each query, then permutes the answer back so the result
maps into `ref`'s original layout.

```ruby
ref  = CA_INT([10, 20, 30, 40, 50])
mine = CA_INT([30, 50, 99])

addr = mine.locate_addr(ref)
#  => [ 2, 4, _ ]    99 is not in ref → UNDEF
```

`locate_nearest_addr(ref, direction: :round, tolerance: nil)` is the continuous
sibling: it uses `linear_section` + rounding for non-exact matching against a
sorted reference (`direction:` selects `:round` / `:floor` / `:ceil`). Pass
`tolerance:` to mask results whose distance `|ref[addr] - self|` exceeds the
given bound — useful when snapping observations onto a coarser reference axis,
where a far-away hit should be rejected rather than snapped:

```ruby
ref = CA_FLOAT64([10, 20, 30, 40, 50])
sel = CA_FLOAT64([15, 33, 100])

sel.locate_nearest_addr(ref)                   #  => [ 1, 2, _ ]
sel.locate_nearest_addr(ref, tolerance: 5.0)   #  => [ 1, 2, _ ]
sel.locate_nearest_addr(ref, tolerance: 4.0)   #  => [ _, 2, _ ]  # 15 rejected (|20-15| > 4)
```

### Reusing an address array

The point of returning bare addresses — rather than gathering values in one
shot — is that the same address array can drive many lookups:

```ruby
addr = obs_time.locate_addr(ref_time)   # compute once
model_temp[addr]                        # reuse
model_wind[addr]
model_rh[addr]
```

Each `ref`-shaped array reads back at the observation positions with no extra
sort or search.

### Scattering observations onto a reference grid

Pair `locate_addr` with `scatter_replace!` to fill a reference-shaped grid with
sparse observations in one chain:

```ruby
ref_hour  = CArray.int(24).seq                # 0..23 hourly slots
obs_hour  = CA_INT([3, 9, 18])                # scattered observation hours
obs_value = CA_DOUBLE([12.4, 18.7, 22.1])

addr = obs_hour.locate_addr(ref_hour)
grid = ref_hour.template(obs_value.data_type)
               .fill(UNDEF)
               .scatter_replace!(addr, obs_value)
# grid[3] = 12.4, grid[9] = 18.7, grid[18] = 22.1, all others UNDEF
```

Unmatched observations (`addr[i] == UNDEF`) skip the scatter automatically — no
filter step is needed. `scatter_replace!` is a fast path around
`grid[addr] = obs_value` that skips the intermediate `CAGrid` snapshot; its mask
policy matches the indexer (a masked `obs_value[i]` marks the target cell as
masked). Use `scatter_add!` instead when duplicate positions should accumulate
rather than overwrite.

## Method summary

| Method                          | Returns                                                    |
|---------------------------------|------------------------------------------------------------|
| `sort(axis:)`                   | Per-slab sorted **view**                                   |
| `sort_copy(axis:)`              | Per-slab sorted **entity** (owned copy)                    |
| `sort_index(axis:)`             | Positions that would sort each slab                        |
| `project(idx)`                  | Reorder self by an index array (named form of `self[idx]`) |
| `partition_index(k, axis:)`     | Positions of a k-th-element partition                      |
| `rank_index(axis:)`             | Rank (0 = smallest) of each cell within its slab           |
| `bsearch(query, axis:)`         | Binary search of a **sorted** array; miss → `UNDEF`        |
| `search(query, axis:)`          | Linear search of an **unsorted** array; miss → `UNDEF`     |
| `search_nearest(query, axis:)`  | Index of the closest cell; never a miss                    |
| `linear_section(val, axis:)`    | Value → fractional address; out of range → `NaN`           |
| `linear_fetch(pos, axis:)`      | Fractional address → interpolated value; out of range → `NaN` |
| `locate_addr(ref)`              | Address of each element within `ref`; miss → `UNDEF`       |
| `locate_nearest_addr(ref, …)`   | Nearest address within a sorted `ref`, with `tolerance:`   |
| `scatter_replace!(addr, src)`   | Scatter `src` into self at `addr` (overwrite)              |
| `scatter_add!(addr, src)`       | Scatter-add `src` into self at `addr` (accumulate)         |
