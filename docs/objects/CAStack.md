# CAStack — outer-axis stack view of K uniform parents

`CAStack` is the view class behind CArray's view-default composition
methods (`CArray.stack`, `meld`, `montage`, `CArray#stack`).  It presents
**K uniform-shape parent arrays as one array**, with a single new axis —
the *K axis* — that selects which parent an element comes from.  No data
is copied: a `CAStack` gathers from its parents on demand, and writes flow
straight back to them.

```
a = [1 2 3]     b = [4 5 6]     c = [7 8 9]     each shape [3]

CArray.stack([a, b, c])          k_axis = 0, shape [3, 3]

  K axis ↓
  ┌───────────┐
  │ 1  2  3   │  ← a   (result[0] is a)
  │ 4  5  6   │  ← b   (result[1] is b)
  │ 7  8  9   │  ← c   (result[2] is c)
  └───────────┘
```

This document is the reference for the `CAStack` **view class** itself —
its structure, the K axis, view/write semantics, the cost model, and how
masks behave.  For the full composition cheat-sheet (`stack` vs `meld` vs
`montage` vs the ragged eager `concatenate` / `mosaic` / `tabulate`), see
[Composition.md](../topics/Composition.md).

---

## 1. What a CAStack is

A `CAStack` wraps **K parent CArrays that share the same shape, ndim,
`data_type`, and byte width**.  It adds one dimension — the K axis — so
that

```
result.ndim  == parent.ndim + 1
result.shape == parent.shape with K inserted at k_axis
```

The K axis is where the question *"which source array?"* lives.  Every
other axis follows each parent's own layout, element for element.

The uniformity requirement is strict: parents are neither broadcast nor
coerced.  `CArray.stack` runs `promote_list` first to reconcile numeric
`data_type`s (e.g. `int32` + `float64` → `float64`), but the shapes must
already agree — otherwise the constructor raises `ArgumentError`.

```ruby
require "carray"

a = CA_INT([[1, 2, 3], [4, 5, 6]])       # shape [2, 3]
b = CA_INT([[7, 8, 9], [10, 11, 12]])
c = CA_INT([[13, 14, 15], [16, 17, 18]])

s = CArray.stack([a, b, c])
puts s.inspect
#=> <CAStack.int32(3,2,3): elem=18 mem=72b
#   [ [ [ 1, 2, 3 ],
#       [ 4, 5, 6 ] ],
#     [ [ 7, 8, 9 ],
#       [ 10, 11, 12 ] ],
#     [ [ 13, 14, 15 ],
#       [ 16, 17, 18 ] ] ]>
```

Typical sources of a `CAStack`: atmospheric or depth layers, satellite
band stacks, ensemble members, multi-annotator ground truth, or any "K
independent observations of the same grid" pattern.

---

## 2. Constructing a CAStack

Any of these produce a `CAStack` view (see [Composition.md](../topics/Composition.md)
for `meld` / `montage`, which build on `CAStack` internally):

```ruby
CArray.stack(list, axis: 0, data_type: nil)   # class method
a.stack(b, c, axis: 0)                         # instance method: [self, b, c]
some_stack.append(d, e)                        # extend an existing stack
```

- **`CArray.stack(list, axis:)`** stacks `list` along a new K axis at
  position `axis` (default 0).  Runs `promote_list` for a common
  `data_type`; re-wraps homogeneous Face inputs (`CATime`, …) so the
  Face stays on top.
- **`CArray#stack(*others, axis:)`** always treats `self` as one parent —
  even when `self` is itself a `CAStack` (it becomes a nested parent, not
  a flat append).
- **`CAStack#append(*others)`** flat-appends into the receiver's parents,
  **preserving `k_axis`**.  Stack depth stays 1; parents remain leaf
  arrays rather than nesting.

```ruby
s = CArray.stack([a, b])            # 2 parents, k_axis = 0
s = s.append(c)                     # 3 parents, k_axis = 0  (flat)
```

`CArray#split(axis:)` is the inverse: it slices an array along one axis
into an Array of `(ndim-1)`-D `CABlock` views that round-trip back through
`CArray.stack`.

```ruby
CArray.stack(a.split(axis: 0), axis: 0) == a   # true
```

---

## 3. The K axis (any position)

The K axis can be inserted at **any position** in `[0, parent.ndim]`, not
just the front.  `axis:` accepts negative indices.  This lets one set of
parents present as time-outermost, channel-innermost, or anything between,
without copying.

```ruby
a = CA_INT([[1, 2, 3], [4, 5, 6]])       # shape [2, 3]
b = CA_INT([[7, 8, 9], [10, 11, 12]])
c = CA_INT([[13, 14, 15], [16, 17, 18]])

CArray.stack([a, b, c], axis: 0).shape    #=> [3, 2, 3]   K outermost
CArray.stack([a, b, c], axis: 1).shape    #=> [2, 3, 3]   K in the middle
CArray.stack([a, b, c], axis: -1).shape   #=> [2, 3, 3]   K innermost (RGB pattern)
```

`axis: -1` is the channel-data idiom: for 2-D image parents `[H, W]`, an
RGB stack is `[H, W, 3]` with each parent contributing one channel plane.

The design keeps the K axis to a single position deliberately.  Rearranging
it further is a job for `transpose` on the resulting view — a chain
(`stack(...).transpose(...)`) rather than a fatter node.

---

## 4. Introspection

A `CAStack` exposes its structure directly:

```ruby
s = CArray.stack([a, b, c], axis: -1)

s.n_parents      #=> 3          number of parents (K)
s.k_axis         #=> 2          resolved K-axis position
s.parents        #=> [a, b, c]  the parent arrays, identity preserved
s.parents[0].equal?(a)   #=> true
```

`parents` returns the actual parent objects (identity preserved), which is
what makes `append` and round-tripping through `split` exact.

---

## 5. View semantics: writes flow to the parents

A `CAStack` owns no buffer.  Reads gather from the parents; **writes scatter
straight back into them**.

```ruby
a = CA_INT([1, 2, 3])
b = CA_INT([4, 5, 6])
s = CArray.stack([a, b])

s[0, 1] = 99                 # write one cell
a.to_a                       #=> [1, 99, 3]   ← parent a mutated

s[1, nil] = CA_INT([40, 50, 60])
b.to_a                       #=> [40, 50, 60] ← parent b mutated
```

### `to_ca` vs `copy`

A `CAStack` **is** a CArray, so `to_ca` returns **self** — it does *not*
materialise.  Use `to_ca` when you only need "a CArray to read or pass
along"; it is a no-op and cheap.

```ruby
s.to_ca.equal?(s)   #=> true    (no copy — same object)
```

To obtain an **independent, contiguous buffer** (for binary I/O, a
MemoryView export, or a C extension that calls `ca_attach`), use **`copy`**.
`copy` always materialises and always owns its data.

```ruby
t = s.copy          # fresh contiguous CArray, independent of the parents
t.class             #=> CArray
t[0, 0] = -99       # does NOT touch a / b
```

This follows CArray's general `to_ca` / `copy` contract: `to_ca` = "hand
me a CArray, minimal work"; `copy` = "give me my own data".  Reach for
`copy` whenever you want the stack flattened into a standalone array.

---

## 6. Cost model: partial use, partial cost

`CAStack` is a **refuse-to-materialise** view: its value is letting you
touch a large K-parent volume without ever allocating `K × parent` bytes at
once.  Two delivery paths coexist:

- **Gather path (preferred).**  Slicing, iterating, and the reduction
  kernels reach the parents through region requests, so **only the touched
  region is fetched**.  A slice that lands inside a single parent folds
  directly to that parent; a slice spanning parents dispatches K-fold, once
  per parent, over just its sub-region.

  ```ruby
  s[1, 0..1, 0..2]     # inside parent 1 → folds to a single-parent fetch
  s[0..2, 0, 0..1]     # spans parents   → K-fold dispatch, per-parent sub-region
  ```

- **Attach path (materialise).**  `copy`, `ca_attach`, and any operation
  that needs one contiguous buffer materialise the whole thing — peak
  allocation is `K × parent.elements × bytes`.  This always works; it is
  simply the expensive path, and it is the caller's choice.

The guiding priority is **peak-memory over throughput**: `CAStack` exists
so that "K huge grids" never have to become one huge allocation just to be
read or reduced.  Prefer the gather path (slices, reductions) and only
`copy` when a contiguous buffer is genuinely required.

---

## 7. Reductions along the K axis

Because reductions reach the parents through the gather path, you can
reduce a `CAStack` **without materialising it** — including along the K
axis itself, which is the common "average over layers / ensemble members"
operation.

```ruby
s = CArray.stack([a, b, c])      # shape [3, 2, 3], k_axis = 0

s.mean(axis: 0)                  # mean over the 3 parents, per grid cell
#=> <CArray.float64(2,3): ...
#   [ [ 7.0, 8.0, 9.0 ],
#     [ 10.0, 11.0, 12.0 ] ]>
```

The reduction walks per-slab tiles and reuses one small buffer across the
K parents, so there is no full-volume materialisation on the way to the
result.  `sum`, `min`, `max`, `mean`, `variance`, and the rest of the
reduction family behave the same way, along the K axis or any other.

---

## 8. Mask: horizontal propagation across parents

Masking a `CAStack` is self-similar — the mask of a `CAStack` is itself a
`CAStack` over the parents' masks (class `CAStackMask`).  The distinctive
behaviour is **horizontal propagation**: the first time the stack gains a
mask, it forces **every parent** to acquire an (all-unmasked) mask, so all
parents keep uniform mask capacity.

```ruby
x = CArray.float64(3) { |i| i }        # no mask
y = CArray.float64(3) { |i| 10 + i }   # no mask

s = CArray.stack([x, y])
s[0, 0] = UNDEF                        # mask one cell of the stack

x.has_mask?   #=> true   ← forced to gain a mask
y.has_mask?   #=> true   ← forced too (horizontal propagation)

puts s.inspect
#=> <CAStack.float64(2,3): elem=6 mask=1 mem=48b
#   [ [ _, 1.0, 2.0 ],
#     [ 10.0, 11.0, 12.0 ] ]>
```

This is on top of the ordinary vertical propagation (a masked value on the
stack lands in the corresponding parent).  Horizontal propagation is what
keeps the K parents interchangeable once masking is in play.

---

## 9. Materialisation and interop

- **Independent contiguous CArray:** `copy` (see §5).
- **MemoryView / binary I/O / C `ca_attach`:** these need a contiguous
  buffer, so `copy` first, then export the resulting entity.  A `CAStack`
  gathers from K separate parents and has no single backing buffer to hand
  out zero-copy.
- **`to_ca`** is *not* a materialiser here — it returns the stack unchanged.

```ruby
buf = CArray.stack(layers, axis: 0).copy    # contiguous [K, H, W]
buf.dump_binary(io)                          # now safe for I/O / export
```

---

## 10. Where CAStack sits

- Class: `CAStack < CAView < CArray`; mask class `CAStackMask`.
- `obj_type`: `CA_OBJ_STACK`; multi-parent (`CA_FLAG_MULTI_PARENTS`).
- Implementation: `ext/ca_obj_stack.c`; Ruby surface in
  `lib/carray/stack.rb`.

Unlike the CAStride family (`CABlock`, `CARefer`, …), a `CAStack` cannot be
expressed as a single strided gather off one buffer — it dispatches per
parent — so it is its own view kind rather than a CAStride typedef.

---

## 11. Known limitations

- **Scalar (ndim-dropping) indexing on a `CAStack`-rooted view triggers a
  full materialise.**  `stack[k, nil]` drops the K axis and falls back to
  materialising.  To stay on the gather path, use range indexing —
  `stack[k..k, nil]` — or `copy` upfront if you are going to touch most of
  the data anyway.
- **No zero-copy MemoryView export.**  `copy` to a contiguous entity first
  (§9).

---

## 12. Quick reference

| Method | Kind | Returns | Notes |
|---|---|---|---|
| `CArray.stack(list, axis:)` | class | `CAStack` view | new K axis at `axis` |
| `CArray#stack(*others, axis:)` | instance | `CAStack` view | `self` is one parent |
| `CAStack#append(*others)` | instance | `CAStack` view | flat-append, keeps `k_axis` |
| `CArray#split(axis:)` | instance | `Array<CABlock>` | inverse of `stack` |
| `stack.n_parents` | attr | Integer | K |
| `stack.k_axis` | attr | Integer | resolved K-axis position |
| `stack.parents` | attr | `Array<CArray>` | parents, identity preserved |
| `stack.to_ca` | — | **self** | no copy |
| `stack.copy` | — | `CArray` | materialise, independent, contiguous |

See also: [Composition.md](../topics/Composition.md) (the full `stack` / `meld` /
`montage` / ragged family), [IteratorFamily.md](../topics/IteratorFamily.md), and
[MemoryView.md](../interop/MemoryView.md).
