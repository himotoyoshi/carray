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

## 2. A view chosen by values keeps only the positions

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

## 4. A Ruby Array index is `[start, count, step]`, not a list of positions

In NumPy and Numo, `a[[4, 1, 3]]` picks cells 4, 1 and 3. In CArray a Ruby Array key is a block: start, count, and an optional step.

```ruby
a = CArray.int32(6).seq
a[[1, 3]].to_a              #=> [1, 2, 3]   start 1, count 3
a[[4, 1, 3]].to_a           #=> [4]         start 4, count 1, step 3
a[CA_INT64([4, 1, 3])].to_a #=> [4, 1, 3]   a list of positions
```

**Instead:** pass the positions as an integer CArray (`CA_INT64([...])`). See [NumPy and CArray](NumPyEquivalents.md) and the [indexer decision tree](Indexer_decision_tree.md).

## 5. `==` compares whole arrays; `eq` compares cells

`==` answers whether two whole arrays are equal, so it returns `true` or `false`, and an array is never `==` to a number. The per-cell comparison is `eq`.

```ruby
CA_INT32([1, 2]) == CA_INT32([1, 3])          #=> false
CA_INT32([1, 2]) == 1                         #=> false
CA_INT32([1, 2]).eq(CA_INT32([1, 3])).to_a    #=> [true, false]
CA_INT32([1, 2]).eq(1).to_a                   #=> [true, false]
```

## 6. Multiple assignment does not unpack a CArray

CArray does not define `to_ary`, so Ruby does not unpack it on the right of a multiple assignment. (Defining it would make Ruby unpack arrays in places where nobody asked for it.) `Array()` and the splat go through `to_a` and do work.

```ruby
x, y = CA_INT32([1, 2])    # x is the whole CArray, y is nil
x, y = *CA_INT32([1, 2])   # x == 1, y == 2
Array(CA_INT32([1, 2]))    #=> [1, 2]
```

## 7. Integer arithmetic stays in the integer type

The result keeps the integer type of the array, as in C: integer division truncates and values out of range wrap around.

```ruby
(CA_INT32([7]) / 2).to_a     #=> [3]
(CA_INT32([7]) / 2.0).to_a   #=> [3.5]
(CA_INT8([100]) + 100).to_a  #=> [-56]
```

**Instead:** convert first (`to_type(:float64)`, or a wider integer type) when the result needs more range or a fraction.

## 8. A lazy view is read-only

```ruby
l = CArray.int32(3).seq.lazy
l[0] = 5    # RuntimeError: []=: can not modify read-only array
```

Write into the array the expression reads from, or evaluate the lazy view (`to_ca`) and write into the result. See [Lazy](Lazy.md) for the other differences (per-cell `[]` cost, MemoryView export).
