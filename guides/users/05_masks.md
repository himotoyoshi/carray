# Masks and missing values

Every CArray can carry an *element-wise mask* — a record, kept alongside the
data, of which elements are "missing". This is built in to the array; you do not
need a separate array or a sentinel value such as `NaN`. Calculations that
understand the mask leave the missing elements out.

## What `UNDEF` is

`UNDEF` is a single object standing for "no value here". You assign it to mask
a cell, and you get it back when you read one:

```ruby
a = CArray.float64(2, 3).seq!
a[0, 1] = UNDEF

a[0, 1]              #  => UNDEF
a[0, 0]              #  => 0.0
```

It is neither of the two things it resembles.

* It is **not `nil`**. A `float64` array holds float64 values and nothing else,
  so a Ruby `nil` has nowhere to sit in a cell; `UNDEF` is what an array uses
  in its place. The last section of this chapter compares the two.
* It is **not `NaN`**. `NaN` is a floating-point *value*, and a value takes part
  in arithmetic; `UNDEF` masks the cell rather than filling it, and an integer
  array can be masked just as well. That comparison also has a section below.

`UNDEF` is truthy, so `if a[0, 1]` takes the branch — ask the array
(`a.is_masked`) or compare (`a[0, 1] == UNDEF`) instead.

**`UNDEF` is what a masked cell shows you, not what the array computes with.**
The only thing you can do with the object is compare it: `UNDEF + 1` raises,
and so does every other operation. The array does not compute with it either.
Which cells are missing is kept as a separate record alongside the data, and a
calculation reads that record and leaves those cells out — no arithmetic on
`UNDEF` ever takes place. The two are worth keeping apart in your head: a
masked *element* is a bookkeeping fact about a cell, while `UNDEF` is the
object handed to you when you look at one.

In practice this rarely comes up, because working with whole arrays keeps you
on the array's side of the line. `UNDEF` appears when you read a single cell,
when you mask one, and when a reduction has nothing to answer with.

## Masking elements

Assign the special constant `UNDEF` to mask an element. Masked elements
display as `_`.

```ruby
a = CArray.float64(2, 3).seq!
a[0, 1] = UNDEF
a[1, 2] = UNDEF
a
#  => [ [ 0.0,   _, 2.0 ],
#       [ 3.0, 4.0,   _ ] ]
```

You can mask many elements at once by assigning `UNDEF` through a boolean index
(see [Indexing and slicing](02_indexing_and_slicing.md)):

```ruby
b = CArray.float64(4).seq!
b[b.lt(2)] = UNDEF      #  mask every element less than 2
#  => [ _, _, 2.0, 3.0 ]
```

## Masking by condition through the indexer

The same `[]=` form takes a comparison keyword in place of the boolean array.
The result is the same as building the boolean first; this form is just shorter.

```ruby
c = CArray.int32(5).seq!         #  => [ 0, 1, 2, 3, 4 ]
c[:eq, 2] = UNDEF               #  mask cells equal to 2
c                               #  => [ 0, 1, _, 3, 4 ]

d = CArray.int32(5).seq!
d[:gt, 2] = UNDEF               #  mask cells greater than 2
d                               #  => [ 0, 1, 2, _, _ ]
```

The same idea works for IEEE-special values on a float array, using the
`:is_invalid` key (NaN or any infinity):

```ruby
e = CA_DOUBLE([1.0, Float::NAN, 3.0, Float::INFINITY, 5.0])
e[:is_invalid] = UNDEF
e                               #  => [ 1.0, _, 3.0, _, 5.0 ]
```

## Masking by condition through return-form methods

Sometimes you want a *new* masked array rather than mutating the original.
The `mask_*` methods are the return-form counterparts of the indexer above.
The original array is left untouched.

```ruby
x = CArray.int32(5).seq!         #  => [ 0, 1, 2, 3, 4 ]
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
z = CArray.float64(5).seq!
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

`mask` is the mask itself, as a boolean array over the same storage. Reading it
answers what `is_masked` answers; writing to it masks and unmasks cells:

```ruby
t = a.copy
t.mask[0, 0] = true    #  mask one more cell
t.count_masked         #  => 3
t.mask = false         #  clear the whole mask
t.count_masked         #  => 0
```

`has_mask?` asks whether a mask exists at all, which is a different question
from whether anything is missing right now: once an array has been given a
mask it keeps it, even after the last masked cell is cleared. `count_masked` is the
one to ask about the present state.

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
m = CArray.float64(3, 4).seq!
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

Two keywords let you say what you want in those cells. `min_count:` demands a
number of present elements before an answer counts — below it the cell comes
back `UNDEF`, which is how you stop an all-masked row from reporting a sum of
zero. `fill_value:` puts a value of your own in every cell that would be
`UNDEF`:

```ruby
m.sum(axis: 1, min_count: 1)
#  => [ 6.0, _, 38.0 ]          the empty row no longer answers 0

m.mean(axis: 1, fill_value: 0.0)
#  => [ 1.5, 0.0, 9.5 ]         a value of your choosing instead of UNDEF

m.sum(axis: 1, min_count: 1, fill_value: -1.0)
#  => [ 6.0, -1.0, 38.0 ]       both together
```

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

## What carries the mask

The rule is short: **giving every cell a value clears the mask; computing from
the cells carries it.**

| | the result's mask |
|---|---|
| `copy` | carried — values and mask both |
| `template` | none — shape and data type only |
| arithmetic, `to_type`, `zero`, `one` | carried |
| `fill`, `a[] = v`, `seq!`, `fill_copy` | cleared — every cell was given a value |
| a view (`a[0, nil]`, `reshape`, `transpose`, …) | shared with the source |
| `value` | dropped — a view of the values alone |

```ruby
a = CArray.float64(2, 3).seq!
a[0, 1] = UNDEF

a.copy.count_masked        #  => 1
a.template.count_masked    #  => 0    a fresh array, nothing missing in it
a.fill_copy(9)             #  => [ [ 9.0, 9.0, 9.0 ], [ 9.0, 9.0, 9.0 ] ]
```

Two of those repay a second look.

`template` gives an unmasked array because it carries neither values nor mask —
it is a fresh array of the same shape and data type, and a fresh array has
nothing missing in it. That is what you want when it is a place to write
results into.

`a.zero` is **not** `a.fill_copy(0)` on a masked array. `zero` computes a value
from each cell, so it behaves like arithmetic and the mask rides along;
`fill_copy` puts a value in every cell, so nothing is missing afterwards:

```ruby
a.zero        #  => [ [ 0.0,   _, 0.0 ], [ 0.0, 0.0, 0.0 ] ]
a.fill_copy(0)#  => [ [ 0.0, 0.0, 0.0 ], [ 0.0, 0.0, 0.0 ] ]
```

Because a view shares the mask rather than a copy of it, masking a cell through
a view masks it in the source:

```ruby
row = a[0, nil]
row[0] = UNDEF
a.count_masked    #  => 2
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

The full reference is `docs/topics/MaskDuplicates.md`.

## Looking past the mask: `value`

`value` returns a view of the same storage with the mask dropped. It is useful
when you want to inspect what is actually sitting in memory under the masked
cells, or to feed a routine that does not understand masks.

```ruby
a = CArray.float64(2, 3).seq!     # the masked array from the top of the chapter
a[0, 1] = UNDEF
a[1, 2] = UNDEF

a.value
#  => [ [ 0.0, 1.0, 2.0 ],
#       [ 3.0, 4.0, 5.0 ] ]
```

Because it is a view, writes through `value` reach back into the original
storage. The mask itself is not touched.

## Removing the mask

Two methods clear a mask by supplying values for the missing cells. `unmask`
works on the receiver — it is one of the two destructive methods that carry no
`!` (`fill` is the other) — and `strip_mask` leaves the receiver alone and
returns a new array.

Given a value, every masked cell takes it:

```ruby
a.strip_mask(0)
#  => [ [ 0.0, 0.0, 2.0 ],
#       [ 3.0, 4.0, 0.0 ] ]

a.strip_mask(-999)
#  => [ [   0.0, -999.0,    2.0 ],
#       [   3.0,    4.0, -999.0 ] ]

b = a.copy
b.unmask(-1)
b
#  => [ [  0.0, -1.0,  2.0 ],
#       [  3.0,  4.0, -1.0 ] ]
```

`unmask` with no argument at all clears the mask and leaves whatever was
stored underneath — the values `value` shows:

```ruby
c = a.copy
c.unmask
c
#  => [ [ 0.0, 1.0, 2.0 ],
#       [ 3.0, 4.0, 5.0 ] ]
```

`strip_mask` has no such form; a copy of the values alone is `a.value.copy`. It
insists on being told what to put in the gaps, and raises if you give it
nothing.

### Filling from the neighbours

Instead of one value everywhere, `method:` derives each gap from the cells
around it. `:forward` carries the last present value forward, `:backward`
carries the next one back, and `:linear` interpolates between the two.

```ruby
g = CA_DOUBLE([1.0, 2.0, 3.0, 4.0, 5.0])
g[1] = UNDEF
g[2] = UNDEF

g.strip_mask(method: :forward)    #  => [ 1.0, 1.0, 1.0, 4.0, 5.0 ]
g.strip_mask(method: :backward)   #  => [ 1.0, 4.0, 4.0, 4.0, 5.0 ]
g.strip_mask(method: :linear)     #  => [ 1.0, 2.0, 3.0, 4.0, 5.0 ]
```

A gap with no neighbour to draw from stays masked — a leading run has nothing
before it to carry forward:

```ruby
h = CA_DOUBLE([1.0, 2.0, 3.0, 4.0])
h[0] = UNDEF
h.strip_mask(method: :forward)    #  => [ _, 2.0, 3.0, 4.0 ]
```

On a multi-dimensional array, `axis:` says which way to carry. Without it the
array is filled in flat order.

```ruby
m = CArray.float64(2, 4).seq!
m[0, 1] = UNDEF
m[1, 3] = UNDEF

m.strip_mask(method: :forward, axis: 1)   #  across each row
#  => [ [ 0.0, 0.0, 2.0, 3.0 ],
#       [ 4.0, 5.0, 6.0, 6.0 ] ]

m.strip_mask(method: :forward, axis: 0)   #  down each column
#  => [ [ 0.0,   _, 2.0, 3.0 ],
#       [ 4.0, 5.0, 6.0, 3.0 ] ]
```

`unmask` takes the same keywords and fills in place.

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
