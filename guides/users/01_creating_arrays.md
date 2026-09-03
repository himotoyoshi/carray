# Creating arrays

## By shape and data type

The basic constructor is a class method named after the data type. It takes the shape — one integer per axis — and returns an array of that shape.

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

The full set of data types, and the constructor that makes each:

| Constructor                            | Element type                      |
|----------------------------------------|-----------------------------------|
| `boolean`                              | true / false (stored as one byte) |
| `int8`, `int16`, `int32`, `int64`      | signed integers                   |
| `uint8`, `uint16`, `uint32`, `uint64`  | unsigned integers                 |
| `float32`, `float64`                   | floating-point numbers            |
| `cmplx64`, `cmplx128`                  | complex numbers                   |
| `fixlen`                               | fixed-length byte strings         |
| `object`                               | arbitrary Ruby objects            |

An array reports its own type as a symbol:

```ruby
CArray.float64(3).data_type    #  => :float64
CArray.int32(3).data_type      #  => :int32
CArray.boolean(3).data_type    #  => :boolean
```

### Filling the whole array

`fill` puts one value into every element and returns the array. It is a destructive method: it writes into the array it is called on, even though its name carries no `!`. Because the plain name is taken, the copying form is the one that had to be given a suffix — `fill_copy`, at the end of this chapter.

```ruby
CArray.float64(2, 4).fill(9.0)
#  => [ [ 9.0, 9.0, 9.0, 9.0 ],
#       [ 9.0, 9.0, 9.0, 9.0 ] ]

CArray.int32(5).fill(-1)
#  => [ -1, -1, -1, -1, -1 ]
```

Assigning to the whole array with `a[] = 9.0` does the same thing.

A block that takes no parameters is shorthand for assigning to the array once it has been made. The block is evaluated a single time and its value is stored into the whole array:

```ruby
CArray.float64(2, 4) { 9.0 }
#  => [ [ 9.0, 9.0, 9.0, 9.0 ],
#       [ 9.0, 9.0, 9.0, 9.0 ] ]

CArray.float64(2, 4).tap { |a| a[] = 9.0 }     #  the same thing, spelled out
```

What the block cannot do is run more than once. An expression that would give a different answer each time it ran is still run only once, and that one answer goes everywhere. To vary by element, the block has to be given the indices to vary by — which is the next section.

### From the indices

A block that takes parameters is called once per element and receives that element's indices; its return value becomes that element. Where the parameterless block assigns the whole array once, this one fills it cell by cell.

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

A 2-D block can express many familiar patterns directly. A chess-board pattern is just the parity of `i + j`:

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

What the constructor is doing here is `map_index!`, written as part of making the array: the block receives one index per axis. Naming fewer parameters than there are axes drops the ones you did not name, exactly as in any Ruby block — so `{ |i| ... }` on a 2-D array is handed the row index, the same value all the way along each row.

```ruby
CArray.int32(2, 3) { |i, j| i * 3 + j }
CArray.int32(2, 3).map_index! { |i, j| i * 3 + j }   #  the same thing
#  => [ [ 0, 1, 2 ],
#       [ 3, 4, 5 ] ]

CArray.int32(2, 3) { |i| 2 * i }
#  => [ [ 0, 0, 0 ],
#       [ 2, 2, 2 ] ]                                 #  i is the row index
```

A single running count over the whole array is a different thing, and it has its own name: `map_addr!` hands the block one number that walks the elements in order.

```ruby
CArray.int32(2, 3).map_addr! { |i| 2 * i }
#  => [ [ 0, 2,  4 ],
#       [ 6, 8, 10 ] ]
```

On a 1-D array the two coincide, which is where the expectation comes from.

Filling this way is convenient, but every element pays for a Ruby block call. Where the values can be had another way — a sequence, an arithmetic expression, a random fill — that way stays in C.

## Sequences

`seq!` puts an arithmetic sequence into the array it is called on. With no arguments it counts from 0 by 1; you can give a start and a step (the step may be negative).

```ruby
CArray.float64(4).seq!          #  => [ 0.0, 1.0, 2.0, 3.0 ]
CArray.float64(4).seq!(1, 2)    #  => [ 1.0, 3.0, 5.0, 7.0 ]
CArray.int32(5).seq!(10, -2)    #  => [ 10, 8, 6, 4, 2 ]
```

The step can be fractional for a float array:

```ruby
CArray.float64(5).seq!(0.0, 0.5)
#  => [ 0.0, 0.5, 1.0, 1.5, 2.0 ]
```

For a multi-dimensional array, `seq!` fills in row-major order:

```ruby
CArray.int32(2, 4).seq!
#  => [ [ 0, 1, 2, 3 ],
#       [ 4, 5, 6, 7 ] ]

CArray.int32(3, 3).seq!(1, 1)
#  => [ [ 1, 2, 3 ],
#       [ 4, 5, 6 ],
#       [ 7, 8, 9 ] ]
```

`span!` fills with evenly spaced values covering a range (both ends included):

```ruby
CArray.float64(5).span!(0..1)     #  => [ 0.0, 0.25, 0.5, 0.75, 1.0 ]
CArray.float64(5).span!(0..100)   #  => [ 0.0, 25.0, 50.0, 75.0, 100.0 ]
```

`span!` also works on a multi-dimensional shape, spreading the values across the flat element order:

```ruby
CArray.float64(3, 3).span!(0..1)
#  => [ [ 0.0,   0.125, 0.25  ],
#       [ 0.375, 0.5,   0.625 ],
#       [ 0.75,  0.875, 1.0   ] ]
```

`scale!` does the same with two endpoints instead of a range, and always includes both:

```ruby
CArray.float64(5).scale!(10, 20)   #  => [ 10.0, 12.5, 15.0, 17.5, 20.0 ]
CArray.float64(5).scale!(20, 10)   #  => [ 20.0, 17.5, 15.0, 12.5, 10.0 ]
```

The difference between the two is at the edges. A `Range` can leave its end out, so `span!(0...1)` spreads the values over a shorter interval than `span!(0..1)` does; and `span!` refuses an integer array outright, since "five evenly spaced integers from 0 to 10" has two defensible answers and it will not pick one for you (the error names both). `scale!` takes the endpoints directly and rounds:

```ruby
CArray.float64(5).span!(0...1)     #  => [ 0.0, 0.2, 0.4, 0.6000000000000001, 0.8 ]
CArray.int32(5).scale!(0, 10)      #  => [ 0, 2, 5, 7, 10 ]
```

### `seq!` and `seq`

`seq`, `span` and `scale` exist too, and they are not the same method with the mark left off. They leave the receiver alone and answer with a **new** array of its shape and data type, filled by the same rule:

```ruby
x = CArray.float64(4).seq!(100)   #  => [ 100.0, 101.0, 102.0, 103.0 ]

x.seq                             #  => [ 0.0, 1.0, 2.0, 3.0 ]
x                                 #  => [ 100.0, 101.0, 102.0, 103.0 ]   untouched
```

On an array you have just allocated the two give the same values, which is why `CArray.float64(4).seq` is a common thing to write. It does more work, though: the array you allocated is used only as a pattern for a second one, so the memory is claimed twice and written twice — about double the time from a million elements upward. When you have just made the array, `seq!` is the one that says what you mean.

## Random values

`random!` fills an array with random values in place. It runs in C, without a per-element Ruby block.

For a **float** array it draws uniformly from `[0, 1)` by default; one argument sets the upper bound, two arguments set both, and a Range says the same thing:

```ruby
CArray.float64(4).random!               #  in [0, 1)
CArray.float64(4).random!(10)           #  in [0, 10)
CArray.float64(4).random!(-1.0, 1.0)    #  in [-1, 1)
CArray.float64(4).random!(-0.5..0.5)    #  the same, written as a Range
```

For an **integer** array the range is required, since there is no natural default. A closed Range includes its end, an exclusive one does not:

```ruby
CArray.int32(6).random!(6)              #  each in 0..5
CArray.int32(6).random!(1..6)           #  dice: each in 1..6
CArray.int32(6).random!(1...6)          #  each in 1..5
```

A **boolean** array fills at random as well; `object` and `fixlen` arrays are not supported.

`randomn!` is the same idea for the normal distribution: it fills a float or complex array with standard-normal samples, mean 0 and standard deviation 1. Scale and shift with ordinary arithmetic when you want a different mean or spread — `CArray.float64(n).randomn! * sd + mean`.

### `random!` and `random`

`random` and `randomn` exist too, and as with `seq`, they are not the same method with the mark left off. They leave the receiver alone and answer with a new array of its shape and data type, filled with fresh samples:

```ruby
base = CArray.float64(3).seq!   #  => [ 0.0, 1.0, 2.0 ]
r    = base.randomn             #  a fresh random array
base                            #  => [ 0.0, 1.0, 2.0 ]   base is unchanged
```

So `CArray.float64(1000).random` reads as "a new array of 1000 uniform samples" — the receiver is consulted for its shape and data type and nothing else. When you have just allocated the array, `random!` is the one that says what you mean.

All four take an `rng:` keyword: pass a `Random` instance to draw from that instead of Ruby's global source, and a seeded one — `random!(rng: Random.new(42))` — makes the fill reproducible. The same keyword works on `shuffle` and `shuffle!`, which put an array's own elements into a random order.

### The other way: a block

A random array can also be built with a block — but only if the block takes an index. Without a parameter it is a constant fill, by the rule earlier in this chapter: `rand` is called once, and that one number goes everywhere.

```ruby
CArray.int32(8) { rand(100) }
#  => [ 42, 42, 42, 42, 42, 42, 42, 42 ]   #  one call, broadcast

CArray.int32(8) { |i| rand(100) }
#  => [ 73, 14, 88,  3, 51, 60,  9, 27 ]   #  eight separate calls
```

The second form does what was meant, but it is the long way round: every element leaves C, runs Ruby, and comes back. Over a million elements that costs roughly ten times what `random!(100)` costs for the same result.

So one spelling quietly fills the array with a single number and the other pays a Ruby call per element. `random!` does neither — reach for it, or for `random`, and keep the block for values nothing else can produce.

## From an existing array

An array is also a source for the next one. `copy` returns a freshly allocated, independent array holding a copy of the data. Use it whenever you want an array you can change without affecting the original — or to turn a view (see [Views](06_views.md)) into real, contiguous memory. It always allocates.

```ruby
a = CArray.int32(2, 3).seq!
b = a.copy      #  an independent copy of a

b[0, 0] = 99
a[0, 0]         #  => 0    a is untouched
```

`fill_copy` is that same copy with one value put everywhere — `a.fill_copy(7)`. Zeros and ones are wanted often enough to have methods of their own, `a.zero` and `a.one`, each with a `!` form that writes into the receiver instead.

### An array shaped like another one: `template`

This is the shape-only companion of `copy`, and it is what the plain `seq`, `span`, `scale`, `random` and `randomn` were doing earlier in this chapter: the receiver serves as a pattern and nothing more.

`copy` brings the values across with the shape. When only the shape is wanted — a fresh array to write results into — `template` gives one: the same shape and data type as the receiver, filled with zeros.

```ruby
a = CArray.int32(2, 3).seq!

a.template
#  => [ [ 0, 0, 0 ],
#       [ 0, 0, 0 ] ]

a.template(:float64)          #  the same shape, a different data type
#  => [ [ 0.0, 0.0, 0.0 ],
#       [ 0.0, 0.0, 0.0 ] ]
```

It takes a block on the same terms as the constructors at the top of this chapter: no parameters fills, parameters set the elements from their indices.

```ruby
a.template { 7 }
#  => [ [ 7, 7, 7 ],
#       [ 7, 7, 7 ] ]

a.template(:float64) { |i, j| i + j * 0.5 }
#  => [ [ 0.0, 0.5, 1.0 ],
#       [ 1.0, 1.5, 2.0 ] ]
```

The receiver donates its shape and its data type, and nothing else — not its values, and not anything else it carries.

## Data type casting

An array's data type is settled when it is made, so changing it means making another array. There are two spellings for that.

The first is a method on the array, named after the type you want:

```ruby
a = CA_DOUBLE([1.5, 2.5, 3.5])

a.int32                    #  => [ 1, 2, 3 ]           the fraction is dropped
a.float32                  #  => [ 1.5, 2.5, 3.5 ]
```

`to_type` is the same thing said with the type as an argument, for when it is not known until the program runs:

```ruby
a.to_type(:int32)          #  => [ 1, 2, 3 ]
```

The second is a global function, again one per data type. These read the way a cast reads in C, with the type standing in front of what is to be brought over:

```ruby
CA_INT(a)                  #  => [ 1, 2, 3 ]
CA_FLOAT32(a)              #  => [ 1.5, 2.5, 3.5 ]
```

`CA_BOOLEAN`, `CA_INT8`, `CA_INT32`, `CA_FLOAT64`, `CA_CMPLX128`, `CA_OBJECT` and the rest all exist, with `CA_INT`, `CA_FLOAT` and `CA_DOUBLE` as short names for the common three. Handed an array, the two spellings do the same work; and an array that is already of the type asked for comes back as a copy.

## `to_ca` — a CArray from something that is not one

`to_ca` is the method an object implements in order to hand you a CArray. Ruby's `Array` and `Range` implement it, and so do the array classes of other libraries.

```ruby
[1, 2, 3].to_ca                #  => [ 1, 2, 3 ]
(0..4).to_ca                   #  => [ 0, 1, 2, 3, 4 ]
```

It promises a CArray and nothing beyond that. In particular it does **not** promise a duplicate. What comes back may share its memory with the source or may be freshly made, and which of those you get is the implementer's business. A CArray asked for `to_ca` hands back itself.

So when you want something you can change freely, say so: `copy` always allocates, and `x.to_ca.copy` is the spelling for an `x` that may not be a CArray yet.

Since no data type was named, an `Array` or a `Range` lands in `object`. When the elements are numbers you mean to compute with, name the type instead:

```ruby
[1, 2, 3].to_ca.data_type      #  => :object
CA_INT([1, 2, 3]).data_type    #  => :int32
```

## Casting something that is not an array

The `CA_<TYPE>` functions take more than arrays. Where `to_ca` asks only for a CArray, these ask for one *of a named type*, and they accept much the same things.

A single number comes back as a `CScalar` — one value carrying a CArray data type, which arithmetic and assignment accept anywhere an array is accepted:

```ruby
CA_INT(3)                  #  => [ 3 ]
CA_DOUBLE(3)               #  => [ 3.0 ]
```

A Ruby `Array` becomes an array of those values, and the nesting gives the shape:

```ruby
CA_INT([1, 2, 3])
#  => [ 1, 2, 3 ]

CA_DOUBLE([[1, 2], [3, 4]])
#  => [ [ 1.0, 2.0 ],
#       [ 3.0, 4.0 ] ]
```

A `Range` is counted out. A second argument gives the step, and a descending range counts down:

```ruby
CA_INT(0..5)               #  => [ 0, 1, 2, 3, 4, 5 ]
CA_INT(0...5)              #  => [ 0, 1, 2, 3, 4 ]
CA_DOUBLE(0..1, 0.25)      #  => [ 0.0, 0.25, 0.5, 0.75, 1.0 ]
CA_INT(5..0)               #  => [ 5, 4, 3, 2, 1, 0 ]
```

A String is read as the values themselves. Whitespace or a comma separates the elements, a semicolon starts a new row, and `_` marks a missing one (see [Masks and missing values](05_masks.md)):

```ruby
CA_INT("1 2 3")            #  => [ 1, 2, 3 ]

CA_INT("1 2; 3 4")
#  => [ [ 1, 2 ],
#       [ 3, 4 ] ]
```

And `nil` gives an empty array of that type:

```ruby
CA_INT(nil)                #  => [  ]
```

### What each type looks like

These functions are also the shortest way to see how each data type prints. Signed and unsigned integers print as integers, booleans as `1` / `0`, complex numbers in `a+bi` form:

```ruby
CA_INT8([-1, 0, 1])                 #  => [ -1, 0, 1 ]
CA_UINT8([0, 10, 20, 30])           #  => [ 0, 10, 20, 30 ]
CA_BOOLEAN([true, false, true])     #  => [ 1, 0, 1 ]
CA_CMPLX128([Complex(1, 2), Complex(0, -1)])
#  => [ 1.0+2.0i, 0.0-1.0i ]
```

An `object` array holds whatever you put into it, and prints each element the way Ruby would:

```ruby
CA_OBJECT([:a, "x", 1])             #  => [ :a, "x", 1 ]
CA_OBJECT([{x: 0}, {x: 1}])         #  => [ {x: 0}, {x: 1} ]
```

A `fixlen` array holds fixed-width byte strings, and `CA_FIXLEN` takes that width as `bytes:`. Anything shorter is padded with null bytes, which shows when the array prints:

```ruby
CA_FIXLEN(["foo", "ab", "data"], bytes: 4)
#  => [ "foo\x00", "ab\x00\x00", "data" ]
```
