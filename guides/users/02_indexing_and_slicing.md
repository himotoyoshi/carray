# Indexing and slicing

Indexing uses `[]` and `[]=`, with one argument per axis. Each of those
arguments is an **index**: a position along one axis, counted from 0. An
element of a two-dimensional array therefore takes two indices, one per axis.

There is a second way of naming the same element. Lay the whole array out as
one long run — last axis first, so the elements that sit next to each other in
memory come out next to each other — and number that run from 0. Such a number
is an **address**. A `[3, 4]` array has indices `[i, j]` and addresses `0` to
`11`, and `a[1, 2]` and address `6` name the same element.

Most of this chapter is about indices. Addresses come back at the end, where
an array of them selects elements.

The examples below all use this 3-by-4 array:

```ruby
a = CArray.int32(3, 4).seq!
#  => [ [ 0,  1,  2,  3 ],
#       [ 4,  5,  6,  7 ],
#       [ 8,  9, 10, 11 ] ]
```

## A single element

Give an integer for each axis to read one element. Negative indices count from
the end.

```ruby
a[1, 2]      #  => 6
a[0, 0]      #  => 0
a[2, 3]      #  => 11
a[-1, -1]    #  => 11   the last element
a[-1, 0]     #  => 8    last row, first column
a[0, -1]     #  => 3    first row, last column
a[-2, -3]    #  => 5    second-to-last row, third-to-last column
```

Positive and negative indices mix freely, axis by axis:

```ruby
a[1, -1]     #  => 7    row 1, last column
a[-1, 2]     #  => 10   last row, column 2
```

Reading one element gives an ordinary Ruby object — an `Integer` here, a
`Float` from a float array — not an array of one element.

Assigning to a single position writes one element:

```ruby
a[0, 0] = 99
#  => [ [ 99,  1,  2,  3 ],
#       [  4,  5,  6,  7 ],
#       [  8,  9, 10, 11 ] ]
```

You can assign through a negative index too:

```ruby
a[-1, -1] = 0
#  => [ [ 99,  1,  2, 3 ],
#       [  4,  5,  6, 7 ],
#       [  8,  9, 10, 0 ] ]
```

## A whole axis with `nil`

`nil` in an axis position means "every index along this axis". This is how you
take a row or a column.

```ruby
a = CArray.int32(3, 4).seq!   # back to the values it started with

a[1, nil]    #  => [ 4, 5, 6, 7 ]    the second row
a[nil, 2]    #  => [ 2, 6, 10 ]      the third column
a[0, nil]    #  => [ 0, 1, 2, 3 ]    the first row
a[-1, nil]   #  => [ 8, 9, 10, 11 ]  the last row
a[nil, -1]   #  => [ 3, 7, 11 ]      the last column
a[nil, 0]    #  => [ 0, 4, 8 ]       the first column
```

Two `nil`s give the whole array back (as a view):

```ruby
a[nil, nil]
#  => [ [ 0,  1,  2,  3 ],
#       [ 4,  5,  6,  7 ],
#       [ 8,  9, 10, 11 ] ]
```

## A range of indices

A `Range` selects a contiguous run along an axis. Both inclusive (`..`) and
exclusive (`...`) ranges are accepted, and negative endpoints count from the
end.

```ruby
a[nil, 1..2]
#  => [ [ 1,  2 ],
#       [ 5,  6 ],
#       [ 9, 10 ] ]    columns 1 and 2, all rows

a[0..1, nil]
#  => [ [ 0, 1, 2, 3 ],
#       [ 4, 5, 6, 7 ] ]    rows 0 and 1, all columns

a[0..1, 1..2]
#  => [ [ 1, 2 ],
#       [ 5, 6 ] ]    the top-left 2x2 sub-block (rows 0-1, columns 1-2)
```

Exclusive ranges drop the endpoint:

```ruby
a[0, 0...2]    #  => [ 0, 1 ]       columns 0 and 1 of row 0 (3 excluded)
a[0...2, 0]   #  => [ 0, 4 ]        rows 0 and 1 of column 0
```

Negative endpoints make "from the start" / "to the end" easy:

```ruby
a[nil, 1..-1]
#  => [ [ 1,  2,  3 ],
#       [ 5,  6,  7 ],
#       [ 9, 10, 11 ] ]    all columns except the first

a[nil, -2..-1]
#  => [ [  2,  3 ],
#       [  6,  7 ],
#       [ 10, 11 ] ]       the last two columns

a[0..-1, 0..-1]
#  => [ [ 0,  1,  2,  3 ],
#       [ 4,  5,  6,  7 ],
#       [ 8,  9, 10, 11 ] ]   the whole array, written with ranges
```

A run does not have to be every index in the range. Ruby's `Range#step` gives
an arithmetic sequence, and CArray takes it as the indices to pick:

```ruby
a[nil, (0..3).step(2)]
#  => [ [ 0,  2 ],
#       [ 4,  6 ],
#       [ 8, 10 ] ]           every other column

a[(0..2).step(2), nil]
#  => [ [ 0, 1,  2,  3 ],
#       [ 8, 9, 10, 11 ] ]    the first and third rows

a[nil, (1..3).step(2)]
#  => [ [ 1,  3 ],
#       [ 5,  7 ],
#       [ 9, 11 ] ]           starting from column 1 instead
```

A step of zero is an error, since it would name the same index for ever. There
is a second spelling, `[start, count, step]`, which says how many to take
rather than where to stop; [Indexer reference](16_indexer_reference.md) covers
it and every other form of `[]`.

## Mixing integers, `nil`, and ranges

The forms above combine freely. Each axis takes one argument; the result drops
the axes where you gave an integer and keeps the ones where you gave `nil` or a
range.

```ruby
a[1, 1..2]    #  => [ 5, 6 ]        row 1, columns 1-2 — drops the row axis
a[1..2, 0]    #  => [ 4, 8 ]        rows 1-2, column 0 — drops the column axis

a[0..1, 2]
#  => [ 2, 6 ]                      a 2-element column slice

a[-1, 1..-1]
#  => [ 9, 10, 11 ]                 last row from column 1 onward
```

## In three dimensions

The same rules generalise to any number of axes. With a 3-D array, you give
three index arguments.

```ruby
v = CArray.int32(2, 3, 4).seq!
#  shape (2, 3, 4), values 0..23

v[0, 1, 2]       #  => 6           a single element
v[-1, -1, -1]    #  => 23          the last element

v[0, nil, nil]
#  => [ [ 0, 1,  2,  3 ],
#       [ 4, 5,  6,  7 ],
#       [ 8, 9, 10, 11 ] ]         the first 2-D "slab"

v[nil, 0, nil]
#  => [ [  0,  1,  2,  3 ],
#       [ 12, 13, 14, 15 ] ]       row 0 of each slab

v[nil, nil, 0]
#  => [ [  0,  4,  8 ],
#       [ 12, 16, 20 ] ]           column 0 of each slab

v[0, 1..2, 1..3]
#  => [ [ 5,  6,  7 ],
#       [ 9, 10, 11 ] ]            a sub-block of the first slab
```

## Standing in for several axes with `:~`

Writing out one `nil` per axis gets tedious as the number of axes grows. The
sigil `:~` stands in for **as many `nil`s as are needed** to fill the remaining
axes, so you only have to name the axes you actually care about.

```ruby
a[:~, 1]     #  => [ 1, 5, 9 ]        same as a[nil, 1]
a[1, :~]     #  => [ 4, 5, 6, 7 ]     same as a[1, nil]

v[0, :~]     #  the first 2-D slab    same as v[0, nil, nil]
v[:~, 0]     #  column 0 of each slab same as v[nil, nil, 0]
v[:~]        #  the whole array       same as v[nil, nil, nil]
```

`:~` may appear at most once in an index, and it may expand to zero axes — so
`v[0, :~, 1, 2]` is fine and simply means `v[0, 1, 2]`.

Older code and documentation may use `false` for this; it still works, but `:~`
is the recommended spelling.

## By a boolean mask

A comparison produces a boolean array of the same shape — true (`1`) where the
condition holds (see [Element-wise operations](03_elementwise.md)):

```ruby
a.gt(5)
#  => [ [ 0, 0, 0, 0 ],
#       [ 0, 0, 1, 1 ],
#       [ 1, 1, 1, 1 ] ]
```

Indexing with such a boolean array returns the matching elements as a 1-D array:

```ruby
a[a.gt(5)]
#  => [ 6, 7, 8, 9, 10, 11 ]    the elements greater than 5
```

Boolean conditions combine with `&`, `|`, `^` (or `and`, `or`, `xor`), so you
can filter on more than one criterion at once:

```ruby
a[a.gt(2) & a.lt(8)]
#  => [ 3, 4, 5, 6, 7 ]          strictly between 2 and 8

a[a.gt(8) | a.lt(2)]
#  => [ 0, 1, 9, 10, 11 ]        outside the range [2, 8]

a[a.eq(0) | a.eq(11)]
#  => [ 0, 11 ]                  just the two endpoints
```

You can assign through the same form to update only the selected elements:

```ruby
a[a.gt(5)] = 0
#  => [ [ 0, 1, 2, 3 ],
#       [ 4, 5, 0, 0 ],
#       [ 0, 0, 0, 0 ] ]
```

## By an array of positions

Indexing with an integer CArray picks out elements by address — the single
number that names an element in the flattened array, as above:

```ruby
b = CA_INT([10, 20, 30, 40, 50])
b[CA_INT([0, 2, 4])]    #  => [ 10, 30, 50 ]    the elements at addresses 0, 2, 4
```

For a multi-dimensional array the addresses run through the whole array, not
along one axis:

```ruby
a = CArray.int32(3, 4).seq!
a[CA_INT([0, 5, 11])]   #  => [ 0, 5, 11 ]      addresses 0, 5 and 11
```

Like every other form of indexing in CArray, this returns a view — assigning
through it writes back to the source:

```ruby
b = CA_INT([10, 20, 30, 40, 50])
b[CA_INT([0, 2, 4])] = 0
b                       #  => [ 0, 20, 0, 40, 0 ]
```

(See [Views](06_views.md) for why this is a view rather than a copy.)

## Writing through a slice

Any of the slice forms above can appear on the left of an assignment. Assigning
a scalar fills every selected element; assigning an array of matching shape
copies it in element-wise.

### Filling a slice with a scalar

```ruby
a = CArray.int32(3, 4).seq!

a[1, nil] = -1            #  fill the whole second row with -1
#  => [ [  0,  1,  2,  3 ],
#       [ -1, -1, -1, -1 ],
#       [  8,  9, 10, 11 ] ]

a[nil, 0] = 0             #  zero out the first column
#  => [ [ 0,  1,  2,  3 ],
#       [ 0, -1, -1, -1 ],
#       [ 0,  9, 10, 11 ] ]

a[0..1, 1..2] = 99        #  fill a 2x2 sub-block with the same value
#  => [ [ 0, 99, 99,  3 ],
#       [ 0, 99, 99, -1 ],
#       [ 0,  9, 10, 11 ] ]
```

### Copying values into a slice

A right-hand side of matching shape is copied in element by element:

```ruby
a = CArray.int32(3, 4).seq!

a[nil, 0] = CA_INT([7, 8, 9])   #  copy three values into the first column
#  => [ [ 7,  1,  2,  3 ],
#       [ 8,  5,  6,  7 ],
#       [ 9,  9, 10, 11 ] ]

a[0..1, 0..1] = CA_INT([[100, 200], [300, 400]])  #  copy a 2x2 block in
#  => [ [ 100, 200,  2,  3 ],
#       [ 300, 400,  6,  7 ],
#       [   9,   9, 10, 11 ] ]
```

You can also copy a slice from one array into a slice of another:

```ruby
src = CArray.int32(3, 4).seq!
dst = CArray.int32(3, 4)         #  starts at all zeros
dst[0..1, 1..2] = src[1..2, 0..1]
dst
#  => [ [ 0, 4, 5, 0 ],
#       [ 0, 8, 9, 0 ],
#       [ 0, 0, 0, 0 ] ]
```

### Assigning to the whole array with `a[] = ...`

`[]` with no axis arguments addresses the array as a whole. This is the usual
way to replace the contents of an array without allocating a new one — useful in
particular for assigning a view of an array back into the array itself (see
[Views](06_views.md)):

```ruby
a = CArray.int32(3, 4).seq!
a[] = 0                          #  fill every element with 0
#  => [ [ 0, 0, 0, 0 ],
#       [ 0, 0, 0, 0 ],
#       [ 0, 0, 0, 0 ] ]

a[] = CA_INT([[1, 2, 3, 4],      #  replace the contents from another array
              [5, 6, 7, 8],
              [9,10,11,12]])
#  => [ [ 1,  2,  3,  4 ],
#       [ 5,  6,  7,  8 ],
#       [ 9, 10, 11, 12 ] ]
```

The right-hand side does not have to match the shape of `a` if it claims no
shape of its own. A 1-D source of length 12 fills a `[3, 4]` target in
row-major order, and so does a Ruby Array:

```ruby
a = CArray.int32(3, 4)
a[] = CArray.int32(12).seq!        #  1-D source, 2-D target
#  => [ [ 0, 1,  2,  3 ],
#       [ 4, 5,  6,  7 ],
#       [ 8, 9, 10, 11 ] ]

a[] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]     #  same thing
```

A source that *does* claim a shape has to agree with the target's, and a
`[3, 4]` source into a `[2, 6]` target does not:

```ruby
b = CArray.int32(2, 6)
b[] = a
#  => RuntimeError: shape mismatch writing to carray ([2, 6] <- [3, 4]);
#     shapes must agree once size-1 axes are dropped, or one side must be 1-D,
#     or the source must be smaller and broadcastable -- use .flatten to write
#     the values in the order they lie

b[] = a.flatten                    #  say it explicitly
#  => [ [ 0, 1, 2,  3,  4,  5 ],
#       [ 6, 7, 8,  9, 10, 11 ] ]
```

`#flatten` returns a view, so nothing is copied to say this. Axes of length 1
do not count as a disagreement — `[2, 3, 1]` and `[2, 3]` are the same shape
written two ways.

### Repeating along a size-1 axis

The flat copy above matches by *total* element count, not axis by axis. There
is one case where an assignment does stretch a particular axis to fit: a
**size-1 axis** on the right-hand side. `src[:_, nil, nil]` inserts an axis of
length 1; on assignment that axis is sized to the target's matching axis and
the value is repeated to fill it.

```ruby
row    = CArray.int32(3, 4).seq!          # one [3, 4] block, values 0..11
target = CArray.int32(5, 3, 4)

target[] = row[:_, nil, nil]             # repeat the block along axis 0
target[0, nil, nil].to_a == row.to_a     #  => true
target[4, nil, nil].to_a == row.to_a     #  => true   every slab is a copy of row
```

The axis may sit anywhere — not only the first — and it works through a
partial slice too:

```ruby
mid = CArray.int32(5, 4).seq!
t   = CArray.int32(5, 3, 4)
t[] = mid[nil, :_, nil]                   # stretch the middle axis to 3

t2 = CArray.int32(5, 3, 4)
t2[1..3, nil, nil] = row[:_, nil, nil]    # fill only slabs 1..3, leave 0 and 4
```

Only size-1 axes are flexible; every other axis must still match exactly, so a
genuine shape conflict raises rather than guessing. The source is never asked
to shrink, either — a bigger source into a smaller target raises.

This is the same size-1 broadcast an operation performs, so `:_` reads the same
way on both sides:

```ruby
target + row[:_, nil, nil]      # broadcasts in the operation
target[] = row[:_, nil, nil]    # broadcasts on the store
```

Both need the two to have the same number of axes before a size-1 axis can be
stretched — CArray never adds an axis of its own to make shapes line up, which
is what `:_` is for. See [Broadcasting](07_broadcasting.md) for the operation
side.

These slices are *views* onto the original data, not copies — writing through
them changes the original array. That property is the subject of
[Views](06_views.md).
