# Per-cell access: the `elem_*` family

When you hold **the coordinates of one cell** — `(y, x)` of a pixel,
`(i, j, k)` of a grid point — the `elem_*` family is the fastest way to
read or write that cell. You pass the per-axis index as it is; there is
no need to turn it into a flat address first.

`ca[i, j]` reaches the same cell with the same result, but `[]` / `[]=`
is a general dispatcher: it has to recognise Ranges, `nil`, boolean
masks, integer arrays, symbols and mixed keys before it can find out
that the key names one cell. `elem_*` knows that from the start, and
on a 2-D int32 array a call costs roughly half of `ca[i, j]` (a third
for `elem_incr` against `ca[i, j] += 1`, and much less than that for
`elem_masked?` against `ca.mask[i, j]`).

| method | equivalent to | mutates |
|---|---|---|
| `elem_fetch(idx)` | `ca[*idx]` (one cell) | no |
| `elem_store(idx, v)` | `ca[*idx] = v` | yes |
| `elem_swap(i, j)` | `t = ca[*i]; ca[*i] = ca[*j]; ca[*j] = t` | yes |
| `elem_copy(src, dst)` | `ca[*dst] = ca[*src]` | yes |
| `elem_incr(idx)` | `ca[*idx] += 1` (numeric) | yes |
| `elem_decr(idx)` | `ca[*idx] -= 1` (numeric) | yes |
| `elem_min(idx, v)` | `ca[*idx] = [ca[*idx], v].min` | yes |
| `elem_max(idx, v)` | `ca[*idx] = [ca[*idx], v].max` | yes |
| `elem_masked?(idx)` | `ca.mask[*idx] == 1` | no |
| `elem_mask(idx)` | `ca[*idx] = UNDEF` | yes |
| `elem_unmask(idx)` | clears mask bit, keeps data | yes |

Everything below works after `require "carray"`.

---

## 1. Index form: per-axis or flat

Every `elem_*` method accepts `idx` in two shapes:

- **`Array<Integer>`** — one index per axis, length `self.ndim`. This is
  the form the family is built around: the coordinates you already have.
- **Integer** — a flat row-major address into `self`, in
  `0 ... self.elements`.

```ruby
a = CArray.int32(3, 4).seq            # 0..11 row-major
a.elem_fetch([1, 1])                  # => 5   (per-axis)
a.elem_fetch(5)                       # => 5   (flat)
```

A negative index counts from the end, as it does for `[]`. Out-of-range
values raise `IndexError`, and so do an index that is not an Integer
(`1.5`) and a per-axis Array whose length is not `self.ndim`.

The flat form is there for the case where an address is what you hold
(a position out of `sort_addr`, say). When you hold per-axis
coordinates, pass them as they are rather than converting them with
`index2addr` first.

---

## 2. Semantics — identical to `[]`

The `elem_*` methods are not a different contract; they are the same
contract applied to exactly one cell.

- **Cast** — `elem_store` and `elem_min` / `elem_max` cast the value to
  `self.data_type` before writing, just like the indexer.
- **Mask** — `elem_fetch` returns `UNDEF` for a masked cell; `elem_store`
  clears the mask bit unless the value passed is `UNDEF` (in which case
  the cell is masked); `elem_incr` / `_decr` / `_min` / `_max` skip
  masked cells (they leave data and mask untouched).
- **NaN** — `elem_min` / `elem_max` on float types follow the `fmin` /
  `fmax` rule (NaN is treated as missing: `min(NaN, v) == v`,
  `min(x, NaN) == x`). All other arithmetic follows plain C (NaN
  propagates through `_incr` / `_decr` naturally — they touch integer
  types most of the time).

There is nothing in `[i, j] = v` that is impossible with
`elem_store([i, j], v)`, and nothing the reverse. The choice is
about **cost per call**.

---

## 3. When to use it

The deciding question is **what you hold**:

| you hold | reach for |
|---|---|
| the per-axis index (or the address) of **one** cell | `elem_*` |
| **many** addresses and values at once, as CArrays | `self[addrs] = vals` or `scatter_*!(addrs, vals)` |
| a computation over a whole axis or region | an axis reduction, `windows`, `blocks`, a vector operation |

`elem_*` saves cost per call, not per element, so the saving matters
when one cell operation is repeated many times from Ruby — typically
because the loop has to stay in Ruby (input arrives one sample at a
time, each step depends on the last, the loop branches or breaks).

If you can express the same computation as a vector operation, that is
a larger win than switching `[]` for `elem_*`. And if you already have
the addresses and values as CArrays, don't take them apart into a Ruby
loop over `elem_*` — the vector form always wins. Per-axis index
arrays become addresses through `index2addr` (§7).

---

## 4. Patterns

### 4.1 Histogram bump in a Ruby loop

When you are already inside a Ruby loop for other reasons (e.g. streaming
raw bytes off a socket) and want to bump a counter cell:

```ruby
hist = CA_INT64(256).fill(0)
stream.each_byte do |b|
  hist.elem_incr(b)
end
```

If the loop only serves to bump the histogram, materialise the labels
first and let `bincount` or `scatter_add!` do the vectored write —
they will beat any Ruby loop.

### 4.2 In-place swap during a hand-rolled sort

Any comparison-based reorder you write in Ruby (partial sort, custom
tie-breaking, permutation apply) needs a pairwise swap:

```ruby
# Fisher–Yates shuffle over an existing 1-D array
n = a.elements
(n - 1).downto(1) do |i|
  j = rand(i + 1)
  a.elem_swap(i, j) if i != j
end
```

`ca[i], ca[j] = ca[j], ca[i]` works but allocates a two-element temporary
array on every iteration; `elem_swap` avoids it and handles mask states
in one shot.

### 4.3 Pair-wise copy for permutation apply

Applying a permutation you have computed (in Ruby, one entry at a time)
to a scratch buffer:

```ruby
dst.elements.times do |k|
  dst.elem_copy(perm[k], k)   # dst[k] = src[perm[k]]   — same array
end
```

Again, if `perm` and `src` are both CArrays, `dst[] = src[perm]` is the
vector form and is preferable. Use the `elem_copy` form only when the
copy is embedded in a larger scalar decision that stays in Ruby.

### 4.4 Per-cell scoring with a running max

Sample-by-sample decoding where each sample carries `(index, score)`
and you want to keep the best per cell:

```ruby
best = CA_FLOAT32(k).fill(-Float::INFINITY)
stream.each do |index, score|
  best.elem_max(index, score)
end
```

This is the streaming counterpart to `scatter_max!(indices, scores)`.
Use the scatter form once you can batch; use `elem_max` when the
loop must stay scalar.

### 4.5 Masking one cell at a time

To poke a hole in an existing array without going through the mask
view:

```ruby
img.elem_mask([y, x])          # img[y, x] = UNDEF
img.elem_unmask([y, x])        # data preserved, mask cleared
img.elem_masked?([y, x])       # => true / false
```

Equivalent to indexer forms but cheaper when done inside a
`bad_pixels.each { |y, x| … }` loop.

### 4.6 Watermark / high-score cells

Track the maximum value ever seen at each cell as observations stream
in:

```ruby
watermark = CA_FLOAT64(*shape).fill(-Float::INFINITY)
loop do
  y, x, v = next_observation
  break unless v
  watermark.elem_max([y, x], v)
end
```

Ruby-level flow control (`break` on end-of-stream, occasional
`next` on invalid samples, logging) is why the loop stays scalar —
otherwise a vectored `scatter_max!` would be preferable.

### 4.7 Pop-and-push into a resident buffer

Where a fixed-size buffer models a moving window and each step
removes the oldest and adds a new sample:

```ruby
buf.elem_copy(1, 0)            # shift-left one cell (single hole)
buf.elem_store(-1, new_val)    # write the new sample at the tail
```

For a full ring buffer, an integer `head` index and `elem_store(head, v)`
is the direct spelling.

---

## 5. Semantics vs. `[]`: the small print

A few edge cases where `elem_*` behaves identically but the wording
differs slightly from the indexer path:

- **Empty array** — `elem_fetch` raises `IndexError` on an empty array,
  as the indexer does: no index names a cell.
- **Object arrays** — `elem_fetch` / `elem_store` on `CA_OBJECT` handle
  arbitrary Ruby values, same as the indexer. `elem_incr` / `_decr`
  / `_min` / `_max` require a numeric data type (raise
  `CArray::DataTypeError` on object / fixlen / boolean).
- **Views** — `elem_*` works on any CArray including views (CABlock,
  CARefer, CAStride, …). Entity arrays get the direct-pointer fast
  path; views go through the view's own `xfer_index`. There is nothing
  to opt in to.
- **Mask allocation** — `elem_mask(idx)` allocates the mask array
  lazily if it doesn't exist yet, matching `ca[idx] = UNDEF`.

---

## 6. Quick reference

```
              read      write      arithmetic  mask
  ------------------------------------------------------
  elem_fetch   ✓
  elem_store             ✓ (or mask if UNDEF)
  elem_swap              ✓  (both cells + mask)
  elem_copy              ✓  (from cell to cell)
  elem_incr              ✓          ✓  (+= 1)     skips masked
  elem_decr              ✓          ✓  (-= 1)     skips masked
  elem_min               ✓          ✓  (fmin)     skips masked
  elem_max               ✓          ✓  (fmax)     skips masked
  elem_masked?  ✓                              ✓
  elem_mask                                    ✓  (set)
  elem_unmask                                  ✓  (clear)
```

Use `elem_*` when you hold the coordinates of one cell and the loop
stays in Ruby. When you can batch, batch.

## 7. Coordinate ↔ address primitives

`scatter_*!` takes a flat address array.  When your coordinates are
per-axis indices, convert them with the vectorized primitives
**`addr2index` / `index2addr`**.  Both come in an instance form (uses
`self.shape`) and a class form (`shape:` kwarg, no receiver needed).

```ruby
h, w = 20, 60
world = CArray.boolean(h, w) { false }

# per-axis indices → flat addresses
is = CA_INT32([1, 2, 3, 3, 3])
js = CA_INT32([1, 2, 0, 1, 2])
addrs = CArray.index2addr(is, js, shape: [h, w])
world.scatter_replace!(addrs, true)   # boolean self + true scalar

# flat addresses → per-axis indices (inverse)
i, j = CArray.addr2index(addrs, shape: [h, w])
# i.to_a == [1, 2, 3, 3, 3]
# j.to_a == [1, 2, 0, 1, 2]
```

Note that `scatter_replace!` (unlike the arithmetic `scatter_*!`
family) accepts a boolean `self` and the scalars `true` / `false` —
assignment does not need to widen the target.

Contract:

| input                        | `addr2index`                          | `index2addr`                          |
|------------------------------|---------------------------------------|---------------------------------------|
| all-scalar                   | `Array<Integer>` of length `ndim`     | `Integer`                             |
| any CArray                   | `Array<CArray>` (same shape as input) | `CArray` (shape from first non-scalar arg) |
| masked cells                 | mask propagates to every axis output  | mask propagates from any input        |
| out-of-range                 | `ArgumentError`                       | `IndexError`                          |
| shape mismatch between args  | —                                     | `ArgumentError` (loud, no broadcasting) |

`i, j = ca.addr2index(x)` unpacks uniformly for scalar and vector `x`,
so callers written for one shape work for the other with no change.
