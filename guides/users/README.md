# CArray User's Guide

An introduction to Ruby/CArray 3.0, written for readers new to it. No prior
knowledge of CArray 2.0 is assumed; familiarity with NumPy or Numo::NArray may
help but is not required.

The tone is plain and example-driven, introducing one topic at a time. Only
settled, confirmed methods are shown.

## How this guide is written

A few editorial principles guide these chapters. They are worth stating up front,
both to set reader expectations and to keep later revisions consistent.

- **Complete explanation, not a quick tutorial.** Each chapter aims to cover its
  topic in full for a CArray user — including reference tables of every operator,
  function, or form available, so a reader can see the whole surface in one place.
  Breadth in the chapter is deliberate; do not thin a chapter out into a "getting
  started" sketch and push the rest to a separate reference.

- **CArray is described in its own vocabulary, on its own terms.** The behaviour
  of a method is stated as CArray's behaviour — not as "the same as" or
  "following" NumPy, pandas, or Numo. CArray grew as its own system; framing it
  as a port of another library subordinates it and, because the vocabularies
  differ in subtle ways, misleads. Concretely:
  - Do **not** write that CArray "follows" or "conforms to" pandas/numpy for
    ordinary behaviour. Describe the rule directly (e.g. the time algebra of
    "instant ± duration", not "the rules follow pandas").
  - A neutral *equivalence pointer* for readers who happen to know another library
    ("equivalent to `np.concatenate`") is fine as wayfinding and need not be
    purged — but it is a signpost, not the definition.
  - Deliberate conformance to an external *standard* is different and should be
    stated plainly: the MemoryView format follows PEP 3118 because that is an
    intentional interop contract.
  - A dedicated NumPy/Numo → CArray migration table, if wanted, belongs in its
    own separate document — not woven through the teaching chapters.

## Reading order

[Introduction](introduction.md) comes first: what CArray is, and how the guide is
arranged. It carries no number, because it is front matter rather than chapter
zero — the `rake pdf:*` task names it explicitly and places it ahead of the
numbered chapters, which sort into reading order on their own.

The first eight chapters are the core walkthrough — read them in order to learn
CArray from scratch.

1. [Getting Started](00_getting_started.md)
2. [Creating arrays](01_creating_arrays.md)
3. [Indexing and slicing](02_indexing_and_slicing.md)
4. [Element-wise operations](03_elementwise.md)
5. [Reduction and statistics](04_reduction_and_statistics.md)
6. [Masks and missing values](05_masks.md)
7. [Views](06_views.md)
8. [Broadcasting](07_broadcasting.md)

## Further topics

These can be read in any order, once the core walkthrough is comfortable. Each
introduces a topic that also has its own, more thorough reference in `docs/`;
the chapters here are the example-driven entry points.

9. [Lazy evaluation](09_lazy.md) — building unevaluated expression trees and
   materialising on demand. Full reference: `docs/topics/Lazy.md`.
10. [Composition](10_composition.md) — combining arrays along existing or new
    axes (`meld`, `stack`, `montage`, `concatenate`, `mosaic`, `tabulate`).
    Full reference: `docs/topics/Composition.md`.
11. [Slab iteration](11_slab_iteration.md) — iterating per-axis with
    `each_slab` / `map_slab` / `reduce_slab`. Full reference:
    `docs/topics/SlabIterator.md`.
12. [Faces and extended data types](12_faces.md) — giving raw numbers an
    interpretation (dates, times, units), with `CATime` as the worked
    example. Chapter 26 covers the time arrays themselves in full.
    Full reference: `docs/topics/CAFace.md` and
    `docs/topics/CATime.md`.
13. [Object arrays](13_object_arrays.md) — arrays of arbitrary Ruby objects.
    Full reference: `docs/topics/CAObject.md`.
14. [Text, fixed-length strings, and records](14_text_and_fixlen.md) — the
    string-array family (`CAString`, `CAFixlenString`, `CAConstString`, raw
    `CA_FIXLEN`) side by side with construction, string operations,
    ordering, conversions, and interop; plus `CARecord`, the array of
    structs with named fields. Full reference: `docs/topics/StringArrays.md`,
    `docs/objects/CAConstString.md`, `docs/objects/CARecord.md`.
15. [MemoryView interop](15_memory_view.md) — zero-copy exchange with
    Numo::NArray, Apache Arrow, PyCall, fiddle. Full reference:
    `docs/interop/MemoryView.md`.
16. [Indexer reference](16_indexer_reference.md) — every form of `[]` and
    `[]=`, with a quick-lookup table. Companion to chapter 2.
    Full reference: `docs/topics/Indexer_decision_tree.md`.
17. [Tips and techniques](17_tips_and_techniques.md) — a cookbook of practical
    idioms drawn from across the chapters: shape reshaping, row-wise
    normalisation, conditional updates, in-place sort via view assignment,
    mask handling, anti-patterns, and more.
18. [Sort, search, and interpolation](18_sort_search_interpolation.md) —
    ordering (`sort`, `sort_index`), rank selection (`partition_index`,
    `rank_index`), search (`bsearch`, `search_nearest`), 1-D interpolation
    (`linear_section`, `linear_fetch`), and address lookup (`locate_addr`).
19. [Input and output](19_input_output.md) — Ruby `Array` interchange, the
    `CArray.save` / `CArray.load` binary format, `Marshal` for object arrays,
    and a pointer to MemoryView. Full reference:
    `docs/topics/Serialization.md`.
20. [Iterating and displaying arrays](20_iterating_and_display.md) — `each`,
    `each_index`, `each_with_index`, `map!`, and how an array prints (`inspect`
    vs. the raw-bytes `to_s`).
21. [The iterator family](21_iterator_family.md) — the map to the five
    reduction iterators (slab, window, block, categorical, group): one common
    surface, five engines, and how to choose. Full reference:
    `docs/topics/IteratorFamily.md`.
22. [Window iteration](22_window_iteration.md) — rolling / sliding statistics,
    the `bounds:` policy, and bounded `correlate` / `convolve`. Full reference:
    `docs/topics/CAWindowIterator.md`.
23. [Block iteration](23_block_iteration.md) — non-overlapping tiles for
    pooling and downsampling (`a.blocks`). This chapter is its own reference.
24. [Categories and grouping](24_categories_and_grouping.md) — the
    `CACategorical` classifier, categorical group-by (`group_by_category`), and
    axis / coordinate grouping (`value[cat, …]` with `axis: :group`). Full
    references: `docs/objects/CACategorical.md`,
    `docs/topics/CACategoricalIterator.md`,
    `docs/topics/AxisGroup.md`,
    `docs/topics/CAGroupIterator.md`.
25. [Histograms](25_histograms.md) — binning values into counts (1-D and
    joint), weighted and streaming histograms, and the discrete sibling
    `bincount_nd`. Full reference: `docs/topics/Histogram.md`.
26. [Time arrays](26_time_arrays.md) — `CATime` and `CATimedelta` in full:
    instants and durations on an integer tick grid; construction
    (`time_series`, `time_range`, `CArray.time`), resolutions (count × base,
    `to_unit`),
    unit-reconciling arithmetic, comparison and search, and the step system
    (`timesteps`, `floor` / `ceil` / `round`, `is_righttime`) for bucketing,
    calendar periods, fiscal years, and series matching. Companion to
    chapter 12, which introduces the Face mechanism itself. Full reference:
    `docs/topics/CATime.md`.
27. [The boolean data type](27_boolean_arrays.md) — the 0/1 truth type in
    full: its three representations (and the `to_a` truthiness trap),
    strict casting, logical vs. arithmetic dispatch, boolean reductions, and
    Kleene three-valued logic across masks (`skip_masked:`). Deepens the
    introduction in chapter 3. Full reference: `docs/topics/Boolean.md`.
28. [Discovery — distinct values, counts, modes, membership](28_discovery.md) —
    `unique`, `value_counts`, `nunique`, `mode` / `is_mode`, `is_in`, and
    the set operations `intersection` / `union` / `difference`. The
    value-hash discovery family (NaN-folding, mask-excluding) that sits
    beside `mask_duplicates` in chapter 5.

> Note: chapters 09–25 have grown organically and are numbered in the order
> they were written, not in a settled reading order. A pass to reorder them
> is planned once the set stabilises. (Chapters 21–25 form a natural cluster —
> read 21 first as the map, then any of 22–25.)

## Reference

* [Vocabulary](08_vocabulary.md) — CArray-specific terms (entity/view, address,
  mask/UNDEF, data_type, Face), with a NumPy/Numo correspondence table. Can be
  read first or used as a glossary.

## Out of scope

These chapters cover what a CArray user needs to know. Material aimed at C
extension authors — writing kernels (`docs/authoring/HOW_TO_WRITE_KERNEL.md`), the sweep
author surface (`docs/authoring/Sweep_Author_Surface.md`), and writing C extensions
generally (`docs/authoring/WritingCExtensions.md`) — is out of scope here. (The
user-facing MemoryView format reference is `docs/interop/MemoryViewFormat.md`, linked
from chapter 15.)
