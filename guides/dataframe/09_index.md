# Row labels: the index

A frame can have an **index**: an array of labels, one per row — a date, a name, an identifier — kept beside the columns. You do not need one to work with a frame; everything in the earlier chapters works without. An index helps when rows are naturally known by a label: you can look a row up by its label, choose rows by a range of labels, and interpolate along it.

```ruby
require "carray"
sales = CAFrame.from_csv("sales.csv", missing: ["-1", "n/a"])
north = sales.filter { |f| f["shop"].eq("north") }.drop("shop").copy
```

## Making a column the index — `set_index`

`set_index` moves a column into the index. It changes the frame and returns it:

```ruby
north.set_index("date")
p north
# #<CAFrame nrow=8 columns=[visitors:int64, revenue:float64, rating:float64] index="date">
# date        visitors  revenue  rating
# ----------  --------  -------  ------
# 2024-03-04       182  2121.39     4.2
# 2024-03-05       175   2235.1     4.3
# 2024-03-06       190  2285.32     4.1
# 2024-03-07       204  2681.38     4.4
# 2024-03-08       268   3323.2     4.0
# 2024-03-09       341   3974.7       _
# 2024-03-10       322  4112.58     4.1
# 2024-03-11       188  2261.26     4.3
```

The index is printed first, under its name. It is no longer a column:

```ruby
north.column_names   # => ["visitors", "revenue", "rating"]
north.index.class    # => CATime
north.axis_name      # => "date"
```

The index's name is the frame's **axis name** — the name of its row axis. `set_index` takes it from the column it moved.

`reset_index` does the reverse: the index goes back to being the first column.

```ruby
north.reset_index.column_names   # => ["date", "visitors", "revenue", "rating"]
north.set_index("date")
```

A frame can also be built with an index (chapter 2):

```ruby
df = CAFrame.new({ "floor_m2" => [120, 85, 240] }, index: ["north", "south", "central"], axis_name: "shop")
df.index.to_a   # => ["north", "south", "central"]
```

## What the index is for

### Looking up a row by its label — `at`

`at(label)` gives the row with that label, as a Hash. It is the label counterpart of `df[i]`, which goes by position:

```ruby
north.at("2024-03-09")
# => {"date" => #<CATime::Element 2024-03-09 (19791D)>, "visitors" => 341, "revenue" => 3974.7, "rating" => UNDEF}
```

A time index takes the label as text, a `Time` or a `Date`. Other indexes take a value of their own kind: a number for a numeric index, a String for a text index.

`at` gives exactly one row, so it raises when there is none or more than one:

- a frame without an index: `ArgumentError`;
- a label not in the index: `KeyError`;
- a label that appears more than once: `ArgumentError`. Labels need not be unique, and `filter` gives every row with a label: `df.filter { |f| f.index.eq(label) }`.

### Choosing rows by their labels

Inside `filter`, `f.index` is the index, an array like any column, so conditions on labels are written like conditions on columns:

```ruby
weekend = north.filter { |f| f.index.is_between("2024-03-09", "2024-03-10") }
weekend["visitors"].to_a   # => [341, 322]
```

### Interpolating along it

`fill(name, :linear)` interpolates against the index when the frame has one. With a date index, a gap is filled in proportion to the time elapsed, so a series with uneven gaps between dates is handled correctly:

```ruby
t = north.copy
t["visitors"][3..4] = UNDEF
t.fill("visitors", :linear)
t["visitors"].to_a   # => [182, 175, 190, 240, 291, 341, 322, 188]
```

The column holds integers, so each interpolated value is rounded to the nearest integer: 240.33 becomes 240, and 290.67 becomes 291. Cast the column to `:float64` first to keep the fractions. Without an index, `:linear` interpolates by row position, which is the same only when the rows are equally spaced.

### Labelling summaries

A group summary uses the group key as its index (chapter 10), and `resample` uses the time bins (chapter 11). So the rows of a summary are labelled, and `at` finds them:

```ruby
means = sales.drop("date").group_by("shop").mean
means.at("south")["rating"].round(2)   # => 4.6
```

To use the labels as an ordinary column — for a `join`, or to write them as data — call `reset_index`.

## The index is not a column

The index sits beside the columns, and the methods that work on columns leave it alone:

- `north["date"]` raises `KeyError`: use `north.index`.
- `drop` does not remove it, and `select` does not need to name it.
- Arithmetic between columns ignores it. Columns of the same frame line up because they are the same rows, not because of their labels.

It goes everywhere the rows go: `filter`, `head`, sorting, `copy` and the other row selections carry each row's label with it. A row Hash includes it under the axis name, and `to_csv` writes it as the first column.

While a frame has an index, a column cannot have the index's name: `north.append("date", …)` raises, because `"date"` already names the row axis.

## Changing the index

`set_index` on a frame that already has one puts the old index back as a column first, so no labels are lost:

```ruby
df = sales.copy.set_index("shop")
df.set_index("date")
df.column_names   # => ["shop", "visitors", "revenue", "rating"]
```

`reset_index` restores the axis name the frame had before `set_index`.

## Indexes that repeat

An index may hold the same label more than once — `sales` indexed by `shop` has eight rows for each. Everything works except `at`, which needs one row per label:

```ruby
by_shop = sales.copy.set_index("shop")
by_shop.at("north")   # raises ArgumentError
by_shop.filter { |f| f.index.eq("north") }.nrow   # => 8
```

## Rows without a label

A row whose label is missing — an unmatched row from an outer join (chapter 12), say — cannot be found with `at`. Find such rows by their mask:

```ruby norun
df.filter { |f| f.index.is_masked }
```

## When to use an index

Use one when the rows have a natural label you will look up or slice by, or that should stay with the rows through every operation — dates in a time series, identifiers of records. Leave it out when no column plays that part; nothing in CAFrame requires one.

One more reason to have a **unique** index: `filter(keep_masked: true)` and `df[rows] = UNDEF` make every cell of a row missing, and the index is then the only thing left that says which row it was. When no column is unique, an index of row numbers does the job (chapter 6).
