# Getting columns and rows

`df[...]` is the way into a frame. What you put in the brackets decides what you get back: a String gives a column, anything else gives rows.

| `df[key]` with… | gives |
|---|---|
| a column name | that column, a CArray |
| several column names | an Array of those columns |
| an Integer | one row, as a Ruby Hash |
| a Range of Integers | those rows, as a frame |
| a boolean CArray | the rows where it is `true`, as a frame |
| an integer CArray | the rows at those positions, in that order, as a frame |

```ruby
require "carray"
sales = CAFrame.from_csv("sales.csv", types: :infer, missing: ["-1", "n/a"])
```

## Columns

### One column

A column name gives the column:

```ruby
revenue = sales["revenue"]
revenue.class          # => CArray
revenue.mean.round(2)  # => 2626.11
```

What you get is the column the frame holds, not a copy. It has every CArray method, and writing to it writes to the frame:

```ruby
revenue[0] = 2200.0
sales["revenue"][0]   # => 2200.0
revenue[0] = 2121.39
```

A name the frame does not have raises `KeyError` naming it (`no column "nope"`). `column_names` lists the names the frame has.

### Several columns

Several names give an Array of columns, which suits parallel assignment:

```ruby
visitors, revenue = sales["visitors", "revenue"]
per_visitor = revenue / visitors
per_visitor[0].round(2)   # => 11.66
```

### A frame of some columns — `select`

`df[...]` with names always gives arrays. When you want a frame of some of the columns, use `select`. It also puts the columns in the order you name them:

```ruby
p sales.select("shop", "revenue").head(3)
# #<CAFrame nrow=3 columns=[shop:CAString, revenue:float64]>
# shop     revenue
# -------  -------
# north    2121.39
# south    1391.47
# central   3038.0
```

`select` with one name still gives a frame. The frame `select` returns holds the same column arrays as `sales`, so writing through it reaches `sales` (chapter 16).

To leave out a few columns instead of naming the ones to keep, use `drop`:

```ruby
sales.drop("date", "rating").column_names   # => ["shop", "visitors", "revenue"]
```

## Rows

### One row

An Integer gives one row as a Ruby Hash. A negative number counts from the end:

```ruby
sales[0]
# => {"date" => #<CATime::Element 2024-03-04 (19786D)>, "shop" => "north", "visitors" => 182, "revenue" => 2121.39, "rating" => 4.2}
sales[-1]["shop"]   # => "central"
```

A missing cell is `UNDEF` in the Hash. Test for it with `== UNDEF`, not with `nil?`: `UNDEF` is not `nil`.

```ruby
row = sales[7]
row["visitors"] == UNDEF   # => true
row["visitors"].nil?       # => false
```

### A range of rows

A Range gives the rows at those positions, as a frame:

```ruby
p sales[3..5]
# #<CAFrame nrow=3 columns=[date:CATime[D], shop:CAString, visitors:int64, revenue:float64, rating:float64]>
# date        shop     visitors  revenue  rating
# ----------  -------  --------  -------  ------
# 2024-03-05  north         175   2235.1     4.3
# 2024-03-05  south         102  1632.61     4.7
# 2024-03-05  central       295  2717.54     3.9
```

Ranges are positions, counted from 0. To choose rows by their label — a date, a name — use `filter` (chapter 6) or `at` (chapter 9).

`head(n)` and `tail(n)` give the first and last `n` rows; `n` is 5 when left out.

### Rows chosen by a condition

A boolean CArray with one value per row picks the rows where it is `true`:

```ruby
top_rated = sales[sales["rating"] >= 4.6]
top_rated["shop"].to_a   # => ["south", "south", "south", "south", "south"]
```

This is what `filter` does with a block (chapter 6); the block form is usually easier to read, because the condition can use the frame's columns by name.

A cell of the condition that is missing chooses no row. The north shop's rating for 9 March is missing, so whether it was 4.6 or more is unknown, and that row is not among the top-rated ones.

### Rows at given positions

An integer CArray gives the rows at those positions, in that order. Positions can repeat:

```ruby
pick = sales[CA_INT64([2, 0, 0])]
pick["shop"].to_a   # => ["central", "north", "north"]
```

This is how you apply an order or a sample that you have worked out yourself.

### Rows as frames share their cells

Every way of getting rows as a frame — a range, a condition, positions, `head`, `tail` — gives a frame whose columns look into the original's. Writing a cell through it writes the original:

```ruby
first = sales.head(1)
first["visitors"][0] = 0
sales["visitors"][0]   # => 0
first["visitors"][0] = 182
```

That is useful for correcting values in part of a table. When you want an independent table, `copy` it (chapter 16).

## One row at a time

`each_row` gives each row as a Hash, as `df[i]` does:

```ruby
sales.head(3).each_row { |r| puts "#{r["shop"]}: #{r["visitors"]} visitors" }
# north: 182 visitors
# south: 95 visitors
# central: 310 visitors
```

Without a block it returns an Enumerator, so `each_row.map`, `each_row.select` and the like work. Row by row is the slow way to work on a frame; whenever a computation can be written with whole columns, write it that way.
