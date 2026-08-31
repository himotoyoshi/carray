# CArray Developer's Guide

A guide to *how CArray is built* — the C internals, the view machinery, the
attach lifecycle, the kernel-author surfaces, and the build/test tooling. It is
written for people who work on CArray itself: the core maintainers, future
maintainers years from now, and authors of companion C-extension gems
(`carray-*`).

This is the **developer's** counterpart to the **user's** guide in
`guides/users/`. Where the user's guide teaches you to
*use* CArray from Ruby, this guide explains *why the Ruby surface behaves the
way it does* and *how to extend it in C*. The two overlap deliberately — a
concept introduced for users (entity/view, mask, `to_ca`/`copy`) is re-examined
here from the implementation side.

## How this fits with the other documentation trees

CArray has two documentation trees aimed at different audiences:

| Tree | Audience | Nature |
|------|----------|--------|
| `guides/users/` | Ruby users | User's guide — example-driven, settled API only |
| **`guides/devel/`** (this tree) | CArray developers & ext authors | **Developer's guide — a coherent explanation of the implementation** |

This guide distils the *settled* design into a stable, readable narrative. When
this guide and the source code disagree, trust the **code** — it is the ground
truth, verified with `git log`.

This guide and the `docs/` topic tree are **parallel sets** — this guide is the
narrative you read through, `docs/` is the topic dictionary you look things up
in. Content overlap is fine; each set stands on its own. This guide is
self-contained and does not link out to `docs/`.

## Audience and assumptions

You are assumed to be comfortable with C, the Ruby C extension API
(`rb_*` functions, `VALUE`, TypedData), and CArray *as a user* (read the user's
guide first if not). Familiarity with NumPy/Numo internals is helpful but not
required; this guide explains CArray on its own terms.

## Reading order

The guide is in five parts. Read Part I top to bottom first — everything else
builds on the data structures, memory model, mask, and attach lifecycle. After
that, the parts are independent; jump to whichever subsystem you are working on.

### Part I — Foundations
- [00 Glossary](00_glossary.md) — developer vocabulary (obj_type, dispatch
  tables, attach, slab/fiber, kernel, pool, descriptor), plus **C conventions at
  a glance** (the naming-prefix rule, `volatile VALUE`, `data_type`-not-dtype,
  `*_index`, and the C/YARD comment style). Read first or use as a lookup.
- [01 Architecture overview](01_architecture_overview.md) — the big picture:
  entity vs view, the obj_type dispatch model, the class hierarchy, and the
  `ext/` file map.
- [02 Core data structures](02_core_data_structures.md) — the `CArray` struct
  and its relatives, the `obj_type` enum, the `ca_func` / `ca_class` /
  `ca_typeddata` dispatch arrays, TypedData wiring.
- [03 Memory management](03_memory_management.md) — `xmalloc`/`xfree`, the
  CArray pool framework, GC integration, mask storage.
- [04 The attach lifecycle](04_attach_lifecycle.md) — `attach`/`sync`/`detach`,
  the R1–R4 contract, the alias fast path, compose-fold.
- [05 Mask and UNDEF](05_mask_and_undef.md) — the built-in mask that **only
  CArray has** and that **threads through all of view algebra**: mask as a child
  CArray, mask classes, propagation through views and operations, UNDEF. A
  foundation, not a subsystem — established here before Part II because every
  view carries it.

### Part II — Views
- [06 View algebra and CAStride](06_view_algebra_and_castride.md) — the CAStride
  family, pure-typedef vs prefix+tail subclasses, the strided fast paths.
- [07 The per-axis descriptor framework](07_axis_descriptor_framework.md) — the
  shared gather/scatter/fill engine behind CASelectAxis and CAGrid.
- [08 View catalog](08_view_catalog.md) — a reference entry per view type: what
  it represents, where it lives, its attach and MemoryView strategy.
- [09 Faces](09_faces.md) — extended data types layered on a numeric array via a
  runtime-installed obj_type (dates, durations, struct records). Placed here, next
  to the view catalog, because a Face *is* a kind of view/obj_type and cannot be
  explained apart from the view machinery.

### Part III — The C author surface (writing kernels)
- [10 Author surface overview](10_author_surface_overview.md) — the four entry
  points and when to use each; the design principles every ext author inherits.
- [11 The kernel iterator](11_kernel_iterator.md) — `CA_FOR_EACH_FIBER` /
  `CA_FOR_EACH_SLAB`, the state machine, levels, masks, the write path.
- [12 The mkkernel DSL](12_mkkernel_dsl.md) — generating typed kernel coverage:
  reduce/binop/monop/scan/sort/search, the `:object` branch, SIMD license.
- [12a Cast and promote](12a_cast_and_promote.md) — the five canonical
  intake/negotiation routes (`wrap_readonly`, `result_type`, binop coerce,
  `promote_list`, decide-only) built on the single-source `ca_cast_table`
  and `ca_promote_type`, the MV format-parse single point, and the
  recurring `X.to_type(peer.data_type)` truncation anti-pattern.
- [13 The sweep author surface](13_sweep_author_surface.md) — element-wise
  `xfer_all`-family macros.
- [14 call_cfunc](14_call_cfunc.md) — vectorising a scalar C function.
- [15 carray.h helper reference](15_carray_h_helper_reference.md) — the common
  helper collection and the "don't grow the vocabulary" discipline.
- [15a Common idioms](15a_common_idioms.md) — the recurring shapes the
  primitives are composed into: option parsing, axis kwarg, output
  allocation, wrap-readonly coerce, mask propagation, scalar fold-back.

### Part IV — Subsystems
- [16 Indexing and access](16_indexing_and_access.md) — `carray_access.c`, the
  indexer decision tree, which view each index form produces.
- [16a The iterator family](16a_iterator_family.md) — the `CAIterator`
  form-only base and its five engines (slab / window / block / categorical /
  group): where each engine lives (Ruby composition vs dedicated C kernels),
  the counting-sort scatter, the axis-group compute kernel, the contract
  invariants.
- [16b The `fz_hash` discovery engine](16b_fz_hash_discovery.md) — the
  one-pass value-seen-set substrate behind `unique` / `value_counts` /
  `nunique` / `mask_duplicates` / `categorize` / `is_in` / the set
  operations / `is_mode` / `mode`. Explains the three key lanes (numeric /
  object / fixlen), the NaN and signed-zero fix-ups that define the family's
  distinctness contract, and how to plug in a new discovery-shaped kernel.
- [17 Lazy evaluation](17_lazy.md) — the lazy view tree, `force`, fusion.
- [18 The MemoryView protocol](18_memory_view_protocol.md) — producer/consumer
  strategies, the format string.
- [18a Serialization](18a_serialization.md) — the `_CARRAY3` portable binary
  container (fixed 256-byte header, single-endian promise, YAML trailer) and
  the Marshal integration that rides on it.

### Part V — Build and tooling
- [19 Build, generators, and testing](19_build_generators_testing.md) — extconf,
  the code generators, `CARRAY_DEV`, the distclean rule, the test suites.

### Part VI — Cross-cutting concerns
- [20 Memory efficiency and streaming](20_memory_efficiency_and_streaming.md) —
  a tour of the optimisations that keep peak memory low: not materialising
  intermediate views (compose-fold, alias, axis-merge), slab/chunk/tile
  streaming, fused scatter kernels, single-pass discovery, and streaming I/O.

## Status and handoff

This guide is built incrementally across sessions. The table below is the
**single source of truth for what is done**. When you finish work on a chapter,
update its row. Statuses:

- **stub** — skeleton only: scope, outline, and source pointers. No prose.
- **draft** — written through once, usable, may need review/examples.
- **done** — reviewed, examples verified against a live build.

| Ch | File | Status | Notes |
|----|------|--------|-------|
| — | README.md | draft | this file |
| 00 | 00_glossary.md | draft | developer vocabulary written; extend as chapters land |
| 01 | 01_architecture_overview.md | draft | verified vs carray.h structs/enums; examples not re-run |
| 02 | 02_core_data_structures.md | draft | verified vs carray.h (struct fields, ca_operation_function_t) |
| 03 | 03_memory_management.md | draft | verified vs ca_array_pool.c primitives |
| 04 | 04_attach_lifecycle.md | draft | verified vs carray.h API + ca_update impl |
| 05 | 05_mask_and_undef.md | draft | mask surface methods verified present; Part I (foundational) |
| 06 | 06_view_algebra_and_castride.md | draft | verified vs ca_obj_stride.c fast-path ladder + CAStride.md |
| 07 | 07_axis_descriptor_framework.md | draft | verified vs ca_axis_descriptor.h + ca_axis_dispatch.c |
| 08 | 08_view_catalog.md | draft | view list vs ext/; MV col partly pending (see chapter footer) |
| 09 | 09_faces.md | draft | verified vs ca_obj_face.c + CAFace.md; Part II (a Face is a view/obj_type) |
| 10 | 10_author_surface_overview.md | draft | four-surface table + 6 principles + bench discipline |
| 11 | 11_kernel_iterator.md | draft | verified vs ca_kernel_iterator.h freeze contract + HOW_TO sum example |
| 12 | 12_mkkernel_dsl.md | draft | verified vs mkkernel.rb entry points + MkKernelDSL.md |
| 12a | 12a_cast_and_promote.md | draft | verified vs carray_core.c cast_table + carray_cast.c primitives + carray_memory_view.c format probe |
| 13 | 13_sweep_author_surface.md | draft | verified vs Sweep_Author_Surface.md families |
| 14 | 14_call_cfunc.md | draft | verified vs carray_call_cfunc.c + CallCfunc.md |
| 15 | 15_carray_h_helper_reference.md | draft | primitive signatures verified vs carray.h |
| 15a | 15a_common_idioms.md | draft | option parsing / axis kwarg / template / wrap-readonly / mask overlay / scalar fold-back |
| 16 | 16_indexing_and_access.md | draft | verified vs carray_access.c + Indexer_decision_tree.md (flagged its stale MAPPING) |
| 16a | 16a_iterator_family.md | draft | verified vs lib/carray/iterator.rb + *_iterator.rb + ca_categorical_iterator.c / ca_group_iter.c / ca_axis_group.c |
| 16b | 16b_fz_hash_discovery.md | draft | verified vs ext/carray_factorize.c (fz_hash / fz_levels + lane switches) + Ruby wrappers |
| 17 | 17_lazy.md | draft | verified vs ca_obj_*op.c + carray_lazy.c arena |
| 18 | 18_memory_view_protocol.md | draft | verified vs carray_memory_view.c strategy table |
| 18a | 18a_serialization.md | draft | verified vs lib/carray/serialize.rb (header layout, save/load, marshal_dump) |
| 19 | 19_build_generators_testing.md | draft | verified vs the build/test discipline in the source tree |
| 20 | 20_memory_efficiency_and_streaming.md | draft | cross-cutting; refs verified vs ext/ sources (compose-fold, streaming reduce, scatter kernels, tile cache, streaming I/O) |

### Conventions for writers

- **This is a C-internals document, not a user guide.** Explain *how the mechanism
  works in C* — structs, dispatch, the data path — not *how to use the feature
  from Ruby*. The tell that you have drifted: Ruby REPL examples with `# =>`
  pretty-printed output, or a catalogue of Ruby methods. Those belong in the
  user's guide (`guides/users/`). A Ruby snippet is justified only when it
  *illustrates the C mechanism* (e.g. which view class an expression builds);
  otherwise point at the user's guide and explain what that surface sits on.
- **English prose.** Source comments stay English too.
- **Verify before you write.** Every code reference (`file:line`, struct field,
  macro, primitive name) must be checked against the current source tree, which
  is the ground truth. Run a live `CARRAY_DEV=1 rake build_ext` and try Ruby
  snippets in a REPL before pinning them.
- **No gratuitous NumPy mapping** in the prose. A "coming from
  NumPy" correspondence table is fine where it genuinely helps a porter; scatter
  comparisons through the body are not.
- **Keep chapters self-contained.** This guide is a book (PDF-bound); don't
  send readers out to the `docs/` topic tree mid-chapter. Restate what you need.

### TODO — the draft → done pass

All chapters are at `draft` (written through, verified against the source tree,
but examples not yet re-run on a live build). To move a chapter to `done`, work
through the items below and update its status row.

- [ ] **Run every code example against a live build.** Build with
  `CARRAY_DEV=1 rake build_ext`, then execute each Ruby/C snippet (or its
  equivalent) and confirm it behaves as written. This is the main draft→done gate
  for all chapters.
- [ ] **ch08 — fill the MemoryView-strategy gaps.** Confirm the MV strategy
  (direct / strided / attach / reject) for the views not in
  `carray_memory_view.c`'s explicit table: CAByteSwap, CASelectAxis, CARemap,
  CARoll, CATile, CAStack, and the Faces. (See the chapter footer.)
- [ ] **ch19 — re-verify the baseline test counts.** The dev / release / rspec
  counts in the table are a snapshot; re-run `rake test` on the current tree and
  update them.
- [ ] **Re-audit for user-guide drift** once content settles: no `# =>` REPL
  output, no Ruby-method catalogues (the C-internals convention above).
- [ ] **Track the in-flight reorgs** so chapters don't go stale: the `carray.h`
  public/internal split (ch15) and the `xfer_*` protocol superseding
  `copy_data`/`sync_data` (ch02/ch04) are landing incrementally — revisit those
  chapters when they do.
- [ ] **Cross-check against the source tree** periodically: this guide already
  corrected several stale facts (CAMapping retired in R.3, the real `ca_func`
  `xfer_*` fields, `rb_carray_new` returning `VALUE`). Treat the code as ground
  truth.
