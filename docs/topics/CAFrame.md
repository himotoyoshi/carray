# A DataFrame built on CArray columns (`CAFrame`)

`CAFrame` is a lightweight DataFrame: a set of **named columns**, each a [`CArray`](../WhatIsCArray.md). The frame adds names on top of the columns and hands the columns back whenever you ask for them, so everything CArray offers (masks, [views](Composition.md), [Face](CAFace.md) types, [MemoryView](../interop/MemoryView.md) interop) applies to them directly.

Four things to know before you start:

- **A column is a `CArray`.** `df["temp"]` is the stored array itself, not a wrapper.
- **Missing values are masked cells.** A column carries its mask as any CArray does, and the frame's verbs follow it. A masked cell reads as `UNDEF`, and assigning `UNDEF` masks a cell.
- **Sub-frames are views, not copies.** `select`, `filter`, `head` and row slices write through to the original frame. `df.copy` makes an independent frame (see [Sub-frames share data](#sub-frames-share-data-with-the-original-frame)).
- **A column can be N-D.** A vector or a profile per row is one column. This is covered in its own chapter, [N-D columns](#n-d-columns); everything before it can be read with ordinary 1-D columns in mind.

```ruby
require "carray"

df = CAFrame.new(
  "station" => CA_OBJECT(["tokyo", "osaka", "tokyo"]),
  "temp"    => CA_FLOAT64([22.1, 25.3, 19.0]),
)

df["temp"]                       # => CArray [22.1, 25.3, 19.0]  (the column itself)
df.select("station", "temp")     # => a sub-frame with two columns
df.filter { |f| f["temp"] > 20 } # => a sub-frame of the matching rows
p df.group_by("station").mean    # per-station means as a new frame
```

```
#<CAFrame nrow=2 columns=[temp:float64] index="station">
station   temp
-------  -----
tokyo    20.55
osaka     25.3
```

### A typical session

The chapters follow the order in which a frame is usually used: read it, look at it, pick rows and columns, fix the columns, aggregate, combine, write it out.

```ruby
df = CAFrame.from_csv("obs.csv", types: { "temp" => :float64 })  # Building a frame
puts df.describe.to_table                                        # Looking at a frame
df.parse_to_time("time").set_index("time")                       # Editing columns, The index
warm  = df.filter { |f| f["temp"] > 20 }                         # Selecting rows
daily = df.resample("time", "1 day").mean                        # Grouping rows
means = df.group_by("station").mean.reset_index
means.join(meta, on: "station").to_csv("summary.csv")            # Combining, Exporting
```

### Contents

1. [The model](#the-model)
2. [Building a frame](#building-a-frame)
3. [Looking at a frame](#looking-at-a-frame)
4. [Getting columns and rows](#getting-columns-and-rows)
5. [Selecting and sorting rows](#selecting-and-sorting-rows)
6. [Editing columns](#editing-columns)
7. [The index](#the-index)
8. [Grouping rows](#grouping-rows)
9. [Combining frames](#combining-frames)
10. [Reshaping](#reshaping)
11. [Exporting](#exporting)
12. [View, copy and sharing](#view-copy-and-sharing)
13. [Read-only frames](#read-only-frames)
14. [N-D columns](#n-d-columns)

---

## The model

A frame holds its data as an ordered Hash of columns, keyed by column name (`name => CArray`).

The one rule is that **every column has the same length `N`**, the number of rows.

```ruby
df = CAFrame.new(
  "temp" => CA_FLOAT64([1.0, 2.0, 3.0]),
  "rh"   => CA_FLOAT64([60.0, 55.0, 70.0]),
)
df.nrow   # => 3
df.ncol   # => 2
```

A column may also have more axes than one; then axis 0 is the row axis and has length `N`, and the axes after it are free. See [N-D columns](#n-d-columns).

A frame holds its columns as CArrays. `df["temp"]` returns the CArray the frame holds for that column, not a copy. Writing to that CArray therefore changes the data of the frame itself. When you build a frame from your own arrays, `CAFrame.new("temp" => t)` stores `t` itself, so writing to `t` also changes the frame.

A frame may also have an **index**: a row-aligned array of labels (times, station names) that is kept beside the columns rather than among them. See [The index](#the-index).

### Sub-frames share data with the original frame

A sub-frame is a frame made from part of another frame. It shares data with the frame it came from in one of two ways:

- `select` picks columns. The sub-frame holds the same column CArrays as the original frame.
- `filter`, `head`, `tail` and a row slice pick rows. Each column of the sub-frame is a CArray view of the original column.

Either way, writing a cell through the sub-frame changes the original frame, and the other way around. Nothing is copied unless you ask: `df.copy` makes a frame whose columns and index are copies.

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

Which operations share and which copy is listed operation by operation in [View, copy and sharing](#view-copy-and-sharing). To make a frame refuse writes altogether, see [Read-only frames](#read-only-frames).

---

## Building a frame

There are three constructors, one per shape the data arrives in:

| the data is… | constructor |
|---|---|
| arrays you already have, one per column | `CAFrame.new` |
| an Array of row Hashes (parsed JSON) | `CAFrame.from_records` |
| a CSV file or IO | `CAFrame.from_csv` |

### `CAFrame.new`

Pass a Hash of `name => column`. Columns may be `CArray`s or anything that answers `to_ca` (a Ruby `Array`, a lazy view). Column names are **Strings** — a Symbol key in a column hash is stringified. Pairs may be given inline:

```ruby
CAFrame.new("a" => CA_INT32([1, 2, 3]), "b" => CA_FLOAT64([1.0, 2.0, 3.0]))

# control options are keyword-separated from columns:
CAFrame.new({ "v" => CA_FLOAT64([1, 2, 3]) },
            axis_name: "time",
            index: CArray.int64([100, 200, 300]))
```

A length disagreement raises immediately:

```ruby
CAFrame.new("a" => CA_INT32([1, 2]), "b" => CA_INT32([1, 2, 3]))
# => ArgumentError: column "b" has axis-0 length 3, expected 2
```

**Note.** The keyword slot doubles as the `axis_name:` / `index:` control channel. Only those two Symbols are recognized there; any other Symbol keyword is rejected rather than taken as a column, so a mistyped control option cannot silently turn into one. String-keyed pairs always go to columns (a String can't be a keyword), so a column named `"index"` or `"axis_name"` is written the ordinary way:

```ruby
CAFrame.new(temp: CA_INT32([1, 2, 3]))          # ArgumentError (stray Symbol keyword)
CAFrame.new("index" => CA_INT32([1, 2, 3]))     # a column named "index"
```

### `CAFrame.from_records`

Build a frame from an **Array of row Hashes** — the shape `JSON.parse` yields for a JSON array of objects:

```ruby
records = JSON.parse(File.read("obs.json"))   # => [ {...}, {...}, ... ]
df = CAFrame.from_records(records)
```

A record value is **already a typed Ruby object** (`Float`, `Integer`, `Complex`, `DateTime`, `String`), so `from_records` builds each column from the types of its values. Strings are not parsed: a date written as a string stays a string, and a column of mixed values stays `:object`.

| the column's non-nil values are… | column built as |
|---|---|
| all `Integer` | `:int64` |
| `Integer` and `Float` | `:float64` |
| `Integer`, `Float` and `Complex` | `:cmplx128` |
| strings / `DateTime` / booleans / `Rational` / `BigDecimal` / mixed | `:object` (left as is) |
| numeric **arrays** of one shape | an N-D column (see [Making N-D columns](#making-n-d-columns-from-records)) |

- The column set is the **union of keys** in first-appearance order; keys are stringified (String- or Symbol-keyed records both work).
- A **missing key or `nil`** becomes `UNDEF`. An integer column with a hole stays `:int64` with an `UNDEF` cell — **no promotion to float**: the mask carries the missingness, so there is no need to force the column to float to hold a NaN.
- `types:` casts named columns afterward (the same map / array-key forms as [`cast`](#changing-a-columns-type)), overriding the detected type:

```ruby
df = CAFrame.from_records(records,
                          types: { %w[prefNumber humidity] => :int32 })
```

### `CAFrame.from_csv`

Read a CSV from a path or from an open IO. The header row gives the column names, and every column is read as text (a `CAString`) unless you ask for types:

```ruby
df = CAFrame.from_csv("obs.csv")                                    # every column as text
df = CAFrame.from_csv("obs.csv", types: { "temp" => :float64 })     # temp read as float64
df = CAFrame.from_csv("obs.csv", types: :infer)                     # each column's type inferred
```

With `types: :infer`, each text column is given the type every one of its present cells can be read as — integer, float, boolean, or a time written year first — and stays text otherwise (the rules are under [`infer_types`](#finding-the-types--infer_types)). A time column read this way is already a `CATime`, so it goes straight to `set_index`; `parse_to_time` is for a column still held as text.

An empty cell, or one that cannot be read as the type asked for, becomes `UNDEF`. The other options — missing-value tokens, encodings, header and data lines, reading only some columns — are described in [Reading and writing CSV](CAFrameCSV.md#reading-csv-caframefrom_csv).

### Other formats

Reading other formats — Excel, Parquet, Arrow, SQLite, DuckDB and others — is planned as separate gems that build a frame with these constructors. They will be released one at a time; none is available yet.

---

## Looking at a frame

Right after reading a frame, look at what you got: `p` for a glance, `describe` for a check of every column, and the readers at the end of this chapter for its size, names and types.

### Printing — `p`, `puts`, `to_table`

```ruby
p df                       # summary line + first 8 / last 2 rows
puts df                    # the whole frame
puts df.to_table(rows: 40) # explicit cap, split evenly around the elided middle
```

```
#<CAFrame nrow=1286 columns=[name:object, lat:float64, temp:int32] index="id">
  id  name               lat  temp
----  -----------  ---------  ----
   0  station0          45.0     0
   1  station1     44.999667     1
   2  station2     44.999333     2
   3  station3        44.999     3
   4  station4     44.998667     4
   5  station5     44.998333     5
   6  station6        44.998     6
   7  station7     44.997667     7
   :  :                    :     :
1284  station1284     44.572    10
1285  station1285  44.571667    11
```

**`p df` stays a screenful** (the summary line, then the first 8 and last 2 rows) while **`puts df` prints the whole frame**. Both are built on `to_table`, which takes options:

- `rows:` caps the printed rows (default 20); the elided middle becomes a `:` row, and a footer states the full size. `rows: nil` prints every row.
- `precision:` rounds float cells to that many decimal places **for display only** (default 6), so that one value like `141.67833333333334` does not set the width of the whole column. `precision: nil` prints them as Ruby renders them.
- `index: false` drops the index column.

In the table, numeric columns are right-aligned and everything else left-aligned, and **a masked cell shows as `_`** (the marker CArray's own inspect uses). `to_table` is text to be looked at, not read back — for a file, use [`to_csv`](#csv--to_csv).

### Checking a frame just read — `describe`

`describe` summarizes the columns, **one row per column**, as a new frame indexed by column name — so a wide table stays readable, and the result is an ordinary frame to filter or print:

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

- `type` is the data type, or the Face's class for a Face column. A text column read by `from_csv` shows as `CAString` here, though `data_types` lists it as `:object` (a `CAString` is a Face over object storage).
- `count` and `masked` count cells; `unique` is the number of distinct present values. A `masked` count you did not expect is the usual sign that a column was read with the wrong type.
- `min` / `max` / `mean` / `stddev` apply where the column's kind gives them a meaning and are `UNDEF` elsewhere:
  - real numbers and booleans get all four (a boolean's mean is the share of trues);
  - complex numbers get `mean` and `stddev` (no order, and no `unique`);
  - `CATime` and `CATimedelta` get all four, as times and durations;
  - text, categorical and record columns get the counts only.
- A column with no present cell has `UNDEF` statistics. The index is not a column and is not summarized.

`describe("temp", "rh")` summarizes only the named columns.

### Size, names and types

| reader | returns |
|---|---|
| `nrow` | number of rows `N` (normally the length of the columns; see [A frame with only an index](#a-frame-with-only-an-index) for the exception) |
| `ncol` | number of columns |
| `column_names` | `Array<String>` of column names, in column order |
| `data_types` | `Hash<String, Symbol>` of `name => data_type` |
| `columns` | `Array<CArray>` of the stored columns themselves, in column order |
| `axis_name` | the row-axis name (String); see [The index](#the-index) |
| `index` | the index `CArray`, or `nil` |

```ruby
df.column_names     # => ["station", "temp"]
df.data_types       # => { "station" => :object, "temp" => :float64 }
```

The Arrays and Hashes these readers return are made for each call, so changing one does not change the frame. The CArrays inside them are not copies: `columns` holds the stored columns themselves, and `index` is the stored index.

Positional or pattern selection of columns is done on `column_names` rather than with an API of its own — e.g. `df.select(*df.column_names[1..])` or `df.select(*df.column_names.grep(/temp/))`.

---

## Getting columns and rows

`df[...]` takes a key. A String key returns a column; the other keys select rows:

| key | result |
|---|---|
| `String` ×1 | the column — the `CArray` the frame holds |
| `String` ×2+ | `Array<CArray>` — those columns, in order |
| `Integer` | one row, as a Ruby `Hash` |
| `Range` (integer endpoints) | positional row slice → **sub-frame** |
| boolean `CArray` | row filter → **sub-frame** |
| integer `CArray` | row gather → **sub-frame** |

**What `df[...]` returns is decided by the type of the key alone, never by the values in the frame.**

Besides `df[...]`, this chapter covers `head` / `tail`, `at` (a row by its label), `select` (a frame of some columns) and `each_row`. Writing with `df[...] =` is in [Editing columns](#adding-removing-and-renaming-columns) and [Masking, deleting and splicing rows](#masking-deleting-and-splicing-rows).

### Columns by name

One name gives a bare `CArray`; several give an `Array` of them — the same "one gives an element, several give an array" rule as `ca[i]` and `ca[i..j]`. This makes destructuring natural:

```ruby
df["temp"]                 # => CArray            (one column)
df["temp", "rh"]           # => [CArray, CArray]  (several columns)

t, rh = df["temp", "rh"]   # parallel assignment
```

The returned columns are the **stored arrays**, so writing through one changes the frame — the same write-through rule as any CArray view:

```ruby
t, = df["temp", "rh"]
t[1] = -7.0
df["temp"][1]              # => -7.0
```

`df[...]` never returns a *frame* for String keys — for a frame of some columns, use [`select`](#a-frame-of-some-columns--select). A missing name raises `KeyError`; a key list mixing Strings and other types raises `ArgumentError`.

### One row as a Hash

A single integer returns the row as a Ruby `Hash` (`name => value`), with the index included under the row-axis name when the frame has one. As with `Array#[]`, a negative position counts from the end: `df[-1]` is the last row. A position out of range raises `IndexError`.

```ruby
df[0]
# => { "station" => "tokyo", "temp" => 22.1 }
```

A masked cell comes back as `UNDEF`, **not** `nil`. Test for it with `== UNDEF` — `UNDEF.nil?` is `false`, so `.nil?` misses it:

```ruby
m = CAFrame.new("temp" => CA_FLOAT64([22.1, UNDEF, 19.0]))
m[1]                        # => { "temp" => UNDEF }
m[1]["temp"] == UNDEF       # => true
m[1]["temp"].nil?           # => false  (do not use this to detect missing)
```

### Rows as a sub-frame

A Range, a boolean `CArray` or an integer `CArray` selects **rows** and returns a **sub-frame**; each column is a view sharing storage with the frame it came from:

```ruby
df[0..1]                   # rows 0..1 (positional)
df[df["temp"] > 20]        # boolean row filter
df[CA_INT64([2, 0, 1])]    # integer row gather (reorder / repeat)
```

Ranges are **positional only** — endpoints must be integers, and a non-integer Range raises. To select a range of labels, use [`filter`](#filter--rows-matching-a-condition) with `f.index`.

### First and last rows — `head`, `tail`

`head(n)` and `tail(n)` return the first / last `n` rows as a sub-frame (`n` defaults to 5). `n` larger than `nrow` yields the whole frame; `n` of 0 yields an empty frame; a negative `n` raises.

```ruby
df.head        # first 5 rows
df.tail(3)     # last 3 rows
```

### One row by its label — `at`

`at(label)` returns the single row whose index label equals `label`, as a Ruby `Hash` — the counterpart of `df[i]` that looks the row up by label instead of position. The frame must have an index (see [The index](#the-index)). The label is matched exactly, so any index type works: numbers, strings and other objects, times, categoricals.

```ruby
byname = df.set_index("station")
byname.at("osaka")             # => { "station" => "osaka", "temp" => 25.3 }
```

`at` always returns one row Hash, so it raises when there is not exactly one row to return:

- a frame with no index raises `ArgumentError`;
- a label that is not in the index raises `KeyError`;
- a label that appears **more than once** raises `ArgumentError` (an index is not required to be unique). Use `filter` to get every row with that label, as a frame:

```ruby
df.filter { |f| f.index.eq(label) }   # every row whose label matches
```

**Rows with no label.** An `:outer` / `:right` [`join`](#join--match-rows-by-key) and [`align`](#align--conform-to-a-reference-key-set) can leave a row whose index cell is masked. Such a row has no label, so `at` cannot reach it: `at(UNDEF)` raises `ArgumentError`. (Two undefined labels are not the same label, so there would be no single row to return; `join` and `align` match keys the same way.) Reach those rows by their mask instead:

```ruby
df.filter { |f| f.index.is_masked }   # every row with no label
```

### A frame of some columns — `select`

`select` picks columns and returns a **sub-frame** holding them — the same CArrays the original frame holds. Where `df["a", "b"]` returns the columns as CArrays, `df.select("a", "b")` keeps a frame:

```ruby
sub = df.select("station", "temp")   # => CAFrame with two columns
sub.column_names                     # => ["station", "temp"]
```

`select` **always returns a frame**, even for one name (unlike `df["a"]`):

```ruby
df.select("temp").column_names       # => ["temp"]   (a frame, not a CArray)
```

The requested order becomes the new frame's column order, so `select` also **reorders columns**:

```ruby
df.select("temp", "station").column_names
# => ["temp", "station"]
```

Being a sub-frame, it holds the original's columns — writing through it changes the original. `select` takes no block; to choose rows too, chain `filter`:

```ruby
df.select("station", "temp").filter { |f| f["temp"] > 20 }
```

### One row at a time — `each_row`

```ruby
df.each_row { |r| ... }    # yield each row as a Ruby Hash
df.each_row                # without a block -> Enumerator
```

`each_row` is for the occasional look at single rows. Most work on a frame is done on whole columns, not in per-row loops. Each row is yielded as `df[i]` would return it (a masked cell is `UNDEF`); for rows as plain Ruby values ready to serialize, use [`to_records`](#ruby-records--to_records).

---

## Selecting and sorting rows

### `filter` — rows matching a condition

`filter` selects **rows** with a block that receives the frame and returns a boolean column. The block builds the condition from `f["col"]` (and `f.index`):

```ruby
df.filter { |f| f["temp"] > 24 }
df.filter { |f| (f["temp"] > 24) & (f["rh"] < 50) }   # & / | combine conditions
```

The block lets you refer to columns without binding a variable first, and the result is a sub-frame, so filters chain into `group_by`, `join` and the rest.

Column names are written as `f["..."]` strings, **not** bare identifiers: a frame allows any column name (`"temp.max"`, names with spaces, names that collide with method names), which a `method_missing` DSL cannot support.

The **index** is a row-aligned array like a column, reachable as `f.index`, so **conditions on labels are ordinary column conditions**:

```ruby
df.filter { |f| f.index >= "2024-06-15 01:00" }
df.filter { |f| (f.index >= lo) & (f.index <= hi) }   # a range of labels
```

A comparison between two frames does not fit a block that receives one frame — take the columns out as local variables instead (they are CArrays, so you can name them):

```ruby
diff = df_aws["temp"] - df_gpv["temp"]
```

### Rows whose condition is undetermined — `keep_masked:`

A row is **undetermined** when the value its condition reads is masked, so the condition is neither true nor false for it. By default such a row is **dropped**, exactly as a false row would be. Pass `keep_masked: true` to keep it, masked:

```ruby
df.filter { |f| f["temp"] > 24 }                     # undetermined rows dropped
df.filter(keep_masked: true) { |f| f["temp"] > 24 }  # they survive, masked
```

The surviving undetermined rows arrive with their **data cells masked** and their **index value present**, so the row stays identifiable and a later, better-informed pass can judge it again. Rows whose condition is true carry their values through unchanged either way.

**`keep_masked: true` returns a new frame, not a sub-frame**: a view could not show those rows masked without masking them in the original frame too. This holds whether or not the condition actually has a masked cell, so whether the result shares data never depends on the data.

### `sort_by_key` — reorder rows by key columns

`sort_by_key(*keys, order:, masked_position:)` sorts rows by one or more key columns, the first key deciding first and the next breaking its ties. It returns a sub-frame.

```ruby
df.sort_by_key("temp")                             # one column, ascending
df.sort_by_key("station", "temp")                  # by station, then temp
df.sort_by_key("temp", order: :desc)               # all keys descending
df.sort_by_key(["station", :asc], ["temp", :desc]) # a direction per key
df.sort_by_key("temp", masked_position: :first)    # masked rows first
df.sort_by_key("time")                             # by the index (its axis name)
```

- Each key is a **column name** (or the index's axis name), or a **`[name, :asc | :desc]`** pair. `order:` is the direction for bare-name keys (default `:asc`).
- **`masked_position:`** sends rows whose key is masked to the `:last` (default) or `:first` end.
- Descending order works for **every data type**, not only numbers.

### `sort_by` — sort by a computed key

The block form `sort_by { |f| ... }` is the sorting sibling of `filter`: the block receives the frame and returns a key `CArray` — or an `Array` of them — sorted ascending. Use it for keys that are **computed** rather than a plain column:

```ruby
df.sort_by { |f| (f["temp"] - target).abs }                          # nearest to target first
df.sort_by { |f| f["temp"].order(descending: true, method: :dense) } # a descending key
```

`sort_by` also takes `masked_position:`. For a descending key, use `col.order(descending: true, method: :dense)` as above; it works for any type, where negating a value does not, and it keeps ties as ties when several keys are combined. (`sort_by_key` builds its descending keys the same way.)

---

## Editing columns

### New frame or `self`?

The column verbs split by **what they change**, and that alone decides whether a call returns a new frame or changes `self`:

- Verbs that make the table a **different table** — a different set of columns (`append`, `drop`), different names (`rename`) — return a **new frame** that shares the columns. Chain or reassign: `df = df.append(...).drop(...)`.
- Verbs that **edit a column of the same table** — its mask (`mask_eq`, `fill`), its type (`cast`, `promote`, `parse_to_time`, `to_time`) — and the verbs that choose which column is the index (`set_index` / `reset_index`) return **`self`**.

Whether an edit reaches other frames that share the column depends on the verb:

| verb | returns | reaches frames sharing the column |
|---|---|---|
| `append` / `drop` / `rename` | a new frame | — (this frame is unchanged) |
| `mask_eq` / `fill` | `self` | yes — the stored column is edited |
| `cast` / `promote` / `parse_to_time` / `to_time` | `self` | no — a new column is bound in its place |
| `set_index` / `reset_index` | `self` | — (no cell changes) |

`copy` first when an edit must not reach other frames.

```ruby
# the set of columns or their names change -> new frame (keep the result):
df = df.append("tempF", df["temp"] * 9 / 5.0 + 32) # add a derived column at the end
df = df.drop("raw", "scratch")                      # remove columns (data untouched)
df = df.rename("temp" => "temperature")             # rename, keeping the order

# edit a column of the same table -> self (changes df in place):
df.cast("temp", :float64)                           # change a column's type
df.mask_eq("flag", -999)                            # mask cells equal to a sentinel
df.fill("temp", :linear)                            # fill masked cells
```

### Adding, removing and renaming columns

- **`append(name, col)`** returns a new frame with the column added at the end, or replacing an existing column of that name in place. Its length must be `N`. Only a frame with **no columns and no index** takes `N` from the column appended to it; a frame of zero rows that still has a column or an index requires length 0 (see [A frame with only an index](#a-frame-with-only-an-index)).
- **`drop(*names)`** returns a new frame without those columns. The data is not touched.
- **`rename(old => new, ...)`** returns a new frame with the columns renamed, in the same order.

The same changes can be made to the frame itself with `df["name"] =`:

```ruby
df["temp"] = col      # bind the name to that column (a new name is added)
df["temp"] = nil      # remove the column
df["temp"] = UNDEF    # mask every cell of the column, in place
```

These act on **this** frame only. (Ruby returns the right-hand side as the value of an assignment, so `[]=` has no way to return a new frame the way `append` / `drop` do.) A frame this one was derived from keeps its own columns — each frame has its own set of names.

- **Rebinding is a replacement, not an edit.** `df["a"] = other_col` binds the name to a different column and leaves the old one alone, so frames that hold the old column do not see the change — like `cast` and `promote`, and unlike `fill` or `mask_eq`, which edit the shared column. Rebinding is also where a column enters an existing frame, so this is where its length must equal `nrow` (a frame with no columns and no index takes its `nrow` from the first column assigned).
- **`df["c"] = UNDEF` does reach other frames**, because it masks the stored column in place rather than replacing it.
- A scalar right-hand side is refused (there is no implicit broadcast — write `CArray.float64(df.nrow) { 3 }`), and so is a `CAFrame` (take a column from it, or splice rows with [`df[rows] = other`](#masking-deleting-and-splicing-rows)).
- When the frame has an index, its axis name is not a column name: assigning to it raises and points at `set_index` / `reset_index`.

### Changing a column's type

```ruby
df.cast("temp", :float64)                           # one column
df.cast("temp" => :float64, "rh" => :int32)         # map form: several columns
df.cast(["u", "v"] => :float64)                     # one type shared by several
df.cast(:infer)                                     # the types infer_types finds
df.cast(default: :float64, "station" => nil)        # the rest float64, station as is
df.promote                                          # every column to one common type
df.promote(:object)                                 # ...to the widest type of all
```

**`cast`** binds a new column of the target type in place of the old one, so the change does not reach frames sharing the old column. What it does depends on the column and the target:

- **Text to a number.** A text (object) column, or a string column (`CArray.string`, `CArray.const_string`), is read as decimal numbers: digits with an optional sign, decimal point and exponent (and `nan` / `inf` for floats), surrounding spaces ignored.
  - A cell is data, not a Ruby literal: `"010"` is ten, and `"0x1F"` / `"1_000"` are not numbers.
  - An integer type takes any number whose value is exactly an integer (`"1.0"`, `"1e3"`), decided from the digits so that a long integer is not rounded; `"1.5"` is not an integer.
  - A cell that does not read, or a value the type cannot hold (`"300"` into `:int8`), becomes `UNDEF`.
  - A Ruby number in an object column follows the same rule: an Integer that fits, or a Float, Rational or BigDecimal with no fractional part, is kept, and `2.5` becomes `UNDEF` rather than being truncated — so `"2.5"` and `2.5` in one column agree.
- **Text to `:time`.** `cast(name => :time)` parses a text column into a `CATime` column, as [`parse_to_time`](#time-columns) without a format does.
- **A number to a number**, and other targets, go through `to_type`, an ordinary conversion.

**`on_error:`** decides what an unreadable cell does, for `cast`, `parse_to_time` and `from_csv` alike:

- `:mask` (the default) makes it `UNDEF`;
- `:warn` does the same and warns once per column, with the count and the first few cells;
- `:raise` raises `CAFrame::UnreadableColumn` naming the column, the row and the cell, and rebinds no column.

Blank, `nil` and masked cells are missing values, not errors, under every policy.

```ruby
df.cast("rh" => :int32, on_error: :raise)
# CAFrame::UnreadableColumn: column "rh", row 41 "1.5" cannot be read as int32
```

**`promote`** brings the **whole frame** to one data type, where `cast` forces only the columns you name.

- Without an argument the type is the one `CArray.result_type` picks — the same choice [`to_ca`](#a-matrix--to_ca) makes — so `df.promote` means "make this frame stackable into one matrix". A frame that is already of one type is left alone.
- With an argument, the type must be a **widening** for every column. A narrowing target raises and points at `cast`, the verb for a lossy change. `:object` is the widest type and always accepted, which is how a frame mixing text, Face and numeric columns becomes one type.
- Like `cast`, it binds new columns, so the change does not reach frames sharing the old ones.

**Face columns.** A Face column ([`CATime`](CATime.md), [`CACategorical`](../objects/CACategorical.md), [`CAConstString`](../objects/CAConstString.md)) decides its own conversions, and `cast` / `promote` leave the decision to it: `:object` gives its **surface** values (labels, not codes; `CATime::Element`, not serials), and a numeric target gives whatever the Face declares in `#to_numeric` — a fixed-point column becomes its scaled values, while a Face that declares nothing raises and says so (a time is not a number). The storage underneath is always reachable through `df["name"].parent`. Because the Face decides, the widening rule above applies to plain columns only.

### Finding the types — `infer_types`

`infer_types` returns, for each text column, the type all its present cells can be read as, as a Hash that `cast` takes directly. `cast(:infer)` is `cast(infer_types)`, and `from_csv(types: :infer)` applies it while reading.

```ruby
df.infer_types   # => { "time" => :time, "temp" => :float64, "n" => :int64, "flag" => :boolean }
df.cast(df.infer_types)                           # the same as cast(:infer)
df.cast(df.infer_types.merge("code" => :int32))   # with one type of your own
```

- Only text columns are looked at (object columns, `CAString`, `CAConstString`); a column that already has a type is not listed.
- A column is listed only when **every present cell reads as one type**, tried in this order:
  1. a number: `:int64` when every value is an integer that fits in int64, `:float64` when every value is a number;
  2. `:boolean` when every value is `true` or `false` (in any case);
  3. `:time` when every value is a date or time written year first (`"2024-01-01"`, `"2024-01-01 12:00:00"`, `"2024-01-01T12:00:00.5Z"`), in the finest unit the text shows.
- A column of only `0` and `1` is `:int64`; `cast("name" => :boolean)` makes it boolean.
- Numbers with a leading zero (`"007"`) and integers too long for int64 stay text, since they are usually codes or identifiers.
- Dates written day-first or month-first (`"01/02/2024"`) are not taken as times, since the order cannot be told from the text; use [`parse_to_time`](#text--parse_to_time) with a format or `:infer`.
- Blank, `nil` and masked cells take no part. A column with no present cell is not listed.

### Splitting a text column — `split_column`

`split_column(name, sep, into:)` splits each cell of a text column into several columns:

```ruby
df = df.split_column("code", "-", into: ["kind", "num"])   # "A-12" -> "A", "12"
df.cast("num" => :int32)                                  # the pieces are text
```

- It returns a new frame. The new columns take the place of the old one, which leaves the frame.
- Each cell is split into at most `into.size` pieces. A cell with more separators puts the rest in the last column; a cell with fewer leaves the remaining columns `UNDEF`. A masked cell is `UNDEF` in every new column.
- `sep` is a String or a Regexp, as in `String#split`. A Regexp with a capturing group adds the captured pieces, so write groups as `(?:...)`.
- The new columns are `CAString`; follow with `cast` for numbers.
- Only a 1-D text column can be split. `into:` takes two or more distinct names, none of them an existing column.

### Time columns

Two verbs turn a column into a [time](CATime.md) column, one per kind of input. Each rebinds the column and returns `self`; make it the index with `set_index` afterward.

| the column holds… | verb |
|---|---|
| dates written as text | `parse_to_time` |
| numbers counted from an epoch (netCDF, Excel) | `to_time` |

```ruby
# text -> time
df.parse_to_time("time").set_index("time")      # written year first
df.parse_to_time("time", "%d/%m/%Y")            # an explicit strptime format
df.parse_to_time("time", :infer)                # find the one format it is in
df.parse_to_time("time", :mixed)                # guess at each cell (slow)

# counts since an epoch -> time
df.to_time("t", unit: :h, epoch: "1990-01-01")  # netCDF "hours since 1990-01-01"
df.to_time("t", unit: :day, epoch: "1899-12-30").set_index("t")  # Excel serial date

# the same pair as one value -- a netCDF units attribute goes straight in
df.to_time("t", CATime::Grid.parse("hours since 1990-01-01"))
```

#### Text — `parse_to_time`

`parse_to_time(name, format = nil, unit: nil, on_error: :mask)` parses a column of text: an object `CArray` of Strings, or a `CAString` / `CAConstString` / `CAFixlenString`. A non-text column raises. Choose the second argument by what you know about the text:

- **you know the format** → pass it as a strptime format (`"%d/%m/%Y"`);
- **it is written year first** → pass nothing;
- **it is written in one format, but you do not know which** → `:infer`;
- **each cell is written its own way** → `:mixed`, which guesses per cell and can misread without saying so.

**Without a format**, only text written **year first** is read:

- the date as `YYYY-M-D` or `YYYY/M/D` (month and day with or without a leading zero);
- optionally a time of day after `T` or a space: `h:mm`, `:ss`, a fraction of up to nine digits, or after `T` the hour alone as `hh`;
- optionally a zone: `Z`, `+09:00`, `+0900`, `+09`. A time without a zone is UTC.

A date in another order is not read, because whether `"01/02/2024"` is January or February cannot be told from the text; pass a format, `:infer` or `:mixed` for it.

**`:infer`** finds the one format the column is written in. The first present cell gives the candidate formats (listed in [Formats `:infer` recognizes](#formats-infer-recognizes)), and each later cell drops the candidates it does not fit until one is left — so a later `13/02/2024` settles whether `01/02/2024` is day-first. It raises:

- `CAFrame::UnreadableColumn` when no candidate fits the first cell, when none is left, or when a cell does not fit the chosen format — whatever `on_error` says;
- `CAFrame::AmbiguousTimeFormat` when more than one candidate is left at the end. Its `formats` lists them; pick one and pass it.

`infer_time_format(name)` returns the format `:infer` would choose, so you can write it into your code:

```ruby
df.infer_time_format("date")   # => "%d/%m/%Y"

begin
  df.parse_to_time("date", :infer)
rescue CAFrame::AmbiguousTimeFormat => e
  e.formats                    # => ["%d/%m/%Y", "%m/%d/%Y"]
  df.parse_to_time("date", "%d/%m/%Y")
end
```

**`:mixed`** is for text that is not written in one format, which is broken as data for a machine to read. It guesses at each cell on its own, as `Time.parse` does, so it can read a cell wrongly without saying so: `"01/02/24"` is read as 24 February 2001. It is also much slower.

**The unit.** Without a format, or with `:infer`, the unit is the finest the text shows: `:D` for dates alone, `:s` with a time of day, `:ms` / `:us` / `:ns` for fractions of a second. With a format it is `:s`. `unit:` sets it explicitly, in the spellings `CArray.time` takes (`:s`, `"10 minutes"`, a `CATime::Resolution`).

The inferred unit is the finest **any** cell shows, so one cell with nanoseconds puts the whole column in `:ns`, which spans only the years 1677 to 2262. A date outside that span raises `RangeError` naming the column and the cell, under every `on_error:`, rather than becoming `UNDEF`. Pass a coarser `unit:` (`unit: :us`) to avoid it.

**Other details.** Hour 24 is read only as `24:00:00`, the end of the day (the next midnight); `24:30` does not parse. Missing and unparseable cells become `UNDEF`; `on_error: :warn` / `:raise` report the unparseable ones as [`cast`](#changing-a-columns-type) does.

#### Formats `:infer` recognizes

- Dates day-first or month-first, separated by `/`, `-` or `.`, with four- or two-digit years.
- Month names, as in `Jan 2, 2024` or `2 Jan 2024`.
- `YYYYMMDD`.
- Each with an optional time: `h:mm`, `h:mm:ss`, a fraction of a second, or `AM` / `PM`; and an optional zone: `+0900`, `+09:00`, `+09`, `Z`, `UTC` or `GMT`.
- Japanese dates `2024年1月2日`, with an optional `3時4分`, `3時4分5秒` or `3:04` time.

A zone named after a place (`JST`, `CST`) is not a candidate, since some of those names mean different offsets in different places.

#### Counts since an epoch — `to_time`

`to_time(name, grid = nil, unit:, epoch: nil)` reads an integer column as counts of `unit` since `epoch` (default the Unix epoch).

- `epoch` takes any time literal (String / `Time` / Integer), so columns measured from another origin convert directly.
- A float column is accepted only when every value is whole; a fractional value raises `CAFrame::UnreadableColumn` (use a finer `unit`). A non-numeric column raises.
- A [`CATime::Grid`](CATime.md) carries the (unit, epoch) pair as one value, passed positionally or as `unit:`, so a netCDF `units` attribute needs no taking apart. It also keeps a time of day in the epoch that the keyword form loses: the keyword `epoch` is read on the `unit` grid, so `unit: :D, epoch: "1980-01-01 12:00"` drops the 12:00, while `CATime::Grid.parse("days since 1980-01-01 12:00")` keeps it.

### Masking and filling cells

**`mask_eq(name, value)`** masks the cells of a column equal to `value` — a sentinel such as `-999` that a file uses for "missing". It edits the stored column in place, so the change reaches every frame sharing it.

**`fill(name, method)`** fills the masked cells of a column **in place**, returning `self`:

```ruby
df.fill("temp", :ffill)     # forward-fill: carry the last present value
df.fill("temp", :bfill)     # back-fill: carry the next present value
df.fill("temp", :linear)    # linear interpolation between present values
df.fill("temp", 0.0)        # a constant
```

- **`:ffill` / `:bfill`** carry the nearest present value; leading cells (for `:ffill`) or trailing cells (for `:bfill`) with nothing to carry stay masked. Works for any column type.
- **`:linear`** interpolates a numeric column **against the frame's index** when one is set (a time index gives interpolation in time), and against the row position when there is no index. With an index that is neither numeric nor a time (station names, say), it raises rather than falling back to the row position; to interpolate by position there, use `df["temp"].unmask(method: :linear)` on the column directly. Cells outside the range of present values stay masked; a column with fewer than two present cells is left unchanged.
- **A value** fills every masked cell with that constant.

A [categorical](../objects/CACategorical.md) column's codes are read-only, so `mask_eq` and `fill` raise on one. Bind a new column instead: `df = df.append("s", df["s"].strip_mask(method: :forward))`.

### Masking, deleting and splicing rows

`df[sel] =` with a row selector acts on rows. The **right-hand value** chooses the operation:

| `df[sel] = ` | operation |
|---|---|
| `UNDEF` | **mask** the selected rows across every column, in place |
| `nil` | **delete** the selected rows — the frame shrinks |
| a `CAFrame` | **splice**: replace the selected contiguous rows with its rows |

```ruby
df[2..3]            = UNDEF   # mask rows 2 and 3 (every column)
df[df["temp"] < 0]  = UNDEF   # mask by condition
df[2..3]            = nil     # delete rows 2 and 3
df[df["temp"] < 0]  = nil     # delete by condition
df[2..3]            = other   # replace rows 2..3 with other's rows (any number)
df[6...6]           = other   # an empty span at the end -> append other's rows
```

`sel` is classified exactly as a key for a 1-D column is ([Indexer decision tree](Indexer_decision_tree.md)): a slice (`Range` / `ArithmeticSequence` / `[start, count, step]`), a boolean `CArray`, an integer `CArray`, or an `Integer`.

- **Mask and delete** accept any of them (they are passed on to the column's indexer, so their errors are CArray's).
- **Splice** needs a contiguous span, so it takes an `Integer` or a slice with step 1; a strided or scattered selector raises.

What each form does:

- **`= UNDEF`** masks the stored cells, so the shape is unchanged and the index is kept — the masked rows stay identifiable, and every view derived from the frame sees the change.
- **`= nil`** keeps the remaining rows in order and shrinks the index with them.
- **`= other`** works like Ruby's `Array#[]=` splice: `other` may have **any number of rows**, so the number of rows changes. Its **set of columns must match exactly**. When the frame has an index, `other` must have one too (its rows need labels), and the indexes are woven together.

To drop rows **without** changing the frame in place, take a filtered sub-frame instead — `df[mask]` or `filter` return a new frame and leave this one as it is.

> **What happens to shared storage.** In short: after a delete or a splice, the rows that remain still share storage with the original columns; `copy` gives an independent frame. In detail:
>
> - `= UNDEF` masks **in place**, so every alias and derived view sees the change.
> - `= nil` rebinds each column to a **row-gather view of its former self** (`col[keep]`), so the remaining rows **still share storage with the original columns**: writing through the frame after a delete reaches a column taken out before it, and the other way around. Nothing is copied; the original full-length buffers stay alive behind the views, so `copy` if you want to free them.
> - `= other` rebuilds each column with `CArray.meld` of three pieces: a view of the rows before the span, a **snapshot** of `other`'s column, and a view of the rows after it.
>   - The **spliced rows are independent of `other`**: writing them never reaches `other`, and `other`'s later writes never reach the frame. This holds **even when `other` has as many rows as the span** — splicing changes the frame's structure and always takes a snapshot, unlike CArray's element write `ca[sel] = other`. (If it wrote through only when the counts matched, the same expression would copy or not depending on the number of rows.)
>   - The **rows outside the span still share storage with the original columns**, as with `= nil`. A column taken out before the splice keeps its own length and its own values in the replaced span, but writes to the rows on either side of the span go both ways. `copy` the result to detach it.

---

## The index

The index is an array of **row labels** — times, station names, ids — kept beside the columns. You need one for:

- looking up a row by label with [`at`](#one-row-by-its-label--at);
- conditions on labels in [`filter`](#filter--rows-matching-a-condition) (`f.index`);
- interpolating in time with [`fill(name, :linear)`](#masking-and-filling-cells);
- labelling the rows of a grouped result — [`group_by`](#grouping-rows) and [`resample`](#time-bins--resample) make the group key the index.

The index is not a column: `df["time"]` does not reach it (it raises `KeyError`), and `drop` does not remove it. Its name is the frame's **`axis_name`**, the name of the row axis (`"row"` by default); it is the key the index appears under in a row `Hash`, and the first column `to_csv` writes. Because of that, while the frame has an index, its axis name cannot also be a column name: building such a frame, or `append` of a column with that name, raises `ArgumentError`.

### `set_index` / `reset_index`

```ruby
df.set_index("time")       # move the column "time" to the index (changes df)
df.reset_index             # move the index back to a column at the front (changes df)
df.index                   # the index CArray (or nil)
df.axis_name               # the row-axis name
```

`set_index` renames the row axis after the column it moves, since that is the name the index then appears under. `reset_index` is its inverse, and puts the earlier name back:

```ruby
df = CAFrame.new({ "t" => …, "v" => … }, axis_name: "obs")
df.set_index("t").axis_name    # => "t"
df.reset_index.axis_name       # => "obs"
```

A frame **built** with an index (`CAFrame.new(..., index:)`) had no axis name before it, so there is nothing to put back and `reset_index` leaves the default `"row"`. A frame derived from an indexed one — a row slice, `filter`, `copy` — behaves the same way.

**Re-indexing.** `set_index` on a frame that **already has an index** replaces it, and the old index goes back to being a column at the front, just as `reset_index` would put it. So re-indexing loses no column: `set_index("b")` on a frame indexed by `"a"` is the same as `reset_index` followed by `set_index("b")`:

```ruby
df.set_index("a")
df.set_index("b")
df.column_names     # => ["a", "v"]   -- "a" is a column again, not lost
df.reset_index      # => axis_name "obs" again, column_names ["b", "a", "v"]
```

### A frame with only an index

`nrow` is read off something the frame holds: a column, or the index. So a frame may have an index and **no columns** and still have `N` rows:

```ruby
CAFrame.new({}, index: CA_INT32([10, 20, 30]), axis_name: "t").nrow   # => 3
```

You usually reach one by dropping every column of an indexed frame. Such a frame works as any other — `at`, `filter`, `head`, `sort_by_key`, `align`, `copy`, `to_csv` and `to_records` carry the index as they would carry a column. Only `to_ca` fails, having no column to stack.

When a frame has **neither columns nor an index**, nothing holds the row count any more, and `nrow` is 0. The next column assigned then sets `N` afresh — which may be a different number from before:

```ruby
df = CAFrame.new("a" => CA_INT32([1, 2, 3]))   # no index
e  = df.drop("a")
e.nrow                                         # => 0   -- nothing holds 3 any more
e.append("b", CArray.int32(99).seq!).nrow      # => 99  -- the new column sets N
```

A frame that still has its index refuses that column (`column "b" has axis-0 length 99, expected 3`). Keep an index, or rebuild with `CAFrame.new`, when the old length should be enforced.

---

## Grouping rows

`group_by` groups **rows** by one or more keys and returns a `GroupedFrame`; a reduction on it gives one row per group:

```ruby
p df.group_by("station").mean
```

```
#<CAFrame nrow=2 columns=[temp:float64] index="station">
station   temp
-------  -----
tokyo    20.55
osaka     25.3
```

`resample` does the same with time bins as the groups (see [Time bins](#time-bins--resample)).

### Keys and groups

The key is a column name, several names (a composite key), or a `CArray` of one value per row.

```ruby
grp = df.group_by("station")
grp.ngroup                 # => number of groups
grp.labels                 # => group key values, in code order
```

- **The result's index** is the group's key value. With a single key it keeps the key's data type and Face — an integer key gives an integer index, a `CATime` key a `CATime` index — so the result can be joined or aligned on it. A composite key gives an object index of the key tuples.
- **Groups appear in the order their keys first appear.**
- **A row whose key is masked belongs to no group**, as `filter` drops a row whose condition is undetermined. With a composite key, one masked component is enough. So the group sizes need not add up to `nrow` — count the masked keys (`df["k"].count_masked`) to account for the difference, or fill them first (`df.fill("k", value)`) to group them together.
- **When things are read.** The grouping and its labels are fixed when `group_by` is called: changing a key afterwards does not move rows between groups. The **values** are read when a reduction is called, so a reduction after `df["v"][i] = x` sees the new value, in the group the row had when `group_by` was called. Group again after changing a key.

### Choosing a reduction

A `GroupedFrame` offers four ways to reduce. Choose by what you need:

| you need… | use |
|---|---|
| the same reduction for every column | [`sum` / `mean` / `min` / `max`](#the-same-reduction-for-every-column) |
| a reduction, or an output name, of your own for each column | [`aggregate`](#a-reduction-per-column--aggregate) |
| a computation that combines several columns | [`table`](#computing-across-columns--table) |
| one column, with any reduction the categorical iterator offers | [`grp["col"]`](#one-column--the-group-iterator) |

### The same reduction for every column

`sum` / `mean` / `min` / `max` reduce **every column whose type has that reduction** into a new frame indexed by the group labels. A time column has a mean, a minimum and a maximum but no sum; a string column a minimum and a maximum only; a boolean column all four. A column whose type lacks the reduction is left out. The **key columns are skipped** — they are the result's index.

```ruby
df.group_by("station").mean       # => frame of per-station means
```

Each takes `min_count:` and `fill_value:`, as a CArray reduction does: a group with fewer than `min_count` present values is `UNDEF`, and `fill_value` fills the `UNDEF` cells:

```ruby
df.group_by("station").mean(min_count: 20)                  # too few readings -> UNDEF
df.group_by("station").sum(min_count: 1, fill_value: 0.0)
```

### A reduction per column — `aggregate`

Map each output name to `[input_column, reduction]`. The reduction is a **Symbol** (a vectorized reduction) or a **Proc** (called with each group's slice of the column, for any computation):

```ruby
df.group_by("station").aggregate(
  "temp_mean" => ["temp", :mean],
  "temp_max"  => ["temp", :max],
  "temp_rng"  => ["temp", ->(c) { c.max - c.min }],
)
# => columns temp_mean / temp_max / temp_rng, index = station labels
```

A Symbol reduction takes its arguments after it, as in a call, with keywords last: `"temp_p90" => ["temp", :percentile, 90.0]`, `"temp_mean" => ["temp", :mean, min_count: 20]`.

### Computing across columns — `table`

When a reduction of one column at a time is not enough, `table` yields **each group as a sub-frame** and collects the Hash the block returns, column by column, into a new frame. The full frame API works on `g`:

```ruby
df.group_by("station").table do |g|
  { "n" => g.nrow, "tmax" => g["temp"].max }
end
```

### One column — the group iterator

`grp["col"]` gives the [`CACategoricalIterator`](CACategoricalIterator.md) for one column, so every per-group reduction the iterator offers is available. The result is a `CArray`, not a frame:

```ruby
df.group_by("station")["temp"].mean    # => per-group means as a CArray
```

### Time bins — `resample`

`resample(name, unit)` groups the rows into **time bins** of length `unit` along a time column (or the time index). It returns a `GroupedFrame`, so every reduction above applies:

```ruby
df.resample("time", "1 hour").mean
df.resample("time", "1 day").aggregate("rain" => ["rain", :sum], "tmax" => ["temp", :max])
df.resample("time", "1 month").table { |g| { "n" => g.nrow } }
```

The result's index is the bin labels as a `CATime`, **in time order**, and its row axis is named after the time column. The time column itself becomes the index, not a reduced column.

**Which end names the bin.** With `label: :left` (the default) a bin starts at its label and holds the times at or after it: `[00:00, 01:00)` is labelled `00:00`. With `label: :right` a bin ends at its label and holds the times up to and including it: `(00:00, 01:00]` is labelled `01:00` — the usual convention for a value that describes the hour before it, such as hourly precipitation:

```ruby
df.resample("time", "1 hour", label: :right).sum   # 01:00 = what fell in the hour up to 01:00
```

With readings every 30 minutes, the two labellings put the rows in different bins:

```
time   rain     label: :left (sum)              label: :right (sum)
00:00   1.0     00:00   3.0  (00:00, 00:30)     00:00   1.0  (00:00)
00:30   2.0     01:00   7.0  (01:00, 01:30)     01:00   5.0  (00:30, 01:00)
01:00   3.0     02:00   5.0  (02:00)            02:00   9.0  (01:30, 02:00)
01:30   4.0
02:00   5.0
```

**Shifting the bins.** `origin:` shifts them as `CATime#floor` does: `"1 hour"` with `origin: "2024-01-01 00:30"` gives bins at `00:30`, `01:30`, …. Month and year bins start on the calendar boundary.

**Empty bins.** By default a bin with no rows does not appear. `fill: true` makes every bin from the first to the last a row; an empty one reduces as an empty reduction does — `UNDEF` for `mean`, `0` for `count` and `sum` — so "no data in this hour" stays distinguishable from a mean:

```ruby
df.resample("time", "1 hour", fill: true).mean     # every hour, UNDEF where none
```

**Short bins.** A bin with only some of its readings still reduces. `min_count:` makes it `UNDEF` below a number of present values — for an hourly mean of 10-minute data that wants all six:

```ruby
df.resample("time", "1 hour", label: :right).mean(min_count: 6)
```

A row whose time is masked belongs to no bin. `resample` builds the bins and nothing more: it does not interpolate. To bring a series onto a grid of instants, build the grid with `CArray.time_range` and [`align`](#align--conform-to-a-reference-key-set) onto it, then `fill(name, :linear)` if values should be interpolated.

---

## Combining frames

How the rows of the frames are put together decides the verb:

| rows are put together | verb |
|---|---|
| matched by a key in both frames | `join` (`join_asof` for the nearest key) |
| matched by a key against a reference you supply | `align` |
| one frame's rows after another's | `CAFrame.meld` / `CAFrame.concatenate` |
| the same rows, with columns side by side | `paste` |
| the same rows, as layers | `CAFrame.stack` — see [Layers](#layers--caframestack--unstack) |

### `join` — match rows by key

```ruby
obs.join(meta, on: "station")                    # left join (default)
obs.join(meta, on: "station", how: :inner)       # :inner / :outer / :right
```

Choose `how:` by which rows you want to keep:

- **`:left`** (default) — add the other frame's columns to a table you keep as it is, e.g. station metadata added to observations. Every left row stays; a row with no match gets `UNDEF` in the new columns.
- **`:inner`** — only rows whose key is in both frames.
- **`:outer`** — every row of both, e.g. to see which keys each side is missing.
- **`:right`** — every row of the other frame; it is the reference.

The key stays a column, and the result keeps the left frame's index:

| `how:` | rows kept | index | a row only on the right |
|---|---|---|---|
| `:left` (default) | every left row | the left index | — |
| `:inner` | rows on both sides | the left index | — |
| `:outer` | every row of both | the left index | its index is masked |
| `:right` | every right row | the left index | its index is masked |

For `:inner`, `:outer` and `:right`, the key values of both sides are aligned into one set, which becomes the `on` column.

The key must be one value per row; an N-D column cannot be a key for `join`, `join_asof` or `align` (take a component, `df["wind"][nil, 0]`, as a column first).

**Column-name collisions.** A non-key column present on both sides collides (the key `on` is kept once, never suffixed). By default both sides get a suffix — `temp` → `temp_left` / `temp_right`:

```ruby
obs.join(fcst, on: "time")                               # temp_left, temp_right
obs.join(fcst, on: "time", suffixes: ["_obs", "_fcst"])  # name them up front
obs.join(fcst, on: "time", suffixes: false)              # raise on collision instead
```

Choosing meaningful `suffixes:` at join time saves a `rename` afterward. `paste` follows the same rule.

### `join_asof` — the nearest key

`join_asof` matches each left row to the **nearest** row of the other frame by the key — for time series observed at different times. `direction:` says which row:

- `:floor` — the latest at or before;
- `:ceil` — the first at or after;
- `:round` — the nearest.

A row with no such row (before the first key under `:floor`, after the last under `:ceil`) gets `UNDEF`, and so does a row whose match is farther than `tolerance:` — use it to refuse a stale match past the end of the other frame:

```ruby
obs.join_asof(radar, on: "time", direction: :floor, tolerance: "10 minutes")
```

- **`tolerance:` is the same kind of quantity as the key.** For a numeric key it is a number (`tolerance: 0.5`). For a time key it is a duration: a String in the spellings `CArray.time(unit:)` takes (`"10 minutes"`), or a `CATimedelta` value (`CATimedelta::Element.new(600, :s)`). A bare number is refused for a time key, since its length would depend on the unit the column is stored in; a duration means the same length whatever that unit is.
- Neither frame needs to be sorted by the key; the result keeps the left frame's row order.
- `on:` must name a column in both frames; the index cannot be the key (unlike `align`). `reset_index` first if the key is the index.
- Like a `:left` `join`, the result shares this frame's columns and index; the other frame's columns are gathered into new arrays.

### `align` — conform to a reference key set

`align(key, reference)` conforms every column to a **reference array of key values that you supply** — the one-sided sibling of `join` (pandas `reindex`). Each column is gathered onto the reference by exact key match; the key column (or the index) **becomes** the reference, and a reference key absent from the frame comes back as a row that has only its key, `UNDEF` everywhere else.

`align` measures no interval and generates nothing — you build the reference axis: a complete time grid, a canonical station list, a master key set. That is how gaps in a series become visible as rows:

```ruby
# a 10-minute series with a 40-minute gap (11:40 -> 12:20); reftime is the
# complete 10-minute axis, built with CArray.time_range.
gapped.align("time", reftime)
# => a frame on reftime; the three missing rows carry their time and UNDEF
#    everywhere else. An int column's gaps stay int + UNDEF (no float promotion).
```

- `key` may be a column name or the index's axis name.
- When a key value appears more than once in the frame, the **first** row with it is taken.
- `reference` is a `CArray` (or `Array`). Its values are matched against the key **by value**, so the types must be comparable: a `DateTime` object key matches by `eql?` / `hash`, a time or integer key natively (and faster).
- `align` only gathers; it does not interpolate or resample. Fill the gaps afterward with [`fill`](#masking-and-filling-cells) or your own column arithmetic.

### `CAFrame.meld` / `CAFrame.concatenate` — rows after rows

Both put frames one after another along the **row axis**: the same columns, more rows. No frame is privileged, so they are class methods, like `CArray.meld` / `CArray.concatenate`. Choose by whether the result should stay connected to its inputs:

| | result | data types | when to use |
|---|---|---|---|
| `CAFrame.meld` | **sub-frame** — each column is a view over the inputs, sharing their storage | **must match** column by column; a mismatch raises (a view cannot convert types without hiding a change of schema) | to stay connected to the inputs, or to avoid the copy |
| `CAFrame.concatenate` | **new frame** — independent of the inputs | **promoted** to a common type per column | for a detached result, or when the inputs' types differ |

```ruby
CAFrame.meld(jan, feb, mar)          # a view over three months
CAFrame.concatenate(jan, feb, mar)   # an independent frame
CAFrame.meld([jan, feb, mar])        # an Array is accepted too
```

Both follow the same rules:

- Columns are **matched by name**, in the first frame's order; every frame must have the same set of column names, or it raises. (A mode that fills missing columns with `UNDEF` may be added as an option later.)
- **Masks are kept.**
- The **index** is joined the same way as the columns when every frame has one (their axis names must agree). If none has one, the result has none; a mix raises.
- One frame is not a special case: `CAFrame.meld(df)` returns a view sharing `df`'s columns, `CAFrame.concatenate(df)` an independent copy.
- A frame with **no rows** adds no values, so its data types take no part: a header-only CSV reads as object columns, and joined to a typed frame it neither makes `meld` refuse nor turns `concatenate`'s columns into object. It still needs the same columns, and an index exactly when the others have one.

Because `meld` shares storage, writes go **both ways**: writing a row of the result reaches the input frame that owns the row, and writing an input reaches the result. `copy` the result to detach it.

### `paste` — columns side by side

`paste(other)` puts `other`'s columns **beside** this frame's, matched by **row position** — the positional counterpart of `join`, named after the UNIX `paste`. Both frames must have the same `nrow`, and their rows are taken to correspond already; nothing is aligned.

```ruby
obs.paste(fcst)                             # side by side, same rows
obs.paste(fcst, suffixes: ["_obs", "_fcst"])
```

- Colliding names follow the **same suffix rule as `join`**.
- This frame's index is kept; `other`'s index, if any, is not carried.
- Returns a new frame. Paste three or more by chaining: `a.paste(b).paste(c)`.

Use `join` instead when the rows must be **matched by a key**.

---

## Reshaping

Observations often arrive **long**: one row per (time, station) pair. To put the stations side by side, spread the long frame into a **wide** one with `pivot`; `melt` goes the other way.

```ruby
long = CAFrame.new(
  "time"    => CA_INT32([2, 1, 1, 2, 3]),
  "station" => CA_OBJECT(["tokyo", "tokyo", "osaka", "osaka", "tokyo"]),
  "temp"    => CA_FLOAT64([20.0, 10.0, 11.0, 21.0, 30.0]),
)

wide = long.pivot(index: "time", columns: "station", values: "temp")
wide.column_names     # => ["osaka", "tokyo"]
wide.index.to_a       # => [1, 2, 3]
wide["osaka"].to_a    # => [11.0, 21.0, UNDEF]
wide["tokyo"].to_a    # => [10.0, 20.0, 30.0]
```

### `pivot` — long to wide

`pivot(index:, columns:, values:)` makes each distinct value of the `index` key a row and each distinct value of the `columns` key a column; the cell where they cross holds the `values` cell of the row that has that pair.

- `index:` may name the frame's index as well as a column.
- Both keys are **sorted ascending**. The `index` key becomes the result's index and names its row axis; the `columns` key values become column names through `to_s`.
- A pair **no row has is `UNDEF`** (osaka at time 3 above), and so is a pair whose value is masked. A row whose `index` or `columns` key is masked belongs to no cell.
- A Face column (a time column, say) stays that Face, and so does a Face index.
- It is a **new frame**; it shares no storage with the long one.

`values:` may be an **Array** of column names. Each is spread over the same rows and columns, and the output columns are named `"<value>_<label>"`, all of the first value's columns before the next's:

```ruby
long.pivot(index: "time", columns: "station", values: ["temp", "rh"])
# columns: temp_osaka, temp_tokyo, rh_osaka, rh_tokyo
```

Two output columns that would share a name raise.

#### Repeated pairs — `aggregate:`

`pivot` places values; it does not combine them, so two rows with the same pair raise. Pass `aggregate:` with a reduction name (`:mean`, `:sum`, `:max`, `:count`, …) and each cell holds that reduction over the rows that have its pair:

```ruby
hourly.pivot(index: "day", columns: "station", values: "temp", aggregate: :mean)
```

Masked values are left out of the reduction, as in any reduction, so a pair whose values are all masked is `UNDEF`. A pair **no row has stays `UNDEF` whatever the reduction, `:count` included** — "counted none" and "no such pair" stay distinguishable.

### `pivot_grid` — the same cells as one CArray

When the next step is array arithmetic rather than named columns, `pivot_grid` returns the cells as a single CArray, with the two key arrays that label its axes:

```ruby
temp, times, stations = long.pivot_grid(index: "time", columns: "station",
                                        values: "temp")
temp.shape            # => [3, 2]
stations.to_a         # => ["osaka", "tokyo"]
temp.mean(axis: 0)    # => mean per station: [16.0, 20.0]
```

Axis 0 follows the `index` key and axis 1 the `columns` key. Missing pairs, masked keys, repeats and `aggregate:` behave as in `pivot`, and the grid keeps the value column's data type, Face included. It takes one value column; call it once per column for several.

### `melt` — wide to long

`melt` stacks value columns one after another into a single column, with a column naming where each row came from and the id columns repeated alongside:

```ruby
wide = CAFrame.new("time"  => CA_INT32([1, 2, 3]),
                   "tokyo" => CA_FLOAT64([10, 20, 30]),
                   "osaka" => CA_FLOAT64([11, 21, 31]))

long = wide.melt(id: "time")
long.column_names       # => ["time", "variable", "value"]
long["variable"].to_a   # => ["tokyo", "tokyo", "tokyo", "osaka", "osaka", "osaka"]
long["value"].to_a      # => [10.0, 20.0, 30.0, 11.0, 21.0, 31.0]
```

- With no `value_columns:`, every column that is not an id is melted. `var_name:` and `value_name:` rename the two new columns.
- When the frame has an index, it is carried as an id column named after the row axis.
- Masked cells stay masked.
- **The result is a sub-frame**: its value column is a view of the melted columns, so writing the result reaches the wide frame. `copy` it to detach it.
- Because it is a view, the value columns must share **one data type**. Mixed types raise rather than being promoted silently; `cast` them first.

`melt` followed by `pivot` on the same keys gives back the wide frame's values and column names. The id column comes back as the index, and the value columns in ascending order of their names.

---

## Exporting

| you want… | use |
|---|---|
| Ruby values, e.g. for JSON | `to_records` |
| a CSV file or String | `to_csv` |
| one numeric matrix for array work | `to_ca` |

### Ruby records — `to_records`

```ruby
df.to_records              # rows as an Array of plain Ruby Hashes
JSON.generate(df.to_records)          # -> a JSON array of objects
CAFrame.from_records(df.to_records)   # the same names, values and mask
```

`to_records` gives the rows as an `Array` of Hashes, **normalized for export**: a masked cell (`UNDEF`) becomes `nil`, and every value is a plain Ruby value. That normalization — which `each_row` does *not* do — is what lets `JSON.generate` serialize it and `from_records` read it back.

A record carries only Ruby values, so this is what a round trip keeps:

| | after `from_records(df.to_records)` |
|---|---|
| column names and their order | kept |
| every cell's value | kept |
| the mask | kept — `nil` is read back as `UNDEF` |
| the data type | rebuilt from the values: any integer column comes back `int64`, a `float32` column `float64`, a boolean column an object column of `true` / `false`, a time or string column an object column of its elements |
| the index | not kept — it comes back as an ordinary first column (call `set_index` again) |
| the columns of a frame with no rows | not kept — `to_records` gives `[]`, which has no names in it |

When the types matter, read back with `types:` or `cast` afterwards; to keep the types and the index together, use `to_csv` / `from_csv` with `types:`.

**`nil` and `UNDEF` become the same thing on the way out.** In memory they are distinct — a masked cell is `UNDEF`, and an object column can hold a genuine Ruby `nil` as a value. Neither `to_records` nor `to_csv` keeps them apart: both write either one as missing, and both read missing back as `UNDEF`. So a `nil` held as a value in an object column comes back masked.

### CSV — `to_csv`

`to_csv` writes the frame as CSV, to a file or as a String:

```ruby
df.to_csv("out.csv")       # write a CSV file, returns self
csv = df.to_csv            # no path -> return the CSV String
```

The index, when there is one, is written as the first column. A masked cell is written as an empty field, which `from_csv` reads back as masked. Every column must be 1-D. The options — separators, encodings, missing-value tokens — are described in [Reading and writing CSV](CAFrameCSV.md#writing-csv-to_csv).

### A matrix — `to_ca`

`df.to_ca` gives the `(nrow, ncol)` matrix, one matrix column per frame column, in column order. It is a view: no data is copied, and writes reach the columns.

```ruby
m = df.to_ca                # (nrow, ncol) view, no data copied
m[0, 1] = 99.0              # writes go back into the column
owned = df.to_ca.copy       # an independent matrix
```

- Columns of different numeric types are read at a common type.
- Columns with no common type — text or Face columns beside numeric ones — raise. `df.promote(:object).to_ca` gives an object matrix of their values.
- `to_ca(writable: true)` asks for a matrix whose writes are sure to reach the columns. It raises when a column is read-only or is read at a promoted type, since a write there would not reach the stored value. `df.promote.to_ca(writable: true)` converts the columns first, so it passes.

`CArray.tabulate(df.columns)` builds an independent matrix directly.

---

## View, copy and sharing

This chapter lists, for each operation, what it returns and whether that shares data with the frame it came from. `copy` gives a frame that shares nothing with the original:

```ruby
snapshot = df.copy         # independent; later edits to df don't touch it
```

**Sub-frames** — share the data; writing one reaches the frame it came from, and the other way around:

| operation | see |
|---|---|
| `df.select(...)` — the same column CArrays | [select](#a-frame-of-some-columns--select) |
| `df[0..1]` / `df[bool]` / `df[ints]` / `df.filter { }` — views of the selected rows | [Rows as a sub-frame](#rows-as-a-sub-frame), [filter](#filter--rows-matching-a-condition) |
| `df.head(n)` / `df.tail(n)` | [head, tail](#first-and-last-rows--head-tail) |
| `df.sort_by_key(...)` / `df.sort_by { }` — views in the sorted order | [sort_by_key](#sort_by_key--reorder-rows-by-key-columns) |
| `CAFrame.meld(...)` — writes reach the input frames | [meld](#caframemeld--caframeconcatenate--rows-after-rows) |
| `df.melt(...)` — except the new column naming each row's source | [melt](#melt--wide-to-long) |
| each group in `grouped.table { \|sub\| }` | [table](#computing-across-columns--table) |
| `df.stack_rows(by:)` / `df.unstack_rows` | [From rows of a group](#from-rows-of-a-group--stack_rows--unstack_rows) |
| `CAFrame.stack(...)` / `df.unstack(axis:)` | [Layers](#layers--caframestack--unstack) |
| `df.to_ca` — a matrix view over the columns | [to_ca](#a-matrix--to_ca) |

**New frames that share some columns** — the frame you called it on is unchanged:

| operation | shared | new | see |
|---|---|---|---|
| `df.append` / `drop` / `rename` | every column | — | [Adding, removing and renaming](#adding-removing-and-renaming-columns) |
| `df.paste(other)` | the columns of both frames | — | [paste](#paste--columns-side-by-side) |
| `df.dup` / `clone` | every column and the index | — (adding or dropping a name affects only the new frame) | — |
| `df.join(..., how: :left)` / `df.join_asof(...)` | this frame's columns and index | the other frame's columns, gathered | [join](#join--match-rows-by-key) |
| `df.split_column(...)` | the other columns | text columns built from the split one | [split_column](#splitting-a-text-column--split_column) |
| `df.stack_columns(...)` / `unstack_column(...)` | the other columns | a view of the stacked or split columns | [From columns side by side](#from-columns-side-by-side--stack_columns--unstack_column) |

**Results that share nothing:**

| operation | see |
|---|---|
| `df.copy` | — |
| `df.filter(keep_masked: true) { }` | [keep_masked](#rows-whose-condition-is-undetermined--keep_masked) |
| `CAFrame.concatenate(...)` | [concatenate](#caframemeld--caframeconcatenate--rows-after-rows) |
| `df.join(..., how: :inner / :outer / :right)` / `df.align(...)` | [join](#join--match-rows-by-key), [align](#align--conform-to-a-reference-key-set) |
| `df.pivot(...)` / `df.pivot_grid(...)` | [pivot](#pivot--long-to-wide) |
| `df.to_records` | [to_records](#ruby-records--to_records) |
| `df.stack_rows(by:, on:)` | [From rows of a group](#from-rows-of-a-group--stack_rows--unstack_rows) |

**Operations that change `self`** — and whether the change reaches other frames sharing the column:

| operation | reaches frames sharing the column | see |
|---|---|---|
| `df.mask_eq(...)` / `df.fill(...)` | yes — the stored column is edited | [Masking and filling](#masking-and-filling-cells) |
| `df["c"] = UNDEF` / `df[sel] = UNDEF` | yes — masks the stored cells | [Adding, removing and renaming](#adding-removing-and-renaming-columns), [rows](#masking-deleting-and-splicing-rows) |
| `df.cast(...)` / `promote` / `parse_to_time` / `to_time` | no — a new column is bound | [Changing a column's type](#changing-a-columns-type) |
| `df["c"] = col` | no — the name is bound to a different column | [Adding, removing and renaming](#adding-removing-and-renaming-columns) |
| `df["c"] = nil` | — (removes the column from this frame only) | [Adding, removing and renaming](#adding-removing-and-renaming-columns) |
| `df[sel] = nil` | the remaining rows still share storage with the original columns | [rows](#masking-deleting-and-splicing-rows) |
| `df[sel] = frame` | the rows outside the span still share storage; the spliced rows share nothing | [rows](#masking-deleting-and-splicing-rows) |
| `df.set_index` / `reset_index` | — (no cell changes) | [The index](#the-index) |
| `df.protect` | — (makes the frame read-only; the arrays it was built from stay writable) | [Read-only frames](#read-only-frames) |

`df["col"]` returns the stored column itself ([The model](#the-model)).

---

## Read-only frames

Because sub-frames and columns write through, a frame handed to other code can be changed by it, or a write meant for one view can land in the frame it came from. Make a frame read-only when it should not change: a reference table that several sub-frames are taken from, or a frame passed to code that should only read it.

There are two levels. `freeze` fixes the frame's structure — its columns, rows and index. `protect` does that and also makes the cells of its columns refuse writes:

| | `freeze` | `protect` |
|---|---|---|
| add, remove or rebind a column (`df["c"] = ...`) | raises `FrozenError` | raises `FrozenError` |
| assign to rows (`df[sel] = ...`) | raises `FrozenError` | raises `FrozenError` |
| in-place verbs (`fill`, `mask_eq`, `cast`, `set_index`, ...) | raises `FrozenError` | raises `FrozenError` |
| write a cell or a mask through a column (`df["temp"][0] = v`) | writes | raises |

`freeze` leaves the cells to the columns, as `Array#freeze` leaves an Array's elements alone. Both change the frame and return it.

```ruby
temp = CA_FLOAT64([22.1, 25.3, 19.0])
df   = CAFrame.new("temp" => temp).protect
df.protected?              # => true
df["temp"][0] = 0.0        # raises: can not modify read-only array
df["temp"][0] = UNDEF      # raises as well -- masks are cells too

temp[0] = 0.0              # the array it was built from is still writable
df["temp"][0]              # => 0.0  -- and the write shows through
```

`protect` replaces each column, and the index, with a read-only view of itself; the arrays the frame was built from do not change, and whoever holds them can still write. `df["temp"]` returns the read-only view, not `temp` itself. A column that is already read-only (a categorical, a `CAConstString`) is kept as it is.

- Frames derived from a protected frame by views (`select`, `filter`, a row slice) read through the read-only views and refuse cell writes too; they are not frozen.
- `copy` gives a frame that can be written again.
- `dup` is not frozen, so it is not protected, though its columns are the same read-only views; `clone` keeps both.
- A frame already frozen with `freeze` cannot be protected afterwards, since its columns can no longer be replaced: `protect` raises `FrozenError`. Call `protect` instead of `freeze` when you want both.

---

## N-D columns

A column may carry axes after the row axis: a wind vector `(N, 2)`, a vertical profile `(N, 20)`, a covariance matrix `(N, 3, 3)`. Columns share only the number of rows on axis 0; the axes after it are free, so all three can sit in one frame beside scalar columns `(N,)`:

```ruby
df = CAFrame.new(
  "station" => CA_OBJECT(["tokyo", "osaka", "tokyo"]),
  "temp"    => CA_FLOAT64([22.1, 25.3, 19.0]),                      # (3,)
  "wind"    => CA_FLOAT64([[1.2, -0.3], [2.1, 0.5], [0.0, 0.0]]),   # (3, 2)
)
df["wind"].shape                 # => [3, 2]
p df.group_by("station").mean
```

```
#<CAFrame nrow=2 columns=[temp:float64, wind:float64[2]] index="station">
station   temp  wind
-------  -----  ------------
tokyo    20.55  [0.6, -0.15]
osaka     25.3  [2.1, 0.5]
```

Row operations carry the axes after the row axis along, so most of this document applies to N-D columns unchanged; the [table at the end of this chapter](#how-each-operation-treats-n-d-columns) lists the places where they behave differently.

The axes after the row axis carry **no labels**. Keep what each position means alongside, as an array of your own (`months = [1, 2, 3, 12]` for a column that has only those months, `days = CArray.time([...])` for layers).

### Working with a component

The frame's row conditions are 1-D, so to filter or sort on an N-D column, take a scalar component of it first — index the column as a CArray:

```ruby
df["wind"][nil, 0]                 # component 0 of every row (nil = all rows) -> (N,)
df.filter { |f| f["wind"][nil, 0] > 4 }               # a condition on a component
df = df.append("speed",                               # wind speed from the components
               (df["wind"][nil, 0] ** 2 + df["wind"][nil, 1] ** 2).sqrt)
```

### Making N-D columns

An N-D column comes from one of four places:

| the data is… | made by |
|---|---|
| an N-D array you already have | `CAFrame.new("wind" => …)` |
| JSON records with an array per cell | [`from_records`](#making-n-d-columns-from-records) |
| columns laid side by side (one per month, say) | [`stack_columns`](#from-columns-side-by-side--stack_columns--unstack_column) |
| several rows per group (a sounding's levels) | [`stack_rows`](#from-rows-of-a-group--stack_rows--unstack_rows) |

A fifth verb, [`CAFrame.stack`](#layers--caframestack--unstack), adds an axis to every column at once by laying several frames on top of each other.

#### Making N-D columns from records

In [`from_records`](#caframefrom_records), an **array cell** of one shape across every record becomes one N-D column: `{ "temp" => [min, mean, max] }` over `N` records is a single `(N, 3)` column, and a nested cell `[[1, 2], [3, 4]]` gives an `(N, 2, 2)` one.

Cells of different shapes, nesting that is not rectangular, or non-numeric elements fall back to an object column; so do cells with no value at all (every element `nil`, or empty arrays), as a scalar column of `nil` does.

### From columns side by side — `stack_columns` / `unstack_column`

A file often lays a series out as columns side by side: a value per month, one per hour, or for each month three values (maximum, minimum, mean). `stack_columns` makes them one N-D column, and `unstack_column` splits it back:

```ruby
df                                     # three columns side by side
# station  t_max  t_min  t_mean
# tokyo     25.1   18.2    21.0
# osaka     27.3   20.4    23.5

w = df.stack_columns("t_max".."t_mean", into: "temp")
# station  temp
# tokyo    [25.1, 18.2, 21.0]
# osaka    [27.3, 20.4, 23.5]

w.unstack_column("temp", into: %w[t_max t_min t_mean])   # the three columns again
```

With many columns, a Range of names and `shape:` arrange them into more than one axis:

```ruby
df = df.stack_columns("G02_002".."G02_013", into: "precip")            # int32[12]
df = df.stack_columns("G02_015".."G02_050", into: "temp", shape: [12, 3])
df["temp"][nil, 6, 0]                  # July's maximum, every row
df["precip"].sum(axis: 1)              # the year's total, every row
df = df.unstack_column("temp", into: names)   # the 36 columns again
```

**Choosing the columns.** They are a **Range of names**, an **Array** or a **Regexp**:

- A Range means this frame's columns from the first name to the last, **in the frame's order** (not the names Ruby would count between the two); `...` leaves the last one out.
- An Array is taken in its own order.
- A Regexp matches in the frame's order.

A name that is not a column, a Range that runs backwards, or a column named twice raises.

**`stack_columns`:**

- `into:` is the new column's name, a String. The new column takes the place of the first of the stacked columns; the others leave the returned frame.
- `shape:` arranges the columns in row-major order — the last axis runs fastest — and must hold exactly as many: 36 columns of maximum, minimum, mean for each month are `shape: [12, 3]`. Without it the columns make one axis.
- The new column is a **view** of the old ones: writing to it — masking a missing-value code with `df["temp"][:eq, 999999] = UNDEF`, say — writes the columns it was made from.
- Columns of different data types are read at a common type. Stacked columns that are themselves N-D keep their axes after the new ones.

**`unstack_column`:**

- It puts one column per position in the N-D column's place, in row-major order, as views.
- `into:` names them; without it they are named `"temp_0"`, or `"temp_6_2"` with two axes. The frame does not remember the names the columns had, so pass them as `into:` to get them back.
- When `into:` names as many columns as the **first** axis after the row axis is long, the column is split along that axis only, and each new column keeps the axes after it: a `(n, 2, 3)` column with two names gives two `(n, 3)` columns. This undoes `stack_columns` of columns that were themselves N-D.
- A column whose axes hold no position (an `(n, 0)` column) has nothing to split into and raises.

### From rows of a group — `stack_rows` / `unstack_rows`

A long table often lays a series out as rows: one observation per row, several rows per station (a sounding's levels, a day's hours). `stack_rows` makes each group's rows one row, every other column becoming an N-D column over them; `unstack_rows` spreads them back:

```ruby
long                                   # station, level, temp: 6 rows
# station  level   temp
# tokyo     1000   15.0
# tokyo      850    5.0
# tokyo      500  -20.0
# osaka     1000   17.0
# osaka      850    7.0
# osaka      500  -18.0

n = long.stack_rows(by: "station")
# station  level             temp
# tokyo    [1000, 850, 500]  [15.0, 5.0, -20.0]
# osaka    [1000, 850, 500]  [17.0, 7.0, -18.0]

n["temp"].min(axis: 1)                 # each station's lowest temperature
n.unstack_rows                         # the 6 rows again, station as the index
```

**The key.** `by:` takes keys as `group_by` does — column names, or a CArray of one value per row — and the key becomes the **index**. A computed key folds consecutive rows: `h.stack_rows(by: h["time"].floor(unit: :D))` makes an hourly series one row per day, each column `[24]`. Every row needs a key.

**The other columns.** A group's rows are stacked **in the order they are in the frame**; `sort_by` first for another order. A column that tells the rows apart (`level` here) is stacked like any other, so what position k means stays in the frame as a column. The frame's own index, if it has one, is stacked as a column named after the row axis. A frame with no column besides the key, and no index, has nothing to stack and raises.

**Lining up the rows — `on:`.** How the rows of the groups line up depends on `on:`:

| | rows are matched | a group with a missing row | result |
|---|---|---|---|
| without `on:` | by position | raises | a view: writes reach the long frame |
| `on: "level"` | by the value of `level` | `UNDEF` at that position | a new frame |

Without `on:`, every group must have the **same number of rows**: filling a short group with `UNDEF` at its end would put its values at the wrong positions — a station missing the 850 hPa row would have its 500 hPa value where 850 belongs. With `on:`, position k is the k-th value of that column **in the order it first appears** in the frame (`sort_by` first for another order); a group with two rows for one value raises, and the `on:` column is stacked too, with the same values in every row:

```ruby
long.stack_rows(by: "station", on: "level")   # osaka has no 850 hPa row
# station  level             temp
# tokyo    [1000, 850, 500]  [15.0, 5.0, -20.0]
# osaka    [1000, 850, 500]  [17.0, _, -18.0]
```

**`unstack_rows`** spreads **every** N-D column along its first axis after the row axis, repeating the other columns and the index once per position; the N-D columns must agree on that length. The index stays the index (`reset_index` turns it back into a column).

An N-D column the frame had before `stack_rows` — a wind vector `(N, 2)` — is `(groups, rows, 2)` after it and spreads back to `(N, 2)`. But on a frame that was never stacked, `unstack_rows` spreads such a column's components into rows, so set it aside first.

### Layers — `CAFrame.stack` / `unstack`

`CAFrame.stack` puts several frames of the **same shape** on top of each other as layers: the rows stay as they are, and each column gains an axis that runs over the frames. Several files of the same table — one per day, say — become one frame whose columns hold every day:

```ruby
s = CAFrame.stack(day1, day2, day3)   # temp:float64 -> temp:float64[3]
s["temp"]                             # (nrow, 3): row by day
s["temp"][nil, 1]                     # day2's column
s["temp"][0..9, nil]                  # a block of rows over every day
s["temp"].mean(axis: 1)               # each row's mean over the days
```

Row verbs (`filter`, `sort_by`, `meld`, `head`) work on the stack unchanged, and work across the layers is a column reduction along the layer axis. `group_by` takes one value per row, so group by a component — `s.group_by(s["station"][nil, 0])` — rather than by a stacked column, which it refuses.

- `axis:` counts a column's own axes, 0 being the row axis, so it starts at 1 and defaults to 1: the layer axis comes right after the rows in **every** column (`v:float64[2]` becomes `float64[3, 2]`). Axis 0 is refused — rows are joined by `meld` / `concatenate` — and so is a negative axis, which would name a different axis in columns with different numbers of axes.
- Every frame must have the same columns, the same number of rows, and the same index **by value** under the same axis name (or none). Stacked rows have to be the same rows; frames whose rows differ are refused rather than put together row by row. The result takes the first frame's index.
- The result is a **view**: each column is a `CAStack` over the frames' columns, and writes reach them. `copy` it for an independent frame. A column whose data type differs between the frames is read at a common type.

`unstack(axis:)` is the inverse: one frame per position on that axis, each with this frame's index and views of its columns. `CAFrame.stack(*s.unstack(axis: 1))` gives the same frame back. Every column must have the axis with the same length; a column without it has no layer to give each frame, so it raises rather than repeating the column in every frame.

```ruby
s.unstack(axis: 1)  # => [day1's frame, day2's frame, day3's frame]
```

### How each operation treats N-D columns

| operation | with an N-D column |
|---|---|
| row selection (`df[...]`, `filter`, `head`, `sort_by_key`, …) | the axes after the row axis are carried along |
| `df[i]` / `each_row` | the cell is a view of that row's slice; writing it reaches the frame |
| `filter` | the condition must be one value per row; an N-D condition raises — take a component |
| `sort_by_key` / `sort_by` | a key must be one value per row; an N-D key raises |
| keys of `group_by`, `join`, `join_asof`, `align` | must be one value per row; an N-D column is refused — take a component |
| `group_by` / `resample` reductions, `aggregate` with a Symbol | reduced along the rows, so each group keeps the shape: a `(N, 20)` profile gives `(groups, 20)`, each station's mean profile |
| `aggregate` with a Proc | the Proc receives each group's slice, shaped `(rows in the group, ...)` |
| `fill` | filled down the rows: each position is a series of its own, filled only from the rows above and below it, never from a neighbouring component |
| `join` / `join_asof` / `align` (columns brought in) | gathered correctly; a row with no match comes back fully masked |
| `paste` | no restriction |
| `meld` / `concatenate` | the axes after the row axis must agree across frames (also for a frame with no rows) |
| `pivot` / `pivot_grid` | kept in every output column; in `pivot_grid` they come after the two key axes. `aggregate:` needs 1-D value columns |
| `melt` | the value columns must share one shape after the row axis |
| `describe` | `type` shows the shape (`float64[2]`); `count` and `masked` count elements, not rows — a `(3, 2)` column has `count` 6 — and `unique` and the statistics are taken over all elements together |
| `to_table` / `p` | each row's slice as a bracketed list, each element shown as a scalar cell of its kind would be (rounded, `_` when masked, a time as its date, a string quoted) |
| `to_records` | the cell becomes a Ruby `Array`, which `from_records` reads back as the same N-D column |
| `to_csv` | raises — a CSV cell is flat; `unstack_column` first |
| `to_ca` | raises when any column is N-D, even if every column has the same shape; take the column with `df["name"]` |

---

## See also

- [What is CArray](../WhatIsCArray.md) — the array type columns are made of.
- [Reading and writing CSV](CAFrameCSV.md) — every option of `from_csv` / `to_csv`.
- [CACategorical](../objects/CACategorical.md) — categorical columns and the group-by substrate.
- [CATime](CATime.md) — time columns and time indices.
- [CAFace](CAFace.md) — semantic column types (time / categorical) carried through joins and gathers.
- [MemoryView](../interop/MemoryView.md) — zero-copy interchange from a column.
