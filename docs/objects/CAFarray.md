# CAFarray — column-major (Fortran-order) view

`CAFarray` presents a row-major array as if it were stored in **column-major
(Fortran) order**. It is a CAStride view: no data is
copied, and the reversed-order layout is produced by walking the parent's bytes
with permuted strides.

```
a = int32 [[0, 1, 2],
           [3, 4, 5]]        shape [2, 3], row-major buffer 0 1 2 3 4 5

a.farray                     shape [3, 2]

  [[0, 3],
   [1, 4],
   [2, 5]]                   same buffer, read column-major
```

The view reverses the parent's axis order, so element
`view[i0, i1, …, in-1]` aliases parent element `parent[in-1, …, i1, i0]`:

```
view.ndim  == parent.ndim
view.shape == parent.shape reversed
```

Equivalently: the raw bytes of the parent, read in the view's own C-order,
are the parent's bytes in Fortran order — which is exactly what a column-major
consumer (LAPACK, BLAS, Fortran code) expects.

## Construction

`CArray#farray` takes no arguments:

```ruby
a  = CArray.int32(2, 3) { |i, j| i * 3 + j }
a.to_a                      # => [[0, 1, 2], [3, 4, 5]]

fa = a.farray
fa.shape                    # => [3, 2]
fa[0, 1]                    # => 3   (= a[1, 0])
fa.to_a                     # => [[0, 3], [1, 4], [2, 5]]
```

Applying `farray` twice returns to the original order:

```ruby
a.farray.farray.to_a == a.to_a    # => true
```

## Relationship to `transpose`

For any array, `a.farray` and `a.transpose` (full-axis reversal, no argument)
produce the **same logical values** — both reverse all axes:

```ruby
a.farray.to_a == a.transpose.to_a       # => true (any ndim)
```

They differ in intent, not in the elements they expose:

- **`transpose`** is about the *logical* axis order — "swap rows and columns",
  and it accepts an explicit permutation (`a.transpose(2, 0, 1)`).
- **`farray`** is about *memory layout* — "hand these bytes to a column-major
  reader." It only ever does the full reversal.

Reach for `farray` when the framing is "give me a Fortran / column-major view of
this data"; reach for `transpose` when the framing is "reorder these axes."

## Writing

`CAFarray` is a live, writable view; writes flow back to the parent through the
permuted strides:

```ruby
a  = CArray.int32(2, 3) { |i, j| i * 3 + j }
fa = a.farray
fa[0, 1] = 99
a[1, 0]                     # => 99
```

## MemoryView export

A `CAFarray` exports through the MemoryView protocol as a **strided** producer,
so a consumer receives the column-major layout with zero copy:

```ruby
fa  = CArray.int32(2, 3).seq.farray
imported = CArray.from_memory_view(fa)
imported.shape              # => [3, 2]
imported.to_a == fa.to_a    # => true
```

## Class and hierarchy

- Ruby class `CAFarray < CAStride < CAView < CArray`; mask class
  `CAFarrayMask < CAFarray`.
- `obj_type` is `CA_OBJ_FARRAY`, installed at runtime.
- Implemented as a pure `CAStride` typedef — it carries no state beyond the
  strides and base offset, so its full behavior (slicing, masking, the
  contiguous alias fast path, compose-fold) is inherited from `CAStride`.

## Related

- The CAStride strided-view family `CAFarray` belongs to (`CATranspose`,
  `CARefer`, `CABlock`, `CARepeat`).
- [MemoryView](../interop/MemoryView.md) — zero-copy interop, including the strided export
  path used here.
