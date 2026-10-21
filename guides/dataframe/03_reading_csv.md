# Reading CSV files

CSV files come in many layouts, and few of them are tidy. This chapter goes through what you can tell `CAFrame.from_csv` about a file: the types of its columns, how it writes missing values, where its header and data are, which columns you need, and what encoding it is in.

Writing CSV is in chapter 17.

## Where the text comes from

`from_csv` takes a path, or anything that reads like an open file:

```ruby
require "carray"
require "stringio"

sales = CAFrame.from_csv("sales.csv")              # a path

text = "shop,revenue\nnorth,2121.39\nsouth,1391.47\n"
df = CAFrame.from_csv(StringIO.new(text))          # text you already have
df.nrow   # => 2

File.open("sales.csv") { |io| CAFrame.from_csv(io) }.nrow   # => 24
```

A String is always taken as a path, never as CSV text. To read text you have in memory — the body of a web response, say — wrap it in a `StringIO`. An IO you pass is read from where it is and left open; closing it is up to you.

The examples in this chapter use small texts in `StringIO`, so you can see the whole file next to the code that reads it.

## Column types

### Types worked out from the text

The first line gives the column names. Each column is given the type that every one of its present cells can be read as:

```ruby
sales = CAFrame.from_csv("sales.csv")
sales.data_types
# => {"date" => CATime, "shop" => CAString, "visitors" => :int64, "revenue" => :float64, "rating" => CAString}
```

A column gets a type only when every one of its present cells fits that type:

- **Integers** become `:int64` when every cell is a whole number that fits.
- **Numbers** become `:float64` when every cell is a number.
- **`true` / `false`** in any case become `:boolean`. A column of only `0` and `1` is read as integers, since it could equally be counts; say `:boolean` if it is a yes/no column.
- **Times** become `:time` when every cell is a date or time written year first: `2024-03-04`, `2024/3/4 9:30`, `2024-03-04T12:00:00Z`.
- **Everything else stays text**, as a `CAString` — an array of strings. In particular:
  - a number with a leading zero (`007`), which is usually a code;
  - an integer too long for `int64`, which is usually an identifier;
  - a date written day-first or month-first (`04/03/2024`), since which one it is cannot be told from the text.

One unreadable cell keeps a whole column as text. That is what happened to `rating` above: the `n/a` in it is not a number. Telling `from_csv` how the file writes missing values (next section) usually settles it.

### Everything as text — `types: :string`

`types: :string` reads every column as text. Nothing is converted, so nothing is lost or misread; you can convert columns yourself afterwards (chapter 7):

```ruby
df = CAFrame.from_csv("sales.csv", types: :string)
df["revenue"].class   # => CAString
df["revenue"][0]      # => "2121.39"
```

### Naming the types — `types:`

Give a Hash of column name to type. The columns it names take those types, and the others are worked out as above:

```ruby
text = <<~CSV
  item,price,stock
  coffee,3.20,40
  tea,,25
  cake,4.50,x
CSV
df = CAFrame.from_csv(StringIO.new(text), types: { "price" => :float64, "stock" => :int32 })
p df
# #<CAFrame nrow=3 columns=[item:CAString, price:float64, stock:int32]>
# item    price  stock
# ------  -----  -----
# coffee    3.2     40
# tea         _     25
# cake      4.5      _
```

- An **empty cell** is missing, in every column.
- A cell that **cannot be read as the type** — `x` as an integer — is missing too. How to be told about such cells instead is below.
- The integer column keeps its type with a missing cell in it.

The types are the CArray data types: `:int8` … `:int64`, `:uint8` … `:uint64`, `:float32`, `:float64`, `:cmplx128`, `:boolean`, `:object`; and three that make a special kind of column:

| type | gives |
|---|---|
| `:time` | a time column (`CATime`) from dates and times written year first |
| `:categorical` | a categorical column: each distinct value stored once, cells holding small codes |
| `:boolean` | `true` / `false` in any case, and `1` / `0` |

Several columns can share a type by giving an Array of names as the key:

```ruby
df = CAFrame.from_csv("sales.csv", types: { ["revenue", "rating"] => :float64 })
df.data_types["revenue"]   # => :float64
```

Numbers are read as decimal numbers: `"010"` is ten, and `"0x1F"` or `"1_000"` are not numbers. A value that does not fit the type — `"300"` as `:int8` — is unreadable, not wrapped around.

### Exceptions to the worked-out types

In the Hash, `:string` (or `nil`) keeps a named column as text, and `default:` sets the type of every column the Hash does not name — a type, or `:string` to keep them all text:

```ruby
text = <<~CSV
  sku,item,stock,price
  0012,coffee,40,3.20
  0013,tea,25,2.80
CSV
df = CAFrame.from_csv(StringIO.new(text),
                      types: { "stock" => :int16, "item" => :categorical })
df.data_types
# => {"sku" => CAString, "item" => CACategorical, "stock" => :int16, "price" => :float64}
```

`sku` stayed text without being named: its leading zeros mark it as a code. To keep a column that does read as numbers as text — a postal code, say — name it with `nil`.

### Looking before converting — `infer_types`

When you would rather see the decision before it is made, read the file as text and ask:

```ruby
raw = CAFrame.from_csv("sales.csv", types: :string)
raw.infer_types
# => {"date" => :time, "visitors" => :int64, "revenue" => :float64}
```

The result is a Hash `cast` takes directly, so you can adjust it and apply it — or copy it into your program, so the types no longer depend on what this particular file happened to contain:

```ruby
raw = raw.cast(raw.infer_types.merge("visitors" => :int32))
raw.data_types["visitors"]   # => :int32
```

A column missing from the Hash, like `rating` here, could not be read as one type.

## Missing values

### How the file writes "no value" — `missing:`

An empty field is always missing. Many files also use a code for it: `-1`, `NA`, `n/a`, `-999`. List them with `missing:`, and those fields are read as missing **before** the columns are typed, so the code never reaches a column as a number:

```ruby
sales = CAFrame.from_csv("sales.csv", missing: ["-1", "n/a"])
sales["visitors"].count_masked   # => 1
sales["rating"].data_type        # => :float64
```

Tokens are compared with the text of the field as written. `"-1"` does not match `-1.0`; list both if the file uses both. A token must be a String; a number such as `missing: -1` raises an error.

When the codes differ by column, give a Hash. `default:` gives the tokens for every column, and a column name gives that column's own, replacing the default:

```ruby
text = <<~CSV
  account,balance,score
  -1,250.0,-
  7,-1,82
CSV
df = CAFrame.from_csv(StringIO.new(text),
                      missing: { default: "-1", "score" => ["-1", "-"], "account" => [] })
df["account"].to_a   # => [-1, 7]
df["balance"].to_a   # => [250.0, UNDEF]
df["score"].to_a     # => [UNDEF, 82]
```

In the `account` column, `-1` is a real account number, so `"account" => []` gives it no tokens.

### Cells that cannot be read — `on_error:`

A cell that cannot be read as its column's type becomes missing. That keeps reading going, but it can hide a problem in the file. `on_error:` chooses what happens:

| `on_error:` | an unreadable cell |
|---|---|
| `:mask` (default) | becomes missing |
| `:warn` | becomes missing, and a warning names the column, the count and the first few cells |
| `:raise` | stops the read with `CAFrame::UnreadableColumn`, naming the column, the row and the text |

```ruby
text = "item,stock\ncoffee,40\ntea,2O\n"
CAFrame.from_csv(StringIO.new(text), types: { "stock" => :int32 }, on_error: :raise)   # raises CAFrame::UnreadableColumn: column "stock", row 1 "2O" cannot be read as int32
```

Here a letter O was typed for a zero. Empty cells and the `missing:` tokens are missing values, not errors, whatever `on_error:` says.

A good habit for a file you do not know: read it with `on_error: :warn` the first time, or look at the `masked` column of `describe` (chapter 4).

## Where the header and the data are

### Title lines, unit lines, no header

Lines are counted from 0, as in `File.readlines(path)[i]`.

| the file has… | read it with |
|---|---|
| the names on the first line, data after (the usual case) | nothing extra |
| two title lines above the names | `header: 2` |
| the names, then two lines of units or notes | `header: 0, data: 3` |
| no names | `column_names: [...]`, or `header: false` for `c0`, `c1`, … |
| names you want to replace | `header: 0, column_names: [...]` |

```ruby
text = <<~CSV
  Monthly price list
  item,price
  -,USD
  coffee,3.20
  tea,2.80
CSV
df = CAFrame.from_csv(StringIO.new(text), header: 1, data: 3, types: { "price" => :float64 })
df["price"].to_a   # => [3.2, 2.8]
```

A line of units right below the names can be kept as **column attributes** instead of skipped. `attrs: [:units]` reads the line after the header as each column's `units`:

```ruby
text = <<~CSV
  item,price
  -,USD
  coffee,3.20
CSV
df = CAFrame.from_csv(StringIO.new(text), attrs: [:units], types: { "price" => :float64 })
df["price"].attr(:units)   # => "USD"
```

### Part of the rows

`data:` can be a Range of lines, to read part of a large file — the first few lines while you work out its layout, for example:

```ruby
CAFrame.from_csv("sales.csv", data: 1..6).nrow   # => 6
```

### Part of the columns — `columns:`

`columns:` reads only the columns you name, in the order you give. The others are passed over without being turned into strings, so a few columns of a wide file take little more time and memory than a narrow file would:

```ruby
df = CAFrame.from_csv("sales.csv", columns: ["shop", "revenue"], types: { "revenue" => :float64 })
df.column_names   # => ["shop", "revenue"]
```

Columns can be given by position too, as Integers or Ranges counted from 0, which helps when the names are long or missing. A Hash renames the columns as they are read:

```ruby
df = CAFrame.from_csv("sales.csv", columns: { "revenue" => "income", 2 => "customers" })
df.column_names   # => ["income", "customers"]
```

`types:` and `missing:` then refer to the new names.

### Anything else — a reading block

For a layout the options do not describe, give a block. It receives a reader and says, line by line, what each part of the file is:

```ruby
text = <<~CSV
  # exported 2024-03-12
  # all shops
  item,price
  name,USD
  coffee,3.20
CSV
df = CAFrame.from_csv(StringIO.new(text)) do |r|
  r.skip 2            # two comment lines
  r.header            # the column names
  r.header(:units)    # a line read as each column's "units" attribute
  r.data              # the rest is data
end
df["price"].attr(:units)   # => "USD"
df.nrow                    # => 1
```

## Separators, quotes and spaces

| option | meaning | default |
|---|---|---|
| `sep:` | the field separator; may be longer than one character | `","` |
| `quote:` | the quote character | `'"'` |
| `strip:` | trim spaces around unquoted fields | `false` |

Files written where a comma is the decimal mark often separate fields with semicolons:

```ruby
text = "item; price\ncoffee;  3.20\n"
df = CAFrame.from_csv(StringIO.new(text), sep: ";", strip: true, types: { "price" => :float64 })
df.column_names     # => ["item", "price"]
df["price"][0]      # => 3.2
```

A tab-separated file is read with `sep: "\t"`.

## Files in another encoding

A file is read as UTF-8 unless you say otherwise; a byte-order mark at its start is skipped. For a file in another encoding, name both the encoding it is in and the one to convert to. A CSV saved by an older spreadsheet program in Western Europe, for example, is often in Windows-1252:

```ruby norun
df = CAFrame.from_csv("prices.csv", encoding: "Windows-1252:UTF-8")
df["item"][0]   # => "Café latte", now in UTF-8
```

Name both halves. With `encoding: "Windows-1252"` alone the file is read, but the names and cells stay in Windows-1252, so a name you type in your (UTF-8) program finds no column. A file that is not valid UTF-8, read without `encoding:`, stops with an error that says to pass `encoding:`. Other common cases are `"ISO-8859-1:UTF-8"`, and `"CP932:UTF-8"` for a spreadsheet saved in Japanese.

## When the file is malformed

A field that cannot be read as written stops the read with an error: text after a closing quote, a quote inside an unquoted field, a quoted field that never closes, a record with more fields than there are columns. The message begins with the file and line, in the form an editor can jump to:

```ruby
text = "item,size\nposter,24\"x36\n"
CAFrame.from_csv(StringIO.new(text))   # raises CAFrame::CSVParser::MalformedCSV: line 2: a quote inside unquoted field 2
```

A field that holds a quote is written quoted, with the quote doubled: `"24""x36"`. That is also how `to_csv` writes it.

A line that is empty, or has only spaces, is skipped in a file of more than one column. In a file of one column it is a row with a missing cell, because that is how a missing single cell is written.

## Reading with a different parser

If you already have a parser you trust for a particular source, pass it as `parser:` — anything that takes the source and returns the header and the rows:

```ruby
require "csv"
df = CAFrame.from_csv("sales.csv", parser: ->(path) { rows = CSV.read(path); [rows.shift, rows] })
df.nrow   # => 24
```

The parser then owns the reading, so `sep:`, `quote:`, `strip:` and `encoding:` are its concern; `types:` and `missing:` still apply.

## Large files

- **Read only the columns you need** with `columns:`.
- **Give types when you know them.** A column read with a numeric type is never held as strings.
- **Use `:categorical` for a column of few distinct values** repeated many times — shop names, product codes. Each distinct value is stored once.
- A text column that you will no longer edit can be packed with `to_const_string`, which stores all its strings in one buffer:

```ruby
sales = CAFrame.from_csv("sales.csv", missing: ["-1", "n/a"])
sales["shop"] = sales["shop"].to_const_string
sales["shop"].class   # => CAConstString
```

## Summary

| the file… | option |
|---|---|
| has numbers, dates, yes/no columns | worked out by default; `types:` to name them |
| should be read as text, unconverted | `types: :string` |
| writes missing values with a code | `missing:` |
| may contain mistakes you want to hear about | `on_error: :warn` / `:raise` |
| has title or unit lines, or no header | `header:` / `data:` / `column_names:` / `attrs:` |
| is wide, and you need a few columns | `columns:` |
| is laid out some other way | a reading block |
| uses `;` or tabs | `sep:` |
| is not UTF-8 | `encoding: "Windows-1252:UTF-8"` and the like |
