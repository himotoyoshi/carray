# Frames and arrays

A frame is a set of named arrays. You have seen that `df["name"]` gives a column as a CArray; this chapter is about using that freely — taking columns out to compute with, putting results back, turning a frame into one matrix and a matrix into a frame — and about the array tools that are available on a column without anything special in the frame.

```ruby
require "carray"
sales = CAFrame.from_csv("sales.csv", types: :infer, missing: ["-1", "n/a"])
```

## A column is an array

What you get from `df["name"]` is the array the frame holds. Everything in the CArray User's Guide applies to it: arithmetic and mathematical functions, summaries along any axis, sorting and searching, masks, histograms, rolling windows.

```ruby
r = sales["revenue"]
z = (r - r.mean) / r.stddev          # standardised revenue
z.to_a.first(3).map { |v| v.round(2) }   # => [-0.62, -1.52, 0.51]
```

A few tools that are often useful on a column:

| want | on a column |
|---|---|
| the order that would sort it | `sort_index` |
| each value's rank | `order` (`descending: true`, ties with `method:`) |
| running totals, maxima | `cumsum`, `cummax` |
| percentiles | `percentile(90)`, `median`, `quantile` |
| distinct values and how often | `unique`, `value_counts`, `nunique` |
| membership in a set | `is_in([...])` |
| counts per interval | `histogram1d(edges: [...])` |
| a category for each value | `categorize` |

```ruby
h = sales["visitors"].histogram1d(edges: [0, 100, 200, 300, 400, 500])
h.counts.to_a   # => [1, 10, 4, 7, 1]
```

The counts are per hundred visitors: one day under 100, ten from 100 to 199, and so on. They add up to 23; the missing count takes no part.

### Putting results back

A result with one value per row goes back into the frame as a column:

```ruby
sales["z"] = z
sales["rank"] = r.order(descending: true)
sales.sort_by_key("rank").head(3)["date"].to_a.map(&:to_s)   # => ["2024-03-10", "2024-03-09", "2024-03-09"]
```

A missing input gives a missing result, so the new columns line up with the old ones, gaps included.

### Columns from different frames

Arithmetic between columns pairs cells by position. Columns of the same frame always line up, because they are the same rows. Columns of two different frames line up only if the frames have the same rows in the same order; the index plays no part in arithmetic. To line up two tables by a key, `join` or `align` them first (chapter 12).

## The whole frame as one matrix — `to_ca`

`to_ca` gives the frame as a two-dimensional array: one row per row, one column per column. It is a view: no data is copied, and writing to the matrix writes to the columns.

```ruby
m = sales.select("visitors", "revenue", "rating").to_ca
m.shape       # => [24, 3]
m.data_type   # => :float64
m.mean(axis: 0).to_a.map { |v| v.round(2) }   # => [237.13, 2626.11, 4.19]
```

The columns are read at one common type — here `float64`, since the visitor counts are integers and the others floats. Columns with no common type, such as text beside numbers, raise; `select` the numeric columns first, or `promote(:object)` the frame for a matrix of Ruby objects.

When you will write through the matrix, ask for that with `to_ca(writable: true)`. It raises if a write could not reach the stored value — because a column is read at a different type, for instance — instead of letting the write be lost. `promote` first makes every column the same type, which makes the matrix writable:

```ruby
nums = sales.select("visitors", "revenue").copy.promote
w = nums.to_ca(writable: true)
w[0, 0] = 200.0
nums["visitors"][0]   # => 200.0
```

For a matrix of its own, `copy` the result: `df.to_ca.copy`.

## An array as a frame — `to_frame`

The other way round, a two-dimensional array becomes a frame with `to_frame`, one column per position along its last axis (chapter 2). This is how a computed matrix gets names:

```ruby
grid, days, shops = sales.pivot_grid(index: "date", columns: "shop", values: "revenue")
share = grid / grid.sum(axis: 1, min_count: 3)[nil, :_]
df = share.to_frame(*shops.to_a)
df.column_names                                    # => ["central", "north", "south"]
df["north"][0].round(3)                            # => 0.324
```

`grid.sum(axis: 1, min_count: 3)` is each day's total over the three shops; `min_count: 3` makes the total missing on a day when a shop's figure is missing, rather than a total of the other two that would make their shares look too large. `[nil, :_]` gives the totals a second axis of length 1, so that dividing spreads each day's total across the three shops. CArray does not spread arrays of different shapes into each other unless you say so this way.

## Columns that are not plain numbers

Besides numbers, a frame column can hold times, categories or text. These columns are CArrays too (the CArray User's Guide calls them *Faces*): each stores numbers or strings and shows them as something else. Three appear in frames all the time:

| column | stores | reads as |
|---|---|---|
| time (`CATime`) | ticks since 1970 | instants: `2024-03-04` |
| categorical (`CACategorical`) | small integer codes | labels: `"north"` |
| text (`CAString`, `CAConstString`) | strings | strings |

These columns keep what they are through every frame operation: a filtered time column is a time column, a joined categorical column is categorical, a group summary keyed by time has a time index. They compare with values of their own kind — a time with `"2024-03-09"`, a categorical with `"north"` — and two of them match by what they mean: a day column joins a seconds column by the instant, a categorical column joins a text column by the labels.

When you need the stored numbers, ask the column: `ticks` on a time column, `codes` on a categorical one:

```ruby
cat = sales["shop"].categorize
cat.codes.to_a.first(6)   # => [0, 1, 2, 0, 1, 2]
cat.labels                # => ["north", "south", "central"]
```

## Exchanging data with other libraries

A column can be handed to other array libraries that read Ruby's MemoryView, such as Numo::NArray and Apache Arrow for Ruby, without copying. The CArray User's Guide covers this in its chapter *MemoryView interop*. For a frame as a whole, the usual exchange is a file: CSV (chapter 3 and chapter 17), or records for JSON (chapter 17).

## In the CArray User's Guide

In the CArray User's Guide: *Views* ([06_views.md](../users/06_views.md)) for why a column taken out shares its cells, *Broadcasting* ([07_broadcasting.md](../users/07_broadcasting.md)) for `[nil, :_]`, *Histograms* ([25_histograms.md](../users/25_histograms.md)), *Faces* ([12_faces.md](../users/12_faces.md)), and *MemoryView interop* ([15_memory_view.md](../users/15_memory_view.md)).
