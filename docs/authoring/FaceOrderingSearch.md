# Face ordering and search — the ORDERABLE / COMPARABLE gate

A Face (see [`CAFace.md`](../topics/CAFace.md)) presents a surface identity over a
numeric storage buffer. Often its surface `data_type` is `CA_FIXLEN` (or another
non-numeric tag) precisely so that mkkernel numeric dispatch does *not*
silently treat it as its storage type. That defensive gate, however, also
blocks the ordering / search / interpolation kernels, which genuinely want to
run on the numeric storage.

**The flags below apply to every Face, whatever its surface `data_type` is.**
The gate is a separate axis from the FIXLEN choice of `CAFace.md` §2.5: it keys
on `CA_FLAG_IS_FACE` and never reads `data_type`, so a Numeric Face — one whose
surface `data_type` *is* its numeric storage type — is refused at these kernels
exactly like a FIXLEN one until it sets `ORDERABLE`. `CATimedelta` is the
in-tree case: `int64` on both sides, and it still has to opt in (§2).

This document explains the opt-in mechanism that lets a Face participate in
those kernels — two flags and one template method — and the C-level policy
that governs it. It is aimed at extension authors writing a Face (in C or as a
`CAObject` subclass). For the user-facing view of one Face that uses it, see
[`CATime.md`](../topics/CATime.md) §10.

Source: `ext/mkkernel.rb` (`emit_sort_dispatch`, `emit_search_dispatch`),
`ext/carray_order.c` (`ca_linear_prep`, `rb_ca_linear_section_m`),
`ext/carray_sort.c` (`rb_ca_s_sort_addr`), `ext/carray.h` (the flags),
`ext/ca_obj_face.c` (`rb_ca_strip_face_value`).

---

## 1. Why a gate exists at all

Without a gate, handing a Face to a numeric ordering/search kernel does one of
two bad things:

- **Silent wrong.** The mkkernel dispatcher switches on `src->data_type`. For a
  FIXLEN-surface Face a search kernel lands on the `memcmp` (byte-wise,
  unsigned) branch; for signed or little-endian numeric storage the ordering is
  wrong — and it fails *silently*. A Numeric Face escapes that particular
  branch but not the hazard: its dispatch is correct only *within one space*,
  so an operand from another space (a `:ns` query against a `:s` array) is
  compared raw and answers wrongly. Neither is safe without the gate.
- **SEGV.** A hand-written flat kernel (`rb_ca_s_sort_addr`) builds its index
  output with `rb_ca_template_with_type`, which face-lifts the result back
  into a Face. That output view has `ptr == NULL`, so the kernel's write
  dereferences a null pointer.

The first response (landed 2026-07-02) was to **reject** any Face at these
kernel entries — *error is better than silent wrong*. The opt-in mechanism
below then re-admits the Faces that can safely descend to storage.

---

## 2. The two flags are different axes

```c
/* ext/carray.h */
#define CA_FLAG_FACE_ORDERABLE_STORAGE  256
#define CA_FLAG_FACE_COMPARABLE_STORAGE 512
```

They answer two different questions. Do **not** conflate them.

| flag | scope | claim | unlocks |
|---|---|---|---|
| **ORDERABLE** | **self** (my own elements) | "my storage order == my surface order" | `sort`, `sort_addr`, `sort_index`, `partition`, `partition_index`, `rank_index`, the value-hash family (`unique`, `value_counts`, `mode`, `categorize`) |
| **COMPARABLE** | **cross** (an external value vs my storage) | "an external value compares directly against my storage, no conversion" | `bsearch`, `search`, `bsearch_addr`, `find_value_index`, `linear_section`, `locate_*`, `count(v)`, `is_in`, the set operations |

- **ORDERABLE is self-scope.** Sorting rearranges *my own* elements; it never
  looks at an external value. If descending to storage preserves my order,
  I can be sorted. A unit-bearing Face is automatically ORDERABLE: every
  element shares the array's unit, so storage order is always surface order.

- **COMPARABLE is cross-scope.** Search and interpolation place an *external
  query* against my storage. That only works if the query, as-is, is directly
  comparable to my storage — which is a stronger claim than "I sort
  correctly."

The canonical example of why they must be separate is `CATime`:

> A `:s` (second-resolution) array is **ORDERABLE** — its int64 epochs sort
> correctly. But it is **not COMPARABLE**: a `:ns` (nanosecond) query compared
> raw against `:s` storage would be off by a factor of 10⁹. Folding the two
> flags into one would force time to choose between "cannot sort" and
> "silently mis-compares across units." Neither is acceptable, so the flags
> stay distinct.

A Face that *is* directly comparable (a frame-less, single-interpretation
integer relabel with no unit parameter) sets **both**.

---

## 3. `to_comparable` — the **reference** reconciles the operand

A unit Face is ORDERABLE but not COMPARABLE, yet we still want
`datetime_axis.bsearch(datetime_query)` to work. The escape is a template
method the Face class defines — and its **receiver is the reference**, not the
operand:

```ruby
# receiver = the reference (self/axis); argument = the operand (query/rhs)
reference.to_comparable(operand) # => operand brought into the reference's own
                                 #    representation, or raise if irreconcilable
```

`to_comparable` brings the operand **into the reference's own representation**
(e.g. converts a `:ns` operand to the axis's `:s` unit, or lifts a `Time` to a
length-1 time in the axis's unit). After that, comparing operand-storage
against reference-storage is a comparison between two values in *the
reference's* space — which is exactly what ORDERABLE already guarantees. So the
reconciled path needs only ORDERABLE; COMPARABLE is the flag for the
*un-reconciled* (direct) path.

Putting the conversion on the **reference** matters: the reference is always
one of our own Face classes, so it can `case` on the operand and accept a
foreign type — a `CATime::Element`, a Ruby `Time`, a Ruby `DateTime` —
**without monkey-patching that foreign class**. (A query-side receiver would
need `Time#to_comparable`, a core-class patch; refinements do not even reach
the C-level `rb_funcall` dispatch, so there is no clean opt-in that way.) The
cost is O(faces) — each Face owns one `to_comparable` — instead of
O(operands × faces). A new Face author writes one method and receives every
operand type its `case` chooses to accept; **coverage is per-Face** (time
accepts `Time`/`DateTime`; timedelta, being a duration, does not).

`to_comparable` is a semantic conversion (unit arithmetic), so it is a Ruby
method, not a flag. The split is deliberate:

- **"Is it safe to descend?"** → a C flag (a Face can be authored C-only).
- **"How do I reconcile an operand?"** → a Ruby method (unavoidably semantic).

---

## 4. The search flow (C dispatcher, not per-Face Ruby)

The whole point of the flags + `to_comparable` is that a Face needs **no
per-method Ruby override**. The dispatcher (in `emit_search_dispatch` and
`rb_ca_linear_section_m`) implements the decision generically:

```
reference (self):
    Face and not ORDERABLE          -> raise   (can't establish order)
    Face and ORDERABLE              -> strip to storage; remember COMPARABLE

operand (query / rhs), driven by the reference:
    reference COMPARABLE            -> strip a Face operand; take a plain
                                       operand as-is                 (direct)
    reference a non-COMPARABLE Face -> reference.to_comparable(operand), strip
                                       (ANY operand type: Face CArray, Element,
                                       Time, DateTime, ...; raises if the
                                       reference cannot reconcile it, or if it
                                       has no to_comparable at all)
    reference plain                 -> take the operand as-is
```

`to_comparable` is invoked from C via `rb_funcall(reference, "to_comparable",
1, operand)`. The dispatcher strips the reference to storage with
`rb_ca_strip_face_value`, so the switch on `data_type` and every
index/addr/position output are built on the plain numeric parent.

So a Face's *entire* contract to join the search family is:

1. set `CA_FLAG_FACE_ORDERABLE_STORAGE` (and `COMPARABLE` if directly
   comparable), and
2. if it is a unit Face, define `to_comparable(operand)`.

No `def bsearch` / `def search` / `def linear_section` on the Face class.

Note the corollary of the reference driving reconciliation: when the
**reference is plain** (a bare numeric array) and the **operand is a Face**,
there is no reference Face to reconcile it, so the operand is passed through
as-is and its fixlen surface simply fails to cast to the numeric storage
(a `CArray::DataTypeError`). Search a plain axis with `operand.parent`.

---

## 5. Plain queries and the storage boundary

A **bare-storage query** — an `Integer`, a non-Face numeric array — searched
against a non-COMPARABLE Face reference is a *direct comparison of the Face's
hidden storage*. Only COMPARABLE licenses direct external comparison, so a
non-COMPARABLE Face rejects it. What the reference *does* accept is whatever
its own `to_comparable` chooses to reconcile — for time that includes a
`Time` / `DateTime` / `Element` (each lifted into the axis's unit), because
those carry an absolute instant, not a raw storage integer:

```ruby
dt = CArray.time_series("2024-06-15", periods: 6, freq: :D)   # not COMPARABLE
dt.bsearch(19538)          # => raise (a bare int would touch the hidden epoch)
dt.bsearch(Time.utc(2024, 6, 17))  # => OK  (Time lifted into the axis unit)
dt.bsearch(other_datetime) # => OK  (Face operand, reconciled by to_comparable)

dt.parent.bsearch(19538)   # => OK  (explicit storage-space search)
```

The line the gate draws is: a **bare storage value** must not reach a Face's
hidden storage implicitly. The explicit escape is `.parent` — descend to
storage on purpose, and own the raw semantics. A `Time` is not a bare storage
value; it is an operand the time reference knows how to convert.

**The write direction draws the line differently, on purpose.** Storing raw
storage is a documented escape that predates the Face write hook, so `t[0] =
477338` and `t[0..1] = int64_array` both stay raw
(`PROPOSAL_FACE_WRITE_SCALAR.md` §7). The asymmetry follows from what the bare
number *is* in each direction: reading, it is a question the Face has to
interpret, and a silently wrong answer is unnoticeable; writing, it is data the
caller supplies, already declared to be in storage terms. What the write side
does insist on is that raw means raw **storage** — an integer-storage Face
takes integer cells only, so a bare float array is refused rather than
truncated by the storage cast (matching the scalar path, where `to_comparable`
refuses a `Float`). `t.parent[] = float_array` is where the caller owns the
cast.

`linear_fetch` is the exception that proves the rule: its argument is a
*fractional position index*, not a value compared against the axis, so it is
outside this gate and takes a plain index directly.

### 5.0 Equality rides ORDERABLE too

The value-hash family (`unique` / `value_counts` / `mode` / `is_in` / the set
operations / `categorize`) asks about **equality**, not order, and it keys on raw
cells — so it needs the same descent. ORDERABLE is the license it uses, because
order preservation implies what equality needs: *equal storage ⇔ equal surface*.

That implication is exactly what a non-ORDERABLE Face does not offer, and
`CAConstString` shows why the flag has to gate this. Its cells are
`(start, end)` byte ranges into a shared buffer, so two equal strings stored at
different offsets have **different storage** — descending would count them as
distinct.

A Face in that position answers for itself, and the two in-tree cases show the
two shapes that takes:

| Face | why the gate cannot serve it | how it answers |
|---|---|---|
| `CAConstString` | storage is a byte range, not the bytes | runs the family on `#to_string`, where a cell *is* the string, and rebuilds value outputs as a `CAConstString` |
| `CACategorical` | code order is the vocabulary's order, not the labels'; and a lifted code array would still be codes | keeps distinctness on the codes (a uint8 pass) and translates only the values crossing the surface, so the answers are labels |

Both are plain Ruby overrides next to the class's other surface methods
(`CAConstString#count` / `#sort`, `CACategorical#count` / `#category_sizes`)
— which is the pattern to follow for a new Face whose equality is not its
storage's. [`CAFace.md`](../topics/CAFace.md) §6.3 is the checklist form of
this: the three questions that pick your flags, the three ways a family goes
wrong when it has not been told about you, and what to assert to know you are
done.

### 5.1 Which half of the pair keeps the Face

`linear_section` and `linear_fetch` point in opposite directions, and the Face
follows the direction:

| | returns | Face on the result |
|---|---|---|
| `linear_section(value)` | a fractional **position** | no — a position is a plain index |
| `linear_fetch(index)` | a **value** off the axis | yes — re-lifted into the axis's own class and unit |

`CATime` / `CATimedelta` therefore override `linear_fetch` (in
`lib/carray/time.rb`) while leaving `linear_section` to the generic gate. The
override keeps `self`'s unit: the array's grid is the output grid, so an
interpolated instant landing between two ticks is rounded to the nearest one,
and callers who need sub-tick precision widen the grid first with `to_unit`.
An out-of-range address comes back as UNDEF rather than NaN, because int64
storage has no NaN to carry the sentinel.

Both halves read the same storage grid, which is what makes
`axis.linear_fetch(axis.linear_section(v))` return `v` even for a calendar
unit — there is no second interpolation space to choose between. A Face author
adding a unit Face inherits this by declaring ORDERABLE; only the re-lift
(one method) is per-Face work.

---

## 6. Making a Face participate

### 6.1 C-level Face

Set the flags in the setup function, next to `CA_FLAG_IS_FACE`:

```c
/* ORDERABLE only (unit-bearing): sort family, search via to_comparable */
ca->flags = CA_FLAG_IS_FACE | CA_FLAG_FACE_ORDERABLE_STORAGE;

/* ORDERABLE + COMPARABLE (directly comparable, no unit): sort AND direct search */
ca->flags = CA_FLAG_IS_FACE
          | CA_FLAG_FACE_ORDERABLE_STORAGE
          | CA_FLAG_FACE_COMPARABLE_STORAGE;
```

`CATime` / `CATimedelta` take the first form (see
`ext/ca_obj_time.c`, `ext/ca_obj_timedelta.c`) and define
`to_comparable` in `lib/carray/time.rb`.

### 6.2 CAObject (Ruby) Face

Pass the flags as keyword arguments to `super`; they wire straight to the C
flags (so a Ruby-authored Face still declares its safety without a callback):

```ruby
class Relabel < CAObject                 # single-interpretation int relabel
  def initialize(parent)
    super(CA_INT64, parent.dim, parent: parent, face: true,
          orderable_storage: true, comparable_storage: true)
  end
end

r = Relabel.new(CA_INT64([0, 2, 4, 6, 8, 10]))
r.sort_addr                    # => [0, 1, 2, 3, 4, 5]
r.bsearch(CA_INT64([4, 8]))    # => [2, 4]     (COMPARABLE: plain query OK)
r.linear_section(CA_INT64([1, 7]))  # => [0.5, 3.5]
```

Both kwargs are only meaningful with `face: true` (otherwise
`ArgumentError`). A unit-bearing Ruby Face sets `orderable_storage: true`
only and defines a `to_comparable(operand)` method (receiver = the reference;
it `case`s on the operand it is willing to accept).

### 6.3 Non-numeric storage

No separate "float-orderable" flag is needed for `linear_section`. It casts
the storage to `float64` in `ca_linear_prep`; a Face whose storage is not
numeric (e.g. a fixlen-string Face) is rejected by that cast automatically.
ORDERABLE plus the cast is sufficient.

---

## 7. Summary

| your Face is… | flags | `to_comparable(operand)` | sort family | search / linear |
|---|---|---|---|---|
| unit-bearing (time, timedelta) | ORDERABLE | define it (reference reconciles the operand) | ✓ | ✓ via reconcile; bare storage value → raise |
| single-interpretation relabel | ORDERABLE + COMPARABLE | not needed | ✓ | ✓ direct; plain query OK |
| fixlen storage (record, fixed-width string) | none | — | ✓ by **memcmp** (default) | reject (numeric-only) |
| non-orderable numeric storage | none | — | reject | reject |

**Sort-family Face gate.** The sort family descends any Face to its storage and
then relies on the storage's `data_type`:

- **fixlen storage → memcmp**, the default order for fixlen (the same order a
  plain fixlen array sorts by). A fixed-width string Face sorts correctly; a
  struct/record Face gets a deterministic *byte* order (arbitrary across fields,
  but a valid total order). No flag is needed — memcmp is the default, never
  something you have to opt into. (A future `CA_FLAG_FACE_ORDER_AS_OBJECT` will
  let a Face opt *out* of memcmp and order by its scalar `<=>` instead.)
- **numeric storage → requires ORDERABLE**, so the numeric order equals the
  surface order. A non-orderable numeric Face raises (numeric-sorting it would
  reorder the surface silently).

`search` / `linear` stay numeric-only for now: they need a comparable/
interpolatable numeric coordinate, so a fixlen Face is still rejected there.

The reject remains the last line of defence for the cases that have no defined
order: a non-orderable numeric Face still raises, so nothing silently
mis-compares.

---

## 8. See also

- [`CAFace.md`](../topics/CAFace.md) — the Face substrate (structure, lift, authoring).
- [`CATime.md`](../topics/CATime.md) §10 — the user-facing view of these
  capabilities on the built-in time Faces.
- [`LinearInterpolation.md`](../topics/LinearInterpolation.md) — `linear_section` /
  `linear_fetch` / `locate_*` semantics on plain arrays.
