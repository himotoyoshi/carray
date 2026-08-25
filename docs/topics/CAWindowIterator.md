# CAWindowIterator — rolling reductions and bounded convolution (`windows`)

`a.windows(*ranges)` returns a **`CAWindowIterator`** that rolls a window over
every cell of `a`. Its reduction methods (`sum`, `mean`, `min`, `median`, …)
fold each cell's window to one value, so the result is shaped like `a` — a
*rolling* (moving-window) result. `correlate` / `convolve` do the weighted
version, i.e. bounded convolution (image filters, FIR filters, smoothing).

It is the **window member of the 3.0 iterator family**, a sibling of
[`CASlabIterator`](SlabIterator.md) and
[`CACategoricalIterator`](CACategoricalIterator.md). Where a slab iterator folds
each non-overlapping slab, a window iterator folds an **overlapping** window
centred on every anchor cell.

```ruby
require "carray"

a = CArray.float64(8).seq(1)          # [1, 2, 3, 4, 5, 6, 7, 8]

a.windows(-1..1).mean                 # rolling mean, width-3 window
#=> [1.5, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 7.5]   (edges fold fewer cells)

a.windows(-1..1).correlate(CA_FLOAT64([0.25, 0.5, 0.25]))
#=> [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 5.75]  smoothing filter
```

## How the engine works

The iterator builds a **padded copy** of the source once (the source in the
interior, the margins filled by the boundary policy), takes its
[`sliding_windows`](../../ext/ca_obj_stride.c) view (a zero-copy strided view of
every window), and runs one vectorized core reduction over the trailing window
axes. So a named reduction is a single pass over a strided view — much faster
than folding each window one at a time, and the reduction inherits the core
`dtype` / mask / empty / epsilon contracts unchanged.

The practical consequence — which drives the [performance guidance](#performance-and-recommended-settings)
below — is that the iterator itself adds essentially **no** overhead over
`sliding_windows` + a core reduction; the only costs on top are the one-time
pad copy and, for a masked margin, the mask-aware reduction path.

## Construction and window geometry

```ruby
a.windows(*ranges, bounds: :skip, fill_value: nil)
```

Each `ranges[i]` is a `lo..hi` **offset range** around the anchor cell on axis
`i`. For anchor `i`, the window covers `a[i+lo .. i+hi]`:

| call | window | anchor position |
|---|---|---|
| `a.windows(-1..1)` | width 3, centred | middle |
| `a.windows(-2..2)` | width 5, centred | middle |
| `a.windows(0..2)` | width 3, forward-looking | left end |
| `a.windows(-2..0)` | width 3, backward-looking | right end |

For an N-D array give one range per axis: `img.windows(-1..1, -1..1)` is a 3×3
window. The output is shaped like the source (one window per cell).

## Boundary policy (`bounds:`)

At the edges a window reaches outside the array. `bounds:` chooses what happens
there:

| `bounds:` | margin | output shape | notes |
|---|---|---|---|
| `:skip` (**default**) | masked (UNDEF) | source shape | an edge window folds only its in-bounds cells |
| `:nearest` | edge cell replicated | source shape | margins are real values (edge extension) |
| `:truncate` | none (no padding) | shrinks to `Nᵢ − wᵢ + 1` per axis | only fully in-bounds windows; zero-copy |
| `fill_value: v` | constant `v` | source shape | a constant margin (e.g. `fill_value: 0.0`) |

`:strict` from 2.0's `window` is **not** offered here: every array has out-of-
bounds edges, so it would always raise. Use `:truncate` to drop the overhanging
positions instead.

With the default `:skip`, an edge window's out-of-bounds cells are masked, so the
core reduction simply skips them — `mean` averages the available cells, `count`
reports the effective (shrinking) window size, and so on.

### Boundary strictness — `min_count:` / `fill_value:`

Because `:skip` masks the margin, the whole *strictness* spectrum falls out of
the ordinary core-reduction keywords, passed straight through:

```ruby
a.windows(-1..1).mean                                    # fold whatever is present
#=> [1.5, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 7.5]

a.windows(-1..1).mean(min_count: 3)                      # require a full window
#=> [UNDEF, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, UNDEF]

a.windows(-1..1).mean(min_count: 3, fill_value: 0.0)     # ... and fill the edges
#=> [0.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 0.0]
```

- `min_count: k` — a window with fewer than `k` present cells yields `UNDEF`.
  `min_count: <window size>` means "full windows only".
- `fill_value: v` — replace an `UNDEF` **result** with `v`.

(Note the two roles of a fill value: `fill_value:` at **construction** sets the
*margin*; `fill_value:` on a **reduction call** replaces an *undefined result*.)

## Named reductions

Every named reduction folds each window to one value and returns a source-shaped
array (or a shrunk one under `:truncate`):

| family | methods |
|---|---|
| arithmetic | `sum` `prod` `mean` |
| extrema | `min` `max` `minmax` |
| spread | `variance` `stddev` (sample) · `variancep` `stddevp` (population) |
| boolean | `all` `any` |
| position | `min_index` `max_index` (index within the window) |
| weighted | `wsum(weights)` `wmean(weights)` (weights shaped like one window) |
| order statistics | `median` `percentile(*p)` `quantile` — see [below](#order-statistics) |
| counting | `count` / `count_not_masked` / `count_masked` / `count(v)` · `elements` |

`elements` is the (constant) window size; `count_not_masked` is the effective
number of in-bounds cells per window (the renormalizing denominator). All
reductions accept `min_count:` / `fill_value:`.

## Bounded convolution — `correlate` / `convolve`

A windowed **weighted** sum. The kernel has the shape of one window.

```ruby
img = CArray.float64(100, 100).random!
lap = CA_FLOAT64([[0, -1, 0], [-1, 4, -1], [0, -1, 0]])   # Laplacian

img.windows(-1..1, -1..1).correlate(lap)     # cross-correlation (kernel as-is)
img.windows(-1..1, -1..1).convolve(lap)       # convolution (kernel flipped)
```

- **`correlate`** computes `out[i] = Σⱼ a[i+j]·k[j]` — the kernel is **not**
  flipped. This is the image-processing / deep-learning "convolution".
- **`convolve`** flips the kernel on every axis first: `out[i] = Σⱼ a[i−j]·k[j]`
  — the signal-processing / mathematical convolution. For a **symmetric** kernel
  (box blur, Gaussian, Laplacian) the two are identical; they differ only for an
  asymmetric kernel (a derivative, a Sobel edge).

For a zero-padded filter (the usual image-filter boundary), construct the
iterator with `fill_value: 0.0` — see the [performance note](#performance-and-recommended-settings),
it is both correct and faster than the default `:skip`.

## Order statistics

`median` / `percentile` / `quantile` need every value of a window held together.
Two constraints of the core order statistics shape the surface:

- they take a **single** axis, so a multi-axis (N-D) window is materialized and
  its window axes flattened into one before the core call;
- they do **not** accept a masked input, so the default `:skip` (masked margin)
  is **rejected** with a message. Use an **unmasked** margin:

```ruby
sig.windows(-2..2, bounds: :nearest).median      # edge-extended
sig.windows(-2..2, bounds: :truncate).median     # interior only, output shrinks
sig.windows(-2..2).median                         # raises: :skip has a masked margin
```

(When the core gains masked per-axis order statistics this restriction lifts and
`:skip` will work directly.)

## Generic iteration — `each` / `reduce`

The escape hatch for a statistic not in the named surface. These yield each
window, so they are the slow, general path (use a named reduction or
`correlate` for speed):

```ruby
a.windows(-1..1).each { |window| ... }        # side effects; Enumerator without a block
a.windows(-1..1, bounds: :truncate).reduce { |window| window.max - window.min }
```

`reduce { |window| ... }` folds each window to one value (a source-shaped
result); `reduce(init) { |acc, x| ... }` is the element-wise fold.

There is **no `map`**: windows overlap, so an element-wise scatter back to the
source is ill-defined. Calling it is a `NoMethodError`.

## Performance and recommended settings

The dominant cost is the core reduction over the `sliding_windows` view. The
iterator layer adds essentially nothing on top of it; the only extra costs are
the one-time **pad copy** (all source-shaped modes) and, for the default
`:skip`, the **mask-aware reduction path**. Measured on one machine (1-D, 1M
cells, width-3 rolling mean — absolute numbers are machine-specific, the *ratios*
are the point):

| path | time | vs. bare `sliding_windows` |
|---|---:|---|
| `a.sliding_windows(3).mean(axis: 1)` (bare) | 7.4 ms | — |
| `windows(…, bounds: :truncate).mean` | 7.4 ms | same (no wrapper overhead) |
| `windows(…, bounds: :nearest).mean` | 8.1 ms | + ~10 % (pad copy) |
| `windows(…).mean` (`:skip`, default) | 11.3 ms | + ~50 % (pad + masked reduction) |

So `:skip` buys the "fold only what's in bounds" semantics at the price of the
masked reduction path; `:nearest` and `:truncate` run on the plain unmasked
(SIMD) path.

### Recommended setting by application

| what you want | setting | why |
|---|---|---|
| **Moving average / smoothing**, edges use available cells (window shrinks at the border) | `bounds: :skip` (default) | the correct renormalized edge; accepts the mask-path cost |
| **Moving average**, fast, edges extended (no shrink) | `bounds: :nearest` | unmasked → no mask-path cost, edge value repeated |
| **Interior only** / valid mode, fastest, output may shrink | `bounds: :truncate` | identical to bare `sliding_windows`; zero-copy |
| **Full-window-only** but keep the shape (edges undefined) | `:skip` + `min_count: <window size>` (`+ fill_value:`) | edges → `UNDEF` (or a fill) instead of a shorter fold |
| **Zero-padded convolution** (image / FIR filters) | construct with `fill_value: 0.0`, then `correlate` / `convolve` | same result as the `:skip` default but ~20 % faster (unmasked 0-margin vs the masked path — a 0 tap and a skipped tap are equal in a sum) |
| **Edge-extended convolution** | `bounds: :nearest`, then `correlate` / `convolve` | replicates the edge instead of zero |
| **Median / percentile filter** | `bounds: :nearest` or `:truncate` | order statistics require an unmasked margin (`:skip` raises) |

Rule of thumb: reach for `:skip` when the *renormalized* edge (dividing by the
available cells) is what you mean; reach for `:nearest` / `:truncate` /
`fill_value:` when you want the unmasked fast path and can accept edge extension,
a shrunk output, or a constant margin.

## Migration from 2.0

In 2.0, `a.windows(-1..1)` used a **zero-filled** margin. In 3.0 the default is
`:skip` (a masked margin), so an edge window now folds only its in-bounds cells,
and `.each` yields boundary windows whose margin cells are masked (not `0`). For
the old zero-fill behaviour construct with `fill_value: 0.0`; for edge extension
use `bounds: :nearest`.

## See also

- [`SlabIterator.md`](SlabIterator.md) — the non-overlapping (per-axis slab) sibling.
- [`CACategoricalIterator.md`](CACategoricalIterator.md) — the group-by sibling.
