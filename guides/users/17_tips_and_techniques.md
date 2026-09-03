# Tips and techniques

A cookbook of short idioms that come up often. Each one stands on its own; pick the ones you need. Cross-links point to the chapter that explains the underlying mechanism in full.

All examples assume `require "carray"`.

## Shape and broadcasting

### Centre each row on its row mean

Reduce along the row axis with `keep_axis: true` so the result keeps shape `[N, 1]` and broadcasts straight back against the source. No explicit `:_` insertion is needed.

```ruby
x = CA_DOUBLE([[1, 2, 3, 4],
               [5, 6, 7, 8]])

x - x.mean(axis: 1, keep_axis: true)
#  => [ [ -1.5, -0.5, 0.5, 1.5 ],
#       [ -1.5, -0.5, 0.5, 1.5 ] ]
```

See [Reduction and statistics](04_reduction_and_statistics.md) for `keep_axis:`, and [Broadcasting](07_broadcasting.md) for the size-1 axis rule.

### Normalise each row to sum to 1

The same idea with `sum`. Each row is divided by its own total, so every row of the result sums to 1.

```ruby
x = CA_DOUBLE([[1, 2, 3],
               [4, 5, 6]])

x / x.sum(axis: 1, keep_axis: true)
#  => [ [ 0.1667, 0.3333, 0.5    ],
#       [ 0.2667, 0.3333, 0.4    ] ]
```

### Subtract the column mean from each column

The mirror of centring the rows: reduce along axis 0 instead, and the kept axis broadcasts down the columns.

```ruby
b = CA_DOUBLE([[1, 2, 3],
               [4, 5, 6]])

b - b.mean(axis: 0, keep_axis: true)
#  => [ [ -1.5, -1.5, -1.5 ],
#       [  1.5,  1.5,  1.5 ] ]
```

### Mark the largest element of each row

A per-row reduction compared back against the row it came from.

```ruby
b = CA_DOUBLE([[1, 2, 3],
               [4, 5, 6]])

b.eq(b.max(axis: 1, keep_axis: true))
#  => [ [ 0, 0, 1 ],
#       [ 0, 0, 1 ] ]
```

### Per-row z-score with broadcasting

Subtract the row mean and divide by the row standard deviation. `keep_axis: true` on both reductions keeps the broadcast clean.

```ruby
x = CA_DOUBLE([[1, 2, 3, 4],
               [5, 6, 7, 8]])

mu = x.mean(axis: 1, keep_axis: true)
sd = x.stddev(axis: 1, keep_axis: true)

(x - mu) / sd
#  => [ [ -1.1619, -0.3873, 0.3873, 1.1619 ],
#       [ -1.1619, -0.3873, 0.3873, 1.1619 ] ]
```

### Outer product of two vectors

Turn one vector into a column (`[nil, :_]` — a new axis after the existing one) and the other into a row (`[:_, nil]`), then multiply. Broadcasting fills in the rectangle.

```ruby
v = CA_INT([1, 2, 3])
w = CA_INT([10, 20, 30, 40])

v[nil, :_] * w[:_, nil]
#  => [ [ 10, 20, 30,  40 ],
#       [ 20, 40, 60,  80 ],
#       [ 30, 60, 90, 120 ] ]
```

Any element-wise operation works the same way — `+`, `lt`, `hypot`, etc.

### Flatten to 1-D

Three idioms produce a 1-D view over the same elements:

```ruby
a = CArray.int32(2, 3).seq

a.reshape(-1)            # -1 = "fill in whatever length is needed"
a[nil]                   # nil = whole-array indexer, flattened
a.flatten                # the explicit name

# all three:
#  => [ 0, 1, 2, 3, 4, 5 ]

a.reshape(a.elements)    # the long form, same result
```

All three return a view, so writing through it updates `a`. See [Views](06_views.md).

### Inserting axes programmatically with `insert_axis`

When you write the index at the call site, the `:_` and `:*` sigils are the natural way to add an axis. `insert_axis` is for the other case — library code that builds the axis list from data, where the positions and sizes are only known at run time.

Each position names the existing axis the new axis goes *before* (`ndim` appends at the end; negatives count from the end). Positions are in the source frame, so they do not shift as other axes are inserted, and the same position twice stacks two axes there. By default it inserts size-1 axes:

```ruby
a = CArray.float64(5, 3).seq

a.insert_axis(0)        #  => shape (1, 5, 3)   before axis 0
a.insert_axis(0, 1)     #  => shape (1, 5, 1, 3) before each axis
a.insert_axis(0, 0)     #  => shape (1, 1, 5, 3) two before axis 0
a.insert_axis(-1)       #  => shape (5, 3, 1)   at the end
```

The `repeat:` keyword sizes the inserted axes. It mirrors the two ways an axis can be added:

```ruby
# repeat: N (> 1) — a read-only view that repeats the data N times
a.insert_axis(1, repeat: 4)        #  => shape (5, 4, 3), each slice == a

# repeat: 1 (or omitted) — a size-1 axis, stretched when you assign into it
row = CArray.int32(3, 4).seq
t   = CArray.int32(5, 3, 4)
t[] = row.insert_axis(0)               # row copied into every slab

# per-position array, one value per position
a.insert_axis(0, 1, repeat: [2, 3])    #  => shape (2, 5, 3, 3)
```

A scalar `repeat:` applies to every inserted axis; an array gives one value per position, so `insert_axis(0, 1, repeat: [1, 3])` leaves the axis before axis 0 at length 1 and repeats the one before axis 1 three times.

This is the same machinery as the `:_` indexer (see [Indexing and slicing](02_indexing_and_slicing.md) for how a size-1 axis stretches on a store); `insert_axis` just lets you drive it from a computed list.

## Building arrays

### Identity matrix with a 2-D block

The two-argument block form receives the indices, so a comparison expresses the diagonal directly.

```ruby
CArray.int32(3, 3) { |i, j| i == j ? 1 : 0 }
#  => [ [ 1, 0, 0 ],
#       [ 0, 1, 0 ],
#       [ 0, 0, 1 ] ]
```

See [Creating arrays](01_creating_arrays.md) for the block-fill pattern in general.

### Lower-triangular or chess-board patterns

The same idea — any predicate on `(i, j)` gives a pattern.

```ruby
CArray.int32(4, 4) { |i, j| i >= j ? 1 : 0 }     #  lower-triangular ones
#  => [ [ 1, 0, 0, 0 ],
#       [ 1, 1, 0, 0 ],
#       [ 1, 1, 1, 0 ],
#       [ 1, 1, 1, 1 ] ]

CArray.int32(4, 4) { |i, j| (i + j) % 2 }        #  chess-board
#  => [ [ 0, 1, 0, 1 ],
#       [ 1, 0, 1, 0 ],
#       [ 0, 1, 0, 1 ],
#       [ 1, 0, 1, 0 ] ]
```

### A vector of consecutive denominators with `seq`

Sometimes you want `[1, 2, 3, …, N]` as a float array — typically as the denominator of a running mean. `seq(1)` does that in one call.

```ruby
N = 5
CArray.float64(N).seq(1)
#  => [ 1.0, 2.0, 3.0, 4.0, 5.0 ]
```

### Convert between data types with `CA_INT(a)` / `a.int32` / `a.float32`

`CA_INT(a)`, `CA_DOUBLE(a)`, etc., cast an existing CArray to the named type. The method form `a.int32`, `a.float32`, … does the same.

```ruby
a = CA_DOUBLE([1.5, 2.7, 3.9])

CA_INT(a)              #  => [ 1, 2, 3 ]
a.int32                #  => [ 1, 2, 3 ]
a.float32              #  => [ 1.5, 2.7, 3.9 ]     (as float32)
a.to_type(:int32)      #  same as a.int32          (eager)
```

**Eager (`a.float32`) vs view (`a.as_float32`)**. The bare name produces a new, independent copy at the target type. The `as_` prefix produces a view onto `a` — writing through it converts back and updates `a`:

```ruby
a = CArray.float64(2, 3).seq

v = a.as_float32       #  also: a.as_type(:float32)
v[0, 0] = 99.0         #  writes through: a[0, 0] is now 99.0
```

Note: not every cast is allowed (`float64 → boolean` raises). Cast through an explicit predicate instead — for example `a.ne(0)` gives a boolean.

## Reductions

### Position of the smallest or largest element

`min_index` and `max_index` give the *position*, not the value. With `axis:` you get one position per slice. Combine with `keep_axis: true` if you want the result shaped to broadcast back.

```ruby
m = CA_INT([[3, 1, 4],
            [1, 5, 9]])

m.max_index(axis: 1)                    #  => [ 2, 2 ]
m.max_index(axis: 1, keep_axis: true)
#  => [ [ 2 ],
#       [ 2 ] ]
```

See [Reduction and statistics](04_reduction_and_statistics.md). CArray uses the `_index` suffix throughout — there is no `argmin` / `argmax`.

### Top-K positions via `sort_index`

`sort_index` returns the positions that would sort the array. Take the tail for the largest, the head for the smallest. Index back to get the values.

```ruby
v = CA_INT([3, 1, 4, 1, 5, 9, 2, 6])

idx = v.sort_index            #  => [ 1, 3, 6, 0, 2, 4, 7, 5 ]
top3 = idx[-3..-1]            #  => [ 4, 7, 5 ]    positions of the top three
v[top3]                       #  => [ 5, 6, 9 ]    the corresponding values
```

### Counting matches: `(a > 5).count(true)`

A comparison gives a boolean array; `count(true)` tells you how many cells satisfy it.

```ruby
a = CA_INT([1, 2, 3, 4, 5, 6, 7, 8, 9, 10])

(a > 5).count(true)     #  => 5
a.gt(5).count(true)     #  => 5      same thing
```

For per-row counts, use `axis:`:

```ruby
m = CA_INT([[1, 2, 3], [4, 5, 6], [7, 8, 9]])
m.gt(4).count(true, axis: 1)
#  => [ 0, 2, 3 ]
```

### "Any row contains x?" with `any(axis: 1)`

`any` and `all` are reductions too — they take `axis:` like the rest.

```ruby
m = CA_INT([[1, 2, 3],
            [4, 5, 6],
            [7, 8, 9]])

m.eq(5).any(axis: 1)
#  => [ 0, 1, 0 ]      only row 1 contains a 5
```

### Cumulative running mean

The running mean at position `k` is the running sum up to `k` divided by `k+1`. Build the denominator with `seq(1)`.

```ruby
a = CA_DOUBLE([2, 4, 6, 8, 10])

denom = CArray.float64(a.elements).seq(1)    #  [ 1.0, 2.0, 3.0, 4.0, 5.0 ]
a.cumsum / denom
#  => [ 2.0, 3.0, 4.0, 5.0, 6.0 ]
```

### Quick shape and mask checks

Trivial, but they come up constantly.

```ruby
a = CArray.float64(3, 3).seq
a[0, 1] = UNDEF
a[2, 2] = UNDEF

a.shape == [3, 3]    #  => true
a.has_mask?          #  => true
a.count_masked       #  => 2
a.count_not_masked   #  => 7
```

See [Masks and missing values](05_masks.md) for the mask, and [Reduction and statistics](04_reduction_and_statistics.md) for the counting methods.

### Bincount — tallying integer labels

`bincount` takes an array of non-negative integer labels and returns the count of each label, in label order. The result has length `max(labels) + 1` by default, or `length:` (whichever is larger).

```ruby
labels = CA_INT32([0, 1, 1, 2, 0, 1])
labels.bincount               #  => [ 2, 3, 1 ]    label 0 appears 2 times, 1 appears 3 times, 2 once
labels.bincount(length: 5)    #  => [ 2, 3, 1, 0, 0 ]    pad with zeros
```

The result's data type is `uint32` (or `uint64` if the result is huge). Convert with `.int64` or `.float64` if you need signed or floating-point arithmetic downstream.

### Weighted bincount — sum per group

Pass `weights:` to sum a parallel array of weights into each label's bucket instead of counting. The output data type follows `weights`.

```ruby
labels  = CA_INT32([0, 1, 1, 2, 0, 1])
weights = CA_DOUBLE([1, 2, 3, 4, 5, 6])

labels.bincount(weights: weights)
#  => [ 6.0, 11.0, 4.0 ]    sum of weights for each label
```

### Group-by mean in two lines

Combining the two forms gives a group-by mean — the canonical use of weighted bincount.

```ruby
labels = CA_INT32([0, 1, 1, 2, 0, 1])
values = CA_DOUBLE([10, 20, 30, 40, 50, 60])

sums   = labels.bincount(weights: values)    #  => [ 60.0, 110.0, 40.0 ]
counts = labels.bincount                      #  => [    2,     3,    1 ]

means = sums / counts.float64
#  => [ 30.0, 36.6667, 40.0 ]
```

Masked labels are skipped entirely — the cell does not contribute to any bucket — so `bincount` plays well with masked input:

```ruby
labels = CA_INT32([0, 1, 1, 2, 0, 1])
labels[1] = UNDEF
labels.bincount               #  => [ 2, 2, 1 ]    the masked '1' is dropped
```

### Higher moments from a frequency table

Only `wsum` and `wmean` are built in, but every higher moment is a weighted sum of powers of `(value - mean)`, so the same pieces build them. `seq!(axis: k)` lays the value axis out at the shape of the table, and `keep_axis: true` keeps the running mean lined up for the subtraction.

```ruby
freq = CA_INT([[10, 0, 0, 0],     # each row is one frequency distribution
               [ 0, 0, 0, 10],
               [ 9, 3, 7, 2]])

val  = CArray.int32(*freq.shape).seq!(axis: 1)   # every row is 0, 1, 2, 3
wtot = freq.sum(axis: 1, keep_axis: true)        # total count per row, [3, 1]

mean = (val * freq).sum(axis: 1, keep_axis: true) / wtot
#  => [ [ 0.0 ], [ 3.0 ], [ 1.0952 ] ]           shape [3, 1]

dev  = val - mean                                # [3, 4] - [3, 1] broadcasts
var  = (freq * dev**2).sum(axis: 1, keep_axis: true) / wtot
#  => [ [ 0.0 ], [ 0.0 ], [ 1.1338 ] ]           population variance per row
```

The third and fourth moments follow the same shape, with `dev**3` and `dev**4`. A row whose counts sum to zero, or whose spread is zero, gives `NaN` from the `0/0` — the honest answer where the moment is undefined.

For a 1-D table `freq.index` is the value axis and no `seq!` is needed. For an N-D one it is not, which is why the value axis is built above.

## Sort, search, and interpolation

Ordering, searching, and table-lookup have their own chapter now: [Sort, search, and interpolation](18_sort_search_interpolation.md). It covers `sort` / `sort_copy` / `sort_index` / `project`, `partition_index` / `rank_index`, `bsearch` / `search` / `search_nearest`, `linear_section` / `linear_fetch`, and `locate_addr` / `locate_nearest_addr` / `scatter_replace!`.

## Masks

### Mark NaN / Inf as missing, then do math safely

`mask_invalid` lifts every IEEE-special cell into the mask. After that, reductions skip those positions instead of being poisoned by NaN.

```ruby
a = CA_DOUBLE([1.0, Float::NAN, 3.0, Float::INFINITY, 5.0])

a.sum                          #  => NaN          IEEE poisons the result
a.mask_invalid.sum             #  => 9.0          masked → skipped
a.mask_invalid.mean            #  => 3.0
```

See [Masks and missing values](05_masks.md).

### Replace missing with a default via `strip_mask`

`strip_mask(default)` returns a copy with the mask removed and the missing cells filled with the value you supply.

```ruby
a = CArray.float64(2, 3).seq
a[0, 1] = UNDEF

a.strip_mask(-1)
#  => [ [ 0.0, -1.0, 2.0 ],
#       [ 3.0,  4.0, 5.0 ] ]

a.strip_mask(0)
#  => [ [ 0.0, 0.0, 2.0 ],
#       [ 3.0, 4.0, 5.0 ] ]
```

### Fold several possibly-missing scalars

A reduction that had nothing to work on answers `UNDEF`, and `UNDEF` is truthy, so an `if` will not catch it. For one call, ask for a fallback there: `a.mean(fill_value: 0.0)`. When you have to combine several such answers in Ruby code, `CArray.guard_undef` short-circuits: it yields the values to the block only when none of them is `UNDEF`, and otherwise returns its `fill_value:` (`UNDEF` by default).

```ruby
a = CArray.float64(4).seq!
a[] = UNDEF

CArray.guard_undef(a.min, a.max) { |lo, hi| hi - lo }   #  => UNDEF
CArray.guard_undef(a.min, a.max, fill_value: 0.0) { |lo, hi| hi - lo }
#  => 0.0
```

This is for Ruby-level code working on scalars. Whole-array work does not need it — the mask travels through the calculation on its own.

### Clean an array of NaN / Inf in place

`a[:is_invalid] = value` writes through the predicate-key indexer. No copy.

```ruby
a = CArray.float64(5).seq
a[2] = Float::NAN
a[3] = Float::INFINITY

a[:is_invalid] = 0
a
#  => [ 0.0, 1.0, 0.0, 0.0, 4.0 ]
```

See [Indexer reference](16_indexer_reference.md) for the predicate-key forms.

## Views and assignment

### Conditional update via boolean indexing

The boolean form on the left of `=` updates exactly the selected cells.

```ruby
a = CA_INT([1, 5, 8, 3, 9, 2])
a[a.gt(5)] = 5
a
#  => [ 1, 5, 5, 3, 5, 2 ]
```

### Conditional update via predicate-key indexer

The same effect, more concise — pass the comparison key directly.

```ruby
a = CA_INT([1, 5, 8, 3, 9, 2])
a[:gt, 5] = 0
a
#  => [ 1, 5, 0, 3, 0, 2 ]
```

See [Indexer reference](16_indexer_reference.md) for the full list of keys.

### In-place sort with `a[] = a.sort`

`sort` returns a view of the source in sorted order. Assigning it back through `a[] = ...` makes the sort effectively in place. This is the modern replacement for the older `sort!` bang form.

```ruby
a = CA_INT([3, 1, 4, 1, 5, 9, 2, 6])
a[] = a.sort
a
#  => [ 1, 1, 2, 3, 4, 5, 6, 9 ]
```

The pattern works for any view-returning rearranger — `reverse`, `flip`, `roll`, `shift`. See [Views](06_views.md).

### In-place reverse, roll, flip

Same idiom, different rearranger.

```ruby
v = CA_INT([1, 2, 3, 4, 5])
v[] = v.reverse
v
#  => [ 5, 4, 3, 2, 1 ]

v = CA_INT([1, 2, 3, 4, 5])
v[] = v.roll(2)
v
#  => [ 4, 5, 1, 2, 3 ]
```

### Compose view chains; materialise once at the end

Reshape, transpose, slice, reverse — these all return views and cost nothing to create. Only `.copy` at the tail of the chain actually allocates and materialises.

```ruby
a = CArray.int32(100, 100).seq

# Three view layers; no data copied yet.
chain = a.transpose.reverse[0..10, 0..10]
chain.class             #  => CABlock     still a view chain
chain.entity?           #  => false

# One allocation here.
result = chain.copy
result.class            #  => CArray
result.entity?          #  => true
```

This is the canonical way to express a multi-step view transform that you actually want to keep: build the chain, then `.copy`. See [Views](06_views.md) and [Composition](10_composition.md).

## Anti-patterns

A few traps worth naming explicitly.

### Don't use `dup` (or `clone`) to "copy" a view

`dup` returns *another view onto the same storage*. Writing to the result still updates the source.

```ruby
a = CArray.int32(2, 3).seq
v = a[0, nil]
d = v.dup          #  looks like a copy — it isn't
d[0] = 999
a
#  => [ [ 999, 1, 2 ],
#       [   3, 4, 5 ] ]    a was modified!
```

Use `copy` when you want an independent array. See [Views](06_views.md).

### Don't use `to_ca` to materialise a view

`to_ca` means "give me this as a CArray". A view is already a CArray, so it is returned **unchanged**. It does not allocate, and it does not give you a writable buffer that is separate from the source.

```ruby
a = CArray.int32(2, 3).seq
v = a[0, nil]

v.to_ca.equal?(v)    #  => true     same object — no copy
v.copy.equal?(v)     #  => false    fresh, independent array
```

If you intend to modify the result, or you need a contiguous, owned buffer, use `copy`. See [Views](06_views.md) and [Creating arrays](01_creating_arrays.md).

### Don't stash the slab object across iterations

The 1-D CArray that `each_slab` hands to the block is **reused** on every iteration — same object, different data. If you save it into a container that outlives the block, every entry ends up pointing at the same object, showing the last iteration's data.

```ruby
m = CArray.int32(2, 3).seq

#  WRONG — every entry aliases the same slab object
refs = []
m.each_slab(axis: 1) { |row| refs << row }

#  RIGHT — take a snapshot
rows = []
m.each_slab(axis: 1) { |row| rows << row.copy }
```

See [Per-slab iteration](11_slab_iteration.md).

## Where to go next

Each tip above points to the chapter that explains the mechanism in full:

* [Creating arrays](01_creating_arrays.md) — constructors and block fill.
* [Indexing and slicing](02_indexing_and_slicing.md) — the slice and boolean forms used throughout.
* [Element-wise operations](03_elementwise.md) — operators, math functions, predicates like `is_invalid`.
* [Reduction and statistics](04_reduction_and_statistics.md) — `axis:`, `keep_axis:`, and the position / counting reductions.
* [Masks and missing values](05_masks.md) — `UNDEF`, `mask_invalid`, `strip_mask`, and how reductions skip masked cells.
* [Views](06_views.md) — why `sort`, `reverse`, and slices are views, and why `dup` does not give you a copy.
* [Broadcasting](07_broadcasting.md) — the size-1 axis rule, `:_`, and the outer-product idiom.
* [Composition](10_composition.md) — chaining view operations.
* [Per-slab iteration](11_slab_iteration.md) — `each_slab`, `map_slab`, `reduce_slab`, and the slab-reuse rule.
* [Indexer reference](16_indexer_reference.md) — the predicate-key forms such as `a[:gt, 5] = 0` and `a[:is_invalid] = 0`.
* [Sort, search, and interpolation](18_sort_search_interpolation.md) — the full treatment of `sort_index`, `bsearch`, `linear_section`, `locate_addr`, and more.
