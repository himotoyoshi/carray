# 16b — The `fz_hash` discovery engine

A whole family of Ruby-side methods — `unique`, `value_counts`, `nunique`,
`mask_duplicates`, `categorize`, `is_in`, the set operations
(`intersection` / `difference` / `union`), `is_mode`, `mode` — all read
different answers out of the *same* one-pass value-seen-set. That shared
substrate lives in `ext/carray_factorize.c` and is named after its central
struct, `fz_hash`. This chapter explains what the substrate is, how the
lanes work, which invariants the kernels rely on, and how a new
discovery-shaped kernel plugs in.

Two design points frame everything else:

1. **One intern pass, many answers.** Each member of the family is a
   different projection of the same open-addressing intern loop —
   `first-appearance code`, `first-seen flag`, `count`, `presence`, and so
   on. Adding another discovery kernel means picking a projection, not
   writing a new hash.
2. **Value-based distinctness with two per-lane exceptions.** The numeric
   lane collapses all NaN and treats `-0.0 == +0.0`; the object lane
   reproduces Ruby `hash` / `eql?` with one deviation (Float NaN also
   collapses). Every family member inherits this contract identically —
   which is what makes it correct to say "these methods share a
   distinctness rule" rather than each maintaining its own.

## 16b.1 The substrate

### `fz_hash` — open-addressing intern by widened 64-bit key

```c
typedef struct {
  uint64_t *key;
  int32_t  *code;
  uint8_t  *used;
  VALUE    *val;    /* object lane only — for the eql? re-check */
  char     *raw;    /* fixlen lane only — for the memcmp re-check */
  int       esz;    /* fixlen element size (0 otherwise) */
  ca_size_t cap;    /* power of two */
  ca_size_t n;      /* distinct keys interned so far */
  int       shift;  /* 64 - log2(cap); the home slot is the top log2(cap) bits */
} fz_hash;
```

Open-addressing with linear probing over a power-of-two capacity;
load-factor 0.7 triggers `fz_hash_grow` (double the capacity, rehash into
the new table, free the old). The home slot is the *top* `log2(cap)` bits
of the key — `slot = key >> shift`. Using the high bits rather than a
low-bits modulo is what lets the numeric lane feed the hash a *raw widened
value* as the key: consecutive integers (or bitwise-consecutive floats)
land in different home slots because they differ in their high bits after
the shift. No mixing function, no per-insert multiply — the widening step
itself is the whole "hash" of the numeric lane.

The three key lanes:

- **numeric lane** — `fz_hash_init(&h)`. The key *is* the value,
  sign-/zero-extended into 64 bits: for integers,
  `key = (uint64_t)(int64_t)v` (sign-extend for signed types, zero-extend
  for unsigned); for floats, `key = bit_cast<uint64_t>(v)` with the two
  value-based fix-ups below. Since the widening is lossless within a
  dtype, a key match *proves* value equality — no re-check is stored, and
  `val` / `raw` stay `NULL`.
- **object lane** — `fz_hash_init_obj(&h)`. `key = NUM2ULL(rb_hash(v))`,
  with the interned `VALUE` stored beside it. A slot collision (same key,
  different value) falls through to an `rb_eql` re-check. This is
  literally Ruby Hash's rule.
- **fixlen lane** — `fz_hash_init_mem(&h, esz)`. `key = fz_bytehash(bytes,
  esz)` (FNV-1a over the `esz` bytes — a *lossy* hash), with the interned
  bytes stored beside it. Collisions fall through to `memcmp`. This
  reproduces Ruby `String#eql?` for the uniform-width binary cells the
  fixlen family uses.

The `val` array is not separately GC-marked. Its `VALUE`s are elements of
the live receiver, so the GC reaches them through `self` — a subtle but
load-bearing property of the kernels always running under the receiver's
lifetime, and something to preserve if the substrate ever grows a variant
that outlives a single call.

### Numeric lane fix-ups (must match everywhere)

Two value-based exceptions distinguish this contract from a naive bit-cast:

- **All NaN collapse to one distinct value.** Every NaN, regardless of
  sign or payload, takes a fixed canonical key
  (`0x7FF8000000000000ULL`). So the second NaN in an input is a duplicate,
  `nunique` counts NaN as one, and `is_in` finds NaN in a set that has
  any NaN.
- **`-0.0` and `+0.0` share a key.** `-0.0` is normalised to `+0.0` before
  the bit cast (`v == 0.0 ? +0.0 : v` — the `==` catches both signed
  zeros).

The object lane additionally collapses every Float NaN to the same
canonical key (its numeric-lane counterpart), *deviating* from Ruby Hash
(which keeps distinct NaN objects apart). This is a deliberate
alignment: it is the one place where `CA_OBJECT` distinctness matches the
numeric family instead of matching Ruby.

If you ever add a new numeric-key path (e.g. a wider integer type, or a
different float format), replicate both fix-ups verbatim — otherwise the
family members silently disagree with each other about what a distinct
value is.

### `fz_levels` — the appearance-ordered append buffer

```c
typedef struct { char *p; int esz; ca_size_t n, cap; } fz_levels;
```

A push-only byte buffer sized in `esz`-byte elements. Every kernel that
needs to *emit* the interned values (not just count them) pushes the raw
element whenever `fz_hash_intern` reports `is_new = 1`. Because the intern
loop walks the input in row-major flatten order and only pushes on first
sight, the buffer holds the distinct values in **first-appearance
order** — the family's canonical order, deviating from Ruby `Array#uniq`
in *what counts as equal* (NaN collapse) but matching it in *what order
they appear*.

For a count-only kernel (`nunique`), `fz_levels` is not used at all; the
answer is `h.n`.

### Per-fiber reset

`fz_hash_reset` zeros `used` while keeping the allocated `key` / `code`
capacity, and `fz_levels_free` + re-init recycles the level buffer. The
per-axis kernels (`__mask_duplicates__(axis)`, `__nunique__(axis, ...)`,
`__is_mode__(axis)`, `__mode_axis__(axis)`) reuse the tables across
fibers rather than reallocating — the fiber loop is the hot path, and
allocation amortisation matters.

## 16b.2 The projections — one loop, many answers

Every kernel drives `fz_hash_intern` through the fiber surface
(`ca_iter_state` on the innermost axis; kernels that need a whole-array
seen-set flatten first and iterate over axis 0). What differs is which
side effect they record.

| kernel | side effect per element | output |
|---|---|---|
| `__factorize_appearance__` (categorize) | write `code` into a uint32 scratch; push level on `is_new` | `[narrow-codes CArray, levels CArray]` |
| `__mask_duplicates__(axis)` | write `!is_new` into a boolean output | boolean CArray, source shape |
| `__unique_flat__` | push level on `is_new` | 1-D CArray of levels |
| `__value_counts_flat__` | push level on `is_new`; `++counts[code]` | `[levels, counts]` (`counts` = 1-D int64) |
| `__nunique__(axis, keep_axis)` | none — `h.n` is the answer | reduced int64 CArray |
| `__is_mode__(axis)` | per-fiber two-pass frequency table; mark cells hitting the max | boolean CArray, source shape |
| `__mode_axis__(axis)` | frequency table → distinct modal values, ascending, per fiber | ragged `Array<CArray>` (slot `j` = each fiber's `j`-th smallest mode) |
| `__is_in__(values)` | phase 1: build the seen-set from `values`; phase 2: probe every self cell | boolean CArray, source shape |
| `__intersection__` / `__difference__` / `__union__` | phase 1: seen-set from one side; phase 2: emit levels present/absent/either | 1-D CArray |
| `__locate_addr__(ref)` | build seen-set from `ref` (position beside each key); probe self, emit index | int64 CArray, source shape |

The `factorize` kernel is the archetype — it exposes both projections
(codes *and* levels) in one pass. Every other kernel is a specialisation
that drops one of them or replaces it with a different accumulator
(counts, first-seen flag, presence bit, per-fiber max-count marking).

### `is_in` and the set operations — two-phase intern-then-probe

`is_in`, the set operations, and `locate_addr` all use a second primitive
alongside `intern`: `fz_hash_lookup` (three lanes, matching `intern`),
which returns the code for a key without inserting. So they run as:

1. **Phase 1 — build the seen-set** from the *set* side (the `values`
   argument for `is_in`, `other` for the set ops). Each new value is
   interned; masked cells do not enter the set.
2. **Phase 2 — probe** every cell of `self` with the lookup. The kernel
   writes a boolean (`is_in`), or accumulates into an output array of
   levels (`intersection` / `difference`), or writes back a source index
   (`locate_addr`).

`self`'s mask propagates into the output on the probe pass — a masked
self cell has unknown membership, so `is_in` masks it, matching how any
element-wise comparison would treat that cell.

### `is_mode` / `mode_axis` — the frequency-table branch

`is_mode` needs a per-fiber count, not just a first-seen flag, so it
piggybacks a small `fz_levels` of `int64` counts on the hash: `code` is
the index into `counts[]`, `++counts[code]` on every seen key. Ties are
kept — every cell whose count equals the fiber's max is marked, never
broken. `mode_axis` reads out the same table to emit the modal values
themselves, ascending, as a ragged `Array<CArray>` (slot `j` = each
fiber's `j`-th smallest mode, UNDEF where a fiber has fewer than `j+1`
modes). That ragged shape is deliberate — it matches the
`quantile` contract for per-axis order statistics, so consumers already
know how to stack it into a rectangle with `CArray.stack`.

## 16b.3 The `factorize` archetype and why `categorize` uses it

`categorize` (the CACategorical constructor) is the family member that
needs *both* codes and levels: the categorical stores the codes and a
label vocabulary. Before the substrate, that meant a two-step Ruby path
(discover levels; then one full `eq` scan per distinct value to assign
codes — `O(k · N)`, quadratic in the vocabulary size). The `factorize`
kernel folds both into one pass:

```
codes, levels = self.__factorize_appearance__
```

`codes` is a *narrow-unsigned* CArray (uint8 / uint16 / uint32 depending
on `k`), with the top value of that width (`0xFF` / `0xFFFF` / `0xFFFFFFFF`)
reserved as the **exclusion sentinel** — the same sentinel `mask_duplicates`
uses when its input is masked. `CACategorical.from_codes` derives the
mask by testing against the sentinel, so mask handling is uniform across
the discovery family. Explicit-labels and `sort_labels: true` fall back
to the discovery-then-scatter path in Ruby (`mask_duplicates[:is_not_masked].to_a`),
because they either reorder the codes (breaking factorize's
appearance-order alignment) or supply the vocabulary externally.

## 16b.4 The kernel_iterator layering

Every fz_hash kernel drives the fiber loop through the standard
kernel-iterator state machine rather than reaching for `ca_attach`:

```c
ca_iter_state st_in, st_out;
int8_t axis = (int8_t)(ca->ndim - 1);   /* innermost fiber */

CA_FOR_EACH_FIBER_INOUT(st_in, st_out, ca, out, axis, ...)
{
  /* p_in points at the fiber, p_out at its output fiber,
     m at the fiber's mask (or NULL) */
  ...
}
```

This is the recommended layering — the substrate is *policy* (what
counts as equal, how appearance order is defined), and the fiber
iteration is the standard "deliver a strided fiber" mechanism from
ch. 11. Kernels that need a whole-array seen-set (`__unique_flat__`,
`__value_counts_flat__`, `__intersection__`) simply do **not** reset the
hash between fibers, and flatten their input first so there is a single
outer fiber. Kernels that need a per-fiber seen-set (`__mask_duplicates__`,
`__nunique__`, `__is_mode__`, `__mode_axis__`) call `fz_hash_reset` at
the top of each fiber. That flag — reset or not — is the entire
"axis kwarg" of the family, expressed as a hash-lifecycle choice
rather than a kernel-parameter dispatch.

## 16b.5 The Ruby-side wrappers

The wrappers in `lib/carray/methods/*.rb` and
`lib/carray/categorical.rb` are thin. Their job is:

- **Dtype promotion at the boundary.** `is_in(values)` runs
  `promote_value_set(values)` to promote `self` and `values` to a common
  dtype via `CArray.result_type` (the same rule binops use), so cross-dtype
  membership is value-correct — an int cell equals a float set element of
  the same value, and a fractional set element never truncates onto an int
  cell. This is the general "cast / promote is a single source" rule
  applied at the discovery boundary.
- **Flatten-first for the whole-array case.** `axis: nil` is expressed by
  `self.flatten.__mask_duplicates__(0).reshape(*shape)` — one seen-set
  over the whole array, restored to source shape. Adding a whole-array
  form of a new discovery kernel is usually just this recipe.
- **Mask contract.** Masked source cells stay masked in the output;
  masked set/reference cells do not enter the seen-set. Both are enforced
  in the C kernel (the fiber-loop checks `m && m[i]`) and documented in
  the wrapper.
- **Boolean routing.** Boolean rides the uint8 numeric lane (its storage
  is uint8 0/1, so at most two distinct keys ever intern) — every wrapper
  accepts booleans without a special case.

`contains` was retired in favour of `is_in` because "contains" carried the
wrong distinctness (element-wise `==` semantics, no NaN collapse) — the
value-hash contract is the one users want, and giving it its own name
avoided quietly changing an existing method's meaning.

## 16b.6 Adding a new discovery kernel

The recipe:

1. **Pick the projection.** Do you need `is_new` (mask_duplicates),
   `code` (factorize), the level (unique), a count keyed by code
   (value_counts, is_mode), just `h.n` (nunique), or a two-phase probe
   (is_in, locate_addr)?
2. **Copy an existing kernel with the closest projection.** Rewire the
   per-element side effect; do **not** rewrite the intern loop, the
   lane switches, or the NaN / signed-zero fix-ups. Uniformity of the
   distinctness contract is the family's central invariant, and it is
   preserved by copying, not by reasoning about it.
3. **Choose per-fiber vs whole-array.** Reset the hash at the top of
   each fiber (per-axis form) or not (whole-array form, driven from
   Ruby by flattening). Kernels that offer both usually expose only the
   per-axis form in C and let the Ruby wrapper flatten for `axis: nil`.
4. **Wire the Ruby wrapper.** Autoload it from `autoload_carray.rb`,
   promote dtypes with `result_type` at the boundary if the kernel
   takes a second CArray, and document the mask contract on the
   docstring.
5. **Pin the numeric fix-ups by test.** At minimum: a NaN-collapse test,
   a `-0.0`/`+0.0` collapse test, an object-lane NaN-collapse test, and
   a fixlen-lane byte-equality test. The whole family shares one
   distinctness rule; every new kernel must be tested against it
   independently, because the rule is enforced by convention (each
   kernel doing the same thing) rather than by a single choke point.

A dedicated non-`fz_hash` kernel is justified only when the projection
cannot be expressed as "walk the fiber, intern, record" — for example,
when the answer depends on *ordering* the values rather than *seeing*
them (median, quantile), or when a sort-based algorithm is already
optimal and the seen-set would give no additional information. Everything
that *is* an intern-shaped question belongs on `fz_hash`; the whole point
of the substrate is that the family's distinctness contract is defined
once and reused, rather than re-implemented per method and drifting.
