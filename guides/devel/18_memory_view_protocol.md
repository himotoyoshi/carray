# 18 The MemoryView protocol

> **Status: draft.** Written through once; not yet re-verified against a live
> build. See [README](README.md) for conventions.

CArray implements Ruby 3.0+'s `rb_memory_view_t` protocol, so it can exchange raw
buffers with Numo::NArray, Apache Arrow, PyCall, and fiddle without copying. This
chapter explains the C machinery on both sides — importing (consumer) and exporting
(producer) — which arrays export, the mask policy, and the format string. The implementation is `ext/carray_memory_view.c`.

Why the protocol matters structurally: it is CArray's **escape hatch** to other
libraries. Because CArray's view-everywhere model makes concurrent
derived-view × entity access a non-goal ([ch. 4](04_attach_lifecycle.md)), the
sanctioned way to hand data to another ownership model is to export it through
MemoryView (zero-copy) or `copy` it out.

## Consumer side: importing

Three class methods import a foreign MemoryView producer:

- **`CArray.memory_view_available?(obj)`** — a lightweight predicate.
- **`CArray.from_memory_view(obj)`** — **copy** import; returns an owned entity.
  Accepts a strided source (it materialises while copying).
- **`CArray.wrap_memory_view(obj)`** — **zero-copy** import; returns a `CAWrap`
  over the foreign buffer for a row-major contiguous source, or a `CAStride` for a
  strided one.

A typeless producer (`format == NULL`) is accepted with an explicit `data_type:` or via
`CArray::Float64.from_memory_view(obj)` — the importer supplies the element type
the producer didn't declare.

### Naming where a borrowed buffer came from

`wrap_memory_view` takes the class of its result from the receiver. Called on
`CArray` it builds a `CAWrap`, as it always has. Called on a subclass of `CAWrap`
it builds that subclass:

```ruby
class VipsPixels < CAWrap
  def image ; instance_variable_get(:@vips_image) ; end
end

v = VipsPixels.wrap_memory_view(bmv)
v.class          # => VipsPixels
```

This exists for gems that bridge a foreign buffer into CArray. Without it the
only way to get a named class is to build the wrap yourself in C — and a
hand-built wrap gives up what this method does for you: the MemoryView holder,
the release on collection, and the propagation of the producer's read-only flag.

Two calls are refused rather than answered with something else. A receiver
outside the `CAWrap` line (`CScalar`, the Face classes, any other `CArray`
subclass) raises `TypeError`. A strided producer raises `ArgumentError` when a
subclass was asked for, because the result would be a `CAStride` layered over an
inner `CAWrap` — not the class that was named. On `CArray` itself a strided
producer still returns that `CAStride`.

**The class marks the provenance of the returned object, not the meaning of its
data.** It does not descend into views:

```ruby
v[0..1, nil].class   # => CABlock
```

That is deliberate. A slice of a borrowed image is no longer that image, so
`#image` should not be reachable from it. Do not build an API that expects the
class to survive view algebra — for semantic identity that does survive it, the
mechanism is a Face (chapter on `CAFace`), which describes what the *elements*
mean rather than where the array came from.

## Producer side: alias only

When CArray *is* the producer it hands out its own bytes and nothing else: the
export never materialises a copy. An array is exported when its parent chain
composes, by stride arithmetic, down to a core entity (`CA_OBJ_ARRAY` /
`ARRAY_WRAP` / `SCALAR`). That is the entity itself, or a CAStride-family view
(`REFER` / `BLOCK` / `STRIDE` / `FARRAY` / `TRANSPOSE` / `REPEAT` / `FIELD`, and
reshapes of them that compose linearly). Everything else is refused, and the
refusal tells the consumer to export `.copy`: CASelect, CAGrid, CAShift, CAWindow,
CAFake, CAReduce, CAStack, CAMeld, lazy expressions, CABitarray / CABitfield,
CAObject, a reshape across a non-contiguous step, and any view whose root was
installed from outside the core.

One resolver, `ca_mv_compose_to_entity`, decides. `memory_view_available?`,
`memory_view_reject_reason` and the export itself all go through it, so they
cannot disagree. `ca_mv_runtime_types[]` still labels each class (direct /
strided / attach / reject), but only to name the class in a refusal; the resolver
refuses every class labelled attach.

A Face is exported as its storage only when it registered that its storage bytes
carry its values (`ca_face_register_memory_view`, internal): CARecord as `T{...}`
and CAFixlenString as `Ns`. The other Faces (a time with its unit, categorical
codes with their labels) are refused; export `.ticks` or `.codes` instead.

The strided views are why a transposed or sliced CArray exports **zero-copy**: the
strides and base offset that drive the view internally
([ch. 6](06_view_algebra_and_castride.md)) are exactly what the MemoryView protocol
wants.

### Layout requests

A consumer that asks for no strides (SIMPLE, or ROW_MAJOR) gets the export only
when the composed layout is row-major contiguous; COLUMN_MAJOR only when it is
column-major contiguous (a transposed array). Otherwise the request is refused:
no contiguous copy is made behind the consumer's back. A writable request is
refused for any read-only source (`ca_is_readonly`): CARepeat and `value` views
are read-only.

### A buffer lent for a call

Two kinds of array hold a pointer that lasts only for one call, and both export:

- the `data` a CAObject bulk hook (`copy_data`, `sync_data`, `copy_block`, ...)
  receives is the caller's buffer, lent for the hook;
- a slab that `each_slab` yields along a non-contiguous axis is a view over the
  walk's scratch, which every iteration refills and the walk frees at its end.

Exporting them is the intended use: a hook hands `data` to a NetCDF or HDF5
binding to fill, a block hands a slab to a writer. The export, and a wrap made
from it, is valid until the hook returns or the block's iteration ends. CArray
cannot extend it: a view the hook took keeps its cells because the array can
point it at a copy, but an export has already given out the address. An export
kept past the call reads or writes memory that is no longer the array's. Code
that needs the bytes afterwards exports `.copy`.

## The mask policy

A masked CArray passed directly to `from_memory_view` / `wrap_memory_view` is
**rejected** with `ArgumentError`. The mask carries information the flat buffer
cannot, so the caller must say explicitly what to export:

- `ca.value` — a CARefer that drops the mask ([ch. 5](05_mask_and_undef.md));
- `ca.mask` — the boolean mask array itself;
- `ca.strip_mask(fill)` — a filled copy.

This is the deliberate "no silent data loss" choice: rather than guess, the
protocol makes the caller name the projection.

## The format string

The format string is the bidirectional element-type bridge. Outbound
(`ca_mv_format_for`) picks the canonical pack specifier for each CArray data_type;
inbound (`ca_mv_data_type_from_format`) accepts a wider set of synonyms, because
NumPy, Numo, and Arrow each describe e.g. `int32` differently. The normative
spec is PEP 3118 (with a struct-format section on top); keep the Numo side in
sync when extending the table.

## Making a new obj_type exportable

An obj_type exports only by composing onto a core entity, so a new view exports
zero-copy when it is a CAStride subclass whose strides fold into its parent's
([ch. 6](06_view_algebra_and_castride.md)); a new element type also needs its
format in `ca_mv_format_for` / `ca_mv_data_type_from_format`.

**An obj_type installed from outside the core is not exported**, nor is a view
onto one: a source class defined by a C extension ([ch. 8](08_view_catalog.md))
hands out `src.copy` when a consumer needs a MemoryView, and
`memory_view_available?` says so rather than letting the export fail later.
Opening the export to extensions would need a registration API; nobody has needed
one yet.

## Author-only escape: attaching a mask to a read-only wrap

`wrap_memory_view` returns a read-only CAWrap whenever the producer declares
the buffer immutable (Arrow, Parquet, mmap `MAP_PRIVATE`, ...). That correctly
protects the *values* buffer — but a bridge sometimes needs to attach a
CArray-side mask derived from a *separate* validity buffer the producer also
exposes. Direct `v.mask = m` on the read-only wrap hits `rb_ca_modify` and
raises.

The **public "One-way" contract on `set_read_only_flag` stands**: READONLY,
once set, cannot be lifted from user code. But READONLY carries different
semantics depending on the class:

- **(a) external immutable memory** — `wrap_memory_view` over Arrow /
  Parquet / mmap `MAP_PRIVATE`: values buffer is truly immutable, but the
  CArray-side mask slot is separate. Bounded lift for mask attach is safe.
- **(b) formal-API-only writes** — a future variant of "writable only
  through an invariant-preserving API to keep derived caches in sync".
  Lifting READONLY bypasses the formal API; do not lift.
- **(c) no writable target** — `CAObject`, and any `CASource` subclass that
  produces its elements on demand: they come from a Ruby callback or an
  upstream source rather than sitting in a buffer. Lifting READONLY is
  meaningless.

A library / class author who knows *which* case applies in their subsystem
is in a position to decide whether a bounded lift is safe. For that case
CArray provides a private, block-scoped escape:
`CArray#without_read_only_flag { }` (`ext/carray_test.c` alongside
`rb_ca_set_read_only_flag`). It clears `CA_FLAG_READ_ONLY` on the receiver
for the duration of the block and `rb_ensure`s the flag back on both normal
return and raise. Being private, callers reach it via `send` — the `send`
requirement *is* the signal that the caller is an author who knows the
invariants:

```ruby
v = CArray.wrap_memory_view(arr)
v.send(:without_read_only_flag) do
  v.mask = <mask derived from the producer's null buffer>
end
```

The lift covers every write, not only the mask: a value write inside the
block lands in the producer's buffer, which the producer declared immutable
(a frozen CArray source changes). Keep the block to what the lift is for.

Author discipline (not enforced by the primitive): entities only (CArray /
CScalar / CAWrap). Using it on a view of a read-only parent lets
`create_mask`'s parent-chain recursion mutate the parent's mask allocation as
a side effect — the view-chain readonly guarantee breaks for sibling views.
The primitive does not police receiver type; the author is expected to know
whether the lift is safe in their context.

## Where to go next

- The per-obj_type strategy column in context → [ch. 8](08_view_catalog.md).
- The strides/offset the strided strategy reuses → [ch. 6](06_view_algebra_and_castride.md).
- The thread-safety stance that makes this the escape hatch → [ch. 4](04_attach_lifecycle.md).

---
*When done, update the status row in [README](README.md).*
