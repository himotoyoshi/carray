# A DataFrame built on CArray columns (`CAFrame`)

> **Status: provisional.** CAFrame is being grown inside CArray, and that is
> where it is expected to stay. Splitting it into a gem of its own remains an
> option if it ever outgrows the fit — that would change the `require` and make
> it a separate dependency — but it is not the current direction.

`CAFrame` is a lightweight DataFrame: a set of **named columns**, each a real
[`CArray`](../WhatIsCArray.md). The frame adds only one thing on top of the
columns — **names** — and hands the columns back raw whenever you ask for
them, so you *escape* to a plain `CArray` and get the entire CArray universe
(masks, [views](Composition.md), [Face](CAFace.md) types,
[MemoryView](../interop/MemoryView.md) interop) for free.

That escape-first stance is the whole idea:

- a **column is a first-class `CArray`** (`df["temp"]` is the stored array
  itself, not a wrapper);
- the frame layer is a thin Ruby shell over columns; anything the frame does
  not offer, you do on the escaped column with ordinary CArray operations;
- there is **no type-inference engine, no opaque Series wrapper, no hidden
  index alignment** — the frame keeps names, you keep control;
- **sub-frames are views, not copies.** `select`, `filter`, `head` and row
  slices share storage with the frame they came from, so writing to one writes
  to the other. `copy` is the only way to cut the link
  ([Ownership](#ownership--columns-are-shared-views-copy-is-the-only-cut),
  [§13](#13-view-copy-and-aliasing)).

```ruby
require "carray"

df = CAFrame.new(
  "station" => CA_OBJECT(["tokyo", "osaka", "tokyo"]),
  "temp"    => CA_FLOAT64([22.1, 25.3, 19.0]),
  "wind"    => CA_FLOAT64([[1.2, -0.3], [2.1, 0.5], [0.0, 0.0]]),
)

df["temp"]                       # => CArray [22.1, 25.3, 19.0]  (the column itself)
df.select("station", "temp")     # => a view-frame with two columns
df.filter { |f| f["temp"] > 20 } # => a view-frame of the matching rows
df.group_by("station").mean      # => per-station means as a new frame
```

---

## 1. The model

A frame holds:

- an ordered **Hash of columns** (`name => CArray`). Column order is the Hash
  insertion order.
- a **row axis name** (default `"row"`).
- an optional **index column** (a 1-D `CArray` aligned to the rows).

The one structural invariant is the **axis-0 length**: every column must agree
on its first-dimension length `N` (the row count). Beyond axis 0, each column's
**trailing shape is free** — a frame can mix a scalar column `(N,)`, a vector
column `(N, 2)`, and a tensor column `(N, 3, 3)`. This is how CAFrame carries
record/tensor columns that a 2-D grid DataFrame cannot (see
[N-D columns](#4-n-d-columns)).

```ruby
df = CAFrame.new(
  "temp" => CA_FLOAT64([1.0, 2.0, 3.0]),          # (3,)   scalar column
  "wind" => CA_FLOAT64([[1, 2], [3, 4], [5, 6]]), # (3, 2) vector column
)
df.nrow   # => 3
df.nvar   # => 2
df["wind"].shape  # => [3, 2]
```

### What holds the row count

`nrow` is not a number the frame remembers on its own — it is read off
something the frame holds. A column holds it; so does the **index**, which is
why a frame may have an index and **no columns at all** and still be a frame of
`N` rows:

```ruby
CAFrame.new({}, index: CA_INT32([10, 20, 30]), axis_name: "t").nrow   # => 3
```

Such a frame is an ordinary one. `at`, `filter`, `head`, `sort_by_key`, `align`,
`copy`, `to_csv` and `to_records` all work on it, reading and carrying the index
the same way they carry a column (§13). What does not work is asking for the
index as a column — `df["t"]` raises `KeyError`, because the index is not one
(§3) — and `to_ca`, which has no column to stack.

You reach one by dropping every column of an indexed frame. **`drop` cannot
remove the index**: the index is not a column, so `drop(axis_name)` raises
`KeyError` like any other absent name. `reset_index` is the way, and it does not
delete the index either — it *demotes* it to an ordinary column at the front:

```ruby
df = CAFrame.new({ "a" => CA_INT32([1, 2, 3]) },
                 index: CA_INT32([10, 20, 30]), axis_name: "t")
df.drop("a").nrow           # => 3   -- the index still holds the row count
df.drop("a").nvar           # => 0
df.reset_index.variable_names   # => ["t", "a"]   -- the index became a column
```

When the last witness goes — no columns **and** no index — there is no row count
to keep, and the frame reports `nrow` 0. The next column assigned then fixes `N`
again, exactly as it does for a frame that was built empty:

```ruby
df = CAFrame.new("a" => CA_INT32([1, 2, 3]))   # no index
df.nrow                                        # => 3
e = df.drop("a")
e.nrow                                         # => 0   -- nothing holds 3 any more
e.append("b", CArray.int32(99).seq!).nrow      # => 99  -- the new column fixes N
```

That is a real change of row count, so it is worth being deliberate about:
a frame that still has an index refuses a differently-sized column
(`column "b" has axis-0 length 99, expected 3`), while one with no witness left
accepts it. Keep an index, or rebuild with `CAFrame.new`, when you want the
old length enforced.

### Ownership — columns are shared views, `copy` is the only cut

A frame is a **thin envelope over living columns**. Sub-frames (from `select`,
`filter`, a row slice) and escaped columns (`df["temp"]`) share those columns
**by reference**, exactly like any CArray view, so a frame is cheap to build and
to pass around. The flip side: there is **no copy-on-write and no
`SettingWithCopy` warning**. An edit reaches every frame that shares the column —
whether you go through a verb or through the escaped column
(`df["temp"][i] = v`). When you want an independent table, say so: `df.copy`
materializes every column and the index. To own a single column, rebind a fresh
copy — `df = df.append("temp", df["temp"].copy)`. **This is CArray's
view-everywhere model lifted to a table, not a general DataFrame** — how you
place `copy` is the dividing line.

```ruby
df   = CAFrame.new("station" => CA_OBJECT(["tokyo", "osaka", "tokyo"]),
                   "temp"    => CA_FLOAT64([22.1, 25.3, 19.0]))
warm = df.filter { |f| f["temp"] > 20 }
warm["temp"][0] = 0.0
df["temp"].to_a            # => [0.0, 25.3, 19.0]  -- the edit reached df

snap = df.copy
snap["temp"][1] = 99.0
df["temp"].to_a            # => [0.0, 25.3, 19.0]  -- a copy does not
```

Which operations share and which copy is listed operation by operation in
[§13](#13-view-copy-and-aliasing).

---

## 2. Construction

### `CAFrame.new`

Pass a Hash of `name => column`. Columns may be `CArray`s or anything that
answers `to_ca` (a Ruby `Array`, a lazy view). Column names are **Strings** —
a Symbol key in a column hash is stringified. Pairs may be given inline:

```ruby
CAFrame.new("a" => CA_INT32([1, 2, 3]), "b" => CA_FLOAT64([1.0, 2.0, 3.0]))

# control options are keyword-separated from columns:
CAFrame.new({ "v" => CA_FLOAT64([1, 2, 3]) },
            axis_name: "time",
            index: CArray.int64([100, 200, 300]))
```

The keyword slot doubles as the `axis_name:` / `index:` control channel. Only
those two Symbols are recognized there; any other Symbol keyword is rejected
rather than taken as a column, so a mistyped control option cannot silently turn
into one. String-keyed pairs always route to columns (a String can't be a
keyword), so a column named `"index"` or `"axis_name"` is written the ordinary
way:

```ruby
CAFrame.new(temp: CA_INT32([1, 2, 3]))          # ArgumentError (stray Symbol keyword)
CAFrame.new("index" => CA_INT32([1, 2, 3]))     # a column named "index"
```

A length disagreement raises immediately:

```ruby
CAFrame.new("a" => CA_INT32([1, 2]), "b" => CA_INT32([1, 2, 3]))
# => ArgumentError: column "b" has axis-0 length 3, expected 2
```

### `CAFrame.from_csv`

Read a CSV from a path, or from an open IO — anything answering `gets`, which
a `StringIO` is. So CSV already in memory does not have to go to a temporary
file first:

```ruby
CAFrame.from_csv("obs.csv")                      # a path
CAFrame.from_csv(StringIO.new(body))             # text already in hand
File.open("obs.csv") { |io| CAFrame.from_csv(io) }
```

A String is always read as a **path**, never as CSV text. Guessing between the
two by looking for a newline is the kind of guess that is right until it is
not, and `StringIO` says which one you meant. An IO is read from wherever it
is and left open — the caller opened it, so the caller closes it. One reader
drives both forms, so a path and the same bytes in memory cannot come to be
read differently; `encoding:` is the exception, since it is an open mode and an
IO is already open (there the IO's own encoding governs, and a BOM is the
caller's).

The header row supplies column names (Strings). Every column is
read **raw as a `CAString` of the cell strings** unless you ask for types.
Pass `types:` to cast named columns on the way in, `types: :infer` to cast the
columns that read as numbers, or call [`cast`](#8-column-verbs) later. Cells
that fail to parse become `UNDEF` automatically (**parse-mask**):

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

Number types are read as decimal numbers (`"010"` is ten), and `on_error:`
(`:mask` / `:warn` / `:raise`) works as it does for
[`cast`](#8-column-verbs).

**Cleaning text.** Because a text column is a `CAString`, the string operations
are on the column itself, and the in-place ones write to the frame — there is
no need to take the cells out to a Ruby Array and put them back:

```ruby
df["station"].strip!                         # trim every cell, in place
df["code"].gsub!("-", "")
df["num"] = df["code"].extract(/(\d+)/, '\1') # a new text column
df.cast("num", :int32)                       # then read it as numbers
```

`extract` masks a cell its pattern does not match, so the cell stays `UNDEF`
through the `cast` instead of turning into 0; a match of the empty string is
`""`. To make several columns of one, use `split_column`, which puts the new
columns in the old one's place and returns a new frame:

```ruby
df = df.split_column("code", "-", into: ["kind", "num"])   # "A-12" -> "A", "12"
```

A cell is split into at most as many pieces as there are names, so with more
separators the rest stays in the last column (`"B-7-x"` gives `"B"`, `"7-x"`),
and with fewer the columns it does not reach are `UNDEF`; a masked cell is
`UNDEF` in all of them. `sep` is a String or a Regexp as `String#split` takes
it (write a group as `(?:...)`, since a capturing group adds pieces).

Read without `types:`, all the columns of a file are views over one object
array, so the `CAString` of each column holds no copy of its own. Read with
`types:`, the file is read without making a String per cell: a column cast to
a number never holds Strings, and each column left as text is a `CAString` of
its own. `to_const_string` packs a column of
read-only text into one buffer, which is lighter for a large column that is no
longer edited.

`types: :infer` casts a column to `:int64` when every cell that is not missing
is an integer that fits, to `:float64` when every such cell is a number, to
`:time` when every such cell is a year-first date or time (`"2024-01-01"`,
`"2024/1/2 3:04"`, `"2024-01-01T12:00:00.5Z"`), and leaves it as text
otherwise. A number with a leading zero (`"007"`) is a code and keeps its
column as text, and so does an integer too long for `:int64` (an
identifier), which a float would round. A day-first or month-first date
(`"01/02/2024"`) is not read as time, since which one it is cannot be told;
cast it with `parse_to_time` and a format. `df.infer_types` returns the same
decision as a map, so it can be checked, written into the code, or adjusted:

```ruby
df = CAFrame.from_csv("obs.csv")
df.infer_types        # => { "time" => :time, "temp" => :float64, "count" => :int64 }
df.cast(df.infer_types.merge("count" => :int32))
```

**Mostly one rule, with exceptions.** `default:` in the map sets every column
the map does not name — `:infer` to infer them, or a type to cast them all —
and a named column takes its own entry instead. `nil` leaves a column as the
text it was read as, which is how to keep a column out of inference:

```ruby
CAFrame.from_csv("obs.csv", types: { default: :infer, "count" => :int32, "id" => nil })
# infer the rest; count is int32; id stays text even though it reads as a number

CAFrame.from_csv("obs.csv", types: { default: :float64, ["station", "note"] => nil })
# every column float64 except station and note
```

`types: :infer` is `types: { default: :infer }`. A map without `default:`
casts only what it names, as before. `default:` is a Symbol and column names
are Strings, so they cannot collide; any other Symbol key raises.
`from_records` takes the same `types:`, and so does `cast` itself: `types:` is
handed to `df.cast(types)`, so `df.cast(:infer)` and
`df.cast(default: :infer, "id" => nil)` do the same to a frame already read.

**A file's own spelling of missing.** An unquoted empty field, and a cell a
short row never reached, are `UNDEF` without asking. Files that write missing
some other way — a `-999` sentinel, `///`, `NA` — say so with `missing:`. A
field whose text is one of the tokens becomes `UNDEF` **before** `types:`
casts, so the sentinel never reaches the column as a number:

```ruby
CAFrame.from_csv("obs.csv", missing: ["-999", "///"],
                 types: { "temp" => :float64 })
# -999 and /// are UNDEF in every column; temp is float64 without a -999.0 in it

CAFrame.from_csv("obs.csv", missing: { default: "-999", "rh" => ["-999", "-"], "id" => [] })
# -999 in every column; rh also takes "-"; in id, -999 is a real value
```

In a Hash, `default:` gives the tokens for every column and a **column name
gives that column's own, replacing the default** (`[]` or `""` for none).
Without `default:`, the columns the Hash does not name keep only the empty
field. `default:` is a Symbol and column names are Strings, so the two cannot
collide; any other Symbol key raises.

Tokens are **Strings, compared with the field's text as read** — after
`strip:`, whether the field was quoted or not. So `"-999"` does not match
`-999.0`, and a number given as a token (`missing: -999`) raises instead of
quietly matching some spellings and not others. `""` means the empty field,
which is missing already, so a quoted `""` stays the empty string. A Hash
naming a column the file does not have raises `KeyError`.

Parsing uses a **built-in tokenizer** (no external dependency). The body of a
UTF-8 file is read in C, a few megabytes at a time, straight into one object
array; the columns are handed to the frame as views over it, so the build is
cheap. Text in another encoding (unless the IO transcodes it to UTF-8),
`strip: true`, and a record the C reader does not take go through the same
rules in Ruby, which is also what reports a malformed record.
Options: `sep:` (default `","`, and it may be longer than one character, as
`"::"`), `quote:` (`'"'`), `strip:` (trim spaces from
unquoted fields, default `false` = RFC 4180 spacing), `encoding:`
(default `"bom|utf-8"`, strips a BOM).

Input that cannot be read as written **raises rather than losing data**. A
quoted field must end at the separator or the end of the record: text after
the closing quote (`"ab"cd`, or a space as in `"x" ,2`) raises
`CAFrame::CSVParser::MalformedCSV`, except that `strip:` lets spaces through
there as it does around an unquoted field. A quote inside an unquoted field
(`5"in`) raises too: a field that holds a quote is written quoted, with the
quote doubled (`"5""in"`), which is how `to_csv` writes it. So does a quoted
field that is never closed, and a record with more fields than there are
columns. A record goes on past the end of its line only inside a quoted field.

The message starts with the file and the line, in the form an editor or a
terminal jumps to:

```
obs.csv:5004: a quote inside unquoted field 2 ("ab\"c"); ... (record 5003)
```

The line is the file's, counting the header, the lines `skip` dropped and the
lines inside quoted fields; for a field never closed it is the line the field
opens on. The record number follows when it is not the same. An IO with no
path gives `line 5004:` instead. The error also answers `path`, `lineno` and
`record`.

**Blank lines.** In a file of more than one column, a line that is empty, or
only spaces and tabs with no separator, is not a row and is skipped. In a file
of one column it is a row, because an empty line is how a missing single cell
is written — `to_csv` writes a masked cell of a one-column frame that way — and
spaces are a value (`UNDEF` with `strip: true`). So a blank last line of a
one-column file reads as a masked last row: it cannot be told from one that
`to_csv` wrote. Strip it from the file, or give the frame another column, if it
is not meant as a row. A file without a header is treated the same way once
its column count is known.

A header that
names a column twice raises `ArgumentError`, since a frame keeps one column
per name; name the columns yourself, as in `header: 0, column_names: [...]`
(below), to read such a file.

**A file in another encoding** is read by naming its encoding and the one to
transcode to. A CSV written by Excel in Japanese is CP932 — what Windows calls
Shift_JIS, with the characters plain Shift_JIS lacks (`①`, `髙`, `㈱`):

```ruby
df = CAFrame.from_csv("obs.csv", encoding: "CP932:UTF-8")
df["地点"]                         # names and cells are UTF-8

File.open("obs.csv", "r:CP932:UTF-8") { |io| CAFrame.from_csv(io) }
```

Name both halves. `encoding: "CP932"` alone reads the file but leaves names and
cells in CP932, so `df["地点"]` written in UTF-8 source finds no column. Naming
plain `Shift_JIS` for an Excel file reads until the first character it lacks,
then raises `Encoding::UndefinedConversionError`. Left at the default, a file
that is not UTF-8 raises `invalid byte sequence in UTF-8`; both errors say to
pass `encoding:`. Which encoding a file is in cannot be told from its bytes, so
the message names the option, not a value.

For files with a title, a units row, or no header, say on which **lines** the
header and the data are. A line is given by its index from 0, as in
`File.readlines(path)[i]`:

```ruby
CAFrame.from_csv("obs.csv")                              # header at 0, data after it
CAFrame.from_csv("obs.csv", header: 2)                   # two title lines above
CAFrame.from_csv("obs.csv", header: 0, data: 3)          # units on lines 1-2
CAFrame.from_csv("big.csv", data: 1..100)                # the first 100 data lines
CAFrame.from_csv("raw.csv", column_names: %w[date temp rh])   # no header line
CAFrame.from_csv("raw.csv", header: false)               # names c0, c1, ...
```

`header:` is the line of the column names (default 0), or `false` for none.
`data:` is the first line of the data (default the line after the header), or
a Range of lines (`4..`, `...101`). A record that starts within `data:` is read
whole, even when a quoted field carries it past the last line. A
malformed-record error names the line from 1, as an editor numbers it, so the
line `e.lineno` is index `e.lineno - 1`.

`column_names:` names the columns. Given alone, the file is taken to have no
header line; given with `header:`, it replaces the names on that line. There
have to be as many names as the file has columns -- those of the header line,
or else of the first record -- or it raises `ArgumentError`.

`columns:` reads only some of the columns, in the order given: names of the
header or of `column_names:`, or indexes from 0 (Integers and Ranges, `0..2`,
`3..`). The fields of the others are passed over without being made into
Strings, so a few columns of a wide file take little more time and memory than
a narrow file would. `types:` and `missing:` then name the columns selected.

```ruby
CAFrame.from_csv("wide.csv", columns: %w[date temp rh])
CAFrame.from_csv("raw.csv", header: false, columns: [0, 3])   # names c0, c3
```

For anything else, pass a **reading block**. It is given the reader, which
reads in the order the block says, with `skip(n)` / `header` /
`header(name)` / `column_names(...)` / `columns(...)` / `data`:

```ruby
CAFrame.from_csv("obs.csv") do |r|
  r.skip 2              # drop 2 preamble lines
  r.header              # next line is the header
  units = r.header(:units)   # a second header, read and returned
  r.data                # the rest are data rows
end

CAFrame.from_csv("obs.csv") { it.skip 2; it.header; it.data }
```

The reader comes as the block's parameter rather than as `self`, so a local
variable that happens to be named `data` or `header` cannot stand in for the
verb; a block without a parameter raises. A block and `header:` / `data:` /
`column_names:` / `columns:` cannot be given together.

To swap in a different parser (the stdlib `csv`, or a typed-table source), pass
`parser:` — a callable `source -> [headers, rows]`, handed whatever you passed
as the source. When given, it owns parsing,
so `sep:` / `quote:` / `strip:` / `encoding:` and any block are its concern:

```ruby
require "csv"
CAFrame.from_csv("obs.csv",
                 parser: ->(p) { t = CSV.read(p); [t.shift, t] })   # first row = header
```

### `CAFrame.from_records`

Build a frame from an **Array of row Hashes** — the shape `JSON.parse` yields
for a JSON array of objects:

```ruby
records = JSON.parse(File.read("obs.json"))   # => [ {...}, {...}, ... ]
df = CAFrame.from_records(records)
```

Unlike a CSV cell (always a string), a record value is **already a typed Ruby
object** (`Float`, `Integer`, `DateTime`, `String`). So `from_records` builds
each homogeneous column at its **native leaf type** — this is *arranging by the
value's own type*, not string inference, so §4.2's rule holds: **no date-like
string is parsed**, and anything mixed stays object.

| the column's non-nil values are… | column built as |
|---|---|
| all `Integer` | `:int64` |
| all `Numeric` (int/float mix) | `:float64` |
| strings / `DateTime` / booleans / mixed | `:object` (left as is) |
| equal-length numeric **arrays** | an **N-D** `(N, L)` column (see §4) |

- The column set is the **union of keys** in first-appearance order; keys are
  stringified (String- or Symbol-keyed records both work).
- A **missing key or `nil`** becomes `UNDEF`. An integer column with a hole
  stays `:int64` with an `UNDEF` cell — **no promotion to float** (the mask
  carries the missingness, unlike a NaN-forced float column).
- `types:` casts named columns afterward (same map / array-key forms as
  [`cast`](#8-column-verbs)), overriding the detected type:

```ruby
df = CAFrame.from_records(records,
                          types: { %w[prefNumber humidity] => :int32 })
```

An equal-length **array cell** across every record becomes one N-D column —
`{ "temp" => [min, mean, max] }` over `N` records is a single `(N, 3)` column
(see [N-D columns](#4-n-d-columns)). Ragged lengths or non-numeric leaves fall
back to an object column.

---

## 3. Column and row access — `df[...]`

`df[...]` is a **total function of the key type** (no sniffing of contents).
String keys *escape* to raw columns; row-selector keys stay in frame-land:

| key | result |
|---|---|
| `String` ×1 | the column — a raw `CArray` (the escape unit) |
| `String` ×2+ | `Array<CArray>` — the escaped columns, in order |
| `Integer` | one row, as a Ruby `Hash` |
| `Range` (integer endpoints) | positional row slice → **view-frame** |
| boolean `CArray` | row filter → **view-frame** |
| integer `CArray` | row gather → **view-frame** |

### String keys escape

One name collapses to a bare `CArray`; several give an `Array` of them — the
same "single collapses, plural is an array" rule as `ca[i]` vs `ca[i..j]`. This
makes destructuring natural:

```ruby
df["temp"]                 # => CArray            (one column)
df["temp", "wind"]         # => [CArray, CArray]  (several columns)

t, wind = df["temp", "wind"]   # parallel assignment
```

The escaped columns are the **stored arrays** (aliases), so writing through one
mutates the frame — the same write-through contract as any CArray view:

```ruby
t, = df["temp", "wind"]
t[1] = -7.0
df["temp"][1]              # => -7.0
```

`df[...]` never returns a *frame* for String keys — for a column-subset frame,
use [`select`](#5-select). A missing name raises `KeyError`; a mixed-type
multi-key list raises `ArgumentError`.

### Integer → one row (Hash)

A single integer returns the row as a Ruby `Hash` (`name => value`), with the
index field included when the frame has one. Scalar columns give a scalar; N-D
columns give the trailing-shape slice:

```ruby
df[0]
# => { "station" => "tokyo", "temp" => 22.1, "wind" => <CArray [1.2, -0.3]> }
```

A masked cell surfaces as `UNDEF`, **not** `nil`. Test for it with `== UNDEF` —
`UNDEF.nil?` is `false`, so `.nil?` misses it:

```ruby
m = CAFrame.new("temp" => CA_FLOAT64([22.1, UNDEF, 19.0]))
m[1]                        # => { "temp" => UNDEF }
m[1]["temp"] == UNDEF       # => true
m[1]["temp"].nil?           # => false  (do not use this to detect missing)
```

### Range / boolean / integer CArray → view-frame

These select **rows** and return a **view-frame** (each column a view sharing
storage with the parent):

```ruby
df[0..1]                   # rows 0..1 (positional)
df[df["temp"] > 20]        # boolean row filter
df[CA_INT64([2, 0, 1])]    # integer row gather (reorder / repeat)
```

Ranges are **positional only** — endpoints must be integers. Label ranges go
through [`filter`](#6-filter) with `f.index` (see below). A non-integer range
raises.

### `head` / `tail` → first / last rows (view-frame)

`head(n)` and `tail(n)` return the first / last `n` rows as a positional
view-frame (`n` defaults to 5). `n` larger than `nrow` yields the whole frame;
`n` of 0 yields an empty frame; a negative `n` raises.

```ruby
df.head        # first 5 rows (view-frame)
df.tail(3)     # last 3 rows
```

### `at` → one row by index label (Hash)

`at(label)` returns the single row whose index label equals `label`, as a Ruby
`Hash` — the label-keyed counterpart to `df[i]`. The label is matched exactly
against the index, so any orderable / object / time / categorical index
works. The frame must have an index (`set_index`).

```ruby
byname = df.set_index("station")
byname.at("osaka")             # => { "station" => "osaka", "temp" => 25.3, ... }
```

The return type is always a row Hash. A missing label raises `KeyError`, and a
**duplicate** label raises `ArgumentError` (the index is not required to be
unique) — reach for the multi-row, frame-returning path instead:

```ruby
df.filter { |f| f.index.eq(label) }   # every row whose label matches
```

An index may carry a **masked cell** — an `:outer` / `:right` join and `align`
both produce one for a row that matched nothing. Such a row has no label, so
`at` cannot reach it: `at(UNDEF)` raises `ArgumentError`, and asking for a real
label whose cell is masked raises `KeyError` like any other absent label. Two
undefined labels are not the same label, so there is nothing for `at` to return
one row for — which is the answer the key-matching primitives behind `join` and
`align` already give. Reach for those rows with mask vocabulary instead:

```ruby
df.filter { |f| f.index.is_masked }   # every row with no label
```

### `sort_by_key` → reorder rows by key columns (view-frame)

`sort_by_key(*keys, order:, masked_position:)` sorts rows **lexicographic** by
one or more key columns (the first key is primary). It delegates to the
multi-key `CArray.sort_addr` for the row permutation and gathers every column
and the index by it, returning a view-frame.

```ruby
df.sort_by_key("temp")                             # one column, ascending
df.sort_by_key("station", "temp")                  # lexicographic: station, then temp
df.sort_by_key("temp", order: :desc)               # all keys descending
df.sort_by_key(["station", :asc], ["temp", :desc]) # per-key direction
df.sort_by_key("temp", masked_position: :first)    # masked rows first
df.sort_by_key("time")                             # by the index (axis name)
```

- Each key is a **column name** (or the index axis name), or a
  **`[name, :asc | :desc]`** pair. `order:` is the direction for bare-name keys
  (default `:asc`). A key must be a scalar (1-D) column (an N-D key raises).
- **`masked_position:`** sends masked key rows to the `:last` (default) or
  `:first` end.
- Descending works for **every data type** (a descending key is internally its dense
  descending rank via `CArray#order` — reliable where negating a value is not,
  and tie-safe in a multi-key sort).

The block form `sort_by { |f| ... }` is the **escape** (the sort sibling of
`filter`): the block receives the frame and returns a key `CArray` — or an
`Array` of them — sorted ascending. Use it for **derived or composite** keys
that are not a plain column:

```ruby
df.sort_by { |f| (f["temp"] - target).abs }                          # nearest-to-target
df.sort_by { |f| f["temp"].order(descending: true, method: :dense) } # a descending key
```

`sort_by` also takes `masked_position:`. Build a descending key the same way
`sort_by_key` does internally — with `col.order(descending: true, method: :dense)`.

### `df[...] =` → the key picks the axis, as it does when reading

The write side of `df[...]` classifies the **key** the same way the read side
does: a **String names a column**, anything else selects **rows**.

```ruby
df["temp"] = col      # bind the name to that column (a new name is added)
df["temp"] = nil      # remove the column
df["temp"] = UNDEF    # mask every cell of the column, in place
df[2..3]   = nil      # remove those rows (below)
```

An assignment can only ever mutate the receiver — Ruby hands the right-hand
side back as the value of the expression, so there is no way for `[]=` to
return a new frame the way `append` / `drop` do. All the forms below act on
**this** frame; a parent frame's column set is untouched (membership is
per-frame).

Two of the column forms are worth stating plainly:

- **Rebinding is a replacement, not an edit.** Every other edit reaches the
  shared column and so is visible everywhere it is held — `fill`, `mask_eq`,
  `df[rows] = UNDEF`. `df["a"] = other_col` is the exception, together with
  `cast`: it binds the name to a different column and leaves the old one
  alone, so nothing that holds the old column sees the change. Rebinding is
  also the one place a column enters an existing frame, so it is where the
  **axis-0 length** must match `nrow` (an empty frame takes its `nrow` from
  the first column assigned).
- **`= UNDEF` does write through**, because it masks the stored column in
  place rather than replacing it — the column counterpart of
  `df[rows] = UNDEF`.

A scalar right-hand side is refused (no implicit broadcast — write
`CArray.float64(df.nrow) { 3 }`), as is a `CAFrame` (escape a column from it,
or splice rows with `df[rows] = other`). When the frame has an index, its
`axis_name` is not a column name: assigning to it raises and points at
`set_index` / `reset_index`.

#### Row forms — mask / delete / splice

With a non-String key the **right-hand value** picks the operation and the key
selects the rows:

| `df[sel] = ` | operation |
|---|---|
| `UNDEF` | **mask** the selected rows across every column, in place |
| `nil` | **delete** the selected rows — the frame shrinks |
| a `CAFrame` | **splice**: replace the selected contiguous rows with its rows |

```ruby
df[2..3]            = UNDEF   # mask rows 2 and 3 (every column)
df[df["temp"] < 0]  = UNDEF   # mask by condition
df[2..3]            = nil     # drop rows 2 and 3
df[df["temp"] < 0]  = nil     # drop by condition
df[2..3]            = other   # replace rows 2..3 with other's rows (any count)
df[6...6]           = other   # empty span at the end -> append other's rows
```

`sel` is a **row-axis indexer key, classified exactly as a 1-D column key**
([Indexer decision tree](Indexer_decision_tree.md)): a slice (`Range` /
`ArithmeticSequence` / `[start, count, step]`), a boolean `CArray`, an integer
`CArray`, or an `Integer`. **Mask and delete** accept any of them (they are
forwarded to the column indexer, so their errors are CArray's). **Splice** needs
a contiguous span, so it takes an `Integer` or a step-1 slice; a strided or
scattered selector raises.

- **`= UNDEF`** writes through to the column storage, so the shape is unchanged
  and the index is kept — the masked rows stay identifiable, and every view
  derived from the frame still tracks the change.
- **`= nil`** keeps the surviving rows in order and shrinks the index with them.
- **`= other`** follows **Ruby `Array#[]=` splice semantics**: `other` may carry
  **any number of rows**, so the row count changes; its **column set must match
  exactly**. When the frame has an index, `other` must have one too (its rows
  need labels), and the indexes are woven together.

> **What happens to shared storage** — the three forms differ, and all stay
> within CArray's view model:
>
> - `= UNDEF` masks **in place** (write-through), so every alias and derived view
>   sees the change; the shape is unchanged.
> - `= nil` rebinds each column to a **row-gather view of its former self**
>   (`col[keep]`), so the surviving rows **still share storage with the original
>   columns** — writing through the frame after a delete reaches a column escaped
>   before it, and vice versa. Nothing is copied; the original full-length
>   buffers stay alive behind the views, so `copy` if you want to reclaim them.
> - `= other` rebuilds each column with `CArray.meld` of three pieces: a view of
>   the rows before the span, a **snapshot** of `other`'s column, and a view of
>   the rows after it. The result is a `CAMeld` view, so the two halves behave
>   differently:
>   - The **spliced span is independent of `other`**: writing the frame's new
>     rows never reaches `other`, and `other`'s later writes never reach the
>     frame. This holds **even when `other` has the same row count as the
>     span** — `= other` is splice (structural), not an element-write, so it
>     does not write through to `other` the way CArray's `ca[sel] = other`
>     does. (Making it write-through when the counts happen to match would make
>     the same expression copy or mutate depending on lengths — the row count
>     deciding the behavior — so it always snapshots.)
>   - The **rows outside the span still share storage with the original
>     columns**, just as in the `= nil` form. A column escaped before the splice
>     keeps its own length and its own values in the replaced span, but writes to
>     the rows on either side of that span propagate both ways. `copy` the result
>     if you want a frame detached from the originals.
>
> To drop rows **without** mutating the frame in place, take a filtered view
> instead — `df[mask]` / `filter` return a new frame and leave this one bound to
> its current columns.

---

## 4. N-D columns

A column may carry trailing dimensions (a wind vector `(N, 2)`, a vertical
profile `(N, 20)`, a covariance `(N, 3, 3)`). Such a column comes either from
constructing it directly (`CAFrame.new("wind" => CA_FLOAT64([[…], …]))`) or from
[`from_records`](#2-construction), where an equal-length array cell
(`{ "temp" => [min, mean, max] }`) across the records stacks into one `(N, L)`
column. Row-selecting operations carry the trailing shape along automatically.
To work on a component, **escape and index the column** — the frame's row
filters are 1-D, so drop an N-D column to a scalar component first:

```ruby
df["wind"][nil, 0]                 # first component of every row -> (N,) column
df["wind"][nil, 0] > 4             # a boolean row mask built from a component
df = df.append("speed",
               (df["wind"][nil, 0] ** 2 + df["wind"][nil, 1] ** 2).sqrt)
```

> There is no `df["wind", 0]` component sugar — the leading `nil` in
> `df["wind"][nil, 0]` is explicit on purpose, keeping `df[...]` a clean
> column/row selector.

---

## 5. `select`

`select` is **column projection**: a **view-frame** holding the named columns
as aliases (zero-copy, sharing storage with the parent). It is the frame-valued
counterpart to `df[...]`'s escape — where `df["a", "b"]` hands back raw
CArrays, `df.select("a", "b")` keeps a frame:

```ruby
sub = df.select("station", "temp")   # => CAFrame with two columns
sub.variable_names                        # => ["station", "temp"]
```

`select` **never collapses** — one name is still a frame (unlike `df["a"]`):

```ruby
df.select("temp").variable_names          # => ["temp"]   (a frame, not a CArray)
```

Because the requested order becomes the new frame's column order, `select`
doubles as a **column reorder**:

```ruby
df.select("wind", "temp", "station").variable_names
# => ["wind", "temp", "station"]
```

Being a view-frame, its columns are aliases — writing through mutates the
parent. It chains with `filter` and everything else:

```ruby
df.select("station", "temp").filter { |f| f["temp"] > 20 }
```

`select` takes **no block** — a row condition goes through `filter`. The two
are orthogonal and compose by chaining (`df.select(…).filter { … }`); they are
deliberately *not* fused into one `select(cols) { cond }` call.

---

## 6. `filter`

`filter` selects **rows** with a block that receives the frame and returns a
boolean column. The block builds the mask from `f["col"]` (and `f.index`):

```ruby
df.filter { |f| f["temp"] > 24 }
df.filter { |f| (f["temp"] > 24) & (f["rh"] < 50) }   # & / | combine masks
```

The block form lets you reference columns without binding a variable, and the
result is a view-frame, so filters chain into group-by, join, etc.

Column names are written as `f["..."]` strings, **not** bare identifiers — a
frame allows arbitrary column names (`"temp.max"`, names with spaces, names
that collide with method names), which a `method_missing` DSL cannot support.

The **index** is just a row-aligned column, reachable as `f.index`, so **label
conditions are ordinary column conditions** — no separate `.loc` entry point:

```ruby
df.filter { |f| f.index >= "2024-06-15 01:00" }
df.filter { |f| (f.index >= lo) & (f.index <= hi) }   # a label range
```

### Rows whose membership is undetermined — `keep_masked:`

A **masked (UNDEF) selector cell** means the row's membership is genuinely
undetermined: the predicate read a masked input, so the answer is neither true
nor false. By default such a row is **dropped**, exactly as a false cell would
be. Pass `keep_masked: true` to carry the UNDEF forward instead:

```ruby
df.filter { |f| f["temp"] > 24 }                     # undetermined rows dropped
df.filter(keep_masked: true) { |f| f["temp"] > 24 }  # they survive, masked
```

The surviving undetermined rows arrive with their **data cells masked** and
their **index value present**, so the row stays identifiable and a later,
better-informed pass can re-judge it. Definitely-true rows carry their values
through unchanged either way.

> `keep_masked: true` returns a **materialized** frame, not a view-frame —
> writing the carried-forward UNDEF into the result is something a view cannot
> do without masking the parent's rows. This holds whether or not the selector
> actually carries a masked cell, so the same call site does not switch between
> sharing and copying depending on the data.

Two-frame comparisons don't fit a single-frame block — pull the columns out as
local variables instead (they're raw CArrays, so you can name them):

```ruby
diff = df_aws["temp"] - df_gpv["temp"]
```

---

## 7. Rows and conversion

```ruby
df.each_row { |r| ... }    # yield each row as a Ruby Hash (escape path)
df.each_row                # without a block -> Enumerator
```

`each_row` is an escape hatch for touching heterogeneous / Face-carrying rows
occasionally — the primary idiom is column-vectorized work, not per-row loops.

```ruby
df.to_records              # rows as an Array of plain Ruby Hashes
```

`to_records` is the **inverse of `from_records`** and the shape
`JSON.generate` wants. It exports rows as an `Array` of Hashes and **normalizes
for export**: a masked cell (`UNDEF`) becomes `nil`, an N-D column cell becomes
a Ruby `Array`, and a scalar stays a Ruby value. That normalization (which
`each_row` does *not* do — it yields the raw view with `UNDEF` and `CArray`
slices) is what lets it round-trip and serialize:

```ruby
CAFrame.from_records(df.to_records)   # rebuilds the same columns
JSON.generate(df.to_records)          # -> a JSON array of objects
```

The **mask survives**: `nil` on the way back in is the only spelling a missing
cell has, so it becomes `UNDEF` again in every column. The **data type is
rebuilt from the values**, which is not always the one you started with — a
Ruby `Integer` carries no width, so any integer column comes back `int64`, and
a boolean column comes back as an object column of `true` / `false`. When the
exact types matter, `to_csv` with `types:` on the way back, or `cast`
afterwards, is the way to pin them.

> **`nil` and `UNDEF` are the same thing on the way out.** In memory they are
> distinct — a masked cell is `UNDEF`, and an object column can hold a genuine
> Ruby `nil` as a value (§3). Neither `to_records` nor `to_csv` keeps that apart:
> both write either one as missing, and both read missing back as `UNDEF`. So a
> `nil` held as a value in an object column comes back masked. Serialization has
> one way to say "nothing here", and this is it; if the distinction matters,
> keep it in a value the format can carry (an empty string, a sentinel) rather
> than in `nil`.

If a 2-D CArray of shape `(nrow, nvar)` is what you want, `to_ca` hands
one over — a **view**, one column per variable in column order:

```ruby
m = df.to_ca                # CAStack view (nrow, nvar), no data copied
m[0, 1] = 99.0              # writes flow back into the column
owned = df.to_ca.copy       # independent, owned matrix
```

Only all-scalar (**1-D**) columns qualify; an N-D column has no single
matrix form and raises — escape it per column with `df["name"]`. A mixed
data type set is promoted to a common type (`result_type`) through lazy cast
lanes, so the promotion costs no buffer either.

`to_ca(writable: true)` — the 3.0 "give me something my writes reach"
demand — is honoured only when every column enters the stack unchanged.
A read-only column, or one the common type promotes (it is stacked
through a cast lane, so a write there is no longer the value handed
over), is refused rather than silently answered.

Columns with no common type as stored — text (`fixlen`) or `Face`-typed
columns beside numeric ones — raise. `promote` is the frame-level answer:

```ruby
df.promote(:object).to_ca   # every column at its surface values -> object matrix
df.promote.to_ca            # already-common type; also makes writable: true pass
```

`CArray.tabulate(df.variables)` is the eager sibling: it builds an owned
table directly and also accepts 2-D column blocks.

```ruby
df.to_csv("out.csv")       # write a CSV file, returns self
csv = df.to_csv            # no path -> return the CSV String
df.to_csv(sep: ";", header: false, index: false)
```

`to_csv` is the text form of the same flat table `to_ca` needs: every column
must be **1-D** (an N-D column has no flat CSV cell and raises — export it per
column, or use `to_records` + JSON for the structured shape). Unlike `to_ca` it
does **not** promote to a common data type — each column is formatted to text on its
own, so numbers, strings, and time / categorical columns sit side by side.

The index (if any) is written as the first column under `axis_name` unless
`index: false`. A **masked cell (UNDEF) becomes an empty field**, which
`from_csv` reads back as UNDEF (parse-mask) — so mask round-trips. A genuine
empty string is written quoted (`""`) to stay distinct from missing. Fields
containing the separator, a quote, or a newline are quoted with internal quotes
doubled (RFC 4180). Options `sep` / `quote` mirror `from_csv`; `header` /
`index` default to true.

A float32 value is written as the shortest decimal that reads back as the
same float32 (`0.1`, not `0.10000000149011612`, the double it widens to), and
so is each part of a cmplx64 one; reading the file with `types:` of
`:float32` gives the values back bit for bit.

`encoding:` transcodes the text before it is written or returned; left out,
the CSV is UTF-8. A character the encoding cannot hold raises
`Encoding::UndefinedConversionError` instead of being dropped, naming the
cell:

```ruby
df.to_csv("out.csv", encoding: "CP932")   # for Excel in Japanese
# to_csv: row 1500 of "s" ("東😀"): "😀" (U+1F600) cannot be written in CP932
```

The CSV is built in UTF-8, so a String cell in another encoding is
transcoded. A cell that is not text raises naming the cell too: bytes that
are not valid in their encoding (`Encoding::InvalidByteSequenceError`), and
bytes with no encoding, ASCII-8BIT (`Encoding::CompatibilityError`; give them
one with `force_encoding`). Rows are counted from 0, as `df[i]` is.

`missing:` writes a masked cell as a given String instead of an empty field,
for a reader that expects a sentinel. It takes the same forms as on
`from_csv` — one String, or a Hash with `default:` and per-column overrides
(the index goes by its axis name), where `""` is the empty field — so the same
argument reads the file back with the mask in place:

```ruby
spec = { default: "-999", "comment" => "" }
df.to_csv("out.csv", missing: spec)
CAFrame.from_csv("out.csv", missing: spec)   # the mask comes back
```

If a real value would be written as a column's token, the file could not tell
the two apart, so `to_csv` raises and names the column and row.

### Looking at a frame — `to_table`, `p`, `puts`

```ruby
p df                       # summary line + first 8 / last 2 rows
puts df                    # the whole frame (to_s)
puts df.to_table(rows: 40) # explicit cap, split evenly around the elided middle
```

```
#<CAFrame nrow=1286 vars=[name:object, lat:float64, temp:int32] index="id">
  id  name              lat  temp
----  ----------  ---------  ----
   0  観測点0          45.0     0
   1  観測点1     44.999667     1
   :  :                   :     :
1285  観測点1285  44.571667    25
```

`to_table` is the display counterpart of `to_csv` and shares none of its
constraints — it is text to be looked at, not read back. Numeric columns are
right-aligned and everything else left-aligned, a **masked cell shows as `_`**
(the marker CArray's own inspect uses), and an **N-D column** — which `to_csv`
rejects, having no flat cell — shows each row's slice as an Array literal.
Column widths are counted in terminal cells, so a CJK name occupies two per
character and the columns stay square.

Float cells are rounded to `precision` decimal places **for display only**
(default 6): full precision lets one value like `141.67833333333334` set the
width of the whole column. `precision: nil` prints them as Ruby renders them.

`rows` caps the printed rows (default 20) and the elided middle becomes a `:`
row; `rows: nil` prints every row. When rows are elided, a footer states the
full size. `index: false` drops the index column.

`inspect` and `to_s` sit on the same renderer: **`p df` stays a screenful**
(the summary line, then the first 8 and last 2 rows) while **`puts df` is the
whole frame**.

### Checking a frame just read — `describe`

`describe` summarizes the columns, **one row per column**, as a new frame
indexed by column name — so a wide table stays readable, and the result is an
ordinary frame to filter or print:

```ruby
puts df.describe.to_table
```

```
column   type     count  masked  unique  min         max         mean        stddev
-------  -------  -----  ------  ------  ----------  ----------  ----------  --------
station  object       3       0       2  _           _           _           _
temp     float64      2       1       2  19.0        22.1        20.55       2.192031
time     CATime       3       0       3  2024-01-01  2024-01-03  2024-01-02  1D
```

- `type` is the data type, or the Face's class for a Face column, with the
  trailing shape of an N-D column in brackets (`float64[3]`).
- `count` and `masked` count cells, so an N-D column counts every cell of every
  row; `unique` is the number of distinct present values.
- `min` / `max` / `mean` / `stddev` apply where the column's kind gives them a
  meaning and are `UNDEF` elsewhere: real numbers and booleans get all four
  (a boolean's mean is the share of trues), complex numbers get `mean` and
  `stddev` (no order, and no `unique`), `CATime` and `CATimedelta` get all four
  as times and durations, and text, categorical and record columns get the
  counts only.
- A column with no present cell has `UNDEF` statistics. The index is not a
  column and is not summarized.

`describe("temp", "rh")` summarizes only the named columns.

### Index

```ruby
df.set_index("time")       # move "time" to the index (mutates self; §8 role change)
df.reset_index             # move the index back into a column (mutates self)
df.index                   # the index CArray (or nil)
df.axis_name               # the row-axis name
```

`set_index` renames the row axis after the column it promotes, because that is
the name the index then appears under — as the first CSV column, and as its key
in a row `Hash`. `reset_index` is its inverse, and puts the earlier name back:

```ruby
df = CAFrame.new({ "t" => …, "v" => … }, axis_name: "obs")
df.set_index("t").axis_name    # => "t"
df.reset_index.axis_name       # => "obs"
```

A frame **built** with an index never had a row axis name before it, so there is
nothing to put back and `reset_index` leaves the default `"row"`. A frame
derived from an indexed one — a row slice, `filter`, `copy` — is born indexed in
the same way, so it behaves the same.

`set_index` on a frame that **already has an index** replaces it, and the index
being replaced goes back to being a column — the same demotion `reset_index`
performs, in the same position. So re-indexing keeps every column, and
`set_index("b")` on a frame indexed by `"a"` is the same as `reset_index`
followed by `set_index("b")`:

```ruby
df.set_index("a")
df.set_index("b")
df.variable_names   # => ["a", "v"]   -- "a" is a column again, not lost
df.reset_index      # => axis_name "obs" again, variable_names ["b", "a", "v"]
```

---

## 8. Column verbs

The verbs split by **what they change** — the single rule that decides whether a
call returns a new frame or mutates `self`:

- Verbs that make the table a **different table** — a different column set
  (`append`, `drop`), different names (`rename`) — return a **new frame**.
  Columns are shared, so the new frame is a cheap envelope; chain or reassign:
  `df = df.append(...).drop(...)`.
- Verbs that **edit a column of the same table** — its mask (`mask_eq`, `fill`),
  its type (`cast`, `promote`), or which column is the index (`set_index` /
  `reset_index`) — return **`self`**. The edit is written through to the shared column, so it
  reaches any frame sharing that column; `copy` first to isolate. The one
  exception is `cast`, which must allocate a new column (the byte layout
  changes) and so does not reach other frames.

```ruby
# column set / names change -> new frame (thread the result):
df = df.append("tempF", df["temp"] * 9 / 5.0 + 32) # add a derived column at the tail
df = df.drop("raw", "scratch")                      # remove columns (data untouched)
df = df.rename("temp" => "temperature")             # rename, preserving order

# edit a column of the same table -> self (mutates in place):
df.cast("temp", :float64)                           # cast a column
df.cast("temp" => :float64, "rh" => :int32)         # map form: several columns
df.cast(["u", "v"] => :float64)                     # one type shared by several
df.cast(:infer)                                     # what infer_types finds
df.cast(default: :float64, "station" => nil)        # the rest float64, station as is
df.promote                                          # every column to one common type
df.promote(:object)                                 # ...to the widest type of all
df.mask_eq("flag", -999)                            # mask cells equal to a sentinel
```

Notes:

- **`append`** returns a new frame with the column added at the tail (or
  replacing an existing name in place). The length must match `N`; appending to
  an empty frame (`nrow` `0`, a defined value) yields a frame whose `N` is that
  column's length.
- **`cast`** reads a text (object) column into an integer or float type as
  decimal numbers: digits with an optional sign, decimal point and exponent
  (and `nan` / `inf` for floats), surrounding spaces ignored. A cell is data,
  not a Ruby literal, so `"010"` is ten and `"0x1F"` / `"1_000"` are not
  numbers. An integer type takes any number whose value is exactly an integer
  (`"1.0"`, `"1e3"`), decided from the digits so a long integer is not
  rounded; `"1.5"` is not an integer. A cell that does not read, or a value
  the type cannot hold (`"300"` into `:int8`), becomes `UNDEF` (parse-mask).
  A Ruby number in an object column is held to the same rule: an Integer
  that fits, or a Float, Rational or BigDecimal with no fractional part, is
  kept, and `2.5` is `UNDEF` rather than truncated, so `"2.5"` and `2.5` in
  one column agree. A string column (`CArray.string`, `CArray.const_string`)
  is read the same way as an object column of text.
  `:time` parses a text column into a `CATime` column in the finest unit its
  text shows: `:D` for dates alone, `:s` with a time of day, `:ms` / `:us` /
  `:ns` for fractions of a second (for a format or a unit of your own, use
  `parse_to_time`). The unit is the finest any cell shows, so one cell with
  nanoseconds puts the column in `:ns`, which spans only 1677 to 2262; a date
  outside it raises `RangeError` naming the column and the cell, under every
  `on_error:`, rather than becoming `UNDEF`. `parse_to_time(name, unit: :us)`
  reads it in a coarser unit. Other targets go through `to_type`, and casting a
  numeric column is an ordinary conversion. It rebinds a fresh column — the one edit that does
  **not** write through to frames sharing the old column.

  `on_error:` decides what an unreadable cell does: `:mask` (the default)
  makes it `UNDEF`; `:warn` does the same and warns once per column with the
  count and the first few cells; `:raise` raises `CAFrame::UnreadableColumn`
  naming the column, the row and the cell, and rebinds no column. Blank, `nil` and
  masked cells are missing values, not errors, under every policy.

  ```ruby
  df.cast("rh" => :int32, on_error: :raise)
  # CAFrame::UnreadableColumn: column "rh", row 41 "1.5" cannot be read as int32
  ```
- **`promote`** brings the **whole frame** to one data type, where `cast`
  forces the columns you name. Without an argument the type is the one
  `CArray.result_type` picks — the same decision `to_ca` makes internally, so
  `df.promote` is exactly "make this frame stackable", and a frame that is
  already uniform is left alone. With an argument the type must be a
  **widening** for every column; a narrowing target raises and points at
  `cast`, the verb that forces a lossy change. `:object` is the widest type
  and always accepted, which is how a frame mixing text, `Face`-typed and
  numeric columns becomes single-typed (and so how `to_ca` can hand back a
  matrix for it).
- **A `Face` column** ([`CATime`](CATime.md),
  [`CACategorical`](../objects/CACategorical.md),
  [`CAConstString`](../objects/CAConstString.md)) answers the conversion
  itself, and `cast` / `promote` hand it over rather than second-guessing:
  `:object` gives its **surface** values (labels, not codes;
  `CATime::Element`, not serials), and a numeric target gives whatever the
  Face declares in `#to_numeric` — a fixed-point column becomes its scaled
  values, while a Face that declares nothing raises and says so (a time is
  not a number). The storage is always reachable, deliberately, through
  `df["name"].parent`. Because the Face decides, the widening rule above
  applies to plain columns only.
- **`mask_eq`** masks in place through the escaped column (write-through). A
  [categorical](../objects/CACategorical.md) column's codes are read-only, so `mask_eq`
  on one raises — recode by rebinding a new column instead.

### Datetime columns

Two verbs turn a column into a [time](CATime.md) column, one per
input shape. Each rebinds the column and returns `self`; make it the index with
`set_index` afterward.

```ruby
# text -> time: parse date strings
df.parse_to_time("time").set_index("time")      # written year first
df.parse_to_time("time", "%d/%m/%Y")            # explicit strptime format
df.parse_to_time("time", :infer)                # find the one format it is in
df.parse_to_time("time", :mixed)                # guess at each cell (slow)

# serial -> time: reinterpret integer counts since an epoch
df.to_time("t", unit: :h, epoch: "1990-01-01")  # netCDF "hours since 1990-01-01"
df.to_time("t", unit: :day, epoch: "1899-12-30").set_index("t")  # Excel serial date

# the same pair as one value — a units attribute goes straight in
df.to_time("t", CATime::Grid.parse("hours since 1990-01-01"))
```

- **`parse_to_time(name, format = nil, unit: nil, on_error: :mask)`**
  parses a string-bearing column (an object `CArray` of Strings, or a
  `CAString` / `CAConstString` / `CAFixlenString`). Without `format` it reads
  text written **year first** and nothing else: the date as
  `YYYY-M-D` or `YYYY/M/D` (month and day with or without a leading zero),
  then optionally a time of day after `T` or a space (`h:mm`, `:ss`, a
  fraction of up to nine digits) and a zone (`Z`, `+09:00`, `+0900`, `+09`;
  a time without a zone is UTC). A date in another order is not read,
  because whether `"01/02/2024"` is January or February cannot be told from
  the text; pass a strptime `format` for it, `:infer`, or `:mixed` to guess
  at each cell, which is much slower. `unit` defaults to the finest the text
  shows without a format or with `:infer`, and to `:s` with a format; it
  takes the unit spellings `CArray.time` does (`:s`, `"10 minutes"`, a
  `CATime::Resolution`). Hour 24 is read only as `24:00:00`, the end of the
  day (the next midnight); `24:30` does not parse.
  Missing and unparseable cells become `UNDEF` (parse-mask);
  `on_error: :warn` / `:raise` reports the unparseable ones as `cast` does.
  A non-string column raises. `cast(name => :time)` is the call without a
  format.

  `:infer` finds the one format the column is written in. The first
  present cell gives the candidate formats (day-first and month-first dates
  with `/`, `-` or `.`, two-digit years, month names as in `Jan 2, 2024`
  or `2 Jan 2024`, `YYYYMMDD`, each with an optional `h:mm`, `h:mm:ss`,
  fraction of a second, or `AM` / `PM` time and a zone `+0900`, `+09:00`,
  `+09`, `Z`, `UTC` or `GMT`; and Japanese dates `2024年1月2日`, with an
  optional `3時4分`, `3時4分5秒` or `3:04` time), and each later cell drops
  the candidates it does not fit until one is left, so a later
  `13/02/2024` settles whether `01/02/2024` is day-first. It raises
  `CAFrame::UnreadableColumn` when no candidate fits the first cell and when
  none is left, and a cell not in the chosen format raises it too, whatever
  `on_error` says. When more than one is left at the end it raises
  `CAFrame::AmbiguousTimeFormat`, whose `formats` lists them. A zone named for a place (`JST`, `CST`) is not a
  candidate, since some of those names mean different offsets in different
  places. `infer_time_format(name)` returns the format it chose, to write
  into the code:

  ```ruby
  df.infer_time_format("date")   # => "%d/%m/%Y"

  begin
    df.parse_to_time("date", :infer)
  rescue CAFrame::AmbiguousTimeFormat => e
    e.formats                    # => ["%d/%m/%Y", "%m/%d/%Y"]
    df.parse_to_time("date", "%d/%m/%Y")
  end
  ```

  `:mixed` is for text that is not written in one format, which is broken
  as data a machine reads. It guesses at each cell on its own, as
  `Time.parse` does, so it can read a cell wrongly without saying so:
  `"01/02/24"` is read as 24 February 2001.
- **`to_time(name, grid = nil, unit:, epoch: nil)`** reads an integer column
  as counts of `unit` resolution since `epoch` (default the Unix epoch).
  `epoch` takes any time literal (String / `Time` / Integer), so columns
  measured from another origin convert directly. A float column is accepted
  only when every value is whole; a fractional serial raises
  `CAFrame::UnreadableColumn` (use a finer `unit`). A non-numeric column raises.

  A [`CATime::Grid`](CATime.md) carries that (unit, epoch)
  pair as one value — passed positionally or as `unit:` — so a netCDF `units`
  attribute needs no taking apart. It also carries a phase the keyword form
  cannot: the keyword `epoch` is read on the `unit` grid, so
  `unit: :D, epoch: "1980-01-01 12:00"` loses the time of day, while
  `CATime::Grid.parse("days since 1980-01-01 12:00")` resolves the finer
  storage that holds it.

There is no bundled "convert and index" verb — compose the conversion with
`set_index`, keeping each step explicit.

### Filling masked cells — `fill`

`fill(name, method)` fills the masked cells of a column **in place**
(write-through, returning `self`):

```ruby
df.fill("temp", :ffill)     # forward-fill: carry the last present value
df.fill("temp", :bfill)     # back-fill: carry the next present value
df.fill("temp", :linear)    # linear interpolation between present values
df.fill("temp", 0.0)        # constant fill
```

- **`:ffill` / `:bfill`** carry the nearest present value; leading (for `:ffill`)
  or trailing (for `:bfill`) cells with nothing to carry stay masked. Works for
  any column type.
- **`:linear`** interpolates a numeric column against the frame's **index**
  coordinate when one is set (else the cell position) — this is where the index
  earns its keep. Cells outside the present range stay masked; a column with
  fewer than two present cells is left unchanged.
- a bare value fills every masked cell with that constant.

Because `fill` writes through, a [categorical](../objects/CACategorical.md) column raises
(its codes are read-only) — rebind a filled copy instead:
`df = df.append("s", df["s"].strip_mask(method: :forward))`.

---

## 9. `group_by` and `GroupedFrame`

`group_by` groups **rows** by one or more keys — a column name, several names
(composite key), or an external length-`N` `CArray`. Everything routes through
`categorize` → [`group_by_category`](../objects/CACategorical.md), so the frame layer only
builds the key and hands back a `GroupedFrame`:

```ruby
grp = df.group_by("station")
grp.ngroup                 # => number of groups
grp.labels                 # => group key values, in code order
```

A row whose key is **masked** belongs to **no group**: which group it falls in
is undetermined, and grouping takes the same default `filter` does and leaves it
out rather than inventing a group for it. With a composite key one undetermined
component is enough to make the whole tuple undetermined. So the group sizes
need not add up to `nrow` — count the masked keys (`df["k"].count_masked`) if
you need to account for the difference, or fill them first
(`df.fill("k", value)`) to group them together.

The index of a reduced frame is the group's key value. With a single key it
keeps the key's data type and Face — an integer key gives an integer index, a
`CATime` key a `CATime` index — so the result can be joined or aligned on it.
Groups appear in the order their keys first appear. A composite key gives an
object index of the key tuples.

The grouping and its index are taken when `group_by` is called: changing the key
afterwards does not move rows between groups or rename them. The **values** are
read when a reduction is called, so a reduction after `df["v"][i] = x` sees the
new value, in the group the row had when the grouping was taken. Group again
after changing a key.

A `GroupedFrame` has three surfaces:

### (a) Convenience reductions

`sum` / `mean` / `min` / `max` reduce **every numeric scalar column** into a
new frame indexed by the group labels. The **key columns are skipped** — they
are the index of the result, whatever their data type — and so are non-numeric
and N-D columns, which a reduction has nothing to say about:

```ruby
df.group_by("station").mean       # => frame of per-station means
```

Each takes `min_count:` and `fill_value:` as a core reduction does: a group with
fewer than `min_count` present values is `UNDEF`, and `fill_value` fills the
`UNDEF` cells:

```ruby
df.group_by("station").mean(min_count: 20)                  # too few readings -> UNDEF
df.group_by("station").sum(min_count: 1, fill_value: 0.0)
```

### (b) `aggregate` — declarative per-column reductions

Map each output name to `[input_column, reduction]`. The reduction is a
**Symbol** (a vectorized reduction applied through the group iterator) or a
**Proc** (per-group custom, called with the group's column slice — this is how
N-D columns reduce):

```ruby
df.group_by("station").aggregate(
  "temp_mean" => ["temp", :mean],
  "temp_max"  => ["temp", :max],
  "wind_mean" => ["wind", ->(c) { c.mean(axis: 0) }],   # N-D column, per group
)
# => frame with columns temp_mean / temp_max / wind_mean, index = station labels
```

A Symbol reduction takes its keywords as a third element:
`"temp_mean" => ["temp", :mean, min_count: 20]`.

### (c) `table` — cross-column Ruby escape

When aggregation isn't enough, `table` yields **each group as a view-frame**
and collects a Hash of outputs column-wise into a new frame. The full frame API
works on `g`:

```ruby
df.group_by("station").table do |g|
  { "n" => g.nrow, "tmax" => g["temp"].max }
end
```

### (d) Raw group iterator

`grp["col"]` exposes the underlying
[`CACategoricalIterator`](CACategoricalIterator.md) for one column, so any
per-group reduction the iterator offers is reachable:

```ruby
df.group_by("station")["temp"].mean    # => per-group means as a CArray
```

### Time bins — `resample`

`resample(name, unit)` groups the rows into **time bins** of length `unit`
along a time column (or the time index), and returns a `GroupedFrame`, so
every reduction above applies:

```ruby
df.resample("time", "1 hour").mean
df.resample("time", "1 day").aggregate("rain" => ["rain", :sum], "tmax" => ["temp", :max])
df.resample("time", "1 month").table { |g| { "n" => g.nrow } }
```

The result's index is the bin labels as a `CATime`, **in time order**, and its
row axis is named after the time column. The time column itself is the index,
not a reduced column.

**Which end names the bin.** With `label: :left` (the default) a bin starts at
its label and holds the times at or after it: `[00:00, 01:00)` is labelled
`00:00`. With `label: :right` a bin ends at its label and holds the times up to
and including it: `(00:00, 01:00]` is labelled `01:00` — the convention for a
value that describes the hour before it:

```ruby
df.resample("time", "1 hour", label: :right).sum   # 01:00 = what fell in the hour up to 01:00
```

`origin:` shifts the bins the way `CATime#floor` does: `"1 hour"` with
`origin: "2024-01-01 00:30"` gives bins at `00:30`, `01:30`, …. Month and year
bins start on the calendar boundary.

**Empty bins.** By default a bin with no rows does not appear. `fill: true`
makes every bin from the first to the last a row; an empty one reduces as an
empty reduction does — `UNDEF` for `mean`, `0` for `count` and `sum` — so "no
data in this hour" stays distinguishable from a mean:

```ruby
df.resample("time", "1 hour", fill: true).mean     # every hour, UNDEF where none
```

**Short bins.** A bin with only some of its readings still reduces. `min_count:`
makes it `UNDEF` below a number of present values — for an hourly mean of
10-minute data that wants all six:

```ruby
df.resample("time", "1 hour", label: :right).mean(min_count: 6)
```

A row whose time is masked belongs to no bin. `resample` builds the bins and
nothing more: it does not interpolate. To bring a series onto a grid of
instants, build the grid with `CArray.time_range` and `align` onto it (§10),
then `fill(name, :linear)` if values should be interpolated.

---

## 10. Combining frames — `join`, `align`, `meld`, `paste`

Join delegates to CArray addressing primitives: the key yields an address
array, and each column is gathered by `project` (length-preserving,
miss → `UNDEF`, [Face](CAFace.md)-preserving).

```ruby
obs.join(meta, on: "station")                    # left join (default)
obs.join(meta, on: "station", how: :inner)       # inner / :outer / :right
```

- **`:left`** (default) keeps every left row; right columns are gathered per
  left row, misses become `UNDEF`.
- **`:inner` / `:outer` / `:right`** set-align both key sets; the aligned key
  values form the `on` column.

N-D columns are gathered correctly (the row address is expanded across the
trailing shape; a missed row comes back fully masked).

**Column-name collisions.** A non-key column present on both sides collides
(the key `on` is kept once, never suffixed). By default both sides are
disambiguated with suffixes — `temp` → `temp_left` / `temp_right`:

```ruby
obs.join(fcst, on: "time")                          # temp_left, temp_right
obs.join(fcst, on: "time", suffixes: ["_obs", "_fcst"])  # name them up front
obs.join(fcst, on: "time", suffixes: false)         # raise on collision instead
```

Pick meaningful `suffixes:` at join time to avoid renaming afterward; or fix
names later with `rename`. `_left`/`_right` read clearer than pandas' `_x`/`_y`.
The same policy governs `paste`.

### As-of join

`join_asof` matches each left row to the **nearest** `other` row by the key —
for irregular time series. `direction:` follows CArray (`:floor` = most recent
at-or-before, `:ceil` = first at-or-after, `:round` = nearest). A row with no
such row in `other` (before the first key under `:floor`, after the last under
`:ceil`) comes back `UNDEF`, and so does a row whose match is farther than
`tolerance:` — use it to refuse a stale match past the end of `other`:

```ruby
obs.join_asof(radar, on: "time", direction: :floor, tolerance: 600)
```

### `align` — conform to a reference key set

`align(key, reference)` is the **asymmetric sibling of `join`** (pandas
`reindex`): it conforms every variable to a **caller-supplied reference** array
of key values. Each column is gathered onto the reference by exact key match;
the aligned key column (or index) *becomes* the reference, and a reference key
absent from the source comes back `UNDEF` in every other column.

CAFrame **measures no interval and generates nothing** — you own the reference
axis. This is the primitive for reindexing to an axis you built (a complete
time grid, a canonical station list, a master key set): supply it as
`reference` and the gaps become `UNDEF` rows carrying only the key.

```ruby
# a 10-minute series with a 40-minute gap (11:40 -> 12:20); reftime is the
# complete 10-minute axis the caller built (e.g. via DateTime arithmetic).
gapped.align("time", reftime)
# => a frame on reftime; the three missing rows carry their time and UNDEF
#    everywhere else. An int column's gaps stay int + UNDEF (no float promotion).
```

`key` may be a column name or the index axis name. `reference` is a `CArray`
(or `Array`); its values are matched against the source key **by value**, so
the types must be comparable — a `DateTime` object key matches by `eql?`/`hash`,
a time / integer key matches natively (and faster).

Because the reference is external, `align` stays a pure gather with no
interpolation or resampling — fill the `UNDEF` gaps afterward with an explicit
step (`fill`, §8, or your own column math on the escaped columns).

### `CAFrame.meld` / `CAFrame.concatenate` — stack rows

Both stack frames along the **row axis** (vertical): same columns, more rows.
They are the **symmetric sibling of `join`** — no frame is privileged — so they
are class methods (mirroring `CArray.meld` / `CArray.concatenate`), not `df.join`.

The pair mirrors the CArray-level taxonomy, and the choice is view vs. eager:

| | result | data types | when to use |
|---|---|---|---|
| `CAFrame.meld` | **view frame** — each column is a `CAMeld` over the inputs, sharing their storage | **must match** per column; a mismatch raises, because a view constructor cannot auto-cast without hiding schema drift | you want the stacked frame to stay connected to its inputs, or you want to avoid the copy |
| `CAFrame.concatenate` | **eager frame** — each column is a materialized entity, independent of the inputs | **promote** to a common type per column | you want a detached result, or the inputs' types differ |

```ruby
CAFrame.meld(jan, feb, mar)          # a view over three months
CAFrame.concatenate(jan, feb, mar)   # an independent frame
CAFrame.meld([jan, feb, mar])        # an Array is accepted too
```

Everything else is shared between the two:

- Columns are **matched by name** (output order follows the first frame); every
  frame must carry the same column-name set, or it raises.
- **Masks are preserved**, and an **N-D column** carries its trailing dimensions
  (which must agree across frames).
- The **index** is stacked the same way as the columns when every frame has one
  (their `axis_name` must agree) — a `CAMeld` view for `meld`, a materialized
  column for `concatenate`. If none of the frames has an index, the result has
  none; a mix raises.
- A single-frame call is not special-cased: `CAFrame.meld(df)` returns a view
  sharing `df`'s columns, `CAFrame.concatenate(df)` returns an independent copy.

Because `meld` shares storage, writes flow **both ways**: writing a row of the
result reaches whichever input frame owns that row, and writing an input reaches
the result. `copy` the result if you want it detached.

Both are deliberately strict (same columns only) — a union-with-`UNDEF` mode is a
possible future opt-in, kept out to stay explicit.

### `paste` — merge columns by position

`paste(other)` puts `other`'s variables **beside** this frame's, matched by
**row position** — a keyless column merge (the column-direction counterpart of
the row-stacking `meld` / `concatenate`, named after the UNIX `paste`; the positional
counterpart of the key-aligned `join`). Both frames must have the same `nrow`;
rows are assumed to already correspond (no key alignment — consistent with the
no-implicit-align stance).

```ruby
obs.paste(fcst)                             # side by side, same rows
obs.paste(fcst, suffixes: ["_obs", "_fcst"])
```

- Colliding column names use the **same suffix policy as `join`** (default
  `_left`/`_right`, `suffixes:` to override, `suffixes: false` to raise).
- This frame's index is kept; `other`'s index (if any) is not carried — only its
  columns are pasted.
- Returns a new frame. Paste three or more by chaining
  (`a.paste(b).paste(c)`).

Use `join` instead when the rows must be **aligned by a key** rather than by
position.

---

## 11. Reshaping — `pivot`, `pivot_grid`, `melt`

Observations often arrive **long**: one row per (time, station) pair. To put
the stations side by side, spread the long frame into a **wide** one with
`pivot`; `melt` goes the other way.

```ruby
long = CAFrame.new(
  "time"    => CA_INT32([2, 1, 1, 2, 3]),
  "station" => CA_OBJECT(["tokyo", "tokyo", "osaka", "osaka", "tokyo"]),
  "temp"    => CA_FLOAT64([20.0, 10.0, 11.0, 21.0, 30.0]),
)

wide = long.pivot(index: "time", columns: "station", values: "temp")
wide.variable_names   # => ["osaka", "tokyo"]
wide.index.to_a       # => [1, 2, 3]
wide["osaka"].to_a    # => [11.0, 21.0, UNDEF]
wide["tokyo"].to_a    # => [10.0, 20.0, 30.0]
```

### `pivot` — long to wide

`pivot(index:, columns:, values:)` makes each distinct value of the `index` key
a row and each distinct value of the `columns` key a column; the cell where
they cross holds `values` from the row that carried that pair.

- Both keys are **sorted ascending**. The `index` key becomes the result's
  index and names its row axis; the `columns` key values become column names
  through `to_s`.
- A pair **no row carries is UNDEF** (osaka at time 3 above), and so is a pair
  whose value is masked. A row whose `index` or `columns` key is masked belongs
  to no cell and is left out.
- `index:` may name the frame's index as well as a column.
- A value column with trailing dimensions keeps them in every output column. A
  Face column (a time column, say) stays that Face, and so does a Face index.
- The result is a **new frame**; it shares no storage with the long one.

`values:` may be an **Array** of column names. Every one is spread over the same
rows and columns, and the output columns are named `"<value>_<label>"`, all of
the first value's columns before the next's:

```ruby
long.pivot(index: "time", columns: "station", values: ["temp", "rh"])
# columns: temp_osaka, temp_tokyo, rh_osaka, rh_tokyo
```

Two output columns that would share a name raise.

**Repeated pairs.** Without `aggregate:`, two rows with the same pair raise —
`pivot` places values, it does not combine them. Pass `aggregate:` with a
reduction name (`:mean`, `:sum`, `:max`, `:count`, …) and every pair holds that
reduction over the rows that carry it:

```ruby
hourly.pivot(index: "day", columns: "station", values: "temp", aggregate: :mean)
```

Masked values are left out of the reduction, as in any reduction, so a pair
whose values are all masked is UNDEF. A pair **no row carries stays UNDEF
whatever the reduction, `:count` included** — "counted none" and "no such pair"
stay distinguishable. `aggregate:` needs one-dimensional value columns.

### `pivot_grid` — the same cells as one CArray

When the next step is array arithmetic rather than named columns,
`pivot_grid` returns the cells as a single CArray, with the two key arrays that
label its axes:

```ruby
temp, times, stations = long.pivot_grid(index: "time", columns: "station",
                                        values: "temp")
temp.shape            # => [3, 2]
stations.to_a         # => ["osaka", "tokyo"]
temp.mean(axis: 0)    # => mean per station: [16.0, 20.0]
```

Axis 0 follows the `index` key and axis 1 the `columns` key; any trailing
dimensions of the value column come after them. Missing pairs, masked keys,
repeats and `aggregate:` behave as in `pivot`, and the grid keeps the value
column's data type, Face included. It takes one value column; call it once per
column for several.

### `melt` — wide to long

`melt` stacks value columns one after another into a single column, with a
column naming where each row came from and the id columns repeated alongside:

```ruby
wide = CAFrame.new("time"  => CA_INT32([1, 2, 3]),
                   "tokyo" => CA_FLOAT64([10, 20, 30]),
                   "osaka" => CA_FLOAT64([11, 21, 31]))

long = wide.melt(id: "time")
long.variable_names     # => ["time", "variable", "value"]
long["variable"].to_a   # => ["tokyo", "tokyo", "tokyo", "osaka", "osaka", "osaka"]
long["value"].to_a      # => [10.0, 20.0, 30.0, 11.0, 21.0, 31.0]
```

- With no `value_columns:`, every column that is not an id is melted.
  `var_name:` and `value_name:` rename the two new columns.
- When the frame has an index, it is carried as an id column named after the
  row axis.
- Masked cells stay masked.
- The result is a **view-frame**: the value column is a `CArray.meld` of the
  melted columns and each id column a `CArray.meld` of itself, so writing the
  result reaches the wide frame. `copy` it if you want it detached.
- Because it is a view, the value columns must share **one data type** and one
  trailing shape. Mixed types raise rather than being promoted silently; `cast`
  them first.

`melt` followed by `pivot` on the same keys gives the wide frame back.

---

## 12. Metadata readers

Each reader returns a **fresh** object — the live columns Hash is never
exposed.

| reader | returns |
|---|---|
| `variable_names` | `Array<String>` of column names, in column order |
| `variables` | `Array<CArray>` of the stored columns themselves, in column order |
| `nvar` | number of columns |
| `nrow` | number of rows (axis-0 length `N`) — backed by a column, or by the index when the frame has no columns |
| `data_types` | `Hash<String, Symbol>` of `name => data_type` |
| `axis_name` | row-axis name (String) |
| `index` | the index `CArray`, or `nil` |

```ruby
df.variable_names        # => ["station", "temp", "wind"]
df.data_types       # => { "station" => :object, "temp" => :float64, "wind" => :float64 }
```

Positional / pattern column selection composes on `variables` rather than
having its own API — e.g. `df.select(*df.variable_names[1..])` or
`df.select(*df.variable_names.grep(/temp/))`.

---

## 13. View, copy, and aliasing

Frame view/copy semantics follow CArray exactly:

| operation | result |
|---|---|
| `df["col"]` | the **stored column** (alias) — writing mutates the frame |
| `df.select(...)` | **view-frame**, columns aliased (zero-copy) |
| `df[0..1]` / `df[bool]` / `df.filter { }` | **view-frame**, columns are row views sharing storage |
| `df.head(n)` / `df.tail(n)` | **view-frame**, as a row slice |
| `df.sort_by_key(...)` / `df.sort_by { }` | **view-frame**, columns are row-gather views in the sorted order |
| `df.filter(keep_masked: true) { }` | a **materialized** frame — columns and index both independent; the carried-forward UNDEF has to be written into the result, which a view cannot do (§6) |
| `df.copy` | an **independent** frame — every column materialized |
| `df.append` / `drop` / `rename` | a **new frame** (column set / names change) — columns shared, cheap; the original is untouched (§8) |
| `df.split_column(...)` | a **new frame** — the other columns shared, the new ones fresh `CAString` columns built from the split column (§2) |
| `df.paste(other)` | a **new frame** — the columns of both frames shared, nothing copied (§10) |
| `df.dup` / `clone` | a **new frame sharing every column and the index** (the CArray `dup` contract: shallow). Adding or dropping a name affects only the copy, but writing a column writes through. For an independent frame use `copy`, not `dup` |
| `df.cast(...)` | **self** — rebinds a fresh column of the new type; does not write through to frames sharing the old column |
| `df.promote(...)` | **self** — same as `cast`, applied to every column (fresh columns, common type) |
| `df.parse_to_time(...)` / `df.to_time(...)` | **self** — as `cast`: rebinds that column to a fresh time column |
| `df.set_index` / `reset_index` | **self** — an index-role change, data unchanged |
| `df.drop` of every column | **a new frame with no columns** — it keeps the index, and with it the row count; `drop` cannot remove the index (§1) |
| `df.mask_eq(...)` / `df.fill(...)` | **write-through self** — mutates the shared column in place, visible through every alias / parent |
| `df["c"] = col` | **self** — binds the name to a different column; a replacement, not an edit, so it does not reach holders of the old one (as `cast`) |
| `df["c"] = nil` | **self** — removes the column from this frame's set |
| `df["c"] = UNDEF` | **write-through self** — masks the stored column in place, visible through every alias |
| `df[sel] = UNDEF` | **write-through self** — masks the selected rows in place; shape unchanged, visible through every derived view |
| `df[sel] = nil` | **self** — rebinds each column to a row-gather view of itself; surviving rows still share storage with the originals (§3) |
| `df[sel] = frame` | **self** — rebuilds each column as a `CAMeld` of [rows before the span, a snapshot of `other`'s column, rows after it]. The spliced span is independent of `other`; the rows on either side still share storage with the original columns (§3) |
| `CAFrame.meld(...)` | a **view-frame** — each column a `CAMeld` over the inputs; writes flow both ways (§10) |
| `CAFrame.concatenate(...)` | an **independent** frame — each column materialized (§10) |
| `df.join(..., how: :left)` / `df.join_asof(...)` | a **new frame, shared on one side only**: this frame's columns and index go in as they are (writing them reaches this frame), while the other frame's columns are gathered copies — a miss has to become UNDEF, which a view cannot express (§10) |
| `df.join(..., how: :inner/:outer/:right)` / `df.align(...)` | a **new frame sharing nothing** — both sides are gathered onto the aligned key, so every column is a copy (§10) |
| `df.pivot(...)` / `df.pivot_grid(...)` | a **new frame** / a **new CArray** sharing nothing — each cell is gathered from the row that carried its pair, and a missing pair has to become UNDEF (§11) |
| `df.melt(...)` | a **view-frame** — the value column is a `CAMeld` of the melted columns and each id column a `CAMeld` of itself, so writes reach this frame; only the column naming the source is new (§11) |
| `grouped.table { \|sub\| }` | each `sub` is a **view-frame** of that group's rows — writing it reaches the grouped frame (§9) |
| `df.each_row` | a Hash of **raw cells** per row: a scalar cell is a Ruby value, an N-D cell is a **live view** of that row's slice (§7) |
| `df.to_records` | plain Ruby Hashes — values normalized (`CArray` -> `Array`, UNDEF -> `nil`), so independent of the frame (§7) |
| `df.to_ca` | a **view** — a `CAStack` of shape `(nrow, nvar)` over the stored columns; writes flow back, `copy` for an owned matrix |

Because view-frames share storage, mutating a view writes through to the
parent — the same aliasing rule as CArray views. When you need an independent
frame, use `copy`:

```ruby
snapshot = df.copy         # independent; later edits to df don't touch it
```

---

## See also

- [What is CArray](../WhatIsCArray.md) — the array type columns are made of.
- [CACategorical](../objects/CACategorical.md) — categorical columns and the group-by
  substrate.
- [CATime](CATime.md) — time columns and time indices.
- [CAFace](CAFace.md) — semantic column types (time / categorical) carried
  through joins and gathers.
- [MemoryView](../interop/MemoryView.md) — zero-copy interchange from an escaped column.
