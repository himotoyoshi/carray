# String arrays

CArray represents strings in **four** ways.  Three of them are String
[Faces](CAFace.md) — dedicated classes that present a Ruby `String` per cell —
and the fourth is the raw fixed-width storage they can sit on.  They differ
only in *storage*: the surface (construction, fetch, string operations,
conversions) is uniform, so from a user's seat the choice is a storage
trade-off, not a different API.

| type | storage | mutable | portable¹ | when to use |
|---|---|---|---|---|
| **`CAString`** | `CA_OBJECT` (Ruby `String` per cell) | yes | no | general-purpose, arbitrary length / encoding |
| **`CAFixlenString`** | `CA_FIXLEN` (K bytes/cell) | yes | **yes** | bounded-width columns; interchange / on-disk / stacking |
| **`CAConstString`** | `int64` `(start,end)` pairs + one byte buffer | **no** | no | large, read-mostly label / key columns (sort / group / join) |
| raw `CA_FIXLEN` | `CA_FIXLEN` (K bytes/cell) | yes | yes | the untyped storage — bytes, not "strings" (see below) |

¹ *portable* = the Face survives multi-parent constructions (`CArray.stack`,
`Marshal`, MemoryView).  `CA_FIXLEN` bytes are self-contained; a `CA_OBJECT`
`VALUE` and a `CAConstString`'s shared buffer are per-process.

The three Faces vs. raw `CA_FIXLEN`: a raw fixlen array is *K-byte blobs* with
no string meaning, so it returns the raw padded bytes.  `CAFixlenString` is the
*string interpretation* of the same storage (trailing NUL is padding — see
[Fetch](#fetch-encoding-and-padding)).  Same bytes, different reading — exactly
what a Face is for.

---

## Choosing a type

- **Just working with strings?** `CAString`.  It holds Ruby `String`s directly,
  any length, any encoding, fully mutable.
- **Fixed-width column** (a database `CHAR(K)`, a fixed record field, something
  you want to `Marshal` / stack / export zero-copy)?  `CAFixlenString`.
- **A big, read-mostly column of labels / keys** you sort / group / join on?
  `CAConstString` — it packs the bytes into one shared buffer and stores a
  `(start, end)` byte range per element, so slicing / gathering / sorting only
  rearranges the ranges (no byte copy).
- **A high-duplication column** (a few distinct values repeated many times)?
  Reach for [`CACategorical`](../objects/CACategorical.md) (codes + a small dictionary =
  Arrow `DictionaryArray`) rather than `CAConstString`, which stores every
  element's bytes.

All three answer the same string methods; you can convert freely between them
(see [Conversions](#conversions)).

---

## Construction

```ruby
CArray.string(["alpha", "", "gamma"])          # CAString  (1-D from an Array)
CArray.string(3) { |i| "item#{i}" }            # block form
CArray.string([a, nil, b])                     # nil -> masked element

CArray.fixlen_string(["ab", "cde"], bytes: 4)  # CAFixlenString, slot width 4
CArray.fixlen_string(labels)                   # width defaults to the max bytesize
CArray.fixlen_string(x, bytes: 3, truncate: :silent)  # :error (default) | :silent

CArray.const_string(["alpha", "", "gamma"])    # CAConstString
CArray.const_string(labels, encoding: Encoding::UTF_8)
```

Shared conventions (all three):

- **`nil` is a masked element; `""` is a valid empty string** — distinct.
  `nil` fetches as `UNDEF`; `""` is a real zero-length string.
- A block of **arity 0** is evaluated once and broadcast (the same quirk as
  `CArray.float64(n){ ... }`); use `{ |i| ... }` for per-element values.

Type-specific:

- **`fixlen_string`** — `bytes:` is the slot width (default = the widest value).
  A value longer than the slot is governed by `truncate:` at *construction*
  time: `:error` (default) raises; `:silent` keeps the leading `bytes` bytes.
  (A per-cell `fix[i] = long` always truncates silently — the native fixlen
  store has no length check.)
- **`const_string`** — element encoding must match `:encoding` (default UTF-8);
  pure-ASCII passes regardless.  There is no offset-sharing dedup: every
  element's bytes are stored once in logical order (for a high-duplication
  column use [`CACategorical`](../objects/CACategorical.md) instead).

The raw storage, for completeness:

```ruby
CArray.new(CA_FIXLEN, [n], bytes: 3)   # K-byte blobs, NOT a string Face
```

---

## Fetch, encoding, and padding

```ruby
CArray.const_string(["a"])[0]     # => "a"      (frozen, UTF-8, column encoding)
CArray.string(["a"])[0]           # => "a"      (the stored Ruby String, its own encoding)
CArray.fixlen_string(["a"], bytes: 3)[0]   # => "a"   (trailing NUL stripped; ASCII-8BIT)
CArray.new(CA_FIXLEN, [1], bytes: 3).tap { |r| r[0] = "a" }[0]  # => "a\x00\x00" (raw bytes)
```

- **`CAFixlenString` strips trailing NUL on fetch.**  A fixed slot pads short
  strings with NUL, which is *padding, not content* — the same convention as
  NumPy's `'S'`/`'U'` dtypes.  So `str_len`, `upcase`, etc. see the logical
  string (`"a"`, length 1), not the padded `"a\x00\x00"`.  The *storage* keeps
  the padding, so `bytes`, sorting, and MemoryView still see the raw K bytes,
  and a **raw** `CA_FIXLEN` array (no Face) returns the padding.  Genuine
  trailing NULs can't survive this — use a raw fixlen array for binary blobs.
  (Fetched strings are `ASCII-8BIT`; `CAFixlenString` has no encoding tag —
  `force_encoding` if you need one.)
- **`CAConstString`** returns **frozen** strings in the column encoding.
- **`CAString`** returns the stored Ruby `String` as-is.

Views (`ct[1..3]`, `ct[mask]`, transpose, gather) return the *same* Face class
and, for `CAConstString`, share the buffer — only the `(start,end)` ranges are
rearranged.

---

## String operations

The String Faces mix in a common operation surface (numeric arrays have none of
these — that is the point of the Faces).  Output follows the return category:
a String result is a **`CAString`**, an Integer result an `:int` CArray, a
Boolean result a `:boolean` CArray.  Mask and shape are carried.

```ruby
s = CArray.string(["  Foo ", "bar", "BAZ"])

# transforms -> CAString
s.upcase        # => ["  FOO ", "BAR", "BAZ"]
s.strip         # => ["Foo", "bar", "BAZ"]
s.gsub("a", "@")
# also: downcase capitalize swapcase lstrip rstrip chomp
#       delete_prefix delete_suffix center ljust rjust
#       encode force_encoding scrub extract(regexp, repl='\0')

# predicates -> :boolean
s.start_with?("B")   # => [0, 0, 1]
s.end_with?("Z")     # also: include?(sub), match?(regexp)

# set membership -> :boolean  (marks EVERY matching cell)
s.in?("bar", "BAZ")  # => [0, 1, 1]

# lengths / positions -> :int      (str_ prefix where a bare name is an array op)
s.str_len            # per-cell character length   (#length/#size = element count)
s.bytesize
s.str_index("a")     # per-cell substring position (#index is an array method)
s.rindex("a")

# numeric parse
CArray.string(["12", "x", "34"]).to_i   # => [12, 0, 34]     (also to_f)
```

- **Naming.** Methods use the bare `String` name where it does not collide with
  a `CArray` method (`upcase`, `strip`, `start_with?`, `to_i`, …); the few that
  clash keep a `str_` prefix (`str_len`, `str_index`), because `#length` /
  `#index` already mean array-level things.
- **In place** (`upcase!`, `strip!`, `gsub!`, …) exist on the **mutable** Faces
  (`CAString`, `CAFixlenString`) only — `CAConstString` is read-only.
- **`CAConstString` runs the byte-level ones natively** (`eq`, `count`,
  `start_with?`, `end_with?`, `include?`, `byte_length`) — comparing record
  bytes directly, no per-cell Ruby `String`.  They override the generic path
  transparently; you call the same method.

**Formatting to strings** (the explicit stringify path, works on any array
including numeric — this is how numbers become strings, since the string
builders reject numeric arrays):

```ruby
values.format("%03d")                       # => CAString, per-cell (self is the first arg)
labels.format("%s = %d", values)            # => CAString, interleaving a second array
CArray.format("%s = %d", labels, values)    # => CAString, class form (scalars broadcast)
```

---

## Ordering and search

Ordering is by byte value (`memcmp`), which equals Ruby `String#<=>` within an
encoding — so it is faithful to sorting the Ruby strings.

```ruby
a.sort         # sorted, same Face class  (CAConstString: a no-copy view)
a.sort_copy    # sorted, standalone       (CAConstString only; owned + compacted)
a.sort_index   # ascending permutation -> :int
a.min / a.max  # byte-extremum element (skips masked; nil/UNDEF if all-masked)

ct.search("foo")            # CAConstString: flat index of the first match, or nil
ct.find_value_index("foo")  #   (native; the (start,end)-pair + buffer storage can't use the kernels)
```

Works on all three Faces for `sort` / `sort_index` / `min` / `max`
(`CAConstString` and raw fixlen via `memcmp`, `CAString` via `String#<=>`).
`sort` on `CAConstString` is a view (the `(start,end)` pairs are gathered, bytes never move);
`sort_copy` gives an owned, compacted column.

---

## Conversions

Convert **between the three Faces** with the `to_*` family — these are
String-Face methods (like the string operations, they are not on plain
`CArray`).  Each follows the `to_ca` principle: **self (zero-copy)** when self is
already the target Face compatibly, **materialise** (shape + mask carried)
otherwise.

```ruby
face.to_string                              # -> CAString
face.to_fixlen_string(bytes: K, truncate:)  # -> CAFixlenString
face.to_const_string(encoding:)             # -> CAConstString
```

For example `const.upcase` returns a `CAString`; chain `.to_const_string` (or
`.to_fixlen_string(bytes: K)`) to re-compact the result.

**From a non-Face array, use the builders.**  A raw `CA_FIXLEN` array or a
`CA_OBJECT` array of Strings becomes a Face through `CArray.string` /
`fixlen_string` / `const_string`, which accept a CArray source (a raw
`CA_FIXLEN` reads as NUL-stripped strings; a `CA_OBJECT` array wraps zero-copy):

```ruby
CArray.string(obj_array)          # CA_OBJECT of Strings -> CAString (zero-copy wrap)
CArray.const_string(raw_fixlen)   # K-byte blobs -> CAConstString (padding stripped)
CArray.fixlen_string(raw_fixlen)  # -> CAFixlenString (zero-copy wrap)
```

**A numeric array has no string reading** — the builders reject it (the mirror
of the numeric gate below).  Stringify explicitly with
[`#format` / `CArray.format`](#string-operations):

```ruby
CArray.string(int_array)          # => CArray::DataTypeError
int_array.format("%03d")          # => CAString  ["000", "001", ...]
```

---

## Numeric gate

There is no meaningful numeric reduction of a string column, and CArray refuses
to produce one silently.  `CAConstString` and `CAFixlenString` present a
`CA_FIXLEN` surface, so numeric kernels raise:

```ruby
ct.sum    # => CArray::DataTypeError
ct.mean   # => CArray::DataTypeError
```

(`CAConstString`'s storage is `int64` *(start,end) offset pairs* — running a
numeric kernel over them would produce garbage; the gate prevents exactly
that.)  `CAString` is
object-backed, so numeric folds fail at the element level instead.  Use the
string operations and `sort` / `min` / `max` above.

The mirror holds on the construction side: the string builders reject a numeric
array (there is no string reading of numbers), so a numeric-to-string is always
the explicit `#format` / `CArray.format` above — never a silent conversion.

---

## Interop and portability

- **`CAFixlenString`** is portable: its fixed-width bytes survive `CArray.stack`,
  `Marshal`, and MemoryView export.  This is the type to reach for when the
  strings must cross a boundary as a single contiguous block.
- **`CAConstString`** and **`CAString`** are per-process (a shared buffer / Ruby
  `VALUE`s), so they do not participate in those multi-parent constructions.
  `copy` gives an independent column; `to_fixlen_string(bytes: K)` gives a
  portable one.

> **Variable-length + MemoryView.** MemoryView (PEP 3118) is fixed-itemsize and
> cannot represent a variable-length column in a single view.  A
> `CAConstString`'s `(start,end)` pairs and byte buffer can be exported as two
> integer MemoryViews and reassembled out-of-band, but there is no single
> zero-copy MemoryView of "the strings" — that is the domain of the Arrow C Data
> Interface (not yet implemented).  The buffer is a pure concatenation
> (= Arrow values layout), so it can back an Arrow string array directly.

---

## `CAConstString` specifics

`CAConstString` is a compact, read-only column laid out Arrow-style — one shared
byte buffer holding the element bytes as a **pure concatenation** (= Arrow
values layout, no length prefix), plus an `int64` `(start, end)` byte-range pair
per element.  Each element is self-describing (carries its own range), so
slice / gather / sort views over the pairs stay permutation-safe with no byte
copy.  It fills the gap left by `CA_OBJECT` for large, read-mostly columns,
where per-element GC and memory overhead would otherwise dominate.

```ruby
ct.buffer      # => the frozen internal byte buffer (pure concatenation)
ct.encoding    # => the column Encoding

subset = ct[mask].copy   # standalone: fresh (start,end) pairs + a buffer holding
                         # ONLY the referenced bytes, repacked in logical order
```

`copy` (aliased `to_ca`) is the only point that descends out of the view
algebra: it produces a fresh column with a compacted buffer, so copying a small
slice of a large column shrinks memory accordingly.  A view keeps its parent
buffer alive while it lives (the ordinary meaning of a view); `copy` to detach
and shrink.  **Read-only by design** — mutable variable-length strings are
already covered by `CAString` / `CA_OBJECT`, and immutability is what makes the
shared buffer safe.

---

## See also

- [`CAFace.md`](CAFace.md) — the Face substrate these three build on.
- [`MemoryView.md`](../interop/MemoryView.md) — zero-copy interchange (relevant to
  `CAFixlenString`).
- [`InteropWithArrow.md`](../interop/InteropWithArrow.md) — importing an Arrow
  `String` / `LargeString` column into a `CAConstString`.
