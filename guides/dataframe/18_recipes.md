# Recipes

Each recipe here is a complete answer to a common question, using the methods of the earlier chapters together. They all start from the same two files:

```ruby
require "carray"
require "stringio"
sales = CAFrame.from_csv("sales.csv", types: :infer, missing: ["-1", "n/a"])
shops = CAFrame.from_csv("shops.csv", types: :infer)
```

## Check a file you have just received

You have a new file and want to know whether it can be trusted before you use it. Read it, look at the types and the missing counts, and check the values against what you know about them:

```ruby
fresh = CAFrame.from_csv("sales.csv", types: :infer, missing: ["n/a"], on_error: :warn)
puts fresh.describe.to_table
# column    type       count  masked  unique  min         max         mean         stddev
# --------  ---------  -----  ------  ------  ----------  ----------  -----------  ----------
# date      CATime[D]     24       0       8  2024-03-04  2024-03-11  2024-03-08   2D
# shop      CAString      24       0       3  _           _           _            _
# visitors  int64         24       0      23  -1          402         227.208333   106.91849
# revenue   float64       23       1      23  1391.47     4112.58     2626.113478  809.768975
# rating    float64       23       1      14  3.5         4.8         4.186957     0.384122
```

The minimum visitor count of `-1` stands out. Rules make such checks explicit and repeatable:

```ruby
report = fresh.verify(
  "visitors not negative" => ->(f) { f["visitors"] >= 0 },
  "rating from 1 to 5"    => ->(f) { f["rating"].is_between(1, 5) },
  "one row per shop-day"  => ->(f) { f.is_duplicate("shop", "date").not },
)
report.column_names.each do |rule|
  puts "#{rule}: #{report[rule].count(false)} broken, #{report[rule].count_masked} unknown"
end
# visitors not negative: 1 broken, 0 unknown
# rating from 1 to 5: 0 broken, 1 unknown
# one row per shop-day: 0 broken, 0 unknown
```

Having seen that `-1` is a code for "no count", read the file with `missing: ["-1", "n/a"]` from then on.

## Find missing rows

Every shop should have a row for every day. Build the full list of shop-days and keep the ones the file lacks, with an `:anti` join:

```ruby
days  = CArray.time_range("2024-03-04", "2024-03-11", unit: :D).to_a
names = ["north", "south", "central"]
expected = CAFrame.from_records(names.product(days).map { |s, d| { "shop" => s, "date" => d } })
partial  = sales[sales["date"].ne("2024-03-07") | sales["shop"].ne("south")]   # a file missing one row
p expected.join(partial, on: ["shop", "date"], how: :anti)
# #<CAFrame nrow=1 columns=[shop:object, date:object]>
# shop   date
# -----  ----------
# south  2024-03-07
```

## The best day of each shop

Sort by the figure, largest first, and keep the first row of each shop:

```ruby
ranked = sales.sort_by_key("revenue", order: :desc)
best = ranked[ranked.is_duplicate("shop").not]
p best.select("shop", "date", "revenue")
# #<CAFrame nrow=3 columns=[shop:CAString, date:CATime[D], revenue:float64]>
# shop     date        revenue
# -------  ----------  -------
# north    2024-03-10  4112.58
# central  2024-03-09   3939.6
# south    2024-03-10  2785.04
```

## Change from the previous day, per shop

`lag` within each shop gives the previous day's figure; the rows must be in date order within each shop:

```ruby
df = sales.sort_by_key("shop", "date").select("shop", "date", "revenue").copy
prev = df.group_by("shop").lag("revenue")
df["change"]  = df["revenue"] - prev
df["change%"] = (df["revenue"] / prev - 1) * 100
p df.head(4)
# #<CAFrame nrow=4 columns=[shop:CAString, date:CATime[D], revenue:float64, change:float64, change%:float64]>
# shop     date        revenue   change     change%
# -------  ----------  -------  -------  ----------
# central  2024-03-04   3038.0        _           _
# central  2024-03-05  2717.54  -320.46  -10.548387
# central  2024-03-06  3078.67   361.13   13.288857
# central  2024-03-07  3060.93   -17.74   -0.576223
```

The first day of each shop has no previous day, so its change is missing.

## Each day's share of its shop's total, and its rank

```ruby
df = sales.select("shop", "date", "revenue").copy
g = df.group_by("shop")
df["share%"] = df["revenue"] / g.sum("revenue", keep_rows: true) * 100
df["rank"]   = g.order("revenue", descending: true) + 1
p df.filter { |f| f["rank"] <= 2 }.sort_by_key("shop", "rank")
# #<CAFrame nrow=6 columns=[shop:CAString, date:CATime[D], revenue:float64, share%:float64, rank:int64]>
# shop     date        revenue     share%  rank
# -------  ----------  -------  ---------  ----
# central  2024-03-09   3939.6  17.815756     1
# central  2024-03-10  3270.26  14.788851     2
# north    2024-03-10  4112.58  17.884725     1
# north    2024-03-09   3974.7  17.285115     2
# south    2024-03-10  2785.04  18.211601     1
# south    2024-03-09  2724.34  17.814679     2
```

## Compare with targets

Join the targets on, compute the difference, and list the shops below target:

```ruby
targets = CAFrame.new("shop" => ["north", "south", "central"], "target" => [22000.0, 16000.0, 24000.0])
actual  = sales.select("shop", "revenue").group_by("shop").sum.reset_index
cmp = actual.join(targets, on: "shop")
cmp["gap"] = cmp["revenue"] - cmp["target"]
p cmp.filter { |f| f["gap"] < 0 }
# #<CAFrame nrow=2 columns=[shop:CAString, revenue:float64, target:float64, gap:float64]>
# shop      revenue   target       gap
# -------  --------  -------  --------
# south    15292.67  16000.0   -707.33
# central  22113.01  24000.0  -1886.99
```

Remember that the central shop's total lacks one day (chapter 1). `count` in the same summary shows how many days each total covers, which belongs in a report like this.

## Weekdays against weekends

A computed key splits the days without adding a column:

```ruby
day_type = sales["date"].weekday.is_in([0, 6]).then_else("weekend", "weekday")
p sales.select("visitors", "revenue").group_by(day_type).mean
# #<CAFrame nrow=2 columns=[visitors:float64, revenue:float64] index="group">
# group      visitors      revenue
# -------  ----------  -----------
# weekday  216.117647  2329.064118
# weekend  296.666667  3467.753333
```

To see it by shop too, group by both, or spread one key across columns with `pivot` (chapter 13):

```ruby
df = sales.select("shop", "revenue").copy
df["day_type"] = day_type
p df.pivot(index: "shop", columns: "day_type", values: "revenue", aggregate: :mean)
# #<CAFrame nrow=3 columns=[weekday:float64, weekend:float64] index="shop">
# shop         weekday  weekend
# -------  -----------  -------
# central      2980.63  3604.93
# north    2484.608333  4043.64
# south    1630.548333  2754.69
```

## A moving average per shop

Average each shop's revenue over its last three days:

```ruby
w = sales.windows(on: "date", before: "3 days", by: "shop", interval: "1 day")
df = sales.select("shop", "date", "revenue").copy
df["avg3"] = w.mean("revenue").mask_where(w.is_complete.not)
p df.filter { |f| f["shop"].eq("north") }
# #<CAFrame nrow=8 columns=[shop:CAString, date:CATime[D], revenue:float64, avg3:float64]>
# shop   date        revenue         avg3
# -----  ----------  -------  -----------
# north  2024-03-04  2121.39            _
# north  2024-03-05   2235.1            _
# north  2024-03-06  2285.32  2213.936667
# north  2024-03-07  2681.38       2400.6
# north  2024-03-08   3323.2       2763.3
# north  2024-03-09   3974.7  3326.426667
# north  2024-03-10  4112.58  3803.493333
# north  2024-03-11  2261.26  3449.513333
```

`mask_where(w.is_complete.not)` leaves the first two days without an average, since they do not have three days behind them.

## Fill a missing day by interpolation, per shop

Split the table by shop, put each shop on the full list of days, interpolate along the dates, and put the shops back together:

```ruby
days = CArray.time_range("2024-03-04", "2024-03-11", unit: :D)
filled = ["north", "south", "central"].map { |s|
  part = sales.filter { |f| f["shop"].eq(s) }.drop("shop").align("date", days)
  part.set_index("date").cast("visitors" => :float64).fill("visitors", :linear)
  part.append("shop", CArray.string(part.nrow) { s })
}
all = CAFrame.concatenate(filled)
all.filter { |f| f["shop"].eq("south") }.at("2024-03-06")["visitors"]   # => 106.0
```

The south shop's missing count for 6 March is now the value halfway between the days around it.

## Combine files delivered in parts

Files of the same layout, one per week, are read and put after one another. `concatenate` reconciles their column types:

```ruby norun
files = Dir.glob("sales_week_*.csv").sort
all = CAFrame.concatenate(files.map { |path|
  CAFrame.from_csv(path, types: :infer, missing: ["-1", "n/a"])
})
```

If the same row may appear in two files, remove the repeats: `all[all.is_duplicate("shop", "date").not]`.

## Turn a summary into JSON

```ruby
require "json"
summary = sales.group_by("shop").aggregate(
  "revenue" => ["revenue", :sum],
  "days"    => ["revenue", :count],
).reset_index
summary["revenue"] = (summary["revenue"] * 100).round / 100.0
puts JSON.pretty_generate(summary.to_records)
# [
#   {
#     "shop": "north",
#     "revenue": 22994.93,
#     "days": 8
#   },
#   {
#     "shop": "south",
#     "revenue": 15292.67,
#     "days": 8
#   },
#   {
#     "shop": "central",
#     "revenue": 22113.01,
#     "days": 7
#   }
# ]
```
