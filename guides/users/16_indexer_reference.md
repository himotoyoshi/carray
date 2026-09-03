# Indexer reference

This page is the reference for `[]` and `[]=` on a CArray. It walks through every form the indexer accepts, what shape it gives back, and what class the result has. For a gentler introduction see [Indexing and slicing](02_indexing_and_slicing.md); for the underlying classifier wire format see `docs/topics/Indexer_decision_tree.md`.

**Every form of `[]` returns a view onto the original storage** — writing through it reaches back to the source. That property is the subject of [Views](06_views.md); this page just notes the class of view each form produces.

Most examples use this 3-by-4 array:

```ruby
a = CArray.int32(3, 4).seq!
#  => [ [ 0,  1,  2,  3 ],
#       [ 4,  5,  6,  7 ],
#       [ 8,  9, 10, 11 ] ]
```

---

## 1. One argument per axis

The general form takes one argument per axis. Each argument independently selects from its axis; the result drops the axes you gave an integer to and keeps the rest.

### 1.1 Integer — pick one position

A plain `Integer` selects a single index along that axis.

```ruby
a[1, 2]      #  => 6
a[0, 0]      #  => 0
a[2, 3]      #  => 11
```

Negative integers count from the end.

```ruby
a[-1, -1]    #  => 11    last element
a[-1, 0]     #  => 8     last row, first column
a[0, -1]     #  => 3     first row, last column
```

When every axis is given an integer, the call resolves to one element. The result is a plain Ruby object — `Integer`, `Float`, etc. — not a zero-dimensional array.

```ruby
a[1, 2].class                                   #  => Integer
CArray.float64(2, 2).seq![0, 1].class            #  => Float
```

* **Shape back:** scalar (axis dropped).
* **Class back:** the underlying Ruby type (`Integer`, `Float`, ...).

### 1.2 `nil` — keep the whole axis

`nil` in an axis position means "every index along this axis". This is how you take a row, a column, or a slab.

```ruby
a[1, nil]    #  => [ 4, 5, 6, 7 ]      second row
a[nil, 2]    #  => [ 2, 6, 10 ]        third column
a[nil, nil]  #  => the whole array, as a view
```

* **Shape back:** the axis is kept at full length.
* **Class back:** `CABlock`.

### 1.3 Range — a contiguous run

A `Range` selects a contiguous run. Both inclusive (`..`) and exclusive (`...`) ranges work; negative endpoints count from the end.

```ruby
a[nil, 1..2]      #  columns 1 and 2 of every row
#  => [ [ 1,  2 ],
#       [ 5,  6 ],
#       [ 9, 10 ] ]

a[0..1, nil]      #  rows 0 and 1
#  => [ [ 0, 1, 2, 3 ],
#       [ 4, 5, 6, 7 ] ]

a[0, 0...2]       #  => [ 0, 1 ]      exclusive: endpoint dropped
a[nil, 1..-1]     #  every column except the first
a[nil, -2..-1]    #  the last two columns
```

A degenerate exclusive range where `start == last` gives a zero-length axis (`{start, count = 0, step = 1}` in the classifier's terms). Negative endpoints are normalised by plain addition of the axis length before bounds-checking.

Endless and beginless ranges work too:

```ruby
a[0, 1..]         #  => [ 1, 2, 3 ]    from column 1 to the end
a[0, ..2]         #  => [ 0, 1, 2 ]    from the start through column 2
a[0, ..-2]        #  => [ 0, 1, 2 ]    from the start to the second-to-last
```

* **Shape back:** the axis is kept at the length of the range.
* **Class back:** `CABlock`.

### 1.4 `Enumerator::ArithmeticSequence` — a strided run

Ruby's `(start..stop).step(n)` produces an arithmetic sequence; CArray accepts it directly.

```ruby
v = CArray.int32(10).seq!           #  => [ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 ]
v[(0..9).step(2)]                  #  => [ 0, 2, 4, 6, 8 ]
v[(1..8).step(3)]                  #  => [ 1, 4, 7 ]
```

A `step` of zero is a `RuntimeError`.

* **Shape back:** the axis is kept at `(count, step)` length.
* **Class back:** `CABlock`.

### 1.5 The `[start, count, step]` array form

A Ruby `Array` in an axis position is shorthand for a strided run. The classifier accepts four shapes:

| form                  | meaning                                              |
|-----------------------|------------------------------------------------------|
| `[i]`                 | one element at `i` (kept as a length-1 axis)         |
| `[nil, step]`         | from index 0 with the given step                     |
| `[start, count]`      | `count` consecutive elements starting at `start`     |
| `[start, count, step]`| `count` elements starting at `start`, stepping by `step` |

```ruby
v = CArray.int32(10).seq!
v[[2]]                #  => [ 2 ]                length-1 axis (not a scalar)
v[[nil, 2]]           #  => [ 0, 2, 4, 6, 8 ]    every other element from 0
v[[3, 4]]             #  => [ 3, 4, 5, 6 ]       four elements starting at 3
v[[1, 3, 2]]          #  => [ 1, 3, 5 ]          three elements, step 2
```

Note that `[i]` keeps the axis (it is a one-cell block), while a bare integer `i` drops it (it is a scalar). This distinction matters for things like translating to NetCDF hyperslab notation.

A `step` of zero, or an `Array` of any length other than 1, 2, or 3, is an error.

* **Shape back:** the axis is kept at the length of the strided run.
* **Class back:** `CABlock`.

### 1.6 The rubber sigil — `:~` (or `false`)

`:~` (and the legacy `false`) is the **rubber sigil**: it stands for as many `nil` axes as it takes to fill the rest of the shape. Useful when you only care about a few axes at known positions.

```ruby
a[:~, 1]     #  => [ 1, 5, 9 ]        same as a[nil, 1]
a[1, :~]     #  => [ 4, 5, 6, 7 ]     same as a[1, nil]
a[false]     #  => the whole array (legacy form for a[])
```

In a 3-D array `:~` can expand to more than one axis:

```ruby
v = CArray.int32(2, 3, 4).seq!
v[1, :~].shape    #  => [3, 4]    :~ expands to two nils
v[:~, 0].shape    #  => [2, 3]    :~ expands to two nils
```

At most one `:~` may appear; using it lifts the strict arity check, so `argc` can be less than `ndim`. `argc > ndim + 1` is still an error.

---

## 2. Single-argument shortcuts on a multi-dimensional array

When you give *one* argument to a multi-dimensional array, the indexer treats it as addressing the *flattened* array. Three forms apply.

### 2.1 Single integer — flat address

```ruby
a[5]      #  => 5    the 5th element in row-major order
a[11]     #  => 11   the last element
```

Addresses count elements in row-major order; see [Vocabulary](08_vocabulary.md).

* **Shape back:** scalar.
* **Class back:** Ruby `Integer` / `Float` / ...

### 2.2 Single `nil` — flatten

```ruby
a[nil]   #  => [ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 ]
```

This is the flatten form. The result is a 1-D view onto the same storage.

* **Shape back:** 1-D, length `a.elements`.
* **Class back:** `CARefer`.

### 2.3 Single Range / ArithmeticSequence / Array — flat slice

```ruby
a[1..3]            #  => [ 1, 2, 3 ]    flat positions 1..3
a[(0..11).step(3)] #  => [ 0, 3, 6, 9 ] every third element in flat order
```

The triple `[start, count, step]` is computed by a recursive scan in flat (1-D) address space.

* **Shape back:** 1-D.
* **Class back:** `CABlock`.

---

## 3. Indexing with a CArray

A CArray of integers or booleans in an index position triggers a different form, depending on its data type and shape.

### 3.1 Boolean CArray of the same shape — `SELECT`

A boolean mask of matching `elements` picks out the cells where it is true, in row-major order, as a 1-D array.

```ruby
a[a.gt(5)]
#  => [ 6, 7, 8, 9, 10, 11 ]
```

This is the form built on top of comparisons (see [Element-wise operations](03_elementwise.md)) and is the canonical way to filter elements.

A boolean array of mismatched size is a `RuntimeError`.

* **Shape back:** 1-D, length = number of true cells.
* **Class back:** `CASelect`.

### 3.2 Integer CArray on a 1-D source — `GRID`

For a 1-D `b`, an integer CArray picks elements at the given positions:

```ruby
b = CA_INT([10, 20, 30, 40, 50])
b[CA_INT([0, 2, 4])]   #  => [ 10, 30, 50 ]
```

* **Shape back:** same shape as the index CArray.
* **Class back:** `CAGrid`.

### 3.3 Integer CArray on a multi-d source — `MAPPING`

When the source has `ndim > 1` and you pass a single integer CArray, it is treated as flat addresses into the source:

```ruby
a[CA_INT([0, 5, 11])]    #  => [ 0, 5, 11 ]     flat positions 0, 5, 11
a[CA_INT([[0, 1], [10, 11]])]
#  => [ [ 0,  1 ],
#       [ 10, 11 ] ]                            keeps the index shape
```

* **Shape back:** same shape as the index CArray.
* **Class back:** `CAGrid` when the index is 1-D; `CARefer` (a flat mapping view) when the index is itself multi-dimensional.

A CArray of any other data type (not boolean, not integer) is an `IndexError`.

### 3.4 Several integer CArrays — `GRID` (Cartesian)

Pass one integer CArray per axis to take the **Cartesian product** of the picks.

```ruby
a[CA_INT([0, 2]), CA_INT([1, 3])]
#  => [ [ 1, 3 ],
#       [ 9, 11 ] ]
```

You can mix with `nil`:

```ruby
a[CA_INT([0, 2]), nil]
#  => [ [ 0, 1,  2,  3 ],
#       [ 8, 9, 10, 11 ] ]
```

* **Shape back:** product of the index CArray sizes (or `nil` axis lengths).
* **Class back:** `CAGrid`.

---

## 4. Symbol keys — `:eq`, `:gt`, `:lt`, ...

A symbol in the first argument position is sugar for asking the array a question about itself and indexing by the answer:

```ruby
a[:method, arg]   # is exactly  a[a.method(arg)]
```

So `:eq` turns the indexer into a **condition matcher**, the same as building a boolean mask first and using the form in §3.1.

```ruby
c = CArray.int32(5).seq!    #  => [ 0, 1, 2, 3, 4 ]

c[:eq, 2]    #  => [ 2 ]
c[:gt, 2]    #  => [ 3, 4 ]
c[:lt, 3]    #  => [ 0, 1, 2 ]
c[:ne, 2]    #  => [ 0, 1, 3, 4 ]
c[:ge, 2]    #  => [ 2, 3, 4 ]
c[:le, 2]    #  => [ 0, 1, 2 ]
```

For floating arrays, `:is_invalid` picks every NaN and infinity:

```ruby
e = CA_DOUBLE([1.0, Float::NAN, 3.0, Float::INFINITY, 5.0])
e[:is_invalid]    #  => [ NaN, Infinity ]
```

The same keys work on `[]=`, where they replace cells that match the condition:

```ruby
d = CArray.int32(5).seq!
d[:gt, 2] = 0       #  => [ 0, 1, 2, 0, 0 ]
d[:eq, 0] = -1      #  => [ -1, 1, 2, -1, -1 ]
```

What it buys you is the middle of a chain. Selecting by a property of a value means naming that value twice, which a chain has no room for — so without the symbol key you have to break the chain, or reach for `then`:

```ruby
a = CA_DOUBLE([1.0, 0.0, -1.0, 4.0])
b = CA_DOUBLE([2.0, 0.0, 4.0, 0.0])
a / b                                  #  => [ 0.5, NaN, -0.25, Infinity ]

(a / b)[:is_finite]                    #  => [ 0.5, -0.25 ]

t = a / b; t[t.is_finite]              #  the same, having named it
(a / b).then { |t| t[t.is_finite] }    #  the same again
```

The `[]=` forms above buy the same thing: `d[:gt, 2] = 0` says once what `d[d.gt(2)] = 0` says twice, and the condition is about the very array being written.

There is no table of accepted keys — any method name works, because the form is the identity above. The ones worth knowing are the comparisons (`:eq`, `:ne`, `:gt`, `:ge`, `:lt`, `:le`) and the predicates (`:is_invalid`, `:is_finite`, `:is_nan`, `:is_masked`, `:is_not_masked`), plus any boolean-returning method you define yourself.

Read the identity both ways: `a[:fill, 0]` is `a[a.fill(0)]`, which empties `a` and then indexes it. Name a question, not a change.

See [Masks and missing values](05_masks.md) for the `[:eq, v] = UNDEF` mask-by-condition pattern, and for the return-form counterparts (`mask_eq`, `mask_where`, `mask_invalid`).

* **Shape back:** 1-D, length = number of matching cells.
* **Class back:** `CASelect`.

---

## 5. Repetition — `:%`

This sigil turns the indexer into a repetition operation rather than a selection.

`:%` in the first position turns the array into a `CARepeat` view of the given target shape. The source is replicated to fill the new axes.

```ruby
v = CA_INT([1, 2, 3])
v[:%, 2, 3].shape    #  => [3, 2, 3]
v[:%, 2, 3]
#  => [ [ [ 1, 1, 1 ],
#         [ 1, 1, 1 ] ],
#       [ [ 2, 2, 2 ],
#         [ 2, 2, 2 ] ],
#       [ [ 3, 3, 3 ],
#         [ 3, 3, 3 ] ] ]
```

* **Class back:** `CARepeat`.

---

## 6. Adding axes — `:_`

`:_` introduces a new size-1 axis at its position. Unlike every other indexer form, `:_` *adds* an axis rather than selecting from one.

```ruby
v = CA_INT([1, 2, 3])
v[:_, nil].shape    #  => [1, 3]    add a leading size-1 axis (a row)
v[nil, :_].shape    #  => [3, 1]    add a trailing size-1 axis (a column)

m = CArray.int32(2, 3).seq!
m[nil, :_, nil].shape   #  => [2, 1, 3]    new axis inserted between the existing axes
```

This is the canonical way to line up shapes for broadcasting; see [Broadcasting](07_broadcasting.md) for the full story.

* **Class back:** `CAStride` (a reshape view).

---

## 7. Writing through the indexer

Every form above can sit on the left of an assignment. The right-hand side is either a scalar (filling every selected cell) or an array of the matching shape (copied in cell by cell).

### 7.1 Fill with a scalar

```ruby
a = CArray.int32(3, 4).seq!

a[1, nil] = -1              #  fill the whole second row
a[nil, 0] =  0              #  zero the first column
a[0..1, 1..2] = 99          #  fill a 2x2 block
a[a.gt(5)] = 0              #  zero every cell greater than 5
a[:eq, 0] = -1              #  same effect through the predicate key
```

### 7.2 Copy from a matching-shape source

```ruby
a = CArray.int32(3, 4).seq!
a[nil, 0] = CA_INT([7, 8, 9])
a[0..1, 0..1] = CA_INT([[100, 200], [300, 400]])
```

You can copy from a slice of one array into a slice of another:

```ruby
src = CArray.int32(3, 4).seq!
dst = CArray.int32(3, 4)
dst[0..1, 1..2] = src[1..2, 0..1]
```

### 7.3 Whole-array assignment with `a[] = ...`

`[]` with no arguments addresses the array as a whole. This is the usual way to replace the contents in place without allocating a new entity. It is especially useful for writing a view of `a` back into `a` itself:

```ruby
a = CArray.int32(3, 4).seq!
a[] = 0                                     #  zero everything
a[] = CA_INT([[1, 2, 3, 4],
              [5, 6, 7, 8],
              [9,10,11,12]])                #  replace contents
```

See [Views](06_views.md) for the view-into-itself idiom — e.g. `a[] = a.flip(0)`, which reverses `a` in place without ever allocating a separate buffer.

### 7.4 Masking through `[]= UNDEF`

Assigning `UNDEF` through any of these forms masks the selected cells rather than overwriting their value:

```ruby
b = CArray.float64(5).seq!
b[b.lt(2)] = UNDEF       #  mask cells less than 2
b[:gt, 3]  = UNDEF       #  same idea through the predicate key
```

See [Masks and missing values](05_masks.md) for the full story.

---

## 8. Quick lookup

| Index form                                       | Region          | View class           |
|--------------------------------------------------|-----------------|----------------------|
| `a[]`                                            | ALL             | `CARefer`            |
| `a[i, j]` (all axes integer)                     | POINT           | scalar (Ruby object) |
| `a[i, nil]`, `a[nil, j]`, `a[i, 1..2]`, ...      | BLOCK           | `CABlock`            |
| `a[nil, nil]`                                    | BLOCK           | `CABlock`            |
| `a[i]` on multi-d                                | ADDRESS         | scalar               |
| `a[nil]` on multi-d                              | FLATTEN         | `CARefer`            |
| `a[Range]` on multi-d                            | ADDRESS_COMPLEX | `CABlock`            |
| `a[bool_carray]` (matching elements)             | SELECT          | `CASelect`           |
| `a[:eq, v]`, `a[:gt, v]`, ..., `a[:is_invalid]`  | SELECT          | `CASelect`           |
| `a[int_carray]` (1-D index)                      | GRID            | `CAGrid`             |
| `a[int_carray]` (multi-d index, flat mapping)    | MAPPING         | `CARefer`            |
| `a[int_carray, int_carray, ...]` (per-axis pick) | GRID            | `CAGrid`             |
| `a[:%, shape...]`                                | REPEAT          | `CARepeat`           |
| `a[..., :_, ...]`                                | (newaxis)       | `CAStride`           |
| `a[:~, ...]` or `a[false]`                       | (rubber)        | depends on the rest  |

For the wire-format detail behind this table — the exact payload each region carries, every error condition, and the recursive flat-address scan used by `ADDRESS_COMPLEX` — see `docs/topics/Indexer_decision_tree.md`.
