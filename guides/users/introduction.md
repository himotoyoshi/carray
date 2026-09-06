# Introduction

Ruby/CArray is an extension library that adds a multi-dimensional numerical array class to Ruby. Values are stored as binary data in one block of memory and worked on collectively; the class is built that way so that numerical computation and data analysis can be done in Ruby.

It has been developed since 2005, and this is its third major version. Two ideas run through the whole of it.

The first is that an absent value belongs to the array rather than to a convention agreed between a program and its data. Any array can carry a mask that marks individual elements as undefined. The mask is stored beside the values rather than among them, so no number is spent standing in for absence: an array of integers has no value it may not hold, and one of floating-point numbers has no reading it must reject. Arithmetic carries the mask through to its result, and a statistic leaves the marked elements out of its calculation.

```ruby
a = CArray.int32(4).seq!
a[2] = UNDEF
a          #  => [ 0, 1, _, 3 ]
a.mean     #  => 1.3333333333333333
```

The second is that referring to data does not copy it. Addressing, slicing, transposing, reshaping, selecting by a condition, mapping addresses, gathering on a grid, reinterpreting the data type: each of these produces a **view**, which reads from the array it refers to and writes back to it. Reshaping is one of them, so an array seen in another shape is still that array.

```ruby
a = CArray.int32(4, 4).seq!
pairs = a.reshape(8, 2)   # the same values, seen as eight pairs
pairs[2..3, nil] = 0      # a block of the reshaped view
a
#  => [ [ 0, 1, 2, 3 ],
#       [ 0, 0, 0, 0 ],
#       [ 8, 9, 10, 11 ],
#       [ 12, 13, 14, 15 ] ]
```

They also compose. Any of them can be applied to the result of another, in any combination and to any depth, and what comes out is still a view of the array at the bottom: a column slice can be reshaped, a transpose can be reshaped, and a store into either reaches the array underneath. Copying is something you ask for, with `copy`.

Neither idea is a separate array class that you opt into. The mask belongs to the array class itself, so it survives every view above; and a view can be laid over any array, including one whose values you define yourself in Ruby. That is what the rest of this chapter, and the chapters after it, set out.

## Single data type, multiple dimensions

An array stores values of a single, uniform data type — fixed-width integers (8, 16, 32 or 64 bits), floating-point numbers (32 or 64 bits), complex numbers (64 or 128 bits), fixed-length strings, or Ruby objects. Every element is the same size, and they sit next to each other in memory.

An array has a multi-dimensional rectangular shape: the number of axes it has, and the length of each. The same values can be presented as one long run, as rows and columns, or as a stack of blocks, and CArray gives you an index per axis to reach them. As a result, CArray behaves as the multi-dimensional array that numerical calculation and data processing call for.

An element need not hold a single number. A record type packs several named values into one element, so a table of readings — a time, a latitude, a temperature — can be held as one array rather than three, and a field of it read out as an array in its own right.

## Collective arithmetic operations and various reduction operations

Arithmetic and the elementary mathematical functions apply element by element to a whole array, and reductions — sums, means, extremes, and the other statistics — summarise it, either entirely or along the axes you name. Because the values are of one type and lie together in memory, this work happens in C, not in a Ruby loop over each element.

When what you want done to each part of an array is not one of the operations the library provides, you can still work a part at a time rather than an element at a time: name the axes that a part spans, and a Ruby block is called once for each sub-array over the remaining axes. A block that computes a whole row runs once per row, and receives that row as an array.

Nor need the parts a reduction runs over be axes. Sliding windows and non-overlapping tiles are two other ways of naming them; a third is grouping — the elements that share a category, or that fall in the same band of coordinates along an axis. A monthly mean of a `[time, lat, lon]` field, or a per-region average taken with a region map, is then one reduction rather than a loop. However the parts are named, the same `sum`, `mean`, `min` and the rest apply to them, and the answer comes back as an array.

## Missing values are part of the array

Reading a masked element yields `UNDEF`, and storing `UNDEF` into an element marks it; the mask can also be set from a condition, read out as a boolean array, counted, and cleared with a value to fill the gaps.

The mask belongs to the array class and not to any one kind of array, so every array in the library has it, whatever else it is. A reduction along an axis reports as undefined those of its results that had nothing left to work from, so the gaps in the answer say where the gaps in the data were.

## Referring to data without copying

The ways of referring to data are many: addressing, slicing, selecting by a condition, mapping addresses, gathering on a grid, transposing, shifting, rolling, converting the data type, reshaping. What each returns is a view, and a view holds no data of its own; it records how to reach the values in the array it refers to, and goes for them when a value is read, an element stored, or a calculation made.

View classes are subclasses of CArray, so a view is an array: everything in this guide applies to it, the mask included, and nothing has to be done to it before it can be used. A view can therefore be built on a view, and handed to anything that expects an array.

What is stored through a view reaches the array underneath, and the mask reaches it too: writing `UNDEF` into an element of a view marks the element it stands for, and writing a value into a marked one clears the mark. This holds however the view was arrived at. A slice of a reshape of a transpose is not a place where values happen to be readable — it is the array it came from, seen differently, in its mask as much as in its values.

Data is not copied at the boundary of the library either. CArray implements the MemoryView protocol in both directions, so an array can be handed to another numerical library, and a buffer belonging to one can be worked on as a CArray, with neither side duplicating the data. Adopting CArray therefore does not ask that the rest of your work move with it.

## Arrays you define yourself

An array can be given a domain meaning without changing how its values are stored. A count of days is read and written as a date, an integer as a category, a run of bytes as a string; the storage stays what it was, and the arithmetic stays as fast as it was. Such a class is called a **Face**. Several come with the library — `CATime`, whose elements are instants on a grid you name (days, seconds, milliseconds) while the array underneath stays an array of integers, is one — and one can be written for a domain of your own.

An array need not hold values at all. Subclass `CAObject` in Ruby and say how the element at a given position is obtained — computed on demand, read from a file, fetched from a database, taken from an instrument — and what you have written is a CArray. It is indexed and sliced as one, views can be built on it, reductions run over it, and anything that accepts an array accepts it. An array of a million elements that stores none of them costs nothing to make.

Arrays of all these kinds are what a data frame — `CAFrame`, which comes with the library — holds in its columns. A column is a plain CArray and nothing else, so masks, views, groupings and the arrays you define yourself go on working inside a table, and a column taken out of a frame is an array like any other.

## How this guide is arranged

The guide is written to be read in order, each chapter assuming the ones before it:

* [Getting started](00_getting_started.md) — installing CArray, making a first array, and a short tour of what the rest of the guide covers
* [Creating arrays](01_creating_arrays.md) — the constructors, the data types, and the ways of filling an array with values
* [Indexing and slicing](02_indexing_and_slicing.md) — reading and writing elements, rows, columns and sub-blocks, and selecting by a condition
* [Element-wise operations](03_elementwise.md) — arithmetic, comparison, and the mathematical functions applied to every element
* [Reduction and statistics](04_reduction_and_statistics.md) — summaries over the whole array or along the axes you choose
* [Masks and missing values](05_masks.md) — marking elements as undefined, and how arithmetic and statistics then treat them
* [Views](06_views.md) — reshaping, transposing and slicing without copying, and what a write through a view reaches
* [Broadcasting](07_broadcasting.md) — combining arrays whose shapes differ

CArray is larger than these chapters, and the guide is being written alongside the 3.0.x releases; further chapters join this list as they settle.
