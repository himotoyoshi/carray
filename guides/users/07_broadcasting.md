# Broadcasting

Broadcasting is the rule for combining arrays whose shapes are not identical. In
an element-wise operation, an axis of size 1 in one operand is stretched to match
the corresponding axis of the other, so that the two line up element for element.

All examples use:

```ruby
a = CArray.int32(2, 3).seq
#  => [ [ 0, 1, 2 ],
#       [ 3, 4, 5 ] ]
```

## A scalar against an array

The simplest case: a scalar applies to every element.

```ruby
a + 10
#  => [ [ 10, 11, 12 ],
#       [ 13, 14, 15 ] ]
```

The same rule applies regardless of the array's data type. A scalar is just
broadcast across every element:

```ruby
a * 2
#  => [ [ 0, 2,  4 ],
#       [ 6, 8, 10 ] ]

f = CArray.float64(2, 3).seq
f + 0.5
#  => [ [ 0.5, 1.5, 2.5 ],
#       [ 3.5, 4.5, 5.5 ] ]

f / 2.0
#  => [ [ 0.0, 0.5, 1.0 ],
#       [ 1.5, 2.0, 2.5 ] ]
```

Comparisons against a scalar broadcast in exactly the same way, producing a
boolean array of the same shape (see [Element-wise operations](03_elementwise.md)):

```ruby
a > 2
#  => [ [ 0, 0, 0 ],
#       [ 1, 1, 1 ] ]
```

## A size-1 axis stretched to match

When two arrays have the same number of axes and one of them has size 1 along an
axis, that axis is stretched to match the other.

A column (shape `[2, 1]`) is stretched across the three columns of `a`:

```ruby
col = CA_INT([[10], [20]])      #  shape [2, 1]
#  => [ [ 10 ],
#       [ 20 ] ]

a + col
#  => [ [ 10, 11, 12 ],
#       [ 23, 24, 25 ] ]    10 added to row 0, 20 added to row 1
```

A row (shape `[1, 3]`) is stretched across the two rows of `a`:

```ruby
row = CA_INT([[100, 200, 300]])     #  shape [1, 3]
#  => [ [ 100, 200, 300 ] ]

a + row
#  => [ [ 100, 201, 302 ],
#       [ 103, 204, 305 ] ]    the same three values added to each row
```

The same stretching works for any operation, not just `+`. Multiplication by a
column scales each row by a different factor:

```ruby
factor = CA_INT([[1], [10]])        #  shape [2, 1]

a * factor
#  => [ [  0,  1,  2 ],
#       [ 30, 40, 50 ] ]    row 0 unchanged, row 1 multiplied by 10
```

And two size-1 axes in different positions stretch in both directions at once.
Here a column of shape `[2, 1]` meets a row of shape `[1, 3]`, and the result
takes the full `[2, 3]` shape — every column entry is combined with every row
entry. This is the **outer product** idiom:

```ruby
col = CA_INT([[1], [2]])            #  shape [2, 1]
row = CA_INT([[10, 20, 30]])        #  shape [1, 3]

col * row
#  => [ [ 10, 20, 30 ],
#       [ 20, 40, 60 ] ]
```

## Comparisons broadcast too

A comparison between an array and a size-1 slice stretches just like an
arithmetic operation, returning a boolean array of the broadcast shape. This is
the natural way to ask "for each row, which elements exceed that row's
threshold?":

```ruby
threshold = CA_INT([[1], [4]])      #  shape [2, 1] — one threshold per row

a > threshold
#  => [ [ 0, 0, 1 ],
#       [ 0, 0, 1 ] ]    row 0 against 1, row 1 against 4
```

The boolean result can then be used as a mask or as an index — see
[Indexing and slicing](02_indexing_and_slicing.md).

## Axes are never added implicitly

CArray broadcasting only stretches size-1 axes. It never invents new axes to make
two arrays line up. So two arrays with a *different number of axes* do not combine
automatically — that is reported as an error rather than guessed at.

```ruby
v = CA_INT([100, 200, 300])    #  shape [3] — one axis

a + v
#  => RuntimeError: elements mismatch (6 <-> 3)
```

This is a deliberate choice: a 1-D array of length 3 could mean either a row or a
column, so CArray asks you to say which.

The same applies in higher dimensions. A 3-D array does not silently combine
with a 2-D array even if the trailing axes happen to match:

```ruby
a3 = CArray.int32(2, 3, 4).seq    #  shape [2, 3, 4]
b2 = CArray.int32(3, 4).seq       #  shape [3, 4]

a3 + b2
#  => RuntimeError: elements mismatch (24 <-> 12)
```

## Adding an axis when you mean to

Add the size-1 axis explicitly with `:_` in the index. `:_` introduces a new axis
of size 1 at that position, turning a 1-D array into a row or a column.

```ruby
v = CA_INT([100, 200, 300])    #  shape [3]

v[:_, nil].shape    #  => [1, 3]   a row
v[nil, :_].shape    #  => [3, 1]   a column
```

With the axis made explicit, broadcasting applies as above:

```ruby
a + v[:_, nil]      #  treat v as a row and add it to each row of a
#  => [ [ 100, 201, 302 ],
#       [ 103, 204, 305 ] ]
```

The same fix works for the 3-D / 2-D case. To add a `[3, 4]` plane to every
slice of a `[2, 3, 4]` array, give it a leading size-1 axis:

```ruby
a3 = CArray.int32(2, 3, 4).seq    #  shape [2, 3, 4]
b2 = CArray.int32(3, 4).seq       #  shape [3, 4]

(a3 + b2[:_, nil, nil]).shape     #  => [2, 3, 4]
```

`:_` can appear anywhere — it always inserts a new size-1 axis at that
position, and the surrounding `nil`s keep the existing axes:

```ruby
v = CA_INT([1, 2, 3, 4])

v[:_, nil].shape    #  => [1, 4]
v[nil, :_].shape    #  => [4, 1]
```

### Reading `[nil, :_, nil]` and friends

When `:_` appears inside an index expression, it sits *between* the existing
axes and inserts a new size-1 axis at that position. The `nil`s mark the
**existing** axes (each `nil` means "keep this whole axis"); the `:_` marks
the **new** size-1 axis being introduced.

So for a 2-D array `m` with shape `[2, 3]`:

```ruby
m = CArray.int32(2, 3).seq          #  shape [2, 3]

m[:_, nil, nil].shape    #  => [1, 2, 3]    new axis added at the front
m[nil, :_, nil].shape    #  => [2, 1, 3]    new axis inserted between axes 0 and 1
m[nil, nil, :_].shape    #  => [2, 3, 1]    new axis added at the end
```

Reading `m[nil, :_, nil]` left to right: "keep axis 0, then insert a new
size-1 axis, then keep axis 1". The total number of `nil`s in the expression
always equals the original `ndim`; each `:_` increases the resulting `ndim`
by one.

The same applies to a 1-D vector — `:_` chooses *which* size-1 axis you are
introducing:

```ruby
v = CA_INT([1, 2, 3])

v[:_, nil].shape    #  => [1, 3]    add a leading axis (a "row")
v[nil, :_].shape    #  => [3, 1]    add a trailing axis (a "column")
```

You can use several `:_`s in one expression to add several axes at once:

```ruby
v[:_, nil, :_].shape    #  => [1, 3, 1]
```

### `insert_axis` — the same effect, as a method

`insert_axis(*axes)` does exactly what the `:_` form does, but as a regular
method call. Each argument names the existing axis that the new size-1 axis is
inserted *before*; `-1` (or `ndim`) appends at the very end. The positions refer
to the *original* axes, so giving several does not shift them around.

```ruby
a = CArray.int32(2, 3).seq          #  shape [2, 3]

a.insert_axis(0).shape       #  => [1, 2, 3]      before axis 0
a.insert_axis(-1).shape      #  => [2, 3, 1]      at the end
a.insert_axis(1).shape       #  => [2, 1, 3]      before axis 1
a.insert_axis(0, 1).shape    #  => [1, 2, 1, 3]   before axis 0 and before axis 1
a.insert_axis(0, -1).shape   #  => [1, 2, 3, 1]   before axis 0 and at the end
```

Both forms return a view onto the same storage — no data is copied; the new
axes only exist in the shape.

```ruby
v = CA_INT([1, 2, 3])

v.insert_axis(0)
#  => [ [ 1, 2, 3 ] ]              shape [1, 3]

v.insert_axis(-1)
#  => [ [ 1 ],
#       [ 2 ],
#       [ 3 ] ]                    shape [3, 1]
```

Use `:_` when you are already inside an index expression and the visual layout
makes the position clear; use `insert_axis` when you want to name the
operation explicitly or are chaining method calls.

## The outer-product idiom

A common use of `:_` is to turn two 1-D vectors into a column and a row and
combine them — the result is the "outer" combination of every pair.

```ruby
v = CA_INT([1, 2, 3, 4])     #  shape [4]
w = CA_INT([10, 20, 30])     #  shape [3]

v[nil, :_] * w[:_, nil]
#  => [ [ 10, 20, 30 ],
#       [ 20, 40, 60 ],
#       [ 30, 60, 90 ],
#       [ 40, 80, 120 ] ]
```

The same pattern works for any operation: `v[nil, :_] + w[:_, nil]` gives an
outer sum, `v[nil, :_].lt(w[:_, nil])` gives an outer comparison table, and so
on.

## Common patterns

A handful of recipes show up often. Each combines a per-axis reduction (see
[Reduction and statistics](04_reduction_and_statistics.md)) with broadcasting
back to the original shape.

**Normalise each row by its sum.** `b.sum(axis: 1)` collapses axis 1, giving a
1-D array of length 2 (one sum per row). Re-introduce the collapsed axis with
`:_` so it lines up as a column, then divide:

```ruby
b = CA_DOUBLE([[1, 2, 3],
               [4, 5, 6]])

row_sum = b.sum(axis: 1)            #  shape [2]
row_sum                              #  => [ 6.0, 15.0 ]

b / row_sum[nil, :_]
#  => [ [ 0.1667, 0.3333, 0.5    ],
#       [ 0.2667, 0.3333, 0.4    ] ]    each row sums to 1.0
```

**Subtract the column mean from each column.** `b.mean(axis: 0)` collapses the
rows, leaving one mean per column. Add a leading size-1 axis with `:_` to turn
it into a row that broadcasts down the columns:

```ruby
col_mean = b.mean(axis: 0)          #  shape [3]
col_mean                             #  => [ 2.5, 3.5, 4.5 ]

b - col_mean[:_, nil]
#  => [ [ -1.5, -1.5, -1.5 ],
#       [  1.5,  1.5,  1.5 ] ]
```

**Centre each row on its own mean.** The mirror image: reduce along axis 1 and
broadcast back as a column.

```ruby
row_mean = b.mean(axis: 1)          #  shape [2]
row_mean                             #  => [ 2.0, 5.0 ]

b - row_mean[nil, :_]
#  => [ [ -1.0, 0.0, 1.0 ],
#       [ -1.0, 0.0, 1.0 ] ]
```

**A per-row threshold check.** Combine a per-row reduction with a comparison:

```ruby
row_max = b.max(axis: 1)            #  shape [2]    => [ 3.0, 6.0 ]

b.eq(row_max[nil, :_])
#  => [ [ 0, 0, 1 ],
#       [ 0, 0, 1 ] ]    mark the max in each row
```

The pattern is always the same: reduce along an axis to collapse it, then bring
the size-1 axis back with `:_` so the reduced result broadcasts back over the
original shape.
