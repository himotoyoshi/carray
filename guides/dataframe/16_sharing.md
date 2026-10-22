# What is shared, and protecting a frame

A frame you make from another frame usually **shares its cells** with it. This chapter explains which operations share and which copy, when sharing helps, when to cut the link with `copy`, and how to make a frame refuse changes.

```ruby
require "carray"
sales = CAFrame.from_csv("sales.csv", missing: ["-1", "n/a"])
```

## Parts of a frame are views

Choosing rows or columns of a frame gives a frame whose columns are **views** of the original's columns: they show the original's cells rather than copies of them. Writing through one writes the other:

```ruby
north = sales.filter { |f| f["shop"].eq("north") }
north["revenue"][0] = 2200.0
sales["revenue"][0]   # => 2200.0
```

The change made through `north` is in `sales`, because `north`'s cells are `sales`'s cells. The same holds the other way: a change to `sales` shows in `north`.

```ruby
sales["revenue"][0] = 2121.39
north["revenue"][0]   # => 2121.39
```

So a correction made in a part reaches the whole table: find the rows to fix with `filter`, fix them in the result, and the original is fixed. Taking a part of a large table also takes no memory of its own. Keep in mind, too, that code which changes a frame it was given changes the frame the caller holds.

## Cutting the link — `copy`

`copy` gives a frame whose columns and index are new arrays of their own:

```ruby
snapshot = north.copy
snapshot["revenue"][0] = 0.0
sales["revenue"][0]   # => 2121.39
```

Copy when you are about to change a part and want the original as it was, when you hand a frame to code you do not control, or when you want a large original to be freed while you keep a small part of it (a view keeps the whole original in memory).

`dup` is not a substitute for `copy`. It makes a new frame object holding the **same** columns: adding or removing a column of the duplicate leaves the original's set of columns alone, but writing a cell writes both.

## Which operations share

**Share cells with the original** — writing either one changes the other:

| operation |
|---|
| `select`, and `df["a", "b"]` (the columns themselves) |
| `filter`, `df[rows]`, `head`, `tail` |
| `sort_by_key`, `sort_by` |
| `join(how: :semi)`, `join(how: :anti)` |
| `CAFrame.meld`, `CAFrame.stack` |
| `melt` |
| each group handed to a `table` block |
| `stack_rows` without `on:`, `unstack_rows` |
| `to_ca` |

**A new frame that shares some columns** — the frame you called it on keeps its set of columns, but the shared columns are the same arrays:

| operation | shares |
|---|---|
| `append`, `drop`, `rename`, `set_index`, `reset_index` | every column |
| `cast`, `promote`, `parse_to_time`, `to_time` | every column but the converted ones, which are new |
| `paste` | the columns of both frames |
| `join(how: :left)`, `join_asof` | this frame's columns; the other frame's are copied |
| `join(how: :inner)` | the columns of both frames, picked by row |
| `join(how: :right)` | the other frame's columns; this frame's are copied |
| `split_column`, `contrast_columns` | the columns not split |
| `stack_columns`, `unstack_column` | the other columns; the new columns are views of the old |

**Independent of the original:**

| operation |
|---|
| `copy` |
| `CAFrame.concatenate` |
| `join(how: :outer)`, `align` |
| `pivot`, `pivot_grid` |
| group summaries, `resample`, `describe` |
| `to_records`, `to_csv` |

## Methods that change a frame

Methods that change the table — `cast`, `set_index` and the others in the first table above — give a new frame and leave the one you called them on as it is. A few methods change the frame you call them on. Whether the change also reaches other frames sharing the same columns depends on what they change:

| method | reaches frames sharing the column? |
|---|---|
| writing a cell, `fill`, `mask_eq`, `df["c"] = UNDEF`, `df[rows] = UNDEF` | yes: the stored cells change |
| `df["c"] = column` | no: the name now refers to a different column |
| `df["c"] = nil` | no: only this frame's set of columns changes |

For example, filling a column fills it for every frame that shares it:

```ruby
part = sales.select("shop", "visitors")
part.group_by("shop").fill("visitors", :ffill)
sales["visitors"][7]   # => 102
```

while converting it gives a new frame with a new column, and neither `part` nor `sales` changes:

```ruby
floats = part.cast("visitors", :float64)
floats["visitors"].data_type   # => :float64
part["visitors"].data_type     # => :int64
sales["visitors"].data_type    # => :int64
```

## Protecting a frame

When a frame should not change — a reference table that several parts are taken from, or a frame handed to code that should only read it — make it read-only. There are two levels:

| | `freeze` | `protect` |
|---|---|---|
| add, remove or replace a column | refused | refused |
| delete, mask or replace rows | refused | refused |
| methods that change the frame (`fill`, `mask_eq`) | refused | refused |
| methods that give a new frame (`cast`, `set_index`, …) | allowed; the new frame is not frozen | allowed; the new frame is not frozen, and the columns it shares stay read-only |
| write a cell through a column | **allowed** | refused |

`freeze` fixes the frame's structure, as `Array#freeze` fixes an Array's elements but not the objects in it. `protect` also makes every cell refuse writes:

```ruby
ref = sales.copy.protect
ref.protected?                 # => true
ref["revenue"][0] = 0.0        # raises RuntimeError: []=: can not modify read-only array
ref["shop"] = nil              # raises FrozenError
```

Frames taken from a protected frame by `filter`, `select` and the other sharing operations read the same protected cells, so they refuse writes too. `copy` gives a frame you can write again.

`protect` makes the frame's columns read-only views; it does not change the arrays they were made from. Whoever holds one of those arrays can still write to it, and the protected frame shows the change. To be sure nothing changes underneath, protect a copy, as above.

## In the CArray User's Guide

*Views* in the CArray User's Guide ([06_views.md](../users/06_views.md)) explains views on arrays, which is what the columns of a sub-frame are.
