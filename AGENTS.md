# Working on CArray with an AI assistant

CArray is not a NumPy dialect. It has its own vocabulary and its own
first-class features — masks, views, indexer keys, Faces, MemoryView,
the iterator family.

The failure this file exists to prevent is code that **works while
bypassing them**. Spellings that fail are self-correcting; spellings that
succeed while going around a feature are not, and someone has to catch
them by hand every time.

## Before writing array code

Most of these run without error, which is what makes them expensive.

| What you want | The habit to avoid | CArray |
|---|---|---|
| to fill an array with generated values | a block: `{ rand(n) }`, `{ \|i\| i + 100 }` | `random!`, `seq!`, `span!`. A block taking no argument is evaluated **once** and broadcast, so `{ rand(n) }` puts the same number in every cell |
| a mean that ignores missing values | NaN sentinels, `nanmean` | masks — `a.mean` already excludes masked cells |
| to get the mask out of the way | `a.value` | `strip_mask(v)`, which says what the missing cells become. CArray guarantees nothing about what lies under a mask, so `a.value` reads unspecified data and quietly changes the answer |
| to replace missing values with a number | guessing which of the two is in place | `unmask(v)` fills in place and returns the receiver; `strip_mask(v)` returns a new array and leaves the receiver untouched |
| to modify part of an array | copy, edit, write back | assign into the view: `a[] = a.flip(0)` |
| an independent array you can modify | `dup`, `to_ca` | `copy`. `dup` is almost never what you want — it returns another view onto the same storage — and `to_ca` returns the receiver itself |
| to act on cells matching a condition | build a boolean array, index with it | indexer keys: `a[:eq, v] = UNDEF`, `a[:is_invalid] = UNDEF` |
| to look at a boolean array's cells | expecting `1` and `0` | `b[i]`, `b.to_a` and `each` give `true` / `false`, so `b[i] == 1` is quietly false. Arithmetic is a different matter: boolean takes part as 0/1, so `b * a` masks, `b.sum` counts and `b.mean` is the proportion |
| the number of true cells | `count_true`, or bare `count` | `count(true)`. Bare `count` means `count_not_masked` — how many cells hold a value at all. The whole family is `count(v)`, `count_masked`, `count_not_masked` |
| to convert an array's data type | picking whichever spelling comes to mind | `to_type(:float64)` (or `a.float64`) builds a new array. `as_type(:float64)` (or `a.as_float64`) is a view: it follows later changes to the source, and writes through it reach the source |
| to accept a number, an Array or a foreign array as an operand | converting it by hand | `CArray.wrap_readonly(x, type)` when you only read it, `CArray.wrap_writable(x, type)` when writes have to reach it. The names state what the caller needs; `wrap_writable` raises rather than return a copy that would swallow the writes |
| to give an array a semantic type (times, categories, text) | extend the data type, a structured `dtype` | a Face — a view class over ordinary storage (`CATime`, `CACategorical`, `CAConstString`). Data types are a fixed set; semantics live in the class, not the data type |
| an operation between arrays of different rank | expecting NumPy's trailing-axis alignment | it does not happen, and the mismatch is raised. Declare the axis instead: `a + c[:_, nil]`. `:_` inserts a size-1 axis; `:*` leaves one unbound until the operation binds it |
| axes you do not want to spell out | writing every `nil` | `:~` stands for as many axes as needed — `b[:~, 0]`, `b[0, :~]` |
| to hand data to another library | `to_a` | MemoryView: `CArray.wrap_memory_view` / `CArray.from_memory_view` |
| to work along an axis | a Ruby loop over cells | `each_slab`, `windows`, `blocks`, `group_by_category` |
| a dataframe | pandas idioms; a Hash of arrays; copying defensively | `CAFrame`, in the core. `df.filter { \|f\| f["a"].gt(1) }` returns a frame of views, and writing into it reaches the original — pandas would have handed you a copy |
| matrix products, decompositions, solving | reaching for `np.dot` / `np.linalg`, or writing it out by hand | not in the core — the carray-linalg gem (`CArray::Linalg.matmul`, `.solve`, `.svd`). The core stays free of a BLAS dependency on purpose |

When a case is not listed, look it up before inventing a spelling:
`docs/` for topic reference, `guides/devel/` for the developer's guide.

## Vocabulary

Use CArray's words — in code, in comments, and when discussing a change.

- `data_type`, never `dtype`
- `shape` and `ndim`, not `dim` and `rank`
- methods returning a position end in `_index` (`sort_index`,
  `min_index`). There is no `arg*` family
- do not write "same as `np.something`" in a comment. Say what the code
  does

## This is Ruby

- iterate with `each` and `map`, not with index loops
- do not add a local helper that wraps a CArray primitive; call the
  primitive
- private methods are `private`; a `_` prefix is not access control
- `!` marks the dangerous member of a pair, not mutation. Plenty of Ruby
  methods modify the receiver without one

## Verifying a change

    rake build_ext
    rake test

Both must report no failures. See CONTRIBUTING.md for what is worth
sending and in which form.
