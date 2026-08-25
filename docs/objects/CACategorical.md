# CACategorical — categorical dtype (dense codes + label vocabulary)

`CACategorical` is a categorical column: a dense integer **codes** array plus a
small **label vocabulary**, structurally identical to a pandas `Categorical`
or an Arrow dictionary. Each cell stores a code (an index into `labels`), and
per-cell fetch decodes the code back into its label.

It is implemented as a READONLY [Face](../topics/CAFace.md) over the codes array, so:

- the **codes ARE the storage parent** — every view-creating operation
  (slice / reshape / transpose / mask / gather) carries the codes along the
  view chain automatically. Only the label vocabulary is carried as
  Face state;
- the surface is `CA_FIXLEN`, which **gates off numeric kernels** (`cat + 1`
  raises — arithmetic on category codes is nonsense). The meaningful
  operations come back for free on the codes parent (`cat.codes.bincount`,
  `cat.codes.count(code)`, …);
- exclusion (missing / out-of-vocabulary) is encoded **both** as a mask
  **and** as the all-ones sentinel value in the code bytes — READONLY keeps
  them in sync forever.

A plain `require "carray"` is all you need — `CArray#categorize` and the
`CACategorical` constant are both autoloaded on first use.

## Construction

There are three entry points, covering the three ways a categorical column
appears in practice: discovering the vocabulary from data, imposing a fixed
vocabulary on data, or importing already-dense codes from pandas / Arrow.

### 1. `keys.categorize` — discover the vocabulary from data

Called on an array of raw category keys (typically a `CA_OBJECT` or
`CAConstString` column). Discovers the distinct levels in
**first-appearance order** — not sorted, not hashed to arbitrary order —
so re-running on the same input gives the same codes.

```ruby
keys = CArray.object(8) { |i| %w[mar mar jan jan jul jul jan mar][i] }
cat  = keys.categorize

cat.labels        # => ["mar", "jan", "jul"]        (first-appearance order)
cat.codes.to_a    # => [0, 0, 1, 1, 2, 2, 1, 0]
cat.to_a          # => ["mar", "mar", "jan", "jan", "jul", "jul", "jan", "mar"]
cat.labels.size   # => 3   (the category count)
```

Masked keys are treated as excluded and never become a level:

```ruby
keys      = CArray.object(4) { |i| %w[a b z a][i] }
keys[2]   = UNDEF
cat       = keys.categorize
cat.labels        # => ["a", "b"]                   (masked key not a level)
cat[2]            # => UNDEF
```

The code dtype is chosen automatically as the narrowest unsigned integer
that fits the vocabulary while reserving its top value as the exclusion
sentinel:

| categories | code dtype | sentinel |
|---|---|---|
| up to 255      | `uint8`  | `0xFF` |
| up to 65 535   | `uint16` | `0xFFFF` |
| larger         | `uint32` | `0xFFFFFFFF` |

### 2. `keys.categorize(labels: vocab)` — impose a fixed vocabulary

Pass an explicit vocabulary to lock the code assignment and to treat any
key outside the set as excluded. This is the right form for reproducible
pipelines (the code of every category is stable across runs and datasets)
and for aligning several columns to a shared vocabulary.

```ruby
keys = CArray.object(5) { |i| %w[jan jul mar jan dec][i] }
cat  = keys.categorize(labels: %w[jan feb mar])

cat.labels           # => ["jan", "feb", "mar"]
cat.codes.to_a       # => [0, UNDEF, 2, 0, UNDEF]      (codes carry the mask)
cat.codes.value.to_a # => [0, 255, 2, 0, 255]          (jul / dec -> sentinel)
cat.to_a             # => ["jan", UNDEF, "mar", "jan", UNDEF]
cat.has_mask?        # => true
```

Duplicate labels are rejected (the code -> label mapping must be a bijection):

```ruby
keys.categorize(labels: %w[a a b])   # => ArgumentError
```

### 3. `CACategorical.from_codes(codes, labels)` — wrap already-dense codes

The **pandas / Arrow import receiver**. Wraps an integer `CArray` of codes
plus a label vocabulary, with no discovery. `codes` becomes the Face's
storage parent verbatim — zero-copy when it is a wrapped memory view.

```ruby
codes = CArray.uint8(6) { |i| [0, 1, 0, 2, 1, 0][i] }
cat   = CACategorical.from_codes(codes, %w[tokyo osaka kyoto])
cat.to_a          # => ["tokyo", "osaka", "tokyo", "kyoto", "osaka", "tokyo"]
```

Excluded cells are identified by the **all-ones sentinel** (type-max for an
unsigned dtype, `-1` for a signed one — the same missing code that pandas
and Arrow use) and masked here. Both encodings survive because the Face is
READONLY, so exports round-trip without conversion.

**Unsigned codes** (Arrow-style):

```ruby
# 0xFF = the reserved sentinel for uint8
codes = CArray.uint8(4) { |i| [0, 0xFF, 1, 0][i] }
cat   = CACategorical.from_codes(codes, %w[a b])
cat.has_mask?         # => true (derived from the sentinel)
cat.to_a              # => ["a", UNDEF, "b", "a"]
```

**Signed codes** (`-1` = missing):

```ruby
codes = CArray.int8(4) { |i| [0, -1, 1, 0][i] }
cat   = CACategorical.from_codes(codes, %w[a b])
cat.to_a              # => ["a", UNDEF, "b", "a"]
```

### 4. Binning continuous data

For continuous values (temperature, precipitation, …) the canonical
form is **snap to a grid, then `categorize`** — the labels are the
actual snapped values, no separate edges / labels to author.

Two value-returning primitives cover the two grid shapes:

- [`CArray#snap(step, offset: 0.0)`](../../lib/carray/methods/snap.rb) —
  **uniform** grid `..., -step + offset, offset, step + offset, ...`
- [`CArray#snap_to(list, lfill:, ufill:)`](../../lib/carray/methods/snap.rb) —
  **non-uniform** grid given as an ascending list

Both return the snapped **value** (same dtype as the source /
`list`). Because the returned array is just a coarser version of the
input, `categorize` on it works exactly like `categorize` on any other
column.

**Uniform 0.5 K grid**:

```ruby
temp = CArray.float64(500) { rand * 30 + 268 }        # samples in K

cat = temp.snap(0.5).categorize

cat.labels           # => [285.5, 271.0, 296.5, …]    (first-appearance)
cat.to_a             # => [285.5, 271.0, 285.5, …]    (round-trips)
cat.category_sizes.to_a    # counts per distinct snapped value
```

Labels come out in first-appearance order by default. Pass
`sort_labels: true` to get them ascending — the natural form for a
downstream table (per-bin counts, per-bin means, plot axis):

```ruby
cat = temp.snap(0.5).categorize(sort_labels: true)
cat.labels           # => [270.0, 270.5, 271.0, …, 299.5]  (ascending)
```

Or pass a fixed vocabulary explicitly when you want the grid pinned
regardless of which values happen to appear in this particular sample
(so empty grid points still show as 0 in `category_sizes`):

```ruby
grid = Array.new(61) { |i| 270.0 + i * 0.5 }          # 270.0, 270.5, …, 300.0
cat  = temp.snap(0.5).categorize(labels: grid)
cat.labels           # => [270.0, 270.5, 271.0, …, 300.0]
cat.category_sizes.to_a    # length-61, aligned to `grid`; empty grid points are 0
```

Use `offset:` to shift the phase — e.g. `snap(0.5, offset: 0.25)`
snaps to `..., 0.25, 0.75, 1.25, ...` (bin centers instead of edges).

**Non-uniform grid** — precipitation rates, log-spaced thresholds,
domain-defined class breakpoints:

```ruby
rain = CArray.float64(500) { rand * 50 }
cat  = rain.snap_to([0.0, 1.0, 5.0, 20.0]).categorize

cat.labels        # => [0.0, 5.0, 20.0, 1.0]        (whichever appeared first)
cat.category_sizes.to_a # counts per snapped level
```

Out-of-range handling for `snap_to`:

- default — below `list[0]` and above `list[-1]` are clamped to the
  nearest end (i.e. all finite values snap to a list value);
- `lfill: nil` / `ufill: nil` — mask the corresponding side instead;
- `lfill: value` / `ufill: value` — replace the corresponding side
  with an explicit value (typically a sentinel outside the list);
- `NaN` / masked input cells are always masked in the output.

**Authored labels instead of raw values** — sometimes each bin needs a
label that is not a data value (a `Range`, a class name, a symbol). Use
[`CArray#bin_to`](../../lib/carray/methods/bin.rb) to get the bin
index against an explicit `edges` array and hand a matching `labels`
list to `from_codes`:

```ruby
edges  = [0, 1, 5, 20, 100, 1_000]                    # precipitation (mm/h)
labels = %w[trace light moderate heavy violent]
codes  = rain.bin_to(edges)
cat    = CACategorical.from_codes(codes, labels)
cat.category_sizes.to_a    # counts per class, aligned to `labels`
```

**Equal-frequency (quantile) binning** — let the data set the edges so
every bin holds roughly the same count. Compute the edges with
`percentile` and feed them to `bin_to`:

```ruby
n_bins = 10
qs     = Array.new(n_bins + 1) { |i| i * 100.0 / n_bins }   # 0, 10, …, 100
edges  = temp.percentile(*qs)                               # 11 numeric edges
codes  = temp.bin_to(edges, include_max: true)              # last bin inclusive
labels = Array.new(n_bins) { |i| "q#{i + 1}" }              # "q1".."q10"

cat = CACategorical.from_codes(codes, labels)
cat.category_sizes.to_a    # ≈ [N/10, N/10, …]   (ties can skew a bit)
```

The same idiom does quartiles (`n_bins = 4`, labels `%w[Q1 Q2 Q3 Q4]`),
deciles (10), or any other equal-frequency scheme.

> **Related index-returning primitives.** When you only need the
> integer bin index (histogram, weighted aggregation, joint-code
> composition), reach directly for the sibling primitives:
> [`bin(vmin, vmax, step)`](../../lib/carray/methods/bin.rb) for uniform
> equal-width bins, [`bin_to(edges)`](../../lib/carray/methods/bin.rb)
> for explicit edges. Wrapping a bare bin index in a categorical whose
> labels are the integers `0..k-1` does not add information.

## Multi-dimensional categoricals

`categorize` operates element-wise on any shape — the codes array simply
inherits the shape of the input. The label vocabulary is a flat list
shared by every cell.

### 2-D: a station × month table of weather regimes

```ruby
regimes = CArray.object(3, 4) { |s, m|
  # 3 stations, 4 months, each cell is one of: :dry, :wet, :storm
  [[:dry, :dry,   :wet,   :wet],
   [:dry, :storm, :storm, :wet],
   [:wet, :wet,   :dry,   :storm]][s][m]
}

cat = regimes.categorize
cat.labels        # => [:dry, :wet, :storm]         (first-appearance order)
cat.shape         # => [3, 4]
cat.codes.to_a    # => [[0, 0, 1, 1], [0, 2, 2, 1], [1, 1, 0, 2]]
cat.category_sizes.to_a # => [4, 5, 3]                    (dry / wet / storm)
```

The row and column views are themselves `CACategorical` — the label
vocabulary rides along:

```ruby
station_0 = cat[0, nil]
station_0.class       # => CACategorical
station_0.labels      # => [:dry, :wet, :storm]     (same vocabulary)
station_0.to_a        # => [:dry, :dry, :wet, :wet]

month_3   = cat[nil, 3]
month_3.to_a          # => [:wet, :wet, :storm]
```

Per-axis operations drop to the codes parent — plain `CArray` methods work:

```ruby
# Which stations were :dry at least twice?
(cat.eq(:dry).sum(axis: 1) >= 2).to_a   # => [1, 0, 0]

# Fraction of :storm cells per station
cat.eq(:storm).mean(axis: 1).to_a       # => [0.0, 0.5, 0.25]
```

### 3-D with a fixed vocabulary (reproducible pipeline)

When several datasets must share a vocabulary — training vs test splits,
different years of the same measurement — pass `labels:` explicitly. The
sentinel is a natural fit for out-of-vocabulary regimes that only appear in
a later batch.

```ruby
VOCAB = %i[dry wet storm calm]

train = train_keys.categorize(labels: VOCAB)   # (station, month, year) shape
test  = test_keys .categorize(labels: VOCAB)   # same shape, same codes

# Same code always means the same regime; unknown regimes are UNDEF.
train.codes.data_type == test.codes.data_type   # => true
```

### Building a categorical directly from codes (skip discovery)

If your data already arrives as dense integer codes (a database join key,
an ML feature column, an Arrow dictionary column exported from Python) use
`from_codes` and skip `categorize` entirely:

```ruby
# shape (100, 24): 100 sensors × 24 hours, each cell is an integer code 0..4
codes  = CArray.uint8(100, 24) { |s, h| some_code(s, h) }
labels = %w[idle low medium high critical]
cat    = CACategorical.from_codes(codes, labels)

cat[0, 12]        # => "medium"     (decoded)
cat.shape         # => [100, 24]
cat.category_sizes.to_a # length-5 counts, aligned to labels
```

## More categorization recipes

The three primitives (`categorize`, `from_codes`, `snap` / `bin_to`)
compose into most real-world categorization patterns. A few hints:

### Rule-based classification

When the category is a predicate, not a stored key, write straight into a
codes array. Cells that no rule matches keep the sentinel and are
excluded:

```ruby
x = CArray.float64(...)                                 # any shape

codes = CArray.uint8(*x.shape).fill(0xFF)               # start all-excluded
codes[x.eq(0)]      = 0
codes[x.lt(0)]      = 1
codes[x.gt(0)]      = 2

cat = CACategorical.from_codes(codes, %i[zero negative positive])
cat.category_sizes.to_a
```

Rules are applied in order — a cell hit by two rules ends up in the last
one that wrote it, so put the more specific rule last (or use disjoint
predicates).

### Normalize before you categorize

Same key spelled two ways = two categories, unless you canonicalize
first. This is where `CAConstString` / `CA_OBJECT` operations shine:

```ruby
raw = ["Tokyo ", "tokyo", "OSAKA", "osaka", " Tokyo"]
cat = CA_OBJECT(raw).convert { |s| s.strip.downcase }.categorize
cat.labels     # => ["tokyo", "osaka"]
cat.to_a       # => ["tokyo", "tokyo", "osaka", "osaka", "tokyo"]
```

Any `convert` that returns a comparable value works — a domain mapping
(`{ "JP" => "Japan", "US" => "USA" }`), a locale-safe fold, a stemmer …

### Top-K + "other"

Take the K most frequent categories, fold the rest into an "other"
bucket. Two-pass: discover, decide, re-categorize with a fixed
vocabulary:

```ruby
keys = CA_OBJECT(%w[a b c a a b d e a b c f a])
K    = 2

tmp = keys.categorize
top = tmp.labels.zip(tmp.category_sizes.to_a)
        .sort_by { |_, c| -c }.first(K).map(&:first)
# top => ["a", "b"]

folded = keys.convert { |k| top.include?(k) ? k : "other" }
cat    = folded.categorize(labels: top + ["other"])

cat.labels                  # => ["a", "b", "other"]
cat.category_sizes.to_a           # => [5, 3, 5]
```

### Datetime → month / season / year-month

For [`CATime`](../topics/CATime.md), how you categorize the timestamp
depends on whether the group is a **fixed cycle** (Jan…Dec, Mon…Sun,
spring…winter) or a **data-driven period** on the timeline (which
year-months actually appear in this dataset).

**Fixed cycle** (climatology — year-across grouping into a fixed set of
buckets). Extract the field and pass the vocabulary explicitly to pin
the label order:

```ruby
month = dt.month                                        # 1..12 integers
cat   = month.categorize(labels: (1..12).to_a)
cat.labels           # => [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]
cat.category_sizes.to_a    # => [n_jan, n_feb, …, n_dec]      (aligned to labels)
```

Seasons are a rule-based collapse of the same field:

```ruby
season = month.convert(:object) { |m| [nil, :winter, :winter, :spring, :spring, :spring,
                          :summer, :summer, :summer, :autumn, :autumn,
                          :autumn, :winter][m] }
cat    = season.categorize(labels: %i[spring summer autumn winter])
cat.labels           # => [:spring, :summer, :autumn, :winter]
```

**Data-driven period** (timeline — one group per distinct
`(year, month)` / date / week that appears in the data). Use
`strftime` with an ISO format so string ascending order = chronological
order, and let `sort_labels: true` do the sort:

```ruby
cat = dt.strftime("%Y-%m").categorize(sort_labels: true)
cat.labels           # => ["2023-11", "2023-12", "2024-01", "2024-02", …]  (chronological)
```

Same shape works for annual (`"%Y"`), daily (`"%Y-%m-%d"`), or
sub-daily periods. `sort_labels: true` earns its keep here — you don't
know ahead of time which years / months / days the dataset covers, so
you can't pre-declare the vocabulary, but you want the downstream table
to read chronologically.

### Combining two categoricals (cross-product)

To group by two categoricals at once (station × regime, sensor × severity,
…), form a joint code `a.codes * b.labels.size + b.codes` and label it with
the cross-product:

```ruby
a = station.categorize                                  # labels ["sapporo", "tokyo"]
b = regime .categorize                                  # labels [:dry, :wet, :storm]

joint_codes  = a.codes * b.labels.size + b.codes        # in [0, Ka*Kb)
joint_labels = a.labels.product(b.labels)
# joint_labels => [["sapporo", :dry],   ["sapporo", :wet], ["sapporo", :storm],
#                  ["tokyo",   :dry],   ["tokyo",   :wet], ["tokyo",   :storm]]

joint = CACategorical.from_codes(joint_codes, joint_labels)
joint[0]                        # => ["sapporo", :dry]  (decoded pair)
joint.category_sizes.reshape(a.labels.size, b.labels.size)   # contingency table, rows=station, cols=regime
```

Excluded cells in either input propagate — masked codes stay masked
through the arithmetic.

### Spatial: (lat, lon) → grid cell

Two `bin` on the axes, one flattening step, one `from_codes`:

```ruby
n_rows, n_cols = 2, 3
i = lat.bin(lat_min, lat_max, bins: n_rows)             # row index in [0, 2)
j = lon.bin(lon_min, lon_max, bins: n_cols)             # col index in [0, 3)

cell_codes  = i * n_cols + j
cell_labels = Array.new(n_rows * n_cols) { |c| [c / n_cols, c % n_cols] }
# cell_labels => [[0,0], [0,1], [0,2], [1,0], [1,1], [1,2]]

cells = CACategorical.from_codes(cell_codes, cell_labels)
cells[0]           # => [1, 2]        (whichever (row, col) the 1st sample fell in)
```

Any cell outside the lat/lon range is excluded on both inputs, so
`cell_codes` inherits the union of the masks.

### Sort the vocabulary after discovery

`categorize` uses first-appearance order by default (stable,
reproducible). Pass `sort_labels: true` to get the discovered vocabulary
ascending — one-call idiom:

```ruby
keys = CA_OBJECT(%w[mar jan jul jan mar])
cat  = keys.categorize(sort_labels: true)
cat.labels                         # => ["jan", "jul", "mar"]   (alphabetical)
cat.codes.to_a                     # => [2, 0, 1, 0, 2]
```

`sort_labels:` is a discovery-only knob — when you pass `labels:`
explicitly the caller has already decided the order, and `sort_labels:`
is ignored.

## Views: slice / reshape / transpose / mask

Because the codes ARE the storage parent, any view of a `CACategorical` is
again a `CACategorical` — the codes chain gathers naturally and the label
vocabulary is carried as Face state.

```ruby
codes = CArray.uint8(6) { |i| [0, 1, 0, 2, 1, 0][i] }
cat   = CACategorical.from_codes(codes, %w[tokyo osaka kyoto])

sl = cat[1..4]
sl.class           # => CACategorical
sl.codes.to_a      # => [1, 0, 2, 1]
sl.labels          # => ["tokyo", "osaka", "kyoto"]     (inherited)
sl.to_a            # => ["osaka", "tokyo", "kyoto", "osaka"]

# reshape / transpose / boolean gather all work
cat.reshape(2, 3).class       # => CACategorical
cat[cat.eq("tokyo")].to_a     # => ["tokyo", "tokyo", "tokyo"]
```

## Label-space vs code-space operations

The element value of a categorical **is** its category, so the built-in
label-space methods specialise `CArray`'s value operations into label
space — the user never has to look up the integer code. When you do want
codes (interop, ML features, joining on integer keys), reach for `.codes`.

### Label-space methods (by category label)

```ruby
cat = CArray.object(6) { |i| %w[a b a c b a][i] }.categorize

cat.eq("a")            # => boolean CArray:  [1, 0, 1, 0, 0, 1]
cat.ne("a")            # => boolean CArray:  [0, 1, 0, 1, 1, 0]
cat.count("a")         # => 3
cat.count("zzz")       # => 0                (unknown label -> 0, not an error)

cat.category_sizes.to_a      # => [3, 2, 1]        (aligned to labels, keeps trailing 0)
cat.labels.zip(cat.category_sizes.to_a)
                        # => [["a", 3], ["b", 2], ["c", 1]]
```

`category_sizes` always returns a length-`k` array in label order, even when a
category never occurs — unlike `cat.codes.bincount`, which truncates
trailing zero categories:

```ruby
codes = CArray.uint8(4) { |i| [0, 1, 0, 1][i] }
cat   = CACategorical.from_codes(codes, %w[a b c])
cat.codes.bincount.to_a   # => [2, 2]        (truncated)
cat.category_sizes.to_a         # => [2, 2, 0]     (full k-length, aligned to labels)
```

Excluded cells stay `UNDEF` in `eq` / `ne` — an unknown category cannot
match anything:

```ruby
keys = CArray.object(4) { |i| %w[a b z a][i] }
keys[2] = UNDEF
cat = keys.categorize
cat.eq("a").to_a          # => [1, 0, UNDEF, 1]
```

### Code-space (fall through to CArray via `.codes`)

`cat.codes` returns the raw storage parent. Everything `CArray` offers
works there — arithmetic, histograms, joins, etc.

```ruby
cat.codes.bincount        # per-category counts (truncates trailing 0)
cat.codes.count(0)        # count of one category by code
cat.codes.eq(2)           # boolean mask by code

# Feed to any integer kernel:
cat.codes.value.refer(CA_INT32)   # widen for a downstream API
```

## Exclusion: mask AND sentinel

Every excluded cell carries **both** encodings:

- **the CArray mask**  — `cat.is_masked[i] == 1`, `cat[i] == UNDEF`,
  mask-aware reductions and `category_sizes` all skip it (native CArray idiom);
- **the sentinel value in the code byte** — the all-ones bit pattern
  (`0xFF` / `0xFFFF` / `0xFFFFFFFF` for unsigned; `-1` for the signed
  reinterpretation). This is what a per-axis grouping kernel skips by its
  `[0, k)` range check, and what pandas / Arrow expect on the wire.

Because the Face is READONLY these two can never diverge. Consumers may
rely on either encoding without checking the other.

```ruby
keys = CArray.object(5) { |i| %w[jan jul mar jan dec][i] }
cat  = keys.categorize(labels: %w[jan feb mar])   # jul, dec excluded

# 1. Mask view — native CArray
cat.is_masked.to_a          # => [0, 1, 0, 0, 1]
cat[1]                      # => UNDEF

# 2. Raw code bytes — sentinel at excluded positions
cat.codes.value.to_a        # => [0, 255, 2, 0, 255]   (uint8 type-max)

# 3. Byte-reinterpret to signed (zero-copy) — same bytes, pandas -1 semantics
cat.codes.value.refer(CA_INT8).to_a
                            # => [0, -1, 2, 0, -1]
```

## Numeric gate

`CACategorical`'s surface is `CA_FIXLEN`, so raw arithmetic is refused:

```ruby
cat + 1               # => RuntimeError (numeric ops gated)
```

Numeric operations on category codes are a category error — even if
`("summer" + 1)` compiled, it would not mean anything. When you want to
work in code space, be explicit:

```ruby
cat.codes + 1         # OK — you asked for the raw integers
```

## API summary

| method | returns |
|---|---|
| `CArray#categorize(labels: nil)`         | `CACategorical` — discover vocabulary in first-appearance order |
| `CArray#categorize(labels: vocab)`       | `CACategorical` — fixed vocabulary, off-set keys excluded |
| `CACategorical.from_codes(codes, labels)`| `CACategorical` — wrap already-dense codes + labels (sentinel-aware) |
| `cat.labels`                             | `Array` — frozen label vocabulary |
| `cat.codes`                              | `CArray` — the raw integer codes (= storage parent) |
| `cat.labels.size`                        | `Integer` — the category count |
| `cat[i]`                                 | label (or `UNDEF` if excluded) |
| `cat.eq(label)` / `cat.ne(label)`        | boolean `CArray` (unknown label → all-false) |
| `cat.count(label)`                       | `Integer` — count of one category (unknown label → 0) |
| `cat.category_sizes`                           | length-`k` `CArray` — counts per label, aligned to `labels` |

## Notes

- **READONLY.** `cat[i] = code` raises. To edit a categorical, work on the
  codes parent (`cat.codes[i] = new_code`) with the invariant that codes
  stay in `[0, k)` or equal the sentinel — but usually you build a fresh
  categorical instead.
- **Label vocabulary is frozen at construction.** The container is copied
  and `freeze`d so a caller's array is never frozen as a side effect;
  the label objects themselves are left as-is (container-level freeze).
- **`categorize` is O(N) per label** (one vectorized masked write per
  category). For a huge input with a small vocabulary this is close to
  optimal in Ruby-level code; for very large vocabularies, arriving with
  pre-computed codes and using `from_codes` is faster.
- **Interoperates with [`CAConstString`](CAConstString.md).** A common
  pipeline is `ct = CArray.text(raw); cat = ct.categorize` — the text
  column keeps its bytes shared, and the categorical carries only the
  small `labels` array plus a dense code column.
