# Text, fixed-length strings, and records

CArray's numeric types all store one value per element in a fixed number of
bytes. This chapter covers the corner of the library that reads *the bytes*
themselves as something structured — a short label, a variable-length UTF-8
string, or a fixed-width record with named fields.

Four representations of text arrays and one representation of struct arrays
share the same shape / mask / view algebra as the numeric types; from your
seat, choosing between them is a **storage trade-off**, not a different
API. The uniform surface is worth stating up front:

| type              | storage                                    | mutable | portable¹ | when to use                              |
|-------------------|--------------------------------------------|---------|-----------|-------------------------------------------|
| **`CAString`**    | one Ruby `String` per cell (`CA_OBJECT`)   | yes     | no        | general-purpose, arbitrary length / encoding |
| **`CAFixlenString`** | K bytes per cell (`CA_FIXLEN`)          | yes     | **yes**   | bounded-width columns; interchange / on-disk / stacking |
| **`CAConstString`** | int64 `(start, end)` pairs + one shared buffer | **no** | no    | large read-mostly label / key columns you sort, group, join on |
| raw `CA_FIXLEN`   | K bytes per cell, no string interpretation | yes     | yes       | actual byte blobs (record bodies, binary payloads) — not "strings" |
| **`CARecord`**    | K-byte record per cell (`CA_FIXLEN`) plus a struct schema | yes | **yes** | array of structs (named fields) |

¹ *portable* means the type survives multi-parent constructions (`CArray.stack`,
`Marshal`, MemoryView export as one block). Only fixed-width bytes are
self-contained; a shared string buffer and a Ruby object payload are
per-process.

The three string Faces are just different *readings* of underlying storage;
you can convert freely between them. `CARecord` is the same idea one level
up: it reads K bytes as a struct with named fields instead of as a string.

## Which string type to reach for

- **Just working with strings?** `CAString`. Ruby `String`s directly, any
  length, any encoding, fully mutable.
- **Fixed-width column** (a database `CHAR(K)`, a fixed record field, a column
  you want to `Marshal` / stack / export zero-copy)? `CAFixlenString`.
- **Big, read-mostly labels or keys** you sort / group / join on?
  `CAConstString` — one shared byte buffer plus `(start, end)` ranges, so
  slicing / gathering / sorting only rearranges the ranges.
- **A few distinct labels repeated many times** (a *category*)? Use the
  categorical type (see [Categories and grouping](24_categories_and_grouping.md)) —
  it stores each distinct value once plus a small code per element.
- **Actual byte blobs**, not strings? Raw `CA_FIXLEN`.

## Construction

All three Faces share the same construction conventions — a Ruby `Array` of
strings, a block form (with the arity-0 fill shortcut from
[Creating arrays](01_creating_arrays.md)), and `nil` cells as `UNDEF`:

```ruby
CArray.string(["alpha", "", "gamma"])           #  CAString
CArray.string(3) { |i| "item#{i}" }             #  block form
CArray.string(["a", nil, "b"])                  #  nil → masked element

CArray.fixlen_string(["ab", "cde"], bytes: 4)   #  CAFixlenString, slot width 4
CArray.fixlen_string(labels)                    #  width defaults to the widest value
CArray.fixlen_string(x, bytes: 3, truncate: :silent)   #  :error (default) | :silent

CArray.const_string(["alpha", "", "gamma"])     #  CAConstString
CArray.const_string(labels, encoding: Encoding::UTF_8)

CArray.new(CA_FIXLEN, [n], bytes: 3)            #  raw K-byte blobs (not a Face)
```

Two shared conventions to know about:

- **`nil` is a masked element; `""` is a valid empty string.** They are
  distinct: `nil` fetches as `UNDEF`, `""` is a real zero-length string.
- **A block of arity 0 is evaluated once and broadcast** — the same fill
  shortcut as `CArray.float64(n) { 1.0 }`. Use `{ |i| ... }` for per-element
  values.

Type-specific:

- **`fixlen_string`** — `bytes:` is the slot width (default: the widest
  input). A value longer than the slot at construction time is governed by
  `truncate:`: `:error` (default) raises, `:silent` keeps the leading `bytes`
  bytes. Once the array exists, a per-cell `fix[i] = long` always truncates
  silently — the fixed-width store has no length check.
- **`const_string`** — element encoding must match `:encoding` (default
  UTF-8); pure-ASCII passes regardless. Every element's bytes are stored
  once in logical order, with no offset-sharing dedup, so for a
  high-duplication column reach for `CACategorical` instead.

## Fetch, encoding, and padding

```ruby
CArray.string(["a"])[0]                      #  => "a"    (the stored Ruby String, its own encoding)
CArray.fixlen_string(["a"], bytes: 3)[0]     #  => "a"    (trailing NUL stripped; ASCII-8BIT)
CArray.const_string(["a"])[0]                #  => "a"    (frozen, in the column encoding)
CArray.new(CA_FIXLEN, [1], bytes: 3)
     .tap { |r| r[0] = "a" }[0]              #  => "a\x00\x00"   (raw bytes; no Face)
```

The important difference is that **`CAFixlenString` strips the trailing NUL
on fetch.** A fixed slot pads shorter strings with NUL bytes, and that
padding is *padding, not content*. `str_len`, `upcase`, and the other string
operations see the logical string (`"a"`, length 1), not the padded
`"a\x00\x00"`. The storage keeps the padding (so `bytes`, sorting, and
MemoryView still see the raw K bytes, and a raw `CA_FIXLEN` array returns
them intact), but the string reading hides it.

Fetched fixlen strings are `ASCII-8BIT` (no encoding tag on the storage);
`force_encoding` if you need one. `CAConstString` returns **frozen** strings
in the column's encoding.

Views (`ct[1..3]`, `ct[mask]`, transpose, gather) return the same Face class.
For `CAConstString` the view **shares the underlying buffer** — only the
`(start, end)` ranges are rearranged, no bytes are copied — which is what
makes a large read-mostly column cheap to slice.

## String operations

All three String Faces mix in a common set of string operations (numeric
arrays deliberately have none of these — that separation is a large part
of what makes the Faces earn their weight). The output category follows the
category of a plain `String` method: a String result is a `CAString`, an
Integer result an `:int` CArray, a Boolean result a `:boolean` CArray. Mask
and shape are carried.

```ruby
s = CArray.string(["  Foo ", "bar", "BAZ"])

# transforms → CAString
s.upcase        #  => ["  FOO ", "BAR", "BAZ"]
s.strip         #  => ["Foo", "bar", "BAZ"]
s.gsub("a", "@")
# also: downcase capitalize swapcase lstrip rstrip chomp
#       delete_prefix delete_suffix center ljust rjust
#       encode force_encoding scrub extract(regexp, repl='\0')

# predicates → :boolean
s.start_with?("B")   #  => [0, 0, 1]
s.end_with?("Z")
s.include?("a")
s.match?(/^[A-Z]+$/)

# set membership → :boolean (marks every matching cell)
s.in?("bar", "BAZ")  #  => [0, 1, 1]

# lengths / positions → :int
s.str_len            #  per-cell character length
s.bytesize
CArray.string(["banana", "raspberry"]).str_index("a")   #  per-cell substring position
CArray.string(["banana", "raspberry"]).rindex("a")

# numeric parse
CArray.string(["12", "x", "34"]).to_i   #  => [12, 0, 34]     (also to_f)
```

Two naming quirks are worth calling out. Methods use the plain Ruby `String`
name where it does not collide with a CArray method (`upcase`, `strip`,
`start_with?`, `to_i`, …). The few names that clash keep a `str_` prefix:
`str_len` and `str_index`, because `#length` and `#index` already mean
array-level things (element count, first-occurrence flat address).

In-place forms (`upcase!`, `strip!`, `gsub!`, …) exist on the **mutable**
Faces only — `CAString` and `CAFixlenString`. `CAConstString` is read-only
(that immutability is exactly what makes the shared buffer safe); the
transforms return a fresh `CAString` instead, which you can chain into
`.to_const_string` to re-compact.

### Numbers → strings: explicit format

A numeric array has no string reading, so the string builders reject it:

```ruby
CArray.string(int_array)          #  => CArray::DataTypeError
```

Turn numbers into strings explicitly with `#format` / `CArray.format`. This
is the only route:

```ruby
values.format("%03d")                       #  => CAString ["001", "042", ...]
labels.format("%s = %d", values)            #  interleave a second array
CArray.format("%s = %d", labels, values)    #  class form (scalars broadcast)
```

## Ordering and search

Ordering is by byte value (`memcmp`), which equals Ruby `String#<=>` within a
given encoding — so it is faithful to sorting the Ruby strings for the
common case where every element shares an encoding:

```ruby
a.sort         #  sorted, same Face class  (CAConstString: a no-copy view)
a.sort_copy    #  sorted, standalone       (owned copy)
a.sort_index   #  ascending permutation → :int
a.min / a.max  #  byte-extremum element (skips masked; nil / UNDEF if all-masked)
```

`sort` on a `CAConstString` is cheap precisely because it is a view: the
`(start, end)` pairs are gathered, the bytes never move. `sort_copy` gives an
owned, compacted result when you want an independent column.

The same three Faces support the search side:

```ruby
ct.search("foo")            #  flat index of the first match, or nil
ct.find_value_index("foo")  #  low-level primitive backing search
```

## Masks

A masked (`UNDEF`) cell prints as `_` and is skipped by mask-aware
operations. Same interface as any other CArray (see
[Masks and missing values](05_masks.md)):

```ruby
a = CArray.string(["a", "b", "c"])
a[1] = UNDEF
a.is_masked.to_a             #  => [false, true, false]
a.include?("b").to_a         #  => [false, UNDEF, false]    (masked cell propagates)
a.include?("b").count(true)  #  => 0
```

Assignment accepts `UNDEF`; on a `CAString` or `CAFixlenString` a `nil` in
the source literal is also read as `UNDEF`.

## Numeric gate

There is no meaningful numeric reduction of a string column, and CArray
refuses to produce one silently. `CAConstString` and `CAFixlenString`
present a `CA_FIXLEN` surface, so numeric kernels raise:

```ruby
ct.sum    #  => CArray::DataTypeError
ct.mean   #  => CArray::DataTypeError
```

`CAConstString`'s storage is `int64` `(start, end)` pairs — running a
numeric kernel over them would produce garbage; the gate prevents exactly
that. `CAString` is object-backed, so a numeric fold fails at the element
level with the same effect. Use the string operations and `sort` / `min` /
`max` above.

## Conversions between the Faces

The `to_*` family converts between the three String Faces (these are
String-Face methods, not on plain CArray). Each follows the `to_ca`
principle: **self, zero-copy** when self is already the target Face
compatibly, **materialise** (shape and mask carried) otherwise:

```ruby
face.to_string                              #  → CAString
face.to_fixlen_string(bytes: K, truncate:)  #  → CAFixlenString
face.to_const_string(encoding:)             #  → CAConstString
```

For example `ct.upcase` returns a `CAString`; chain `.to_const_string` (or
`.to_fixlen_string(bytes: K)`) to re-compact the transformed result into the
storage shape you want.

For a **non-Face** source — a raw `CA_FIXLEN` array or an object array of
Strings — use the builders instead. They accept a CArray directly: a raw
`CA_FIXLEN` reads as NUL-stripped strings; an object array of Strings wraps
zero-copy:

```ruby
CArray.string(obj_array)          #  CA_OBJECT of Strings → CAString (zero-copy wrap)
CArray.const_string(raw_fixlen)   #  K-byte blobs → CAConstString (padding stripped)
CArray.fixlen_string(raw_fixlen)  #  → CAFixlenString (zero-copy wrap)
```

## Interop and portability

Portability is what usually decides the type at a boundary:

- **`CAFixlenString`** is portable — its fixed-width bytes survive
  `CArray.stack`, `Marshal`, and MemoryView export. This is the type to
  reach for when the strings must cross a boundary as a single contiguous
  block.
- **`CAConstString`** and **`CAString`** are per-process (a shared buffer, or
  Ruby `VALUE`s on the heap), so they do not participate in those
  multi-parent constructions as one block. `copy` gives an independent
  in-process column; `to_fixlen_string(bytes: K)` gives a portable one.
- **Variable-length + MemoryView.** MemoryView is fixed-item-size and cannot
  represent a variable-length column in a single view. A `CAConstString`'s
  `(start, end)` pairs and byte buffer can be exported as two integer
  MemoryViews and reassembled out of band, but there is no single zero-copy
  MemoryView of "the strings".

The `CAConstString` buffer is a pure concatenation of the element bytes
(= the Apache Arrow values layout, no length prefix), so it can back an
Arrow string array directly, and an Arrow `String` / `LargeString` column
imports into a `CAConstString`.

## Raw `CA_FIXLEN`

For binary blobs — record bodies, packed structs, images, anything where
K bytes per cell is what you want and no string reading applies — reach for
raw `CA_FIXLEN` with no Face on top:

```ruby
a = CArray.new(CA_FIXLEN, [3], bytes: 4)
a[0] = "foo"
a[0]                       #  => "foo\x00"    (raw bytes; no NUL stripping)
```

Fetch, assignment, boolean masking, sort, and comparison all work — but they
all operate on the **raw bytes**, padding included. Comparisons therefore
have to match the cell width byte-for-byte:

```ruby
labels = CArray.new(CA_FIXLEN, [4], bytes: 5)
labels[] = ["red", "blue", "red", "green"]

labels.eq("red")           #  => [0, 0, 0, 0]     no match — "red" is 3 bytes
labels.eq("red\x00\x00")   #  => [1, 0, 1, 0]     padded to 5 bytes, now it matches

def pad(s, n) = s.ljust(n, "\x00")
labels.eq(pad("red", labels.bytes))   #  => [1, 0, 1, 0]
```

A `CAFixlenString` over the same storage strips the padding automatically —
that is exactly what the Face is for. Use raw `CA_FIXLEN` when the bytes
really are bytes; use `CAFixlenString` when they are strings.

## `CARecord` — array of structs

A `CARecord` is the array-of-structs Face: an array whose elements are
instances of a struct data class you defined, laid out as one fixed-width
record per cell. The record bytes live in an ordinary `CA_FIXLEN` entity;
the Face on top adds only the knowledge of *which struct class* those bytes
decode to.

### Defining the struct type

The element type is a `CAStruct` data class, built with the `CArray.struct`
DSL:

```ruby
GeoCoord = CArray.struct { float64 :lat; float64 :lng }
GeoCoord::DATA_SIZE         #  => 16   (bytes per record)

Pixel = CArray.struct { uint8 :r; uint8 :g; uint8 :b }
Pixel::DATA_SIZE            #  => 3
```

Field types are the usual numeric types (`int32`, `float64`, and so on).
The struct class knows its own byte size; that is what `CARecord` uses to
allocate the storage.

### Construction

Two entry points: allocate fresh storage, or wrap an existing entity.

```ruby
a = CARecord.new(GeoCoord, 5)          #  1-D, 5 records
CARecord.new(GeoCoord, 3, 4)           #  2-D, shape [3, 4]
a.class                                #  => CARecord
a.data_class                           #  => GeoCoord
a.parent.data_type                     #  => :fixlen

ent = CArray.new(CA_FIXLEN, [3], bytes: GeoCoord::DATA_SIZE)
w   = CARecord.wrap(ent, GeoCoord)     #  zero-copy wrap of an existing entity
```

Or pin the `data_class` on a named subclass — a natural home for domain
methods over the record array:

```ruby
class CAGeoCoord < CARecord
  data_class GeoCoord

  def centroid
    [self["lat"].mean, self["lng"].mean]
  end
end

g = CAGeoCoord.new(100)                #  no more data_class argument needed
```

`data_class` is immutable once declared — re-declaring it on the subclass
raises.

### Field access

Indexing a `CARecord` by **field name** projects a column view onto the
underlying bytes. The result is an ordinary numeric array you can compute
on — the Face is stripped, because a `lat` column of floats is no longer a
`GeoCoord`:

```ruby
a = CARecord.new(GeoCoord, 3)
a["lat"][] = [1.0, 2.0, 3.0]
a["lng"][] = [4.0, 5.0, 6.0]

a["lat"].to_a                #  => [1.0, 2.0, 3.0]     (an ordinary float64 view)
a["lat"].mean                #  => 2.0
```

The view shares storage with the record array, so writes flow back into it:

```ruby
a["lat"][] = CArray.float64(3).seq
a[0]["lat"]                  #  => 0.0    (assignment is visible on the record side)
```

Indexing by **integer** decodes a single cell to a struct instance:

```ruby
v = a[0]
v.class                      #  => GeoCoord
v[:lat]                      #  => 1.0
```

Field projection composes with the ordinary view algebra — a slice or
transpose of a `CARecord` can still project its fields:

```ruby
a[1..2]["lat"].to_a          #  => [1.0, 2.0]
```

### Masking

Masks work as they do for any Face — the mask is carried on the parent, and
masking a cell marks the whole record:

```ruby
a = CARecord.new(GeoCoord, 5)
a.mask = 0
a[2] = UNDEF
a.count_masked               #  => 1
a.mask.to_a                  #  => [false, false, true, false, false]
```

### Ordering — by bytes, not by field values

`CARecord` sorts and searches by the **raw record bytes** (`memcmp`), not
by any per-field comparison. Because floating-point fields are not
byte-order comparable, memcmp ordering of a record generally does *not*
match the numeric ordering of any single field:

```ruby
a = CARecord.new(GeoCoord, 3)
a["lat"][] = [3.0, 1.0, 2.0]
a["lng"][] = [0.0, 0.0, 0.0]
a.sort_index.to_a            #  => [1, 2, 0]   byte order — not numeric lat order
```

To sort by a field's value, sort **that field's projection** and gather the
records by the resulting index:

```ruby
order = a["lat"].sort_index  #  sort by lat numerically
a[order]                     #  records reordered by lat
```

The projection carries the field's numeric semantics, so the sort is
faithful; the gather then reorders the records by the numeric ranking.

### Arithmetic is off

`CARecord` presents a `CA_FIXLEN` surface, which gates numeric kernels off:

```ruby
a + a     #  => CArray::DataTypeError
```

`record + record` is meaningless (what would it even mean?), and CArray
prefers to say so loudly rather than silently produce a byte-sum of the two
fixed blobs. Do the arithmetic on the field projections instead.

### Portability

The record bytes travel: `CArray.save` / `CArray.load` (see
[Input and output](19_input_output.md)) round-trip a `CARecord` as raw
bytes, and MemoryView export works. The binary format carries the bytes
only — the `data_class` identity is not embedded, so on load you re-supply
it by loading into a `CARecord` of the right type.

## Quick recap

- Four representations of text arrays plus one representation of struct
  arrays share CArray's shape / mask / view algebra; choose by storage
  properties, not by API.
- `CAString` for general-purpose Ruby strings, `CAFixlenString` for
  bounded-width portable columns, `CAConstString` for large read-mostly
  label / key columns, raw `CA_FIXLEN` for actual byte blobs.
- The three Faces share one string-operation surface (transforms /
  predicates / lengths / positions), converting freely between them with
  `to_string` / `to_fixlen_string` / `to_const_string`.
- Ordering is by bytes (`memcmp`); numeric kernels are gated off; numbers →
  strings is always the explicit `#format`.
- `CARecord` reads K bytes as a struct with named fields; `a["field"]` is a
  live projection you can compute on, `a[i]` decodes to a struct instance,
  and sorting must go through a field projection because the whole-record
  sort is by raw bytes.
