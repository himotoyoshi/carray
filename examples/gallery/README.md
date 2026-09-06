# Gallery

Whole programs. Each script here runs from beginning to end and produces a
result worth looking at — a picture, a table, a distribution — rather than
demonstrating one method. Read one in a sitting and you come away with a
working program.

Some pieces show off how short CArray's answer to a classic problem is; some
walk through how a thing is done. Both belong. The one thing every piece has
in common is that it is **whole**: it sets up its own data, does the work, and
prints something.

For the API itself, one piece at a time, see [`../basics/`](../basics/).

## Running

```sh
ruby -Iext -Ilib examples/gallery/game_of_life.rb
```

With CArray installed as a gem, drop the `-I` flags. Nothing here needs
external data, and nothing needs a gem beyond CArray itself; every result is
printed as text.

There is no reading order. Browse by title.

## The pieces

### Neighbourhoods — shifted views and windows

- **`game_of_life.rb`** — Conway's Game of Life. A 3x3 window sum
  (`windows(-1..1, -1..1).sum`) gives the neighbour count, then boolean
  arithmetic gives the birth-and-survival rule.
- **`wave_1d.rb`** — the 1-D wave equation on a fixed-end string. The
  Laplacian is `u.shift(-1) - 2 * u + u.shift(1)`, and the leapfrog update
  advances the whole grid in one expression. A Gaussian pulse splits,
  travels, and reflects with a sign change at the ends.
- **`edge_detect.rb`** — the Sobel edge detector as six shifted views combined
  with weights, per axis. `gx.abs2 + gy.abs2` is the squared gradient
  magnitude with no `sqrt`, thresholded against its own max.
- **`image_threshold.rb`** — threshold an 8-bit image, then dilate the result
  by combining shifted views.
- **`moving_average.rb`** — smooth a noisy signal with a windowed mean, no
  explicit for-loop.

### Boolean and mask

- **`sieve_of_eratosthenes.rb`** — the classic sieve as boolean-index
  assignment. The primes fall out in a few lines, and `cumsum` of the boolean
  gives the prime-counting function.
- **`sieve_of_eratosthenes_masked.rb`** — the same sieve written with the
  mask instead, for the contrast.

### Grouping and categories

- **`daily_activity.rb`** — a year of daily counts aggregated by month and by
  day of week. `CATime` supplies the calendar (`.month`, `.weekday`),
  `.lookup` the readable labels, and `CACategorical` + `group_by_category`
  the per-group means.
- **`kmeans_2d.rb`** — Lloyd's algorithm on a 2-D point cloud. Assignment is
  a single broadcast distance expression, the centroid update reuses
  `group_by_category(cat).mean`, and the final state renders on an ASCII grid.

### Distributions

- **`random_walk.rb`** — 500 independent walkers over 400 steps, all in one
  expression via `cumsum(axis: 1)`. Per-step `mean` / `stddev` along axis 0
  draw a ±2σ envelope, and the endpoint distribution matches the
  central-limit-theorem prediction.
- **`histogram_ascii.rb`** — `histogram1d` on three distributions rendered as
  vertical ASCII bells. The bar grid comes from broadcasting a
  `heights >= levels` boolean.

### Iteration on a grid

- **`mandelbrot.rb`** — the Mandelbrot set as a single expression applied to a
  2-D grid of complex numbers.

## Idioms you will keep seeing

The gallery is where the everyday vocabulary shows up in use rather than in
isolation. These recur across the pieces:

| idiom | what it replaces | seen in |
|---|---|---|
| `then_else(a, b)` | a per-element `if` | 6 of the 12 |
| `.shift(±1)` on an axis | neighbour indexing with bounds checks | `wave_1d`, `edge_detect`, `image_threshold` |
| `.windows(range, ...)` | a nested loop over a neighbourhood | `game_of_life`, `moving_average` |
| `.lookup(table)` | a per-element map to characters or labels | `mandelbrot`, `image_threshold`, `kmeans_2d`, `daily_activity` |
| `.abs2` | `x.re**2 + x.im**2`, or a `sqrt` you did not need | `mandelbrot`, `edge_detect`, `kmeans_2d` |
| `cumsum(axis:)` | an accumulator loop | `random_walk`, both sieves |
| `group_by_category(cat)` | a hash of arrays, then a loop per key | `daily_activity`, `kmeans_2d` |

## Adding a piece

The bar is that it is a whole program — it stands alone, sets up its own data,
and ends with output someone would want to look at. Keep it inside a hundred
lines, print the results next to what the reader should expect, and prefer the
tightest form CArray offers: the gallery is also where readers learn which
method to reach for.
