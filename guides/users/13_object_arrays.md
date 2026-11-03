# Arrays of Ruby objects

Most CArray data types are numeric — an `int32` array holds machine integers, a `float64` array holds doubles. An array whose `data_type` is `:object` is different: each cell holds an arbitrary Ruby value. Strings, symbols, hashes, instances of any class, even other arrays — any Ruby object fits in a cell of such an array.

This is for cases where the value is not a number, or where the numeric types do not say enough on their own.

## What `object` arrays are good for

A few common situations:

- The values are not numeric at all — strings, symbols, dates, custom domain objects.
- The values are heterogeneous — different cells hold different kinds of Ruby object (some `Integer`, some `Float`, some `String`).
- The values are numeric but need Ruby semantics — integers of any size, `Rational`, `BigDecimal`.
- The code needs CArray's shape, indexing, masking, and view machinery, but the values are Ruby objects that would otherwise go in a nested `Array`.

The generality of an array with `data_type` `:object` costs speed, because every read and write crosses into Ruby.

## Constructing an object array

The constructor is `CArray.object`, with the same shape-and-block form as the numeric constructors (see [Creating arrays](01_creating_arrays.md)). With no block, every cell is initialised to the Ruby integer `0`, not `nil`:

```ruby
CArray.object(3)
#  => [ 0, 0, 0 ]
```

With a block, the block is called once per cell and its return value becomes the element:

```ruby
CArray.object(3) { |i| [:a, "x", 1][i] }
#  => [ :a, "x", 1 ]

CArray.object(2) { |i| {x: i} }
#  => [ {x: 0}, {x: 1} ]
```

The `data_type` of an object array reports as `:object`:

```ruby
CArray.object(3).data_type
#  => :object
```

An `object` array can also be built from an existing Ruby `Array` with the global function `CA_OBJECT`:

```ruby
CA_OBJECT([:a, "b", 3])
#  => [ :a, "b", 3 ]

CA_OBJECT([[1, 2], [3, 4]])
#  => [ [ 1, 2 ],
#       [ 3, 4 ] ]
```

As with the other `CA_*` functions, the nesting determines the shape.

`Array#to_ca` gives the same result. Its `data_type` is `:object` even when every element is a number:

```ruby
[1, 2, 3].to_ca.data_type_name
#  => "object"

[[1, 2], [3, 4]].to_ca.shape
#  => [2, 2]
```

To get a numeric array from a Ruby `Array`, use a numeric function such as `CA_INT32` or `CA_FLOAT64`.

The shorthand from [Creating arrays](01_creating_arrays.md) applies here too: a block that takes no parameters is evaluated once and its value stored into the whole array.

```ruby
CArray.object(3) { "same string" }
#  => [ "same string", "same string", "same string" ]
```

Every cell then holds the same object, so changing that String in place shows in all of them. Give the block a parameter — even an unused one — to evaluate it per cell.

## Heterogeneous storage

There is no rule that says all cells must be the same Ruby class. Different cells can hold different kinds of object:

```ruby
h = CArray.object(3) { |i| [1, "two", 3.0][i] }
h.to_a
#  => [ 1, "two", 3.0 ]
h.data_type
#  => :object
```

Iteration yields whatever Ruby class each cell happens to hold:

```ruby
CA_OBJECT([1, 2.0, "three"]).each { |v| print v.class, " " }
#  Integer Float String
```

## Arithmetic: it calls the Ruby method

Element-wise arithmetic on an `object` array calls the corresponding Ruby method on each cell: `+` on an `object` array means "send `+` to each element".

This makes the usual operators work on whatever the elements are willing to accept:

```ruby
n = CA_OBJECT([1, 2, 3])
n + 10
#  => [ 11, 12, 13 ]
n * 2
#  => [ 2, 4, 6 ]
```

With strings, `+` concatenates and `*` repeats — because that is what those operators mean for `String`:

```ruby
s = CA_OBJECT(["a", "b", "c"])
s + "!"
#  => [ "a!", "b!", "c!" ]
s * 3
#  => [ "aaa", "bbb", "ccc" ]
```

Two object arrays of the same shape combine element by element, again by dispatching to Ruby:

```ruby
s = CA_OBJECT(["a", "b", "c"])
t = CA_OBJECT(["1", "2", "3"])
s + t
#  => [ "a1", "b2", "c3" ]
```

Comparisons (`eq`, `lt`, `gt`, …) and the comparison operators work the same way, by calling the Ruby method on the element and returning a boolean result:

```ruby
n = CA_OBJECT([1, 2, 3])
n > 1
#  => [ 0, 1, 1 ]
```

For named-value equality, `eq` works against any Ruby object:

```ruby
CA_OBJECT([:a, :b, :a, :c]).eq(:a)
#  => [ 1, 0, 1, 0 ]
```

Operations that are not meaningful for the element class will raise whatever exception that class would normally raise. There is no silent coercion. If a cell holds an object that does not respond to the operator, the call fails the same way it would in plain Ruby.

Numeric reductions such as `sum`, `mean`, `min`, and `max` (see [Reduction and statistics](04_reduction_and_statistics.md)) work on an object array by folding the cells with the corresponding Ruby operator — `sum` sends `+`, `min` and `max` compare with `<=>`. They succeed when the elements support that operator and raise whatever the element class would raise when they do not (summing strings, for example). Note that the result stays in Ruby arithmetic — `mean` of integer cells uses integer division, for instance. For heavy numeric work, convert to a numeric type first (see [Converting to and from numeric arrays](#converting-to-and-from-numeric-arrays)).

## Masks work the same as for numeric arrays

Object arrays carry the same mask machinery as numeric arrays (see [Masks and missing values](05_masks.md)). Assigning `UNDEF` to a cell marks it as missing:

```ruby
m = CArray.object(4) { |i| i.odd? ? UNDEF : i }
m.has_mask?
#  => true
m.to_a
#  => [ 0, UNDEF, 2, UNDEF ]
m.mask.to_a
#  => [false, true, false, true]
```

This is one advantage of an object array over a nested Ruby `Array`: the mask is real and separate, so the code does not need a convention such as "`nil` means missing".

A `nil` in a cell is a value, so it takes part like any other: `o.eq(nil)`, `o.count(nil)` and `o.search(nil)` find it, and a masked cell is not `nil`. The numeric predicates ask the cell itself, as arithmetic does: `is_nan` calls `nan?`, and `is_invalid` and `mask_invalid` call `finite?`. A cell whose value has no such method raises `NoMethodError`, which is Ruby's own answer. Mask those cells first if the column holds more than numbers:

```ruby
o = CA_OBJECT([1.0, nil, Float::NAN])
o.is_nan                  #  NoMethodError: undefined method 'nan?' for nil
o.mask_eq(nil).is_nan.to_a  #  => [false, UNDEF, true]
```

## Views and shape work the same

Slicing, transposing, and the other view operations from [Views](06_views.md) all work on object arrays:

```ruby
m = CArray.object(2, 3) { |i, j| [i, j].to_s }
m[0, nil].to_a
#  => [ "[0, 0]", "[0, 1]", "[0, 2]" ]
m.transpose.to_a
#  => [ [ "[0, 0]", "[1, 0]" ],
#       [ "[0, 1]", "[1, 1]" ],
#       [ "[0, 2]", "[1, 2]" ] ]
```

A view of an object array shares its cells with the original. Writing through the view changes the underlying array, as with any other CArray.

## Converting to and from numeric arrays

When the values in an `object` array are actually numeric, they can be converted to a numeric data type with the usual type-conversion methods:

```ruby
n = CA_OBJECT([1, 2, 3])
n.int32.to_a
#  => [ 1, 2, 3 ]
n.float64.to_a
#  => [ 1.0, 2.0, 3.0 ]
```

A number keeps its value (an integer type drops the fraction), and a String is read as a decimal number. A cell that cannot be read this way becomes `UNDEF` instead of raising:

```ruby
CA_OBJECT([1, 2.5, "3", "abc", nil]).float64.to_a
#  => [ 1.0, 2.5, 3.0, UNDEF, UNDEF ]
```

Going the other way — turning a numeric array into an `object` array — is also a type conversion:

```ruby
CA_INT32([10, 20, 30]).object.to_a
#  => [ 10, 20, 30 ]
```

Each cell becomes a Ruby `Integer` (or `Float`, etc., depending on the source type).

## Memory and garbage collection

No special handling is needed. Assign Ruby objects into the array and read them out. The garbage collector does not collect a string while it is in an `object` cell, and nothing has to be freed by hand when the array goes out of scope.

## Arrays inside cells

A cell can hold another array, and that array's cells can hold more. An array that comes back to itself this way is refused with `ArgumentError` ("cyclic reference") when it is read. Operations that walk into the cells — `hash`, `==`, `eql?`, `unique` and the other value-hash methods, `Marshal.dump` — also refuse arrays nested more than 256 levels deep, because a lazy expression in a cell can give a new array each time it is opened and never come back to one already seen.

## When not to use `object`

Object arrays are a fallback. Each operation crosses the C-to-Ruby boundary once per cell, which is slower than the equivalent numeric kernel by a wide margin. For numeric work — reductions, element-wise math, large data — use a numeric data type from the start.

Use `:object` when the values genuinely are not numeric, or when the flexibility is worth the cost: heterogeneous payloads, prototyping a shape-aware data structure, or wrapping a small number of Ruby objects in something that participates in CArray indexing and masking.
