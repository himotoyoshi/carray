# Scatter and Bincount

CArray has two closely related primitives for **write-side aggregation** —
depositing many values into a few target cells, keyed by integer
addresses. Both are the "inverse" of gather (`self[addrs]` reading):
they *write* to `addrs`, and duplicate addresses fold into the same
cell via a chosen reduction.

| primitive | address model | reduction | typical shape |
|---|---|---|---|
| `CArray#scatter_add!` / `_sub!` / `_mul!` / `_min!` / `_max!` / `_replace!` | flat 1-D addresses into `self` | in-place, any numeric type | scratchpad-shaped `self`, len-N `addrs` and `vals` |
| `CArray#bincount` | non-negative integer labels | counts (or weighted sum) per label | 1-D output sized `max(label)+1` |
| `CArray#bincount_nd` | M-tuple of integer labels | joint counts / weighted sum | fiber-shape × per-dim lengths |

The `scatter_*!` family is the low-level building block: you own the
scratch array, you choose the reduction, and you write in place. The
`bincount` / `bincount_nd` methods are the packaged special cases when
the reduction is "count" (or a weighted sum) and the addresses are
integer *labels* — they build the target for you and pick fast
per-shape kernels.

Everything in this guide works after `require "carray"`.

---

## 1. `scatter_*!` — mutate `self[addrs[i]]` in place

Signature (all six):

```ruby
self.scatter_add!(addrs, vals)      # self[addrs[i]] += vals[i]
self.scatter_sub!(addrs, vals)      # self[addrs[i]] -= vals[i]
self.scatter_mul!(addrs, vals)      # self[addrs[i]] *= vals[i]
self.scatter_min!(addrs, vals)      # self[addrs[i]] = min(..., vals[i])
self.scatter_max!(addrs, vals)      # self[addrs[i]] = max(..., vals[i])
self.scatter_replace!(addrs, vals)  # self[addrs[i]]  = vals[i]  (last-write-wins)
```

- `self` — any numeric CArray. The target is treated as a flat 1-D buffer
  of length `self.elements`; multi-dimensional targets work through their
  flat address space (`i0 * s0 + i1 * s1 + …`, C-order).
- `addrs` — a CArray of any integer type (coerced to `CA_SIZE`) or a
  Ruby `Array`. Values must be in `0 ... self.elements` — out-of-range
  raises `IndexError`.
- `vals` — a CArray with `vals.elements == addrs.elements`, coerced to
  `self.data_type`, or a Numeric scalar broadcast to every address.

### 1.1 Duplicate addresses accumulate (sequential, unbuffered)

The `_add` / `_sub` / `_mul` / `_min` / `_max` variants **fold every
occurrence** of a repeated address:

```ruby
buf   = CA_INT32([0, 0, 0, 0, 0])
addrs = CA_INT32([0, 2, 0, 2, 2])
vals  = CA_INT32([1, 1, 1, 1, 1])
buf.scatter_add!(addrs, vals)
buf.to_a                           # => [2, 0, 3, 0, 0]
```

This is the crucial difference from `self[addrs] = vals`, which is
**last-write-wins** — duplicates overwrite each other and only the final
pair survives. `scatter_replace!` is the fast in-place spelling of that
last-write semantics:

```ruby
buf = CA_INT32([0, 0, 0])
buf.scatter_replace!([0, 0, 1], [10, 20, 30])
buf.to_a                           # => [20, 30, 0]  (last write at 0 wins)
```

### 1.2 NaN / missing-value rule

Only `scatter_min!` / `scatter_max!` on **float** data types use the fmin /
fmax rule (NaN is treated as missing): `min(NaN, v) → v`,
`min(x, NaN) → x`. Every other variant follows plain C arithmetic —
NaN propagates through `_add` / `_sub` / `_mul`, integer overflow wraps.

### 1.3 Mask policy

The accumulate family (`_add` / `_sub` / `_mul` / `_min` / `_max`)
**skips the pair** whenever any of `addrs[i]`, `vals[i]`, or the target
`self[addrs[i]]` is masked. "Unknown source can't accumulate", "unknown
target stays unknown".

`scatter_replace!` follows the indexer contract instead: a valid `vals[i]`
overwrites the target *and* clears its mask bit; a masked `vals[i]` flips
the target to masked.

### 1.4 Why not just `self[addrs] += vals`?

`self[addrs] += vals` looks like scatter-add, but it is
`self[addrs] = self[addrs] + vals` — a gather, then an add, then a
last-write scatter. Duplicate addresses collapse to whichever pair is
written last.

Choose based on address distribution:

- addresses guaranteed unique → `self[addrs] = self[addrs] + vals` or
  `scatter_replace!` (both correct, `scatter_replace!` faster);
- duplicates possible and you want them to fold → the accumulate family.

---

## 2. `bincount` — 1-D discrete counting

```ruby
labels = CA_INT32([0, 1, 1, 2, 0, 1])
labels.bincount                    # => CA_UINT32([2, 3, 1])
```

Rules:

- `self` must be an integer data type (any width). Labels are the *value*,
  not the position — `bincount` reads them as bin indices.
- Output length is `max(length, self.max + 1)` where `length:` is an
  optional lower bound: use it when downstream code needs a fixed
  vocabulary size:

  ```ruby
  labels.bincount(length: 5)       # => CA_UINT32([2, 3, 1, 0, 0])
  ```

- The output data type is `CA_UINT32` (or `CA_UINT64` when the length exceeds
  2³²). It inherits the *weights* data type in the weighted form.

- Negative labels raise `ArgumentError`. Masked labels are silently
  skipped (not counted). Masked weights are skipped too — their label
  contributes zero.

### 2.1 Weighted sum per label

`weights:` turns counting into a per-label sum:

```ruby
labels  = CA_INT32([0, 1, 1, 2, 0, 1])
weights = CA_DOUBLE([1, 2, 3, 4, 5, 6])
labels.bincount(weights: weights)  # => CA_DOUBLE([6, 11, 4])
```

The output has the *weights* data type so the accumulator doesn't lose
precision.

### 2.2 Relationship to `scatter_add!`

`bincount` is exactly this, but faster and safer:

```ruby
out = CA_UINT32(k).fill(0)
out.scatter_add!(labels, 1)          # counts
```

```ruby
out = CA_DOUBLE(k).fill(0)
out.scatter_add!(labels, weights)    # weighted sum
```

Use the `bincount` surface when the reduction *is* count/weighted-sum
over a 1-D label space; use `scatter_*!` when you want a different
reduction, an explicit scratchpad, or in-place accumulation across
many chunks.

---

## 3. `bincount_nd` — joint discrete counting

```ruby
data.bincount_nd(lengths: [L_0, ..., L_{M-1}], axis: [-2, -1], weights: w)
```

- Input layout: `fiber_shape + (A,) + (M,)` — the same "fiber, sample,
  channel" model as `histogram` (see [Histogram.md](Histogram.md)).
- The trailing channel axis of length `M` carries the M integer labels
  of each sample.
- The sample axis (length `A`) is reduced.
- Each fiber position gets an independent joint count.

Returns a `CArray::BincountND` accumulator (streaming and composable via
`add` and `+`). Storage is `fiber_shape + (L_0 + 1, …, L_{M-1} + 1)` —
one **upper-overflow cell** per dimension (labels `>= lengths[k]` fold
into it); negative labels raise.

```ruby
h = CA_INT32([[0, 1],
              [2, 0],
              [1, 1],
              [1, 1]]).bincount_nd(lengths: [3, 2])
h.counts.to_a           # => [[0, 1], [0, 2], [1, 0]]     (shape [3, 2])
h.total                 # => 4
```

Reach for `bincount_nd` when the reduction is a joint count over `M ≥ 2`
label channels *and* you want the natural rectangular output. When the
labels can be raveled to one integer (e.g. `code = row * n_cols + col`
with known `n_cols`), plain `bincount` is often equally fast and
returns a flat vector — but the ergonomic win of the M-D shape is real.

---

## 4. Applications

The rest of this document is a catalogue of concrete patterns. Each
example is self-contained.

### 4.1 Segment sum (group-by sum by integer key)

Sum `values` grouped by an integer `group_id` in `0..K-1`:

```ruby
values   = CA_DOUBLE([1.0, 2.5, 0.5, 4.0, 2.0, 3.0])
group_id = CA_INT32([0,   1,   0,   2,   1,   0])
k        = 3

out = CA_DOUBLE(k).fill(0)
out.scatter_add!(group_id, values)
out.to_a                              # => [4.5, 4.5, 4.0]
```

This is the group-by-sum core; `bincount(weights:)` is the packaged
form of the same idiom.

### 4.2 Group-by mean via numerator + denominator

Combine two scatters — sum of values into the numerator, count into the
denominator:

```ruby
num = CA_DOUBLE(k).fill(0)
den = CA_DOUBLE(k).fill(0)
num.scatter_add!(group_id, values)
den.scatter_add!(group_id, 1.0)      # broadcast scalar
mean = num / den
mean.to_a                             # => [1.5, 2.25, 4.0]
```

`bincount` alone would give you `den` (counts); pairing with a weighted
`bincount(weights: values)` for the numerator is exactly equivalent and
often cleaner.

### 4.3 Group-by min / max / product

```ruby
lo = CA_DOUBLE(k).fill(Float::INFINITY)
hi = CA_DOUBLE(k).fill(-Float::INFINITY)
lo.scatter_min!(group_id, values)
hi.scatter_max!(group_id, values)

prod = CA_DOUBLE(k).fill(1.0)
prod.scatter_mul!(group_id, values)
```

Groups untouched by any address keep their initial value (`+∞` / `-∞`
/ `1.0`), which is a natural identity element for the reduction.

### 4.4 Confusion matrix

Given per-sample predictions and truths in `0..K-1`, the flat address
into a `K × K` matrix is `truth * K + pred`:

```ruby
k        = 4
truth    = CA_INT32([0, 1, 2, 2, 3, 0, 1, 1, 2, 3])
pred     = CA_INT32([0, 1, 2, 1, 3, 0, 2, 1, 2, 3])
addr     = truth * k + pred

confusion = CA_INT64(k, k).fill(0)
confusion.scatter_add!(addr, 1)
```

`bincount_nd(lengths: [K, K])` on `stack([truth, pred], axis: 1)` gives
you the same table without the manual ravel.

### 4.5 One-hot encoding

Turn a length-N label vector into an `N × K` matrix with a single 1 per
row:

```ruby
labels = CA_INT32([0, 2, 1, 2])
k      = 3
n      = labels.elements

onehot = CA_UINT8(n, k).fill(0)
row    = CA_INT32(n).seq             # [0, 1, 2, 3]
addr   = row * k + labels            # flat address of the "1" per row
onehot.scatter_replace!(addr, 1)
```

Because each row's "1" address is unique, `scatter_replace!` is the
right variant (fast, unambiguous).

### 4.6 COO → dense sparse tensor

An unordered stream of `(row, col, value)` triples with possible
duplicates — assemble a dense matrix that sums coincident entries:

```ruby
n_rows = 5
n_cols = 5
row    = CA_INT32([0, 1, 2, 2, 4])
col    = CA_INT32([1, 3, 2, 2, 0])
val    = CA_DOUBLE([1.0, 2.0, 3.0, 4.0, 5.0])

dense = CA_DOUBLE(n_rows, n_cols).fill(0)
dense.scatter_add!(row * n_cols + col, val)
```

The `(2, 2)` cell holds `3.0 + 4.0 = 7.0` — that is the whole point of
the accumulate variant.

### 4.7 Rasterisation / image splatting

Draw a batch of coloured points onto an image, letting overlaps
accumulate (motion blur / density splat) or replace (paint):

```ruby
h = 480; w = 640
img = CA_FLOAT32(h, w).fill(0)

# points (x, y) with intensity
x  = CA_INT32([10, 20, 10, 100])
y  = CA_INT32([50, 50, 50, 300])
iy = CA_FLOAT32([1.0, 0.7, 0.5, 0.3])

img.scatter_add!(y * w + x, iy)      # accumulate overlaps (splat)
```

For **maximum-intensity projection** swap in `scatter_max!`; for a
plain paint use `scatter_replace!`.

### 4.8 Hough-style voting

Every input feature votes into every candidate parameter cell it
supports. Vote counts are just a scatter-add into a parameter grid:

```ruby
# edge pixels vote for candidate (rho, theta) cells
n_rho = 200; n_theta = 180
vote  = CA_INT32(n_rho, n_theta).fill(0)

rho_idx   = ...                       # per-vote rho bin
theta_idx = ...                       # per-vote theta bin
vote.scatter_add!(rho_idx * n_theta + theta_idx, 1)
```

`bincount_nd(lengths: [n_rho, n_theta])` on the stacked
`(rho_idx, theta_idx)` channels does the same and returns the grid
already shaped.

### 4.9 Sparse gradient accumulation

Backprop for an embedding table: multiple tokens map to the same row
and their gradients must sum, not overwrite:

```ruby
vocab_size = 50_000
dim        = 128
grad_table = CA_FLOAT32(vocab_size, dim).fill(0)

tokens = CA_INT32([...])              # length B
dy     = CA_FLOAT32(B, dim)           # per-token upstream gradient

# One scatter_add! per embedding column keeps the address vector 1-D;
# the accumulator is fastest when addresses fit L1.
dim.times do |d|
  addr = tokens * dim + d
  grad_table.scatter_add!(addr, dy[nil, d])
end
```

The unbuffered accumulate is essential here — token duplicates within a
batch are the common case for popular vocabulary.

### 4.10 Colour / palette quantisation tally

Given an image and a palette-index-per-pixel, count how many pixels
each palette entry received:

```ruby
palette_size = 256
palette_idx  = ...                    # CA_UINT8 image, values in 0..255
palette_idx.bincount(length: palette_size)
```

For 2-D joint palette usage (which palette combos appear across two
frames), use `bincount_nd(lengths: [256, 256])`.

### 4.11 Event counting per time-bucket

Aggregate an event stream into fixed-width time-buckets:

```ruby
bucket_ms = 60_000                    # 1 minute
t_ms      = ...                       # CA_INT64 timestamps
first     = t_ms.min
bucket    = ((t_ms - first) / bucket_ms).int32
counts    = bucket.bincount
```

Add `weights: durations` for total busy-time per bucket, or use
`scatter_max!` on a per-bucket scratchpad for peak values per minute.

### 4.12 Contingency tables

Cross-tabulate two categorical variables:

```ruby
# survey: choice in 0..3, region in 0..4
choice = CA_INT32([...])
region = CA_INT32([...])

table = CArray.stack([choice, region], axis: -1).bincount_nd(lengths: [4, 5])
table.counts                          # shape [4, 5]
```

Add a third channel for a three-way table by extending both `lengths`
and the stacked axis.

### 4.13 Deduplicating with "keep first"

For each unique key, keep the *first* value's index:

```ruby
keys       = CA_INT32([2, 0, 2, 1, 0, 2])
k          = keys.max + 1
first_seen = CA_INT64(k).fill(Float::INFINITY.to_i)  # sentinel = "no key yet"
idx        = CA_INT64(keys.elements).seq             # [0, 1, 2, 3, 4, 5]
first_seen.scatter_min!(keys, idx)
first_seen.to_a                                       # => [1, 3, 0]
```

`scatter_max!` gives "keep last"; `scatter_min!(keys, values)` gives
"minimum value per key" — the reduction is user-selected.

### 4.14 Building an inverted index

For each token, count how many documents it appeared in:

```ruby
# docs = length-D token lists → flatten to (doc_id, token_id) pairs
doc_id     = CA_INT32([0, 0, 0, 1, 1, 2, 2, 2, 2])
token_id   = CA_INT32([5, 7, 5, 5, 9, 7, 7, 5, 9])
vocab_size = 10

# doc-frequency (count of *distinct* docs containing the token):
seen = CA_UINT8(vocab_size, 3).fill(0)   # 3 = number of docs
seen.scatter_replace!(token_id * 3 + doc_id, 1)
df   = seen.sum(axis: 1)                 # per-token document count
```

The `scatter_replace!` collapses "token 5 appearing twice in doc 0" to
a single 1; then the axis-sum turns per-`(token, doc)` presence into
per-token document frequency.

### 4.15 Radix / bucket prefix

The classic bucket-sort setup: count per bucket, then prefix-sum to
locate each bucket's slot:

```ruby
buckets       = keys / bucket_width           # CA_INT32
per_bucket    = buckets.bincount(length: n_buckets)
bucket_offset = per_bucket.accumulate         # exclusive prefix sum = starting offset
```

The prefix step is a plain scan on the histogram, but the histogram
itself is `bincount`.

### 4.16 Graph in-degree from an edge list

```ruby
n_nodes = 1000
src     = ...   # CA_INT32 length E
dst     = ...   # CA_INT32 length E

in_degree  = dst.bincount(length: n_nodes)
out_degree = src.bincount(length: n_nodes)
```

Weighted variants (`weights: edge_weight`) give the summed in-strength
and out-strength.

### 4.17 Voronoi / nearest-centre tally

Each sample carries the index of its nearest cluster centre; how many
samples ended up in each cell?

```ruby
nearest = ...                        # CA_INT32, values in 0..k-1
sizes   = nearest.bincount(length: k)
```

For the k-means "sum of samples per cluster" step you actually want a
weighted scatter into a `(k, d)` array:

```ruby
centroid_sum = CA_DOUBLE(k, d).fill(0)
centroid_cnt = CA_INT64(k).fill(0)
d.times do |j|
  centroid_sum.scatter_add!(nearest * d + j, samples[nil, j])
end
centroid_cnt.scatter_add!(nearest, 1)
new_centroids = centroid_sum / centroid_cnt.reshape(k, 1)
```

### 4.18 Feature hashing (hash trick)

Sum values into a fixed-size feature vector after hashing keys:

```ruby
n_features = 1 << 20
hashes     = keys.map { |k| k.hash & (n_features - 1) }.to_ca(CA_INT32)
feat       = CA_DOUBLE(n_features).fill(0)
feat.scatter_add!(hashes, values)
```

Collisions are the whole point — they fold, they don't overwrite.

### 4.19 Streaming aggregation over chunks

For datasets that don't fit in memory, both `CArray::BincountND` and a
hand-rolled `scatter_add!` accumulator support streaming:

```ruby
# bincount_nd streaming
acc = nil
chunks.each do |chunk|                   # each chunk: shape (A, M)
  h = chunk.bincount_nd(lengths: [Lx, Ly])
  acc = acc ? acc + h : h
end
acc.counts
```

```ruby
# scatter_add! streaming (any reduction)
out = CA_DOUBLE(k).fill(0)
chunks.each do |chunk|                   # chunk: values + group_ids
  out.scatter_add!(chunk[:groups], chunk[:values])
end
```

The `bincount_nd` accumulator has structural checks (`lengths`,
`fiber_shape`, weighted state must match); `scatter_add!` will happily
mix anything you throw at it, so the discipline is on the caller.

### 4.20 Multi-resolution binning

Compute several histogram resolutions from the same data without
re-reading it:

```ruby
coarse_bin = fine_bin / 4                # integer division, wider bins
fine       = fine_bin.bincount(length: 256)
coarse     = coarse_bin.bincount(length: 64)
```

The coarse counts equal the sum of every four fine counts — a check that
your reduction is exact:

```ruby
coarse == fine.reshape(64, 4).sum(axis: 1)   # => all true
```

### 4.21 Building a lookup table by "last known good"

Given an event log `(id, timestamp, status)`, keep the latest status
per id:

```ruby
n_ids  = 10_000
status = CA_INT32(n_ids).fill(-1)
order  = timestamp.sort_index          # visit events oldest-first
status.scatter_replace!(id[order], status_code[order])
```

Since `scatter_replace!` is last-write-wins and we present addresses in
timestamp order, the final `status[i]` is the newest one.

### 4.22 Marginal distributions from a joint bincount

Once you have a joint `bincount_nd`, marginals are `accumulate` calls
along the trailing axes:

```ruby
h = data.bincount_nd(lengths: [10, 20, 30])
marginal_0 = h.counts.accumulate(axis: 2).accumulate(axis: 1)  # p(x)
marginal_1 = h.counts.accumulate(axis: 2).accumulate(axis: 0)  # p(y)
marginal_2 = h.counts.accumulate(axis: 1).accumulate(axis: 0)  # p(z)
```

Whether you compute this once at the end or store `bincount` marginals
alongside the joint depends on downstream demand — the joint is always
sufficient.

---

## 5. Choosing between the surfaces

A short decision guide:

| you have | you want | reach for |
|---|---|---|
| non-negative integer labels, 1-D output | counts (or weighted sum) per label | `bincount` |
| `M ≥ 2` integer channels, rectangular output | joint counts (or weighted sum) | `bincount_nd` |
| addresses that are already flat, arbitrary reduction | in-place accumulate/replace | `scatter_*!` |
| labels **and** you want overflow reporting | counts + overflow cell | `bincount_nd` |
| labels **and** you want the *M*-D shape without a ravel | joint table | `bincount_nd` |
| you want group-by (min / max / product / …) | non-count reductions | `scatter_min!` / `scatter_max!` / `scatter_mul!` |
| your target already exists and you'll write many chunks | streaming accumulate | `scatter_add!` (or `BincountND#add`) |

`bincount` and `bincount_nd` are the packaged fast paths for the
common count-and-sum shapes; `scatter_*!` is the workhorse for
everything else and the escape hatch when you need a reduction the
histogram surfaces don't expose. They compose freely — a joint
`bincount_nd` for the count, a paired `scatter_add!` into an equally
shaped scratchpad for the weighted sum, and you have joint mean tables
in two passes with no per-cell Ruby.
