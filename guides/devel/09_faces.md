# 09 Faces

> **Status: draft.** Written through once; not yet re-verified against a live
> build. See [README](README.md) for conventions.

## Why this sits next to the view catalog (Part II)

A Face is not a separate subsystem — it is **a kind of view / obj_type**: an
extended data type that wraps a numeric (or fixlen) array and reinterprets it
*semantically* without touching the bytes. It cannot be explained apart from the
view machinery (obj_type dispatch, the class hierarchy, attach), so it belongs
right after the [view catalog](08_view_catalog.md). Read it once the view
chapters are comfortable. This chapter is the implementation-side front
door for Faces.

## What a Face is

A Face is a view that gives raw storage a *meaning*: a calendar timestamp
(`CATime`), a duration (`CATimedelta`), a struct record (`CARecord`), or a
user-defined type. It satisfies three properties:

1. **Storage transparency.** The view's buffer *is* the parent's buffer, byte for
   byte. No element conversion happens at the storage layer:
   `face.bytes == face.parent.bytes`, and `face[i]` at the C level reads the same
   bytes as `face.parent[i]`. (A Face may present a *surface* data_type different
   from its *storage* data_type — see below — but the bytes are unchanged.)
2. **Identity carry.** The view has its own Ruby class, and that class survives
   every view-creating operation:
   `dt.transpose.reshape(...).flip[2..5].class == CATime`.
3. **Top-of-chain placement.** A Face is always the *outermost* view. Slicing or
   transposing a Face is rewritten so the Face stays on top —
   `CATime[CABlock[int64_entity]]`, never the other way round. The invariant
   `face.parent.data_type == storage` holds across the whole chain.

This is the implementation root of the project value "a Face can be authored
outside the core and just work" ([ch. 1](01_architecture_overview.md), runtime
obj_type install): a Face is class-independent machinery keyed off a flag, so an
external gem can add a semantic type without changing core.

## The flag is the gate; CAFace is organisation

The single source of truth for "is this a Face?" is the **`CA_FLAG_IS_FACE`** bit
in `ca->flags`, not the class:

```c
#define CA_FLAG_IS_FACE  128

#define ca_is_face(ca)   ca_test_flag((ca), CA_FLAG_IS_FACE)
        /* The single source of truth for "is this a Face?"  Not class. */
```

Every Face-aware path — the lift hook, the strip helper, the kernel-iterator
entry — reads the flag. The abstract `CAFace` class exists only for *inheritance
organisation* (C-level Face subclasses derive from it) and as a hook point; it is
not what makes something a Face. The Ruby-side test is `ca.face?`.

## The substrate

The machinery lives in `ext/ca_obj_face.{c,h}`. It is dominated by **thin
forwarders to the parent**: because storage is transparent, a Face's transfer
*is* its parent's transfer, which is why authoring a Face needs essentially no
storage code.

### Strip and re-lift

```c
CArray *ca_strip_face   (CArray *ca);
        /* Peel Face layers off the top of the chain so an internal
           pipeline (kernel iterator, math kernel) talks to the
           underlying storage. Returns the underlying CArray (= ca
           unchanged when ca is not a Face). Idempotent. */

VALUE   ca_face_lift    (VALUE storage_result, VALUE original_face);
        /* Wrap the result of a view-creating method so the Face
           stays on top of the chain (property 3 — "outermost"). */

VALUE   rb_ca_face_template (VALUE original_face, VALUE new_storage);
        /* Build a new Face instance from `original_face`, replacing
           its storage parent with `new_storage`.  This is the one
           core path that raw-memcpys a CArray struct and must reset
           the CAView prefix including _pool ([ch. 3]). */
```

The kernel author never sees a Face: it is stripped on entry (`ca_strip_face`)
and re-lifted on the result (`ca_face_lift`).

### The op-table forwarders

A Face's op table is populated mostly with these parent-forwarding slots:

```c
void  ca_face_attach     (void *ca);   /* ca_attach(ca->parent) + alias */
void  ca_face_sync       (void *ca);   /* ca_sync(ca->parent) */
void  ca_face_detach     (void *ca);   /* ca_detach(ca->parent) */
void  ca_face_fill_data  (void *ca, void *val);
void  ca_face_xfer_index (void *ca, ca_size_t *idx, void *data, int dir);
void  ca_face_xfer_addrs (void *ca, ca_size_t n, ca_size_t *addrs,
                          void *data, int dir);
void  ca_face_xfer_stride(void *ca, ca_size_t *starts, ca_size_t *counts,
                          ca_size_t *strides, void *data, int dir);
void  ca_face_xfer_all   (void *ca, void *data, int dir);
```

### Identity carry: where `face_template` is used

Every view-creating method on a CArray (`reshape`, `transpose`, `flip`, `[]`
slice, …) ends with a `ca_face_lift` when the original was a Face. The lift
internally calls `rb_ca_face_template` to build the new Face instance — and that
is the one place in core that raw-copies a CArray struct, hence the load-bearing
**`_pool` reset invariant** ([ch. 3](03_memory_management.md), "the reset
invariant").

## Surface vs storage data_type (the FIXLEN gate)

A Face keeps its parent's *storage* data_type (e.g. `int64` for a CATime) but
may declare a different *surface* data_type. The important case: a **NonNumeric
Face declares surface `CA_FIXLEN`** to **gate mkkernel numeric dispatch**:

```c
ca->data_type = CA_FIXLEN;          /* surface: numeric kernels decline */
ca->parent->data_type = CA_INT64;   /* storage: int64 ticks */
ca->bytes = ca->parent->bytes;      /* = 8 */
```

When mkkernel-generated arithmetic (`+`, `*`) dispatches on `ca->data_type`, it
sees `CA_FIXLEN` and declines — so `dt + 1` doesn't silently run integer addition
on a calendar timestamp. The Face's own Ruby-level `+` method, when it makes
semantic sense, is implemented directly (calling into the int64 storage through
`ca_face_xfer_*`). The gate is what makes "a Face is not arithmetically a
number" both safe (no silent wrong math) and overrideable (a Face can opt in
to specific operations on its own terms).

## Two authoring paths

The same substrate supports two implementation styles:

- **C-level struct subclass** — used for `CATime` / `CATimedelta` /
  `CARecord` / `CAConstString`. You define the struct (CAView prefix +
  face-specific tail), pick the storage `data_type`, fill the op table (mostly
  with the `ca_face_*` forwarders, substituting your own only where the Face
  genuinely needs custom behaviour — typically the constructor, the per-cell
  `rb_ca_ptr2obj` / `_obj2ptr`, and the Ruby class surface), write a setup and
  `Init_`, register the obj_type via `ca_install_obj_type`, and add the Ruby
  surface.
- **Ruby-level `CAObject` subclass** — for user-defined Faces. Requires **zero
  storage callbacks**: a complete Face is roughly six lines of `initialize`, with
  all per-cell I/O delegated to the parent CArray at native C speed. This is
  the path an external gem author normally takes.

The runtime obj_type install ([ch. 1](01_architecture_overview.md)) is what lets
an external gem add a Face without recompiling the core.

## The portable-state table

```c
extern uint8_t face_state_portable_table[CA_OBJ_TYPE_MAX];
```

`face_state_portable_table[obj_type] == 1` means the Face's state can cross a
process or parent boundary — Marshal, MemoryView producer, and multi-parent
constructors (CAStack, `concatenate`, `stack`, `meld`). A `0` means the state is
tied to a specific parent buffer and those constructors must reject it.

The canonical `0` is **CAConstString**: its backing buffer is per-parent (a
pure-concat UTF-8 byte pool indexed by fixlen-16 `(start, end)` pairs), so a
CAConstString cell's meaning depends on which parent it came from. Stacking K
CAConstStrings would mean reconciling K independent byte pools — which is why
CAStack et al. reject it. The portable escape hatch is `to_fixlen_string`, which
copies each cell into a fixed-width slot.

`CATime` and `CATimedelta` set `1` — their state is purely in the surface
data_type wrapper (the unit), carried alongside via Marshal-friendly metadata.

`CARecord` is deliberately left *unregistered* in the C table: portability is a
property of the record's schema (its member types), which a single per-obj_type
flag cannot express. Resolution therefore defers to the concrete record class —
a class-level `face_state_portable?` if one is defined, otherwise the default
(portable). No such predicate is defined today, so a CARecord currently resolves
to portable.

## Open: Marshal / dump_binary identity preservation

Carrying a Face's *class identity* through `dump_binary` / `Marshal` round-trips —
so a dumped `CATime` reloads as a `CATime`, including anonymous
subclasses — is **deferred**. `dump_binary` itself is largely untouched in 3.0;
the Face-identity question is out of scope, left to a later dump_binary phase.

## Where to go next

- The view machinery a Face rides on →
  [ch. 6](06_view_algebra_and_castride.md),
  [ch. 8](08_view_catalog.md).
- How the kernel iterator strips and re-lifts Faces →
  [ch. 11](11_kernel_iterator.md).
- The `_pool` reset invariant `rb_ca_face_template` honours →
  [ch. 3](03_memory_management.md).

---
*When done, update the status row in [README](README.md).*
