# Histograms

A histogram counts how many values fall into each of a set of bins. CArray
builds them for continuous data (real values sorted into bins by their edges)
and for discrete data (integer labels counted directly), in one dimension, two
dimensions, or any number at once. The entry methods return a small stateful
object that carries the bin layout and the counts, and that you can keep feeding
data to in chunks.

Where the histogram methods really earn their keep is on **multi-dimensional
arrays**. You are not meant to flatten your data first and loop in Ruby. Point a
method at an axis with `axis:` and every fiber along the remaining axes gets its
own histogram in a single call — one spectrum per detector row, one distribution
per grid cell, one joint histogram per time step. The flat 1-D case is just the
degenerate one-fiber version of the same machine.

This chapter starts with the simplest case — a 1-D histogram of continuous
values — and builds up to per-axis (fiber) histograms, joint histograms,
weighting, and streaming. The discrete sibling `bincount_nd` comes at the end.

Everything here works after `require "carray"`.

## The simplest case: a 1-D histogram

You supply the **edges** — the boundary values between bins — and CArray counts
how many samples land in each bin.

```ruby
edges = CArray.float64(6).span(0..5)      # [0, 1, 2, 3, 4, 5] -> 5 bins
data  = CA_FLOAT64([0.5, 1.5, 1.5, 4.5, -1.0, 5.0, 5.5])

h = data.histogram1d(edges: edges)
h.counts.to_a                             # => [1, 2, 0, 0, 1]
```

`edges` is `N+1` ascending boundary values, and defines `N` bins. Bin `k` spans
the half-open interval `[edges[k], edges[k+1])` — closed on the left, open on
the right. So the five bins above are `[0,1)`, `[1,2)`, `[2,3)`, `[3,4)`,
`[4,5)`. The one `0.5` lands in bin 0; the two `1.5`s in bin 1; the `4.5` in
bin 4.

`edges:` is a required keyword. Give it any 1-D CArray (or a Ruby Array of
numbers) sorted ascending with at least two values.

### The bin centres and edges are on the object

The returned object remembers its layout:

```ruby
h.edges.to_a       # => [0.0, 1.0, 2.0, 3.0, 4.0, 5.0]
h.midpoints.to_a   # => [0.5, 1.5, 2.5, 3.5, 4.5]   bin centres, length N
```

`midpoints` is `(edges[0..-2] + edges[1..-1]) / 2` — the centre of each bin,
one value shorter than `edges`. It is what you usually plot the counts against.

### Out-of-range values: under and over

Three of the seven samples above fell outside the edges — `-1.0` is below the
bottom, and `5.0` and `5.5` are at or above the top. These are not discarded.
They are held in two extra **outlier** cells, one below the bins and one above:

```ruby
h.under            # => 1     samples below edges[0]
h.over             # => 2     samples at or above edges[-1]
h.total            # => 7     every sample seen, in range or not
h.outlier_total    # => 3     total minus counts.sum
```

Notice `5.0` — a value exactly equal to the **top** edge — counted as `over`,
not into the last bin, because bins are right-open. If you want the top edge
folded into the last bin, see [Closing the top edge](#closing-the-top-edge)
below.

The counts you see with `counts` are the in-range bins only. The real storage
extends them by two cells and is available as `full_counts`:

```ruby
h.full_counts.to_a   # => [1, 1, 2, 0, 0, 1, 2]
#                          ^under  <- in-range bins ->  ^over
h.counts.to_a        # => [1, 2, 0, 0, 1]
```

`full_counts` has shape `(N + 2)`: the `N` bins plus one under cell at the front
and one over cell at the back. `counts` is a zero-copy view of just the middle.

### Closing the top edge

For a bounded quantity — a probability, a percentage, an angle mod 360 — you
usually want a value sitting exactly on the top edge to count in the last bin
rather than spilling into `over`. Pass `include_max: true`:

```ruby
h = data.histogram1d(edges: edges, include_max: true)
h.counts.to_a      # => [1, 2, 0, 0, 2]   the 5.0 now lands in bin 4
h.over             # => 1                 only 5.5 is still over
```

### Masked and NaN values are skipped

Masked cells and `NaN` values take part in no bin at all — not even the outlier
cells, and not in `total`:

```ruby
data = CA_FLOAT64([0.5, Float::NAN, 1.5, 3.5]).to_ca
data[0] = UNDEF                            # mask the first element

h = data.histogram1d(edges: edges)
h.counts.to_a      # => [0, 1, 0, 1, 0]   only 1.5 and 3.5 counted
h.total            # => 2
```

See [Masks and missing values](05_masks.md) for how masks work generally.

### Along an axis of a bigger array

`histogram1d` is not limited to a flat array. Hand it a multi-dimensional array
and name the **sample** axis with `axis:`; every position of the remaining axes
gets its own independent histogram, computed in one call. The counts gain those
axes in front:

```ruby
data = CArray.float64(2, 4)                  # two rows
data[0, nil] = CA_FLOAT64([0.5, 1.5, 2.5, 3.5])
data[1, nil] = CA_FLOAT64([4.5, -1.0, 0.5, 0.5])

h = data.histogram1d(edges: edges, axis: -1)  # bin along the last axis
h.counts.shape         # => [2, 5]            one row of bins per input row
h.counts[0, nil].to_a  # => [1, 1, 1, 1, 0]
h.counts[1, nil].to_a  # => [2, 0, 0, 0, 1]
h.under.to_a           # => [0, 1]            per-row outliers, too
```

Omitting `axis:` bins the whole array flat, as in every example above. The full
mechanics of per-axis histograms — and the joint version — are in
[One histogram per row: `axis:` and fibers](#one-histogram-per-row-axis-and-fibers)
below.

## What the entry methods return

`histogram1d`, `histogram2d`, and `histogram` all return a `CArray::Histogram`
object. It is a live accumulator — it holds the counts and knows its bin layout,
so you read results off it and can keep adding to it.

| accessor          | what it gives you                                            |
|-------------------|-------------------------------------------------------------|
| `counts`          | in-range bins                                               |
| `full_counts`     | the extended storage (each bin axis has `+2` outlier cells) |
| `under` / `over`  | the outlier cells (see `axis:` for joint histograms)        |
| `total`           | every sample seen, in range or not                          |
| `outlier_total`   | samples that fell outside on any axis                       |
| `edges`           | the bin edges                                               |
| `midpoints`       | the bin centres                                             |

`add` and `+` extend the same object; they are covered under
[streaming](#streaming-accumulate-in-chunks) below.

## Joint histograms: two or more channels at once

A joint histogram bins each sample by several coordinates at the same time. A
weather sample might carry both a humidity and a temperature; a 2-D histogram
tells you how many samples fall in each humidity-temperature cell.

The input carries the coordinates on a trailing **channel** axis: each sample is
a length-`M` row of `M` coordinates. For `histogram2d` that is `(A, 2)` — `A`
samples, two coordinates each.

```ruby
eh = CArray.float64(11).span(0..100)   # 10 humidity bins
et = CArray.float64(7).span(-20..40)   #  6 temperature bins

data = CArray.float64(4, 2)            # 4 samples, 2 coordinates each
data[0, nil] = CA_FLOAT64([55.0, 15.0])   # humidity in, temp in
data[1, nil] = CA_FLOAT64([-5.0, 15.0])   # humidity under
data[2, nil] = CA_FLOAT64([55.0, 50.0])   # temp over
data[3, nil] = CA_FLOAT64([ 5.0,  5.0])   # in, in

h = data.histogram2d(edges: [eh, et])

h.counts.shape       # => [10, 6]    a 2-D grid of in-range bins
h.full_counts.shape  # => [12, 8]    each axis extended by +2
h.total              # => 4
h.outlier_total      # => 2
```

Now `edges:` is an array of `M` edge arrays, one per dimension, each with its
own bin count. `counts` is an `M`-dimensional grid.

### Which axis's outlier? `under(axis:)` / `over(axis:)`

With more than one dimension, `under` and `over` need to know *which*
coordinate's outlier you mean. Pass `axis:`; the other dimensions are summed
away, giving the marginal:

```ruby
h.under(axis: 0)     # => 1    samples below the humidity range
h.over(axis: 1)      # => 1    samples above the temperature range
```

For a 1-D histogram `axis:` may be omitted (there is only one axis). For two or
more dimensions it is required:

```ruby
h.under              # ArgumentError: axis: keyword required (M=2)
```

### edges and midpoints per dimension

For a joint histogram, `edges` and `midpoints` return an **array** of `M`
CArrays, one per dimension. For a 1-D histogram they return a single CArray:

```ruby
h.midpoints                    # => [<CArray 10>, <CArray 6>]
h.midpoints.map(&:elements)    # => [10, 6]
```

### `include_max` per dimension

`include_max` may be a single boolean applied to every dimension, or an array of
`M` booleans so you can close the top edge on one axis and leave another open:

```ruby
h = data.histogram2d(edges: [eh, et], include_max: [true, false])
```

### Three or more dimensions: `histogram`

`histogram2d` is a thin wrapper that insists on exactly two edge arrays. For
three or more coordinates use `histogram` directly, with `M` edge arrays and an
explicit `axis:` naming the `[sample, channel]` pair:

```ruby
e = CArray.float64(3).span(0..2)   # 2 bins per axis
d = CArray.float64(2, 3)           # 2 samples, 3 coordinates each
d[0, nil] = CA_FLOAT64([0.5, 0.5, 0.5])
d[1, nil] = CA_FLOAT64([1.5, 1.5, 1.5])

h = d.histogram(edges: [e, e, e], axis: [0, 1])
h.counts.shape        # => [2, 2, 2]
h.counts[0, 0, 0]     # => 1
h.counts[1, 1, 1]     # => 1
h.total               # => 2
```

## Weighted histograms

A weighted histogram adds a **weight** per sample instead of a plain count of 1.
Pass a `weights:` array shaped like the samples (the input minus the channel
axis):

```ruby
edges   = CArray.float64(6).span(0..5)
data    = CA_FLOAT64([0.5, 1.5, 1.5, 4.5, -1.0, 5.0, 5.5])
weights = CA_FLOAT64([1, 2, 3, 4, 5, 6, 7])

h = data.histogram1d(edges: edges, weights: weights)
h.counts.to_a               # => [1.0, 5.0, 0.0, 0.0, 4.0]
h.counts.data_type_name     # => "float64"
```

Bin 1 holds the two `1.5`s, which carry weights `2` and `3`, so its cell reads
`5.0`. Unweighted counts are `int64`; weighted counts are always `float64`. All
the outlier cells and `total` are weighted the same way.

Weighting works identically for joint histograms — one weight per sample, the
channel axis dropped:

```ruby
h = data.histogram2d(edges: [eh, et], weights: some_weights)
```

## Streaming: accumulate in chunks

The object the entry methods return is a live accumulator. You do not have to
hold all your data in one array — start an empty accumulator and feed it chunks
with `add`.

Bootstrap an empty accumulator by passing a zero-length sample axis to the entry
method:

```ruby
acc = CArray.float64(0).histogram1d(edges: edges)   # empty
acc.add(CA_FLOAT64([0.5, 1.5]))
acc.add(CA_FLOAT64([2.5, 3.5, 4.5]))
acc.counts.to_a    # => [1, 1, 1, 1, 1]
acc.total          # => 5
```

`add(chunk, weights: ...)` accepts the same shapes as the entry method. The
sample-axis length is free — each chunk may be a different size — but the fiber
shape (see below) and the weighted/unweighted state are locked once the
accumulator is built.

### Combining histograms with `+`

Two histograms built over the same layout add cell by cell:

```ruby
h1 = CA_FLOAT64([0.5, 1.5, 2.5]).histogram1d(edges: edges)
h2 = CA_FLOAT64([0.5, 4.5, -1.0]).histogram1d(edges: edges)

hc = h1 + h2
hc.counts.to_a     # => [2, 1, 1, 0, 1]
hc.under           # => 1
```

`+` returns a new histogram and checks that both sides agree on edges, fiber
shape, `include_max`, and weighted/unweighted state; it raises otherwise. This
lets you build histograms over separate batches — for example one per file — and
merge them at the end.

## One histogram per row: `axis:` and fibers

Give `histogram1d` a 2-D (or higher) array and name the **sample** axis with
`axis:`. Every position of the remaining axes — the *fiber* axes — gets its own
independent histogram, all computed in a single call:

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

The leading axis here is a fiber axis, so `counts` gains that axis in front, and
`under`, `over`, `total`, and `outlier_total` each return one value per fiber
position rather than a scalar.

A vectorized *joint* histogram combines both ideas — the input is
`fiber + (A, M)`. For a 3-D input `(2, 3, 2)`, `histogram2d`'s default
`axis: [-2, -1]` names the last two axes as `[sample, channel]`, leaving the
first as a fiber:

```ruby
data = CArray.float64(2, 3, 2)   # 2 fibers, 3 samples each, 2 coordinates
# ... fill data ...
h = data.histogram2d(edges: [eh, et])
h.counts.shape   # => [2, 10, 6]   a 10x6 grid per fiber
```

## The discrete sibling: `bincount` and `bincount_nd`

When the values are already non-negative integer *labels*, you do not need
edges — the value **is** the bin index. Use `bincount` for one variable and
`bincount_nd` for the joint count of several.

For a single variable, `bincount` returns a plain counts array:

```ruby
labels = CA_INT32([0, 1, 1, 2, 2, 2, 5])
labels.bincount.to_a              # => [1, 2, 3, 0, 0, 1]
#  index:                              0  1  2  3  4  5
labels.bincount.data_type_name    # => "uint32"
```

The output covers `0 .. max_label`. Pad it to a fixed size with `length:`, and
weight it with `weights:`:

```ruby
labels.bincount(length: 8).to_a   # => [1, 2, 3, 0, 0, 1, 0, 0]
CA_INT32([0, 1, 1, 2]).bincount(weights: CA_FLOAT64([1, 2, 3, 4])).to_a
# => [1.0, 5.0, 4.0]
```

For the joint distribution of `M` integer variables, `bincount_nd` mirrors the
`histogram` surface, with `lengths:` (the number of valid labels per dimension)
in place of `edges:`:

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

`bincount_nd` returns a `CArray::BincountND` object, and supports weighting,
streaming `add`, `+` composition, and vectorized fibers exactly like a
histogram. It is the discrete counterpart, so its outlier model is simpler:
labels index from 0, so there is no lower outlier. A label at or above its
length lands in a single **upper overflow** cell, and the storage grows by `+1`
per dimension (not `+2`). A negative label is an error, not an outlier:

```ruby
data = CArray.int32(3, 2)
data[0, nil] = CA_INT32([0, 0])   # in / in
data[1, nil] = CA_INT32([5, 1])   # label 5 >= length 3 -> overflow on dim 0
data[2, nil] = CA_INT32([1, 9])   # label 9 >= length 3 -> overflow on dim 1

h = data.bincount_nd(lengths: [3, 3])
h.full_counts.shape   # => [4, 4]    each axis is L+1
h.counts.sum          # => 1         only the first sample is fully in range
h.overflow(axis: 0)   # => 1
h.overflow(axis: 1)   # => 1
h.overflow_total      # => 2
```

`overflow(axis:)` is the discrete analogue of `over(axis:)`, and like it,
requires `axis:` once `M >= 2`.

### Which tool to use

* **Continuous values → `histogram1d` / `histogram2d` / `histogram`.** You
  choose the bins with `edges:`. Out-of-range values are kept in `under` and
  `over`.
* **Integer labels, one variable → `bincount`.** The label is the bin index;
  simplest and fastest.
* **Integer labels, joint distribution → `bincount_nd`.** Out-of-range labels
  go to the upper overflow cell; negatives raise.

You *can* histogram integer data with integer edges, but the discrete methods
are the natural fit — no edges to spell out, and no lower outlier to reason
about.

## Method reference

### Entry methods

| method | input | returns |
|---|---|---|
| `histogram1d(edges:, axis: -1, include_max: false, weights: nil)` | `fiber + (A,)` (channel axis may be omitted) | `CArray::Histogram` |
| `histogram2d(edges:, axis: [-2,-1], include_max: false, weights: nil)` | `fiber + (A, 2)` | `CArray::Histogram` |
| `histogram(edges:, axis: [-2,-1], include_max: false, weights: nil)` | `fiber + (A, M)` | `CArray::Histogram` |
| `bincount(weights: nil, length: nil)` | `(A,)` integer | counts `CArray` |
| `bincount_nd(lengths:, axis: [-2,-1], weights: nil)` | `fiber + (A, M)` integer | `CArray::BincountND` |

`edges:` and `lengths:` are required. `axis:` names the sample axis
(`histogram1d`) or the `[sample, channel]` axis pair (the joint methods).

### `CArray::Histogram`

| method | result |
|---|---|
| `counts` | in-range bins, shape `fiber + (N_0, …, N_{M-1})` |
| `full_counts` | extended storage, each bin axis `+2` (under / over) |
| `under(axis:)` / `over(axis:)` | outlier marginal on one axis; `axis:` optional for `M = 1`, required for `M >= 2` |
| `total` / `outlier_total` | per-fiber totals |
| `midpoints` / `edges` | a single `CArray` for `M = 1`, an array of `M` otherwise |
| `add(chunk, weights:)` | accumulate another chunk |
| `+` | combine two compatible histograms cell by cell |

### `CArray::BincountND`

| method | result |
|---|---|
| `counts` | in-range bins, shape `fiber + (L_0, …, L_{M-1})` |
| `full_counts` | extended storage, each bin axis `+1` (upper overflow) |
| `overflow(axis:)` | upper-overflow marginal; `axis:` optional for `M = 1`, required for `M >= 2` |
| `total` / `overflow_total` | per-fiber totals |
| `lengths` | the per-dimension label ranges |
| `add(chunk, weights:)` | accumulate another chunk |
| `+` | combine two compatible accumulators cell by cell |

## See also

* [Reduction and statistics](04_reduction_and_statistics.md) — `sum`, `mean`,
  and the other per-axis reductions that summarise a whole array.
* [Masks and missing values](05_masks.md) — how masked and `NaN` samples are
  skipped.
* [The iterator family](21_iterator_family.md) — the fiber model that the
  vectorized (`axis:`) forms build on.
* `../Histogram.md` — the full reference.
