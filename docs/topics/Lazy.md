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

## Where lazy sits in CArray

### A view that changes values

CArray's views come in two kinds:

| kind | what it changes | examples |
|---|---|---|
| positional | which cell is read | `[]`, `transpose`, `reshape`, `shift`, `window`, selection |
| value | what the cell read becomes | `fake` (a cast on read), the lazy views |

A lazy view is the general form of the second kind.  `fake` changes a
value's type as it is read; a lazy view does the same with arithmetic,
mathematical functions and comparisons.  Neither holds data: each makes its
cells from its parent when they are read, and everything that reads a view
reads these the same way.

So lazy is not a separate engine or mode.  It is the view algebra carried
from positions over to values.  The two kinds compose on the operands: a
positional view of a marked array stays marked (§4), so
`a.lazy.shift(1) + a.lazy` is still one expression.  Choose positions on
the operands — a positional view taken of an expression already built is a
view of an array, and the next operation on it is computed eagerly.

### The same meaning as eager, computed at a different time

- **Eager is the default.**  `a + b` computes now; only `.lazy` and `fuse`
  build an expression instead.
- **The answer is the same.**  A lazy expression computes exactly what the
  eager one would; where the two differ, that is a defect.
- **So the choice is about speed only** — whether to make an array for
  each step or to make one pass.  §6 is the guide.

### The one array that is an answer not yet computed

Having no data of its own gives a lazy view properties no other array has:

- it is **read-only** — there is nowhere for a write to land
- **`to_ca` does work here and nowhere else.**  On any other array `to_ca`
  returns the array itself; a lazy view has no cells until they are
  computed, so `to_ca` computes them into a new array
- it **cannot be exported through MemoryView** — there is no buffer to hand
  over yet

### An expression another evaluator can compute

A lazy expression is a closed graph with a data type on every node, so it
is the one form in which CArray can hand *what to compute* to something
else as plain data.

- CArray decides what the answer is: the operations, the mask rules, the
  types.
- A lazy expression carries that, not yet computed.
- An evaluator registered with CArray may compute it another way.  The
  `carray-jit` gem registers one that compiles the expression; without it,
  CArray walks the expression itself, and the answer is the same either way.

CArray keeps the decision: it asks the evaluator only for expressions large
enough to be worth it, the evaluator may decline, and one that raises is
dropped and the walk takes over.  It is asked wherever the expression is
made whole: `to_ca`, `copy`, `out[] = expr`, and a reduction, scan, sort
or median that makes it whole before it starts (§6).  A reduction of the
whole array streams the expression in chunks instead, and is left to.

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
- a Face (`CATime`, `CACategorical`, a string array, ...) returns itself
  from `.lazy`: a lazy tree computes on storage and would drop what the
  Face means, so its operations stay eager -- inside `CArray.fuse` too

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
| Enumerable | `each`, `to_a`, `map`, ... on the lazy view | materialises first, then delegates to entity |
| `sort` | `lazy_view.sort`, `lazy_view.sort(axis: k)` | a read-only sorted view over the expression, as a sort of an array is a view over the array: the order is fixed when it is made, its cells read the expression and follow later changes of the operands, and it refuses writes like the expression |
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

## 6. Performance — what each path costs

An expression can be computed three ways:

| path | what it does |
|---|---|
| **eager** | one pass per operation, each making a new array |
| **walk** | `.lazy` / `fuse` with nothing registered: CArray computes the expression itself, with no array for the steps along the way |
| **compiled** | `.lazy` / `fuse` with an evaluator registered (the `carray-jit` gem): the whole expression becomes one loop |

The compiled path is asked only for an expression of 10,000 cells or more,
and only where the whole expression is made into an array:

- `to_ca`, `copy`, and `out[] = expr`
- a reduction along an axis (`sum(axis: 1)`), of a masked expression, or
  one that never streams (`variance`, `min_index`, `wsum`)
- a scan (`cumsum`), a sort (`sort_index`), `median` and `percentile`

A reduction of the whole array with no mask (`sum`, `mean`, `min`, `max`)
streams the expression in small chunks instead of making it whole, and is
walked: handing it over would cost the memory of the whole
expression.

### Measured (Apple M2 Max, 512 × 512, milliseconds per call)

Conway's Life rule — eight shifted neighbours summed, then
`n.eq(3) | (alive & n.eq(2))`:

| type | eager | walk | compiled | walk / eager | compiled / eager |
|---|---:|---:|---:|---:|---:|
| `uint8`   | 0.67 | 0.58 | 0.26 | 0.87x | 0.39x |
| `uint16`  | 0.91 | 0.76 | 0.27 | 0.83x | 0.30x |
| `uint32`  | 1.36 | 1.09 | 0.33 | 0.80x | 0.24x |
| `uint64`  | 2.84 | 1.93 | 0.34 | 0.68x | 0.12x |
| `float64` | 2.48 | 2.00 | 0.33 | 0.81x | 0.13x |

Five-point Laplacian, `float64`
(`u.shift(1,0) + u.shift(-1,0) + u.shift(0,1) + u.shift(0,-1) - u * 4.0`):

| eager | walk | compiled | walk / eager | compiled / eager |
|---:|---:|---:|---:|---:|
| 1.45 | 0.82 | 0.28 | 0.56x | 0.19x |

A chain of `^` over eight `uint64` sources, `.lazy`, walk / eager:

| cells (one buffer) | depth 4 | depth 16 | depth 64 | depth 256 |
|---:|---:|---:|---:|---:|
| 4,096 (32 KB)     | 0.57 | 0.46 | 0.42 | 0.41 |
| 65,536 (512 KB)   | 0.54 | 0.40 | 0.37 | 0.41 |
| 1,048,576 (8 MB)  | 0.71 | 0.39 | 0.48 | 0.40 |

In every case measured the walk is no slower than eager, at every type,
size and depth; it saves the arrays eager makes for each step.  The
compiled path is faster again by a wide margin.

### The fixed cost of `fuse`

`fuse` reads a block's source the first time that block is called, which
takes a fraction of a millisecond, and keeps what it made of it.  Each
call after that costs about a microsecond more than writing `.lazy`:

| cells | eager | `.lazy` | `fuse` |
|---:|---:|---:|---:|
| 16     |   1.0 µs |  2.1 µs |  3.1 µs |
| 4,096  |   7.3 µs |  5.9 µs |  7.6 µs |
| 65,536 | 105.7 µs | 57.6 µs | 59.3 µs |

A block that assigns to a local outside it, or yields to the method's
block, has to be run in its own frame, and costs about 12 µs a call.

### What the compiled path does not take

The expression is still computed — by the walk — when the compiled path
cannot describe it:

- an object array, or a comparison with a tolerance (`feq`, `is_close`)
- a reduction of the whole array with no mask, which streams (above)
- an expression smaller than 10,000 cells

A `shift` of an expression (rather than of an array), a `roll` or a
`window` is handed over as an array the evaluator has to copy whole
before reading, which can make it slower than the walk.  Shift the
arrays the expression is built from instead.

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
