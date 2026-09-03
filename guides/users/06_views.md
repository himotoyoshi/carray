# Views

A *view* is an array that does not own its data. Instead it refers to another
array's storage and presents it in a different shape, order, or arrangement.
Because a view shares storage with the array it refers to, creating one does not
copy the data.

**You use a view exactly like any other array** — the same methods, the same
indexing, the same behaviour. You do not have to know or check whether what you
are holding is a view or an entity; they feel identical to use.

> **The one thing to keep in mind:** writing through a view reaches back and
> changes the data it refers to. This is the whole point of a view, and the main
> thing to be aware of. If you want a separate array that you can change freely,
> make a copy with `copy` (shown at the end of this page).

The slices from [Indexing and slicing](02_indexing_and_slicing.md) are views.
Several methods produce views directly.

```ruby
a = CArray.int32(2, 3).seq
#  => [ [ 0, 1, 2 ],
#       [ 3, 4, 5 ] ]
```

## Reshaping

`reshape` presents the same elements with a different shape, as long as the total
number of elements is unchanged.

```ruby
a.reshape(3, 2)
#  => [ [ 0, 1 ],
#       [ 2, 3 ],
#       [ 4, 5 ] ]

a.reshape(6)            #  flatten to one dimension
#  => [ 0, 1, 2, 3, 4, 5 ]
```

Reshape works in either direction — you can flatten a multi-dimensional array
down to 1-D, or re-fold a 1-D array into any shape whose elements multiply out
to the same total.

```ruby
flat = CArray.int32(24).seq
#  => [ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, ..., 23 ]

cube = flat.reshape(2, 3, 4)        #  re-fold 1-D into 3-D
#  => [ [ [  0,  1,  2,  3 ],
#         [  4,  5,  6,  7 ],
#         [  8,  9, 10, 11 ] ],
#       [ [ 12, 13, 14, 15 ],
#         [ 16, 17, 18, 19 ],
#         [ 20, 21, 22, 23 ] ] ]

cube.reshape(24)                    #  back down to 1-D
#  => [ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, ..., 23 ]

cube.reshape(4, 6)                  #  any compatible 2-D shape
#  => [ [  0,  1,  2,  3,  4,  5 ],
#       [  6,  7,  8,  9, 10, 11 ],
#       [ 12, 13, 14, 15, 16, 17 ],
#       [ 18, 19, 20, 21, 22, 23 ] ]
```

Every one of these is a view onto `flat`; writing into any of them updates the
shared storage.

## Transposing

`transpose` swaps axes. For a 2-D array it exchanges rows and columns.

```ruby
a.transpose
#  => [ [ 0, 3 ],
#       [ 1, 4 ],
#       [ 2, 5 ] ]
```

For a higher-dimensional array, `transpose` takes the permutation of axes you
want. Pass the new axis order as integers.

```ruby
c = CArray.int32(2, 2, 3).seq
c.shape              #  => [2, 2, 3]

c.transpose(2, 0, 1).shape
#  => [3, 2, 2]     axis 2 moved to the front, the rest follow

c.transpose(2, 0, 1)
#  => [ [ [ 0, 3 ],
#         [ 6, 9 ] ],
#       [ [ 1, 4 ],
#         [ 7, 10 ] ],
#       [ [ 2, 5 ],
#         [ 8, 11 ] ] ]
```

Transposes are pure views — even multi-axis ones — so they cost nothing to
create.

## Operations that return views, even when you might not expect it

Reshape and transpose are obviously about rearranging without copying. But a
number of operations that *look* like they should produce a brand-new, modified
array also return views and **leave the original untouched**: `sort`, `reverse`,
`flip`, `shift`, `roll`, and others.

The general rule is worth holding onto: in CArray, an operation that only
**rearranges or selects existing elements** gives you a view. An actual copy
happens only when you ask for one with `to_ca`, or when an operation has to
compute new values (like arithmetic). So rather than memorising which methods
copy, assume you have a view and remember that writing through it reaches the
source.

```ruby
a = CA_INT([3, 1, 2, 5, 4])

a.sort               #  => [ 1, 2, 3, 4, 5 ]    a sorted view
a.reverse            #  => [ 4, 5, 2, 1, 3 ]    a reversed view
a                    #  => [ 3, 1, 2, 5, 4 ]    the original is unchanged
```

They really are views — you can see it from their class:

```ruby
a.sort.class         #  => CARemap
a.reverse.class      #  => CAStride
a.flip(0).class      #  => CAStride
a.shift(1).class     #  => CAShift
a.roll(1).class      #  => CARoll
```

Other view-producing forms have their own classes too, and you can confirm them
the same way:

```ruby
b = CArray.int32(2, 3).seq

b.reshape(6).class       #  => CAStride
b.transpose.class        #  => CATranspose
b[0, nil].class          #  => CABlock
b[nil, 0..1].class       #  => CABlock
b[CA_INT([0, 2])].class  #  => CAGrid
b[b.gt(2)].class         #  => CASelect
```

The names differ because the underlying mechanics differ, but from your side
they are all just arrays — and writing through any of them reaches the source.

`flip`, `shift`, and `roll` rearrange along an axis:

```ruby
b = CA_INT([1, 2, 3, 4, 5])

b.flip(0)            #  => [ 5, 4, 3, 2, 1 ]    reversed along axis 0
b.shift(1)           #  => [ 0, 1, 2, 3, 4 ]    shifted right, vacated slot filled with 0
b.roll(1)            #  => [ 5, 1, 2, 3, 4 ]    rotated right (the last element wraps around)
```

For a 2-D array, `flip` and `sort` take the axis to act on:

```ruby
m = CA_INT([[3, 1, 2], [6, 4, 5]])

m.flip(0)            #  flip the rows
#  => [ [ 6, 4, 5 ],
#       [ 3, 1, 2 ] ]

m.sort(axis: 1)      #  sort within each row
#  => [ [ 1, 2, 3 ],
#       [ 4, 5, 6 ] ]
```

### Selecting with an index array or a boolean array

Picking elements out by an array of positions, or by a boolean condition, also
produces a view rather than a copy:

```ruby
a = CA_INT([10, 20, 30, 40, 50])

a[CA_INT([0, 2, 4])]    #  => [ 10, 30, 50 ]   the elements at positions 0, 2, 4
a[a.gt(25)]             #  => [ 30, 40, 50 ]   the elements greater than 25
```

Because they are views, assigning through them writes back to the source:

```ruby
a[CA_INT([0, 2, 4])] = 0
a                       #  => [ 0, 20, 0, 40, 0 ]
```

The boolean form works the same way — assigning through it updates exactly the
selected positions:

```ruby
a = CA_INT([10, 20, 30, 40, 50])
a[a.gt(25)] = -1
a                       #  => [ 10, 20, -1, -1, -1 ]
```

(In some libraries this style of indexing — "fancy indexing" — makes a copy. In
CArray it is a view, like every other form of indexing.)

### Applying the result in place

Because these return views, the natural way to *replace* an array with its sorted
(or flipped, rolled, ...) version is to assign the view back into the whole array
with `a[] = ...`:

```ruby
a = CA_INT([3, 1, 2, 5, 4])
a[] = a.sort
a                    #  => [ 1, 2, 3, 4, 5 ]    a now holds the sorted values
```

This is safe even though the right-hand side is a view of `a` itself.

The same pattern handles every "give me a rearranged version" view:

```ruby
a = CA_INT([3, 1, 2, 5, 4])
a[] = a.reverse
a                    #  => [ 4, 5, 2, 1, 3 ]

b = CA_INT([1, 2, 3, 4, 5])
b[] = b.flip(0)
b                    #  => [ 5, 4, 3, 2, 1 ]

m = CA_INT([[3, 1, 2], [6, 4, 5]])
m[] = m.sort(axis: 1)
m
#  => [ [ 1, 2, 3 ],
#       [ 4, 5, 6 ] ]
```

This `a[] = a.something` idiom replaces the older `something!` bang methods —
the view does the work, and the assignment writes the result back into the
original storage.

## Writing through a view changes the original

A view shares the storage of the array it refers to, so assigning through it
updates that array:

```ruby
a = CArray.int32(2, 3).seq
row = a[0, nil]         #  a view of the first row: [ 0, 1, 2 ]
row[1] = 99

row
#  => [ 0, 99, 2 ]

a                       #  the original changed too
#  => [ [ 0, 99, 2 ],
#       [ 3, 4, 5 ] ]
```

This holds for every kind of view, including reshapes:

```ruby
a = CArray.int32(2, 3).seq
a.reshape(6)[0] = -1
a
#  => [ [ -1, 1, 2 ],
#       [  3, 4, 5 ] ]
```

It also holds through arbitrarily long chains. Each step is a view, and the
write at the end propagates back through them all:

```ruby
a = CArray.int32(2, 3).seq
a.reshape(3, 2).transpose[0, 1] = 999
a
#  => [ [   0,   1, 999 ],
#       [   3,   4,   5 ] ]
```

## Getting an independent copy: `copy`

When you want a separate array that does not share storage, call `copy`. It
allocates new memory and copies the data, so changes to the copy do not touch the
original.

```ruby
a  = CArray.int32(2, 3).seq
cp = a[0, nil].copy     #  an independent copy of the first row
cp[1] = 99

cp
#  => [ 0, 99, 2 ]

a                       #  unchanged
#  => [ [ 0, 1, 2 ],
#       [ 3, 4, 5 ] ]
```

`copy` always makes a fresh, independent copy. `to_ca`, by contrast, does the
least work needed to hand you a CArray — and a view is already a CArray, so it is
returned unchanged:

```ruby
a = CArray.int32(2, 3).seq
v = a[0, nil]              #  a view

v.to_ca.equal?(v)    #  => true    already a CArray → returned as-is, no copy
v.copy.equal?(v)     #  => false   copy always allocates a new, owned array
```

The two `equal?` outcomes pin down the semantics: `to_ca` hands back the very
same object (same `object_id`), while `copy` always produces a fresh one.

So:

* **`to_ca`** — "give me this as a CArray". Any CArray — an entity or a view — is
  returned unchanged (no copy). Use it when you just need a CArray to read or pass
  along. It does **not** turn a view into independent memory.
* **`copy`** — always returns a new, independent, contiguous array. Use it when
  you intend to modify the result, must not disturb the original, or need real
  owned memory out of a view.

> **Anti-pattern: don't use `dup` or `clone` to copy a view.** They are Ruby's
> standard shallow copy: on a *view* they return **another view onto the same
> storage**, so writing to the result still changes the source. This is a
> classic trap.
>
> ```ruby
> a = CArray.int32(2, 3).seq
> v = a[0, nil]
> d = v.dup       #  looks like a copy, but it is another view of a
> d[0] = 777
> a               #  the original was modified!
> #  => [ [ 777, 1, 2 ],
> #       [   3, 4, 5 ] ]
> ```
>
> Always use `copy` when you need an independent array.

## Composing views

Views can be built on top of views, to any depth. A transpose of a reshape is
just another view, and writing through the whole chain still reaches the original
data.

```ruby
a = CArray.int32(2, 3).seq

a.reshape(3, 2).transpose
#  => [ [ 0, 2, 4 ],
#       [ 1, 3, 5 ] ]

a.reshape(3, 2).transpose[nil, 0]
#  => [ 0, 1 ]          a view through three steps
```

Materialising into real memory happens only when you ask for it (with `to_ca`),
or when an operation needs a concrete array.

CArray offers a wide range of view-producing methods beyond reshape and
transpose. The ones in this document are the basics; the others build on the same
idea — refer to the data, copy only when asked.

## View classes

In CArray, each kind of view is its own named class — the array tells you what
kind of view it is if you ask. You rarely need to use these names directly; the
table below is a reference for what you might see when you call `.class` on a
view.

All of these are subclasses of `CAView` (and `CAView` itself is a subclass of
`CArray`), so every method you can call on a regular array works on a view
unchanged.

| Class             | Produced by                                                                 | Example                                                  |
|-------------------|-----------------------------------------------------------------------------|----------------------------------------------------------|
| `CABlock`         | Integer / `nil` / `Range` slicing of one or more axes                       | `a[0, nil]`, `a[1..2, nil]`, `a[nil, 0..1]`              |
| `CAStride`        | `reshape`, `insert_axis` (and `:_`), `reverse`, `flip`                      | `a.reshape(3, 2)`, `a[:_, nil]`, `a.reverse`             |
| `CATranspose`     | `transpose`                                                                 | `a.transpose`                                            |
| `CARefer`         | Flattening with a single `nil`; indexing by a multi-dimensional index array  | `a[nil]`, `a[CA_INT([[0, 1], [2, 3]])]`                  |
| `CARemap`         | `sort` (a view onto the source in sorted order)                             | `a.sort`, `a.sort(axis: 1)`                              |
| `CAGrid`          | Indexing by an array of positions on one or more axes                       | `a[CA_INT([0, 2, 4])]`                                   |
| `CASelect`        | Indexing by a boolean array                                                 | `a[a.gt(3)]`                                             |
| `CAShift`         | `shift` (shifted view; vacated slots filled)                                | `a.shift(1)`                                             |
| `CARoll`          | `roll` (rotated view; wrap-around)                                          | `a.roll(1)`                                              |

Confirm them in irb:

```ruby
a = CArray.int32(3, 3).seq

a[0, nil].class           #  => CABlock
a[1..2, nil].class        #  => CABlock
a.reshape(9).class        #  => CAStride
a.insert_axis(0).class    #  => CAStride
a[:_, nil, nil].class     #  => CAStride
a.reverse.class           #  => CAStride
a.flip(0).class           #  => CAStride
a.transpose.class         #  => CATranspose
a.sort.class              #  => CARemap
a[CA_INT([0, 2])].class   #  => CAGrid
a[a.gt(3)].class          #  => CASelect

v = CA_INT([1, 2, 3, 4, 5])
v.shift(1).class          #  => CAShift
v.roll(1).class           #  => CARoll
```

There are a few more specialised view classes (`CAReduce`, `CAWindow`,
`CAMapping`, `CAFake`, `CAField`, `CABitarray`, `CABitfield`, `CAObject`)
which you may encounter when using advanced features such as window scans,
fixed-size record fields, or sub-byte storage. These follow the same rule:
they are views onto data they do not own, so
writing through them updates the source.

An entity — a real, data-owning array — has class `CArray` (or, for a
zero-dimensional value, `CScalar`). The check `ca.entity?` returns `true` for
those and `false` for any of the view classes above:

```ruby
a = CArray.int32(3, 3).seq
a.entity?              #  => true
a[0, nil].entity?      #  => false
a.transpose.entity?    #  => false
a.reshape(9).entity?   #  => false

a.copy.entity?         #  => true     copy materialises into an entity
```
