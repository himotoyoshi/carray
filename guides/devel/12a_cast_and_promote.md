# 12a — Cast and promote: the canonical routes

Every non-trivial method in CArray sooner or later has to do one of two
things: **take a value of some other type and use it as an operand**, or
**bring two or more arrays to a common dtype so a kernel can read them
uniformly.** The rules for both are already single-source — CArray has
one cast table, one promotion function, one classifier, and one binop
coercion helper. What drifts is not the rules but **the call-site
wiring**: an author, faced with "I need a float here", invents a bespoke
one-line coerce on the spot, and over time those one-liners disagree in
subtle ways (which operand gets dropped, whether an MV producer is
recognised, whether NaN survives, whether -0.0 folds).

The discipline is therefore not "know the rules" (they are already
uniform) but **route through the existing canonical paths**. This chapter
lays them out, shows the ground-truth primitives they sit on, and pins
the anti-pattern that keeps re-appearing.

## 12a.1 The rules already live on a single source

The one place the *promotion policy* is defined:

```
ext/carray_core.c:  ca_cast_table  [17][17]     /* ARRAY -> ARRAY  */
                    ca_cast_table2 [17][17]     /* SCALAR -> ARRAY */
```

Two `int8_t` matrices indexed by data_type code:

```
test = ca_cast_table[a][b]
  1  →  cast a to b
  0  →  a already fits b
 -1  →  a cannot be cast to b (try the other direction)
```

The matrices are **upper-triangular by dtype width and hierarchy**
(`bool < integers < floats < complex < object`; unsigned/signed step in
order), and every legal `1` in the ARRAY table is a widening cast (int8
→ int16, int32 → float64, float64 → complex128, anything → object).
The scalar table is nearly identical but slightly more permissive for
signed/unsigned corners (a scalar int8 can meet an unsigned array of the
same width without a loud reject).

The one function that folds this into "give me the common type":

```c
int8_t ca_promote_type (int8_t a, int8_t b);   /* ext/carray_cast.c */
```

Pairwise: if `a == b` return `a`; else consult the table in both
directions and return whichever side survives; else raise with the two
type names. **The lazy view layer's `CABinOp` constructor uses the same
function** to decide its output_data_type, so eager `a * b` and lazy
`a.lazy * b.lazy` cannot disagree about promotion — the discipline is
enforced by shared code, not by convention.

The one classifier that turns "an argument" into "a dtype":

```c
int8_t ca_arg_to_data_type (VALUE obj);        /* ext/carray_cast.c */
```

- a **CArray** → its `data_type`;
- a **Symbol / String / Class** naming a dtype → the code;
- a **Numeric / bool / nil / arbitrary Object** → the dtype inferred
  from the value (`Fixnum`→int64, `Float`→float64, `true`/`false`→bool,
  `Complex`→complex128, anything else → object);
- an **MV producer** → the dtype derived from `view.format` via
  `ca_mv_probe_data_type` (see §12a.4).

Everything on top — `CArray.result_type`, `CArray.promote_list`,
`rb_ca_wrap_readonly`, the binop coerce — is built on this trio. A new
helper that reinvents any of them is a drift vector.

## 12a.2 The five canonical routes

| Situation | Route | Primitive it calls |
|---|---|---|
| Accept a non-CArray operand at a **fixed** dtype | `rb_ca_wrap_readonly(v, INT2NUM(dt))` / `wrap_writable` | wraps into a CScalar / cast view |
| Bring **two negotiable operands** to a common type | `CArray.result_type(a, b)` → `to_type(t)` on each | `ca_promote_type` |
| The binary op **`a op b`** | do nothing — write `a * b` | `rb_ca_cast_self_or_other` |
| Make **N arrays** share one dtype | `CArray.promote_list(list)` | folds `ca_promote_type` |
| Just **decide** the N-ary common dtype | `CArray.result_type(*args)` | same |

Each row exists because the caller intent is genuinely different, and
each has a canonical spelling. They are not five spellings of one
concept; they are five different concepts sharing one *substrate*.

### `wrap_readonly` / `wrap_writable` — the type-coercion intake

`rb_ca_wrap_readonly(v, INT2NUM(dt))` is the **canonical way to accept a
non-CArray as a typed operand**. It converts

- `Numeric` → CScalar of dtype `dt`;
- `Array` / `Range` → CArray of dtype `dt`;
- `String` (fixlen), `nil`, `obj` responding to `.to_ca` → the appropriate
  wrapping;
- an **MV producer** → import via `wrap_memory_view` and adapt to `dt`;
- a CArray of dtype `dt` → **pass-through** (no CAFake, no allocation);
- a CArray of a different dtype → CAFake cast view at zero cost.

The pass-through property is what makes `wrap_readonly` cheap to use as
a defensive coerce at kernel entry: on the common path (the operand is
already the right dtype) it returns the same object.

`wrap_writable` is the mirror image for a **destination** you write back
to (its result must be a CArray whose store commits to the caller, so
it rejects a CScalar coerce). For a foreign object it asks
`obj.to_ca(writable: true)`, which is the `to_ca` contract's way of
demanding a result whose writes reach the source; an implementation that
can only return a copy raises rather than swallowing the writes.

The `dt` argument is a **fixed target**. Using a fixed target is correct
only in one of two situations:

- the kernel *structurally requires* that type (f64 for a transcendental
  function, `CA_SIZE` for indices, `CA_BOOLEAN` for masks), or
- the target was already settled elsewhere by `result_type` (i.e. you
  are wrapping *after* the negotiation).

Passing `otherArray.data_type` as `dt` when the operand is negotiable is
the anti-pattern of §12a.5.

### `CArray.result_type` — negotiation between negotiable operands

```ruby
t = CArray.result_type(self, ref)
a = (self.data_type == t) ? self : self.to_type(t)
b = (ref.data_type  == t) ? ref  : ref.to_type(t)
```

`result_type` accepts any mix of CArrays, dtype names (Symbol / String /
Class), Numeric literals, and MV producers, classifies each via
`ca_arg_to_data_type`, and folds pairwise through `ca_promote_type`.
Returned as a Symbol; caller compares to each operand's `data_type` and
calls `to_type` only where a change is needed (the guard avoids
allocating a copy for the arm already at the common type).

Writing this two-line `result_type` → `to_type` in three places in the
codebase is not duplication — it is **the canonical route spelled out
in the open**. Folding it into a private `coerce_negotiable` helper
buries the intent and starts the drift.

### Binop coercion — do nothing when a `*` is next

If the very next thing after your coerce is `a * b` (or `+`, `-`, `/`,
`<`, `==`, …), **write it directly**. `rb_ca_cast_self_or_other`
(`ext/carray_cast.c:1245`) is the binop's built-in coercer: it inspects
`ca_cast_table` / `ca_cast_table2` between the two sides, picks the
common type, and materialises the widened operand exactly where the
kernel receives it. Doing your own coerce beforehand is a strict pessimisation
and a correctness trap — the anti-pattern coerces one side to the
peer's dtype and truncates.

### `promote_list` — homogenise N arrays

`CArray.promote_list(list)` folds `ca_arg_to_data_type` across the list,
then rewrites each entry to the common type — the exact operation
`CAStack.new` and Face-preserving stack construction perform to build a
uniform-dtype pile. If you find yourself hand-rolling
`arrays.map(&:data_type).reduce(...)` followed by a `.each { |a|
a.to_type(...) }`, that is `promote_list` spelt out.

### `ca_promote_type` and `result_type` — decide-only

Sometimes you need only the common dtype (to allocate an output, to
choose a kernel branch) without actually promoting anything.
`result_type` at the Ruby side, `ca_promote_type` at the C side. Cheap:
one or two table lookups; no allocation.

## 12a.3 Decision flow

1. Does the operand come from outside CArray (Numeric / Array / String /
   nil / MV)? → **`wrap_readonly`** (with `dt` decided by step 2 or 3).
2. Is the target **structurally required** by the kernel (f64 /
   `CA_SIZE` / `CA_BOOLEAN`)? → hard-code the dtype in `wrap_readonly`.
3. Is the target **a negotiation with a peer array**? → settle it with
   `result_type`. **Never** write `X.to_type(peer.data_type)`.
4. Is `a op b` the very next thing? → do nothing; **delegate to binop**.
5. Are you homogenising N arrays? → **`promote_list`**.

Steps 2 and 3 are the crux: the same wrapper call (`wrap_readonly(v,
dt)`) is right when `dt` is a hard requirement and wrong when `dt` is a
peer's dtype in disguise. The tell is *whether you can name the type
without referring to another array*: `CA_FLOAT64` you can name;
`peer.data_type` you cannot.

## 12a.4 MemoryView producers as operands

An MV producer (Numo + `numo/narray/memoryview`, Arrow, a
`pycall-memoryview` wrapped NumPy array, …) is accepted at all three
intake points, and the dtype derivation is single-sourced:

| Entry point | How the MV is handled |
|---|---|
| `a * mv` (binop coerce) | `rb_ca_cast_self_or_other` runs `wrap_memory_view` before classifying, so the MV becomes a CAWrap and the normal cast_table logic takes over. |
| `wrap_readonly(mv, dt)` | detects the MV producer, imports it, adapts to `dt` (import strategy — copy vs zero-copy — is inside `wrap_memory_view` / `from_memory_view`). |
| `result_type(a, mv)` / `promote_list(list_with_mv)` | `ca_arg_to_data_type` calls `ca_mv_probe_data_type`, which **fetches the MV, parses `view.format`, releases the MV without importing**. Dtype known; no data moved. |

The **format-parse is the single source of "what dtype is this MV?"**:
`ca_mv_data_type_from_format(format, item_size)` in
`ext/carray_memory_view.c`. Both routes — the classifier that only wants
a dtype, and the wrapper that also wants the bytes — go through it.
This is what "canonical" means here: not that they share a helper
function name, but that they share the one *decision point* about MV
dtype. A second helper that also parses formats and calls it "just for
result_type" would be immediate drift.

`ca_mv_probe_data_type` deliberately does **not** import the bytes.
Building a zero-copy view with `wrap_memory_view` "just to learn the
dtype" would drag in the import strategy (readonly/writable, copy
vs alias) and re-couple concerns the split holds apart. If you need only
the dtype, probe; if you need the bytes, wrap or from — never wrap to
probe.

## 12a.5 The recurring anti-pattern: one-sided `X.to_type(other.data_type)`

Dropping a **negotiable operand** to the peer array's dtype is a
truncation bug in waiting:

```ruby
# BAD: kernel is Float, source is Int -> kernel truncates to 0
prod = source * kernel.to_type(source.data_type)

# GOOD: let binop promote (Int × Float → Float)
prod = source * kernel
```

```ruby
# BAD: query 1.5 truncated to 1 against an Int ref, then mis-matched
q = query.to_type(ref.data_type)
hit = ref.eq(q)

# GOOD: negotiate to a common type
t = CArray.result_type(query, ref)
q = query.data_type == t ? query : query.to_type(t)
r = ref.data_type   == t ? ref   : ref.to_type(t)
hit = r.eq(q)
```

**The tell**: the target you drop to is `something.data_type`. If the
target is a fixed type the kernel structurally requires — `CA_FLOAT64`
for `sqrt`, `CA_SIZE` for an index, `CA_BOOLEAN` for a mask — the
coerce is legitimate and `wrap_readonly(v, CA_FLOAT64)` is the correct
spelling. If the target is "match the peer", the coerce is negotiation
in disguise and belongs to `result_type`.

Two grounded fix histories illustrate the trap:

- `correlate` in `lib/carray/window_iterator.rb` used to force the
  kernel to the source dtype (`kernel.to_type(sv.data_type)`), so an
  int source silently truncated a float kernel to zero. The fix: drop
  the coerce and let binop promote.
- `locate_addr` in `lib/carray/methods/locate_addr.rb` used to coerce
  `self` to `ref.data_type` (`query.to_type(ref.data_type)`), so a
  fractional query against an int ref truncated and mis-hit. The fix:
  route through `CArray.result_type`.

Both were once-line "obviously right" coerces that had been drifting
for a while before the truncation became visible. The lesson recorded
in the discipline is not "watch for these two methods" but **"suspect
every `X.to_type(other.data_type)` and audit whether the target is
structural or negotiated"**.

## 12a.6 Weight promotion in weighted reductions

Weighted reductions (`wsum` / `wmean`) illustrate why the anti-pattern
also shows up in **core kernels**, not just Ruby wrappers.

Before the 2026-07-08 fix, the array_arg of the core `wsum` / `wmean`
kernels wrapped weights at a fixed `src->data_type` (`:match_source` in
the mkkernel DSL). Consequence: an int source with float weights
truncated the weights to 0 at kernel intake, so `wmean` returned `NaN`
even though the caller had provided perfectly good float weights. Worse,
the core kernel is the *delegation target* for the wsum / wmean of the
window / block / slab / categorical iterators — every family member
inherited the truncation, and stripping the offending `.to_type` on the
Ruby side did nothing because the core re-truncated.

The fix, encoded in `ext/mkkernel.rb`, was **array_arg `data_type:
:promote`**: materialise the weights at the **f64 computation type**,
regardless of source dtype. This split the C type of the weight cell
the reduce body reads (the `T_W` parameter of the emitted
`CA_SLAB_REDUCE_ARRAY_T_EX`) from the source cell type `T`. The reduce
body is `(double) v * (double) w`; f64 storage for the weights is
exactly equivalent to "read the native weight and cast to double" for
every combination of source/weight dtypes, with no truncation and no
precision surprise. Integer weights keep their integer values (widened
losslessly to double); float weights are not truncated.

The generalisation for a kernel author writing a new array_arg:
**decide whether the argument's C storage type is a knob or a
consequence.** If the reduce body reads it as `double` regardless
(computation-typed), `:promote` is right. If the reduce body needs the
native cell type (e.g. an index passed to `ca_ptr_at_addr`), match a
concrete type. The trap is defaulting to `:match_source` for a
computation-typed argument because "it seemed the least surprising" —
that is exactly the peer-dtype anti-pattern reincarnated in the DSL.

## 12a.7 Do not add a new coerce helper

If the intent is expressed by one of the five routes, **do not wrap
them**. Call the CArray primitive directly. Writing
`result_type` → `to_type` in the two or three places that need it is
not duplication — it is the canonical route spelt out in the open, and
the standard vocabulary reads better at the call site than a private
`negotiate_dtype` in a util module. A helper is justified only when it
adds **genuine semantic value**:

- a **domain concept** (a Face-specific promotion policy that resolves
  Face state alongside dtype; a mask policy that ties value promotion
  to mask reconciliation);
- a **policy** with side effects (an entry helper for a callable-f
  routine that combines validation, coerce, and error-message shape).

"Type-safe wrapper", "shorter to write", "reads more nicely" are not
semantic value. They are the drift vector this chapter exists to
prevent.

## 12a.8 Where the pieces live

```
ext/carray_core.c
  ca_cast_table          ARRAY -> ARRAY promotion policy
  ca_cast_table2         SCALAR -> ARRAY promotion policy

ext/carray_cast.c
  ca_promote_type        pairwise fold of the tables
  ca_arg_to_data_type    classifier: CArray / Symbol / Numeric / MV -> dtype
  rb_ca_cast_self_or_other  binop coercer
  rb_ca_s_result_type    Ruby entry: CArray.result_type(*args)
  rb_ca_s_promote_list   Ruby entry: CArray.promote_list(list)

ext/carray_memory_view.c
  ca_mv_data_type_from_format   format string -> dtype
  ca_mv_probe_data_type         fetch view, parse format, release (no import)

Ruby wrappers using them
  lib/carray/methods/locate_addr.rb     result_type -> to_type
  lib/carray/methods/is_in.rb           promote_value_set (result_type inside)
  lib/carray/window_iterator.rb         binop coercion (correlate/convolve)
  ext/mkkernel.rb                       array_arg data_type: :match_source | :promote
```

A working note pinned in `ca_promote_type`'s docstring records the audit
trail confirming there is exactly one policy source; when adding a new
type or dtype relationship, that audit is the place to update.
