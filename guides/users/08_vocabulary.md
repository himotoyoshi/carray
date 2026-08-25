# Vocabulary

CArray uses some words in its own way. This page collects the terms that are
particular to CArray, or whose meaning differs from what you might expect coming
from another array library. You can read it first, or come back to it as a
reference.

## Entity and view

An **entity** is an array that owns its data — a real block of memory. A **view**
is an array that owns no data of its own and instead refers to another array's
storage, presenting it in some other shape or arrangement. Slicing, reshaping,
and transposing all produce views (see [Views](06_views.md)).

```ruby
a = CArray.int32(2, 3).seq
a.entity?            #  => true
a[0, nil].entity?    #  => false   a slice is a view, not an entity
```

More view-making operations — each of these produces a view, not an entity:

```ruby
a.transpose.entity?     #  => false   a transposed view
a.reshape(6).entity?    #  => false   reshape returns a view in CArray
a[a > 2].entity?        #  => false   boolean indexing also returns a view
```

**You use a view exactly like any other array.** The methods, indexing, and
behaviour are the same whether you hold an entity or a view — you do not need to
know or check which one you have. The one thing a view adds that you must keep in
mind: **writing through a view reaches back and changes the data it refers to**
(see [Views](06_views.md)). To get an independent array that does not share
storage, call `copy`.

A distinctive point of CArray is that each kind of view is its own named class,
and the array will tell you which one it is if you ask:

```ruby
a.class              #  => CArray       (an entity)
a[0, nil].class      #  => CABlock      (a slice view)
a.transpose.class    #  => CATranspose
a.reshape(6).class   #  => CAStride
a[a > 2].class       #  => CASelect     (boolean / fancy indexing)
```

You rarely need to name these classes; it only explains why a slice prints as a
`CArray`-like array yet shares storage with its source.

## address

The **address** of an element is its flat, one-dimensional position when the
array is read in row-major order (last axis varying fastest). `address` returns
an array of these positions, in the array's own shape.

```ruby
a = CArray.int32(2, 3).seq
a.address
#  => [ [ 0, 1, 2 ],
#       [ 3, 4, 5 ] ]
```

For a view, the address reflects the view's own ordering:

```ruby
a.transpose.address
#  => [ [ 0, 1 ],
#       [ 2, 3 ],
#       [ 4, 5 ] ]    counted across the transposed (3x2) shape
```

A slice or a boolean-indexed view also numbers its own elements from 0 — the
address is the position *within the view*, not within the source it refers to:

```ruby
a[1, nil].address       #  => [ 0, 1, 2 ]    addresses inside the 1-D slice
a[a > 2].address        #  => [ 0, 1, 2 ]    addresses inside the selected view
```

Address is CArray's term for what some libraries call a flat or ravel index. It
is distinct from a multi-axis position like `[1, 2]`, which CArray calls an
*index*.

## mask and UNDEF

Every CArray can carry an element-wise **mask** that records which elements are
"missing". **`UNDEF`** is the special constant you assign to mark an element as
missing; masked elements print as `_`. This is built in to every array — you do
not need a separate masked-array type. See [Masks](05_masks.md).

```ruby
a = CArray.float64(3).seq
a[0] = UNDEF
a                #  => [ _, 1.0, 2.0 ]
a.has_mask?      #  => true
```

Arithmetic on a masked array carries the mask through automatically — the masked
position stays masked in the result:

```ruby
a + 10           #  => [ _, 11.0, 12.0 ]    the masked element propagates
```

`value` gives a view that ignores the mask and exposes the raw stored values:

```ruby
a.value          #  => [ 0.0, 1.0, 2.0 ]   the underlying storage, mask dropped
```

## data_type

CArray says **`data_type`**, not "dtype", for the element type of an array. It is
reported as a symbol.

```ruby
CArray.float64(3).data_type    #  => :float64
CArray.int32(3).data_type      #  => :int32
CArray.uint8(3).data_type      #  => :uint8
CArray.cmplx64(3).data_type    #  => :cmplx64    a 64-bit complex (2x float32)
```

## Scalar access returns a plain Ruby object

Indexing down to a single element returns an ordinary Ruby object — an `Integer`,
`Float`, `Complex`, `String`, etc. — not a zero-dimensional array.

```ruby
a = CArray.int32(2, 3).seq
a[1, 2]          #  => 5         a Ruby Integer
a[1, 2].class    #  => Integer
```

Compare this with indexing that leaves an axis open: as soon as any axis is
expressed with `nil` (or a range), the result is a CArray, not a scalar — even if
all but one position is pinned down:

```ruby
a[1, nil]        #  => [ 3, 4, 5 ]    a 1-D CArray (a CABlock view of row 1)
a[1, nil].class  #  => CABlock
```

## to_ca, copy, dup

These look similar but play different roles. The clearest way to keep them apart
is by *what you start from* and *what you want*:

The dividing line is simple: **`to_ca` presents existing data as a CArray with
the least work (no copy); `copy` owns the data (always a fresh copy).**

* **`copy`** — **own the data.** Always allocates a new, independent, contiguous
  entity — duplicating an entity, materialising a view. Use it when you will
  modify the result, must not disturb the original, or need real owned memory.

* **`to_ca`** — **present this as a CArray, doing the least work.** Anything that
  is already a CArray is handed back unchanged:
    * a CArray **entity** or a CArray **view** → returned as-is (`self`), no copy
      (a `CAWrap` wrapping external memory counts as a CArray too → `self`);
    * a **lazy view** (`a.lazy + 1`) has no data yet, so it is *evaluated* into an
      entity (like Ruby's `Enumerable#to_a` forcing a lazy enumerator);
    * a Ruby **`Array`** or a **`Numo::NArray`** → built into a new CArray (there
      is no existing buffer to present, so this one must allocate).

* **`dup` / `clone`** — Ruby's standard shallow copy. On an entity this happens to
  give an independent array, but on a **view it returns another view onto the same
  storage** — so it is *not* a reliable way to get an independent copy, and is a
  trap if you treat it like one. Prefer `copy`.

The three behave differently on the same view — `equal?` (Ruby object identity)
tells the story:

```ruby
a = CArray.int32(2, 3).seq
v = a[0, nil]              #  a view (CABlock)
v.to_ca.equal?(v)    #  => true    already a CArray → returned as-is
v.copy.equal?(v)     #  => false   a fresh owned copy (independent storage)
v.dup.equal?(v)      #  => false   a new object, but still a view of the same data
```

And to make the `dup` trap concrete: writing through the dup'd view still
reaches the original storage.

```ruby
d = v.dup
d[0] = 999
v[0]            #  => 999    v was changed, because d shares its storage
a[0, 0]         #  => 999    and so was a, the underlying entity
```

For arrays from other libraries that speak the MemoryView protocol (for example
Apache Arrow), use `CArray.from_memory_view(obj)` (copy) or
`CArray.wrap_memory_view(obj)` (zero-copy, yielding a `CAWrap`). See
MemoryView.

Rule of thumb: **`to_ca`** to get a CArray out of whatever you are holding (cheap);
**`copy`** when you need an independent, owned array. Avoid `dup` / `clone` for
making independent copies.

## Broadcasting

CArray's **broadcasting** only stretches axes of size 1; it never adds axes
implicitly to make shapes line up. Two arrays with different numbers of axes are
an error, not a silent re-interpretation. To add an axis on purpose, use `:_` in
the index. This differs from the implicit trailing-alignment used by some other
libraries. See [Broadcasting](07_broadcasting.md).

A 1-D array does not silently combine with a 2-D one — you have to say whether
it is a row or a column:

```ruby
a = CArray.int32(2, 3).seq
v = CA_INT([100, 200, 300])    #  shape [3] — one axis

a + v             #  => RuntimeError: elements mismatch (6 <-> 3)

a + v[:_, nil]    #  treat v as a row (shape [1, 3]) and broadcast it
#  => [ [ 100, 201, 302 ],
#       [ 103, 204, 305 ] ]
```

## Face

A **Face** is an extended data type built on top of CArray — a way to give the
raw numbers an interpretation, such as a calendar date (`CATime`). Faces are
an advanced topic with their own documentation; they are mentioned here only so
the word is not a surprise when you meet it.

## If you are coming from NumPy or Numo

| Their term            | In CArray                                         |
|-----------------------|---------------------------------------------------|
| dtype                 | `data_type`                                       |
| flat / ravel index    | address                                           |
| `transpose` (a view)  | `transpose` — a view, as expected                 |
| `reshape` makes a copy (Numo) | `reshape` returns a **view** — a notable difference; writing through it updates the source |
| fancy indexing makes a copy (index array / boolean array) | the same indexing returns a **view** in CArray; writing through it updates the source |
| `sort` makes a copy   | `sort`, `reverse`, `flip`, `shift`, `roll` all return **views** — the original is unchanged; apply in place with `a[] = a.sort` |
| masked array (special)| the mask is built in to every array; mark with `UNDEF` |
| `np.newaxis` / `None` | `:_`                                              |
| implicit broadcasting | explicit only — size-1 axes stretch, axes are never added implicitly |
| a view (anonymous)    | a view, but with a named class (`CABlock`, `CATranspose`, ...) |
| `axis=` argument      | `axis:` keyword (e.g. `a.sum(axis: 0)`); positional axis arguments are not accepted |
| `argmin` / `argmax`   | `min_index` / `max_index` (CArray uses `*_index` instead of `arg*`) |
