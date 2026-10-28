# MemoryView interoperability in CArray

CArray implements Ruby 3.0+ MemoryView protocol (`rb_memory_view_t`) as a standardized, zero-copy interchange with other libraries that implement it. At present these include Apache Arrow (red-arrow) and `Fiddle::MemoryView`.

This document is the user-facing reference. The canonical `format` string specification is in [`MemoryViewFormat.md`](MemoryViewFormat.md).

---

## 1. Overview

A numerical array is just *buffer + shape + data_type + strides*, but every library packages that information differently. MemoryView is Ruby's standard envelope. Implementing the protocol once lets CArray interoperate with every other library that does the same — no per-pair bridge code.

Three things you can do:

1. **Receive a buffer from any producer** — `CArray.from_memory_view(obj)` or `CArray.wrap_memory_view(obj)`.
2. **Hand a CArray to any consumer** — pass `ca` to any function that calls `rb_memory_view_get` (Arrow, `Fiddle::MemoryView`, …). No conversion code on either side.
3. **Build arbitrary strided views over your own data** — `CArray#as_strided(shape:, strides:)`.

---

## 2. Quick start

Every example here runs with what ships with Ruby (Fiddle) or with red-arrow.

### From Arrow (zero-copy)

```ruby
require "carray"
require "arrow"

arrow = Arrow::DoubleArray.new([1.0, 2.0, 3.0])
v = CArray.wrap_memory_view(arrow)
v.to_a         # => [1.0, 2.0, 3.0]
v.read_only?   # => true  (Arrow's buffer is immutable)
```

### To a consumer (zero-copy)

`Fiddle::MemoryView` reads a CArray's buffer in place:

```ruby
require "fiddle"

ca = CArray.float64(3, 4).seq
mv = Fiddle::MemoryView.new(ca)
mv.format      # => "d"
mv.shape       # => [3, 4]
mv[1, 2]       # => 6.0
ca[1, 2] = -1
mv[1, 2]       # => -1.0  (shared memory)
mv.release
```

### Bytes with no type (typeless producer)

Some producers publish raw bytes with no data type (`format == NULL`); `Fiddle::Pointer` is one. Supply `data_type:`, or use the data-type-class factory, to read them:

```ruby
ptr = Fiddle::Pointer.malloc(32, Fiddle::RUBY_FREE)
ptr[0, 32] = [1.0, 2.0, 3.0, 4.0].pack("d*")

arr = CArray.wrap_memory_view(ptr, data_type: :float64).reshape(2, 2)
# or
arr = CArray::Float64.wrap_memory_view(ptr).reshape(2, 2)
arr.to_a       # => [[1.0, 2.0], [3.0, 4.0]]
```

---

## 3. Public API

### `CArray.memory_view_available?(obj) → Boolean`

Cheap probe: returns `true` if `obj` is a MemoryView producer — Ruby's `rb_memory_view_available_p`. Does not acquire the view; safe to call in hot paths. It does not say CArray can read the view: a producer can still refuse it, or offer a format CArray does not read, and `from_memory_view` / `wrap_memory_view` then raise.

### `CArray.memory_view_reject_reason(obj) → String | nil`

Diagnostic for CArray as a producer. For a CArray, returns a one-line explanation of why it cannot export itself (so why another library's consumer, or `wrap_memory_view(ca)`, would be refused), or `nil` if it can. For any other object it returns `nil`. Use this when a wrap call raises and you want a precise reason — the exception itself carries only `"object does not support MemoryView"` because Ruby's MemoryView core swallows producer exceptions.

```ruby
ca = CArray.int32(3, 4).seq
CArray.memory_view_reject_reason(ca[ca > 5])
# => "this view is CASelect (boolean-mask selection (positions
#     not expressible as strides)); zero-copy wrap not possible.
#     Export arr.copy for a snapshot."
```

### `CArray.from_memory_view(obj, data_type: nil, mask: nil) → CArray`

**Copy** import. Acquires a MemoryView, allocates an independent contiguous CArray, copies (or gathers) the data, and releases the view. The result owns its buffer; mutations on either side are isolated.

- Accepts strided sources (gathered into row-major order).
- Accepts typeless producers when `data_type:` is given. Their bytes are read as one 1-D run, so a typeless producer whose own shape and strides are not row-major contiguous is refused.
- `mask:` takes a second producer for the mask: one byte per element (`?`, `B` / `C`, `b` / `c`), row-major contiguous, of the data's shape. Any non-zero byte is masked.
- A boolean (`?`) producer's bytes other than 0 and 1 are read as true.
- The result is a plain `CArray` whatever the receiver; a receiver other than `CArray` or a `CAWrap` (a Face class, `CScalar`) raises `TypeError`.

```ruby
ca = CArray.int32(3, 4).seq
tr = CArray.from_memory_view(ca.transpose)   # strided source, gathered
tr.shape                                     # => [4, 3]

# typeless producer: name the data_type with `data_type:`
raw = CArray.from_memory_view(ptr, data_type: :float64)
```

### `CArray.wrap_memory_view(obj, data_type: nil, mask: nil) → CAWrap | CAStride`

**Zero-copy** import. Returns a view that points directly at the foreign buffer. The view is held alive until the wrap is GC'd; mutations on either side are immediately visible.

- Contiguous source → `CAWrap`.
- Strided source (negative strides, transposed, column-major, …) → `CAStride` (see §5).
- Typeless source → 1D wrap with the given `data_type:`; chain `.reshape` for shape. A strided typeless source is refused.
- `mask:` borrows a second producer as the mask, under the rules of `from_memory_view`, plus: the data must be row-major contiguous, the mask must not share bytes with the data, and its bytes must be 0 or 1 (a wrap cannot normalise them; `from_memory_view` can). A store writes the mask cell of each element it stores, so a read-only mask makes the whole array read-only.
- A boolean (`?`) producer must hold 0 or 1 in every byte.

What is checked against the producer's buffer: for a contiguous view, that its shape fits in `byte_size`; for a strided one, that `byte_size` covers the element count. A strided view's `byte_size` is by convention the element count times `item_size` (CArray, NumPy and Arrow all export it so), which does not bound where the strides reach, so the strides themselves are trusted. A negative shape, a shape too large to count, and a missing `strides` array (read as row-major) are handled for every source.

```ruby
src = CArray.float64(3, 4).seq
ca  = CArray.wrap_memory_view(src)
ca[0, 0] = -1
src[0, 0]   # => -1.0

# typeless producer: name the data_type with `data_type:`, then reshape
buf = CArray.wrap_memory_view(ptr, data_type: :float64).reshape(2, 2)
```

### Dtype-class factories

Each data-type class takes the same two methods:

```ruby
CArray::Float64.from_memory_view(obj)
CArray::Int32.wrap_memory_view(obj)
CArray::UInt8.from_memory_view(obj)
# etc. for every numeric data_type class
```

This is a thin wrapper for `CArray.{from,wrap}_memory_view(obj, data_type: <data_type>)` and takes `mask:` as they do — useful when you want the data_type obvious at the call site, or when bridging typeless producers. A typed producer keeps its shape (and must agree with the class's type); a typeless one is read as 1-D.

---

## 4. `wrap` vs `from`: when to use which

Both methods accept the same producers, but their guarantees and acceptance criteria differ.

| | `from_memory_view` | `wrap_memory_view` |
|---|---|---|
| Cost | one copy (or gather) | zero |
| Result ownership | owned CArray | borrowed (anchored to source) |
| Strided source | gathered into contiguous | preserved as `CAStride` |
| Source mutated later | result unaffected | result sees the change |
| Result mutated | source unaffected | source sees the change |
| Read-only source | always OK | result is read-only |

Rule of thumb: **use `from_memory_view` when you want an independent snapshot, `wrap_memory_view` when you want shared state**. If the source has an unstable lifetime (file just mmap'd, network buffer about to be released), prefer `from_`.

---

## 5. Strided imports

Imported strided producers are exposed as `CAStride`, a virtual array that does direct strided addressing into the foreign buffer. The example below uses a CArray as the producer:

```ruby
src  = CArray.float64(4, 5).seq
yrev = src[-1..0, nil]                # rows in reverse order: a negative row stride
ca   = CArray.wrap_memory_view(yrev)
ca.class    # => CAStride
ca.shape    # => [4, 5]
ca.strides  # => [-40, 8]
ca[0, 0]    # => 15.0  (src[3, 0])
ca[3, 0]    # => 0.0   (src[0, 0])
```

`CAStride` supports the standard CArray interface: indexing, slicing, math, masking, etc. Writes go straight through to the foreign buffer (no staging copy). Read-only sources propagate to `ca.read_only?`.

### CAStride attributes

```ruby
ca.strides       # => Array of byte strides (signed; zero allowed)
ca.byte_offset   # => Integer; bytes from parent ptr to ca[0,...,0]
ca.parent        # => the wrap that anchors the foreign memory
ca.shape         # => standard
ca.read_only?    # => propagated from the producer
```

### Building strided views over your own data

`CArray#as_strided(shape:, strides:, offset: 0)` constructs a `CAStride` view directly. The interface mirrors `numpy.lib.stride_tricks.as_strided`: you supply byte strides and take responsibility for staying in-bounds.

```ruby
ca = CArray.float64(3, 4).seq
# a 2×2 sub-grid with the same byte strides as ca
v  = ca.as_strided(shape: [2, 2], strides: [16, 8])
v.to_a  # => [[0.0, 1.0], [2.0, 3.0]]
```

Useful for broadcasting tricks (stride=0), windowing, axis reversal (negative stride), and anything else expressible as `addr = parent_ptr + base_offset + Σ idx[k] * strides[k]`.

---

## 6. Export side — which CArray views are exportable

### 6.1 Which arrays are exported

The export is **zero-copy only**: a consumer gets a view onto bytes that already exist. Nothing is materialised for it — a materialised snapshot would not see later writes, and writes into it would not reach the array.

An array is exported when it is

- an **entity** (`CArray`, `CAWrap`, `CScalar`), or
- a **strided view** (`CARefer`, `CABlock`, `CATranspose`, `CAFarray`, `CARepeat`, `CAField`, `CAStride`) whose chain of parents composes into byte strides over an entity, or
- a **Face** whose storage bytes carry its values on their own — a `CARecord` (exported member by member, see [Record format for CARecord](#record-format-for-carecord)) or a `CAFixlenString` (exported as `Ns` bytes) — over one of the above,

and it has no mask and an exportable data type (§7). A strided view is exported with its strides; a consumer that asks for a contiguous view (as `Fiddle::MemoryView` does) gets one only when the view is contiguous.

Everything else is refused:

| array | why |
|---|---|
| `CASelect`, `CAGrid`, `CASelectAxis`, `CARemap` | positions not expressible as strides |
| `CAShift`, `CARoll`, `CAWindow`, `CATile` | cells outside the parent or repeated out of order |
| `CAStack`, `CAMeld` | more than one parent buffer |
| lazy expressions (`CAMonOp`, `CABinOp`, …, including `as_type` and `swap_bytes`) | the values do not exist yet |
| `CABitarray`, `CABitfield` | sub-byte addressing |
| `CATime`, `CATimedelta`, `CACategorical`, `CAConstString` | the storage bytes do not say what they mean without the Face |
| a `CA_OBJECT` array | Ruby objects, not bytes |
| an array or view onto an entity installed outside the core (`ca_install_obj_type`, e.g. a `CASource` subclass) | its bytes need not be in memory |

`memory_view_available?` and `memory_view_reject_reason` answer from the same rule, so an array they accept is exported and one they refuse is explained. To hand a refused array to a consumer, export a copy (`arr.copy`); for a refused Face, export its storage (`.ticks`, `.codes`) — a copy of a Face is still the Face.

### 6.2 `wrap_memory_view` (zero-copy)

`wrap_memory_view` on a CArray accepts exactly what §6.1 exports: the result aliases the same memory as the underlying entity, which is what "zero copy" requires. A strided view stays strided (a `CAStride` over the entity).

What this means concretely:

| pattern | wrappable? |
|---|---|
| `ca` (entity) | yes |
| `ca[i..j, nil]` (outer-row slice, contiguous CABlock) | yes |
| `ca[nil, j..k]` (column slice, non-contiguous CABlock) | yes (kept as strided CAStride) |
| `ca.transpose` (CATranspose) | yes |
| `ca.farray` (CAFarray) | yes |
| `ca.reshape(...)` (CARefer, byte-compatible) | yes |
| `ca.refer(:data_type, dim)` (CARefer, byte reinterpretation) | yes (when parent is contiguous) |
| `ca.field(...)` (CAField) | yes |
| a `CARecord` / `CAFixlenString` over any of the above | yes |
| `ca[bool_array]` (CASelect) | no |
| `ca[int_array]` (CAGrid) | no |
| `ca.shift(...)` / `ca.roll(...)` / `ca.window(...)` / `ca.tile(...)` | no |
| `CArray.stack(...)` / `CArray.meld(...)` | no |
| `ca.as_type(:data_type)` / any lazy expression | no |
| `CATime` / `CATimedelta` / `CACategorical` / `CAConstString` | no |
| `CABitarray` / `CABitfield` / a `CA_OBJECT` array | no |

For rejected views, the diagnostic message from `memory_view_reject_reason` names which link in the chain failed.

If you need to hand a rejected view to a consumer, take a snapshot first:

```ruby
snap = ca[ca > 5].copy                # CASelect -> entity
CArray.wrap_memory_view(snap)         # OK
```

`to_ca` does not take a snapshot (it returns a view as it is), and `from_memory_view` reads only arrays that are exported, so neither replaces `copy` here.

---

## 7. data_type mapping

CArray emits the format vocabulary of `ruby/memory_view.h` (`c` / `C` / `s` / `S` for the narrow integers). Only boolean (`?`), complex (`Zf` / `Zd`) and fixed-length bytes (`Ns`) keep their PEP 3118 spelling, since Ruby's vocabulary has none for them. The full table:

| CArray data_type | `format` | `item_size` |
|---|---|---|
| `CA_BOOLEAN` | `"?"` | 1 |
| `CA_INT8` | `"c"` | 1 |
| `CA_UINT8` | `"C"` | 1 |
| `CA_INT16` | `"s"` | 2 |
| `CA_UINT16` | `"S"` | 2 |
| `CA_INT32` | `"i"` | 4 |
| `CA_UINT32` | `"I"` | 4 |
| `CA_INT64` | `"q"` | 8 |
| `CA_UINT64` | `"Q"` | 8 |
| `CA_FLOAT32` | `"f"` | 4 |
| `CA_FLOAT64` | `"d"` | 8 |
| `CA_CMPLX64` | `"Zf"` | 8 |
| `CA_CMPLX128` | `"Zd"` | 16 |
| `CA_FIXLEN` (`bytes` = N) | `"Ns"` | N |

The importer is permissive: it also accepts the PEP 3118 spellings (`b` / `B` / `h` / `H`) and the other pack synonyms (`l` / `L`, `s!` / `i!` / `l!` / `q!`), and reads `l` / `L` of item size 8 as 64-bit. See [`MemoryViewFormat.md`](MemoryViewFormat.md) for the full producer/consumer convention.

### Record format for CARecord

A `CARecord` exports its members' specifiers in a row, in Ruby's vocabulary, with `x<N>` for padding:

```ruby
r = CARecord.new(CArray.struct { uint8 :a; uint64 :b }, 2)
CArray.memory_view_available?(r)   # => true
# format "Cx7Q", item size 16
r.memory_view_field_names          # => ["a", "b"]
```

Ruby's format has no member names, so the record array gives them as `memory_view_field_names`, one per specifier. A bridge to PEP 3118 (pycall-memoryview, for numpy) uses them to write a named `T{...}` format. A member declared with `endian:` is written with Ruby's byte order spelling. CArray does not import a record format.

See [`MemoryViewFormat.md`](MemoryViewFormat.md) for the normative spec.

**Not exportable / not importable**:

- `CA_OBJECT` — VALUE column, not raw memory

`CA_FLOAT128` / `CA_CMPLX256` are reserved enum values but disabled (`ca_valid[]=0`) in 3.0 — they cannot appear on a live CArray, so the question of exporting them does not arise.

---

## 8. Mask handling

CArray's mask layer has no representation in the MemoryView protocol. The policy:

- A masked CArray passed directly to `from_memory_view` or `wrap_memory_view` is **rejected** with `ArgumentError`.
- Use `.value` to export the raw value layer (mask ignored).
- Use `.mask` to export the mask itself as a boolean CArray.
- Use `.strip_mask(fill)` for a copy with masked positions filled.

```ruby
ca = CArray.int32(3, 4).seq
ca.mask = 0
ca.mask[0, 0] = 1

CArray.wrap_memory_view(ca)                  # raises
CArray.wrap_memory_view(ca.value)            # OK (CARefer, value layer)
CArray.wrap_memory_view(ca.mask)             # OK (boolean carray)
CArray.wrap_memory_view(ca.strip_mask(-1))   # OK (filled copy)
```

The rejection is intentional: masked positions hold unspecified values, and silently letting them flow into another library as if they were valid would be a data-correctness bug.

### 8.1 Attaching a mask onto a read-only wrap (library / class author only)

Some producers (Arrow, Parquet, ...) carry null-ness in a *separate* buffer alongside the values. A bridge that wants a zero-copy `wrap_memory_view` for the values and then a mask derived from the null buffer hits a wall: the wrap is read-only (the producer's contract), so `v.mask = m` raises. `.copy` works and is the answer for user code; it negates the zero-copy motivation, which is acceptable at the user surface.

For library / class authors who understand why READONLY was set in the first place, CArray provides a private, block-scoped escape: `without_read_only_flag { ... }`. **This is not a public API and does not weaken the "One-way" semantic of `set_read_only_flag`** — READONLY remains un-liftable from user code by design. The primitive is invoked via `send`, and the `send` requirement *is* the intended signal that the caller is an author who knows the invariants, not general user code.

The semantic behind READONLY varies by class, and the escape is safe only in some cases:

- **(a) external immutable memory** (this section's case — `wrap_memory_view` over Arrow / Parquet / mmap `MAP_PRIVATE`): values buffer is truly immutable but the CArray-side mask slot is separate. Bounded lift for mask attach is **safe**.
- **(b) formal-API-only writes** (future variants where writes must go through invariant-preserving API to keep derived caches in sync): lifting READONLY would bypass the formal API. **Do not lift.**
- **(c) no writable target** (`CAObject`, and any `CASource` subclass that produces its elements on demand): elements come from a Ruby callback or an upstream source rather than being stored. Lifting is meaningless.

The primitive does not distinguish these. Only the class author knows which applies.

```ruby
# Inside a bridge / library / Face author's own code:
v = CArray.wrap_memory_view(arr)   # read-only CAWrap, zero-copy
v.send(:without_read_only_flag) do
  v.mask = <mask derived from the producer's null buffer>
end
# v is read-only again, now with a mask
```

The lift is not limited to the mask. Inside the block every write is allowed, values included, and a value write lands in the producer's buffer — memory the producer declared immutable. When the producer is a frozen CArray, that array's values change. Keep the block to what the lift is for.

The recipe needs a contiguous producer. A strided producer is wrapped as a view over a read-only byte array, and the lift does not reach that parent, so `v.mask =` still raises; `mask:` is not accepted for strided data either. A read-only strided producer has no zero-copy way to carry a mask: use `.copy`.

A mask borrowed with `wrap_memory_view(data, mask: m)` from a read-only producer stays read-only inside the block: the lift leaves a mask that is itself a wrap alone, so its bits are never written.

Discipline (not enforced by the primitive): use it only on **entities** (CArray / CScalar / CAWrap). On a view of a read-only parent, `mask=` allocates the parent's mask as a side effect (the view chain's `create_mask` recursion) and mutates a buffer the producer declared immutable, breaking the view-inherits-readonly guarantee for sibling views. The author is responsible for knowing that this is safe in their context.

**If you are writing user code, not a library / bridge / class**, `.copy` is the correct answer, not this primitive.

---

## 9. Lifetime of the view

### `from_memory_view`

The view is acquired and released inside the call. The result is fully independent; the source object may be freed immediately.

### An export of a buffer lent for a call

Two arrays hold memory only for the length of one call: the `data` a CAObject hook such as `copy_data` receives, and a slab `each_slab` yields along a non-contiguous axis. Both export, so you can hand them to another library inside the hook or the block. The export is valid until the hook returns or the iteration ends; kept longer, it points at memory the array no longer owns. Export `.copy` to keep the bytes.

### `wrap_memory_view`

The view is held alive by a small TypedData "holder" attached to the returned wrap via an internal ivar. When the wrap is garbage-collected, the holder's `dfree` calls `rb_memory_view_release`. The source object is anchored by a second ivar so it cannot be GC'd while the wrap is alive.

Multiple borrowers of the same source coexist safely (Ruby's MemoryView machinery refcounts the source).

#### A producer that locks while it is borrowed

Some producers restrict what can be done to their memory while a MemoryView of it is out. `IO::Buffer`, which exports a MemoryView from Ruby 4.1, is one: it stays locked until every view is released, and `resize`, `free` and (for a mapped file) unmapping raise `IO::Buffer::LockedError` in the meantime. Reading into the buffer is not blocked, so a loop that reads into the same buffer and processes it through the wrap keeps working.

The wrap gives the view back when it is garbage-collected, not when your code stops using it. Views made from the wrap (`w.reshape(...)`, `w[0..9]`, a slab kept from `each_slab`) keep it reachable as well. So after the last use, the buffer can stay locked until the next collection:

```ruby
buf = IO::Buffer.map(File.open("data.bin"), nil, 0, IO::Buffer::READONLY)
w   = CArray::Float32.wrap_memory_view(buf).reshape(nt, ny, nx)
# ... use w ...
w = nil
buf.free          # may raise IO::Buffer::LockedError: w is not collected yet
```

To release the producer at a known point, either import with `from_memory_view` (a copy, which holds no view at all), or drop every reference to the wrap and its views and run `GC.start` before you resize or free the buffer. CArray has no method that gives the view back early: an array whose memory can disappear while views of it are alive would make many ordinary operations unsafe.

---

## 10. Performance: zero-copy via layout design

A `CABlock` returned by `ca[index]` is contiguous **iff** all steps are 1 and every inner dimension fully covers the parent. On a row-major CArray, outer-axis slices are contiguous; inner slices are strided.

For row-major `CArray.float64(M, N)`:

| Slice | Contiguous? |
|---|---|
| `ca[i, nil]` (single row) | yes |
| `ca[i..j, nil]` (row range, full width) | yes |
| `ca[i..j, nil, nil]` (outer range, 3D) | yes |
| `ca[nil, j]` (single column) | no |
| `ca[nil, j..k]` (column range) | no |
| `ca[i..j, k..l]` (inner range not full) | no |
| `ca[[0, M, 2]]` (step > 1) | no |

A consumer that asks for a contiguous view, as `Fiddle::MemoryView` does, gets one for an outer-axis slice and is refused one for an inner slice. To hand slices of a large array to such a consumer one at a time, put the axis you step along first:

```ruby
require "fiddle"

ca = CArray.float64(365, 180, 360)   # (time, lat, lon)

mv = Fiddle::MemoryView.new(ca[0, nil, nil])       # one time step, zero-copy
mv.shape   # => [180, 360]
mv.release

mv = Fiddle::MemoryView.new(ca[0..30, nil, nil])   # 31 time steps, zero-copy
mv.shape   # => [31, 180, 360]
mv.release

Fiddle::MemoryView.new(ca[nil, 0, nil])            # ArgumentError: an inner slice
```

An inner slice is still exported, as a strided view, to a consumer that accepts strides (`CArray.wrap_memory_view(ca[nil, 0, nil])` is a `CAStride`). For a consumer that does not, copy the slice first (`ca[nil, 0, nil].copy`).

---

## 11. Distinct concepts: `reshape` vs `refer` vs `as_type`

These three CArray methods return view-style results but differ in what they do at the byte level:

| method | view class | semantics | wrap export |
|---|---|---|---|
| `ca.reshape(*dim)` | `CARefer` | same data_type, change shape only | yes |
| `ca.refer(:data_type, dim)` | `CARefer` (byte reinterpret) | reinterpret bytes as another data_type | yes (when parent contiguous) |
| `ca.as_type(:data_type)` | `CAMonOp` (lazy expression) | **convert values** element-wise | no (the values do not exist yet) |

`as_type` performs a real type conversion (`int → float` etc.); the bytes change, so zero-copy is not applicable. `refer(:data_type, dim)` reinterprets the same bytes as a different data_type (e.g. four `uint8` as one `uint32`) — the data is unchanged in memory.

---

## 12. Limitations

- `CA_OBJECT` is not exported or imported (VALUE column, not raw memory). `CA_FIXLEN` is exported as `Ns` bytes, or member by member when it is a `CARecord` (see [Record format for CARecord](#record-format-for-carecord)); a record format is not imported. `CA_FLOAT128` / `CA_CMPLX256` are disabled in 3.0 and cannot appear on a live CArray.
- Data is exported in the machine's byte order, except a record member declared with `endian:`, which carries Ruby's byte order spelling in the record format. On input, views in the other byte order are rejected. See [`MemoryViewFormat.md`](MemoryViewFormat.md).
- Only arrays that alias an entity are exported (§6). Export a `copy` of anything else.

---

## 13. Where to find the tests

| File | Coverage |
|---|---|
| `spec/spec_ai/test_memory_view.rb` | availability / reject_reason |
| `spec/spec_ai/test_memory_view_export_matrix.rb` | which arrays are exported |
| `spec/spec_ai/test_memory_view_simple_form.rb` | producers that leave shape and strides out (SIMPLE form) |
| `spec/spec_ai/test_memory_view_borrower.rb` | end-to-end via the C borrower test ext |
| `spec/spec_ai/test_memory_view_import.rb` | from / wrap import path matrix |
| `spec/spec_ai/test_memory_view_import_contract.rb` | producers that misstate their geometry, typeless producers, the format vocabulary |
| `spec/spec_ai/test_memory_view_typeless.rb` | typeless producer + data_type-class factory |
| `spec/spec_ai/test_memory_view_masked_wrap.rb` | `mask:` on import |
| `spec/spec_ai/test_memory_view_wrap_class.rb` | the class of the result of `wrap_memory_view` |
| `spec/spec_ai/test_memory_view_fixlen_bytes.rb` | `CA_FIXLEN` as `Ns` |
| `spec/spec_ai/test_memory_view_release_gc_safety.rb` / `test_memory_view_leaks.rb` | release of the view |
| `spec/spec_ai/test_ca_obj_stride.rb` | CAStride + as_strided |
| `spec/spec_ai/test_ca_obj_stride_bmv.rb` | strided BMV imports |
| `spec/spec_ai/test_bmv_interop.rb` | CArray-side BMV producer/consumer matrix |
| `spec/spec_ai/test_castride_family.rb` | CARefer / CABlock / CATranspose / CAFarray / CARepeat unified-CAStride coverage |
