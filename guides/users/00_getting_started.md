# Getting Started

Ruby/CArray is a library for multi-dimensional numerical arrays. An array holds many values of a single, uniform data type (for example 64-bit floats or 32-bit integers) in one contiguous block of memory, and lets you operate on all of them at once.

This chapter is a quick tour: enough to install CArray, make an array, and see what working with one looks like. Everything it shows in passing has a chapter of its own further on.

## Install

```
gem install carray
```

Or add it to your `Gemfile`:

```ruby
gem "carray"
```

Requires Ruby 3.0 or later.

On a multi-core machine, parallel `make` cuts install time noticeably:

```
MAKEFLAGS="-j$(nproc)" gem install carray                     # Linux
MAKEFLAGS="-j$(sysctl -n hw.ncpu)" gem install carray         # macOS
```

## A first array

```ruby
require "carray"

a = CArray.float64(2, 3)
#  => [ [ 0.0, 0.0, 0.0 ],
#       [ 0.0, 0.0, 0.0 ] ]
```

`CArray.float64(2, 3)` creates a 2-by-3 array of 64-bit floats, filled with zeros. This is how an array is made: ask for the shape and data type you want, then put values into it.

Values go in a whole array at a time. `seq!` fills it with a sequence, an assignment writes one value everywhere it reaches, and arithmetic answers a filled array of its own:

```ruby
a.seq!
#  => [ [ 0.0, 1.0, 2.0 ],
#       [ 3.0, 4.0, 5.0 ] ]

a[] = 1.5
#  => [ [ 1.5, 1.5, 1.5 ],
#       [ 1.5, 1.5, 1.5 ] ]
```

A block that takes indices is the one filling that does not stay in C: it is called once per element, so the values are produced by running Ruby as many times as the array has elements. Keep it for values that cannot be arrived at any other way.

```ruby
CArray.float64(2, 3) { |i, j| i * 3 + j }
#  => [ [ 0.0, 1.0, 2.0 ],
#       [ 3.0, 4.0, 5.0 ] ]
```

[Creating arrays](01_creating_arrays.md) covers the rest.

## A few more data types

The same shape-and-type pattern works for every data type:

```ruby
CArray.int32(4).seq!
#  => [ 0, 1, 2, 3 ]

CArray.boolean(4)
#  => [ 0, 0, 0, 0 ]

CArray.float64(3).seq!(0, 0.5)     # start at 0, step by 0.5
#  => [ 0.0, 0.5, 1.0 ]
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

## Taking a slice

Indexing uses `[]` with one argument per axis. An integer picks one element; `nil` means "every index along this axis"; a `Range` picks a contiguous run.

```ruby
a = CArray.int32(3, 4).seq!
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

## Arithmetic over the whole array

Operators apply element-wise and return a new array:

```ruby
a = CA_INT([1, 2, 3, 4])

a + 10        #  => [ 11, 12, 13, 14 ]
a * a         #  => [  1,  4,  9, 16 ]
a.gt(2)       #  => [  0,  0,  1,  1 ]    a boolean result
```

More — including comparisons and the usual math functions like `sqrt`, `exp`, `sin` — in [Element-wise operations](03_elementwise.md).

## Reducing to a summary

A reduction summarises an array down to fewer values — for example a sum, mean, or maximum:

```ruby
a = CA_DOUBLE([2, 4, 6])
a.sum         #  => 12.0
a.mean        #  =>  4.0
a.max         #  =>  6.0
```

You can also reduce along a chosen axis of a higher-dimensional array:

```ruby
m = CArray.int32(2, 3).seq!
m.sum(axis: 0)    #  => [ 3.0, 5.0, 7.0 ]   sum down each column
m.sum(axis: 1)    #  => [ 3.0, 12.0 ]       sum across each row
```

More in [Reduction and statistics](04_reduction_and_statistics.md).

## Views that share storage

Many operations don't copy the data: they hand you a *view* that refers to the same storage in a different shape or order.

```ruby
a = CArray.int32(2, 3).seq!
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

When you want an independent array you can change without disturbing the original, ask for one with `copy`. Views are a central idea in CArray and have a chapter to themselves: [Views](06_views.md).

## What you can do with it

The rest of this guide walks through the basics in order:

* [Creating arrays](01_creating_arrays.md) — constructors, data types, filling with values
* [Indexing and slicing](02_indexing_and_slicing.md) — reading and writing elements, rows, columns, and sub-blocks
* [Element-wise operations](03_elementwise.md) — arithmetic, comparison, and mathematical functions applied to every element
* [Reduction and statistics](04_reduction_and_statistics.md) — sums, means, and other summaries over the whole array or along an axis
* [Masks and missing values](05_masks.md) — marking elements as missing and having calculations account for them
* [Views](06_views.md) — reshaping, transposing, and slicing without copying
* [Broadcasting](07_broadcasting.md) — combining arrays of different shapes
