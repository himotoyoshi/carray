# CARefer — byte-reinterpret and shape-rewrite view

`CARefer` is the view class behind `CArray#refer`, `#reshape`, and
`#flatten`. It re-presents a parent's **raw bytes** as an array of a
possibly different `data_type`, byte width, or shape — with no copy. It is
the tool for:

- viewing the same bytes as another element type (`uint32` ⇄ `int32`,
  `uint32` → two `uint16`s, four `uint8`s → one `uint32`),
- changing shape (`reshape`, `flatten`), and
- carrying a record schema over a reinterpreted buffer (a `data_class`
  argument yields a `CARecord`).

`CARefer` is the sibling of `CAStride`: a same-width, same-type reshape is
usually rewritten to a plain `CAStride` directly.
What makes `CARefer` distinct is the **byte-level reinterpret** — a
different `data_type` or `bytes` that a pure stride cannot express — and,
with it, the three mask-translation modes documented in §5.

This document covers the various uses of `CARefer` and, in detail, **how
masks behave** across width changes.

---

## 1. What a CARefer is

`CARefer` wraps **one parent CArray** and describes how to read its bytes:

- **`data_type`** — the element type the bytes are read as
- **`bytes`** — the view's element width
- **`dim`** — the view's shape (row-major, contiguous over its own bytes)
- **`offset`** — a starting offset, measured in *parent elements*

The parent's byte buffer is reinterpreted straight through. The only hard
rule is that element boundaries must line up: the view width must divide
the parent width, or vice versa, and the total byte extent must fit inside
the parent.

```ruby
require "carray"

a = CArray.uint32(2)
a[] = [0x00010002, 0x00030004]

a.refer(CA_INT32).to_a       #=> [65538, 196612]   (same bytes, signed view)
```

Because it reads bytes as-is, `CARefer` reflects the platform's byte
order — no endianness conversion is applied.

---

## 2. Reinterpreting the element type — `#refer`

```ruby
a.refer                                   # same type, shape, width — a plain alias
a.refer(data_type, dim = nil, bytes: nil, offset: 0)
a.refer(data_class, dim, ...)             # → CARecord
```

`refer` has three width relationships between the parent and the view.

### 2.1 Same width — pure reinterpret

When the view width equals the parent width, `dim` may be omitted (it
reuses the parent's shape):

```ruby
a = CArray.uint32(2)
a[] = [0x00010002, 0x00030004]

a.refer(CA_INT32).to_a       #=> [65538, 196612]
a.refer(CA_FLOAT32).to_a     # same 8 bytes read as two float32
```

### 2.2 Divided — one parent element splits into several

When the view width is **smaller** and divides the parent width, each
parent element becomes `ratio = parent.bytes / bytes` view elements. You
must give the new shape explicitly:

```ruby
a = CArray.uint32(2)
a[] = [0x00010002, 0x00030004]           # 8 bytes total

d = a.refer(CA_UINT16, [4])              # 8 / 2 = 4 uint16 elements
d.to_a                                    #=> [2, 1, 4, 3]   (little-endian halves)
```

### 2.3 Spanned — several parent elements fold into one

When the view width is **larger** and is a multiple of the parent width,
`ratio = bytes / parent.bytes` adjacent parent elements combine into one
view element:

```ruby
b = CArray.uint16(4)
b[] = [2, 1, 4, 3]                        # 8 bytes total

s = b.refer(CA_UINT32, [2])              # 4 / 2 = 2 uint32 elements
s.to_a                                    #=> [65538, 196612]
```

### 2.4 `offset:` and `bytes:`

`offset:` skips a number of **parent elements** before the view starts;
`bytes:` overrides the view element width (usually inferred from the
type). The view's total byte extent must still fit inside the parent.

```ruby
o = CArray.uint32(4).seq                  # [0, 1, 2, 3]
o.refer(CA_UINT32, [2], offset: 2).to_a   #=> [2, 3]
```

### 2.5 A `data_class` argument → `CARecord`

When the type argument is a **data class** (e.g. a `CAStruct` subclass),
the reinterpret is wrapped in a `CARecord` so field projection keeps
working over the reinterpreted bytes. See [CARecord.md](CARecord.md).

---

## 3. Rewriting shape — `#reshape` and `#flatten`

`reshape` and `flatten` keep the type and width and only change the shape.
When the new shape is expressible as strides over the parent's deepest
ancestor, the result is a `CAStride` (cheaper to compose); otherwise it
falls back to a `CARefer`. Either way it is a zero-copy view.

```ruby
m = CArray.int32(6).seq
m.reshape(2, 3).to_a         #=> [[0, 1, 2], [3, 4, 5]]
m.flatten.to_a               #=> [0, 1, 2, 3, 4, 5]
```

**Placeholders** make the target shape easier to write:

```ruby
m = CArray.int32(12).seq

m.reshape(3, -1).dim         #=> [3, 4]    (-1 infers the remaining axis)
m.reshape(2, :~).dim         #=> [2, 6]    (:~ is the same auto-infer sigil)

b = CArray.int32(2, 3).seq
b.reshape(nil, nil).dim      #=> [2, 3]    (nil copies the source axis)
```

**Element count is conserved.** Without a placeholder, the product of the
new shape must equal the source element count — a mismatch raises rather
than silently truncating:

```ruby
m.reshape(5)                 # RuntimeError: cannot reshape 12 elements into 5
```

At most one `-1` / `:~` placeholder is allowed.

---

## 4. It is a view — writes reach the parent

`CARefer` copies nothing. Writing through it lands in the parent's bytes:

```ruby
m = CArray.int32(6).seq
r = m.reshape(2, 3)
r[0, 0] = 99
m[0]                         #=> 99
```

To get an independent, detached array, materialise with `copy` (always a
fresh entity). See the view-vs-owned semantics in the project docs.

---

## 5. Mask behavior

This is where the byte-reinterpret shows its subtlety. A `CARefer` over a
**masked** parent produces a masked view, and the mask is translated to
match the width change. There are three modes — the same three as the data
(§2), applied to the parent's mask.

### 5.1 Same width — the mask is reflected 1:1

A same-width reinterpret or a reshape reflects each parent mask bit to the
corresponding view cell:

```ruby
a = CArray.uint32(3).seq
a[1] = UNDEF
a.refer(CA_INT32).is_masked.to_a    #=> [0, 1, 0]

r = CArray.int32(6).seq
r[2] = UNDEF
r.reshape(2, 3).is_masked.to_a      #=> [[0, 0, 1], [0, 0, 0]]
```

### 5.2 Divided — each parent bit broadcasts across its sub-cells

When one parent element splits into `ratio` view elements, its single mask
bit is **broadcast** to all `ratio` sub-cells: if the parent value was
masked, every piece of it is masked.

```ruby
b = CArray.uint32(3).seq
b[1] = UNDEF                          # parent element 1 masked

d = b.refer(CA_UINT16, [6])          # ratio 2
d.is_masked.to_a                      #=> [0, 0, 1, 1, 0, 0]
#                                          └───┘  └──┘  └───┘
#                                          elem0  elem1 elem2
```

### 5.3 Spanned — parent bits OR-reduce into one

When `ratio` parent elements fold into one view element, their mask bits
are combined with **logical OR**: the view cell is masked if *any* of the
parent elements it covers was masked.

```ruby
c = CArray.uint16(4).seq
c[1] = UNDEF                          # elements 0 and 1 fold into view cell 0

e = c.refer(CA_UINT32, [2])          # ratio 2
e.is_masked.to_a                      #=> [1, 0]
#                                          │  └ covers elements 2,3 (both clear)
#                                          └── covers elements 0,1 (1 is masked → masked)
```

This OR-reduction is the conservative choice: a reinterpreted value cannot
be trusted if any byte of it came from a masked source element.

> **Under the hood.** Same-width masks are a `CARefer` over the parent's
> mask; divided masks are built from a `CARepeat` that broadcasts each bit
> across the ratio; spanned masks are built from a `CAReduce` that
> OR-folds the ratio adjacent bits. You never see these intermediates —
> they are the view's mask companion (`CAReferMask`).

---

## 6. Constraints and errors

| condition | result |
|---|---|
| view width does not divide parent width (or vice versa) | `RuntimeError` |
| `offset` negative | `RuntimeError` |
| view byte extent exceeds the parent | `RuntimeError` |
| `CA_OBJECT` parent reinterpreted as a non-object type | `RuntimeError` |
| `reshape` product ≠ element count (no placeholder) | `RuntimeError` |
| more than one `-1` / `:~` placeholder | `RuntimeError` |
| `reshape` with a different byte width but no `dim` | `RuntimeError` |

`CA_OBJECT` cannot be reinterpreted as a numeric type — its elements are
Ruby object references, not fixed-width bytes.

---

## 7. Cost model

- **Construction** is O(1): the view stores its shape, strides, offset,
  and parent reference.
- **Reading / writing a cell** is a single strided access into the
  parent's bytes; no per-cell conversion.
- **Same-width reshape / flatten** rewrites to a `CAStride` where possible,
  so it composes cheaply through chains of views.
- **Materialising** (`to_ca` / `copy` / feeding a kernel) copies the
  view's bytes into a contiguous buffer.

---

## 8. Quick reference

| call | result |
|---|---|
| `a.refer` | same-type, same-shape alias |
| `a.refer(data_type)` | same-width reinterpret (shape reused) |
| `a.refer(data_type, dim)` | divided/spanned reinterpret to `dim` |
| `a.refer(data_type, dim, offset: n)` | start `n` parent elements in |
| `a.refer(data_class, dim)` | `CARecord` over the reinterpreted bytes |
| `a.reshape(*dim)` | shape rewrite (`CAStride` or `CARefer`) |
| `a.reshape(3, -1)` / `(2, :~)` | infer one axis from the element count |
| `a.reshape(nil, ...)` | copy that axis from the source shape |
| `a.flatten` | 1-D row-major view |
| mask, same width | reflected 1:1 |
| mask, divided | each parent bit broadcast across `ratio` cells |
| mask, spanned | `ratio` parent bits OR-reduced into one |

## See also

- `CAStride` — the pure strided-view base; same-width reshapes rewrite to
  it.
- [CARecord.md](CARecord.md) — schema-carrying record arrays, produced by
  the `data_class` form of `refer`.
- [CAField.md](CAField.md) — the field-of-a-record view, another byte-window
  reinterpret.
