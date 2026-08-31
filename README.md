# Ruby/CArray

Ruby/CArray is an extension library for the multi-dimensional array class.

## Features

* Multidimensional arrays holding values of a single, uniform data type
* Indexing and slicing in many ways — by position, range, boolean mask, or
  index/address arrays
* Element-wise arithmetic, mathematical and transcendental functions
* Reduction and statistics computed over the whole array or along any axis
* Built-in per-element mask on every array to represent missing values, properly
  accounted for in reductions and statistics
* A rich family of views onto the original data — for indexing, reshaping, and
  reinterpreting elements — without copying
* Views compose into chains of any depth, and writing through them reaches all the
  way back to the source data
* Explicit broadcasting: operating on arrays of different shapes by stretching
  size-1 axes to match, without ever adding axes implicitly
* Fast reductions built on compiler auto-vectorization
* Kernel-style iteration from Ruby: drive a Ruby block over each sub-array spanning
  chosen axes
* Faces: a mechanism for building extended data types on top of CArray (time,
  categorical and variable-length string columns are such types)
* Easily define record types that bind several data together as one element
* User-defined array classes, written in Ruby, that share the full CArray interface
  so your own type behaves like a CArray everywhere
* A DataFrame (`CAFrame`) whose columns are plain CArrays — it adds names and row
  operations (select, filter, sort, join, group-by, CSV I/O) and hands a column
  back as the array itself, so masks, views and Faces keep working on it
* Writing per-axis methods and functions in C extensions with ease — a single
  kernel runs across every view type, with no per-view branching to write yourself
* MemoryView protocol support — interoperate with other numerical libraries as both
  producer and consumer

## Status

3.0.x still moves: behavior can change between releases — see
[CHANGELOG.md](CHANGELOG.md). 3.1 is the first release meant to be depended on.

## Contributing

Bug reports and feature requests are welcome — please open an issue.

**Before opening a pull request, read [CONTRIBUTING.md](CONTRIBUTING.md).**
It is short, and it says which form a contribution is best sent in. A small,
self-contained bug fix is fine as a pull request. Anything larger is better
started as an issue: code here gets rewritten as a matter of course, so a
patch for a larger change is likely to end up reimplemented rather than
merged, and describing the problem gets you further than writing one.

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

* [What is Ruby/CArray](docs/WhatIsCArray.md)

## Credits

Up to version 2.0, CArray was authored by himotoyoshi.

CArray 3.0 was designed and reviewed by a human developer; the implementation was
produced in collaboration with AI coding tools.

## License

MIT (after version 1.5.0)

Copyright (C) 2005-2026 himotoyoshi
