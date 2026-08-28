# Semantic identity views with `CAFace`

CArray 3.0 introduces a *Face* mechanism that lets a CArray carry a
Ruby-visible semantic identity (a date, a duration, an angle, a
quantity with units, …) without altering its storage layout. A Face
view shares the parent's data buffer byte-for-byte, but presents a
different Ruby class, a different scalar return type, and any
domain-specific methods its author chooses to attach.

CAFake (a data_type-reinterpreting view) and CAByteSwap (an
endian-reinterpreting view) belong to the same family — *masks* that
sit on top of a storage layer without copying data. Face is the
semantic-identity variant: the storage is unchanged, the identity is.

This document is the user- and extension-author-facing reference for
the Face substrate.

---

## 1. Overview

A Face view satisfies three properties:

1. **Storage transparency.** The view's buffer is the parent's buffer
   verbatim. No element conversion happens at the storage layer.
   `dt.bytes == dt.parent.bytes`, and `dt[i]` (at the C level) reads
   the same bytes that `dt.parent[i]` reads. A Face may optionally
   present a *surface* `data_type` different from its parent's
   *storage* `data_type` (e.g. a NonNumericFace declares surface =
   `CA_FIXLEN` to gate mkkernel numeric dispatch while parent stays
   int64); see §2.5 below.
2. **Identity carry.** The view has its own Ruby class
   (`CATime`, `CATimedelta`, user-defined `CACircular`, …) and
   that class is preserved across every view-creating operation
   (`dt.transpose.reshape(...).flip[2..5].class == CATime`).
3. **Top-of-chain placement.** A Face is always the outermost view in
   the chain. A reference / slice / transpose operation on a Face is
   rewritten so the Face stays on top:
   `CATime[CABlock[int64_entity]]`, never
   `CABlock[CATime[int64_entity]]`.
   `dt.parent.data_type == storage` is the invariant maintained
   across the full view chain (§8).

The mechanism is implemented as a small substrate in
`ext/ca_obj_face.{c,h}`:

- A flag, `CA_FLAG_IS_FACE`, marks an instance as a Face.
- An abstract class, `CAFace`, sits in the class hierarchy as the
  organisational base for C-level Face subclasses.
- A set of helper functions, `ca_face_*`, implements the
  storage-transparent op-table slots (attach / sync / detach /
  fill_data / xfer_*) by forwarding to the parent.
- A lift hook, `ca_face_lift`, wraps the result of a view-creating
  method so the Face stays at the top of the chain.
- A strip helper, `ca_strip_face`, peels Face layers off when an
  internal pipeline (e.g. `kernel_iterator`) needs to talk to the
  underlying storage directly.

The same mechanism supports two implementation styles — a C-level
struct subclass (used for `CATime` / `CATimedelta`) and a
Ruby-level subclass of `CAObject` (used for user-defined Faces).
Section 3 lays out the choice; sections 4 and 5 walk through each
path.  For Ruby authors writing a new semantic type, the headline
is that the CAObject path requires **zero storage callbacks** — a
complete Face is roughly six lines of `initialize`, with all
per-cell I/O delegated to the parent CArray at native C speed.
See §3 for the worked example.

---

## 2. The flag is the gate, the class hierarchy is organisation

The single source of truth for "is this a Face?" is the
`CA_FLAG_IS_FACE` bit in `ca->flags`. Every Face-aware code path —
`ca_face_lift`, `ca_strip_face`, the deployment macros, the
`kernel_iterator` entry — reads the flag, not the class hierarchy.

```c
static inline int ca_is_face(const CArray *ca) {
    return ca_test_flag(ca, CA_FLAG_IS_FACE);
}
```

The Ruby-side equivalent is `ca.face?`, which reads the same bit.

The `CAFace` class exists for two unrelated reasons:

- **Inheritance organisation.** C-level Face subclasses derive from
  `CAFace`, so their Ruby class hierarchy reads
  `CATime < CAFace < CAView < CArray`. The shared op
  helpers live in the same source file (`ext/ca_obj_face.c`) — the
  class is the natural owner of the file's other contents.
- **TypedData chain.** `caface_data_type.parent =
  &caview_data_type`, and concrete subclasses chain their
  `data_type` through `caface_data_type`. This is purely a
  type-tag-relationship marker; the callbacks (`dmark`, `dfree`,
  `dsize`) are defined per subclass, not inherited from the chain.

Because the class hierarchy is organisation rather than the gate, two
useful invariants hold:

- **C-level Face subclasses inherit from CAFace.** `is_a?(CAFace)` is
  true for them, but this is a *consequence* of how they happen to
  be organised, not the definition of "Face".
- **CAObject-based Faces do not inherit from CAFace.** A user-written
  Face that subclasses `CAObject` does not enter the `CAFace`
  hierarchy. It still sets the flag, so `ca_is_face` returns true,
  but `is_a?(CAFace)` returns false. Code that decides whether
  something is a Face must use the flag.

`CAFace` itself is abstract; its allocator raises `TypeError`. Only
concrete subclasses can be instantiated.

## 2.5 Numeric vs NonNumeric surface — the FIXLEN gate

A Face declares one of two surface choices at setup time:

| | surface `data_type` | mkkernel numeric dispatch | example |
|---|---|---|---|
| **Numeric Face** | `parent->data_type` (e.g. float64) | passes through to numeric kernels | an angle in radians (`samples/face/ca_circular.rb`): the surface value *is* the stored number |
| **NonNumeric Face** | `CA_FIXLEN` | hits `ca_*_not_implement` stub → `rb_eCADataTypeError` | `CATime`, `CATimedelta` (`dt + dt`, `sqrt(dur)` are nonsense) |

The NonNumeric variant leverages the fact that mkkernel emits
`ca_*_not_implement` raise stubs for `CA_FIXLEN` slots — by declaring
`ca->data_type = CA_FIXLEN` in setup, all numeric / math / reduction
kernels naturally raise without any new gate infrastructure. The
*storage* remains the parent's `data_type` (e.g. int64); the FIXLEN
label is the *surface* the dispatch table sees.

Choosing between the two:

- If the parent storage operations make algebraic sense on the Face
  (`+` `-` `*` `sum` etc. preserve domain semantics), choose Numeric.
- If they do not (time + time, sqrt(epoch), bitwise(offset),
  …), choose NonNumeric — silent nonsense becomes a loud TypeError.

Note that "some of them make sense" is not Numeric: the dispatch is
all-or-nothing, so a Face whose `+` is meaningful but whose `sqrt` is not
takes NonNumeric and defines the meaningful ones itself. `CATimedelta` is
the worked example — durations add, scale and average, and every one of
those is a Ruby override, while `sqrt(5 seconds)` and a variance in
squared ticks are exactly what the gate should stop.

### Choosing NonNumeric means declaring `#to_numeric`

The gate stops the *implicit* numeric dispatch, not an explicit request.
`to_type(:float64)` is the caller saying "give me these values as
numbers", and a NonNumeric Face must answer it — its storage is not the
answer (scaled integers, codes, serials), and no rule can infer one. So
the Face declares it:

```ruby
class CAFixedPoint < CAObject       # int64 storage, CA_FIXLEN surface
  def to_numeric
    parent.float64 / @scale.to_f
  end
end

prices.to_type(:float64)   # => [123.45, 130.20, 128.75]
prices.to_type(:int64)     # => [123, 130, 128]  (ordinary cast of the above)
```

`#to_numeric` returns the values as a **plain CArray** of any numeric
type and the requested type follows as an ordinary cast of it, so one
method covers every target. It is array-level on purpose: the vectorised
expression the author writes anyway costs 1.45 ms per million cells,
where going through the surface cell by cell costs 449 ms.

A Face that declares nothing raises when cast to anything but `:object`
— which is the Face saying its values are not numbers, information that
an array of `UNDEF` would not carry. The two explicit escapes remain:
`to_type(:object)` for the surface values, `#parent` for the storage.
None of this applies to a Numeric Face, whose surface *is* its storage.

This choice governs the **arithmetic / math / reduction** dispatch only.
It is independent of the ordering, search, count and value-hash families,
which are gated separately by `CA_FLAG_FACE_ORDERABLE_STORAGE` /
`CA_FLAG_FACE_COMPARABLE_STORAGE` (§6.3, and
[`FaceOrderingSearch.md`](../authoring/FaceOrderingSearch.md)). Those gates test
`CA_FLAG_IS_FACE` and never read the surface `data_type`, so **a Numeric Face
needs the flags exactly as much as a NonNumeric one** — a Face whose surface
and storage are the same `int64` is still refused by `sort` / `bsearch` /
`unique` until it sets `ORDERABLE`. Picking Numeric buys you `+` and `sum`; it
buys you nothing at those other gates.

The invariant `Face.parent.data_type == storage` is maintained across
view chains regardless of which choice is made: the lift hook rewrites
intermediate view `data_type` to the storage type so that
`dt[0..2].parent.data_type` is still int64, never FIXLEN.

Permitted operations on a NonNumeric Face are restored by Ruby method
overrides that route through `parent` (e.g. `dt.sort` calls
`parent.sort.time(unit: unit)`). See §6 / §9 for examples.

External-gem Faces (`carray-text`, `carray-categorical`,
`carray-sparse` etc.) gain the gate for free by setting
`data_type = CA_FIXLEN` at setup; no coordination with the core
flag mechanism is required. This is the design rationale for the
FIXLEN-surface approach.

A CAObject-based (= pure-Ruby) Face declares the same surface choice
via `super(CA_FIXLEN, dim, bytes: 8, storage: <storage_type>,
parent: <entity>, face: true)`; see §5.4 for the full pattern.

---

## 3. Two implementation paths

Both paths produce a Face that obeys the three properties of §1, and
both are transparently consumed by every view-creating method, by
`kernel_iterator`, and by per-cell access.

| Path | Class hierarchy | Storage type | Hot path | Effort |
|---|---|---|---|---|
| **C-level Face** | `MyFace < CAFace < CAView` | Any (int64, float64, FIXLEN, …) | C struct + op table; per-cell access is dispatcher-direct | ~250 lines C |
| **CAObject Face** | `MyFace < CAObject` (flag set via `face: true`) | Any | Ruby-level method definitions; per-cell access still C-fast (Face mode bypasses CAObject's per-cell Ruby callback) | ~30 lines Ruby |

### A complete Face is six lines of Ruby

The headline UX of the CAObject path: **Face mode requires zero
storage callbacks**.  Unlike traditional CAObject usage
([`CAObject.md`](CAObject.md) §2), where the author must define at
least `fetch_index` / `fetch_addr` (and `store_*` for writable
arrays) to back per-cell Ruby callbacks, a Face under
`face: true` short-circuits all of that — storage lives in the
`:parent` CArray and the `ca_face_*` thin-forward helpers route
every storage op directly to it.

```ruby
class MyPrice < CAObject
  def initialize(parent, currency: :usd)
    @currency = currency
    super(CA_FIXLEN, parent.dim, bytes: 8, storage: CA_INT64,
          parent: parent, face: true)
  end
end
```

That is a complete, fully functional Face.  No `fetch_index`, no
`store_index`, no `copy_data`, no `sync_data` — and per-cell access
runs at the parent's native C speed (= int64 dispatch here), not
the ~100× overhead of a Ruby-callback per cell.  From this point
on, the author only writes what is *new* about their type: domain
methods (`#convert_to`, `#total`, …), operator overrides where the
semantics differ from raw storage arithmetic, and optional
`copy_state` / `storage_to_scalar` hooks.

This is what makes external-gem Faces (`carray-text`,
`carray-categorical`, `carray-money`, `carray-sparse`, …) tractable
to build without touching CArray core: the Face substrate provides
view-chain identity carry, mkkernel gating (via FIXLEN surface),
mask propagation, MemoryView export, and all the storage plumbing.
The Ruby author writes only the semantic layer.

**Use the C-level path** when the Face is part of the core type
system (time, timedelta), when extra struct-tail state is needed
beyond what a Ruby ivar comfortably expresses, or when the Face needs
to participate in C-level dispatch in a non-trivial way.

**Use the CAObject path** for user-domain semantic types (angle,
quantity, custom calendar, fixed-point) where Ruby-level operator
definitions and ivar state are sufficient.

The two paths are interchangeable from a *user's* perspective: code
that consumes a Face cannot tell which path it came from.

---

## 4. Writing a C-level Face subclass

This section walks through what `CATime` does. The exact source
lives in `ext/ca_obj_time.c`; the structure is the same for any
new C-level Face.

### 4.1 The struct

```c
typedef struct {
  /* === CAView prefix (must match field-for-field) === */
  int16_t    obj_type;
  int8_t     data_type;      /* the storage data_type, e.g. CA_INT64 */
  int8_t     ndim;
  int32_t    flags;          /* CA_FLAG_IS_FACE is set in setup */
  ca_size_t  bytes;
  ca_size_t  elements;
  ca_size_t *dim;
  char      *ptr;
  CArray    *mask;
  CArray    *parent;
  uint32_t   attach;
  uint8_t    nosync;
  /* === Face tail (subclass-specific state) === */
  int8_t     unit;           /* the tick base (CATime-specific) */
  int64_t    count;          /* tick multiplier N: tick = count * base */
} CATime;
```

The prefix up to `nosync` is dictated by `CAView`. The tail holds
whatever per-instance semantic state the Face needs. CATime
keeps a unit byte plus an int64 tick multiplier; CATimedelta likewise;
a CARecord-style Face puts a `data_class` reference here.

The tail is included in `dsize`:

```c
static size_t
ca_time_dsize (const void *ap)
{
  const CATime *ca = (const CATime *) ap;
  return sizeof(CATime) + ca->ndim * sizeof(ca_size_t);
}
```

`dsize` is what the lift mechanism uses to memcpy the struct
(including the tail) when a derived view inherits the Face's identity
— see §6.

### 4.2 The `data_type`

```c
const rb_data_type_t catime_data_type = {
    .parent           = &caface_data_type,
    .wrap_struct_name = "CATime",
    .function = {
        .dmark  = ca_mark,
        .dfree  = ca_free,
        .dsize  = ca_time_dsize,
        .dcompact = NULL,
    },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY,
};
```

The parent pointer goes through `caface_data_type` (declared `extern`
in `carray.h`), which itself chains `caview_data_type`. This makes
`TypedData_Get_Struct(obj, ..., &carray_data_type, ca)` work for any
Face — the chain reaches `carray_data_type` at the root.

`dmark` / `dfree` / `dsize` are defined per subclass; the
`caface_data_type` entry leaves them NULL and does not contribute to
inheritance. The chain is purely a type-tag-relationship marker.

### 4.3 The op table

```c
ca_operation_function_t ca_time_func = {
  -1,                              /* obj_type, filled by ca_install_obj_type */
  CA_VIRTUAL_ARRAY,
  free_ca_time,                  /* subclass-specific (frees tail) */
  ca_time_func_clone,        /* subclass-specific (knows tail size) */
  ca_time_func_allocate,     /* subclass-specific (alias parent->ptr) */
  ca_face_attach,                  /* shared helper */
  ca_face_sync,                    /* shared helper */
  ca_face_detach,                  /* shared helper */
  ca_face_fill_data,               /* shared helper */
  ca_time_func_create_mask,  /* subclass-specific (refer to parent mask) */
  ca_face_xfer_index,              /* shared helper */
  ca_face_xfer_addrs,              /* shared helper */
  NULL,                            /* fold_stride: identity Face is not foldable */
  ca_face_xfer_stride,             /* shared helper */
  ca_face_xfer_all,                /* shared helper */
};
```

Eight of the fourteen slots are shared `ca_face_*` helpers declared
in `ext/ca_obj_face.h`. They implement the storage-transparent
default: attach forwards to the parent and aliases `parent->ptr`,
sync forwards, detach releases the alias and detaches the parent,
xfer slots delegate to the parent's xfer routines, fill_data
delegates to `ca_fill`.

The six subclass-specific slots cover the things that must know about
the tail or the data_type:

- `free_object` — frees the tail.
- `clone` — duplicates with the correct tail size.
- `allocate` — establishes the alias to `parent->ptr`. The alias is
  the entire reason Face is "free": no buffer is malloced, no bytes
  are copied; the Face just sees the parent's buffer as its own.
- `create_mask` — usually a `CARefer` over the parent's mask, so the
  Face inherits the parent's mask without copying.

### 4.4 The setup function

```c
int
ca_time_setup (CATime *ca, CArray *parent, int8_t unit, int64_t count)
{
  if ( parent->data_type != CA_INT64 ) {
    rb_raise(rb_eTypeError,
             "CATime requires int64 storage");
  }
  ca->obj_type  = CA_OBJ_TIME;
  /* NonNumericFace: surface = CA_FIXLEN gates mkkernel numeric ops
     (= dispatch hits ca_*_not_implement stub → TypeError).  Storage
     remains parent->data_type (= CA_INT64); bytes = 8 must be set
     explicitly for FIXLEN.  See §2.5 for the surface vs storage
     choice. */
  ca->data_type = CA_FIXLEN;
  ca->flags     = CA_FLAG_IS_FACE;     /* <-- the gate */
  ca->ndim      = parent->ndim;
  ca->bytes     = sizeof(int64_t);
  ca->elements  = parent->elements;
  ca->ptr       = NULL;                /* alias is set in allocate */
  ca->mask      = NULL;
  ca->dim       = ALLOC_N(ca_size_t, parent->ndim);
  memcpy(ca->dim, parent->dim, sizeof(ca_size_t) * parent->ndim);
  ca->parent    = parent;
  ca->attach    = 0;
  ca->nosync    = 0;
  ca->unit      = unit;
  if ( ca_has_mask(parent) ) ca_create_mask((CArray *) ca);
  if ( ca_is_scalar(parent) ) ca_set_flag(ca, CA_FLAG_SCALAR);
  if ( ca_test_flag(parent, CA_FLAG_READ_ONLY) )
    ca_set_flag(ca, CA_FLAG_READ_ONLY);
  return 0;
}
```

The critical line is `ca->flags = CA_FLAG_IS_FACE`. Every Face
subclass sets this flag in setup; downstream Face-aware machinery
detects Face-ness from the flag alone. A Numeric Face writes
`ca->data_type = parent->data_type` (= the storage type); a NonNumeric
Face — `CATime` and `CATimedelta` both — writes
`ca->data_type = CA_FIXLEN` to opt into the mkkernel gate.

### 4.5 The `Init_` function

```c
void
Init_ca_obj_time ()
{
  rb_cCATime = rb_define_class("CATime", rb_cCAFace);
  CA_OBJ_TIME = ca_install_obj_type(rb_cCATime,
                                          &catime_data_type,
                                          rb_cCArrayMask,
                                          &carray_mask_data_type,
                                          ca_time_func);
  rb_define_alloc_func(rb_cCATime, rb_ca_time_s_allocate);
  rb_define_method(rb_cCATime, "initialize_copy",
                                     rb_ca_time_initialize_copy, 1);
  /* ... domain methods (unit, wrap, etc.) ... */
}
```

The class is registered under `rb_cCAFace` (not `rb_cCAView`),
so its Ruby class hierarchy reads `CATime < CAFace <
CAView < CArray`. The `Init_` must be called *after* `Init_ca_face`
(which defines `rb_cCAFace`); `ext/ruby_carray.c` orders these
correctly.

### 4.6 Ruby surface

The class itself is now defined. Ruby-side method additions (`unit`,
operator overrides, `storage_to_scalar` for scalar fetch, helpers like
`CArray.time_series`) live in `lib/carray/time.rb`. They are
ordinary Ruby methods on the registered class; nothing about the
Ruby surface is special-cased for Face.

---

## 5. Writing a CAObject Face

The Ruby-level path uses `CAObject`'s existing infrastructure
(`:parent` option, callback-based `fetch_index` / `store_index`) but
sets the Face flag at construction. With the flag set, the per-cell
Ruby callbacks are bypassed (`CAObject` shortcuts to a
thin-forward path semantically equivalent to `ca_face_*`), so the
view runs at C speed; the Ruby class is consulted only for
operator dispatch, ivar carry, and scalar-return wrapping.

### 5.1 Minimal skeleton

```ruby
class MyFace < CAObject
  def initialize(parent, *args, **opts)
    @semantic_state = ...                    # whatever state the Face needs

    super(STORAGE_DTYPE,                     # e.g. CA_INT64, CA_FLOAT64
          parent.dim,
          parent: parent,
          face: true)                        # <-- sets CA_FLAG_IS_FACE
  end

  attr_reader :semantic_state

  def copy_state(src)                        # called by lift (see §6)
    @semantic_state = src.semantic_state
  end

  # domain-specific methods, operator overrides, etc.
end
```

The `face: true` option is what installs the flag. `CAObject`'s
constructor honours it; nothing else in user code has to change.

### 5.2 Worked example — `CACircular`

A view that treats its parent's float64 buffer as angles, with
circular statistics defined on top:

```ruby
class CACircular < CAObject
  def initialize(parent, range: :rad)
    @range = range                            # :rad or :deg
    super(CA_FLOAT64, parent.dim, parent: parent, face: true)
  end

  attr_reader :range

  def copy_state(src)
    @range = src.range
  end

  def circular_mean
    vals    = self.to_a
    factor  = (@range == :deg) ? (Math::PI / 180.0) : 1.0
    sum_sin = vals.sum { |v| Math.sin(v * factor) }
    sum_cos = vals.sum { |v| Math.cos(v * factor) }
    mean    = Math.atan2(sum_sin / vals.size, sum_cos / vals.size)
    mean   += 2 * Math::PI if mean < 0
    (@range == :deg) ? mean * 180.0 / Math::PI : mean
  end
end

raw = CArray.float64(5) { |i| i * Math::PI / 4 }
cc  = CACircular.new(raw, range: :rad)
cc.circular_mean             # => π/2
cc[1..3].circular_mean       # view chain preserves the Face
cc.flip.range                # => :rad (ivar carried via copy_state)
```

### 5.3 What you may not do

- Do not change the storage. The thin-forward path assumes that
  reading the Face yields the parent's bytes unchanged. Defining
  `fetch_index` that returns a translated value is silently ignored
  in Face mode (it would be a no-op shortcut, not the callback).
- Do not omit `face: true`. Without it the instance is a plain
  CAObject and per-cell Ruby callbacks run on every access.
- Do not omit `copy_state` if you have ivars. The lift mechanism
  uses `dsize`-driven memcpy for the C struct, but Ruby ivars are
  carried via the optional `copy_state` callback. Without it, a
  sliced view's ivars are nil.

### 5.4 NonNumeric Face from CAObject — the `:storage` opt-in

To declare a CAObject-based Face as NonNumeric (= make `face_arr + x`
etc. raise upfront instead of dispatching per-cell through Ruby `:+`),
pass surface = `CA_FIXLEN` as the data_type argument and the actual
storage type via the `:storage` option:

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
arr[0..2].parent.data_type   # => :int64  (storage invariant maintained)
```

The mechanism is the same surface-vs-storage split that
`CATime` uses internally — only that the C-level Face puts
both values in its struct, while the CAObject path puts surface in
the `data_type` argument and storage in `:storage`. See `§2.5
Numeric vs NonNumeric surface — the FIXLEN gate` for the rationale.

#### Contract

| `:storage` | declared `data_type` | parent.data_type | Result |
|---|---|---|---|
| omitted | must equal | parent.data_type | Numeric Face (= legacy, surface == storage) |
| explicit | free (CA_FIXLEN or other) | must equal `:storage` | NonNumeric or numeric, surface != storage allowed |
| explicit but `face: true` omitted | — | — | `ArgumentError` (`:storage` only meaningful in Face mode) |
| explicit but mismatch with parent | — | — | `TypeError` |

`bytes` (or `:bytes`) must always match `parent.bytes`; this is the
memory-layout invariant the lift mechanism depends on.

#### Recovering permitted operations

Numeric ops that *are* meaningful (e.g. comparison, sort) come back
via Ruby overrides that route through `parent`:

```ruby
class MyTagArray < CAObject
  # ... super(...) above ...

  def sort(*a, **o)
    parent.sort(*a, **o).then { |sorted| self.class.new(sorted) }
  end

  def <(other);  parent < other.parent;  end
  def ==(other); parent == other.parent; end
end
```

The `parent` accessor is the escape hatch into the storage int64 (or
whatever the parent's data_type is); the FIXLEN surface only blocks
the *unconditional* numeric-kernel dispatch, not Ruby-level
delegation.

---

## 6. The lift mechanism

The "Face is always at the top of the chain" property is enforced at
the tail of every view-creating method (`[]`, `reshape`, `transpose`,
`flip`, `sort`, …). When the receiver is a Face, the result is
wrapped so the Face identity comes back on top.

The wiring is a single macro:

```c
#define CA_FACE_LIFT_IF_FACE(obj, self, ca) do {                   \
  if ( ca_is_face(ca) && rb_obj_is_kind_of((obj), rb_cCArray) ) {  \
    (obj) = ca_face_lift((obj), (self));                           \
  }                                                                \
} while (0)
```

placed just before the `return` in each view-creating method. The
macro is deployed at the tail of every view-creating method in
CArray's core (slice, reshape, transpose, flip, roll, sort, select,
window, shift, tile, partition, and so on — roughly two dozen sites).
Adding a new view-creating method means adding one line of macro at
its tail.

`ca_face_lift` itself does three things:

```c
VALUE
ca_face_lift (VALUE view, VALUE face_parent)
{
  CArray *view_ca;
  VALUE   lifted;

  TypedData_Get_Struct(view, CArray, &carray_data_type, view_ca);

  /* (a) Duplicate the Face's C struct (including tail), swap its
         parent to point at the new view, and wrap it under the
         Face's Ruby class. */
  lifted = rb_ca_face_template(face_parent, view_ca, view_ca->dim);

  /* (b) Pin the underlying view as the Ruby-level parent of the
         lifted Face, so GC cannot collect the slice we wrap. */
  rb_ca_set_parent(lifted, view);

  /* (c) If the Face's Ruby class defines copy_state, call it to
         carry Ruby-side ivars from the source Face to the lifted
         Face. */
  static ID id = 0;
  if ( id == 0 ) id = rb_intern("copy_state");
  if ( rb_respond_to(face_parent, id) )
    rb_funcall(lifted, id, 1, face_parent);

  return lifted;
}
```

The work done by `rb_ca_face_template` is the storage-transparent
copy. It uses the Face's `dsize` to determine the struct size
(including the subclass tail), `memcpy`s the whole struct, rewrites
the `parent` pointer and the shape fields to point at the new
underlying view, resets `ptr`/`mask` (the lifted Face is unattached
until the next access), and wraps the result under `CLASS_OF(face_
parent)` so the Ruby class identity is preserved.

The Ruby ivar carry, the GC root, and the deployment macro are the
only three things subclass authors need to be aware of:

- C-level Face authors usually do not need `copy_state` because their
  state lives in the struct tail (which the memcpy carries
  automatically). They define `copy_state` only when they hold
  state in Ruby ivars in addition to the tail.
- CAObject-based Face authors usually do need `copy_state`, because
  their state is in ivars by definition.
- New view-creating methods need one line of `CA_FACE_LIFT_IF_FACE`
  at the return path.

### 6.1 Scalar return — `storage_to_scalar`

Per-cell access (`ca[i]`, `ca.fetch_index(...)`, `ca.to_a[k]`, …)
returns a Ruby scalar, not a CArray. The lift mechanism cannot apply
here; instead a parallel hook reads the Face's storage value and
hands it to a wrapper. The hook prefers a C function pointer
registered via `ca_face_register_storage_to_scalar` and falls back to a
Ruby method named `storage_to_scalar` if none is registered:

```c
#define CA_FACE_STORAGE_TO_SCALAR_IF_FACE(obj, self, ca) do {                       \
  if ( ca_is_face(ca) && (obj) != CA_UNDEF && (obj) != Qnil                   \
       && ! rb_obj_is_kind_of((obj), rb_cCArray) ) {                          \
    ca_face_storage_to_scalar_fn _fn = ca_face_storage_to_scalar_table[(ca)->obj_type]; \
    if ( _fn != NULL ) {                                                      \
      (obj) = _fn((self), (obj));                /* C fast path */             \
    } else {                                                                  \
      static ID id_w = 0;                                                     \
      if ( id_w == 0 ) id_w = rb_intern("storage_to_scalar");                    \
      if ( rb_respond_to((self), id_w) )                                      \
        (obj) = rb_funcall((self), id_w, 1, (obj));                           \
    }                                                                         \
  }                                                                           \
} while (0)
```

In-core Faces register a C function at `Init_` time:

```c
ca_face_register_storage_to_scalar(CA_OBJ_TIME,
                                rb_ca_time_storage_to_scalar);
```

The Ruby class still defines `storage_to_scalar` (via `rb_define_method`
on the C function), so Ruby callers can use
`dt.storage_to_scalar(raw)` directly — the Ruby method is a thin
ergonomic wrapper around the same C function. The "C-as-core,
Ruby-as-thin-surface" direction is intentional: external-gem Faces
that omit `ca_face_register_storage_to_scalar` still work via the
`rb_funcall` fallback by defining `def storage_to_scalar` in Ruby.

For NonNumericFace (FIXLEN surface), the per-cell fetch delivers an
8-byte raw `String` to the wrapper; the wrapper decodes it as the
parent storage type:

```c
static VALUE
rb_ca_time_storage_to_scalar (VALUE self, VALUE raw)
{
  CATime *ca; CATimeElement *s;
  int64_t epoch;
  TypedData_Get_Struct(self, CATime, &catime_data_type, ca);
  if (TYPE(raw) == T_STRING) {
    memcpy(&epoch, RSTRING_PTR(raw), sizeof(int64_t));
  } else {
    epoch = NUM2LL(raw);   /* Numeric Face surface delivers Integer */
  }
  VALUE obj = TypedData_Make_Struct(rb_cCATimeElement,
                                    CATimeElement,
                                    &catime_element_data_type, s);
  s->value = epoch;
  s->unit  = ca->unit;
  return obj;
}
```

Note the `Element` itself is also a C TypedData struct (= `int64 value
+ int8 unit`); direct `TypedData_Make_Struct` + field write avoids
both `LL2NUM` boxing and `rb_class_new_instance` (= Ruby `initialize`
dispatch). The Ruby-side `CATime::Element` keeps only
non-perf-critical methods (`to_time`, `to_s`, `inspect`, `<=>`,
`==`); `value` / `unit` are C accessors.

The macro is a no-op for non-Face arrays, for `UNDEF` (masked
elements), and for sub-array fetches (those go through the lift
macro).

Naming: `storage_to_scalar` is a decode — it copies the storage value
out and constructs a fresh surface value object (not a zero-copy wrap of
the parent bytes). Its write counterpart is `scalar_to_storage`
(§6.2); the two form a matched directional pair.

**Bulk paths take the same route.** Anything that hands a Face's cells
back as Ruby values decodes through this hook, so it yields the surface:

- `to_a` — a Face never takes the numeric fast path (which reads the
  storage buffer), whatever its storage `data_type`. A numeric-storage
  Face (`CATimedelta` is `int64`) would otherwise hand back serials while
  `ca[i]` handed back `Element`s.
- `to_type(:object)` / `#object` — the object cast of a Face is its
  **surface values**: labels rather than codes, `CATime::Element` rather
  than serials, the string rather than the `(start, end)` descriptor. The
  same rule data_class arrays (`CARecord` / `CAStruct`) have always had.
- `as_type` / `fake` / `CArray.wrap_readonly` / `CArray.wrap_writable` —
  these reinterpret storage under another `data_type`, and no view
  decodes a surface, so none of them may answer with the bytes. The one
  that never promised a view answers with the conversion `to_type`
  performs: `wrap_readonly` gives the surface values for `:object` and
  `#to_numeric` for a numeric type, which is what makes a Face usable as
  an operand of a plain array without silently arriving as bytes.
  `as_type`, `fake` and `wrap_writable` raise, naming both ways down.
  A Numeric Face asked for another numeric type is not affected — its
  surface is its storage, so the ordinary adapting view is right.

The storage stays reachable, deliberately and explicitly, through
`.parent` — `td.parent.to_a` gives the serials, and it keeps the fast
path. Reaching the storage should be something the caller wrote down.

### 6.2 Scalar store — `scalar_to_storage`

The read hook has a write counterpart: storing a surface value object
into a Face cell (`dt[i] = other_instant`) must convert *back* to the
Face's storage domain, or the raw store would ignore the unit. The
hook is the mirror of `storage_to_scalar`: it prefers a C function
registered via `ca_face_register_scalar_to_storage` and falls back to
a Ruby method `scalar_to_storage(surface)`.

Unlike the read hook, the write hook is not placed at each return
site. It fires in one place, `rb_ca_obj2ptr` — the single funnel every
surface-value store passes through — just before the storage cast:

```c
if ( ca_face_safe_check(ca) ) {
  obj = ca_face_scalar_to_storage(self, ca, obj);   /* surface -> storage-domain */
  convert_type = ca_storage_type_of(ca);
}
```

`ca_face_scalar_to_storage` returns `obj` unchanged for a non-Face `ca`
(so the non-Face store path is untouched), consults the C table first,
then the Ruby fallback. The contract of the hook:

- a recognized surface value object (for time/timedelta: `Element`,
  `Time`, `DateTime`) → a storage-domain value in the Face's unit;
- a bare `Integer` / `String` it does not recognize → returned
  unchanged, so the existing storage cast (and the `.parent` raw-store
  escape) is preserved;
- an unconvertible value (e.g. a cross-unit-group instant) → raise,
  never a silent mis-store.

time/timedelta implement the hook by delegating to the same
`to_comparable` unit algebra the reference side uses, so read and write
stay in lockstep: `dt[0] = dt[2]; dt[0] == dt[2]` holds by
construction. The Ruby-only tier (fallback, no C table entry) is
sufficient for correctness; a C table entry is an optional hot-path
follow-up.

### 6.3 Operation families — what each one takes from you

§6 covers who puts the Face back on a **view**, 6.1 / 6.2 on a **scalar**.
This section is the third layer: the operation *families* that will meet your
Face, what each needs from you, and how to tell you have covered them.

It is written from the bill: bringing `CATime` through the families cost five
rounds of "this site did not know", one of which answered **silently wrong**
rather than visibly wrong. The failures were not N unrelated items — they were
three patterns repeating across sites, which is what makes them checkable.

#### The three questions

Answer these before writing any code; they decide your flags and your overrides.

| question | yes | no |
|---|---|---|
| Does descending to storage preserve my element **order**? | set `CA_FLAG_FACE_ORDERABLE_STORAGE`: the sort, search, count and value-hash families descend and lift for you | leave it unset and answer for yourself (below) |
| Can an external value be compared against my storage **as it stands**? | also set `CA_FLAG_FACE_COMPARABLE_STORAGE` | define `to_comparable(operand)`, which reconciles any operand type into your space |
| Do I carry a **unit** — an alternative space for the same value? | `to_comparable` is where the conversion lives (and where you refuse what cannot convert) | you need neither flag's conversion path; one space is all there is |

The order question carries the equality question with it, which is why the
value-hash family (equality, not order) uses the same flag. The hazard it rules
out is **distinct storage that decodes to the same value**: an order-preserving
descent cannot have it, and a Face that does have it must not claim ORDERABLE.

None of the three asks whether your surface is numeric, and that is not an
omission: the gates key on `CA_FLAG_IS_FACE` alone. A Numeric Face (§2.5,
surface `data_type` == its numeric storage) answers the same three questions
and sets the same flags — `CATimedelta` is `int64` on both sides, answers
*yes / no / yes*, and so sets `ORDERABLE` only plus a `to_comparable`. Setting
neither flag means the families refuse you, whatever your surface type is.

#### The three patterns

Every gap found so far is one of these. The middle one is the dangerous one.

| # | pattern | what it looks like when a site does not know |
|---|---|---|
| **P1** | a **value output** is not lifted back | raw storage leaks to the caller — byte strings, or bare ticks. Ugly, but visible the first time you look |
| **P2** | an **operand** is not reconciled into your space | **a wrong answer that looks right.** Same-unit input still works, so ordinary tests pass; only a cross-unit case exposes it (`d(:D).is_in(h(:h))` answered "no shared instants" for arrays that shared one) |
| **P3** | the **write** direction disagrees with the read | a bare value truncates into storage instead of being refused |

#### What the flags buy, and what stays yours

| family | covered by the flags? | your part |
|---|---|---|
| view-creating (`[]`, `reshape`, `sort`, `flip`, …) | yes (lift macro, §6) | nothing |
| scalar read / store | — | `storage_to_scalar` / `scalar_to_storage` (6.1 / 6.2) |
| `min` / `max` / sort / partition / rank | ORDERABLE | nothing (`minmax` has no core gate: re-lift the pair in Ruby) |
| search / `linear_section` / `count(v)` | ORDERABLE + (COMPARABLE or `to_comparable`) | the one `to_comparable` |
| value-hash discovery (`unique`, `value_counts`, `mode`, `is_in`, set operations, `locate_addr`, `categorize`) | ORDERABLE + same | nothing |
| gap-fill (`unmask` / `strip_mask` with `method:`) | hold is byte-generic (any Face); `:linear` defers to your `linear_fetch` | nothing, once `linear_fetch` is decided |
| `linear_fetch` | **no** — it returns a value in your space, and the grid policy is yours | a Ruby override (`CATime` keeps its unit and rounds to its grid) |
| reductions that land in a **different** value space (`sum`, `mean`, `median`, `stddev`, `variance`) | **no** | decide each one in Ruby. `CATime` raises on `sum` (instants do not add) and on `variance` (squared time has no type), answers `mean` / `median` on its own unit rounded to the nearest tick, and returns a `CATimedelta` for `stddev` |

The last two rows are the ones no flag can answer: they are semantics, not
mechanism. Everything above them should be free once the flags are right — and
if it is not, that is a bug in the family, not something for you to work around.

#### When your equality is not your storage's

Do **not** set ORDERABLE. Answer for yourself instead, in plain Ruby methods
next to your other surface methods. The two in-tree cases show the two shapes:

| Face | why the flag would lie | shape of the answer |
|---|---|---|
| `CAConstString` | a cell is a `(start, end)` byte range, so the same string at two offsets is two cells | **decode and delegate**: run the family on `#to_string` (where a cell *is* the string) and rebuild value outputs with `#to_const_string` |
| `CACategorical` | code order is the vocabulary's order, not the labels'; and a lifted code array is still codes | **translate only what crosses the surface**: keep distinctness on the codes (a `uint8` pass) and map codes to labels on the way out |

Two ordering traps in the second shape, both real: a "sorted" result must be
sorted in **your** space (`unique(sort: true)` sorts labels, not codes), and any
contract that says "ascending" (`mode`) has to be evaluated there too.

#### Knowing you are done

The families are enumerable, so make a matrix rather than trusting review:

1. For every **value-returning** member, assert the returned **class** and the
   state that identifies your space (unit, labels, encoding). This catches P1.
2. For every **two-array** member, assert one case whose operand is in a
   *different* space from the receiver — a different unit, a different
   vocabulary. This is the only thing that catches P2, and it is cheap.
3. Assert one **write** case per surface type you accept, plus one bare-storage
   case that must be refused. This catches P3.
4. Assert that the members you deliberately left plain (counts, booleans,
   addresses) are still plain, so a later sweep does not "fix" them.

That matrix exists: **`spec/spec_ai/test_face_family_matrix.rb`**. Adding a Face
means adding one row to its `FACES` table; a member your Face does not support
is declared in `raises:` and asserted to raise, so a skip is an assertion too —
if someone later makes it work, the matrix fails and asks for the table to be
updated rather than quietly losing the coverage.

It earns its keep immediately: its first run named `CAFixlenString#unique lost
the Face (P1)`, which is how that gap got closed. Prevention is not available —
the lift and gate points are per-site by construction (§6 says two dozen sites,
and that is the price of not having a data type descriptor) — so detection is where
the effort belongs.

---

## 7. Helper reference

All Face mechanism helpers are declared in `ext/ca_obj_face.h`.

### 7.1 Storage thin-forward helpers (op-table slots)

```c
void ca_face_attach     (void *ap);
void ca_face_sync       (void *ap);
void ca_face_detach     (void *ap);
void ca_face_fill_data  (void *ap, void *ptr);

void ca_face_xfer_index (void *ap, ca_size_t *idx,
                         void *data, int dir);
void ca_face_xfer_addrs (void *ap, ca_size_t n, ca_size_t *addrs,
                         void *data, int dir);
void ca_face_xfer_stride(void *ap, ca_size_t *starts, ca_size_t *counts,
                         ca_size_t *strides, void *data, int dir);
void ca_face_xfer_all   (void *ap, void *data, int dir);
```

Each forwards to the parent's corresponding routine. They constitute
the default storage-transparent op table. A Face subclass installs
them by reference in its `ca_operation_function_t` table; a Face that
needs to interpose at the storage layer can override any slot.

### 7.2 Lift / strip helpers

```c
VALUE   rb_ca_face_template (VALUE original_face, CArray *new_parent,
                              ca_size_t *new_dim);
VALUE   ca_face_lift        (VALUE view, VALUE face_parent);
CArray *ca_strip_face       (CArray *src);
```

- `rb_ca_face_template` is the struct duplicator. It is the primitive
  for `ca_face_lift` and for any Face-aware copy machinery. Callers
  do not usually invoke it directly.
- `ca_face_lift` is the deployment-site entry. It wraps a view under
  the Face's Ruby class.
- `ca_strip_face` walks down through Face layers and returns the
  first non-Face parent. It is what `kernel_iterator` calls at entry
  to talk to underlying storage directly. Multiple Face layers
  (rare; only possible when a user explicitly stacks one Face over
  another) are all stripped.

### 7.3 Deployment macros

```c
CA_FACE_LIFT_IF_FACE(obj, self, ca)
CA_FACE_STORAGE_TO_SCALAR_IF_FACE(obj, self, ca)
```

The convention is: place the macro just before the `return` of a
view-creating method (LIFT) or a scalar-fetch method (STORAGE_TO_SCALAR).
`obj` is the result being returned; the macro mutates it in place if
the receiver is a Face.

The write counterpart, `scalar_to_storage` (§6.2), is *not* a
return-path macro. It fires inside `rb_ca_obj2ptr` (the single
surface-value store funnel), so a Face's store conversion applies to
every store path without the author placing a macro at each call site.

### 7.3a Face-local dispatch tables for `storage_to_scalar` / `scalar_to_storage`

```c
/* read: storage -> surface scalar */
typedef VALUE (*ca_face_storage_to_scalar_fn)(VALUE self, VALUE raw);
extern ca_face_storage_to_scalar_fn ca_face_storage_to_scalar_table[CA_OBJ_TYPE_MAX];

void ca_face_register_storage_to_scalar (int obj_type,
                                      ca_face_storage_to_scalar_fn fn);

/* write: surface scalar -> storage */
typedef VALUE (*ca_face_scalar_to_storage_fn)(VALUE self, VALUE surface);
extern ca_face_scalar_to_storage_fn ca_face_scalar_to_storage_table[CA_OBJ_TYPE_MAX];

void ca_face_register_scalar_to_storage (int obj_type,
                                      ca_face_scalar_to_storage_fn fn);
```

A Face subclass that wants the per-cell scalar fetch/store hot path to
skip `rb_funcall` registers its C function in the matching table at
`Init_` time. Both tables are local to the Face mechanism — they are
*not* the same as `ca_operation_function_t`, so extending them does not
require modifying the global op table or any other subsystem.
Unregistered obj_types fall through to `rb_funcall` of the Ruby
`storage_to_scalar` / `scalar_to_storage` method (= the
external-gem-friendly fallback). Registering neither is valid too: a
Face whose surface value already equals its storage value (no unit or
encoding to apply) leaves both tables NULL and stores/reads raw.

### 7.4 The class and the TypedData entry

```c
extern VALUE                rb_cCAFace;
extern const rb_data_type_t caface_data_type;

void Init_ca_face (void);
```

`rb_cCAFace` is the abstract superclass for C-level Face subclasses.
`caface_data_type` is the TypedData chain entry; its callbacks are
NULL (subclasses define their own). `Init_ca_face` registers the
class and forbids direct instantiation; it must be called before any
concrete Face subclass's `Init_` (which `ext/ruby_carray.c` arranges).

---

## 8. Invariants

These rules are load-bearing: code outside the Face substrate is
allowed to assume them.

1. **Flag is the gate.** `ca_is_face(ca)` is the only Face-ness
   check. Class hierarchy is organisation; do not use
   `rb_obj_is_kind_of(obj, rb_cCAFace)` as a Face test.
2. **Face stays on top.** Every view-creating method that operates on
   a Face returns a Face. The lift mechanism is responsible for this;
   new view-creating methods must deploy the lift macro.
3. **Local swap, no sort.** When a view-creating method runs on a
   Face, the reference node and the Face are swapped once. There is
   no Face stack walk, no order preservation across multiple Face
   layers — explicit stacking is the user's responsibility.
4. **Storage is the parent's, by default.** Storage-layer ops on a
   Face thin-forward to the parent. A Face that needs to interpose
   at the storage layer overrides the relevant op-table slot
   explicitly; the default policy is transparency.
5. **kernel_iterator strips Faces at entry.** Reduction / sort /
   search kernels run on storage; the Face-or-not decision is the
   caller's (does the result get re-lifted?), not the kernel's.
6. **Both legs.** Face is a two-leg mask: reads return the parent's
   value (optionally re-wrapped by `storage_to_scalar` for scalars and
   by `ca_face_lift` for view-returning paths); writes accept Ruby
   values (optionally translated by an explicit setter the subclass
   defines) and store them through to the parent. Read-only Face is
   a degenerate case, not the structural rule.
7. **`Face.parent.data_type == storage` across the chain.** For a
   NonNumericFace (surface = `CA_FIXLEN`), the lift hook rewrites
   intermediate view `data_type` to the storage type so any
   `view.parent.data_type` reachable from a Face is the storage type
   (e.g. int64), never `CA_FIXLEN`. This is the escape-hatch
   invariant that lets Ruby overrides write
   `parent.subtract(other.parent)` and have it dispatch on int64.
8. **Primitive non-modification.** Face-aware logic stays at call
   sites, not inside global primitives (`ca_cast_block`,
   `ca_*_func_table` lookup, kernel dispatch). When a call site needs
   to feed a Face into a primitive, it constructs a "shadow CArray"
   (= zero-initialised local with the storage `data_type`, aliasing
   the Face's `ptr`) and passes that to the primitive; the primitive
   never sees the Face. See `rb_ca_store_all`'s Array-RHS branch for
   the canonical example.

---

## 9. Existing Face subclasses

| Class | Path | Storage | Surface | Domain | Defined in |
|---|---|---|---|---|---|
| `CATime` | C-level | `CA_INT64` | `CA_FIXLEN` (NonNumeric) | an absolute instant as an int64 tick index on a `count × base` grid | `ext/ca_obj_time.c`, `lib/carray/time.rb` |
| `CATimedelta`  | C-level | `CA_INT64` | `CA_FIXLEN` (NonNumeric) | a duration as an int64 tick count on a `count × base` grid | `ext/ca_obj_timedelta.c`, `lib/carray/time.rb` |
| `CAString` | C-level | `CA_OBJECT` | `CA_OBJECT` | a String column whose cells are the Strings themselves | `ext/ca_obj_string.c` |
| `CAConstString` | C-level | `CA_FIXLEN` (16 B `(start,end)` pair) | `CA_FIXLEN` | a read-only String column over one shared byte buffer | `ext/ca_obj_const_string.c`, `lib/carray/const_string.rb` |
| `CAFixlenString` | C-level | `CA_FIXLEN` | `CA_FIXLEN` (identical — the Face adds the String surface, not a representation) | a fixed-width String column | `ext/ca_obj_fixlen_string.c` |
| `CACategorical` | Ruby (over the codes) | narrow unsigned codes | `CA_FIXLEN` | dense codes + a label vocabulary | `lib/carray/categorical.rb` |
| `CARecord` | C-level | the struct bytes | `CA_FIXLEN` | a record whose `data_class` decodes the fields | `ext/ca_obj_record.c` |

What each one answered to §6.3's three questions — the same table read as
precedent:

| Class | ORDERABLE | COMPARABLE | `to_comparable` | value families |
|---|---|---|---|---|
| `CATime` / `CATimedelta` | yes | no (a unit-bearing operand needs converting) | yes | ride the gate; `linear_fetch` and the centroid reductions are Ruby overrides |
| `CAString` | yes | no | **no** (one space, nothing to convert) | ride the gate |
| `CAConstString` | **no** — storage is a byte range, not the bytes | — | — | own overrides via `#to_string` (§6.3) |
| `CACategorical` | **no** — code order is the vocabulary's | — | — | own overrides in label space (§6.3) |
| `CAFixlenString` | yes | yes | no (one space) | ride the gate. Both flags hold *by construction*: a cell decodes to its own bytes, padding included, so the descent is the identity map — see the note below |
| `CARecord` | no | — | — | not wired; `memcmp` is the sort default and field-order ordering is still future work |

`CAFixlenString` is the degenerate case worth knowing about: its surface *is*
its storage, byte for byte, so ORDERABLE and COMPARABLE are true by
construction and it should declare both. It did not, and the cost was exactly
P1 — `unique` / `value_counts` / `mode` / the set operations handed their
results back as a plain fixlen array while `sort` / `mask_duplicates` kept the
class — plus a search family that refused a String query for no reason. If your
Face is an identity relabel like this one, declare both flags.

`CATime` is the canonical NonNumericFace example: `dt + dt` is
a category error, so its surface flips to `CA_FIXLEN` and the mkkernel
dispatch table's existing `ca_*_not_implement` stubs do the gating.
`CATimedelta` is NonNumeric for the same reason read one level down:
`dur + dur = dur` does make sense, but the dispatch is all-or-nothing,
and letting it through also lets through `sqrt` of a duration and a
variance in squared ticks. So it gates the surface too and defines the
handful of meaningful operations (`+ - * /`, `abs`, unary `-`, `sum`,
`mean`, `median`, `stddev`, `minmax`) itself. Turning one into a plain
number is `#ticks`, which says which unit it is counting.

`docs/CATime.md` is the user-facing reference for these two
classes. They are also the worked example of the C-level path: the
struct layout, op table, setup function, and Ruby surface follow the
template described in §4 verbatim.

---

## 10. See also

- [`FaceOrderingSearch.md`](../authoring/FaceOrderingSearch.md) — how a Face joins the
  ordering / search / interpolation kernels: the ORDERABLE / COMPARABLE
  flags and the `to_comparable` template method, plus (§5) the read / write
  asymmetry on a bare storage value and (§5.0) why equality rides ORDERABLE.
  §6.3 above is the family-level checklist that sits on top of it.
- [`CATime.md`](CATime.md) — user-facing reference for
  the first two Face subclasses.
- [`CAObject.md`](CAObject.md) — the CAObject callback-based view,
  which is also the substrate for Ruby-level Faces.
- [`WritingCExtensions.md`](../authoring/WritingCExtensions.md) — general guide
  for C extensions against CArray; §3 covers `ca_install_obj_type`
  and the op-table format that every Face subclass uses.
