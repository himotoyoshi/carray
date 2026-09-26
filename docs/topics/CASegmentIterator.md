# CASegmentIterator — reductions over consecutive segments (`segments`)

`value.segments(offsets: o)` returns a **`CASegmentIterator`** that cuts `value`
into **consecutive segments** and folds each segment to one value. Segment `c`
is the cells `o[c]...o[c + 1]`, read in flatten order; the result has one cell
per segment.

It is the **segment member of the 3.0 iterator family**, a sibling of
[`CASlabIterator`](SlabIterator.md), [`CAWindowIterator`](CAWindowIterator.md),
[`CABlockIterator`](CABlockIterator.md) and
[`CACategoricalIterator`](CACategoricalIterator.md). Where a block iterator cuts
tiles of one fixed size, a segment iterator cuts pieces of **any** length,
including zero, at boundaries you give.

```ruby
require "carray"

v = CA_FLOAT64([1, 2, 3, 4, 5])

v.segments(offsets: [0, 2, 2, 5]).sum     # three segments: [1, 2], [], [3, 4, 5]
#=> [3.0, 0.0, 12.0]

v.segments(lengths: [2, 0, 3]).mean       # the same segments, by length
#=> [1.5, UNDEF, 4.0]
```

A typical source of offsets is the row pointer of a compressed sparse matrix:
the per-row sums of a matrix–vector product are

```ruby
(data * x[indices]).segments(offsets: indptr).sum
```

## Construction

```ruby
value.segments(offsets: o)     # k + 1 boundaries: segment c is o[c]...o[c + 1]
value.segments(lengths: l)     # k lengths: the segments start at cell 0
```

Give exactly one of the two. They are the same two ways of naming segments that
`CArray.segment_offsets` and `CArray.segment_index` take, and are checked the
same way: offsets must not decrease, lengths must not be negative, and neither
may be masked. Both accept a CArray of any integer type or an Array of Integers.

- **Offsets need not start at 0.** The cells before `o[0]` and from `o[-1]` on
  belong to no segment — for example the offsets of some rows cut out of a
  longer table. The segments must lie within the value; `o[-1]` beyond
  `value.elements` raises `ArgumentError`.
- **A multi-dimensional value is read flat**, as `value.reshape(value.elements)`.
  There is no `axis:` form: a reduction given `axis:` raises
  `NotImplementedError`.
- **The iterator takes a copy** of the covered cells when it is built, so its
  answers describe the value as it was then. Build a new iterator after writing
  to the value.

```ruby
v  = CA_FLOAT64([1, 2, 3, 4])
it = v.segments(lengths: [2, 2])
v[0] = 100
it.sum                           #=> [3.0, 7.0]     (the copy)
v.segments(lengths: [2, 2]).sum  #=> [102.0, 7.0]
```

## Named reductions

Each named reduction folds every segment to one value and returns a length-`k`
array:

| family | methods |
|---|---|
| arithmetic | `sum` `accumulate` `prod` `mean` |
| extrema | `min` `max` `minmax` |
| spread | `variance` `stddev` (sample) · `variancep` `stddevp` (population) |
| boolean | `all` `any` |
| position | `min_index` `max_index` (position within the segment) |
| weighted | `wsum(weights)` `wmean(weights)` (weights shaped like the value) |
| order statistics | `median` `percentile(p)` `quantile` |
| counting | `count` / `count_not_masked` / `count_masked` / `count(v)` · `elements` |

Each is the core reduction of the same name applied to the segment, so its data
type, mask handling and answer for an empty or all-masked segment are the
core's: `sum` of an empty segment is `0`, `mean` / `min` / `median` of one are
UNDEF, and `elements` is the segment's length.

Numeric values (the integer and float types) go through fused kernels that
visit the copy once for all segments. Boolean, complex and object values, and a
[Face](CAFace.md) such as `CATime`, are reduced segment by segment through the
core — correct, and slower when there are many segments. A Face reduction
answers in the Face:

```ruby
t = CArray.time(%w[2024-01-03 2024-01-01 2024-01-05 2024-01-02], unit: :D)
t.segments(lengths: [2, 2]).min   # a CATime: 2024-01-01, 2024-01-02
```

## `map`, the scans, `each`, `reduce`

The segments do not overlap, so an element-wise transform and a running
statistic both have a well-defined place to go. `map` and the scans return a
**value-shaped** array; a cell in no segment is UNDEF there.

```ruby
v  = CA_FLOAT64([9, 5, 7, 1, 3, 8, 2])
it = v.segments(offsets: [1, 3, 3, 6])     # cells 0 and 6 are in no segment

it.map { |s| s - s.mean }
#=> [UNDEF, -1.0, 1.0, -3.0, -1.0, 4.0, UNDEF]

it.cumsum
#=> [UNDEF, 5.0, 12.0, 1.0, 4.0, 12.0, UNDEF]
```

The scans are `cumsum` `cumprod` `cummax` `cummin` `cumcount`. As in
`CArray#cumsum`, a masked cell inside a segment holds the running value.

`each` yields each segment as a CArray (an empty segment yields an empty
array); `reduce { |s| ... }` folds each segment to one value and
`reduce(init) { |acc, x| ... }` folds it element by element — the escape hatch
for a statistic the named surface does not have.

## Addresses and sorting

- **`min_addr` / `max_addr`** — the flat address **in the value** of each
  segment's minimum or maximum, where `min_index` / `max_index` give the
  position within the segment. An empty or all-masked segment is UNDEF.
- **`sort_addr`** — the value's addresses that sort each segment, segment after
  segment, covering only the cells that are in a segment.

```ruby
v = CA_FLOAT64([9, 5, 7, 1, 3, 8, 2])
v.segments(offsets: [1, 3, 3, 6]).min_addr    #=> [1, UNDEF, 3]
```

## Relation to `CACategoricalIterator`

A categorical iterator is a segment iterator over a **category-sorted copy**:
`value.group_by_category(cat)` gathers the value so that each category is one
contiguous run, and answers every reduction without `axis:` as the segment
reduction over that copy. `CACategoricalIterator` descends from
`CASegmentIterator` and adds the labels and the per-fiber (`axis:`) form. When
the pieces are already contiguous — rows of a sparse matrix, the records of a
ragged array — `segments` skips the sort.

## See also

- [`IteratorFamily.md`](IteratorFamily.md) — the shared iterator surface and how the members differ.
- [`CACategoricalIterator.md`](CACategoricalIterator.md) — grouping by a category instead of by position.
- [`CABlockIterator.md`](CABlockIterator.md) — fixed-size tiles.
