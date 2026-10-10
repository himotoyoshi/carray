# Reading and writing CSV (`CAFrame.from_csv` / `to_csv`)

`CAFrame.from_csv` reads a CSV file into a [`CAFrame`](CAFrame.md), and `to_csv` writes a frame as CSV. This document describes both and the options that control them.

## Reading CSV (`CAFrame.from_csv`)

Read a CSV from a path, or from an open IO — anything answering `gets`, which a `StringIO` is. So CSV already in memory does not have to go to a temporary file first:

```ruby
CAFrame.from_csv("obs.csv")                      # a path
CAFrame.from_csv(StringIO.new(body))             # text already in hand
File.open("obs.csv") { |io| CAFrame.from_csv(io) }
```

A String is always read as a **path**, never as CSV text. Guessing between the two by looking for a newline is the kind of guess that is right until it is not, and `StringIO` says which one you meant. An IO is read from wherever it is and left open — the caller opened it, so the caller closes it. One reader drives both forms, so a path and the same bytes in memory cannot come to be read differently; `encoding:` is the exception, since it is an open mode and an IO is already open (there the IO's own encoding governs, and a BOM is the caller's).

The header row supplies column names (Strings). Every column is read **raw as a `CAString` of the cell strings** unless you ask for types. Pass `types:` to cast named columns on the way in, `types: :infer` to cast the columns that read as numbers, or call [`cast`](CAFrame.md#8-column-verbs) later. Cells that fail to parse become `UNDEF` automatically (**parse-mask**):

```ruby
df = CAFrame.from_csv("obs.csv")
df["temp"].class          # => CAString   (raw strings)
df["temp"].data_type      # => :object

df = CAFrame.from_csv("obs.csv", types: { "temp" => :float64, "rh" => :int32 })
df["temp"].data_type      # => :float64
# an empty cell or "xx" in the temp column -> UNDEF

CAFrame.from_csv("obs.csv", types: { "rh" => :int32 }, on_error: :warn)
# "xx" is still UNDEF, and a warning names the column and the cells
```

Number types are read as decimal numbers (`"010"` is ten), and `on_error:` (`:mask` / `:warn` / `:raise`) works as it does for [`cast`](CAFrame.md#8-column-verbs).

**Cleaning text.** Because a text column is a `CAString`, the string operations are on the column itself, and the in-place ones write to the frame — there is no need to take the cells out to a Ruby Array and put them back:

```ruby
df["station"].strip!                         # trim every cell, in place
df["code"].gsub!("-", "")
df["num"] = df["code"].extract(/(\d+)/, '\1') # a new text column
df.cast("num", :int32)                       # then read it as numbers
```

`extract(regexp, replace)` replaces each cell's match as `String#sub` does, so `'\1'` is the part the first group captured. It masks a cell its pattern does not match, so the cell stays `UNDEF` through the `cast` instead of turning into 0; a match of the empty string is `""`. To make several columns of one, use `split_column`, which puts the new columns in the old one's place and returns a new frame:

```ruby
df = df.split_column("code", "-", into: ["kind", "num"])   # "A-12" -> "A", "12"
```

A cell is split into at most as many pieces as there are names, so with more separators the rest stays in the last column (`"B-7-x"` gives `"B"`, `"7-x"`), and with fewer the columns it does not reach are `UNDEF`; a masked cell is `UNDEF` in all of them. `sep` is a String or a Regexp as `String#split` takes it (write a group as `(?:...)`, since a capturing group adds pieces).

Read without `types:`, all the columns of a file are views over one object array, so the `CAString` of each column holds no copy of its own. Read with `types:`, the file is read without making a String per cell: a column cast to a number never holds Strings, and each column left as text is a `CAString` of its own. `to_const_string` packs a column of read-only text into one buffer, which is lighter for a large column that is no longer edited.

`types: :infer` casts a column to `:int64` when every cell that is not missing is an integer that fits, to `:float64` when every such cell is a number, to `:boolean` when every such cell is `true` or `false` (in any case), to `:time` when every such cell is a year-first date or time (`"2024-01-01"`, `"2024/1/2 3:04"`, `"2024-01-01T12:00:00.5Z"`), and leaves it as text otherwise. A column of `0` and `1` is inferred as `:int64`: it could equally be counts, so say which with `types: { "flag" => :boolean }`, or with `cast("flag" => :boolean)` on the integer column. A number with a leading zero (`"007"`) is a code and keeps its column as text, and so does an integer too long for `:int64` (an identifier), which a float would round. A day-first or month-first date (`"01/02/2024"`) is not read as time, since which one it is cannot be told; cast it with `parse_to_time` and a format. `df.infer_types` returns the same decision as a map, so it can be checked, written into the code, or adjusted:

```ruby
df = CAFrame.from_csv("obs.csv")
df.infer_types        # => { "time" => :time, "temp" => :float64, "count" => :int64 }
df.cast(df.infer_types.merge("count" => :int32))
```

**Mostly one rule, with exceptions.** `default:` in the map sets every column the map does not name — `:infer` to infer them, or a type to cast them all — and a named column takes its own entry instead. `nil` leaves a column as the text it was read as, which is how to keep a column out of inference:

```ruby
CAFrame.from_csv("obs.csv", types: { default: :infer, "count" => :int32, "id" => nil })
# infer the rest; count is int32; id stays text even though it reads as a number

CAFrame.from_csv("obs.csv", types: { default: :float64, ["station", "note"] => nil })
# every column float64 except station and note
```

`types: :infer` is `types: { default: :infer }`. A map without `default:` casts only what it names, as before. `default:` is a Symbol and column names are Strings, so they cannot collide; any other Symbol key raises. `from_records` takes the same `types:`, and so does `cast` itself: `types:` is handed to `df.cast(types)`, so `df.cast(:infer)` and `df.cast(default: :infer, "id" => nil)` do the same to a frame already read.

**A file's own spelling of missing.** An unquoted empty field, and a cell a short row never reached, are `UNDEF` without asking. Files that write missing some other way — a `-999` sentinel, `///`, `NA` — say so with `missing:`. A field whose text is one of the tokens becomes `UNDEF` **before** `types:` casts, so the sentinel never reaches the column as a number:

```ruby
CAFrame.from_csv("obs.csv", missing: ["-999", "///"],
                 types: { "temp" => :float64 })
# -999 and /// are UNDEF in every column; temp is float64 without a -999.0 in it

CAFrame.from_csv("obs.csv", missing: { default: "-999", "rh" => ["-999", "-"], "id" => [] })
# -999 in every column; rh also takes "-"; in id, -999 is a real value
```

In a Hash, `default:` gives the tokens for every column and a **column name gives that column's own, replacing the default** (`[]` or `""` for none). Without `default:`, the columns the Hash does not name keep only the empty field. `default:` is a Symbol and column names are Strings, so the two cannot collide; any other Symbol key raises.

Tokens are **Strings, compared with the field's text as read** — after `strip:`, whether the field was quoted or not. So `"-999"` does not match `-999.0`, and a number given as a token (`missing: -999`) raises instead of quietly matching some spellings and not others. `""` means the empty field, which is missing already, so a quoted `""` stays the empty string. A Hash naming a column the file does not have raises `KeyError`.

Parsing uses a **built-in tokenizer** (no external dependency). The body of a UTF-8 file is read in C, a few megabytes at a time, straight into one object array; the columns are handed to the frame as views over it, so the build is cheap. Text in another encoding (unless the IO transcodes it to UTF-8), `strip: true`, and a record the C reader does not take go through the same rules in Ruby, which is also what reports a malformed record. Options: `sep:` (default `","`, and it may be longer than one character, as `"::"`), `quote:` (`'"'`), `strip:` (trim spaces from unquoted fields, default `false` = RFC 4180 spacing), `encoding:` (default `"bom|utf-8"`, strips a BOM).

Input that cannot be read as written **raises rather than losing data**. A quoted field must end at the separator or the end of the record: text after the closing quote (`"ab"cd`, or a space as in `"x" ,2`) raises `CAFrame::CSVParser::MalformedCSV`, except that `strip:` lets spaces through there as it does around an unquoted field. A quote inside an unquoted field (`5"in`) raises too: a field that holds a quote is written quoted, with the quote doubled (`"5""in"`), which is how `to_csv` writes it. So does a quoted field that is never closed, and a record with more fields than there are columns. A record goes on past the end of its line only inside a quoted field.

The message starts with the file and the line, in the form an editor or a terminal jumps to:

```
obs.csv:5004: a quote inside unquoted field 2 ("ab\"c"); ... (record 5003)
```

The line is the file's, counting the header, the lines `skip` dropped and the lines inside quoted fields; for a field never closed it is the line the field opens on. The record number follows when it is not the same. An IO with no path gives `line 5004:` instead. The error also answers `path`, `lineno` and `record`.

**Blank lines.** In a file of more than one column, a line that is empty, or only spaces and tabs with no separator, is not a row and is skipped. In a file of one column it is a row, because an empty line is how a missing single cell is written — `to_csv` writes a masked cell of a one-column frame that way — and spaces are a value (`UNDEF` with `strip: true`). So a blank last line of a one-column file reads as a masked last row: it cannot be told from one that `to_csv` wrote. Strip it from the file, or give the frame another column, if it is not meant as a row. A file without a header is treated the same way once its column count is known.

A header that names a column twice raises `ArgumentError`, since a frame keeps one column per name; name the columns yourself, as in `header: 0, column_names: [...]` (below), to read such a file.

**A file in another encoding** is read by naming its encoding and the one to transcode to. A CSV written by Excel in Japanese is CP932 — what Windows calls Shift_JIS, with the characters plain Shift_JIS lacks (`①`, `髙`, `㈱`):

```ruby
df = CAFrame.from_csv("obs.csv", encoding: "CP932:UTF-8")
df["地点"]                         # names and cells are UTF-8

File.open("obs.csv", "r:CP932:UTF-8") { |io| CAFrame.from_csv(io) }
```

Name both halves. `encoding: "CP932"` alone reads the file but leaves names and cells in CP932, so `df["地点"]` written in UTF-8 source finds no column. Naming plain `Shift_JIS` for an Excel file reads until the first character it lacks, then raises `Encoding::UndefinedConversionError`. Left at the default, a file that is not UTF-8 raises `invalid byte sequence in UTF-8`; both errors say to pass `encoding:`. Which encoding a file is in cannot be told from its bytes, so the message names the option, not a value.

For files with a title, a units row, or no header, say on which **lines** the header and the data are. A line is given by its index from 0, as in `File.readlines(path)[i]`:

```ruby
CAFrame.from_csv("obs.csv")                              # header at 0, data after it
CAFrame.from_csv("obs.csv", header: 2)                   # two title lines above
CAFrame.from_csv("obs.csv", header: 0, data: 3)          # units on lines 1-2
CAFrame.from_csv("big.csv", data: 1..100)                # the first 100 data lines
CAFrame.from_csv("raw.csv", column_names: %w[date temp rh])   # no header line
CAFrame.from_csv("raw.csv", header: false)               # names c0, c1, ...
```

`header:` is the line of the column names (default 0), or `false` for none. `data:` is the first line of the data (default the line after the header), or a Range of lines (`4..`, `...101`). A record that starts within `data:` is read whole, even when a quoted field carries it past the last line. A malformed-record error names the line from 1, as an editor numbers it, so the line `e.lineno` is index `e.lineno - 1`.

`column_names:` names the columns. Given alone, the file is taken to have no header line; given with `header:`, it replaces the names on that line. There have to be as many names as the file has columns -- those of the header line, or else of the first record -- or it raises `ArgumentError`.

`columns:` reads only some of the columns, in the order given: names of the header or of `column_names:`, or indexes from 0 (Integers and Ranges, `0..2`, `3..`). The fields of the others are passed over without being made into Strings, so a few columns of a wide file take little more time and memory than a narrow file would. `types:` and `missing:` then name the columns selected.

```ruby
CAFrame.from_csv("wide.csv", columns: %w[date temp rh])
CAFrame.from_csv("raw.csv", header: false, columns: [0, 3])   # names c0, c3
```

For anything else, pass a **reading block**. It is given the reader, which reads in the order the block says, with `skip(n)` / `header` / `header(name)` / `column_names(...)` / `columns(...)` / `data`:

```ruby
CAFrame.from_csv("obs.csv") do |r|
  r.skip 2              # drop 2 preamble lines
  r.header              # next line is the header
  units = r.header(:units)   # a second header, read and returned
  r.data                # the rest are data rows
end

CAFrame.from_csv("obs.csv") { it.skip 2; it.header; it.data }
```

The reader comes as the block's parameter rather than as `self`, so a local variable that happens to be named `data` or `header` cannot stand in for the verb; a block without a parameter raises. A block and `header:` / `data:` / `column_names:` / `columns:` cannot be given together.

To swap in a different parser (the stdlib `csv`, or a typed-table source), pass `parser:` — a callable `source -> [headers, rows]`, handed whatever you passed as the source. When given, it owns parsing, so `sep:` / `quote:` / `strip:` / `encoding:` and any block are its concern:

```ruby
require "csv"
CAFrame.from_csv("obs.csv",
                 parser: ->(p) { t = CSV.read(p); [t.shift, t] })   # first row = header
```

## Writing CSV (`to_csv`)

```ruby
df.to_csv("out.csv")       # write a CSV file, returns self
csv = df.to_csv            # no path -> return the CSV String
df.to_csv(sep: ";", header: false, index: false)
```

`to_csv` is the text form of the same flat table `to_ca` needs: every column must be **1-D** (an N-D column has no flat CSV cell and raises — export it per column, or use `to_records` + JSON for the structured shape). Unlike `to_ca` it does **not** promote to a common data type — each column is formatted to text on its own, so numbers, strings, and time / categorical columns sit side by side.

The index (if any) is written as the first column under `axis_name` unless `index: false`. A **masked cell (UNDEF) becomes an empty field**, which `from_csv` reads back as UNDEF (parse-mask) — so mask round-trips. A genuine empty string is written quoted (`""`) to stay distinct from missing. Fields containing the separator, a quote, or a newline are quoted with internal quotes doubled (RFC 4180). Options `sep` / `quote` mirror `from_csv`; `header` / `index` default to true.

A float32 value is written as the shortest decimal that reads back as the same float32 (`0.1`, not `0.10000000149011612`, the double it widens to), and so is each part of a cmplx64 one; reading the file with `types:` of `:float32` gives the values back bit for bit.

A boolean column is written as `1` / `0`, as a boolean is in every other serialization. Reading it back as boolean takes `types: { "flag" => :boolean }`, which reads `1` / `0` and also `true` / `false` in any case (the spelling pandas, R and spreadsheets write); a blank field is UNDEF and any other text follows `on_error:`. `cast("flag" => :boolean)` turns an integer column of 0 / 1 into a boolean one by the same rule.

`encoding:` transcodes the text before it is written or returned; left out, the CSV is UTF-8. A character the encoding cannot hold raises `Encoding::UndefinedConversionError` instead of being dropped, naming the cell:

```ruby
df.to_csv("out.csv", encoding: "CP932")   # for Excel in Japanese
# to_csv: row 1500 of "s" ("東😀"): "😀" (U+1F600) cannot be written in CP932
```

The CSV is built in UTF-8, so a String cell in another encoding is transcoded. A cell that is not text raises naming the cell too: bytes that are not valid in their encoding (`Encoding::InvalidByteSequenceError`), and bytes with no encoding, ASCII-8BIT (`Encoding::CompatibilityError`; give them one with `force_encoding`). Rows are counted from 0, as `df[i]` is.

`missing:` writes a masked cell as a given String instead of an empty field, for a reader that expects a sentinel. It takes the same forms as on `from_csv` — one String, or a Hash with `default:` and per-column overrides (the index goes by its axis name), where `""` is the empty field — so the same argument reads the file back with the mask in place:

```ruby
spec = { default: "-999", "comment" => "" }
df.to_csv("out.csv", missing: spec)
CAFrame.from_csv("out.csv", missing: spec)   # the mask comes back
```

If a real value would be written as a column's token, the file could not tell the two apart, so `to_csv` raises and names the column and row.

## See also

- [CAFrame](CAFrame.md) — the frame a file is read into and written from.
