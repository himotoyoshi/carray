# Reduction and statistics

A reduction combines many elements into fewer — for example, summing an array
down to a single number. CArray can reduce over the whole array, or along one or
more chosen axes.

## The reductions

With no arguments, a reduction returns a single value for the whole array.

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

Those seven are also the summary statistics you would want first of an array:
its total and its product, its extremes, its centre, and its spread.

`variance` and `stddev` are the sample statistics: they divide by one less than
the count. `variancep` and `stddevp` are the population pair, dividing by the
count itself.

```ruby
a = CA_DOUBLE([0, 2, 4, 6])

a.variance     #  => 6.666666666666667     divided by 3
a.variancep    #  => 5.0                   divided by 4
a.stddev       #  => 2.581988897471611
a.stddevp      #  => 2.23606797749979
```

## The type of the answer

Most reductions answer in `float64` whatever the array's own type is. That is
why the results above print with a `.0`, and it holds for integer input too:
the sum of an `int32` array is a Float, not an Integer. A total does not fit in
the type of the things being totalled — widening is what keeps it from
wrapping. `min` and `max` are the exceptions, since the answer is one of the
elements and comes back in the array's own type.

```ruby
i = CA_INT([1000000, 2000000, 3000000])

i.sum                #  => 6000000.0    a Float
i.sum.class          #  => Float
i.min                #  => 1000000      an Integer, from the array
```

`accumulate` is the sum without that widening: it answers in the array's own
type. The total then has nowhere to overflow into, so it wraps, and nothing
says that it did.

```ruby
a = CArray.int8(300).fill(1)     #  three hundred 1s

a.sum                            #  => 300.0
a.accumulate                     #  => 44       300 % 256
```

Reach for it only when that arithmetic is what you want.

## Locating the minimum and maximum

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

An order statistic has no answer for an empty distribution. Like `mean`, it
never raises there — see "When there is nothing to reduce" below.

(To *generate* random arrays rather than summarise them, see `random!` in
[Creating arrays](01_creating_arrays.md).)

## Counting

`count` with no argument is how many elements there are.

```ruby
a = CA_INT([1, 2, 2, 3, 2, 4])

a.count                     #  => 6
```

Given a value, it counts the elements equal to it:

```ruby
a.count(2)                  #  => 3
a.count(5)                  #  => 0
```

Given an array of values, it answers once for each of them, in that array's
shape — a small frequency table over the values you name:

```ruby
a.count(CA_INT([2, 4]))     #  => [ 3, 1 ]     how many 2s, how many 4s
```

`axis:` counts within each slab, as it does for the other reductions:

```ruby
m = CA_INT([[1, 2, 2],
            [3, 2, 4]])

m.count(2, axis: 1)         #  => [ 2, 1 ]     per row
```

### `bincount`

When the values are non-negative integers and you want every one of them
counted, `bincount` does it in a single pass. The result is indexed *by the
value*: entry `k` holds how many times `k` occurred.

```ruby
d = CA_INT([0, 1, 2, 2, 0, 1, 2, 0])

d.bincount                  #  => [ 3, 2, 3 ]    three 0s, two 1s, three 2s
```

The output stops at the largest value present. `length:` asks for a longer
one, so that tables built from different data line up:

```ruby
d.bincount(length: 5)       #  => [ 3, 2, 3, 0, 0 ]
```

`weights:` sums a weight per element instead of counting, and takes its data
type from the weights — the same walk, answering "how much" rather than "how
many":

```ruby
w = CA_DOUBLE([1, 1, 1, 1, 2, 2, 2, 2])

d.bincount(weights: w)      #  => [ 5.0, 3.0, 4.0 ]
```

The labels have to be non-negative integers: a negative label raises, and so
does a float array. [Histograms](25_histograms.md) covers binning values that
are not already small integers.

## Reducing along an axis

An array's axes are the directions you index it in, numbered from 0 in the
order you write them: in `a[i, j]`, `i` indexes axis 0 and `j` indexes axis 1.
For a two-dimensional array that makes axis 0 the one running down the rows and
axis 1 the one running across the columns. The last axis is the one whose
elements lie next to each other in memory, which is the order `seq!` fills in
and the order a flattened reduction walks.

Pass `axis:` to reduce along one of them. The reduction runs along that axis
and the axis is then gone from the result, so `axis: 0` collapses the rows and
leaves one value per column, while `axis: 1` collapses the columns and leaves
one per row.

```ruby
m = CArray.int32(2, 3).seq!
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

An array of axis numbers collapses several at once, as the next section shows.
The order statistics — `median`, `percentile`, `quantile` — take one axis only,
and so do the cumulative scans.

## Reducing a higher-dimensional array

The same rules extend to any number of axes. Here is a 2x2x2 array:

```ruby
c = CArray.int32(2, 2, 2).seq!
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

Reducing removes the axis, which is why `m.sum(axis: 1)` on a `[2, 3]` array
gives a `[2]` array. `keep_axis: true` keeps it, as an axis of length 1:

```ruby
m = CArray.int32(2, 3).seq!

m.sum(axis: 1).shape                       #  => [2]
m.sum(axis: 1, keep_axis: true).shape      #  => [2, 1]
```

The result then has as many axes as the array it came from, so it lines up
against that array without further work — which is the whole point of asking
for it:

```ruby
x = CA_DOUBLE([[1, 2, 3],
               [4, 5, 6]])

x - x.mean(axis: 1, keep_axis: true)       #  each row less its own mean
#  => [ [ -1.0, 0.0, 1.0 ],
#       [ -1.0, 0.0, 1.0 ] ]
```

Without it you would put the axis back by hand, writing
`x - x.mean(axis: 1)[nil, :_]`; [Broadcasting](07_broadcasting.md) is where
that form belongs. Multi-axis reductions take `keep_axis:` too — each reduced
axis becomes length 1 and the others are left alone.

Every reduction in this chapter accepts `keep_axis:`, apart from `count` used
without a value. The cumulative scans do not take it either, their output
already having the shape of the input.

## Weighted reductions and frequency tables

`wsum` and `wmean` are the *weighted* sum and mean: each element is scaled by a
matching weight before it is combined. `wmean(w)` is `sum(v * w) / sum(w)`.

```ruby
v = CA_DOUBLE([1, 2, 3, 4])
w = CA_DOUBLE([4, 3, 2, 1])

v.wsum(w)     #  => 20.0    1*4 + 2*3 + 3*2 + 4*1
v.wmean(w)    #  => 2.0     20.0 / (4 + 3 + 2 + 1)
```

A natural use is a frequency table. The mean of the original data is the
weighted mean of the values by their counts, and `index` hands you the value
axis that `bincount` counted along:

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

val  = CArray.int32(*freq.shape).seq!(axis: 1)   # value axis: every row is 0, 1, 2, 3
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

`cumsum` is a *running* total — at each position it holds the sum of everything
up to and including that position. With no argument they
flatten the array first and return a 1-D running total; with `axis:` they run
along that axis and keep the array's shape.

```ruby
v = CA_INT([1, 2, 3, 4])
v.cumsum            #  => [ 1.0, 3.0, 6.0, 10.0 ]

m = CArray.int32(2, 3).seq!
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

Multi-axis cumulative is not supported directly because it is ambiguous (a
flattened running sum, or a 2-D summed-area table?). Chain instead when you
mean the latter: `m.cumsum(axis: 0).cumsum(axis: 1)`.

## When there is nothing to reduce

An empty array has no elements to fold, and some reductions still answer:
adding no numbers gives 0, multiplying none gives 1, and none of them match
the value you asked to count.

```ruby
CA_FLOAT64([]).sum        #  => 0.0
CA_FLOAT64([]).prod       #  => 1.0
CA_FLOAT64([]).count(1.0) #  => 0
```

The rest have nothing to answer with. The smallest of no numbers is not a
number, and neither is their mean or their median, so what comes back is
`UNDEF` — the object CArray uses for a value that is not defined. It is not
Ruby's `nil`, and [Masks and missing values](05_masks.md) is where it is
properly introduced.

```ruby
CA_FLOAT64([]).min        #  => UNDEF
CA_FLOAT64([]).mean       #  => UNDEF
CA_FLOAT64([]).median     #  => UNDEF
```

`fill_value:` puts a value of your own choosing there instead:

```ruby
CA_FLOAT64([]).mean(fill_value: 0.0)   #  => 0.0
CA_FLOAT64([]).min(fill_value: -1.0)   #  => -1.0
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
| `variancep`           | `variancep(axis: k)`                 | Population variance as `float64`              |
| `stddevp`             | `stddevp(axis: k)`                   | Population standard deviation as `float64`    |
| `wsum`                | `wsum(weights, axis: k)`             | Weighted sum as `float64`; `weights` is a per-element weight the same shape as the array |
| `wmean`               | `wmean(weights, axis: k)`            | Weighted mean `sum(v*w)/sum(w)` as `float64`  |
| `accumulate`          | `accumulate(axis: k)`                | Sum that keeps the input data type; wraps at that type's width |
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
| `count`            | `count(axis: k)` or `count(value, axis: k)` | Without a value, the number of elements. With one, how many equal it; `value` may be a scalar, `true`/`false` for a boolean array, or a CArray of values, in which case the answer carries that array's shape. |
| `bincount`         | `bincount(length: 0, weights: nil)` | Counts per non-negative integer label, indexed by the label. `weights:` sums those instead of counting. Not a per-axis reduction. |

### Cumulative scans

Scan methods produce an array of the same shape as the input. `axis:` selects
the single axis to scan along (not a list — multi-axis cumulative semantics are
ambiguous; chain two scans if you really want that).

| Method      | Argument form         | Returns                                                                   |
|-------------|-----------------------|---------------------------------------------------------------------------|
| `cumsum`    | `cumsum(axis: k)`     | Running sum. Without `axis:`, a flattened 1-D scan over the whole array.  |

### Notes on `axis:` and `keep_axis:`

* `axis: k` (a single integer) — collapse the one axis `k`.
* `axis: [k1, k2, …]` (an array) — collapse several axes at once. Everything
  here takes it except the order statistics (`median`, `percentile`,
  `quantile`) and the cumulative scans, which take a single axis.
* Without `axis:` — reduce over the whole array.
* Negative axis numbers count from the last axis (`-1` is the last axis).
* `keep_axis: true` — keep each reduced axis as a size-1 axis instead of
  removing it. The result then has the same `ndim` as the input and broadcasts
  cleanly back against it (`x - x.mean(axis: 1, keep_axis: true)`). Every
  reduction takes it apart from `count` without a value; the cumulative scans do
  not, their output already having the shape of the input.

