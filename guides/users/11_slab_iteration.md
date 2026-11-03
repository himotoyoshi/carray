# Slab iteration

CArray's reductions in [Reduction and statistics](04_reduction_and_statistics.md) cover the everyday cases — `sum`, `mean`, `min`, `max`, and so on, each with an optional `axis:`. For computations those built-ins do not provide, such as a trimmed mean, a custom normalisation, or an inject-style accumulation, use the **slab iterator**.

The slab iterator passes the array to a Ruby block one piece at a time. Each piece is cut out along the chosen axes. CArray walks every piece, and the block holds the computation.

Three methods share this surface:

| method          | what it does                                | what it returns                    |
|-----------------|---------------------------------------------|------------------------------------|
| `each_slab`     | runs the block for every slab               | `self`                             |
| `map_slab`      | builds a new array slab-by-slab             | an array shaped like `self`        |
| `reduce_slab`   | collapses each slab to a scalar             | `self.shape` with the slab axes removed |

A *slab* is the sub-array that `axis:` cuts out, and these methods pass it to their block. If `axis:` names one axis, the slab is a 1-D `CArray`. If `axis:` names several axes, the slab is a `CArray` with the shape of those axes (see [Higher-dimensional arrays](#higher-dimensional-arrays)). A slab is read-only: writing to it raises `RuntimeError`, and `map_slab` is the way to produce changed values. (With `init:`, the block of `reduce_slab` receives single elements instead; see below.)

## Picking a slab axis

A slab has the axes named in `axis:`. The other axes of the array select which slab the block receives. For a 3-D array:

```ruby
c = CArray.int32(2, 2, 3).seq
#  => [ [ [ 0, 1, 2 ],
#         [ 3, 4, 5 ] ],
#       [ [ 6, 7, 8 ],
#         [ 9, 10, 11 ] ] ]

c.each_slab(axis: 2) { |slab| p slab.to_a }
#  [0, 1, 2]
#  [3, 4, 5]
#  [6, 7, 8]
#  [9, 10, 11]

c.each_slab(axis: 0) { |slab| p slab.to_a }
#  [0, 6]
#  [1, 7]
#  [2, 8]
#  [3, 9]
#  [4, 10]
#  [5, 11]

c.each_slab(axis: [0, 2]) { |slab| p slab.to_a }
#  [[0, 1, 2], [6, 7, 8]]
#  [[3, 4, 5], [9, 10, 11]]
```

Negative numbers count from the end, so `axis: -1` is the last axis. It is often the most useful choice and also the fastest, because the slab lives in contiguous memory.

## `each_slab` — visit every slab

The examples above already use `each_slab`. It runs the block once for each slab and returns `self`. Use it for side-effects: printing, writing to a file, accumulating into something outside the array.

```ruby
m = CArray.int32(2, 3).seq
m.each_slab(axis: 1) { |slab| puts slab.sum }
#  3.0
#  12.0
```

Without a block, `each_slab` returns an enumerator, so methods such as `.map` and `.each_with_index` can follow it:

```ruby
m.each_slab(axis: 1).map { |slab| slab.sum }
#  => [3.0, 12.0]
```

`break`, `next`, and `return` work in the block as in a normal Ruby iterator.

## `map_slab` — build a new array, slab by slab

`map_slab` walks every slab the same way, but uses the block's return value to fill in the corresponding slab of a new output array. The output has the same shape as `self`.

The block can return one of two things:

* **a CArray of the same shape as the slab** — it is written to the output slab, or
* **a scalar** — it is broadcast across the whole output slab.

Centring each slab is a typical use of the first form:

```ruby
m = CA_DOUBLE([[1, 2, 3, 4],
               [5, 6, 7, 8]])

m.map_slab(axis: 1) { |slab| slab - slab.mean }
#  => [ [ -1.5, -0.5, 0.5, 1.5 ],
#       [ -1.5, -0.5, 0.5, 1.5 ] ]
```

Returning a scalar is convenient when every cell of the output slab should have the same value:

```ruby
m = CArray.int32(2, 3).seq
m.map_slab(axis: 1) { |slab| slab.sum }
#  => [ [ 3,  3,  3 ],
#       [ 12, 12, 12 ] ]
```

The output has the data type of the source, so values that do not fit it are cut down to it. Pass `data_type:` to choose another:

```ruby
m = CA_INT32([[1, 2],
              [4, 7]])

m.map_slab(axis: 1) { |slab| slab - slab.mean }
#  => [ [  0, 0 ],
#       [ -1, 1 ] ]

m.map_slab(axis: 1, data_type: :float64) { |slab| slab - slab.mean }
#  => [ [ -0.5, 0.5 ],
#       [ -1.5, 1.5 ] ]
```

Returning a CArray of a different shape, or a Ruby symbol when the output data type is numeric, raises `ArgumentError`.

## `reduce_slab` — collapse each slab to a scalar

`reduce_slab` reduces each slab to one value. The output has the slab axes removed, the same shape rule as `sum(axis: k)` and the other reductions from [Reduction and statistics](04_reduction_and_statistics.md). As with `map_slab`, the output has the data type of the source unless `data_type:` is given.

It has two forms.

### Without `init:` — the block receives a slab

The block receives one whole slab and returns a single scalar. This is the quick way to express a reduction that does not exist as a built-in:

```ruby
m = CA_DOUBLE([[1, 2, 3, 4],
               [5, 6, 7, 8]])

# range (max - min) of each slab
m.reduce_slab(axis: 1) { |slab| slab.max - slab.min }
#  => [ 3.0, 3.0 ]
```

The block must return a scalar — even a single-element CArray is rejected. Pull a value out with `slab[0]`, `slab.sum`, or another method that returns a plain Ruby value.

### With `init:` — the block receives each element

With `init:`, the block receives `(acc, x)` for every element in the slab, like Ruby's `Enumerable#inject`. CArray passes the elements in order, and the final `acc` of each slab becomes the output cell.

```ruby
m = CArray.int32(2, 3).seq
m.reduce_slab(axis: 0, init: 0) { |acc, x| acc + x }
#  => [ 3, 5, 7 ]
```

`init:` can be any Ruby object (use `data_type: :object` for non-numeric accumulators).

## Higher-dimensional arrays

The output of `reduce_slab` keeps the axes that are not in `axis:`, for any number of dimensions.

```ruby
c = CArray.int32(2, 2, 2).seq
#  => [ [ [ 0, 1 ],
#         [ 2, 3 ] ],
#       [ [ 4, 5 ],
#         [ 6, 7 ] ] ]

c.reduce_slab(axis: 2) { |slab| slab.sum }
#  => [ [ 1,  5 ],
#       [ 9, 13 ] ]    axis 2 collapsed, shape (2, 2) remains

c.reduce_slab(axis: 0) { |slab| slab.max }
#  => [ [ 4, 5 ],
#       [ 6, 7 ] ]
```

`axis:` also takes an array of axes: `c.reduce_slab(axis: [0, 2]) { |slab| slab.max }` gives `[ 5, 7 ]`. For reductions that the built-ins already cover (`sum`, `prod`, `min`, `max`, `mean`, `variance`, `stddev`, `accumulate`, `count`), pass the same `axis: [k1, k2, …]` to them directly; see [Reduction and statistics](04_reduction_and_statistics.md).

## Marking the slab axes in an index: `:>`

The indexer can also choose the slab axes. Write `:>` at the position of each slab axis. The result is a `CASlabIterator`, which has the same operations under shorter names:

```ruby
m = CArray.int32(2, 3).seq

m[nil, :>].each { |slab| p slab.to_a }
#  [0, 1, 2]
#  [3, 4, 5]

m[nil, :>].sum
#  => [ 3.0, 12.0 ]

c = CArray.int32(2, 3, 4).seq

c[:>, nil, :>].each { |slab| p slab.shape }
#  [2, 4]
#  [2, 4]
#  [2, 4]

c[:>, nil, :>].sum
#  => [ 60.0, 92.0, 124.0 ]
```

| with `axis:`                              | with `:>`                          |
|-------------------------------------------|------------------------------------|
| `m.each_slab(axis: 1) { ... }`            | `m[nil, :>].each { ... }`          |
| `m.map_slab(axis: 1) { ... }`             | `m[nil, :>].map { ... }`           |
| `m.reduce_slab(axis: 1) { ... }`          | `m[nil, :>].reduce { ... }`        |
| `m.reduce_slab(axis: 1, init: 0) { ... }` | `m[nil, :>].reduce(0) { ... }`     |
| `m.sum(axis: 1)`                          | `m[nil, :>].sum`                   |
| `c.sum(axis: [0, 2])`                     | `c[:>, nil, :>].sum`               |

`m[nil, :>]` corresponds to `axis: 1`, and `m[:>, nil]` corresponds to `axis: 0`. Several `:>` correspond to several axes: on a 3-D array, `c[:>, nil, :>]` corresponds to `axis: [0, 2]`.

The `map` method of `CASlabIterator` does not take `data_type:`. Use `map_slab` to choose the data type of the output. Assignment through `:>` raises `IndexError`.

[The iterator family](21_iterator_family.md) describes `CASlabIterator` together with the other iterators.

## Masks

A masked source array is passed straight through: the slab the block receives carries the mask, so masked cells show up as `UNDEF`. Any mask-aware method called on the slab (`sum`, `mean`, `count_not_masked`, …) skips them just as it would on a whole array (see [Masks and missing values](05_masks.md)). A masked cell of the array the `map_slab` block returns is masked in the result.

With `init:`, a masked cell reaches the block of `reduce_slab` as `UNDEF`, so the block has to skip it:

```ruby
masked = CA_DOUBLE([[1, 2, 3],
                    [4, 5, 6]])
masked[0, 1] = UNDEF

masked.reduce_slab(axis: 1, init: 0.0) { |acc, x| x.equal?(UNDEF) ? acc : acc + x }
#  => [ 4.0, 15.0 ]
```

If the missing cells should take a value instead, give them one first with `strip_mask`:

```ruby
masked.strip_mask(0.0).reduce_slab(axis: 1, init: 0.0) { |acc, x| acc + x }
#  => [ 4.0, 15.0 ]
```

## Relation to the built-in reductions

The reductions in [Reduction and statistics](04_reduction_and_statistics.md) are written in C, and `m.mean(axis: 1)` always computes the same thing. `reduce_slab` runs Ruby code for each slab, so it is slower but can compute anything. Prefer the built-ins for everyday reductions. Use the slab iterator for a reduction that does not exist as a built-in (a trimmed mean, a custom accumulation, a routine that combines several CArray operations).

## Copy a slab to use it after the block ends

The block receives the **same slab object on every iteration**. When the next iteration starts, that object shows the data of the next slab. This has no effect on code that uses the slab only inside the block.

If the slab itself is stored in something that remains after the block, every entry refers to the same object and shows the data of the *last* iteration.

```ruby
# WRONG — every entry ends up the same
refs = []
m.each_slab(axis: 1) { |slab| refs << slab }       # all entries are the same object

# RIGHT — take a snapshot in the block
slabs = []
m.each_slab(axis: 1) { |slab| slabs << slab.copy }
```

Use `slab.copy` or `slab.to_a` to keep a slab. `slab.dup` is not a snapshot: like any view's `dup` it shares the data, and on some axes it shows the last slab after the walk. This is the same rule as views in general — see [Views](06_views.md).

Results computed inside the block (`slab.sum`, `slab - 1`, `slab.median`) hold the current iteration's data and can be kept. A view of the slab, such as `slab[1..-1]`, reads the current data inside the block, but like the slab itself it must be copied to be kept.

The same holds for handing a slab to another library through MemoryView (`CArray.wrap_memory_view(slab)`, `Fiddle::MemoryView.new(slab)`, a C extension that reads it): inside the block it sees the current slab, but kept past the iteration it can see the next slab, or memory the walk has already freed. Give the library `slab.copy` if it keeps the data.

## A few worked examples

### Trimmed mean

This example drops the smallest and the largest value of each slab before it takes the mean. The value `100` does not affect the result.

```ruby
d = CA_DOUBLE([[1, 2, 3, 100],
               [5, 6, 7, 8]])

d.reduce_slab(axis: 1) { |slab| slab.sort[1..-2].mean }
#  => [ 2.5, 6.5 ]
```

### Z-score

```ruby
d = CA_DOUBLE([[1, 2, 3],
               [4, 8, 12]])

d.map_slab(axis: 1) { |slab| (slab - slab.mean) / slab.stddev }
#  => [ [ -1.0, 0.0, 1.0 ],
#       [ -1.0, 0.0, 1.0 ] ]
```

### Scaling each plane of a 3-D array

With `axis: [1, 2]`, each slab is one plane, and each plane is scaled by its own maximum.

```ruby
c = CA_DOUBLE([[[ 1,  2], [ 3,  4]],
               [[10, 20], [30, 40]]])

c.map_slab(axis: [1, 2]) { |slab| slab / slab.max }
#  => [ [ [ 0.25, 0.5 ],
#         [ 0.75, 1.0 ] ],
#       [ [ 0.25, 0.5 ],
#         [ 0.75, 1.0 ] ] ]
```

### Slope of a linear fit at each grid point

Here axis 0 is time, and axes 1 and 2 are the grid. Each slab is the time series of one grid point, and the result has the shape of the grid.

```ruby
g = CArray.float64(4, 2, 2) { |t, y, x| (y + x + 1) * t + 3.0 }

time = CArray.float64(4).seq
dt   = time - time.mean

g.reduce_slab(axis: 0) { |slab| (dt * (slab - slab.mean)).sum / (dt * dt).sum }
#  => [ [ 1.0, 2.0 ],
#       [ 2.0, 3.0 ] ]
```

### Evaluating polynomials

With `init:`, the block receives the cells in order, so the result can depend on that order. This example evaluates one polynomial for each slab at `x = 10`, with Horner's method. The first slab is `x**2 + 2*x + 3`.

```ruby
coefficients = CA_DOUBLE([[1, 2, 3],
                          [2, 0, 1]])

coefficients.reduce_slab(axis: 1, init: 0.0) { |acc, a| acc * 10.0 + a }
#  => [ 123.0, 201.0 ]
```

### Longest run above a threshold

The block can use any Ruby code. This example converts the slab to a Ruby Array and uses `Enumerable#chunk`.

```ruby
w = CA_DOUBLE([[1, 5, 6, 2, 7, 8, 9],
               [9, 9, 1, 1, 1, 9, 1]])

w.reduce_slab(axis: 1) { |slab|
  slab.to_a.chunk { |v| v > 4 }
           .select { |above, _| above }
           .map { |_, run| run.size }
           .max || 0
}
#  => [ 3.0, 2.0 ]
```

### Joining the strings of an object array

```ruby
names = CA_OBJECT([["a", "b", "c"],
                   ["x", "y", "z"]])

names.reduce_slab(axis: 1) { |slab| slab.to_a.join("-") }
#  => [ "a-b-c", "x-y-z" ]
```

### Requiring a minimum number of valid cells

The block can return `UNDEF`, and the output cell is then masked.

```ruby
masked = CA_DOUBLE([[1, 2, 3],
                    [4, 5, 6]])
masked[0, 1] = UNDEF
masked[0, 2] = UNDEF

masked.reduce_slab(axis: 1) { |slab| slab.count_not_masked >= 2 ? slab.mean : UNDEF }
#  => [ UNDEF, 5.0 ]
```

### Reporting each plane

Without a block, `each_slab` returns an enumerator, so `with_index` gives the number of each slab.

```ruby
c = CArray.int32(2, 2, 3).seq

c.each_slab(axis: [1, 2]).with_index { |slab, i| puts "plane #{i}: max = #{slab.max}" }
#  plane 0: max = 5
#  plane 1: max = 11
```

### Collecting slabs

```ruby
slabs = []
c.each_slab(axis: [1, 2]) { |slab| slabs << slab.copy }

slabs.map { |s| s.shape }
#  => [[2, 3], [2, 3]]
```
