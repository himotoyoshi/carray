# 16a — The iterator family

CArray 3.0 ships a family of **reduction iterators** that all answer the same
question — *"fold each piece of the array to a value"* — while differing in
what a *piece* is. From the Ruby side they present one uniform surface
(`sum` / `mean` / `median` / `each` / `reduce` / …); underneath, each member
supplies its own engine, and those engines are implemented in strikingly
different ways: two are thin Ruby dispatchers over core reductions, one is a
Ruby dispatcher over dedicated C scatter kernels, and one is a C-defined class
whose hot path never leaves C. This chapter explains the family model, where
each engine lives, and the design invariants a new member must keep.

Do not confuse this family with the **kernel iterator** of ch. 11. The kernel
iterator (`CA_FOR_EACH_SLAB` and friends) is the *C author surface* — the
mechanism a C kernel uses to receive slabs of any view. The iterator family is
the *Ruby user surface* — objects a Ruby program holds and calls reductions
on. Several family engines are themselves *built on* the kernel iterator (the
axis-group compute kernel pins its slab axes with `CA_FOR_EACH_SLAB`), which
is exactly the intended layering.

## 16a.1 One surface, five engines

| member | a *piece* is… | built by | output shape | engine lives in |
|---|---|---|---|---|
| `CASlabIterator` | a fiber/slab along the marked axes | `a[nil, :>]` (indexer) | outer shape | Ruby sugar over `each_slab` / `map_slab` / `reduce_slab` (`lib/carray/slab_iterator.rb`) |
| `CAWindowIterator` | an overlapping window per anchor | `a.windows(-1..1)` | reference-shaped (rolling) | Ruby: padded entity + `sliding_windows` strided view + core reduction (`lib/carray/window_iterator.rb`) |
| `CABlockIterator` | a non-overlapping tile | `a.blocks(3, 3)` | ceil tile grid | Ruby: block_view decomposition + core reduction (`lib/carray/block_iterator.rb`) |
| `CACategoricalIterator` | the cells of one category | `value.group_by_category(cat)` | length-`k` | Ruby dispatch (`lib/carray/categorical_iterator.rb`) over C kernels (`ext/ca_categorical_iterator.c`) |
| `CAGroupIterator` | a coordinate-classified group | `value[cat, nil, …]` | `[K, band…]` slot order | C class (`ext/ca_group_iter.c`) + C compute kernel (`ext/ca_axis_group.c`) + Ruby metadata (`lib/carray/axis_group.rb`) |

Two structural facts explain most of the table:

- **The partition members (slab / block / categorical / group) assign every
  cell to exactly one piece.** That is what makes a per-cell running scan
  (`cumsum` …), a scatter-back `map`, and a per-piece `sort_addr` well-defined
  for them. The window's pieces overlap and its margin cells are padding with
  no source address, so those operations are structurally impossible there and
  the window member overrides them to raise with a reason.
- **Every named reduction is the corresponding core `CArray` reduction lifted
  to the piece.** The iterator adds no numeric semantics of its own: dtype
  promotion, mask handling, the empty/all-masked contract (identity for
  `sum`/`prod`/`count`, UNDEF for ratios and extrema), and the ε-close
  floating-point contract are all the core's, unchanged. An engine that
  cannot delegate to a core reduction (the fused C kernels below) must
  reproduce that contract exactly — this is the family's central invariant.

## 16a.2 The form-only base: `CAIterator`

`CAIterator` is deliberately **form-only**: it carries no engine, no state
machine, no generic dispatch. The class object is created in C
(`ext/ruby_carray.c`):

```c
rb_cCAIterator = rb_define_class("CAIterator", rb_cObject);
```

because two C-side consumers need the constant to exist before any Ruby file
loads: `carray_access.c` constructs `CASlabIterator` by name when the indexer
meets a `:>` sigil, and `Init_ca_group_iter()` subclasses it for
`CAGroupIterator`. Everything else about the base is plain Ruby
(`lib/carray/iterator.rb`):

- `attr_reader :ndim, :shape` (with `dim` as the legacy alias) over ivars
  each member sets in its own `initialize`.
- The **required surface** — tier-1/2 reductions, position (`min_index` /
  `max_index` / `min_addr` / `max_addr`), weighted (`wsum` / `wmean`), order
  statistics (`median` / `percentile` / `quantile`), the count family, and
  generic iteration (`each` / `reduce`) — declared as abstract stubs that
  raise `NotImplementedError, "<class> must implement #<name>"`. A member
  that leaves one unimplemented fails **loudly at the gap**, rather than
  reading as "no such method".
- A **recommended surface** (`map`, `sort_addr`, and the per-cell scans
  `cumsum` / `cumprod` / `cummax` / `cummin` / `cumcount`) declared as
  template methods that raise "does not provide (optional)". These are
  well-defined for the partition members and structurally impossible for the
  window, so they are not required; a member implements each when it is
  well-defined and overrides it to raise with its own reason when not.

There is deliberately **no `include Enumerable`**. Enumerable would leak
reduction-shaped names (`min`, `sum`, `count`, `to_a`, …) built on `each`,
which would silently fold the pieces the wrong way — e.g. Enumerable's `min`
would compare whole piece CArrays with `<=>` instead of computing a per-piece
minimum. With an explicit surface, a method a member does not provide is a
clean error, never a wrong answer. This is the same "loud failure over silent
wrongness" stance the mask machinery takes.

### The retired 2.0 model

CArray 2.x had a very different `CAIterator`: a C struct carrying
`kernel_at_addr` / `kernel_at_index` function-pointer slots, with C-defined
`CADimensionIterator` / `CABlockIterator` / window engines
(`ext/ca_iter_dimension.c` / `ca_iter_block.c` / `ca_iter_window.c`) whose
kernels advanced by *mutating the underlying view's tail in place* (e.g.
rewriting a CABlock's `start[]` and resyncing the prefix). That generic
dispatch engine is **retired**; the sources are preserved at
`samples/caiterator/` for reference. The 3.0 members reuse the 2.0 *names*
(`CAWindowIterator`, `CABlockIterator`) because the concepts — a window, a
tile — are stable, but they are new implementations on new engines. When you
read old material describing CAIterator as a C dispatch struct, that is the
2.0 model.

## 16a.3 CASlabIterator — sugar over the slab methods

The lightest member. The C indexer dispatch in `carray_access.c` classifies
an index containing the `:>` sigil as an ITERATOR index: the `:>` positions
are recorded as `slab_axes`, the index is re-run with those positions as full
ranges (producing the *reference* view), and the result is wrapped by name:

```c
klass = rb_const_get(rb_cObject, rb_intern("CASlabIterator"));
```

The Ruby class (`lib/carray/slab_iterator.rb`, autoloaded on first use) holds
`@reference` and `@slab_axes`, computes the outer shape from the non-slab
axes, and delegates everything to the slab-method trio:

- `each` → `reference.each_slab(axis: slab_axes)`
- `map` → `reference.map_slab(...)`
- `reduce` → `reference.reduce_slab(...)`
- named reductions → the core per-axis reduction with `axis: slab_axes`
  (which is why their contracts are trivially the core's); the order
  statistics fall back to a `reduce_slab` per-slab fold where the core
  per-axis form does not apply.

`kernel_at_index(idx)` builds the slab view at one outer index by filling an
index array with `nil` at slab positions and the outer coordinates elsewhere
— a plain `[]` call, no special machinery.

## 16a.4 CAWindowIterator — padded entity + strided view + one core pass

The rolling member replaced a per-anchor 2.0 C engine with a decomposition
into three existing primitives, each already fast:

1. **Build a padded entity once.** The source is copied into the interior of
   a larger buffer; the margin cells are filled according to the `bounds:`
   policy chosen at construction — `:skip` (UNDEF margin, the default),
   `:nearest` (edge replication), or a constant `fill_value:`. With
   `:truncate` no padding is built at all.
2. **Take its `sliding_windows` view** — a pure strided view (a CAStride)
   over the padded buffer whose trailing axes are the window offsets. No
   data moves; overlap costs nothing because the windows are aliases into
   the same buffer.
3. **Run one core reduction over the trailing window axes.** The output is
   reference-shaped (or shrunk to `N_i - w_i + 1` per axis for `:truncate`).

One vectorised pass, and every contract is inherited: with `:skip` the margin
is UNDEF, so the core's mask skipping makes an edge window fold only its
in-bounds cells, and the core's `min_count:` / `fill_value:` kwargs — passed
straight through — express the whole strictness spectrum ("fold whatever is
present" up to "full windows only, edges filled") with no window-specific
knob. Order statistics need an unmasked margin, so under `:skip` they raise
with guidance to use `:nearest` or `:truncate`.

`correlate(kernel)` / `convolve(kernel)` are member-specific: a bounded
cross-correlation/convolution expressed as a multiply of the window view by
the (flipped, for convolve) kernel plus a sum over the window axes — again
composition, not a dedicated engine.

`map`, the scans, and `sort_addr` raise here: a cell belongs to many windows,
so no single running value or scatter-back target exists.

## 16a.5 CABlockIterator — block_view decomposition

The pooling member also composes existing primitives, but differently,
because tiles do not overlap:

1. The source splits into an **interior region** (every axis truncated to a
   size-divisible extent) plus **2ᵐ − 1 boundary regions**, where *m* is the
   number of axes whose length is not a multiple of the tile size.
2. Each region is a `block_view` — a CAStride reshaping the region into
   `(tile-grid axes…, tile axes…)`, zero-copy over the source via
   compose-fold. No padded entity is built (unlike the window member); the
   interior stays on the source buffer.
3. Each region is reduced by one core reduction over the trailing tile axes
   and scattered into its rectangle of the ceil-shaped tile grid.

So a 2-D source with both axes ragged costs four core reductions (interior,
right edge, bottom edge, corner) — a constant number independent of N.

There is deliberately **no boundary-policy knob**: the sole behaviour is full
coverage (every cell belongs to a tile; edge tiles fold whatever is present).
A partial edge tile carries fewer real cells, so the core's `min_count:`
naturally marks it UNDEF when it is not full, and "valid pooling" (drop the
remainder) is expressed explicitly by slicing first: `a[0...q*b].blocks(b)`.
This is the explicit-over-implicit stance applied to pooling.

## 16a.6 CACategoricalIterator — counting-sort scatter + segment kernels

The per-category member is where the family first needs dedicated C kernels,
because a category's members are scattered arbitrarily through the source:
order statistics (median / percentile) cannot be computed from streaming
accumulators — every value of a group must be held together. The engine
therefore materialises **one category-contiguous grouped copy** and runs
segment reductions over it.

### The grouping plan cache on CACategorical

The plan — `sort_addr` (a counting sort over the codes), `reduceat_index`
(the segment start offsets), `category_sizes` — depends **only on the codes**,
which are read-only (the codes parent carries `CA_FLAG_READ_ONLY`, which is
what licenses the memoisation). So the plan is cached on the *categorical*,
built on first grouping access and shared by every payload column: a wide
aggregate (many value columns grouped by the same categorical) pays the
counting sort once. Only the plan is cached; the payload-dependent grouped
copy is rebuilt per column. `build_grouping` force-builds the plan ahead of a
batch; lazy building already covers correctness.

### `__categorical_scatter__` — the single-pass grouped copy

`ext/ca_categorical_iterator.c` implements the gather as a **counting-sort
scatter**: a mutable copy of the segment starts serves as a per-category
write cursor, and one ascending pass over the flat payload does

```c
pos = cur[code]++;
memcpy(grouped + pos*bytes, value + j*bytes, bytes);
```

O(n), stable (the ascending scan keeps each category's members in source
order), and no permutation array is ever built. It is the discrete,
value-carrying sibling of the histogram scatter kernel: where the histogram
scatters a `+1` into counts, this scatters the payload cell itself. Codes
dispatch on their native integer type; the value move is a bytes-wide
`memcpy`, so no value-dtype dispatch is needed.

Two masks meet here and are kept distinct:

- the **codes mask is authoritative for exclusion** — a masked code cell
  joins no group (its code value is never read);
- the **value mask propagates** into the grouped copy, so a group with a
  masked payload cell reduces exactly as the core does (the cell is skipped
  by mask-aware reductions).

The output position is data-dependent (`cursor[code]++`), which the aligned
kernel-iterator macros do not model — so this kernel materialises its flat
inputs itself (`ca_attach` aliases a contiguous entity and gathers a view),
one of the legitimate uses of attach in a kernel.

### Segment reductions and the per-fiber axis kernels

Over the grouped copy, the `__reduceat_*__` private kernels fold each
`[offset[c], offset[c+1])` segment: fused moments (count/sum/min/max in one
pass), percentile (select within the held segment), variance, prod,
argmin/argmax, all/any. Each group result equals `CArray#<reduction>` over
that group's members — the contract invariant again — and results are
length-`k` CArrays aligned to `cat.labels`, with undefined slots as MASKED
cells, never magic floats.

Since 2026-07 the iterator also answers **per-fiber axis reductions**
(`grp.mean(axis: k)` on an N-D payload) through a second kernel set,
`__fiber_scatter_moments__` / `__fiber_scatter_prod__` /
`__fiber_scatter_wsum_wmean__`: a per-fiber scatter-add over broadcast codes,
one pass, no counting sort. The fused moments result is memoised per
`(iterator, axis)` in `@axis_moments_cache`, so `count` / `sum` / `min` /
`max` / `mean` off one axis share a single kernel call. The variance family
along an axis is composed in Ruby (per-code mask + the core's per-axis
variance), inheriting the core's centred two-pass numerics.

## 16a.7 CAGroupIterator — the C member

The axis-group member classifies a grid array *by its axis coordinates* and
is the one family member whose class itself is defined in C
(`ext/ca_group_iter.c`), because its construction sits on the `[]` hot path.
The split of responsibilities is deliberate:

- **`ext/ca_group_iter.c`** — the `[]` **type gate** (recognising a
  CACategorical / AxisGroup among index arguments and routing to the group
  path instead of ordinary selection), CAGroupIterator construction, and the
  `axis: :group` reduce driving.
- **`lib/carray/axis_group.rb`** — the value-independent metadata:
  `AxisGroup` (the spec built by `value.axis_group(cat, nil, …)`, a shape
  template only — one spec serves many arrays), `GroupLabels` (a lazy
  factorised label view), reduce-plan assembly and output-axis permutation.
  Plain O(ndim) metadata, off the hot path, so Ruby is the right place.
- **`ext/ca_axis_group.c`** — the O(N) compute kernel
  `__axis_group_reduce__` (and `__axis_group_scan__`), taking pre-built code
  bundles so it is independent of how the classifier was constructed.

A registration handshake keeps the hot path free: `lib/carray/axis_group.rb`
calls `CArray.__register_axis_group_classes__(CACategorical, AxisGroup)` at
load time, storing the class objects in C statics (GC-registered). Until the
classes are loaded the statics are `Qnil` and the `[]` type-gate scan
short-circuits — a normal index pays **nothing** (not even a `kind_of?`) for
the feature's existence.

### The compute kernel

`__axis_group_reduce__` is a showcase of the kernel iterator used from
inside the library:

- `CA_FOR_EACH_SLAB` pins the **union of grouped source axes** as the slab
  and walks the band (non-grouped) axes in the outer iteration. Because the
  outer iteration advances row-major over the complement axes in ascending
  source order, the slab-emission counter *is* the band flat index of the
  `[K, band…]` output — no index arithmetic needed.
- For each slab element a **composite group code** is computed on the fly
  from the per-bundle code tables (a rank-N categorical is one bundle
  consuming several source axes). The composite code is **never
  materialised** — it is a per-element local. Peak memory is the output plus
  per-group accumulators, O(K·band), never O(N).
- The accumulate is a sort-free scatter: `out[composite*band + b] op= v`.
  Codes outside `[0, k)` at any bundle mark the element unassigned (it
  contributes to no group), mirroring digitize's out-of-bounds handling.

Because a group preserves source order, a *within-group* index is weak; the
group member exposes the flat **source address** of a winner (`min_addr` /
`max_addr`) instead of `min_index` / `max_index` — the `_addr` vs `_index`
split at work (an `_addr` indexes back into the original array; an `_index`
is a position within a piece). Its scans take `axis: :group`, and `cumcount`
is the running member ordinal within each group.

### Why the group member takes `axis: :group`

The other four members bind their piece structure at construction, so their
reductions take no axis. The group member is built by the *same* indexer
that performs plain selection — `value[cat, nil]` must remain a valid
selection when `cat` is an ordinary array — so the grouping is engaged at
the reduction call (`.mean(axis: :group)`), not at construction. This is the
one asymmetry in the family's calling convention, and it is forced by the
indexer's dual role.

## 16a.8 Invariants for a new family member

A new member (or a companion gem adding one) must keep:

1. **Subclass `CAIterator` and set `@ndim` / `@shape`.** The base's abstract
   stubs then define your remaining obligations loudly.
2. **Implement the required surface; override the optional surface to raise
   with a reason when structurally impossible.** Never let an unimplemented
   reduction fall through to something that silently folds wrong — that is
   the entire point of the no-Enumerable design.
3. **Delegate to core reductions wherever possible.** Every contract you
   care about (dtype, mask, empty/all-masked, ε-close) then comes for free.
   Write a dedicated C kernel only when the piece layout makes delegation
   impossible (data-dependent scatter, held segments for order statistics) —
   and then reproduce the core contract exactly, pinned by tests.
4. **Respect the `_index` / `_addr` split**: `*_index` is a position within
   a piece; `*_addr` is a flat address into the original array. Provide
   whichever is meaningful for your piece structure.
5. **Keep construction off the hot path** unless it must be there. Ruby +
   autoload is the default (window/block/categorical); C-side class
   construction and a registration handshake are justified only when the
   builder sits inside `[]` (slab, group).
6. **Cache only value-independent plans, and only on read-only carriers.**
   The categorical's grouping-plan cache is sound because the codes are
   read-only; a plan keyed on mutable payload would go silently stale.
