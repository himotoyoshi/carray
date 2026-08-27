# Getting Started

Ruby/CArray is a library for multi-dimensional numerical arrays. An array holds
many values of a single, uniform data type (for example 64-bit floats or 32-bit
integers) in one contiguous block of memory, and lets you operate on all of them
at once.

If you have used NumPy or Numo::NArray, the idea will be familiar. The names of
the methods and the way views work are particular to CArray, so this guide
introduces them from the ground up; no prior knowledge of CArray is assumed.

## Install

```
gem install carray
```

Requires Ruby 3.0 or later.

## A first array

```ruby
require "carray"

a = CArray.float64(2, 3) { |i, j| i * 3 + j }
#  => [ [ 0.0, 1.0, 2.0 ],
#       [ 3.0, 4.0, 5.0 ] ]
```

`CArray.float64(2, 3)` creates a 2-by-3 array of 64-bit floats. The block is
called once for each element, receiving the indices, and its return value becomes
that element. Array creation is covered in detail in
[Creating arrays](01_creating_arrays.md).

## A few more data types

The same shape-and-block pattern works for every data type:

```ruby
CArray.int32(4) { |i| i }
#  => [ 0, 1, 2, 3 ]

CArray.boolean(4) { |i| i.odd? }
#  => [ 0, 1, 0, 1 ]

CArray.float64(3).seq(0, 0.5)
#  => [ 0.0, 0.5, 1.0 ]
```

A block-less call fills with zeros, which is a convenient starting point:

```ruby
CArray.int32(2, 3)
#  => [ [ 0, 0, 0 ],
#       [ 0, 0, 0 ] ]
```

You can also build an array straight from Ruby values:

```ruby
CA_INT([1, 2, 3, 4])
#  => [ 1, 2, 3, 4 ]

CA_DOUBLE([[1, 2], [3, 4]])
#  => [ [ 1.0, 2.0 ],
#       [ 3.0, 4.0 ] ]
```

More on constructors and data types in [Creating arrays](01_creating_arrays.md).

## Inspecting an array

Every array reports its shape and data type:

```ruby
a.shape        #  => [2, 3]    size of each axis
a.ndim         #  => 2         number of axes
a.elements     #  => 6         total number of elements
a.data_type    #  => :float64  the element type
```

`size` is an accepted alternative to `elements` (both return `6` here).

## A quick slicing example

Indexing uses `[]` with one argument per axis. An integer picks one element;
`nil` means "every index along this axis"; a `Range` picks a contiguous run.

```ruby
a = CArray.int32(3, 4).seq
#  => [ [ 0,  1,  2,  3 ],
#       [ 4,  5,  6,  7 ],
#       [ 8,  9, 10, 11 ] ]

a[1, 2]         #  => 6                       one element
a[1, nil]       #  => [ 4, 5, 6, 7 ]          a row
a[nil, 2]       #  => [ 2, 6, 10 ]            a column
a[0..1, 1..2]
#  => [ [ 1, 2 ],
#       [ 5, 6 ] ]                            a sub-block
```

Full story in [Indexing and slicing](02_indexing_and_slicing.md).

## A quick arithmetic example

Operators apply element-wise and return a new array:

```ruby
a = CA_INT([1, 2, 3, 4])

a + 10        #  => [ 11, 12, 13, 14 ]
a * a         #  => [  1,  4,  9, 16 ]
a.gt(2)       #  => [  0,  0,  1,  1 ]    a boolean result
```

More — including comparisons and the usual math functions like `sqrt`, `exp`,
`sin` — in [Element-wise operations](03_elementwise.md).

## A quick reduction

A reduction summarises an array down to fewer values — for example a sum,
mean, or maximum:

```ruby
a = CA_DOUBLE([2, 4, 6])
a.sum         #  => 12.0
a.mean        #  =>  4.0
a.max         #  =>  6.0
```

You can also reduce along a chosen axis of a higher-dimensional array:

```ruby
m = CArray.int32(2, 3).seq
m.sum(axis: 0)    #  => [ 3.0, 5.0, 7.0 ]   sum down each column
m.sum(axis: 1)    #  => [ 3.0, 12.0 ]       sum across each row
```

More in [Reduction and statistics](04_reduction_and_statistics.md).

## A quick view

Many operations don't copy the data: they hand you a *view* that refers to the
same storage in a different shape or order.

```ruby
a = CArray.int32(2, 3).seq
row = a[0, nil]      #  a view of the first row
row[1] = 99
a
#  => [ [ 0, 99, 2 ],
#       [ 3,  4, 5 ] ]    writing through the view changed a
```

Reshape and transpose are views too:

```ruby
a.reshape(3, 2)
#  => [ [ 0, 99 ],
#       [ 2,  3 ],
#       [ 4,  5 ] ]

a.transpose
#  => [ [ 0, 3 ],
#       [ 99, 4 ],
#       [ 2, 5 ] ]
```

When you want an independent array you can change without disturbing the
original, ask for one with `copy`. Views are a central idea in CArray and have a
chapter to themselves: [Views](06_views.md).

## What you can do with it

The rest of this guide walks through the basics in order:

* [Creating arrays](01_creating_arrays.md) — constructors, data types, filling
  with values
* [Indexing and slicing](02_indexing_and_slicing.md) — reading and writing
  elements, rows, columns, and sub-blocks
* [Element-wise operations](03_elementwise.md) — arithmetic, comparison, and
  mathematical functions applied to every element
* [Reduction and statistics](04_reduction_and_statistics.md) — sums, means, and
  other summaries over the whole array or along an axis
* [Masks and missing values](05_masks.md) — marking elements as missing and
  having calculations account for them
* [Views](06_views.md) — reshaping, transposing, and slicing without copying
* [Broadcasting](07_broadcasting.md) — combining arrays of different shapes

> These documents are drafts. Method names and behaviour shown here are taken
> from a current development build of CArray 3.0.
