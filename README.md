# Ruby/CArray

Ruby/CArray is an extension library for the multi-dimensional array class. It provides arrays of a single, uniform data type, with indexing and slicing in many forms, element-wise arithmetic and mathematical functions, reductions and statistics over the whole array or along any axis, and broadcasting between shapes that differ in size-1 axes. The features listed below are in addition to these.

## Status

3.0.x still moves: behavior can change between releases — see [CHANGELOG.md](CHANGELOG.md). 3.1 is the first release meant to be depended on. Until then, treat it as a place to try things out.

## Features

* Every array carries a per-element mask for missing values, respected by reductions and statistics
* Views compose without copying — a write through the outermost view reaches the source data
* MemoryView protocol on both sides: share buffers with other numerical libraries without copying
* Kernel-style iteration: run a Ruby block over each sub-array spanning the axes you choose
* Attach domain meaning (time, angle, quantity with units…) without changing storage — a Face
* Define your own array class in pure Ruby while keeping the full CArray interface
* Pack multiple values into one element as a record type
* Comes with a DataFrame (`CAFrame`) whose columns are plain CArrays, so masks and views keep working on them

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

## Quick example

```ruby
require "carray"

# --- create a 2x3 array ---
a = CArray.float64(2, 3) { |i, j| i * 3 + j }
#  => [ [ 0, 1, 2 ],
#       [ 3, 4, 5 ] ]

# --- reductions over the whole array or along an axis ---
a.sum                      #  => 15.0          over the whole array
a.sum(axis: 0)             #  => [ 3, 5, 7 ]   sum down each column
a.sum(axis: 1)             #  => [ 3, 12 ]     sum across each row

# --- element-wise operations and functions ---
a + 1
#  => [ [ 1, 2, 3 ],
#       [ 4, 5, 6 ] ]

a.exp
#  => [ [  1.000,   2.718,   7.389 ],
#       [ 20.086,  54.598, 148.413 ] ]

# --- select by condition ---
a[(a % 2).eq(0)]           #  => [ 0, 2, 4 ]   the even elements

# --- views share storage with the original ---
a.reshape(3, 2)
#  => [ [ 0, 1 ],
#       [ 2, 3 ],
#       [ 4, 5 ] ]

a.transpose
#  => [ [ 0, 3 ],
#       [ 1, 4 ],
#       [ 2, 5 ] ]

a[0, nil]                  #  => [ 0, 1, 2 ]   the first row
a[nil, 0]                  #  => [ 0, 3 ]      the first column

a[nil, 1..2]               #  a block view of the last two columns
#  => [ [ 1, 2 ],
#       [ 4, 5 ] ]

# --- writing through a view updates the original ---
a[0, nil] = -1
a
#  => [ [ -1, -1, -1 ],
#       [  3,  4,  5 ] ]

# --- missing values ---
b = CArray.float64(2, 3) { |i, j| i * 3 + j }
b[0, 1] = UNDEF            #  mark some missing values
b[1, 2] = UNDEF
b
#  => [ [ 0, _, 2 ],
#       [ 3, 4, _ ] ]

b.sum                      #  => 9            missing values are ignored
b.sum(axis: 0)             #  => [ 3, 4, 2 ]  (column sums)
b.sum(axis: 1)             #  => [ 2, 7 ]     (row sums)

# the mask is not NaN: dropping it to NaN lets IEEE rules take over instead
b.strip_mask(Float::NAN).sum(axis: 0)
#  => [ 3, NaN, NaN ]      NaN propagates rather than being ignored
```

## Documentation

* [Introduction](guides/users/introduction.md) — what Ruby/CArray is: one data type, many dimensions, views, and missing values
* [Getting started](guides/users/00_getting_started.md) — installing it, making a first array, and a short tour of the rest
* [Creating arrays](guides/users/01_creating_arrays.md) — constructors, data types, and the ways of filling an array with values
* [Indexing and slicing](guides/users/02_indexing_and_slicing.md) — elements, rows, columns, sub-blocks, and selection by condition
* [Indexer reference](guides/users/16_indexer_reference.md) — every form `[]` accepts, the shape it gives back, and the view it produces
* [Element-wise operations](guides/users/03_elementwise.md) — arithmetic, comparison, and the mathematical functions
* [Broadcasting](guides/users/07_broadcasting.md) — combining arrays whose shapes differ
* [Views](guides/users/06_views.md) — reshaping, transposing and slicing without copying, and what a write through a view reaches
* [Reduction and statistics](guides/users/04_reduction_and_statistics.md) — summaries over the whole array or along the axes you choose
* [Masks and missing values](guides/users/05_masks.md) — marking elements as undefined, and how calculations then treat them

## Contributing

Bug reports and feature requests are welcome — please open an issue.

**Before opening a pull request, read [CONTRIBUTING.md](CONTRIBUTING.md).** It is short, and it says which form a contribution is best sent in. A small, self-contained bug fix is fine as a pull request. Anything larger is better started as an issue: code here gets rewritten as a matter of course, so a patch for a larger change is likely to end up reimplemented rather than merged, and describing the problem gets you further than writing one.

## Credits

Up to version 2.0, CArray was authored by himotoyoshi.

CArray 3.0 was designed and reviewed by a human developer; the implementation was produced in collaboration with AI coding tools.

## License

MIT (after version 1.5.0)

Copyright (C) 2005-2026 himotoyoshi
