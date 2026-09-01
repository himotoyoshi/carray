# MemoryView interoperability in CArray

CArray implements Ruby 3.0+ MemoryView protocol (`rb_memory_view_t`)
as a standardized, zero-copy interchange with other numerical
libraries (Numo::NArray, Apache Arrow, OpenCV, Fiddle, NetCDF, …).

This document is the user-facing reference. The canonical `format`
string specification is in
[`MEMORYVIEW_FORMAT.md`](MEMORYVIEW_FORMAT.md) (PEP 3118 first,
co-ratified with `numo-narray-memoryview` and `bulk-memory-view`).

---

## 1. Overview

A CArray and a Numo::NArray (or Arrow tensor, OpenCV `Mat`, …) are
each just *buffer + shape + data_type + strides*, but every library
packages that information differently. MemoryView is Ruby's standard
envelope. Implementing the protocol once lets CArray interoperate
with every other library that does the same — no per-pair bridge
code.

Three things you can do:

1. **Receive a buffer from any producer** —
   `CArray.from_memory_view(obj)` or `CArray.wrap_memory_view(obj)`.
2. **Hand a CArray to any consumer** — pass `ca` to any function
   that calls `rb_memory_view_get` (Numo, Arrow, NetCDF I/O bindings,
   …). No conversion code on either side.
3. **Build arbitrary strided views over your own data** —
   `CArray#as_strided(shape:, strides:)`.

---

## 2. Quick start

### Zero-copy interop with Numo

```ruby
require "carray"
require "numo/narray"
require "numo/narray/memoryview"

# CArray -> Numo (zero-copy)
ca = CArray.float64(3, 4).seq
na = Numo::NArray.wrap_memory_view(ca)
na[0, 0] = -1
ca[0, 0]  # => -1.0  (shared memory)

# Numo -> CArray (zero-copy)
na2 = Numo::Int32.new(5).seq
ca2 = CArray.wrap_memory_view(na2)
```

### Reading bytes from a typeless producer (mmap, IO buffer)

Some producers (e.g. `mmap-view`) publish `format == NULL` — raw
bytes with no data_type label. Supply `data_type:` (or use the data_type-class
factory) to reinterpret:

```ruby
arr = CArray.wrap_memory_view(mmap_view, data_type: :float64).reshape(100, 100)
# or
arr = CArray::Float64.wrap_memory_view(mmap_view).reshape(100, 100)
```

### CArray as producer to BulkMemoryView

```ruby
require "bulk-memory-view"

ca  = CArray.float64(3, 4).seq
bmv = BulkMemoryView.from(ca)    # snapshot copy
bmv2 = BulkMemoryView.wrap(ca)   # zero-copy alias
```

---

## 3. Public API

### `CArray.memory_view_available?(obj) → Boolean`

Cheap probe: returns `true` if `obj` exposes a MemoryView that
CArray can consume. Does not acquire the view; safe to call in
hot paths.

### `CArray.memory_view_reject_reason(obj) → String | nil`

Diagnostic. Returns a one-line explanation of why
`wrap_memory_view(obj)` would reject, or `nil` if it would
succeed (or if `obj` is not a MemoryView producer at all).
Use this when a wrap call raises and you want a precise reason —
the exception itself carries only `"object does not support
MemoryView"` because Ruby's MemoryView core swallows producer
exceptions.

```ruby
ca = CArray.int32(3, 4).seq
CArray.memory_view_reject_reason(ca[ca > 5])
# => "this view is CASelect (boolean-mask selection (positions
#     not expressible as strides)); zero-copy wrap not possible.
#     Use CArray.from_memory_view(arr) or arr.to_ca for a snapshot."
```

### `CArray.from_memory_view(obj, data_type: nil) → CArray`

**Copy** import. Acquires a MemoryView, allocates an independent
contiguous CArray, copies (or gathers) the data, and releases the
view. The result owns its buffer; mutations on either side are
isolated.

- Accepts strided sources (gathered into row-major order).
- Accepts typeless producers when `data_type:` is given.

```ruby
tr = Numo::Int32.new(3, 4).seq.transpose   # strided
ca = CArray.from_memory_view(tr)            # OK, gather to contiguous

# typeless producer: name the data_type with `data_type:`
raw = CArray.from_memory_view(mmap_view, data_type: :float64)
```

### `CArray.wrap_memory_view(obj, data_type: nil) → CAWrap | CAStride`

**Zero-copy** import. Returns a view that points directly at the
foreign buffer. The view is held alive until the wrap is GC'd;
mutations on either side are immediately visible.

- Contiguous source → `CAWrap`.
- Strided source (negative strides, transposed, column-major, …)
  → `CAStride` (see §6).
- Typeless source → 1D wrap with the given `data_type:`; chain
  `.reshape` for shape.

```ruby
na = Numo::DFloat.new(3, 4).seq
ca = CArray.wrap_memory_view(na)
ca[0, 0] = -1
na[0, 0]   # => -1.0

# typeless producer: name the data_type with `data_type:`, then reshape
buf = CArray.wrap_memory_view(mmap_view, data_type: :float64).reshape(100, 100)
```

### Dtype-class factories

The standard Numo-style factory form is supported:

```ruby
CArray::Float64.from_memory_view(obj)
CArray::Int32.wrap_memory_view(obj)
CArray::UInt8.from_memory_view(obj)
# etc. for every numeric data_type class
```

This is a thin wrapper for `CArray.{from,wrap}_memory_view(obj,
data_type: <data_type>)` — useful when you want the data_type obvious at the
call site, or when bridging typeless producers.

---

## 4. `wrap` vs `from`: when to use which

Both methods accept the same producers, but their guarantees and
acceptance criteria differ.

| | `from_memory_view` | `wrap_memory_view` |
|---|---|---|
| Cost | one copy (or gather) | zero |
| Result ownership | owned CArray | borrowed (anchored to source) |
| Strided source | gathered into contiguous | preserved as `CAStride` |
| Source mutated later | result unaffected | result sees the change |
| Result mutated | source unaffected | source sees the change |
| Read-only source | always OK | result is read-only |
| `value_array` / `mask`, etc. on the result | allowed | restricted (see §6.2) |

Rule of thumb: **use `from_memory_view` when you want an
independent snapshot, `wrap_memory_view` when you want shared
state**. If the source has an unstable lifetime (file just
mmap'd, network buffer about to be released), prefer `from_`.

---

## 5. Strided imports

Imported strided producers are exposed as `CAStride`, a virtual
array that does direct strided addressing into the foreign buffer.

```ruby
bmv = BulkMemoryView.new([4, 5], format: "d")
bmv.write((0...20).map(&:to_f).pack("d*"))

# yrev: negate the row stride to reverse the row axis
yrev = BulkMemoryView.wrap(bmv, strides: [-bmv.strides[0], bmv.strides[1]])
ca   = CArray.wrap_memory_view(yrev)
ca.class    # => CAStride
ca.shape    # => [4, 5]
ca.strides  # => [-40, 8]
ca[0, 0]    # => 15.0  (was bmv[3, 0])
ca[3, 0]    # => 0.0   (was bmv[0, 0])
```

`CAStride` supports the standard CArray interface: indexing, slicing,
math, masking, etc. Writes go straight through to the foreign
buffer (no staging copy). Read-only sources propagate to
`ca.read_only?`.

### CAStride attributes

```ruby
ca.strides       # => Array of byte strides (signed; zero allowed)
ca.byte_offset   # => Integer; bytes from parent ptr to ca[0,...,0]
ca.parent        # => the wrap that anchors the foreign memory
ca.shape         # => standard
ca.read_only?    # => propagated from the producer
```

### Building strided views over your own data

`CArray#as_strided(shape:, strides:, offset: 0)` constructs a
`CAStride` view directly. The interface mirrors
`numpy.lib.stride_tricks.as_strided`: you supply byte strides and
take responsibility for staying in-bounds.

```ruby
ca = CArray.float64(3, 4).seq
# a 2×2 sub-grid with the same byte strides as ca
v  = ca.as_strided(shape: [2, 2], strides: [16, 8])
v.to_a  # => [[0.0, 1.0], [2.0, 3.0]]
```

Useful for broadcasting tricks (stride=0), windowing, axis
reversal (negative stride), and anything else expressible as
`addr = parent_ptr + base_offset + Σ idx[k] * strides[k]`.

---

## 6. Export side — which CArray views are exportable

### 6.1 `from_memory_view`-style consumers

Any consumer that uses `rb_memory_view_get(obj, &view, flags)` and
accepts strided views can read **any** CArray of a supported
data_type, including all virtual array types — strided ones are
exported zero-copy with computed strides, and the rest
materialise on attach.

The full export matrix:

| obj_type | Strategy | Strides |
|---|---|---|
| `CA_OBJ_ARRAY` / `CA_OBJ_ARRAY_WRAP` / `CA_OBJ_SCALAR` | direct | contiguous |
| `CA_OBJ_REFER` (reshape) | direct/attach | contiguous |
| `CA_OBJ_BLOCK` / `CA_OBJ_FARRAY` / `CA_OBJ_TRANSPOSE` / `CA_OBJ_REPEAT` / `CA_OBJ_STRIDE` / `CA_OBJ_FIELD` | strided | computed |
| `CA_OBJ_SELECT` / `CA_OBJ_MAPPING` / `CA_OBJ_GRID` / `CA_OBJ_SHIFT` / `CA_OBJ_WINDOW` / `CA_OBJ_FAKE` / `CA_OBJ_BYTE_SWAP` / `CA_OBJ_REDUCE` | attach | contiguous |
| `CA_OBJ_BITARRAY` / `CA_OBJ_BITFIELD` / `CA_OBJ_OBJECT` | reject | — |
| any obj_type installed by an extension (`ca_install_obj_type`) | reject | — |

The strategy table is keyed by class name with no registration hook, so a
class defined outside the core — a `CASource` subclass, say — cannot
declare a strategy and is rejected. `memory_view_available?` reports
`false` for it; pass `obj.copy` to a consumer that needs a MemoryView.

### 6.2 `wrap_memory_view` (zero-copy)

`wrap_memory_view` is stricter than the general export path
because the resulting view must alias the same memory as some
underlying entity — that's what "zero copy" actually requires.
The rule:

> The view, and every link in its parent chain, must be an entity
> or a *contiguous* `CAStride`-family member; the chain must
> terminate at an entity.

What this means concretely:

| pattern | wrappable? |
|---|---|
| `ca` (entity) | yes |
| `ca[i..j, nil]` (outer-row slice, contiguous CABlock) | yes |
| `ca[nil, j..k]` (column slice, non-contiguous CABlock) | yes (kept as strided CAStride) |
| `ca.transposed` (CATranspose) | yes |
| `ca.farray` (CAFarray) | yes |
| `ca.reshape(...)` (CARefer, byte-compatible) | yes |
| `ca.refer(:data_type, dim)` (CARefer, byte reinterpretation) | yes (when parent is contiguous) |
| `ca[bool_array]` (CASelect) | no |
| `ca[int_array]` (CAMapping / CAGrid) | no |
| `ca.shift(...)` / `ca.window(...)` / `ca.field(...)` / `ca.reduce(...)` | no |
| `ca.as_type(:data_type)` (CAFake; lazy cast) | no |
| `bit_or_object_typed_carray` | no |

For rejected views, the diagnostic message from
`memory_view_reject_reason` names which link in the chain failed.

If you need to hand a rejected view to a consumer, take a
snapshot first:

```ruby
snap = ca[ca > 5].to_ca               # CASelect -> entity
CArray.wrap_memory_view(snap)         # OK
# or shorter:
CArray.from_memory_view(ca[ca > 5])   # gather-copy
```

---

## 7. data_type mapping

CArray emits PEP 3118 canonical format strings (v1.2). The full
table:

| CArray data_type | `format` | `item_size` |
|---|---|---|
| `CA_BOOLEAN` | `"?"` | 1 |
| `CA_INT8` | `"c"` | 1 |
| `CA_UINT8` | `"C"` | 1 |
| `CA_INT16` | `"s"` | 2 |
| `CA_UINT16` | `"S"` | 2 |
| `CA_INT32` | `"l"` | 4 |
| `CA_UINT32` | `"L"` | 4 |
| `CA_INT64` | `"q"` | 8 |
| `CA_UINT64` | `"Q"` | 8 |
| `CA_FLOAT32` | `"f"` | 4 |
| `CA_FLOAT64` | `"d"` | 8 |
| `CA_CMPLX64` | `"Zf"` | 8 |
| `CA_CMPLX128` | `"Zd"` | 16 |

The importer is permissive: it accepts v1.0/v1.1 synonyms (`"C"`
for boolean, `"ff"` / `"dd"` for complex, `i`/`i!`/`l!`/`s!` etc.)
and disambiguates by `item_size`. See [`MEMORYVIEW_FORMAT.md`](MEMORYVIEW_FORMAT.md)
for the full producer/consumer convention.

### 7.6 PEP 3118 struct format for CAStruct (`T{...}`)

A `CA_FIXLEN` CArray whose `data_class` is a `CAStruct` subclass
exports a PEP 3118 nested struct format string:

```
T{<member_fmt>:<name>:<member_fmt>:<name>:...:}
```

Each member's `<member_fmt>` follows PEP 3118 dialect (e.g.
`b`/`B`/`h`/`H`/`i`/`I`) and padding is canonical *elided* (the
omitted bytes are implicit from member offsets). Consumers that
understand PEP 3118 struct format (NumPy, PyArrow, ...) can
zero-copy receive CAStruct arrays.

Importing `T{...}` on the consumer side is reserved for a future
phase; today CArray emits but does not parse struct format.

See [`MEMORYVIEW_FORMAT.md`](MEMORYVIEW_FORMAT.md) §6 for the normative spec.

**Not exportable / not importable**:

- `CA_FIXLEN` — variable-width payload, no canonical specifier
  (exception: CAStruct-backed `CA_FIXLEN` arrays are exported as a
  PEP 3118 struct format `T{...}`; see §7.6)
- `CA_OBJECT` — VALUE column, not raw memory

`CA_FLOAT128` / `CA_CMPLX256` are reserved enum values but disabled
(`ca_valid[]=0`) in 3.0 — they cannot appear on a live CArray, so
the question of exporting them does not arise.

---

## 8. Mask handling

CArray's mask layer has no representation in the MemoryView
protocol. The policy:

- A masked CArray passed directly to `from_memory_view` or
  `wrap_memory_view` is **rejected** with `ArgumentError`.
- Use `.value` to export the raw value layer (mask ignored).
- Use `.mask` to export the mask itself as a boolean CArray.
- Use `.unmask_copy(fill)` to materialise with masked positions
  filled.

```ruby
ca = CArray.int32(3, 4).seq
ca.mask = 0
ca.mask[0, 0] = 1

CArray.wrap_memory_view(ca)                  # raises
CArray.wrap_memory_view(ca.value)            # OK (CARefer, value layer)
CArray.wrap_memory_view(ca.mask)             # OK (boolean carray)
CArray.from_memory_view(ca.unmask_copy(-1))  # OK (filled snapshot)
```

The rejection is intentional: masked positions hold unspecified
values, and silently letting them flow into another library as
if they were valid would be a data-correctness bug.

### 8.1 Attaching a mask onto a read-only wrap (library / class author only)

Some producers (Arrow, Parquet, ...) carry null-ness in a *separate*
buffer alongside the values. A bridge that wants a zero-copy
`wrap_memory_view` for the values and then a mask derived from the null
buffer hits a wall: the wrap is read-only (the producer's contract), so
`v.mask = m` raises. `.copy` works and is the answer for user code;
it negates the zero-copy motivation, which is acceptable at the user
surface.

For library / class authors who understand why READONLY was set in the
first place, CArray provides a private, block-scoped escape:
`without_read_only_flag { ... }`. **This is not a public API and does
not weaken the "One-way" semantic of `set_read_only_flag`** — READONLY
remains un-liftable from user code by design. The primitive is invoked
via `send`, and the `send` requirement *is* the intended signal that
the caller is an author who knows the invariants, not general user
code.

The semantic behind READONLY varies by class, and the escape is safe
only in some cases:

- **(a) external immutable memory** (this section's case — `wrap_memory_view`
  over Arrow / Parquet / mmap `MAP_PRIVATE`): values buffer is truly
  immutable but the CArray-side mask slot is separate. Bounded lift for
  mask attach is **safe**.
- **(b) formal-API-only writes** (future variants where writes must go
  through invariant-preserving API to keep derived caches in sync):
  lifting READONLY would bypass the formal API. **Do not lift.**
- **(c) no writable target** (`CAObject`, and any `CASource` subclass that
  produces its elements on demand): elements come from a Ruby callback or
  an upstream source rather than being stored. Lifting is meaningless.

The primitive does not distinguish these. Only the class author knows
which applies.

```ruby
# Inside a bridge / library / Face author's own code:
v = CArray.wrap_memory_view(arr)   # read-only CAWrap, zero-copy
v.send(:without_read_only_flag) do
  v.mask = <mask derived from the producer's null buffer>
end
# v is read-only again, now with a mask
```

Discipline (not enforced by the primitive): use it only on **entities**
(CArray / CScalar / CAWrap). On a view of a read-only parent, `mask=`
allocates the parent's mask as a side effect (the view chain's
`create_mask` recursion) and mutates a buffer the producer declared
immutable, breaking the view-inherits-readonly guarantee for sibling
views. The author is responsible for knowing that this is safe in
their context.

**If you are writing user code, not a library / bridge / class**,
`.copy` is the correct answer, not this primitive.

### `from_memory_view`

The view is acquired and released inside the call. The result is
fully independent; the source object may be freed immediately.

### `wrap_memory_view`

The view is held alive by a small TypedData "holder" attached to
the returned wrap via an internal ivar. When the wrap is
garbage-collected, the holder's `dfree` calls
`rb_memory_view_release`. The source object is anchored by a
second ivar so it cannot be GC'd while the wrap is alive.

Multiple borrowers of the same source coexist safely (Ruby's
MemoryView machinery refcounts the source).

---

## 10. Performance: zero-copy via layout design

A `CABlock` returned by `ca[index]` is contiguous **iff** all
steps are 1 and every inner dimension fully covers the parent.
On a row-major CArray, outer-axis slices are contiguous; inner
slices are strided.

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

For destinations such as NetCDF / HDF5 / file I/O, arrange the
iteration axis as the outermost dimension — the same convention
NumPy recommends ("keep iteration axis at the slowest-varying
position"):

```ruby
ca = CArray.float64(365, 180, 360)   # (time, lat, lon)

# zero-copy per timestep
365.times do |t|
  nc.var("temp").read_into(ca[t, nil, nil])
end

# zero-copy slab
nc.var("temp").read_into(ca[0..30, nil, nil])
```

Non-outer slices still work (the exporter falls back to attach +
sync), but pay an O(N) materialise cost each call.

---

## 11. Amortising materialise cost: `attach!`-loop

`CArray#attach!` is a low-level escape hatch that exposes the
internal attach/sync/detach lifecycle. Most users never need it
— the regular code paths handle attach internally. The one
legitimate use case is **amortising materialise cost across many
I/O ops into the same non-contiguous destination**.

```ruby
# Without attach!: 39 × (materialise + I/O + sync) = 39 sync passes
39.times do |i|
  nc.var("temp").read_into(big[i, k, nil, nil])
end

# With attach!: 1 materialise + 39 × zero-copy I/O + 1 sync
big[nil, k, nil, nil].attach! do |ca|
  39.times do |i|
    nc.var("temp").read_into(ca[i, nil, nil])
  end
end
```

The block parameter is the (now-materialised) virtual; inside the
block its inner slices are contiguous and exportable zero-copy.
`attach!` uses `rb_ensure` so sync + detach run on block exit
even on exception.

### Safety constraints

- **Block-required**: calling `attach!` without a block raises
  `LocalJumpError`. This forces the attached state to live
  inside an explicit scope (the same idiom as
  `File.open { |f| ... }` and `Mutex#synchronize { ... }`).
- **Do not cache the block parameter** past the block. After the
  block returns, the materialised buffer is freed.
- **Do not call `attach!` recursively on the same array.** Use
  nested MemoryView wraps inside the block — those cooperate
  correctly with the internal ownership tracking.

`CArray` also defines `__attach__` / `__sync__` / `__detach__`.
The `__` prefix marks them as internal; user and library-author
code should never call them directly. `attach!` is the only
public form.

---

## 12. Worked examples

### CArray ↔ Numo::NArray

```ruby
require "carray"
require "numo/narray"
require "numo/narray/memoryview"

# CArray -> Numo, zero-copy
ca = CArray.float64(3, 4).seq
na = Numo::NArray.wrap_memory_view(ca)
na[0, 0] = -1
ca[0, 0]   # => -1.0

# Numo -> CArray, zero-copy
na2 = Numo::Int32.new(5).seq
ca2 = CArray.wrap_memory_view(na2)
ca2[2] = -999
na2[2]     # => -999

# Strided Numo source: snapshot
tr  = Numo::Int32.new(3, 4).seq.transpose
ca3 = CArray.from_memory_view(tr)
```

### CArray ↔ BulkMemoryView

```ruby
require "carray"
require "bulk-memory-view"

# CArray -> BMV
ca   = CArray.float64(3, 4).seq
snap = BulkMemoryView.from(ca)   # snapshot copy
alias_ = BulkMemoryView.wrap(ca) # zero-copy alias

# BMV -> CArray (typed)
bmv = BulkMemoryView.new([2, 3], format: "d")
bmv.write([1.0, 2, 3, 4, 5, 6].pack("d*"))
ca  = CArray.wrap_memory_view(bmv)

# Strided BMV (axis reversal)
yrev = BulkMemoryView.wrap(bmv, strides: [-bmv.strides[0], bmv.strides[1]])
ca   = CArray.wrap_memory_view(yrev)   # CAStride, shape [2,3], strides [-24, 8]
```

### Typeless producer (mmap)

```ruby
require "carray"
require "mmap-view"

region = MmapView.open("data.bin")
arr    = CArray::Float64.wrap_memory_view(region).reshape(1000, 1000)
# arr is a zero-copy view into the mapped file
```

---

## 13. Distinct concepts: `reshape` vs `refer` vs `as_type`

These three CArray methods return view-style results but differ in
what they do at the byte level:

| method | view class | semantics | wrap export |
|---|---|---|---|
| `ca.reshape(*dim)` | `CARefer` | same data_type, change shape only | yes |
| `ca.refer(:data_type, dim)` | `CARefer` (byte reinterpret) | reinterpret bytes as another data_type | yes (when parent contiguous) |
| `ca.as_type(:data_type)` | `CAFake` | **convert values** element-wise | no (lazy materialise) |

`as_type` performs a real type conversion (`int → float` etc.);
the bytes change, so zero-copy is not applicable.
`refer(:data_type, dim)` reinterprets the same bytes as a different
data_type (e.g. four `uint8` as one `uint32`) — the data is unchanged
in memory.

---

## 14. Limitations

- `CA_OBJECT` is not exported or imported (VALUE column, not raw
  memory). `CA_FIXLEN` is not exported as a plain buffer either,
  but CAStruct-backed `CA_FIXLEN` arrays do export as a PEP 3118
  `T{...}` struct format (§7.6). `CA_FLOAT128` / `CA_CMPLX256`
  are disabled in 3.0 and cannot appear on a live CArray.
- Cross-endian byte-swap is out of scope for v1.2; producers
  must emit data in host order and consumers reject views with
  the opposite byte-order prefix. See
  [`MEMORYVIEW_FORMAT.md`](MEMORYVIEW_FORMAT.md) §1.3.
- The wrap path requires alias-chain to entity (§6.2). Snapshot
  paths (`from_memory_view`, `to_ca`) have no such restriction.

---

## 15. Where to find the tests

| File | Coverage |
|---|---|
| `spec_ai/test_memory_view.rb` | availability / reject_reason |
| `spec_ai/test_memory_view_borrower.rb` | end-to-end via the C borrower test ext |
| `spec_ai/test_memory_view_import.rb` | from / wrap import path matrix |
| `spec_ai/test_memory_view_typeless.rb` | typeless producer + data_type-class factory |
| `spec_ai/test_numo_interop.rb` | cross-library tests against Numo (omitted if not installed) |
| `spec_ai/test_ca_obj_stride.rb` | CAStride + as_strided |
| `spec_ai/test_ca_obj_stride_bmv.rb` | strided BMV imports |
| `spec_ai/test_bmv_interop.rb` | CArray-side BMV producer/consumer matrix |
| `spec_ai/test_castride_family.rb` | CARefer / CABlock / CATranspose / CAFarray / CARepeat unified-CAStride coverage |
