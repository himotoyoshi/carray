# Categories and grouping

A recurring shape of question is "compute a statistic *per category*." The mean temperature per season. The count of samples per wind-speed bucket. The maximum value per region on a map. In each case the data carries a **label** — a season, a bucket, a region — and you want one answer for every distinct label.

CArray answers this in two steps. First you build a **categorical**: the object that says which category each cell belongs to. Then you **group** by it, and reduce each group. There are two grouping surfaces, depending on the shape of your problem:

| you have | you reach for |
|---|---|
| a flat array of values + a parallel array of labels | `value.group_by_category(cat)` |
| a grid, grouped along one or more *axes* by their coordinates | `value[cat, nil, …]` with `axis: :group` |

Both consume the same categorical. This chapter teaches the categorical first, then each grouping path in turn.

Everything here works after `require "carray"` — the categorical and grouping classes autoload on first use.

---

## The categorical

A **categorical** is a labelled column: a dense array of integer **codes** plus a small **label** vocabulary. Each cell stores a code — an index `0 … k-1` into the labels — and reading the cell decodes the code back to its label. It is the CArray data type for "this cell is one of a fixed, small set of categories." (If you know a pandas `Categorical` or an Arrow dictionary, it is the same idea.)

The class is `CACategorical`. Two facts drive everything about it:

* The **codes are the storage.** A categorical is a read-only view (a Face) over an integer codes array, so slicing, reshaping, transposing, or gathering a categorical gives you another categorical — the codes ride the view chain, the label vocabulary tags along.
* The surface is **non-numeric.** Arithmetic on a categorical raises — adding `1` to a category is a category error. When you genuinely want the raw integers, ask for `.codes`.

### Building one from data — `categorize`

The everyday constructor is `CArray#categorize`, called on an array of raw category keys. It discovers the distinct levels in **first-appearance order** — not sorted, not hashed to arbitrary order — so re-running on the same input gives the same codes.

```ruby
keys = CArray.object(8) { |i| %w[mar mar jan jan jul jul jan mar][i] }
cat  = keys.categorize

cat.labels        #  => ["mar", "jan", "jul"]       first-appearance order
cat.codes.to_a    #  => [0, 0, 1, 1, 2, 2, 1, 0]
cat.to_a          #  => ["mar", "mar", "jan", "jan", "jul", "jul", "jan", "mar"]
cat.labels.size   #  => 3                            the category count
```

Pass `sort_labels: true` to get the discovered vocabulary ascending instead — the natural form when the categories will head a table or a plot axis:

```ruby
keys = CArray.object(5) { |i| %w[mar jan jul jan mar][i] }
cat  = keys.categorize(sort_labels: true)
cat.labels        #  => ["jan", "jul", "mar"]        alphabetical
cat.codes.to_a    #  => [2, 0, 1, 0, 2]
```

### Imposing a fixed vocabulary

Pass `labels:` to lock the code assignment. This is the reproducible form: the code of every category is stable across runs and datasets, so several columns can share a vocabulary. Any key outside the set is **excluded** — it becomes a masked cell and drops out of every group.

```ruby
keys = CArray.object(5) { |i| %w[jan jul mar jan dec][i] }
cat  = keys.categorize(labels: %w[jan feb mar])   # jul, dec are off-set

cat.labels        #  => ["jan", "feb", "mar"]
cat.to_a          #  => ["jan", UNDEF, "mar", "jan", UNDEF]
cat[1]            #  => UNDEF                        jul excluded
cat.has_mask?     #  => true
```

`sort_labels:` is a discovery-only knob: when you pass an explicit `labels:` you have already chosen the order, so `sort_labels:` is ignored. Duplicate labels raise — the code-to-label mapping must be one-to-one.

### Wrapping codes you already have — `from_codes`

When the data already arrives as dense integer codes — a database join key, an ML feature column, an Arrow dictionary exported from Python, the output of a binning primitive — use `CACategorical.from_codes(codes, labels)` and skip discovery. The `codes` array becomes the storage parent verbatim.

```ruby
codes = CArray.uint8(6) { |i| [0, 1, 0, 2, 1, 0][i] }
cat   = CACategorical.from_codes(codes, %w[tokyo osaka kyoto])
cat.to_a          #  => ["tokyo", "osaka", "tokyo", "kyoto", "osaka", "tokyo"]
```

Excluded cells are identified by the **all-ones sentinel** — type-max for an unsigned code type, `-1` for a signed one — and masked automatically. Both conventions are recognised, so codes imported from either world just work:

```ruby
# signed -1 = missing
codes = CArray.int8(4) { |i| [0, -1, 1, 0][i] }
CACategorical.from_codes(codes, %w[a b]).to_a
                  #  => ["a", UNDEF, "b", "a"]
```

### Binning continuous data

For continuous values (temperature, precipitation, altitude, …) the categories are usually intervals rather than discrete keys. The canonical form is **snap to a grid, then `categorize`** — the labels are the actual snapped values, so you never have to author edges and labels separately.

Two value-returning primitives cover the two grid shapes:

- `snap(step, offset: 0.0)` — snap each value to a **uniform** grid `..., -step + offset, offset, step + offset, ...`
- `snap_to(list, lfill:, ufill:)` — snap each value to the nearest entry of a **non-uniform** ascending list

Both return the snapped value at the source's data type, and because that result is just a coarser version of the input, `categorize` works on it without any special-case handling:

```ruby
temp = CArray.float64(500) { |i| rand * 30 + 268 }        # samples in K

cat = temp.snap(0.5).categorize(sort_labels: true)
cat.labels.first(5)              #  => [268.0, 268.5, 269.0, 269.5, 270.0]
cat.category_sizes.to_a.first(5) #  => counts per snapped bin (aligned to labels)
```

Pass `offset:` to shift the grid phase — `snap(0.5, offset: 0.25)` snaps to `..., 0.25, 0.75, 1.25, ...` (bin centres rather than edges).

If you want a **pinned** grid — one that always shows every bin regardless of which values happened to appear in this particular sample — pass the grid as `labels:` to `categorize`:

```ruby
grid = Array.new(61) { |i| 270.0 + i * 0.5 }              # 270.0, 270.5, ..., 300.0
cat  = temp.snap(0.5).categorize(labels: grid)
cat.category_sizes.to_a          #  length 61; empty bins show as 0
```

For a non-uniform list of thresholds — precipitation rates, log-spaced altitude bands, domain-defined class breakpoints — `snap_to` clamps out-of-range values to the nearest end by default. Pass `lfill: nil` / `ufill: nil` to mask them out instead, or `lfill: value` / `ufill: value` to substitute a sentinel:

```ruby
rain = CArray.float64(6) { |i| [0.2, 3, 15, 0.5, 25, 40][i] }
rain.snap_to([0.0, 1.0, 5.0, 20.0]).to_a
#  => [0.0, 5.0, 20.0, 1.0, 20.0, 20.0]
```

#### Authored labels: `bin_to` + `from_codes`

Sometimes each bin needs a **label that is not a data value** — a `Range`, a class name, a symbol. Use `bin_to(edges)` to get the bin index against an explicit list of edges, then hand a matching `labels:` list to `from_codes`:

```ruby
edges  = [0, 1, 5, 20, 100, 1_000]           # precipitation (mm/h)
labels = %w[trace light moderate heavy violent]

rain = CArray.float64(6) { |i| [0.2, 3, 15, 0.5, 25, 40][i] }
codes = rain.bin_to(edges)                    #  => [0, 1, 2, 0, 3, 3]
cat   = CACategorical.from_codes(codes, labels)
cat.to_a
#  => ["trace", "light", "moderate", "trace", "heavy", "heavy"]
cat.category_sizes.to_a
#  => [2, 1, 1, 2, 0]                         (counts per class, aligned to labels)
```

The sibling `bin(vmin, vmax, bins:)` (uniform equal-width) returns bin indices directly, without the round-trip through snapped values. Reach for the index-returning primitives when you only need integer codes downstream — for a histogram, a weighted aggregation, or a composite grid code (§below). Wrapping a bare bin index in a categorical whose labels are `0..k-1` does not add information.

#### Equal-frequency (quantile) bins

Let the data set the edges so every bin holds roughly the same count: compute the edges with `percentile` and feed them to `bin_to`:

```ruby
temp   = CArray.float64(1000) { |i| rand * 30 + 268 }
n_bins = 10
qs     = Array.new(n_bins + 1) { |i| i * 100.0 / n_bins }   # 0, 10, ..., 100
edges  = temp.percentile(*qs)                                # 11 numeric edges
codes  = temp.bin_to(edges, include_max: true)               # last bin inclusive
labels = Array.new(n_bins) { |i| "q#{i + 1}" }

cat = CACategorical.from_codes(codes, labels)
cat.category_sizes.to_a       #  ≈ [100, 100, ...]  (ties can skew a little)
```

The same shape does quartiles (`n_bins = 4`), deciles (10), or any other equal-frequency scheme.

### Accessors

| accessor | returns |
|---|---|
| `cat.labels` | `Array` — the frozen label vocabulary |
| `cat.labels.size` | `Integer` — the number of categories (the value called `k` in the design docs) |
| `cat.codes` | `CArray` — the raw integer codes (the storage parent) |
| `cat.ndim` | `Integer` — rank of the code map (see [multi-axis categoricals](#multi-axis-categoricals)) |
| `cat.shape` | `Array` — shape of the code map |
| `cat[i]` | the label at cell `i` (or `UNDEF` if excluded) |

> **There is no `cat.k`.** The category count is `cat.labels.size`. Some design notes and older reference text write `cat.k`; that accessor was retired.

### Exclusion: mask and sentinel together

Every excluded cell carries **two** encodings, and because the categorical is read-only they can never drift apart:

* the **mask** — `cat[i]` is `UNDEF`, `cat.is_masked[i]` is `1`, and mask-aware reductions skip it. This is the native CArray idiom;
* the **sentinel value in the code bytes** — the all-ones bit pattern, which a grouping kernel skips by its `[0, k)` range check and which pandas / Arrow expect on the wire.

```ruby
keys = CArray.object(5) { |i| %w[jan jul mar jan dec][i] }
cat  = keys.categorize(labels: %w[jan feb mar])   # jul, dec excluded

cat.is_masked.to_a               #  => [false, true, false, false, true]     the mask
cat.codes.value.to_a             #  => [0, 255, 2, 0, 255]  raw bytes (uint8 type-max)
cat.codes.value.refer(CA_INT8).to_a
                                 #  => [0, -1, 2, 0, -1]    same bytes read signed
```

(`cat.codes.to_a` shows `UNDEF` at the excluded cells, because the codes view carries the mask; `.value` strips the mask to reveal the raw sentinel bytes. See [Masks and missing values](05_masks.md) for `value`.)

### Label-space operations

Because the *value* of a categorical cell is its category, the built-in comparison and counting methods work in **label space** — you name a label, not a code:

```ruby
cat = CArray.object(6) { |i| %w[a b a c b a][i] }.categorize

cat.eq("a").to_a       #  => [true, false, true, false, false, true]     boolean mask, by label
cat.count("a")         #  => 3
cat.count("zzz")       #  => 0                        unknown label -> 0, not an error
cat.category_sizes.to_a      #  => [3, 2, 1]                per-category counts, aligned to labels
```

`category_sizes` always returns a length-`k` array in label order, keeping a trailing `0` for a category that never occurs — so `labels.zip(category_sizes.to_a)` always pairs up:

```ruby
codes = CArray.uint8(4) { |i| [0, 1, 0, 1][i] }
cat   = CACategorical.from_codes(codes, %w[a b c])
cat.codes.bincount.to_a   #  => [2, 2]        (raw bincount truncates trailing zeros)
cat.category_sizes.to_a         #  => [2, 2, 0]     (full k-length, aligned to labels)
```

Excluded cells stay `UNDEF` in `eq` / `ne` — an unknown category matches nothing:

```ruby
keys = CArray.object(4) { |i| %w[a b z a][i] }
keys[2] = UNDEF
cat = keys.categorize
cat.eq("a").to_a          #  => [true, false, UNDEF, true]
```

### Code-space operations — the `.codes` escape hatch

`cat.codes` is the raw storage parent, a plain integer `CArray`. Everything `CArray` offers works there — arithmetic, histograms, joins:

```ruby
cat.codes + 1             # OK — you asked for the raw integers
cat.codes.count(0)        # count of one category by its code
cat.codes.eq(2)           # boolean mask by code
```

The numeric gate is on the categorical surface only, to catch nonsense early:

```ruby
cat + 1                   #  => RuntimeError (numeric ops gated on the categorical)
cat.codes + 1             #  => OK
```

### Multi-axis categoricals

`categorize` works element-wise on any shape, so a categorical can be more than 1-D. The codes array inherits the shape of the input; the label vocabulary is a flat list shared by every cell.

```ruby
regimes = CArray.object(3, 4) { |s, m|
  [[:dry, :dry,   :wet,   :wet],
   [:dry, :storm, :storm, :wet],
   [:wet, :wet,   :dry,   :storm]][s][m]
}
cat = regimes.categorize

cat.labels        #  => [:dry, :wet, :storm]      first-appearance order
cat.shape         #  => [3, 4]
cat.category_sizes.to_a #  => [4, 5, 3]                 dry / wet / storm
```

Slices are themselves categoricals — the vocabulary rides along:

```ruby
cat[0, nil].class    #  => CACategorical
cat[0, nil].to_a     #  => [:dry, :dry, :wet, :wet]
```

And per-axis work drops naturally to the codes parent through the label-space comparisons (note the `axis:` keyword — positional axis arguments are not accepted):

```ruby
# which stations were :dry at least twice?
(cat.eq(:dry).sum(axis: 1) >= 2).to_a    #  => [true, false, false]

# fraction of :storm cells per station
cat.eq(:storm).mean(axis: 1).to_a        #  => [0.0, 0.5, 0.25]
```

A rank-N categorical matters for the axis-group path below: it **consumes N source axes** and collapses them into one group axis — for example a `[lat, lon]` region map that classifies two axes at once.

### More categorization recipes

A few patterns come up often enough to write down; each is a short composition of the three primitives (`categorize`, `from_codes`, and the binning family).

**Rule-based classification.** When the category is a predicate, not a stored key, write straight into a codes array. Start every cell excluded (the all-ones sentinel), then let each rule paint over the cells it matches; anything no rule touches stays masked:

```ruby
x = CA_DOUBLE([-2.0, 0.0, 1.5, -1.0, 3.0])

codes = CArray.uint8(x.size).fill(0xFF)      # start all-excluded
codes[x.eq(0)] = 0
codes[x.lt(0)] = 1
codes[x.gt(0)] = 2

cat = CACategorical.from_codes(codes, %i[zero negative positive])
cat.to_a                #  => [:negative, :zero, :positive, :negative, :positive]
cat.category_sizes.to_a #  => [1, 2, 2]
```

Rules apply in order — a cell hit by two rules lands in the one written last — so put the more specific rule after the more general one, or make the predicates disjoint.

**Normalize before you categorize.** The same key spelled two ways becomes two categories unless you canonicalize first. `convert` is the natural pre-processing step:

```ruby
raw = ["Tokyo ", "tokyo", "OSAKA", "osaka", " Tokyo"]
cat = CA_OBJECT(raw).convert { |s| s.strip.downcase }.categorize
cat.labels        #  => ["tokyo", "osaka"]
cat.to_a          #  => ["tokyo", "tokyo", "osaka", "osaka", "tokyo"]
```

Anything that returns a comparable value works — a domain mapping (`{ "JP" => "Japan", ... }`), a locale-safe fold, or a stemmer.

**Top-K + "other".** Discover the K most frequent categories, fold the rest into a single "other" bucket. Two passes: discover, decide, re-categorize with a fixed vocabulary:

```ruby
keys = CA_OBJECT(%w[a b c a a b d e a b c f a])
K    = 2

tmp = keys.categorize
top = tmp.labels.zip(tmp.category_sizes.to_a)
        .sort_by { |_, n| -n }.first(K).map(&:first)
#  top => ["a", "b"]

folded = keys.convert { |k| top.include?(k) ? k : "other" }
cat    = folded.categorize(labels: top + ["other"])
cat.labels               #  => ["a", "b", "other"]
cat.category_sizes.to_a  #  => [5, 3, 5]
```

**Time-of-year grouping.** For a `CATime` array (see [Time arrays](26_time_arrays.md)), how you categorize the timestamp depends on whether the group is a **fixed cycle** (Jan…Dec, Mon…Sun, spring…winter) or a **data-driven period** (which year-months actually appear in this dataset).

Fixed cycle — climatology, one bucket per month regardless of year:

```ruby
month = dt.month                                        # 1..12
cat   = month.categorize(labels: (1..12).to_a)
cat.labels           #  => [1, 2, 3, ..., 12]
cat.category_sizes.to_a   #  => [n_jan, n_feb, ..., n_dec]
```

Seasons are a rule-based collapse of the same field:

```ruby
season = month.convert(:object) { |m|
  [nil, :winter, :winter, :spring, :spring, :spring,
        :summer, :summer, :summer, :autumn, :autumn,
        :autumn, :winter][m]
}
cat = season.categorize(labels: %i[spring summer autumn winter])
```

Data-driven period — one bucket per distinct year-month that appears in the data. Format the timestamps as ISO strings so that first-appearance order (which is what `categorize` gives) *is* chronological order, as long as the input timestamps arrive in time order:

```ruby
cat = dt.strftime("%Y-%m").categorize
cat.labels           #  => ["2023-11", "2023-12", "2024-01", ...]
```

If the input timestamps might arrive out of order, cast the ISO strings to an object array first (`dt.strftime("%Y-%m").to_type(:object).categorize( sort_labels: true)`) so that the labels can be sorted lexicographically. The same shape does annual (`"%Y"`), daily (`"%Y-%m-%d"`), or sub-daily periods.

**Combining two categoricals (cross-product).** To group by two categoricals at once (station × regime, sensor × severity), form a joint code `a.codes * b.labels.size + b.codes` and pair the labels:

```ruby
a = station.categorize                # labels ["sapporo", "tokyo"]
b = regime .categorize                # labels [:dry, :wet, :storm]

joint_codes  = a.codes * b.labels.size + b.codes
joint_labels = a.labels.product(b.labels)
joint = CACategorical.from_codes(joint_codes, joint_labels)

joint.category_sizes.reshape(a.labels.size, b.labels.size)
# a station × regime contingency table
```

Excluded cells in either input propagate — masked codes stay masked through the arithmetic.

**Spatial grid — `(lat, lon)` → cell index.** Two `bin` calls on the axes, one flattening step, one `from_codes`:

```ruby
n_rows, n_cols = 2, 3
i = lat.bin(lat_min, lat_max, bins: n_rows)      # row index in [0, n_rows)
j = lon.bin(lon_min, lon_max, bins: n_cols)      # col index in [0, n_cols)

cell_codes  = i * n_cols + j
cell_labels = Array.new(n_rows * n_cols) { |c| [c / n_cols, c % n_cols] }

cells = CACategorical.from_codes(cell_codes, cell_labels)
```

Any point outside the lat/lon range is excluded on the corresponding input, so `cell_codes` inherits the union of the masks.

The full categorical reference is CACategorical.md.

---

## Categorical group-by — `group_by_category`

The first grouping path is for a **flat** problem: an array of values, and a parallel array of labels, both read cell for cell. You want one statistic per category.

`value.group_by_category(cat)` returns a **`CACategoricalIterator`**, whose reduction methods each return a length-`k` array — one value per category, aligned to `cat.labels`.

```ruby
keys   = CA_OBJECT(%w[b a b c a b])
values = CA_INT32([10, 20, 30, 40, 50, 60])
cat    = keys.categorize                    # labels: ["b", "a", "c"]

grp = values.group_by_category(cat)

grp.labels     #  => ["b", "a", "c"]
grp.elements   #  => [ 3, 2, 1 ]                       cells per category
grp.sum        #  => [ 100.0, 70.0, 40.0 ]             float64, as CArray#sum
grp.accumulate #  => [ 100, 70, 40 ]                   int32, the fold kept in type
grp.mean       #  => [ 33.333…, 35.0, 40.0 ]           float64
grp.median     #  => [ 30.0, 35.0, 40.0 ]
```

The categorical carries the classification; `value` is only data. A cell of `value` belongs to a category iff the corresponding cell of `cat` has that category. The two must have the same number of elements — both are read flat, so they may be N-dimensional and of different shapes.

The guiding rule is simple:

> **A category's statistic equals the CArray reduction over that category's members.** `grp.mean[i]` is `members.mean`, `grp.variance[i]` is `members.variance`, and so on.

So everything you know about how a reduction treats an ordinary array — how it skips masked cells, what it returns on a short or empty array — carries over group by group.

### Excluded cells drop out

A cell is excluded — out of vocabulary, or masked in `cat` — when it joins no group. It simply does not count anywhere:

```ruby
keys   = %w[x y z x q x]                                  # 'q' is out of vocabulary
values = CA_DOUBLE([1, 2, 3, 4, 5, 6])
cat    = CA_OBJECT(keys).categorize(labels: %w[x y z w])  # 'w' never appears

grp = values.group_by_category(cat)
grp.labels     #  => ["x", "y", "z", "w"]
grp.elements   #  => [ 3, 1, 1, 0 ]      'q' dropped; x = {1, 4, 6}; w empty
grp.sum        #  => [ 11.0, 2.0, 3.0, 0.0 ]
```

### Two counts: `elements` and `count_not_masked`

Two masks meet here — the categorical's exclusion, and a mask carried by `value` itself. The difference shows up in the counts:

* `elements` counts the cells **classified** into a category, including cells whose `value` is masked;
* `count_not_masked` (also `count` with no argument) counts the **present** cells — the ones a reduction actually uses as its denominator.

They agree unless `value` carries a mask.

```ruby
keys = %w[a a a b]
vals = CA_DOUBLE([10, 20, 30, 40]); vals[1] = UNDEF   # one value missing
cat  = CA_OBJECT(keys).categorize(labels: %w[a b c])

grp = vals.group_by_category(cat)
grp.elements          #  => [ 3, 1, 0 ]        cells classified into a / b / c
grp.count_not_masked  #  => [ 2, 1, 0 ]        present cells (a lost one)
grp.sum               #  => [ 40.0, 40.0, 0.0 ]  10 + 30, skipping the masked 20
grp.mean              #  => [ 20.0, 40.0, UNDEF ]  40 / 2 present, not 40 / 3
```

`mean` divides by `count_not_masked`, exactly as `CArray#mean` skips masked cells (see [Masks and missing values](05_masks.md)).

### Empty and all-masked groups

A group with no present cells reduces like an empty array, following the core [empty-reduction contract](04_reduction_and_statistics.md):

* reductions with an identity return it — `sum` gives `0`, `prod` gives `1`;
* reductions without one — `mean`, `median`, `variance`, `stddev`, `min`, `max` — return a masked (`UNDEF`) cell, because there is no value to report;
* the counts (`elements`, `count_not_masked`, `count_masked`) are always defined integers, never masked.

```ruby
# category 'c' above is empty:
grp.sum[2]              #  => 0.0     empty sum is the identity (unmasked)
grp.mean.is_masked[2]   #  => 1       empty mean is undefined (masked)
```

Because the empty slot is a genuine masked cell — not a magic `NaN` — a downstream calculation propagates the missing-ness through the mask.

A single-value group is not empty: its sample variance is `0.0`, matching `CArray#variance` on a one-element array:

```ruby
cat = CA_OBJECT(%w[a b b]).categorize
grp = CA_DOUBLE([5, 10, 20]).group_by_category(cat)
grp.variance   #  => [ 0.0, 50.0 ]     'a' has one value -> 0.0, not masked
```

### Sorting within groups — `sort_addr`

`sort_addr` returns a single flat array of the **source** addresses that sort each category's members, laid out group-major: segment `c` holds category `c`'s addresses in ascending-value order, and the segments follow `labels` order. Gathering the raveled source by it yields the values grouped and sorted within each group:

```ruby
keys = %w[b a b c a b]
val  = CA_INT32([10, 30, 60, 40, 50, 20])
grp  = val.group_by_category(CA_OBJECT(keys).categorize)  # b={10,60,20}, a={30,50}, c={40}

grp.sort_addr                 #  => [ 0, 5, 2, 1, 4, 3 ]    flat source addresses
val.reshape(6)[grp.sort_addr] #  => [ 10, 20, 60, 30, 50, 40 ]   sorted within b | a | c
```

A masked value sorts to the tail of its segment (as `CArray#sort` sends masked cells to the end). There is no group-*local* sort index — the grouped copy is already category-contiguous, so only the source-address form is offered, mirroring `min_addr` (kept) versus a within-group index (skipped).

### Custom per-group work — `each` / `reduce` / `map`

When the named reductions do not cover what you need, three methods hand you each group's members so you can compute it yourself — the same escape hatch as [`each_slab` / `reduce_slab` / `map_slab`](11_slab_iteration.md).

```ruby
cat = CA_OBJECT(%w[a a b b]).categorize
grp = CA_DOUBLE([10, 20, 30, 40]).group_by_category(cat)

grp.each { |members| p members.to_a }   # side effect only; returns self
#  => [10.0, 20.0]
#  => [30.0, 40.0]

# reduce: one value per category
grp.reduce { |members| members.max - members.min }   #  => [ 10.0, 10.0 ]
grp.reduce(0.0) { |acc, x| acc + x }                  #  => [ 30.0, 70.0 ]

# map: group-wise element-wise transform, back into a source-shaped array
grp.map { |members| members - members.mean }          #  => [ -5.0, 5.0, -5.0, 5.0 ]
```

`each` with no block returns an `Enumerator`. `reduce` returns a length-`k` array (`init` gives the inject-style form). `map` returns a new array shaped like the source `value` — the block returns a same-length CArray (scattered cell for cell) or a scalar (broadcast over the group); cells in no category are `UNDEF`. Use `value[] = grp.map { … }` for an in-place update.

The iterator does **not** mix in `Enumerable` — only the methods documented here are defined. A name that is not defined is a plain `NoMethodError`, not a wrong answer.

### N-dimensional value and categorical

`value` and `cat` may be N-dimensional; both are read flat, so the result is still one value per category. Position does not matter — cells are grouped purely by category:

```ruby
keys = CA_OBJECT([%w[a b], %w[b a]])   # 2x2
vals = CA_DOUBLE([[1, 2], [3, 4]])
grp  = vals.group_by_category(keys.categorize)
grp.labels   #  => ["a", "b"]
grp.sum      #  => [ 5.0, 5.0 ]     a = {(0,0), (1,1)}, b = {(0,1), (1,0)}
```

---

## Axis-group — grouping a grid by its coordinates

The second grouping path is for a **grid**. Here the categories run along an *axis*: a `[time, lat, lon]` field grouped by season along the time axis, a map grouped by region along its spatial axes, values grouped by which longitude band they sit in. You keep the other axes and fold each group.

This is a newer, 3.x-era surface. The support-class names (`AxisGroup`, `CAGroupIterator`, `GroupLabels`) are still provisional and may be renamed; the surface described here — build a categorical, position it, reduce with `:group`, read labels — is the stable part.

The full reference is AxisGroup.md and CAGroupIterator.md.

### Positioning the categorical

You place the categorical against the array **one slot per axis**. The slot position *is* the source axis:

| slot | meaning |
|---|---|
| a `CACategorical` | a **group axis** — consumes `cat.ndim` source axes, collapses them into one output axis of length `cat.labels.size` |
| `nil` | a **band axis** — kept as-is |

```ruby
season = CArray.object(12) { |t|
  %w[DJF DJF MAM MAM MAM JJA JJA JJA SON SON SON DJF][t]
}.categorize                                   # 12 months -> 4 seasons

temp = CArray.float64(12, 2, 3) { |t, y, x| t + y * 0.5 + x * 0.25 }

temp[season, nil, nil].mean(axis: :group).shape   #  => [4, 2, 3]   season x lat x lon
```

The `season` slot is a group axis (the 12 months collapse to 4 seasons); the two `nil` slots are band axes, kept as-is. The result carries a seasonal mean for every `(lat, lon)`.

**All axes must be given explicitly.** The slots must account for exactly `value.ndim` source axes — there is no trailing omission and no implicit `nil` fill. A spec that silently guesses the axes it wasn't told about is a spec you have to second-guess:

```ruby
temp.axis_group(season)        #  => raises IndexError: 1 of 3 axes
temp.axis_group(season, nil)   #  => raises IndexError: 2 of 3 axes
```

### The `axis: :group` keyword is required

Indexing an array with a group spec does **not** return an array — it returns a `CAGroupIterator`, a reduction dispatcher holding the value and the spec. You reach a result by calling a reduction on it *with* `axis: :group`.

That keyword is required by design. The very same indexer (`value[cat, nil]`) can also do ordinary selection, so grouping is **opt-in**: only `axis: :group` engages it. Without it, the value is reduced plainly, ignoring the grouping:

```ruby
gi = temp[season, nil, nil]

gi.mean(axis: :group)   # group reduction         -> shape [4, 2, 3]
gi.mean(axis: 1)        # plain reduce over axis 1 -> shape [12, 3]
gi.mean                 # plain reduce over all    -> a scalar
```

`axis: :group` reduces every group axis and keeps the band axes as output axes, in **slot order** — a group axis stays at its slot position, it is not pulled to the front:

```ruby
s = CArray.float64(2, 3, 12) { |i, j, k| i + j + Math.cos(k) }
s[nil, nil, season].mean(axis: :group).shape   #  => [2, 3, 4]   band, band, group
```

### The reductions

The group iterator exposes the [iterator-family surface](21_iterator_family.md), each taking `axis: :group`:

```
sum   accumulate   prod   mean   min   max
variance   stddev   variancep   stddevp
count   count_masked   elements   minmax
wsum(w)   wmean(w)
median   percentile(p)   quantile
min_addr   max_addr   sort_addr
```

Each result matches the core `CArray` reduction over each group's members, so the empty / all-masked contract carries through unchanged — `sum` of an empty group is `0` (identity), `mean` / `median` of an empty group is a masked cell:

```ruby
keys = CArray.object(4) { |i| %w[a a c c][i] }
cat  = keys.categorize(labels: %w[a b c])       # category "b" is unused
a    = CArray.float64(4) { |i| i + 1.0 }

a[cat].mean(axis: :group).to_a     #  => [1.5, UNDEF, 3.5]
a[cat].count(axis: :group).to_a    #  => [2, 0, 2]
```

Masked input cells and out-of-vocabulary keys are simply left out of their group, so masks and grouping compose without ceremony.

### Position: `min_addr`, not `min_index`

A group preserves source order, so a *within-group* index is weak. The group returns the **flat source address** of the winning cell instead, which you index back into the raveled source:

```ruby
data  = CArray.float64(4, 6) { |s, m| 10 + s + m }
gi    = data[nil, season]                        # (station, month->season)
addr  = gi.min_addr(axis: :group)                # shape [4, 3]
data.reshape(data.elements)[addr]                # the group minima
```

`min_index` / `max_index` are not provided on this iterator — calling one raises `NotImplementedError`. This is the one place the group iterator differs from the rest of the [iterator family](21_iterator_family.md).

### Folding a band axis into the statistic

`axis: [:group, n]` reduces the group axes **and** folds band slot `n` into the same statistic — a partial reduction. The folded axis disappears from the output:

```ruby
mon = CArray.object(6) { |i| %w[jan jan feb feb mar mar][i] }.categorize
lon = CArray.object(4) { |j| %w[E E W W][j] }.categorize
t   = CArray.float64(6, 4, 5) { |i, j, k| i + j + k }

g = t.axis_group(mon, lon, nil)   # slots: [group mon, group lon, band k]

t[g].mean(axis: :group).shape       #  => [3, 2, 5]   mon x lon x k
t[g].mean(axis: [:group, 2]).shape  #  => [3, 2]      mon x lon, k folded in
```

The integer in `[:group, n]` is a **band** slot position; naming a group slot there is an error, because `:group` already reduces the group axes:

```ruby
t[g].mean(axis: [:group, 0])      #  => raises IndexError: slot 0 is a group axis
```

### Order statistics

`median`, `percentile(p)`, and `quantile` (the five-number summary `[min, Q1, median, Q3, max]`) work per group too. Unlike the tier-1 reductions they cannot be scattered — an order statistic needs every member of a group held together — so they materialize one band fiber at a time, keeping peak memory proportional to the group axis length, not the whole array:

```ruby
temp = CArray.float64(6, 4) { |i, j| Math.sin(i) + j }   # [time, station]
seas = CArray.object(6) { |i| %w[a a b b c c][i] }.categorize
gi   = temp[seas, nil]                                    # group axis 0, band = station

gi.median(axis: :group).shape         #  => [3, 4]   per-(season, station) median
gi.percentile(90, axis: :group).shape #  => [3, 4]
gi.quantile(axis: :group).map(&:shape) #  => [[3, 4], [3, 4], [3, 4], [3, 4], [3, 4]]
```

Folding a band *into* an order statistic (`axis: [:group, n]`) raises `NotImplementedError` — it gathers a group axis and a band axis into one statistic, a different operation, and remains a follow-up.

### The value is a shape template

`axis_group` reads only the **shape** of `value` — its rank and axis lengths — never its data. So a spec is value-independent and can be reused across every array with the same shape:

```ruby
g     = temp.axis_group(season, nil, nil)   # (never touches temp's data)
other = CArray.float64(12, 2, 3) { |t, y, x| t * 7 + y - x }

temp[g].mean(axis: :group)    # season means of temp
other[g].sum(axis: :group)    # season sums of a different field, same spec
```

The inline `value[cat, nil, …]` form is exactly `value[value.axis_group(cat, nil, …)]` — build the spec once when you reuse it, index directly when you don't.

### Composite and rank-N groupings

Two extensions come for free, because internally every grouping reduces to one *composite* classification over the group axes — you do not learn a new API.

**Several group axes** — group by more than one categorical at once; the result gets one axis per group slot:

```ruby
mon = CArray.object(6) { |i| %w[jan jan feb feb mar mar][i] }.categorize
lon = CArray.object(4) { |j| %w[E E W W][j] }.categorize
t   = CArray.float64(6, 4) { |i, j| i + j }

t[mon, lon].sum(axis: :group).shape   #  => [3, 2]   mon x lon
```

**A rank-N categorical** — a single categorical built from an N-D map consumes several source axes and collapses them into **one** group axis. Here a `[lat, lon]` region map classifies two axes into one region axis; the regions need not be rectangular, because the grouping follows the coordinate label, not the grid geometry:

```ruby
field  = CArray.float64(4, 2, 3) { |t, y, x| t * 100 + y * 10 + x }
region = CArray.object(2, 3) { |y, x|
  [%w[sea sea land], %w[land ice ice]][y][x]
}.categorize                                   # rank-2: consumes 2 axes

g = field.axis_group(nil, region)   # band time axis, group over lat + lon
field[g].mean(axis: :group).shape   #  => [4, 3]   time x region
```

### Reading the coordinates back — `labels`

A reduced result is a bare array — its group axis is "group 0", "group 1", … with no names attached. `g.labels` reattaches the coordinates in the same index space as the result. A group axis contributes its category label; a band axis contributes its integer index.

For one output block, pass its index:

```ruby
g = temp.axis_group(season, nil, nil)
g.labels(0, 0, 0)   #  => ["DJF", 0, 0]
g.labels(2, 1, 0)   #  => ["JJA", 1, 0]
```

For the whole result, `g.labels` (or `value[g].labels`) returns a `GroupLabels` view whose shape matches the reduction cell for cell:

```ruby
mon = CArray.object(6) { |i| %w[jan jan feb feb mar mar][i] }.categorize
lon = CArray.object(4) { |j| %w[E E W W][j] }.categorize
t   = CArray.float64(6, 4) { |i, j| i + j }
g   = t.axis_group(mon, lon)

lab = t[g].labels
lab.shape       #  => [3, 2]
lab[0, 0]       #  => ["jan", "E"]
lab[2, 1]       #  => ["mar", "W"]
```

The per-axis label vectors — the headings you would put on a table — are available directly:

```ruby
lab.axis(0)     #  => ["jan", "feb", "mar"]   the mon axis labels
lab.axis(1)     #  => ["E", "W"]              the lon axis labels
lab.coords      #  => [["jan", "feb", "mar"], ["E", "W"]]   all headings
```

`GroupLabels` builds block tuples on demand from these small per-axis vectors — it never materializes the full tuple table, so it stores one vector per output axis regardless of how many blocks there are.

### Custom per-group work

`each`, `map`, and `reduce` are available here too, and — unlike the named reductions — they take **no** `axis: :group`, because they have no plain form. They always group, materializing one band block at a time:

```ruby
season = CA_INT32([0, 0, 1, 1]).categorize
d      = CArray.float64(2, 4) { |s, m| s + m * 1.0 }
gi     = d[nil, season]

gi.map { |members| members - members.mean }   # centre within each group, source-shaped
```

---

## Worked example: monthly climatology

A `[time, lat, lon]` field, grouped into meteorological seasons along the time axis.

```ruby
require "carray"

nt, nlat, nlon = 12, 2, 3
temp = CArray.float64(nt, nlat, nlon) { |t, y, x| 15 + t + y * 0.5 + x * 0.25 }

season = CArray.object(nt) { |t|
  %w[DJF DJF MAM MAM MAM JJA JJA JJA SON SON SON DJF][t]
}.categorize(labels: %w[DJF MAM JJA SON])

# seasonal mean field: one (lat, lon) map per season
g    = temp.axis_group(season, nil, nil)
clim = temp[g].mean(axis: :group)
clim.shape                    #  => [4, 2, 3]

# name the season axis
g.labels.axis(0)              #  => ["DJF", "MAM", "JJA", "SON"]

# spatial mean per season: fold both band axes into the statistic
zonal = temp[g].mean(axis: [:group, 1, 2])
zonal.shape                   #  => [4]
season.labels.zip(zonal.to_a) #  => [["DJF", …], ["MAM", …], ["JJA", …], ["SON", …]]
```

---

## Which grouping do I use?

Both consume a categorical, but they answer different shapes of question.

| | `group_by_category` | axis-group (`value[cat, …]`) |
|---|---|---|
| input | a flat value array + a parallel categorical | a grid + a categorical positioned on axes |
| groups by | which category each cell has | which coordinate each axis position has |
| result | length-`k`, one per category | one axis per group slot, band axes kept |
| kept axes | none — the value is read flat | the band (`nil`) axes ride through |
| order statistics | yes (materializes once) | yes (materializes per band block) |
| best for | a flat categorical; many statistics on one grouping | a grid grouped along axes; reuse one spec across fields |

If you only want counts, note that the dedicated `histogram` surface is simpler than either — no categorical to build. Grouping earns its keep once the reduction goes beyond counting (`mean`, `variance`, weighted sums), you need order statistics, or one classifier drives several reductions.

Both engines are consistent with the rest of CArray: masks pass straight through, excluded cells drop out of their group, and empty groups follow the core [empty-reduction contract](04_reduction_and_statistics.md) — identity for `sum` / `count`, `UNDEF` for ratios and extrema.

---

## Reference: `CACategoricalIterator` (`group_by_category`)

Every reduction returns a length-`k` `CArray` aligned to `cat.labels` unless noted. `k` is `cat.labels.size`. Each one is the core reduction lifted to the category, so its result data type is the one `CArray#<op>` promotes the value to.

| method | result | notes |
|---|---|---|
| `labels` | `Array` | the vocabulary the results align to |
| `elements` | int64 | cells classified into the category (includes value-masked cells) |
| `count` | int64 | present (non-masked) cells; no argument = `count_not_masked` |
| `count_not_masked` | int64 | present cells — the reductions' denominator |
| `count_masked` | int64 | masked cells; `count(UNDEF)` is the same |
| `count(v)` | int64 | cells whose value equals `v` |
| `sum` | as `CArray#sum` | float64 for an integer value; empty / all-masked = `0` (identity) |
| `accumulate` | value data type | the same fold kept in the value's own type, wrapping at its width |
| `prod` | as `CArray#prod` | float64 for an integer value; empty / all-masked = `1` (identity) |
| `min` / `max` | as `CArray#min` / `#max` | the value's own type (a boolean widens to uint64); empty / all-masked = `UNDEF` |
| `minmax` | `[min, max]` | pair of length-`k` arrays |
| `mean` | as `CArray#mean` | float64 for an integer value, exact for an object one; empty / all-masked = `UNDEF` |
| `variance` / `stddev` | as `CArray#variance` / `#stddev` | sample (ddof = 1); single value = `0.0` |
| `variancep` / `stddevp` | as `CArray#variancep` / `#stddevp` | population (ddof = 0) |
| `median` | as `CArray#median` | = `percentile(50)` |
| `percentile(p)` | as `CArray#percentile` | `p` in `0..100` |
| `quantile` | `Array<CArray>` | five-number summary `[min, Q1, median, Q3, max]` |
| `wsum(w)` / `wmean(w)` | float64 | weighted; `w` is a per-cell weight in source order |
| `all` / `any` | boolean | boolean value data type only |
| `min_index` / `max_index` | int64 | group-local position of the min / max |
| `min_addr` / `max_addr` | int64 | flat source address of the min / max |
| `sort_addr` | int64 | length-`nvalid`, source addresses that sort each group, group-major |
| `each { \|members\| … }` | self | yields each category's members; no block → `Enumerator` |
| `reduce { \|members\| … }` | length-`k` | custom per-group reduction |
| `reduce(init) { \|acc, x\| … }` | length-`k` | inject-style per-group fold |
| `map { \|members\| … }` | source-shaped `CArray` | group-wise transform; cells in no category → `UNDEF` |

## Reference: `CAGroupIterator` (`value[cat, …]`)

The named reductions take `axis: :group` to engage grouping; `each` / `map` / `reduce` always group and take no `axis:`. Output is in **slot order** (each group slot → its `k`, each band slot → its length).

| method | notes |
|---|---|
| `sum` `prod` `mean` `min` `max` | tier-1, scattered (peak O(1)) |
| `variance` `stddev` `variancep` `stddevp` | as above |
| `count` `count_masked` `elements` `minmax` | as above |
| `wsum(w)` `wmean(w)` | weighted; `w` is source-shaped |
| `median` `percentile(p)` `quantile` | materialize one band block at a time |
| `min_addr` `max_addr` | flat source address (no `min_index` / `max_index` here) |
| `sort_addr` | per-group sorted flat source addresses, group-major |
| `axis: :group` | required, engages grouping |
| `axis: [:group, n]` | also folds band slot `n` into the statistic (not for order statistics) |
| `each` / `map` / `reduce` | custom per-group work; always group, no `axis:` |
| `g.labels` | `GroupLabels` — coordinate labels in the result's index space |
| `g.labels(i, j, …)` | the label tuple for one output block |
| `g.labels.axis(k)` / `.coords` | per-axis label vectors (table headings) |

## See also

* CACategorical.md — the categorical in full: binning continuous data, rule-based classification, time grouping, interop.
* CACategoricalIterator.md — the categorical group-by reference.
* AxisGroup.md and CAGroupIterator.md — the axis-group reference.
* [The iterator family](21_iterator_family.md) — the shared reduction surface both group iterators belong to.
* [Per-slab iteration](11_slab_iteration.md) — the `each` / `map` / `reduce` escape hatch, per axis.
* [Reduction and statistics](04_reduction_and_statistics.md) — the per-array reductions each group delegates to, and the empty-reduction contract.
* [Masks and missing values](05_masks.md) — the mask contract the reductions follow.
* [Indexing and slicing](02_indexing_and_slicing.md) — how `value[cat, nil, …]` fits the general indexer.
