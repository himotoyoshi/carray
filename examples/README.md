# CArray examples

Runnable code. Every file here is a standalone Ruby script or a complete
extension; nothing is loaded from `lib/carray/`.

The prose documentation lives elsewhere and is organised by how you read it:

| Location        | Purpose                                          |
|-----------------|--------------------------------------------------|
| `docs/`         | Topic reference. Look up a term or a feature.    |
| `guides/users/` | User's Guide. Read through, chapter by chapter.  |
| `guides/devel/` | Developer's Guide. The internals.                |
| `examples/`     | This directory. Code to read and run.            |

## Running

From a checkout of the repository:

```sh
ruby -Iext -Ilib examples/gallery/game_of_life.rb
```

With CArray installed as a gem, drop the `-I` flags. Every script sets up its
own data and needs nothing from outside.

---

## Learning the API

### `basics/` — the essentials

The core vocabulary. Everything else assumes it. Each script prints results
next to the values you should see, and stands on its own.

- `01_creation.rb` — constructing arrays (`CArray.float64`, generator block,
  `seq`, `span`, `Array#to_ca`)
- `02_indexing.rb` — element access (`[i, j]`, slicing, boolean selection,
  assignment)
- `03_mask.rb` — missing values (`UNDEF`, `is_masked`, `mask_eq`, mask
  propagation)

These are fragments: each one shows a part of the API rather than finishing a
job. Where one matches a chapter of the User's Guide, it names its counterpart
at the top.

### `gallery/` — whole programs ([README](gallery/README.md))

A script here runs from beginning to end and produces a result worth looking
at. Read one in a sitting and you come away with a working program, not a
list of methods. Some show off how short CArray's answer is, some walk through
how a thing is done; both belong, as long as the script is a whole.

- `moving_average.rb` — smooth a noisy signal with a windowed mean, no explicit
  for-loop
- `image_threshold.rb` — threshold an 8-bit image and dilate the result by
  combining shifted views
- `mandelbrot.rb` — the Mandelbrot set as a single expression applied to a 2-D
  grid of complex numbers
- `game_of_life.rb` — Conway's Game of Life: a 3x3 window sum for the
  neighbour count, then boolean arithmetic for the birth-and-survival rule
- `sieve_of_eratosthenes.rb` — the classic sieve as boolean-index assignment;
  primes fall out in a few lines, and `cumsum` of the boolean gives the
  prime-counting function
- `sieve_of_eratosthenes_masked.rb` — the same sieve written with the mask
- `daily_activity.rb` — a year of daily counts aggregated by month and by day
  of week, using `CATime` for the calendar (`.month`, `.weekday`), `.lookup`
  for readable labels, and `CACategorical` + `group_by_category` for the
  per-group means
- `histogram_ascii.rb` — `histogram1d` on three distributions rendered as
  vertical ASCII bells; the bar grid is built by broadcasting a
  `heights >= levels` boolean
- `wave_1d.rb` — the 1-D wave equation on a fixed-end string. The Laplacian is
  `u.shift(-1) - 2 * u + u.shift(1)` and the leapfrog update advances the whole
  grid in one expression. A Gaussian pulse splits, travels, and reflects with a
  sign change at the ends
- `kmeans_2d.rb` — Lloyd's algorithm on a 2-D point cloud. Assignment is a
  single broadcast distance expression, the centroid update reuses
  `group_by_category(cat).mean`, and the final state renders on an ASCII grid
  via `scatter_replace!` + `.lookup(palette)`
- `random_walk.rb` — 500 independent one-dimensional walkers over 400 steps,
  all in one CArray expression via `cumsum(axis: 1)`. Per-step `mean` /
  `stddev` along axis 0 draw a ±2σ envelope; the endpoint distribution matches
  the central-limit-theorem prediction
- `edge_detect.rb` — the Sobel edge detector as six shifted views combined with
  weights, per axis. `gx.abs2 + gy.abs2` is the squared gradient magnitude with
  no `sqrt`, thresholded against its own max to pick the strong edges

There is no reading order. Browse by title.

---

## Defining your own array type (Ruby)

Two halves of one shelf. A Face puts a meaning on storage CArray already
holds; a CAObject stands in for storage that lives somewhere else entirely.

### `face/` — Face subclasses ([README](face/README.md))

Semantic-type views: the storage stays what it is, and the Face decides what
the values *mean* (see [CAFace.md](../docs/topics/CAFace.md)). A Ruby Face
with `face: true` writes no storage callbacks at all, which is what these
samples demonstrate.

- `ca_circular.rb` — angles: a circular range plus circular statistics
- `ca_fixed_point.rb` — fixed-point numbers over an integer store
- `ca_geocoord.rb` — a composite Face on `CARecord`

### `caobject/` — callback-based views ([README](caobject/README.md))

`CAObject` lets the authoritative store live outside CArray — a nested Ruby
Array, another gem's buffer, or a rule that computes values on demand. This is
the prototype path: write it in Ruby first, move it to C when it outgrows
that ([CAObject.md](../docs/topics/CAObject.md) §7).

- `nested.rb` — a rectangular nested Ruby Array as the store. Defines the
  **full template set** (`fetch_index` / `store_index` / `fetch_addr` /
  `store_addr` / `copy_data` / `sync_data` / `fill_data` / `create_mask`), so
  it works on every access path. Read this one first
- `link.rb` — a reactive view: reads recompute through a block evaluator
- `pack.rb` — multi-parent assembly, N arrays packed behind a leading axis
- `recurrence.rb` — a lazily evaluated recurrence

---

## Writing your own extension (C)

### `c-extensions/`

Complete extensions that use CArray's public C author surface. Each
subdirectory is a whole ext (`extconf.rb` + `.c` + `example.rb`) that an
external author can copy as a starting point, and each is mirrored as a
regression fixture under `spec/spec_ai/`. See
[`c-extensions/README.md`](c-extensions/README.md).

---

## What these are, and are not

- **Not part of the library.** Nothing here is loaded from `lib/carray/`. Copy
  from it, or take it as a starting point.
- **They run.** Each one works as written; the quality bar is close to a test.
- **They teach.** The docs cross-reference them, and they are the reference to
  read before writing a Face or a view of your own.
- **They are where extensions grow up.** A useful type that does not earn a
  place in the library can live here first.
