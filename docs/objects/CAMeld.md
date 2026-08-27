# CAMeld — ragged concatenate view

`CAMeld` is the view class behind {CArray.meld} and {CArray#meld}.
It **welds K parent arrays along one of their existing axes**, with
the welded axis allowed to have different lengths per parent (the
"ragged" case).  No data is copied: reads gather from parents on
demand, and writes flow straight back to them.

```
a = [[1 2 3]        b = [[10 20]        c = [[100]
     [4 5 6]]            [30 40]              [200]]
                          [50 60]]
   shape [2, 3]        shape [3, 2]        shape [2, 1]

CArray.meld(a, b, axis: 0)     shape [5, 3]   welds along rows
                                                 (a's rows above b's rows)

CArray.meld(a, c, axis: 1)     shape [2, 4]   welds along cols
                                                 (a's cols left of c's col)
```

The welded axis is called the **meld axis**; segment boundaries are
tracked in a prefix-sum table {CAMeld#seg_offsets}.  Users see one
contiguous axis; the engine keeps the segments.

For the full composition cheat-sheet (`meld` vs `stack` vs the eager
`concatenate` / `mosaic` / `tabulate`), see
[Composition.md](../topics/Composition.md).

---

## 1. What a CAMeld is

A `CAMeld` wraps **K parent CArrays that share `ndim`, `data_type`,
byte width, and every axis length except the meld axis**.  Along the
meld axis, parents may have different lengths — those lengths add up
to the view's meld-axis length:

```
result.ndim              == parent.ndim
result.shape[a]          == parent.shape[a]           for a != meld_axis
result.shape[meld_axis]  == Σ_k parents[k].dim[meld_axis]
```

The prefix-sum table `seg_offsets` records where each segment starts:

```
seg_offsets[0]           == 0
seg_offsets[k+1]         == seg_offsets[k] + parents[k].dim[meld_axis]
seg_offsets[n_parents]   == shape[meld_axis]
```

So a view coordinate `(i₀, …, v, …, iₙ)` at meld-axis position `v`
belongs to segment `k` where `seg_offsets[k] ≤ v < seg_offsets[k+1]`,
and maps to parent[k] at meld-axis position `v - seg_offsets[k]`.

---

## 2. Constructing a CAMeld

Three entry points, all returning a `CAMeld`:

```ruby
CArray.meld(a, b, c, axis: 0)      # splat form (recommended)
CArray.meld([a, b, c], axis: 0)    # Array form (convenience)
a.meld(b, c, axis: 0)              # instance form
CAMeld.new([a, b, c], axis: 0)       # low-level constructor
```

`axis:` defaults to `0` (outer axis) and accepts negative values
(normalised against the reference `ndim`).  There is no `data_type:`
kwarg: `CArray.meld` requires every piece to already have the same
`data_type` (see below).

`CArray.meld` handles both uniform and ragged inputs through the same
segment-major engine — the meld axis is allowed to differ per parent
(that's the "ragged" case), and reductions land at eager parity
regardless via the per-parent decompose fast path.

Uniform check at construction time — parents must agree on:

- `ndim`
- `data_type` (mismatch raises — see below)
- byte width
- every axis length except `meld_axis`

Any mismatch raises `ArgumentError`.

### `data_type` strictness

`CArray.meld` is a view constructor and refuses to auto-cast, since a
cast produces a fresh entity and breaks the "identity preserved" view
contract.  When you have pieces with mixed `data_type`:

- pre-cast pieces yourself: `CArray.meld(a.to_type(:float64), b, ...)`;
- use {CArray.concatenate} (eager, materialised copy — auto-casts to the
  common type or an explicit `data_type:` kwarg).

CAFrame mirrors this split: {CAFrame.meld} is the strict view frame
(each column is a CAMeld view; same data type required per column) and
{CAFrame.concatenate} is the eager auto-casting alternative (each
column is a fresh entity from {CArray.concatenate}).

### Nested `meld` flattens

When one of the inputs is itself a `CAMeld` **with the same meld axis**,
`CArray.meld` absorbs its parents into the resulting `CAMeld`'s parent
list instead of nesting:

```ruby
inner = CArray.meld(a, b, axis: 0)              # 2-parent CAMeld
outer = CArray.meld(inner, c, axis: 0)          # 3-parent CAMeld, not nested
outer.parents                                     # => [a, b, c]
```

This keeps `xfer_all` / reduce chains at depth 1 regardless of how the
user builds the concat.  A `CAMeld` with a **different** meld axis is
left as-is (its segment structure is orthogonal to the outer axis).

---

## 3. The meld axis and segment offsets

```ruby
a = CArray.int32(3, 4) { |i, j| 100 + i * 10 + j }
b = CArray.int32(5, 4) { |i, j| 200 + i * 10 + j }
c = CArray.int32(1, 4) { |i, j| 300 + i * 10 + j }

m = CArray.meld(a, b, c, axis: 0)

m.shape         # => [9, 4]
m.meld_axis     # => 0
m.n_parents     # => 3
m.seg_offsets   # => [0, 3, 8, 9]
m.parents       # => [a, b, c]   (identity preserved)
```

`seg_offsets[k]..seg_offsets[k+1]` marks the meld-axis span occupied
by parent `k` in the view.  Non-meld axes are uniform and are indexed
identically in view and parent.

---

## 4. Reading (view semantics)

Any `CArray` indexing / iteration works on a `CAMeld`:

- **Scalar access** (`m[i, j]`) — binary-searches `seg_offsets` for the
  segment, then delegates to `parent[k]`'s scalar access.
- **Structural slice** (`m[a..b, nil]`) — dispatches to the segments
  that overlap the requested range; each segment contributes a
  contiguous sub-slab.  External-axis (`meld_axis == 0`) hits a
  K-contig-`xfer_all` best path at memcpy bandwidth; internal-axis
  uses per-parent slab + trailing-chunk memcpy (also memcpy-bound,
  see §7 for the cost model).
- **Non-structural access** (transpose, arbitrary strides) — falls
  through to a per-cell safety-net that composes byte offsets in the
  root's flat space and looks each cell up via
  {CAMeld#xfer_index}.  Correct for any stride pattern; slower than
  structural but still bounded (7–12× eager entity in typical
  benchmarks).

`m.copy` materialises the whole view into a fresh entity; `.to_ca`
returns `self` (since `CAMeld` is a data view, not a lazy view).

---

## 5. Writing (view-through, chain composability)

Writes flow straight back to the parents:

```ruby
m = CArray.meld(a, b, c, axis: 0)
m[0, 0]      = 999.0     # writes to a[0, 0]
m[3..4, nil] = 0         # writes to b's first two rows
m[]          = other_ca  # bulk write, syncs each segment to its parent
```

Because segments alias parent memory, an external reference taken
**before** a chain of writes stays connected to the same data:

```ruby
a = CArray.float64(10) { |i| i.to_f }
m = CArray.meld(a, CArray.float64(5) { 100.0 }, axis: 0)
m[0] = -1.0
a[0]   # => -1.0   (write reached the parent)
```

This is the chain composability that CAMeld deliberately preserves —
a reference stays connected to what it references.  Callers who need write isolation
opt into it explicitly:

```ruby
m.copy   # fresh entity, disconnected from parents
a.copy   # snapshot the parent before writes if you need the old value
```

CAFrame's `df[sel] = df2` and {CAFrame.meld} route through CAMeld
with this same view-through behaviour, with one wrinkle: the splice
snapshots the RHS +df2+ (each column is `.copy`-ed) so subsequent
writes to `df1`'s spliced middle segment do not reach df2.  See
`lib/carray/frame/frame.rb`'s `[]=` docstring for the CAFrame-side
contract in full.

---

## 6. Reductions

CAMeld overrides `sum` / `mean` / `min` / `max` / `variance` /
`variancep` / `stddev` / `stddevp` with a **per-parent decompose fast
path** (`lib/carray/meld_reduce.rb`).  For the meld axis:

```
op(concat_k parent[k]) == combine_k op(parent[k])
```

where `combine` is `+` for `sum`, per-element `min` / `max` for those
ops, `(Σ per-parent sums) / total_count` for `mean`, and Chan/Welford
parallel merge for `variance` / `stddev`.  Each per-parent reduction
runs on an entity, hitting the fastest kernel_iterator path.

For a non-meld axis, each parent independently reduces its own local
axis and the K results are `CArray.meld`'d back along `meld_axis`
(materialised to entity with a trailing `.copy` to preserve
`CArray#reduce`'s entity-returning contract).

Fast-path preconditions:

- `axis:` kwarg is a single Integer (or absent for a flat reduce)
- no mask on the CAMeld or any parent (a masked reduce needs per-cell
  dispatch; those punt to the SRC_ATTACH slow path)
- no non-`:axis` kwargs (`min_count`, `fill_value`, `keep_axis`, etc.
  punt to super)

Order statistics (`median` / `percentile` / `quantile`) don't
decompose (per-parent medians ≠ overall median) — they stay on the
SRC_ATTACH materialise-then-reduce path, which is already essentially
eager parity because the sort cost dominates.

Bench (M2 Apple clang, K=12 × (400, 400) f64, 14 MiB):

| op                 | eager entity | CAMeld (fast path) |
|--------------------|-------------:|-------------------:|
| `mean(axis: 0)`    | ~1290 µs     | ~1400 µs (1.08×)   |
| `sum(axis: 0)`     | ~1236 µs     | ~1364 µs (1.10×)   |
| `min(axis: 0)`     | ~1291 µs     | ~1330 µs (1.03×)   |
| `max(axis: 0)`     | ~1270 µs     | ~1580 µs (1.24×)   |
| `median(axis: 0)`  | ~4120 µs     | ~4420 µs (1.07×)   |

Compared to SRC_ATTACH materialise-then-reduce (~14 000 µs on the same
dataset), the decompose fast path is **9.5×–11.7× faster** while
staying within eager-entity noise.

---

## 7. Cost model

| Path                        | External axis  | Internal axis     |
|-----------------------------|----------------|-------------------|
| `xfer_all` (materialise)    | K contig       | K slab + chunk    |
|                             | ≈ eager        | ≈ eager           |
| `xfer_stride` structural    | K-segment      | K-segment slab    |
|                             | ≈ eager        | ≈ eager           |
| `xfer_stride` non-structural| per-cell       | per-cell          |
|                             | 7–12× eager    | 7–12× eager       |
| `xfer_index` scalar         | O(log K) probe | O(log K) probe    |
| `xfer_addrs` gather         | O(n log K)     | O(n log K)        |

External-axis `xfer_all` writes each parent contiguously into the
result buffer at `seg_offsets[k] × tail_bytes`.  Internal-axis
`xfer_all` copies each parent into a slab buf then scatters a
trailing contig chunk (`Π_{a≥meld_axis} p.dim[a]` bytes) per outer
combo — one memcpy call per outer iteration, not per cell.

Non-structural (transpose, strided step) falls back to per-cell
`xfer_index` — correct for any stride pattern, but slow.  Hot paths
should stay structural; structural coverage includes range slices,
full materialise, and any composed CAStride chain that keeps axis
order.

Measured on an M2.

---

## 8. Relationship to `meld`, `stack`, `concatenate`

| Operation                     | View (same data type)          | Eager (auto-cast)          |
|-------------------------------|--------------------------------|----------------------------|
| Concat along existing axis    | `meld`  (CAMeld view)          | `concatenate` (owned copy) |
| Add a new axis                | `stack` (CAStack view)         | (ragged impossible)        |
| Tile grid                     | `montage`                      | `mosaic`                   |

- {CArray.meld} — uniform-or-ragged, `CAMeld` view; requires same
  `data_type` across pieces (no `data_type:` kwarg).  Also available as
  an instance method (`a.meld(b, c, axis: 0)`).
- {CArray.concatenate} — uniform-or-ragged, **eager materialised
  copy**; auto-casts to the common data type (or takes an explicit
  `data_type:` kwarg).  For callers who want an owned entity or have
  mixed-type pieces without wanting to cast them themselves.

`meld` and `concatenate` differ in materialisation and data type policy.
Reach for `meld` when downstream code can work with a view (most
operations, especially reductions, do) and the data types already agree; reach
for `concatenate` when you need an independent entity or want implicit
promotion.

---

## 9. Masks

A `CAMeld`'s mask is built by horizontal propagation: if any parent
has (or gains) a mask, the CAMeld's `create_mask` walks all parents,
ensures each has a mask, and builds a CAMeld-shaped mask by welding
the per-parent masks along the same `meld_axis`.

Reads through the masked view see the per-parent mask correctly.
Reductions on a masked CAMeld currently take the SRC_ATTACH slow
path (the per-parent decompose fast path punts on `has_mask?`) —
future work if it matters for a workload.

---

## 10. Related

- [Composition.md](../topics/Composition.md) — full composition
  cheat-sheet (concat / meld / stack / concatenate / montage / mosaic
  / tabulate).
- [CAStack.md](CAStack.md) — the outer-axis stack view, uniform K
  parents on a new K axis.
- `lib/carray/frame/frame.rb` — CAFrame `df[sel] = df2` splice_rows,
  which routes each column through `CArray.meld`.
- `lib/carray/frame/concat.rb` — `CAFrame.meld(*frames)` (view frame,
  strict per-column data type) and `CAFrame.concatenate(*frames)` (eager
  frame, per-column auto-cast).
