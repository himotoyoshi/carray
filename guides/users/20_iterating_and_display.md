# Iterating and displaying arrays

Two everyday mechanics that the topical chapters do not otherwise cover:
walking an array's elements in plain Ruby, and how an array shows itself when
you print or inspect it.

For the array-wide operations you will usually reach for first — arithmetic,
reductions, per-slab work — see [Element-wise operations](03_elementwise.md),
[Reduction and statistics](04_reduction_and_statistics.md), and
[Per-slab iteration](11_slab_iteration.md). This chapter is about the plain-Ruby
`each`-style loops for the times you genuinely want to visit elements one by one.

## Iterating over elements

`each` yields every element in row-major order (last axis varying fastest),
regardless of the array's number of dimensions:

```ruby
m = CArray.int32(2, 3).seq
#  => [ [ 0, 1, 2 ],
#       [ 3, 4, 5 ] ]

m.each { |x| print x, " " }
#  0 1 2 3 4 5
```

`each_index` yields the **index tuple** of each element — one argument per axis
— instead of the value:

```ruby
m.each_index { |i, j| print "(#{i},#{j}) " }
#  (0,0) (0,1) (0,2) (1,0) (1,1) (1,2)
```

`each_with_index` yields the value followed by its index tuple:

```ruby
m.each_with_index { |x, i, j| print "#{x}@#{i},#{j}  " }
#  0@0,0  1@0,1  2@0,2  3@1,0  4@1,1  5@1,2
```

`each_with_addr` yields the value and its flat **address** (the row-major
position; see [Vocabulary](08_vocabulary.md)):

```ruby
m.each_with_addr { |x, k| print "#{x}@#{k} " }
#  0@0 1@1 2@2 3@3 4@4 5@5
```

Called without a block, `each` returns an `Enumerator`, so the full Ruby
`Enumerable` toolkit is available (`map`, `select`, `each_slice`, …):

```ruby
m.each.select(&:even?)     #  => [0, 2, 4]
```

To transform in place, `map!` replaces each element with the block's result:

```ruby
a = CArray.int32(5).seq
a.map! { |x| x * x }
a                          #  => [ 0, 1, 4, 9, 16 ]
```

A caution: element-by-element Ruby iteration crosses from C into Ruby on every
cell, so it is far slower than a vectorised operation. When you can express the
work as arithmetic (`a * a`), a reduction (`a.sum`), or a per-slab routine
(chapter 11), prefer that; reach for `each` / `map!` when the per-cell logic is
genuinely arbitrary Ruby.

## How an array displays

In `irb` or via `p`, an array shows a header line — class, data type, shape,
memory size — followed by its contents laid out by shape. This is the array's
`inspect` form:

```ruby
CArray.int32(2, 3).seq
#  => <CArray.int32(2,3): elem=6 mem=24b
#  [ [ 0, 1, 2 ],
#    [ 3, 4, 5 ] ]>
```

Large arrays are abbreviated with `...` so the output stays readable — the
display is a preview, not a dump.

### `to_s` is *not* a printable form

One sharp edge worth knowing: `to_s` on a numeric array returns the **raw
bytes** of the underlying storage as a binary `String`, not a human-readable
rendering. It is the packed data, useful for writing bytes out, but not what you
want to look at:

```ruby
CArray.int32(3).seq.to_s
#  => "\x00\x00\x00\x00\x01\x00\x00\x00\x02\x00\x00\x00"   raw bytes, not "[0, 1, 2]"
```

To get a readable string, use `inspect` (what `p` and `irb` call), or convert to
a Ruby structure first with `to_a` (see [Input and output](19_input_output.md)):

```ruby
CArray.int32(3).seq.to_a.to_s     #  => "[0, 1, 2]"
CArray.int32(3).seq.inspect       #  => "<CArray.int32(3): ... [ 0, 1, 2 ]>"
```
