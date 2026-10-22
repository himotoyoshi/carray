# Combining tables

Data you need often sits in more than one table: daily figures in one, the shops' details in another; this week's file and last week's. This chapter covers putting tables together. Which method to use depends on how the rows of the tables correspond:

| the rows correspond… | use |
|---|---|
| by a key, such as a shop name, in both tables | `join` |
| by the nearest key, such as the latest time at or before | `join_asof` (chapter 11) |
| by a key, to a list of keys you supply | `align` |
| not at all: one table's rows follow the other's | `CAFrame.meld` / `CAFrame.concatenate` |
| by position: the same rows, more columns | `paste` |

```ruby
require "carray"
sales = CAFrame.from_csv("sales.csv", missing: ["-1", "n/a"])
shops = CAFrame.from_csv("shops.csv")
```

## Matching rows by a key — `join`

`join` puts each row of this table together with the rows of the other table that have the same key:

```ruby
detail = sales.join(shops.select("shop", "size", "floor_m2"), on: "shop")
p detail.head(4)
# #<CAFrame nrow=4 columns=[date:CATime[D], shop:CAString, visitors:int64, revenue:float64, rating:float64, size:CAString, floor_m2:int64]>
# date        shop     visitors  revenue  rating  size   floor_m2
# ----------  -------  --------  -------  ------  -----  --------
# 2024-03-04  north         182  2121.39     4.2  small       120
# 2024-03-04  south          95  1391.47     4.6  small        85
# 2024-03-04  central       310   3038.0     3.8  large       240
# 2024-03-05  north         175   2235.1     4.3  small       120
```

The key column appears once, and the other table's columns follow this table's.

### Which rows to keep — `how:`

The two tables need not have the same keys. The shop table has a `west` shop with no sales; here a small table also has an `east` shop that the shop table does not know:

```ruby
extra = CAFrame.new("shop" => ["north", "east"], "revenue" => [100.0, 200.0])
left  = extra.join(shops.select("shop", "size"), on: "shop")
left["size"].to_a   # => ["small", UNDEF]
```

| `how:` | keeps |
|---|---|
| `:left` (default) | every row of this table; a row with no match gets missing values in the new columns |
| `:inner` | only rows whose key is in both tables |
| `:outer` | every row of both tables |
| `:right` | every row of the other table |

```ruby
extra.join(shops.select("shop", "size"), on: "shop", how: :inner).nrow   # => 1
extra.join(shops.select("shop", "size"), on: "shop", how: :outer).nrow   # => 5
extra.join(shops.select("shop", "size"), on: "shop", how: :right).nrow   # => 4
```

`:left` is what you usually want when adding details to a table: every row stays, and a missing match is visible as missing values rather than a vanished row.

When a key appears more than once on both sides, every pairing gives a row: a key on 2 rows of this table and 3 of the other gives 6 rows. When the other table's key is unique — one row per shop, as here — `:left` gives exactly one row per row of this table, in the same order.

The result shares cells with the tables it came from wherever every row has a row of that table: this table's columns for `:left` and `:inner`, the other table's for `:inner` and `:right`. Writing such a cell writes the original, and reading it looks the rows up each time. When you will write to the result, or read it many times — group it, summarize it repeatedly — take a copy first:

```ruby
both = extra.join(shops.select("shop", "size"), on: "shop", how: :inner).copy
```

### Cleaning data through a join

The sharing is what data cleaning needs. A table read from a file or a database is a working copy: the source stays as it is, and the cleaning happens on the copy, just before the analysis. A check often needs both tables — here, a day with more than 2.5 visitors per square metre of floor is suspect — and the cells it finds belong to one of them. Build the condition on the joined table and write to it; with the default `:left`, this table's columns are shared, so the write lands in the original. Work on a copy to keep `sales` as it is:

```ruby
checked = sales.copy
detail  = checked.join(shops.select("shop", "floor_m2"), on: "shop")
crowded = detail["visitors"] > detail["floor_m2"] * 2.5
detail["visitors"][crowded] = UNDEF
checked["visitors"].count_masked   # => 3, one of them missing already
```

The other table's columns — the side with missing values for rows without a match — are new columns of the joined table, so a write to them stays there. To write back to that table too, pass `view: :full`: its columns become views as well, with the places without a match left as holes that read as missing and ignore writes. Here the floor area is the one to doubt:

```ruby
area    = shops.select("shop", "floor_m2").copy
detail  = sales.join(area, on: "shop", view: :full)
crowded = detail["visitors"] > detail["floor_m2"] * 2.5
detail["floor_m2"][crowded] = UNDEF
area["floor_m2"].to_a   # => [UNDEF, 85, 240, 200]
```

`view: :full` is experimental, and a column with holes is slow to read — ten times or more. That is fine for cleaning; for the analysis afterwards, use the cleaned tables themselves, or a copy of the joined one.

### Keeping rows by whether the other table has their key — `:semi`, `:anti`

Sometimes you want no columns from the other table, only to know whether it has the key. `:semi` keeps the rows whose key the other table has; `:anti` keeps the rows whose key it does not have:

```ruby
large = shops.filter { |f| f["size"].eq("large") }
sales.join(large, on: "shop", how: :semi)["shop"].to_a.uniq   # => ["central"]
shops.join(sales, on: "shop", how: :anti)["shop"].to_a        # => ["west"]
```

The second line is a common check: which shops have no sales at all. Each row appears at most once, in this table's order, and shares its cells with this table, as `filter` does.

### Several key columns

Give an Array of names to match on several columns at once; a row matches when every one of them matches:

```ruby norun
orders.join(targets, on: ["shop", "date"])
```

### Keys with different names

When the key has another name in the other table, give a Hash of this table's name to the other's. The key keeps this table's name, and the other table's key column is not added:

```ruby
codes = shops.rename("shop" => "code")
sales.join(codes.select("code", "size"), on: { "shop" => "code" }).column_names
# => ["date", "shop", "visitors", "revenue", "rating", "size"]
```

### How keys are compared

Keys are compared by value, so the two key columns need not be of the same type:

- **Numbers** of different types match when their values are equal: an integer `2` matches a float `2.0`.
- **Times** of different resolutions match by the instant: a day matches midnight of that day.
- **Text** held in different ways — a text column, a categorical column, fixed-width strings — matches by the strings.
- **NaN** matches NaN; a **missing** key matches nothing.

Two cases are stricter. An object column compares with Ruby's `eql?`, as a Ruby Hash does, so `1` and `1.0` are different keys there; convert such a column to a number first. And a time key does not match plain integers, which have no unit; convert them with `to_time` first (chapter 11).

### Columns with the same name

A column other than the key that both tables have would appear twice. By default both copies get a suffix, `_left` and `_right`:

```ruby
target = CAFrame.new("shop" => ["north", "south", "central"], "revenue" => [20000.0, 15000.0, 25000.0])
actual = sales.select("shop", "revenue").group_by("shop").sum.reset_index
p actual.join(target, on: "shop", suffixes: ["_actual", "_target"])
# #<CAFrame nrow=3 columns=[shop:CAString, revenue_actual:float64, revenue_target:float64]>
# shop     revenue_actual  revenue_target
# -------  --------------  --------------
# north          22994.93         20000.0
# south          15292.67         15000.0
# central        22113.01         25000.0
```

`suffixes:` names them yourself, which saves a `rename` afterwards. With `suffixes: false`, a column name in both tables raises an error instead.

### Joining on the index

The key may be the index of either table, named by its axis name:

```ruby
by_shop = shops.copy.set_index("shop")
sales.join(by_shop.select("size"), on: "shop").column_names.last   # => "size"
```

The result keeps this table's index.

## Conforming to a list of keys — `align`

`align` puts a table onto a list of keys that you supply, in that order: a row for each key, taken from the table where it has one, and a row of missing values where it does not. Keys the table has but the list does not are left out:

```ruby
summary = sales.select("shop", "visitors", "revenue").group_by("shop").sum.reset_index
p summary.align("shop", ["central", "north", "south", "west"])
# #<CAFrame nrow=4 columns=[shop:object, visitors:float64, revenue:float64]>
# shop     visitors   revenue
# -------  --------  --------
# central    2675.0  22113.01
# north      1870.0  22994.93
# south       909.0  15292.67
# west            _         _
```

`align` is how you make sure a report has a row for every member of a list — every shop, every product, every day (chapter 11 uses it with a list of days) — whether or not the data has one. It only matches rows; filling the gaps is up to you.

## One table after another — `meld` and `concatenate`

Data delivered in parts — one file per week, one per shop — is put back together by placing the tables one after another. The tables must have the same column names; the columns are matched by name:

```ruby
week1 = sales.filter { |f| f["date"] < "2024-03-11" }
week2 = sales.filter { |f| f["date"] >= "2024-03-11" }
all = CAFrame.concatenate(week1, week2)
all.nrow   # => 24
```

There are two ways to do it, which differ in whether the result is connected to its parts:

| | result | column types |
|---|---|---|
| `CAFrame.concatenate` | an independent table | may differ between the parts; each column takes a type that can hold every part |
| `CAFrame.meld` | a view of the parts, sharing their cells | must be the same in every part |

`meld` copies nothing, so it suits large tables and a result you only read. Writing a cell of a melded table writes the part it came from, and the other way around. `concatenate` gives a table of its own, and also lets parts differ in type — one file's `visitors` read as integers, another's as floats:

```ruby
a = CAFrame.new("shop" => ["north"], "visitors" => CA_INT64([182]))
b = CAFrame.new("shop" => ["south"], "visitors" => CA_FLOAT64([95.5]))
CAFrame.concatenate(a, b)["visitors"].to_a   # => [182.0, 95.5]
CAFrame.meld(a, b)                           # raises ArgumentError
```

Both take any number of tables, or an Array of them. Missing values are kept. When the tables have an index, the indexes are joined too.

## The same rows, more columns — `paste`

When two tables have the same rows in the same order — two exports of the same data with different columns — `paste` puts their columns side by side:

```ruby
counts  = sales.select("date", "shop", "visitors")
figures = sales.select("revenue", "rating")
counts.paste(figures).column_names   # => ["date", "shop", "visitors", "revenue", "rating"]
```

`paste` matches rows by position and checks only that the numbers of rows agree. If the rows might not be in the same order, use `join` on a key instead. Columns with the same name get suffixes, as with `join`.
