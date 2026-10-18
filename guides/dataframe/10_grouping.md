# Summarising by group

"What is the total per shop?", "the average on weekdays and on weekends?", "how did each day compare with that shop's usual?" — these are questions about groups of rows. `group_by` splits the rows into groups by a key, and the methods of the result summarise each group, or compute something for each row from its own group.

```ruby
require "carray"
sales = CAFrame.from_csv("sales.csv", types: :infer, missing: ["-1", "n/a"])
```

## Grouping rows — `group_by`

`group_by` takes the name of the column to group by and returns a grouped frame. Nothing is computed until you ask for a summary:

```ruby
by_shop = sales.group_by("shop")
by_shop.ngroup    # => 3
by_shop.labels    # => ["north", "south", "central"]
```

The groups are in the order their keys first appear in the frame.

A summary gives one row per group, labelled by the key:

```ruby
p by_shop.sum
# #<CAFrame nrow=3 columns=[visitors:float64, revenue:float64, rating:float64] index="shop">
# shop     visitors   revenue  rating
# -------  --------  --------  ------
# north      1870.0  22994.93    29.4
# south       909.0  15292.67    36.8
# central    2675.0  22113.01    30.1
```

Every column that has a sum is summed — here the visitor counts, revenue and ratings. A sum of ratings means little; choose the columns to summarise, as below. The key column is not summed: its values are the labels of the result, its **index** (chapter 9). The date column is left out because dates have no sum.

The visitor totals are floating-point numbers. `sum` is a statistic, and is computed in `float64` whatever the column's type, so a large total does not wrap around as a total kept in an integer type would.

### Choosing the columns to summarise

Name columns, and you get their results as arrays — one name gives one array, several give an Array of them:

```ruby
by_shop.sum("revenue").to_a.map { |v| v.round(2) }   # => [22994.93, 15292.67, 22113.01]
visitors, rating = by_shop.mean("visitors", "rating")
rating.to_a.map { |v| v.round(2) }                   # => [4.2, 4.6, 3.76]
```

To keep a frame, `select` or `drop` columns before grouping:

```ruby
p sales.select("shop", "visitors", "revenue").group_by("shop").mean
# #<CAFrame nrow=3 columns=[visitors:float64, revenue:float64] index="shop">
# shop       visitors      revenue
# -------  ----------  -----------
# north        233.75   2874.36625
# south    129.857143   1911.58375
# central     334.375  3159.001429
```

### The summaries

| summary | gives each group |
|---|---|
| `sum` `prod` | the total, the product |
| `mean` `median` | the average, the middle value |
| `min` `max` | the smallest, the largest |
| `variance` `stddev` | the spread (sample), and `variancep` `stddevp` (population) |
| `count` | the number of values present |
| `nunique` | the number of distinct values present |
| `first` `last` | the first, the last value present, in row order |
| `all` `any` | for yes/no columns: whether every, or some, value is `true` |
| `accumulate` | the total added up as C adds numbers of the column's type: a total larger than the type can hold wraps around (in an `int8` column, 100 + 100 gives −56). It is for when you want exactly that arithmetic; for a total, use `sum` |

Each leaves out missing values, as the same summary on a whole column does (chapter 8). Each applies to the columns whose type has it: a date column has a `min`, `max`, `mean` and `median` but no `sum`; a text column a `min` and `max`, by alphabetical order.

```ruby
p sales.group_by("shop").last
# #<CAFrame nrow=3 columns=[date:CATime[D], visitors:int64, revenue:float64, rating:float64] index="shop">
# shop     date        visitors  revenue  rating
# -------  ----------  --------  -------  ------
# north    2024-03-11       188  2261.26     4.3
# south    2024-03-11       101   1525.1     4.7
# central  2024-03-11       298  3008.01     3.9
```

`last` gives, for each column, the latest value present in each group — a quick way to see the most recent state of every shop. A missing value is passed over, so a column whose last row is missing gives the value before it.

### Groups with too little data — `min_count:` and `fill_value:`

`min_count: n` gives `UNDEF` for a group with fewer than `n` values present; `fill_value:` puts a value of your choosing where a result is `UNDEF`:

```ruby
by_shop.mean("visitors", min_count: 8).to_a   # => [233.75, UNDEF, 334.375]
```

The south shop has seven counted days, so with `min_count: 8` it has no average. This is the way to refuse a figure that rests on too little data.

## Keys

### Several columns

Several key names group by their combination. Here the shop table (chapter 12) adds each shop's size, and a computed column says whether the day is a weekend:

```ruby
shops = CAFrame.from_csv("shops.csv", types: :infer)
df = sales.join(shops.select("shop", "size"), on: "shop")
df["day_type"] = df["date"].weekday.is_in([0, 6]).then_else("weekend", "weekday")
p df.select("size", "day_type", "visitors", "revenue").group_by("size", "day_type").mean
# #<CAFrame nrow=4 columns=[size:CAString, day_type:object, visitors:float64, revenue:float64]>
# size   day_type    visitors      revenue
# -----  --------  ----------  -----------
# small  weekday   159.636364  2057.578333
# large  weekday   319.666667      2980.63
# small  weekend       255.75     3399.165
# large  weekend        378.5      3604.93
```

With several keys, the result has a column for each key, holding each group's key values, followed by the summaries; it has no index. To label the rows by one of the keys, `set_index` it (chapter 9).

### A computed key

A key need not be a column of the frame. Any array with one value per row will do, so you can group by something you compute without adding it as a column first:

```ruby
traffic = (sales["visitors"] >= 300).then_else("busy", "normal")
g = sales.group_by(traffic)
g.labels                                  # => ["normal", "busy"]
g.mean("rating").to_a.map { |v| v.round(2) }   # => [4.36, 3.77]
```

Busy days have lower ratings. The south shop's day with no visitor count has no traffic value, so it belongs to neither group (below).

### The index as a key

When the frame has an index, its name works as a key, as a column name does:

```ruby
by_label = sales.copy.set_index("shop").group_by("shop")
by_label.max("visitors").to_a   # => [341, 186, 402]
```

### Rows whose key is missing

A row whose key is missing belongs to no group, and so takes part in no summary. With several keys, one missing part is enough. The group sizes then add up to fewer than `nrow`; `count_masked` on the key tells you how many rows were left out, and `fill` on the key puts them in a group of their own if you want them counted.

## A summary of your own per column — `aggregate`

`aggregate` names each result and says how to compute it: `"name" => [column, summary]`. Different columns can take different summaries, and one column several:

```ruby
p sales.group_by("shop").aggregate(
  "revenue"     => ["revenue", :sum],
  "best_day"    => ["revenue", :max],
  "p25_visitors" => ["visitors", :percentile, 25],
  "range"       => ["visitors", ->(v) { v.max - v.min }],
)
# #<CAFrame nrow=3 columns=[revenue:float64, best_day:float64, p25_visitors:float64, range:int64] index="shop">
# shop      revenue  best_day  p25_visitors  range
# -------  --------  --------  ------------  -----
# north    22994.93   4112.58         186.5    166
# south    15292.67   2785.04         101.5     91
# central  22113.01    3939.6        303.25    107
```

- A Symbol names a summary; its arguments follow it (`:percentile, 25`), with keywords last (`:mean, min_count: 7`).
- A lambda receives the group's part of the column, as a CArray, and returns a value. Use it for anything the named summaries do not cover.

## Computing across columns — `table`

When a result needs several columns of the group at once, `table` gives you each group as a frame. The block returns a Hash, and each key of the Hash becomes a column:

```ruby
p sales.group_by("shop").table { |g|
  best = g.sort_by_key("revenue", order: :desc)[0]
  { "days" => g.nrow, "best_date" => best["date"], "per_visitor" => g["revenue"].sum / g["visitors"].sum }
}
# #<CAFrame nrow=3 columns=[days:int64, best_date:CATime[D], per_visitor:float64] index="shop">
# shop     days  best_date   per_visitor
# -------  ----  ----------  -----------
# north       8  2024-03-10    12.296754
# south       8  2024-03-10    16.823619
# central     8  2024-03-09     8.266546
```

Integers in the returned Hashes become an integer column and other numbers a float column, strings a text column, and times taken from a time column a time column; anything else — `true`/`false`, a mix of kinds — becomes an object column. `nil` and `UNDEF` are missing.

Note that `per_visitor` here sums each column over its own present days: the south shop's 6 March revenue counts but its visitors do not. If the two should cover the same days, choose the rows first (`g.filter { |f| f["visitors"].is_not_masked }`).

## One column, every summary — `grouped["col"]`

`grouped["col"]` gives one column split by the groups, with every summary the column itself has, including the ones that take arguments:

```ruby
by_shop["revenue"].median.to_a.map { |v| v.round(1) }   # => [2483.4, 1597.0, 3060.9]
by_shop["visitors"].percentile(90).to_a                 # => [327.7, 178.8, 392.2]
```

The result is an array with one value per group, in the order of `labels`.

## A group value on every row — `keep_rows: true`

Often you want each row compared with its own group: a day against its shop's average, a day's share of its shop's total. With `keep_rows: true`, `sum`, `mean`, `min`, `max`, `aggregate` and `table` give each row the result of its own group, so the result lines up with the frame's columns:

```ruby
shop_total = by_shop.sum("revenue", keep_rows: true)
sales["share"] = sales["revenue"] / shop_total
shop_mean = by_shop.mean("revenue", keep_rows: true)
sales["vs_mean"] = sales["revenue"] - shop_mean
p sales.head(6)
# #<CAFrame nrow=6 columns=[date:CATime[D], shop:CAString, visitors:int64, revenue:float64, rating:float64, share:float64, vs_mean:float64]>
# date        shop     visitors  revenue  rating     share      vs_mean
# ----------  -------  --------  -------  ------  --------  -----------
# 2024-03-04  north         182  2121.39     4.2  0.092255   -752.97625
# 2024-03-04  south          95  1391.47     4.6  0.090989   -520.11375
# 2024-03-04  central       310   3038.0     3.8  0.137385  -121.001429
# 2024-03-05  north         175   2235.1     4.3    0.0972   -639.26625
# 2024-03-05  south         102  1632.61     4.7  0.106758   -278.97375
# 2024-03-05  central       295  2717.54     3.9  0.122893  -441.461429
```

A row whose key is missing gets `UNDEF`, since it has no group.

## Values from within the group — `lag`, `order`, running totals

Some values are computed among the rows of each row's own group: the previous day's figure, a rank, a running total. These are one per row by nature:

```ruby
df = sales.copy
g = df.group_by("shop")
df["change"]  = df["revenue"] - g.lag("revenue")
df["rank"]    = g.order("revenue", descending: true)
df["to_date"] = g.cumsum("revenue")
p df.filter { |f| f["shop"].eq("north") }.select("date", "revenue", "change", "rank", "to_date")
# #<CAFrame nrow=8 columns=[date:CATime[D], revenue:float64, change:float64, rank:int64, to_date:float64]>
# date        revenue    change  rank   to_date
# ----------  -------  --------  ----  --------
# 2024-03-04  2121.39         _     7   2121.39
# 2024-03-05   2235.1    113.71     6   4356.49
# 2024-03-06  2285.32     50.22     4   6641.81
# 2024-03-07  2681.38    396.06     3   9323.19
# 2024-03-08   3323.2    641.82     2  12646.39
# 2024-03-09   3974.7     651.5     1  16621.09
# 2024-03-10  4112.58    137.88     0  20733.67
# 2024-03-11  2261.26  -1851.32     5  22994.93
```

| method | each row gets |
|---|---|
| `lag(name, n: 1)` | the value `n` rows back in its group; `UNDEF` where there is none. A negative `n` looks ahead |
| `order(name, descending:)` | its rank in its group, `0` for the smallest (or the largest, with `descending: true`) |
| `cumsum` `cumprod` `cummax` `cummin` `cumcount` | the running value of its group, up to and including the row |

"Back" means earlier rows of the frame. If the rows are not in time order, sort them first (`sort_by_key("date")`), or the previous row is not the previous day.

`g.fill(name, :ffill)` fills missing values from earlier rows of the same group only, never from another group (chapter 8).

## Keeping whole groups — `filter`

`filter` on a grouped frame keeps the rows of the groups that pass a test. The block receives the grouped frame and returns one value per group, built from group summaries:

```ruby
well_rated = sales.group_by("shop").filter { |g| g.mean("rating") >= 4.0 }
well_rated["shop"].to_a.uniq   # => ["north", "south"]

complete = sales.group_by("shop").filter { |g| g["visitors"].count_not_masked.eq(8) }
complete["shop"].to_a.uniq     # => ["north", "central"]
```

The result is a frame of the kept rows, in their original order, sharing its cells with the original. To summarise it by group again, call `group_by` on it.

## When the data is read

The groups are fixed when `group_by` is called: if you change a key afterwards, rows do not move between groups. The values are read when a summary is asked for, so a summary sees values changed after `group_by`. When you change keys, group again.

## Grouping by time

Grouping rows into periods of time — days, weeks, months — is `resample`, covered with the other time-series tools in chapter 11. It returns a grouped frame, so everything in this chapter applies to it.

## In the CArray User's Guide

The CArray User's Guide describes grouping the cells of arrays in *Categories and grouping* ([24_categories_and_grouping.md](../users/24_categories_and_grouping.md)).
