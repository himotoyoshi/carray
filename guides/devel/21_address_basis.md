# 21 The address basis (`CArray::AddressBasis`)

Every surface in Part III hands a kernel its *cells*: the kernel iterator
delivers a slab or a fiber at a time, the sweep ELEMENT family delivers one
element at a time, `call_cfunc` delivers the arguments of a scalar call.

Some code does not want cells. A kernel generated from an expression writes
its own loop — it reads `a[i-1]` and writes `a[i]`, or it reaches across two
axes for a stencil — and what it needs from CArray is not delivery but an
**addressing basis**: a pointer, a byte offset, and one byte stride per axis.
Given those, it addresses cells itself.

`CArray::AddressBasis` lends exactly that, for the length of a block.

```
ext/carray_address_basis.c          the whole surface, one file
```

It is a **runtime facility at the same layer as `ca_attach`**, not a user
API. It hands raw machine addresses to Ruby, and nothing sensible decodes
them except a consumer that already knows what to do with them. It is
documented here and deliberately not in the user-facing `docs/` tree, it is
not advertised in the README, and the user's guide does not mention it. The
consumers today are `carray-jit` and `carray-jit-aot` — the one companion
carray knows by name (see ch. 10 for why that exception exists).

If you are writing a kernel, you want ch. 11, not this chapter. Come here
only when the code that will run is *generated* and addresses cells on its
own terms.

## Why it is not one of the four surfaces

| Surface | Why it does not fit |
|---|---|
| kernel iterator (ch. 11) | Delivers per cell or per slab, and has no N-ary form. A generated kernel with five operands and a stencil reach cannot be expressed as "here is the next slab". |
| sweep ELEMENT family (ch. 13) | Flattens the array. A stencil needs the axis structure the flattening throws away. |
| `CA_WITH_BUFFER` (ch. 13) | The closest relative — it also lends a buffer for the length of a block — but it materialises the whole view, one array at a time, and gives back a contiguous buffer rather than the view's own strides. |

The shape of the surface follows from that: **N arrays at once**, **strides
rather than contiguity**, and **only the region the caller says it will
touch**.

## The two entry points

```ruby
CArray::AddressBasis.open(arrays, writable,
                          region_starts = nil, region_counts = nil,
                          packed = false) { |...| ... }

CArray::AddressBasis.classify(array)   #=> Hash
```

`open` opens every array, yields, and closes them all on the way out —
**including when the block raises**, which is the whole reason it is a block
form. `classify` reports how an array *would* be opened without opening it,
which is what a caller uses to decide whether a fast path applies.

Both refuse the same two things up front:

- an array whose `data_type` is `CA_OBJECT`, because its cells are `VALUE`s
  and a generated kernel computes on numbers (`ArgumentError`);
- an array that is read-only, when the matching `writable` flag is true
  (`RuntimeError`).

## The three tiers

An array is classified in the order the public predicates suggest. The tier
decides where the pointer comes from, and it is the only thing about the
opening that varies.

| Tier | Predicate | What the basis is |
|---|---|---|
| **1 `TIER_ENTITY`** | `ca_is_entity` | The entity's own buffer. The strides are its row-major layout. Nothing is copied. |
| **2 `TIER_STRIDE`** | `ca_is_stride_family`, **and** the fold reaches an entity | `ca_stride_compose_to_root` collapses the whole view chain into root + base offset + one stride per axis. A transpose, a column slice, a reshape is addressed **in place**: no gather, no scatter. |
| **3 `TIER_XFER`** | anything else | `ca_xfer_stride` moves **only the box the caller asked for** into a packed buffer, and writes that box back on close. |

### Why tier 2 insists the fold reaches an entity

`ca_stride_compose_to_root` stops at the first thing it cannot fold through,
and that need not be an entity. A `CARefer` over a gather view —
`whole[whole >= 0].reshape(4, 4)` — folds one step and lands on the
`CASelect`. Attaching a root like that materialises a temporary, and
detaching it throws the kernel's writes away, silently.

So a fold that does not reach an entity **is not the stride tier**. It falls
to tier 3, which moves only the cells the kernel asked for and sends them
back. `classify` reports this honestly: such a view has `stride_family: true`
and `tier: TIER_XFER`.

### Why tier 3 never calls `ca_attach` on the view

A whole-view materialise costs the same whether the kernel touches ten cells
or ten million. Measured on a four-million-element gather view, `ca_attach`
was 2.7 ms regardless, while the region transfer was 0.001 ms for a hundred
cells and 2.3 ms for a million.

A cost that does not scale with the work is a cost the caller cannot reason
about. Tier 3 pays in proportion to what the kernel asked to touch, which is
what makes a region argument worth having at all.

## The region

`region_starts` and `region_counts` are one array each, with one entry per
opened array; each entry is either `nil` (the whole array) or one start and
one count **per axis**. Both halves have to be given or neither.

```ruby
AddressBasis.open([view], [true], [[1, 1]], [[2, 2]]) { |bases| ... }
```

Two things about how the region lands:

- **The basis is shifted, not re-based.** The pointer is moved back so that
  the view's *own* coordinates still address it: cell `(1, 1)` is at
  `pointer + 1*strides[0] + 1*strides[1]` whether or not a region was given.
  That is the same trick a view's `base_offset` plays on its parent's
  pointer, and it means the generated kernel indexes identically in all three
  tiers.
- **The strides come from the box, not the view.** `ca_xfer_stride` packs the
  box row-major, so a `2 × 2` box of `int32` has strides `[8, 4]`, not the
  view's `[16, 4]`. The `:dim` the basis reports is still the *view's* shape.

The region is only consulted by tier 3 — tiers 1 and 2 address the whole
array, which already covers any box inside it. The rank of the region is
checked for every array whatever tier it lands in; its **bounds** are checked
where it is used, so an out-of-range region raises on a tier-3 array and is
ignored on a tier-1 one.

## Masks

A mask is a CArray of the same shape as its parent and, for a view, the same
*kind* of view — a `CABlock`'s mask is a `CABlockMask` — so it is opened by
exactly the same tier logic as the data, in a slot of its own.

One refusal is specific to masks. A view that reinterprets the element size
(`f.refer(CA_INT32, [8])` over a `float64` array) gets a mask of its own
shape, but one cell of that mask covers a fraction of a parent cell, so
writing cell *i*'s mask also marks its neighbour. A per-cell kernel writes
cells independently and cannot express that, so opening such a view with a
mask raises `ArgumentError` rather than marking a neighbour quietly.

Note that a mask slot carries no region of its own: when the data is boxed,
the mask is still transferred whole. That is consistent rather than wrong —
both are addressed by the view's coordinates — but it is a transfer the box
did not ask for.

## The block form

With four arguments the block is handed **one Hash per array**, in the order
the arrays were given. This is the form to *read* an opening in.

| key | |
|---|---|
| `:tier` | `TIER_ENTITY` / `TIER_STRIDE` / `TIER_XFER` |
| `:pointer` | the address of cell `(0, 0, …)`, as an Integer |
| `:strides` | byte stride per axis, `ndim` entries |
| `:dim` | the **view's** shape |
| `:bytes` | bytes per cell |
| `:data_type` | the numeric data type, as C reads it |
| `:writable` | the flag that was passed in |
| `:mask_pointer` | the mask's address, or `nil` when there is no mask |
| `:mask_strides` | the mask's byte strides, or `nil` |

## The packed form — the buffer layout

Given a fifth argument that is true, the block is handed **four byte buffers**
instead. This is what a kernel is actually passed: the four `String`s go
straight to the C as pointers, and the generated code reads them by slot
number.

The hash form exists so a caller can look at an opening. A kernel never
looks: building a Hash and an Array per array so that Ruby can immediately
pack them back into bytes is a round trip through the object heap that
nothing reads, and it cost more than the opening did. So the packed form
writes the four buffers directly.

**This layout is a contract**, not an implementation detail — the code that
reads it is generated somewhere else. It is written out here so that it can
be implemented without reading `packed_body`.

For `count` arrays, in the order they were given to `open`:

| buffer | length | contents |
|---|---|---|
| `pointers` | `count × uint64` | one address per array, in order |
| `strides` | `Σ ndim × int64` | each array's byte strides, **concatenated** |
| `mask_pointers` | `count × uint64` | one per array; **`0` when the array has no mask** |
| `mask_strides` | `Σ ndim × int64` | each mask's byte strides, concatenated; **`ndim` zeros when the array has no mask** |

Three things a reader has to know, and only the first is guessable.

1. **Slot *i* is array *i*.** The order is the one the caller gave.

2. **The stride buffers are concatenated, not padded.** Entries are not a
   fixed width apart, because arrays have different ranks. An array's strides
   begin at the sum of the ranks of the arrays before it, which means the
   reader has to know every array's rank — the generator does, because it
   assigned the slots.

3. **An array with no mask still takes its slots in `mask_strides` — one per
   axis *of its own*, zero.** Not "no entries", and not padded to the
   kernel's rank. This is the part that is wrong if it is implemented without
   being read: leave the zeros out and every mask after that array moves;
   pad to the kernel's rank and an operand of lower rank than the kernel — a
   row broadcast over a grid — moves every mask after it.

An example. Two arrays: a `3 × 4` `int32` with no mask, then a length-4
`int32` that is masked.

```
pointers      [ &grid, &row ]                       2 × uint64
strides       [   16,    4,    4 ]                  2 + 1 = 3 × int64
mask_pointers [     0, &row_mask ]                  2 × uint64
mask_strides  [    0,    0,    1 ]                  2 + 1 = 3 × int64
              ^^^^^^^^^  the grid's own rank, zeroed
```

The signature on the C side, for reference — the other arguments are the
generator's business, not CArray's:

```c
void kernel (char **pointers, int64_t *strides, int64_t *bounds,
             double *reals, int64_t *integers, void **functions,
             void **data, char **mask_pointers, int64_t *mask_strides,
             int32_t *error);
```

## Closing

`open` runs the block under `rb_ensure`, and closes in reverse order.

- A **tier-1 or tier-2** basis addresses the root's own memory, so a write is
  already where it belongs. Closing detaches the root, and nothing else.
- A **tier-3** region is a buffer of its own. Closing sends it back with
  `ca_xfer_stride` — if the array was opened writable — and frees it.

Two consequences worth stating, because a consumer will meet both.

**A raise does not roll anything back.** The block leaving by an exception
still runs the close, which still sends a writable region back. Whatever the
kernel managed to write before it gave up is in the array. That is the same
promise `attach!` makes (ch. 4): the close is guaranteed, the *contents* are
the caller's business.

**A refusal part way through still closes what was already open.** Arrays are
opened one at a time, and a later one can be refused — the reinterpret-plus-
mask case above, for instance. The arrays already open at that point are
closed on the way out.

## What is pinned, and where

`spec/spec_ai/test_address_basis.rb` covers the three tiers, the region, the
mask slots, the refusals, and the packed layout above, plus the closing path
twice over: functionally (a raising block's writes still land) and by
measurement (the malloc zone does not grow across two hundred raising opens;
macOS only, omitted elsewhere).

## Related chapters

- [ch. 04](04_attach_lifecycle.md) — `ca_attach` / `ca_detach` and the R1–R5
  contract this sits on.
- [ch. 06](06_view_algebra_and_castride.md) — `ca_stride_compose_to_root`,
  which is the whole of tier 2.
- [ch. 10](10_author_surface_overview.md) — the four author surfaces, and why
  this is not one of them.
- [ch. 20](20_memory_efficiency_and_streaming.md) — the "don't materialise the
  whole thing" discipline that tier 3 is an instance of.
