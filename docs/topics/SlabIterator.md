# Slab iterator — per-axis Ruby block surface

CArray provides three `CArray` instance methods — `map_slab`,
`reduce_slab`, and `each_slab` — that iterate over an array one
**slab** (a 1-D slice along a chosen axis) at a time and hand each
slab to a Ruby block. They let you run per-axis kernels in a few
lines of Ruby without writing C.

The name *slab* is used in preference to *along axis*: it makes clear
that the block sees a fiber, not the array reduced along the axis,
and avoids the ambiguity of "iterate along axis k" (which can read
as either "walk along k" or "walk over the slices perpendicular to
k").

| method | semantics | output shape |
|---|---|---|
| `map_slab(axis:, data_type:) { \|slab\| ... }` | Per-axis element-wise vectorise | same as self |
| `reduce_slab(axis:, [init:, data_type:]) { ... }` | Per-axis reduction (dual surface) | self.dim minus axis |
| `each_slab(axis:) { \|slab\| ... }` | Side-effect iteration | self (= return self) |

The block always receives a **1-D CArray** representing one fiber along
`axis:`. Standard CArray operations (`sum`, `mean`, indexing, arithmetic,
`.dup`, `.copy`) work directly on the slab.

## When to reach for the slab iterator

Three situations where this surface is the right tool:

1. **Ergonomics** — a few lines of Ruby instead of a C kernel and a
   recompile.
2. **`CA_OBJECT` / `CA_FIXLEN` per-axis paths** — the C kernel
   facilities are numeric-only at compile time; the slab iterator
   gives object / fixlen sources a per-axis path.
3. **Ad-hoc prototyping** — useful before committing to a C kernel.

What the slab iterator is **not** designed for:

- Hot inner loops where a native data_type kernel exists (`sum`,
  `mean`, `sort`, etc.). The structural `rb_yield` cost (~100 ns per
  call) keeps the slab iterator roughly 10–100× slower than a native
  reduction on cheap kernels. This is by design — the slab iterator
  is a Ruby-side surface, not a replacement for C kernels.

## Surface

### `map_slab(axis:, data_type:) { |slab| ... }`

`numpy.apply_along_axis` analogue. The block returns either:

- a **same-length CArray** → scattered into the output slab, or
- a **scalar** (Ruby Numeric / Boolean / `nil`, or any VALUE when the
  output data_type is `:object`) → broadcast to fill the output slab.

```ruby
# centre each row
ca.map_slab(axis: 1) { |row| row - row.mean }

# per-row sum (broadcast over slab — every cell in the row holds the sum)
ca.map_slab(axis: 1) { |row| row.sum }

# data_type override
ca.map_slab(axis: 1, data_type: :int32) { |row| row * 10 }
```

Returning a `CArray` with the wrong shape or a Ruby symbol on a numeric
output is a strict `ArgumentError`. The block's slab is borrowed; never
escape it (see "Slab persistence" below).

### `reduce_slab(axis:, [init:, data_type:]) { ... }`

Dual surface. `init:` presence picks the form (decided at `__init__`
time, no per-iter branch):

```ruby
# per-slab block form (no init):
ca.reduce_slab(axis: -1) { |slab| slab.median }

# per-element fiber form (init given):
ca.reduce_slab(axis: 0, init: 0.0) { |acc, x| acc + x }
```

Output shape is `self.dim` with the slab axis removed. A 1-D self
reducing axis 0 returns a 1-D length-1 result.

The per-slab block form requires a **scalar** return — even a
1-element `CArray` is rejected; extract via `slab[0]` or `slab.sum`
etc. The per-element fiber form lets `acc` be any Ruby object (use
`data_type: :object` for non-Numeric accumulators).

### `each_slab(axis:) { |slab| ... }`

Side-effect only. The block's return value is discarded; the method
returns `self`. Without a block, returns an `Enumerator` so you can
chain `.map`, `.each_with_index`, etc.

```ruby
ca.each_slab(axis: 0) { |row| fits.write_row(row) }

# Enumerator support — safe when the block extracts scalars
sums = ca.each_slab(axis: 1).map { |row| row.sum }
```

`break` / `next` / `return` propagate through `rb_ensure` so the T1
substrate is cleaned up before the non-local exit.

## Axis convention

`axis:` is the **operation's target axis**, not the axis that survives
in the output. `map_slab` / `each_slab` give the block a fiber along
`axis:`; `reduce_slab` collapses that axis. The visibility difference
flows from operation semantics; the axis itself is the same.

```ruby
ca.map_slab(axis: 1)    { |row| ... }  # row spans axis 1
ca.reduce_slab(axis: 1) { |row| ... }  # axis 1 collapsed in output
```

Negative axes are supported (`axis: -1` is the innermost). The
current surface is single-axis only; multi-axis slabs
(`axis: [k1, k2]`) are not supported.

## Slab persistence — block-only contract

The slab CArray is **reused per iteration**: its underlying `ptr` is
mutated in place. Capturing the slab object across iterations leaves
every entry referring to the same CArray, showing only the last iter's
data. This is documented and **not runtime-checked** (= per-cell access
hooks would defeat the cost model).

Use `slab.copy` / `slab.dup` / `slab.to_a` inside the block to snapshot:

```ruby
# CORRECT — snapshots taken in the block
rows = []
ca.each_slab(axis: 1) { |row| rows << row.dup }

# TRAP — every entry refers to the same persistence-trapped object
refs = []
ca.each_slab(axis: 1) { |row| refs << row }   # refs all point at iter N-1 data
```

In-block derived views (`row.dup`, `row[range]`, `row + 1`,
`(row > 0).as_int32`, `row.median`) read the current iter's data
correctly. The slab is presented as a `CAStride` whose
`(parent, base_offset, strides)` triple is updated per iteration so
that derived views see the right window.

## Mask handling

Masked source arrays currently raise `NotImplementedError`.
Strip the mask explicitly via `ca.value` if you need to feed a
masked source through:

```ruby
masked_ca.value.map_slab(axis: 1) { |row| row.normalize }
```

## Internal use — `CA_OBJECT` per-axis paths

Several pre-existing API surfaces — which used to raise on
`CA_OBJECT` axis paths — are routed through the slab iterator
internally. User-facing call sites do not change:

| method                                       | previous behaviour            | current behaviour                                |
|----------------------------------------------|-------------------------------|--------------------------------------------------|
| `mask_duplicates(axis: k)` on `CA_OBJECT` / `CA_FIXLEN` | `NotImplementedError`         | `map_slab` per-fiber Ruby Hash de-dup            |
| `sort(axis: k)` on `CA_OBJECT`               | `CArray::DataTypeError`       | `map_slab` per-fiber `to_a.sort`                 |
| `median(axis: k)` on `CA_OBJECT`             | `CArray::DataTypeError`       | `reduce_slab` per-fiber Ruby sort + pick         |
| `percentile(p, axis: k)` on `CA_OBJECT`      | `CArray::DataTypeError`       | `reduce_slab` per-fiber Ruby sort + interp       |

Performance for these `CA_OBJECT` axis paths sits at the slab
iterator's floor (`rb_yield` plus a Ruby Array conversion per fiber);
numeric data_type paths continue to use their dedicated C kernels and
are unaffected.

## Base mechanism — short tour

The implementation lives entirely in `ext/carray_slab.{c,h}`. Each
entry point (`rb_ca_map_slab` / `rb_ca_reduce_slab` /
`rb_ca_each_slab`) stack-allocates a per-call `ca_slab_iter_state_t`,
populates it via the nofail `slab_state_init`, and runs the body
under `rb_ensure` so the per-form loop (`slab_state_run_body`) and
the cleanup (`slab_state_finish`) are both guaranteed. There is no
Ruby-visible iterator object.

On each iteration the slab view is presented as a `CAStride` whose
four addressing fields are slid:

| field         | role                                                                       |
|---------------|----------------------------------------------------------------------------|
| `parent`      | `self` (ALIAS mode) or an internal `CAWrap` carrier (SCRATCH mode)         |
| `strides[0]`  | the kernel iterator's slab stride — constant across the walk               |
| `base_offset` | byte offset of the current fiber within `parent` — updated per iter (ALIAS)|
| `ptr`         | contig delivery: either an alias into the source or a scratch buffer       |

The ALIAS / SCRATCH choice is made once at init time. ALIAS is used
when the kernel iterator can hand back a pointer directly into source
memory (innermost axis on a contiguous source); SCRATCH is used when
non-innermost axes require strided fibers to be gathered into an
internal buffer.

## Tutorial examples

### Per-row normalisation

```ruby
zscore = ca.map_slab(axis: 1) { |row| (row - row.mean) / row.std }
```

### Per-column rank via Ruby Array

```ruby
ranks = ca.map_slab(axis: 0) do |col|
  sorted = col.to_a.each_with_index.sort.map(&:last)
  rank   = Array.new(sorted.size)
  sorted.each_with_index { |orig_i, r| rank[orig_i] = r }
  CArray.int32(rank.size) { |i| rank[i] }
end
```

### Per-row median of CA_OBJECT (routed through `reduce_slab` internally)

```ruby
ca = CArray.object(rows, cols) { |i, j| some_struct(i, j) }
medians = ca.median(axis: 1)        # dispatches through reduce_slab on CA_OBJECT
```

### Stencil via `each_slab` + view composition

```ruby
out = CArray.float64(*ca.dim)
ca.each_slab(axis: 1) do |row|
  # `row` is a length-N 1-D CAStride; slice + neighbour ops freely
  out[row.position[0], 1..-2] = (row[0..-3] + row[1..-2] + row[2..-1]) / 3.0
end
```

### Ad-hoc inject reduction

```ruby
# weighted geometric mean per column
weights = [0.2, 0.3, 0.5]
ca.reduce_slab(axis: 0, init: 1.0) do |acc, x|
  acc * (x ** weights[some_index_logic])  # user-controlled
end
```

## See also

- [`HOW_TO_WRITE_KERNEL.md`](../authoring/HOW_TO_WRITE_KERNEL.md) — the C-side
  counterpart, for cases where the `rb_yield` cost of the slab
  iterator is the bottleneck.
