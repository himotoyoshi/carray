# Lazy element-wise views — `.lazy` / `CArray.lazy` / `CArray.fuse`

CArray 3.0 introduces **lazy element-wise views**: an element-wise
expression like `(a + b * t).sum` builds a small operator tree (no
intermediate buffer) and evaluates in one streamed pass on first
materialise.  Three surfaces are provided:

| surface | scope | output |
|---|---|---|
| `head.lazy` | persistent — keep a lazy view and consume it many times | lazy view (escape OK) |
| `CArray.lazy(args...) { |args...| body }` | transient block scope, **lazy structure preserved** | lazy view (pass-through on block exit) |
| `CArray.fuse(args...) { |args...| body }` | transient — fuse a single expression and get back an entity | entity (auto-materialise on block exit) |

All three surfaces are type-driven (no thread-local state).  `a + b` syntax
is unchanged; eager and lazy paths coexist.

---

## 1. `.lazy` — persistent lazy view

```ruby
m = a.lazy            # zero-cost marker
y = (m.sqrt + m.sin)  # CABinOp tree, not yet evaluated
y.to_ca               # materialise — single pass, no intermediates
```

- `.lazy` returns a read-only marker wrapping `a`
- subsequent element-wise / affine ops build a `CAMonOp` / `CABinOp`
  / `CATriOp` / `CAMonCmp` / `CABinCmp` tree
- nothing is computed until you call `.to_ca` (or trigger materialise
  via `each`, `to_a`, `sum`, etc.; see §4)
- the marker (and the tree) is **read-only**: `m[0] = v` raises

---

## 2. `CArray.fuse` — transient fusion + polymorphic helper

`CArray.fuse(args...) { |args...| body }` wraps each CArray argument
with `.lazy`, yields the wrappers to the block, then on block exit
auto-materialises any bare lazy return value into an entity.

```ruby
result = CArray.fuse(u) { |u|
  (u.shift(1,0,fill_value:0) + u.shift(-1,0,fill_value:0) +
   u.shift(0,1,fill_value:0) + u.shift(0,-1,fill_value:0) - 4*u) / h**2
}
# result is a CArray entity
```

Arguments that are **not** CArray (Float, Integer, Rational, etc.) are
passed through unchanged — this enables the polymorphic numeric helper
idiom:

```ruby
using CArray::CoreExtensions   # postfix sqrt/exp/log/sin/... on Numeric

def magnus(t)
  CArray.fuse(t) { |t| 6.1078 * ((17.27 * t) / (t + 237.3)).exp }
end

magnus(25.0)               # => 31.677 (Float — refinement maps .exp to Math.exp)
magnus(temperature_array)  # => CArray (CAMonOp tree materialised in one pass)
```

The **same expression** carries both scalar and array paths.  No
`is_a?` branching, no formula duplication.  This is unique to CArray
among Ruby numeric libraries; it builds on:

- the `CArray::CoreExtensions` refinement (= same postfix math methods
  on `Float` / `Integer` / `Rational` as on `CArray` instances), and
- the lazy view substrate (= `CAMonOp` / `CABinOp` etc. give CArray
  args fusion + 1-pass materialise).

### Block exit semantics

| block return value | what `fuse` returns |
|---|---|
| `CAMonOp` / `CABinOp` / `CATriOp` / `CAMonCmp` / `CABinCmp` / `CALazyMarker` | `.to_ca` applied → entity |
| plain `CArray` entity | passes through unchanged |
| `Numeric` | passes through unchanged |
| `Array`, `Hash`, `nil`, etc. | passes through unchanged (Array containing lazy views does **not** recursively materialise; if you need that, call `.to_ca` explicitly inside the block) |

### Shadow read-only

Inside the block, the lazy-wrapped argument (= "shadow") is read-only:

```ruby
CArray.fuse(arr) { |a| a[0] = 99 }   # raises RuntimeError
```

Eager arrays captured from outside the block remain mutable normally.
Numeric arguments are pass-through and behave like ordinary Ruby
numbers.

### Nested `fuse`

Inner `fuse` materialises at its own exit:

```ruby
CArray.fuse(a) { |a|
  inner = CArray.fuse(b) { |b| a + b }   # inner is an entity here
  a + inner                               # outer is `lazy + entity`
}
```

Nested `fuse` breaks fusion at the inner boundary; for a single
fused expression prefer a flat call: `CArray.fuse(a, b) { |a, b| ... }`.

### When `fuse` is overhead

Numeric args add ~100 ns of Ruby overhead per `fuse` call (= block
yield + a few `is_a?` checks).  Irrelevant for typical use, but if you
call a `fuse`-based helper in a tight loop with Numeric args (= an
antipattern; bulk-op the array instead), you can branch on
`arg.is_a?(CArray)` at the call site for raw speed.

---

## 3. `CArray.lazy` — transient lazy scope (= no auto-materialise)

`CArray.lazy(args...) { |args...| body }` is the pair of `CArray.fuse`
that **does not** auto-materialise on block exit.  Each CArray arg is
wrapped with `.lazy` (read-only marker), the block runs, and the
return value passes through unchanged.

```ruby
expr = CArray.lazy(a, b) { |s, o| (s + o) * 2 }
expr.class          #=> CABinOp (lazy view)
expr.to_ca          # full materialise on demand
expr.sum            # reduce in one chain+reduce pass
```

Use this when you want to:

- **build a reusable lazy expression** (= apply the same expression to
  multiple datasets):
  ```ruby
  def normalised(arr)
    CArray.lazy(arr) { |a| (a - a.mean) / a.stddev }
  end
  series = many_arrays.map { |arr| normalised(arr).to_ca }
  ```
- **pass a lazy chain across function boundaries** (= caller decides
  how to materialise: full / reduction / cast / etc.)
- **debug / introspect** the lazy tree (= `expr.dump_tree`,
  `expr.inspect`) without triggering materialise
- **choose the materialise shape later** (= `.to_ca` for full,
  `.sum` / `.mean(axis: k)` for reduction, etc.)

Polymorphic semantics match `fuse` — Numeric / non-CArray args pass
through unchanged, so the same helper definition supports both
`CArray.lazy(arr, b) { ... }` and `CArray.lazy(scalar, b) { ... }`.

### `fuse` vs `lazy` — when to use which

| You want | Surface |
|---|---|
| A single closed-form expression that returns an entity | `CArray.fuse(args) { ... }` |
| To keep the expression as a lazy view (= caller chooses materialise) | `CArray.lazy(args) { ... }` |
| To hold a lazy view across many statements / iterations | `.lazy` (= persistent surface, no block) |

---

## 4. Operation taxonomy (= what materialises and what doesn't)

| category | examples | effect on lazy view |
|---|---|---|
| element-wise op | `+ - * / **`, `sqrt sin exp`, `< == is_nan`, `& \| ^`, `fma / fms / clip` | builds new `CAMonOp` / `CABinOp` / `CATriOp` / `CAMonCmp` / `CABinCmp` node; no materialise |
| positional view | `[]`, `.shift`, `.roll`, `.flip` / `.reverse`, `.transpose` / `.T`, `.reshape`, `.flatten`, `.window`, `.diagonal`, `.tile`, `.refer` | keeps the lazy wrapper on top of the view; no materialise. The rule is the category, not the list: a view method whose shape is fixed when it is built and which only moves positions keeps the chain. The deliberate exceptions are anything that owns its data (`copy`), reorders values (`sort`, `partition`) or changes what the mask means (`value`, `strip_mask`) |
| cast | `.fake(:int32)`, data_type widening | adds cast node to tree; no materialise |
| reduction | `sum`, `mean`, `min`, `max`, `variance`, `argmin`, ... | materialises and reduces in one pass |
| Enumerable | `each`, `to_a`, `map`, `sort`, ... on the lazy view | materialises first, then delegates to entity |
| `[]=` | `lazy_view[i] = v` | **raises** (`CA_FLAG_READ_ONLY`) |
| per-cell `[]` | `lazy_view[i]` | works (one-cell `xfer_index`); for hot loops, snapshot `.to_ca` first |
| MV export | passing a lazy view to a `MemoryView` consumer (Arrow, Numo, bulk-memory-view) | **raises** `TypeError` with hint to call `.to_ca` first |
| `inspect` / `to_s` / `dump_tree` | introspection | summary string only; no materialise |

---

## 5. When to use which surface

- **`.lazy`** — when you want to hold onto a lazy expression across
  many statements/iterations, e.g. a parametric model
  `model = (a.lazy + b * param)` evaluated for thousands of `param`
  values in a tight loop.
- **`CArray.fuse(args) { ... }`** — when you want to write a single
  closed-form expression and get an entity back, and (especially) when
  the same helper should accept both `CArray` and `Numeric`.
- **`CArray.lazy(args) { ... }`** — when you want `fuse`-style block
  scope but need to **return the lazy view** to the caller (= caller
  picks the materialise form: `.to_ca` / `.sum` / `.mean(axis:)` /
  etc.).

When in doubt, `fuse` is the safer default: nothing escapes the block
as a lazy view, so external code never has to know about the lazy
substrate.

---

## 6. Performance — when fuse wins, when eager wins

`fuse` is not unconditionally faster.  Whether `fuse` beats the
equivalent eager expression depends on three independent axes:

1. **Source count** in the expression (= number of CArray operands
   read per output cell).  Eager scales as `O(sources × element-wise
   contig pass)`, each pass auto-vectorised.  `fuse` scales as
   `O(cells × sources)` in a single scalar dispatch loop.  Eager
   prefers many sources; `fuse` prefers few.
2. **Element width** (= SIMD lane count per 128-bit register).  Eager
   auto-vectorisation processes 16 `uint8`s, 8 `uint16`s, 4 `uint32`s,
   or 2 `uint64` / `float64` per SIMD iteration.  Wider elements
   shrink eager's vectorisation lead.  `fuse`'s per-cell dispatch cost
   is largely width-insensitive.
3. **Per-cell compute density** and **intermediate buffer pressure**.
   Eager allocates one contig buffer per binop; deep chains over
   large `float64` arrays spill out of L2 and pay memory traffic for
   every intermediate.  `fuse` writes only the final result.  Heavy
   per-cell arithmetic (transcendentals, branchy bool rules) amortises
   `fuse`'s dispatch overhead.

### Measured break-even (M2, 512², `CARRAY_DEV=1`)

Conway's Life rule (`(n==3) | (a & n==2)` over 8 neighbour shifts =
9-source chain) across `uintN` widths, eager vs `CArray.fuse`:

| type     | SIMD lane | eager ms/step | fuse ms/step | fuse/eager |
|----------|----------:|--------------:|-------------:|-----------:|
| `uint8`  |        16 |          0.69 |         2.27 |      3.30x |
| `uint16` |         8 |          0.99 |         2.44 |      2.46x |
| `uint32` |         4 |          1.71 |         2.84 |      1.66x |
| `uint64` |         2 |          3.79 |         3.74 |      0.99x |

Eager scales linearly with element width (memory-bandwidth-bound).
`fuse` stays nearly flat (per-cell dispatch dominates, width-
insensitive).  They cross at `uint64` / `float64` SIMD width.

5-point Laplacian (`a.roll(1,0) + a.roll(-1,0) + a.roll(0,1) +
a.roll(0,-1) - 4*a`, 5-source f64):

| variant | ms/iter | vs eager |
|---------|--------:|---------:|
| eager   |    1.65 |    1.00x |
| fuse    |    1.15 |    0.70x (= **fuse 1.4x faster**) |

### Decision guide

Reach for `fuse` when **any** of:
- the data type is `float64` / `complex128` (= 2-lane SIMD)
- chain has heavy per-cell math (`exp`, `log`, `sqrt`, transcendentals)
- intermediate buffers are large (= each binop spills L2, > a few MB)
- source count is small (1–4)

Stay with eager when **all** of:
- the data type is narrow (`uint8` / `int16` / `float32`, 4+ lanes)
- per-cell op is light (add / cmp / bitwise / cast)
- source count is high (5+)
- intermediate buffers fit comfortably in L2

Chained eager `+` on roll views is fast (the chained intermediates
stay hot in cache).  `add!` on a view source pays a per-call attach
cost; for accumulation patterns prefer chained `+` unless you have
profiled.

### Chain depth × buffer size — the "small N, deep chain" cliff

For light-op chains (uint64 bitwise, integer add), the fuse/eager
ratio depends on **both** chain depth and per-buffer size relative
to cache hierarchy.  Eager allocates one intermediate per binop; if
all intermediates fit L1 (or L2), eager's vectorised passes are
cheap and fuse loses despite the chain being fused.  Once
intermediates spill, eager pays memory traffic per binop and fuse
wins decisively.

Measured uint64 XOR chain over 8 sources:

| N (cells) | per-buffer | depth 4 | depth 16 | depth 64 | depth 256 |
|----------:|-----------:|--------:|---------:|---------:|----------:|
|     4,096 |      32 KB |    1.32 |     0.92 |     1.54 |    18.48  |
|    65,536 |     512 KB |    0.97 |     0.65 |     0.70 |     1.85  |
| 1,048,576 |       8 MB |    0.96 |     0.76 |     0.72 |     0.75  |

(values are `fuse / eager`; < 1.00 = fuse wins)

At N=4K (intermediates fit L1), eager dominates and a depth-256
chain triggers a catastrophic fuse degradation (cache eviction on
the lazy arena).  At N=1M, all depths sit in fuse's favour —
intermediate-buffer memory traffic for eager grows linearly with
depth, while fuse stays in one pass.

So "many ops favours fuse" is true **conditional on buffer size**.
For scientific-data sizes (≥ ~64K cells) the win is robust across
chain depths.  For tiny intermediate buffers (< L1), prefer eager
even for deep chains.

### Cast at the chain tail — `as_<type>`, not `.<type>`

A common mistake when keeping a lazy chain alive across iterations:

```ruby
expr = ((n.eq(3)) | (x & n.eq(2))).uint8        # WRONG
expr = ((n.eq(3)) | (x & n.eq(2))).as_uint8     # right
```

`ca.<type>` (e.g. `.uint8`, `.float64`) eagerly materialises a lazy
expression into an entity at the call site.  Subsequent `.to_ca` on
the result returns the same snapshot — the chain is broken.
`ca.as_<type>` builds a lazy cast node (`CAMonOp`) that re-evaluates
on every `.to_ca`.  Use `as_<type>` whenever the cast is the tail
of a chain you intend to materialise more than once.

---

## 7. Source

- `lib/carray/lazy.rb` — Ruby-level dispatch and `CArray.fuse`
- `lib/carray/core_extensions.rb` — `CArray::CoreExtensions` refinement
- `ext/carray_lazy.c` — `CALazyMarker` C-level view
- `ext/ca_obj_monop.c`, `ext/ca_obj_binop.c`, `ext/ca_obj_triop.c` — `CAMonOp`, `CABinOp`, `CATriOp`
- `ext/ca_obj_moncmp.c`, `ext/ca_obj_bincmp.c` — `CAMonCmp`, `CABinCmp`
