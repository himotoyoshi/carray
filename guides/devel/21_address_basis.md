# 21 The address basis (`CArray::AddressBasis`)

Every surface in Part III hands a kernel its *cells*: the kernel iterator
delivers a slab or a fiber at a time, `call_cfunc` delivers the arguments of
a scalar call or a flat chunk, `rb_ca_call_with_buffer` delivers the whole
array as one contiguous buffer.

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
own terms — or when a hand-written C kernel has to read cells by address
across rows, which is what the C entry (below) is for.

## Why it is not one of the four surfaces

| Surface | Why it does not fit |
|---|---|
| kernel iterator (ch. 11) | Delivers per cell or per slab, and has no N-ary form. A generated kernel with five operands and a stencil reach cannot be expressed as "here is the next slab". |
| call_cfunc (ch. 14) | Flattens the array. A stencil needs the axis structure the flattening throws away. |
| `rb_ca_call_with_buffer` (ch. 13) | The closest relative — it also lends a buffer for the length of a block — but it materialises the whole view, one array at a time, and gives back a contiguous buffer rather than the view's own strides. |

The shape of the surface follows from that: **N arrays at once**, **strides
rather than contiguity**, and **only the region the caller says it will
touch**.

## The two entry points

```ruby
CArray::AddressBasis.open(arrays, writable,
                          region_starts = nil, region_counts = nil,
                          packed = false) { |...| ... }

CArray::AddressBasis.classify(array)   #=> Hash
CArray::AddressBasis.tier(array)       #=> TIER_ENTITY, TIER_STRIDE or TIER_XFER
```

`open` opens every array, yields, and closes them all on the way out —
**including when the block raises**, which is the whole reason it is a block
form. `classify` reports how an array *would* be opened without opening it,
which is what a caller uses to decide whether a fast path applies. `tier`
answers what `classify` reports as `:tier`, without building the Hash, for a
caller that asks on every call.

`classify` refuses nothing; its `:refusal` is the reason `open` would refuse
the array for reading, or nil. `open` refuses, before it opens any array:

- an array whose `data_type` is `CA_OBJECT`, because its cells are `VALUE`s
  and a generated kernel computes on numbers (`ArgumentError`);
- an array that is read-only, when the matching `writable` flag is true
  (`RuntimeError`);
- a masked view that reinterprets the element size (see *Masks* below,
  `ArgumentError`).

## The C entry: `ca_with_address_bases`

A C extension does not go through Ruby. It calls the same machinery
directly, declared in `carray.h`:

```c
typedef struct {
  char       *ptr;                        /* cell (0, ..., 0) */
  ca_size_t   strides[CA_RANK_MAX];       /* byte step along each axis */
  boolean8_t *mask;                       /* NULL when no mask */
  ca_size_t   mask_strides[CA_RANK_MAX];  /* byte step in the mask */
  int         writable;
} ca_address_basis_t;

VALUE ca_with_address_bases (int32_t n, CArray **arrays, const int *writable,
                             const ca_size_t *const *box_start,
                             const ca_size_t *const *box_count,
                             VALUE (*body)(ca_address_basis_t *bases, VALUE arg),
                             VALUE arg);
```

It opens the `n` arrays, calls `body` with one basis per array, and closes
them all on the way out, including when `body` raises. Everything this
chapter says about `open` holds for it: the same refusals, the same three
tiers, the same masks, the same closing. Two things differ.

- **The tier is not shown.** A basis is a pointer, strides, a mask and a
  flag; the C caller addresses cells through it the same way whichever tier
  produced it. A cell is at `ptr + Σ idx[k] * strides[k]`, its mask byte at
  `mask + Σ idx[k] * mask_strides[k]`.
- **The box is given per array, as start and count.** `box_start[i]` and
  `box_count[i]` hold `ndim` values each for array `i`. Pass `NULL` for both
  pointers, or for one array's entries, to lend the whole array. Give them
  as a pair — a start without a count is refused.

The region rules below apply unchanged: the box decides what tier 3 copies,
tiers 1 and 2 lend the whole array either way, and the kernel must address
only the box.

A three-point stencil over rows, reading `a` and writing `out`:

```c
static VALUE
stencil_body (ca_address_basis_t *b, VALUE arg)
{
  Info *info = (Info *) arg;               /* rows and columns of out */
  for (ca_size_t i = 0; i < info->rows; i++)
    for (ca_size_t j = 0; j < info->cols; j++) {
      double v0 = *(double *)(b[0].ptr + i * b[0].strides[0] + j * b[0].strides[1]);
      double v2 = *(double *)(b[0].ptr + (i + 2) * b[0].strides[0] + j * b[0].strides[1]);
      *(double *)(b[1].ptr + i * b[1].strides[0] + j * b[1].strides[1]) = v0 + v2;
    }
  return Qnil;
}

CArray *arrays[2] = { a, out };
int writable[2] = { 0, 1 };
ca_with_address_bases(2, arrays, writable, NULL, NULL, stencil_body, (VALUE) &info);
```

`a` may be a transposed view, a gathered view, an integer array seen through
`fake(:float64)` or a lazy expression; `out` may be a view of another array.
The kernel does not change. The `CArray` pointers must stay alive for the
call, so keep the `VALUE`s they came from on the stack.

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

The region is only *used* by tier 3 — tiers 1 and 2 address the whole array,
which already covers any box inside it. It is **checked** for every array all
the same, before any of them is opened: one start and one count per axis, both
Integers (a Float is a `TypeError`, not truncated), and the box inside the
array. A region that is wrong is refused the
same way whatever the arrays turn out to be, rather than being noticed only
once the same call is handed a gather view.

## Masks

A mask is a CArray of the same shape as its parent and, for a view, the same
*kind* of view — a `CABlock`'s mask is a `CABlockMask` — so it is opened by
exactly the same tier logic as the data, in a slot of its own.

One refusal is specific to masks. A view that reinterprets the element size
(`f.refer(CA_INT32, [8])` over a `float64` array) gets a mask of its own
shape, but one cell of that mask covers a fraction of a parent cell, so
writing cell *i*'s mask also marks its neighbour. A per-cell kernel writes
cells independently and cannot express that, so opening such a view with a
mask raises `ArgumentError` rather than marking a neighbour quietly. This
holds in every tier: a view that lands in tier 3 moves the same mask, and the
neighbour would be marked on the way back.

A mask added to a parent after a view of it was made is not on the view
until the view is asked for it. `open` asks, so such a mask is opened.

A mask has its array's shape, so it takes its array's box: in tier 3 the
mask moves the same cells as the data, not the whole view's.

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

- A **tier-1 or tier-2** basis addresses the root's own memory. Closing syncs
  the root and detaches it. For an ordinary entity the sync does nothing; an
  entity that keeps its cells elsewhere while attached (the mask of a
  CAObject whose mask comes from Ruby hooks) receives the writes there.
- A **tier-3** region is a buffer of its own. If the array was opened
  writable, closing sends back **the cells whose bytes the kernel changed**,
  a run along the last axis at a time, and frees the buffer. Sending the
  whole box would also send the cells the kernel left alone, and those do
  not come back unchanged through a view that converts: a `float64` read
  through an `int32` view as 1 would be written back as 1.0. It would also
  overwrite a write the kernel made to the same cells through another
  basis that addresses them in place. A kernel that writes the very value
  it read leaves the cell as it was.

Three consequences worth stating, because a consumer will meet all of them.

**A raise does not roll anything back.** The block leaving by an exception
still runs the close, which still sends a writable region back. Whatever the
kernel managed to write before it gave up is in the array. That is the same
promise `attach!` makes (ch. 4): the close is guaranteed, the *contents* are
the caller's business.

**A failure part way through still closes what was already open.** Arrays
are opened one at a time, and opening a later one can raise — a tier-3 read
whose own transfer fails, for instance. The arrays already open at that
point are closed on the way out.

**One region failing to go back does not stop the others.** A write-back can
raise — the array's own transfer failing, as a lazily backed source's does
when its I/O fails. The close sets that exception aside, sends the remaining
regions back, frees every buffer and detaches every root, and raises it
afterwards — unless the block raised, in which case the block's exception is
the one that propagates.

**CArray's exceptions carry `CArray::AddressBasis::Failure`.** An exception
raised while the arrays are checked, opened or closed — a refusal, an array
whose own transfer fails — is extended with that module. One raised by the
block is not, and neither is a mistake in the request (a region outside the
array, a missing flag). A caller that runs code of its own in the block tells
the two apart by it: `Fusion` keeps a registered evaluator when the failure
is CArray's, and lets the walk meet the same array.

## The sweep

```ruby
CArray::AddressBasis.sweep(function, fsync, arrays, *parts)   #=> nil
```

A kernel with no neighbour in it — an element-wise pass — does not need a
basis at all: CArray's chunked sweep (`ca_call_cslab_N_r`) can acquire the
operands, broadcast them and hand the kernel a chunk at a time. What the
sweep cannot carry is the kernel's other inputs (captured scalars, the C
functions it calls, an error slot), and it passes one `userdata` pointer
through untouched for them.

`sweep` is that call made from Ruby. `function` is the address of a
`ca_cslab_r_t`, `fsync` CArray's one character per operand (`0` read, `1`
written; any other character is refused), and `arrays`
one to seven operands (the arities the family is generated for). `userdata`
is a table of pointers, one per entry of `parts`, each to the bytes of that
String.

**The bytes are the Strings' own, not a copy.** That is sound because a
String's bytes do not move while the call runs: `sweep` holds every part in
an array on the machine stack for the length of the call, and compaction does
not move an object referenced from there. The sweep allocates, so a
collection can run in the middle of the call; the pin is what makes that
harmless. Being an argument is not enough by itself — a splat of 128 or more
reaches a C method as a heap array, whose elements compaction moves — and the
machine stack is why `sweep` takes at most 1024 parts (`ArgumentError`
beyond).

A part that is not frozen is the kernel's to write, and is made unshared
before its address is taken, so the write lands in that String alone. A
frozen part is read only. Every part must start on an 8-byte boundary, since
a kernel reads doubles and int64s out of them; one that does not — a frozen
tail of a longer String, which shares its bytes one byte in — is refused
(`ArgumentError`).

## What a basis does not guard

**Two bases that write the same cell.** Opening one array twice, or an array
and a view of it, lends two bases that can reach the same cell. What that
cell holds afterwards is not specified: a box sends its changed cells back
when it is closed, after anything written in place, and the arrays are closed
in the reverse of the order they were given. Neither is something to rely on.
Reading through one basis what was written through another is not specified
either, since a box is a copy taken at the opening. Arrays that share storage
are not refused — `a[0..1]` and `a[2..3]` share it and touch different cells
— so the caller keeps the cells it writes apart.

**What is written is not checked.** A basis lends the storage: a Face is lent
as its storage type (a `CATime` as eight-byte fixlen) and its values are not
checked on the way back, and a boolean cell takes whatever byte is written.
A kernel writes values the array's own store would accept — 0 or 1 into a
boolean — or the array holds something no other route could have put there.

## What is pinned, and where

`spec/spec_ai/test_address_basis.rb` covers the three tiers, the region, the
mask slots, the refusals, and the packed layout above, plus the closing path
twice over: functionally (a raising block's writes still land) and by
measurement (the malloc zone does not grow across two hundred raising opens;
macOS only, omitted elsewhere).

`spec/spec_ai/test_address_basis_c.rb` drives the C entry from an extension
compiled outside carray (`spec/spec_ai/ext_address_basis/`): a stencil over
entities, folded views, gathered views, conversions, lazy expressions and a
CAObject, a box write that leaves the cells outside the box alone, and a
raising body whose write still lands.

`spec/spec_ai/test_address_basis_sweep.rb` covers `sweep`, with the kernel a
Ruby block behind a Fiddle closure. That kernel's first act is the most
thorough compaction Ruby has (`GC.verify_compaction_references` toward an
empty heap), after which it checks that every part is still where its
pointer says; a String held only by an Array is moved by the same
compaction, which is what says the compaction was real.

## Related chapters

- [ch. 04](04_attach_lifecycle.md) — `ca_attach` / `ca_detach` and the R1–R6
  contract this sits on.
- [ch. 06](06_view_algebra_and_castride.md) — `ca_stride_compose_to_root`,
  which is the whole of tier 2.
- [ch. 10](10_author_surface_overview.md) — the four author surfaces, and why
  this is not one of them.
- [ch. 20](20_memory_efficiency_and_streaming.md) — the "don't materialise the
  whole thing" discipline that tier 3 is an instance of.
