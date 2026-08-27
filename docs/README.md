# Ruby/CArray Documentation

This directory holds the user- and author-facing documentation for
Ruby/CArray. Each page is tagged by its **nature**, so you can tell at
a glance whether it is something to read through, something to look up,
or something you only need when writing C:

| Tag | Nature | Read it when… |
|---|---|---|
| **Overview** | Orientation / concepts | you are new, or want the mental model |
| **Guide** | How to use a feature from Ruby | you want to *do* something |
| **Reference** | Look-up material (enumerations, format strings, decision trees) | you need an exact rule or table |
| **C author** | For writing C extensions and kernels | you are building a gem on top of CArray in C |

New here? Start with [WhatIsCArray](WhatIsCArray.md), then skim the
[indexer reference](topics/Indexer_decision_tree.md).

---

## Start here — orientation

| Doc | Tag | What it is |
|---|---|---|
| [WhatIsCArray](WhatIsCArray.md) | Overview | What Ruby/CArray is and the shape of its object model |

## Core usage

Indexing and building arrays — the everyday operations.

| Doc | Tag | What it is |
|---|---|---|
| [Indexer decision tree](topics/Indexer_decision_tree.md) | Reference | Every kind of `[]` index key and how it is classified |
| [Element access (`elem_*`)](topics/ElementAccess.md) | Guide | Per-cell fast path for tight scalar loops — a lighter `ca[i, j]` |
| [Conditional selection](topics/ConditionalSelection.md) | Guide | `then_else` / `replace_where` / `conditional` / `CArray.select` — pick per cell |
| [Composition](topics/Composition.md) | Guide | Assembling arrays into one (`bind` / `merge` / `join` / stack) |
| [gather_nd / put_nd](topics/GatherNd.md) | Guide | N-D positional gather/scatter (stacked or per-axis coordinates) |

## Data types and views

Storage types, semantic-identity views, and the derived-view kinds a
CArray can present.

| Doc | Tag | What it is |
|---|---|---|
| [CAFace](topics/CAFace.md) | Overview + Guide | Semantic identity views (a date, an angle, a unit) over plain storage |
| [FaceOrderingSearch](authoring/FaceOrderingSearch.md) | Reference | The `ORDERABLE` / `COMPARABLE` gate that governs sort/search on Faces |
| [CATime](topics/CATime.md) | Guide | `CATime` / `CATimedelta` — dates and durations |
| [CACategorical](objects/CACategorical.md) | Guide | Categorical data type — dense codes plus a label vocabulary |
| [CAConstString](objects/CAConstString.md) | Guide | Read-only variable-length string columns |
| [StringArrays](topics/StringArrays.md) | Guide | Fixed-length string arrays |
| [CARecord](objects/CARecord.md) | Guide | Array of structs (fixlen record view) |
| [CAObject](topics/CAObject.md) | Guide | Defining a CArray in Ruby with a per-cell callback |
| [CABitarray](objects/CABitarray.md) | Guide | Per-bit boolean view of an array |
| [CAFarray](objects/CAFarray.md) | Guide | Column-major (Fortran-order) view |
| [CAStack](objects/CAStack.md) | Guide | Outer-axis stack view of K uniform parents (`stack` / `meld` / `montage`) |
| [Lazy](topics/Lazy.md) | Guide | Lazy element-wise views — `.lazy` / `CArray.lazy` / `CArray.fuse` |
| [CAFrame](topics/CAFrame.md) | Guide (provisional) | A lightweight DataFrame over named CArray columns |

## Iterators and reductions

One reduction surface — *fold each piece to a value* — with several
engines that differ in what a *piece* is.

| Doc | Tag | What it is |
|---|---|---|
| [IteratorFamily](topics/IteratorFamily.md) | Overview | The whole family: one surface, five engines |
| [SlabIterator](topics/SlabIterator.md) | Guide | Per-axis Ruby block surface (`each_slab` / `map_slab` / `reduce_slab`) |
| [CAWindowIterator](topics/CAWindowIterator.md) | Guide | Rolling reductions and bounded convolution (`windows`) |
| [CABlockIterator](topics/CABlockIterator.md) | Guide | Non-overlapping tile reductions and pooling (`blocks`) |
| [CACategoricalIterator](topics/CACategoricalIterator.md) | Guide | Per-category reduction (`group_by_category`) |
| [CAGroupIterator](topics/CAGroupIterator.md) | Guide | Group a grid by its axis coordinates |
| [AxisGroup](topics/AxisGroup.md) | Overview + Guide | Axis-group reduction: grouping a grid by its coordinates |

## Features

Self-contained operations you reach for by name.

| Doc | Tag | What it is |
|---|---|---|
| [Histogram](topics/Histogram.md) | Guide | Histograms and N-D bincount |
| [Scatter and Bincount](topics/ScatterAndBincount.md) | Guide | `scatter_*!` primitives and `bincount` / `bincount_nd` with applications |
| [MaskDuplicates](topics/MaskDuplicates.md) | Guide | `mask_duplicates` — mark duplicates while keeping the shape |
| [LinearInterpolation](topics/LinearInterpolation.md) | Guide | `linear_section` and `linear_fetch` |
| [Serialization](topics/Serialization.md) | Reference | Serialize / deserialize via the `_CARRAY3` binary format |

## Interoperability

Zero-copy exchange with other array libraries.

| Doc | Tag | What it is |
|---|---|---|
| [MemoryView](interop/MemoryView.md) | Guide | MemoryView interop — importing and exporting buffers (canonical) |
| [MemoryViewFormat](interop/MemoryViewFormat.md) | Reference | Format-string contract (PEP 3118, strict at the top level) |
| [InteropWithArrow](interop/InteropWithArrow.md) | Guide | Interoperating with Apache Arrow |

## Writing C extensions

For gem authors building on CArray in C — accepting, producing, and
computing over CArray, and writing kernels on its universal dispatch
surface.

| Doc | Tag | What it is |
|---|---|---|
| [WritingCExtensions](authoring/WritingCExtensions.md) | C author | The whole picture: the struct, views, masks, boundary coercion, MemoryView, packaging |
| [HOW_TO_WRITE_KERNEL](authoring/HOW_TO_WRITE_KERNEL.md) | C author | Writing a kernel on the `kernel_iterator` surface |
| [MkKernelDSL](authoring/MkKernelDSL.md) | C author | The mkkernel DSL — generating kernel coverage over the standard data types |
| [CallCfunc](authoring/CallCfunc.md) | C author | The `call_cfunc` surface — vectorizing a scalar C function |
| [Sweep_Author_Surface](authoring/Sweep_Author_Surface.md) | C author | Element-wise macros built on `xfer_all` |

---

## Subdirectories

Topic docs are filed by kind:

- [`objects/`](objects/) — individual view / data type classes worth documenting.
- [`authoring/`](authoring/) — the C-extension author surface.
- [`interop/`](interop/) — exchange with other array libraries and formats.
- [`internal/`](internal/) — internal-structure references.
- [`topics/`](topics/) — everything else, as a flat topic dictionary.

The read-through **guide books** live outside `docs/`, in
[`../guides/`](../guides/): `devel/` (Developer's Guide) and `users/`
(User's Guide), plus `pdf/` for their bundled editions (`rake pdf:all`).

## Notes

- `interop/MEMORYVIEW_FORMAT.md` is a historical record from the v1.x phase and
  is **superseded** by [MemoryViewFormat](interop/MemoryViewFormat.md); it is
  kept only for provenance.
