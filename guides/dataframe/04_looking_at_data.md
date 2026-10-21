# Looking at your data

Before analysing a table, look at it: how big it is, what type each column was read as, how many cells are missing, and whether the values are in the range you expect. This chapter shows the ways of doing that.

```ruby
require "carray"
sales = CAFrame.from_csv("sales.csv", missing: ["-1", "n/a"])
```

## Printing a frame

`p` prints a summary line and the table, cut down to the first eight and last two rows so that it stays a screenful:

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

The summary line gives the number of rows and, for each column, its name and type. `CATime[D]` is a time column stored to the day.

`puts` prints the whole frame. Both are built on `to_table`, which you can call yourself with options:

```ruby
puts sales.to_table(rows: 4, precision: 1)
# date        shop     visitors  revenue  rating
# ----------  -------  --------  -------  ------
# 2024-03-04  north         182   2121.4     4.2
# 2024-03-04  south          95   1391.5     4.6
# :           :               :        :       :
# 2024-03-11  south         101   1525.1     4.7
# 2024-03-11  central       298   3008.0     3.9
# (24 rows, 5 columns)
```

| option | effect | default |
|---|---|---|
| `rows:` | the most rows to print; the middle is replaced by a `:` row and a footer gives the full size. `nil` prints every row | 20 |
| `precision:` | decimal places for floating-point cells, for display only | 6 |
| `index:` | `false` leaves out the index column | `true` |

In the table, numbers are aligned to the right and everything else to the left, and a missing cell is shown as `_`. `to_table` is for reading on the screen; to save a table, write it with `to_csv` (chapter 17).

## Checking every column — `describe`

`describe` gives one row per column, which keeps even a wide table readable:

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

| column | what it tells you |
|---|---|
| `type` | the type the column was read as; check this first |
| `count` | the cells that hold a value |
| `masked` | the missing cells |
| `unique` | the number of distinct values present |
| `min` `max` `mean` `stddev` | for numbers, booleans, times and durations; `_` where they do not apply |

**Read the `masked` column after every file you load.** A count you did not expect usually means a column was read with the wrong type — a decimal comma in a float column, a stray letter in an integer one — and its unreadable cells became missing. Re-read with `on_error: :warn` (chapter 3) to see which cells they were.

For a time column the mean is a time and the standard deviation a duration (`2D` is two days). A boolean column's mean is the share of `true` cells.

The result of `describe` is itself a frame, indexed by column name, so you can filter or print it like any other:

```ruby
d = sales.describe
p d.filter { |f| f["masked"] > 0 }.index.to_a
# ["visitors", "revenue", "rating"]
```

`describe("visitors", "revenue")` describes only the columns you name.

## Size, names and types

| method | returns |
|---|---|
| `nrow` | the number of rows |
| `ncol` | the number of columns |
| `column_names` | the column names, in order |
| `data_types` | a Hash of column name to type |
| `columns` | the columns themselves, in order |
| `index` | the index (chapter 9), or `nil` |
| `axis_name` | the name of the row axis |

```ruby
sales.nrow           # => 24
sales.ncol           # => 5
sales.column_names   # => ["date", "shop", "visitors", "revenue", "rating"]
sales.data_types
# => {"date" => CATime, "shop" => CAString, "visitors" => :int64, "revenue" => :float64, "rating" => :float64}
```

For an ordinary column `data_types` gives the data type, a Symbol. For a column of times, text or categories it gives the column's class.

`column_names` is a plain Ruby Array, so choosing columns by pattern or position is done with Array methods:

```ruby
sales.column_names.grep(/^r/)   # => ["revenue", "rating"]
sales.column_names[2..]         # => ["visitors", "revenue", "rating"]
```

## Looking at one column

A column is a CArray, so all of CArray's summaries work on it directly:

```ruby
sales["visitors"].min          # => 95
sales["visitors"].max          # => 402
sales["shop"].unique.to_a      # => ["north", "south", "central"]
sales["revenue"].count_masked  # => 1
```

`value_counts` gives each distinct value with the number of times it occurs, as two arrays:

```ruby
values, counts = sales["shop"].value_counts
values.to_a   # => ["north", "south", "central"]
counts.to_a   # => [8, 8, 8]
```

Eight days from each shop: the table has no missing rows.

The same summaries work on the frame, giving one row with a value for each column you name, or for every column that has the summary when you name none:

```ruby
p sales.max("visitors", "revenue")
# #<CAFrame nrow=1 columns=[visitors:int64, revenue:float64]>
# visitors  revenue
# --------  -------
#      402  4112.58
```

## Finding the rows with missing values

`is_masked` gives, for each cell of a column, `true` where it is missing. Used as a row selector it picks out those rows:

```ruby
p sales[sales["revenue"].is_masked]
# #<CAFrame nrow=1 columns=[date:CATime[D], shop:CAString, visitors:int64, revenue:float64, rating:float64]>
# date        shop     visitors  revenue  rating
# ----------  -------  --------  -------  ------
# 2024-03-08  central       388        _     3.6
```

To find the rows missing anything at all, combine the columns' tests with `|`:

```ruby
any_missing = sales.columns.map(&:is_masked).inject(:|)
p sales[any_missing]
# #<CAFrame nrow=3 columns=[date:CATime[D], shop:CAString, visitors:int64, revenue:float64, rating:float64]>
# date        shop     visitors  revenue  rating
# ----------  -------  --------  -------  ------
# 2024-03-06  south           _   1479.8     4.5
# 2024-03-08  central       388        _     3.6
# 2024-03-09  north         341   3974.7       _
```

Chapter 8 covers what to do about them.

## One row at a time

`sales[i]` gives one row as a Ruby Hash, and `each_row` goes through the rows that way:

```ruby
sales[7]
# => {"date" => #<CATime::Element 2024-03-06 (19788D)>, "shop" => "south", "visitors" => UNDEF, "revenue" => 1479.8, "rating" => 4.5}
```

A date comes back as a `CATime::Element`, a single time value, and a missing cell as `UNDEF`. Looking at single rows is handy for checking; for analysis, work on whole columns, which is both shorter to write and much faster.
