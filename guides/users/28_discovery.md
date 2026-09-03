# Discovery — distinct values, counts, modes, membership

Once you have an array of raw values, a common next step is to *ask about the
distribution of values themselves*: which values appear, how many times each,
what the most common one is, whether a set of query values is present at all.
This chapter covers the family of value-hash discovery methods that answer
those questions.

They share a common substrate. Every one of them treats two values as the
same when they compare `==` — so `1` and `1.0` are the same, and (because
`NaN != NaN`) every NaN is folded into a single canonical bucket by these
methods (unlike `mask_duplicates`, which uses strict `==` and keeps each NaN
distinct). Masked (`UNDEF`) cells are excluded from the value set; they
neither appear as a distinct value nor count toward frequencies.

The methods:

| Method            | Answers                                                       |
|-------------------|----------------------------------------------------------------|
| `unique`          | Which distinct values are present?                             |
| `value_counts`    | Which distinct values, and how many of each?                   |
| `nunique`         | How many distinct values are there?                            |
| `mode`            | Which value (or values) is the most frequent?                  |
| `is_mode`         | Shape-preserving flag: is each cell one of the modes?          |
| `is_in(set)`      | Shape-preserving flag: is each cell in a given set of values?  |
| `intersection`    | Values present in both self and another array                  |
| `union`           | Values present in either self or another array                 |
| `difference`      | Values present in self but not in the other array              |

`mask_duplicates`, at the end of this chapter, belongs to the same corner of
the library with a different contract: it uses strict `==` (so NaNs are all
kept) and keeps the shape, painting the repeats over rather than compressing
them out.

## `unique` — the distinct values

`unique` returns a 1-D CArray of the distinct values in the input, in
first-seen order:

```ruby
a = CA_INT([1, 2, 2, 3, 1])

a.unique          #  => [ 1, 2, 3 ]   (an int32 CArray, not a Ruby Array)
```

The result is always 1-D, regardless of the input shape: an N-D array is
flattened first, because "which distinct values are present" has no
per-axis version that fits into a rectangle (the number of distinct values
differs from fiber to fiber).

Masked cells are excluded, and NaN cells collapse into a single NaN:

```ruby
m = CA_INT([1, 2, 2, 3, 1]); m[1] = UNDEF
m.unique          #  => [ 1, 3 ]           (2 was the only cell masked)

f = CA_DOUBLE([1.0, Float::NAN, 2.0, Float::NAN, 1.0])
f.unique          #  => [ 1.0, NaN, 2.0 ]  (both NaNs folded into one)
```

That NaN-folding is the whole reason the method is called `unique` rather
than the older Ruby-idiomatic name `uniq`: on a floating array `uniq` (the
Array method) would treat every `NaN` as a distinct object, whereas
`unique` follows the value-hash contract that all NaN cells are the same
value.

Historically CArray 2.x had a `uniq` method that returned the same
first-seen list. The replacement here is `unique`; the compressed form that
`mask_duplicates` used to return before 3.0 is now
`a.mask_duplicates[:is_not_masked].copy`.

## `value_counts` — distinct values and their counts

`value_counts` returns a pair `[values, counts]` — two CArrays of the same
length, one listing the distinct values and the other the number of
occurrences of each:

```ruby
a = CA_INT([1, 2, 2, 3, 1, 3, 3])

vals, cnts = a.value_counts
vals.to_a          #  => [1, 2, 3]
cnts.to_a          #  => [2, 2, 3]     (three 3s, two 1s, two 2s)
```

The default order is first-seen. Sort the result differently with `sort:`:

- `sort: :count` — descending by count (ties broken by first-seen);
- `sort: :value` — ascending by value;
- `sort: false` — first-seen (the default).

```ruby
a.value_counts(sort: :count).map(&:to_a)   #  => [[3, 1, 2], [3, 2, 2]]
a.value_counts(sort: :value).map(&:to_a)   #  => [[1, 2, 3], [2, 2, 3]]
```

Because it returns a pair of CArrays, you can feed the counts straight into
further arithmetic:

```ruby
vals, cnts = a.value_counts
(cnts.to_type(:float64) / cnts.sum).to_a
#  => [0.2857..., 0.2857..., 0.4285...]    (relative frequencies)
```

Masked cells are excluded (they contribute nothing to counts, and no `UNDEF`
appears as a distinct value).

## `nunique` — how many distinct values

`nunique` is the count of distinct values. It takes `axis:`, so you can ask
per-row or per-column:

```ruby
a = CA_INT([1, 2, 2, 3, 1])
a.nunique          #  => 3

m = CA_INT([[1, 2, 2, 1],
            [3, 3, 3, 4]])
m.nunique                    #  => 4       (over the whole array)
m.nunique(axis: 1).to_a      #  => [2, 2]  (per row)
m.nunique(axis: 0).to_a      #  => [2, 2, 2, 2]   (per column)
```

Masked cells are excluded, and NaNs collapse to one distinct value.

## `mode` and `is_mode` — the most frequent value(s)

`mode` returns the most frequent value(s) as a CArray. When there is a
unique winner, the result has one element; when several values tie for the
top count, all of them are returned:

```ruby
a = CA_INT([1, 2, 3, 3, 3, 4, 4])
a.mode.to_a         #  => [3]

b = CA_INT([1, 2, 2, 3, 1, 3])
b.mode.to_a         #  => [1, 2, 3]        (three-way tie: each appears twice)
```

`is_mode` is the shape-preserving companion — a boolean array marking every
cell whose value is one of the modes:

```ruby
a.is_mode.to_a      #  => [false, false, true, true, true, false, false]   (the three 3s)
b.is_mode.to_a      #  => [true, true, true, true, true, true]              (every cell is a mode value)
```

`is_mode` is the *first-class* form — it does not squash ties into an
arbitrary choice, and it composes with masks and per-axis reductions in the
usual way (`b.is_mode(axis: 1)` masks each row's modes).

For per-axis `mode`, each fiber can have a different number of modes (from
1 for a clear winner up to the fiber length for a total tie), so a
rectangular result is impossible. `mode(axis: k)` therefore returns a
**Ruby `Array` of CArrays**, one CArray per fiber, giving that fiber's mode
values:

```ruby
m = CA_INT([[1, 2, 2, 1],
            [3, 3, 3, 4]])

r = m.mode(axis: 1)          #  => Ruby Array of length 2
r.class                       #  => Array
r[0].to_a                     #  => [1, 2]     (row 0: 1 and 2 tie)
r[1].to_a                     #  => [3]        (row 1: 3 wins outright)
```

To recover a rectangular result, use `is_mode(axis: 1)` instead:

```ruby
m.is_mode(axis: 1).to_a
#  => [ [1, 1, 1, 1],   # both 1 and 2 are modes of row 0
#       [1, 1, 1, 0] ]  # only 3 is the mode of row 1
```

## `is_in` — set membership as a shape-preserving mask

`is_in(set)` asks "is each cell one of these values?" and returns a
boolean array of the same shape:

```ruby
a = CA_INT([1, 2, 3, 4, 5])

a.is_in([2, 4]).to_a          #  => [false, true, false, true, false]
a.is_in(CA_INT([1, 3, 5])).to_a  #  => [true, false, true, false, true]
```

The `set` argument may be a Ruby `Array` or a CArray. Types are promoted
symmetrically (`int32` and `float64` operands promote to `float64` on both
sides), so you don't get integer-truncation surprises — a Float `1.5`
query against an `int32` array will not accidentally match `1`.

The classic use is filtering rows by category label:

```ruby
labels = CA_OBJECT(["cat", "dog", "bird", "dog", "fish"])
keep   = labels.is_in(["cat", "dog"])
labels[keep].to_a       #  => ["cat", "dog", "dog"]
```

Masks propagate on the array side (a masked cell in `self` yields a masked
output cell), and masked cells in the query `set` are excluded from the
set entirely.

## Set operations — `intersection`, `union`, `difference`

The two-array set operations treat both operands as sets of distinct values
(each flattened first, mask cells dropped, NaN folded) and return a flat
CArray of the resulting set values:

```ruby
a = CA_INT([1, 2, 3])
b = CA_INT([2, 3, 4])

a.intersection(b).to_a  #  => [2, 3]      (in both)
a.union(b).to_a         #  => [1, 2, 3, 4]  (in either)
a.difference(b).to_a    #  => [1]         (in a but not b)
```

They accept a `sort: true` keyword to force ascending order (default is
first-seen order in `self`):

```ruby
a.intersection(b, sort: true).to_a   #  => [2, 3]
```

Data types are promoted the same way as `is_in`.

## `mask_duplicates` — first occurrences, in place

`mask_duplicates` masks every cell whose value was seen earlier, keeping the
first occurrence. It paints over the repeats rather than squeezing them out, so
the shape stays as it was (see [Masks and missing values](05_masks.md) for what
a mask is):

```ruby
a = CA_INT([10, 20, 20, 30, 10])
a.mask_duplicates      #  => [ 10, 20, _, 30, _ ]
```

Keeping the shape is what lets it work per fiber. Rows hold different numbers
of distinct values, so a squeezed answer would be ragged and could not be a
rectangular array:

```ruby
m = CA_INT([[1, 2, 1],
            [1, 2, 3],
            [4, 2, 1]])

m.mask_duplicates(axis: 1)        #  along each row
#  => [ [ 1, 2, _ ],
#       [ 1, 2, 3 ],
#       [ 4, 2, 1 ] ]
```

`axis: k` runs along each fiber of axis `k`; the default takes the whole array
in flatten order. Values are judged by `==`, so every `NaN` survives — this is
the one place in the chapter where NaNs are not folded together — and a cell
that is already masked takes no part.

## What to reach for

| You want to know                                    | Reach for                             |
|-----------------------------------------------------|---------------------------------------|
| The distinct values                                 | `a.unique`                            |
| Distinct values *and* their counts                  | `a.value_counts`                      |
| Just the count of distinct values                   | `a.nunique` (with optional `axis:`)   |
| The most common value                               | `a.mode`                              |
| Which cells hold a modal value (per axis OK)        | `a.is_mode(axis:)`                    |
| Which cells belong to a given set                   | `a.is_in(set)`                        |
| Values common to two arrays                         | `a.intersection(b)`                   |
| Combined set of values                              | `a.union(b)`                          |
| Values in `a` not in `b`                            | `a.difference(b)`                     |
| First-occurrence marker without squashing shape     | `a.mask_duplicates`                   |

`unique` / `value_counts` / `nunique` / `mode` all fold NaN into a single
canonical bucket and exclude masked cells; `mask_duplicates` uses strict
`==` and keeps every NaN separate. Pick by whether you want values-as-set
semantics or positions-as-mask semantics.
