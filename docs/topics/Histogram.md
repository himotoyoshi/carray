# Histograms in CArray

CArray builds histograms — counts of how many samples fall into each
cell — for continuous and for discrete data, in one, two, or any number
of dimensions, and (uniquely) computes a *separate* histogram for every
position of a leading "fiber" axis in one call.

There are two families of methods, chosen by the *kind* of data:

| data | tool | cell = |
|---|---|---|
| **continuous** (real values, binned by edges) | `CArray#histogram1d` / `#histogram2d` / `#histogram` | a half-open interval `[edge[k], edge[k+1])` |
| **discrete** (non-negative integer labels) | `CArray#bincount` (1-D) / `#bincount_nd` (joint) | a single integer value |

For continuous data you supply **edges**; a value is placed into the bin
whose interval contains it. For discrete data the integer value *is* the
bin index, so no edges are needed — you supply the per-dimension
**length** (number of distinct values).

The continuous methods and `bincount_nd` return a small stateful object
(`CArray::Histogram` / `CArray::BincountND`) that carries the bin
configuration and the counts, and supports streaming and composition.
`bincount` returns a plain counts array.

Everything in this guide works after `require "carray"`.

---

## 1. The input layout: fiber, sample, channel

All of these methods read their input with the same shape model:

```
    fiber_shape   +   (A,)   +   (M,)
        ^               ^          ^
        |               |          channel axis — the M coordinates of one sample
        |               sample axis — A independent samples
        leading fiber axes — one independent histogram is built per position
```

* **sample axis** (length `A`) — the axis you reduce over. Each element
  along it is one observation.
* **channel axis** (length `M`) — the `M` coordinates of a single sample.
  `M = 1` for a 1-D histogram, `M = 2` for a 2-D joint histogram, and so
  on. The channel axis carries, for each sample, its value in every
  dimension.
* **fiber axes** — everything in front. Each fiber position gets its own
  independent histogram. With no fiber axes you get one global histogram.

The `axis:` keyword names the `[sample, channel]` pair. For a plain 1-D
histogram the channel axis can be omitted entirely (see below).

---

## 2. Continuous data, 1-D: `histogram1d`

```ruby
edges = CArray.float64(6).span(0..5)       # [0, 1, 2, 3, 4, 5] -> 5 bins
data  = CA_FLOAT64([0.5, 1.5, 1.5, 4.5, -1.0, 5.0, 5.5])

h = data.histogram1d(edges: edges)
h.counts.to_a                              # => [1, 2, 0, 0, 1]
```

`edges` are `N+1` ascending boundary values defining `N` bins. Bin `k`
spans `[edges[k], edges[k+1])` — closed on the left, open on the right.

### The extended counts model: under and over

Two of the seven samples above fell outside the edges (`-1.0` below,
`5.0` and `5.5` at/above the top). They are not discarded — they are
counted in two extra **outlier** cells, one below and one above:

```ruby
h.full_counts.to_a    # => [1, 1, 2, 0, 0, 1, 2]
#                            ^under  <-- in-range bins -->  ^over
h.counts.to_a         # => [1, 2, 0, 0, 1]   (the in-range bins only)
```

`full_counts` is the real storage: shape `(N + 2)` — the `N` in-range
bins plus one **under** cell at the front and one **over** cell at the
back. `counts` is a zero-copy view of just the in-range bins.

Accessors read straight off this storage:

```ruby
h.under            # => 1     samples below edges[0]
h.over             # => 2     samples at/above edges[-1]
h.total            # => 7     every sample seen, in-range or not
h.outlier_total    # => 3     total - counts.sum  (fell outside on any axis)
```

Note that a value exactly equal to the **top** edge (`5.0` here) lands in
`over`, not in the last bin, because bins are right-open. See
[bin closure](#bin-closure-include_max) to change that.

### midpoints and edges

```ruby
h.midpoints.to_a   # => [0.5, 1.5, 2.5, 3.5, 4.5]   bin centres, length N
h.edges.to_a       # => [0.0, 1.0, 2.0, 3.0, 4.0, 5.0]
```

`midpoints` returns `(edges[0..-2] + edges[1..-1]) / 2` — handy for
plotting against bin centres.

### Bin closure (`include_max`)

For a bounded quantity (humidity 0–100 %, a probability, an angle mod
360°) you usually want the top edge included in the last bin. Pass
`include_max: true`:

```ruby
h = data.histogram1d(edges: edges, include_max: true)
h.counts.to_a      # => [1, 2, 0, 0, 2]   the 5.0 now lands in bin 4
h.over             # => 1                 only 5.5 is still over
```

### Weighted histograms

Each sample can contribute a weight instead of 1:

```ruby
weights = CA_FLOAT64([1, 2, 3, 4, 5, 6, 7])
h = data.histogram1d(edges: edges, weights: weights)
h.counts.to_a                  # => [1.0, 5.0, 0.0, 0.0, 4.0]
h.counts.data_type_name        # => :float64   (counts switch to float when weighted)
```

Unweighted counts are `int64`; weighted counts are `float64`.

### Masked and NaN data

Masked elements and `NaN` values are skipped — not counted in any cell,
including the outliers:

```ruby
data = CA_FLOAT64([0.5, Float::NAN, 1.5, 3.5]).to_ca
data[0] = UNDEF                 # mask the first element

h = data.histogram1d(edges: edges)
h.counts.to_a      # => [0, 1, 0, 1, 0]   only 1.5 and 3.5 counted
h.total            # => 2
```

### Streaming: accumulate over chunks

The returned object is a live accumulator. Start an empty one with a
zero-length sample axis and feed it chunks with `add`:

```ruby
acc = CArray.float64(0).histogram1d(edges: edges)   # empty
acc.add(CA_FLOAT64([0.5, 1.5]))
acc.add(CA_FLOAT64([2.5, 3.5, 4.5]))
acc.counts.to_a    # => [1, 1, 1, 1, 1]
acc.total          # => 5
```

`add(chunk, weights: ...)` accepts the same shapes as the entry method;
the sample axis length is free, the fiber shape must match.

### Combining histograms (`+`)

Two histograms over the same edges add cell by cell:

```ruby
h1 = CA_FLOAT64([0.5, 1.5, 2.5]).histogram1d(edges: edges)
h2 = CA_FLOAT64([0.5, 4.5, -1.0]).histogram1d(edges: edges)
hc = h1 + h2
hc.counts.to_a     # => [2, 1, 1, 0, 1]
hc.under           # => 1
```

`+` checks that both sides agree on edges, fiber shape, `include_max` and
weighted/unweighted; it raises otherwise.

### Vectorized: one histogram per row

Give `histogram1d` a 2-D (or higher) array and an `axis:` that names the
sample axis. Every position of the remaining (fiber) axes gets its own
histogram, computed in a single call:

```ruby
data = CArray.float64(2, 4)
data[0, nil] = CA_FLOAT64([0.5, 1.5, 2.5, 3.5])
data[1, nil] = CA_FLOAT64([4.5, -1.0, 0.5, 0.5])

h = data.histogram1d(edges: edges, axis: -1)   # reduce the last axis

h.counts.shape         # => [2, 5]            one row of bins per input row
h.counts[0, nil].to_a  # => [1, 1, 1, 1, 0]
h.counts[1, nil].to_a  # => [2, 0, 0, 0, 1]
h.under.to_a           # => [0, 1]            per-row under counts
h.total.to_a           # => [4, 4]
```

Here `under`, `over`, `total` and friends return one value per fiber
position (shape `[2]`), not a scalar.

---

## 3. Continuous data, 2-D and N-D: `histogram2d`, `histogram`

A joint histogram bins each sample by `M` coordinates at once. The input
is `fiber + (A, M)`: a length-`M` channel axis carrying the coordinates.

```ruby
eh = CArray.float64(11).span(0..100)   # 10 humidity bins
et = CArray.float64(7).span(-20..40)   #  6 temperature bins

data = CArray.float64(4, 2)            # 4 samples, 2 coordinates each
data[0, nil] = CA_FLOAT64([55.0, 15.0])   # in / in
data[1, nil] = CA_FLOAT64([-5.0, 15.0])   # under humidity
data[2, nil] = CA_FLOAT64([55.0, 50.0])   # over temperature
data[3, nil] = CA_FLOAT64([ 5.0,  5.0])   # in / in

h = data.histogram2d(edges: [eh, et])

h.counts.shape       # => [10, 6]    a 2-D grid of in-range bins
h.full_counts.shape  # => [12, 8]    each axis extended by +2 (under/over)
h.total              # => 4
h.outlier_total      # => 2
```

`edges` is now an array of `M` edge arrays (one per dimension), each with
its own bin count. `counts` is an `M`-dimensional grid.

### Per-axis marginals: `under(axis:)`, `over(axis:)`

With more than one dimension you must say *which* axis's outlier you
mean. The other axes are summed away:

```ruby
h.under(axis: 0)     # => 1    samples below the humidity range
h.over(axis: 1)      # => 1    samples above the temperature range
```

For a 1-D histogram `axis:` may be omitted; for `M ≥ 2` it is required:

```ruby
h.under              # ArgumentError: axis: keyword required (M=2)
```

### midpoints per dimension

```ruby
h.midpoints                       # => [<CArray 10>, <CArray 6>]
h.midpoints.map(&:elements)       # => [10, 6]
```

For `M = 1`, `midpoints` and `edges` return a single `CArray`; for
`M ≥ 2` they return an array of `M` CArrays.

### `include_max` per dimension

`include_max` may be a single boolean (applied to all dimensions) or an
array of `M` booleans, so you can include the top edge on a bounded axis
and leave another axis open:

```ruby
h = data.histogram2d(edges: [eh, et], include_max: [true, false])
```

### General M-D: `histogram`

`histogram2d` is a thin wrapper that requires exactly two edge arrays.
For three or more dimensions use `histogram` directly with `M` edges and
an explicit `axis:`:

```ruby
e  = CArray.float64(3).span(0..2)   # 2 bins per axis
d  = CArray.float64(2, 3)           # 2 samples, 3 coordinates each
d[0, nil] = CA_FLOAT64([0.5, 0.5, 0.5])
d[1, nil] = CA_FLOAT64([1.5, 1.5, 1.5])

h = d.histogram(edges: [e, e, e], axis: [0, 1])
h.counts.shape        # => [2, 2, 2]
h.counts[0, 0, 0]     # => 1
h.counts[1, 1, 1]     # => 1
h.total               # => 2
```

A vectorized joint histogram combines both ideas — `fiber + (A, M)`:

```ruby
# 2 fibers, 3 samples each, 2 coordinates -> a 2-D histogram per fiber
data = CArray.float64(2, 3, 2) { |f, a, c| ... }
h = data.histogram2d(edges: [eh, et])   # default axis: [-2, -1]
h.counts.shape   # => [2, 10, 6]
```

---

## 4. Discrete data, 1-D: `bincount`

When the values are already non-negative integer labels, the value *is*
the bin — no edges. `bincount` counts occurrences of each label:

```ruby
labels = CA_INT32([0, 1, 1, 2, 2, 2, 5])
labels.bincount.to_a              # => [1, 2, 3, 0, 0, 1]
#  index:                              0  1  2  3  4  5
labels.bincount.data_type_name    # => :uint32
```

The output length covers `0 .. max_label`. Pad it to a fixed size with
`length:` (the result grows past it if a label is larger):

```ruby
labels.bincount(length: 8).to_a   # => [1, 2, 3, 0, 0, 1, 0, 0]
```

Weighted counts work the same way and return the weights' type:

```ruby
CA_INT32([0, 1, 1, 2]).bincount(weights: CA_FLOAT64([1, 2, 3, 4])).to_a
# => [1.0, 5.0, 4.0]
```

Labels must be a non-negative integer array; a float array raises
`CArray::DataTypeError`.

---

## 5. Discrete joint: `bincount_nd`

`bincount_nd` is to `bincount` what `histogram` is to a 1-D histogram:
the joint count of `M` integer labels. The surface mirrors `histogram`,
with one difference — instead of `edges:` you give `lengths:`, the number
of valid values per dimension:

```ruby
x = CA_INT32([0, 1, 1, 2, 0])
y = CA_INT32([0, 0, 1, 1, 2])
data = CArray.int32(5, 2)         # fiber + (A=5, M=2)
data[nil, 0] = x
data[nil, 1] = y

h = data.bincount_nd(lengths: [3, 3])

h.counts.to_a     # => [[1, 0, 1],
                  #     [1, 1, 0],
                  #     [0, 1, 0]]
h.total           # => 5
```

`lengths` is required (the entry method needs it to size the output). Use
the dedicated `bincount` for a bare 1-D count; `bincount_nd` is for
`M ≥ 2` (or an explicit `(A, 1)` shape).

### The upper-overflow model

Unlike a histogram, a discrete count has a structural lower bound of 0
(labels index from 0); `length` `L` is the upper cut. So there is only
*one* outlier direction — upward — and storage is extended by **+1** per
dimension (one overflow cell on top), not +2:

```
    value v in 0 .. L-1   -> cell v
    value v >= L          -> upper overflow cell (index L)
    value v < 0           -> ArgumentError (not a valid label)
```

```ruby
data = CArray.int32(3, 2)
data[0, nil] = CA_INT32([0, 0])   # in / in
data[1, nil] = CA_INT32([5, 1])   # label 5 >= length 3 -> overflow on dim 0
data[2, nil] = CA_INT32([1, 9])   # label 9 >= length 3 -> overflow on dim 1

h = data.bincount_nd(lengths: [3, 3])

h.full_counts.shape   # => [4, 4]    each axis is L+1 (3 + 1 overflow cell)
h.total               # => 3
h.counts.sum          # => 1         only the first sample is fully in range
h.overflow(axis: 0)   # => 1         samples whose dim-0 label >= 3
h.overflow(axis: 1)   # => 1
h.overflow_total      # => 2         samples that overflowed on any axis
```

`overflow(axis:)` is the discrete analogue of `over(axis:)`; like the
histogram marginals it requires `axis:` when `M ≥ 2`. A negative label is
treated as an error, not an outlier:

```ruby
d = CArray.int32(2, 1); d[nil, 0] = CA_INT32([0, -1])
d.bincount_nd(lengths: [3])     # ArgumentError: bincount_nd: negative label
```

### Weighted, vectorized, streaming, composition

These behave exactly as for the continuous histogram.

```ruby
# weighted
data.bincount_nd(lengths: [3, 3], weights: CA_FLOAT64([...]))

# vectorized: one joint count per fiber position
df = CArray.int32(2, 4, 2) { |f, a, c| (f + a + c) % 3 }
h  = df.bincount_nd(lengths: [3, 3], axis: [1, 2])
h.counts.shape   # => [2, 3, 3]   a 3x3 grid per fiber
h.total.to_a     # => [4, 4]

# streaming
acc = CArray.int32(0, 1).bincount_nd(lengths: [3])
acc.add(CA_INT32([0, 1]))
acc.add(CA_INT32([1, 2, 2]))
acc.counts.to_a  # => [1, 2, 2]

# combining
ha + hb          # checks lengths / fiber_shape / weighted match
```

---

## 6. Choosing the right tool

```
                 values are real numbers?
                 /                       \
               yes                        no (non-negative integers)
                |                          |
          histogram1d /              one variable?      several variables?
          histogram2d /                  |                    |
          histogram                   bincount            bincount_nd
        (edges per axis)            (value = bin)      (value = bin, joint)
```

* **Continuous values → `histogram*`.** You decide the bins via `edges`.
  Out-of-range values are kept in `under` / `over`.
* **Integer labels, one variable → `bincount`.** Fastest and simplest;
  the label is the bin index directly.
* **Integer labels, joint distribution → `bincount_nd`.** Out-of-range
  labels are kept in the upper overflow cell; negatives are an error.

You *can* histogram integer data with integer edges
(`edges: CArray.float64(L+1).span(0..L)`), but `bincount` / `bincount_nd`
are the natural and faster tools for the discrete case.

---

## 7. Method reference

### Entry methods

| method | input shape | returns |
|---|---|---|
| `histogram1d(edges:, axis: -1, include_max: false, weights: nil)` | `fiber + (A,)` (channel optional) | `CArray::Histogram` |
| `histogram2d(edges:, axis: [-2,-1], include_max: false, weights: nil)` | `fiber + (A, 2)` | `CArray::Histogram` |
| `histogram(edges:, axis: [-2,-1], include_max: false, weights: nil)` | `fiber + (A, M)` | `CArray::Histogram` |
| `bincount(weights: nil, length: nil)` | `(A,)` integer | counts `CArray` |
| `bincount_nd(lengths:, axis: [-2,-1], weights: nil)` | `fiber + (A, M)` integer | `CArray::BincountND` |

### `CArray::Histogram`

| method | result |
|---|---|
| `counts` | in-range bins, shape `fiber + (N_0, …, N_{M-1})` |
| `full_counts` | extended storage, each bin axis `+2` (under/over) |
| `under(axis:)` / `over(axis:)` | outlier marginal on one axis, shape `fiber` |
| `outlier_total` / `total` | per-fiber totals |
| `midpoints` / `edges` | single `CArray` for `M=1`, array of `M` otherwise |
| `add(chunk, weights:)` | accumulate another chunk |
| `+` | element-wise combine (structure must match) |

### `CArray::BincountND`

| method | result |
|---|---|
| `counts` | in-range bins, shape `fiber + (L_0, …, L_{M-1})` |
| `full_counts` | extended storage, each bin axis `+1` (upper overflow) |
| `overflow(axis:)` | upper-overflow marginal on one axis, shape `fiber` |
| `overflow_total` / `total` | per-fiber totals |
| `lengths` | the per-dimension extents |
| `add(chunk, weights:)` | accumulate another chunk |
| `+` | element-wise combine (structure must match) |
