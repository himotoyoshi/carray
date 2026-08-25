# A DataFrame built on CArray columns (`CAFrame`)

> **Status: provisional.** CAFrame is being grown inside CArray, and that is
> where it is expected to stay. Splitting it into a gem of its own remains an
> option if it ever outgrows the fit — that would change the `require` and make
> it a separate dependency — but it is not the current direction.
>
> The surface described here is implemented and tested unless a section is
> marked **TBD**, which flags a planned feature that is not yet built. Names
> and details of TBD items may change.

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
  index alignment** — the frame keeps names, you keep control.

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

Read a CSV. The header row supplies column names (Strings). Every column is
read **raw as an object column of the cell strings** — CAFrame does not guess
types. Casting is a separate, explicit step: pass `types:` to cast named
columns on the way in, or call [`cast`](#8-column-verbs) later. Cells that fail
to parse become `UNDEF` automatically (**parse-mask**):

```ruby
df = CAFrame.from_csv("obs.csv")
df["temp"].data_type      # => :object   (raw strings)

df = CAFrame.from_csv("obs.csv", types: { "temp" => :float64, "rh" => :int32 })
df["temp"].data_type      # => :float64
# an empty cell or "xx" in the temp column fails to_type -> UNDEF
```

Parsing uses a **built-in fast tokenizer** (no external dependency): quote-free
records are split directly, and only quote-bearing records go through the field
scanner (embedded separators / newlines / `""` escapes). Columns are handed to
the frame as views over one backing object array, so the build is cheap.
Options: `sep:` (default `","`), `quote:` (`'"'`), `strip:` (trim spaces from
unquoted fields, default `false` = RFC 4180 spacing), `encoding:`
(default `"bom|utf-8"`, strips a BOM).

For files with a preamble, a units row, or no header, pass a **reading-control
block** — `skip(n)` / `header` / `header(name)` / `column_names(...)` / `body`:

```ruby
CAFrame.from_csv("obs.csv") do
  skip 2          # drop 2 preamble lines
  header          # next line is the header
  skip 1          # drop a units row
  body            # the rest are data rows
end
```

Without a block the default is `header` then `body`. A headerless file gets
positional names `c0`, `c1`, … unless you supply `column_names`.

To swap in a different parser (the stdlib `csv`, or a typed-table source), pass
`parser:` — a callable `path -> [headers, rows]`. When given, it owns parsing,
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
- Descending works for **every dtype** (a descending key is internally its dense
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
> - `= other` rebuilds each column with `CArray.concatenate`, which
>   **materializes**, so the spliced columns are fresh, independent buffers (the
>   one row form that copies). This holds **even when `other` has the same row
>   count as the span** — `= other` is splice (structural), not an element-write,
>   so it never writes through, unlike CArray's `ca[sel] = other`. A column
>   escaped before the splice keeps the old data. (Making it write-through when
>   the counts happen to match would make the same expression copy or mutate
>   depending on lengths — the row count deciding the behavior — so it always
>   copies.)
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
CAFrame.from_records(df.to_records)   # rebuilds the same columns and types
JSON.generate(df.to_records)          # -> a JSON array of objects
```

If a 2-D CArray of shape `(nrow, nvar)` is what you want, `to_ca` hands
one over — a **view**, one column per variable in column order:

```ruby
m = df.to_ca                # CAStack view (nrow, nvar), no data copied
m[0, 1] = 99.0              # writes flow back into the column
owned = df.to_ca.copy       # independent, owned matrix
```

Only all-scalar (**1-D**) columns qualify; an N-D column has no single
matrix form and raises — escape it per column with `df["name"]`. A mixed
dtype set is promoted to a common type (`result_type`) through lazy cast
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
does **not** promote to a common dtype — each column is formatted to text on its
own, so numbers, strings, and time / categorical columns sit side by side.

The index (if any) is written as the first column under `axis_name` unless
`index: false`. A **masked cell (UNDEF) becomes an empty field**, which
`from_csv` reads back as UNDEF (parse-mask) — so mask round-trips. A genuine
empty string is written quoted (`""`) to stay distinct from missing. Fields
containing the separator, a quote, or a newline are quoted with internal quotes
doubled (RFC 4180). Options `sep` / `quote` mirror `from_csv`; `header` /
`index` default to true.

### Index

```ruby
df.set_index("time")       # move "time" to the index (mutates self; §8 role change)
df.reset_index             # move the index back into a column (mutates self)
df.index                   # the index CArray (or nil)
df.axis_name               # the row-axis name
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
df.promote                                          # every column to one common type
df.promote(:object)                                 # ...to the widest type of all
df.mask_eq("flag", -999)                            # mask cells equal to a sentinel
```

Notes:

- **`append`** returns a new frame with the column added at the tail (or
  replacing an existing name in place). The length must match `N`; appending to
  an empty frame (`nrow` `0`, a defined value) yields a frame whose `N` is that
  column's length.
- **`cast`** uses `to_type`, so parse failures on string columns become
  `UNDEF` (parse-mask). Casting a numeric column is an ordinary conversion. It
  rebinds a fresh column — the one edit that does **not** write through to
  frames sharing the old column.
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
df.parse_to_time("time").set_index("time")
df.parse_to_time("time", "%d/%m/%Y")            # explicit strptime format

# serial -> time: reinterpret integer counts since an epoch
df.to_time("t", unit: :h, epoch: "1990-01-01")  # netCDF "hours since 1990-01-01"
df.to_time("t", unit: :day, epoch: "1899-12-30").set_index("t")  # Excel serial date
```

- **`parse_to_time(name, format = nil, unit: :s)`** parses a
  string-bearing column (an object `CArray` of Strings, or a `CAString` /
  `CAConstString` / `CAFixlenString`). Missing and unparseable cells become
  `UNDEF` (parse-mask). A non-string column raises.
- **`to_time(name, unit:, epoch: nil)`** reads an integer column as counts
  of `unit` resolution since `epoch` (default the Unix epoch). `epoch` takes any
  time literal (String / `Time` / Integer), so columns measured from another
  origin convert directly. A float column is accepted only when every value is
  whole; a fractional serial raises (use a finer `unit`). A non-numeric column
  raises.

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

> **TBD — `strict` cast.** A `strict:` option on `cast` (parse failure raises
> instead of masking) is not yet built.

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

A `GroupedFrame` has three surfaces:

### (a) Convenience reductions

`sum` / `mean` / `min` / `max` reduce **every numeric scalar column** into a
new frame indexed by the group labels (non-numeric / N-D columns are skipped):

```ruby
df.group_by("station").mean       # => frame of per-station means
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

---

## 10. `join` and `join_asof`

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
at-or-before, `:ceil` = next, `:round` = nearest); rows out of range or beyond
`tolerance:` come back `UNDEF`:

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
step (a forthcoming `fill`, or your own column math on the escaped columns).

### `CAFrame.concat` — stack rows

`CAFrame.concat(*frames)` stacks frames along the **row axis** (vertical): same
columns, more rows. It is the **symmetric sibling of `join`** — no frame is
privileged — so it is a class method (like `CArray.concatenate`), not `df.join`.

```ruby
CAFrame.concat(jan, feb, mar)     # three months of rows, stacked
CAFrame.concat([jan, feb, mar])   # an Array is accepted too
```

- Columns are **matched by name** (output order follows the first frame); every
  frame must carry the same column-name set, or it raises.
- Each output column is `CArray.concatenate` of that column, so **dtypes promote**
  to a common type, **masks are preserved**, and an **N-D column** carries its
  trailing dimensions (which must agree across frames).
- The **index** is concatenated when every frame has one (their `axis_name` must
  agree); if none do, the result has no index; a mix raises.
- The result is a **new materialized frame**, not a view. A single-frame
  `concat(df)` returns an independent copy.

This is deliberately strict (same columns only) — a union-with-`UNDEF` mode is a
possible future opt-in, kept out to stay explicit.

### `paste` — merge columns by position

`paste(other)` puts `other`'s variables **beside** this frame's, matched by
**row position** — a keyless column merge (the column-direction counterpart of
the row-stacking `concat`, named after the UNIX `paste`; the positional
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

## 11. Metadata readers

Each reader returns a **fresh** object — the live columns Hash is never
exposed.

| reader | returns |
|---|---|
| `variables` | `Array<String>` of column names, in column order |
| `nvar` | number of columns |
| `nrow` | number of rows (axis-0 length `N`) |
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

## 12. View, copy, and aliasing

Frame view/copy semantics follow CArray exactly:

| operation | result |
|---|---|
| `df["col"]` | the **stored column** (alias) — writing mutates the frame |
| `df.select(...)` | **view-frame**, columns aliased (zero-copy) |
| `df[0..1]` / `df[bool]` / `df.filter { }` | **view-frame**, columns are row views sharing storage |
| `df.copy` | an **independent** frame — every column materialized |
| `df.append` / `drop` / `rename` | a **new frame** (column set / names change) — columns shared, cheap; the original is untouched (§8) |
| `df.cast(...)` | **self** — rebinds a fresh column of the new type; does not write through to frames sharing the old column |
| `df.promote(...)` | **self** — same as `cast`, applied to every column (fresh columns, common type) |
| `df.set_index` / `reset_index` | **self** — an index-role change, data unchanged |
| `df.mask_eq(...)` / `df.fill(...)` | **write-through self** — mutates the shared column in place, visible through every alias / parent |
| `df["c"] = col` | **self** — binds the name to a different column; a replacement, not an edit, so it does not reach holders of the old one (as `cast`) |
| `df["c"] = nil` | **self** — removes the column from this frame's set |
| `df["c"] = UNDEF` | **write-through self** — masks the stored column in place, visible through every alias |
| `df[sel] = UNDEF` | **write-through self** — masks the selected rows in place; shape unchanged, visible through every derived view |
| `df[sel] = nil` | **self** — rebinds each column to a row-gather view of itself; surviving rows still share storage with the originals (§3) |
| `df[sel] = frame` | **self** — rebuilds columns via `concatenate` (materialized, independent of the old columns); splice is the one row form that copies (§3) |
| `df.to_ca` | a **view** — a `CAStack` of shape `(nrow, nvar)` over the stored columns; writes flow back, `copy` for an owned matrix |

Because view-frames share storage, mutating a view writes through to the
parent — the same aliasing rule as CArray views. When you need an independent
frame, use `copy`:

```ruby
snapshot = df.copy         # independent; later edits to df don't touch it
```

---

## 13. Planned features (TBD)

These appear in the design and are intended, but are **not implemented yet**:

- **`fill(name, :ffill | :bfill)`** — forward / back-fill of masked cells.
- **`cast(name, type, strict: true)`** — parse failure raises instead of
  masking.
  > **Naming caveat (settle before building).** "strict" is overloaded across
  > the notes: an earlier "strict-parse" idea meant *mask* the failures, while
  > this `strict:` means *raise* on them — opposite senses. There are really
  > three parse behaviors — lenient (`"xx" → 0.0`), mask (`"xx" → UNDEF`, now
  > the `to_type` default), and raise — and they deserve three distinct words.
  > Pick the vocabulary before this option lands, while it is still free to move.

---

## See also

- [What is CArray](../WhatIsCArray.md) — the array type columns are made of.
- [CACategorical](../objects/CACategorical.md) — categorical columns and the group-by
  substrate.
- [CATime](CATime.md) — time columns and time indices.
- [CAFace](CAFace.md) — semantic column types (time / categorical) carried
  through joins and gathers.
- [MemoryView](../interop/MemoryView.md) — zero-copy interchange from an escaped column.
