# The iterator family — one reduction surface, five engines

CArray 3.0 has a family of **iterators** that all answer the same question —
*"fold each piece of the array to a value"* — but differ in what a *piece* is
and how the pieces are laid out. They share a common set of method names so that
once you know one, you can read the others; each supplies its own fast engine.

| iterator | a *piece* is… | built by | output shape |
|---|---|---|---|
| [`CASlabIterator`](SlabIterator.md) | a fiber along the marked axes | `a[nil, :>]` / `each_slab` | outer shape (source minus the slab axes) |
| [`CAWindowIterator`](CAWindowIterator.md) | an overlapping window per anchor | `a.windows(-1..1)` | reference-shaped (rolling); shrunk for `:truncate` |
| [`CABlockIterator`](CABlockIterator.md) | a non-overlapping tile | `a.blocks(3, 3)` | tile grid (ceil) |
| [`CACategoricalIterator`](CACategoricalIterator.md) | the cells of one category | `value.group_by_category(cat)` | length-`k` (one per category) |
| [`CAGroupIterator`](CAGroupIterator.md) | a coordinate-classified group | `value[cat, nil, …]` | slot order (group → `k`, band → length) |

They descend from a **form-only base**, `CAIterator`, which carries no engine of
its own — it only declares the shared shape accessors (`shape` / `ndim`; `dim`
is a legacy alias) and the common reduction surface every member is expected to
provide. There is deliberately **no** `include Enumerable`: names like `min` /
`sum` / `to_a` are not allowed to leak in and silently fold the pieces the wrong
way. A method a member does not provide raises a clean `NotImplementedError`,
never a wrong answer.

## The common surface

Every family member provides these (the surface `CASlabIterator` and
`CACategoricalIterator`, the two reference members, both have):

```
sum  prod  mean  min  max  variance  stddev  all  any     # tier 1
variancep  stddevp  minmax                                # tier 2
wsum  wmean                                               # weighted
median  percentile  quantile                             # tier 3 (order statistics)
count  count_not_masked  count_masked  elements          # count family
each  reduce                                             # generic iteration
```

Each reduction is the corresponding **core `CArray` reduction lifted to the
piece**, so its data type, mask handling, empty / all-masked contract (identity for
`sum` / `prod` / `count`, `UNDEF` for ratios and extrema), and ε-close numeric
contract are the core's, unchanged — the iterator adds no new semantics. `all` /
`any` require a boolean payload, as `CArray#all` / `#any` do.

`each` / `reduce` are the escape hatch for a statistic not in the named list:
`each { |piece| … }` yields each piece (an `Enumerator` with no block);
`reduce { |piece| … }` folds each piece to one value, and `reduce(init) { |acc,
e| … }` fiber-folds each piece.

## Where the members differ

The differences are as meaningful as the common surface — they follow from what
a piece *is*.

| method | Slab | Window | Block | Categorical | Group |
|---|:--:|:--:|:--:|:--:|:--:|
| tier 1 / 2, `minmax`, `wsum` / `wmean` | ✓ | ✓ | ✓ | ✓ | ✓ |
| `median` / `percentile` / `quantile` | ✓ | ✓ ¹ | ✓ | ✓ | ✓ |
| count family, `elements`, `each` / `reduce` | ✓ | ✓ | ✓ | ✓ | ✓ |
| `min_index` / `max_index` (position **within** a piece) | ✓ | ✓ | ✓ | ✓ | — ² |
| `min_addr` / `max_addr` (flat **source** address of the winner) | ✓ | ✓ ³ | ✓ | ✓ | ✓ |
| `map` (per-piece transform, scattered back to the source) | ✓ | — ⁴ | ✓ | ✓ | ✓ |
| `sort_addr` (per-piece sort → source addresses) | ✓ | — ⁴ | ✓ | ✓ | ✓ |
| `cumsum` / `cumprod` / `cummax` / `cummin` / `cumcount` (per-cell running scan) | ✓ | — ⁴ | ✓ | ✓ | ✓ ⁵ |

1. Window order statistics need an unmasked margin (`bounds: :nearest` or
   `:truncate`); the default `:skip` (UNDEF margin) raises with guidance.
2. A group preserves source order, so a *within-group* index is weak; the group
   offers the flat **source address** (`min_addr` / `max_addr`) instead — the
   `_addr` vs `_index` split (a group indexes back into the original array).
3. A window's winner is a single cell, so its source address is well-defined even
   with overlap. When the winner is a boundary cell, `bounds: :nearest` resolves
   to the edge source cell it replicates and `bounds: :constant` (a padded margin
   value with no source cell) yields a masked result.
4. A window's pieces overlap and its margin cells are padding with no source
   address, so a scatter-back (`map`), a per-cell running scan (`cumsum` etc.,
   a cell would land in many windows with no single running value), and a
   per-cell source `sort_addr` are all ill-defined; use `reduce` for a custom
   per-window fold.
5. A group's scans take `axis: :group`; its `cumcount` is the running member
   ordinal within each group.

**Reductions vs per-cell surface.** The reductions collapse a piece to one value
(output = the piece grid). `map` and the scans (`cumsum` …) instead write **one
value per source cell** — their output is **source-shaped**. A running scan is
single-valued only when every cell belongs to exactly one piece, which is why the
partition members (slab / block / categorical / group) provide it and the
overlapping window does not.

**Position — `_index` vs `_addr`.** `min_index` is the position of the minimum
*within the piece* (a window/tile/slab has a natural local index, usable with
`take_along_axis`). `min_addr` is the **flat address in the original array** of
the winning cell (`source.reshape(source.elements)[it.min_addr]`). A group has
no meaningful within-piece index, so it exposes `min_addr` only; a window/block
exposes the within-piece index.

**Member-specific methods** (outside the common surface):

- `CAWindowIterator`: `correlate(kernel)` / `convolve(kernel)` (bounded
  cross-correlation / convolution), the `bounds:` policy, and `min_count:` /
  `fill_value:` on every reduction for boundary strictness.
- `CASlabIterator`: `sort_index` (within-axis rank, for `take_along_axis`).
- `CAGroupIterator`: `labels` and the whole `axis_group` grouping machinery.
- `CACategoricalIterator`: `labels`.

## Calling conventions

Four of the members bind the axis at construction, so a reduction takes no axis:

```ruby
a[nil, :>].mean                 # slab
a.windows(-1..1).mean           # window (rolling)
a.blocks(2, 2).mean             # block (pooling)
value.group_by_category(cat).mean   # categorical
```

**`CAGroupIterator` is the exception**: the same array indexer produces either a
plain selection or a grouping, so a group reduction takes `axis: :group` to
engage the grouping (without it the value is reduced plainly):

```ruby
value[cat, nil].mean(axis: :group)   # per-group mean, band axis preserved
```

See [`CAGroupIterator`](CAGroupIterator.md) for why, and for the grouping shapes.

## Choosing a member

- **A statistic per row/column/plane** of a regular array → slab (`a[nil, :>]`).
- **A rolling / sliding statistic** (moving average, bounded convolution) →
  window (`a.windows`).
- **Pooling / downsampling** into non-overlapping tiles → block (`a.blocks`).
- **Group by a label** (one array of keys) → categorical
  (`value.group_by_category`).
- **Group by axis coordinates** of a grid (month × region, a category map) →
  group (`value[cat, …]`).
