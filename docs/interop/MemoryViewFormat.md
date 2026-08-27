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
the data rather than merely fail to describe it.  Two structural
formats stay PEP 3118 as well: `T{...}` records and the `Ns`
fixed-bytes form, neither of which Ruby's vocabulary has a notion of.

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

Not emitted (no MV format):

- `CA_FIXLEN` — variable-byte payload, CArray-specific
- `CA_OBJECT` — VALUE column, protocol-level limit
- bitarray / bitfield — sub-byte, MV protocol does not represent
- `CAUnboundRepeat` — shape not yet bound

For CAStruct-typed data CArray emits a PEP 3118 struct format
`T{...}` — see [Struct format](#struct-format) below.  The body
uses the same primitive spellings as the top-level table.

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
| `H`, `S`, `S!`       | 2           | uint16      |
| `i`, `i!`, `l`, `l!` | 4           | int32       |
| `I`, `I!`, `L`, `L!` | 4           | uint32      |
| `q`, `q!`, `l`, `l!` | 8           | int64       |
| `Q`, `Q!`, `L`, `L!` | 8           | uint64      |
| `f`                  | 4           | float32     |
| `d`                  | 8           | float64     |
| `Zf`                 | 8           | complex64   |
| `ff`                 | 8           | complex64   |
| `Zd`                 | 16          | complex128  |
| `dd`                 | 16          | complex128  |

Synonyms cover the conventions used by:

- Ruby pack-template (`c`/`C`/`s`/`S`/`l`/`L` at native widths)
- red-arrow's MV producer (same as Ruby pack-template)
- numpy / Python struct (`l`/`L` at LP64 native widths, item_size 8)

Stripped before dispatch: alignment `|`, host-matching byte-order
markers (`<`/`>`/`=` when they match the host).  Cross-endian
sources are rejected.

---

## Rules

### Item size is authoritative

The `format` character carries the semantic type; `item_size`
carries the byte width.  Consumers MUST cross-check.  The same
character with different `item_size` can resolve to different
data types — `(l, 4)` is int32, `(l, 8)` is int64.

### Host byte order only

CArray emits and accepts host-native byte order.  Cross-endian
exchange via `<`/`>` prefixes is deferred.

### No alignment padding at top level

Producers MUST NOT emit `|`.  Consumers strip it on input.

### `Zf` / `Zd` for complex

Complex numbers use PEP 3118's `Z<float>` form: `Zf` (8-byte
complex64) and `Zd` (16-byte complex128).  The legacy `ff` / `dd`
synonyms remain accepted on input but are not emitted.

---

## Struct format

For CAStruct-typed data the producer emits

```
T{<fmt1>:<name1>:<fmt2>:<name2>:...:}
```

`T{...}` is a PEP 3118 construct with no Ruby counterpart, so a record
body stays in PEP 3118's vocabulary even though the top-level table
does not.  A consumer reading the body reads it as PEP 3118, and a
bridge that forwards the record whole keeps it intact:

| field type | spec    |
|------------|---------|
| bool       | `?`     |
| int8       | `b`     |
| uint8      | `B`     |
| int16      | `h`     |
| uint16     | `H`     |
| int32      | `i`     |
| uint32     | `I`     |
| int64      | `q`     |
| uint64     | `Q`     |
| float32    | `f`     |
| float64    | `d`     |
| complex64  | `Zf`    |
| complex128 | `Zd`    |
| padding    | `<N>x`  |

Example: `T{B:a:7x:Q:b:}` — uint8 `a`, 7 pad bytes, uint64 `b`.

The body MUST end with a colon before the closing `}`.  Padding
is canonically elided (no name slot after the `x`).

Consumers that don't natively support struct types MAY treat
`T{...}` as opaque (forward `view.format` unchanged, treat
`item_size` as record byte width).  Consumers that DO parse it
MUST verify the sum of field sizes (including padding) equals
`item_size`.

Producers do NOT emit `T{...}` for:

- nested struct (`T{T{...}:nested:...}`) — not represented
- bitfield members — no PEP 3118 grammar
- `:fixlen` / `:object` members — out of scope for buffer protocol
- sub-array members (`(N)<fmt>:name:`) — deferred

---

## Mask policy

CArray rejects MV requests on masked CArrays with
`ArgumentError`.  Use one of these to make the intent explicit:

- `ca.value` — MV-exposable CARefer ignoring the mask
- `ca.mask` — boolean MV of the mask itself
- `ca.unmask_copy(fill)` — eager copy with fills
