# Choosing and ordering rows

Most questions about a table start by narrowing it down — the weekend days, one shop, the days above a target — or by putting it in order. This chapter covers both, and how to find and remove repeated rows.

```ruby
require "carray"
sales = CAFrame.from_csv("sales.csv", types: :infer, missing: ["-1", "n/a"])
```

## `filter` — rows where a condition holds

`filter` takes a block. The block receives the frame and returns a condition: a boolean array with one value per row, built from the columns. The rows where it is `true` make up the result.

```ruby
big_days = sales.filter { |f| f["revenue"] > 3500 }
big_days.nrow   # => 3
```

The result is a frame, so filters chain into everything else — another filter, a sort, a group summary:

```ruby
p sales.filter { |f| f["shop"].eq("north") }.filter { |f| f["visitors"] < 200 }
```

```
#<CAFrame nrow=4 columns=[date:CATime[D], shop:CAString, visitors:int64, revenue:float64, rating:float64]>
date        shop   visitors  revenue  rating
----------  -----  --------  -------  ------
2024-03-04  north       182  2121.39     4.2
2024-03-05  north       175   2235.1     4.3
2024-03-06  north       190  2285.32     4.1
2024-03-11  north       188  2261.26     4.3
```

### Building conditions

A condition is ordinary array arithmetic on columns. These are the pieces you will use most:

| condition | `true` where |
|---|---|
| `f["revenue"] > 3000`, `>=`, `<`, `<=` | the comparison holds |
| `f["shop"].eq("north")`, `.ne(...)` | the cell equals, or does not equal, the value |
| `f["shop"].is_in(["north", "south"])` | the cell is one of the values |
| `f["rating"].is_between(4.0, 4.5)` | the value lies in the interval (both ends included) |
| `f["shop"].start_with?("n")`, `.end_with?`, `.include?`, `.match?(/re/)` | a text cell matches |
| `f["visitors"].is_masked`, `.is_not_masked` | the cell is missing, or present |
| `f["revenue"].is_nan` | the cell holds NaN |
| `f["date"] >= "2024-03-09"` | a time comparison; a time column compares with date text, `Time` and `Date` |

Equality is written `eq`, not `==`. On arrays, `==` asks whether two arrays are equal as a whole, which is a different question.

Combine conditions with `&` (and), `|` (or) and `.not`. Put each comparison in parentheses, because `&` and `|` bind more tightly than comparisons do:

```ruby
sales.filter { |f| (f["visitors"] > 300) & (f["rating"] >= 3.7) }.nrow           # => 5
sales.filter { |f| f["shop"].eq("south") | (f["revenue"] > 3500) }.nrow          # => 11
sales.filter { |f| f["shop"].is_in(["north", "south"]).not }.nrow                # => 8
```

`is_between` also takes a Range, and `exclude:` leaves out one end or both:

```ruby
sales.filter { |f| f["rating"].is_between(4.0...4.5) }.nrow                    # => 9
sales.filter { |f| f["date"].is_between("2024-03-09", "2024-03-10") }.nrow     # => 6
```

A time column has accessors for the parts of a date — `year`, `month`, `day`, `weekday` (0 for Sunday to 6 for Saturday) and more — which make conditions such as "weekends only" short:

```ruby
weekend = sales.filter { |f| f["date"].weekday.is_in([0, 6]) }
weekend["date"].to_a.map(&:to_s).uniq   # => ["2024-03-09", "2024-03-10"]
```

### Conditions that use the whole column

Because a condition is computed from whole columns, it can use summaries of them — a mean, a percentile, a group's value:

```ruby
mean, sd = sales["revenue"].mean, sales["revenue"].stddev
unusual = sales.filter { |f| (f["revenue"] - mean).abs > 1.5 * sd }
unusual["revenue"].to_a   # => [1391.47, 3974.7, 3939.6, 4112.58]
```

Group-relative conditions — better than its own shop's average, say — use a group result laid out on the rows (chapter 10):

```ruby
shop_mean = sales.group_by("shop").mean("revenue", keep_rows: true)
sales.filter { |f| f["revenue"] > shop_mean }.nrow   # => 8
```

### Column names in conditions

Columns are written `f["revenue"]`, always with the String name. A column name may contain spaces, dots or anything else, and it never collides with a method name, so this one form works for every frame.

The block's `f` is the frame being filtered. For conditions that mix in arrays from elsewhere, refer to them by variable, as `shop_mean` above. They must have one value per row, in the frame's row order.

## Rows whose condition cannot be decided

A condition is undetermined for a row when a value it reads is missing. The north shop's rating for 9 March is missing, so `f["rating"] >= 4.3` is neither true nor false for that row. `filter` leaves such rows out, as it leaves out the rows where the condition is false:

```ruby
sales.filter { |f| f["rating"] >= 4.3 }.nrow   # => 11
```

Sometimes you want to keep those rows to look at later, because they might belong. `keep_masked: true` keeps them, with their cells marked missing:

```ruby
p sales.filter(keep_masked: true) { |f| f["shop"].eq("north") & (f["rating"] >= 4.3) }
```

```
#<CAFrame nrow=4 columns=[date:CATime[D], shop:CAString, visitors:int64, revenue:float64, rating:float64]>
date        shop   visitors  revenue  rating
----------  -----  --------  -------  ------
2024-03-05  north       175   2235.1     4.3
2024-03-07  north       204  2681.38     4.4
_           _             _        _       _
2024-03-11  north       188  2261.26     4.3
```

The third row is the undetermined one. Its cells are all missing here because the frame has no index; a frame with an index keeps the row's label, so you can still tell which row it was (chapter 9).

The frame `keep_masked: true` returns is a new frame, not a view of the original: it could not show a row as missing without making it missing in the original too.

To choose the undetermined rows on purpose, test the mask directly:

```ruby
sales.filter { |f| f["rating"].is_masked }["shop"].to_a   # => ["north"]
```

## Checking rows against rules — `verify`

When you have expectations about the data — counts are not negative, ratings run from 1 to 5 — `verify` checks every row against each of them and returns one column of verdicts per rule. Here the file is read without telling it about the `-1` code, as you might the first time:

```ruby
unchecked = CAFrame.from_csv("sales.csv", types: :infer, missing: ["n/a"])
report = unchecked.verify(
  "visitors not negative" => ->(f) { f["visitors"] >= 0 },
  "rating from 1 to 5"    => ->(f) { f["rating"].is_between(1, 5) },
  "revenue positive"      => ->(f) { f["revenue"] > 0 },
)
p report[6..9]
```

```
#<CAFrame nrow=4 columns=[visitors not negative:boolean, rating from 1 to 5:boolean, revenue positive:boolean]>
visitors not negative  rating from 1 to 5  revenue positive
---------------------  ------------------  ----------------
true                   true                true
false                  true                true
true                   true                true
true                   true                true
```

A rule is a name and a lambda. The lambda receives the frame, as a `filter` block does, and returns one boolean per row. In the report, `true` means the rule holds, `false` means the row breaks it, and a missing cell means the rule could not be checked because a value it reads is missing.

Count the verdicts, and use a rule's column to pick out the rows that break it:

```ruby
report["visitors not negative"].count(false)   # => 1
report["revenue positive"].count_masked        # => 1
p unchecked[report["visitors not negative"].eq(false)]
```

```
#<CAFrame nrow=1 columns=[date:CATime[D], shop:CAString, visitors:int64, revenue:float64, rating:float64]>
date        shop   visitors  revenue  rating
----------  -----  --------  -------  ------
2024-03-06  south        -1   1479.8     4.5
```

That is the `-1` the till wrote for a missing count. `count(false)` counts the rows that break a rule; `count_masked` the rows it could not judge.

This is a good step right after reading a file you will use more than once: write the rules down once and run them on every new delivery.

## Putting rows in order

### `sort_by_key` — by columns

`sort_by_key` sorts by one or more columns. The first decides; the next breaks ties; and so on:

```ruby
p sales.sort_by_key("revenue").head(3)
```

```
#<CAFrame nrow=3 columns=[date:CATime[D], shop:CAString, visitors:int64, revenue:float64, rating:float64]>
date        shop   visitors  revenue  rating
----------  -----  --------  -------  ------
2024-03-04  south        95  1391.47     4.6
2024-03-06  south         _   1479.8     4.5
2024-03-11  south       101   1525.1     4.7
```

`order: :desc` sorts every key from largest to smallest. To give each key its own direction, give `[name, :asc]` or `[name, :desc]` pairs:

```ruby
p sales.sort_by_key(["shop", :asc], ["revenue", :desc]).head(4)
```

```
#<CAFrame nrow=4 columns=[date:CATime[D], shop:CAString, visitors:int64, revenue:float64, rating:float64]>
date        shop     visitors  revenue  rating
----------  -------  --------  -------  ------
2024-03-09  central       402   3939.6     3.5
2024-03-10  central       355  3270.26     3.7
2024-03-06  central       305  3078.67     3.7
2024-03-07  central       322  3060.93     4.0
```

Text sorts in byte order, so `central` comes before `north` and `south`. Times sort in time order.

- **Missing values** go to the end, whichever the direction. `masked_position: :first` puts them at the start instead.
- **NaN** goes after the numbers, and before the missing values.
- Rows with equal keys keep their original order.
- A categorical column cannot be a key, because its codes are not in the order of its labels; sort by its labels with `sort_by { |f| f["k"].to_type(:object) }`.

### `sort_by` — by a value you compute

`sort_by` takes a block that returns the key, for orders that are not a plain column. Ascending:

```ruby
target = 3000.0
p sales.sort_by { |f| (f["revenue"] - target).abs }.head(3)
```

```
#<CAFrame nrow=3 columns=[date:CATime[D], shop:CAString, visitors:int64, revenue:float64, rating:float64]>
date        shop     visitors  revenue  rating
----------  -------  --------  -------  ------
2024-03-11  central       298  3008.01     3.9
2024-03-04  central       310   3038.0     3.8
2024-03-07  central       322  3060.93     4.0
```

The block can return an Array of keys, which then work as `sort_by_key`'s several keys do. For a key in descending order, use `order(descending: true)` on it, which works for any type of column:

```ruby
by_shop = sales.sort_by { |f| [f["shop"], f["visitors"].order(descending: true, method: :dense)] }
by_shop["visitors"][0..2].to_a   # => [402, 388, 355]
```

### The top rows

Sorting and then taking the first rows gives the largest or smallest few:

```ruby
top3 = sales.sort_by_key("revenue", order: :desc).head(3)
top3["shop"].to_a   # => ["north", "north", "central"]
```

A sorted frame shares its cells with the original, in the new order, as other row selections do.

## Repeated rows

`is_duplicate` marks the rows that repeat an earlier row. Its negation keeps one row of each. Here a file has been delivered twice, overlapping:

```ruby
twice = CAFrame.meld(sales.head(2), sales.head(3))
twice.nrow                           # => 5
twice.is_duplicate.to_a              # => [false, false, true, true, false]
twice[twice.is_duplicate.not].nrow   # => 3
```

With column names, only those columns are compared. One row per shop, the first:

```ruby
p sales[sales.is_duplicate("shop").not]
```

```
#<CAFrame nrow=3 columns=[date:CATime[D], shop:CAString, visitors:int64, revenue:float64, rating:float64]>
date        shop     visitors  revenue  rating
----------  -------  --------  -------  ------
2024-03-04  north         182  2121.39     4.2
2024-03-04  south          95  1391.47     4.6
2024-03-04  central       310   3038.0     3.8
```

| `except:` | the row left unmarked |
|---|---|
| `:first` (default) | the first of each set of repeats |
| `:last` | the last of each set |
| `:none` | none: every row whose values appear more than once is marked |

```ruby
latest = sales[sales.is_duplicate("shop", except: :last).not]
latest["date"].to_a.map(&:to_s)   # => ["2024-03-11", "2024-03-11", "2024-03-11"]
```

Values are compared as values: NaN equals NaN here. A row with a missing cell in the compared columns is never marked as a repeat.

## In the CArray User's Guide

For more on boolean arrays — `&`, `|`, `.not`, and how they treat missing cells — see *The boolean data type* in the CArray User's Guide ([27_boolean_arrays.md](../users/27_boolean_arrays.md)).
