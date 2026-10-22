# Writing results out

When the analysis is done, the results go somewhere: a CSV file for a spreadsheet or another program, JSON for a web service, or plain text for a report. This chapter covers each.

| you want… | use |
|---|---|
| a CSV file, or CSV text | `write_csv`, `to_csv` |
| Ruby Hashes and Arrays, for JSON | `to_records` |
| rows as Ruby Arrays | `to_a` |
| a table as text, to read | `to_table` |
| one numeric matrix | `to_ca` (chapter 15) |

```ruby
require "carray"
require "json"
sales = CAFrame.read_csv("sales.csv", missing: ["-1", "n/a"])
summary = sales.select("shop", "visitors", "revenue").group_by("shop").mean
```

## CSV — `write_csv` and `to_csv`

`write_csv` writes a file (or to an open IO), and `to_csv` returns the same CSV as a String:

```ruby
summary.write_csv("summary.csv")
puts summary.to_csv
# shop,visitors,revenue
# north,233.75,2874.36625
# south,129.85714285714286,1911.58375
# central,334.375,3159.0014285714287
```

- The index, when there is one, is written as the first column, under its name. `index: false` leaves it out.
- A missing cell is written as an empty field. `read_csv` reads an empty field back as missing, so the gaps survive the round trip.
- An empty string, which is a value and not a gap, is written `""` to keep the two apart.
- A field containing the separator, a quote or a line break is quoted, with quotes doubled.
- Times are written year first (`2024-03-04`, `2024-03-04T08:12:00Z`), which `read_csv` reads back as times.
- A yes/no (boolean) column is written as `1` and `0`; read it back with `types: { "name" => :boolean }`.
- Numbers are written in full, so `read_csv` reads back the same values. `precision:` rounds every floating-point cell to that many decimal places for a tidier file:

```ruby
puts summary.to_csv(precision: 2)
# shop,visitors,revenue
# north,233.75,2874.37
# south,129.86,1911.58
# central,334.38,3159.0
```

```ruby
puts sales.head(3).to_csv(sep: ";", header: false)
# 2024-03-04;north;182;2121.39;4.2
# 2024-03-04;south;95;1391.47;4.6
# 2024-03-04;central;310;3038.0;3.8
```

### Writing a code for missing values — `missing:`

Some programs expect missing values written as a code. `missing:` writes one — a String for every column, or a Hash with a `default:` and per-column codes, the same form `read_csv` reads:

```ruby
puts sales[6..8].to_csv(missing: "NA")
# date,shop,visitors,revenue,rating
# 2024-03-06,north,190,2285.32,4.1
# 2024-03-06,south,NA,1479.8,4.5
# 2024-03-06,central,305,3078.67,3.7
```

Reading the file back with the same `missing:` restores the gaps. If a real value would be written the same as the code, `to_csv` raises rather than write a file in which the two cannot be told apart.

### Another encoding — `encoding:`

`to_csv` writes UTF-8. For a program that expects another encoding, give `encoding:`. A character the encoding cannot hold raises, naming the cell, rather than being dropped:

```ruby norun
df.write_csv("for_excel.csv", encoding: "Windows-1252")
```

### Column attributes — `attrs:`

`attrs: [:units]` writes, below the names, a line with each column's `units` attribute, which `read_csv(attrs: [:units])` reads back:

```ruby
df = sales.select("shop", "revenue").head(2).copy
df["revenue"].set_attr(:units, "USD")
puts df.to_csv(attrs: [:units])
# shop,revenue
# ,USD
# north,2121.39
# south,1391.47
```

### What does not fit in a CSV

A column with several values per row (chapter 14) has no single field to go in, so `to_csv` raises; split it with `unstack_column` first, or write records as JSON. The frame's own attributes (a title, say) are not written.

## Records and JSON — `to_records`

`to_records` gives the rows as an Array of Hashes, ready for `JSON.generate`. A missing cell becomes `nil`, which JSON writes as `null`; a time stays a time value, which JSON writes as text:

```ruby
records = sales[6..7].to_records
records.first
# => {"date" => #<CATime::Element 2024-03-06 (19788D)>, "shop" => "north", "visitors" => 190, "revenue" => 2285.32, "rating" => 4.1}
puts JSON.generate(records)
# [{"date":"2024-03-06","shop":"north","visitors":190,"revenue":2285.32,"rating":4.1},{"date":"2024-03-06","shop":"south","visitors":null,"revenue":1479.8,"rating":4.5}]
```

`from_records` reads such records back (chapter 2). What a round trip through records keeps:

| | after `from_records(df.to_records)` |
|---|---|
| column names and order | kept |
| values | kept |
| missing cells | kept: `nil` is read as missing |
| column types | rebuilt from the values: integers become `int64`, floats `float64`, text a text column, and times a time column of the same resolution; `true`/`false` and a mix of kinds become an object column |
| the index | comes back as an ordinary first column; call `set_index` again |

When the types matter, give `types:` when reading back, or use CSV with `types:`.

## Rows as Arrays — `to_a`

`to_a` gives the rows as an Array of Arrays, one value per column, without the column names and without the index. A missing cell stays `UNDEF`, so decide first what it should be — fill it with `strip_mask`, or leave the row out with `drop_masked` (chapter 8):

```ruby
sales.select("visitors", "revenue")[6..7].to_a
# => [[190, 2285.32], [UNDEF, 1479.8]]
sales.select("visitors", "revenue")[6..7].drop_masked.to_a
# => [[190, 2285.32]]
```

A library that takes a table as rows and calls `to_a` on what it is given can be handed the frame directly.

## A table as text — `to_table`

For a report to read rather than a file to process, `to_table` gives the frame as aligned text (chapter 4). `rows: nil` includes every row:

```ruby
File.write("summary.txt", summary.to_table(rows: nil, precision: 1))
puts File.read("summary.txt")
# shop     visitors  revenue
# -------  --------  -------
# north       233.8   2874.4
# south       129.9   1911.6
# central     334.4   3159.0
```

`to_table` is for people; to read data back into a program, write CSV.
