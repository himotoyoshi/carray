# Creating arrays

## By shape and data type

The basic constructor is a class method named after the data type. It takes the
shape — one integer per axis — and returns an array of that shape.

```ruby
CArray.float64(3)        #  a 1-D array of 3 floats
CArray.int32(2, 3)       #  a 2-D array, 2 rows by 3 columns
CArray.float64(4, 4, 4)  #  a 3-D array
```

Without a block, the array is filled with zeros:

```ruby
CArray.float64(3)
#  => [ 0.0, 0.0, 0.0 ]

CArray.int32(2, 4)
#  => [ [ 0, 0, 0, 0 ],
#       [ 0, 0, 0, 0 ] ]
```

### Filling with a value

`fill` puts one value into every element, in place, and returns the array:

```ruby
CArray.float64(2, 4).fill(9.0)
#  => [ [ 9.0, 9.0, 9.0, 9.0 ],
#       [ 9.0, 9.0, 9.0, 9.0 ] ]

CArray.int32(5).fill(-1)
#  => [ -1, -1, -1, -1, -1 ]
```

Assigning to the whole array with `a[] = 9.0` does the same thing.

A block that takes no parameters is read as this same fill. Such a block
receives no indices, so nothing in it can vary from element to element; CArray
therefore evaluates it **once** and puts that one value everywhere:

```ruby
CArray.float64(2, 4) { 9.0 }
#  => [ [ 9.0, 9.0, 9.0, 9.0 ],
#       [ 9.0, 9.0, 9.0, 9.0 ] ]
```

The rule holds whatever the block contains. An expression that would give a
different answer each time it ran is still run only once, and that one answer
goes everywhere:

```ruby
CArray.int32(8) { rand(100) }
#  => [ 42, 42, 42, 42, 42, 42, 42, 42 ]   #  one rand call, broadcast
```

To vary by element, the block has to be given the indices to vary by — which is
the next section.

### From the indices

A block that takes parameters is called once per element and receives that
element's indices; its return value becomes the element.

```ruby
CArray.int32(5) { |i| i }
#  => [ 0, 1, 2, 3, 4 ]

CArray.int32(5) { |i| i * i }
#  => [ 0, 1, 4, 9, 16 ]
```

For a 2-D array the block receives a row index and a column index:

```ruby
CArray.int32(2, 3) { |i, j| i * 3 + j }
#  => [ [ 0, 1, 2 ],
#       [ 3, 4, 5 ] ]

CArray.int32(3, 3) { |i, j| i == j ? 1 : 0 }   #  an identity matrix
#  => [ [ 1, 0, 0 ],
#       [ 0, 1, 0 ],
#       [ 0, 0, 1 ] ]
```

A 2-D block can express many familiar patterns directly. A chess-board pattern
is just the parity of `i + j`:

```ruby
CArray.int32(4, 4) { |i, j| (i + j) % 2 }
#  => [ [ 0, 1, 0, 1 ],
#       [ 1, 0, 1, 0 ],
#       [ 0, 1, 0, 1 ],
#       [ 1, 0, 1, 0 ] ]
```

A lower-triangular matrix of ones:

```ruby
CArray.int32(4, 4) { |i, j| i >= j ? 1 : 0 }
#  => [ [ 1, 0, 0, 0 ],
#       [ 1, 1, 0, 0 ],
#       [ 1, 1, 1, 0 ],
#       [ 1, 1, 1, 1 ] ]
```

A 2-D ramp — the value grows with the distance from the corner:

```ruby
CArray.float64(3, 3) { |i, j| (i + j).to_f }
#  => [ [ 0.0, 1.0, 2.0 ],
#       [ 1.0, 2.0, 3.0 ],
#       [ 2.0, 3.0, 4.0 ] ]
```

For a 3-D array the block receives three indices:

```ruby
CArray.int32(2, 2, 2) { |i, j, k| i*4 + j*2 + k }
#  => [ [ [ 0, 1 ],
#         [ 2, 3 ] ],
#       [ [ 4, 5 ],
#         [ 6, 7 ] ] ]
```

A single parameter is enough, and it does not have to be used: its presence is
what puts the block into per-element mode.

```ruby
CArray.int32(8) { |i| rand(100) }
#  => [ 73, 14, 88,  3, 51, 60,  9, 27 ]   #  evaluated 8 times
```

Filling this way is convenient, but every element pays for a Ruby block call.
Where the values can be had another way — a sequence, an arithmetic
expression, or `random!` for the case above — that way stays in C.

## Data types

| Constructor                            | Element type                      |
|----------------------------------------|-----------------------------------|
| `boolean`                              | true / false (stored as one byte) |
| `int8`, `int16`, `int32`, `int64`      | signed integers                   |
| `uint8`, `uint16`, `uint32`, `uint64`  | unsigned integers                 |
| `float32`, `float64`                   | floating-point numbers            |
| `cmplx64`, `cmplx128`                  | complex numbers                   |
| `fixlen`                               | fixed-length byte strings         |
| `object`                               | arbitrary Ruby objects            |

Each type stores its values directly, and that shows in how they print:

```ruby
CA_INT8([-1, 0, 1])
#  => [ -1, 0, 1 ]

CArray.uint8(4) { |i| i * 10 }
#  => [ 0, 10, 20, 30 ]

CArray.boolean(4) { |i| i.even? }
#  => [ 1, 0, 1, 0 ]    #  boolean prints as 0 / 1
```

Complex numbers print in `a+bi` form:

```ruby
CArray.cmplx128(3) { |i| Complex(i, -i) }
#  => [ 0.0+0.0i, 1.0-1.0i, 2.0-2.0i ]
```

The `object` type holds any Ruby value, and each element is whatever you put
there:

```ruby
CA_OBJECT([:a, "x", 1])
#  => [ :a, "x", 1 ]

CArray.object(2) { |i| {x: i} }
#  => [ {x: 0}, {x: 1} ]
```

`fixlen` is for fixed-width byte strings. It needs a `:bytes` option giving the
width; shorter strings are padded with null bytes, which is visible when the
array prints:

```ruby
CArray.fixlen(3, :bytes => 4) { |i| ["foo", "ab", "data"][i] }
#  => [ "foo\x00", "ab\x00\x00", "data" ]
```

A note on the block form used in these examples: writing `{ |i| ... }` is
convenient for showing how each data type is filled, but it calls back into Ruby
once per element and is not the fastest way to build an array. For real work,
prefer the dedicated routes covered later in this chapter — `CA_INT([...])` and
friends for known values, `seq` for arithmetic sequences, `random!` for random
fills — and reserve the per-cell block for cases where you genuinely need
arbitrary Ruby logic per element.

The data type of an existing array is reported by `data_type` as a symbol:

```ruby
CArray.float64(3).data_type    #  => :float64
CArray.int32(3).data_type      #  => :int32
CArray.boolean(3).data_type    #  => :boolean
```

## From a Ruby array of values

To build an array from values you already have in a Ruby `Array`, use the global
constructor functions. They take a (possibly nested) array and convert it,
choosing the shape from the nesting.

```ruby
CA_INT([1, 2, 3])
#  => [ 1, 2, 3 ]

CA_DOUBLE([[1, 2], [3, 4]])
#  => [ [ 1.0, 2.0 ],
#       [ 3.0, 4.0 ] ]

CA_DCOMPLEX([Complex(1, 2), Complex(0, -1)])
#  => [ 1.0+2.0i, 0.0-1.0i ]
```

Each constructor corresponds to a data type: `CA_BOOLEAN`, `CA_INT8`, `CA_INT32`,
`CA_FLOAT64`, and so on. `CA_INT`, `CA_FLOAT`, and `CA_DOUBLE` (an alias for
`CA_FLOAT64`) are convenient short names.

Nesting determines the shape, so a deeper Ruby array gives a higher-dimensional
CArray:

```ruby
CA_INT64([[1, 2], [3, 4]])
#  => [ [ 1, 2 ],
#       [ 3, 4 ] ]

CA_UINT8([0, 128, 255])
#  => [ 0, 128, 255 ]

CA_BOOLEAN([true, false, true])
#  => [ 1, 0, 1 ]
```

These functions also accept individual scalars and other CArrays, converting
the values to the target type. They are the canonical way to *cast* a Ruby
value or another array into a particular numeric type.

## Sequences

`seq` fills an existing array with an arithmetic sequence, in place, and returns
it. With no arguments it counts from 0 by 1; you can give a start and a step
(the step may be negative).

```ruby
CArray.float64(4).seq          #  => [ 0.0, 1.0, 2.0, 3.0 ]
CArray.float64(4).seq(1, 2)    #  => [ 1.0, 3.0, 5.0, 7.0 ]
CArray.int32(5).seq(10, -2)    #  => [ 10, 8, 6, 4, 2 ]
```

The step can be fractional for a float array:

```ruby
CArray.float64(5).seq(0.0, 0.5)
#  => [ 0.0, 0.5, 1.0, 1.5, 2.0 ]
```

For a multi-dimensional array, `seq` fills in row-major order:

```ruby
CArray.int32(2, 4).seq
#  => [ [ 0, 1, 2, 3 ],
#       [ 4, 5, 6, 7 ] ]

CArray.int32(3, 3).seq(1, 1)
#  => [ [ 1, 2, 3 ],
#       [ 4, 5, 6 ],
#       [ 7, 8, 9 ] ]
```

`span` fills with evenly spaced values covering a range (both ends included):

```ruby
CArray.float64(5).span(0..1)     #  => [ 0.0, 0.25, 0.5, 0.75, 1.0 ]
CArray.float64(5).span(0..100)   #  => [ 0.0, 25.0, 50.0, 75.0, 100.0 ]
```

`span` also works on a multi-dimensional shape, spreading the values across the
flat element order:

```ruby
CArray.float64(3, 3).span(0..1)
#  => [ [ 0.0,   0.125, 0.25  ],
#       [ 0.375, 0.5,   0.625 ],
#       [ 0.75,  0.875, 1.0   ] ]
```

## Random arrays

`random!` fills an array with random values **in place** and returns it. It runs
in C, without a per-element Ruby block, so it is the standard way to build a
random array (and it sidesteps the `{ rand }` broadcast trap noted earlier).

For a **float** array it draws uniformly from `[0, 1)` by default; a positional
argument sets the upper bound, two positional arguments set both bounds, and a
Ruby Range is accepted with `..` (closed) or `...` (half-open):

```ruby
CArray.float64(4).random!               #  => [ 0.42, 0.72, 0.00, 0.30 ]   in [0, 1)
CArray.float64(4).random!(10)           #  => [ 4.17, 7.20, 0.00, 3.02 ]   in [0, 10)
CArray.float64(4).random!(-1.0, 1.0)    #  => [ -0.17, 0.44, -1.00, -0.40 ]   in [-1, 1)
CArray.float64(4).random!(-0.5..0.5)    #  same shape, Range syntax
```

(The numbers here are illustrative — each call draws fresh values.  For
float arrays, `..` and `...` yield the same distribution: the endpoint
probability is ~2⁻⁵³, so the closed form is accepted syntactically but not
enforced at the mantissa level — matching NumPy/SciPy convention.)

For an **integer** array a range is required, since there is no natural
default:

```ruby
CArray.int32(6).random!(6)              #  => [ 5, 3, 4, 0, 1, 3 ]   each in [0, 6) = 0..5
CArray.int32(6).random!(-3, 3)          #  each in [-3, 3) = -3..2
CArray.int32(6).random!(1..6)           #  dice: each in 1..6 (6 included, Range closed)
CArray.int32(6).random!(1...6)          #  each in 1..5 (Range half-open)
```

A **boolean** array fills with random `0` / `1`.  `object` and `fixlen`
arrays are not supported.

### Normal distribution: `randomn!`

`randomn!` fills a float (or complex) array with standard-normal samples
(mean 0, standard deviation 1):

```ruby
CArray.float64(4).randomn!           #  => [ -0.25, -1.30, -1.38, 4.03 ]
```

Scale and shift with ordinary arithmetic when you need a different mean or
spread — for example `CArray.float64(n).randomn! * sd + mean`.

### Eager forms: `random` and `randomn`

`random!` and `randomn!` mutate the receiver. The non-bang `random` and
`randomn` instead return a **new** array of the same shape and data type, leaving
the receiver untouched:

```ruby
base = CArray.float64(3).seq   #  => [ 0.0, 1.0, 2.0 ]
r    = base.randomn            #  a fresh random array
base                           #  => [ 0.0, 1.0, 2.0 ]   base is unchanged
```

So `CArray.float64(1000).random` reads as "a new array of 1000 uniform samples"
— the receiver is consulted only for its shape and data type.

### Reproducible streams with `rng:`

By default these methods draw from Ruby's global random source. Pass `rng:` a
`Random` instance to control the stream; seeding it makes the fill reproducible:

```ruby
a = CArray.float64(4).random!(rng: Random.new(42))
b = CArray.float64(4).random!(rng: Random.new(42))
a.to_a == b.to_a               #  => true    same seed, same values
```

The `rng:` keyword works on all of `random`, `randomn`, `random!`, `randomn!`,
and on `shuffle` / `shuffle!`, which reorder an array's own elements at random
(eager copy and in-place respectively).

## Copying and materialising

`copy` returns a freshly allocated, independent array holding a copy of the data.
Use it whenever you want an array you can change without affecting the original —
or to turn a view (see [Views](06_views.md)) into real, contiguous memory.

```ruby
b = a.copy      #  an independent copy of a
```

`to_ca` just means "give me this as a CArray": anything that is already a CArray —
an entity *or* a view — is returned unchanged, with no copy. It is the general way
to obtain a CArray from a Ruby `Array` or another array library. When you want an
independent, owned copy, use `copy` (not `to_ca`).

The difference is most visible on a view:

```ruby
a = CArray.int32(2, 3).seq
v = a[0, nil]            #  a row view of a

v.to_ca.equal?(v)        #  => true    same object, no copy
v.copy.equal?(v)         #  => false   a fresh, independent entity

w = v.copy
w[0] = 99
a[0, 0]                  #  => 0       a is untouched, copy is independent
```

By contrast, writing through `v` itself would have changed `a`; that is the
point of a view, and is covered in [Views](06_views.md).
