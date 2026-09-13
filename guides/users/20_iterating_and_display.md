# Iterating and displaying arrays

Two everyday mechanics that the topical chapters do not otherwise cover: walking an array's elements in plain Ruby, and how an array shows itself when you print or inspect it.

For the array-wide operations you will usually reach for first — arithmetic, reductions, per-slab work — see [Element-wise operations](03_elementwise.md), [Reduction and statistics](04_reduction_and_statistics.md), and [Per-slab iteration](11_slab_iteration.md). This chapter is about the plain-Ruby `each`-style loops for the times you genuinely want to visit elements one by one.

## Iterating over elements

`each` yields every element in row-major order (last axis varying fastest), regardless of the array's number of dimensions:

```ruby
m = CArray.int32(2, 3).seq
#  => [ [ 0, 1, 2 ],
#       [ 3, 4, 5 ] ]

m.each { |x| print x, " " }
#  0 1 2 3 4 5
```

`each_index` yields the **index tuple** of each element — one argument per axis — instead of the value:

```ruby
m.each_index { |i, j| print "(#{i},#{j}) " }
#  (0,0) (0,1) (0,2) (1,0) (1,1) (1,2)
```

`each_with_index` yields the value followed by its index tuple:

```ruby
m.each_with_index { |x, i, j| print "#{x}@#{i},#{j}  " }
#  0@0,0  1@0,1  2@0,2  3@1,0  4@1,1  5@1,2
```

`each_with_addr` yields the value and its flat **address** (the row-major position; see [Vocabulary](08_vocabulary.md)):

```ruby
m.each_with_addr { |x, k| print "#{x}@#{k} " }
#  0@0 1@1 2@2 3@3 4@4 5@5
```

Called without a block, `each` returns an `Enumerator`, so the full Ruby `Enumerable` toolkit is available (`map`, `select`, `each_slice`, …):

```ruby
m.each.select(&:even?)     #  => [0, 2, 4]
```

To transform in place, `map!` replaces each element with the block's result:

```ruby
a = CArray.int32(5).seq
a.map! { |x| x * x }
a                          #  => [ 0, 1, 4, 9, 16 ]
```

A caution: element-by-element Ruby iteration crosses from C into Ruby on every cell, so it is far slower than a vectorised operation. When you can express the work as arithmetic (`a * a`), a reduction (`a.sum`), or a per-slab routine (chapter 11), prefer that; reach for `each` / `map!` when the per-cell logic is genuinely arbitrary Ruby.

## How an array displays

In `irb` or via `p`, an array shows a header line — class, data type, shape, memory size — followed by its contents laid out by shape. This is the array's `inspect` form:

```ruby
CArray.int32(2, 3).seq
#  => <CArray.int32(2,3): elem=6 mem=24b
#  [ [ 0, 1, 2 ],
#    [ 3, 4, 5 ] ]>
```

Large arrays are abbreviated with `...` so the output stays readable — the display is a preview, not a dump.

### The whole array: `inspect_full`

When the array *is* what you came to look at, `inspect_full` renders the same thing with the eliding dropped:

```ruby
a = CArray.int32(8, 12).seq!

a.inspect
#  => <CArray.int32(8,12): elem=96 mem=384b
#  [ [ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 ],
#    [ 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23 ],
#    [ 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35 ],
#    ... ... ...
#    [ 84, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95 ] ]>

puts a.inspect_full        #  all eight rows, and every value in each
```

The header, the layout and the `_` for a masked cell are `inspect`'s — only the abbreviation goes. So for an array small enough that `inspect` was not eliding anything, the two give the same string.

It returns a String and holds the whole array in it, which is the cost: a line is as long as the last axis makes it, and nothing is streamed. There is no threshold to set — `inspect` always previews and `inspect_full` always doesn't, rather than one method whose behaviour depends on state set somewhere else.


### `to_s` is *not* a printable form

One sharp edge worth knowing: `to_s` on a numeric array returns the **raw bytes** of the underlying storage as a binary `String`, not a human-readable rendering. It is the packed data, useful for writing bytes out, but not what you want to look at:

```ruby
CArray.int32(3).seq.to_s
#  => "\x00\x00\x00\x00\x01\x00\x00\x00\x02\x00\x00\x00"   raw bytes, not "[0, 1, 2]"
```

To get a readable string, use `inspect` (what `p` and `irb` call), or convert to a Ruby structure first with `to_a` (see [Input and output](19_input_output.md)):

```ruby
CArray.int32(3).seq.to_a.to_s     #  => "[0, 1, 2]"
CArray.int32(3).seq.inspect       #  => "<CArray.int32(3): ... [ 0, 1, 2 ]>"
```

For a large array, `inspect_full` is the one that leaves nothing out.
