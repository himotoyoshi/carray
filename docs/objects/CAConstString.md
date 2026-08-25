# CAConstString — read-only variable-length string column

`CAConstString` is a compact, read-only column of variable-length strings, laid
out Arrow-style as an `int64` `(start,end)` byte-range pair per element plus one
shared byte buffer (a pure concatenation of the element bytes).  It is the
read-mostly member of CArray's string-array family (`CAString`,
`CAFixlenString`, `CAConstString`), and like them it is a String
[Face](../topics/CAFace.md): it presents a Ruby `String` per cell over its own
storage.

Because each element is a `(start, end)` range into the shared buffer, slicing,
gathering, and sorting only rearrange the ranges — **the bytes never move**.
That makes it the type to reach for on a **large, read-mostly column of labels /
keys** you sort, group, or join on, where a `CA_OBJECT` column's per-element
`String` (GC pressure, per-object overhead) would dominate.

## When to use it

| you have… | reach for |
|---|---|
| a big, read-mostly label / key column (sort / group / join) | **`CAConstString`** |
| general-purpose, mutable, arbitrary length / encoding | `CAString` (`CA_OBJECT`) |
| a bounded fixed-width column you must `Marshal` / stack / export | `CAFixlenString` (`CA_FIXLEN`) |
| a **high-duplication** column (few distinct values, repeated) | [`CACategorical`](CACategorical.md) |

`CAConstString` stores **every element's bytes** once in logical order — there
is **no offset-sharing dedup**.  So for a column of a few distinct labels
repeated many times, [`CACategorical`](CACategorical.md) (dense integer codes +
a small label vocabulary = Arrow `DictionaryArray`) is the better fit: it stores
each distinct value once and only a small code per element.  One imports
straight from an Arrow `DictionaryArray` — see
[Interoperating with Arrow](../interop/InteropWithArrow.md#31-which-arrow-types-a-carray-can-hold).

## Construction

```ruby
CArray.const_string(["alpha", "", "gamma"])          # 1-D from an Array
CArray.const_string(labels, encoding: Encoding::UTF_8)
CArray.const_string(raw_fixlen)   # K-byte fixlen blobs -> CAConstString (padding stripped)
```

- **`nil` is a masked element; `""` is a valid empty string** — distinct. `nil`
  fetches as `UNDEF`; `""` is a real zero-length string.
- Element **encoding must match `:encoding`** (default UTF-8); pure-ASCII passes
  regardless.
- A block of **arity 0** is evaluated once and broadcast (the same quirk as
  `CArray.float64(n) { ... }`); use `{ |i| ... }` for per-element values.

## Fetch, buffer, and views

```ruby
ct = CArray.const_string(["a", "bb", "ccc"])

ct[0]        # => "a"        (frozen, in the column encoding)
ct.buffer    # => "abbccc"   (the frozen internal byte buffer — pure concatenation)
ct.encoding  # => the column Encoding
```

- Fetch returns a **frozen** `String` in the column encoding.
- A view (`ct[1..2]`, `ct[mask]`, transpose, gather) returns the **same Face
  class** and **shares the buffer** — only the `(start,end)` ranges are
  rearranged, no bytes are copied.  A view keeps its parent buffer alive while it
  lives (the ordinary meaning of a view).

`copy` (aliased `to_ca`) is the only point that descends out of the view
algebra: it produces a fresh column with a **compacted** buffer holding only the
referenced bytes, repacked in logical order — so copying a small slice of a large
column shrinks memory accordingly.

```ruby
subset = ct[mask].copy   # standalone: fresh (start,end) pairs + a buffer of
                         # ONLY the referenced bytes
```

**Read-only by design.**  There is no per-cell assignment and no in-place string
op.  Mutable variable-length strings are already covered by `CAString`
(`CA_OBJECT`); immutability is exactly what makes the shared buffer safe.

## String operations

Being a String Face, `CAConstString` answers the common string-operation surface
(transforms, predicates, lengths, parsing).  Output follows the return category:
a String result is a **`CAString`**, an Integer result an `:int` CArray, a
Boolean result a `:boolean` CArray; mask and shape are carried.

```ruby
ct = CArray.const_string(["Foo", "bar", "BAZ"])

ct.upcase            # => CAString ["FOO", "BAR", "BAZ"]   (transforms -> CAString)
ct.start_with?("B")  # => :boolean [0, 0, 1]
ct.in?("bar", "BAZ") # => :boolean [0, 1, 1]  (marks every matching cell)
ct.str_len           # => :int per-cell character length  (#length = element count)
```

- **In-place ops (`upcase!`, `strip!`, …) are not available** — those exist only
  on the mutable Faces (`CAString`, `CAFixlenString`).  A transform returns a
  fresh `CAString`; chain [`.to_const_string`](#conversions) to re-compact it.
- **The byte-level operations run natively** (`eq`, `count`, `start_with?`,
  `end_with?`, `include?`, `byte_length`) — comparing record bytes directly, with
  no per-cell Ruby `String`.  They override the generic path transparently; you
  call the same method.
- **Naming.** Methods use the bare `String` name where it does not collide with a
  `CArray` method (`upcase`, `start_with?`, …); the few that clash keep a `str_`
  prefix (`str_len`, `str_index`), because `#length` / `#index` already mean
  array-level things.

To turn a **numeric** array into strings, stringify explicitly with
`#format` / `CArray.format` (the string builders reject numeric arrays):

```ruby
values.format("%03d")   # => CAString ["001", "042", ...]
```

## Ordering and search

Ordering is by byte value (`memcmp`), which equals Ruby `String#<=>` within an
encoding — so it is faithful to sorting the Ruby strings.

```ruby
ct.sort         # sorted, same class — a NO-COPY VIEW (the (start,end) pairs are
                #   gathered; the bytes never move)
ct.sort_copy    # sorted, standalone — an owned, compacted column
ct.sort_index   # ascending permutation -> :int
ct.min / ct.max # byte-extremum element (skips masked; nil / UNDEF if all-masked)

ct.search("foo")            # flat index of the first match, or nil
ct.find_value_index("foo")  # (native — the (start,end)-pair + buffer storage
                            #  can't use the generic search kernels)
```

`sort` is cheap precisely because it is a view over rearranged ranges; use
`sort_copy` when you want an owned, compacted result.

## Numeric gate

There is no meaningful numeric reduction of a string column, and CArray refuses
to produce one silently.  `CAConstString` presents a `CA_FIXLEN` surface, so
numeric kernels raise:

```ruby
ct.sum    # => CArray::DataTypeError
ct.mean   # => CArray::DataTypeError
```

Its storage is `int64` *(start,end) offset pairs* — running a numeric kernel over
them would produce garbage, and the gate prevents exactly that.  Use the string
operations and `sort` / `min` / `max` above.

## Conversions

Convert **between the String Faces** with the `to_*` family (String-Face methods,
not on plain `CArray`).  Each follows the `to_ca` principle: **self (zero-copy)**
when self is already the target Face compatibly, **materialise** (shape + mask
carried) otherwise.

```ruby
ct.to_string                              # -> CAString
ct.to_fixlen_string(bytes: K, truncate:)  # -> CAFixlenString (portable, fixed width)
face.to_const_string(encoding:)           # any String Face -> CAConstString
```

For example `ct.upcase` returns a `CAString`; chain `.to_const_string` to
re-compact the result into a fresh `CAConstString`.

## Interop and portability

`CAConstString` is **per-process**: its shared byte buffer does not survive the
multi-parent constructions that portable types do.

- It does **not** participate in `CArray.stack`, `Marshal`, or MemoryView export
  as a single block.  For a portable column use `to_fixlen_string(bytes: K)`
  (fixed-width `CA_FIXLEN` bytes travel), or `copy` for an independent in-process
  column.
- **Variable-length + MemoryView.** MemoryView (PEP 3118) is fixed-itemsize and
  cannot represent a variable-length column in one view.  A `CAConstString`'s
  `(start,end)` pairs and byte buffer can be exported as two integer MemoryViews
  and reassembled out-of-band, but there is no single zero-copy MemoryView of
  "the strings" — that is the domain of the Arrow C Data Interface (not yet
  implemented).
- The buffer is a **pure concatenation** (= Arrow values layout, no length
  prefix), so it can back an Arrow string array directly, and an Arrow
  `String` / `LargeString` column imports into a `CAConstString`.

## See also

- [`StringArrays.md`](../topics/StringArrays.md) — the whole string-array family
  side by side (`CAString`, `CAFixlenString`, `CAConstString`, raw `CA_FIXLEN`)
  and how to choose between them.
- [`CAFace.md`](../topics/CAFace.md) — the Face substrate this builds on.
- [`CACategorical.md`](CACategorical.md) — the better fit for a high-duplication
  label column.
- [`InteropWithArrow.md`](../interop/InteropWithArrow.md) — importing an Arrow
  `String` / `LargeString` column.
