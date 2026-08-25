# CArray Serialization (`_CARRAY3`)

`CArray.save`, `CArray.load`, and `CArray.dump` serialize a CArray to —
and deserialize it from — the portable `_CARRAY3` binary format.  This
document is both the guide to those methods and the wire-format
contract, written so that a reader in any language can be implemented
from this page alone.

The format has one governing promise: **the raw numeric payload lives
at a fixed byte offset in a single file-wide byte order.**  A reader
in C, FORTRAN, or any language with raw file access reaches the data
with one seek and never has to parse any Ruby-specific metadata.  CArray-native concepts — the
attribute Hash, the `data_class` record schema, and the mask — ride in
a text trailer at the tail of the file that non-Ruby readers skip.

Scope: this is a format for **temporary / workflow handoff** — dump a
result, hand it to the next process, consume, discard.  It is not a
long-term archive format; for archival storage export to a mature
format (NetCDF, HDF5, Parquet, …).

---

## Serializing and deserializing

Three class methods cover the round trip.  They read and write the same
`_CARRAY3` bytes; they differ only in where those bytes come from or go.

| method | direction | destination / source |
|---|---|---|
| `CArray.save(ca, output, **opt)` | serialize | a file path (`String`) or an open IO |
| `CArray.dump(ca, **opt)`         | serialize | returns the bytes as a binary `String` |
| `CArray.load(input, **opt)`      | deserialize | a file path, an in-memory payload `String`, or an IO |

```ruby
a = CArray.float64(2, 3).seq

CArray.save(a, "result.ca")          # -> file
b = CArray.load("result.ca")         # <- file
b == a                               # => true

blob = CArray.dump(a)                # -> binary String
CArray.load(blob) == a               # => true
```

`save` and `load` also accept any IO, so a payload can stream through a
pipe or a `StringIO` without touching the filesystem.  `load`
distinguishes an in-memory payload from a filename by the magic string:
a `String` that begins with `"_CARRAY3"` and is at least a header long
is decoded in place, while any other `String` is treated as a path.

### What round-trips

A round trip preserves everything that describes the array as a numeric
container:

- **shape** and **data type**;
- the **mask** — a masked element comes back masked, not as stray data;
- **attributes** attached with `set_attr` — JSON-compatible values
  (string / number / bool / null / array / nested map) plus non-finite
  Floats such as `Float::INFINITY`;
- the **`data_class`** of a record array (a [Face](CAFace.md) over a
  fixlen record — see [CARecord](../objects/CARecord.md)).  A named
  record class comes back as itself; an anonymous one is reconstructed
  field-for-field from the schema stored in the trailer.

```ruby
a = CArray.int32(4).seq
a[2] = UNDEF
a.set_attr(:units, "m/s")
a.set_attr(:fillvalue, Float::INFINITY)

b = CArray.load(CArray.dump(a))
b[2]                 # => UNDEF     (still masked)
b.attr("units")      # => "m/s"
b.attr("fillvalue")  # => Infinity
b == a               # => true
```

### Byte order — `:endian`

By default a writer emits the host's native byte order and never swaps
on write.  Pass `:endian` to force the output order:

```ruby
CArray.save(a, "big_endian.ca", endian: CA_BIG_ENDIAN)
```

`load` reads the file's order from the header and swaps into the host
order automatically, so a file written on one architecture reads
correctly on another with no action from the caller.  The mechanism is
specified in [Endianness](#endianness).

### Reinterpreting a bare record — `:data_type`

A `CA_FIXLEN` payload with no `data_class` in its trailer loads back as
a bare fixed-length byte array.  Pass `:data_type` to `load` to
reinterpret those record bytes as a specific element type instead:

```ruby
CArray.load("packed.ca", data_type: CA_FLOAT64)
```

### What cannot be serialized

Two things fall outside the format and raise `ArgumentError` from `save`
/ `dump`:

- an **object array** (`CA_OBJECT`, arbitrary Ruby objects per cell) —
  it has no fixed-width raw representation (see
  [Object arrays](#object-arrays));
- a **`data_class`** whose layout the v1.0 trailer schema cannot express
  — a bitfield member, or a non-primitive member (nested record, CArray
  template, fixlen).  Layer 1 describes flat, primitive-typed members
  only (see [The trailer](#the-trailer)).

`load` raises `RuntimeError` on a bad magic string, an unsupported
version, or a failed corruption cross-check (endian marker or
`data_bytes`).

---

## File structure

```
+-----------------------------------------------------------+
| 0      Header      256 bytes, fixed                       |
+-----------------------------------------------------------+
| 256    Data        elements * element_bytes, raw          |
+-----------------------------------------------------------+
| ...    Mask        elements bytes of int8, if has_mask    |
+-----------------------------------------------------------+
| ...    Trailer     UTF-8 YAML, trailer_bytes long, if any |
+-----------------------------------------------------------+
```

The Data region always begins at `data_offset` (256 in v1.x).  Mask
and Trailer are present only when the header says so; their positions
are given by explicit header offsets, so a reader never computes them
by hand.

---

## Header

The header is a fixed 256-byte block.  All multi-byte integers are
stored in the **file's byte order** (see [Endianness](#endianness)); a
reader determines that order from `endian_marker`, the first multi-byte
field, before interpreting any of them.

| offset | field            | type        | notes |
|-------:|------------------|-------------|-------|
| 0      | `magic`          | char\*8     | `"_CARRAY3"` |
| 8      | `endian_marker`  | uint32      | `0x01020304` in file order; the byte-order determinant |
| 12     | `version_major`  | uint8       | `1` |
| 13     | `version_minor`  | uint8       | `0` |
| 14     | `header_bytes`   | uint16      | `256` |
| 16     | `has_mask`       | uint8       | `0` / `1` |
| 17     | `has_trailer`    | uint8       | `0` / `1` |
| 18     | `data_type_code` | uint8       | CArray type code (table below) |
| 19     | `ndim`           | uint8       | number of dimensions |
| 20     | `reserved0`      | uint32      | `0` (aligns `shape` to an 8-byte boundary) |
| 24     | `shape`          | int64\*16   | shape; front `ndim` slots valid |
| 152    | `element_bytes`  | uint32      | bytes per element |
| 156    | `flags`          | int32       | raw `ca->flags` snapshot (provenance; not read on load) |
| 160    | `elements`       | uint64      | total element count |
| 168    | `data_offset`    | uint64      | `256` in v1.x |
| 176    | `data_bytes`     | uint64      | `elements * element_bytes` |
| 184    | `mask_offset`    | uint64      | `0` if `!has_mask` |
| 192    | `mask_bytes`     | uint64      | `0` if `!has_mask` |
| 200    | `trailer_offset` | uint64      | `0` if `!has_trailer` |
| 208    | `trailer_bytes`  | uint64      | `0` if `!has_trailer` |
| 216    | `data_checksum`  | uint64      | `0` (reserved) |
| 224    | `checksum_algo`  | uint8       | `0` = none (reserved) |
| 225    | reserved         | zero-padded | to 256 |

Rules for forward compatibility:

- A writer **zeroes** every reserved byte.
- A reader **ignores** reserved bytes it does not understand, so a
  future writer may set them without breaking an older reader.
- The header is **authoritative** for shape, size, and mask/trailer
  presence.  Any duplicate of these in the trailer is diagnostic only; a
  reader seeing divergence should treat the file as corrupt.

`flags` is a verbatim snapshot of the source array's internal CArray
flags at write time — a provenance record of what the array was (scalar,
Face, view, read-only, …).  It is **not read on load** and has no bearing
on reconstruction; a reader that only wants the numbers can ignore it.

### C declaration

```c
#include <stdint.h>

struct ca3_header {
    char     magic[8];         /* "_CARRAY3"                */
    uint32_t endian_marker;    /* 0x01020304 in file order  */
    uint8_t  version_major;
    uint8_t  version_minor;
    uint16_t header_bytes;     /* 256                       */
    uint8_t  has_mask;
    uint8_t  has_trailer;
    uint8_t  data_type_code;
    uint8_t  ndim;
    uint32_t reserved0;        /* alignment                 */
    int64_t  shape[16];
    uint32_t element_bytes;
    int32_t  flags;            /* raw ca->flags snapshot    */
    uint64_t elements;
    uint64_t data_offset;
    uint64_t data_bytes;
    uint64_t mask_offset;
    uint64_t mask_bytes;
    uint64_t trailer_offset;
    uint64_t trailer_bytes;
    uint64_t data_checksum;
    uint8_t  checksum_algo;
    uint8_t  reserved[31];
};
_Static_assert(sizeof(struct ca3_header) == 256, "");
```

---

## Endianness

A `_CARRAY3` file is **single-endian throughout** — header integers and
the data region share one byte order.  There is no mixed-endian file: a
big-endian file is big-endian header, data, and all.  The order is
**self-describing** via `endian_marker` at offset 8; there is no separate
endian byte.

A writer emits everything in the host's native order (it never swaps on
write).  A reader decides once, for the whole file:

1. Read the 4 raw bytes at offset 8 and interpret them as a host
   `uint32`.  The writer stored `0x01020304` in file order, so it reads
   back as `0x01020304` when the file's order matches the host and as
   `0x04030201` when it differs.  Equivalently, the leading byte alone
   decides: `0x01` = big-endian file, `0x04` = little-endian file.
   Anything else means the file is corrupt or not `_CARRAY3`.
2. If the file's order differs from the host, byte-swap every header
   integer *and* every data element on read.  The int8 mask is never
   swapped.

Besides fixing the byte order, `endian_marker` doubles as a header
corruption cross-check: a valid file always reads it back as
`0x01020304` once interpreted in the file's own order.

---

## Data type codes

`data_type_code` (byte 18) is the CArray type code.  These codes are
stable: the enumeration is ABI-frozen and hole-preserving, so a dropped
type keeps its slot rather than shifting its neighbours.

| code | type       | element_bytes | PEP 3118 |
|-----:|------------|--------------:|----------|
| 0    | fixlen     | (variable)    | —        |
| 1    | boolean    | 1             | `?`      |
| 2    | int8       | 1             | `b`      |
| 3    | uint8      | 1             | `B`      |
| 4    | int16      | 2             | `h`      |
| 5    | uint16     | 2             | `H`      |
| 6    | int32      | 4             | `i`      |
| 7    | uint32     | 4             | `I`      |
| 8    | int64      | 8             | `q`      |
| 9    | uint64     | 8             | `Q`      |
| 10   | float32    | 4             | `f`      |
| 11   | float64    | 8             | `d`      |
| 13   | complex64  | 8             | `Zf`     |
| 14   | complex128 | 16            | `Zd`     |
| 16   | object     | —             | —        |

Codes 12 and 15 are retired slots (a former 128-bit float and 256-bit
complex) and are never emitted.  Code 16 (object) is never written to a
`_CARRAY3` file — see [Object arrays](#object-arrays).

Code 0 (`fixlen`) is a fixed-length byte record; `element_bytes` gives
the record size and, when the array has a `data_class`, the trailer
carries the field schema (see [The trailer](#the-trailer)).

The `PEP 3118` column is the single-character specifier used for member
types inside the trailer's `data_class` schema.  This mapping is owned
by the format: it currently coincides with CArray's MemoryView producer
notation, but the format freezes its own copy here so a future
MemoryView change does not alter the on-disk schema.

---

## Data region

Beginning at `data_offset`, the data region is `data_bytes =
elements * element_bytes` of raw, C-contiguous (row-major) elements in
the file's byte order.  `data_bytes` is a cross-check field — a reader
seeing `data_bytes != elements * element_bytes` should treat the file
as corrupt.

## Mask region

When `has_mask` is `1`, `mask_bytes = elements` bytes of `int8` begin
at `mask_offset`, one byte per element in the same C-contiguous order
as the data: `1` marks a masked (missing) element, `0` a present one.
The mask is `int8`, so it is byte-order neutral and never swapped.  A
reader that does not model missing values can ignore the mask; the data
bytes under a masked element are unspecified.

---

## The trailer

The trailer holds CArray-native metadata that has no place in a
language-neutral numeric buffer.  It is present only when there is
something to carry — an attribute Hash or a `data_class` schema — so a
plain numeric array writes no trailer at all.  Non-Ruby readers that
only want the numbers never need to touch it.

The trailer is **UTF-8 YAML in flow style** — one line that reads like
JSON, but with native `.inf` / `-.inf` / `.nan` literals for non-finite
Floats.  Any YAML parser (libyaml, PyYAML, …) reads it.  A reader
should load it in a safe mode that refuses arbitrary language-specific
object tags (CArray uses `Psych.safe_load`, which rejects `!ruby/object:`
tags).

```yaml
{attrs: {units: m/s, fillvalue: .inf, valid_range: [0.0, .inf]},
 data_class: {kind: struct, record_bytes: 20,
   members: [{name: lat, type: d, offset: 0, bytes: 8},
             {name: lng, type: d, offset: 8, bytes: 8},
             {name: id, type: i, offset: 16, bytes: 4}],
   name: MyRecord}}
```

### `attrs`

A mapping of user attributes attached to the array (units, fill
values, provenance strings, …).  Keys are strings; values are
JSON-compatible (string / number / bool / null / array / nested map)
plus non-finite Floats.

### `data_class`

Present when the array is a fixed-length record type (`data_type_code`
= 0) that carries a `data_class`.  Two layers:

**Layer 1 — portable** (`kind` / `record_bytes` / `members`) is always
present.  A non-Ruby reader uses this alone: given the raw record bytes
in the data region, it computes a pointer to each field from the
`offset` and `type` in `members[]`.

- `kind` — `"struct"` or `"union"`.
- `record_bytes` — bytes per record (equals `element_bytes`).
- `members` — a flat list of `{name, type, offset, bytes}`, where
  `type` is the bare PEP 3118 character from the table above.

In v1.0 a `data_class` schema describes **flat, primitive-typed members
only**.  Nested records, bitfields, and packed sub-byte columns cannot
be described in Layer 1 and cause `CArray.save` to raise (see
[What cannot be serialized](#what-cannot-be-serialized)).

**Layer 2 — Ruby-side, optional** (`name`) carries the fully-qualified
Ruby class name when the class has one.  A non-Ruby reader ignores it.
On load, Ruby resolves the class by name; if the name no longer exists,
it synthesises an anonymous record type from Layer 1 instead (field
access still works, but the original class identity is not restored).

---

## Reading the format

### FORTRAN

```fortran
character(len=8)          :: magic
integer(kind=8)           :: data_offset
real(kind=8), allocatable :: a(:,:)

open(unit=10, file="x.ca", access="stream", form="unformatted")
read(10, pos=1) magic
if (magic /= "_CARRAY3") stop "not a carray file"

! data_offset is at byte 169 (1-indexed); never hard-code 257 — a
! future version_minor could move the data.
read(10, pos=169) data_offset
allocate(a(m, n))
read(10, pos=data_offset + 1) a       ! +1: header offset is 0-indexed
close(10)
```

For a masked file, read `mask_offset` (byte 185) the same way and do a
second `read` at `mask_offset + 1`.  The example assumes the file's
byte order matches the host; for a cross-endian file (detect via
`endian_marker` at byte 9) swap the header integers and every data
element on read.

### C (mmap)

```c
#include <sys/mman.h>

void *p = mmap(NULL, sb.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
const struct ca3_header *h = p;

/* Single-endian file: if endian_marker reads swapped, the file's byte
   order differs from the host — swap every header integer (and later
   the data) before use.  On the common LE-host / LE-file path this
   branch is skipped. */
int swap = (h->endian_marker != 0x01020304u);
uint64_t data_off = swap ? bswap64(h->data_offset) : h->data_offset;

const double  *data = (const double  *)((const char *)p + data_off);
const int8_t  *mask = h->has_mask
    ? (const int8_t *)((const char *)p + (swap ? bswap64(h->mask_offset)
                                               : h->mask_offset))
    : NULL;   /* mask is int8, never swapped */
```

The trailer, if any, is UTF-8 YAML at `trailer_offset` (`trailer_bytes`
long); a reader that wants the attribute map or record schema parses it
with any YAML library in a safe-load mode.

---

## Object arrays

An array of arbitrary Ruby objects (`data_type_code` 16) cannot occupy
a fixed-offset raw region — there is no fixed-width value to lay down
and no data type to record — so it is **not serialisable by this
format**: `CArray.save` and `CArray.dump` raise `ArgumentError` on one.
Such an array has no portable representation; persist it through a
Ruby-only mechanism instead.
