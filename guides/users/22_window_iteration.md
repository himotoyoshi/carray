# Window iteration

The slab iterator in [Slab iteration](11_slab_iteration.md) folds each
*non-overlapping* fiber of an array. The **window iterator** folds an
*overlapping* window centred on every cell. Give each cell a small
neighbourhood, fold that neighbourhood to one value, and you get a **rolling**
result — a moving average, a running standard deviation, a bounded convolution —
shaped like the original array.

You build one with `windows`:

```ruby
a = CArray.float64(8).seq(1)     #  => [ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0 ]

a.windows(-1..1).mean            #  rolling mean over a width-3 window
#  => [ 1.5, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 7.5 ]
```

Every interior cell averages itself and its two neighbours. The edges have no
neighbour on one side, so — by default — they average only the cells that exist:
cell 0 sees `[1, 2]` and reports `1.5`, cell 7 sees `[7, 8]` and reports `7.5`.
What the edges do is the [boundary policy](#the-boundary-policy-bounds), covered
below.

`windows` returns a **`CAWindowIterator`**, the window member of the 3.0
iterator family — a sibling of the [slab iterator](11_slab_iteration.md) and
the categorical (group-by) iterator; see the
[iterator family overview](21_iterator_family.md). Like them, it carries a broad
common surface of named reductions, plus an `each` / `reduce` escape hatch and a
few members of its own.

## Building a window

```ruby
a.windows(*ranges, bounds: :skip, fill_value: nil)
```

You give **one offset range per axis**. Each range `lo..hi` describes the window
around an anchor cell `i`: the window spans `a[i+lo .. i+hi]`. So the window
width on that axis is `hi - lo + 1`, and where `lo`/`hi` sit relative to zero
decides whether the anchor is centred, leading, or trailing.

| call | width | shape of window | anchor sits at |
|---|---|---|---|
| `a.windows(-1..1)` | 3 | centred | the middle |
| `a.windows(-2..2)` | 5 | centred | the middle |
| `a.windows(0..2)`  | 3 | forward-looking | the left end |
| `a.windows(-2..0)` | 3 | backward-looking | the right end |

For an N-D array give **one range per axis** — a 2-D array needs two ranges:

```ruby
m.windows(-1..1, -1..1)          # a 3x3 window per cell
m.windows(-1..1, 0..0)           # a 3x1 vertical window (single column)
```

Passing the wrong number of ranges raises `ArgumentError`.

By default the output is shaped exactly like the source — one window, and so one
folded value, per cell. (The exception is `bounds: :truncate`, which drops the
edge anchors and shrinks the output; see below.)

## The common reduction surface

A window fold is applied to every cell's window. The named reductions are the
same family you already know from [Reduction and statistics](04_reduction_and_statistics.md),
now evaluated per window:

| family | methods |
|---|---|
| arithmetic | `sum` · `accumulate` · `prod` · `mean` |
| extrema | `min` · `max` · `minmax` |
| spread | `variance` · `stddev` (sample) · `variancep` · `stddevp` (population) |
| boolean | `all` · `any` |
| position | `min_index` · `max_index` (position *within the window*) |
| weighted | `wsum(weights)` · `wmean(weights)` |
| order statistics | `median` · `percentile(*p)` · `quantile` (see [below](#order-statistics)) |
| counting | `count` · `count_not_masked` · `count_masked` · `count(v)` · `elements` |
| generic | `each` · `reduce` (escape hatch) |

Each named reduction returns a source-shaped array (or a shrunk one under
`:truncate`). They all accept `min_count:` and `fill_value:`, described in
[Boundary strictness](#boundary-strictness-min_count--fill_value).

```ruby
a.windows(-1..1).sum
#  => [ 3.0, 6.0, 9.0, 12.0, 15.0, 18.0, 21.0, 15.0 ]

a.windows(-1..1, bounds: :nearest).max
#  => [ 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 8.0 ]
```

Two counts are worth distinguishing:

* **`elements`** is the constant window size (`Π wᵢ`) — a structural number that
  does not depend on the boundary or the mask.
* **`count_not_masked`** is the *effective* number of cells actually folded per
  window, which shrinks at a `:skip` edge. It is the renormalising denominator
  of a rolling average.

```ruby
a.windows(-1..1).elements            #  => [ 3, 3, 3, 3, 3, 3, 3, 3 ]
a.windows(-1..1).count_not_masked    #  => [ 2, 3, 3, 3, 3, 3, 3, 2 ]
```

Under the default `:skip`, `count` with no argument is `count_not_masked`.

## The boundary policy (`bounds:`)

At the edges a window reaches outside the array. `bounds:` chooses what fills
that margin. There are three policies, plus a constant-fill escape:

| `bounds:` | margin | output shape |
|---|---|---|
| `:skip` (**default**) | masked (`UNDEF`) — an edge window folds only its in-bounds cells | source shape |
| `:nearest` | the nearest edge cell replicated outward | source shape |
| `:truncate` | none — only fully in-bounds anchors are produced | shrinks to `Nᵢ − wᵢ + 1` per axis |
| `fill_value: v` | a constant `v` in the margin | source shape |

Take the same array and the same width-3 window through each:

```ruby
a = CArray.float64(8).seq(1)     #  => [ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0 ]

a.windows(-1..1).mean                       # :skip (default)
#  => [ 1.5, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 7.5 ]

a.windows(-1..1, bounds: :nearest).mean     # edge cell replicated
#  => [ 1.333..., 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 7.666... ]

a.windows(-1..1, bounds: :truncate).mean    # interior only, output shrinks
#  => [ 2.0, 3.0, 4.0, 5.0, 6.0, 7.0 ]

a.windows(-1..1, fill_value: 0.0).mean      # constant 0 margin
#  => [ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 5.0 ]
```

Read them off:

* **`:skip`** — cell 0's window `[·, 1, 2]` folds only the two present cells:
  `(1+2)/2 = 1.5`. The margin is masked, so the reduction skips it. This is the
  *renormalised* edge — the average of what is actually there.
* **`:nearest`** — cell 0's window becomes `[1, 1, 2]` (the first cell copied
  into the margin): `(1+1+2)/3 = 1.333…`. The margin holds a real value.
* **`:truncate`** — only anchors whose full window is in bounds survive, so cell
  0 and cell 7 are dropped and the output has 6 elements. No padding at all.
* **`fill_value: 0.0`** — cell 7's window is `[7, 8, 0]`: `(7+8+0)/3 = 5.0`. A
  constant margin.

`:truncate` shrinks the output, so its shape is `Nᵢ − wᵢ + 1` on each axis:

```ruby
a.windows(-1..1, bounds: :truncate).mean.shape    #  => [6]
```

There is no `:strict` policy. Every array has out-of-bounds edges, so a policy
that raised on any overhang would always raise; use `:truncate` to drop the
overhanging positions instead.

> **A note on the 3.0 default.** In CArray 2.0 an edge window used a
> **zero-filled** margin. In 3.0 the default is `:skip`, a masked margin, so an
> edge `mean` now renormalises over its present cells instead of dividing a
> zero-padded sum by the full width. To recover the old zero-fill behaviour,
> construct with `fill_value: 0.0`; for edge extension use `bounds: :nearest`.

## Boundary strictness (`min_count:` / `fill_value:`)

The window iterator has **no boundary-strictness machinery of its own**. Because
the default `:skip` margin is masked, the whole strictness spectrum — from "fold
whatever is present" to "full windows only" — falls out of the ordinary
reduction keywords `min_count:` and `fill_value:`, which flow straight through to
the core reduction (see [Masks and missing values](05_masks.md) for how these
keywords behave in general):

```ruby
a.windows(-1..1).mean                                 # fold whatever is present
#  => [ 1.5, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 7.5 ]

a.windows(-1..1).mean(min_count: 3)                   # require a full window
#  => [ _, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, _ ]

a.windows(-1..1).mean(min_count: 3, fill_value: 0.0)  # ... and fill the edges
#  => [ 0.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 0.0 ]
```

* **`min_count: k`** — a window with fewer than `k` present cells yields
  `UNDEF`. Setting `min_count:` to the window size means "full windows only" —
  the shape is kept but the edges are undefined.
* **`fill_value: v`** on a reduction call — replace an `UNDEF` *result* with `v`.

Note the two distinct roles of a fill value. At **construction** (`windows(...,
fill_value: v)`) it sets the *margin*. On a **reduction call**
(`mean(fill_value: v)`) it replaces an *undefined result*. They are independent
knobs.

## Weighted windows and bounded convolution

A **weighted** window fold is `out[i] = Σⱼ window[i][j] · weightⱼ`. Two pairs of
methods express it, differing only in convention.

`wsum` / `wmean` take a weight array shaped like a single window:

```ruby
a.windows(-1..1, bounds: :nearest).wsum(CA_FLOAT64([1, 2, 1]))
#  => [ 5.0, 8.0, 12.0, 16.0, 20.0, 24.0, 28.0, 31.0 ]

a.windows(-1..1, bounds: :nearest).wmean(CA_FLOAT64([1, 2, 1]))
#  => [ 1.25, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 7.75 ]
```

`correlate` / `convolve` do the same weighted sum but under the two standard
kernel conventions:

* **`correlate(kernel)`** computes `out[i] = Σⱼ a[i+j]·k[j]` — the kernel is
  applied **as-is, not flipped**. This is the image-processing / deep-learning
  sense of "convolution".
* **`convolve(kernel)`** flips the kernel on every axis first:
  `out[i] = Σⱼ a[i−j]·k[j]` — the signal-processing / mathematical convolution.

For a **symmetric** kernel (a box blur, a Gaussian, a Laplacian) the two are
identical. They differ only for an asymmetric kernel, such as a derivative:

```ruby
k = CA_FLOAT64([1.0, 0.0, -1.0])            # an asymmetric (derivative) kernel

a.windows(-1..1, bounds: :nearest).correlate(k)
#  => [ -1.0, -2.0, -2.0, -2.0, -2.0, -2.0, -2.0, -1.0 ]

a.windows(-1..1, bounds: :nearest).convolve(k)     # kernel flipped -> sign flips
#  => [ 1.0, 2.0, 2.0, 2.0, 2.0, 2.0, 2.0, 1.0 ]
```

The kernel must be shaped like one window (`w₁ × … × wₙ`); a mismatch raises
`ArgumentError`. In two dimensions the kernel is a small matrix:

```ruby
m   = CArray.float64(4, 4).seq(1)
lap = CA_FLOAT64([[0, -1, 0], [-1, 4, -1], [0, -1, 0]])   # Laplacian

m.windows(-1..1, -1..1, bounds: :nearest).correlate(lap)
#  => [ [ -5.0, -4.0, -4.0, -3.0 ],
#       [ -1.0,  0.0,  0.0,  1.0 ],
#       [ -1.0,  0.0,  0.0,  1.0 ],
#       [  3.0,  4.0,  4.0,  5.0 ] ]
```

For a zero-padded filter — the usual image-filter boundary — construct the
iterator with `fill_value: 0.0`. A tap reaching outside the source then
contributes zero, which is exactly what a zero margin means, and it runs on the
faster unmasked path.

## Order statistics

`median`, `percentile`, and `quantile` need every value of a window held
together. The core order statistics they call have two constraints that shape
the surface here:

* they take a **single** axis, so for an N-D window CArray materialises the
  windows and flattens the window axes into one before the core call; and
* they **do not accept a masked input**, so the default `:skip` (a masked
  margin) is **rejected** — you must supply an unmasked margin.

```ruby
sig = CArray.float64(8).seq(1)

sig.windows(-2..2, bounds: :nearest).median      # edge-extended margin
#  => [ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0 ]

sig.windows(-2..2, bounds: :truncate).median     # interior only, output shrinks
#  => [ 3.0, 4.0, 5.0, 6.0 ]
```

Calling an order statistic under the default `:skip` raises with a pointer to
the fix:

```ruby
sig.windows(-2..2).median
#  ArgumentError: windowed order statistics need an unmasked margin;
#  use bounds: :nearest (edge-extend) or bounds: :truncate (valid).
#  For an UNDEF-margin median use reduce { |w| w.median } (slower).
```

`percentile` follows the usual `CArray#percentile` rules — one argument returns
one array, several return an array of arrays — and `quantile` returns the
five-number summary `[min, Q1, median, Q3, max]`.

## Position within a window

`min_index` / `max_index` report *where in the window* the extremum sits — an
offset in `0 … windowsize-1`, not a source address:

```ruby
a.windows(-1..1, bounds: :nearest).max_index
#  => [ 2, 2, 2, 2, 2, 2, 2, 1 ]
```

Every interior window rises across `[i-1, i, i+1]`, so the maximum is at offset
`2`; the last window `[7, 8, 8]` peaks at offset `1`.

There is **no `map`** and **no `sort_addr`** on a window iterator. Overlapping
windows share cells, so an element-wise transform has no well-defined
scatter-back, and a window's padded margin cells have no source address to
return from a sort. Both raise `NotImplementedError` explaining why. (The single
winning cell of `min_addr` / `max_addr` *is* a real source cell, so those are
fine.)

## Generic iteration — `each` and `reduce`

For a statistic not in the named surface, `each` and `reduce` hand you each
window directly. They are the slow, general path — a per-window materialise — so
prefer a named reduction or `correlate` when one fits.

`each` yields each anchor's window as a CArray (an Enumerator without a block):

```ruby
a = CArray.float64(6).seq(1)

a.windows(-1..1, bounds: :truncate).each.map { |w| w.to_a }
#  => [ [1.0, 2.0, 3.0], [2.0, 3.0, 4.0], [3.0, 4.0, 5.0], [4.0, 5.0, 6.0] ]
```

`reduce` folds each window to one value, producing a source-shaped result — the
escape hatch for a custom rolling statistic:

```ruby
a.windows(-1..1, bounds: :truncate).reduce { |w| w.max - w.min }   # rolling range
#  => [ 2.0, 2.0, 2.0, 2.0 ]
```

`reduce(init) { |acc, x| ... }` is the element-wise inject form, the same shape
of API as `reduce_slab` in [Slab iteration](11_slab_iteration.md).

## Masks

A `:skip` margin is *itself* expressed as a mask: the padded margin cells are
`UNDEF`, and the core reduction skips them — which is why `:skip` "folds only
what is present". Any mask already on the source rides along the same way, so an
edge window with genuinely-missing source cells simply folds fewer of them. See
[Masks and missing values](05_masks.md) for how the reductions treat `UNDEF`.

The one place this interacts with the surface is order statistics: they cannot
take a masked input, so they reject the `:skip` margin (above). Everything else —
`sum`, `mean`, `min`, `variance`, `count_not_masked`, `correlate` — is fully
mask-aware and needs no special handling.

## A few worked examples

### Moving average

```ruby
series = CArray.float64(10).seq(1)

series.windows(-2..2).mean                      # width-5, renormalised edges
series.windows(-2..2, bounds: :nearest).mean    # width-5, edges extended
series.windows(-2..2, bounds: :truncate).mean   # width-5, valid interior only
```

Reach for `:skip` when the *renormalised* edge (dividing by the cells that
exist) is what you mean; reach for `:nearest` / `:truncate` / `fill_value:` when
you want an unmasked fast path and can accept edge extension, a shrunk output, or
a constant margin.

### A smoothing (box-blur) kernel

```ruby
img = CArray.float64(4, 4).seq(1)
box = CArray.float64(3, 3) { 1.0 / 9.0 }        # 3x3 averaging kernel

img.windows(-1..1, -1..1, bounds: :nearest).correlate(box)
#  a smoothed image, edges extended
```

### A zero-padded FIR filter

```ruby
signal = CArray.float64(64).random!
fir    = CA_FLOAT64([0.1, 0.2, 0.4, 0.2, 0.1])  # a low-pass tap set

signal.windows(-2..2, fill_value: 0.0).convolve(fir)
```

## See also

* [Iterator family](21_iterator_family.md) — the overview of `windows`,
  `each_slab`, and the categorical iterator.
* [Slab iteration](11_slab_iteration.md) — the non-overlapping, per-axis sibling.
* [Reduction and statistics](04_reduction_and_statistics.md) — the named
  reductions the window folds delegate to, and `min_count:` / `fill_value:`.
* [Masks and missing values](05_masks.md) — `UNDEF`, and how a masked margin is
  folded.
* Full reference: `CAWindowIterator.md` — design
  rationale, the boundary/`min_count` unification, and performance guidance.
