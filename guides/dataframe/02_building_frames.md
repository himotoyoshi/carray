# Building a frame

Data reaches a frame in one of four shapes, and there is one way in for each:

| your data is… | build the frame with |
|---|---|
| arrays you already have, one per column | `CAFrame.new` |
| one array whose columns lie along an axis | `CArray#to_frame` |
| an Array of Hashes, as parsed JSON gives | `CAFrame.from_records` |
| a CSV file | `CAFrame.from_csv` (chapter 3) |

## From arrays — `CAFrame.new`

Pass a Hash of column name to column. Every column must have the same length; that length is the number of rows.

```ruby
require "carray"

df = CAFrame.new(
  "shop"     => ["north", "south", "central"],
  "revenue"  => CA_FLOAT64([2121.39, 1391.47, 3038.0]),
  "visitors" => [182, 95, nil],
)
p df
```

```
#<CAFrame nrow=3 columns=[shop:object, revenue:float64, visitors:int64]>
shop     revenue  visitors
-------  -------  --------
north    2121.39       182
south    1391.47        95
central   3038.0         _
```

A column may be given as a CArray or as a Ruby Array.

- **A CArray is used as it is**, without being copied. The frame holds your array, so writing to the array changes the frame and the other way around (chapter 16).
- **A Ruby Array is turned into a column by its values**: whole numbers give an `int64` column, any decimal among them a `float64` column, strings or a mix of kinds an `object` column. An Array of equal-length Arrays gives a column with more than one value per row (chapter 14).
- **`nil` or `UNDEF` in an Array is a missing cell.** The `visitors` column above is `int64` with its last cell missing.

```ruby
df.data_types   # => {"shop" => :object, "revenue" => :float64, "visitors" => :int64}
```

### Column names are Strings

Every column name is a String, here and in every method that names a column. A Symbol is refused rather than quietly becoming a column:

```ruby
CAFrame.new(revenue: CA_FLOAT64([1.0, 2.0]))   # raises TypeError: CAFrame.new: a column name is a String
```

Symbols are kept for options. `CAFrame.new` takes three, and when you give them the columns go in braces:

| option | what it sets |
|---|---|
| `index:` | an array of row labels (chapter 9) |
| `axis_name:` | the name of the row axis, which is also the name the index goes by |
| `attrs:` | a Hash of attributes describing the table (below) |

```ruby
df = CAFrame.new({ "revenue" => CA_FLOAT64([2121.39, 1391.47, 3038.0]) },
                 index: ["north", "south", "central"], axis_name: "shop")
p df
```

```
#<CAFrame nrow=3 columns=[revenue:float64] index="shop">
shop     revenue
-------  -------
north    2121.39
south    1391.47
central   3038.0
```

### Lengths must agree

Columns of different lengths are refused when the frame is built, with the column that disagrees named:

```ruby
CAFrame.new("a" => [1, 2], "b" => [1, 2, 3])   # raises ArgumentError: column "b" has axis-0 length 3, expected 2
```

There is no stretching of a single value into a column. To make a column of one repeated value, make it the right length yourself:

```ruby
flags = CArray.int8(3) { 0 }
flags.to_a   # => [0, 0, 0]
```

## From one array — `to_frame`

When the table is already an array — a matrix of measurements, say, with one column per variable — `to_frame` shows it as a frame. Rows run along the first axis, and each position along the last axis becomes a column:

```ruby
m = CA_FLOAT64([[1.62, 58.0, 41],
                [1.75, 71.5, 35],
                [1.68, 63.2, 29]])
df = m.to_frame("height", "weight", "age")
p df
```

```
#<CAFrame nrow=3 columns=[height:float64, weight:float64, age:float64]>
height  weight   age
------  ------  ----
  1.62    58.0  41.0
  1.75    71.5  35.0
  1.68    63.2  29.0
```

Nothing is copied. Each column is a view of the matrix — a way of looking at part of it — so the frame and the matrix are the same data seen two ways:

```ruby
df["age"][1] = 36
m[1, 2]          # => 36.0
```

Without names the columns are called `c0`, `c1`, …. With `axis:` the columns are taken along another axis; a three-dimensional array gives columns with more than one value per row (chapter 14).

## From records — `from_records`

Data from a web service or a JSON file usually arrives as an Array of objects, one per row. `from_records` builds a frame from that shape:

```ruby
require "json"

json = <<~JSON
  [{"shop": "north",   "revenue": 2121.39, "visitors": 182},
   {"shop": "south",   "revenue": 1391.47},
   {"shop": "central", "revenue": 3038.0, "visitors": 310, "note": "promotion"}]
JSON
df = CAFrame.from_records(JSON.parse(json))
p df
```

```
#<CAFrame nrow=3 columns=[shop:object, revenue:float64, visitors:int64, note:object]>
shop     revenue  visitors  note
-------  -------  --------  ---------
north    2121.39       182  _
south    1391.47         _  _
central   3038.0       310  promotion
```

- The columns are every key that appears in any record, in the order they first appear.
- A key missing from a record, or a `null`, is a missing cell. The south shop has no `visitors`, and two shops have no `note`.
- Each column's type comes from its values, which JSON has already typed: all integers give `int64`, integers and decimals `float64`. Anything else — strings, booleans, a mix — gives an `object` column holding the values as they are.
- Strings are not parsed. A date written as a string stays a string until you convert it (chapter 7).

`types:` converts named columns as they are built:

```ruby
df = CAFrame.from_records(JSON.parse(json), types: { "visitors" => :int32 })
df.data_types   # => {"shop" => :object, "revenue" => :float64, "visitors" => :int32, "note" => :object}
```

Symbol keys work as well as String keys; they become String column names.

## From a CSV file — `from_csv`

```ruby
sales = CAFrame.from_csv("sales.csv", types: :infer, missing: ["-1", "n/a"])
sales.nrow   # => 24
```

Reading CSV has enough to it to need its own chapter: the next one.

## Starting empty and adding columns

A frame with no columns takes its number of rows from the first column you add:

```ruby
df = CAFrame.new({})
df["x"] = CArray.float64(4).seq!
df["y"] = df["x"] * 2
df.nrow   # => 4
```

## Describing the table — attributes

A frame can carry a few facts about the table as a whole — a title, where the data came from — as attributes. They are kept with the frame and do not take part in any computation.

```ruby
sales = CAFrame.from_csv("sales.csv", types: :infer, missing: ["-1", "n/a"])
sales.set_attr(:title, "daily figures by shop")
sales.set_attr(:source, "sales.csv")
sales.attr(:title)    # => "daily figures by shop"
sales.attrs           # => {"title" => "daily figures by shop", "source" => "sales.csv"}
```

Keys may be Symbols or Strings and are stored as Strings. A value must be something JSON can hold: a number, a String, `true` / `false` / `nil`, or an Array or Hash of those.

A column has attributes of its own, as any CArray does — units and currencies are common ones:

```ruby
sales["revenue"].set_attr(:currency, "USD")
sales["revenue"].attr(:currency)   # => "USD"
```

A frame made by choosing rows or columns of this one — `filter`, `head`, `select`, `drop`, `rename`, `copy` and the like — takes its attributes with it, since it is still the same table. A frame computed from it — a group summary, a join, a pivot — starts with none.

```ruby
sales.head(3).attr(:title)                   # => "daily figures by shop"
sales.group_by("shop").mean.attr(:title)     # => nil
```
