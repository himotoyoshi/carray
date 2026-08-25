# Reduction and statistics

A reduction combines many elements into fewer — for example, summing an array
down to a single number. CArray can reduce over the whole array, or along one or
more chosen axes.

## Over the whole array

With no arguments, a reduction returns a single value.

```ruby
a = CA_DOUBLE([2, 4, 6])

a.sum        #  => 12.0
a.prod       #  => 48.0
a.min        #  => 2.0
a.max        #  => 6.0
a.mean       #  => 4.0
a.variance   #  => 4.0
a.stddev     #  => 2.0
```

The common reductions are `sum`, `prod`, `min`, `max`, `mean`, `variance`,
`stddev`. (`sum` and `mean` return a floating-point value even for an integer
array, which is why the results above print with a `.0`.)

### Each reduction on its own

The individual behaviours, shown on small concrete arrays:

```ruby
CA_DOUBLE([1, 2, 3, 4]).sum        #  => 10.0
CA_DOUBLE([1, 2, 3, 4]).prod       #  => 24.0
CA_DOUBLE([3, 1, 4, 1, 5]).min     #  => 1.0
CA_DOUBLE([3, 1, 4, 1, 5]).max     #  => 5.0
CA_DOUBLE([2, 4, 4, 4, 5, 5, 7, 9]).mean       #  => 5.0
CA_DOUBLE([0, 2, 4, 6]).variance               #  => 6.666666666666667
CA_DOUBLE([0, 2, 4, 6]).stddev                 #  => 2.581988897471611
```

## Position of the extreme element

`min_index` and `max_index` give the *position* of the smallest or largest
element, not its value. With no arguments they return a flat (one-dimensional)
position; with `axis:` they reduce that axis and give the position within each
remaining slice.

```ruby
v = CA_INT([3, 1, 4, 1, 5, 9, 2, 6])
v.min_index    #  => 1     the first 1 lives at flat position 1
v.max_index    #  => 5     the 9 lives at flat position 5

m = CA_INT([[3, 1, 4],
            [1, 5, 9]])
m.min_index(axis: 0)   #  => [ 1, 0, 0 ]   per column: which row holds the min
m.max_index(axis: 1)   #  => [ 2, 2 ]      per row: which column holds the max
```

CArray uses the `_index` suffix throughout — there is no `argmin` / `argmax`.

## Order statistics: median, percentile, quantile

`median`, `percentile`, and `quantile` summarise the *distribution* of the
values rather than adding or multiplying them. Like the other reductions they
take `axis:` (and `keep_axis:`), and reduce over the whole array without it.

```ruby
v = CA_DOUBLE([3, 1, 4, 1, 5, 9, 2, 6])

v.median               #  => 3.5
v.percentile(50)       #  => 3.5
v.percentile(25, 50, 75)   #  => [ 1.75, 3.5, 5.25 ]     several at once
v.quantile             #  => [ 1.0, 1.75, 3.5, 5.25, 9.0 ]
```

- `median` returns the middle value (the mean of the two middle values when the
  count is even).
- `percentile(p, …)` takes one or more percentile ranks in `0..100`; a single
  rank returns a scalar, several return an array in the order you asked.
- `quantile` takes no rank — it returns the five-number summary (minimum, lower
  quartile, median, upper quartile, maximum), i.e. `percentile(0, 25, 50, 75, 100)`.

Along an axis, each behaves like the other reductions — the chosen axis is
removed and the statistic is computed per slab:

```ruby
m = CA_DOUBLE([[1, 2, 3, 4],
               [5, 6, 7, 8]])
m.median(axis: 1)      #  => [ 2.5, 6.5 ]
```

An order statistic has no answer for an empty distribution, so — like `mean` —
an empty array, or a zero-length reduction axis, gives `UNDEF` (never a raise):

```ruby
CA_DOUBLE([]).median                    #  => UNDEF
CArray.float64(0, 3).median(axis: 0)    #  => [ UNDEF, UNDEF, UNDEF ]
```

> **Current limitation:** the *whole-array* forms handle a mask — `data.median`
> and `data.percentile(50)` reduce over the present values and skip the missing
> ones — but the *per-axis* forms do not yet accept a masked input:
> `data.median(axis: 1)` on an array that carries a mask raises rather than
> reducing each slab over its present values. For now, reduce masked data with
> the whole-array form, or strip the mask first (see
> [Masks and missing values](05_masks.md)).

(To *generate* random arrays rather than summarise them, see `random!` in
[Creating arrays](01_creating_arrays.md).)

## Counting

`count(v)` counts how many elements equal `v`. `count_masked` and
`count_not_masked` count the missing and present elements (see
[Masks](05_masks.md) for what "masked" means).

```ruby
a = CA_INT([1, 2, 2, 3, 2, 4])
a.count(2)            #  => 3
a.count(5)            #  => 0

a.count_masked        #  => 0
a.count_not_masked    #  => 6
```

## Along an axis

Pass `axis:` to reduce along a particular axis. The result has that axis removed.
For a 2-D array, `axis: 0` collapses the rows (giving a per-column result) and
`axis: 1` collapses the columns (giving a per-row result).

```ruby
m = CArray.int32(2, 3).seq
#  => [ [ 0, 1, 2 ],
#       [ 3, 4, 5 ] ]

m.sum(axis: 0)    #  => [ 3.0, 5.0, 7.0 ]   sum down each column
m.sum(axis: 1)    #  => [ 3.0, 12.0 ]       sum across each row
```

The same `axis:` works for every reduction:

```ruby
m.mean(axis: 0)   #  => [ 1.5, 2.5, 3.5 ]
m.max(axis: 1)    #  => [ 2, 5 ]
m.min(axis: 0)    #  => [ 0, 1, 2 ]
m.prod(axis: 1)   #  => [ 0.0, 60.0 ]
m.stddev(axis: 0) #  => [ 2.1213203435596424, 2.1213203435596424, 2.1213203435596424 ]
```

## Reducing a higher-dimensional array

The same rules extend to any number of axes. Here is a 2x2x2 array:

```ruby
c = CArray.int32(2, 2, 2).seq
#  => [ [ [ 0, 1 ],
#         [ 2, 3 ] ],
#       [ [ 4, 5 ],
#         [ 6, 7 ] ] ]

c.sum(axis: 0)
#  => [ [ 4.0,  6.0 ],
#       [ 8.0, 10.0 ] ]    axis 0 removed, a 2x2 result

c.sum(axis: 1)
#  => [ [  2.0,  4.0 ],
#       [ 10.0, 12.0 ] ]   axis 1 removed

c.sum(axis: 2)
#  => [ [ 1.0,  5.0 ],
#       [ 9.0, 13.0 ] ]    axis 2 removed

c.max(axis: 2)
#  => [ [ 1, 3 ],
#       [ 5, 7 ] ]
```

You can reduce several axes at once by passing an array of axis numbers. The
listed axes are all removed:

```ruby
c.sum(axis: [1, 2])
#  => [ 6.0, 22.0 ]    axes 1 and 2 removed, a length-2 result

c.sum(axis: [0, 1])
#  => [ 12.0, 16.0 ]   axes 0 and 1 removed
```

## Keeping the reduced axis with `keep_axis:`

By default, the axis you reduce along disappears from the result — that is why
`m.sum(axis: 1)` on a `[2, 3]` array gives a `[2]` array. Pass
`keep_axis: true` to keep it as a size-1 axis instead. The result then has the
same `ndim` as the input, and broadcasts cleanly against the original.

```ruby
m = CArray.int32(2, 3).seq
#  => [ [ 0, 1, 2 ],
#       [ 3, 4, 5 ] ]

m.sum(axis: 1).shape                       #  => [2]
m.sum(axis: 1, keep_axis: true).shape      #  => [2, 1]

m.sum(axis: 1, keep_axis: true)
#  => [ [  3 ],
#       [ 12 ] ]                            shape [2, 1] — a column

m.sum(axis: 0, keep_axis: true)
#  => [ [ 3, 5, 7 ] ]                       shape [1, 3] — a row
```

The point is broadcasting (see [Broadcasting](07_broadcasting.md)). With
`keep_axis: true`, the reduced result has size 1 along the axis you collapsed,
so it lines up automatically with the original — no need to insert the axis
back manually with `:_`.

**Subtract the row mean from each row** — the canonical use:

```ruby
x = CA_DOUBLE([[1, 2, 3],
               [4, 5, 6]])

x.mean(axis: 1, keep_axis: true)
#  => [ [ 2.0 ],
#       [ 5.0 ] ]                           shape [2, 1]

x - x.mean(axis: 1, keep_axis: true)
#  => [ [ -1.0, 0.0, 1.0 ],
#       [ -1.0, 0.0, 1.0 ] ]
```

Without `keep_axis:` you'd write `x - x.mean(axis: 1)[nil, :_]` — same result,
one more step.

**Normalise each row by its sum:**

```ruby
totals = x.sum(axis: 1, keep_axis: true)
#  => [ [  6.0 ],
#       [ 15.0 ] ]

x / totals
#  => [ [ 0.1667, 0.3333, 0.5 ],
#       [ 0.2667, 0.3333, 0.4 ] ]    each row sums to 1
```

**3-D arrays.** `keep_axis: true` works with multi-axis reductions too — each
reduced axis becomes size 1, leaving the other axes untouched.

```ruby
c = CArray.int32(2, 3, 4).seq

c.mean(axis: 1, keep_axis: true).shape       #  => [2, 1, 4]
c.mean(axis: [0, 2], keep_axis: true).shape  #  => [1, 3, 1]
```

`keep_axis:` is accepted by every reduction that takes `axis:` — `sum`,
`prod`, `min`, `max`, `mean`, `variance`, `stddev`, `min_index`, `max_index`,
`count`, `count_masked`, `count_not_masked`, `accumulate`.

## Weighted reductions and frequency tables

`wsum` and `wmean` are the *weighted* sum and mean: each element is scaled by a
matching weight before it is combined. `wmean(w)` is `sum(v * w) / sum(w)`.

```ruby
v = CA_DOUBLE([1, 2, 3, 4])
w = CA_DOUBLE([4, 3, 2, 1])

v.wsum(w)     #  => 20.0    1*4 + 2*3 + 3*2 + 4*1
v.wmean(w)    #  => 2.0     20.0 / (4 + 3 + 2 + 1)
```

A natural use is a **frequency table**. `bincount` (see
[Histograms](25_histograms.md)) counts how often each value `0, 1, 2, …` occurs:
the *index* is the value and the entry is its count. The mean of the original
data is then the weighted mean of the values by their counts — and `index` hands
you the value axis directly:

```ruby
data = CA_INT([1, 2, 2, 2, 0, 0, 0, 2, 1, 2, 0, 0, 0, 3, 2, 3, 2, 1, 0, 0, 0])
freq = data.bincount           #  => [ 9, 3, 7, 2 ]   counts of 0, 1, 2, 3

freq.index.wmean(freq)         #  => 1.0952380952380953
data.mean                      #  => 1.0952380952380953   the same, computed directly
```

### Higher moments, per axis

Only `wsum` and `wmean` are built in, but every higher moment (variance,
skewness, …) is a weighted sum of powers of `(value - mean)`, so you can build
them from the same pieces. Two tools make the per-axis form clean: `seq(axis: k)`
lays the value axis out at the shape of the frequency table, and
`keep_axis: true` keeps the running mean lined up for the subtraction.

```ruby
freq = CA_INT([[10, 0, 0, 0],     # each row is one frequency distribution
               [ 0, 0, 0, 10],
               [ 9, 3, 7, 2]])

val  = CArray.int32(*freq.shape).seq(axis: 1)   # value axis: every row is 0, 1, 2, 3
wtot = freq.sum(axis: 1, keep_axis: true)       # total count per row, shape [3, 1]

mean = (val * freq).sum(axis: 1, keep_axis: true) / wtot
#  => [ [ 0.0 ], [ 3.0 ], [ 1.0952 ] ]          shape [3, 1]

dev  = val - mean                               # [3, 4] - [3, 1] broadcasts, no manual :_
var  = (freq * dev**2).sum(axis: 1, keep_axis: true) / wtot
#  => [ [ 0.0 ], [ 0.0 ], [ 1.1338 ] ]          population variance per row
```

`keep_axis: true` is what keeps this tidy: the running `mean` stays shape
`[3, 1]`, so `val - mean` lines up against the `[3, 4]` value axis on its own —
without it you would reinsert the axis by hand as `mean[nil, :_]`. The higher
central moments follow the same shape: `(freq * dev**3).sum(…) / wtot` for the
third, `dev**4` for the fourth. A row whose counts sum to zero, or whose spread
is zero, yields `NaN` from the `0/0` — the honest answer where the moment is
undefined.

> **`index` gives the value axis only for a 1-D table.** For an N-D frequency
> table, `freq.index` is not the per-row value axis, so build it with
> `seq(axis: k)` as above.

## Cumulative reductions (prefix scans)

`cumsum` and `cumcount` are *running* totals — at each position they hold the
result for everything up to and including that position. With no argument they
flatten the array first and return a 1-D running total; with `axis:` they run
along that axis and keep the array's shape.

```ruby
v = CA_INT([1, 2, 3, 4])
v.cumsum            #  => [ 1.0, 3.0, 6.0, 10.0 ]

m = CArray.int32(2, 3).seq
#  => [ [ 0, 1, 2 ],
#       [ 3, 4, 5 ] ]

m.cumsum            #  flatten first, then run
#  => [ 0.0, 1.0, 3.0, 6.0, 10.0, 15.0 ]

m.cumsum(axis: 0)   #  run down each column
#  => [ [ 0.0, 1.0, 2.0 ],
#       [ 3.0, 5.0, 7.0 ] ]

m.cumsum(axis: 1)   #  run across each row
#  => [ [ 0.0, 1.0, 3.0 ],
#       [ 3.0, 7.0, 12.0 ] ]
```

`cumcount` counts present (non-masked) elements as it goes:

```ruby
m.cumcount(axis: 1)
#  => [ [ 1, 2, 3 ],
#       [ 1, 2, 3 ] ]    no masked elements, so each row counts 1, 2, 3
```

Multi-axis cumulative is not supported directly because it is ambiguous (a
flattened running sum, or a 2-D summed-area table?). Chain instead when you
mean the latter: `m.cumsum(axis: 0).cumsum(axis: 1)`.

## Reductions on a masked array

If an array carries a mask (see [Masks and missing values](05_masks.md)), the
masked elements are left out of reductions automatically. A masked sum adds only
the present values; a masked mean divides by the count of present values.

```ruby
a = CArray.float64(2, 3).seq
a[0, 1] = UNDEF
a[1, 2] = UNDEF
a
#  => [ [ 0.0,   _, 2.0 ],
#       [ 3.0, 4.0,   _ ] ]

a.sum                 #  => 9.0      0 + 2 + 3 + 4
a.mean                #  => 2.25     9 / 4 present elements
a.count_not_masked    #  => 4
a.count_masked        #  => 2
a.count(3.0)          #  => 1        present elements only

a.mean(axis: 0)       #  => [ 1.5, 4.0, 2.0 ]   per-column means of present
a.mean(axis: 1)       #  => [ 1.0, 3.5 ]        per-row means of present
```

`cumsum` and `cumcount` step over masked elements — at a masked position the
running total is carried forward unchanged:

```ruby
a.cumsum
#  => [ 0.0, 0.0, 2.0, 5.0, 9.0, 9.0 ]    flat scan; mask positions hold the prior acc

a.cumcount
#  => [ 1, 1, 2, 3, 4, 4 ]                same idea, counting only present cells
```

## When there is nothing to reduce

A reduction can end up with **no elements to fold** — either the array is empty,
or every element is masked. What comes back depends on whether the reduction has
a natural "empty" answer:

```ruby
CA_FLOAT64([]).sum        #  => 0.0     the sum of no numbers is 0
CA_FLOAT64([]).prod       #  => 1.0     the product of no numbers is 1
CA_FLOAT64([]).count(1.0) #  => 0       zero matches among no elements
CA_FLOAT64([]).min        #  => UNDEF   the minimum of no numbers has no value
CA_FLOAT64([]).mean       #  => UNDEF   0 / 0 is undefined
```

An all-masked array behaves exactly like an empty one — masked cells are left
out, so folding what remains folds nothing:

```ruby
a = CA_FLOAT64([1, 2, 3])
a[] = UNDEF               # mask every cell
a.sum                     #  => 0.0     same as CA_FLOAT64([]).sum
a.min                     #  => UNDEF
```

The rule is consistent: a reduction with an identity element returns it
(`sum` / `accumulate` / `wsum` → `0`, `prod` → `1`, `count` → `0`), and a
reduction without one returns `UNDEF` — `min` / `max`, the ratio statistics
`mean` / `variance` / `stddev`, and the order statistics `median` / `percentile`
/ `quantile` (a middle value of nothing has no answer). This mirrors the masked
case above: `sum` already skips masked cells, so a sum over *nothing left* is
`0`.

Per axis, this applies slab by slab — an all-masked slab yields the identity (or
`UNDEF`), as a normal, unmasked result cell:

```ruby
m = CArray.float64(3, 2) { |i, j| i * 2.0 + j }
m[1, nil] = UNDEF                 # mask the middle row
m.sum(axis: 1)                    #  => [ 1.0, 0.0, 9.0 ]   masked row -> 0
m.sum(axis: 1).has_mask?          #  => false
```

### Requiring present data with `min_count:`

If you would rather treat "nothing to reduce" (or "too little to trust") as a
missing result, pass `min_count:` — the reduction returns `UNDEF` unless at
least that many present (unmasked) cells contributed:

```ruby
CA_FLOAT64([]).sum(min_count: 1)  #  => UNDEF   0 present < 1 required

a = CA_FLOAT64([1, 2, 3])
a[] = UNDEF
a.sum(min_count: 1)               #  => UNDEF   all masked, 0 present
```

### Supplying a fallback with `fill_value:`

When a reduction would return `UNDEF` — the no-answer reductions on empty input
(`min` / `max` / `mean` / `median` / …), or any cell knocked out by `min_count:`
— pass `fill_value:` to substitute a value instead. This is the lightweight way
to say "…but use this if there was nothing to work with," and it works on both
the whole-array and per-axis forms:

```ruby
CA_FLOAT64([]).mean(fill_value: 0.0)   #  => 0.0     instead of UNDEF
CA_FLOAT64([]).min(fill_value: -1.0)   #  => -1.0

m = CArray.float64(3, 2) { |i, j| i * 2.0 + j }
m[1, nil] = UNDEF
m.sum(axis: 1, min_count: 1, fill_value: -1)   #  => [ 1.0, -1.0, 9.0 ]
```

`fill_value:` only ever replaces `UNDEF` cells; a defined identity (an empty
`sum` of `0`) is never `UNDEF`, so there is nothing to fill there.

> **Careful — do not test a scalar result with `if`.** `UNDEF` is *truthy* in
> Ruby (only `nil` and `false` are false), so `if v = a.mean; … end` treats an
> empty/all-masked result as if it were present. Reach for `fill_value:` at the
> call site, or compare explicitly with `v == UNDEF`, instead of relying on truth
> value. (Search-style lookups such as `a.search(v)` return `nil`, not `UNDEF`,
> for "not found" — see [Masks and missing values](05_masks.md) for why the two
> differ.)

## `accumulate` — sum that keeps the input type

`accumulate` is `sum`, but its result keeps the input data type instead of
widening to `float64`. Use it when you specifically want to stay in integer (or
in another exact type) rather than land in floating-point.

```ruby
m = CA_INT([[1, 2, 3],
            [4, 5, 6]])

m.sum                  #  => 21.0      a Float
m.accumulate           #  => 21        an Integer

m.sum(axis: 0).data_type         #  => :float64
m.accumulate(axis: 0).data_type  #  => :int32

m.accumulate(axis: 0)  #  => [ 5, 7, 9 ]
```

## Method reference

The reduction and statistics methods covered above, with their argument forms.
Every method shown takes `axis:` as an optional keyword argument; passing it
collapses that axis (or those axes) and returns an array with the chosen axis
removed. Without `axis:`, the result is a single value over the whole array.

### Scalar reductions

| Method                | Argument form                        | Returns                                       |
|-----------------------|--------------------------------------|-----------------------------------------------|
| `sum`                 | `sum(axis: k)` or `sum(axis: [k, …])`| Sum; widens to `float64`                      |
| `prod`                | `prod(axis: k)`                      | Product; widens to `float64`                  |
| `min`                 | `min(axis: k)`                       | Minimum, in the input type                    |
| `max`                 | `max(axis: k)`                       | Maximum, in the input type                    |
| `mean`                | `mean(axis: k)`                      | Arithmetic mean as `float64`                  |
| `variance`            | `variance(axis: k)`                  | Sample variance as `float64`                  |
| `stddev`              | `stddev(axis: k)`                    | Sample standard deviation as `float64`        |
| `wsum`                | `wsum(weights, axis: k)`             | Weighted sum as `float64`; `weights` is a per-element weight the same shape as the array |
| `wmean`               | `wmean(weights, axis: k)`            | Weighted mean `sum(v*w)/sum(w)` as `float64`  |
| `accumulate`          | `accumulate(axis: k)`                | Sum that keeps the input data type            |
| `median`              | `median(axis: k)`                    | Middle value as `float64`                     |
| `percentile`          | `percentile(p, …, axis: k)`          | One or more percentile ranks in `0..100`; scalar for one rank, array for several |
| `quantile`            | `quantile(axis: k)`                  | Five-number summary `[min, Q1, median, Q3, max]` |

### Position reductions

| Method        | Argument form          | Returns                                                       |
|---------------|------------------------|---------------------------------------------------------------|
| `min_index`   | `min_index(axis: k)`   | Without `axis:`, a single `Integer` — the **flat position** of the minimum in row-major order. With `axis:`, an array of axis-local positions, shape = source shape with `k` removed. |
| `max_index`   | `max_index(axis: k)`   | Same as `min_index`, for the maximum.                         |

### Counting

| Method             | Argument form                  | Returns                                                                    |
|--------------------|--------------------------------|----------------------------------------------------------------------------|
| `count`            | `count(value, axis: k)`        | Number of elements equal to `value`. `value` may be a scalar, `true`/`false` (for boolean arrays), or a same-shape CArray (compared element-wise). |
| `count_masked`     | `count_masked(axis: k)`        | Number of masked (missing) elements.                                       |
| `count_not_masked` | `count_not_masked(axis: k)`    | Number of present (non-masked) elements.                                   |

### Cumulative scans

Scan methods produce an array of the same shape as the input. `axis:` selects
the single axis to scan along (not a list — multi-axis cumulative semantics are
ambiguous; chain two scans if you really want that).

| Method      | Argument form         | Returns                                                                   |
|-------------|-----------------------|---------------------------------------------------------------------------|
| `cumsum`    | `cumsum(axis: k)`     | Running sum. Without `axis:`, a flattened 1-D scan over the whole array.  |
| `cumcount`  | `cumcount(axis: k)`   | Running count of present (non-masked) cells.                              |

### Notes on `axis:` and `keep_axis:`

* `axis: k` (a single integer) — collapse the one axis `k`.
* `axis: [k1, k2, …]` (an array) — collapse several axes at once. Supported by
  the scalar reductions (`sum`, `prod`, `min`, `max`, `mean`, `variance`,
  `stddev`, `accumulate`) and the counting methods. Not supported by
  cumulative scans.
* Without `axis:` — reduce over the whole array.
* Negative axis numbers count from the last axis (`-1` is the last axis).
* `keep_axis: true` — keep each reduced axis as a size-1 axis instead of
  removing it. The result then has the same `ndim` as the input and broadcasts
  cleanly back against it (`x - x.mean(axis: 1, keep_axis: true)`). Accepted
  by every reduction that takes `axis:`. Not applicable to cumulative scans
  (their output already has the same shape as the input).

