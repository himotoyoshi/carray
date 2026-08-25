# Linear interpolation in CArray: `linear_section` and `linear_fetch`

`linear_section` and `linear_fetch` are a complementary pair built around
one idea — the **fractional index**. A value's fractional index says
*where between two array positions it lies*: index `2.5` means "halfway
between element 2 and element 3".

| method | maps | answers |
|---|---|---|
| `CArray#linear_section(value)` | **value → fractional index** | "at what (fractional) position does `value` sit in this monotonic array?" |
| `CArray#linear_fetch(index)` | **fractional index → value** | "what value lives at this fractional position?" |

They are inverses of one another:

```ruby
y = CA_DOUBLE([0.0, 1.0, 3.0, 6.0, 10.0])

f = y.linear_section(4.0)   # => 2.333...   (4.0 sits 1/3 of the way from y[2]=3 to y[3]=6)
y.linear_fetch(f)           # => 4.0         (back again)
```

Everything in this guide works after `require "carray"`.

---

## 1. Why a fractional index? The canonical use: interpolate y at arbitrary x

The pair shines when you have two arrays sampled on the **same grid** —
an independent variable `x` and a dependent variable `y` — and you want
`y` at an `x` that falls between sample points. You do it in two steps:

1. `x.linear_section(x_query)` — find the fractional index of `x_query`
   along the `x` array.
2. `y.linear_fetch(that_index)` — read `y` at the same fractional index.

```ruby
xs = CA_DOUBLE([10.0, 20.0, 30.0, 40.0, 50.0])   # the grid (must be monotonic)
ys = CA_DOUBLE([ 1.0,  4.0,  9.0, 16.0, 25.0])   # values on that grid

frac = xs.linear_section(35.0)   # => 2.5   (35 is halfway between xs[2]=30 and xs[3]=40)
ys.linear_fetch(frac)            # => 12.5  (halfway between ys[2]=9 and ys[3]=16)
```

This is ordinary piecewise-linear interpolation, decomposed into a
**search** (`linear_section`) and a **gather** (`linear_fetch`). Keeping
them separate is what lets each one vectorize over a whole array of
queries and over array axes (sections 4–5).

> The grid array passed to `linear_section` must be monotonic (ascending
> *or* descending — both work). The interpolation is undefined on
> non-monotonic data; no error is raised, you simply get the bracket the
> search happens to land on.

---

## 2. `linear_section` — value to fractional index

```ruby
y = CA_DOUBLE([0.0, 1.0, 3.0, 6.0, 10.0])

y.linear_section(0.0)    # => 0.0    (exactly at index 0)
y.linear_section(3.0)    # => 2.0    (exactly at index 2)
y.linear_section(4.0)    # => 2.333...
y.linear_section(10.0)   # => 4.0    (exactly at the last index)
```

Descending grids work the same way:

```ruby
d = CA_DOUBLE([10.0, 6.0, 3.0, 1.0, 0.0])
d.linear_section(4.0)    # => 1.666...  (between d[1]=6 and d[2]=3)
```

### Two search methods: `:binary` (default) vs `:linear`

```ruby
y.linear_section(4.0, method: :binary)   # default
y.linear_section(4.0, method: :linear)
```

The two methods compute the **same function** — they differ only in cost.
Pick by the grid:

| | `:binary` (default) | `:linear` |
|---|---|---|
| algorithm | binary search, `O(log n)`, with an `O(1)` fast path for equispaced grids | sequential scan, `O(n)` |
| best when | the grid is large and/or evenly spaced | the grid is short, or you prefer a simple scan |

Both agree on every input, including out of range. A query that falls
outside the grid has **no fractional index** — `linear_section` does not
extrapolate — so it returns `nil` (a `Float64` `NaN` in array form):

```ruby
y = CA_DOUBLE([0.0, 1.0, 3.0, 6.0, 10.0])

# inside the range: identical answers
y.linear_section(4.0, method: :binary)    # => 2.333...
y.linear_section(4.0, method: :linear)     # => 2.333...

# outside the range: both report "no answer"
y.linear_section(-5.0, method: :binary)   # => nil
y.linear_section(50.0, method: :binary)   # => nil
y.linear_section(-5.0, method: :linear)   # => nil
y.linear_section(50.0, method: :linear)   # => nil
```

The result is always a fractional index in `0 .. n-1`, or `nil`/`NaN` for
an out-of-range query — the same domain as `linear_fetch` (section 3), so
the two compose cleanly. (If you ever need extrapolation past the ends,
do it explicitly on the value arrays; it is not a built-in mode.)

An unknown `method:` raises:

```ruby
y.linear_section(1.0, method: :bogus)     # ArgumentError
```

---

## 3. `linear_fetch` — fractional index to value

`linear_fetch` reads a value at a fractional position by blending the two
neighbouring elements:

```ruby
y = CA_DOUBLE([0.0, 2.0, 4.0, 6.0, 8.0])

y.linear_fetch(2.0)    # => 4.0   (exactly y[2])
y.linear_fetch(2.5)    # => 5.0   (halfway between y[2]=4 and y[3]=6)
```

The index must lie within `0 .. n-1`. Anything outside that closed range
returns `nil` (there is no element to extrapolate from):

```ruby
y.linear_fetch(-0.5)   # => nil
y.linear_fetch(4.0)    # => 8.0   (n-1 is the last valid index)
y.linear_fetch(4.5)    # => nil
```

This matches `linear_section`'s domain exactly: both work over `0 .. n-1`
and report anything outside it as `nil`/`NaN`, never extrapolating. The
whole family obeys one rule — *out of range means no answer* — so values
flow through a `linear_section` → `linear_fetch` chain without a single
range check in your code.

---

## 4. Working over an axis: `axis:`

Both methods take an `axis:` keyword. Without it the array is flattened
and treated as one 1-D sequence:

```ruby
m = CArray.float64(3, 4) { |i, j| (i * 4 + j).to_f }   # flattens to 0.0 .. 11.0
m.linear_section(5.5)    # => 5.5   (flattened, row-major)
```

With `axis:` the operation runs **once per fiber** along that axis; every
other axis indexes an independent problem. The named axis is consumed:

```ruby
m = CArray.float64(3, 4) { |i, j| (i * 10 + j).to_f }
# row i is [10*i, 10*i+1, 10*i+2, 10*i+3]

out = m.linear_fetch(1.5, axis: 1)   # one fetch per row
out.dim                              # => [3]
out.to_a                             # => [1.5, 11.5, 21.5]
```

`linear_section` over an axis works the same way — the axis is removed
and replaced by the (scalar) result for each fiber:

```ruby
self_3d = CArray.float64(4, 5, 6) { |i, j, k| j.to_f }
r = self_3d.linear_section(2.5, axis: 1)   # axis 1 (length 5) consumed
r.dim                                      # => [4, 6]
```

Negative axes count from the end, exactly like indexing:

```ruby
m.linear_section(2.5, axis: -1) == m.linear_section(2.5, axis: m.ndim - 1)
```

An out-of-range axis raises `ArgumentError`.

---

## 5. Many queries at once: per-fiber matched queries

When the query argument is itself a CArray (rather than a scalar), the
result shape depends on how the query's shape relates to `self`. There
are four accepted layouts, tried in the order **A3 → A2 → A2.5 → A1**.
Take `self` of shape `[4, 5, 6]` with `axis: -1` (so the searched axis
has length 6, and the *base shape* — everything else — is `[4, 5]`):

| layout | query shape | meaning | result shape |
|---|---|---|---|
| **A1** | scalar | one query for every fiber | `[4, 5]` (axis removed) |
| **A2** | `[M]` (1-D) | the same `M` queries broadcast to every fiber | `[4, 5, M]` (axis → M) |
| **A2.5** | `[4, 5]` (the base shape, `ndim ≥ 2`) | one *distinct* query per fiber | `[4, 5]` (axis removed) |
| **A3** | `[4, 5, M]` (base shape + a free axis) | `M` distinct queries per fiber | `[4, 5, M]` (axis → M) |

```ruby
self_3d = CArray.float64(4, 5, 6) { |i, j, k| k.to_f }

# A1 — scalar, one answer per fiber
self_3d.linear_fetch(2.5, axis: -1).dim                  # => [4, 5]

# A2 — a shared list of queries, broadcast to every fiber
val = CA_DOUBLE([1.5, 3.0, 4.5])
self_3d.linear_section(val, axis: -1).dim                # => [4, 5, 3]

# A2.5 — one query per fiber (query shape == base shape)
val = CArray.float64(4, 5) { |i, j| ((i + j) % 6).to_f }
self_3d.linear_fetch(val, axis: -1).dim                  # => [4, 5]

# A3 — M distinct queries per fiber (the meteorological regrid case)
val = CArray.float64(4, 5, 3) { |i, j, m| (m * 2 + 0.5).to_f }
self_3d.linear_fetch(val, axis: -1).dim                  # => [4, 5, 3]
```

A3 is the workhorse for regridding: each `(i, j)` column of `self` is a
profile, `val[i, j, :]` are the `M` target positions for that column, and
the result holds the interpolated value of every target in every column —
all in one call, no Ruby-level loop.

> A2.5 requires `self.ndim >= 3` (so the base shape has `ndim >= 2` and is
> unambiguous). For a 2-D `self` where you want one query per fiber, make
> the per-fiber intent explicit by reshaping the query to `[N, 1]`, which
> takes the A3 path with `M = 1`.

---

## 6. Data types, masks, and return values

**Data type.** Both methods compute in `Float64`. An integer (or other
numeric) `self` is coerced automatically; the result is always `Float64`:

```ruby
CA_INT64([0, 1, 2, 3, 4]).linear_section(2.5)   # => 2.5
```

**Return value.**

* For a 1-D `self` with a scalar query you get a plain Ruby `Float`, or
  `nil` when there is no answer (`linear_fetch` out of range, or
  `linear_section method: :linear` out of range).
* Otherwise you get a `Float64` CArray. Positions with no answer hold
  `NaN` (these become `nil` only in the 1-D scalar shortcut above).

**Masks.** A masked element in `self` makes the monotonic grid
ill-defined, so a masked `self` is rejected:

```ruby
y = CA_DOUBLE([0.0, 1.0, 2.0])
y[1] = UNDEF
y.linear_section(1.0)   # RuntimeError: ... should not have any masked elements
y.linear_fetch(1.0)     # RuntimeError
```

If you need to interpolate across gaps, fill or drop the masked entries
first (e.g. `y.strip_mask(fill_value)`, or rebuild the grid from the
unmasked entries) so it is contiguous and monotonic before calling these
methods.

A masked *query* is a different matter and is answered, not rejected: an
undetermined query gets an undetermined answer, so that position comes back
UNDEF instead of reading whatever value sits under the mask.

---

## 7. Time axes

A `CATime` / `CATimedelta` axis works in the same two steps, and each half
returns the kind of thing its direction implies:

```ruby
t = CArray.time_series("2024-06-15T00:00", count: 7, unit: "2 hours")

t.linear_section(CArray.time(["2024-06-15T04:00"], unit: :h))  # -> 2.0 (a position)
t.linear_fetch(CA_FLOAT64([0.0, 2.5]))                          # -> CATime (unit: 2 h)
```

`linear_section` takes a time query directly (a `CATime`, a `CATime::Element`,
a Ruby `Time` or `DateTime`) and reconciles the unit for you; it returns a
plain fractional index, same as for a numeric axis. `linear_fetch` returns
**times**, so it gives back a `CATime` in the *same unit as the axis*.

That last point is the one to plan for: the array's unit is its grid, so an
interpolated instant that lands between two ticks is rounded to the nearest
tick. Widen the grid first when the interpolation needs finer resolution —
`to_unit` is exact (it only ever moves to a finer grid):

```ruby
t.linear_fetch(CA_FLOAT64([0.0, 0.25]))
# => 00:00, 00:00      the 2-hour grid cannot hold the 30-minute offset

t.to_unit(:ms).linear_fetch(CA_FLOAT64([0.0, 0.25]))
# => 00:00:00.000, 00:30:00.000
```

Widening helps the query side too: unit reconciliation is lossless, so a query
finer than the axis must land on the axis's grid (`05:00` against a `2 h` axis
raises). One `to_unit` serves both halves.

Because both halves read the same grid, the round trip holds — including for
calendar units (`:M`, `:Y`), where there is no separate "interpolate in days"
space to think about:

```ruby
t.linear_fetch(t.linear_section(query))   # == query
```

Out of range is UNDEF rather than NaN (int64 tick storage has no NaN to spare),
and a masked address stays UNDEF. Both are missing cells you can test with
`is_masked` or fill with the usual mask tools.

This is what lets a regrid treat every axis alike — `axis.linear_fetch(idx)`
returns something of the same kind and on the same grid as `axis`, whether the
axis is a float coordinate or a time:

```ruby
xc = x.linear_fetch(idx + 0.5)   # Float64 -> Float64
tc = t.linear_fetch(idx + 0.5)   # CATime  -> CATime, same unit
```

A `CAFrame` follows the same rule: `fill(col, :linear)` interpolates a time
column into a time column, on that column's unit.

---

## 8. Quick reference

```ruby
# value -> fractional index
arr.linear_section(value)                      # 1-D, scalar -> Float or nil
arr.linear_section(value, method: :linear)     # :binary (default) | :linear
arr.linear_section(value, axis: k)             # per-fiber along axis k
arr.linear_section(query_ca, axis: k)          # per-fiber matched queries (A1/A2/A2.5/A3)

# fractional index -> value
arr.linear_fetch(index)                        # 1-D, scalar -> Float or nil
arr.linear_fetch(index, axis: k)               # per-fiber along axis k
arr.linear_fetch(index_ca, axis: k)            # per-fiber matched queries

# interpolate y on grid x at an arbitrary x_query
ys.linear_fetch(xs.linear_section(x_query))
```

| concern | behaviour |
|---|---|
| grid requirement | monotonic ascending or descending |
| out of range (whole family) | returns `nil` (scalar) / `NaN` (array); never extrapolates |
| `:binary` vs `:linear` | same function, different cost — agree on every input |
| default search | `:binary` (`O(log n)`, `O(1)` for equispaced grids) |
| compute / result type | `Float64` (inputs coerced) |
| masked `self` | raises `RuntimeError` |
| masked query | that position is UNDEF (never answered from under the mask) |
| time axis | `linear_section` -> position; `linear_fetch` -> `CATime` in the axis's unit (§7) |
| `axis:` | per-fiber; named axis consumed; negatives allowed |
