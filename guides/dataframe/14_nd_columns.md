# Columns with more than one value per row

Sometimes a row carries a set of values that belong together: visitor counts for each part of the day, twelve monthly figures, a pair of coordinates, a short series. In CAFrame such a set can be **one column** whose cells each hold several values. The column is an array of two or more dimensions: its first axis runs along the rows, and the axes after it hold each row's values.

This chapter shows how to make such columns, work with them, and turn them back into ordinary columns.

```ruby
require "carray"
require "stringio"

parts = CAFrame.from_csv(StringIO.new(<<~CSV), types: :infer)
  date,shop,morning,midday,afternoon,evening
  2024-03-04,north,40,61,52,29
  2024-03-04,south,18,30,29,18
  2024-03-05,north,38,58,50,29
  2024-03-05,south,20,33,31,18
CSV
```

Each row gives a shop's visitor counts for four parts of the day.

## Making one column of several — `stack_columns`

`stack_columns` turns several columns into one, with a value for each:

```ruby
df = parts.stack_columns("morning".."evening", into: "visits")
p df
# #<CAFrame nrow=4 columns=[date:CATime[D], shop:CAString, visits:int64[4]]>
# date        shop   visits
# ----------  -----  ----------------
# 2024-03-04  north  [40, 61, 52, 29]
# 2024-03-04  south  [18, 30, 29, 18]
# 2024-03-05  north  [38, 58, 50, 29]
# 2024-03-05  south  [20, 33, 31, 18]
```

`int64[4]` in the summary line says each cell of `visits` holds four integers. The column is an ordinary CArray of shape `(rows, 4)`:

```ruby
df["visits"].shape   # => [4, 4]
```

The columns to stack can be given as a Range of names — every column from the first to the last, in the frame's order — an Array of names, or a Regexp. `shape:` arranges many columns into more than one axis: 36 monthly columns of three figures each become one column with `shape: [12, 3]`.

The new column is a view of the old ones, so nothing is copied, and writing to it writes the columns it came from.

## Working with the values

### Each row's values together

Summaries along the second axis work on each row's values at once. Each row's total visitors:

```ruby
df["visits"].sum(axis: 1).to_a   # => [182.0, 95.0, 175.0, 102.0]
df["visits"].max(axis: 1).to_a   # => [61, 30, 58, 33]
```

The axes after the row axis have no labels in the frame; keep their meaning beside it, for example as `periods = ["morning", "midday", "afternoon", "evening"]`. Which part of the day was busiest:

```ruby
periods = ["morning", "midday", "afternoon", "evening"]
busiest = df["visits"].max_index(axis: 1)
busiest.to_a.map { |i| periods[i] }   # => ["midday", "midday", "midday", "midday"]
```

### One of the values

`df["visits"][nil, k]` is the `k`-th value of every row, as an ordinary column — `nil` means every row. Use it to choose or sort rows, which needs one value per row:

```ruby
df["visits"][nil, 0].to_a                             # => [40, 18, 38, 20]
df.filter { |f| f["visits"][nil, 0] > 30 }.nrow       # => 2
```

### Group summaries keep the shape

A group summary reduces along the rows, so each group keeps the column's shape — each shop's average day:

```ruby
p df.drop("date").group_by("shop").mean
# #<CAFrame nrow=2 columns=[visits:float64[4]] index="shop">
# shop   visits
# -----  ------------------------
# north  [39.0, 59.5, 51.0, 29.0]
# south  [19.0, 31.5, 30.0, 18.0]
```

The same holds for `resample`, `windows` and `aggregate` with a named summary. A lambda in `aggregate` receives the group's part of the column, of shape `(rows in the group, 4)`.

### Everything else carries the values along

Choosing rows, sorting, joining, `meld` and `concatenate` all carry each row's values with the row. A missing cell is missing on its own, so one part of a day can be missing while the others are present.

## Back to separate columns — `unstack_column`

`unstack_column` splits a column into one column per value, in the old column's place. Give the names; without them the columns are called `visits_0`, `visits_1`, …:

```ruby
df.unstack_column("visits", into: periods).column_names
# => ["date", "shop", "morning", "midday", "afternoon", "evening"]
```

## Making one row of several — `stack_rows`

Data often comes the other way round: one row per value, several rows per group:

```ruby
long = CAFrame.from_csv(StringIO.new(<<~CSV), types: :infer)
  shop,period,visits
  north,morning,40
  north,midday,61
  north,afternoon,52
  south,morning,18
  south,midday,30
  south,afternoon,29
CSV
p long.stack_rows(by: "shop")
# #<CAFrame nrow=2 columns=[period:CAString[3], visits:int64[3]] index="shop">
# shop   period                              visits
# -----  ----------------------------------  ------------
# north  ["morning", "midday", "afternoon"]  [40, 61, 52]
# south  ["morning", "midday", "afternoon"]  [18, 30, 29]
```

`stack_rows` makes each group's rows one row. The key becomes the index, and every other column holds that group's values, in the order the rows came.

Without `on:`, the groups must have the same number of rows, matched by position. When a group may be missing a row, give `on:` the column that says which position a row belongs to; a missing row then becomes a missing value at its position, instead of shifting the others:

```ruby
incomplete = long[CA_INT64([0, 1, 2, 3, 5])]   # the south shop's midday row is absent
p incomplete.stack_rows(by: "shop", on: "period")
# #<CAFrame nrow=2 columns=[period:CAString[3], visits:int64[3]] index="shop">
# shop   period                              visits
# -----  ----------------------------------  ------------
# north  ["morning", "midday", "afternoon"]  [40, 61, 52]
# south  ["morning", "midday", "afternoon"]  [18, _, 29]
```

`unstack_rows` spreads the values back out into one row each.

## Building one directly

A column of several values can also be given directly, as an array of shape `(rows, n)` or a Ruby Array of equal-length Arrays:

```ruby
df = CAFrame.new("item" => ["box", "tube"], "size_cm" => [[30, 20, 10], [8, 8, 40]])
df["size_cm"].shape   # => [2, 3]
```

`from_records` makes one from records whose value for a key is an Array of the same length in every record.

## Several tables as layers — `CAFrame.stack`

Tables with the same rows and columns — the same report for two weeks, say — can be laid on top of each other. Each column gains an axis that runs over the tables:

```ruby
w1 = CAFrame.new({ "revenue" => [20733.67, 13767.57] }, index: ["north", "south"], axis_name: "shop")
w2 = CAFrame.new({ "revenue" => [21500.00, 14200.00] }, index: ["north", "south"], axis_name: "shop")
both = CAFrame.stack(w1, w2)
p both
# #<CAFrame nrow=2 columns=[revenue:float64[2]] index="shop">
# shop   revenue
# -----  -------------------
# north  [20733.67, 21500.0]
# south  [13767.57, 14200.0]
both["revenue"].mean(axis: 1).to_a   # => [21116.835, 13983.785]
```

The tables must have the same rows (the same index, if they have one) and the same columns. The result is a view of them, and `unstack(axis: 1)` gives them back as separate tables.

## What does not take several values per row

- **Keys** of `group_by`, `join`, `align` and sorting must be one value per row: take one of the values with `[nil, k]`.
- **CSV** has one value per cell, so `to_csv` raises on such a column; `unstack_column` first. `to_records` writes each cell as a Ruby Array, which JSON can hold.
- **`to_ca`**, which makes one matrix of the whole frame (chapter 15), needs every column to have one value per row.
- In **`describe`**, the counts and statistics are over all the values of the column, not per row.

## In the CArray User's Guide

Summaries along an axis, and the `[nil, k]` form of indexing, are described in the CArray User's Guide: *Reduction and statistics* ([04_reduction_and_statistics.md](../users/04_reduction_and_statistics.md)) and *Indexing and slicing* ([02_indexing_and_slicing.md](../users/02_indexing_and_slicing.md)).
