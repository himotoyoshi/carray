# gather_nd / put_nd

`gather_nd` reads elements (or sub-arrays) from arbitrary N-D positions,
and `put_nd` writes them back. They are the N-D extension of
`take_along_axis` / `put_along_axis`: instead of one index per fiber along
a single axis, you supply a full **coordinate tuple** into the leading
axes of the array.

```ruby
self.shape    = (D0, ..., D_{K-1}, *rest)
result.shape  = (*outer, *rest)
```

The first `K` axes of `self` are *consumed* by each coordinate; the
remaining `rest = self.shape[K..-1]` axes are *carried through*. When
`K == self.ndim` there is no `rest` and you gather scalars; when `K <
self.ndim` you gather whole sub-arrays.

Everything below works after `require "carray"`.

---

## 1. The two index forms

`gather_nd` accepts the coordinates in either of two equivalent forms.

### Stacked — a single CArray `(*outer, K)`

The last axis enumerates a `K`-dimensional coordinate; every leading axis
is an `outer` dimension carried into the result.

```ruby
a = CArray.float64(3, 4).seq

idx = CA_INT64([[0, 1], [1, 3], [2, 0]])   # shape (3, 2), K = 2, outer = (3,)
a.gather_nd(idx).to_a                       # => [1.0, 7.0, 8.0]
```

### Per-axis — an `Array` of K coordinate CArrays

Pass one coordinate array per consumed axis. The per-axis arrays are
broadcast together (element-wise) and treated as a coordinate tuple at
each position — the same shape you would write as NumPy-style `a[i, j]`
fancy indexing.

```ruby
i = CA_INT64([0, 1, 2])
j = CA_INT64([1, 3, 0])

a.gather_nd([i, j]).to_a                     # => [1.0, 7.0, 8.0]
```

The per-axis form is exactly the stacked form with the arrays welded onto
a new trailing axis:

```ruby
a.gather_nd([i, j]) == a.gather_nd(CArray.stack([i, j], axis: -1))   # => true
```

Reach for **per-axis** when your coordinates already live as separate
per-axis arrays (a common shape after `where` / `sort_index` /
`index(axis:)`); reach for **stacked** when they arrive pre-packed as one
`(..., K)` array. Neither copies the coordinate data on the way in.

---

## 2. Broadcasting the per-axis coordinates

The per-axis arrays are combined through `CArray.broadcast`, so size-1
axes stretch to the common `outer` shape. As everywhere in CArray, the
broadcast is **explicit** — the arrays must share `ndim`; cross-ndim
trailing-align is rejected. Insert a size-1 axis with `:_` to line them
up.

```ruby
a = CArray.float64(3, 4).seq

i = CA_INT64([[0], [2]])       # (2, 1)  — column
j = CA_INT64([[0, 1, 3]])      # (1, 3)  — row

g = a.gather_nd([i, j])        # outer broadcasts to (2, 3)
g.shape                        # => [2, 3]
g.to_a                         # => [[0.0, 1.0, 3.0], [8.0, 9.0, 11.0]]
```

An `Integer` scalar is allowed for an axis that is constant across the
gather; it broadcasts to the common shape:

```ruby
a.gather_nd([CA_INT64([0, 1, 2]), 2]).to_a   # column 2 of rows 0,1,2
# => [2.0, 6.0, 10.0]
```

If every entry is a scalar, the list is a single coordinate and the
result follows the degenerate stacked form (a 1-element `(1,)` array,
matching CArray's scalar model):

```ruby
a.gather_nd([2, 3]).to_a       # => [11.0]
```

> **Per-axis entries must be CArray or Integer.** Ruby `Array` literals
> are rejected on purpose — this is a copy-free gather path, and coercing
> arrays through `CA_INT64` on every call would defeat it. Wrap array
> literals yourself once: `a.gather_nd([CA_INT64([0, 2]), CA_INT64([1, 3])])`.

---

## 3. Sub-array gather (`K < ndim`)

When the coordinate consumes fewer axes than `self` has, the trailing
`rest` axes come along whole. Both index forms behave identically.

```ruby
a = CArray.float64(3, 4).seq

# stacked: pick rows 0 and 2 (K = 1, rest = (4,))
a.gather_nd(CA_INT64([[0], [2]])).to_a
# => [[0.0, 1.0, 2.0, 3.0], [8.0, 9.0, 10.0, 11.0]]

# per-axis: the same, one coordinate array
a.gather_nd([CA_INT64([0, 2])]).shape        # => [2, 4]
```

---

## 4. Writing back with `put_nd`

`put_nd` takes the same two index forms and scatters `values` (broadcast
to `outer + rest`) into the coordinates. Duplicate coordinates are
**last-write-wins**, matching `put_along_axis`.

```ruby
a = CArray.float64(3, 4).seq

a.put_nd([CA_INT64([0, 1]), CA_INT64([1, 2])], CA_DOUBLE([100, 200]))
a[0, 1]    # => 100.0
a[1, 2]    # => 200.0
```

`put_nd` is positional overwrite, not accumulation. For `+=`-style
folding onto duplicate coordinates, compute the flat addresses yourself
(`coord · stride` into `a.flatten`) and route to `scatter_add!` — see
[Scatter and bincount](ScatterAndBincount.md).

---

## 5. Coordinate rules

- **Type** — coordinates must be integer. Non-integer indices raise
  rather than truncate.
- **Negative indices** wrap per axis (`-1` == last), the standard CArray
  rule.
- **Out of range** on any axis raises `IndexError`.
- **`K`** (the last axis of the stacked form, or the length of the
  per-axis list) must satisfy `1 <= K <= self.ndim`.
- The result is a freshly materialised CArray. Gather duplicates are
  fine — the same value is simply picked more than once.

---

## 6. Which form to use

| your coordinates | reach for |
|---|---|
| already one packed `(..., K)` array | stacked: `gather_nd(idx)` |
| separate per-axis arrays (from `where`, `sort_index`, `index(axis:)`) | per-axis: `gather_nd([i, j])` |
| per-axis, one axis constant | per-axis with a scalar: `gather_nd([i, 2])` |
| a single fixed coordinate | `gather_nd([2, 3])` or `gather_nd(CA_INT64([2, 3]))` |

Both forms go through the same flat-address computation and a writable
`CAMapping` view of the flattened array, so they cost the same once the
coordinates are CArrays.
