# Introduction

Ruby/CArray is an extension library that adds a multi-dimensional numerical
array class to Ruby. The name says what the class is: a Ruby wrapper around a
numerical array of the kind C works with. Values are held as binary data in one
block of memory and worked on collectively, which is what makes CArray suited to
numerical computation and data analysis.

## One data type, many dimensions

An array holds values of a single, uniform data type — fixed-width integers (8,
16, 32 or 64 bits), floating-point numbers (32 or 64 bits), complex numbers (64
or 128 bits), fixed-length strings, or Ruby objects. Every element is the same
size, and they sit next to each other in memory.

An array also has a shape: the number of axes it has, and the length of each.
The same values can be presented as one long run, as rows and columns, or as a
stack of blocks, and CArray gives you an index per axis to reach them.

## Working on the whole array at once

Arithmetic and the elementary mathematical functions apply element by element to
a whole array, and reductions — sums, means, extremes, and the other statistics
— summarise it, either entirely or along the axes you name. Because the values
are of one type and lie together in memory, this work happens in C, not in a
Ruby loop over each element.

## Referring to data: views

CArray offers many ways of referring to the data in an array: addressing,
slicing, selecting by a condition, mapping addresses, gathering on a grid,
transposing, shifting, rolling, converting the data type, reshaping. Each of
these produces a **view**.

A view holds no data of its own. It refers to another array and fetches values
from it as they are needed — when you read an element, take a copy, or compute
with it. View classes are subclasses of CArray, so a view is used exactly as an
array is; and storing into a view reaches the array it refers to, so a write
through a slice changes the original. Views can refer to views, in chains of
mixed kinds, so that a slice of a transpose of a reshape stays a view all the
way down.

Nothing is copied until you ask, with `copy`, for an array of your own.

## Missing values are part of the array

Any array — a view included — can carry a mask that marks individual elements as
undefined. The mask is not a value written into the data, so it costs the data
no representable number: arithmetic carries the mask through to its result, and
statistics leave the marked elements out of the calculation rather than letting
them contaminate it.

## Arrays you define yourself

You can add an array class of your own, one that computes or fetches its values
however you like while presenting the full CArray interface. In Ruby, subclass
`CAObject` and implement a few template methods; in C, subclass `CAView`. What
you define is used like any other array, and views can be built on it.

## How this guide is arranged

The guide is written to be read in order, each chapter assuming the ones before
it:

* [Getting started](00_getting_started.md) — installing CArray, making a first
  array, and a short tour of what the rest of the guide covers
* [Creating arrays](01_creating_arrays.md) — the constructors, the data types,
  and the ways of filling an array with values
* [Indexing and slicing](02_indexing_and_slicing.md) — reading and writing
  elements, rows, columns and sub-blocks, and selecting by a condition
* [Element-wise operations](03_elementwise.md) — arithmetic, comparison, and the
  mathematical functions applied to every element
* [Reduction and statistics](04_reduction_and_statistics.md) — summaries over
  the whole array or along the axes you choose
* [Masks and missing values](05_masks.md) — marking elements as undefined, and
  how arithmetic and statistics then treat them
* [Views](06_views.md) — reshaping, transposing and slicing without copying, and
  what a write through a view reaches
* [Broadcasting](07_broadcasting.md) — combining arrays whose shapes differ

CArray is larger than these chapters, and the guide is being written alongside
the 3.0.x releases; further chapters join this list as they settle.
