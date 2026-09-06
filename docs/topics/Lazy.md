# Lazy element-wise views — `.lazy` and `CArray.fuse`

An element-wise expression like `(a + b * t).sum` can be built as a small
operator tree rather than evaluated a step at a time: no array stands for a
step along the way, and the whole of it runs in one pass when something asks
for the answer.  Two surfaces build one:

| surface | what it is for |
|---|---|
| `a.lazy` | mark one array, and build from there |
| `CArray.fuse { ... }` | write the expression itself |

Both are type-driven, with no thread-local state.  `a + b` still means what
it meant; the eager and lazy paths sit side by side.

---

## 1. `.lazy` — marking an array

```ruby
m = a.lazy            # a read-only marker over a, costing nothing
y = m.sqrt + m.sin    # an operator tree, not yet evaluated
y.to_ca               # computed here, in one pass, with no intermediates
```

- `.lazy` returns a read-only marker wrapping `a`
- element-wise and affine operations on it build a `CAMonOp` / `CABinOp`
  / `CATriOp` / `CAMonCmp` / `CABinCmp` tree
- nothing is computed until something asks: `to_ca`, or a store, or a
  reduction such as `sum` (see §4)
- the marker, and the tree over it, is **read-only**: `m[0] = v` raises

---

## 2. `CArray.fuse` — writing the expression

```ruby
out[] = CArray.fuse { (a + b) * (c - a) + b * c - a }
total = CArray.fuse { a * weight }.sum
```

The block is **read, not called**.  Its `a` is the array itself, so calling
it would compute the expression eagerly — the thing this exists to avoid.
The source is rewritten so that every name in it holding a CArray reads as
`a.lazy`, and the result is evaluated back in the block's own binding: `self`,
instance variables, methods and constants are what they were where it was
written.

```ruby
class Field
  def gradient
    CArray.fuse { (@u.shift(1, 0) - @u.shift(-1, 0)) / (2 * spacing) }
  end
end
```

What comes back is the **expression**, not an array.  It is computed where it
is used — stored into an array, reduced, or asked for one with `to_ca`.  A
block holding anything but an expression over arrays comes back as whatever
it evaluated to.

Ruby has no macro, so the alternative was to hand the arrays in and take
shadows back.  Julia writes `@.` for the same reason, and does the same thing
to the expression underneath.

### A value that is not an array passes through

Only names holding a CArray are given `.lazy`; everything else is left as it
is.  One helper then reads the same for a scalar and for an array:

```ruby
using CArray::CoreExtensions   # postfix sqrt/exp/log/sin/... on Numeric

def magnus (t)
  CArray.fuse { 6.1078 * ((17.27 * t) / (t + 237.3)).exp }
end

magnus(25.0)               # => 31.677, a Float: the refinement maps .exp to Math.exp
magnus(temperature_array)  # => the expression, computed in one pass
```

The **same expression** carries both paths — no `is_a?` branching, no
formula written twice.  It rests on two things: the `CArray::CoreExtensions`
refinement, which puts the same postfix math on `Float` / `Integer` /
`Rational` as on a CArray, and the lazy views, which give the array path its
fusion.

### The operands are read-only

Inside the block the arrays are read through a marker, so writing raises:

```ruby
CArray.fuse { arr[0] = 99 }   # raises RuntimeError
```

The arrays themselves are untouched, and stay writable outside.

### An index is a position, not a value

`a[i]` reads array `a` at `i`; only `a` is an operand of the expression, so
`i` is left alone whatever it holds.

### When the source cannot be read

A block written in irb, in `eval`, or in a file that is no longer there has
no source to read, and `fuse` says so rather than quietly computing the
expression the slow way.  Write `.lazy` on the operands there:

```ruby
a.lazy + b.lazy
```

That always works, and it is what `fuse` writes for you.

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

- **`CArray.fuse { ... }`** — most of the time.  The expression reads as
  itself, and one helper serves a scalar and an array alike.
- **`.lazy`** — when the expression is held rather than written in one
  place: a parametric model `model = a.lazy + b * param` kept across many
  values of `param`, or an operand marked once and combined further on.
  Also where a block's source cannot be read, in irb or in `eval`.

Both give back an expression, so what forces it is the same either way.

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
- `lib/carray/fuse_source.rb` — reading a block as an expression
- `lib/carray/core_extensions.rb` — `CArray::CoreExtensions` refinement
- `ext/carray_lazy.c` — `CALazyMarker` C-level view
- `ext/ca_obj_monop.c`, `ext/ca_obj_binop.c`, `ext/ca_obj_triop.c` — `CAMonOp`, `CABinOp`, `CATriOp`
- `ext/ca_obj_moncmp.c`, `ext/ca_obj_bincmp.c` — `CAMonCmp`, `CABinCmp`
