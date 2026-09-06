# Axis-group reduction: grouping a grid by its coordinates

`axis_group` classifies the elements of a grid array **by their position
along an axis** and reduces each group — a monthly climatology from a
`[time, lat, lon]` field, a per-region average from a region map, a
seasonal mean folded over longitude. It is the CArray relative of an
xarray `groupby`, with one deliberate difference: CArray has no
scale/label attached to an axis, so you hand the classifier in
**explicitly**.

The classifier is a **categorical** — a small labelled partition of one
(or several) source axes:

```ruby
season = CArray.object(12) { |t| %w[DJF DJF MAM MAM MAM JJA JJA JJA SON SON SON DJF][t] }
                .categorize                  # 12 months -> 4 season labels
```

You then position it against the array, one slot per axis, and reduce:

```ruby
temp = CArray.float64(12, 2, 3) { |t, y, x| t + y * 0.5 + x * 0.25 }

clim = temp[season, nil, nil].mean(axis: :group)
clim.shape                       # => [4, 2, 3]   season x lat x lon
```

The `season` slot is a **group axis** (the 12 months collapse to 4
seasons); the two `nil` slots are **band axes**, kept as-is. The result
carries a seasonal mean for every `(lat, lon)`.

This is a newer, 3.x-era feature. The support-class names
(`AxisGroup`, `CAGroupIterator`, `GroupLabels`) are still provisional
and may be renamed; the surface described here — how you build a
classifier, position it, reduce, and read labels — is the stable
part. `CACategorical` itself is documented in
[CACategorical.md](../objects/CACategorical.md).

Everything in this guide works after `require "carray"`.

---

## 1. The classifier: `CACategorical`

A `CACategorical` is a categorical data type: dense integer **codes** (`0 …
k-1`) plus a **label** vocabulary. Structurally it is the same idea as a
pandas `Categorical` or an Arrow dictionary — each cell is an index into
a small set of categories. [CACategorical.md](../objects/CACategorical.md) is the
full reference; the summary below covers what you need to build one to
hand to `axis_group`.

### Building one

Four entry points cover the everyday cases — discrete keys, continuous
values snapped to a grid, and already-dense codes.

**`keys.categorize`** — discover the levels from data, in
first-appearance order (stable, reproducible). Pass
`sort_labels: true` to get the discovered vocabulary ascending — the
natural form when the group axis will be a table heading or a plot
axis:

```ruby
keys = CArray.object(8) { |i| %w[mar mar jan jan jul jul jan mar][i] }
keys.categorize.labels                     # => ["mar", "jan", "jul"]  (first-appearance)
keys.categorize(sort_labels: true).labels  # => ["jan", "jul", "mar"]  (ascending)
```

**`keys.categorize(labels: set)`** — pin a fixed vocabulary. Keys
outside the set are **excluded** (masked), so they drop out of every
group; the code / label assignment is stable across runs and datasets:

```ruby
keys = CArray.object(5) { |i| %w[jan jul mar jan dec][i] }
cat  = keys.categorize(labels: %w[jan feb mar])   # jul, dec off-set

cat.labels        # => ["jan", "feb", "mar"]
cat[1]            # => UNDEF                       jul excluded
```

**`values.snap(step).categorize`** — for continuous values, snap first
to a grid, then categorize. The labels come out as the actual snapped
values, no separate authoring of edges or level names:

```ruby
temp = CArray.float64(500) { rand * 30 + 268 }        # samples in K

# Sample-driven grid — labels are only the grid points that appeared
temp.snap(0.5).categorize(sort_labels: true).labels
                                             # => [270.0, 270.5, …, 297.5]

# Pinned grid — labels stay length-61 even where no sample landed
grid = Array.new(61) { |i| 270.0 + i * 0.5 }          # 270.0, 270.5, …, 300.0
temp.snap(0.5).categorize(labels: grid).labels
                                             # => [270.0, 270.5, …, 300.0]
```

Non-uniform grids use `snap_to(list)`; authored labels (a `Range`, a
class name, …) use `bin_to(edges)` + `from_codes(codes, labels)`. See
[CACategorical.md §1.4](../objects/CACategorical.md#4-binning-continuous-data)
for the full recipes.

**`CACategorical.from_codes(codes, labels)`** — wrap codes that are
*already* dense (pandas `Categorical` / Arrow dictionary import,
rule-based classification, `bin_to` output):

```ruby
codes = CArray.uint8(6) { |i| [0, 1, 0, 2, 1, 0][i] }
cat   = CACategorical.from_codes(codes, %w[tokyo osaka kyoto])
cat[3]            # => "kyoto"
```

### Reading it

The element *value* of a categorical is its category, so per-cell access
decodes the code back to its label, and the classifier answers questions
in **label space** (you never touch the integer codes):

```ruby
cat = CArray.object(6) { |i| %w[tokyo osaka tokyo kyoto osaka tokyo][i] }.categorize

cat.eq("tokyo").to_a      # => [1, 0, 1, 0, 0, 1]    boolean mask, by label
cat.count("tokyo")        # => 3                       cells in a category
cat.category_sizes.to_a         # => [3, 2, 1]               per-category counts
cat.labels.zip(cat.category_sizes.to_a)
                          # => [["tokyo", 3], ["osaka", 2], ["kyoto", 1]]
```

`#category_sizes` is aligned to `#labels`: a category that never occurs is kept
as a trailing `0`, so `labels.zip(category_sizes.to_a)` always pairs up.

The raw codes stay reachable as `cat.codes` (a plain integer CArray) for
code-space work — interop, ML features — but they are not the everyday
surface.

### Multi-axis (rank-N) categoricals

A categorical can be more than 1-D. A rank-N categorical is an N-D code
map (for example a `[lat, lon]` region map): it **consumes N source
axes** and collapses them into a single group axis.

```ruby
region_map = CArray.object(2, 3) { |y, x|
  [%w[sea sea land], %w[land ice ice]][y][x]
}
region = region_map.categorize

region.ndim       # => 2
region.shape      # => [2, 3]
region.labels     # => ["sea", "land", "ice"]
region.labels.size # => 3
```

The regions here are **not rectangular** — "land" straddles both rows.
That is the point: the grouping follows the coordinate label, not the
grid geometry.

---

## 2. Positioning the classifier: `axis_group`

`value.axis_group(slot0, slot1, …)` builds a **grouping spec**. The slot
position *is* the source axis:

| slot | meaning |
|---|---|
| a `CACategorical` | a **group axis** — consumes `cat.ndim` source axes, collapses them to one output axis of length `cat.labels.size` |
| `nil` | a **band axis** — kept as-is |

```ruby
temp = CArray.float64(12, 2, 3) { |t, y, x| t + y * 0.5 + x * 0.25 }
g    = temp.axis_group(season, nil, nil)
g                        # => #<AxisGroup ndim=3 slots=[g4, band, band]>
```

**All axes must be given explicitly.** The slots must account for exactly
`value.ndim` source axes — there is no trailing omission and no implicit
`nil` fill. This is CArray's explicit-over-implicit stance: a spec that
silently guesses the axes it wasn't told about is a spec you have to
second-guess.

```ruby
temp.axis_group(season)          # raises IndexError: 1 of 3 axes
temp.axis_group(season, nil)     # raises IndexError: 2 of 3 axes
```

A rank-2 region categorical consumes two consecutive axes; the remaining
axis is still spelled out:

```ruby
field = CArray.float64(4, 2, 3) { |t, y, x| t * 100 + y * 10 + x }
field.axis_group(nil, region)    # band axis 0, group over axes 1 and 2
```

### The value is a shape template

`axis_group` reads only the **shape** of `value` — its rank and axis
lengths — never its data. So a spec is value-independent and can be
reused across every array with the same shape:

```ruby
g     = temp.axis_group(season, nil, nil)
other = CArray.float64(12, 2, 3) { |t, y, x| t * 7 + y - x }

temp[g].mean(axis: :group)       # season means of temp
other[g].sum(axis: :group)       # season sums of a different field, same spec
```

### The one-shot form

If you don't need to keep the spec, index the value directly. `value[cat,
nil, …]` builds the spec inline — the two forms are equivalent:

```ruby
temp[season, nil, nil].mean(axis: :group)   # one-shot
temp[g].mean(axis: :group)                  # pre-built, same result
```

Either way, indexing with a group spec does **not** return an array — it
returns a `CAGroupIterator`, a small reduction dispatcher that holds the
value plus the spec. There is no `to_ca` / `copy` / materialise path; you
reach the result by calling a reduction on it (next section). This is the
pandas-`GroupBy` shape: `df.groupby(...)` isn't a frame, it's a thing you
reduce.

---

## 3. Reducing: `axis: :group`

The group iterator exposes a tier-1 white-list of reductions:

```
sum   prod   mean   min   max   variance   stddev   count   all   any
```

Grouping is engaged **only** when `axis:` contains `:group` — again,
explicit by design. Three cases:

```ruby
gi = temp[season, nil, nil]

gi.mean(axis: :group)      # group reduction     -> [4, 2, 3]
gi.mean(axis: 1)           # delegates: plain reduce over axis 1 -> [12, 3]
gi.mean                    # delegates: plain reduce over all    -> scalar
```

`axis: :group` reduces every group axis and leaves the band axes as
output axes, in **slot order** (a group axis stays at its slot position,
it is not pulled to the front):

```ruby
# band, band, group  ->  output keeps that order
s = CArray.float64(2, 3, 12) { |i, j, k| i + j + Math.cos(k) }
s[nil, nil, season].mean(axis: :group).shape    # => [2, 3, 4]
```

### Empty groups

A group with no members reduces to `UNDEF` (masked) — except `count`,
which is a plain `0`:

```ruby
keys = CArray.object(4) { |i| %w[a a c c][i] }
cat  = keys.categorize(labels: %w[a b c])       # category "b" is unused
a    = CArray.float64(4) { |i| i + 1.0 }

a[cat].mean(axis: :group).to_a     # => [1.5, UNDEF, 3.5]
a[cat].count(axis: :group).to_a    # => [2, 0, 2]
```

Masked input cells and excluded (out-of-vocabulary) cells are simply left
out of their group, so masks and grouping compose without any extra
ceremony.

### Folding a band axis into the statistic

`axis: [:group, n]` reduces the group axes **and** folds band slot `n`
into the same statistic — a partial reduction. The folded axis disappears
from the output:

```ruby
mon = CArray.object(6) { |i| %w[jan jan feb feb mar mar][i] }.categorize
lon = CArray.object(4) { |j| %w[E E W W][j] }.categorize
t   = CArray.float64(6, 4, 5) { |i, j, k| i + j + k }

g = t.axis_group(mon, lon, nil)   # slots: [group mon, group lon, band k]

t[g].mean(axis: :group)           # => shape [3, 2, 5]   mon x lon x k
t[g].mean(axis: [:group, 2])      # => shape [3, 2]      mon x lon, k folded in
```

The integer in `[:group, n]` is a **band** slot position; naming a group
slot there is an error (`:group` already reduces the group axes):

```ruby
t[g].mean(axis: [:group, 0])      # raises IndexError: slot 0 is a group axis
```

### Order statistics

`median`, `percentile(p)`, and `quantile` (the five-number summary
`[min, Q1, median, Q3, max]`) also work per group. Unlike the tier-1
white-list they cannot be scattered — an order statistic needs every member
of a group held together — so they materialize. A grouping with band axes
materializes one band fiber at a time (peak stays proportional to the group
axis length, not the whole array):

```ruby
temp = CArray.float64(6, 4) { |i, j| ... }   # [time, station]
gi   = temp[season, nil]                      # group axis 0, band = station

gi.median(axis: :group)          # per-(season, station) median -> [4, 4]
gi.percentile(90, axis: :group)  # per-group 90th percentile
gi.quantile(axis: :group)        # => [min, Q1, median, Q3, max], each [4, 4]
```

They currently cover a flat grouping and a band-preserving grouping with a
single rank-1 group axis; a rank-N categorical or a multi-group-slot
composite is a follow-up.

---

## 4. Labels: reading the coordinates back

A reduced result is a bare array — its axis 0 is "group 0", "group 1", …
with no names attached. `g.labels` gives you the coordinate labels in the
**same index space** as the result.

### A single block's coordinates

`g.labels(i, j, …)` returns the label tuple for one output block: a group
axis contributes its category label, a band axis contributes its integer
index.

```ruby
g = temp.axis_group(season, nil, nil)
r = temp[g].mean(axis: :group)     # shape [4, 2, 3]

g.labels(0, 0, 0)                  # => ["DJF", 0, 0]
g.labels(2, 1, 0)                  # => ["JJA", 1, 0]
```

### A label view, in lockstep with the reduction

`g.labels(axis: SPEC)` returns a `GroupLabels` view whose shape matches
`value[g].reduce(axis: SPEC)` exactly — pass it the **same** `axis:` you
reduced with, and the two line up cell for cell:

```ruby
mon = CArray.object(6) { |i| %w[jan jan feb feb mar mar][i] }.categorize
lon = CArray.object(4) { |j| %w[E E W W][j] }.categorize
t   = CArray.float64(6, 4) { |i, j| i + j }
g   = t.axis_group(mon, lon)

rv  = t[g].sum(axis: :group)       # => shape [3, 2]
lab = t[g].labels                  # reachable straight off the iterator too
lab.shape                          # => [3, 2]
lab[0, 0]                          # => ["jan", "E"]
lab[2, 1]                          # => ["mar", "W"]
```

`g.labels(axis: SPEC)` needs a `:group` in `SPEC` (labels track the
grouped result); asking for a plain integer axis raises.

The per-axis label vectors are also available directly — these are the
headings you would put on a table:

```ruby
lab.axis(0)      # => ["jan", "feb", "mar"]   the group axis labels
lab.axis(1)      # => ["E", "W"]
lab.coords       # => [["jan", "feb", "mar"], ["E", "W"]]   all headings
```

`GroupLabels` builds tuples on demand from the per-axis vectors, so it
stores one small vector per output axis, never the full block table.

---

## 5. Worked example: monthly climatology

Put it together on a `[time, lat, lon]` field with one year of monthly
data.

```ruby
require "carray"

nt, nlat, nlon = 12, 2, 3
temp = CArray.float64(nt, nlat, nlon) { |t, y, x| 15 + t + y * 0.5 + x * 0.25 }

# classify the time axis into meteorological seasons
season = CArray.object(nt) { |t|
  %w[DJF DJF MAM MAM MAM JJA JJA JJA SON SON SON DJF][t]
}.categorize(labels: %w[DJF MAM JJA SON])

# seasonal mean field: one (lat, lon) map per season
g    = temp.axis_group(season, nil, nil)
clim = temp[g].mean(axis: :group)
clim.shape                         # => [4, 2, 3]

# name the season axis
g.labels.axis(0)                   # => ["DJF", "MAM", "JJA", "SON"]

# spatial mean per season: fold both band axes into the statistic
zonal = temp[g].mean(axis: [:group, 1, 2])
zonal.shape                        # => [4]
season.labels.zip(zonal.to_a)      # => [["DJF", ...], ["MAM", ...], ...]
```

### Variant: year-month periods on the timeline

The classifier above is a **fixed cycle** — 4 seasons that repeat every
year. If instead you want one group per distinct year-month that
appears in the data (a **data-driven period**), format the timestamp
with an ISO field so string ascending order matches chronological
order, and let `sort_labels: true` sort:

```ruby
# dt : CATime shape (nt,)
ym = dt.strftime("%Y-%m").categorize(sort_labels: true)
temp[ym, nil, nil].mean(axis: :group)
ym.labels                          # => ["2023-11", "2023-12", "2024-01", …]
```

You don't know ahead of time which months the dataset covers, so a
fixed vocabulary would be wrong here; discovery + sort is the right
tool.

---

## 6. Worked example: continuous-value binning

Sometimes the group axis is not a discrete key but a **value bin** —
"average precipitation by wind-speed bucket", "mean humidity by
elevation band". Snap the classifying values to a grid, categorize the
snapped array, and reduce a co-shaped payload:

```ruby
require "carray"

n = 500
wind = CArray.float64(n) { rand * 20 }               # wind speed [m/s]
prec = CArray.float64(n) { |i| rand * 5 + wind[i] * 0.1 }  # precip [mm/h]

# 2 m/s bins pinned across [0, 20] — empty bins survive as UNDEF in mean,
# 0 in count, so a bar chart never has gaps.
grid = Array.new(11) { |i| i * 2.0 }                 # 0, 2, 4, …, 20
wbin = wind.snap(2.0, direction: :floor).categorize(labels: grid)

# Group prec by wind bin. wbin is rank-1, prec is rank-1, so exactly one slot.
g = prec.axis_group(wbin)
prec[g].mean(axis:  :group).to_a   # mean precipitation per wind bin
prec[g].count(axis: :group).to_a   # samples per wind bin
g.labels.axis(0)                   # => [0.0, 2.0, 4.0, …, 20.0]
```

`direction: :floor` on `snap` picks the bin **lower edge** — the same
half-open convention `[grid[k], grid[k+1])` as `bin(vmin, vmax, step)`,
so you can swap between value-space labels (via `snap`) and integer
bin-index labels (via `bin_to` + `from_codes`) freely.

> **When to reach for `histogram` instead.** If you only want counts,
> the dedicated [`histogram`](Histogram.md) surface is simpler and
> faster — no classifier to build, no `axis_group` spec. `axis_group`
> earns its keep once the reduction goes beyond counting (`mean`,
> `variance`, weighted sums, …) or the same classifier is reused
> across several fields.

---

## 7. Worked example: non-rectangular regions

Group a field by a region map whose regions do not follow the grid.

```ruby
require "carray"

nt = 4
field = CArray.float64(nt, 2, 3) { |t, y, x| t * 100 + y * 10 + x }

# a [lat, lon] region map -> a rank-2 categorical (2 axes -> 1 group axis)
region = CArray.object(2, 3) { |y, x|
  [%w[sea sea land], %w[land ice ice]][y][x]
}.categorize

g = field.axis_group(nil, region)   # band time axis, group over lat+lon
r = field[g].mean(axis: :group)
r.shape                             # => [4, 3]   time x region

g.labels.axis(0)                    # => [0, 1, 2, 3]        band time index
g.labels.axis(1)                    # => ["sea", "land", "ice"]
field[g].count(axis: :group).to_a   # => cells per region, per time step
```

---

## 8. Notes

* **All axes explicit.** `axis_group` requires one slot per source axis
  and `axis: :group` is required to engage grouping. Nothing is inferred
  from context — a spec you can read is a spec you can trust.
* **The value is a shape template.** `axis_group` never reads the data,
  so build a spec once and reuse it across every array of that shape.
* **The iterator is not an array.** `value[g]` is a `CAGroupIterator`; you
  get a result by reducing it. It has no materialise path.
* **Masks and exclusions compose.** Masked input cells and
  out-of-vocabulary keys drop out of their group; empty groups reduce to
  `UNDEF` (`count` gives `0`).
* **Newer feature.** The class names are provisional; the surface (build
  a categorical, position it, reduce with `:group`, read labels) is what
  to rely on.
