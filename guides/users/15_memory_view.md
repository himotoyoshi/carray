# MemoryView interop

A CArray, a `Numo::NArray`, an Apache Arrow tensor, a `Fiddle::Pointer`-backed buffer — each is just *bytes + shape + data_type + strides*, but every library packages that information differently. **MemoryView** is Ruby's standard envelope for that information (`rb_memory_view_t`, available since Ruby 3.0). By implementing the protocol once, CArray can exchange data with any other library that does the same — no per-pair bridge code.

This page is an introduction. The full reference, including the export matrix and format-string conventions, is in `MemoryView.md`.

> See also: [Creating arrays](01_creating_arrays.md) for the regular constructors, and [Views](06_views.md) for the view classes you will see in the return values here (`CAWrap`, `CAStride`, ...).

## Three things you can do

1. **Receive** a buffer from any producer that exposes MemoryView — `CArray.from_memory_view(obj)` (copy) or `CArray.wrap_memory_view(obj)` (zero-copy).
2. **Hand a CArray to any consumer** that reads MemoryView. Pass `ca` directly; the consumer pulls the buffer through the protocol. No conversion code on either side.
3. **Probe** whether an object is consumable — `CArray.memory_view_available?(obj)`.

## Probing: `memory_view_available?`

A cheap predicate. Returns `true` if the object exposes a MemoryView that CArray can read.

```ruby
ca = CArray.float64(3, 4).seq
CArray.memory_view_available?(ca)        #  => true
CArray.memory_view_available?([1, 2, 3]) #  => false
```

It is safe to call in hot paths — it does not acquire or release a view.

## Copy import: `from_memory_view`

`CArray.from_memory_view(obj)` acquires a MemoryView, allocates an independent contiguous CArray, copies the data in, and releases the view. The result owns its own buffer; the producer can be GC'd or mutated freely afterwards.

```ruby
require "numo/narray"
require "numo/narray/memoryview"

na = Numo::DFloat.new(3, 4).seq
ca = CArray.from_memory_view(na)
ca.class                #  => CArray        an entity, not a view
ca.shape                #  => [3, 4]
ca[0, 0] = -1.0
na[0, 0]                #  => 0.0           source untouched
```

Strided producers are accepted — the data is gathered into row-major order during the copy:

```ruby
tr = Numo::DFloat.new(3, 4).seq.transpose   #  strided, shape [4, 3]
ca = CArray.from_memory_view(tr)
ca.class                #  => CArray
ca.shape                #  => [4, 3]
```

Use `from_memory_view` when you want an independent snapshot, or when the producer's lifetime is unstable (e.g. an mmap region about to be released).

## Zero-copy import: `wrap_memory_view`

`CArray.wrap_memory_view(obj)` returns a view that points directly at the producer's buffer. No data is copied. The producer is kept alive for as long as the wrap is reachable; writes through the wrap are immediately visible to the producer (and vice versa).

```ruby
na = Numo::DFloat.new(3, 4).seq
ca = CArray.wrap_memory_view(na)
ca.class                #  => CAWrap        a view over the foreign buffer

ca[0, 0] = -999.0
na[0, 0]                #  => -999.0        shared memory
```

If the producer is strided (transposed, negative strides, column-major, ...), the wrap is exposed as a `CAStride` — direct strided addressing into the foreign buffer, no staging copy:

```ruby
tr = Numo::DFloat.new(3, 4).seq.transpose
ca = CArray.wrap_memory_view(tr)
ca.class                #  => CAStride
ca.shape                #  => [4, 3]
```

The wrap is read-only if the producer is read-only. Closing or freeing the producer while the wrap is alive is a use-after-free — Ruby's MemoryView machinery refcounts the source to make this safe under normal GC.

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

Some producers — `mmap-view`, raw IO buffers, plain byte regions — publish a MemoryView with `format == NULL`, i.e. raw bytes with no data_type label. CArray cannot guess; you supply a `data_type:` keyword:

```ruby
arr = CArray.wrap_memory_view(raw_view, data_type: :float64).reshape(100, 100)
```

The same thing is sometimes more readable as a data_type-class factory:

```ruby
arr = CArray::Float64.wrap_memory_view(raw_view).reshape(100, 100)
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
CArray.from_memory_view(m.unmask_copy(-1))   #  filled snapshot
```

See [Masks and missing values](05_masks.md) for `value`, `mask`, and `unmask_copy`.

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
#      Use CArray.from_memory_view(arr) or arr.to_ca for a snapshot."
```

When the diagnostic tells you to take a snapshot, the idiom is:

```ruby
sel  = ca[ca > 5]
snap = sel.copy                         #  CASelect → entity
CArray.wrap_memory_view(snap)           #  OK now
# or, in one step:
CArray.from_memory_view(sel)            #  gather-copy
```

## CArray as producer

The interesting direction in practice is also the easy one: **you pass a CArray to anyone who reads MemoryView, and it just works**. The consumer calls `rb_memory_view_get(ca, &view, flags)`; CArray does the right thing.

The strategy depends on the view class on CArray's side:

* **Entities and strided views** (`CArray`, `CAWrap`, `CAScalar`, `CABlock`, `CARefer`, `CAStride`, `CATranspose`, `CAFarray`, `CARepeat`, `CAField`) are exported with the appropriate byte strides — **zero-copy**.
* **Scatter / window / cast views** (`CASelect`, `CAMapping`, `CAGrid`, `CAShift`, `CAWindow`, `CAFake`, `CAReduce`, ...) cannot be addressed by strides over the parent buffer. CArray transparently *materialises* them into a contiguous staging buffer and exports that. The cost is one O(N) copy per export.
* **Sub-byte and Ruby-object arrays** (`CABitarray`, `CABitfield`, `CA_OBJECT`) are **rejected** — they have no plain-bytes representation.

For the full export matrix (which obj_type uses which strategy, and the exact PEP 3118 format strings emitted), see `MemoryView.md` §6 and §7.

## A complete round-trip example

```ruby
require "carray"
require "numo/narray"
require "numo/narray/memoryview"

#  Build something on the Numo side
na = Numo::DFloat.new(3, 4).seq

#  Zero-copy wrap into CArray
ca = CArray.wrap_memory_view(na)
ca.class                #  => CAWrap

#  Operate using CArray idioms — the data lives in na's buffer
ca[nil, 0] = 0.0        #  writes through to na's first column
na[0, 0]                #  => 0.0
na[1, 0]                #  => 0.0

#  Take an independent snapshot when you want to detach
snap = ca.copy
snap.class              #  => CArray
snap[0, 0] = 999.0
na[0, 0]                #  => 0.0          snap is independent
```

## Where to read more

* `MemoryView.md` — full reference: every public method, the export strategy matrix, `as_strided`, `attach!`, and lifetime details.
* `MemoryViewFormat.md` — the `format`-string reference (PEP 3118 strict at the top level).
* [Views](06_views.md) — for the view classes (`CAWrap`, `CAStride`, `CAStride`, ...) that appear as return values from `wrap_memory_view`.
