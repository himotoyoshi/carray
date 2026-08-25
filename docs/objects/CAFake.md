# CAFake — a value-casting reinterpret view

`CAFake` is the view class behind `CArray#fake`. It presents a parent
array **as if it had a different `data_type`**, casting each value on read
and on write — the live, view-shaped equivalent of `to_type`. The parent's
storage is shared: reading a cell casts the stored value to the view's
type, and writing a cell casts back into the parent's type.

```
parent = int32[ 0, 1, 2 ]

a.fake(:float64)      →  [0.0, 1.0, 2.0]     (each value cast int → float)
```

## `fake` vs `refer` — cast the value, not the bytes

This is the one thing to get straight. `CAFake` casts **values**;
[CARefer](CARefer.md) reinterprets **bytes**. On the same `int32` parent:

```ruby
a = CArray.int32(3).seq        # [0, 1, 2]

a.fake(:float64).to_a          #=> [0.0, 1.0, 2.0]
#   value cast: the integer 1 becomes the float 1.0

a.refer(CA_FLOAT32).to_a       #=> [0.0, 1.401e-45, 2.803e-45]
#   byte reinterpret: the int32 bit pattern of 1 read as a float32
```

Reach for `fake` when you want the *numbers* in another type; reach for
`refer` when you want the *bytes* under another lens.

---

## 1. What a CAFake is

`CAFake` wraps **one parent CArray** and a target `data_type` (plus
`bytes` for `:fixlen`). It keeps the parent's shape and element count —
each parent cell maps one-to-one to a view cell — and runs every access
through the cast table:

```
result.ndim  == parent.ndim
result.shape == parent.shape
```

There is no separate buffer while the view is live: `fake` shares the
parent's storage and casts on the fly. Materialising the view (`to_ca` /
`copy`) is what produces an independent cast array.

```ruby
require "carray"

a = CArray.int32(3).seq
f = a.fake(:float64)
f.class                        #=> CAFake
f.to_a                         #=> [0.0, 1.0, 2.0]
```

---

## 2. Creating a CAFake — `CArray#fake`

```ruby
a.fake(data_type)              # numeric / boolean reinterpret-by-cast
a.fake(:fixlen, bytes: n)      # fixlen needs an element width
```

`data_type` accepts the usual spellings (`:float64`, `CA_FLOAT64`, a type
constant, …). For `:fixlen` you must pass `bytes:` so the view knows each
element's width.

```ruby
a.fake(:float64)               # int → float on the fly
a.fake(:int16)                 # narrow on the fly
CArray.fixlen(2, bytes: 4).fake(:fixlen, bytes: 2)   # 4-byte text seen as 2-byte
```

---

## 3. Reads and writes both cast

Because storage is shared, a read casts the parent value to the view type,
and a write casts the incoming value back to the parent type. The parent's
type is the real one, so **anything the parent type cannot hold is lost on
write** — exactly like assigning through `to_type`.

```ruby
a = CArray.int32(3).seq        # [0, 1, 2]  (int32 storage)
f = a.fake(:float64)

f[0] = 9.7                     # cast float → int on write
a.to_a                         #=> [9, 1, 2]   (fractional part dropped)
```

A float parent viewed as an integer truncates on read, since the value —
not the bit pattern — is converted:

```ruby
g = CArray.float64(3)
g[] = [1.9, 2.1, 3.5]
g.fake(:int32).to_a            #=> [1, 2, 3]
```

`fixlen` widths truncate the same way:

```ruby
s = CArray.fixlen(2, bytes: 4)
s[] = ["ab", "cdef"]
s.fake(:fixlen, bytes: 2).to_a #=> ["ab", "cd"]
```

To get an independent, materialised cast instead of a live view, use
`copy` (or `to_ca`) — or just `to_type`, which returns an owned array
directly.

---

## 4. Masks

A masked parent yields a masked `CAFake`; each parent mask bit is
reflected 1:1 to the view (the shape is unchanged, so there is no width
translation as there is in `CARefer`):

```ruby
m = CArray.int32(3).seq
m[1] = UNDEF
m.fake(:float64).is_masked.to_a   #=> [0, 1, 0]
```

---

## 5. Cost model

- **Construction** is O(1): the view stores only the target type and the
  parent reference.
- **Reading / writing a cell** costs one cast-table call per element.
- **Materialising** (`to_ca` / `copy` / feeding a kernel) casts every
  element into a contiguous buffer of `parent.elements` elements.
- Because every access transforms values, `CAFake` never folds into a
  plain strided gather — the cast is a genuine transform boundary. It is
  also the auto-cast used internally when a kernel needs its operand in a
  specific type.

---

## 6. `fake` vs `refer` vs `to_type` — quick guide

| you want | use | result |
|---|---|---|
| the same **values** in another type, as a live view | `a.fake(t)` | `CAFake`, shares storage, casts each access |
| the same **values** in another type, as an owned array | `a.to_type(t)` | independent CArray |
| the same **bytes** under another type | `a.refer(t, dim)` | `CARefer`, reinterprets the bit pattern |

---

## 7. Quick reference

| call | result |
|---|---|
| `a.fake(data_type)` | `CAFake` view, same shape, values cast to `data_type` |
| `a.fake(:fixlen, bytes: n)` | fixlen view with element width `n` |
| read | parent value cast to the view type |
| write | incoming value cast back to the parent type (lossy if narrower) |
| masked parent | masked `CAFake` (mask reflected 1:1) |
| independent copy | `a.fake(t).copy` or, more directly, `a.to_type(t)` |

## See also

- [CARefer.md](CARefer.md) — the byte-reinterpret sibling; contrast with
  `fake`'s value cast.
- [CastAndPromote.md](../authoring/CastAndPromote.md) — the canonical type-coercion
  paths (`to_type`, `wrap_readonly`, `result_type`).
