# Pitfalls

Behaviour that is by design but easy to trip over. Each entry says what happens, why, and what to write instead.

This page collects entries as they are found. Once it has enough of them it moves into `guides/users`.

---

## 1. `to_ca` is not a snapshot

Most operations that pick part of an array, or rearrange it, return a view: a slice, `reshape`, `transpose`, `sort`, boolean selection, an index array. A view is already a CArray, so `to_ca` returns the view itself. It does not copy anything, and later writes to the parent still show through it.

```ruby
a = CA_INT32([3, 1, 2])
v = a[0..1].to_ca   # still the view
a[0] = 0
v.to_a              #=> [0, 1]
```

**Instead:** use `copy` for an independent array. A lazy view is the exception: its `to_ca` evaluates the expression into a new array.

## 2. `sort` returns a view, not a sorted array

`a.sort` neither copies `a` nor reorders it. It returns a view (a CARemap) that reads `a` in sorted order. Ruby's `Array#sort` returns a new array, so it is easy to expect the same here. Because the result is a view, the next two entries apply to it: writing into it changes `a`, and it stops being sorted when `a` changes.

```ruby
a = CA_INT32([3, 1, 2])
s = a.sort          # CARemap
a.to_a              #=> [3, 1, 2]   a itself is not reordered
s.to_a              #=> [1, 2, 3]
```

**Instead:** use `sort_copy` for an independent sorted array, and `a[] = a.sort` to sort `a` in place (there is no `sort!`).

## 3. Writing into a view writes into the parent

Views are writable by default, including the ones NumPy returns as copies (`sort`, boolean selection, index arrays). Writing into one changes the parent.

```ruby
a = CA_INT32([3, 1, 2])
a.sort[0] = 9
a.to_a              #=> [3, 9, 2]

b = CA_INT32([3, -1, 2])
b[b > 0][0] = 0
b.to_a              #=> [0, -1, 2]

c = CA_INT32([1, 2])
t = c.tile(2)
t[2] = 9            # the third cell is c[0] again
c.to_a              #=> [9, 2]
```

**Instead:** `copy` first when you want to change the result without touching the source.

## 4. A view chosen by values keeps only the positions

`sort` and boolean selection (`a[a > 0]`) look at the values once, when the view is made, and keep only the positions they picked: the order of the sort, the list of selected cells. They do not keep the condition. The values are read from the parent each time, so once the parent changes, the view is no longer sorted, and no longer holds only the selected values.

```ruby
a = CA_INT32([3, 1, 2])
s = a.sort          # CARemap, [1, 2, 3]
a[0] = 0
s.to_a              #=> [1, 2, 0]

b = CA_INT32([3, -1, 2])
t = b[b > 0]        # CASelect, [3, 2]
b[0] = -5
t.to_a              #=> [-5, 2]
```

The same happens when the change comes through the view itself (`s[-1] = 0`, see §3). A sorted view means "the cells in the order they had when it was sorted", not "always in ascending order".

**Instead:** take a snapshot with `copy` if the parent can change while you still use the result: `a.sort.copy`, `b[b > 0].copy`.

## 5. Writing through a type-converting view converts back to the parent's type

`as_type(:float64)` on an integer array returns a view that reads the integers as floats. Writing into the view writes into the integer array, so each value is converted back to the integer type: the fraction is dropped (toward zero), and a value out of range raises `RangeError`. The view then shows the converted value, not the one you wrote. `CArray.wrap_readonly(a, :float64)` and `CArray.wrap_writable(a, :float64)` return the same kind of view. `wrap_readonly` does not make the result read-only: the name says that you intend only to read it.

```ruby
a = CA_INT32([1, 2, 3])
f = a.as_type(:float64)   # a view of a
f[0] = 5.7
f[1] = -5.7
a.to_a                    #=> [5, -5, 3]
f.to_a                    #=> [5.0, -5.0, 3.0]
```

**Instead:** use `to_type(:float64)` for a new float array when you want to keep the fractions.

## 6. A Ruby Array index is `[start, count, step]`, not a list of positions

In NumPy and Numo, `a[[4, 1, 3]]` picks cells 4, 1 and 3. In CArray a Ruby Array key is a block: start, count, and an optional step.

```ruby
a = CArray.int32(6).seq
a[[1, 3]].to_a              #=> [1, 2, 3]   start 1, count 3
a[[4, 1, 3]].to_a           #=> [4]         start 4, count 1, step 3
a[CA_INT64([4, 1, 3])].to_a #=> [4, 1, 3]   a list of positions
```

**Instead:** pass the positions as an integer CArray (`CA_INT64([...])`). See [NumPy and CArray](NumPyEquivalents.md) and the [indexer decision tree](Indexer_decision_tree.md).

## 7. `==` compares whole arrays; `eq` compares cells

`==` answers whether two whole arrays are equal, so it returns `true` or `false`, and an array is never `==` to a number. The per-cell comparison is `eq`.

```ruby
CA_INT32([1, 2]) == CA_INT32([1, 3])          #=> false
CA_INT32([1, 2]) == 1                         #=> false
CA_INT32([1, 2]).eq(CA_INT32([1, 3])).to_a    #=> [true, false]
CA_INT32([1, 2]).eq(1).to_a                   #=> [true, false]
```

## 8. Multiple assignment does not unpack a CArray

CArray does not define `to_ary`, so Ruby does not unpack it on the right of a multiple assignment. (Defining it would make Ruby unpack arrays in places where nobody asked for it.) `Array()` and the splat go through `to_a` and do work.

```ruby
x, y = CA_INT32([1, 2])    # x is the whole CArray, y is nil
x, y = *CA_INT32([1, 2])   # x == 1, y == 2
Array(CA_INT32([1, 2]))    #=> [1, 2]
```

## 9. Integer arithmetic stays in the integer type

The result keeps the integer type of the array: integer division rounds down, as Ruby's `Integer#/` does, and values out of range wrap around, as in C.

```ruby
(CA_INT32([7, -7]) / 2).to_a #=> [3, -4]
(CA_INT32([7]) / 2.0).to_a   #=> [3.5]
(CA_INT8([100]) + 100).to_a  #=> [-56]
```

**Instead:** convert first (`to_type(:float64)`, or a wider integer type) when the result needs more range or a fraction.

## 10. Arithmetic picks the result type by the types, not by the values

When the two sides of an operator have different types, the result type comes from a fixed rule over the two types. The values are not looked at, so the result can lose what one side held.

- An integer with `float32` gives `float32`, for `int32` and `int64` too. Integers above 2²⁴ lose their low digits.
- A signed integer with an unsigned one gives the unsigned type, so a negative value wraps.
- A `float32` array with a Ruby Float stays `float32`.

```ruby
(CA_INT32([16777217]) + CA_FLOAT32([0])).to_a   #=> [16777216.0]
(CA_INT8([-2]) + CA_UINT8([1])).to_a            #=> [255]   uint8
(CA_FLOAT32([1]) + 0.1).to_a                    #=> [1.100000023841858]
```

Storing has the same character: a Float stored into an integer array loses its fraction (toward zero), as through the views of §5.

```ruby
a = CA_INT32([1, 2])
a[0] = 1.7
a.to_a                                          #=> [1, 2]
```

Comparisons are the exception. `eq`, `lt` and the other comparisons, and `promote_list` and `CArray.stack`, meet at a type that holds both sides, so `CA_INT8([-1]).lt(CA_UINT8([1]))` is `true`.

**Instead:** convert one side first to a type that holds both: `to_type(:float64)`, or a wider signed type such as `:int16`.

## 11. A CScalar is a scalar, not a one-element array

`CA_INT64(5)` without brackets returns a CScalar. In arithmetic a CScalar counts as a scalar, like a Ruby number: if it is of the same kind as the array beside it (both integers, or both floats), it takes the array's type. A one-element array is an array, and the rule of §10 applies to it.

```ruby
(CA_INT8([1, 2]) + CA_INT64(100)).data_type     #=> :int8
(CA_INT8([1, 2]) + CA_INT64([100])).data_type   #=> :int64
```

A CScalar of a different kind keeps its own type, so `CA_INT8([1]) + CA_FLOAT32(0.5)` is `float32`, while `CA_INT8([1]) + 0.5` is `float64` (a Ruby Float is a `float64`). Two CScalars follow the rule for arrays.

**Instead:** to widen the result, convert the array (`to_type`), or pass a one-element array.

## 12. A lazy view is read-only

```ruby
l = CArray.int32(3).seq.lazy
l[0] = 5    # RuntimeError: []=: can not modify read-only array
```

Write into the array the expression reads from, or evaluate the lazy view (`to_ca`) and write into the result. See [Lazy](Lazy.md) for the other differences (per-cell `[]` cost, MemoryView export).
