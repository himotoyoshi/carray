# 20 Memory efficiency and streaming

This chapter is a cross-cutting tour of the places where CArray works hard to
*keep peak memory low* — by not materialising intermediate views, by processing
data one slab/chunk/tile at a time, by fusing passes so no scratch array is
built, and by streaming I/O instead of buffering a whole copy. The individual
mechanisms are documented in their home chapters (the kernel iterator in ch11,
the mkkernel DSL in ch12, compose-fold in ch04/ch06, the lazy arena in ch17);
what this chapter adds is the *throughline*: how a maintainer should reason
about the memory cost of a data path, and the inventory of optimisations that
share the "don't hold the whole thing" discipline.

It is a companion to ch03 (Memory management), which covers *allocation*
(`xmalloc`/`xfree`, the pool framework, GC). This chapter covers the layer
above: given that allocation is cheap and GC-managed, *how do the data paths
avoid asking for a large buffer in the first place*.

## The tension: "deliver the materials" vs. "don't materialise the whole thing"

Two design principles pull against each other in CArray, and the memory-efficiency
work lives in the space between them.

- **Deliver the materials.**
  A kernel author writes kernel logic and trusts that the data arrives, whatever
  view sits underneath. When a view can't be aliased, the engine will
  *materialise* it rather than reject the call.
- **Keep peak memory low.** A full materialise of a large view is exactly the
  allocation the user hoped a view would avoid.

The resolution is that materialise is a *fallback of last resort, and when it
happens it is bounded*: the engine prefers, in order, (1) aliasing the root with
no copy, (2) streaming the view slab-by-slab or chunk-by-chunk so only one small
piece is resident, (3) a fused single pass that never builds the scratch array,
and only then (4) a whole-view materialise. Most of this chapter is the first
three tiers.

Peak memory is treated as a first-class figure of merit, sometimes *ahead of*
throughput: under the CAStack "refuse-materialise" stance, holding a large
stacked source resident is considered worse than being somewhat slower.

## 1. Not materialising the view at all

The cheapest buffer is the one never allocated. The view machinery has several
paths that hand a kernel the data with zero (or O(1)) extra memory.

### Alias fast path — O(1) attach, no copy

When a CAStride-family view is fully contiguous row-major, `attach` does not
malloc-and-copy: it points `ca->ptr` straight at `parent->ptr + base_offset` and
the write path lands directly in parent memory (sync is a no-op, detach does not
free). `reshape` and row slices ride this path. See ch04 (attach lifecycle) and
ch06 (CAStride); the ladder lives in `ext/ca_obj_stride.c`.

### Compose-fold — attach only the root of a view chain

A chain like `entity → CARefer → CABlock → leaf` would, naively, attach and
materialise each intermediate view. Compose-fold instead walks the chain
composing stride coordinates one hop at a time and attaches **only the root
entity** (or the nearest non-foldable ancestor), so intermediate views never
materialise. The hybrid walk (`ext/ca_obj_stride.c:300` onward,
`ca_fold_t`) handles two kinds of participant: always-fold CAStride typedefs
(identity compose-fold) and *sometimes-fold* views that implement the
`fold_stride` operation slot (CAWindow today; CAGrid/CSA/CATile are candidates)
and either compose into the next parent's space or decline, marking the fold
boundary. This is what makes `view.copy` / `view.dump_binary` on a deep chain
cost one root attach instead of N materialises. The kernel iterator uses the same
composition for its L2 strided sources (`ext/ca_kernel_iterator.c`, the
`ca_stride_compose_to_root` path).

Compose-fold also shows up in the sub-byte views: `CABitarray` / `CABitfield`
drive `ca_bit_pack` / `ca_bit_unpack` directly against the effective attached
parent found through identity compose-fold, bypassing the `addrs[]` allocation
the generic scatter path would make (`ext/ca_obj_bitarray.c:408` onward). Only a
cold parent (no live ptr, e.g. a bitarray over a CAFake chain) falls back to a
scratch two-pass.

### Axis-merge — fewer axes, less book-keeping

Adjacent contiguous-mergeable axes are collapsed into one before a transfer or a
descriptor dispatch, so the per-element odometer walks fewer axes and per-element
overhead drops (fill_data went from per-element to contig-run, ~14× on the
measured case). CAStride does this in `ca_stride_merge_axes`; the descriptor
engine mirrors it in `ca_axis_dispatch_merge` (`ext/ca_axis_dispatch.c`). This
does not lower peak memory by itself, but it is what lets a merged view drop into
the contiguous fast paths above instead of a strided materialise. See ch06/ch07.

## 2. Slab-by-slab streaming: the kernel iterator

The kernel iterator (ch11) is the backbone of streaming in CArray. Rather than
handing a kernel the whole array, it yields one **slab** (or **fiber**) at a
time: the outer prefix axes drive an iteration loop, and the kernel sees only the
current slab. Scratch buffers are sized to the *maximum slab*, not the whole
array, and reused across iterations. `CA_FOR_EACH_SLAB` / `CA_FOR_EACH_FIBER`
(and their `_INOUT_MASKED` variants) are the author-facing surface; the state
machine that refills each slab lives in `ext/ca_kernel_iterator.c`
(`next_slab_axes`).

The engine's per-source dispatch decides, for each view kind, whether the current
slab can be aliased (parent.ptr + composed offset, zero materialise) or must be
gathered into a slab-sized scratch. The comments at the top of
`ext/ca_kernel_iterator.c` (SRC_* classification) enumerate this per view; the
important property for this chapter is that even the gather cases are bounded to
slab size, never the whole view.

## 3. Chunked and tiled reductions

Reductions are where large intermediates are most tempting (a partial-sum buffer,
a materialised lazy operand). Three mechanisms keep them small; all are generated
by the mkkernel `reduce` DSL (ch12).

### Streaming chunked reduce over a lazy view

When a full reduction runs over an unmasked lazy view (`a.lazy op b` etc.),
`emit_reduce_streaming` (`ext/mkkernel.rb:2321`) pulls the view in fixed-size
chunks via `ca_xfer_stride` instead of materialising it whole through
SRC_ATTACH. It chunks along the outermost axis with an L1d-friendly element
budget (4096 elements, ~32 KB for f64) and accumulates a running scalar. Peak
memory drops from O(N) to O(max(chunk, inner)): the comment gives the headline
figure — a 1000×10000 f64 reduction goes from ~80 MB of materialised operand to
~80 KB of chunk. The chunk buffer comes from the lazy arena (below). It
short-circuits to the whole-view path for the cases it can't stream (an `axis:`
partial reduction, a non-lazy source, or a masked source).

### Loop-interchange with L1-resident tiles

For a single-axis reduction along a *non-innermost* axis of a contiguous view,
`emit_reduce_loop_interchange` (`ext/mkkernel.rb:1695`) swaps the loop order so
the inner loop walks the contiguous axis, and tiles the output into L1d-friendly
chunks (`TILE = 512` cells = 4 KiB per accumulator buffer, stack-allocated). The
rows read are streaming — each iteration reads a fresh contiguous row — and the
output accumulators stay in L1 regardless of how wide the reduced axis is.

### The lazy arena — amortised scratch, not per-call malloc

The chunk buffers and lazy-operand scratch don't come from fresh `xmalloc`s per
call. `ca_lazy_arena` (`ext/carray_lazy.c:256`) is a 32-slot pool of reusable
buffers: `acquire`/`release` toggles an in-use flag rather than freeing, so a
deep CABinOp chain holds stable pointers across nested acquires, and warm slots
are reused on subsequent `to_ca` calls. Best-fit allocation keeps small requests
(mask scratch) out of large data slots. The trade-off is a resident footprint
(up to 32 × max slab bytes), and exhaustion *raises* rather than degrading —
treated as a programming error, per the single-thread contract. This is the
allocation substrate the streaming reduce sits on.

## 4. Fused scatter kernels — no intermediate index array

A histogram or a group-by is, naively, "compute an index per sample into a
temporary array, then scatter". The fused kernels skip the temporary entirely by
reading each sample, computing its destination, and accumulating in a single
pass.

- **`histogram_scatter_ki`** (`ext/carray_histogram.c:187`) reads each sample
  through the kernel iterator (strided, so channel views over a joint sample
  array are *not* materialised — only the small constant `edges` is attached),
  computes the extended bin index inline, and does `counts[off] += weight`. Peak
  memory is the output counts, not any per-sample index buffer. Its comment calls
  this "peak-memory minimal".
- **`bincount_nd_count_ki`** (`ext/carray_histogram.c:359`) is the discrete
  sibling: integer labels read without coercion, fused label→bin→accumulate.
- **`__categorical_scatter__`** (`ext/ca_categorical_iterator.c`) lays a flat
  payload out as a category-contiguous copy in one pass using a per-category
  write cursor (a mutable copy of the segment starts). No permutation array is
  built; O(n) and stable. It keeps the codes mask (authoritative for exclusion)
  and the value mask (propagated into the grouped output) distinct.
- **The axis-group composite-code walk** (`ext/ca_axis_group.c`) folds each slab
  element into whichever accumulator buffers are non-NULL, accumulating in
  `double` while only the *load* is monomorphised per dtype — so it avoids a
  forced float64 materialise of the (large) source. The per-element composite
  code / offsets are precomputed once (O(group_prod) metadata) and reused across
  bands, keeping peak memory O(output + group_prod), not O(input).

The reduction-dispatcher iterators reinforce this by refusing a materialise path
altogether: `CAGroupIterator` holds the source value plus the spec and exposes
only reductions — it has no `to_ca` / `copy` (`ext/ca_group_iter.c:127`), so a
group-by never produces a large intermediate grouped array unless the user asks
for one.

## 5. Bounded gather caches — CAStack K-axis tile cache

Reducing a CAStack along its stacked axis (`stack.mean(axis: k_axis)`) can't be
aliased — the K parents live in separate buffers. Instead of materialising the
whole stacked view, the engine (`ext/ca_kernel_iterator.c:1264` onward) attaches
the K parents up front (O(1) each for entities), caches their `ptr` aliases and
uniform byte strides, and allocates a **tile cache** sized to the L1d budget. It
refills TILE fibers per K contiguous parent reads and serves the following calls
from the L1-resident cache. Peak buffer is `K × TILE × bytes` (e.g. 12 × 512 × 8
≈ 49 KB), not `K × parent.elements`. There is no size-threshold gate — an earlier
design's threshold was a perf trade-off the tile cache erased.

## 6. Single-pass discovery — the factorize hash

`uniq` / `mask_duplicates` / categorical discovery over integer payloads use one
open-addressing hash (`fz_hash`, `ext/carray_factorize.c:45`) driven by a single
kernel-iterator pass that interns each widened 64-bit key to a first-appearance
code. This replaces the older sort-based approach (sort addresses + gathered copy
+ boolean scan), whose scratch buffers were O(n). Peak memory is O(distinct
values) for the hash table plus the output code/level arrays — no sort buffer, no
gathered copy. The file header (`ext/carray_factorize.c:3`) documents that both
discovery problems share the one hash and the one pass. (The object/fixlen path
still falls back to a Ruby `Hash` seen-set; extending `fz_hash` to object keys is
a pinned future item.)

## 7. Streaming I/O — no whole-copy buffer

Binary serialisation avoids doubling memory through a Ruby String.

- **`dump_binary`** to a file (`ext/carray_conversion.c:320`): for an *entity* it
  writes `ca->ptr` straight through `rb_io_bufwrite`, so peak stays at the array
  size instead of doubling via an intermediate String. (A *view* still
  materialises once into a scratch buffer, because there is no chunked gather API
  for the general view case — a bounded, acknowledged fallback.)
- **`load_binary`** from an IO (`ext/carray_conversion.c:402`): for an entity it
  reads straight into the owned `ca->ptr` in **64 KiB chunks**, so peak is
  `ca_length + 64 KiB` rather than `2 × ca_length`. A view target buffers the
  full read and recurses, because `ca_sync_data` scatters in one pass.
- The **`_CARRAY3`** container (`lib/carray/serialize.rb`) puts the payload at a
  fixed 256-byte header offset with the descriptive metadata in a YAML trailer
  *after* the data, so the writer never has to buffer the whole file to backfill
  a header. See [ch. 18a](18a_serialization.md).

### `attach!` — one materialise, N zero-copy operations, one sync

`attach!` (`ext/carray_core.c:1935`) is the block form that lets user code
amortise a single materialise across many operations: materialise a view once,
do N zero-copy reads/writes against the resident buffer inside the block, then
sync-and-detach once (guaranteed via `rb_ensure`). The canonical use is chunked
I/O into a slice — one gather, N cheap I/O calls, one scatter — instead of N
independent attach/detach round-trips. This is a library-author lifecycle tool,
not a user-facing surface.

## 8. Small elisions worth knowing

- **Broadcast scalar fill** skips the wasted gather: filling a whole array (or a
  masked region) from a scalar `memset`s / broadcasts rather than building and
  scattering a full-length source (`ext/ca_obj_array.c` fill_data;
  `ext/carray_mask.c:484`). The user just writes `a[mask] = v`.
- **Cheap mask scans** short-circuit: "is anything masked" / "is all masked" over
  an alias-attachable contiguous mask uses an O(1) attach plus a word-level bit
  scan with early exit, and a block loop for virtual masks — neither
  materialises the mask (`ext/carray_mask.c`).

## Inventory at a glance

| Mechanism | Where | What it saves |
|---|---|---|
| Alias fast path | `ca_obj_stride.c` | O(1) attach, no copy for contiguous views |
| Compose-fold | `ca_obj_stride.c:300`, `ca_kernel_iterator.c` | attaches only the root of a view chain |
| Sub-byte compose-fold | `ca_obj_bitarray.c:408` | bypasses the `addrs[]` allocation |
| Axis-merge | `ca_axis_dispatch.c`, `ca_stride_merge_axes` | fewer axes → drops into contig fast paths |
| Slab/fiber streaming | `ca_kernel_iterator.c` | scratch = one slab, not the whole array |
| Streaming chunked reduce | `mkkernel.rb:2321` | lazy reduce peak O(chunk), not O(N) |
| Loop-interchange tiles | `mkkernel.rb:1695` | L1-resident output tiles, streaming rows |
| Lazy arena | `carray_lazy.c:256` | reused scratch pool, not per-call malloc |
| `histogram_scatter_ki` | `carray_histogram.c:187` | no per-sample index array |
| `bincount_nd_count_ki` | `carray_histogram.c:359` | fused discrete count |
| `__categorical_scatter__` | `ca_categorical_iterator.c` | one-pass group layout, no permutation array |
| Axis-group walk | `ca_axis_group.c` | peak O(output + group_prod), no float64 source materialise |
| CAStack K-axis tile cache | `ca_kernel_iterator.c:1264` | K×TILE buffer, not K×parent.elements |
| `fz_hash` single pass | `carray_factorize.c:45` | O(distinct), no sort/gather scratch |
| `dump_binary` (entity→file) | `carray_conversion.c:320` | no doubling via a String |
| `load_binary` (entity) | `carray_conversion.c:402` | 64 KiB chunked read into `ca->ptr` |
| `attach!` | `carray_core.c:1935` | 1 materialise + N zero-copy ops + 1 sync |
| Broadcast scalar fill | `ca_obj_array.c`, `carray_mask.c:484` | no full-length source built |
| Cheap mask scan | `carray_mask.c` | word-level scan, mask not materialised |

## Related chapters and design docs

- ch03 Memory management — allocation, the pool framework, GC.
- ch04 Attach lifecycle — alias fast path, compose-fold contract.
- ch06 View algebra and CAStride — the fold walk and the strided fast paths.
- ch11 Kernel iterator — slab/fiber streaming, SRC_* classification.
- ch12 mkkernel DSL — where the streaming/loop-interchange reduce paths are emitted.
- ch17 Lazy — the lazy view tree and the arena.
