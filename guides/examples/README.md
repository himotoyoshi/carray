# Examples

Runnable scripts that show CArray in use. Each file is a standalone Ruby script
that can be executed with `ruby <file>` and needs no external data.

## Where this fits

CArray's learning material is organised into three parallel sets. Each has a
different purpose; pick the one that matches what you want to do.

| Location             | Purpose                                       |
|----------------------|-----------------------------------------------|
| `docs/`              | Topic reference. Look up a term or feature.   |
| `guides/users/`      | User's Guide. Read through, chapter by chapter. |
| `guides/examples/`   | Runnable scripts. Read and run to see behaviour. |
| `samples/`           | Pattern collections and extension examples. Face subclasses, C extensions, IO helpers. |

The User's Guide and the examples here are meant to be used together. The guide
explains, the examples show the same material as code you can run.

## Running

From a checkout of the repository:

```
ruby -Iext -Ilib guides/examples/01_basics/01_creation.rb
```

With CArray installed as a gem:

```
ruby guides/examples/01_basics/01_creation.rb
```

Each script keeps to about a hundred lines. It starts with a short description,
sets up its own data, and prints the results next to the values you should see.
Reading the scripts in order builds up the vocabulary; each one stands on its
own and does not depend on earlier files.

## Chapters

### 01_basics — the essentials

The core vocabulary of CArray. Everything else assumes these.

- `01_creation.rb` — constructing arrays (`CArray.float64`, generator block,
  `seq`, `span`, `Array#to_ca`)
- `02_indexing.rb` — element access (`[i, j]`, slicing, boolean selection,
  assignment)
- `03_mask.rb` — missing values (`UNDEF`, `is_masked`, `mask_eq`, mask
  propagation)

Further chapters will be added over time. Where a chapter matches one in the
User's Guide, the corresponding script names its counterpart at the top.

### cookbook — short recipes that do something

Small self-contained scripts organised by task rather than by API. Each one
picks a common problem and shows how it looks in CArray.

- `moving_average.rb` — smooth a noisy signal with a windowed mean, no explicit
  for-loop
- `image_threshold.rb` — threshold an 8-bit image and dilate the result by
  combining shifted views
- `mandelbrot.rb` — the Mandelbrot set as a single expression applied to a 2-D
  grid of complex numbers
- `game_of_life.rb` — Conway's Game of Life: sum eight shifted views for the
  neighbour count, then boolean arithmetic for the birth-and-survival rule
- `sieve_of_eratosthenes.rb` — the classic sieve as boolean-index assignment;
  primes fall out in a few lines, and `cumsum` of the boolean gives the
  prime-counting function
- `daily_activity.rb` — a year of daily counts aggregated by month and by day
  of week, using `CATime` for the calendar (`.month`, `.weekday`),
  `.lookup` for readable labels, and `CACategorical` +
  `group_by_category` for the per-group means
- `histogram_ascii.rb` — `histogram1d` on three distributions rendered as
  vertical ASCII bells; the bar grid is built by broadcasting a
  `heights >= levels` boolean and printed with the same `then_else` +
  slab-reduce idiom as `image_threshold`
- `wave_1d.rb` — the 1-D wave equation on a fixed-end string. The
  Laplacian is `u.shift(-1) - 2 * u + u.shift(1)` and the leapfrog
  update advances the whole grid in one expression. A Gaussian pulse
  splits, travels, and reflects with a sign change at the ends
- `kmeans_2d.rb` — Lloyd's algorithm on a 2-D point cloud. Assignment
  is a single broadcast distance expression, the centroid update
  reuses `group_by_category(cat).mean`, and the final state renders
  on an ASCII grid via `scatter_replace!` + `.lookup(palette)`
- `random_walk.rb` — 500 independent one-dimensional walkers over 400
  steps, all in one CArray expression via `cumsum(axis: 1)`. Per-step
  `mean` / `stddev` along axis 0 draw a ±2σ envelope; the endpoint
  distribution matches the central-limit-theorem prediction
- `edge_detect.rb` — the Sobel edge detector as six shifted views
  combined with weights, per axis. `gx.abs2 + gy.abs2` is the squared
  gradient magnitude with no `sqrt`, thresholded against its own max
  to pick the strong edges

The cookbook has no reading order; browse by title and run whichever one looks
close to something you want to do.

#### Planned recipes

Candidates for future additions, kept here so the direction is visible.

- `word_count.rb` — a frequency table from `CAConstString` plus
  `group_by_category`.
- `sparse_scatter.rb` — scatter-add for counting collisions on a grid.
- `matrix_power.rb` — Fibonacci numbers via matrix exponentiation (uses
  `carray-linalg`).
- `mask_animation.rb` — a boolean pattern that moves over time, printed frame
  by frame.
