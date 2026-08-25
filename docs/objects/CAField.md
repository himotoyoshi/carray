# CAField — a field-of-a-record view

`CAField` is the view class behind `CArray#field`. It exposes **one
field, at a fixed byte offset inside each element of a parent array**, as
an array of that field's own type. It is how you reach into records:
reinterpret the low half of a `uint32`, pull a single column out of a
fixlen-record parent, or project a struct member.

```
parent = uint32[ 0x00010002, 0x00030004, ... ]      element = 4 bytes

  record layout (little-endian):
    byte 0..1  ┐ low  uint16
    byte 2..3  ┘ high uint16

parent.field(0, CA_UINT16)   →  [0x0002, 0x0004, ...]   (low half)
parent.field(2, CA_UINT16)   →  [0x0001, 0x0003, ...]   (high half)
```

No data is copied: a `CAField` reads and writes the parent's bytes in
place. It is a pure `CAStride` view — the field is just a base offset plus
a stride scaled to the parent's element size.

This document is the reference for the `CAField` view and the
`CArray#field` method. For fixlen text specifically, see
[StringArrays.md](../topics/StringArrays.md); for schema-carrying record arrays, see
[CARecord.md](CARecord.md).

---

## 1. What a CAField is

`CAField` wraps **one parent CArray** and describes a field within each of
its elements:

- **`offset`** — the field's byte offset inside one parent element
- **`data_type`** — the field's own element type (independent of the
  parent's)
- **`bytes`** — the field's element size

The view has the **same shape as the parent** — each output element maps
one-to-one to a parent element, reading the `bytes`-wide window at
`offset`:

```
result.ndim  == parent.ndim
result.shape == parent.shape
```

Internally it is a `CAStride` with `base_offset = offset` and a row-major
byte stride scaled by the parent's element size (`parent.bytes`), so each
step lands in the same offset of the next record.

```ruby
require "carray"

a = CArray.uint32(4)
a[] = [0x00010002, 0x00030004, 0x00050006, 0]

f = a.field(0, CA_UINT16)     # low uint16 of each element
f.class                       #=> CAField
f.to_a                        #=> [2, 4, 6, 0]   (0x0002, 0x0004, ...)

fh = a.field(2, CA_UINT16)    # high uint16 (bytes 2..3)
fh.to_a                       #=> [1, 3, 5, 0]
```

> Byte order follows the platform (little-endian on most machines), since
> `CAField` reinterprets the parent's raw bytes without conversion.

---

## 2. Creating a CAField — `CArray#field`

`field` has four call forms. The one you get depends on the second
argument.

### 2.1 `field(offset, data_type, bytes: nil)` — plain field

Returns a `CAField` of element type `data_type` at byte `offset`. `bytes`
is required for `:fixlen` and inferred for fixed-width types.

```ruby
a.field(0, CA_UINT16)              # low 2 bytes as uint16
a.field(4, CA_FLOAT32)             # float32 at offset 4
a.field(8, :fixlen, bytes: 6)      # 6-byte text field at offset 8
```

Constraints (checked at construction):

```ruby
a.field(-1, CA_UINT16)   # RuntimeError: negative offset
a.field(3, CA_UINT16)    # RuntimeError: offset + bytes (5) exceeds one 4-byte record
a.field(0, CA_OBJECT)    # CArray::DataTypeError: CA_OBJECT can not be a data_type for CAField
```

`CA_OBJECT` is rejected because there are no fixed-width bytes to
reinterpret — a field is a byte window, and Ruby objects are not stored
inline.

### 2.2 `field(offset, template)` — struct-of-array subview

When the second argument is a **CArray template**, the field takes
`template.elements * template.bytes` bytes at `offset` and exposes them
with the template's element type and *trailing* shape. The result is a
`CARefer` over the `CAField`, with the template's dimensions appended to
the parent's:

```ruby
rec = CArray.fixlen(3, bytes: 8)   # 3 records, 8 bytes each
t   = CArray.float32(2)            # template: two float32 = 8 bytes

sub = rec.field(0, t)
sub.class                          #=> CARefer
sub.dim                            #=> [3, 2]   (parent shape + template shape)
```

This is the natural way to read a small fixed-size array member out of
each record.

### 2.3 `field(offset, data_class)` — record-typed field

When the second argument is a **data class** (e.g. a `CAStruct`
subclass), the `CAField` is wrapped in a `CARecord` so the result carries
the class's encode/decode dispatch — element access returns decoded
instances rather than raw bytes. See [CARecord.md](CARecord.md).

### 2.4 `field(name)` — named field

The one-argument form resolves a field **by name** through the parent's
Face/record schema (delegates to the Face layer). It works on record
arrays that carry a schema, such as `CARecord`:

```ruby
a = CARecord.new(GeoCoord, 3)
a.field(0)          # the first field by index → CAField
a["lat"]            # by name (the usual idiom; a.field("lat") is equivalent)
```

For schema-backed arrays the named form is normally spelled `arr["name"]`.

---

## 3. It is a view — writes reach the parent

`CAField` copies nothing. Writing through the field updates exactly the
field's bytes inside each parent element; the rest of the element is
untouched:

```ruby
a = CArray.uint32(4)
a[] = [0x00010002, 0x00030004, 0x00050006, 0]

f = a.field(0, CA_UINT16)     # low half
f[0] = 0xABCD

"0x%08X" % a[0]               #=> "0x0001ABCD"   (high half preserved)
```

This write-through is what makes `field` a projection rather than a copy:
a `CARecord` built on a fixlen parent lets each column
(`a["lat"][] = ...`) flow straight back into the packed record bytes.

To get an independent, detached array instead, materialise with `copy`
(always a fresh entity) — see the view-vs-owned semantics in the project
docs.

---

## 4. Masks

`CAField` participates in CArray's unified mask system through its
`CAStride` base; the companion mask class is `CAFieldMask`. A masked
parent is reflected in the field view.

---

## 5. Cost model

- **Construction** is O(1): the view stores an offset and computed
  strides, no data.
- **Reading / writing a cell** is a single strided access into the
  parent's bytes — no per-cell conversion.
- **Materialising** (`to_ca` / `copy` / feeding a kernel) gathers the
  field into a contiguous buffer of `parent.elements` elements. Because
  `CAField` is a pure `CAStride`, contiguous or mergeable layouts take the
  fast strided-copy paths.

---

## 6. Quick reference

| call | result |
|---|---|
| `a.field(offset, data_type)` | `CAField`, same shape as `a`, field type `data_type` |
| `a.field(offset, :fixlen, bytes: n)` | `CAField` of an `n`-byte text field |
| `a.field(offset, template)` | `CARefer` subview, shape `a.shape + template.shape` |
| `a.field(offset, data_class)` | `CARecord` carrying the class's encode/decode |
| `a.field(name)` | field resolved by name via the record schema |
| offset check | `offset >= 0` and `offset + bytes <= a.bytes`, else `RuntimeError` |
| `:object` | rejected (`CArray::DataTypeError`) |
| read/write | goes through to the parent's bytes in place |

## See also

- [StringArrays.md](../topics/StringArrays.md) — fixlen byte-string arrays, the
  most common `field` parent.
- [CARecord.md](CARecord.md) — schema-carrying record arrays and named
  field projection.
- [CAFarray.md](CAFarray.md) — sibling pure-`CAStride` view (Fortran
  order).
