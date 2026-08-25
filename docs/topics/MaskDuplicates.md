# `CArray#mask_duplicates`: mark duplicates, keep the shape

`mask_duplicates` does **not** squeeze an array down to its distinct values. It
returns a **shape-preserving copy** in which every cell that repeats an
earlier-seen value is **masked**, keeping only the first occurrence.

```ruby
a = CA_INT([10, 20, 20, 30, 10])

a.mask_duplicates
# => <CArray.int32(5): elem=5 mask=2 ...
#     [ 10, 20, _, 30, _ ]>     # the 2nd 20 and the 2nd 10 are masked
```

Think of it as **painting over repeats, not absorbing them out**. The
two ideas behind every example in this guide:

| | |
|---|---|
| **`mask_duplicates` paints, it does not squeeze** | the result has the same shape as the input; duplicates become masked cells |
| **`axis:` is the painting direction** | which way "earlier-seen" runs — `nil` over the whole array, `k` independently within each fiber along axis `k` |

Everything here works after `require "carray"`.

---

## 1. Why masking? Because it is what makes per-axis possible

This is the single idea worth internalizing. Consider deduplicating each
**row** of a matrix:

```ruby
a = CA_INT([[1, 2, 1],
            [1, 2, 3],
            [4, 2, 1]])
```

Row 0 has two distinct values (`1, 2`), rows 1 and 2 have three each. If
`mask_duplicates` *compressed*, row 0 would shrink to length 2 and the others to
length 3 — a **ragged** result that is not a rectangular array. There is
no shape to return.

Masking sidesteps the problem entirely. The shape never changes; each
row just gets its own repeats painted over:

```ruby
a.mask_duplicates(axis: 1)
# => [ [ 1, 2, _ ],     # row 0: the 2nd 1 is masked
#      [ 1, 2, 3 ],     # row 1: all distinct, nothing masked
#      [ 4, 2, 1 ] ]>   # row 2: all distinct
```

So per-axis `mask_duplicates` is not a special feature bolted on — it falls straight
out of the masking design. **Compression cannot express it; masking can.**

---

## 2. The three painting directions

Same matrix, three values of `axis:`.

```ruby
a = CA_INT([[1, 2, 1],
            [1, 2, 3],
            [4, 2, 1]])
```

### `axis: 1` — paint along each row

"Earlier-seen" runs left-to-right, independently per row.

```ruby
a.mask_duplicates(axis: 1)
# => [ [ 1, 2, _ ],
#      [ 1, 2, 3 ],
#      [ 4, 2, 1 ] ]>
```

### `axis: 0` — paint down each column

"Earlier-seen" runs top-to-bottom, independently per column.

```ruby
a.mask_duplicates(axis: 0)
# => [ [ 1, 2, 1 ],     # row 0 is always first-seen
#      [ _, _, 3 ],     # col 0: 2nd 1 masked; col 1: 2nd 2 masked
#      [ 4, _, _ ] ]>   # col 1: 3rd 2 masked; col 2: 2nd 1 masked
```

### `axis: nil` — paint over the whole array

"Earlier-seen" runs in flatten (row-major) order; the entire array is one
fiber.

```ruby
a.mask_duplicates
# => [ [ 1, 2, _ ],     # only the very first 1, 2, 3, 4 survive,
#      [ _, _, 3 ],     # everything else anywhere in the array
#      [ 4, _, _ ] ]>   # is a duplicate and gets masked
```

> Mental model: `axis: nil` is just "treat the whole array as a single
> fiber." It is the same operation as a per-axis paint, with one giant
> fiber instead of many small ones.

---

## 3. Recipes — what the shape-preserving result is good for

Because the positions are preserved, `mask_duplicates` composes with indexers,
counting, and parallel arrays in ways a compressed result never could.

### 3.1 First-occurrence flag (novelty detector)

The unmasked cells *are* the first-seen positions. Pull them out as a
boolean / value view:

```ruby
a = CA_INT([[1, 2, 1],
            [1, 2, 3],
            [4, 2, 1]])

a.mask_duplicates[:is_not_masked]      # the distinct values, first-seen order
# => [ 1, 2, 3, 4 ]
```

Along a time axis this answers "is this the first time this series has
seen this value?" — position-preserving, no loop.

### 3.2 Count distinct values per fiber

Mask the duplicates, then count what survives along the same axis:

```ruby
a.mask_duplicates(axis: 1).count_not_masked(axis: 1)   # distinct values in each row
# => [ 2, 3, 3 ]
```

### 3.3 Keep parallel arrays aligned

You have values and timestamps sampled together; you want to drop
repeated values but keep `times` aligned. Masking never shifts indices,
so the duplicate mask from one array applies directly to the other:

```ruby
values = CA_INT([10, 20, 20, 30, 10])
times  = CA_INT([ 1,  2,  3,  4,  5])

dup = values.mask_duplicates.is_masked   # => [ 0, 0, 1, 0, 1 ]  (boolean)
times[dup] = UNDEF            # mask times wherever values repeated
times
# => [ 1, 2, _, 4, _ ]   # masked at index 2 and 4, the repeated values
```

A compressed `mask_duplicates` would collapse `values` to length 3 and break its
correspondence with `times`.

### 3.4 The old 1-D compressed form (migration)

Pre-3.0 this method was named `uniq` and returned a 1-D entity of the
distinct values. That form is now one step away — select the survivors
and copy:

```ruby
a.mask_duplicates[:is_not_masked].copy
# => <CArray.int32(4) ... [ 1, 2, 3, 4 ]>
```

---

## 4. Comparison semantics

### Strict `==`; NaN is never equal to anything

Duplicate judging uses strict `==`. Because `NaN != NaN`, **NaN cells are
all kept** (none is a duplicate of another):

```ruby
f = CA_DOUBLE([1.0, Float::NAN, 2.0, Float::NAN, 1.0])

f.mask_duplicates
# => [ 1.0, NaN, 2.0, NaN, _ ]   # both NaNs kept; only the 2nd 1.0 masked
```

To treat NaN as "invalid and excluded," mask it first — masked cells do
not participate in judging (see below):

```ruby
f.mask_invalid.mask_duplicates
# => [ 1.0, _, 2.0, _, _ ]   # both NaNs masked out, 2nd 1.0 masked
```

### Masked input cells are passed through, and do not judge

A cell that is already masked on input stays masked and is **invisible**
to duplicate detection — it neither becomes a duplicate nor blocks a
later cell from being "first-seen":

```ruby
m = CA_INT([1, 2, 2, 3, 1])
m[1] = UNDEF                  # mask out the first 2

m.mask_duplicates
# => [ 1, _, 2, 3, _ ]
#         ^      ^
#         |      the 2nd value(2) is now the FIRST visible 2, so it is kept
#         masked input stays masked
```

---

## 5. Data types

`mask_duplicates` works for all data types and for both `axis:` forms.

```ruby
s = CA_OBJECT(["a", "b", "a", "c", "b"])
s.mask_duplicates
# => [ "a", "b", _, "c", _ ]
```

Numeric types use a fast `sort_addr` → gather → scan → scatter backend.
`CA_OBJECT` and `CA_FIXLEN` use a Ruby `Hash` per fiber (slower, but
identical semantics), dispatched through `map_slab` for the per-axis
form.

---

## 6. Summary

- `mask_duplicates` **masks** duplicates instead of removing them — the result has
  the same shape as the input.
- That choice is exactly what makes the **per-axis** form expressible:
  per-fiber distinct counts differ, so a compressed result would be
  ragged; a masked one stays rectangular.
- `axis:` chooses the **direction** "earlier-seen" runs: `nil` = the whole
  array as one fiber, `k` = each fiber along axis `k` independently.
- Shape preservation is the payoff: novelty flags, per-fiber distinct
  counts, and alignment with parallel arrays all come for free. Recover
  the old 1-D compressed form (pre-3.0 `uniq`) with
  `mask_duplicates[:is_not_masked].copy`.
