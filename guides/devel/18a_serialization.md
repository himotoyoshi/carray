# 18a — Serialization: the `_CARRAY3` format and Marshal

Where ch. 18 covers *live* zero-copy interop (MemoryView), this chapter covers
the *persistent* byte formats: the portable `_CARRAY3` container behind
`CArray.save` / `CArray.load` / `CArray.dump`, and the Ruby `Marshal`
integration that rides on it. Both are implemented in **pure Ruby**
(`lib/carray/serialize.rb`, autoloaded); the only C involvement is the raw
payload writer/reader (`dump_binary` / `load_binary` in
`ext/carray_conversion.c`), which streams the element bytes without building
an intermediate String.

The 2.x `_CARRAY_` format was **removed** in 3.0 — there is no legacy reader.
`_CARRAY3` is a clean 3.0 design with one governing promise:

> **The raw numeric payload lives at a fixed byte offset in a single
> file-wide byte order.** A reader in C, FORTRAN, or any language with raw
> file access reaches the data with one seek and never parses any
> Ruby-specific metadata.

Everything CArray-native — the attribute Hash, a record `data_class` schema,
the mask — rides in a text trailer at the tail that non-Ruby readers skip.
The intended scope is **workflow handoff** (dump a result, hand it to the
next process, consume, discard), not long-term archival; archival storage
should export to a mature container (NetCDF, HDF5, Parquet, …).

## 18a.1 Surface and code layout

| method | direction | destination / source |
|---|---|---|
| `CArray.save(ca, output, **opt)` | serialize | file path or open IO |
| `CArray.dump(ca, **opt)` | serialize | returns a binary String |
| `CArray.load(input, **opt)` | deserialize | path, in-memory payload String, or IO |

All three delegate to `CArray::Serializer` (`lib/carray/serialize.rb`), a
`:nodoc:` class wrapping an IO (`StringIO` for the String forms). `load`
distinguishes an in-memory payload from a filename by the magic string: a
String beginning with `"_CARRAY3"` and at least a header long is decoded in
place; any other String is treated as a path.

The **type mapping is owned by serialize.rb** — the on-disk `data_type_code`
values and the PEP 3118 member characters used in the trailer schema are
frozen copies held by the format, deliberately decoupled from the MemoryView
producer so a future MemoryView change cannot alter on-disk bytes.

Two failure classes at the boundary:

- `save` / `dump` raise `ArgumentError` for a **CA_OBJECT** array (no
  fixed-width portable representation — see §18a.7) and for a `data_class`
  the v1.0 flat-primitive schema cannot express (bitfield members, nested
  records, fixlen/CArray-template members).
- `load` raises `RuntimeError` on a bad magic, an unsupported version, or a
  failed corruption cross-check (`endian_marker`, `data_bytes`).

## 18a.2 File structure

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

The Data region always begins at `data_offset` (256 in v1.x). Mask and
Trailer are present only when the header says so, at explicit header offsets
— a reader never computes their positions by hand.

### The header

A fixed 256-byte block. All multi-byte integers are stored in the **file's
byte order**; a reader determines that order from `endian_marker` before
interpreting anything else.

| offset | field            | type        | notes |
|-------:|------------------|-------------|-------|
| 0      | `magic`          | char\*8     | `"_CARRAY3"` |
| 8      | `endian_marker`  | uint32      | `0x01020304` in file order |
| 12     | `version_major`  | uint8       | `1` |
| 13     | `version_minor`  | uint8       | `0` |
| 14     | `header_bytes`   | uint16      | `256` |
| 16     | `has_mask`       | uint8       | `0` / `1` |
| 17     | `has_trailer`    | uint8       | `0` / `1` |
| 18     | `data_type_code` | uint8       | CArray type code (§18a.4) |
| 19     | `ndim`           | uint8       | |
| 20     | `reserved0`      | uint32      | `0` (aligns `shape` to 8 bytes) |
| 24     | `shape`          | int64\*16   | front `ndim` slots valid |
| 152    | `element_bytes`  | uint32      | |
| 156    | `flags`          | int32       | raw `ca->flags` snapshot (provenance only) |
| 160    | `elements`       | uint64      | |
| 168    | `data_offset`    | uint64      | `256` in v1.x |
| 176    | `data_bytes`     | uint64      | `elements * element_bytes` (cross-check) |
| 184    | `mask_offset`    | uint64      | `0` if `!has_mask` |
| 192    | `mask_bytes`     | uint64      | `0` if `!has_mask` |
| 200    | `trailer_offset` | uint64      | `0` if `!has_trailer` |
| 208    | `trailer_bytes`  | uint64      | `0` if `!has_trailer` |
| 216    | `data_checksum`  | uint64      | `0` (reserved) |
| 224    | `checksum_algo`  | uint8       | `0` = none (reserved) |
| 225    | reserved         | zero-padded | to 256 |

Forward-compatibility rules: a writer **zeroes** every reserved byte; a
reader **ignores** reserved bytes it does not understand; the header is
**authoritative** for shape, size, and mask/trailer presence (any duplicate
in the trailer is diagnostic only — divergence means corruption).

`flags` is a verbatim snapshot of `ca->flags` at write time — a provenance
record of what the array was (scalar, Face, view, read-only, …). It is
**not read on load** and has no bearing on reconstruction. This is the one
place internal flag bits escape to disk, which is part of why the flag
enumeration is treated as ABI-frozen.

The equivalent C declaration (`_Static_assert(sizeof == 256)`):

```c
struct ca3_header {
    char     magic[8];         /* "_CARRAY3"                */
    uint32_t endian_marker;    /* 0x01020304 in file order  */
    uint8_t  version_major, version_minor;
    uint16_t header_bytes;     /* 256                       */
    uint8_t  has_mask, has_trailer, data_type_code, ndim;
    uint32_t reserved0;
    int64_t  shape[16];
    uint32_t element_bytes;
    int32_t  flags;
    uint64_t elements, data_offset, data_bytes;
    uint64_t mask_offset, mask_bytes, trailer_offset, trailer_bytes;
    uint64_t data_checksum;
    uint8_t  checksum_algo;
    uint8_t  reserved[31];
};
```

## 18a.3 Endianness

A `_CARRAY3` file is **single-endian throughout** — header integers and the
data region share one byte order; there is no mixed-endian file and no
separate endian byte. The order is self-describing via `endian_marker`: the
writer stores `0x01020304` in file order, so the raw bytes at offset 8 read
`01 02 03 04` on a big-endian file and `04 03 02 01` on a little-endian one —
the leading byte alone decides, and anything else marks the file as corrupt
(the marker doubles as a header corruption cross-check).

On the write side, the default is the host's native order with **no swap on
write**. `save(..., endian: CA_BIG_ENDIAN)` forces the output order; when it
differs from the host, the implementation writes `ca.swap_bytes` — a
byte-swap **view** — through `dump_binary`, so the swap streams through the
raw writer without materialising a swapped copy. On the read side, `load`
detects the file order and swaps header integers and data elements into the
host order when they differ. The int8 mask is byte-order neutral and is
never swapped.

## 18a.4 Data type codes

`data_type_code` is the CArray type code, and the enumeration is
**ABI-frozen and hole-preserving**: a dropped type keeps its slot rather
than shifting its neighbours, so codes on disk stay meaningful forever.

| code | type | bytes | PEP 3118 |
|-----:|------|------:|----------|
| 0 | fixlen | (variable) | — |
| 1 | boolean | 1 | `?` |
| 2 / 3 | int8 / uint8 | 1 | `b` / `B` |
| 4 / 5 | int16 / uint16 | 2 | `h` / `H` |
| 6 / 7 | int32 / uint32 | 4 | `i` / `I` |
| 8 / 9 | int64 / uint64 | 8 | `q` / `Q` |
| 10 / 11 | float32 / float64 | 4 / 8 | `f` / `d` |
| 13 / 14 | complex64 / complex128 | 8 / 16 | `Zf` / `Zd` |
| 16 | object | — | never written |

Codes 12 and 15 are the retired slots of the dropped `long double` family
(a former 128-bit float and 256-bit complex) — hole preservation in action.
Code 0 (`fixlen`) is a fixed-length byte record: `element_bytes` gives the
record size, and when the array carries a `data_class` the trailer holds the
field schema.

## 18a.5 Data and mask regions

The data region is `elements * element_bytes` of raw, C-contiguous
(row-major) elements in the file's byte order, written by `dump_binary` —
which, for a view, attaches and streams rather than materialising a String
copy first (the streaming discipline of ch. 20). `data_bytes` is a
redundancy check: a reader seeing `data_bytes != elements * element_bytes`
should treat the file as corrupt.

When `has_mask` is 1, the mask region is `elements` bytes of int8 in the
same C-contiguous order: `1` = masked, `0` = present. Two contract points a
maintainer must keep:

- **the data bytes under a masked element are unspecified** — this is the
  serialized manifestation of the "mask is not protection" doctrine (a
  masked cell's payload is outside the contract, so kernels are free to
  leave anything there);
- a reader that does not model missing values may ignore the mask entirely.

## 18a.6 The trailer

The trailer exists only when there is semantic content to carry — an
attribute Hash or a `data_class` schema. A plain numeric array writes no
trailer at all, keeping the foreign-reader path "header + raw data" exactly.

Encoding is **UTF-8 YAML in flow style** — one line that reads like JSON but
with native `.inf` / `-.inf` / `.nan` literals, so non-finite Float
attributes survive (JSON proper cannot express them, which is why YAML was
chosen). Decoding uses `Psych.safe_load` with an empty permitted-class list
and aliases off — the symmetric guardrail that refuses `!ruby/object:` tags,
so a hostile trailer cannot instantiate arbitrary Ruby objects.

```yaml
{attrs: {units: m/s, fillvalue: .inf},
 data_class: {kind: struct, record_bytes: 20,
   members: [{name: lat, type: d, offset: 0, bytes: 8},
             {name: lng, type: d, offset: 8, bytes: 8},
             {name: id, type: i, offset: 16, bytes: 4}],
   name: MyRecord}}
```

`attrs` carries the user attribute Hash (string keys; JSON-compatible values
plus non-finite Floats).

`data_class` has two layers, and the split is the point:

- **Layer 1 — portable** (`kind` / `record_bytes` / `members`): always
  present, and sufficient alone for a non-Ruby reader — each member is a
  flat `{name, type, offset, bytes}` with a bare PEP 3118 type character.
  v1.0 describes **flat, primitive-typed members only**; a `data_class`
  with a bitfield, nested record, or non-primitive member makes `save`
  raise rather than write a schema it cannot express (loud failure over a
  silently lossy file).
- **Layer 2 — Ruby-side, optional** (`name`): the fully-qualified Ruby class
  name when the class has one. On load, Ruby resolves it with `const_get`;
  if the constant no longer exists, an anonymous record type is synthesised
  from Layer 1 instead — field access still works, class identity is not
  restored. (Full Face-identity preservation through serialization is a
  known deferred item; the trailer schema deliberately does not attempt it
  in v1.0.)

## 18a.7 The Marshal path

`CArray#marshal_dump` / `#marshal_load` (autoloaded from the same file) make
`Marshal.dump(ca)` work, and they are a thin shell over the portable format:

```ruby
def marshal_dump
  target = (self.class != CArray and self.class != CScalar) ? self.copy : self
  if target.data_type == :object
    ["object", target.shape, target.value.to_a,
     (target.has_mask? ? target.mask.to_a : nil)]
  else
    ["portable", CArray.dump(target)]
  end
end
```

Three design points:

- **Views and subclasses are copied first.** A Marshal payload always
  describes an owning entity — a view's structure (its parent chain) is not
  serialized, only its values. `marshal_load` reconstitutes via
  `initialize_copy`, so the loaded object is a plain entity.
- **The numeric path is the portable format**, tagged `"portable"` — one
  wire format to maintain, and Marshal inherits its endian handling and
  trailer semantics for free.
- **CA_OBJECT arrays exist only here.** They are rejected by the portable
  format (no fixed-width representation, nothing to put in
  `data_type_code`'s raw region), but Marshal is Ruby-only anyway, so the
  `"object"` tag carries `value.to_a` / `mask.to_a` and lets Marshal
  serialize the member objects itself.

## 18a.8 Reading the file from other languages

The design target — one seek to the numbers — in practice:

```fortran
open(unit=10, file="x.ca", access="stream", form="unformatted")
read(10, pos=1) magic                  ! "_CARRAY3"
read(10, pos=169) data_offset          ! never hard-code 257
read(10, pos=data_offset + 1) a        ! +1: header offsets are 0-indexed
```

```c
void *p = mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0);
const struct ca3_header *h = p;
int swap = (h->endian_marker != 0x01020304u);
uint64_t off = swap ? bswap64(h->data_offset) : h->data_offset;
const double *data = (const double *)((const char *)p + off);
```

A reader should take `data_offset` from the header rather than assuming 256:
a future `version_minor` could move the data, and the header contract
guarantees the offset fields stay put.

## 18a.9 Maintainer's checklist

- **Never renumber a type code.** Retired types keep their slots (12, 15).
  A new type takes a fresh code and a row in serialize.rb's frozen tables.
- **The format owns its type notation.** Do not "simplify" by pointing the
  trailer's member characters at the MemoryView producer's table — the
  whole point of the frozen copy is that MV can evolve without rewriting
  what old files mean.
- **Header changes go through reserved space.** New metadata takes reserved
  bytes (readers already ignore them) or a `version_minor` bump; moving
  existing fields is a `version_major` event.
- **Keep the raise surface honest.** Anything the schema cannot express
  must raise at `save`, never write a lossy file that loads as something
  subtly different.
- **Keep the trailer safe-load symmetric.** If the writer ever emits a new
  YAML construct, confirm `Psych.safe_load(permitted_classes: [])` still
  reads it; never widen the permitted classes.
