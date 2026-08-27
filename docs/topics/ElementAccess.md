# Per-cell access: the `elem_*` family

CArray's `[]` / `[]=` indexer is a general dispatcher — it recognises
Ranges, `nil`, boolean masks, Address-key `:%`, integer arrays, symbols,
and mixed multi-key forms, then routes to the appropriate view class or
store path. That flexibility has a small per-call cost: parsing the key,
building a view, and folding it back into the target.

When you are writing a **tight scalar loop** (a histogram bump, a
pair-wise swap, a per-cell increment, a scatter fixup), you don't need
any of that — you already have integer coordinates and one value. The
`elem_*` family is the specialised, always-scalar entry point for that
case. It lands at the same backend as `ca[i, j]` but skips the
front-end dispatcher and inlines the mask probe. Semantics match the
indexer; only the overhead differs.

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

## 1. Index form: flat or per-axis

Every `elem_*` method accepts `idx` in two shapes:

- **Integer** — a flat row-major address into `self`, in
  `0 ... self.elements`.
- **`Array<Integer>`** — one index per axis, length `self.ndim`.

```ruby
a = CA_INT32(3, 4).seq                # 0..11 row-major
a.elem_fetch(5)                       # => 5   (flat)
a.elem_fetch([1, 1])                  # => 5   (per-axis)
```

Out-of-range values raise `IndexError`. Negative indices are **not**
accepted (this is a hot path — the indexer's `-1 == last` sugar is not
performed). Convert to positive at the call site if you need it.

Prefer the flat form when you already have a flat address (`bincount`
output positions, `sort_index` outputs). Prefer the per-axis form when
your coordinates naturally live in axis-space (image `(y, x)`, a grid
`(i, j, k)`) — the parser inlines the `FIXNUM_P` fast path so an
`Array<Integer>` of small integers is nearly free.

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

## 3. When it pays off

The overhead the `elem_*` family removes is per-call, not per-element:

- one `TypedData_Get_Struct` instead of two,
- direct `RARRAY_CONST_PTR` + `FIXNUM_P` instead of `rb_ary_entry`
  + `NUM2SIZE`,
- inline mask probe (`ca->mask` NULL-check + entity fast path)
  instead of an `ca_update_mask` function call,
- for entity arrays, a direct pointer read/write instead of
  `ca_func[ARRAY].xfer_index` through the function-pointer table.

So the win shows up when **the same cell operation happens millions of
times in Ruby**, not when the operation itself is heavy. Two rough
guidelines:

1. If you are calling `ca[i, j]` (or `ca[i, j] = v`) inside a Ruby
   `while` / `each` / `times` loop with a large trip count, and each
   iteration touches one cell, `elem_*` is the right substitute.
2. If you can express the same computation as a vector operation
   (`self[addrs] = vals`, `scatter_add!(addrs, vals)`, `windows`,
   `blocks`, an axis-reduction), *that* is a bigger win than the
   `elem_*` swap. Reach for `elem_*` when the loop is genuinely scalar.

Both `scatter_*!` and `elem_*` bypass the general indexer, but they
solve different shapes:

| you have | reach for |
|---|---|
| **many** addresses and values at once, want vector dispatch | `self[addrs] = vals` or `scatter_*!(addrs, vals)` |
| **one** cell per iteration, in a Ruby loop | `elem_*` |

If you already have `addrs` and `vals` as CArrays, don't decompose them
into a Ruby loop over `elem_*` — that always loses to the vector form.

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

- **Empty array** — `elem_fetch` returns `nil` on `self.empty?`. The
  indexer would raise; `elem_fetch` is the tolerant form.
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

The whole family exists for one reason: when a scalar cell operation
sits inside a Ruby loop with a large trip count, cutting the per-call
Ruby → C overhead by a couple of hundred nanoseconds is what makes the
loop finish in seconds instead of minutes. When you can batch, batch;
when you can't, reach for `elem_*` instead of `[]`.

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
