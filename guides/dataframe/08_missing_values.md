# Missing values

Real tables have gaps: a counter that failed, a field left empty, a value that could not be read. In CAFrame a gap is a **masked cell** — a cell marked as having no value. This chapter is about working with them: where they come from, how calculations treat them, and how to mark, fill or remove them.

```ruby
require "carray"
sales = CAFrame.from_csv("sales.csv", missing: ["-1", "n/a"])
```

## What a missing value is

Every column, whatever its type, can mark any of its cells as missing. The mark is kept beside the values, not among them. Reading a missing cell gives `UNDEF`, and assigning `UNDEF` makes a cell missing:

```ruby
sales["visitors"][7]               # => UNDEF
sales["visitors"].data_type        # => :int64
sales["visitors"].count_masked     # => 1
```

Because the mark is separate from the values, missing values do not change a column's type. An integer column with gaps is still an integer column; a date column with gaps is still a date column; a text column with gaps has missing cells, not empty strings.

### NaN is not missing

A NaN (not-a-number) in a float column is a value: the result of a calculation such as `0.0 / 0.0`. A missing cell is a value that is not there. A column can hold both, and they are told apart:

```ruby
x = CA_FLOAT64([1.0, Float::NAN, 3.0])
x[2] = UNDEF
x.is_nan.to_a         # => [false, true, UNDEF]
x.is_masked.to_a      # => [false, false, true]
```

Statistics leave out missing cells, but a NaN takes part like any number, and usually makes the result NaN. If NaN in your data means "no value", make it missing (below).

## Where missing values come from

| source | |
|---|---|
| reading a file | an empty field; a field matching a `missing:` token; a cell that cannot be read as the column's type (chapter 3) |
| building a frame | `nil` or `UNDEF` in a Ruby Array; a key missing from a record or a JSON `null` (chapter 2) |
| calculation | any element-wise calculation with a missing input |
| combining tables | a `join` row with no match on the other side; an `align` key not in the table (chapter 12) |
| reshaping | a `pivot` cell no row fills (chapter 13) |
| summaries | a group with nothing to summarise, for summaries that have no value for an empty set (below) |
| time series | a `lag` before a group's first row; an empty bin of `resample(fill: true)` (chapters 10 and 11) |

## Finding them

`describe` gives the count for every column (chapter 4). For one column, `count_masked` counts and `is_masked` marks:

```ruby
sales.columns.map(&:count_masked)                    # => [0, 0, 1, 1, 1]
sales[sales["revenue"].is_masked]["shop"].to_a       # => ["central"]
```

The rows missing anything at all:

```ruby
any_missing = sales.columns.map(&:is_masked).inject(:|)
any_missing.count(true)   # => 3
```

## How calculations treat them

### Arithmetic carries them through

A calculation with a missing input gives a missing result:

```ruby
(sales["visitors"] * 2)[7]                         # => UNDEF
(sales["revenue"] / sales["visitors"])[7]          # => UNDEF
```

### Summaries leave them out

Reductions — `sum`, `mean`, `min`, `max`, `stddev`, `median`, … — use only the cells that hold values:

```ruby
south = sales.filter { |f| f["shop"].eq("south") }
south["visitors"].count_not_masked   # => 7
south["visitors"].mean.round(1)      # => 129.9
```

The mean is over the south shop's seven counted days.

### When there is nothing left

When every cell is missing, a summary has nothing to work with. Those that have a natural value for "nothing" give it — `sum` is `0`, `count` is `0` — and the rest give `UNDEF`, since there is no mean or maximum of nothing:

```ruby
none = CA_FLOAT64([UNDEF, UNDEF])
none.sum     # => 0.0
none.mean    # => UNDEF
none.max     # => UNDEF
```

No error is raised, so a group summary with an empty group still gives every other group its value (chapter 10).

### Requiring enough values — `min_count:`

A mean of one day out of eight is still a mean, but you may not want to trust it. `min_count:` makes the result `UNDEF` unless at least that many values were present; `fill_value:` puts a value of your choosing where the result is `UNDEF`:

```ruby
south["visitors"].mean(min_count: 8)                    # => UNDEF
south["visitors"].mean(min_count: 8, fill_value: -1.0)  # => -1.0
```

Both work on group summaries as well, which is where they are most useful.

### Conditions, sorting and grouping

- **`filter`** leaves out a row whose condition reads a missing value, since the condition is neither true nor false for it (chapter 6).
- **Sorting** puts rows with a missing key at the end, or at the start with `masked_position: :first`.
- **Grouping**: a row whose key is missing belongs to no group (chapter 10).
- **Joining**: a missing key matches nothing (chapter 12).

## Marking values as missing

### A code that means "no value" — `mask_eq`

If a column uses a code such as `-1` and you did not tell `from_csv` about it, `mask_eq` makes those cells missing:

```ruby
raw = CAFrame.from_csv("sales.csv")
raw["visitors"].min           # => -1
raw.mask_eq("visitors", -1)
raw["visitors"].min           # => 95
```

### Cells matching a condition

Assigning `UNDEF` to the cells a condition chooses marks them. Say revenue figures above 4000 are known to include a bulk order you want to leave out:

```ruby
df = sales.copy
df["revenue"][df["revenue"] > 4000] = UNDEF
df["revenue"].count_masked   # => 2
```

NaN is turned into missing the same way: `df["x"][df["x"].is_nan] = UNDEF`.

### Whole rows — `df[rows] = UNDEF`

A period when a shop's till was recording wrongly, say, can be marked in every column at once. Here the north shop's own frame, with the dates as its index (chapter 9):

```ruby
north = sales.filter { |f| f["shop"].eq("north") }.drop("shop").copy.set_index("date")
north[north.index >= "2024-03-10"] = UNDEF
p north.tail(3)
# #<CAFrame nrow=3 columns=[visitors:int64, revenue:float64, rating:float64] index="date">
# date        visitors  revenue  rating
# ----------  --------  -------  ------
# 2024-03-09       341   3974.7       _
# 2024-03-10         _        _       _
# 2024-03-11         _        _       _
```

The rows stay in the frame with their cells missing, and the index — which is not a column — keeps their dates, so you can still see which rows they were. This works because the dates are unique within one shop. In a frame whose index is not unique, or that has none, number the rows and make the numbers the index first, as chapter 6 shows.

In a frame without an index, `df[rows] = UNDEF` masks the identifying columns too. To mark only the figures, assign to those columns:

```ruby
df = sales.copy
faulty = df["shop"].eq("north") & (df["date"] >= "2024-03-10")
["visitors", "revenue", "rating"].each { |name| df[name][faulty] = UNDEF }
df["revenue"].count_masked   # => 3
```

## Filling gaps

### `fill`

`fill` fills a column's missing cells, changing the column:

| `fill(name, …)` | each missing cell gets |
|---|---|
| `:ffill` | the last value before it |
| `:bfill` | the next value after it |
| `:linear` | a value interpolated between its neighbours, against the index when there is one |
| a value | that value |

```ruby
s = CAFrame.new("v" => [1.0, nil, nil, 4.0, nil])
s.copy.fill("v", :ffill)["v"].to_a    # => [1.0, 1.0, 1.0, 4.0, 4.0]
s.copy.fill("v", :bfill)["v"].to_a    # => [1.0, 4.0, 4.0, 4.0, UNDEF]
s.copy.fill("v", :linear)["v"].to_a   # => [1.0, 2.0, 3.0, 4.0, UNDEF]
s.copy.fill("v", 0.0)["v"].to_a       # => [1.0, 0.0, 0.0, 4.0, 0.0]
```

A gap with no value on the side a method needs — the last cell under `:bfill` and `:linear` — stays missing.

Whether to fill, and how, is a decision about your data. A visitor count that was not recorded is not zero visitors; carrying the previous day's count forward may be a fair estimate for one day and a poor one for a week.

**Mind the order of the rows.** `sales` interleaves three shops, so filling it whole would carry one shop's figure into another shop's row. Fill within each shop instead, with the group's `fill`:

```ruby
df = sales.copy
df.group_by("shop").fill("visitors", :ffill)
df["visitors"][7]   # => 102
```

The south shop's missing count for 6 March took the south shop's 5 March figure, not the value in the row above it. Linear interpolation in time is shown in chapter 11.

### A filled copy of a column

`fill` changes the column, and so every frame that shares it. To keep the original and have a filled version beside it, make a new column with `strip_mask`, which returns a copy with the gaps filled:

```ruby
s["v_filled"] = s["v"].strip_mask(method: :linear)
s["v"].to_a          # => [1.0, UNDEF, UNDEF, 4.0, UNDEF]
s["v_filled"].to_a   # => [1.0, 2.0, 3.0, 4.0, UNDEF]
```

`strip_mask(value)` fills with a value, and `method: :forward` / `:backward` carry values as `:ffill` / `:bfill` do.

The frame has a `strip_mask` too, which returns a new frame with the gaps filled and leaves the original as it is. A Hash gives each column its own value, and `method:` takes a method or a Hash of them:

```ruby
s2 = CAFrame.new("v" => [1.0, nil, 3.0], "n" => [1, 2, 3])
s2.strip_mask(Float::NAN)["v"].to_a              # => [1.0, NaN, 3.0]
s2.strip_mask("v" => 0.0)["v"].to_a              # => [1.0, 0.0, 3.0]
s2.strip_mask(method: { "v" => :linear })["v"].to_a   # => [1.0, 2.0, 3.0]
s2["v"].to_a                                     # => [1.0, UNDEF, 3.0]
```

One value for the whole frame fills only the columns that have gaps, so `NaN` can fill the float column `v` while the complete integer column `n` is left alone.

### Filling the result of a summary

`fill_value:` on a summary fills its `UNDEF` results only, leaving the data alone (above).

## Removing rows with missing values

`drop_masked` keeps the rows that have a value in every column you name, or in every column when you name none:

```ruby
sales.drop_masked("visitors", "revenue").nrow   # => 22
sales.drop_masked.nrow                          # => 21
```

The result shares the frame's columns, as `filter` does. A `NaN` is a value, not a missing one, so its row stays; mark it as missing first (above) to drop it as well.

Before removing rows, consider whether you need to. Summaries already leave missing values out, and removing a row because one column is missing also removes the values its other columns had.

## Missing values on the way out

- **CSV**: a missing cell is written as an empty field, which `from_csv` reads back as missing. `missing: "NA"` writes a code instead (chapter 17).
- **Ruby values** (`to_records`, for JSON): a missing cell becomes `nil`, and `from_records` reads `nil` back as missing.
- **One row** (`df[i]`, `each_row`): a missing cell is `UNDEF`.
- **Arrays** (`to_a`, of a column or of the frame): a missing cell is `UNDEF`. Before handing rows to another library, fill the gaps with `strip_mask` or leave the rows out with `drop_masked`.

## In the CArray User's Guide

The CArray User's Guide covers masks on arrays of every shape in *Masks and missing values* ([05_masks.md](../users/05_masks.md)), and what each summary gives when nothing is left in *Reduction and statistics* ([04_reduction_and_statistics.md](../users/04_reduction_and_statistics.md)).
