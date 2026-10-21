# Preparing columns

Between reading a table and analysing it there is usually some preparation: add the columns you will need, remove or rename others, fix types that were read wrongly, tidy text, and correct or remove a few rows. This chapter covers those steps. Missing values have a chapter of their own (chapter 8), and so do time columns (chapter 11).

```ruby
require "carray"
sales = CAFrame.from_csv("sales.csv", missing: ["-1", "n/a"])
```

## Does it change the frame, or return a new one?

The methods that change a frame's columns fall into two groups, and which group a method is in decides how you call it:

- **A different set of columns** — `append`, `drop`, `rename`, `split_column`, `contrast_columns` — gives a **new frame**. The frame you called it on is unchanged, so keep the result: `df = df.append(...)`.
- **The same columns, edited** — `cast`, `promote`, `fill`, `mask_eq`, `set_index` — changes the frame itself and returns it, so calls can be chained.

```ruby
df = sales.copy
df.append("per_visitor", df["revenue"] / df["visitors"]).ncol   # => 6
df.ncol                                                         # => 5
df.cast("visitors", :float64)
df["visitors"].data_type                                        # => :float64
```

`append` left `df` with its five columns; `cast` changed `df` itself.

`df["name"] = column` also changes the frame itself; it is the quickest way to add a column to a frame you are working on.

## Adding columns

### `df[name] =`

Assign a column of the right length:

```ruby
sales["per_visitor"] = sales["revenue"] / sales["visitors"]
sales["per_visitor"][0].round(2)   # => 11.66
```

A new name adds a column at the end; an existing name replaces that column. The right-hand side must be a CArray or a Ruby Array with one value per row. A single value raises an error:

```ruby
sales["promotion"] = 0   # raises ArgumentError: column must be a CArray or Array (got Integer)
```

To fill a column with one value, make the column:

```ruby
sales["promotion"] = CArray.int8(sales.nrow) { 0 }
```

### Columns computed from other columns

Anything you can compute with arrays can become a column. Missing cells carry through: a computation with a missing input gives a missing output. The south shop's visitor count for 6 March is missing, so its revenue per visitor is missing too:

```ruby
sales["per_visitor"][7]   # => UNDEF
```

A column chosen cell by cell from two values, by a condition, uses `then_else`:

```ruby
sales["traffic"] = (sales["visitors"] >= 300).then_else("busy", "normal")
sales["traffic"].to_a.tally   # => {"normal" => 15, "busy" => 8, UNDEF => 1}
```

Where the condition cannot be decided, the result is missing too.

### `append` — a new frame with one more column

`append` returns a new frame with the column added. With `before:` or `after:` it goes next to the column you name:

```ruby
df = sales.append("id", CArray.int32(sales.nrow).seq!, before: "date")
df.column_names.first(3)   # => ["id", "date", "shop"]
```

## Removing and renaming columns

```ruby
sales = sales.drop("per_visitor", "promotion", "traffic")
sales.column_names   # => ["date", "shop", "visitors", "revenue", "rating"]

renamed = sales.rename("visitors" => "customers", "revenue" => "takings")
renamed.column_names   # => ["date", "shop", "customers", "takings", "rating"]
```

`drop` and `rename` return new frames that hold the same columns; the data is not copied. `df["name"] = nil` removes a column from the frame itself.

## Changing a column's type

### `cast`

`cast` converts columns to the types you name:

```ruby
df = sales.copy
df.cast("visitors", :float64)                         # one column
df.cast("revenue" => :float32, "rating" => :float32)  # several
df.cast(["revenue", "rating"] => :float64)            # one type for several
df.data_types
# => {"date" => CATime, "shop" => CAString, "visitors" => :float64, "revenue" => :float64, "rating" => :float64}
```

`cast` reads text as numbers, so it is also how you convert a text column you read with `types: :text`:

```ruby
raw = CAFrame.from_csv("sales.csv", types: :text)
raw.cast("revenue" => :float64, "visitors" => :int32)
raw["visitors"].to_a.first(8)   # => [182, 95, 310, 175, 102, 295, 190, -1]
```

Numbers in text are read as decimal numbers, with an optional sign, point and exponent; surrounding spaces are ignored. An integer type takes a value that is exactly a whole number (`"1.0"`, `"1e3"`) but not `"1.5"`. A cell that cannot be read, or whose value the type cannot hold, becomes missing — or, with `on_error: :warn` or `:raise`, tells you so (chapter 3).

```ruby
raw = CAFrame.from_csv("sales.csv", types: :text)
raw.cast("rating" => :float64, on_error: :raise)   # raises CAFrame::UnreadableColumn: column "rating", row 15 "n/a" cannot be read as float64
```

`cast(:infer)` converts the text columns to the types `infer_types` finds, as `from_csv` does when reading.

A converted column replaces the old one in this frame. A frame that shared the old column — one you made earlier with `select`, say — keeps the old one.

### Categorical columns

A column of a few values repeated many times — shops, product types, payment methods — can be made **categorical**: each distinct value is stored once, and every cell holds a small code that refers to it. It takes less memory, and group summaries by it are fast:

```ruby
df = sales.copy.cast("shop" => :categorical)
df["shop"].class          # => CACategorical
df["shop"].labels         # => ["north", "south", "central"]
df["shop"][0]             # => "north"
```

The labels are in the order they first appear. A categorical column reads like a text column, but its cells cannot be written; to change its values, build a new column.

### One type for the whole frame — `promote`

`promote` converts every column to one common type, for example before making the frame into one matrix (chapter 15):

```ruby
nums = sales.select("visitors", "revenue", "rating").copy.promote
nums.data_types   # => {"visitors" => :float64, "revenue" => :float64, "rating" => :float64}
```

With a type, `promote(:float64)`, it converts to that type, but only if no column would lose information by it; for a conversion that may lose information, use `cast`.

## Text columns

A text column — read from a CSV, or given as a Ruby Array of strings — is a `CAString`: an array of strings with the `String` methods applied to every cell. The `!` forms change the column in place, and so the frame:

```ruby
df = CAFrame.new("code" => CArray.string([" A-12", "B-7 ", "a-3"]))
df["code"].strip!
df["code"].upcase!
df["code"].to_a   # => ["A-12", "B-7", "A-3"]
```

`CArray.string` makes a text column from Ruby strings; a plain Ruby Array of strings given for a column becomes one too. An `object` column — an array of Ruby objects, such as the result of `then_else` with two strings — has no string methods of its own; when its values are strings, `df["code"] = CArray.string(df["code"])` turns it into a text column.

The non-`!` forms (`strip`, `upcase`, `sub`, `gsub`, …) return a new column. Predicates — `start_with?`, `include?`, `match?` — return boolean columns for conditions (chapter 6), and `str_len` gives each cell's length.

### Taking part of a text — `extract`

`extract(regexp, replacement)` replaces each cell's match, as `String#sub` does. A cell the pattern does not match becomes missing, so it stays missing through a later `cast` rather than turning into a number:

```ruby
df["num"] = df["code"].extract(/-(\d+)/, '\1')
df.cast("num", :int32)
df["num"].to_a   # => [12, 7, 3]
```

### Splitting a column — `split_column`

`split_column` splits each cell at a separator into several new columns, which take the old column's place:

```ruby
df = CAFrame.new("code" => ["A-12", "B-7", "C"])
parts = df.split_column("code", "-", into: ["kind", "num"])
p parts
# #<CAFrame nrow=3 columns=[kind:CAString, num:CAString]>
# kind  num
# ----  ---
# A     12
# B     7
# C     _
```

A cell with too few pieces leaves the remaining columns missing; with too many, the rest stays in the last column. The new columns are text; `cast` the numeric ones.

## Columns for a statistical model — `contrast_columns`

A model that takes numbers cannot take a column of categories directly. `contrast_columns` replaces such a column by one 0/1 column per category, leaving out the first, which serves as the baseline:

```ruby
orders = CAFrame.new("payment" => ["card", "cash", "online", "cash"], "amount" => [31.5, 12.0, 54.2, 8.4])
p orders.contrast_columns("payment")
# #<CAFrame nrow=4 columns=[payment_cash:int8, payment_online:int8, amount:float64]>
# payment_cash  payment_online  amount
# ------------  --------------  ------
#            0               0    31.5
#            1               0    12.0
#            0               1    54.2
#            1               0     8.4
```

The categories are taken in sorted order unless the column is already categorical, so `card` is the baseline here. `base:` names another baseline, and `full: true` keeps a column for every category.

## Editing rows

### Correcting values

Write corrected values into a column at the rows you choose, with the ordinary array assignment. Suppose the north shop's revenue for 5 March was entered twice by mistake, and is really half the recorded figure:

```ruby
wrong = sales["shop"].eq("north") & sales["date"].eq("2024-03-05")
sales["revenue"][wrong] = sales["revenue"][wrong] / 2
sales["revenue"][3]   # => 1117.55
```

### Deleting rows — `df[rows] = nil`

Assigning `nil` to rows removes them from the frame:

```ruby
df = sales.copy
df[df["shop"].eq("south")] = nil
df.nrow   # => 16
```

To get a frame without some rows while keeping the original whole, choose the others instead: `sales.filter { |f| f["shop"].ne("south") }`.

### Replacing a span of rows — `df[span] = other`

Assigning a frame to a span of rows replaces those rows with its rows, which may be more or fewer. The two frames must have the same columns. Here the first day's figures are replaced by a corrected delivery, and the same rows are then appended at the end:

```ruby
df = sales.copy
fix = df[0..2].copy
fix["revenue"] = [2150.0, 1400.0, 3050.0]
df[0..2] = fix
df["revenue"][0..2].to_a   # => [2150.0, 1400.0, 3050.0]
df[24...24] = fix          # an empty span at the end appends the rows
df.nrow                    # => 27
```

Marking whole rows as missing, `df[rows] = UNDEF`, is in chapter 8.
