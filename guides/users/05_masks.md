# Masks and missing values

Every CArray can carry an *element-wise mask* — a record, kept alongside the
data, of which elements are "missing". This is built in to the array; you do not
need a separate array or a sentinel value such as `NaN`. Calculations that
understand the mask leave the missing elements out.

## Marking elements as missing

Assign the special constant `UNDEF` to mark an element as missing. Masked
elements display as `_`.

```ruby
a = CArray.float64(2, 3).seq
a[0, 1] = UNDEF
a[1, 2] = UNDEF
a
#  => [ [ 0.0,   _, 2.0 ],
#       [ 3.0, 4.0,   _ ] ]
```

You can mark many elements at once by assigning `UNDEF` through a boolean index
(see [Indexing and slicing](02_indexing_and_slicing.md)):

```ruby
b = CArray.float64(4).seq
b[b.lt(2)] = UNDEF      #  mark every element less than 2 as missing
#  => [ _, _, 2.0, 3.0 ]
```

## Marking by condition through the indexer

The same `[]=` form takes a comparison keyword in place of the boolean array.
The result is the same as building the boolean first; this form is just shorter.

```ruby
c = CArray.int32(5).seq         #  => [ 0, 1, 2, 3, 4 ]
c[:eq, 2] = UNDEF               #  mark cells equal to 2
c                               #  => [ 0, 1, _, 3, 4 ]

d = CArray.int32(5).seq
d[:gt, 2] = UNDEF               #  mark cells greater than 2
d                               #  => [ 0, 1, 2, _, _ ]
```

The same idea works for IEEE-special values on a float array, using the
`:is_invalid` key (NaN or any infinity):

```ruby
e = CA_DOUBLE([1.0, Float::NAN, 3.0, Float::INFINITY, 5.0])
e[:is_invalid] = UNDEF
e                               #  => [ 1.0, _, 3.0, _, 5.0 ]
```

## Marking by condition through return-form methods

Sometimes you want a *new* masked array rather than mutating the original.
The `mask_*` methods are the return-form counterparts of the indexer above.
The original array is left untouched.

```ruby
x = CArray.int32(5).seq         #  => [ 0, 1, 2, 3, 4 ]
x.mask_eq(2)                    #  => [ 0, 1, _, 3, 4 ]
x.mask_where(:gt, 2)            #  => [ 0, 1, 2, _, _ ]
x                               #  => [ 0, 1, 2, 3, 4 ]   unchanged
```

`mask_invalid` is the dedicated form for masking NaN / Inf in a float array:

```ruby
y = CA_DOUBLE([1.0, Float::NAN, 3.0, Float::INFINITY, 5.0])
y.mask_invalid                  #  => [ 1.0, _, 3.0, _, 5.0 ]
```

`mask_where` also accepts a boolean array directly, which is handy when the
condition is already computed:

```ruby
z = CArray.float64(5).seq
cond = z.gt(2)
z.mask_where(cond)              #  => [ 0.0, 1.0, 2.0, _, _ ]
```

## Asking about the mask

```ruby
a.has_mask?          #  => true    does this array carry a mask at all?
a.count_masked       #  => 2       how many elements are missing
a.count_not_masked   #  => 4       how many are present

a.is_masked          #  a boolean array, true where an element is missing
#  => [ [ 0, 1, 0 ],
#       [ 0, 0, 1 ] ]
```

`is_invalid` is the matching probe for IEEE-special values. It returns a boolean
without mutating the input:

```ruby
v = CA_DOUBLE([1.0, Float::NAN, Float::INFINITY, 4.0])
v.is_invalid                    #  => [ 0, 1, 1, 0 ]
v.is_invalid.count(true)        #  => 2
```

## Reductions ignore masked elements

This is the main reason the mask exists. Reductions and statistics
(see [Reduction and statistics](04_reduction_and_statistics.md)) skip the missing
elements:

```ruby
a.sum     #  => 9.0     adds only the present elements (0+2+3+4)
a.mean    #  => 2.25    divides by the count of present elements (9 / 4)
a.min     #  => 0.0     ignores the masked cells
a.max     #  => 4.0
a.count_not_masked   #  => 4    elements that contributed
```

Along an axis, each line is reduced over only its present elements:

```ruby
a.sum(axis: 0)    #  => [ 3.0, 4.0, 2.0 ]    per-column sums
a.sum(axis: 1)    #  => [ 2.0, 7.0 ]         per-row sums
```

### An entirely-masked line

If a whole line along the reduction axis is masked, there is nothing present to
reduce. What the output cell holds depends on the reduction: one with a natural
"empty" answer returns it (`sum` → `0`, `prod` → `1`, `count` → `0`), while one
without — `min` / `max` and the ratio statistics `mean` / `variance` / `stddev`
— returns `UNDEF`. See
[When there is nothing to reduce](04_reduction_and_statistics.md) for the full
rule.

```ruby
m = CArray.float64(3, 4).seq
m[1, nil] = UNDEF                #  mask the entire middle row
m
#  => [ [ 0.0, 1.0,  2.0,  3.0 ],
#       [   _,   _,    _,    _ ],
#       [ 8.0, 9.0, 10.0, 11.0 ] ]

m.sum(axis: 1)
#  => [ 6.0, 0.0, 38.0 ]        the empty middle row sums to 0, unmasked

m.count_not_masked(axis: 1)
#  => [ 4, 0, 4 ]                zero contributing elements in row 1

m.mean(axis: 1)
#  => [ 1.5, _, 9.5 ]           mean has no empty answer, so the cell is masked
```

To force the masked-line cell for a reduction that would otherwise return its
identity, require present data with `min_count:`; to substitute a value for any
masked result cell, pass `fill_value:` (both covered in
[Reduction and statistics](04_reduction_and_statistics.md)).

## Arithmetic propagates the mask

In an element-wise operation, a result element is masked if any of its inputs was
masked. Missing-ness carries through the calculation.

```ruby
a + 10
#  => [ [ 10.0,    _, 12.0 ],
#       [ 13.0, 14.0,    _ ] ]
```

The same holds for any binary operation with another array — only positions
present in *both* operands stay present:

```ruby
p = CA_DOUBLE([1.0, 2.0, 3.0])
p[1] = UNDEF
q = CA_DOUBLE([10.0, 20.0, 30.0])

p + q       #  => [ 11.0,  _, 33.0 ]
p * q       #  => [ 10.0,  _, 90.0 ]
p * 2       #  => [  2.0,  _,  6.0 ]    mask survives scalar ops too
```

## Masking duplicates

`mask_duplicates` is a mask *producer* that shows off why a mask is more than a
convenience. It returns a shape-preserving copy in which every cell that repeats
an earlier-seen value is masked, keeping only the first occurrence. It paints
over the repeats; it does not squeeze them out.

```ruby
a = CA_INT([10, 20, 20, 30, 10])
a.mask_duplicates
#  => [ 10, 20, _, 30, _ ]        the 2nd 20 and the 2nd 10 are masked
```

The payoff of painting rather than squeezing is that the same operation works
**per fiber**. Deduplicating each row of a matrix independently has no
compressed answer — different rows keep different numbers of distinct values, so
the result would be ragged and could not be a rectangular array. Masking keeps
the shape and paints each row's repeats over in place:

```ruby
m = CA_INT([[1, 2, 1],
            [1, 2, 3],
            [4, 2, 1]])

m.mask_duplicates(axis: 1)        #  along each row
#  => [ [ 1, 2, _ ],              row 0: the 2nd 1 is masked
#       [ 1, 2, 3 ],              row 1: all distinct
#       [ 4, 2, 1 ] ]             row 2: all distinct
```

`axis:` chooses the direction "earlier-seen" runs — `k` for each fiber along
axis `k` independently, or `nil` (the default) for the whole array taken as one
flatten-order fiber:

```ruby
m.mask_duplicates(axis: 0)        #  down each column
#  => [ [ 1, 2, 1 ],
#       [ _, _, 3 ],
#       [ 4, _, _ ] ]

m.mask_duplicates                 #  the whole array as one fiber
#  => [ [ 1, 2, _ ],              only the first 1, 2, 3, 4 anywhere survive
#       [ _, _, 3 ],
#       [ 4, _, _ ] ]
```

Because positions are preserved, the result composes with everything else in
this chapter. The survivors are the first-seen values, and a count of what
survives per fiber is the distinct-value count:

```ruby
m.mask_duplicates[:is_not_masked]              #  distinct values, first-seen order
#  => [ 1, 2, 3, 4 ]

m.mask_duplicates(axis: 1).count_not_masked(axis: 1)   #  distinct per row
#  => [ 2, 3, 3 ]
```

The duplicate mask can be lifted off and applied to a parallel array, which a
compressed result could never do — masking never shifts indices, so the mask
from one array lines up cell-for-cell with another:

```ruby
values = CA_INT([10, 20, 20, 30, 10])
times  = CA_INT([ 1,  2,  3,  4,  5])

times[values.mask_duplicates.is_masked] = UNDEF   #  mask times where values repeated
times
#  => [ 1, 2, _, 4, _ ]
```

Duplicate judging uses strict `==`. A masked input cell is invisible to it — it
stays masked and neither counts as a duplicate nor blocks a later cell from
being first-seen. Because `NaN != NaN`, `NaN` cells are all kept unless you mask
them first with `mask_invalid`. Every data type works, including object arrays:

```ruby
CA_OBJECT(["a", "b", "a", "c", "b"]).mask_duplicates
#  => [ "a", "b", _, "c", _ ]
```

If you want the older 1-D "distinct values" array (the pre-3.0 `uniq`), select
the survivors and copy: `a.mask_duplicates[:is_not_masked].copy` — or use
the newer `a.unique`, covered in
[Discovery](28_discovery.md) along with `value_counts`, `nunique`, `mode`,
and set membership. The two families differ in one crucial way: `unique`
and friends fold every NaN into a single value (value-hash contract),
while `mask_duplicates` uses strict `==` and keeps each NaN separate.

The full reference is `docs/MaskDuplicates.md`.

## Looking past the mask: `value`

`value` returns a view of the same storage with the mask dropped. It is useful
when you want to inspect what is actually sitting in memory under the masked
cells, or to feed a routine that does not understand masks.

```ruby
a.value
#  => [ [ 0.0, 1.0, 2.0 ],
#       [ 3.0, 4.0, 5.0 ] ]
```

Because it is a view, writes through `value` reach back into the original
storage. The mask itself is not touched.

## Removing the mask

`strip_mask` returns a copy with the mask removed and the missing positions
filled with a value you supply. The original array is unchanged.

```ruby
a.strip_mask(0)
#  => [ [ 0.0, 0.0, 2.0 ],
#       [ 3.0, 4.0, 0.0 ] ]

a.strip_mask(-1)
#  => [ [  0.0, -1.0,  2.0 ],
#       [  3.0,  4.0, -1.0 ] ]

a.strip_mask(-999)
#  => [ [   0.0, -999.0,    2.0 ],
#       [   3.0,    4.0, -999.0 ] ]
```

### NaN versus UNDEF: which to use

The mask is deliberately *not* `NaN`. The two represent missing-ness in very
different ways, and the right choice depends on what you want downstream:

* **`UNDEF` (mask)** — missing-ness is tracked alongside the data. Reductions
  skip it; arithmetic propagates it. Integer arrays can be masked too (`NaN`
  does not exist for integers). Use this for "this measurement was not taken".

* **`NaN`** — a floating-point value with IEEE semantics. It is a real number in
  the array, so reductions *do not* skip it: `sum` of a column with one `NaN`
  is `NaN`. Use this when you want missing values to poison downstream
  computations rather than be ignored.

If you want IEEE behaviour, fill the mask with `NaN` before reducing:

```ruby
a.strip_mask(Float::NAN).sum(axis: 0)
#  => [ 3.0, NaN, NaN ]          NaN propagates rather than being ignored
```

And going the other way, `mask_invalid` lifts existing `NaN` / `Inf` cells into
the mask, so they begin to be ignored instead of poisoning sums:

```ruby
w = CA_DOUBLE([1.0, Float::NAN, 3.0, Float::INFINITY])
w.sum                            #  => NaN              IEEE poisons it
w.mask_invalid.sum               #  => 4.0              skipped via mask
```

## `UNDEF` in a cell versus `nil` from a query

`UNDEF` and Ruby's `nil` both mean "no value here", but they live in different
places, and CArray uses each where it fits:

* **`UNDEF` — absence inside a cell.** It is the mask value, so it is what a
  reduction returns when a line has nothing to reduce (`mean` of an empty row),
  and the only thing that can sit in a masked cell of a `CArray`. A `nil` cannot
  live in an `int64` array; `UNDEF` can.

* **`nil` — absence of a Ruby answer.** A lookup that returns a single Ruby value
  uses `nil` for "not found", so it plugs straight into an `if`:

  ```ruby
  a = CA_DOUBLE([10.0, 20.0, 30.0])
  if i = a.search(25.0)   #  25 is absent -> nil -> the branch is skipped
    a[i]
  end
  ```

The same method follows the container: `search` with a scalar query returns `nil`
for "not found", but `search` with a *vector* of queries returns a `CArray` whose
missing answers are `UNDEF` cells (a `CArray` cannot hold `nil`).

Because `UNDEF` is truthy while `nil` is falsy, a reduction scalar cannot be
tested the same way as a lookup. Prefer a call-site fallback:

```ruby
a.mean(fill_value: 0.0)   #  the average, or 0.0 when every cell is masked
```

Only when you must fold *several* possibly-`UNDEF` scalars together — where a
per-call `fill_value:` cannot express the combination — reach for
`CArray.guard_undef`, which short-circuits to its `fill_value` (default `UNDEF`)
if any argument is `UNDEF` and otherwise yields the values to the block:

```ruby
CArray.guard_undef(a.min, a.max) { |lo, hi| hi - lo }   #  UNDEF if either is UNDEF
```
