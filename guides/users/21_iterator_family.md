# The iterator family

CArray 3.0 has a family of five **iterators** that all answer the same
question — *"fold each piece of the array to a value"* — but disagree about
what a *piece* is. A piece can be a fiber along an axis, a sliding window, a
non-overlapping tile, the cells of one category, or a coordinate-classified
group. Once you can read one member you can read all of them, because they
share a single reduction surface: `mean`, `min`, `stddev`, `median`, `wsum`,
and the rest are spelled the same way everywhere.

This chapter is the map. It shows the one shared question, the common surface,
and where the members legitimately differ — then points you to the chapter that
covers each member in full.

## The five members

Every member takes a source array, decides what a piece is, and lets you
reduce each piece with the same method names. What changes from member to
member is how you build the iterator and the shape of the result.

| iterator | a *piece* is… | built by | output shape | chapter |
|---|---|---|---|---|
| `CASlabIterator` | a 1-D fiber along the marked axis | `a[nil, :>]` / `each_slab` | source shape minus the slab axis | [11](11_slab_iteration.md) |
| `CAWindowIterator` | an overlapping window per anchor | `a.windows(-1..1)` | reference-shaped (rolling) | [22](22_window_iteration.md) |
| `CABlockIterator` | a non-overlapping tile | `a.blocks(2, 2)` | tile grid (ceil) | [23](23_block_iteration.md) |
| `CACategoricalIterator` | the cells sharing one category | `value.group_by_category(cat)` | length-`k`, one per category | [24](24_categories_and_grouping.md) |
| `CAGroupIterator` | a coordinate-classified group | `value[cat, nil]` | group slots × preserved band axes | [24](24_categories_and_grouping.md) |

The intuition to hold onto: **choose a member by what a piece should be**, then
call the reduction you want. The engine underneath each member is different and
tuned for its own layout, but you never see that — you see the same surface.

```ruby
a = CArray.int32(2, 3).seq
#  => [ [ 0, 1, 2 ],
#       [ 3, 4, 5 ] ]

a[nil, :>].mean          # slab: per-row mean
#  => [ 1.0, 4.0 ]

a.blocks(2, 2).sum       # block: sum of each (up-to) 2x2 tile
#  => [ [ 8.0, 7.0 ] ]
```

## The form-only base

All five descend from `CAIterator`, a **form-only base**. It carries no engine
of its own — each member supplies its own. What the base declares is only two
things: the shared shape accessors (`shape` and `ndim`; `dim` is a legacy alias
for `shape`) and the list of reduction names every member is expected to
provide.

`CAIterator` deliberately does **not** `include Enumerable`. That is a design
decision, not an oversight. `Enumerable` would inject `min`, `max`, `sum`,
`count`, `to_a`, and friends — names that already mean something precise on this
surface. If `Enumerable#min` leaked in, `it.min` might silently compare *pieces*
against each other instead of folding *within* each piece, and you would get a
plausible-looking wrong answer with no error. So the family spells out its whole
surface explicitly and lets nothing slip in behind it.

The same principle governs the abstract methods. If a member has not
implemented a required reduction, calling it raises a clean
`NotImplementedError` naming the member — never a wrong answer:

```
CAWindowIterator does not provide #map (optional)
```

A loud failure you can read beats a quiet fold in the wrong direction.

## The common reduction surface

Every member provides the reductions below. This is the surface the two
reference members — `CASlabIterator` and `CACategoricalIterator` — both carry;
the others are held to the same list.

```
sum  accumulate  prod  mean  min  max                     # tier 1
variance  stddev  all  any
variancep  stddevp  minmax                                # tier 2
median  percentile  quantile                              # tier 3 (order statistics)
wsum  wmean                                               # weighted
count  count_not_masked  count_masked  elements           # count family
each  reduce                                              # generic iteration
```

Each of these is the **core CArray reduction lifted to the piece**. It is not a
new implementation with its own rules; it is exactly the reduction from
[Reduction and statistics](04_reduction_and_statistics.md), applied to one piece
at a time. So the piece reduction inherits, unchanged:

- **the same result data type** — `sum` on an integer source promotes to
  `float64` in the family exactly as the core `sum` does, and `accumulate` is
  the same fold kept in the source's own type, wrapping at its width;
- **the same mask handling** — masked cells are skipped, and if the piece
  carries a mask the reduction is mask-aware;
- **the same empty / all-masked contract** — a piece with no contributing cells
  yields the reduction's identity where one exists (`0` for `sum`, `1` for
  `prod`, `0` for `count`) and `UNDEF` where none does (`mean`, `min`, `max`,
  the ratios, the order statistics). See
  [Reduction and statistics](04_reduction_and_statistics.md);
- **the same ε-close numeric contract** — floating reductions are accurate to
  a small relative error, not bit-exact.

`all` / `any` require a boolean payload, just as `CArray#all` / `#any` do.

A few worked calls, on the slab member as the reference:

```ruby
d = CA_DOUBLE([[1, 2, 3, 4],
               [5, 6, 7, 8]])
it = d[nil, :>]                      # slab per row

it.wmean(CA_DOUBLE([1, 1, 2, 2]))    # weighted mean per row
#  => [ 2.8333333333333335, 6.833333333333333 ]

it.median                            # per-row median
#  => [ 2.5, 6.5 ]

it.count_not_masked                  # contributing cells per row
#  => [ 4, 4 ]

it.elements                          # cells per piece (mask ignored)
#  => [ 4, 4 ]
```

### The escape hatch: `each` and `reduce`

When the statistic you want is not in the named list, drop to `each` or
`reduce`. `each { |piece| … }` visits every piece (with no block it returns an
`Enumerator`, so `.map`, `.each_with_index`, and friends chain on). `reduce {
|piece| … }` folds each piece to one value with a block of your own:

```ruby
d[nil, :>].reduce { |row| row.max - row.min }   # per-row range
#  => [ 3.0, 3.0 ]

d[nil, :>].each.map { |row| row.sum }
#  => [10.0, 26.0]
```

`reduce(init) { |acc, e| … }` is the inject-style form: it feeds you each
element of the piece in turn.

## Where the members differ

The differences matter as much as the shared surface, and they all follow from
what a piece *is*.

| method | Slab | Window | Block | Categorical | Group |
|---|:--:|:--:|:--:|:--:|:--:|
| tier 1 / 2, `minmax`, `wsum` / `wmean` | ✓ | ✓ | ✓ | ✓ | ✓ |
| `median` / `percentile` / `quantile` | ✓ | ✓ ¹ | ✓ | ✓ | ✓ |
| count family, `elements`, `each` / `reduce` | ✓ | ✓ | ✓ | ✓ | ✓ |
| `min_index` / `max_index` (position **within** a piece) | ✓ | ✓ | ✓ | ✓ | — ² |
| `min_addr` / `max_addr` (flat **source** address of the winner) | ✓ | — ³ | — ³ | ✓ | ✓ |
| `map` (per-piece transform, scattered back) | ✓ | — ⁴ | ✓ | ✓ | ✓ |
| `sort_addr` (per-piece sort → source addresses) | ✓ | — ⁴ | — ³ | ✓ | ✓ |

1. Window order statistics need an unmasked margin (`bounds: :nearest` or
   `:truncate`); the default `:skip` margin raises with guidance. See
   [Window iteration](22_window_iteration.md).
2. A group preserves source order, so a *within-group* index is weak; the group
   offers the flat source address instead (see below).
3. Not provided in this first version.
4. A window's pieces overlap and its margin cells are padding with no source
   address, so an element-wise scatter-back (`map`) and a per-cell source
   `sort_addr` are ill-defined and raise `NotImplementedError`.

### Position — `_index` vs `_addr`

Two families of "where is the winner" methods coexist, and they answer
different questions.

- **`min_index` / `max_index`** give the position of the extreme *within the
  piece*. A slab, window, or tile has a natural local index (`0`-based along the
  piece), usable with `take_along_axis`.
- **`min_addr` / `max_addr`** give the **flat address in the original array** of
  the winning cell — the index into `source.reshape(source.elements)`.

```ruby
m = CA_DOUBLE([[3, 1, 2],
               [6, 4, 5]])
it = m[nil, :>]

it.min_index    # position of the min within each row
#  => [ 1, 1 ]

it.min_addr     # flat address of each row's min in the source
#  => [ 1, 4 ]
```

Row 0's minimum is at local position `1`; that same cell is flat address `1` in
the source. Row 1's minimum is at local position `1`, which is flat address `4`.

A group has no meaningful within-piece index — its cells keep source order
rather than a compact local order — so it exposes `min_addr` / `max_addr` only,
and no `min_index`. A window or block exposes the within-piece index.

### Member-specific methods

Beyond the common surface, each member adds methods that only make sense for it:

| member | extra methods |
|---|---|
| `CAWindowIterator` | `correlate(kernel)` / `convolve(kernel)`, the `bounds:` policy, and `min_count:` / `fill_value:` on every reduction for boundary strictness |
| `CASlabIterator` | `sort_index` (within-axis rank, for `take_along_axis`), `map_slab` / `reduce_slab` block forms |
| `CAGroupIterator` | `labels` and the `axis_group` grouping machinery |
| `CACategoricalIterator` | `labels` |

## Calling conventions

Four of the five members **bind the axis at construction time**. You choose the
pieces when you build the iterator, so the reduction itself takes no `axis`:

```ruby
a = CArray.int32(2, 3).seq

a[nil, :>].mean                    # slab — axis marked by the indexer
#  => [ 1.0, 4.0 ]

CArray.int32(6).seq.windows(-1..1).mean   # window — offsets fix the pieces
#  => [ 0.5, 1.0, 2.0, 3.0, 4.0, 4.5 ]

a.blocks(2, 2).mean                # block — tile size fixes the pieces
#  => [ [ 2.0, 3.5 ] ]
```

```ruby
val = CA_DOUBLE([10, 20, 30, 40, 50])
cat = CA_OBJECT(["a", "b", "a", "b", "a"]).categorize

val.group_by_category(cat).mean    # categorical — the label array fixes the pieces
#  => [ 30.0, 30.0 ]
```

### The group iterator is the exception

`CAGroupIterator` needs `axis: :group`. The reason is that the array indexer
`value[cat, nil]` is overloaded: with a plain integer index it is an ordinary
selection, and with a categorical it *can* be a grouping. To keep the two apart,
a group reduction only engages the grouping when you pass `axis: :group`.
Without it, the value is reduced plainly.

```ruby
row_cat = CA_OBJECT(["x", "y", "x"]).categorize   # classifies axis 0
val     = CA_DOUBLE([[1, 2],
                     [3, 4],
                     [5, 6]])

val[row_cat, nil].mean(axis: :group)   # per-group mean, band axis preserved
#  => [ [ 3.0, 4.0 ],
#       [ 3.0, 4.0 ] ]

val[row_cat, nil].mean                 # no :group — reduced plainly
#  => 3.5
```

Groups `x` (rows 0 and 2) and `y` (row 1) each collapse to their mean along the
classified axis, and the band axis (the two columns) is preserved. See
[Categories and grouping](24_categories_and_grouping.md) for the grouping shapes
and the `labels` machinery.

## Choosing a member

Pick by what a piece should be:

- **A statistic per row / column / plane** of a regular array → slab
  (`a[nil, :>]`). See [Slab iteration](11_slab_iteration.md).
- **A rolling / sliding statistic** (moving average, bounded convolution) →
  window (`a.windows`). See [Window iteration](22_window_iteration.md).
- **Pooling / downsampling** into non-overlapping tiles → block (`a.blocks`).
  See [Block iteration](23_block_iteration.md).
- **Group by a label** (one array of keys) → categorical
  (`value.group_by_category`). See
  [Categories and grouping](24_categories_and_grouping.md).
- **Group by axis coordinates** of a grid (month × region, a category map) →
  group (`value[cat, …]`). See
  [Categories and grouping](24_categories_and_grouping.md).

The full reference for the family, including the exact abstract contract and the
optional-method rules, is `docs/IteratorFamily.md`.
