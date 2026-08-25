# Interoperating with Apache Arrow

CArray interoperates with [Apache Arrow](https://arrow.apache.org/) in
both directions, without a dedicated bridge library. As a **consumer**
it takes an Arrow array — its values and its null (validity) information —
and turns it into a native CArray with a mask (§1–§8). As a **producer**
it hands a CArray to red-arrow so downstream Arrow consumers can read it
(§9). Values ride Ruby's MemoryView protocol on the import side; the
validity bitmap is unpacked with the `bitarray` view, and packed back
with `pack_bits` on the export side.

This document shows the recommended flow with
[red-arrow](https://github.com/apache/arrow/tree/main/ruby/red-arrow)
(`require "arrow"`), the reasoning behind each step, and where the
cost actually goes.

---

## 1. The shape of the problem

An Arrow array carries two pieces:

- a **values buffer** — contiguous, typed (`int32`, `float64`, …),
- a **validity bitmap** — one *bit* per element, bit-packed,
  **`1` = valid, `0` = null**. It is omitted entirely when the array
  has no nulls.

A CArray carries the mirror of that: a typed data buffer plus a
**mask** (one boolean *byte* per element, **`true` = masked = absent**).
So the mapping is:

| Arrow | CArray |
|---|---|
| values buffer | data buffer |
| validity bit `1` (valid) | mask `false` (present) |
| validity bit `0` (null) | mask `true` (masked) |

The values line up directly. The validity bitmap needs two things:
**unpacking** (bit → byte) and **inversion** (valid → masked).

---

## 2. Combine chunks first

A `ChunkedArray` (what you usually get out of a column) is a list of
`Arrow::Array` chunks, each with its own buffers and its own logical
`offset` into them. Rather than iterate chunk-by-chunk and track
offsets, **combine into a single contiguous array first**:

```ruby
arr = chunked_array.combine   # => one Arrow::Array, offset 0, one buffer pair
```

`combine` gives a fresh contiguous array (`offset == 0`, one values
buffer, one validity bitmap), which makes the import a single pass with
no per-chunk bookkeeping.

`combine` copies the chunks into one new buffer, so the import owns its
data from here on. That is what you want: the result is a plain,
writable CArray you can use directly — read it, modify it, feed it to any
CArray operation — with no tie back to Arrow's memory. (A zero-copy read-only wrap of a
single un-combined chunk with `wrap_memory_view` is still available when
you specifically want a transient read-only lens onto Arrow's memory —
but that is a different workflow from this chapter's combine-first path.
A multi-chunk zero-copy variant that welds K chunks into a single
`CAMeld` view is also possible for library / class authors; see §6.)

---

## 3. Values — through MemoryView

`CArray.from_memory_view` imports the values buffer, inferring the data
type from Arrow:

```ruby
value = CArray.from_memory_view(arr)   # int32 Arrow array -> CA_INT32 CArray
```

The returned CArray owns its buffer (a copy). Null slots hold whatever
Arrow left there (typically `0`); the mask built next marks them.

### 3.1 Which Arrow types a CArray can hold

`from_memory_view` works only when Arrow's values buffer is a
**contiguous array of fixed-width elements** — that is what a CArray *is*.
Arrow has many types that are not that shape, so not every `Arrow::Array`
can become a CArray. The groups:

**Import directly** — one Arrow element, one fixed-width cell, one CArray
`data_type`:

| Arrow type | CArray `data_type` |
|---|---|
| `Int8/16/32/64`, `UInt8/16/32/64` | matching `int*` / `uint*` |
| `Float`, `Double` | `float32`, `float64` |
| `Date32`, `Time32` | `int32` (raw count) |
| `Date64`, `Time64`, `Timestamp` | `int64` (raw count) |

For the temporal types `from_memory_view` gives you the **underlying integer
count** — days, milliseconds, microseconds, whatever the Arrow unit is — not a
date/time object. To carry the unit across, wrap that raw storage in a `CATime`,
whose base units line up one-to-one with Arrow's (`:D`, `:s`, `:ms`, `:us`,
`:ns`, …):

```ruby
raw = CArray.from_memory_view(ts_array)   # Timestamp[us] -> CA_INT64 (raw count)
dt  = CATime.wrap(raw, unit: :us)         # zero-copy Face; the count now means "us since epoch"
```

`CATime` storage is `int64`, so the `int64` temporals (`Date64`, `Time64`,
`Timestamp`) wrap **zero-copy** — mutating `raw` shows through `dt`. The `int32`
temporals (`Date32`, `Time32`) must widen to `int64` first, one copy, before
wrapping:

```ruby
raw = CArray.from_memory_view(date_array)   # Date32 -> CA_INT32 (day count)
dt  = CATime.wrap(raw.int64, unit: :D)      # widen int32 -> int64, then Face-wrap
```

Epoch is 1970 and the clock is naive UTC, so a `Timestamp`'s timezone, if any,
is not applied. See [CATime.md](../topics/CATime.md).

**Import as an N-dimensional column** — a `FixedSizeList(N)` gives every row
exactly `N` values, so a column of `M` rows is really a rectangular `M × N`
block: an ordinary CArray of shape `[M, N]`, the per-row vectors stacked along
axis 0 (the outermost axis is the row axis, the fixed size `N` the trailing
one). Because it is fixed-length there are no per-row offsets — the child is a
flat run of `M × N` values — so it lands as a plain numeric array, not an
object column. Read the child element type, then reshape the values to `[M, N]`:

```ruby
ARROW_TO_CA = {
  Arrow::Int8DataType   => :int8,   Arrow::UInt8DataType  => :uint8,
  Arrow::Int16DataType  => :int16,  Arrow::UInt16DataType => :uint16,
  Arrow::Int32DataType  => :int32,  Arrow::UInt32DataType => :uint32,
  Arrow::Int64DataType  => :int64,  Arrow::UInt64DataType => :uint64,
  Arrow::FloatDataType  => :float32, Arrow::DoubleDataType => :float64,
}

# An Arrow FixedSizeListArray (fixed-width child) -> an [M, N] CArray.
def ndarray_from_arrow(fsl)
  m    = fsl.length
  n    = fsl.value_data_type.list_size
  dsym = ARROW_TO_CA.fetch(fsl.value_data_type.field.data_type.class)

  grid = CArray.send(dsym, m * n)
  grid[] = fsl.to_a.flatten           # M*N values in row order
  grid.reshape(m, n)                  # -> shape [M, N]
end
```

Row-level validity maps to the mask the same way as everywhere else (§4): a
null row masks that whole row of the `[M, N]` array. This is the natural home
for fixed-dimension vectors — coordinates, RGB, fixed-length embeddings.

`CAFrame`, CArray's data frame, holds **N-dimensional columns** directly, so
such a block drops straight in as one column — the frame's row count is `M`,
the column keeps its inner width:

```ruby
require "carray/frame"

emb = ndarray_from_arrow(fsl)            # shape [M, 3]
f   = CAFrame.new("emb" => emb)
f                                        # => #<CAFrame nrow=M vars=[emb:float64[3]]>
f["emb"][0, nil]                         # row 0's whole vector
```

A nested `FixedSizeList(FixedSizeList(K), N)` just adds another trailing axis
(`[M, N, K]`), by the same reasoning applied one more level in.

**Import from `Arrow::Tensor`** — Arrow's tensor (a single N-D numeric
object, not a column) is the mirror of §9.1's Tensor export. Unlike
the FixedSizeList column path, `Arrow::Tensor` does not implement the
MemoryView protocol on the producer side (verified: `from_memory_view`
rejects it — a red-arrow-side gap symmetric with §8 and §9.7). The
recipe uses `load_binary` directly on the tensor's underlying byte
buffer:

```ruby
# An Arrow::Tensor (fixed-width numeric) -> an owned CArray of matching shape.
def carray_from_arrow_tensor(tensor)
  dsym = ARROW_TO_CA.fetch(tensor.value_data_type.class)
  ca   = CArray.send(dsym, *tensor.shape)
  ca.load_binary(tensor.buffer.data.to_s)
  ca
end
```

This mirrors red-arrow-numo-narray's `Tensor#to_narray`. `Arrow::Tensor`
has no validity buffer, so no mask is imported. Byte layout is Arrow's
row-major, matching CArray's — no reshape or transpose is needed.

**Import through the bit codec, not `from_memory_view`** — `Boolean` is
bit-packed, one bit per element, exactly like the validity bitmap. So
`from_memory_view` rejects it, but the same `load_binary` + `bitarray`
codec from [§4.2](#42-bitarray-as-a-packed-bit-codec) unpacks it:

```ruby
b     = Arrow::BooleanArray.new([true, false, true, true])
n     = b.length
bytes = CArray.uint8(b.data_buffer.size)
bytes.load_binary(b.data_buffer.data.to_s)
bits  = bytes.bitarray[0...n]            # => CArray boolean, one byte per bit
```

(Its nulls, if any, live in a *separate* validity bitmap and are unpacked
by §4 as usual — a boolean Arrow array has two bit buffers, values and
validity, handled by the same trick.)

**Import into a string column, not a numeric CArray** — `String`,
`LargeString`, and `Binary` are variable-length (an offsets array plus a
shared byte buffer). No fixed-width MemoryView can express that, so
`from_memory_view` rejects them. But CArray *does* have a home for them:
`CAConstString`, its read-only variable-length string column, laid out
Arrow-style — one shared byte buffer holding the element bytes as a **pure
concatenation** (= Arrow's values buffer), with an `int64` `(start, end)`
byte-range pair per element. The import is a copy, but a cheap one: pull the
Arrow buffers in bulk (no per-element boxing) and write them straight into the
column's storage. Combine first (§2) so the array is a single buffer at offset 0:

```ruby
# An Arrow utf8 / large_utf8 array -> an owned CAConstString.
def const_string_from_arrow(arr)
  n      = arr.length
  large  = arr.is_a?(Arrow::LargeStringArray)   # int64 offsets vs int32
  values = arr.data_buffer.data.to_s            # the concatenated bytes (one copy)

  # offsets buffer -> (start, end) pairs, written straight into the fixlen-16 cells
  o  = (large ? CArray.int64(n + 1) : CArray.int32(n + 1))
  o.load_binary(arr.offsets_buffer.data.to_s)
  pe = CArray.fixlen(n, bytes: 16)              # one (start,end) int64 pair per cell
  pe.field(0, :int64)[] = o[0...n]             # start  (int32 offsets widen on assign)
  pe.field(8, :int64)[] = o[1..n]              # end

  # validity bitmap -> mask, exactly as in §4
  bitmap = arr.null_bitmap
  if bitmap && arr.n_nulls > 0
    bytes = CArray.uint8(bitmap.size)
    bytes.load_binary(bitmap.data.to_s)
    pe.mask = (~bytes).bitarray[arr.offset...(arr.offset + n)]
  end

  CAConstString.wrap(pe, buffer: values, encoding: Encoding::UTF_8)
end
```

The `field(0, :int64)` / `field(8, :int64)` views write the start and end
offsets directly into each 16-byte cell — no intermediate array — and an int32
offset column widens to int64 on assignment, so utf8 (int32 offsets) and
large_utf8 (int64) share one path. It uses only existing CArray primitives
(`fixlen`, `field`, `load_binary`, `bitarray`, `wrap`): CArray stays an Arrow
*consumer* with no dedicated bridge. See
[String arrays](../topics/StringArrays.md#caconststring-specifics). For fixed-width byte
blobs, `CA_FIXLEN` / `to_fixlen_string` is the mutable alternative.

**Import into a categorical column** — a `Dictionary` array is dense integer
indices over a small dictionary of values: exactly
[`CACategorical`](../objects/CACategorical.md)'s dense codes + label vocabulary (Arrow's
`DictionaryArray` *is* a dictionary-encoded, i.e. deduplicated, column). It
imports as its two parts — the indices as a numeric column (bulk MemoryView),
the dictionary through the string recipe above — assembled with
`CACategorical.from_codes`:

```ruby
# An Arrow DictionaryArray (string dictionary) -> a CACategorical.
def categorical_from_arrow(dict)
  codes  = CArray.from_memory_view(dict.indices)     # the N codes (bulk, no boxing)
  labels = const_string_from_arrow(dict.dictionary)  # the small value vocabulary

  bitmap = dict.null_bitmap                           # a null index -> excluded cell
  if bitmap && dict.n_nulls > 0
    bytes = CArray.uint8(bitmap.size)
    bytes.load_binary(bitmap.data.to_s)
    codes.mask = (~bytes).bitarray[dict.offset...(dict.offset + dict.length)]
  end

  CACategorical.from_codes(codes, labels)
end
```

Both parts reuse the recipes already shown — the indices are just an integer
column, the dictionary just a string column — so no new machinery is needed.
This is the natural landing for a high-duplication column; see
[CACategorical](../objects/CACategorical.md).

**Import into a record column** — a `Struct` whose children are all
fixed-width (numeric or temporal) is an array of fixed-size records: exactly
[`CARecord`](../objects/CARecord.md), the array-of-structs Face over a
`CA_FIXLEN` storage. The one twist is layout. Arrow stores a struct
*struct-of-arrays* — each child field is its own separate contiguous buffer —
while a `CARecord` is *array-of-structs*, the fields interleaved inside each
record. So the import is a **transpose**: mirror the Arrow schema as a
`CAStruct` data class, then write each Arrow child column straight into its
field view. That per-field write is bulk (no per-element boxing), the same
character as the string and dictionary recipes; it is a copy, not zero-copy,
because the two layouts do not share bytes.

```ruby
# An Arrow StructArray (all children fixed-width) -> an owned CARecord.
ARROW_TO_CA = {
  Arrow::Int8DataType   => :int8,   Arrow::UInt8DataType  => :uint8,
  Arrow::Int16DataType  => :int16,  Arrow::UInt16DataType => :uint16,
  Arrow::Int32DataType  => :int32,  Arrow::UInt32DataType => :uint32,
  Arrow::Int64DataType  => :int64,  Arrow::UInt64DataType => :uint64,
  Arrow::FloatDataType  => :float32, Arrow::DoubleDataType => :float64,
}

def record_from_arrow(st)
  fields = st.value_data_type.fields

  # Mirror the Arrow schema as a CAStruct data class (name + fixed-width type).
  data_class = CArray.struct do
    fields.each { |f| send(ARROW_TO_CA.fetch(f.data_type.class), f.name.to_sym) }
  end
  rec = CARecord.new(data_class, st.length)

  # struct-of-arrays -> array-of-structs: each child column into its field view.
  fields.each_with_index do |f, i|
    rec[f.name][] = CArray.from_memory_view(st.find_field(i))   # bulk, no boxing
  end

  # struct-level validity -> the record's mask, exactly as in §4
  bitmap = st.null_bitmap
  if bitmap && st.n_nulls > 0
    bytes = CArray.uint8(bitmap.size)
    bytes.load_binary(bitmap.data.to_s)
    rec.mask = (~bytes).bitarray[st.offset...(st.offset + st.length)]
  end

  rec
end
```

Two boundaries are worth stating outright:

- **One mask per record, not per field.** A `CARecord`'s mask is one
  boolean *per record cell*, shared by every field view — masking one field
  masks the whole record. That mirrors a struct's own (struct-level)
  validity bitmap exactly, as above. But Arrow also lets each *child* carry
  its own independent validity ("`a` present, `b` null, same row"), and that
  has no faithful home here: a child-level null must either be folded into
  the whole-record mask (the record goes absent when any field is null) or
  dropped. If per-child nulls matter, import the fields as *separate*
  columns instead of one record.
- **Fixed-width children only.** A child that is itself a string, list, or
  nested struct does not fit a fixed record. Import those fields separately
  through their own recipes (a string child via `CAConstString`, a numeric
  child directly) — at which point you have per-field columns, the natural
  columnar shape, rather than a single `CARecord`.

See [CARecord](../objects/CARecord.md).

**Cannot be imported** — no CArray shape mirrors them:

| Arrow type | why not |
|---|---|
| `List`, `Map` | variable-length / keyed, not a rectangular block |
| `Union` | tagged variant — one-of-N types per cell (see note) |
| `Decimal128`, `Decimal256` | 16-/32-byte, no CArray numeric counterpart |
| `Null` | the type *is* "all null" — no values buffer, no data type to infer |

These raise `ArgumentError` from `from_memory_view`, and — unlike numbers,
strings, dictionaries, fixed-width structs, or fixed-size lists — they have no
CArray column to fall back to either: they are variable-length, keyed, tagged,
or oversized values with nothing to mirror them element-for-element. The interop
covers the flat numeric types (direct), fixed-size lists (as N-dimensional
columns), booleans and other bit-packed buffers (via the bit codec),
variable-length strings (via `CAConstString`), dictionary-encoded columns
(via `CACategorical`), and all-fixed-width structs (via `CARecord`); it stops
where Arrow's values stop being a fixed, rectangular block of cells.

A word on `Union`, because CArray *has* a `CAUnion` and the names collide.
CArray's `CAUnion` is a **C-style union** — several field types laid over the
*same* bytes (`DATA_SIZE` = the largest field), read simultaneously as any of
them, with no tag. Arrow's `Union` is a **tagged variant** — each cell carries
a type id selecting one of N types, semantically "an `int32` *or* a `string`,
this time it is the `int32`." They are unrelated despite the shared word, so
`CAUnion` is not a landing for an Arrow `Union`; a tagged variant has no faithful
mirror in CArray.

The `Null` type is worth a word, because it looks like it should be
easy. It is not a typed array whose cells happen to be null (that is an
ordinary nullable `Int32` etc., handled fine by §4). It is a distinct
type that means *"n elements, all null,"* carrying only a length — no
values buffer and no validity bitmap. Because it names no element type,
there is nothing for `from_memory_view` to infer a `data_type` from. If
you need it as a CArray, you choose a type yourself and build a
fully-masked array of length `n` (`CArray.int32(n) { UNDEF }` or the
like); Arrow contributes only the count.

Whichever importable type you use, the **mask** side (§4) is orthogonal:
the validity bitmap is unpacked the same way regardless of the values
type.

---

## 4. Validity bitmap — unpack into a mask

### 4.1 The idiom

```ruby
n      = arr.length
bitmap = arr.null_bitmap            # Arrow::Buffer, or nil if arr has no nulls

if bitmap && arr.n_nulls > 0        # skip when there is nothing to mask (see §4.5)
  bytes = CArray.uint8(bitmap.size)
  bytes.load_binary(bitmap.data.to_s)          # packed bytes -> uint8 CArray

  # ~bytes inverts in the packed domain (valid 1 -> 0, null 0 -> 1);
  # .bitarray then expands to one boolean per bit. The result is the
  # mask directly (true = null).
  value.mask = (~bytes).bitarray[arr.offset...(arr.offset + n)]
end
```

That is the whole conversion. `value` is now a masked CArray whose
absent cells are exactly Arrow's nulls.

### 4.2 `bitarray` as a packed-bit codec

The line above uses `bitarray` in a way that is worth naming outright,
because it is a legitimate, first-class use of the view — not a trick.

The everyday use of `bitarray` is to *see the bits of your own data*:
`CA_UINT8([0b1010_0011]).bitarray` fans that byte out into eight
booleans `[1,1,0,0,0,1,0,1]`. But that is just one direction of what the
view really is: a **codec between bit-packed bytes and one-boolean-
per-bit**. It reads whatever packed bytes sit under it, in a fixed
LSB-first order (`1, 2, 4, …, 128` within each byte, §4.3), and presents
them as a boolean bit axis. Nothing in that contract requires the bytes
to have originated as CArray numbers.

So decoding a **foreign** packed bitmap through `bitarray` is a
sanctioned use, and this is exactly it. The hinge is one line:

```ruby
bytes = CArray.uint8(bitmap.size)
bytes.load_binary(bitmap.data.to_s)   # <- the actual on-ramp
```

`load_binary` copies a raw byte string into a `uint8` CArray verbatim,
byte for byte, asking no questions about where those bytes came from.
That is what brings Arrow's buffer — or any external packed buffer — into
CArray's world in the first place. Once the bytes are sitting in a
`uint8` CArray, `.bitarray` unpacks them, one boolean per bit, straight
into the mask. `bytes` is a plain carrier for the packing; `load_binary`
fills it, `bitarray` reads it.

Read as a pair, `load_binary` + `bitarray` is a general foreign-bitmap
decoder. Any format that packs bits LSB-first — Arrow here, but also many
on-disk bitmaps and bitset formats — can be brought in with `load_binary`
and unpacked with `bitarray` the same way. Treat this as your
bit-unpacking primitive, not only as a lens on numbers you already hold.

The one thing it relies on is that the producer's packing order matches
CArray's. It does for Arrow — the next section shows why, bit for bit.

### 4.3 Why the bit order just works

Arrow's validity bitmap is **LSB-first**: element `i`'s bit is
`bitmap[i / 8] & (1 << (i % 8))`. CArray's `bitarray` view
(`ext/ca_obj_bitarray.c`) fans each parent byte out into a trailing bit
axis using the same `1, 2, 4, …, 128` bit order, and a single-byte
(`uint8`) parent takes the linear, endian-flip-free path. So the flat
bit order of `bytes.bitarray` matches Arrow's logical element order
one-for-one — no reordering, no host-endianness caveat.

### 4.4 The inversion belongs in the packed domain

Arrow says valid `= 1`; a CArray mask says masked `= 1`. So the bits
must be flipped. Flip them **before** expanding, with `~` (CArray's
bitwise-NOT, aka `bit_neg`) on the `uint8` buffer:

- `~bytes` touches only `n / 8` bytes (one flip per byte),
- `.bitarray` then expands once, and its output *is* the mask.

Doing it the other way — expand first, then `.not` the boolean array —
walks all `n` bytes a second time. See [§6](#6-performance) for the
measured difference. Inverting whole bytes is safe even when `n` is not
a multiple of 8: the **upper** end of the slice, `… + n`, keeps only the
first `n` bits and drops the surplus high bits of the last byte. (That
is the slice's *upper* bound doing end-of-byte trimming — a different
job from its *lower* bound, `arr.offset`, which is not about odd bit
counts at all. The next section separates the two.)

### 4.5 Three things that make it correct

1. **Nothing to mask.** When an array has no nulls, `arr.null_bitmap`
   is usually `nil` — but not always: a *slice* of a nullable array
   keeps the parent's validity buffer even when its own view contains
   zero nulls. Guard on both: `if bitmap && arr.n_nulls > 0`. This
   skips the whole unpack when nothing would be masked and leaves the
   result fully present.
2. **Offset — and why the slice has two ends.** The one slice
   `[arr.offset...(arr.offset + n)]` does *two unrelated jobs*, one at
   each end; it is easy to read the whole thing as "remainder handling,"
   but only the upper end is:

   - **Lower end `arr.offset` — skip to where this array starts.** A
     sliced Arrow array shares its parent's buffers, so element `i` lives
     at bit `arr.offset + i`, not bit `i`. The lower bound skips those
     leading bits that belong to earlier elements. This has nothing to do
     with odd bit counts — it is purely "this view begins partway into a
     shared buffer." Use `[arr.offset...]`, not `[0...]`. After `combine`
     the offset is `0`, but writing `arr.offset` keeps the code correct
     for un-combined arrays too.
   - **Upper end `arr.offset + n` — trim the surplus bits.** `~bytes`
     and `.bitarray` work in whole bytes, so when `n` is not a multiple
     of 8 the last byte carries a few extra high bits past the real data.
     The upper bound keeps exactly `n` and discards them (§4.4). *This* is
     the end-of-byte trimming.

   So `arr.offset` is a start position, not a remainder; the remainder
   lives entirely in the `+ n` at the other end.
3. **Inversion.** Valid `1` ↔ masked `false`. `~` before `.bitarray`
   (§4.4) folds this in; do not skip it, or `true`/`false` come out
   reversed.

---

## 5. Full example

```ruby
require "arrow"
require "carray"

# One Arrow column (ChunkedArray) -> one masked CArray.
def carray_from_arrow_column(column)
  arr = column.combine          # single contiguous Arrow::Array
  n   = arr.length

  value = CArray.from_memory_view(arr)   # values (type inferred)

  bitmap = arr.null_bitmap
  if bitmap && arr.n_nulls > 0
    bytes = CArray.uint8(bitmap.size)
    bytes.load_binary(bitmap.data.to_s)
    value.mask = (~bytes).bitarray[arr.offset...(arr.offset + n)]
  end

  value
end
```

```ruby
c1 = Arrow::Int32Array.new([1, nil, 3])
c2 = Arrow::Int32Array.new([nil, 5])
column = Arrow::ChunkedArray.new([c1, c2])

carray_from_arrow_column(column)
# => <CArray.int32(5): mask=2  [ 1, _, 3, _, 5 ]>
```

---

## 6. Alternative: ChunkedArray as a `CAMeld` view (author-level)

The §2–§5 path answers "give me one owned, writable CArray from this Arrow
column" — the right answer for user code, but it copies the values (via
`combine`) and materialises the whole column up front. A **library / class
author** who wants to avoid that copy can weld the un-combined chunks into a
single [`CAMeld`](../objects/CAMeld.md) view along axis 0: each chunk becomes
a read-only `CAWrap` (`wrap_memory_view`, zero-copy on values), and
`CArray.meld(*wraps, axis: 0)` presents them as one logical array without
a copy. Reductions decompose per parent (CAMeld's per-parent fast path
mirrors Arrow's per-batch execution model), so `sum` / `mean` / `min` /
`max` over the melded column touch each chunk in place with no full
materialisation.

Attaching a mask onto each nullable chunk requires the author-only escape
`send(:without_read_only_flag) { ... }` covered in
[MemoryView.md §8.1](MemoryView.md#81-attaching-a-mask-onto-a-read-only-wrap-library--class-author-only)
— the wrap is read-only by producer contract, and the escape is reserved
for authors who know that READONLY here means "external immutable memory"
(the safe case) and not "no writable target" or "formal-API-only writes".

### 6.1 Recipe

```ruby
require "arrow"
require "carray"

# Author-level: one Arrow column (ChunkedArray) -> one CAMeld view over
# the un-combined chunks. Values are zero-copy per chunk; mask is unpacked
# per chunk (same total work as §5's combine-first path).
def caview_from_arrow_column(column)
  chunks = column.chunks.map do |arr|
    n = arr.length

    # NOTE: wrap_memory_view currently does not honor arr.offset > 0
    # (verified against Arrow::Int32Array.slice); a sliced chunk falls back
    # to a per-chunk combine before wrapping. Un-sliced chunks (the common
    # case for a freshly built ChunkedArray) take the zero-copy path.
    src = (arr.offset == 0) ? arr : Arrow::ChunkedArray.new([arr]).combine
    v   = CArray.wrap_memory_view(src)      # read-only CAWrap, zero-copy

    bitmap = src.null_bitmap
    if bitmap && src.n_nulls > 0
      bytes = CArray.uint8(bitmap.size)
      bytes.load_binary(bitmap.data.to_s)
      v.send(:without_read_only_flag) do    # author-only escape (MemoryView.md §8.1)
        v.mask = (~bytes).bitarray[0...n]
      end
    end
    v
  end

  CArray.meld(*chunks, axis: 0)             # CAMeld view, read-only
end
```

```ruby
c1 = Arrow::Int32Array.new([1, nil, 3])
c2 = Arrow::Int32Array.new([nil, 5])
column = Arrow::ChunkedArray.new([c1, c2])

view = caview_from_arrow_column(column)
# => <CAMeld.int32(5): mask=2 ro [ 1, _, 3, _, 5 ]>
view.sum      # => 9.0   (skipna; per-parent decompose fast path)
view.read_only?   # => true

# When you actually need an owned, writable copy:
owned = view.copy
# => <CArray.int32(5): mask=2 [ 1, _, 3, _, 5 ]>
```

### 6.2 When to use which

| you want | use |
|---|---|
| One owned, writable CArray to work with | §2–§5 combine-first path (canonical) |
| Zero-copy read-only lens over the whole column, reductions ok, no materialisation | this §6 CAMeld path |
| The CAMeld view but occasionally an owned buffer | §6 + `.copy` at the point you need it |

### 6.3 User-facing shape: `combine.to_ca` / `to_ca` / `to_ca.copy`

The three levels in §6.2 map cleanly onto CArray's general `to_ca` /
`copy` contract: `to_ca` is "hand me a CArray with the minimum work",
`copy` is "give me an independent owned entity".
Applied to an Arrow column, that gives the user three natural idioms
without any new method name:

| user writes | intent | what happens |
|---|---|---|
| `column.combine.to_ca` | "materialise on the Arrow side first, then wrap" | Arrow builds a single Array; §3–§5 single-chunk path |
| `column.to_ca` (bound to §6.1) | "give me a CArray with the minimum work" | CAMeld view over K read-only CAWraps; zero-copy per chunk |
| `column.to_ca.copy` | "…and I want an independent owned buffer" | above + one owned materialisation |

Read-only is honest producer contract, not a trap: the CAMeld view
inherits READONLY from its Arrow-owned parents, and the user asks for
writable ownership by writing `.copy`, exactly as with any other CArray
view. The CAMeld class name is visible on the returned object
(`view.class == CAMeld`) for anyone who wants to inspect what they got.

The naming discipline here is deliberate: no new `to_ca_meld` /
`to_ca_view` method. `to_ca` and `copy` already carry the exact
distinction between "view with minimum work" and "independent owned
entity"; introducing a parallel Arrow-only vocabulary would just
re-encode what the existing contract already expresses.

The public-vs-author split: for **non-nullable** chunks the whole recipe
in §6.1 is public API (`wrap_memory_view` + `CArray.meld`), so
`column.to_ca` can be exposed directly. For **nullable** chunks, only
the mask attachment step needs the author-only escape from §6.1 — the
`column.to_ca` binding then lives in a bridge / library, but end-user
code still writes the same three idioms above through it.

### 6.4 Caveats

- **Author-only escape (nullable chunks only).** `send(:without_read_only_flag)`
  is not a public API and is only needed for the mask attachment step
  above. The recipe belongs in a bridge / library / class, not in
  ordinary user code — see [MemoryView.md §8.1](MemoryView.md#81-attaching-a-mask-onto-a-read-only-wrap-library--class-author-only).
  Non-nullable chunks need no escape.
- **Sliced chunks (`arr.offset > 0`) are not honored** by
  `wrap_memory_view` / `from_memory_view` today (verified: a
  `Arrow::Int32Array.slice(3, 4)` wrapped through MemoryView returns
  garbage). The recipe above falls back to a per-chunk `combine` in that
  case, which still avoids the full-column combine of §2 but costs one
  chunk's worth of copy per sliced chunk. Freshly built ChunkedArrays
  usually have `offset == 0` on every chunk; slicing is what introduces
  the offset.
- **Mask cost per chunk = §4 unchanged.** The bitmap unpack is still
  `O(n/8)` per chunk. The saving is on the values path (no combine
  copy), not on the mask path.
- **Read-only result.** The CAMeld view inherits READONLY from its
  read-only parents. Writes require `.copy`.
- **View retention pins buffers.** As long as the CAMeld view (or any
  derived view) is alive, each chunk's Arrow buffer is held alive. This
  is standard CArray view semantics — see `docs/interop/MemoryView.md`
  §9 (Lifetime) — but worth naming here: dropping the reference is what
  releases the pin.

---

## 7. Performance

The conversion is dominated by one unavoidable cost: expanding the
bit-packed validity into a byte-per-element mask is `O(n)` and must
write every cell. Everything else is small. Measured on a
1,000,000-element `int32` column (~1/3 null), median-of-7:

| step / variant | time |
|---|---:|
| acquire bitmap bytes (`data.to_s` + `load_binary`, `n/8` bytes) | ~14 µs |
| **expand** bits → `n` boolean bytes | ~234 µs |
| `~bytes` alone (packed invert, `n/8` bytes) | ~10 µs |
| **A** — `bitarray[…].not` (invert *after* expand) | ~344 µs |
| **B** — `(~bytes).bitarray[…]` (invert *before* expand) | ~248 µs |

**Prefer B.** Inverting in the packed domain before expansion is about
**28 % faster** than `.not`-ing the expanded boolean array, because the
flip touches `n/8` bytes instead of `n`, and the expansion pass then
produces the mask directly (no second pass). The expansion itself is
the floor; a fused "unpack-and-invert" primitive could at best reclaim
B's remaining ~10 µs, so none is provided — `~` before `.bitarray` is
the intended idiom.

---

## 8. Acquisition note (known gap)

The values buffer imports through MemoryView, but the **validity
buffer does not**: red-arrow exposes it with the MemoryView format
`b8`, which `CArray.wrap_memory_view` / `from_memory_view` currently
reject. That is why the bitmap is fetched with `bitmap.data.to_s` +
`load_binary` (two copies of `n/8` bytes, ~14 µs at `n` = 1M) instead
of a zero-copy wrap. It is a small fraction of the total and does not
affect correctness; teaching the MemoryView format parser to accept
`b8` as a `uint8` reinterpret would remove it.

---

## 9. The reverse direction — CArray → Arrow

CArray is also an Arrow *producer*: given a CArray you can build an
`Arrow::Array` that downstream Arrow consumers read. The pieces are
the mirror of §1: a **values buffer** built from the CArray's data
buffer, and a **validity bitmap** built from the mask. Values export
as raw bytes; the mask packs into bits with the byte-domain idiom of
§4.4 read backwards.

There is no export-side counterpart to `from_memory_view`:
`Arrow::Buffer.new` accepts a byte string or a `GLib::Bytes`, not a
MemoryView producer, so the values buffer is one `dump_binary` copy of
`n` bytes (§9.6). Everything else fits with existing primitives.

### 9.1 Which CArray shapes an Arrow array can hold

The §3.1 table read right-to-left:

**Export directly** — fixed-width numeric CArray → matching Arrow
primitive:

| CArray `data_type` | Arrow type |
|---|---|
| `int8/16/32/64`, `uint8/16/32/64` | matching `Int*` / `UInt*` |
| `float32`, `float64` | `Float`, `Double` |

A `CATime` column carries its raw `int64` count and a `unit:`; export
the storage as the matching Arrow temporal (`Date64` / `Time64` /
`Timestamp` for `int64`-storage bases; `Date32` / `Time32` after a
narrowing copy back to `int32`). Epoch is 1970 UTC — see
[CATime.md](../topics/CATime.md).

**Export as `FixedSizeList(N)`** — an `[M, N]` CArray is exactly the
rectangular `M × N` block behind an Arrow fixed-size list. Flatten
axis 1 into the child array (a plain 1-D CArray of length `M * N`),
export that with the numeric recipe, and wrap in a `FixedSizeListArray`
with `list_size = N` and `length = M`.

**Export as `Arrow::Tensor`** — an alternative landing for the same
N-D CArray, targeting numeric / scientific use (a single N-D array as
one Arrow object) rather than columnar use (a `FixedSizeList` column
of length-N vectors). `Arrow::Tensor` takes shape parametrically, so
the recipe is one line:

```ruby
Arrow::Tensor.new(dtype, Arrow::Buffer.new(ca.dump_binary), ca.shape, nil, nil)
```

This mirrors red-arrow-numo-narray's `to_arrow` for Numo. `Tensor`
has no validity buffer, so a mask cannot ride this route; use the
`FixedSizeList` path above (or export the mask as a separate column)
when the mask needs to survive. `Tensor#to_arrow_array` collapses a
1-D tensor into a `PrimitiveArray` of the matching type — useful when
the destination is a flat column rather than a tensor.

**Export a boolean CArray as `BooleanArray`** — CArray boolean is one
*byte* per cell; Arrow boolean is one *bit* per cell (same bit-packing
as the validity bitmap). The bridge is `pack_bits` (§9.4, exact
inverse of `.bitarray`).

**Export a `CAConstString` as `String` / `LargeString`** — a
`CAConstString`'s concatenated byte buffer and `(start, end)` offsets
match Arrow's string layout element-for-element (§3.1 in reverse).
Today the public export path builds the Arrow array from
`cs.to_a` — one Ruby String per element — and reconstructs the
offsets internally. A bulk buffer-level export that reuses the
`CAConstString` internals directly is a known gap; the boxing copy is
the price today.

**Export a `CACategorical` as `DictionaryArray`** — `.codes` (numeric
column with its mask) and `.labels` (the vocabulary) are exactly the
indices + dictionary Arrow needs. Export the codes with the numeric
recipe (§9.5) and the labels as an `Arrow::StringArray`, then assemble
with `Arrow::DictionaryArray.new`.

**Export a `CARecord` as `StructArray`** — array-of-structs →
struct-of-arrays, the reverse transpose of §3.1. Export each field
view as its own child array (`.field(:name).copy` materialises the
strided field into a contiguous buffer, then the numeric recipe
applies); the record-level mask becomes the struct-level validity
bitmap. Per-field independent nulls have no source here — the mask
lives at the record level — mirroring the "one mask per record" note
in §3.1.

**Cannot be exported directly** — no CArray shape mirrors them:
`List` / `Map` (variable-length or keyed), `Union` (tagged variant;
CArray's `CAUnion` is a C-style union — same bytes read as one of
several types, no tag — unrelated), `Decimal128/256` (16-/32-byte
numerics with no CArray counterpart), `Null` (typeless all-null).

### 9.2 Values buffer

```ruby
data_buf = Arrow::Buffer.new(ca.dump_binary)
```

`dump_binary` writes the CArray's contiguous element bytes into a
binary string — the same layout Arrow's values buffer expects. When
`ca` is a view (`.reshape`, `CABlock`, `CAStride`, …), `dump_binary`
materialises the values first, so the resulting Arrow array owns its
data.

The copy is unavoidable today because `Arrow::Buffer.new` does not
accept a MemoryView producer (§9.6). CArray *does* export MemoryView,
so once red-arrow's `Arrow::Buffer.new` learns to accept an MV producer
the copy would disappear; until then, one `dump_binary` per column is
the cost.

### 9.3 Boolean values

The values buffer of an Arrow boolean array is itself bit-packed —
same shape as the validity bitmap. `pack_bits` builds it directly from
a CArray boolean:

```ruby
data_buf = Arrow::Buffer.new(ca.pack_bits.dump_binary)
```

Masked cells are indeterminate in the values buffer; Arrow reads them
through the validity bitmap (§9.4) and treats them as null regardless
of what the value bit says. Nothing extra is needed at masked
positions.

### 9.4 Validity bitmap — pack in the byte domain

Arrow's bitmap wants LSB-first `1 = valid`. The CArray mask carries
byte-per-cell `1 = masked`. The pack is `is_not_masked` (invert in the
byte domain) followed by `pack_bits` (byte → bit) — the mirror of §4.4:

```ruby
vb = ca.validity_bits    # nil if the array has no mask
```

`validity_bits` folds the two steps into one call, returning `nil` when
the array is unmasked. Arrow treats a missing `null_bitmap` as
"all valid", so `nil` is the correct omission — hand it to the array
constructor as-is and no bitmap is allocated. When there *is* a mask,
`validity_bits` returns a `uint8` CArray of `ceil(elements / 8)` bytes,
LSB-first, ready to wrap in an `Arrow::Buffer`.

The primitive underneath, `pack_bits` (`lib/carray/methods/bit_string.rb`),
is the byte→bit codec paired with `.bitarray`:

```ruby
# For any packed uint8 array p, expanding through .bitarray then
# packing back is the identity (up to zero-fill in the trailing bits
# of the last byte when the bit count isn't a multiple of 8):
packed = CA_UINT8([0xAB, 0xCD, 0x37])
packed.bitarray.reshape(-1).pack_bits.to_a == packed.to_a   # => true
```

The tail bits of the last byte are zero-filled when `elements` is not
a multiple of 8; Arrow ignores them by construction (the bitmap length
is a byte count, the logical count is the array length).

### 9.5 Full example

```ruby
require "arrow"
require "carray"

ARROW_TYPES = {
  CA_INT8    => [Arrow::Int8Array,   Arrow::Int8DataType.new],
  CA_INT16   => [Arrow::Int16Array,  Arrow::Int16DataType.new],
  CA_INT32   => [Arrow::Int32Array,  Arrow::Int32DataType.new],
  CA_INT64   => [Arrow::Int64Array,  Arrow::Int64DataType.new],
  CA_UINT8   => [Arrow::UInt8Array,  Arrow::UInt8DataType.new],
  CA_UINT16  => [Arrow::UInt16Array, Arrow::UInt16DataType.new],
  CA_UINT32  => [Arrow::UInt32Array, Arrow::UInt32DataType.new],
  CA_UINT64  => [Arrow::UInt64Array, Arrow::UInt64DataType.new],
  CA_FLOAT32 => [Arrow::FloatArray,  Arrow::FloatDataType.new],
  CA_FLOAT64 => [Arrow::DoubleArray, Arrow::DoubleDataType.new],
}

# One numeric (fixed-width) CArray -> one Arrow::PrimitiveArray.
def arrow_from_carray(ca)
  klass, _dtype = ARROW_TYPES.fetch(ca.data_type)
  data_buf      = Arrow::Buffer.new(ca.dump_binary)

  vb            = ca.validity_bits
  null_buf, nn  = vb ? [Arrow::Buffer.new(vb.dump_binary), ca.mask.sum.to_i]
                     : [nil, 0]

  klass.new(ca.elements, data_buf, null_buf, nn)
end
```

```ruby
ca = CArray.int32(5) { |i| i + 1 }
ca[1] = UNDEF
ca[3] = UNDEF

arrow_from_carray(ca).to_a       # => [1, nil, 3, nil, 5]
```

### 9.6 `CAMeld` → `ChunkedArray`

`CAMeld` (a welded view over K parents; see the CAMeld object doc) is
the natural export shape for an Arrow `ChunkedArray`: one meld parent
= one Arrow chunk. Export each parent with §9.5, hand the list to
`Arrow::ChunkedArray.new`, and the segment structure carries through:

```ruby
chunks = [
  CA_INT32([1, 2, 3]),
  CA_INT32([4, 5]),
  CA_INT32([6, 7, 8, 9]),
]
meld = CArray.meld(*chunks, axis: 0)   # CAMeld view over the three parents

Arrow::ChunkedArray.new(chunks.map { |c| arrow_from_carray(c) })
# => Arrow::ChunkedArray with 3 chunks totaling 9 elements
```

Reverse-mirror of §6: on the import side CAMeld is the way to *avoid*
Arrow's combine copy; on the export side it is the way to *preserve*
the chunk structure without materialising the whole column first.

### 9.7 Acquisition gap (values buffer)

`Arrow::Buffer.new` accepts only `uint8` byte arrays (typically Ruby
`String` with `BINARY` encoding) or `GLib::Bytes`; it does not accept
MemoryView producers. So the values buffer costs one `dump_binary`
copy of `n` bytes on every export, even though CArray exports
MemoryView. This is symmetric with §8 — the import side has the same
gap for the *validity* buffer (Arrow's `b8` MemoryView format is
rejected by `from_memory_view`); the export side inherits it for the
*values* buffer.

A red-arrow patch teaching `Arrow::Buffer.new` (or a companion
`Arrow::Buffer.from_memory_view`) to accept an MV producer would close
both directions. Until then, one `dump_binary` per column is the cost
on export.

---

## 10. See also

- [MemoryView.md](MemoryView.md) — the values path in general.
- [MemoryViewFormat.md](MemoryViewFormat.md) — format-string contract.
- `ext/ca_obj_bitarray.c` — the `bitarray` / `bits` view (bit → boolean).
- `lib/carray/methods/bit_string.rb` — `pack_bits` (byte → bit) and
  `validity_bits` (mask → Arrow-format validity bitmap).
- [`red-arrow-carray`](https://github.com/himotoyoshi/carray-narray) — a
  legacy gem, predating the MemoryView-based recipes above, that provides
  **zero-copy `Arrow::Tensor` ↔ `CArray`** bridging. It calls `arrow-glib`
  from a C extension and wraps the Tensor buffer with `rb_carray_wrap_ptr`,
  keeping the Tensor alive as a GC anchor. Scope is narrow: `Arrow::Tensor`
  only (no `Arrow::Array`), no mask / validity bitmap, and the CArray →
  Arrow direction supports only `uint8` among the unsigned types. Note that
  an `Arrow::Tensor` buffer is immutable by Arrow's own contract
  (`arrow::Buffer::data()` returns `const`, and `garrow_buffer_get_data()`
  returns a `GBytes*` which is documented as guaranteed not to change), so
  a bridge that hands the buffer out as a `CAWrap` should mark that wrap
  read-only. CArray provides this: `ca_set_flag(ca, CA_FLAG_READ_ONLY)`
  from C, and the flag is honoured by `rb_ca_modify` / `ca_is_readonly` in
  every mutating entry point so any subsequent write raises instead of
  corrupting a buffer that may be shared with other Tensors or backed by a
  read-only mmap. (The current `red-arrow-carray` predates the flag and
  does not set it; the intended contract is still read-only.) For general
  `Arrow::Array` (with mask) interop, use the MemoryView-based recipes in
  this document instead; `red-arrow-carray` remains useful when the
  counterpart is specifically a Tensor and arrow-glib is acceptable as a
  build-time dependency.
