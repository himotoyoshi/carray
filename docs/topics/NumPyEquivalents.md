# NumPy and CArray

A lookup table for readers who know a NumPy name and want the CArray one. Each row gives the usual way to write it in CArray. The notes say where the two libraries behave differently: a view where NumPy copies, a different default, a different result type. Rows marked *same* behave the same for ordinary input.

The CArray examples use `a = CArray.int32(3, 4).seq` unless a row says otherwise.

Where one library has no direct counterpart, the row gives the nearest way to do the same thing in the other, so that either name leads to the other. The last two sections list what has no counterpart at all. Only the user-facing surface is compared.

**This is not an exact index. Each row puts side by side the NumPy and CArray features that serve the same purpose, even where the details of their behaviour differ. Read the notes, and the reference for each method, before relying on a row.**


## Creating arrays

| NumPy | CArray | Notes |
|---|---|---|
| `np.zeros((3, 4))` | `CArray.zeros(3, 4)` | float64. For another type: `CArray::Int32.zeros(3, 4)`, or `CArray.int32(3, 4)`, which is zero-filled |
| `np.ones((3, 4))` | `CArray.ones(3, 4)` | float64, as above |
| `np.empty((3, 4))` | `CArray.empty(3, 4)` | |
| `np.full((2, 2), 7)` | `CArray.full([2, 2], 7)` | The type comes from the value: an Integer gives int64 |
| `np.zeros_like(a)` | `a.template` | Same shape and type |
| `np.full_like(a, 7)` | `a.template { 7 }` | |
| `np.eye(3)`, `np.identity(3)` | `CArray.eye(3)` | float64 |
| `np.arange(0, 10, 3)` | `CArray.arange(0, 10, 3)` | Integers give int64 |
| `np.linspace(0, 1, 5)` | `CArray.linspace(0, 1, 5)` | *same*. `a.span(0.0..1.0)` and `a.scale(0, 1)` fill an existing array the same way |
| `np.meshgrid(x, y)` | `CArray.meshgrid(x, y)` | Returns an Array of arrays; for `x` of length 2 and `y` of length 3 each has shape `[3, 2]` |
| `np.array([[1, 2], [3, 4]], dtype=float)` | `CA_FLOAT64([[1, 2], [3, 4]])` | One converter per type: `CA_INT32(...)`, `CA_UINT8(...)`, … `[1, 2].to_ca` gives an **object** array |
| `np.datetime64` arrays | `CArray.time(...)` | Returns a `CATime`; see the CATime topic |
| `a[:] = np.arange(10, 18, 2)` | `CArray.int32(4).seq!(10, 2)` | Fills an array with a start and a step, in place |
| `np.full_like(a, 7)` as a copy of `a` | `a.fill_copy(7)` | |
| `np.arange("2024-01-01", "2024-01-04", dtype="datetime64[D]")` | `CArray.time_range("2024-01-01", "2024-01-03", unit: :D)` | Includes both ends. `CArray.time_series(start, count: 3, unit: :D)` gives a count of steps instead |
| `np.timedelta64` arrays | `CATimedelta` | Subtracting one `CATime` from another gives one |
| `np.array(["ab", "c"])` | `CArray.string(["ab", "c"])` | A string array (`CAString`). `CArray.fixlen_string` makes fixed-length strings, `CArray.const_string` read-only strings of any length |
| `np.dtype([("x", "i4"), ("y", "f8")])` | `CArray.struct { int32 :x; float64 :y }` | Defines a record type for arrays of records (`CARecord`); see the CARecord topic |


## Random numbers

| NumPy | CArray | Notes |
|---|---|---|
| `np.random.random(n)` | `CArray.float64(n).random!` | |
| `rng.integers(0, 10, n)` | `CArray.int32(n).random!(10)` | Values in `0...10` |
| `rng.standard_normal(n)` | `CArray.float64(n).randomn!` | |
| `rng.permutation(a)` | `a.shuffle` | |


## Attributes

| NumPy | CArray | Notes |
|---|---|---|
| `a.shape` | `a.shape` | Returns a Ruby Array |
| `a.ndim` | `a.ndim` | *same* |
| `a.size` | `a.elements` | |
| `a.dtype` | `a.data_type` | A Symbol such as `:int32`, accepted wherever a type is given (`to_type`, `CArray.new`). `a.data_type_name` gives the String `"int32"` |
| `a.itemsize` | `a.bytes` | |

## Copying and converting

| NumPy | CArray | Notes |
|---|---|---|
| `a.astype(np.float64)` | `a.to_type(:float64)` | A copy. Each type has a short form, such as `a.float64` or `a.int32`. `a.as_type(:float64)` gives a lazy **view** instead. A float value that does not fit the integer type becomes masked (`UNDEF`), as does NaN |
| `a.copy()` | `a.copy` | Always an independent copy. `to_ca` returns `self` for a CArray, and `dup` of a **view** shares the data |
| `a.tolist()` | `a.to_a` | |
| `np.result_type(a, 1.5)` | `CArray.result_type(a, 1.5)` | Returns a Symbol such as `:float64` |
| `a.view(np.int16)` | `a.refer(:int16, [3, 8])` | Reads the same bytes as another type; give the new shape. `a.field(0, :int16)` reads one value at a byte offset in each element. `a.fake(:float32)` is a **view** that converts the values instead |
| `a.flags.writeable = False` | `a.set_read_only_flag` | `a.read_only?` reads the flag |
| `np.asarray(obj)` sharing the buffer | `CArray.wrap_memory_view(obj)` | Shares the memory of any object that offers a MemoryView. `CArray.from_memory_view(obj)` copies it |


## Indexing and slicing

| NumPy | CArray | Notes |
|---|---|---|
| `a[1, 2]` | `a[1, 2]` | *same* |
| `a[1]` (2-D) | `a[1, nil]` | With one Integer key, `a[1]` reads element 1 in flat order, not row 1 |
| `a[1:3]` | `a[1...3, nil]` | A Ruby Range: `...` excludes the end, `..` includes it (`a[1..2, nil]` is the same rows). A **view**, as in NumPy |
| `a[:, ::2]` | `a[nil, [nil, 2]]` | **View** |
| `a[:, ::-1]` | `a[nil, -1..0]` | A Range that counts down reads backwards. NumPy's `a[3:0]` is empty, CArray's `a[3..0]` is elements 3, 2, 1, 0 |
| `a[np.newaxis, :, :]` | `a[:_, nil, nil]` | |
| `a[..., 1]` | `a[:~, 1]` | |
| `np.diag(a)` | `a.diagonal` | **View** |

## Index arrays and boolean selection

| NumPy | CArray | Notes |
|---|---|---|
| `a[[0, 2]]` | `a[CA_INT64([0, 2]), nil]` | The index must be an integer CArray. A Ruby Array key `[0, 2]` means *start 0, count 2*. A writable **view** (NumPy returns a copy) |
| `a[np.ix_([0, 2], [1, 3])]` | `a[CA_INT64([0, 2]), CA_INT64([1, 3])]` | Two index arrays select the grid of rows × columns. A writable **view** (NumPy returns a copy) |
| `a[[0, 2], [1, 3]]` (pointwise) | `a.gather_nd(CA_INT64([[0, 1], [2, 3]]))` | Each row of the index array is one `(i, j)` |
| `a[a > 5]` | `a[a > 5]` | A writable **view** (NumPy returns a copy) |
| `np.take_along_axis(a, idx, axis=1)` | `a.take_along_axis(idx, axis: 1)` | A writable **view** (NumPy returns a copy) |
| `np.put_along_axis(a, idx, v, axis=1)` | `a.put_along_axis(idx, v, axis: 1)` | |
| `np.add.at(t, idx, v)` | `t.scatter_add!(idx, v)` | Also `scatter_sub!`, `scatter_mul!`, `scatter_min!`, `scatter_max!` |
| `np.unravel_index(5, a.shape)` | `a.addr2index(5)` | |
| `np.ravel_multi_index((1, 1), a.shape)` | `a.index2addr(1, 1)` | |
| `np.choose(c, [x, y])` | `c.choose([x, y])` | |
| `np.take(a, idx, mode="clip")` | `a.project(idx, lo, hi)` | An index below or above the range takes the value `lo` or `hi` instead of being clipped |


## Reshaping and axes

| NumPy | CArray | Notes |
|---|---|---|
| `a.reshape(4, 3)` | `a.reshape(4, 3)` | Always a **view** |
| `a.ravel()` | `a.flatten` | **View** |
| `a.flatten()` | `a.flatten.copy` | CArray's `flatten` is a **view**; add `.copy` for NumPy's copy |
| `a.T` | `a.T` | **View**, *same* |
| `a.transpose(1, 0)`, `np.swapaxes` | `a.transpose(1, 0)` | **View**. Give the full permutation |
| `np.moveaxis(a, 2, 0)` | `a.dim_view(2)` | Brings the named axes to the front. **View** |
| `np.expand_dims(a, 0)` | `a.insert_axis(0)` | **View** |
| `np.squeeze(a)` | `a.drop_axis` | Drops every axis of length 1, but keeps one axis when every axis has length 1 (NumPy gives a 0-d array) |
| `np.broadcast_to(a, (3, 4))` | `a.broadcast_to(3, 4)` | `a` must already have the same number of axes, for example shape `[1, 4]` |
| `as_strided(a, shape, strides)` | `a.as_strided(shape: [2, 2], strides: [16, 4])` | Strides in bytes, as in NumPy. **View** |


## Flipping and shifting

| NumPy | CArray | Notes |
|---|---|---|
| `np.flip(a, 0)` | `a.flip(0)` | **View** |
| `np.roll(a, 1, axis=0)` | `a.roll(1, 0)` | One shift per axis. A **view** (NumPy copies). Without `axis`, NumPy rolls the flattened array; CArray always shifts per axis |
| `np.concatenate([[0], a[:-1]])` (1-D `a`) | `a.shift(1)` | One amount per axis: for the 2-D `a`, `a.shift(1, 0)` moves the rows down. The cells left behind take `fill_value:` (0 by default). A **view** |
| `a[::-1, ::-1]` (every axis) | `a.reverse` | **View** |


## Joining, splitting and repeating

| NumPy | CArray | Notes |
|---|---|---|
| `np.concatenate([a, b], axis=1)` | `CArray.concatenate([a, b], axis: 1)` | A copy. `CArray.meld([a, b], axis: 1)` joins the same way as a **view** |
| `np.vstack([a, b])` | `CArray.concatenate([a, b], axis: 0)` | |
| `np.hstack([a, b])` | `CArray.concatenate([a, b], axis: 1)` | |
| `np.stack([a, b], axis=0)` | `CArray.stack([a, b], axis: 0)` | A **view** (NumPy copies) |
| `np.unstack(a, axis=0)` | `a.split(axis: 0)` | An Array of **views**, one per index along the axis |
| `np.tile(a, (2, 1))` | `a.tile(2, 1)` | **View** |
| `np.repeat(a, 2)` | `a.repeat(2)` | **View**. `axis:` is accepted |
| `np.pad(a, 1)` | `z = CArray.int32(4, 4); z.paste([1, 1], a)` | Make the larger array, then write `a` into it at an offset (`a` of shape `[2, 2]`). `crop` reads a region back out |
| `np.insert(a, 1, [0, 0])` | `a.insert_block([1], [2]) { 0 }` | An offset and a block size per axis |
| `np.delete(a, [1, 2])` | `a.delete_block([1], [2])` | An offset and a block size per axis |
| `np.column_stack([c1, c2])` | `CArray.tabulate([c1, c2])` | Gives one common type |
| `np.block([[x, y]])` | `CArray.montage([x, y], [1, 2])` | Tiles of the same shape, as a **view**. `CArray.mosaic` copies and accepts tiles of different sizes |


## Arithmetic

| NumPy | CArray | Notes |
|---|---|---|
| `a / b` (integers) | `a.to_type(:float64) / b` | Integer `/` in CArray is floor division, like Ruby's `Integer#/` and NumPy's `//`. Float `/` is true division |
| `a // b` (integers) | `a / b` | |
| `a // b` (floats) | `(a / b).floor` | |
| `a % b` | `a % b` | Floor modulo: the result has the sign of the divisor. *same* |
| `np.fmod(a, b)` | `a.fmod(b)` | Truncated remainder, also for integers |
| `np.divmod(a, b)` | `a.divmod(b)` | Returns `[quotient, remainder]` |
| `a ** -1` (integers) | `a ** -1` | CArray gives an integer result (`2 ** -1` is 0); NumPy raises |
| Mixed types (`int32 + 1.5`, `int8 + int16`) | same expression | float64 and int16 respectively. An integer array with a float32 array gives float32 (NumPy: float64). Integer overflow wraps |
| Broadcasting `(2,) + (2, 1)` | `a[:_, nil] + b` | Arrays with different numbers of axes are refused. Add the axis with `:_` first. Axes of length 1 broadcast when the counts match |

## Elementwise math

| NumPy | CArray | Notes |
|---|---|---|
| `np.sqrt(a)` (integers) | `a.sqrt` | float64 |
| `np.maximum(a, b)` | `a.maximum(b)` | NaN wins, *same* |
| `np.minimum(a, b)` | `a.minimum(b)` | NaN wins, *same* |
| `np.fmax(a, b)` | `a.fmax(b)` | NaN loses |
| `np.fmin(a, b)` | `a.fmin(b)` | NaN loses |
| `np.clip(a, 2, 5)` | `a.clip(2, 5)` | |
| `np.abs(a)` | `a.abs` | *same* |
| `np.sign(a)` | `a.sign` | *same* |
| `np.round(a)` | `a.round` | Halves round away from zero (`2.5` → `3.0`); NumPy rounds halves to even |
| `np.sin`, `np.cos`, `np.tan`, `np.arcsin`, …, `np.sinh`, …, `np.arctanh` | `a.sin` | Also `cos`, `tan`, `asin`, `acos`, `atan`, `sinh`, …, `atanh`. *same* |
| `np.exp`, `np.exp2`, `np.expm1`, `np.log`, `np.log2`, `np.log10`, `np.log1p` | `a.exp` | Also `exp2`, `expm1`, `log`, `log2`, `log10`, `log1p`. *same* |
| `np.arctan2(y, x)` | `y.atan2(x)` | *same* |
| `np.hypot`, `np.copysign`, `np.nextafter`, `np.logaddexp` | `a.hypot(b)` | Also `copysign`, `nextafter`, `logaddexp`. *same* |
| `np.square(a)` | `a.square` | `a ** 2` and `a.pow(2)` also work |
| `np.reciprocal(a)` | `a.rcp` | |
| `1 / np.sqrt(a)` | `a.rsqrt` | |
| `np.trunc`, `np.ceil`, `np.floor` | `a.trunc` | Also `ceil`, `floor` |
| `np.modf(a)[0]` | `a.frac` | Keeps the sign of `a` (`-1.5` gives `-0.5`), like `modf` |
| `np.degrees`, `np.radians` | `a.deg` | Also `rad` |
| `np.signbit(a)` | `a.signbit` | *same* |
| `np.sign(a - v)` | `a.cmp(v)` | -1, 0 or 1 per cell |


## Comparison and tests

| NumPy | CArray | Notes |
|---|---|---|
| `a == b` (elementwise) | `a.eq(b)` | CArray's `==` and `!=` compare whole arrays and return `true` / `false`. `<`, `>`, `<=`, `>=` are elementwise. Also `ne`, `lt`, `le`, `gt`, `ge` |
| `np.array_equal(a, b)` | `a == b` | `==` is false when the data types differ, even if the values are equal. `a.eq(b).all` compares the values only |
| `np.isclose(a, v, rtol=0, atol=t)` | `a.is_close(v, t)` | The tolerance is required and is absolute only; NumPy adds `rtol=1e-5` by default. `is_equiv(v, t)` is the relative test |
| `np.allclose(a, b, rtol=0, atol=t)` | `a.is_close(b, t).all` | Absolute tolerance only, as above |
| `np.isnan(a)` | `a.is_nan` | |
| `np.isinf(a)` | `a.is_inf` | |
| `np.isfinite(a)` | `a.is_finite` | |
| `(a >= lo) & (a <= hi)` | `a.is_between(lo, hi)` | `nil` leaves a side open; `exclude:` makes a bound exclusive |


## Complex numbers

| NumPy | CArray | Notes |
|---|---|---|
| `z.real`, `z.imag` | `z.real` | Also `z.imag`. Both can be assigned: `z.real = …` |
| `np.conj(z)` | `z.conj` | |
| `np.angle(z)` | `z.arg` | For cmplx64 input, the result is float32 |
| `np.abs(z) ** 2` | `z.abs2` | For cmplx64 input, the result is float32 |
| `np.isreal(z)` | `z.is_real` | |

## Bitwise operations and bytes

| NumPy | CArray | Notes |
|---|---|---|
| `a & b`, `a \| b`, `a ^ b`, `~a`, `a << n`, `a >> n` | the same operators | *same* for integer arrays. On boolean arrays, `&` and `\|` follow three-valued logic for masked cells |
| `np.packbits(b, bitorder="little")` | `b.pack_bits` | 1-D boolean input |
| `np.unpackbits(u, bitorder="little")` | `u.bitarray` | A writable **view** of the bits |
| `a.byteswap()` | `a.swap_bytes` | A **view** |


## Reductions

| NumPy | CArray | Notes |
|---|---|---|
| `a.sum()` | `a.sum` | Integer input gives a Float. `a.accumulate` sums in the input type |
| `a.sum(axis=0)` | `a.sum(axis: 0)` | |
| `a.sum(axis=1, keepdims=True)` | `a.sum(axis: 1, keep_axis: true)` | |
| `a.prod()` | `a.prod` | Float, like `sum` |
| `a.mean()` | `a.mean` | An empty array gives `UNDEF`; `sum` gives 0 |
| `a.min()` | `a.min` | An empty array gives `UNDEF`. NaN loses every comparison, so it is never the result; NumPy returns NaN |
| `a.max()` | `a.max` | An empty array gives `UNDEF`. NaN is never the result, as for `min` |
| `np.argmin(a)` | `a.min_index` | Flat index without `axis:`, per-axis with it. Never points at a NaN; NumPy points at the first NaN |
| `np.argmax(a)` | `a.max_index` | Flat index without `axis:`, per-axis with it. Never points at a NaN, as for `min_index` |
| `np.nansum(a)` and other `nan*` | `a.mask_invalid.sum` | Masked cells are left out of every reduction. `mask_invalid` masks NaN and infinities (the `nan*` functions keep infinities) |
| `np.ptp(a)` | `a.max - a.min` | |
| `np.any(a)` | `a.any` | On a boolean array |
| `np.all(a)` | `a.all` | On a boolean array |
| `np.count_nonzero(a)` | `a.ne(0).count(true)` | |
| `np.average(a, weights=w)` | `a.wmean(w)` | `a.wsum(w)` is the weighted sum |
| `(a.min(), a.max())` | `a.minmax` | One pass; returns `[min, max]` |
| — (at least *k* cells) | `a.sum(min_count: 3, fill_value: 0)` | Gives `UNDEF`, or `fill_value`, when fewer than 3 cells contribute. Every reduction takes these |


## Statistics

| NumPy | CArray | Notes |
|---|---|---|
| `a.std()` | `a.stddevp` | NumPy's default is the population formula (`ddof=0`) |
| `a.std(ddof=1)` | `a.stddev` | |
| `a.var()` | `a.variancep` | NumPy's default is the population formula (`ddof=0`) |
| `a.var(ddof=1)` | `a.variance` | |
| `np.median(a)` | `a.median` | NaN sorts after every number and is counted, so `[3, NaN, 1]` gives 3.0; NumPy returns NaN |
| `np.percentile(a, 50, axis=1)` | `a.percentile(50, axis: 1)` | |
| `np.quantile(a, 0.25)` | `a.percentile(25)` | `a.quantile` takes no argument and returns the quartiles `[min, Q1, median, Q3, max]` |

## Cumulative sums and differences

| NumPy | CArray | Notes |
|---|---|---|
| `np.cumsum(a, axis=1)` | `a.cumsum(axis: 1)` | Without `axis:`, over the flattened array. Integer input gives float64 (NumPy keeps an integer type). Also `cumprod`, `cummax`, `cummin`; in `cummax` / `cummin` NaN never wins |
| `np.diff(a)` | `a[nil, 1..-1] - a[nil, 0..-2]` | Along the last axis of the 2-D `a`. For 1-D `a`, `a[1..-1] - a[0..-2]` |
| `np.cumsum(~m.mask)` | `m.cumcount` | The running count of cells that are not masked |


## Sorting

| NumPy | CArray | Notes |
|---|---|---|
| `np.sort(a)` | `a.sort(axis: -1)` | A **view**. `a.sort_copy` returns a new array. Without `axis:` the whole array is sorted flat; NumPy's default is the last axis |
| `np.argsort(a)` | `a.sort_index(axis: -1)` | Without `axis:` the indexes are into the flattened array; NumPy's default is the last axis |
| `np.lexsort((k2, k1))` | `CArray.sort_addr(k1, k2)` | The first key is the primary one; in `np.lexsort` it is the last |
| `np.partition(a, 2)` | `a.partition_copy(2, axis: -1)` | Without `axis:` the array is partitioned flat; NumPy's default is the last axis |
| `np.argpartition(a, 2)` | `a.partition_index(2, axis: -1)` | As for `partition_copy` |
| `np.sort(a, axis=None)[::-1][:3]` | `a.nlargest(3)` | Over the whole array without `axis:`. Also `nsmallest`. Both take `axis:` |
| `np.argsort(a, axis=0)[::-1][:3]` | `a.nlargest_index(3, axis: 0)` | Also `nsmallest_index`. `axis:` is required |
| `v[np.argsort(k)]` | `v.sort_by_key(k)` | |
| `v[np.argmax(k)]` | `v.max_by_key(k)` | Also `min_by_key` |
| `np.argsort(np.argsort(a))` | `a.rank_index` | Ties take ordinal ranks |


## Unique values and sets

| NumPy | CArray | Notes |
|---|---|---|
| `np.unique(a)` | `a.unique` | Values in order of first appearance; `sort: true` sorts them. NaN values are kept as one |
| `np.unique(a, return_counts=True)` | `a.value_counts` | Returns `[values, counts]`, values in order of first appearance; `sort: :value` sorts them |
| `vals[np.argmax(counts)]` (from `np.unique(a, return_counts=True)`) | `a.mode` | Returns every most frequent value, in ascending order |
| `np.unique(a, return_index=True)` | `a.mask_duplicates` | Keeps the first occurrence of each value in place and masks the later ones |
| `np.unique(a, return_inverse=True)` | `a.categorize` | Returns a `CACategorical`: `codes` give each cell's label number, `labels` the values in order of first appearance |
| `np.isin(a, v)` | `a.is_in(v)` | |
| `np.intersect1d(a, b)` | `a.intersection(b)` | `sort: true` sorts the result |
| `np.union1d(a, b)` | `a.union(b)` | `sort: true` sorts the result |
| `np.setdiff1d(a, b)` | `a.difference(b)` | `sort: true` sorts the result |
| `len(np.unique(a))` | `a.nunique` | |


## Finding and choosing values

| NumPy | CArray | Notes |
|---|---|---|
| `np.searchsorted(edges, x, side="right") - 1` | `x.bin_to(edges)` | The bin each value falls in, counting from 0 (see [Binning, grids and interpolation](#binning-grids-and-interpolation)). A value outside the edges, including one equal to the last edge, gives `UNDEF` (NumPy gives -1 or the last index). To find where a value sits in a sorted array, `bsearch` returns its position, or `nil` when it is absent |
| `np.flatnonzero(a > 5)` | `(a > 5).where` | Flat addresses |
| `np.nonzero(a)` | `a.ne(0).where` with `addr2index` | `where` gives flat addresses only |
| `np.where(c, x, y)` | `c.then_else(x, y)` | |
| `np.select(conds, choices, default)` | `CArray.select(conds, choices, default: v)` | |
| `np.flatnonzero(a == v)[0]` | `a.search(v)` | `nil` when absent. Also `search_nearest(v)` |
| `np.searchsorted` with `np.isin`, to find values of `q` in `ref` | `q.locate_addr(ref)` | The address of each value in `ref`, `UNDEF` when absent. Also `locate_nearest_addr` |


## Counting and histograms

| NumPy | CArray | Notes |
|---|---|---|
| `np.bincount(a)` | `a.bincount` | |
| `np.histogram(a, bins=edges)` | `a.histogram1d(edges: edges, include_max: true)` | Returns a `CArray::Histogram`; read `.counts`. Also `histogram2d`. Without `include_max: true` a value equal to the last edge is left out; `np.histogram` puts it in the last bin |
| `np.histogram(a, bins=3)` | `a.histogram1d(edges: CArray.linspace(a.min, a.max, 4), include_max: true)` | CArray takes edges only; make equal-width edges with `linspace` |
| `np.histogram2d(x, y, bins=[ex, ey])` | `CArray.stack([x, y], axis: 1).histogram2d(edges: [ex, ey], include_max: true)` | The samples are the rows of an `[N, 2]` array. `include_max:` as for `histogram1d` |
| `np.histogramdd(sample, bins=[e1, e2, e3])` | `sample.histogram(edges: [e1, e2, e3], include_max: true)` | `sample` of shape `[N, D]`, as in NumPy. `include_max:` as for `histogram1d` |
| — (one histogram per row) | `d.histogram1d(edges: e)` | For `d` of shape `[k, n]`, `counts` has one histogram per row (`[k, bins]`). The leading axes of the input stay as axes of the result; NumPy needs a loop |
| `np.bincount(np.ravel_multi_index(labels.T, (2, 2)), minlength=4).reshape(2, 2)` | `labels.bincount_nd(lengths: [2, 2])` | Counts of integer labels in N dimensions, `labels` of shape `[N, D]`. Read `.counts`. Labels at or above the length are left out of `counts` and read with `overflow(axis: k)` |

## Binning, grids and interpolation

| NumPy | CArray | Notes |
|---|---|---|
| `np.digitize(x, edges)` | `x.bin_to(edges)` | Bin `k` is `[edges[k], edges[k+1])`, counting from 0 (`np.digitize` counts from 1). A value outside the edges becomes `UNDEF` unless `lfill:` / `ufill:` is given |
| `np.digitize(x, np.linspace(0, 2, 3))` | `x.bin(0, 2, 1)` | Equal-width bins over `[vmin, vmax]` with width `step` (or `bins:` for a count). A value equal to `vmax` lands in the last bin |
| `np.round(a / 0.5) * 0.5` | `a.snap(0.5)` | Halves round away from zero (`1.25` → `1.5`); `np.round` rounds them to even. `direction: :floor` / `:ceil` round down or up, `offset:` shifts the grid |
| `grid[np.abs(a[..., None] - grid).argmin(-1)]` | `a.snap_to(grid)` | The nearest value in an ascending `grid`. Values outside the grid go to its ends |
| `np.interp(x, xp, np.arange(len(xp)))` | `xp.linear_section(x)` | The fractional position of each `x` in the ascending `xp`. Outside `xp` gives NaN; `np.interp` returns the end values |
| `np.interp(x, xp, fp)` | `fp.linear_fetch(xp.linear_section(x))` | Outside `xp` gives NaN, as above; `np.interp` returns the end values |

## Masked arrays

| NumPy (`np.ma`) | CArray | Notes |
|---|---|---|
| `np.ma.masked` | `UNDEF` | `a[1] = UNDEF` masks a cell |
| `np.ma.masked_equal(a, 2)` | `a.mask_eq(2)` | |
| `np.ma.masked_invalid(a)` | `a.mask_invalid` | |
| `np.ma.masked_where(c, a)` | `a.mask_where(c)` | |
| `m.filled(0)` | `m.strip_mask(0)` | Returns a new array. `m.unmask(0)` fills in place |
| `np.ma.getmaskarray(m)` | `m.is_masked` | |
| `~np.ma.getmaskarray(m)` | `m.is_not_masked` | |
| `np.ma.is_masked(m)` | `m.any_masked?` | `m.has_mask?` says whether a mask exists at all |
| `np.ma.count_masked(m)` | `m.count_masked` | `m.count_not_masked` counts the rest |
| `m.mask = ~m.mask` | `m.invert_mask` | In place |
| `~np.isfinite(a)` | `a.is_invalid` | Masked cells stay masked |


## Iterating

| NumPy | CArray | Notes |
|---|---|---|
| `for x in a.flat` | `a.each { \|x\| ... }` | Every cell in flat order |
| `np.ndenumerate(a)`, `np.nditer` | `a.each_with_index { \|x, i, j\| ... }` | Yields the value and its per-axis index |
| `for row in a` | `a.each_slab(axis: 1) { \|row\| ... }` | One **view** per index along the other axes. The slab is valid only inside the block |
| `np.apply_along_axis(f, 1, a)` | `a.map_slab(axis: 1) { \|row\| ... }` | The block must return a whole row; its results are collected into a new array. For an `f` that reduces each row to one value, `a.reduce_slab(axis: 1) { \|row\| ... }` |

## Moving windows

| NumPy | CArray | Notes |
|---|---|---|
| `sliding_window_view(a, 3).mean(-1)` | `a.windows(-1..1).mean` | One window per cell, so the result has the shape of `a`. At the ends the window holds fewer cells |
| `np.correlate(a, k, mode="same")` | `a.windows(-1..1).correlate(k)` | At the ends, cells outside the array are left out |
| `np.convolve(a, k, mode="same")` | `a.windows(-1..1).convolve(k)` | At the ends, cells outside the array are left out |
| `sliding_window_view(a, 2)` | `a.sliding_windows(2)` | **View** |
| — (windows by the value of a key, such as time) | `v.windows(on: t, before: "1 hour").mean` | Each window holds the values whose key lies within the given width |
| `sliding_window_view(a, 2)` (as one array) | `a.unfold([2])` | The windows as a new axis. **View** |


## Tiles and runs

| NumPy | CArray | Notes |
|---|---|---|
| `a.reshape(2, 2, 2, 2).mean(axis=(1, 3))` | `a.blocks(2, 2).mean` | Non-overlapping tiles of 2 × 2 (`a` of shape `[4, 4]`) |
| `np.add.reduceat(a, [0, 2])`, `np.maximum.reduceat(…)` | `a.segments(offsets: [0, 2, 5]).sum`, `.max` | Consecutive runs. CArray's `offsets:` also gives the end of the last run (`a` of length 5); `lengths: [2, 3]` gives the same runs by length |
| — (`mean`, `median`, … per run) | `a.segments(offsets: [0, 2, 5]).median` | `reduceat` takes only the ufunc reductions; every reduction of CArray works per run |
| `a.reshape(2, 2, 2, 2).swapaxes(1, 2)` | `a.block_view(2, 2)` | The tiles as new axes (`a` of shape `[4, 4]`). **View** |


## Groups

| NumPy | CArray | Notes |
|---|---|---|
| `np.bincount(codes)`, `np.bincount(codes, weights=v)` | `v.group_by_category(cat).count`, `.sum` | One value per category of `cat` (a `CACategorical`), in the order of its labels |
| — (`mean`, `median`, `min`, … per category) | `v.group_by_category(cat).median` | `np.bincount` gives counts and sums only; every reduction of CArray works per category |
| — (group an axis of a grid, e.g. months into seasons) | `temp[season, nil].mean(axis: :group)` | `season` is a `CACategorical` placed on the axis to group; the other axes are kept. See the AxisGroup topic |

## Tables (pandas)

| pandas | CArray | Notes |
|---|---|---|
| `pd.DataFrame({"k": k, "v": v})` | `CAFrame.new("k" => k, "v" => v)` | A table of named CArray columns. Column names are Strings. `df["v"]` is the column as a CArray |
| `pd.read_csv(path)` | `CAFrame.from_csv(path)` | A String is a path; give CSV text as an IO. `df.to_csv` writes |
| `df.groupby("k").mean()` | `df.group_by("k").mean` | |
| `df.merge(other, on="k")` | `df.join(other, on: "k")` | |
| `df[df["v"] > 1]` | `df.filter(df["v"] > 1)` | |
| `df.sort_values("v")` | `df.sort_by_key("v")` | |


## Saving and loading

| NumPy | CArray | Notes |
|---|---|---|
| `np.save(path, a)` | `CArray.save(a, path)` | CArray's own binary format, not `.npy` |
| `np.load(path)` | `CArray.load(path)` | |
| `pickle.dumps(a)` | `CArray.dump(a)` | A String; `CArray.load` reads it back. `Marshal.dump(a)` also works |


## In NumPy, not in CArray

- Linear algebra: `dot`, `matmul` / `@`, `inner`, `outer`, `kron`, `cross`, `einsum`, `np.linalg`
- `np.fft`
- `np.gradient`

## In CArray, not in NumPy

- **Lazy expressions.** `a.lazy * 2 + b.lazy` builds the expression and computes it when read, without intermediate arrays. `CArray.fuse { ... }` writes the same thing as a block.
- **Attributes on an array.** `set_attr` / `attr` keep named values (a unit, a description) with the array and its views.
- **Arrays computed by Ruby.** `CAObject` defines an array whose cells come from a Ruby callback.
