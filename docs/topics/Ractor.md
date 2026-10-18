# CArray in Ractors

A Ractor can use CArray as the main Ractor does: build arrays, take views of them, compute, reduce, sort, and use CAFrame, structs, CATime and `fuse`. Two things decide how a program is laid out. Arrays cross between Ractors as copies, except a frozen array, which is shared; views stay in the Ractor that made them. And the parts of CArray that are loaded on first use are loaded in the main Ractor, before other Ractors use them.

What this page says was measured on Ruby 3.4.5. Ractor itself is still marked experimental by Ruby.

---

## What works inside a Ractor

Everything that does not cross a Ractor boundary works as it does in the main Ractor, with the same answers:

- constructing arrays, indexing, every kind of view, and storing into them
- element-wise operators, comparisons, math functions, and lazy expressions (`.lazy`, `CArray.fuse`)
- reductions, flat and along an axis, masked or not; sort, search and the discovery methods (`unique`, `value_counts`, `is_in`, …)
- masks, the iterators (`each_slab`, `windows`, `blocks`, `segments`, `group_by_category`, …)
- the Faces (CATime, CATimedelta, CACategorical, the string arrays), CAFrame, structs and record arrays, MemoryView

Each Ractor keeps its own working memory for these (the lazy arena, the kernel iterator's scratch), so Ractors computing at the same time do not share it.

---

## What crosses between Ractors

| what is passed | what the other Ractor receives |
|---|---|
| a frozen array (not a view) | the same object, shared |
| an array that is not frozen | a copy, as Ruby copies other objects; writes to it stay in that Ractor |
| an object array | a copy, when every element is shareable (Integers, Symbols, frozen Strings, …); otherwise `Ractor::Error: can not copy CArray object` |
| a view | refused: `Ractor::Error: can not copy CABlock object` (or the view's class) |
| any array with `move: true` | refused: `can not move CArray object` |
| the value a Ractor returns | a copy |

`Ractor.make_shareable(a)` freezes an array that is not frozen and shares it, as for any Ruby object. Given a view, it refuses, but the message is unhelpful: `ArgumentError: string contains null byte` (Ruby builds the message from `CArray#to_s`, which returns the array's raw bytes).

---

## Sharing one large array

A frozen array is shared without copying, and each Ractor makes its own views of it:

```ruby
data = CArray.float64(4000, 3000) { |i, j| i * 3000.0 + j }
Ractor.make_shareable(data.freeze)

workers = 4.times.map do |k|
  Ractor.new(data, k) do |a, k|
    rows = a.shape[0] / 4
    a[k * rows ... (k + 1) * rows, nil].mean
  end
end
workers.map(&:take)       # Ruby 3.5 and later: workers.map(&:value)
```

The view `a[k * rows ... (k + 1) * rows, nil]` belongs to the Ractor that made it; the array under it is the one `data` names in the main Ractor. Reading a frozen array writes nothing to it, so any number of Ractors can read it at once.

Writing to a shared array, or through a view of it, raises (`FrozenError`, or `can not modify read-only array` through a view), as in the main Ractor.

---

## Load what Ractors use in the main Ractor first

Many methods are defined the first time they are called: their file is loaded then. In a Ractor other than the main one, such a method raises until the main Ractor has loaded its file:

```
'self.stack' is loaded on first use from 'carray/stack'; require it in the main Ractor before other Ractors use it
```

The reason is a Ruby limit rather than a CArray one: Ractors that load files at the same time can deadlock (Ruby 3.4). Require, in the main Ractor, the files of what the Ractors will use:

```ruby
require "carray"
require "carray/stack"
require "carray/methods/unique"

r = Ractor.new { CArray.stack([CArray.int32(3).seq!, CArray.int32(3).seq!]).unique }
```

The classes in the table (`CAFrame`, `CACategorical`, …) are loaded by Ruby when they are first named, also in another Ractor, but the same deadlock applies when several Ractors name one at the same time; require them in the main Ractor too.

| file | what it defines |
|---|---|
| `carray/serialize` | `CArray.save`, `CArray.load`, `CArray.dump`, Marshal of a CArray |
| `carray/fuse_source` | `CArray.fuse` |
| `carray/slab_iterator` | `CASlabIterator` |
| `carray/window_iterator` | `CArray#windows`, `CAWindowIterator` |
| `carray/key_windows` | `CAKeyWindowIterator` |
| `carray/block_iterator` | `CArray#blocks`, `CABlockIterator` |
| `carray/histogram` | `CArray#histogram`, `CArray#histogram1d`, `CArray#histogram2d` |
| `carray/bincount_nd` | `CArray#bincount_nd` |
| `carray/categorical` | `CArray#categorize`, `CACategorical` |
| `carray/axis_group` | `CArray#axis_group` |
| `carray/categorical_iterator` | `CArray#group_by_category`, `CArray#group_by_run` |
| `carray/segment_iterator` | `CArray#segments` |
| `carray/struct` | `CArray.struct`, `CArray.union`, `CAStruct`, `CAUnion` |
| `carray/frame` | `CAFrame`, `CArray#to_frame` |
| `carray/stack` | `CArray.stack`, `CArray.meld`, `CArray.montage`, `CArray#split` |
| `carray/methods/composition` | `CArray.concatenate`, `CArray.mosaic`, `CArray.tabulate` |
| `carray/methods/meshgrid` | `CArray.meshgrid` |
| `carray/methods/bincount` | `CArray#bincount` |
| `carray/methods/repeat` | `CArray#repeat` |
| `carray/methods/broadcast` | `CArray.broadcast` |
| `carray/methods/gather_nd` | `CArray#gather_nd`, `CArray#put_nd` |
| `carray/methods/mask_duplicates` | `CArray#mask_duplicates` |
| `carray/methods/unique` | `CArray#unique` |
| `carray/methods/factorize` | `CArray#factorize` |
| `carray/methods/is_in` | `CArray#is_in`, `CArray#intersection`, `CArray#difference`, `CArray#union` |
| `carray/methods/is_between` | `CArray#is_between` |
| `carray/methods/align_addr` | `CArray.align_addr`, `CArray.align_nearest_addr` |
| `carray/methods/value_counts` | `CArray#value_counts` |
| `carray/methods/nunique` | `CArray#nunique` |
| `carray/methods/lag` | `CArray#lag` |
| `carray/methods/mode` | `CArray#mode`, `CArray#is_mode` |
| `carray/methods/snap` | `CArray#snap`, `CArray#snap_to` |
| `carray/methods/bin` | `CArray#bin`, `CArray#bin_to` |
| `carray/methods/index` | `CArray#index`, `CArray#indices` |
| `carray/methods/bit_string` | `CArray#to_bit_string`, `CArray#from_bit_string`, `CArray#pack_bits`, `CArray#validity_bits` |
| `carray/methods/choose` | `CArray#choose` |
| `carray/methods/join` | `CArray#join` |
| `carray/methods/locate_addr` | `CArray#locate_addr`, `CArray#locate_nearest_addr` |
| `carray/methods/resize` | `CArray#resize` |
| `carray/methods/insert_block` | `CArray#insert_block`, `CArray#delete_block` |
| `carray/methods/string_format` | `CArray.format`, `CArray#format` |

Once the main Ractor has called one of these methods, its file is loaded, and every Ractor can use it.

---

## What only the main Ractor does

- **An expression evaluator** (`CArray.expression_evaluator`, which carray-jit registers) is asked only in the main Ractor. In another Ractor, `CArray.expression_evaluator` is `nil` and a lazy expression is computed by CArray's own walk. The answer is the same.
- **`CArray.fuse`** reads the block's source once in every Ractor. In the main Ractor it then calls a compiled form of it; in another Ractor it evaluates the rewritten expression in the block's own frame on each call, which costs more per call (about 10 µs against 5 µs for a 1000-element `a * b + 1`). The answer is the same.

---

## Why views do not cross

A view reads its parent's cells when it is used, and while it is in use it holds state of its own: how many times it is open, and, for a view that cannot address its parent in place, a copy of the cells it covers. Two Ractors using one view would share that state. Ractor refuses to share an object like that, and CArray keeps it that way.

This also means a program built from Ractors cannot run into the one hazard of using CArray from several threads: a view of an array being read, or written back, while another thread writes the array itself. A frozen array that Ractors share is never written, and each view of it belongs to one Ractor.
