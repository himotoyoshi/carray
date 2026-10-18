# Introduction

`CAFrame` is a table of named columns. You read a CSV into it, look at what you got, fix the columns that were read wrongly, pick out rows, summarise by group or by week, join another table, and write the result out — the work any data frame is for.

```ruby
require "carray"

sales = CAFrame.from_csv("sales.csv", types: :infer, missing: ["-1", "n/a"])
p sales.drop("date").group_by("shop").mean
```

```
#<CAFrame nrow=3 columns=[visitors:float64, revenue:float64, rating:float64] index="shop">
shop       visitors      revenue  rating
-------  ----------  -----------  ------
north        233.75   2874.36625     4.2
south    129.857143   1911.58375     4.6
central     334.375  3159.001429  3.7625
```

What makes CAFrame different from other data frames is what a column is. **A column of a frame is a CArray** — the array itself, not a copy and not a wrapper. The frame adds names, an optional set of row labels, and the verbs that work on rows; everything a column holds and does is the array's. Most of what follows comes from that one decision.

## What a column brings with it

### The whole array toolbox works on a column

`sales["revenue"]` is a CArray, so every array operation applies to it: arithmetic, the mathematical functions, reductions along any axis, sorting, searching, histograms, rolling windows. A condition for choosing rows is an array expression built from columns, so there is no separate expression language to learn:

```ruby
mean = sales["revenue"].mean
sales.filter { |f| (f["revenue"] - mean).abs > 1200 }.nrow   # => 4
```

You can take columns out, compute with them as arrays, and put the result back as a new column. Moving between a frame and plain arrays costs nothing: a column taken out is the stored array, and an array you already have becomes a frame column without being copied.

### A missing value is a masked cell, and a column keeps its type

A CArray can mark any of its cells as missing. The mark is kept beside the values, not among them, so no value is used up to stand for "missing". In a frame, this means a column with missing values **keeps its data type**:

```ruby
sales["visitors"].data_type        # => :int64
sales["visitors"].count_masked     # => 1
sales["visitors"][7]               # => UNDEF
sales["visitors"].mean.round(2)    # => 237.13
```

The visitor counts have a missing day and are still a column of integers. Statistics leave the missing cell out. A missing value reads as `UNDEF` and is written by assigning `UNDEF`.

A floating-point NaN is a value, not a missing mark. A column can hold both, and they are told apart: a NaN is a number that came out of a calculation, a masked cell is a value that is not there. Chapter 8 is about working with missing values.

> **Coming from another library.** Many data frame libraries hold a missing number as NaN, so an integer column with a gap becomes a float column, or switches to a separate nullable type. In CAFrame an integer column with gaps stays an integer column, and NaN and missing stay distinct.

### Choosing rows or columns gives a view, not a copy

A frame made from part of another — the rows `filter` chooses, the columns `select` keeps, the first rows `head` gives — **shares its cells with the frame it came from**. Writing a cell through either one changes both:

```ruby
north = sales.filter { |f| f["shop"].eq("north") }
north["visitors"][0] = 999
sales["visitors"][0]       # => 999
north["visitors"][0] = 182
```

This is how CArray works throughout: referring to data does not copy it. It means you can take a part of a large table and work on it without copying, and correct a value in a part and have the correction reach the whole. When you want an independent table, `copy` makes one:

```ruby
snapshot = north.copy
snapshot["visitors"][0] = 0
sales["visitors"][0]       # => 182
```

> **Coming from another library.** In many data frame libraries a filtered frame behaves as an independent copy, and writing to it never reaches the original. Code carried over that writes to a filtered frame will change the original here. Use `copy` where you want the cut. Chapter 16 lists, operation by operation, what shares cells and what does not.

### A column can hold more than one value per row

A column's first axis runs along the rows; it may have more axes after it. A position per row is a column of shape `(N, 2)`, twenty-four hourly counts per day `(N, 24)`, twelve monthly values `(N, 12)`. Such a column sits beside ordinary columns, follows every row selection, and is reduced row-wise by group summaries, so a group's mean hourly profile comes out as a profile. Chapter 14 covers these columns.

### A column can be times, categories or text, and keeps that meaning

Some columns hold values that are stored as numbers but are something else: times, category labels, strings. CArray has array types for these (it calls them *Faces*), and a frame column can be one. A time column compares with time literals, groups into hours or months, and matches another time column measured in a different unit by the instant it names, not by its stored number:

```ruby
sales["date"].class                                     # => CATime
sales.filter { |f| f["date"] >= "2024-03-09" }.nrow     # => 9
```

These columns keep their kind through filtering, sorting, grouping and joining, so a grouped result keyed by time has a time index, and a joined categorical column is still categorical.

## What the frame itself adds

The frame is deliberately thin. It holds:

- the columns, in order, by name;
- optionally an **index**: a row-aligned array of labels — dates, names, identifiers — kept beside the columns rather than among them (chapter 9);
- a few attributes describing the table, such as a title or a source.

Every column has the same number of rows; that is the frame's one rule. The verbs work on rows: choosing them (`filter`, `head`), ordering them (`sort_by_key`), grouping them (`group_by`, `resample`), matching them with another table's (`join`, `align`), and reshaping them (`pivot`, `melt`).

## Errors rather than guesses

CAFrame prefers to tell you about a problem over guessing what you meant. A few examples you will meet:

- Column names are Strings. A Symbol where a column name belongs is refused, so a mistyped option cannot quietly become a column.
- A single number cannot be assigned as a whole column; write the column you mean (`CArray.float64(df.nrow) { 0.0 }`).
- A date written `01/02/2024` is not read as a time unless you say whether the day or the month comes first.
- A cell that cannot be read as the type you asked for becomes missing by default, and you can ask instead to be warned or to have it raise, naming the column, the row and the text.

## Habits that work differently here

If you have used a data frame elsewhere, these are the points most likely to surprise you:

| you might expect | in CAFrame |
|---|---|
| a filtered or selected frame is a copy | it shares cells with the original; `copy` cuts the link |
| a missing integer makes the column float | the column stays integer; the cell is masked |
| missing is NaN | missing is a mask; NaN is an ordinary float value |
| `df["x"]` gives a series object | it gives the column, a CArray |
| arithmetic between two columns lines up rows by label | cells are paired by position; the index takes no part (line up two tables with `align` or `join` first) |
| `df[1..3]` may select by label | ranges select rows by position; `at` finds a row by its label |
| `df["c"] = 0` fills a column | refused; assign a column of the right length |
| column names may be Symbols | names are Strings |

The row about arithmetic deserves an example, because nothing warns you:

```ruby
x = CAFrame.new("v" => CA_INT32([1, 2, 3]))
y = CAFrame.new({ "v" => CA_INT32([10, 20, 30]) }, index: CA_INT32([2, 1, 0]))
(x["v"] + y["v"]).to_a     # => [11, 22, 33]
```

`y`'s index runs backwards, but the sum pairs the first cell with the first cell. Columns of the same frame always line up, because a frame's rows are its rows; columns of different frames line up only when you have made their rows the same.

## Where to go next

Chapter 1 walks through a complete small analysis. If you prefer to learn piece by piece, start at chapter 2.
