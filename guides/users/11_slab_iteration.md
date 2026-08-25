# Per-slab iteration

CArray's reductions in [Reduction and statistics](04_reduction_and_statistics.md)
cover the everyday cases — `sum`, `mean`, `min`, `max`, and so on, each with an
optional `axis:`. When you want something those built-ins do not provide — a
median, a custom normalisation, a per-row sort, an inject-style accumulation —
you reach for the **slab iterator**.

The slab iterator gives you a small piece of the array at a time and lets you
write what to do in plain Ruby. The piece you get is a 1-D fiber along an axis
you choose. CArray walks every fiber for you; you just write the body.

A *slab* here means one such 1-D fiber. The name avoids the ambiguity of "along
axis k" — which could be read as either walking *along* k or walking *across*
the slices perpendicular to k. *Slab* means the fiber that the block sees.

Three methods share this surface:

| method          | what it does                                | what it returns                    |
|-----------------|---------------------------------------------|------------------------------------|
| `each_slab`     | runs the block for every slab               | `self`                             |
| `map_slab`      | builds a new array slab-by-slab             | an array shaped like `self`        |
| `reduce_slab`   | collapses each slab to a scalar             | `self.shape` with the slab axis gone |

In every form the block receives a 1-D `CArray` and you can call the usual
CArray methods on it — `sum`, `mean`, `sort`, indexing, arithmetic, `copy`.

## Picking a slab axis

`axis:` names the axis that the slab runs along. For a 2-D array:

```ruby
m = CArray.int32(2, 3).seq
#  => [ [ 0, 1, 2 ],
#       [ 3, 4, 5 ] ]
```

* `axis: 1` hands the block each *row* in turn — `[0, 1, 2]`, then `[3, 4, 5]`.
* `axis: 0` hands the block each *column* in turn — `[0, 3]`, then `[1, 4]`,
  then `[2, 5]`.

Negative numbers count from the end, so `axis: -1` is the innermost axis (the
rows of a 2-D array, the innermost 1-D fibers of a 3-D array). It is often the
most useful choice and also the fastest, because the slab lives in contiguous
memory.

## `each_slab` — visit every slab

`each_slab` runs the block once per slab and returns `self`. Use it for
side-effects: printing, writing to a file, accumulating into something outside
the array.

```ruby
m = CArray.int32(2, 3).seq
m.each_slab(axis: 1) { |row| puts row.sum }
#  3
#  12
```

Without a block, `each_slab` returns an enumerator, so you can chain `.map`,
`.each_with_index`, and friends:

```ruby
m.each_slab(axis: 1).map { |row| row.sum }
#  => [3, 12]
```

`break`, `next`, and `return` all work as you would expect from a normal Ruby
iterator.

## `map_slab` — build a new array, slab by slab

`map_slab` walks every slab the same way, but uses the block's return value to
fill in the corresponding slab of a new output array. The output has the same
shape as `self`.

The block can return one of two things:

* **a 1-D CArray of the same length as the slab** — it is dropped into the
  output slab, or
* **a scalar** — it is broadcast across the whole output slab.

Centring each row of a 2-D array is a typical use of the same-length form:

```ruby
m = CA_DOUBLE([[1, 2, 3, 4],
               [5, 6, 7, 8]])

m.map_slab(axis: 1) { |row| row - row.mean }
#  => [ [ -1.5, -0.5, 0.5, 1.5 ],
#       [ -1.5, -0.5, 0.5, 1.5 ] ]
```

Returning a scalar is convenient when you want every cell of the output slab to
carry the same value:

```ruby
m = CArray.int32(2, 3).seq
m.map_slab(axis: 1) { |row| row.sum }
#  => [ [ 3,  3,  3 ],
#       [ 12, 12, 12 ] ]
```

If you want the output to have a different element type from the source, pass
`data_type:`:

```ruby
m = CArray.int32(2, 3).seq
m.map_slab(axis: 1, data_type: :int32) { |row| row * 10 }
#  => [ [  0, 10, 20 ],
#       [ 30, 40, 50 ] ]
```

Returning a 1-D CArray of the wrong length, or a Ruby symbol when the output
data type is numeric, raises `ArgumentError`.

## `reduce_slab` — collapse each slab to a scalar

`reduce_slab` is the general-purpose per-axis reduction. The output has the
slab axis removed, the same shape rule as `sum(axis: k)` and the other
reductions from [Reduction and statistics](04_reduction_and_statistics.md).

It has two forms.

### Per-slab form — block returns the answer

The block receives one whole slab and returns a single scalar. This is the
quick way to express a reduction that does not exist as a built-in:

```ruby
m = CA_DOUBLE([[1, 2, 3, 4],
               [5, 6, 7, 8]])

# range (max - min) of each row
m.reduce_slab(axis: 1) { |row| row.max - row.min }
#  => [ 3.0, 3.0 ]
```

The block must return a scalar — even a single-element CArray is rejected.
Pull a value out with `slab[0]`, `slab.sum`, or another method that returns a
plain Ruby value.

### Per-element form — block accumulates

Pass `init:` and the block receives `(acc, x)` for every element in the slab,
just like Ruby's `Enumerable#inject`. CArray feeds the elements in order and
hands you the final `acc` once a slab is done.

```ruby
m = CArray.int32(2, 3).seq
m.reduce_slab(axis: 0, init: 0.0) { |acc, x| acc + x }
#  => [ 3.0, 5.0, 7.0 ]
```

`init:` can be any Ruby object (use `data_type: :object` for non-numeric
accumulators). The two forms are decided once when iteration starts, so there
is no per-element form-check overhead.

## Higher-dimensional arrays

Everything above extends to any number of dimensions. The slab is always 1-D;
all the other axes index *which* slab.

```ruby
c = CArray.int32(2, 2, 2).seq
#  => [ [ [ 0, 1 ],
#         [ 2, 3 ] ],
#       [ [ 4, 5 ],
#         [ 6, 7 ] ] ]

c.reduce_slab(axis: 2) { |fiber| fiber.sum }
#  => [ [ 1,  5 ],
#       [ 9, 13 ] ]    axis 2 collapsed, shape (2, 2) remains

c.reduce_slab(axis: 0) { |fiber| fiber.max }
#  => [ [ 4, 5 ],
#       [ 6, 7 ] ]
```

The slab iterator is single-axis only — `axis:` takes one integer, not an
array of integers. If you need a multi-axis reduction expressible with the
built-ins (`sum`, `prod`, `min`, `max`, `mean`, `variance`, `stddev`,
`accumulate`, `count`), those accept `axis: [k1, k2, …]`; see
[Reduction and statistics](04_reduction_and_statistics.md).

## Relation to the built-in reductions

The reductions in chapter 4 are pre-packaged: `m.mean(axis: 1)` always does
the same thing, and it does it in C. `reduce_slab` is the general-purpose
form — write whatever per-slab logic you want in Ruby, and pay a little
overhead per slab for the privilege. For everyday reductions, prefer the
built-ins; reach for the slab iterator when you need a reduction that does
not exist as a built-in (a median, a custom inject, a per-row routine that
mixes several CArray operations).

## The slab is reused — copy before keeping it

The 1-D CArray the block receives is **reused on every iteration**. CArray
slides its window across the source, so the slab object you saw last time now
points at the next fiber's data. Inside the block this is invisible — you read
the slab, compute, return — and that is the whole point.

But if you stash the slab itself into something that outlives the block, every
entry ends up pointing at the same object, showing the *last* iteration's data.

```ruby
# WRONG — every entry ends up the same
refs = []
m.each_slab(axis: 1) { |row| refs << row }       # all entries alias each other

# RIGHT — take a snapshot in the block
rows = []
m.each_slab(axis: 1) { |row| rows << row.dup }
```

Use `row.dup`, `row.copy`, or `row.to_a` when you need to remember a slab.
This is the same rule as views in general — see [Views](06_views.md) — and
the slab is in fact presented as a small view onto the source.

Derived values made inside the block (`row.sum`, `row - 1`, `row[1..-1]`,
`row.median`) read the current iteration's data correctly. The trap is only
about keeping the slab object itself across iterations.

## Masks

A masked source array is passed straight through: the slab the block receives
carries the mask, so masked cells show up as `UNDEF`. Any mask-aware method you
call on the slab (`sum`, `mean`, `count_not_masked`, …) skips them just as it
would on a whole array (see [Masks and missing values](05_masks.md)). If you
would rather work on the raw stored values, strip the mask first with `.value`:

```ruby
masked.value.map_slab(axis: 1) { |row| row.normalize }
```

See [Masks and missing values](05_masks.md) for what `value` does.

## A few worked examples

### Per-row z-score

```ruby
m = CA_DOUBLE([[1, 2, 3, 4],
               [5, 6, 7, 8]])

m.map_slab(axis: 1) { |row| (row - row.mean) / row.stddev }
```

### Per-row range

```ruby
m.reduce_slab(axis: 1) { |row| row.max - row.min }
```

### Inject-style per-column sum

```ruby
m = CArray.int32(2, 3).seq
m.reduce_slab(axis: 0, init: 0.0) { |acc, x| acc + x }
#  => [ 3.0, 5.0, 7.0 ]
```

### Collecting slabs (with the copy rule)

```ruby
rows = []
m.each_slab(axis: 1) { |row| rows << row.dup }
```
