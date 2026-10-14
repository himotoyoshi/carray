# MemoryView Format Reference

Reference for the format strings CArray emits and accepts via Ruby's
`rb_memory_view_t` protocol.  See [MemoryView.md](MemoryView.md) for
the user-facing MV API (`CArray.wrap_memory_view`, etc.); this
document is CArray's format-string contract.

CArray's top-level format strings follow **`ruby/memory_view.h`**,
which documents `format` as a sequence of pack-derived specifiers and
expects `item_size` to equal
`rb_memory_view_item_size_from_format(format)`.  The two vocabularies
agree from 32 bits up (`i`/`I`/`q`/`Q`/`f`/`d`) and disagree below it:
what PEP 3118 spells `b`/`B`/`h`/`H`, Ruby spells `c`/`C`/`s`/`S`.
CArray emits Ruby's, which is what lets a generic Ruby consumer —
`Fiddle::MemoryView`, say — read elements out of a CArray at all.

Three types have no Ruby spelling and keep their PEP 3118 form: `?`
(bool) and `Zf`/`Zd` (complex).  Ruby's parser rejects those, so
element access through a generic consumer fails on them; the
alternatives (`C` for a bool, `dd` for a complex) would misdescribe
the data rather than merely fail to describe it.  The `Ns`
fixed-bytes form stays PEP 3118 as well, as Ruby's vocabulary has no
notion of it.  A record is written in Ruby's vocabulary — see
[Record format](#record-format).

Consumers are Postel: PEP 3118 spellings (`b`/`B`/`h`/`H`), the
remaining pack-template synonyms (`l`/`L`, `s!`/`i!`/`l!`/`q!`), and
LP64 platform-long `l`/`L` at `item_size` 8 as emitted by numpy are all
accepted on input.  A view produced by any CArray release therefore
still imports.


---

## Producer table

CArray's MV producer sets `view.format` and `view.item_size` per
data type:

| data type   | `format` | `item_size` |
|-------------|----------|-------------|
| bool        | `?`      | 1           |
| int8        | `c`      | 1           |
| uint8       | `C`      | 1           |
| int16       | `s`      | 2           |
| uint16      | `S`      | 2           |
| int32       | `i`      | 4           |
| uint32      | `I`      | 4           |
| int64       | `q`      | 8           |
| uint64      | `Q`      | 8           |
| float32     | `f`      | 4           |
| float64     | `d`      | 8           |
| complex64   | `Zf`     | 8           |
| complex128  | `Zd`     | 16          |

A plain `CA_FIXLEN` of N bytes is emitted as `Ns`.

Not emitted (no MV format):

- `CA_OBJECT` — VALUE column, protocol-level limit
- bitarray / bitfield — sub-byte, MV protocol does not represent

For a record array (`CARecord`) CArray emits the members'
specifiers in a row — see [Record format](#record-format) below.

---

## Consumer table

The MV consumer dispatches on `(format, item_size)` tuples.
Synonyms commonly used by other producers are accepted in addition
to the canonical forms above.

| `format`             | `item_size` | data type   |
|----------------------|-------------|-------------|
| `?`                  | 1           | bool        |
| `b`, `c`             | 1           | int8        |
| `B`, `C`             | 1           | uint8       |
| `h`, `s`, `s!`       | 2           | int16       |
| `H`, `S`, `S!`, `v`, `n` | 2       | uint16      |
| `i`, `i!`, `l`, `l!`, `j` | 4      | int32       |
| `I`, `I!`, `L`, `L!`, `J`, `V`, `N` | 4 | uint32 |
| `q`, `q!`, `l`, `l!`, `j` | 8      | int64       |
| `Q`, `Q!`, `L`, `L!`, `J` | 8      | uint64      |
| `f`, `e`, `g`        | 4           | float32     |
| `d`, `E`, `G`        | 8           | float64     |
| `Zf`                 | 8           | complex64   |
| `ff`                 | 8           | complex64   |
| `Zd`                 | 16          | complex128  |
| `dd`                 | 16          | complex128  |

Synonyms cover the conventions used by:

- Ruby pack-template (`c`/`C`/`s`/`S`/`l`/`L` at native widths)
- red-arrow's MV producer (same as Ruby pack-template)
- numpy / Python struct (`l`/`L` at LP64 native widths, item_size 8)

Byte order is read in both vocabularies: as a prefix (`<` little,
`>` and `!` big, `=` and `@` the machine's) and as Ruby's suffix on a
single type (`i<`, `s!>`).  `_` is read as `!`.  `e` / `E` / `v` / `V`
are little-endian by their letter and `g` / `G` / `n` / `N` big-endian.
CArray stores the machine's byte order, so a format whose order is the
other one is rejected; a one-byte type (`c` `C` `b` `B` `?`) has no
order and is accepted with any.  The alignment `|` is skipped.

---

## Rules

### Item size is authoritative

The `format` character carries the semantic type; `item_size`
carries the byte width.  Consumers MUST cross-check.  The same
character with different `item_size` can resolve to different
data types — `(l, 4)` is int32, `(l, 8)` is int64.

### Byte order

A plain array is in the machine's byte order.  A record member declared
with `endian:` is written in Ruby's form for it (see
[Record format](#record-format)).  On input, CArray accepts the
machine's byte order only.

### No alignment padding at top level

Producers MUST NOT emit `|`.  Consumers strip it on input.

### `Zf` / `Zd` for complex

Complex numbers use PEP 3118's `Z<float>` form: `Zf` (8-byte
complex64) and `Zd` (16-byte complex128).  The legacy `ff` / `dd`
synonyms remain accepted on input but are not emitted.

---

## Record format

For a record array (`CARecord`) the producer emits the members'
specifiers in their order in the record, in Ruby's vocabulary — the
top-level table above — with `x<N>` for padding between members and
after the last:

| record                                                  | format     |
|---------------------------------------------------------|------------|
| `struct(pack: 1) { int32 :a; float64 :b }`              | `id`       |
| `struct { uint8 :a; uint64 :b }` (aligned)              | `Cx7Q`     |
| `struct(pack: 1, size: 16) { uint32 :x }`               | `Ix12`     |

Ruby's parser reads these, and its item size is the record size.

A member declared with `endian:` is written as Ruby writes byte order:
a suffix on an integer (`i>` big, `s<` little) and its own letter on a
float (`g` / `e` for a big / little float32, `G` / `E` for float64).
A one-byte member needs none.  A complex member with a declared byte
order has no Ruby spelling, and its record is not exported.

Ruby's format has no member names.  A record array gives them as
`memory_view_field_names`, one per specifier in the same order:

```ruby
r = CARecord.new(CArray.struct { uint8 :a; uint64 :b }, 2)
r.memory_view_field_names   # => ["a", "b"]
```

A bridge that writes a format with names (PEP 3118 `T{...}`, for
numpy) asks the exporting object for them under this name.  Any
exporter can answer it; it returns `nil` when the object has no record
format.

A record is not exported when the format cannot describe it:

- a nested struct, an array member, a `:fixlen` / `:object` member, a
  bit member — no item for it
- a union, or members that overlap or are out of offset order — the
  format lays items out one after another
- a complex member with a declared byte order (above)

CArray does not import a record format.

---

## Mask policy

CArray rejects MV requests on masked CArrays with
`ArgumentError`.  Use one of these to make the intent explicit:

- `ca.value` — MV-exposable CARefer ignoring the mask
- `ca.mask` — boolean MV of the mask itself
- `ca.unmask_copy(fill)` — eager copy with fills
