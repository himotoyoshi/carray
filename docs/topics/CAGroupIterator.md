# CAGroupIterator — group a grid by its axis coordinates

`CAGroupIterator` reduces a grid array **by the coordinates of its axes**: you
classify one or more axes with a [`CACategorical`](../objects/CACategorical.md) and get one
result per group, with any other axes preserved. It is the grid-shaped cousin of
[`CACategoricalIterator`](CACategoricalIterator.md) — where that groups a flat
payload by a parallel array of keys, this groups an N-D array along chosen axes
and keeps the rest.

It is a member of the [iterator family](IteratorFamily.md); its reduction
surface is the family surface, with two differences noted below (`axis: :group`
is required, and it offers `min_addr` rather than `min_index`).

## The one thing to remember

Three steps, and one keyword:

```ruby
require "carray"

# data[station, month] — 4 stations, 6 months
data  = CArray.float64(4, 6) { |s, m| 10 + s + m }

# classify the month axis into seasons (a rank-1 categorical over that axis)
month = CA_INT32([0, 0, 1, 1, 2, 2])          # 6 months -> 3 seasons
season = month.categorize                     # labels [0, 1, 2]

g = data[nil, season]                         # nil = keep axis 0, group axis 1
g.mean(axis: :group)                          # => [4, 3]  per (station, season) mean
```

- **Index the array** with a categorical in the slot of each axis you want to
  group, and `nil` in the slot of each axis you want to keep (a *band* axis).
  Every axis must be given a slot.
- **Call a reduction with `axis: :group`.** This is the one keyword that turns
  the grouping on. (Without it the value is reduced plainly, ignoring the
  grouping — the same indexer can also do ordinary selection, so the grouping is
  opt-in.)

The result is **slot order**: each group slot becomes an axis of length `k` (the
number of categories), each band slot keeps its length. Above, slot 0 (station)
is kept at length 4 and slot 1 (month → season) becomes length 3, so the result
is `[4, 3]`.

`g.labels` gives the coordinate labels of the result (a group axis carries its
category labels, a band axis its integer index) without materialising the full
tuple table.

## The reductions

The full [family surface](IteratorFamily.md#the-common-surface) is available,
all taking `axis: :group`:

```ruby
g.sum(axis: :group)          g.mean(axis: :group)      g.min(axis: :group)
g.variance(axis: :group)     g.stddev(axis: :group)    g.minmax(axis: :group)
g.wsum(w, axis: :group)      g.wmean(w, axis: :group)
g.median(axis: :group)       g.percentile(90, axis: :group)   g.quantile(axis: :group)
g.count(axis: :group)        g.count_masked(axis: :group)     g.elements(axis: :group)
g.min_addr(axis: :group)     g.max_addr(axis: :group)
```

Each result matches the core `CArray` reduction over each group's members, so
the empty / all-masked contract carries through: `sum` of an empty group is `0`
(identity), `mean` / `median` of an empty group is a masked (`UNDEF`) cell.
Excluded cells — a value whose category code is masked or out of vocabulary —
join no group.

**Position: `min_addr` / `max_addr`, not `min_index`.** A group preserves source
order, so a *within-group* index is weak; the group returns the **flat source
address** of the winning cell instead, which you can index back into the raveled
source:

```ruby
data.reshape(data.elements)[g.min_addr(axis: :group)]   # the group minima
```

`min_index` / `max_index` are not provided on this iterator: `respond_to?` is
`true` (they are declared on the [iterator family](IteratorFamily.md)), but
calling `g.min_index(axis: :group)` raises `NotImplementedError`. This is the one
place the group iterator differs from the rest of the family — see the
[family differences](IteratorFamily.md#where-the-members-differ).

## Segment scans (the scan sibling)

Where a reduction **collapses** each group to one value, a *scan* keeps the
source shape and writes each cell its group's **running** statistic up to and
including that cell:

```ruby
g.cumsum(axis: :group)    g.cumprod(axis: :group)
g.cummax(axis: :group)    g.cummin(axis: :group)
g.cumcount(axis: :group)
```

The running value accumulates in **row-major position order along the grouped
axes** (per band). A cell's category picks its group; the scan of that group is
inclusive of the cell. This is the **per-group version of the core `CArray`
scan**, and it follows the same conventions: a cell **masked within its group**
holds the running value (its output is **not** masked) — for `cumsum` /
`cumprod` / `cumcount` always, for `cummax` / `cummin` once a member has been
seen. Only two cases are `UNDEF`: a cell **excluded from every group** (its
category code out of vocabulary or masked), and a `cummax` / `cummin` cell whose
group has **no member yet** (an empty extremum has no value — the same reason an
empty-group `max` reduces to `UNDEF`).

```ruby
# per-station running total through the year, kept in the [station, month] grid
data[station, nil].cumsum(axis: :group)
# 1-based running count of present (non-masked) cells within each group
data[station].cumcount(axis: :group)
```

The output data type follows the reduce siblings: `cumsum` / `cumprod` are `float64` (the
running value grows, so integer-preserving sums are a deliberate non-goal, as on
the reduce side); `cummax` / `cummin` **preserve the source data type** (extrema do
not grow magnitude — `int` stays `int`); `cumcount` is `int64`, 1-based (running
count of present cells, inclusive). An `object` source produces an `object`
result for `cumsum` / `cumprod` / `cummax` / `cummin` (`cumsum` / `cumprod` seed
the empty group with `0` / `1`; `cummax` / `cummin` seed from the first member),
and `int64` for `cumcount`.

A scan cannot fold a band **into** the statistic (`axis: [:group, k]`) — that
would collapse an axis, and a scan preserves the source shape. Without
`axis: :group` each delegates to the value's same-named scan.

## Grouping shapes

The same surface works for progressively richer groupings — they all reduce to
one *composite* classification internally, so you do not learn a new API.

**One group axis, no kept axes** (a flat grouping) — every result is a length-`k`
vector, exactly the categorical sibling:

```ruby
temps[station].mean(axis: :group)             # mean per station-class
```

**Group axes + band axes** (the common grid case) — kept axes ride through:

```ruby
data[nil, season].mean(axis: :group)          # [station, season]
```

**Several group axes (a composite)** — group by more than one classification at
once; the result has one axis per group slot:

```ruby
data[station_class, season].mean(axis: :group)   # [n_class, n_season]
```

**A rank-N categorical** — a single categorical built from an N-D map (e.g. a
`[nlon, nlat]` region map) consumes several source axes and collapses them into
**one** group axis:

```ruby
region = region_map.categorize                # region_map is [nlon, nlat]
grid[nil, region].mean(axis: :group)          # [time, n_region]
```

Composite and rank-N groupings support the value reductions, the order
statistics, and generic iteration alike. The only combination not yet supported
is folding a band axis *into* an order statistic (`axis: [:group, k]`) — that
would gather a group axis and a band axis into a single statistic, a different
operation.

## Generic iteration and order statistics

`each` / `map` / `reduce` / `sort_addr` and the order statistics
(`median` / `percentile` / `quantile`) need every member of a group held
together, so they *materialise* — but the group iterator keeps its
**peak-memory** promise: a band grouping materialises **one band position at a
time** (peak = the size of one group block, never a whole-array copy).

Unlike the named reductions, `each` / `map` / `reduce` take **no** `axis: :group`
— they have no plain form, so they always group:

```ruby
g.reduce { |members| members.max - members.min }   # custom per-group stat, slot-shaped
g.map    { |members| members - members.mean }      # centre within each group, source-shaped
g.each   { |members| … }                           # inspect each group
```

## How it fits together

- [`CACategorical`](../objects/CACategorical.md) — the classifier: dense integer codes plus
  a label vocabulary, built by `keys.categorize` (or `CACategorical.from_codes`).
  A rank-1 categorical classifies one axis; a rank-N one classifies several.
- `CArray#axis_group(cat, nil, …)` builds an **`AxisGroup`** — a value-independent
  grouping spec (a shape template), so one spec can drive many arrays.
- Indexing an array with categorical / `nil` slots (`value[cat, nil]`) is the
  shorthand that builds the spec and returns the `CAGroupIterator`.
- `g.labels` returns a **`GroupLabels`** view — the coordinate labels of the
  result, factorised (never a materialised tuple table).

Internally the value reductions **scatter** (peak O(1), the C engine in
`ext/ca_axis_group.c`); the order statistics and iteration **materialise** one
group block at a time (Ruby, `lib/carray/axis_group.rb`). Both go through one
composite categorical over the grouped axes, so every grouping shape shares the
same code path.
