# CAFrame User's Guide

A guide to analysing tables with `CAFrame`, the data frame that comes with Ruby/CArray. A frame is a table whose columns are CArrays. With it you take a table — a CSV export, a JSON response, a set of arrays you already have — read it, clean it, summarise it, combine it with other tables and write the results out, and work on any column directly as an array.

`CAFrame` is part of CArray. `require "carray"` is all it takes, and reading CSV needs no other library.

Every chapter is organised around what you are trying to do with your data rather than around the methods of the class. The methods are all there, but they appear where a task calls for them.

## Who this guide is for

This guide is for people who use CArray. A frame's columns are CArrays, and what you do with a frame is largely what you do with arrays, so the guide assumes the basics of CArray: making arrays, indexing and slicing, element-wise operations, reductions, masks and views. These are the core walkthrough of the **CArray User's Guide** (`guides/users`, its chapters 1 to 8); if you are new to CArray, read those first. Where a chapter here relies on more — times, categories, histograms — it names the chapter of the CArray User's Guide that covers it.

## The data used in the examples

Most examples use two small CSV files, kept beside this guide in `data/`:

- `sales.csv` — daily figures from three shops over eight days: visitors, revenue and customer rating, with a few missing and unreadable cells, as real files have.
- `shops.csv` — a table of the shops: name, size, opening date and floor area.

Both are printed in full in chapter 1, so you can follow the examples without the files. To run them, start Ruby in `guides/dataframe/data`:

```ruby norun
require "carray"
sales = CAFrame.from_csv("sales.csv", types: :infer, missing: ["-1", "n/a"])
```

## Reading order

[Introduction](introduction.md) comes first. It describes what a frame is, lists what you can do with one, and collects a few points of how frames behave that the later chapters take as known. Chapter 1 then takes you through a whole small analysis, from reading a file to writing a summary, so you see the pieces together before each is explained.

1. [A first analysis](01_first_analysis.md)
2. [Building a frame](02_building_frames.md)
3. [Reading CSV files](03_reading_csv.md)
4. [Looking at your data](04_looking_at_data.md)
5. [Getting columns and rows](05_columns_and_rows.md)
6. [Choosing and ordering rows](06_choosing_rows.md)
7. [Preparing columns](07_preparing_columns.md)
8. [Missing values](08_missing_values.md)
9. [Row labels: the index](09_index.md)
10. [Summarising by group](10_grouping.md)
11. [Time series](11_time_series.md)
12. [Combining tables](12_combining.md)
13. [Long and wide tables](13_reshaping.md)
14. [Columns with more than one value per row](14_nd_columns.md)
15. [Frames and arrays](15_frames_and_arrays.md)
16. [What is shared, and protecting a frame](16_sharing.md)
17. [Writing results out](17_writing_out.md)
18. [Recipes](18_recipes.md)
19. [Finding the method for a task](19_task_index.md)

Chapters 2 to 9 are the everyday tools; read them in order the first time. Chapters 10 to 17 can be read in any order once those are familiar. Chapter 18 collects complete worked tasks, and chapter 19 is an index from tasks to methods.
