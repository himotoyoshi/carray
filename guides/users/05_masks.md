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

**Not `nil`.** A `float64` array holds float64 values and nothing else, so a
Ruby `nil` has nowhere to sit in a cell; `UNDEF` is what an array uses in its
place. `nil` is what a *query* answers with — `a.search(25.0)` gives `nil` when
25 is not in the array, and that plugs straight into an `if`. Which of the two
you get follows the container: one query answers `nil`, an array of queries
answers an array whose misses are `UNDEF` cells.

`UNDEF` is truthy, so `if a.mean` takes the branch even when there was nothing
to average. Ask for a fallback at the call site instead:

```ruby
a.mean(fill_value: 0.0)   #  the average, or 0.0 when no cell is present
```

**Not `NaN`.** `NaN` is a floating-point value, and a value takes part in the
arithmetic: a sum containing one `NaN` is `NaN`. `UNDEF` marks the cell rather
than filling it, so a reduction leaves it out — and an integer array can be
masked just as well, which `NaN` cannot do. Reach for the mask when a
measurement was not taken, and for `NaN` when a missing value should poison
what follows. Either can be turned into the other, with `mask_invalid` and
`strip_mask` below.

**`UNDEF` is what a masked cell shows you, not what the array computes with.**
The only thing you can do with the object is compare it: `UNDEF + 1` raises,
and so does every other operation. The array does not compute with it either.
Which cells are missing is kept as a separate record alongside the data, and a
calculation reads that record and leaves those cells out — no arithmetic on
`UNDEF` ever takes place. The two are worth keeping apart in your head: a
masked *element* is a bookkeeping fact about a cell, while `UNDEF` is the
object handed to you when you look at one.

The other side of that is that **what sits in a masked cell is not defined**.
CArray promises which cells are missing, not what is stored in them, and a
calculation may write anything there — that freedom is what lets it run over
every cell without stopping to test the mask.

In practice none of this comes up often, because working with whole arrays
keeps you on the array's side of the line. `UNDEF` appears when you read a
single cell, when you mask one, and when a reduction has nothing to answer
with.

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

`mask_invalid` is the dedicated form for masking NaN / Inf in a float array. It
is how IEEE-special cells stop poisoning a calculation and start being left out
of it:

```ruby
y = CA_DOUBLE([1.0, Float::NAN, 3.0, Float::INFINITY, 5.0])
y.mask_invalid                  #  => [ 1.0, _, 3.0, _, 5.0 ]

y.sum                           #  => NaN    IEEE rules poison the sum
y.mask_invalid.sum              #  => 9.0    masked cells are left out
```

`mask_where` also accepts a boolean array directly, which is handy when the
condition is already computed:

```ruby
z = CArray.float64(5).seq!
cond = z.gt(2)
z.mask_where(cond)              #  => [ 0.0, 1.0, 2.0, _, _ ]
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

`unmask` with no argument at all clears the mask and leaves whatever the
storage holds. Here that is the values the array was given, since nothing has
been computed from it — in general what sits in a masked cell is not defined,
which the section on `value` below comes back to:

```ruby
c = a.copy
c.unmask
c
#  => [ [ 0.0, 1.0, 2.0 ],
#       [ 3.0, 4.0, 5.0 ] ]
```

`strip_mask` has no such form. It insists on being told what to put in the
gaps and raises if you give it nothing; when you want the stored values as a
new array, copy first and unmask the copy, as above.

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

Filling with `NaN` is the way back to IEEE rules — the cells stop being skipped
and start propagating instead:

```ruby
a.strip_mask(Float::NAN).sum(axis: 0)
#  => [ 3.0, NaN, NaN ]
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
a.zero          #  => [ [ 0.0,   _, 0.0 ], [ 0.0, 0.0, 0.0 ] ]
a.fill_copy(0)  #  => [ [ 0.0, 0.0, 0.0 ], [ 0.0, 0.0, 0.0 ] ]
```

Because a view shares the mask rather than a copy of it, masking a cell through
a view masks it in the source:

```ruby
row = a[0, nil]
row[0] = UNDEF
a.count_masked    #  => 2
```
