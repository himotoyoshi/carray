# MemoryView Format String Convention

> **SUPERSEDED (2026-06-29).** This document captures the v1.0/v1.1/v1.2
> co-authored ratification trail (CArray + numo-narray-memoryview +
> bulk-memory-view).  CArray's current MV format contract is
> documented in [MemoryViewFormat.md](MemoryViewFormat.md); the
> producer top-level table flipped from Ruby pack-template synonyms
> (`c`/`C`/`s`/`S`/`l`/`L`) to PEP 3118 strict (`b`/`B`/`h`/`H`/`i`/`I`)
> on 2026-06-29.
> Consumer-side synonyms preserve interop with v1.x-emission producers.
> This file is preserved as the historical record of the v1.x phase.

Status: **v1.2** (2026-05-21)
Co-authors: Ruby/CArray, numo-narray-memoryview, bulk-memory-view
Supersedes: v1.1 (2026-05-21), v1.0 (2026-05-13); both archived in
§7 changelog
Audience: Library authors implementing `rb_memory_view_t` producers or
consumers in Ruby 3.0+.

---

## 0. Authority and design source

Ruby's `rb_memory_view_t` protocol was **designed by Mamoru Kanda
(mrkn) in 2020 as a Ruby port of Python's PEP 3118 (Buffer Protocol)**,
in response to Ruby Feature requests [#13767] and [#14722] for a
cross-library zero-copy data exchange mechanism. The designer is also
the author of PyCall, the Python-Ruby bridge, and the protocol's
implicit goal is to enable handshake with NumPy and Arrow buffers
without per-element conversion.

See: "Ruby 3.0 で導入された MemoryView について" [On the MemoryView introduced
in Ruby 3.0] (mrkn, Speee Tech Blog, 2020-12-24,
https://tech.speee.jp/entry/2020/12/24/093131)

Consequently, the canonical authority for MV format strings is:

1. **PEP 3118** (Python Buffer Protocol) — the protocol design source.
   This is the authoritative reference for symbol semantics.
2. **Ruby's `rb_memory_view_parse_item_format`** — the in-tree C parser,
   which implements PEP 3118 dialect (including `Z` for complex and `?`
   for bool). A producer whose format string passes this parser without
   re-interpretation is well-formed.
3. **Ruby's pack template** — *not* authoritative for MV. The overlap
   between pack symbols and PEP 3118 symbols is convenient for in-Ruby
   consumers but does not make pack the source of truth. Where pack and
   PEP 3118 diverge (e.g. pack `h`/`H` denote hex/bit strings, PEP 3118
   `h`/`H` denote short int / unsigned short), **PEP 3118 wins**.

This authority order resolves the open questions left in v1.0 §5.2
(complex) and motivates the changes in §2 and §3.2 below.

[#13767]: https://bugs.ruby-lang.org/issues/13767
[#14722]: https://bugs.ruby-lang.org/issues/14722

---

## 1. Design principles

Inherited unchanged from v1.0:

- **1.1 Postel's law**: producers conservative, consumers liberal.
- **1.2 `item_size` is authoritative**: format carries the semantic
  type, `item_size` carries the byte width, consumers MUST cross-check.
- **1.3 Host byte order is the default**: cross-endian still deferred
  (see v1.0 §5.1; unchanged in v1.1).
- **1.4 No alignment padding**: `|` is stripped on consumer side, MUST
  NOT be emitted by producer.

New in v1.1:

- **1.5 PEP 3118 first**: when choosing between equivalent symbols for
  the same dtype, prefer the PEP 3118 form. Producer canonical entries
  in §2 follow this rule.

---

## 2. Canonical generation table (producer side)

A conforming producer MUST emit exactly one of these for each
supported dtype. The producer MUST set `item_size` to the byte count
shown.

| dtype | canonical `format` | `item_size` | note |
|---|---|---|---|
| bool | `"?"` | 1 | **changed in v1.1**; was `"C"` in v1.0 |
| int8 | `"c"` | 1 | |
| uint8 | `"C"` | 1 | |
| int16 | `"s"` | 2 | |
| uint16 | `"S"` | 2 | |
| int32 | `"l"` | 4 | |
| uint32 | `"L"` | 4 | |
| int64 | `"q"` | 8 | |
| uint64 | `"Q"` | 8 | |
| float32 (IEEE 754 single) | `"f"` | 4 | |
| float64 (IEEE 754 double) | `"d"` | 8 | |
| complex64 (2× float32) | `"Zf"` | 8 | **new in v1.1** |
| complex128 (2× float64) | `"Zd"` | 16 | **new in v1.1** |

Rationale for new / changed rows:

- **bool `"?"`** (was `"C"`): `?` is PEP 3118's dedicated bool
  specifier and round-trips through `rb_memory_view_parse_item_format`
  as a boolean component. Numo's consumer already maps `?` → UInt8 in
  v1.0 §3.2. The previous `"C"` choice came from Ruby pack semantics
  (where `?` is not a numeric specifier) but is not PEP 3118 canonical.
- **complex `"Zf"` / `"Zd"`**: `Z` is PEP 3118's complex marker
  composed with the underlying float specifier. `String#unpack` does
  not implement `Z` as a numeric prefix (in pack `Z` means
  null-terminated string), but the MV protocol's authority is PEP 3118
  (§0), not pack. The alternative `"ff"` / `"dd"` (two interleaved
  floats) is structurally ambiguous: consumers cannot tell "one complex
  element" from "two real elements packed as a tuple" without
  out-of-band knowledge. `Z` resolves this.

Not exported (no canonical form):

- `CA_FIXLEN` / variable-byte payload types (CArray-only, no portable
  spec)
- `CA_OBJECT` / VALUE column (protocol-level limit)
- long double / float128 — **permanently dropped, see §5.4**
- complex256 (quad-precision complex) — **permanently dropped, see
  §5.4**

---

## 3. Permissive consumer parser (consumer side)

### 3.1 Stripping

Unchanged from v1.0 §3.1.

### 3.2 Synonym table

After stripping, dispatch on the **tuple** `(stripped_format,
item_size)`.

| `stripped_format` | `item_size` | dtype | note |
|---|---|---|---|
| `?` | 1 | bool / uint8 | **canonical in v1.1**; consumers without a native bool type map to uint8 |
| `C`, `B` | 1 | uint8 / bool | **`C` retained as compat synonym for bool** (legacy v1.0 producers) |
| `c`, `b` | 1 | int8 | |
| `s`, `s!`, `h` | 2 | int16 | |
| `S`, `S!`, `H` | 2 | uint16 | |
| `l`, `i`, `i!` | 4 | int32 | |
| `l!` | 4 | int32 (LP32 hosts) | |
| `L`, `I`, `I!` | 4 | uint32 | |
| `L!` | 4 | uint32 (LP32 hosts) | |
| `q`, `q!` | 8 | int64 | |
| `l!` | 8 | int64 (LP64 hosts) | |
| `Q`, `Q!` | 8 | uint64 | |
| `L!` | 8 | uint64 (LP64 hosts) | |
| `f` | 4 | float32 | |
| `d` | 8 | float64 | |
| `Zf` | 8 | complex64 | **canonical in v1.1** |
| `ff` | 8 | complex64 | **compat synonym** (legacy v1.0 producers, CArray pre-v1.1) |
| `Zd` | 16 | complex128 | **canonical in v1.1** |
| `dd` | 16 | complex128 | **compat synonym** (legacy v1.0 producers, CArray pre-v1.1) |

Notes on the new rows:

- `Zf` / `Zd` are **multi-character** specifiers. Consumer dispatchers
  that lookup by single character (e.g. `switch (fmt[0])`) need to be
  extended to peek `fmt[0] == 'Z'` then dispatch on `fmt[1]`. CArray
  and numo dispatch tables already use string compare; the change is
  mechanical.
- `ff` and `dd` are listed as compat synonyms so that any producer
  emitting v1.0-era complex still interoperates. New producers MUST
  emit `Zf` / `Zd`.
- `C` against item_size 1 is now **ambiguous** between uint8 and bool.
  Consumers that need to distinguish (numo-narray has a Bit dtype, for
  example) SHOULD prefer to map `C` → uint8 (the v1.0-era reading) and
  `?` → bool, and only fall back when the user explicitly requests
  bool semantics. This ambiguity is the cost of preserving backward
  compatibility with v1.0 producers; it goes away when all producers
  upgrade.

### 3.3 Validation

Unchanged from v1.0 §3.3.

### 3.4 Implementation aid

Unchanged from v1.0 §3.4. The strip helper does not need to know about
`Z` because `Z` is part of the specifier body, not a prefix.

For dispatchers extending from v1.0:

```c
/* Pseudocode for adding Z handling */
const char *p = strip_prefixes(fmt);
if (p == NULL) return REJECT;
if (p[0] == 'Z') {
    /* PEP 3118 complex: Zf (8 bytes) or Zd (16 bytes) */
    if (p[1] == 'f' && item_size == 8)  return COMPLEX64;
    if (p[1] == 'd' && item_size == 16) return COMPLEX128;
    return REJECT;
}
/* ... existing v1.0 dispatch ... */
```

---

## 4. Reference implementations

| Library | File | Status |
|---|---|---|
| Ruby/CArray | [ext/carray_memory_view.c](../../ext/carray_memory_view.c) | **v1.2 landed (2026-05-21)**. Producer emits v1.1 top-level canonical (`?`/`Zf`/`Zd`) + v1.2 PEP 3118 struct format (`T{...}` with elided padding). Consumer accepts canonical + v1.0/v1.1 compat synonyms; struct format consumption deferred to ENHANCE_CASTRUCT Phase A.1+ (separate effort). |
| numo-narray-memoryview | `ext/numo/narray/memoryview/memoryview.c` | **v1.2 landed in public (2026-05-21, dev `f43c15f` → public `9d41bab..67b495b`)**. v1.1 work: README authority rewrite `332f5ae`, complex full implementation `076351a`. v1.2 work: opaque-REJECT pass-through verified, `test_v12_struct_format_opaque_reject` pins 9 cases. |
| bulk-memory-view | `ext/bulk_memory_view/bulk_memory_view.c` | **v1.2 landed (2026-05-21, `640dc4b`)**. BMV is a buffer holder + normalizer; format parsing delegates to `rb_memory_view_parse_item_format` so v1.2 `T{...}` flows through unchanged. v1.2 work: README scope note + pass-through test (format / item_size / byte_size preservation). `bmv_rebuild_format` hardening for `T{...}` (§6.6) is a separate PR scheduled as a follow-up; not a ratify blocker. |

### 4.1 Interop test matrix

The v1.1 spec is considered ratified once all three libraries pass a
shared round-trip test:

1. CArray emits each dtype in §2 → BMV receives via `.from(producer)`
   → BMV re-publishes → numo consumes via `Numo::NArray.from_memory_view`.
2. The reverse direction (numo emits → BMV → CArray).
3. PyCall hop (informational, not a hard CI gate): NumPy emits `Zd`
   → PyCall → CArray and Numo consumers accept without error.

Test files:

- CArray: `spec_ai/test_bmv_interop.rb`, `spec_ai/test_numo_interop.rb`,
  `spec_ai/test_format_parser.rb`
- numo-narray-memoryview: `test/test_format_parser.rb` (extend with
  `Zf`/`Zd` rows)
- bulk-memory-view: add `test/test_carray_numo_interop.rb` exercising
  the round-trip described above

### 4.2 Per-library migration checklist

#### CArray — **COMPLETE**

- [x] `ca_mv_format_for` (producer): emits `"?"` for `CA_BOOLEAN`,
      `"Zf"` for `CA_CMPLX64`, `"Zd"` for `CA_CMPLX128`. `"C"` / `"ff"` /
      `"dd"` removed from producer table.
- [x] `ca_mv_data_type_from_format` (consumer): added `"?"`/1
      (canonical bool), `"Zf"`/8, `"Zd"`/16 (canonical complex).
      `"C"`/1 retained as UINT8 (v1.0 CArray bool producers receive as
      UINT8, same as pre-v1.1 behaviour, no regression). `"ff"`/8 and
      `"dd"`/16 retained as compat synonyms for v1.0 producers.
- [x] `spec_ai/test_format_parser.rb` extended: canonical rows for
      `"?"`, `"Zf"`, `"Zd"`; compat rows for `"ff"`, `"dd"`;
      `test_unknown_Z_specifiers_rejected` pins the negative space
      (`Zc`, `ZF`/`ZD` uppercase, `Zfx` trailing junk, size
      mismatches).
- [x] `spec_ai/test_memory_view_import.rb` extended: round-trip
      tests for boolean, cmplx64, cmplx128 via
      `wrap_memory_view`, exercising producer → consumer through the
      v1.1 canonical symbols end-to-end.
- [x] Landed in `c467709`: `CA_FLOAT128`
      and `CA_CMPLX256` are now reserved-but-invalid enum values
      (`ca_valid[]=0`); the MV producer table never emitted them and
      remains unchanged for this concern.
- [x] Landed in `c467709`: `CComplex` Ruby
      surface removed, internal `NUM2CC` / `CC2NUM` routed through
      Ruby `Complex`. `CA_CMPLX64` / `CA_CMPLX128` storage layout
      (`float[2]` / `double[2]` contiguous) is unchanged, so MV
      producer continues to publish raw bytes under `"Zf"` / `"Zd"`
      without conversion.

#### numo-narray-memoryview — **COMPLETE in dev (2026-05-21)**

- [x] `dtype_format` (producer): `SComplex` → `"Zf"`/8,
      `DComplex` → `"Zd"`/16. (`076351a`)
- [x] `parse_format_to_class` (consumer): `("Zf", 8)` → `SComplex`,
      `("Zd", 16)` → `DComplex`. Existing `("?", 1) → UInt8` row stays.
      v1.0 compat synonyms `("ff", 8)` / `("dd", 16)` retained. (`076351a`)
- [x] `test/test_format_parser.rb` extended with Zf/Zd canonical rows,
      ff/dd compat rows, and negative-space `test_unknown_Z_specifiers_rejected`.
- [x] README authority section rewritten: PEP 3118 is authoritative;
      pack overlap is convenience, not contract. (`332f5ae`)
- `Bit` → `"?"`/1: **deferred** (Numo::Bit is sub-byte packed, not MV-
      exportable as 1-byte bool; see "Not supported" section in numo
      README, consistent with CArray's `CABitarray` reject policy).

#### bulk-memory-view

- [ ] No code change required for spec conformance (BMV delegates to
      `rb_memory_view_parse_item_format`, which already handles `Z` and
      `?`).
- [ ] Add `test/test_carray_numo_interop.rb` to lock in the
      round-trip described in §4.1.
- [ ] Update README to reference `MEMORYVIEW_FORMAT.md` v1.1 (or its
      successor location) as the cross-library convention BMV
      participates in.

### 4.3 Per-library checklist for v1.2 (struct format)

#### CArray — **COMPLETE in dev (2026-05-21)**

- [x] Producer: PEP 3118 struct format `T{<fmt>:<name>:...}` emitted
      for CAStruct subclass data MV (Phase A.1, `bfd1fe2` +
      `eed2bd1`). Format cached on data_class via
      `@__mv_struct_format__` ivar; zero-copy view.
- [x] Padding: ratified canonical = **elided** (`<N>x:`). Producer
      flipped from named (pre-ratify) to elided at ratification.
- [x] Coverage: all v1.1 primitives inside `T{...}`, alignment gaps,
      explicit trailing padding via `:size`. Rejects nested struct,
      sub-array, `:fixlen`, `:object`, `:bitfield` (with clear
      `reject_reason`).
- [x] Tests: `spec_ai/test_mv_struct_format.rb` (15 tests, 24
      assertions) updated for elided canonical form.
- [ ] **Consumer (Phase A.1+, separate effort)**: `T{...}` parsing
      on inbound, CAStruct reconstruction. Not part of v1.2 spec.

#### numo-narray-memoryview — **COMPLETE, public release shipped (2026-05-21, dev `f43c15f` → public `9d41bab..67b495b`)**

- [x] No producer change required (numo does not export struct
      types; Numo::Struct is not currently constructible on Ruby
      3.4).
- [x] Consumer: existing `parse_format_to_class` REJECTs all
      `T`-prefixed formats cleanly (returns `nil`). Treatment:
      **opaque REJECT** per §6.2.
- [x] README: "Format string convention" section extended with a
      v1.2 opaque pass-through paragraph.
- [x] Test: `test_v12_struct_format_opaque_reject` pins 9 cases —
      canonical (`T{i:a:d:b:}`, `T{B:r:B:g:B:b:B:a:}`),
      v1.3-deferred sub-array (`T{(3)f:xyz:}`), internal endian
      (`T{<i:a:}`), elided padding (`T{i:a:8x:}`), named padding
      (`T{i:a:8x:_:}`), edges (`T`, `T{}`, `Tx`). All assert `nil`
      return; misdispatch regression-protected.

#### bulk-memory-view — **COMPLETE in dev (2026-05-21, `640dc4b`)**

- [x] No producer change required (BMV is a buffer holder; accepts
      arbitrary `format:` from caller and stores verbatim).
- [x] No consumer change required for opaque pass-through (BMV
      delegates to `rb_memory_view_parse_item_format` which already
      parses PEP 3118 `T{...}`).
- [x] README scope note added ("PEP 3118 struct format `T{...}`
      also pass-through"). (`640dc4b`)
- [x] Pass-through test added: format / item_size / byte_size
      preservation across `BMV.from(ca)` for CArray-produced
      `T{...}` MV. (`640dc4b`)
- [ ] **Post-ratify follow-up** (separate PR, not a v1.2 blocker):
      `bmv_rebuild_format` hybrid implementation per §6.6 — pass
      through verbatim for `endian: :preserve`, raise
      `ArgumentError` for explicit cross-endian on `T{...}` inputs
      until v1.3 per-field endian markers land.

---

## 5. Future extensions

### 5.1 Cross-endian exchange

Unchanged from v1.0. Still deferred. The `Z` complex marker composes
with `<`/`>` prefixes in PEP 3118 (e.g. `"<Zd"`), so the v1.x
cross-endian extension does not need to revisit complex symbols.

### 5.2 Complex types — CLOSED in v1.1

Resolved. See §2 and §3.2. The v1.0 informational note is superseded.

Historical record:

- v1.0 (2026-05-13): informational only; CArray emitted `"ff"` /
  `"dd"` provisionally, numo did not emit complex.
- v1.1 (2026-05-21): normative. Canonical = `"Zf"` / `"Zd"`. `"ff"` /
  `"dd"` retained as consumer compat synonyms for v1.0-era producers.
  Driven by §0 (PEP 3118 authority) and BMV's reviewer feedback that
  surfaced the ambiguity of `"ff"` vs. `(float, float)` tuples.

### 5.3 Struct types — CLOSED in v1.2

Resolved. See §6. The v1.0 / v1.1 placeholder "PEP 3118 has a struct
syntax (`T{...}`); a future revision will adopt it rather than invent
a Ruby-specific form" is fulfilled in v1.2.

### 5.4 Quad-precision (float128, complex256) — CLOSED in v1.1

**Permanently out of scope.** Rationale:

- CArray has decided to drop `CA_FLOAT128` and `CA_CMPLX256` in
  3.0.0.
- numo-narray does not have these dtypes.
- PEP 3118 has no portable specifier for quad-precision (`g` denotes
  C `long double`, whose bit-width is platform-dependent — 80 bits on
  x86 with x87, 128 bits on some ABIs, 64 bits on Windows MSVC — and
  is therefore unusable for cross-library exchange).

No conforming producer exists or is planned in the Ruby numerical
ecosystem. This section will not be reopened.

### 5.5 Variable-width (CArray's CA_FIXLEN)

Unchanged from v1.0.

---

## 6. Struct format (PEP 3118 `T{...}`)

Added in v1.2. Producer side is normative; consumer side is opt-in.
A v1.1-conformant consumer is also v1.2-conformant as long as it
does not error on receiving a top-level format string starting with
`T`. Consumers MAY treat such formats as opaque (report unchanged via
`view->format`, treat `item_size` as record byte width, let
downstream code interpret the bytes) or REJECT them (`(format,
item_size) → nil`) — both are conforming.

### 6.1 Producer

A conforming producer that represents record-of-named-fields data
MAY emit a struct format string of the form

    T{<fmt1>:<name1>:<fmt2>:<name2>:...:}

where each `<fmtI>` is a PEP 3118 primitive specifier per §6.3, and
each `<nameI>` is an ASCII field name (no colons, no braces).
`item_size` MUST equal the byte size of one record (sum of field
sizes plus any embedded padding). The body MUST end with a colon
before the closing `}`.

Padding bytes (from alignment gaps or explicit trailing padding)
are represented using PEP 3118's `x` pad-byte specifier with an
optional repeat count: `<N>x`. **Canonical producer form: elided**
(no name slot after the padding specifier). Consumers MUST accept
both elided and named (`<N>x:_:`) forms — see §6.4 for the
rationale and the compat policy.

Example (canonical, elided): `T{B:a:7x:Q:b:}`
(uint8 a, 7 pad bytes, uint64 b)

### 6.2 Consumer

A consumer that does not natively support struct types MAY treat
`T{...}` formats as opaque: report the format unchanged via
`view->format`, treat `item_size` as the record byte width, and let
downstream code interpret the bytes. Consumers that DO support
struct types SHOULD parse the body per §6.3 and dispatch on the
per-field types.

A consumer that opts to parse struct formats MUST cross-check the
sum of per-field sizes (including padding bytes) against
`item_size`; mismatch is a producer bug and SHOULD be rejected.

### 6.3 PEP 3118 dialect (inside `T{...}`)

| field type | spec |
|---|---|
| bool       | `?`  |
| int8       | `b`  |
| uint8      | `B`  |
| int16      | `h`  |
| uint16     | `H`  |
| int32      | `i`  |
| uint32     | `I`  |
| int64      | `q`  |
| uint64     | `Q`  |
| float32    | `f`  |
| float64    | `d`  |
| complex64  | `Zf` |
| complex128 | `Zd` |
| padding    | `<N>x` |

Note: the symbols for int8..uint32 differ from the v1.1 top-level
table (`c`/`C`/`s`/`S`/`l`/`L`). Inside `T{...}` the convention is
PEP 3118 (consistent with NumPy, PyArrow, and Python's buffer
protocol); at top-level, v1.1's pack-template-compatible symbols
remain in effect. Consumers that reuse a single parser for both
contexts SHOULD branch on whether they are inside a `T{...}` body —
otherwise the symbol `i` inside `T{...}` would be misinterpreted as
float32 (top-level convention).

The mixed convention is the deliberate consequence of preserving
v1.1's top-level pack-template compatibility (an explicit v1.1
design choice for in-Ruby consumer ergonomics) while adopting
PEP 3118 for struct-body symbols (the only existing convention in
the broader buffer-protocol ecosystem). Top-level is a brownfield
with shipping producers/consumers — purifying it would churn the
ecosystem for no functional gain. `T{...}` body is a greenfield
with no prior Ruby producer — PEP 3118 strict applies cleanly.
The alternative (revising the v1.1 top-level table to PEP 3118
throughout) was considered and rejected during v1.2 ratification
as breaking a spec ratified one week earlier.

### 6.4 Padding-name convention

**Canonical producer form: elided** (`<N>x:` — no name slot after
the padding specifier).

**Consumer requirement: accept both** elided (`<N>x:`) and named
(`<N>x:_:`) forms. This is the Postel position consistent with the
rest of the spec.

Rationale:

- **Semantic** (numo review): padding is anonymous by definition.
  Putting `_` in the name slot suggests "this has a name we're
  choosing to ignore"; the truth is "this has no field-level
  identity at all". A name slot mismodels the abstraction.
- **Ecosystem parity**: NumPy's observed `memoryview(arr).format`
  for aligned structured dtypes uses the elided form. NumPy is the
  only mature PEP 3118 struct producer in any ecosystem; matching
  it minimizes Python-side reception variance when a Ruby↔Python
  MV bridge is eventually built.
- **Bytes economy** (minor): producer format strings are shorter.

Producer compat policy: pre-v1.2 CArray producers (`bfd1fe2` +
`eed2bd1`, the only such producers) emitted the named form
`<N>x:_:`. v1.2 CArray producers emit the elided form. Consumers
MUST accept both, so the producer flip is a producer-internal
change with no spec-level compat concern.

### 6.5 Sub-array dtype `(N)d:name:` — deferred to v1.3

PEP 3118 supports a sub-array specifier `(N)<fmt>:name:` for a
fixed-size embedded array member, e.g. `(3)f:xyz:` for a `float[3]`
xyz coordinate or `(16)B:uuid:` for a `uint8[16]` UUID.

**Status in v1.2: deferred to v1.3.** Ratification result
(2026-05-21): no co-author has a near-term use case.

- CArray's current CAStruct producer (Phase A.1) rejects sub-array
  members with a stable `reject_reason`. Phase A.1+ does not
  prioritize sub-array emission.
- numo has no consumer pressure (Numo::Struct is not currently
  constructible on Ruby 3.4 regardless).
- BMV is pass-through; no opinion on `(N)d` either way.

**v1.3 reopen conditions** — sub-array is added when at least one
of the following holds:

1. A co-author (CArray, numo, BMV, or a new participant) ships a
   concrete use case requiring `(N)d` emission or consumption.
2. NumPy / Cython / PyArrow side produces `(N)d`-bearing formats in
   a workflow that crosses Ruby↔Python (typically via a future MV
   bridge) and Ruby-side parsing becomes a friction point.

Either trigger surfaces a real reference scenario for the spec to
anchor on. Until then, `(N)d` stays out of the v1.x syntax space.

If fast-tracked in a future revision, the additions would be:

- §6.3 row: `(N)<fmt>` for any primitive `<fmt>` in the table.
- §6.1 producer rule: `item_size` accounts for the array (size = N
  × sizeof(`<fmt>`)).
- §6.2 consumer rule: SHOULD expose the field as an N-element array
  of the underlying primitive.

### 6.6 Note for format-rewriting consumers (informational)

This section is informational. It records a normalizer-side
discovery surfaced during v1.2 ratification (BMV review) so that
future producers / consumers / normalizers do not re-discover the
same trap.

**Background.** A consumer or middleware that rewrites format
strings as part of its public behaviour (e.g. an endian-aware
`from(producer, endian:)` adapter that reconstructs `view->format`
from the `rb_memory_view_item_component_t` list) MUST NOT flatten
a `T{...}` body into a primitive-component sequence. The component
list returned by `rb_memory_view_parse_item_format` exposes the
per-field primitives but loses the `T{...}` delimiters, field
names, and padding markers; naive re-emission produces something
like `"id"` instead of `"T{i:a:d:b:}"` and silently corrupts the
format string.

**Recommended behaviour for endian normalizers** when the input
format contains a `T{...}` body:

- If the caller requested `endian: :preserve` (or the normalizer's
  equivalent "no-op" mode), pass the format through verbatim. This
  is correct because v1.2 `T{...}` bodies cannot carry per-field
  endian markers (§6.7 future-extension lists per-field `<`/`>` as
  deferred), so there is nothing to normalize at the field level.
- If the caller requested explicit cross-endian conversion
  (`endian: :little/:big/:native` on a host where this requires
  byte-swapping), raise an explicit `ArgumentError` (or equivalent)
  with a message that points to this section. A silent no-op in
  this case is a footgun: the user explicitly asked for
  byte-swapping and would receive un-swapped bytes without warning.

**Producers** are not affected by this section — they emit
`T{...}` directly without going through a re-emission step.

**Top-level consumers that only dispatch on the format string**
(do not rewrite it) are also not affected. The numo
`parse_format_to_class` style — `(format, item_size) → dtype` —
returns `nil` for `T{...}` and stays v1.2-conformant with zero
changes (verified by numo `f43c15f`).

When v1.3 introduces per-field endian markers (alongside §6.5
sub-array support, or as a separate phase), this section will be
revisited so that format rewriting on `T{...}` becomes possible
rather than rejected.

### 6.7 Out of scope (deferred to a later revision)

- **Nested struct**: `T{T{i:a:d:b:}:nested:...:}`. PEP 3118 allows
  this; CAStruct does not express it directly. A future revision
  could add it.
- **Endianness markers per field**: PEP 3118 `<`/`>` prefixes inside
  `T{...}`. Same status as §5.1 (cross-endian) at top level — gated
  on the broader cross-endian story.
- **Bitfield members**: PEP 3118 has no bit-field grammar. CArray
  rejects struct format on data_classes with bitfield members
  (`reject_reason = "bitfield member <name> has no PEP 3118
  representation"`).
- **Opaque / variable-width members**: `:fixlen` (CArray-specific
  fixed-byte payload) and `:object` (CArray VALUE column) are
  rejected for the same reason as their top-level counterparts in
  §2.

---

## 7. Changelog

- **v1.2** (2026-05-21):
  - New §6 normative: PEP 3118 struct format (`T{...}`) on the
    producer side. Consumer side opt-in; consumers that do not
    parse struct formats remain v1.2-conformant without code
    change (verified by numo `f43c15f`: existing dispatch table
    REJECTs `T`-prefixed formats cleanly).
  - §6.3 documents the deliberate dialect difference between
    top-level (v1.1 pack-compat) and `T{...}` body (PEP 3118).
    Mixed convention is the ratified path (Option A) to preserve
    v1.1's in-Ruby consumer ergonomics. Rationale: top-level is a
    brownfield with shipping producers/consumers; `T{...}` body is
    a greenfield with no prior art, so PEP 3118 strict applies.
  - §6.4 padding-name convention ratified: **canonical = elided**
    (`<N>x:`); consumers MUST accept both elided and named forms.
    Rationale anchored on numo's semantic argument: padding is
    anonymous by definition, a name slot mismodels the abstraction.
    NumPy observed output also matches elided.
  - §6.5 sub-array dtype `(N)d:name:` deferred to v1.3 with
    explicit reopen conditions recorded.
  - §6.6 (informational) added during ratification: normalizers
    that rewrite format strings (e.g. BMV's endian-aware `from`)
    MUST NOT flatten `T{...}` structure. Discovery surfaced by
    BMV-side review; spec-level note prevents future re-discovery.
  - §5.3 (struct types placeholder from v1.0/v1.1) closed.
  - Driven by ENHANCE_CASTRUCT Phase A.1 (CArray `bfd1fe2` +
    `eed2bd1`) and the resulting need to standardize the symbol
    before any Ruby↔Python MV bridge is built. CArray producer
    flipped from named to elided form at ratification.
  - Co-authored ratification: CArray (`a838b93`),
    numo-narray-memoryview (`f43c15f`), bulk-memory-view
    (`640dc4b`). All three sides landed in dev on 2026-05-21.
    `bmv_rebuild_format` hardening for §6.6 scheduled as a
    follow-up PR on the BMV side; not a ratify blocker.

- **v1.1** (2026-05-21):
  - Added §0 establishing PEP 3118 as the authority, with reference to
    the protocol designer's intent (mrkn 2020).
  - Promoted bool to `"?"` (canonical) with `"C"` retained as consumer
    compat synonym.
  - Promoted complex to `"Zf"` / `"Zd"` (canonical) with `"ff"` /
    `"dd"` retained as consumer compat synonyms.
  - Closed §5.2 (complex types) as resolved.
  - Closed §5.4 (quad-precision) permanently — CArray 3.0 drops the
    only producer that had them, no successor planned.
  - Added bulk-memory-view as co-author. Updated §4 to list three
    reference implementations and added an interop test matrix.
  - Added per-library migration checklist in §4.2.

- **v1.0** (2026-05-13): initial stable release. Established Postel's
  law + `(format, item_size)` tuple dispatch + host-endian default.
  Co-authored by CArray and numo-narray-memoryview. Complex types
  (`ff`/`dd`) were informational only and bool was `"C"` — both
  promoted to PEP 3118 canonical (`Zf`/`Zd`/`?`) in v1.1 above.
