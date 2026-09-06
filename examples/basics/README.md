# Basics

The core vocabulary: how you make an array, how you get at its elements, and
how you say a value is missing. Everything else in CArray assumes these three.

Unlike the [gallery](../gallery/), these are **fragments**. A script here does
not finish a job — it shows one part of the API, prints the result, and moves
on to the next form. Each line of output is written next to the code that
produced it, so you can read a file without running it.

The numbers are a reading order, not a chapter count. Three files is the whole
set: it stops where the essentials stop.

## Running

```sh
ruby -Iext -Ilib examples/basics/01_creation.rb
```

With CArray installed as a gem, drop the `-I` flags.

## The files

### `01_creation.rb` — making an array

The constructor is a class method named for the data type
(`CArray.float64(3)`), and takes one integer per axis. Then the ways to put
values in it: a generator block called once per cell, `seq` for an arithmetic
progression, `span` for evenly spaced values across a range, `random` for
uniform samples, and `Array#to_ca` / `CA_DOUBLE(...)` to convert from Ruby.

### `02_indexing.rb` — getting at elements

One integer per axis for a single element (negative indices count from the
end, as in Ruby). `nil` for a whole axis and a Range for part of one. A
comparison yields a boolean array, which can itself be used as an index.
Assignment through any of those forms. Finishes with `shape` / `ndim` /
`elements`.

The full set of index forms is larger than this; see
[Indexer_decision_tree.md](../../docs/topics/Indexer_decision_tree.md) when
you need one that is not here.

### `03_mask.rb` — missing values

Any array, entity or view, can mark individual cells as missing. Assigning
`UNDEF` sets a mask; `has_mask?` and `is_masked` inspect it. The part worth
reading closely is what the rest of the library then does with it:
**reductions skip masked cells** rather than poisoning the result the way NaN
would, and **arithmetic carries the mask through**. Ends with the ways to put
a mask on or take it off — `mask_eq`, `strip_mask`, and the canonical in-place
form `a[condition] = UNDEF`.

## Alongside the User's Guide

Each script names its counterpart at the top. The guide explains; the script
is the same material as code you can run.

| script | chapter |
|---|---|
| `01_creation.rb` | [Creating arrays](../../guides/users/01_creating_arrays.md) |
| `02_indexing.rb` | [Indexing and slicing](../../guides/users/02_indexing_and_slicing.md) |
| `03_mask.rb` | [Masks and missing values](../../guides/users/05_masks.md) |

The guide goes on to element-wise operations, reduction, views, and
broadcasting. For those, read it — or read the [gallery](../gallery/), where
they turn up in working programs.
