# Defining a CArray in Ruby with `CAObject`

`CAObject` is the bridge that lets you **define a new kind of CArray in
Ruby** by writing fetch/store callbacks. Most CArray subclasses are
*views* — they reference a parent CArray and present it through a
different lens. `CAObject` is different: it lets the Ruby side *produce*
the array contents on demand.

Use it when you want a CArray-shaped object whose data comes from
somewhere the built-in views cannot express:

- a computed/derived array (a function of other CArrays)
- an iterator or generator wrapped in CArray clothing
- a multi-parent assembly (packing several CArrays into a struct view)
- a quick prototype of a view you are still designing

The mechanism is intentionally general but it is **not a fast path**:
every fetch goes through a Ruby method call. Treat `CAObject` as a
substrate for prototyping, glue, and small/medium arrays. For
production-scale hot paths the right answer is to promote the pattern
to a C-level view (see *When not to use* below).

### A Ruby mirror of the C operation table

The set of template methods that `CAObject` looks for
(`fetch_addr` / `fetch_index` / `store_*` / `copy_data` / `sync_data`
/ `fill_data` / `create_mask`) is a 1:1 mirror of the C-side
`ca_operation_function_t` slots that every built-in CArray subclass
fills in. Writing a `CAObject` subclass is structurally the same
exercise as writing a C subclass — only the language changes. This is
deliberate: a working Ruby prototype maps slot-for-slot to a future C
implementation, so when a `CAObject` subclass graduates to a C
extension (as `CAPack` is expected to do once `CAStack` lands), the
shape of the work is already known. Some of the apparent ceremony in
the Ruby surface — most notably the empty-bodied `create_mask`
override (see §2) — exists to keep that mapping honest, by surfacing
slots that would also need a counterpart in C.

---

## 1. The minimum example

A `CAObject` subclass is viable as soon as it defines `initialize` and
one fetcher. This is deliberately the smallest possible surface area:
the goal is to let you **sketch a new CArray kind in seconds**, run it,
and see whether the idea is worth pursuing — without writing any C, and
without filling in all of the operation slots upfront. Performance
(`copy_data`) and C promotion come later, only if the idea proves
itself.

```ruby
require "carray"

class Constant < CAObject
  def initialize(value, dim)
    @value = value
    super(CA_OBJECT, dim, read_only: true)
  end

  private

  def fetch_addr(_addr)
    @value
  end
end

c = Constant.new("hello", [2, 3])
c[0, 1]      # => "hello"
c.to_a       # => [["hello", "hello", "hello"], ["hello", "hello", "hello"]]
c.copy       # => CArray of "hello"s; bulk path falls back to per-element fetch_addr
```

Two things to notice:

1. **`super(type, dim, options)`** must be called from `initialize` to
   register the array's data type, shape, and flags. Without it the
   underlying CArray is unconfigured.
2. **Define at least one fetcher** (`fetch_addr` *or* `fetch_index`).
   That is the only mandatory hook for a readable array. Everything
   else (`copy_data`, `store_*`, `sync_data`, `fill_data`,
   `create_mask`) is an opt-in for performance or extra capability,
   covered in the following section.

---

## 2. The callback contract

`CAObject` dispatches a small set of private template methods on your
subclass. You implement whichever ones your array needs.

### Required: at least one fetcher

| Method                 | When called                                              |
|------------------------|----------------------------------------------------------|
| `fetch_addr(addr)`     | Read a single element by flat index (`0 .. elements-1`). |
| `fetch_index(idx)`     | Read a single element by N-D index `[i, j, ...]`.        |

If you implement only `fetch_addr`, an N-D lookup is translated to a
flat address by CArray. The converse also works. Implementing both
lets you take advantage of whichever is cheaper for your data source.

### Optional: bulk fetcher `copy_data` (performance opt-in)

| Method            | When called                                                          |
|-------------------|----------------------------------------------------------------------|
| `copy_data(data)` | Fill a whole CArray buffer in one call (used by `copy`, attach, …). |

`copy_data` is **optional**. When it is not defined, the engine falls
back to a per-element loop driven by your `fetch_addr` (or
`fetch_index`). A minimal subclass with only `def fetch_addr; end`
therefore already supports `copy`, `attach!`, arithmetic, reduction —
everything that touches the array in bulk just runs through the slow
per-element path.

> **`to_ca` does not materialise.** A `CAObject` *is* a `CArray`, so
> `obj.to_ca` returns `obj` itself (`obj.to_ca.equal?(obj)` is true) and
> calls no callback. Use **`copy`** whenever you want the values in a
> plain owning `CArray`.

Define `copy_data` when you can produce many elements at once
significantly faster than per-element fetches — for example by
delegating to a vectorised CArray operation. The bulk path then
bypasses the Ruby dispatch overhead. The contract is the same as for
`fetch_addr`: both must yield the same value for the same address.

### Optional: partial-region fast paths (`copy_block` / `copy_addrs`)

Between per-cell `fetch_addr` and whole-view `copy_data` there is a
middle zone — read or write a *partial region* in one Ruby call. This
matters for backings whose chunked read is dramatically faster than
per-cell access but whose total size is too large to materialise as a
whole (NetCDF / HDF5 hyperslab, DB bulk query, paginated network source,
deep nested Ruby array).

| Method                                       | When called                                                                |
|----------------------------------------------|----------------------------------------------------------------------------|
| `copy_block(starts, counts, steps, data)`    | Read an order-preserving per-axis sub-region (step ≥ 1) into `data`.       |
| `sync_block(starts, counts, steps, data)`    | Write `data` back to that same sub-region.                                 |
| `copy_addrs(addrs, data)`                    | Gather an arbitrary flat-address list into `data` in one call.             |
| `sync_addrs(addrs, data)`                    | Scatter `data` back to that address list.                                  |
| `fill_block(starts, counts, steps, val)`     | Broadcast one value into that same sub-region.                             |
| `fill_addrs(addrs, val)`                     | Broadcast one value to that address list.                                  |

All six are **optional** — define only what your backing can speed up.
The engine dispatches as a fallback chain:

1. **`copy_block` first.** If you define it and the request can be
   expressed as a per-axis sub-region whose every axis has step ≥ 1
   (i.e. `data[i0, i1, …]` corresponds to
   `self[starts[0] + i0·steps[0], starts[1] + i1·steps[1], …]`), the
   engine calls `copy_block`. This catches the common cases:
   contiguous slice (`obj[1..2, 1..2].copy` → `steps == [1, 1]`),
   stepped slice (`obj[[nil, 2], [nil, 2]].copy` → `steps == [2, 2]`).
2. **`copy_addrs` next.** If `copy_block` is not defined, or the
   request fails the per-axis gate (transpose, fancy mapper, negative
   stride — anything that isn't an order-preserving sub-region), the
   engine expands the region to a flat address list and calls
   `copy_addrs` with the whole list in one shot.
3. **Per-cell fallback.** If neither is defined, the engine loops
   `fetch_addr` per element. Slow but always correct, and partial
   requests **never** escalate to a whole-view materialise — there is
   no OOM risk for forgetting to define `copy_block` on a lazy backing.

`sync_block` / `sync_addrs` mirror the same chain for writes. Define
them only if your array is writable (see *Writable arrays* below).

#### `copy_block` user notes

- **`steps[k]` is the index step**, not a byte stride. It is always
  ≥ 1. The user-facing idiom `steps.all? { |s| s == 1 }` distinguishes
  *contiguous* sub-regions (one `memcpy` per row) from *stepped* ones
  (e.g. HDF5 hyperslab with `stride != NULL`).
- **`data` is a `counts`-shaped CArray** of self's data_type, with a
  borrowed buffer (no `dfree`). Treat it as a writable scratchpad for
  GET, a read-only source for PUT.
- **Empty regions (`counts[k] == 0` for any axis) are not delivered**
  — the engine returns early without calling the callback.
- **Exceptions raised inside `copy_block` / `sync_block` propagate**
  to the caller and do **not** trigger the addrs fallback. If you
  defined `copy_block`, you have promised to handle the partial
  request; an exception is treated as a user error.
- **The bulk path is sentinel-free.** Per-cell `fetch_addr` may return
  `CA_UNDEF` to mark an element masked; `copy_block` cannot. Mask
  bits for partial regions come from the parallel `mask_*` callbacks
  (see §6).

#### `copy_addrs` / `sync_addrs` user notes

- **`addrs` is a 1-D Integer CArray** of flat element addresses
  (`0 .. elements - 1`), in whatever order the engine generated.
  Order matters for `sync_addrs`: when the list contains duplicates,
  the last write to each address wins (Ruby Hash semantics inside the
  user's `addrs.each_with_index { |a, i| backing[a] = data[i] }`).
- **`data` is a 1-D CArray** of length `addrs.elements`, data_type = self.

#### `fill_block` / `fill_addrs` user notes

`fill_data` carries no region, so it can only say *fill everything I
cover*. These two say *fill this part of me*, and they take the same two
shapes as the readers: `fill_block` when the region is a forward per-axis
sub-region of self, `fill_addrs` when it is not (transpose, descending
range, a region that drops an axis).

- **`val` is a single Ruby value**, as for `fill_data` — it does not
  scale with the region, so nothing `counts`-shaped is handed over.
- **`starts` / `counts` / `steps` mean what they mean in `copy_block`**,
  and `addrs` what it means in `copy_addrs`.
- The chain is the same: `fill_block`, then `fill_addrs`, then one
  `store_addr` per cell. A partial fill **never** escalates to filling
  the whole view, whichever rung it lands on — the per-cell floor already
  touched only the cells the caller named. What these buy is the cost of
  getting there.

```ruby
def fill_block (starts, counts, steps, val)
  @buf[*starts.zip(counts, steps)] = val
end
```

Define partial callbacks when your backing has *bulk granularity* that
the per-cell loop cannot exploit — most often when the backing is a
lazy data source where a single round-trip costs the same as fetching
many cells (HDF5, NetCDF, SQL `WHERE ... IN`, paginated HTTP).

### Writable arrays

If your array can be written to, also implement at least one of the
single-element store methods:

| Method                   | When called                                                |
|--------------------------|------------------------------------------------------------|
| `store_addr(addr, val)`  | Write a single element by flat index.                      |
| `store_index(idx, val)`  | Write a single element by N-D index.                       |

As with the fetchers, defining one is enough — the engine translates
between flat address and N-D index in the other direction.

The bulk write methods are optional opt-ins (same fallback story as
`copy_data`):

| Method                   | When called                                                |
|--------------------------|------------------------------------------------------------|
| `sync_data(data)`        | Write a whole CArray buffer back (used by attach/sync).    |
| `fill_data(value)`       | Broadcast a single value to every element.                 |
| `fill_block(...)`        | Broadcast a single value into part of the array.           |
| `fill_addrs(addrs, val)` | Broadcast a single value to an address list.               |

When undefined, the engine loops the corresponding `store_addr` over
every element the request names (see *partial-region fast paths* above
for the region forms). Override them only when you can do meaningfully faster
than a Ruby-callback-per-element loop.

Pass `read_only: true` to `super` (see *Constructor options* below) to
declare the array immutable and skip writing entirely.

### Mask: declare the lifecycle hook

`CAObject` rejects mask creation by default
(`"can't create mask for CAObject"`). To enable masking you write two
pieces of code, each of which corresponds 1:1 to a piece of the C
operation table that a future C extension would have to provide:

1. **Override `create_mask` (no-op is fine).** This is the Ruby
   mirror of the `func_create_mask` slot in
   `ca_operation_function_t`. The engine looks for it with
   `respond_to?` before calling `ca_create_mask(ca)`. Writing
   `def create_mask; end` is the standard form — the body delegates
   to the engine default, but the *presence* of the method declares
   "this CArray kind participates in mask lifecycle". When you later
   promote this prototype to a C extension, this is where you would
   write `ca_xxx_func_create_mask` (or alias `ca_array_func_create_mask`).
2. **Call `self.mask = 0` in `initialize`** (only if `copy_data` will
   write `UNDEF` into the data buffer). This eagerly allocates the
   mask buffer so that bulk-path `UNDEF` writes survive the materialise
   step. Without it, a `UNDEF` written inside `copy_data` is silently
   discarded.

```ruby
class MaskedRandom < CAObject
  def initialize(n)
    super(CA_INT32, [n])
    self.mask = 0           # eager-allocate mask buffer
  end

  private

  def fetch_addr(addr)
    addr.odd? ? UNDEF : addr * 10
  end

  def copy_data(data)
    data.elements.times { |i| data[i] = i.odd? ? UNDEF : i * 10 }
  end

  def create_mask           # opt-in flag (body is intentionally empty)
  end
end
```

Why two steps? CArray's mask is **lazy + sticky** everywhere: an
entity (or any CArray subclass) does not allocate a mask buffer until
something asks for one, and once allocated it stays even when all
bits are cleared. The engine call that copies a `CAObject` to a
materialised buffer checks `source.has_mask?` *before* invoking your
`copy_data`. If you write `UNDEF` inside `copy_data` to a CAObject
that had no mask buffer at entry, the mask bit lands on the internal
data wrapper but is not seen by the caller — the materialised result
ends up without a mask. Calling `self.mask = 0` up-front means
`has_mask?` is already true when the engine inspects the source, so
the mask is copied out alongside the data.

The single-element path (`fetch_addr` returning `UNDEF`) is a
separate code path that allocates and writes the mask directly on
the `CAObject` itself, so it works whether or not you pre-allocated
the mask buffer.

If your array genuinely never produces `UNDEF`, leave `create_mask`
undefined and the engine's default reject becomes documentation of
intent.

### `super` signature

```ruby
super(data_type, dim, **options)
```

| Argument     | Meaning                                                                                       |
|--------------|-----------------------------------------------------------------------------------------------|
| `data_type`  | A CArray data_type symbol (`:float64`, `:int32`, …), `CA_OBJECT`, or a fixlen struct class. Under `face: true` this is the *surface* `data_type` the dispatcher sees (= may be `CA_FIXLEN` to gate numeric ops); see §3.5. |
| `dim`        | Shape as an array, e.g. `[100, 200]`.                                                         |
| `:bytes`     | Element size in bytes. **Should** be passed for `CA_FIXLEN` (see note below); otherwise inferred from `data_type`. Under `face: true`, must equal `parent.bytes`. |
| `:read_only` | If truthy, marks the array as read-only (`CA_FLAG_READ_ONLY`).                                |
| `:parent`    | Optional CArray. When this `CAObject` is logically derived from a single parent, pass it here (§3.4). Required when `face: true` (= storage owner). |
| `:face`      | If truthy, declares the instance a Face (= `CA_FLAG_IS_FACE` set). Requires `:parent`. See §3.5 for the Face contract. |
| `:storage`   | Only valid with `face: true`. Documents and validates `parent.data_type` when the *surface* `data_type` differs from storage (= NonNumeric Face). See §3.5. |

**Note on `CA_FIXLEN` + `:bytes`.** Omitting `:bytes` for a `CA_FIXLEN`
array does *not* raise. It silently produces a degenerate `bytes = 0`
buffer — that is the documented behaviour for all of CArray (pinned by
`spec/Features/feature_extream_spec.rb`), part of the same "extreme
edge cases are accepted gracefully" stance that allows zero-length
dimensions. The 0-byte fixlen is rarely what you want, though: always
pass `:bytes` explicitly when you mean a non-trivial fixlen element.

---

## 3. Real examples (`lib/carray/object/`)

Three subclasses ship with CArray as canonical patterns. They are
small enough to read in one sitting.

### `CAIteratorArray` — wrap an iterator as a CArray

```ruby
class CAIteratorArray < CAObject
  def initialize(it)
    @it = it
    super(CA_OBJECT, @it.dim)
  end

  private

  def fetch_index(idx)
    @it.kernel_at_index(idx)
  end

  def store_index(idx, val)
    @it.kernel_at_index(idx)[] = val
  end

  def copy_data(data)
    data.each_index { |*idx| data[*idx] = @it.kernel_at_index(idx) }
  end

  # sync_data / fill_data: see the source file
end
```

Pattern: a single object (the iterator) provides per-index access; the
class converts that into the full CArray protocol.

### `CALink` — a derived array from a block

```ruby
link = CALink.new(ca_a, ca_b) { |a, b| a + 2 * b }
link[0, 0]   # => evaluator is called with a[0,0], b[0,0]
link.copy    # => fully evaluated CArray
```

Pattern: lazily computed array. `fetch_addr` evaluates the block for
one element; `copy_data` evaluates it for the whole shape using
vectorised CArray operations (much faster than per-element).

### `CANestedArray` — wrap nested Ruby Arrays as a CArray

```ruby
a = CANestedArray.new([[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]])
a.shape       # => [2, 3]
a[1, 2]       # => 6.0
a.copy        # => CArray.float64(2, 3) snapshot
a[0, 0] = 9.0
a.nested      # => [[9.0, 2.0, 3.0], [4.0, 5.0, 6.0]]
```

Pattern: rectangular nested Ruby Array as the authoritative store. The
class implements the full template set (`fetch_index` / `store_index` /
`fetch_addr` / `store_addr` / `copy_data` / `sync_data` / `fill_data`
+ empty `create_mask`) so it works on every access path — per-cell,
bulk, and partial-region materialisation through view chains
(`a[range, range].copy`, `a.transpose.copy`) without ever
materialising the whole nested structure.

### `CAPack` — pack multiple CArrays into a struct array

```ruby
packed = CArray.pack(ca_r, ca_g, ca_b)   # => N x M array of struct(r, g, b)
packed[0, 0]   # => struct instance with r/g/b filled from ca_r/g/b[0, 0]
```

Pattern: multi-parent assembly. The "parent" relationship is held in a
Ruby `@list` ivar, not in the C-level `parent` field, because the
built-in view hierarchy assumes a single parent.

### 3.4 Single-parent CAObject (`:parent` option)

When your subclass is logically derived from **one** CArray (a
computed view, a per-element transform, a typed reinterpretation,
…), pass that array as the `:parent` option to `super`. This
registers it both as the C-level `parent` and as the `@parent` Ruby
ivar, enabling three pieces of standard CArray behaviour that
otherwise stay inert on a `CAObject`:

1. **Flag inheritance.** `read_only?`, `mask_array?`, and
   `value_array?` walk the parent chain. If the parent is
   read-only, your CAObject is automatically read-only too — no
   need to pass `read_only: true` separately.
2. **Frozen propagation.** If the parent is frozen at the moment of
   construction, the CAObject is frozen as well (handled by
   `rb_ca_set_parent`).
3. **GC anchor.** The `@parent` ivar keeps the parent reachable for
   as long as the CAObject is alive, so a derived CAObject built
   over a temporary CArray won't dangle.

```ruby
class Square < CAObject
  def initialize(parent)
    @p = parent
    super(parent.data_type, parent.dim, parent: parent)
  end

  private

  def fetch_addr(addr)
    @p[addr] ** 2
  end

  def copy_data(data)
    data[] = @p * @p
  end
end

base = CArray.float64(3) { |i| i + 1.0 }.freeze
sq   = Square.new(base)
sq.parent.equal?(base)  # => true
sq.read_only?           # => true   (inherited from frozen base)
sq.frozen?              # => true   (inherited from frozen base)
```

The `:parent` slot accepts **one** CArray. The three examples above
(`CAIteratorArray`, `CALink`, `CAPack`) hold their sources in plain
Ruby ivars instead — they are structurally multi-source (iterator,
multiple block arguments, list of CArrays) and don't fit the single
canonical-parent slot. Use `:parent` only when there is a clear
single antecedent.

### 3.5 Face mode (`face: true` + optional `:storage`)

`CAObject` is the Ruby-level path for defining a Face — a semantic
identity layered on top of a storage CArray. The `face: true` option
sets the `CA_FLAG_IS_FACE` bit, which makes the instance participate
in all of CArray's Face-aware machinery (view-creating methods
preserve the class, `storage_to_scalar` is consulted on scalar return,
`kernel_iterator` strips at entry, etc.). See
[`CAFace.md`](CAFace.md) for the full Face substrate.

**No callbacks required.** Unlike the traditional CAObject usage in
§2 (where you must define at least `fetch_index` / `fetch_addr` to
back the per-cell Ruby callback path), Face mode short-circuits the
callbacks entirely. The storage lives in the parent CArray, so
`fetch_index`, `store_index`, `copy_data`, `sync_data`, `fill_data`
are **all bypassed**; the `ca_face_*` thin-forward helpers in
`ext/ca_obj_face.c` route every storage op directly to the parent.
A complete Face subclass therefore needs only `initialize`,
optionally `copy_state`, optionally `storage_to_scalar` /
`scalar_to_storage` (scalar read/write conversion), plus whatever
domain methods you want — zero storage-callback boilerplate. See
`examples/face/ca_circular.rb` and `examples/face/ca_fixed_point.rb`:
both define a fully functional Face without a single `fetch_*` /
`store_*` / `copy_data` method.

Face mode adds two contract knobs to the `super` call:

#### Numeric Face — surface = storage (default)

When the parent storage operations make algebraic sense on the Face
(`+`, `-`, `*`, `sum`, …), declare a Numeric Face by passing the
same `data_type` as the parent:

```ruby
class CACircular < CAObject
  def initialize(parent_float64, range: :rad)
    @range = range
    super(CA_FLOAT64, parent_float64.dim,
          parent: parent_float64,
          face:   true)
  end
end
```

The contract `data_type == parent.data_type` is enforced; mismatches
raise `TypeError`. This is the safety guard against typos for the
common case where you intended surface to equal storage.

#### NonNumeric Face — surface = `CA_FIXLEN`, storage explicit

When numeric ops on the Face are categorically nonsense (e.g. a tag
array, a categorical index, a text-offset table), opt into the
*FIXLEN surface* by passing `data_type = CA_FIXLEN` and naming the
actual storage via `:storage`:

```ruby
class MyTagArray < CAObject
  def initialize(parent_int64)
    super(CA_FIXLEN, parent_int64.dim,
          bytes:   8,
          storage: CA_INT64,         # explicit: parent is int64
          parent:  parent_int64,
          face:    true)
  end
end

raw = CArray.int64(5) { |i| i }
arr = MyTagArray.new(raw)
arr * 2          # => raises (mkkernel CA_FIXLEN slot is not_implement)
arr.sum          # => raises
arr.cumsum       # => raises
arr[0..2].parent.data_type   # => :int64  (storage invariant maintained)
```

The mechanism: mkkernel emits `ca_*_not_implement` raise stubs for
the `CA_FIXLEN` slot of every numeric / math / reduction operation,
so declaring surface = `CA_FIXLEN` makes those operations refuse
upfront. The storage stays at `parent.data_type`, accessible via
the `parent` escape hatch for permitted operations.

#### Contract summary

| `:storage` | declared `data_type` | parent.data_type | Result |
|---|---|---|---|
| omitted | == parent.data_type required | — | Numeric Face (= legacy contract, surface == storage) |
| explicit | free (`CA_FIXLEN` or other) | == `:storage` required | Numeric or NonNumeric Face, surface != storage allowed |
| explicit, `face: true` omitted | — | — | `ArgumentError` (`:storage` only meaningful in Face mode) |
| explicit, parent mismatch | — | — | `TypeError` |

`:bytes` always must equal `parent.bytes` under `face: true`
(memory-layout invariant the lift mechanism depends on).

#### Recovering permitted operations

For a NonNumeric Face, operations that *are* meaningful on the
underlying storage (comparison, sort, count, domain-specific
predicates) come back via Ruby method overrides that route through
`parent`:

```ruby
class MyTagArray < CAObject
  # ... super(...) above ...

  def sort(*a, **o)
    sorted = parent.sort(*a, **o)
    self.class.new(sorted)
  end

  def <(other);  parent < other.parent;  end
  def ==(other); parent == other.parent; end
end
```

The `parent` accessor is the storage escape hatch — the FIXLEN
surface gates only the unconditional numeric-kernel dispatch, not
Ruby-level delegation.

#### Why this design

CArray's choice was to *not* track surface non-numericness via a new
core flag (= which would require every new op and every external
gem to coordinate with the flag). Instead it reuses mkkernel's
existing `CA_FIXLEN` exclusion contract: anything not emitted for
`CA_FIXLEN` is automatically gated, in perpetuity, by virtue of how
the dispatch tables are built. External gem Faces (a future
`carray-text`, `carray-categorical`, …) inherit the gate by setting
`data_type = CA_FIXLEN` at construction; no core change required.

---

## 4. When not to use `CAObject`

`CAObject` is a Ruby-callback bridge. Each `fetch_addr` / `fetch_index`
crosses the C → Ruby boundary, which costs roughly two orders of
magnitude more than a native CArray view access. That is fine for:

- prototyping a new view kind before committing to a C implementation,
- glue code that runs once or a few times per request,
- arrays where the *computation* dominates and the dispatch cost is
  noise (e.g. `CALink` over heavy block work).

Reach for a different mechanism when:

- the array is on a hot path and you've measured `fetch_addr` in the
  profile — promote the pattern to a C view, or precompute into a
  plain CArray (`obj.copy`) once;
- the pattern is a true view of one parent — use `CARefer`, `CABlock`,
  `CAStride`, or one of the built-in subclasses, all of which run at
  C speed with no callback;
- the pattern is multi-parent concatenation — `CAPack` is the Ruby
  prototype that covers this case today; a C implementation
  (`CAStack`) is planned and is expected to subsume it.

`CAObject` is deliberately the slow, flexible end of the design.
Built-in C views are deliberately the fast, constrained end. CArray
keeps both in the same class hierarchy so that an exploratory
`CAObject` subclass and a hand-tuned `CAStride` view share the same
public interface — you can swap them later without rewriting callers.

### The prototyping ladder

`CAObject` is designed as a four-rung path from "idea" to "production
C view", and each rung is cheap to climb. You only pay for the rung
you actually need:

1. **Sketch.** One fetcher (`fetch_addr` *or* `fetch_index`). The
   array works end-to-end — `copy`, arithmetic, reduction, the lot —
   via the per-element fallback. Slow, but correct. This is the
   "does the idea even make sense?" stage.
2. **Speed up in Ruby — partial region.** Add `copy_block` and/or
   `copy_addrs` (plus `sync_*` mirrors for writable arrays) when the
   sketch is dominated by per-cell dispatch but the backing has bulk
   granularity that the whole-view path cannot exploit — for example
   a lazy file format (HDF5 hyperslab), a DB cursor, or a deep nested
   Ruby array where indexing N times is much faster than calling
   `fetch_addr` N times. Partial requests no longer escalate to per-
   cell loops, and importantly **they do not escalate to whole-view
   materialise either** — so this rung is also the right choice when
   the whole array is too large to fit in memory at once.
3. **Speed up further — whole view.** Add `copy_data` (and, for
   writable arrays, `sync_data` / `fill_data`) when even partial
   regions are wasteful and a single materialise of the entire array
   is feasible. Often a vectorised CArray operation inside `copy_data`
   makes the prototype as fast as a hand-written view for in-memory
   backings.
4. **Promote to C.** When the shape of the operation table is stable,
   reimplement the same slots as `ca_xxx_func_*` in a C extension and
   register a new `CA_OBJ_*` type. The 1:1 correspondence between
   Ruby template methods and C slots — including the partial-region
   methods, which mirror the C `xfer_stride` / `xfer_addrs` slots —
   means the work is largely mechanical. Callers don't notice the
   swap because both subclasses share the same public CArray
   interface.

The shipped `CAPack` is a Ruby-stage prototype of a future C-stage
`CAStack`. The fact that you can stop at any rung without rewriting
the surface is the whole point.

---

## 5. Interaction with the rest of CArray

`CAObject` arrays plug into the same surfaces as any other CArray:

- **Indexing** (`obj[i, j]`, `obj[range, ..]`) — works via the fetchers.
- **`obj.copy`** — materialises into a plain `CArray` (calls
  `copy_data` if defined, else loops `fetch_addr`). `obj.to_ca`
  returns `obj` itself and materialises nothing.
- **Partial-region materialise** — chain expressions like
  `obj[range, range].copy` and `obj.transpose.copy` go through the
  partial path: the request reaches `copy_block` (per-axis sub-region,
  step ≥ 1) when defined and the access pattern matches, otherwise it
  falls back to `copy_addrs`, otherwise per-cell. Partial requests
  never escalate to whole-view `copy_data`, so lazy backings that
  cannot materialise their entire contents are safe.

  This holds for the transfer path (`copy` and friends). It does
  **not** hold today for the reduction / kernel path: `obj[roi].sum`
  attaches the parent and calls `copy_data` for the whole array
  regardless of the region requested. A lazy backing that cannot
  materialise its full contents must therefore route through `copy`
  rather than reduce a view directly.
- **`obj.attach!` / arithmetic / reduction** — all routed through
  `copy_data` then operate on the resulting buffer.
- **`kernel_iterator`** (3.0) — `CAObject` is accepted as a source;
  the engine attaches once and then yields contiguous slabs to the
  kernel, so even a Ruby-defined CArray can feed a C kernel through
  the universal dispatch surface. This is an instance of CArray's
  "deliver the material" principle being honoured at both ends of the
  hierarchy.
- **MemoryView protocol** — `CAObject` is currently rejected as a
  MemoryView producer (no stable contiguous backing buffer). Use
  `obj.copy` first if you need to hand the data to another library.
- **Mask** — fetchers may return `CA_UNDEF` to mark an element masked;
  the engine creates the mask lazily on first such return.

---

## 6. Advanced: customising the mask itself (`mask_*` hooks)

Most users never touch this. The default mask story (return `UNDEF`
from a fetcher, optionally pre-allocate via `self.mask = 0`) covers
almost every case. This section documents the `mask_*` callback family
for the rare scenario where you want **the mask bits themselves** to
come from Ruby code rather than from a real boolean buffer — for
example, computing "is this index forbidden?" on demand from an
external source.

The hooks mirror the data-side hooks one-for-one, applied to the mask
array instead of the data:

| Method                                              | Role                                              |
|-----------------------------------------------------|---------------------------------------------------|
| `mask_fetch_addr(addr)`                             | Read one mask bit by flat index (`0` or `1`).     |
| `mask_fetch_index(idx)`                             | Read one mask bit by N-D index.                   |
| `mask_store_addr(addr, val)`                        | Write one mask bit by flat index.                 |
| `mask_store_index(idx, val)`                        | Write one mask bit by N-D index.                  |
| `mask_copy_data(data)`                              | Provide the whole mask in one call (bulk).        |
| `mask_sync_data(data)`                              | Receive the whole mask in one call (bulk).        |
| `mask_fill_data(val)`                               | Broadcast a single mask bit to every element.     |
| `mask_copy_block(starts, counts, steps, data)`      | Provide partial mask region (per-axis sub-region).|
| `mask_sync_block(starts, counts, steps, data)`      | Receive partial mask region.                      |
| `mask_copy_addrs(addrs, data)`                      | Provide mask bits for an arbitrary address list.  |
| `mask_sync_addrs(addrs, data)`                      | Receive mask bits for that address list.          |

The four partial-region variants (`mask_copy_block` / `mask_sync_block` /
`mask_copy_addrs` / `mask_sync_addrs`) follow exactly the dispatch and
contract rules of their data-side counterparts described in
*Optional: partial-region fast paths* under §2. They are the right hook
when partial-region data is delivered by `copy_block` / `copy_addrs` and
you also need mask bits to flow through the same chunked path.

The same contract as on the data side applies: **all variants you
implement must agree on the value for any given address**. The engine
caches Ruby-callback results in the internal mask buffer (per-element
fetches write through via the same address) and bulk paths read that
buffer; if your fetchers return different values for the same address
across calls, the cache will diverge from the function and bulk
results will be wrong. As long as your callbacks are pure, the cache
is a transparent memoisation layer.

This family is rarely used in practice. The shipped examples in
`lib/carray/object/` do not define any of these. Reach for them only
when:

- the mask is genuinely *computed* (not stored), and
- the per-element callback cost is acceptable for your use case.

If you only need static mask data, prefer `self.mask = real_boolean_array`
or returning `UNDEF` from your normal fetcher — both are simpler and
faster.

---

## 7. See also

- `lib/carray/object/ca_obj_iterator.rb`, `ca_obj_link.rb`,
  `ca_obj_nested.rb`, `ca_obj_pack.rb` — the canonical examples
  (all under ~130 lines).
- `ext/ca_obj_object.c` — the C-side dispatcher; the comment header
  enumerates every template method the engine looks for.
- `docs/Composition.md` — `bind` / `merge` / `combine` / `composite` /
  `join`, the built-in (C-implemented) composition methods that cover
  the common multi-array assembly cases without needing `CAObject`.
- `docs/WritingCExtensions.md` — the path to follow when a prototype
  `CAObject` subclass is ready to be promoted to a C view.
