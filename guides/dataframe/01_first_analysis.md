# A first analysis

This chapter takes a small data set from a file to a written summary, so you can see how the pieces fit before each is explained on its own. Don't worry about every detail here; the later chapters return to each step.

## The data

`sales.csv` holds daily figures from three shops of a small chain — `north`, `south` and `central` — over eight days: how many visitors came in, the day's revenue in dollars, and the average rating customers gave, out of 5.

```
date,shop,visitors,revenue,rating
2024-03-04,north,182,2121.39,4.2
2024-03-04,south,95,1391.47,4.6
2024-03-04,central,310,3038.0,3.8
2024-03-05,north,175,2235.1,4.3
2024-03-05,south,102,1632.61,4.7
2024-03-05,central,295,2717.54,3.9
2024-03-06,north,190,2285.32,4.1
2024-03-06,south,-1,1479.8,4.5
2024-03-06,central,305,3078.67,3.7
2024-03-07,north,204,2681.38,4.4
2024-03-07,south,110,1561.34,4.8
2024-03-07,central,322,3060.93,4.0
2024-03-08,north,268,3323.2,4.0
2024-03-08,south,141,2192.97,4.6
2024-03-08,central,388,,3.6
2024-03-09,north,341,3974.7,n/a
2024-03-09,south,186,2724.34,4.4
2024-03-09,central,402,3939.6,3.5
2024-03-10,north,322,4112.58,4.1
2024-03-10,south,174,2785.04,4.5
2024-03-10,central,355,3270.26,3.7
2024-03-11,north,188,2261.26,4.3
2024-03-11,south,101,1525.1,4.7
2024-03-11,central,298,3008.01,3.9
```

Like many real files, it has a few problems. The south shop's visitor counter failed on 6 March, and the till system wrote `-1` for "no count". The central shop's revenue for 8 March is empty. On 9 March no customer rated the north shop, and the rating was written `n/a`.

`shops.csv` describes the shops, including a fourth that has not opened yet:

```
shop,name,size,opened,floor_m2
north,North Street,small,2019-05-01,120
south,South Mall,small,2021-09-15,85
central,Central Station,large,2016-11-20,240
west,West Park,large,2024-04-01,200
```

## Reading the file

`CAFrame.read_csv` reads a CSV and gives each column the type every one of its cells can be read as:

```ruby
require "carray"

sales = CAFrame.read_csv("sales.csv")
sales.data_types
# => {"date" => CATime, "shop" => CAString, "visitors" => :int64, "revenue" => :float64, "rating" => CAString}
```

The dates became a time column, the visitor counts integers and the revenue floats; the empty revenue did not stop that, since an empty cell is missing rather than unreadable. Two columns show the file's problems. `visitors` became integers, but `-1` is now a count of minus one visitor. `rating` stayed text, because `n/a` is not a number.

Both are ways this file writes "no value". Tell `read_csv` about them with `missing:`, and those cells are read as missing before the columns are typed:

```ruby
sales = CAFrame.read_csv("sales.csv", missing: ["-1", "n/a"])
sales.data_types
# => {"date" => CATime, "shop" => CAString, "visitors" => :int64, "revenue" => :float64, "rating" => :float64}
```

## Looking at it

`p` prints a frame as a table, the first and last few rows of it:

```ruby
p sales
# #<CAFrame nrow=24 columns=[date:CATime[D], shop:CAString, visitors:int64, revenue:float64, rating:float64]>
# date        shop     visitors  revenue  rating
# ----------  -------  --------  -------  ------
# 2024-03-04  north         182  2121.39     4.2
# 2024-03-04  south          95  1391.47     4.6
# 2024-03-04  central       310   3038.0     3.8
# 2024-03-05  north         175   2235.1     4.3
# 2024-03-05  south         102  1632.61     4.7
# 2024-03-05  central       295  2717.54     3.9
# 2024-03-06  north         190  2285.32     4.1
# 2024-03-06  south           _   1479.8     4.5
# :           :               :        :       :
# 2024-03-11  south         101   1525.1     4.7
# 2024-03-11  central       298  3008.01     3.9
```

The summary line gives the number of rows and each column's type. A missing cell is shown as `_`: the south shop's visitor count on 6 March. The visitor column is still a column of integers, with one cell missing.

`describe` checks every column at once: its type, how many cells are present and missing, and its range.

```ruby
puts sales.describe.to_table
# column    type       count  masked  unique  min         max         mean         stddev
# --------  ---------  -----  ------  ------  ----------  ----------  -----------  ----------
# date      CATime[D]     24       0       8  2024-03-04  2024-03-11  2024-03-08   2D
# shop      CAString      24       0       3  _           _           _            _
# visitors  int64         23       1      22  95          402         237.130435   97.370569
# revenue   float64       23       1      23  1391.47     4112.58     2626.113478  809.768975
# rating    float64       23       1      14  3.5         4.8         4.186957     0.384122
```

One missing cell in each of `visitors`, `revenue` and `rating` — exactly the three problems in the file. A `masked` count you did not expect is the usual sign that a column was read with the wrong type, so this table is worth a look after every read.

## Choosing rows

`filter` keeps the rows for which a condition holds. The block receives the frame, and the condition is built from its columns:

```ruby
busy = sales.filter { |f| f["visitors"] >= 300 }
p busy
# #<CAFrame nrow=8 columns=[date:CATime[D], shop:CAString, visitors:int64, revenue:float64, rating:float64]>
# date        shop     visitors  revenue  rating
# ----------  -------  --------  -------  ------
# 2024-03-04  central       310   3038.0     3.8
# 2024-03-06  central       305  3078.67     3.7
# 2024-03-07  central       322  3060.93     4.0
# 2024-03-08  central       388        _     3.6
# 2024-03-09  north         341   3974.7       _
# 2024-03-09  central       402   3939.6     3.5
# 2024-03-10  north         322  4112.58     4.1
# 2024-03-10  central       355  3270.26     3.7
```

The south shop's 6 March row is not a candidate: its count is missing, so whether it had 300 visitors cannot be decided, and a row that cannot be decided is left out.

Conditions combine with `&` (and) and `|` (or). Each part is in parentheses, because `&` binds more tightly than a comparison:

```ruby
sales.filter { |f| f["shop"].eq("north") & (f["rating"] >= 4.3) }.nrow   # => 3
```

## Summarising by shop

`group_by` gathers the rows of each shop, and a reduction such as `mean` then gives one row per shop. The date column is dropped first, since an average date is not what we are after:

```ruby
p sales.drop("date").group_by("shop").mean
# #<CAFrame nrow=3 columns=[visitors:float64, revenue:float64, rating:float64] index="shop">
# shop       visitors      revenue  rating
# -------  ----------  -----------  ------
# north        233.75   2874.36625     4.2
# south    129.857143   1911.58375     4.6
# central     334.375  3159.001429  3.7625
```

The shop names became the row labels of the result, its **index**. Each mean leaves out the missing cells: the south shop's mean visitor count is over its seven counted days.

To choose a different reduction for each column, and name the results, use `aggregate`:

```ruby
summary = sales.group_by("shop").aggregate(
  "revenue"      => ["revenue", :sum],
  "best_day"     => ["revenue", :max],
  "busiest"      => ["visitors", :max],
  "days_counted" => ["visitors", :count],
)
p summary
# #<CAFrame nrow=3 columns=[revenue:float64, best_day:float64, busiest:int64, days_counted:int64] index="shop">
# shop      revenue  best_day  busiest  days_counted
# -------  --------  --------  -------  ------------
# north    22994.93   4112.58      341             8
# south    15292.67   2785.04      186             7
# central  22113.01    3939.6      402             8
```

`days_counted` counts the visitor numbers actually present, which tells you how much each figure rests on. The central shop's total revenue leaves out 8 March, which has no figure; that is worth knowing before comparing the totals.

## Summarising over time

`resample` groups rows into time bins instead of by a column's values. The chain's total revenue per week:

```ruby
p sales.select("date", "revenue").resample("date", "1 week").sum
# #<CAFrame nrow=2 columns=[revenue:float64] index="date">
# date         revenue
# ----------  --------
# 2024-03-04  53606.24
# 2024-03-11   6794.37
```

Weeks start on Monday, and each row is labelled with the week's first day. The second week has only its Monday so far.

## A value relative to its group

How did each day compare with that shop's usual revenue? A group reduction with `keep_rows: true` gives every row the result of its own group, so it lines up with the frame's columns, and the comparison is ordinary column arithmetic:

```ruby
shop_mean = sales.group_by("shop").mean("revenue", keep_rows: true)
sales["vs_usual"] = sales["revenue"] / shop_mean
p sales.head(6)
# #<CAFrame nrow=6 columns=[date:CATime[D], shop:CAString, visitors:int64, revenue:float64, rating:float64, vs_usual:float64]>
# date        shop     visitors  revenue  rating  vs_usual
# ----------  -------  --------  -------  ------  --------
# 2024-03-04  north         182  2121.39     4.2  0.738037
# 2024-03-04  south          95  1391.47     4.6  0.727915
# 2024-03-04  central       310   3038.0     3.8  0.961696
# 2024-03-05  north         175   2235.1     4.3  0.777597
# 2024-03-05  south         102  1632.61     4.7  0.854061
# 2024-03-05  central       295  2717.54     3.9  0.860253
```

`sales["vs_usual"] = ...` adds the new column to the frame. A value above 1 is a better day than that shop's average.

## Adding information from another table

The shop table gives each shop its floor area. `join` adds those columns to the summary, matching rows by the shop key. The summary's index is first turned back into a column with `reset_index`, so it can serve as the key:

```ruby
shops = CAFrame.read_csv("shops.csv")
report = summary.reset_index.join(shops.select("shop", "name", "floor_m2"), on: "shop")
report["revenue_per_m2"] = (report["revenue"] / report["floor_m2"]).round(2)
p report
# #<CAFrame nrow=3 columns=[shop:CAString, revenue:float64, best_day:float64, busiest:int64, days_counted:int64, name:CAString, floor_m2:int64, revenue_per_m2:float64]>
# shop      revenue  best_day  busiest  days_counted  name             floor_m2  revenue_per_m2
# -------  --------  --------  -------  ------------  ---------------  --------  --------------
# north    22994.93   4112.58      341             8  North Street          120          191.62
# south    15292.67   2785.04      186             7  South Mall             85          179.91
# central  22113.01    3939.6      402             8  Central Station       240           92.14
```

The west shop is in the shop table but has no sales, so it does not appear: by default `join` keeps the rows of the left table, here the summary.

## Writing the result

`write_csv` writes a frame as CSV to a file, and `to_csv` gives the same text as a String. The revenue totals are sums of floating-point numbers, which can leave a tail of digits such as `22113.010000000002`; rounding them to cents first keeps the file tidy:

```ruby
report["revenue"] = report["revenue"].round(2)
report.write_csv("report.csv")
puts report.to_csv
# shop,revenue,best_day,busiest,days_counted,name,floor_m2,revenue_per_m2
# north,22994.93,4112.58,341,8,North Street,120,191.62
# south,15292.67,2785.04,186,7,South Mall,85,179.91
# central,22113.01,3939.6,402,8,Central Station,240,92.14
```

## What happened along the way

- The file's own ways of writing "no value" became missing cells, and the integer column stayed integer.
- Every summary left out the missing cells, and `count` showed how many were used.
- Each shop's average was put back on every row as an ordinary column.
- `busy` shares its cells with `sales`: a correction made in `busy` would reach `sales`. Chapter 16 explains which operations share cells.

The next chapters take each of these steps in turn.
