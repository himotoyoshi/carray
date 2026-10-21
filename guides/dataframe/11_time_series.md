# Time series

Most tables have a time in them: when an order was placed, the day a figure covers. This chapter covers the tools for working along time: turning text and numbers into times, choosing periods, summarising by hour or week, rolling windows, filling gaps in a regular series, and matching each row with the latest entry of another table.

The examples use the daily `sales` frame and a small log of orders from a café's till, with the price list the café used:

```ruby
require "carray"
require "stringio"

sales = CAFrame.from_csv("sales.csv", missing: ["-1", "n/a"])

orders = CAFrame.from_csv(StringIO.new(<<~CSV))
  time,item,qty
  2024-03-04 08:12,coffee,2
  2024-03-04 08:47,tea,1
  2024-03-04 09:05,coffee,1
  2024-03-04 11:30,cake,3
  2024-03-04 11:58,coffee,2
  2024-03-04 14:20,tea,2
  2024-03-04 14:41,coffee,1
  2024-03-04 16:03,cake,1
CSV

prices = CAFrame.from_csv(StringIO.new(<<~CSV))
  since,item,price
  2024-03-01 00:00,coffee,3.20
  2024-03-01 00:00,tea,2.80
  2024-03-01 00:00,cake,4.50
  2024-03-04 12:00,coffee,3.40
CSV
```

The price of coffee went up at noon on 4 March.

## Time columns

A time column is a `CATime`: each cell is an instant, kept to a fixed **resolution** — a day, a second, a millisecond. The resolution is shown in brackets:

```ruby
sales["date"].class       # => CATime
orders.data_types["time"] # => CATime
p orders.head(2)
# #<CAFrame nrow=2 columns=[time:CATime[s], item:CAString, qty:int64]>
# time                  item    qty
# --------------------  ------  ---
# 2024-03-04T08:12:00Z  coffee    2
# 2024-03-04T08:47:00Z  tea       1
```

`orders["time"]` is stored to the second (`CATime[s]`), and `sales["date"]` to the day (`CATime[D]`). Times are read as UTC unless the text gives a zone.

A time column compares with text, `Time` and `Date`, which is what makes conditions on time short:

```ruby
orders.filter { |f| f["time"] < "2024-03-04 12:00" }.nrow   # => 5
```

Its parts are available as integer columns: `year`, `month`, `day`, `hour`, `minute`, `second`, `weekday` (0 for Sunday), `yday` (day of the year) and `iso_week`:

```ruby
orders["time"].hour.to_a   # => [8, 8, 9, 11, 11, 14, 14, 16]
```

### Making a time column

| your times are… | turn them into a time column with |
|---|---|
| written year first: `2024-03-04`, `2024-03-04 08:12` | `from_csv` (inferred) or `types: { "time" => :time }` when reading |
| text in another layout: `04/03/2024`, `Mar 4, 2024` | `parse_to_time(name, format)` |
| numbers counted from a starting date: seconds since 1970, a spreadsheet's day numbers | `to_time(name, unit:, epoch:)` |

#### Text — `parse_to_time`

`parse_to_time` gives a new frame with a text column converted:

```ruby
d = CAFrame.new("day" => CArray.string(["04/03/2024", "15/03/2024", "01/04/2024"]))
d = d.parse_to_time("day", "%d/%m/%Y")
d["day"].to_a.map(&:to_s)   # => ["2024-03-04", "2024-03-15", "2024-04-01"]
```

The second argument says how the text is written:

- a **format**, as `Time.strptime` takes it: `"%d/%m/%Y"`, `"%m/%d/%Y %H:%M"`;
- **nothing**, for text written year first;
- **`:infer`**, when the text is in one layout but you do not know which: CAFrame tries the common layouts and keeps the one every cell fits;
- **`:mixed`**, when each cell is written its own way. It guesses at each cell separately, as `Time.parse` does, so it can misread a cell without saying so — `"01/02/24"` becomes 24 February 2001 — and it is much slower. Use it only for data that leaves no other choice.

`:infer` refuses to guess when the text could be read more than one way. If every day in the column is 12 or less, nothing tells day-first from month-first:

```ruby
e = CAFrame.new("day" => CArray.string(["04/03/2024", "05/03/2024"]))
e.parse_to_time("day", :infer)   # raises CAFrame::AmbiguousTimeFormat
```

The error lists the candidates in `formats`, so you can choose one and pass it. `infer_time_format` gives the format `:infer` would use, without converting, so you can write it into your program:

```ruby
CAFrame.new("day" => CArray.string(["04/03/2024", "15/03/2024"])).infer_time_format("day")   # => "%d/%m/%Y"
```

A cell that does not fit the format becomes missing; `on_error: :warn` or `:raise` reports it instead, as for `cast` (chapter 3). The resolution is the finest the text shows: days for dates alone, seconds when there is a time of day. `unit:` sets it yourself.

#### Counts from a starting date — `to_time`

Some systems store a time as a count: seconds since 1970, hours since some date, a spreadsheet's day number. `to_time` reads such a column, given the unit and the starting date (the **epoch**, 1970-01-01 when left out):

```ruby
x = CAFrame.new("t" => CA_INT64([1709510400, 1709514000]))
x = x.to_time("t", unit: :s)
x["t"].to_a.map(&:to_s)   # => ["2024-03-04T00:00:00Z", "2024-03-04T01:00:00Z"]

sheet = CAFrame.new("day" => CA_INT64([45355, 45356]))
sheet = sheet.to_time("day", unit: :D, epoch: "1899-12-30")   # spreadsheet day numbers
sheet["day"].to_a.map(&:to_s)   # => ["2024-03-04", "2024-03-05"]
```

Units are written `:s`, `:ms`, `:us`, `:ns` for seconds and their fractions, `:m`, `:h`, `:D`, `:W`, `:M`, `:Y` for minutes up to years, or as text with a count, `"10 minutes"`.

### Periods: `floor`, `ceil`, `round`

`floor(unit:)` brings each time down to the start of its period — its hour, its day, its week — which makes a key for grouping:

```ruby
orders["time"].floor(unit: :h).to_a.map(&:to_s).first(3)
# => ["2024-03-04T08:00:00Z", "2024-03-04T08:00:00Z", "2024-03-04T09:00:00Z"]
```

`ceil` brings times up to the end of their period, and `round` to the nearest boundary.

## Summarising by period — `resample`

`resample(time_column, unit)` groups rows into periods of time. It returns a grouped frame, so every summary of chapter 10 applies:

```ruby
p orders.resample("time", "1 hour")["qty"].sum.to_a   # sold per hour
p orders.drop("item").resample("time", "1 hour").sum
# [3.0, 1.0, 5.0, 3.0, 1.0]
# #<CAFrame nrow=5 columns=[qty:float64] index="time">
# time                  qty
# --------------------  ---
# 2024-03-04T08:00:00Z  3.0
# 2024-03-04T09:00:00Z  1.0
# 2024-03-04T11:00:00Z  5.0
# 2024-03-04T14:00:00Z  3.0
# 2024-03-04T16:00:00Z  1.0
```

The result's index is each period's start, as a time column, and its rows are in time order. The time column itself becomes the index rather than a summarised column. With a time index, give the index's name as the time column.

### Periods within each group — `by:`

`by:` names a column (or several) to split the rows by first; the periods are then made within each group. Weekly revenue for each shop:

```ruby
p sales.select("date", "shop", "revenue").resample("date", "1 week", by: "shop").sum
# #<CAFrame nrow=6 columns=[shop:CAString, date:CATime[D], revenue:float64]>
# shop     date         revenue
# -------  ----------  --------
# north    2024-03-04  20733.67
# north    2024-03-11   2261.26
# south    2024-03-04  13767.57
# south    2024-03-11    1525.1
# central  2024-03-04   19105.0
# central  2024-03-11   3008.01
```

The result has a column for each `by:` key and one for the period's start, and a row for each group and period. It has no index; the groups keep the order in which they first appear. Weeks begin on Monday.

To have one column per shop instead, make a week key with `floor` and spread it with `pivot` (chapter 13), which puts one column's values across columns:

```ruby
weekly = sales.select("date", "shop", "revenue").copy
weekly["week"] = weekly["date"].floor(unit: :W)
p weekly.pivot(index: "week", columns: "shop", values: "revenue", aggregate: :sum)
# #<CAFrame nrow=2 columns=[central:float64, north:float64, south:float64] index="week">
# week        central     north     south
# ----------  -------  --------  --------
# 2024-03-04  19105.0  20733.67  13767.57
# 2024-03-11  3008.01   2261.26    1525.1
```

### Empty periods — `fill: true`

A period with no rows does not appear. The till above recorded nothing between 10:00 and 11:00, so that hour is missing from the table. `fill: true` gives every period from the first to the last a row. An empty period is summarised as an empty set is: `0` for `sum` and `count`, `UNDEF` for `mean`, `max` and the like — so "nothing sold" and "no data" stay distinguishable:

```ruby
p orders.drop("item").resample("time", "1 hour", fill: true).sum
# #<CAFrame nrow=9 columns=[qty:float64] index="time">
# time                  qty
# --------------------  ---
# 2024-03-04T08:00:00Z  3.0
# 2024-03-04T09:00:00Z  1.0
# 2024-03-04T10:00:00Z  0.0
# 2024-03-04T11:00:00Z  5.0
# 2024-03-04T12:00:00Z  0.0
# 2024-03-04T13:00:00Z  0.0
# 2024-03-04T14:00:00Z  3.0
# 2024-03-04T15:00:00Z  0.0
# 2024-03-04T16:00:00Z  1.0
```

### Which end names a period — `label:`

By default a period is named by its start, and holds the times at or after it: the 08:00 row covers 08:00 up to, but not including, 09:00. With `label: :right` a period is named by its end, and holds the times up to and including it — the usual convention for a figure that describes the period before a time, such as "orders in the two hours up to 12:00":

```ruby
p orders.resample("time", "2 hours", label: :right)["qty"].count_not_masked.to_a
# [3, 2, 2, 1]
```

`origin:` shifts the periods: `"1 hour"` with `origin: "2024-03-04 00:30"` gives periods starting at half past each hour. Month and year periods always start on calendar boundaries.

### Periods with too little data

`min_count:` (chapter 10) makes a period's summary `UNDEF` when it has fewer values than you require — a daily mean from hourly figures that wants all 24 hours, say.

## Rolling windows — `windows`

A rolling figure looks at the rows within a span of time around each row: the last hour, the last seven days. `windows(on:, before:)` builds, for each row, the window of rows whose time falls within `before` of its own; reductions on it give one value per row:

```ruby
w = orders.windows(on: "time", before: "1 hour")
w.sum("qty").to_a        # => [2.0, 3.0, 4.0, 3.0, 5.0, 2.0, 3.0, 1.0]
w.elements.to_a          # => [1, 2, 3, 1, 2, 1, 2, 1]
```

Each row's window is the hour ending at its own time: the start is left out and the row itself is included. So the 09:05 order's window holds the two orders before it and itself. `elements` tells you how many rows each window held. A window is defined by time, not by a number of rows, so a quiet period shortens it rather than reaching further back.

- `before:` and `after:` set the span on each side; `exclude:` says whether its ends are included.
- `by:` keeps each window within the rows of the same group — an average over each shop's last three days, for instance:

```ruby
roll = sales.windows(on: "date", before: "3 days", by: "shop")
sales.select("date", "shop", "revenue").copy.append("avg3", roll.mean("revenue")).head(6).then { |f| p f }
# #<CAFrame nrow=6 columns=[date:CATime[D], shop:CAString, revenue:float64, avg3:float64]>
# date        shop     revenue      avg3
# ----------  -------  -------  --------
# 2024-03-04  north    2121.39   2121.39
# 2024-03-04  south    1391.47   1391.47
# 2024-03-04  central   3038.0    3038.0
# 2024-03-05  north     2235.1  2178.245
# 2024-03-05  south    1632.61   1512.04
# 2024-03-05  central  2717.54   2877.77
```

The rows need not be in time order. A row whose time is missing has no window, and its results are `UNDEF`.

To check that a window is complete, give the expected spacing of the data with `interval:`; `is_complete` then tells you which windows hold every point they should:

```ruby
roll = sales.windows(on: "date", before: "3 days", by: "shop", interval: "1 day")
roll.is_complete.to_a.first(9)   # => [false, false, false, false, false, false, true, true, true]
```

The first two days of each shop have fewer than three days behind them. `roll.mean("revenue").mask_where(roll.is_complete.not)` keeps only the full three-day averages.

`at:` places windows at times you give instead of at the rows — a two-hour window every hour, for instance — and returns a frame with a row per time.

## A regular series and its gaps — `align`

A series that should have one row per day may be missing some days, and nothing in the table says so. `align` puts a frame onto a complete axis of times that you supply. Days the frame lacks come back as rows with the time and nothing else:

```ruby
north = sales.filter { |f| f["shop"].eq("north") }.drop("shop").copy
north = north[north["date"].ne("2024-03-07")]       # suppose one day is not in the file
days = CArray.time_range("2024-03-04", "2024-03-11", unit: :D)
full = north.align("date", days)
p full
# #<CAFrame nrow=8 columns=[date:CATime[D], visitors:int64, revenue:float64, rating:float64]>
# date        visitors  revenue  rating
# ----------  --------  -------  ------
# 2024-03-04       182  2121.39     4.2
# 2024-03-05       175   2235.1     4.3
# 2024-03-06       190  2285.32     4.1
# 2024-03-07         _        _       _
# 2024-03-08       268   3323.2     4.0
# 2024-03-09       341   3974.7       _
# 2024-03-10       322  4112.58     4.1
# 2024-03-11       188  2261.26     4.3
```

`CArray.time_range` makes every day from the first to the last; `"1 hour"` or `"15 minutes"` make other grids. Once the gaps are rows, they can be filled. With the dates as the index, `:linear` interpolates in time:

```ruby
full = full.set_index("date").cast("revenue" => :float64).fill("revenue", :linear)
full.at("2024-03-07")["revenue"].round(2)   # => 2804.26
```

## The latest entry of another table — `join_asof`

Each order should be priced at the price in effect when it was placed. The price list has an entry only when a price changes, so an order's price is the **latest entry at or before its time**, for the same item. That is `join_asof`:

```ruby
priced = orders.join_asof(prices.rename("since" => "time"), on: "time", by: "item")
priced["amount"] = priced["qty"] * priced["price"]
p priced
# #<CAFrame nrow=8 columns=[time:CATime[s], item:CAString, qty:int64, price:float64, amount:float64]>
# time                  item    qty  price  amount
# --------------------  ------  ---  -----  ------
# 2024-03-04T08:12:00Z  coffee    2    3.2     6.4
# 2024-03-04T08:47:00Z  tea       1    2.8     2.8
# 2024-03-04T09:05:00Z  coffee    1    3.2     3.2
# 2024-03-04T11:30:00Z  cake      3    4.5    13.5
# 2024-03-04T11:58:00Z  coffee    2    3.2     6.4
# 2024-03-04T14:20:00Z  tea       2    2.8     5.6
# 2024-03-04T14:41:00Z  coffee    1    3.4     3.4
# 2024-03-04T16:03:00Z  cake      1    4.5     4.5
```

The coffee at 11:58 is at the old price, the one at 14:41 at the new.

- `on:` is the time (or other ordered) column, present in both frames under the same name.
- `by:` names columns that must match exactly before the nearest time is chosen.
- `direction:` is `:floor` (the latest at or before, the default), `:ceil` (the first at or after) or `:round` (the nearest).
- `tolerance:` refuses a match farther away than a duration, `"10 minutes"`, so a stale entry is not used: such a row gets `UNDEF`.

Neither frame needs to be sorted.

## Changes over time

The difference from the previous day, per shop, is a group `lag` (chapter 10). The rows must be in time order within each shop, which `sales` already is; sort with `sort_by_key("date")` when it is not:

```ruby
g = sales.group_by("shop")
change = sales["revenue"] - g.lag("revenue")
change.to_a.first(6).map { |v| v == UNDEF ? v : v.round(2) }   # => [UNDEF, UNDEF, UNDEF, 113.71, 241.14, -320.46]
```

## Times in different resolutions

Two time columns of different resolutions — days and seconds, say — compare and match by the instant they name. A day matches midnight of that day:

```ruby
day = CArray.time(["2024-03-04"], unit: :D)
sec = CArray.time(["2024-03-04 00:00:00"], unit: :s)
day.eq(sec).to_a   # => [true]
```

This holds for comparisons, `join`, `align` and the other ways tables are matched, so a daily table and a table of exact times can be put together without converting either.

## In the CArray User's Guide

Time columns are `CATime` arrays, which the CArray User's Guide covers in full in *Time arrays* ([26_time_arrays.md](../users/26_time_arrays.md)): resolutions, arithmetic with durations, and the step system behind `floor` and `resample`.
