# samples/caiterator

Reference implementations of `CAIterator` subclasses, preserved as
educational examples.

## `dimension.c` — CADimensionIterator

`CADimensionIterator` was CArray's original indexer-driven iterator: an
index such as `ca[:_, nil]` (axis 0 walked, axis 1 the kernel) produced one,
and `.each` yielded each sub-array.

**It was retired from the gem in 3.0.** Its capability is fully
subsumed by `CASlabIterator`, reached through the new `:>` slab-axis sigil:

```ruby
# 3.0 and later (CASlabIterator):
ca[nil, :>].each { |row| ... }       # = ca.each_slab(axis: 1)
ca[:>, nil].each { |col| ... }       # = ca.each_slab(axis: 0)
ca[2..5, :>, :>].each { |slab| ... } # = ca[2..5,nil,nil].each_slab(axis: [-2,-1])
```

Note the **role reversal**: the old `:_` marked the *outer* (walked) axis;
the new `:>` marks the *slab* (kernel) axis handed to the block. See the
proposal's migration guide.

## `window.c` — CAWindowIterator (the 2.0 C engine)

`CAWindowIterator` walked a `CAWindow` kernel over a reference array: each
step relocated the kernel's `start[]` to the next anchor cell and resynced
its embed descriptor (`ca_window_recompute_embed`), so `.each` yielded a
boundary-aware window per cell.

**It was retired from the gem in 3.0** and replaced by a Ruby
`CAWindowIterator < CAIterator` (`lib/carray/window_iterator.rb`). The
per-anchor C walk was
speed-non-critical; the 3.0 member instead builds a padded entity once and
runs a single vectorized core reduction over a `sliding_windows` view, which
is much faster for the rolling reductions / bounded convolution people
actually want. `window.c` remains a worked example of a moving-kernel
iterator (relocating `start[]` + resyncing the descriptor each step).

## `block.c` — CABlockIterator (the 2.0 C engine)

`CABlockIterator` walked a `CABlock` kernel over a reference array in
non-overlapping tiles: each step relocated the kernel's `start[]` to the next
tile origin and resynced its prefix (`ca_block_sync_base_offset`), so `.each`
yielded a tile per step.

**It was retired from the gem in 3.0** and replaced by a Ruby
`CABlockIterator < CAIterator` (`lib/carray/block_iterator.rb`). The 3.0
member instead splits the
source into an interior region plus boundary regions, takes a `block_view`
(a zero-copy CAStride) of each, and runs a single core reduction over the
trailing tile axes. `block.c` was the last C iterator on the 2.0 base
dispatch — its 3.0 rewrite is what opened the base cleanup described below.

## Why keep the source?

`dimension.c`, `window.c` and `block.c` are compact, self-contained examples of
how to implement a `CAIterator` subclass against CArray's C internals:

- the iterator struct layout (prefix matching `CAIterator` + a kernel
  pointer),
- the four `kernel_at_addr` / `kernel_at_index` / `kernel_move_to_*`
  callbacks,
- `TypedData` wiring (`dmark` / `dfree` / `dsize`) with a parent typeddata,
- `initialize_copy` and the allocator.

If you want to build a custom iterator view over CArray data, these are the
smallest worked examples.

## `iterator.rb` / `iterator.c` — the CAIterator 2.0 base dispatch

Snapshots of `lib/carray/iterator.rb` and `ext/carray_iterator.c` preserving the
**2.0 base dispatch surface**: the `define_calculate_method` /
`define_filter_method` / `define_evaluate_method` DSL (Ruby) that generated
`sum` / `mean` / `sort` / `axes!` / … on `CAIterator` by delegating to the C
dispatchers `rb_ca_iter_calculate` / `_filter` / `_evaluate` (C), which drove
the `kernel_at_addr` / `kernel_move_to_*` callbacks a C iterator subclass wired
up, over the `CAIterator` C struct (a kernel dispatch slot).

**This was removed in the 3.0 base cleanup.** Once the last C iterator
(`CABlockIterator`) became a Ruby family member, the dispatch had no consumers:
`CAIterator` is now a form-only base (the shared `ndim` / `shape` accessors plus
the abstract common reduction contract, in the live `lib/carray/iterator.rb`),
and each member implements its own engine. These two files are the reference
for what the cleanup removed.

## `class_iterator.rb` — CAClassIterator

`CAClassIterator` (via `CArray#classes`) was the original classification
iterator: it built a table of the addresses matching each value of a sorted
unique classifier and yielded a per-class kernel. It was a consumer of the 2.0
base dispatch (`build_table` + `kernel_at_addr`).

**It was retired from the gem in 3.0**, superseded by `CACategoricalIterator`
(`lib/carray/categorical_iterator.rb`), which classifies via an explicit
`CACategorical` and reduces per group without the per-class address tables.

## Building

The C files use CArray ext internals (`carray.h`, `caiterator_data_type`,
`ca_block_*` / `ca_window_*`, `CAIndexInfo`, …) that the 3.0 base cleanup
removed, so they no longer compile against the current tree unchanged. They are
**not a standalone gem** — kept here as readable references for the retired 2.0
iterator design, not as packaged add-ons.
