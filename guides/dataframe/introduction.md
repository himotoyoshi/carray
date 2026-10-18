# Introduction

`CAFrame` is a table: named columns of the same length, one row per record. Its columns can be arrays you already have, records from a JSON response, or the columns of a CSV file. With a frame you look at the data, fix columns that are not yet what they should be, pick out rows, summarise by group or by week, join another table, and write the result out.

```ruby
require "carray"

df = CAFrame.new(
  "shop"     => ["north", "south", "north", "south"],
  "visitors" => [182, 95, 175, nil],
  "revenue"  => [2121.39, 1391.47, 2235.10, 1632.61],
)
p df.group_by("shop").mean
# #<CAFrame nrow=2 columns=[visitors:float64, revenue:float64] index="shop">
# shop   visitors   revenue
# -----  --------  --------
# north     178.5  2178.245
# south      95.0   1512.04
```

Here the frame is built from Ruby Arrays, and `group_by("shop").mean` gives each shop's average visitors and revenue. The south shop's second visitor count is missing (`nil`), so its visitor average, 95.0, is the average of the one day that has a count.

Each column of a frame is a CArray, and `df["name"]` gives you that array itself, so anything you can do with a CArray you can do with a column.

## Things worth knowing from the start

A few points of how frames behave come up in almost every chapter. They are collected here so that they do not surprise you later. The examples use the small frame `df` built above.

### Columns are arrays

A column is a CArray, so you work on it with array operations. Conditions for choosing rows are written the same way, from columns:

```ruby
mean = df["revenue"].mean
df.filter { |f| f["revenue"] > mean }.nrow   # => 2
```

A result with one value per row can be put back as a new column:

```ruby
df["per_visitor"] = df["revenue"] / df["visitors"]
df["per_visitor"][0].round(2)   # => 11.66
```

### A missing value is a masked cell

A cell that has no value is **masked**: it reads as `UNDEF`, and assigning `UNDEF` masks a cell. The `nil` given for the last visitor count became a masked cell. The mark is kept beside the values, so a column with missing values keeps its type — the visitor counts are still integers:

```ruby
df["visitors"].data_type        # => :int64
df["visitors"].count_masked     # => 1
df["visitors"][3]               # => UNDEF
df["visitors"].mean.round(2)    # => 150.67
```

Summaries such as `mean` leave masked cells out: the mean here is over the three counts present. A calculation with a masked input gives a masked result, so `per_visitor` above is masked in the last row too. A floating-point NaN is not a missing value but an ordinary float value, and it takes part in calculations. Chapter 8 covers missing values.

### Part of a frame shares its cells with the frame

A frame made by choosing rows or columns of another — with `filter`, `select`, `head` and the like — is a **view**: its cells are the cells of the frame it came from. Writing a cell through one changes the other:

```ruby
north = df.filter { |f| f["shop"].eq("north") }
north["visitors"][0] = 999
df["visitors"][0]       # => 999
north["visitors"][0] = 182
```

This lets you correct values in part of a table and have the correction reach the whole. When you want a table of its own, `copy` makes one:

```ruby
snapshot = north.copy
snapshot["visitors"][0] = 0
df["visitors"][0]       # => 182
```

Chapter 16 lists which operations share cells and which do not.

### Columns of different frames are paired by position

Arithmetic between two columns pairs the first cell with the first cell, the second with the second, and so on. Row labels play no part:

```ruby
x = CAFrame.new("v" => CA_INT32([1, 2, 3]))
y = CAFrame.new({ "v" => CA_INT32([10, 20, 30]) }, index: CA_INT32([2, 1, 0]))
(x["v"] + y["v"]).to_a     # => [11, 22, 33]
```

Columns of the same frame always line up, since they are the same rows. To line up two different tables by a key, `join` or `align` them first (chapter 12).

### Column names are Strings

Every column name is a String: `df["revenue"]`, `group_by("shop")`. A Symbol given where a column name belongs raises an error.

### A column is always a full column

`df["flag"] = 0` raises an error: a column needs one value per row. Make the column you mean, such as `CArray.int8(df.nrow) { 0 }`.

### Times, categories and text keep their kind

A column of dates, of category labels or of text is a column of that kind, and stays one through filtering, sorting, grouping and joining. A date column compares with dates written as text:

```ruby
days = CAFrame.new("date"     => CArray.time(["2024-03-04", "2024-03-05", "2024-03-06"], unit: :D),
                   "visitors" => [182, 175, 190])
days["date"].class                                    # => CATime
days.filter { |f| f["date"] >= "2024-03-05" }.nrow    # => 2
```

## What you can do with a frame

| you want to… | chapter |
|---|---|
| see a whole small analysis from start to finish | 1 |
| make a frame from arrays, records or a CSV file | 2, 3 |
| check what you have read: sizes, types, missing values | 4 |
| take columns and rows out of a frame | 5 |
| keep the rows that meet a condition, or put rows in order | 6 |
| add, convert and tidy columns | 7 |
| find, mark and fill missing values | 8 |
| label rows by a date or a name | 9 |
| summarise by group: totals, averages, ranks | 10 |
| work along time: periods, rolling windows, gaps | 11 |
| combine tables by a key, or one after another | 12 |
| turn a long table into a wide one, and back | 13 |
| keep several values per row in one column | 14 |
| move between a frame and arrays | 15 |
| know when a change reaches another frame | 16 |
| write CSV, JSON or a text report | 17 |
