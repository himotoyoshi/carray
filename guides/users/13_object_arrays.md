# Arrays of Ruby objects

Most CArray data types are numeric — an `int32` array holds machine integers, a
`float64` array holds doubles. The `object` data type is different: each cell
holds an arbitrary Ruby value. Strings, symbols, hashes, your own class
instances, even other arrays — anything that fits in a `VALUE` slot fits in an
`object` cell.

This is the escape hatch for cases where the value is not a number, or where
the numeric types do not say enough on their own.

## What `object` arrays are good for

A few common situations:

- The values are not numeric at all — strings, symbols, dates, custom
  domain objects.
- The values are heterogeneous — different cells hold different kinds of
  Ruby object (some `Integer`, some `Float`, some `String`).
- The values are numeric but need Ruby semantics — arbitrary-precision
  integers (`Bignum`), `Rational`, `BigDecimal`.
- You want CArray's shape, indexing, masking, and view machinery, but the
  payload is a Ruby object you would otherwise put in a nested
  `Array`.

You give up speed: every read and write crosses into Ruby. You get back
generality.

## Constructing an object array

The constructor is `CArray.object`, with the same shape-and-block form as the
numeric constructors (see [Creating arrays](01_creating_arrays.md)). With no
block, every cell is initialised to the Ruby integer `0`:

```ruby
CArray.object(3)
#  => [ 0, 0, 0 ]
```

With a block, the block is called once per cell and its return value becomes
the element:

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

You can also build one from an existing Ruby `Array` with the global
constructor `CA_OBJECT`:

```ruby
CA_OBJECT([:a, "b", 3])
#  => [ :a, "b", 3 ]

CA_OBJECT([[1, 2], [3, 4]])
#  => [ [ 1, 2 ],
#       [ 3, 4 ] ]
```

As with the other `CA_*` constructors, the nesting determines the shape.

The arity-0 block shortcut from
[Creating arrays](01_creating_arrays.md) applies here too: a block that takes
no arguments is evaluated once and broadcast.

```ruby
CArray.object(3) { "same string" }
#  => [ "same string", "same string", "same string" ]
```

Give the block a parameter — even an unused one — to evaluate it per cell.

## Heterogeneous storage

There is no rule that says all cells must be the same Ruby class. Different
cells can hold different kinds of object:

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
#  => Integer Float String
```

## Arithmetic: it calls the Ruby method

Element-wise arithmetic on an `object` array is just CArray walking the cells
and invoking the corresponding Ruby method on each one. There is no
specialised C kernel — `+` on an `object` array means "send `+` to each
element".

This makes the usual operators work on whatever the elements are willing to
accept:

```ruby
n = CA_OBJECT([1, 2, 3])
n + 10
#  => [ 11, 12, 13 ]
n * 2
#  => [ 2, 4, 6 ]
```

With strings, `+` concatenates and `*` repeats — because that is what those
operators mean for `String`:

```ruby
s = CA_OBJECT(["a", "b", "c"])
s + "!"
#  => [ "a!", "b!", "c!" ]
s * 3
#  => [ "aaa", "bbb", "ccc" ]
```

Two object arrays of the same shape combine element by element, again by
dispatching to Ruby:

```ruby
s = CA_OBJECT(["a", "b", "c"])
t = CA_OBJECT(["1", "2", "3"])
s + t
#  => [ "a1", "b2", "c3" ]
```

Comparisons (`eq`, `lt`, `gt`, …) and the comparison operators work the same
way, by calling the Ruby method on the element and giving you a boolean
result:

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

Operations that are not meaningful for the element class will raise whatever
exception that class would normally raise. There is no silent coercion. If a
cell holds an object that does not respond to the operator, the call fails
the same way it would in plain Ruby.

Numeric reductions such as `sum`, `mean`, `min`, and `max`
(see [Reduction and statistics](04_reduction_and_statistics.md)) work on an
object array by folding the cells with the corresponding Ruby operator — `sum`
sends `+`, `min` and `max` compare with `<=>`. They succeed when the elements
support that operator and raise whatever the element class would raise when
they do not (summing strings, for example). Note that the result stays in Ruby
arithmetic — `mean` of integer cells uses integer division, for instance. For
heavy numeric work, convert to a numeric type first (see "Converting" below).

## Masks work the same as for numeric arrays

Object arrays carry the same mask machinery as numeric arrays
(see [Masks and missing values](05_masks.md)). Assigning `UNDEF` to a cell
marks it as missing:

```ruby
m = CArray.object(4) { |i| i.odd? ? UNDEF : i }
m.has_mask?
#  => true
m.to_a
#  => [ 0, UNDEF, 2, UNDEF ]
m.mask.to_a
#  => [false, true, false, true]
```

This is one of the advantages of using an object array over a nested Ruby
`Array`: you get a real, separate mask, distinct from any "is this `nil`?"
convention you might otherwise have to invent.

## Views and shape work the same

Slicing, transposing, and the other view operations from
[Views](06_views.md) all work on object arrays:

```ruby
m = CArray.object(2, 3) { |i, j| [i, j].to_s }
m[0, nil].to_a
#  => [ "[0, 0]", "[0, 1]", "[0, 2]" ]
m.transpose.to_a
#  => [ [ "[0, 0]", "[1, 0]" ],
#       [ "[0, 1]", "[1, 1]" ],
#       [ "[0, 2]", "[1, 2]" ] ]
```

A view of an object array shares its cells with the original. Writing
through the view changes the underlying array, as with any other CArray.

## Converting to and from numeric arrays

When the values in an `object` array are actually numeric, you can promote
them to a numeric data type with the usual type-conversion methods:

```ruby
n = CA_OBJECT([1, 2, 3])
n.int32.to_a
#  => [ 1, 2, 3 ]
n.float64.to_a
#  => [ 1.0, 2.0, 3.0 ]
```

The conversion calls `to_i` / `to_f` on each cell. If a cell holds something
that does not convert, you will get the usual Ruby exception.

Going the other way — wrapping a numeric array in `:object` form — is also a
type conversion:

```ruby
CA_INT32([10, 20, 30]).object.to_a
#  => [ 10, 20, 30 ]
```

Each cell becomes a Ruby `Integer` (or `Float`, etc., depending on the
source type).

## Memory and garbage collection

The CArray itself owns a row of `VALUE` slots, one per cell. The Ruby
objects those slots point to are owned by Ruby in the usual way — CArray
marks them so the garbage collector keeps them alive as long as the array
holds a reference, and does not free them when the array is collected
(Ruby's GC does that).

In practice: you do nothing. Assign Ruby objects into the array and read
them out. The GC will not collect a string while it is sitting in an
`:object` cell, and you do not have to free anything yourself when the
array goes out of scope.

The initial fill value of `CArray.object(n)` with no block is the Ruby
integer `0`, not `nil`. That is intentional — `object` arrays are
ultimately numeric arrays in shape, and a numeric zero is a more useful
default than `nil` for the cases where the values are going to be
arithmetic.

## When not to use `object`

Object arrays are a fallback. Each operation crosses the C-to-Ruby
boundary once per cell, which is slower than the equivalent numeric kernel
by a wide margin. For numeric work — reductions, element-wise math, large
data — use a numeric data type from the start.

Reach for `:object` when the values genuinely are not numeric, or when the
flexibility is worth the cost: heterogeneous payloads, prototyping a
shape-aware data structure, or wrapping a small number of Ruby objects in
something that participates in CArray indexing and masking.
