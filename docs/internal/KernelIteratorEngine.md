# The kernel iterator engine — routes and promises

The kernel iterator (`ext/ca_kernel_iterator.c`) hands a kernel the cells of a source array, a slab at a time, and on a write takes what the kernel wrote back to the array. A kernel author sees one surface whatever the source is; the engine underneath picks one of several ways of doing the job, by the kind of source and the kind of walk.

This document is for people working on carray itself. It says, without reading the engine:

- which way a given walk goes (source × walk × read/write),
- what each way keeps of the promises the surface makes, and where,
- how to check both on a development build.

If you write kernels, you do not need any of this: the author's chapter is `guides/devel/11_kernel_iterator.md` and the walkthrough is [`../authoring/HOW_TO_WRITE_KERNEL.md`](../authoring/HOW_TO_WRITE_KERNEL.md).

The description is of the engine as it stands; the route table in §4 was taken from a development build, and §8 says how to take it again.

---

## 0. The question, and how to check an answer

**The question.** For a source `v`, a walk (one of the three below) and a direction (read or write): which way does the engine deliver the cells, and who keeps each promise of §6 on that way?

The three walks a kernel can ask for:

| walk | entry | what the kernel receives |
|---|---|---|
| L1 whole | `ca_iter_state_init_l1(…, CA_SLAB_WHOLE, …)` + `next_slab` (`CA_FOR_EACH_WHOLE`) | the whole view, as one contiguous slab |
| slab axes | `init_l2(…, CA_SLAB_AXES, axes, …)` + `next_slab_axes` (`CA_FOR_EACH_SLAB`) | one slab per index of the other axes, walked with `slab_strides` |
| fiber | slab axes with one axis and `CA_KERNEL_FIBER_CONTIG` (`CA_FOR_EACH_FIBER`) | one contiguous fiber per index of the other axes |

**Checking an answer.** The `ext_iter_write` fixture of the spec suite (`spec/spec_ai/ext_iter_write/iter_write.c`) has `CArray.iw_route(v, walk, axis, write)`, which opens the walk, takes the first slab, and returns what the state holds:

```ruby
require "carray"
$LOAD_PATH.unshift "spec/spec_ai/ext_iter_write"; require "iter_write"

b = CArray.float64(3, 4, 5).seq!
CArray.iw_route(b[CA_INT64([2, 0]), nil, nil], 3, 0, false)
# => {src_kind: 2, alias_mode: 4, root: true, scratch: true, fiber_scratch: false}
#    descriptor, PER_SLAB, parent attached, slab scratch
CArray.iw_route(b[CA_INT64([2, 0]), nil, nil], 3, 0, true)
# => {src_kind: 3, alias_mode: 0, root: false, scratch: true, fiber_scratch: true}
#    the same walk as a write goes by transfer
```

`walk` is 0 = L1 whole, 2 = slab axis, 3 = fiber (4 = two slab axes, the given one and the last). The numbers are the `CA_ITER_SRC_*` and `CA_ITER_ALIAS_*` constants of `ext/ca_kernel_iterator.h`.

---

## 1. One walk is three layers

A walk is decided in three layers, each with its own choices:

| layer | choices | decided in |
|---|---|---|
| **data** — where the slabs are cut from | the source's own memory (`CONTIG`), the root's memory through composed strides (`STRIDED`), a scratch the view was gathered into (`NONE`), or a way of its own (`PER_SLAB`, `PER_FIBER_FUSED`, `STACK`, …) | init, recorded as `alias_mode` |
| **fiber** — how a slab reaches the kernel | as it lies, or gathered into a contiguous run (`CA_KERNEL_FIBER_CONTIG` with a strided fiber) | init (flags and axis) and `next_slab_axes` |
| **write-back** — how written cells reach the array | nothing to do (the kernel wrote into the array), changed cells sent back through the view, the axis dispatch scatter into the parent, or a per-fiber transfer | `sync_slab`, keyed on `alias_mode` and then `src_kind` |

**The route is fixed at init.** `alias_mode` and `src_kind` are assigned only in `init_l1` / `init_l2`; no later call changes them. What varies per slab is the position, never the way.

**The layers stack.** A fiber gathered into a contiguous run sits on top of whatever the data layer is: on a transfer walk the fiber is gathered out of the walk's scratch, and on a write it is scattered back into the scratch before the changed cells go to the source. Reading and writing can also use different machinery on the same walk: a descriptor slab is gathered by the descriptor engine and written back by `ca_axis_dispatch_scatter`.

Most of the engine's length is the init branches that assemble these combinations (§3). Most of its past faults were a combination that kept one promise of §6 differently from the others (§7).

---

## 2. Classification

`ca_iter_classify_source` sorts a source into a `src_kind`, in this order:

1. entity → `SRC_CASTRIDE`; CAStride family (refer, block, transpose, farray, repeat, field, stride) → `SRC_CASTRIDE`
2. a kind registered from outside (`ca_iter_register_source_kind`, only `SRC_ATTACH` can be registered)
3. CASelectAxis, CAGrid, CASelect, CAWindow and CAShift → `SRC_DESCRIPTOR`
4. the conversion views (fake, byte swap, bitfield, bitarray), CAReduce, CAObject, tile, roll, CAStack, CAMeld, CARemap, the five lazy views → `SRC_ATTACH`
5. **anything else with an attach slot** → `SRC_ATTACH`; no attach slot → refused

A Face and a lazy marker are stripped before classification: the walk is over what they wrap.

`ca_iter_route_source` refines a descriptor view, and **both init_l1 and init_l2 route through it**:

- a grid with holes → `SRC_ATTACH` (its holes are delivered by its own transfers)
- a descriptor view whose parent has no memory to lend at this moment (`! parent->ptr && ca_parent_lends_no_memory(parent)`: a conversion view, a lazy view, a CAObject) → `SRC_ATTACH`, so the view asks its parent for the selected cells alone, and a write goes back through the view's own transfer
- otherwise the descriptors are taken (`describe_axes`), and the view is `SRC_DESCRIPTOR_L2_ALIASABLE` when its innermost axis is a plain stride (the L2 walk can then lend the parent's memory), `SRC_DESCRIPTOR` otherwise

On a development build run with `CARRAY_GENERAL_PATH=2`, the classifier returns `SRC_ATTACH` for every source (§5).

---

## 3. The routes

### 3.1 The transfer walk (`SRC_ATTACH`, `alias_mode = NONE`)

`ki_open_by_transfer`: the whole view is gathered into the walk's scratch with `ca_xfer_all(src, scratch, GET)`, its mask likewise. The kernel works in the scratch. On a write, `ki_scratch_push_changed` compares the scratch with the copy kept of what was gathered and sends back only the changed cells (`ca_xfer_addrs` PUT, or `ca_xfer_all` PUT when every cell changed).

Every promise this walk keeps is kept by the view's own transfer — what a cell is, which root cell a write lands on, how a conversion goes back — so the walk itself holds none. That is why it is the reference (§5), and why it is where a source the engine knows nothing more about goes.

The slab-axes form of the same walk gathers the whole view the same way and walks the scratch with row-major strides; a single fiber of a conversion view along its innermost axis instead takes `PER_FIBER_FUSED` (§3.4).

### 3.2 The central axis: entity and CAStride (`SRC_CASTRIDE`)

The source's cells are reached by a pointer and strides:

| case | `alias_mode` | buffer the slabs are cut from |
|---|---|---|
| entity, or a contiguous CAStride view | `CONTIG` | the source's own memory |
| a non-contiguous CAStride view, L2 | `STRIDED` | the root's memory, through strides composed up the chain (`ca_stride_compose_to_root`); the root is attached and recorded in `st->root` |
| a non-contiguous CAStride view, L1 | `NONE` | a scratch gathered with `ca_copy_data` (the same composition) |
| the root lends no memory (`ca_root_lends_no_memory`: a CAObject, a lazy view) | `NONE` | a scratch gathered with the view's region transfer, so only the cells the view covers are asked for |

A write on `CONTIG` / `STRIDED` lands in the borrowed memory; when the root is a view with a buffer of its own, `finish` writes that buffer back with `ca_sync_detach`. A write on the `NONE` cases goes back with `ki_scratch_push_changed`.

### 3.3 Descriptor views (`SRC_DESCRIPTOR`, `SRC_DESCRIPTOR_L2_ALIASABLE`)

The parent is attached (`st->root`) and the descriptor engine (`ca_axis_dispatch_*`) reads it axis by axis: STRIDE, INDEX and SHIFT axes.

| walk | case | `alias_mode` |
|---|---|---|
| L1 whole | any | `NONE`: the view gathered into scratch by `ca_axis_dispatch_gather` |
| slab axes | all slab axes STRIDE, no outer SHIFT | `STRIDED` over the parent |
| slab axes | an outer axis is SHIFT, or a SHIFT slab axis that leaves the innermost axis out | `NONE`: the whole view gathered, then walked with row-major strides |
| slab axes, read | a slab axis is INDEX or SHIFT (other than the above) | `PER_SLAB`: one slab gathered at a time; `PER_SLAB_HOIST` when the innermost slab axis is a stride and no axis is SHIFT (a slab of two or more axes) |
| slab axes, **write** | a slab axis is INDEX or SHIFT | **the transfer walk** (§3.1): the per-slab gather reads only |
| fiber | CAWindow / CAShift whose innermost axis is SHIFT | `PER_FIBER_FUSED` (§3.4); with SHIFT on outer axes only, see §7.5 |

A write on these routes is scattered back into the attached parent (`ca_axis_dispatch_scatter`), and `finish` closes the parent with `ca_sync_detach`. **The write-back here is kept by the parent's attach and sync**, not by a transfer; see §7.2.

### 3.4 Shortcuts

| `alias_mode` | taken when | what it does | layers it handles |
|---|---|---|---|
| `PER_FIBER_FUSED` | one contiguous fiber of a fake or byte-swap view (or a single-cast lazy monop) along its innermost axis; one fiber of a CAWindow / CAShift whose innermost axis is SHIFT | each fiber is fetched with `ca_xfer_stride` GET into the fiber scratch, and on a write put back with `ca_xfer_stride` PUT | data, fiber, write-back — all three per fiber, through the view's region transfer |
| `PER_SLAB` / `PER_SLAB_HOIST` | §3.3 | one slab gathered from the parent per index of the outer axes | data; the fiber layer sits on top |
| `STACK` | a CAStack, read, unmasked, one slab axis that is the stack axis | the K parents are attached and read directly through a tile cache | data and fiber |
| `STACK_OUTER_K` | a CAStack, read, the stack axis among the outer axes | the slab is cut from the parent the outer index picks; the parents' masks are copied | data; fiber on top |

Each tests `ca_fast_paths_enabled()`, so `CARRAY_GENERAL_PATH=1` sends them to the general route of their `src_kind`. A write never takes `STACK` or `STACK_OUTER_K`: init declines them and the walk goes by transfer.

Every shortcut in the engine carries a name tag in a comment beside its code: the layer it handles, what it speeds up, the measured reason, when it is taken, the promises of §6 it keeps, the switch, and the rows of the matrix that check it. `grep -n "Shortcut " ext/ca_kernel_iterator.c` lists them:

| name | layer | measured against its general route | checked by |
|---|---|---|---|
| `KEEP_SCRATCH` | data (where a scratch comes from) | no difference on macOS; Linux unmeasured | `test_iter_ractor_scratch.rb`, the buffer count |
| `PUSH_ALL_CHANGED` | write-back | about 5% | the matrix, whole writes |
| `PER_FIBER_FUSED` (CAWindow / CAShift) | all three, per fiber | about 8% slower | the matrix, fiber rows of the shift view |
| `SHIFT_WHOLE_VIEW` | data | about 1.5x | the matrix, slab-axis rows of the shift and window views |
| `PER_SLAB_HOIST` | data | no difference | the matrix, two-slab-axes rows of the grid parent |
| `STACK` | data and fiber | about 2x | the matrix, stack parent along axis 0 |
| `STACK_OUTER_K` | data | about 11x | the matrix, stack parent along axes 1 and 2 |
| `PER_FIBER_FUSED` (conversion views) | all three, per fiber | no difference | the matrix, fiber rows of the fake parent |
| `PROTECT_ONLY_MAY_RAISE` | exits | about 1.5x | `test_iter_raise_cleanup.rb`, the detectors' raise rows |

---

## 4. The route table

Taken with `iw_route` (§0) on `b = CArray.float64(3, 4, 5).seq!`. R = read, W = write; `+g` = the fiber was gathered into the fiber scratch (it is not contiguous where it lies). Where read and write agree only one is given.

| source | L1 whole | slab axis | fiber |
|---|---|---|---|
| `b`, `b[1..2, nil, nil]`, `b.reshape(12, 5)` | CONTIG | CONTIG | CONTIG (`+g` off the last axis) |
| `b[nil, 1..2, 1..3]`, `b.transpose` | CAStride `NONE` (copy) | STRIDED | STRIDED (`+g` where not contiguous) |
| `b[CA_INT64([2, 0]), nil, nil]` (grid, INDEX on axis 0) | descriptor `NONE` | axis 0: R `PER_SLAB`, W transfer; others: STRIDED | as slab axis |
| `b[nil, nil, CA_INT64([4, 0, 2])]` (grid, INDEX innermost) | descriptor `NONE` | axis 2: R `PER_SLAB`, W transfer; others: STRIDED | as slab axis |
| `b[CA_BOOLEAN([1, 0, 1]), nil, nil]` (select axis) | descriptor `NONE` | STRIDED | STRIDED |
| `b.window(0..1, 1..3, 2..4)` (in bounds) | descriptor `NONE` | STRIDED | STRIDED |
| `b.shift(1, 0, 0)`, `b.window(-1..1, nil, nil)` (SHIFT on axis 0) | descriptor `NONE` | axis 0: R `NONE` (whole view), W transfer; others: `NONE` | as slab axis |
| `b.shift(0, 0, 1)` (SHIFT innermost) | descriptor `NONE` | axes 0, 1: `NONE` (outer SHIFT); axis 2: R `PER_SLAB`, W transfer | `PER_FIBER_FUSED` on every axis |
| `b.swap_bytes`, `b.roll(1, 0, 0)`, `b.tile(1, 2, 1)`, CAMeld | transfer | transfer | transfer |
| `CArray.int32(3,4,5).fake(:float64)` | transfer | transfer | axis 2: `PER_FIBER_FUSED`; others: transfer |
| `CArray.stack(…)` over three slices | transfer | axis 0: R `STACK`; axes 1, 2: R `STACK_OUTER_K`; W transfer | as slab axis |
| a grid over a fake | transfer | transfer | transfer |
| `b.lazy * 2` | transfer | transfer | transfer (W refused: read-only) |

---

## 5. The transfer walk as the reference

A development build run with `CARRAY_GENERAL_PATH=2` switches the fast paths off (as `1` does) and makes the classifier return `SRC_ATTACH` for every source, so every walk is the transfer walk of §3.1. `CArray.__iter_by_transfer_only__` says which run a test is in; `rake spec_ai_transfer` runs the suite that way. `rake spec_ai`, `spec_ai_general` and `spec_ai_transfer` together compare every route with its general route and with the transfer walk.

`spec/spec_ai/test_iter_delivery_matrix.rb` is the test the three runs are meant to compare: parents (entity, transpose, block, stepped block, reshape, grid, fake, swap, stack, meld, roll) × views × masked or not × the walks, read and write. It checks the cells and mask flags the kernel received against the view's `copy`, and a write against a store of the same values through the same view.

The direction matters for the reference. On a read it is a plain `ca_xfer_all` GET. On a write it is GET, the kernel, then **only the changed cells** PUT — not a plain PUT, which on a view that shows the same root cell twice would let the position the kernel did not write overwrite the one it did.

**What the reference cannot check** is any promise that does not show in the values: closing what was opened on every exit, creating nothing on a read walk, keeping produced Ruby values visible to the GC, asking a lazily backed source only for the cells the view covers. Each of those has a detector of its own, run over the same cases as the delivery matrix in `spec/spec_ai/test_iter_delivery_detectors.rb` (§6, the right column):

- **nothing left open**: around every walk, a normal end and a raise in the body opened inside `ca_iter_ensure`, the number of attached views (`CArray.__attached_views__`) and of buffers the iterator took with `ki_data_alloc` and has not given back (`CArray.__iter_buffers__`) are the same before and after. Both counts exist in a development build only. A malloc-zone sweep per parent (macOS) catches what the two counts do not see, such as mask copies taken with `xmalloc`, but only when it is large enough to stand above a few kilobytes of noise per sweep.
- **nothing created by a read**: the source and every array it reads through (`parent`, `parents`) have the same masks and values before and after a read walk.
- **values kept alive**: sources that make a fresh Ruby value per cell (a lazy expression over objects, a CAObject) are walked under `GC.stress`, and the cells received are compared with the copy.
- **partial requests**: views over a CAObject root that records every bulk request are walked, and a view that covers only part of the root must not ask for the whole of it (`copy_data`).

Each detector was checked by breaking the engine on purpose: a CAStack parent not detached, its tile cache not freed, a CAStack read creating a parent's mask, the object scratch not held for the GC, and the redirect of a descriptor view over a parent that lends no memory removed. Each break fails its detector; the last fails the partial-request detector and the GC detector both, because without the redirect such a view is gathered from the attached parent, whose buffer the walk does not hold for the GC.

Tests that assert the route itself (an `alias_mode`, the number of slabs a walk yields, that `row.dup` in `each_slab` shows the row of its iteration) are skipped in the `2` run; they are true of the routes, not of the surface.

---

## 6. The promises, and who keeps them

| # | promise | kept by | detector |
|---|---|---|---|
| 1 | a fiber (`CA_KERNEL_FIBER_CONTIG`) reaches the kernel as a contiguous run of cells and of mask flags | the part `ki_fiber_contig_data` / `ki_fiber_contig_mask`, called on every slab-axes route; `PER_FIBER_FUSED` fetches each fiber into the fiber scratch; `STACK` cuts its slab contiguous | the matrix (fiber walk) |
| 2 | the mask cursor handed out is a copy, never a live mask | written per route: every route gathers the mask into `scratch_mask` (or the fiber mask scratch); `STACK_OUTER_K` copies the parents' masks | `test_iter_write_back.rb` (a mask written through a read walk reaches nothing) |
| 3 | a write lands on the cells that were gathered, and only the changed ones are sent | alias routes: the kernel writes in place; transfer and CAStride scratch: the part `ki_scratch_push_changed`; descriptor routes: `ca_axis_dispatch_scatter` + the parent's `ca_sync_detach`; gathered fiber: `ca_stride_scatter_run` back to `alias_ptr + last_data_off`; `PER_FIBER_FUSED`: `ca_xfer_stride` PUT | the matrix (write) |
| 4 | what a walk opened is closed on every exit: init failure, a raise in the kernel, a raise in a gather or write-back | init clears the state before it can return; `ca_iter_ensure` for the kernel's raise; `CA_ITER_FLAG_WALK_MAY_RAISE` puts the walks that can raise under `rb_protect`; `finish` frees field by field | `test_iter_delivery_detectors.rb` (attached views, iterator buffers, malloc zone), `test_iter_raise_cleanup.rb`, `attach_balance.rb` |
| 5 | an input sharing its root with the destination is read from a copy made before the write | paired walks: `CA_ITER_FLAG_OWNS_SRC` + `ca_iter_reopen_on_copy`; two walks opened separately: the header's contract (the read side copies) | overlap tests |
| 6 | a read walk creates nothing on the source or its parents, masks included | written per route: masks are gathered only when `ca_has_mask` | `test_iter_delivery_detectors.rb`, the stack / meld mask tests |
| 7 | Ruby values produced while gathering (CAObject, lazy object arrays) stay visible to the GC until the walk ends | the object scratch is held for the walk | `test_iter_delivery_detectors.rb` and `test_lazy_object_gc.rb` (`GC.stress`) |
| 8 | a slab may be handed out as a window onto the source only when the walk reads the source's own memory | in the engine, only `CONTIG` / `STRIDED` lend memory; `each_slab` (`ext/carray_slab.c`) makes a window only when `st->t1->alias_ptr == src->ptr` | `test_each_slab.rb` in the `2` run |
| 9 | **a kernel addresses its output by the walk's buffer, not by the array's pointer**: a fresh output is laid out row-major and so is any scratch the walk cuts it from, so an output slab's offset from `st_out.alias_ptr` is its offset in the output | the scan and rank kernels `ext/mkkernel.rb` emits, the gap-fill hold (`ext/carray_hold.c`) — they write the output's mask by that offset | the `2` run (with `co->ptr` instead, the mask lands elsewhere) |

Promises 1, 3 (partly), 4, 5 and 7 are parts called from every route. 2, 6 and 8 are written out route by route; that is where a new route can quietly differ.

---

## 7. Failure shapes

### 7.1 A shortcut that does not know a promise

Most past faults were a route added for speed that kept a promise the general route keeps, but by its own code, and missed it: fibers delivered contiguous only by the general route, a stack route handing out a parent's live mask, a meld route assuming every parent is present. The cure has been the same each time: put the promise in a part and call it from the shortcut, and add the shortcut's row to the matrix.

### 7.2 A route whose promise is kept by someone else

The descriptor routes keep promise 3 through the attached parent: the scatter writes into the parent's buffer and `ca_sync_detach` takes it home. When the parent is a conversion view, its sync skips the cells masked in the array, so a write of a masked cell through a selection of a fake was lost. This is why a descriptor view over a parent that lends no memory goes by transfer (`ca_iter_route_source`), and why both L1 and L2 must route through it.

A parent that is a view with a buffer of its own attached at the time of the walk is not redirected (the test is `! parent->ptr`); its write-back is then its sync. Nothing in the library leaves such a parent attached across a walk outside the development-only `attach!`.

### 7.3 A consumer that assumes a route

Code outside the engine that reads the state — `each_slab` deciding whether the slab can be a window, a kernel computing an output address — must ask the state (promises 8 and 9), not assume the route the source "usually" takes. On the transfer walk an entity is not walked in place.

### 7.4 A route refused where it could be delivered

A request the engine can deliver by transfer is not refused. A write through a slab of a descriptor view with an INDEX or SHIFT slab axis was refused with `CA_ITER_ERR_FLAGS` because the per-slab gather reads only; it now takes the transfer walk. Refusal is for what cannot be delivered at all: a write into a read-only view, a masked source for a kernel that declared `CA_KERNEL_NO_MASK`, a policy or axis that does not exist.

### 7.5 Recorded while writing this document

Found by reading the engine against the route table; left as they are.

- **`PER_FIBER_FUSED` is not taken for a CAWindow / CAShift with SHIFT on outer axes only.** The hook that chooses it accepts `SRC_DESCRIPTOR`, but such a view arrives as `SRC_DESCRIPTOR_L2_ALIASABLE` (its innermost axis is a stride); the step that turns an outer SHIFT back into `SRC_DESCRIPTOR` comes after the hook. The fiber walk then gathers the whole view. The answers are the same; the shortcut does not run in the case it was written for.
- **`PER_SLAB_HOIST` needs a slab of two or more axes** (an INDEX axis plus a stride innermost). The delivery matrix walks one slab axis at a time, so it does not reach this route.
- **The descriptor routes' write-back belongs to the parent's sync** (§7.2): a parent that is a view holding an attached buffer at the time of the walk is not redirected to the transfer walk.

---

## 8. Adding a route

A route added for speed:

1. tests `ca_fast_paths_enabled()`, so `CARRAY_GENERAL_PATH=1` and `2` take the general route and the transfer walk instead;
2. keeps the promises of §6 by calling the parts where they exist, and says in a comment which of the written-out ones it keeps and how;
3. has rows in `test_iter_delivery_matrix.rb` that take it (check with `iw_route`);
4. has a measured reason: how much slower the source is on the route it would otherwise take.

To retake the route table of §4, run `iw_route` over the sources listed there for every walk, axis and direction.

---

## See also

- `guides/devel/11_kernel_iterator.md` — the author's chapter: the surface and its contract
- [`../authoring/HOW_TO_WRITE_KERNEL.md`](../authoring/HOW_TO_WRITE_KERNEL.md)
- `ext/ca_kernel_iterator.h` — the state struct and the frozen surface
- `guides/devel/19_build_generators_testing.md` — `CARRAY_GENERAL_PATH` and the three runs
