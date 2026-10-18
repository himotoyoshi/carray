# MemoryView interop

A numerical array is just *bytes + shape + data_type + strides*, but every library packages that information differently. **MemoryView** is Ruby's standard envelope for that information (`rb_memory_view_t`, available since Ruby 3.0). By implementing the protocol once, CArray can exchange data with any other library that does the same — no per-pair bridge code. At present these include Apache Arrow (red-arrow) and Fiddle, which ships with Ruby; the examples on this page use only those two and CArray itself.

This page is an introduction. The full reference, including the export matrix and format-string conventions, is in `MemoryView.md`.

> See also: [Creating arrays](01_creating_arrays.md) for the regular constructors, and [Views](06_views.md) for the view classes you will see in the return values here (`CAWrap`, `CAStride`, ...).

## Three things you can do

1. **Receive** a buffer from any producer that exposes MemoryView — `CArray.from_memory_view(obj)` (copy) or `CArray.wrap_memory_view(obj)` (zero-copy).
2. **Hand a CArray to any consumer** that reads MemoryView. Pass `ca` directly; the consumer pulls the buffer through the protocol. No conversion code on either side.
3. **Probe** whether an object is consumable — `CArray.memory_view_available?(obj)`.

## Probing: `memory_view_available?`

A cheap predicate. Returns `true` if the object is a MemoryView producer. It does not promise that CArray can read the view: a producer can still refuse it, or offer a format CArray does not read, and the import then raises.

```ruby
ca = CArray.float64(3, 4).seq
CArray.memory_view_available?(ca)        #  => true
CArray.memory_view_available?([1, 2, 3]) #  => false
```

It is safe to call in hot paths — it does not acquire or release a view.

## Copy import: `from_memory_view`

`CArray.from_memory_view(obj)` acquires a MemoryView, allocates an independent contiguous CArray, copies the data in, and releases the view. The result owns its own buffer; the producer can be GC'd or mutated freely afterwards.

```ruby
require "arrow"

arrow = Arrow::DoubleArray.new([1.0, 2.0, 3.0, 4.0])
ca = CArray.from_memory_view(arrow)
ca.class                #  => CArray        an entity, not a view
ca.shape                #  => [4]
ca[0] = -1.0
arrow[0]                #  => 1.0           source untouched
```

Strided producers are accepted — the data is gathered into row-major order during the copy. A transposed CArray is one:

```ruby
src = CArray.float64(3, 4).seq
tr  = CArray.from_memory_view(src.transpose)   #  strided source, shape [4, 3]
tr.class                #  => CArray
tr.shape                #  => [4, 3]
```

Use `from_memory_view` when you want an independent snapshot, or when the producer's buffer may go away (memory about to be released).

## Zero-copy import: `wrap_memory_view`

`CArray.wrap_memory_view(obj)` returns a view that points directly at the producer's buffer. No data is copied. The producer is kept alive for as long as the wrap is reachable; writes through the wrap are immediately visible to the producer (and vice versa).

```ruby
src = CArray.float64(3, 4).seq
ca  = CArray.wrap_memory_view(src)
ca.class                #  => CAWrap        a view over the producer's buffer

ca[0, 0] = -999.0
src[0, 0]               #  => -999.0        shared memory
```

If the producer is strided (transposed, negative strides, column-major, ...), the wrap is exposed as a `CAStride` — direct strided addressing into the foreign buffer, no staging copy:

```ruby
ca = CArray.wrap_memory_view(src.transpose)
ca.class                #  => CAStride
ca.shape                #  => [4, 3]
```

The wrap is read-only if the producer is read-only. Arrow's buffers are immutable, so a wrap of an Arrow array cannot be written:

```ruby
v = CArray.wrap_memory_view(Arrow::DoubleArray.new([1.0, 2.0, 3.0]))
v.read_only?            #  => true
v[0] = 0.0              #  RuntimeError: []=: can not modify read-only array
```

## `from` vs `wrap` at a glance

|                              | `from_memory_view`     | `wrap_memory_view`           |
| ---                          | ---                    | ---                          |
| Cost                         | one copy (or gather)   | zero                         |
| Result ownership             | owned CArray (entity)  | borrowed (anchored to source)|
| Strided source               | gathered to contiguous | preserved as `CAStride`      |
| Source mutated later         | result unaffected      | result sees the change       |
| Result mutated               | source unaffected      | source sees the change       |

Rule of thumb: **`from_memory_view` for an independent snapshot, `wrap_memory_view` for shared state.**

## Typeless producers

Some producers publish a MemoryView with `format == NULL`, i.e. raw bytes with no data_type label. `Fiddle::Pointer`, a pointer to memory a C library handed you, is one. CArray cannot guess; you supply a `data_type:` keyword:

```ruby
require "fiddle"

ptr = Fiddle::Pointer.malloc(32, Fiddle::RUBY_FREE)
ptr[0, 32] = [1.0, 2.0, 3.0, 4.0].pack("d*")

arr = CArray.wrap_memory_view(ptr, data_type: :float64).reshape(2, 2)
```

The same thing is sometimes more readable as a data_type-class factory:

```ruby
arr = CArray::Float64.wrap_memory_view(ptr).reshape(2, 2)
arr.to_a                #  => [[1.0, 2.0], [3.0, 4.0]]
```

These are equivalent. They land the wrap as a 1-D `CAWrap` of the named data_type, which you then `reshape` to whatever shape the buffer actually represents.

## Masked arrays are rejected

CArray's mask layer has no representation in the MemoryView protocol. Passing a masked CArray to `from_memory_view` or `wrap_memory_view` raises `ArgumentError`:

```ruby
m = CArray.int32(3, 4).seq
m.mask = 0
m.mask[0, 0] = 1

CArray.wrap_memory_view(m)
#  ArgumentError: object does not support MemoryView
```

The rejection is intentional: masked positions hold unspecified values, and silently letting them flow into another library as if they were valid would be a data-correctness bug.

You have three explicit ways to proceed:

```ruby
CArray.wrap_memory_view(m.value)             #  raw value layer, mask ignored
CArray.wrap_memory_view(m.mask)              #  the mask itself as boolean
CArray.wrap_memory_view(m.strip_mask(-1))    #  filled copy
```

See [Masks and missing values](05_masks.md) for `value`, `mask`, and `strip_mask`.

## When a wrap is rejected: diagnosing why

Most CArrays export cleanly through `wrap_memory_view`, but a few view classes cannot — they don't alias a contiguous region of an underlying buffer (boolean selections, index-array gathers, window views, etc.).

`CArray.memory_view_reject_reason(obj)` returns a one-line explanation, or `nil` if the object would be accepted:

```ruby
ca = CArray.int32(3, 4).seq
CArray.memory_view_reject_reason(ca)
#  => nil

CArray.memory_view_reject_reason(ca[ca > 5])
#  => "this view is CASelect (boolean-mask selection (positions
#      not expressible as strides)); zero-copy wrap not possible.
#      Export arr.copy for a snapshot."
```

When the diagnostic tells you to take a snapshot, the idiom is:

```ruby
sel  = ca[ca > 5]
snap = sel.copy                         #  CASelect → entity
CArray.wrap_memory_view(snap)           #  OK now
```

`to_ca` is not a snapshot (it hands the view back as it is), and `from_memory_view` reads only arrays that are exported, so `copy` is the one to use.

## CArray as producer

The interesting direction in practice is also the easy one: **you pass a CArray to anyone who reads MemoryView, and it just works**. The consumer calls `rb_memory_view_get(ca, &view, flags)`; CArray does the right thing. `Fiddle::MemoryView` is such a consumer:

```ruby
src = CArray.float64(3, 4).seq
mv  = Fiddle::MemoryView.new(src)
mv.format               #  => "d"
mv[1, 2]                #  => 6.0
src[1, 2] = -1.0
mv[1, 2]                #  => -1.0          the consumer reads CArray's buffer
mv.release
```

The strategy depends on the view class on CArray's side:

* **Entities and strided views** (`CArray`, `CAWrap`, `CScalar`, `CABlock`, `CARefer`, `CAStride`, `CATranspose`, `CAFarray`, `CARepeat`, `CAField`) are exported with the appropriate byte strides — **zero-copy**.
* **Faces whose bytes are their values** (`CARecord` member by member, with its member names as `memory_view_field_names`; `CAFixlenString` as `Ns` bytes) are exported the same way.
* **Everything else is refused**: views whose cells cannot be addressed by strides over one buffer (`CASelect`, `CAGrid`, `CAShift`, `CARoll`, `CAWindow`, `CATile`, `CAStack`, `CAMeld`, ...), lazy expressions, sub-byte and Ruby-object arrays, and Faces whose storage means nothing without the Face (`CATime`, `CATimedelta`, `CACategorical`, `CAConstString`). Nothing is materialised behind your back: hand the consumer a `copy`, or for one of those Faces its storage (`.ticks`, `.codes`).

A consumer that asks for a contiguous view, as `Fiddle::MemoryView` does, is refused one for a strided view such as a column slice; hand it a `copy`.

For the full export matrix and the format strings CArray emits, see `MemoryView.md`.

## A complete round-trip example

Read hourly temperatures from Arrow without copying, compute in CArray, and hand the result to a consumer:

```ruby
require "carray"
require "arrow"
require "fiddle"

#  Two days of three readings, on the Arrow side
temps = Arrow::DoubleArray.new([12.5, 13.0, 14.5, 15.0, 13.5, 12.0])

#  Zero-copy wrap into CArray; the data stays in Arrow's buffer
t = CArray.wrap_memory_view(temps).reshape(2, 3)
t.mean(axis: 1).to_a    #  => [13.333333333333334, 13.5]

#  A computed result is a new CArray, which any consumer can read
anomaly = t - t.mean
mv = Fiddle::MemoryView.new(anomaly)
mv.shape                #  => [2, 3]
mv.release
```

## Where to read more

* `MemoryView.md` — full reference: every public method, the export strategy matrix, `as_strided`, and lifetime details.
* `MemoryViewFormat.md` — the `format`-string reference.
* [Views](06_views.md) — for the view classes (`CAWrap`, `CAStride`, ...) that appear as return values from `wrap_memory_view`.
