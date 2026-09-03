# Element-wise operations

Operations apply to every element and return a new array of results. The original
array is left unchanged unless you use an in-place form.

## Arithmetic with a scalar

```ruby
a = CArray.int32(2, 3).seq!
#  => [ [ 0, 1, 2 ],
#       [ 3, 4, 5 ] ]

a + 1
#  => [ [ 1, 2, 3 ],
#       [ 4, 5, 6 ] ]

a * 2
#  => [ [ 0, 2,  4 ],
#       [ 6, 8, 10 ] ]

a - 10
#  => [ [ -10, -9, -8 ],
#       [  -7, -6, -5 ] ]

a % 2
#  => [ [ 0, 1, 0 ],
#       [ 1, 0, 1 ] ]

-a
#  => [ [ 0, -1, -2 ],
#       [ -3, -4, -5 ] ]
```

Division and exponentiation work the same way:

```ruby
a / 2
#  => [ [ 0, 0, 1 ],
#       [ 1, 2, 2 ] ]      integer divide-and-floor

a ** 2
#  => [ [ 0,  1,  4 ],
#       [ 9, 16, 25 ] ]
```

`/` and `%` work exactly as Ruby's do: on integers `/` rounds toward negative
infinity and `%` carries the sign of the divisor, so `(a / b) * b + a % b == a`
whatever the signs are. C's convention — truncate toward zero, remainder taking
the sign of the dividend — is a separate method, `fmod`, which takes integers as
well as floats; `divmod` answers with the `/` and `%` pair together.

An integer array divided by an integer stays integer. For a floating-point
quotient, divide by a float (or convert the array first):

```ruby
a / 2.0
#  => [ [ 0.0, 0.5, 1.0 ],
#       [ 1.5, 2.0, 2.5 ] ]
```

The scalar's type widens the result: a float scalar promotes the whole result
to floating point, as "Data type promotion" below sets out.

The operators have named equivalents — `add`, `sub`, `mul`, `div`, `mod`,
`pow` — so `a + 1` and `a.add(1)` are the same:

```ruby
a.add(1)
#  => [ [ 1, 2, 3 ],
#       [ 4, 5, 6 ] ]

a.pow(2)
#  => [ [ 0,  1,  4 ],
#       [ 9, 16, 25 ] ]
```

## Arithmetic between two arrays

When both operands are arrays of the same shape, the operation is applied
position by position. (Arrays of *different* shapes are handled by
[Broadcasting](07_broadcasting.md).)

```ruby
a = CArray.int32(2, 3).seq!                  #  => [ [ 0, 1, 2 ], [ 3, 4, 5 ] ]
b = CArray.int32(2, 3) { |i, j| (i * 3 + j) * 10 }
#  => [ [  0, 10, 20 ],
#       [ 30, 40, 50 ] ]

a + b
#  => [ [  0, 11, 22 ],
#       [ 33, 44, 55 ] ]

a * b
#  => [ [  0,  10,  40 ],
#       [ 90, 160, 250 ] ]

b - a
#  => [ [  0,  9, 18 ],
#       [ 27, 36, 45 ] ]
```

Subtraction, division, and modulo are not commutative, so the order matters:

```ruby
a - b
#  => [ [   0,  -9, -18 ],
#       [ -27, -36, -45 ] ]
```

## In-place forms

Many operations have a bang (`!`) variant that modifies the array in place
instead of returning a new one. This avoids allocating a result when you do not
need the original.

```ruby
a = CArray.int32(2, 3).seq!
a.add!(10)
#  => [ [ 10, 11, 12 ],
#       [ 13, 14, 15 ] ]    a itself is changed
```

The other arithmetic operators have the same form — `sub!`, `mul!`, `div!`,
`mod!`, `pow!`:

```ruby
b = CArray.int32(2, 3).seq!
b.sub!(1)
#  => [ [ -1, 0, 1 ],
#       [  2, 3, 4 ] ]

c = CArray.int32(2, 3).seq!
c.mul!(2)
#  => [ [ 0, 2,  4 ],
#       [ 6, 8, 10 ] ]

d = CArray.int32(2, 3).seq!(0, 2)
d.div!(2)
#  => [ [ 0, 1, 2 ],
#       [ 3, 4, 5 ] ]
```

An in-place form keeps the array's existing data type: it never widens the
array to hold the result, so a float result assigned into an integer array is
truncated, just as Ruby's own `Integer` arithmetic would truncate it. Widening
is what the next section is about.

## Data type promotion

When the two sides of an operation have different element types, CArray picks a
result type that can hold both, and promotes the operands to it. The rule is
the usual numeric one: a floating-point operand carries the result to floating
point, a complex one to complex, and a wider integer takes a narrower one with
it.

```ruby
i = CA_INT([1, 2, 3])
f = CA_DOUBLE([0.5, 0.5, 0.5])

(i + f)                        #  => [ 1.5, 2.5, 3.5 ]
(i + f).data_type              #  => :float64      the float operand wins
```

A scalar counts the same way:

```ruby
(CA_INT([1, 2, 3]) / 2.0).data_type    #  => :float64
```

`CArray.result_type` answers the same question without doing the work, which
is useful when you want to know what an expression will land in:

```ruby
CArray.result_type(CA_INT8([1]), CA_INT32([1]))     #  => :int32
CArray.result_type(CA_INT([1]), CA_DOUBLE([1.0]))   #  => :float64
```

To land somewhere else, cast before the operation — `a.float64`, or
`CA_DOUBLE(a)` (see
[Creating arrays](01_creating_arrays.md)).

## Mathematical functions

Elementary functions are methods on the array. They return a new array of
results.

```ruby
CA_DOUBLE([0, 1, 4, 9]).sqrt
#  => [ 0.0, 1.0, 2.0, 3.0 ]

CA_DOUBLE([-2, 3, -4]).abs
#  => [ 2.0, 3.0, 4.0 ]
```

Rounding functions take a float array to whole-number floats:

```ruby
CA_DOUBLE([1.4, 2.5, -1.6, 3.7]).floor
#  => [ 1.0, 2.0, -2.0, 3.0 ]

CA_DOUBLE([1.4, 2.5, -1.6, 3.7]).ceil
#  => [ 2.0, 3.0, -1.0, 4.0 ]

CA_DOUBLE([1.4, 2.5, -1.6, 3.7]).round
#  => [ 1.0, 3.0, -2.0, 4.0 ]
```

For functions whose results are not round numbers, the output below is shown
rounded for readability:

```ruby
CA_DOUBLE([0, 1, 2]).exp
#  => [ 1.0, 2.7183, 7.3891 ]

CA_DOUBLE([1, Math::E, Math::E ** 2]).log
#  => [ 0.0, 1.0, 2.0 ]

CA_DOUBLE([0, Math::PI / 2, Math::PI]).sin
#  => [ 0.0, 1.0, 1.2246467991473532e-16 ]    shown in full, see below

CA_DOUBLE([0, Math::PI / 2, Math::PI]).cos
#  => [ 1.0, 6.123233995736766e-17, -1.0 ]
```

The last two are printed in full rather than rounded, because rounding them
would say something untrue. `Math::PI` is the nearest double to pi, not pi, so
what is taken here is the sine of a number very close to pi -- a tiny value
rather than zero. Reductions and comparisons will see that value, so an
equality test against `0.0` fails where a tolerance test succeeds.

Two-argument functions are methods too. `atan2` takes the `y` array as the
receiver and `x` as the argument; `hypot` gives the Euclidean length of the
two operands position by position:

```ruby
y = CA_DOUBLE([3.0, 4.0])
x = CA_DOUBLE([4.0, 3.0])

y.hypot(x)        #  => [ 5.0, 5.0 ]              sqrt(y*y + x*x)
y.atan2(x)        #  => [ 0.6435, 0.9273 ]        the angle, in radians
```

The usual set is available — `exp`, `log`, `log10`, `sqrt`, `sin`, `cos`, `tan`,
`asin`, `acos`, `atan`, `sinh`, `cosh`, `tanh`, `abs`, `floor`, `ceil`, `round`,
`atan2`, `hypot`, and more. Each has a `!` form that writes the result back into
the array, as the arithmetic operators do.

## Comparison

Comparison methods return a boolean array — `1` where the condition holds, `0`
where it does not. Use the named methods `eq`, `ne`, `lt`, `le`, `gt`, `ge`:

```ruby
c = CA_INT([1, 2, 3, 4, 5])

c.gt(3)      #  => [ 0, 0, 0, 1, 1 ]    greater than 3
c.le(2)      #  => [ 1, 1, 0, 0, 0 ]    less than or equal to 2
c.eq(3)      #  => [ 0, 0, 1, 0, 0 ]    equal to 3
c.ne(3)      #  => [ 1, 1, 0, 1, 1 ]    not equal to 3
c.lt(3)      #  => [ 1, 1, 0, 0, 0 ]    less than 3
c.ge(3)      #  => [ 0, 0, 1, 1, 1 ]    greater than or equal to 3
```

The operators `<`, `<=`, `>`, `>=` are also defined and behave the same way as
`lt`, `le`, `gt`, `ge`:

```ruby
c > 3        #  => [ 0, 0, 0, 1, 1 ]
c <= 2       #  => [ 1, 1, 0, 0, 0 ]
```

> **`==` is not an element-wise `eq`.** `a == b` answers one question about the
> two arrays taken whole — are they equal? — with a single `true` or `false`.
> The element-wise comparison is `a.eq(b)`, and `a.ne(b)` for `!=`. `==` is
> Ruby's own whole-object equality, and cannot be repurposed.
>
> ```ruby
> c = CA_INT([1, 2, 3, 4, 5])
>
> c == 3       #  => false             one boolean: "is c equal to 3?"
> c.eq(3)      #  => [ 0, 0, 1, 0, 0 ] element-wise result you wanted
> ```

The flip side is that `==` is exactly the tool for the question it answers:
"are these two whole arrays equal?" It returns `true` when the operands have the
same shape and every element matches, and `false` otherwise; `!=` is its
negation. Arrays of different data types compare unequal.

```ruby
CA_INT([1, 2, 3]) == CA_INT([1, 2, 3])   #  => true
CA_INT([1, 2, 3]) == CA_INT([1, 2, 9])   #  => false
CA_INT([1, 2, 3]) == CA_DOUBLE([1, 2, 3])   #  => false   different data type
```

Comparison between two arrays of the same shape is element by element:

```ruby
x = CA_INT([1, 5, 3, 7, 2])
y = CA_INT([4, 2, 3, 6, 8])

x.gt(y)      #  => [ 0, 1, 0, 1, 0 ]    x > y position by position
x.eq(y)      #  => [ 0, 0, 1, 0, 0 ]
```

## Boolean combinations

Boolean arrays combine with `&`, `|`, `^` (or the named `and`, `or`, `xor`):

```ruby
c.gt(1) & c.lt(5)      #  => [ 0, 1, 1, 1, 0 ]    both > 1 and < 5
c.gt(4) | c.lt(2)      #  => [ 1, 0, 0, 0, 1 ]    either > 4 or < 2
c.gt(1) ^ c.lt(4)      #  => [ 1, 0, 0, 1, 1 ]    one or the other, not both
```

The combinations chain, so you can build multi-condition tests directly:

```ruby
c.gt(1) & c.lt(5) & c.ne(3)
#  => [ 0, 1, 0, 1, 0 ]    > 1 and < 5 and not 3

(c.lt(2) | c.gt(4)) & c.ne(0)
#  => [ 1, 0, 0, 0, 1 ]    at the extremes, excluding 0
```

Boolean arrays are commonly used to index — see
[Indexing and slicing](02_indexing_and_slicing.md) — and to mask elements
(see [Masks](05_masks.md)).

## Arithmetic with a masked array

If one of the operands carries a mask (see [Masks](05_masks.md)), the result's
mask is set wherever any input was masked. The arithmetic itself is otherwise
unchanged:

```ruby
a = CArray.float64(4).seq!
a[1] = UNDEF
a
#  => [ 0.0, _, 2.0, 3.0 ]

a + 100
#  => [ 100.0, _, 102.0, 103.0 ]   the missing position stays missing

a.sqrt
#  => [ 0.0, _, 1.4142, 1.7321 ]
```

When both operands are arrays, the result is masked wherever either operand was
masked at that position. Missing-ness carries through the calculation — see
[Masks and missing values](05_masks.md) for the full story.

## Boolean arrays

A boolean array — one whose `data_type` is `:boolean` — is what comparisons
return, and what `&` / `|` / `^` combine. CArray prints `true` as `1` and
`false` as `0`, which makes the patterns easy to read. (This section is the
introduction; [The boolean data type](27_boolean_arrays.md) covers the type
in full, including its arithmetic behaviour and how masks interact with
`&` / `|`.)

```ruby
a = CA_INT([1, 2, 3, 4, 5])

b = a.gt(2)
b                       #  => [ 0, 0, 1, 1, 1 ]
b.data_type             #  => :boolean
b.class                 #  => CArray
```

You can also create one directly:

```ruby
CA_BOOLEAN([true, false, true])    #  => [ 1, 0, 1 ]

CArray.boolean(2, 3) { |i, j| (i + j).odd? }
#  => [ [ 0, 1, 0 ],
#       [ 1, 0, 1 ] ]
```

### Combining boolean arrays

`&` / `|` / `^` operate element-wise on two boolean arrays of the same shape.
They have named equivalents `and`, `or`, `xor`. A unary `~` (or `not`) flips
each bit.

```ruby
p = CA_BOOLEAN([true,  true,  false, false])
q = CA_BOOLEAN([true,  false, true,  false])

p & q                  #  => [ 1, 0, 0, 0 ]    AND
p | q                  #  => [ 1, 1, 1, 0 ]    OR
p ^ q                  #  => [ 0, 1, 1, 0 ]    XOR
~p                     #  => [ 0, 0, 1, 1 ]    NOT
p.not                  #  => [ 0, 0, 1, 1 ]    same thing, named form
```

### Asking about a boolean array

`all` returns `true` when every element is `true`; `any` returns `true` when
any element is. They take an optional `axis:` just like the reductions in
chapter 4.

```ruby
b = a.gt(2)             #  => [ 0, 0, 1, 1, 1 ]

b.all                   #  => false
b.any                   #  => true
a.gt(0).all             #  => true
a.gt(99).any            #  => false
```

For a 2-D array, `axis:` gives a result per row or per column:

```ruby
m = CArray.int32(2, 3).seq!
#  => [ [ 0, 1, 2 ],
#       [ 3, 4, 5 ] ]

m.gt(1).all(axis: 1)    #  => [ 0, 1 ]    is every entry in this row > 1?
m.gt(1).any(axis: 0)    #  => [ 1, 1, 1 ] does any entry in this column exceed 1?
```

`count(true)` and `count(false)` count how many elements are true or false.
Equivalent to summing — `count(true) == sum_of_1s` — but more readable.

```ruby
b.count(true)           #  => 3
b.count(false)          #  => 2

m.gt(1).count(true, axis: 1)
#  => [ 1, 3 ]    how many true per row
```

### Boolean indexing recap

The most common use of a boolean array is selecting elements (covered in
[Indexing and slicing](02_indexing_and_slicing.md)):

```ruby
a[a.gt(2)]              #  => [ 3, 4, 5 ]
a[a.gt(2)] = 0
a                       #  => [ 1, 2, 0, 0, 0 ]
```

### Float predicates that return booleans

A handful of methods test each element of a float array and produce a boolean
array. They are the natural way to find NaN / Inf / finite cells before
acting on them.

```ruby
x = CA_DOUBLE([1.0, 0.0/0.0, 1.0/0.0, -2.0, 3.0])
#  0.0/0.0 is NaN, 1.0/0.0 is Inf

x.is_nan                #  => [ 0, 1, 0, 0, 0 ]
x.is_inf                #  => [ 0, 0, 1, 0, 0 ]
x.is_finite             #  => [ 1, 0, 0, 1, 1 ]
x.is_invalid            #  => [ 0, 1, 1, 0, 0 ]    NaN or Inf
```

See [Masks and missing values](05_masks.md) for how `is_invalid` plugs into
the mask machinery (`x.mask_invalid`, `ca[:is_invalid] = UNDEF`).

## Method reference

A lookup table of every element-wise operator, function, and predicate
currently in CArray. All methods listed return a new array of the same
shape as the receiver (except where noted) and propagate the mask from
their inputs. Operator and named forms behave identically; use whichever
reads better.

Methods marked **!** also have an in-place bang form that writes the
result back into the receiver and keeps its data type — for example
`sqrt` / `sqrt!`, `add` / `add!`.

### Arithmetic operators

| Operator      | Named form        | **!** | Notes                                              |
|---------------|-------------------|-------|----------------------------------------------------|
| `a + b`       | `a.add(b)`        | ✓     | Addition                                           |
| `a - b`       | `a.sub(b)`        | ✓     | Subtraction                                        |
| `a * b`       | `a.mul(b)`        | ✓     | Multiplication                                     |
| `a / b`       | `a.div(b)`        | ✓     | Division. Integer division floors toward -inf, as Ruby's `Integer#/` does; float division is true division |
| `a % b`       | `a.mod(b)`        | ✓     | Modulo. The result carries the sign of the divisor, as Ruby's `%` does, and pairs with `/` above so that `(a / b) * b + a % b == a` for integers |
|               | `a.fmod(b)`       | ✓     | Truncated remainder — the sign of the dividend, as C's `fmod` and `%` do. Integers and floats both |
|               | `a.divmod(b)`     |       | `[quotient, remainder]`, the quotient floored. Returns a two-element Array, not a CArray |
| `a ** b`      | `a.pow(b)` or `a.power(b)` | ✓ | Exponent                                       |
|               | `a.copysign(b)`   | ✓     | Magnitude of `a` with sign of `b`                  |
|               | `a.nextafter(b)`  | ✓     | Next representable float from `a` toward `b`       |
|               | `a.logaddexp(b)`  | ✓     | `log(exp(a) + exp(b))`, numerically stable         |
|               | `a.pmax(b)`, `a.pmin(b)`         | ✓ | Pairwise (element-wise) max / min, **NaN-skip** (C99 `fmax` / `fmin`; if one operand is NaN the other wins). Alias: `fmax` / `fmin`. |
|               | `a.maximum(b)`, `a.minimum(b)`   | ✓ | Same but **NaN-propagate**: if either operand is NaN the result is NaN. |
|               | `a.fma(b, c)`     | ✓     | Fused multiply-add: `a * b + c`                    |
|               | `a.fms(b, c)`     | ✓     | Fused multiply-subtract: `a * b - c`               |

### Unary arithmetic

| Operator      | Named form    | **!** | Notes                                              |
|---------------|---------------|-------|----------------------------------------------------|
| `-a`          | `a.neg`       | ✓     | Unary minus                                        |
|               | `a.abs`       | ✓     | Absolute value (returns same data type)                |
|               | `a.abs_i`     | ✓     | Absolute value, keep the data type (for complex stays complex) |
|               | `a.abs2`      | ✓ (real only) | Squared magnitude: `x*x` for real, `re²+im²` for complex (no sqrt). f64 for complex, data type preserved for real |
|               | `a.arg`       | ✓     | Phase angle (`carg`): for real → 0 or π, for complex → argument. Returns f64 in the eager form. |
|               | `a.sign`      | ✓     | Sign: -1 / 0 / +1 for real (NaN-preserving on float), unit vector for complex, 0/1 for bool/uint |
|               | `a.square`    | ✓     | `a * a` (equal to `abs2` for real inputs)          |
|               | `a.rcp`       | ✓     | Reciprocal `1 / a`                                 |
|               | `a.rsqrt`     | ✓     | Reciprocal square root `1 / sqrt(a)`               |
|               | `a.rcp_mul(b)`| ✓     | `b / a` — multiply by reciprocal                   |
|               | `a.frac`      | ✓     | Fractional part (`a - trunc(a)`)                   |
|               | `a.zero`      | ✓     | Set every element to 0 (same shape and data type)      |
|               | `a.one`       | ✓     | Set every element to 1                             |

### Rounding (float → float)

| Method   | Notes                                                          |
|----------|----------------------------------------------------------------|
| `floor`  | Round down                                                     |
| `ceil`   | Round up                                                       |
| `round`  | Round to nearest, ties away from zero (`0.5 → 1`, `-0.5 → -1`) |
| `trunc`  | Round toward zero                                              |

Each has a bang form (`floor!`, `ceil!`, `round!`, `trunc!`).

### Exponential and logarithm

| Method   | Notes                                                          |
|----------|----------------------------------------------------------------|
| `exp`    | `e ** x`                                                       |
| `exp2`   | `2 ** x`                                                       |
| `exp10`  | `10 ** x`                                                      |
| `expm1`  | `exp(x) - 1`, accurate for small `x`                           |
| `log`    | Natural logarithm                                              |
| `log2`   | Base-2 logarithm                                               |
| `log10`  | Base-10 logarithm                                              |
| `logb`   | Unbiased exponent of `x` as a float (`log2(\|x\|)` rounded down) |
| `log1p`  | `log(1 + x)`, accurate for small `x`                           |
| `sqrt`   | Square root                                                    |

All also exist in bang form (`exp!`, `log!`, …).

### Trigonometric

| Method   | Notes                                                          |
|----------|----------------------------------------------------------------|
| `sin`, `cos`, `tan`             | Argument in radians                          |
| `asin`, `acos`, `atan`          | Inverse trigonometric                        |
| `sinh`, `cosh`, `tanh`          | Hyperbolic                                   |
| `asinh`, `acosh`, `atanh`       | Inverse hyperbolic                           |
| `y.atan2(x)`                    | Two-argument arctangent — angle of `(x, y)`  |
| `y.hypot(x)`                    | `sqrt(x*x + y*y)`, without overflow          |
| `rad`                           | Degrees → radians                            |
| `deg`                           | Radians → degrees                            |
| `rad_pi`                        | Normalise to `(-pi, pi]`                     |
| `rad_2pi`                       | Normalise to `[0, 2*pi)`                     |
| `deg_180`                       | Normalise to `(-180, 180]`                   |
| `deg_360`                       | Normalise to `[0, 360)`                      |

All have a bang form.

### Complex-array methods (`cmplx64`, `cmplx128`)

| Method   | Returns                                                        |
|----------|----------------------------------------------------------------|
| `conj`   | Complex conjugate                                              |
| `arg`    | Argument (phase angle, in radians) — `float64` array           |
| `abs`    | Modulus — `float64` array                                      |
| `abs_i`  | Modulus, kept as complex                                       |
| `abs2`   | Squared modulus `re² + im²` — `float64` array, no `sqrt`       |
| `imag_i` | Imaginary part, kept as complex (real part zero)               |

`conj`, `abs_i`, `imag_i` have bang forms.

`abs2` is the sqrt-free companion of `abs`. Use it when the magnitude is only
compared against a threshold (`abs2(z) > r²` is `abs(z) > r`) or when you would
square the modulus anyway; the answer comes out without going through
`sqrt` and back.

### Comparison operators (return a boolean array)

| Operator | Named form    | Notes                                                                                      |
|----------|---------------|--------------------------------------------------------------------------------------------|
| `a == b` | `a.eq(b)`     | `==` returns a single `true`/`false` over the pair; use `eq` for the element-wise result   |
| `a != b` | `a.ne(b)`     | Element-wise not-equal                                                                     |
| `a < b`  | `a.lt(b)`     | Less than                                                                                  |
| `a <= b` | `a.le(b)`     | Less than or equal                                                                         |
| `a > b`  | `a.gt(b)`     | Greater than                                                                               |
| `a >= b` | `a.ge(b)`     | Greater than or equal                                                                      |
|          | `a.feq(b)`    | Float equality with a small built-in tolerance — guards against the `0.1 + 0.2 != 0.3` trap |
|          | `a.is_close(b, tol)`  | `\|a - b\| <= tol` element-wise                                                      |
|          | `a.is_equiv(b, tol)`  | `is_close` with relative tolerance                                                 |

For object arrays:

| Method            | Notes                                                                         |
|-------------------|-------------------------------------------------------------------------------|
| `o.match(regexp)`      | Per-element `x =~ regexp` — the elements must respond to `=~` (typically a string array, or an object array of strings) |
| `o.is_kind_of(cls)`    | Per-element `x.kind_of?(cls)` — works on object arrays of heterogeneous classes |

### Boolean and bit operators

| Operator | Named form     | **!**          | Notes                                  |
|----------|----------------|----------------|----------------------------------------|
| `a & b`  | `a.and(b)`     | `and!`, `bit_and_i!` | Element-wise AND                 |
| `a \| b` | `a.or(b)`      | `or!`, `bit_or_i!`   | Element-wise OR                  |
| `a ^ b`  | `a.xor(b)`     | `xor!`, `bit_xor_i!` | Element-wise XOR                 |
| `a << b` | —              | `bit_lshift!`        | Bit shift left (integer arrays)  |
| `a >> b` | —              | `bit_rshift!`        | Bit shift right                  |
| `~a`     | `a.not`, `a.bit_neg` | `not!`, `bit_neg!` | Element-wise NOT / bitwise complement |

### Boolean reductions

| Method                 | Returns                                          |
|------------------------|--------------------------------------------------|
| `b.all`                | `true` iff every element is `true`               |
| `b.any`                | `true` iff any element is `true`                 |
| `b.count(true)`        | Number of `true` elements                        |
| `b.count(false)`       | Number of `false` elements                       |

All four accept `axis:` for per-row / per-column results (see chapter 4).

### Float predicates (return a boolean array)

| Method        | Notes                                          |
|---------------|------------------------------------------------|
| `is_nan`      | `true` where the cell is NaN                   |
| `is_inf`      | `true` where the cell is +Inf or -Inf          |
| `is_finite`   | `true` where the cell is a finite number       |
| `is_invalid`  | `true` where the cell is NaN or Inf            |
| `signbit`     | `true` where the IEEE sign bit is set (negative, including `-0.0`) |

