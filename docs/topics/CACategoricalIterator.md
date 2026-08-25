# CACategoricalIterator — per-category reduction (`group_by_category`)

`value.group_by_category(cat)` groups the payload array `value` by the
categories of a [`CACategorical`](../objects/CACategorical.md) and returns a
**`CACategoricalIterator`** — an iterator over the categories whose reduction
methods (`sum`, `mean`, `median`, `variance`, …) return one value per category.

The categorical carries the classification; `value` is just the data. A cell of
`value` belongs to a category iff the corresponding cell of `cat` has that
category. `value` and `cat` must have the same number of elements (both are read
flat).

```ruby
require "carray"

keys   = CA_OBJECT(%w[b a b c a b])
values = CA_INT32([10, 20, 30, 40, 50, 60])
cat    = keys.categorize                     # labels discovered: ["b", "a", "c"]

grp = values.group_by_category(cat)

grp.labels        #  => ["b", "a", "c"]
grp.elements      #  => [ 3, 2, 1 ]              cells per category
grp.sum           #  => [ 100, 70, 40 ]          value dtype (int32)
grp.mean          #  => [ 33.333…, 35.0, 40.0 ]  float64
grp.median        #  => [ 30.0, 35.0, 40.0 ]
```

Every result is a length-`k` CArray aligned to `cat.labels` (`k` = number of
groups, available as `#ngroups`): result cell `i` is the statistic of the cells
whose category is `labels[i]`. The category vocabulary is `#labels`.

## The reductions

| method | result dtype | notes |
|---|---|---|
| `elements` | int64 | cells classified into the category (includes value-masked cells); alias `group_sizes` |
| `count` | int64 | present (non-masked) cells; `count` with no argument is `count_not_masked` |
| `count_not_masked` | int64 | present (non-masked) cells — the denominator the value reductions divide by |
| `count_masked` | int64 | masked cells in the category; `count(UNDEF)` is the same |
| `count(v)` | int64 | cells whose value equals `v` |
| `sum` | value dtype | |
| `wsum(w)` / `wmean(w)` | float64 | weighted; `w` is a per-cell weight CArray in the source order (same elements as the value) |
| `prod` | float64 | empty / all-masked category is `1.0` (identity) |
| `min` / `max` | value dtype | |
| `mean` | float64 | |
| `variance` / `stddev` | float64 | sample (ddof = 1) |
| `median` | float64 | = `percentile(50)` |
| `percentile(p)` | float64 | `p` in `0..100`; for a fraction `q` use `percentile(q * 100)` |
| `quantile` | `Array<CArray>` | five-number summary `[min, Q1, median, Q3, max]` (no argument) |
| `minmax` | `Array<CArray>` | `[min, max]` pair |
| `variancep` / `stddevp` | float64 | population (ddof = 0) |
| `min_index` / `max_index` | int64 | group-local index (position within the category's members) |
| `min_addr` / `max_addr` | int64 | flat source address of the min / max (indexes back into the raveled source) |
| `sort_addr` | int64 | length-`nvalid` flat source addresses that sort each group, group-major (see below) |
| `all` / `any` | boolean | boolean value dtype only (as for `CArray#all` / `#any`) |

`prod`, `all`, `any`, and `count(v)` are currently per-group fallbacks (they
delegate to the CArray reduction over each category's members); a fused kernel
for them is a later refinement.

The guiding rule is simple:

> **A category's statistic equals the CArray reduction over that category's
> members.** `grp.mean[i]` is `members.mean`, `grp.variance[i]` is
> `members.variance`, and so on.

So everything you know about how a reduction treats an ordinary array — how it
skips masked cells, what it returns on a short or empty array — carries over
unchanged to each group. The sections below spell out the consequences.

### Sorting within groups

`sort_addr` returns a single length-`nvalid` (`= elements.sum`) int64 array of
the flat **source** addresses that sort each category's members, laid out
group-major: segment `c` holds category `c`'s source addresses in
ascending-value order, and the segments follow `labels` order. Splitting it by
the `elements` prefix sum gives the per-group order, and gathering the source
by it yields the values grouped and sorted within each group:

```ruby
keys = %w[b a b c a b]
val  = CA_INT32([10, 30, 60, 40, 50, 20])
grp  = val.group_by_category(CA_OBJECT(keys).categorize)   # b={10,60,20}, a={30,50}, c={40}

grp.sort_addr                    #  => [ 0, 5, 2, 1, 4, 3 ]   flat source addresses
val.reshape(6)[grp.sort_addr]    #  => [ 10, 20, 60, 30, 50, 40 ]   sorted within b | a | c
```

A masked value sorts to the tail of its segment (as `CArray#sort` sends masked
cells to the end), so the first address of a segment is its minimum but the last
is the masked cell, not the maximum. There is no group-local sort index: the
grouped copy is already category-contiguous, so a group-local rank order is weak
— only the source-address form is offered, mirroring `min_addr` (kept) versus a
group-local min index into the source (skipped).

## Excluded cells

A category can exclude cells in two ways, both handled the same: the cell simply
does not join any group.

- **Out-of-vocabulary** — with a fixed vocabulary, a key that is not a label is
  dropped.
- **Masked category** — a masked cell of `cat` (see
  [`CACategorical`](../objects/CACategorical.md)) is dropped. The mask is authoritative: a
  cell whose code is masked is excluded even if the code itself is a valid
  category index.

```ruby
keys   = %w[x y z x q x]                        # 'q' is out of vocabulary
values = CA_DOUBLE([1, 2, 3, 4, 5, 6])
cat    = CA_OBJECT(keys).categorize(labels: %w[x y z w])   # 'w' never appears

grp = values.group_by_category(cat)
grp.labels   #  => ["x", "y", "z", "w"]
grp.elements    #  => [ 3, 1, 1, 0 ]     'q' at index 4 dropped; x = {1,4,6}
grp.sum      #  => [ 11.0, 2.0, 3.0, 0.0 ]
```

## Masks and missing values

Two masks meet here: the categorical's exclusion (above) and a mask carried by
`value` itself. They are different, and the difference shows up in the counts.

- `elements` counts the cells **classified** into a category — including cells whose
  `value` is masked.
- `count_not_masked` counts the **present** cells — the ones a reduction actually
  uses.

They agree unless `value` carries a mask.

```ruby
keys = %w[a a a b]
vals = CA_DOUBLE([10, 20, 30, 40]); vals[1] = UNDEF   # one value missing
cat  = CA_OBJECT(keys).categorize(labels: %w[a b c])

grp = vals.group_by_category(cat)
grp.elements             #  => [ 3, 1, 0 ]     cells classified into a / b / c
grp.count_not_masked  #  => [ 2, 1, 0 ]     present cells (a lost one)
grp.sum               #  => [ 40.0, 40.0, 0.0 ]     10 + 30, skipping the masked 20
grp.mean              #  => [ 20.0, 40.0, _ ]       40 / 2 present, not 40 / 3
```

`mean` divides by `count_not_masked`, exactly as `CArray#mean` skips masked
cells. See [Masks and missing values](../../guides/users/05_masks.md) for the mask contract.

### Empty and all-masked categories

A category with no present cells — either an empty category (no members) or one
whose members are all masked — reduces like an empty array. That means the
category behaves as though you reduced an empty CArray:

- `sum` returns the additive identity **`0`** (unmasked); `prod`-like identities
  follow the same rule.
- `mean`, `median`, `variance`, `stddev`, `min`, `max` return **`UNDEF`**
  (masked) — there is no value to report.
- the counts (`elements`, `count_not_masked`, `count_masked`) are always defined
  integers (`0`), never masked.

```ruby
# category 'c' above is empty:
grp.sum[2]              #  => 0.0        empty sum is the identity (unmasked)
grp.mean.is_masked[2]   #  => 1          empty mean is undefined (masked)
```

Because the empty slot in `mean` / `variance` / … is a genuine masked cell (not a
magic number like `NaN`), a downstream calculation on `grp.mean` propagates the
missing-ness through the mask.

### A single-value category

Sample variance of one value is `0.0` — the same as `CArray#variance` on a
one-element array. A single-value category is therefore `0.0`, not masked:

```ruby
cat = CA_OBJECT(%w[a b b]).categorize
grp = CA_DOUBLE([5, 10, 20]).group_by_category(cat)
grp.variance   #  => [ 0.0, 50.0 ]     'a' has one value -> 0.0
```

## Iterating the categories

When you need something the named reductions do not cover, `each`, `reduce`, and
`map` hand you each category's members (a CArray, in `labels` order) so you can
compute it yourself — the same escape hatch as `each_slab` / `reduce_slab` /
`map_slab`.

```ruby
cat = CA_OBJECT(%w[a a b b]).categorize
grp = CA_DOUBLE([10, 20, 30, 40]).group_by_category(cat)

grp.each { |members| p members.to_a }      # side effect only; returns self
#  => [10.0, 20.0]
#  => [30.0, 40.0]

# reduce: one value per category (a custom per-category reduction)
grp.reduce { |members| members.max - members.min }   #  => [10.0, 10.0]
grp.reduce(0.0) { |acc, x| acc + x }                 #  => [30.0, 70.0]

# map: group-wise element-wise transform, back into a NEW array of the source
# shape (block returns a same-length CArray, or a scalar to broadcast)
grp.map { |members| members - members.mean }         #  => [-5.0, 5.0, -5.0, 5.0]
```

`each` with no block returns an `Enumerator`. An empty category yields an empty
array. `map` returns a new CArray shaped like the source `value` (the original
is untouched; use `value[] = grp.map { ... }` for in-place); cells in no category
are `UNDEF` in the result. The iterator does **not** mix in `Enumerable`, so only
the methods documented here are defined — a name that is not defined is a plain
`NoMethodError`, not a wrong answer.

## N-dimensional value and categorical

`value` and `cat` may be N-dimensional; both are read flat, so the result is
still a length-`k`, one-per-category array. Cells are grouped by category
regardless of position.

```ruby
keys = CA_OBJECT([%w[a b], %w[b a]])      # 2x2
vals = CA_DOUBLE([[1, 2], [3, 4]])
grp  = vals.group_by_category(keys.categorize)
grp.labels   #  => ["a", "b"]
grp.sum      #  => [ 5.0, 5.0 ]     a = {(0,0), (1,1)}, b = {(0,1), (1,0)}
```

## Relationship to `axis_group`

Both group a categorical, but they answer different needs:

- [`axis_group`](AxisGroup.md) groups a **grid** by coordinate categoricals along
  chosen axes and scatters the monoid reductions (`sum`, `mean`, `min`, `max`,
  `variance`) directly into the group cells — no intermediate copy, so peak
  memory stays flat. Reach for it when you group along axes and want a monoid.
- `group_by_category` lays the values out as category-contiguous blocks once and
  then folds each block. This materialization is what lets it serve the **order
  statistics** (`median`, `percentile`) — which need every value of a
  group held together — and to answer several statistics on the same grouping
  cheaply. Reach for it for a flat categorical, for order statistics, or when you
  want many statistics per group.

## See also

- [`CACategorical`](../objects/CACategorical.md) — the classifier this consumes.
- [`AxisGroup`](AxisGroup.md) — grid group-by along axes (the scatter path).
- [Masks and missing values](../../guides/users/05_masks.md) — the mask contract the
  reductions follow.
- [Reduction and statistics](../../guides/users/04_reduction_and_statistics.md) — the
  per-array reductions each group delegates to.
