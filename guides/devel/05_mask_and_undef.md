# 05 Mask and UNDEF

> **Status: draft.** Written through once; not yet re-verified against a live
> build. See [README](README.md) for conventions.

This chapter is about the **C-level implementation** of the mask: how it is
stored, how the type system dispatches it, how it is delivered through views and
kernels, and the contract a kernel author must honour. The Ruby-facing usage
(`UNDEF`, `has_mask?`, `value`, the mask-set/count methods) belongs to the user's
guide; here we explain what those surfaces sit on.

## Why this is in Part I (Foundations), not in the subsystems

The mask is **something only CArray has** — there is no separate masked-array
type, every array carries one — and it **threads through all of view algebra**:
a slice, a transpose, a reduction all carry and propagate the mask. So it is not
a peripheral subsystem; it is part of what an array *is*. A reader must
understand the mask before reading Part II (Views), because every view chapter
assumes mask propagation. That is why this chapter sits in Foundations, right
after the attach lifecycle and before the view machinery.

## Storage: the mask is a child CArray

The mask is not a flag array bolted on — it is **another CArray**, hanging off the
parent's `mask` field ([ch. 2](02_core_data_structures.md)):

```c
struct _CArray {
  /* … */
  CArray *mask;   /* NULL = no mask; else a boolean child CArray */
};
```

- **`mask == NULL`** is the common case — masks are created lazily, only when a
  cell is actually marked. Code that reads masks must always handle the `NULL`
  (unmasked) case.
- When present, the mask is **boolean storage**: `data_type == CA_BOOLEAN`, one
  `uint8` per element (`0` = present, `1` = masked), with the **same shape** as
  its parent.

Because the mask is a real CArray of the same shape, it rides the same machinery
as the data: it has its own `ptr`, it attaches and syncs *alongside* its parent
(`ca_update` updates `ca->mask` after `ca`, [ch. 4](04_attach_lifecycle.md)), and
a view's mask is a view of the parent's mask with the same rearrangement. There is
no separate "masked transfer" code path — moving the data and moving the mask are
the same operation applied to two parallel CArrays.

## Ownership: `ca_free_nop`

A mask is owned by its parent. Freeing the parent frees the mask. So the mask's
TypedData registers **`dfree = ca_free_nop`** ([ch. 3](03_memory_management.md)):
its own free hook does nothing, leaving the parent's free cascade to release it.
Register a mask's TypedData with the ordinary `ca_free` instead and you get a
double-free crash — the single most common mistake when adding a view.

## Dispatch: the mask sibling classes and `create_mask`

A mask is not a generic CArray; it is a **per-obj_type sibling class**, so that a
view's mask is the *same kind of view* as the view itself. A `CABlock`'s mask is a
`CABlockMask`; a `CARepeat`'s mask is a `CARepeatMask`. This is what the
`create_mask` slot in the operation table produces:

```c
ca_func[ca->obj_type].create_mask(ca);   /* builds the matching mask sibling */
```

The dispatch tables carry a parallel pair for masks —
`ca_mask_class[obj_type]` and `ca_mask_typeddata[obj_type]`
([ch. 2](02_core_data_structures.md)). The reason the sibling must match: a
`CABlock` addresses its parent through `base_offset`/`strides`, and *its mask must
address the parent's mask the same way*. A generic mask would not track the view's
geometry. So when you add a view, you override `create_mask` to build the matching
mask sibling — forget it and you get a mask of the wrong class that reads the wrong
bytes. (For a CAStride subclass, the mask is itself a CAStride subclass with
`mask->mask == NULL` — the cascade terminates because a mask has no mask of its
own.)

## UNDEF: the C singleton

`UNDEF` is the sentinel a caller assigns to mark a cell missing. At the C level it
is the global `CA_UNDEF`, created during init (`ext/carray_undef.c`) and bound to a
top-level Ruby constant:

```c
extern VALUE CA_UNDEF;   /* the "missing cell" marker */
/* … */
CA_UNDEF = rb_funcall(rb_cUNDEF, rb_intern("new"), 0);
rb_const_set(rb_cObject, rb_intern("UNDEF"), CA_UNDEF);
rb_gc_register_mark_object(CA_UNDEF);   /* pin against compacting GC */
```

Two implementation points:

- It is compared by **raw pointer identity** (`rval == CA_UNDEF`) throughout the
  C code — not by `==` — because it is a pure marker.
- That identity comparison means it must live at a **fixed address**. Ruby 3.x's
  compacting GC would otherwise move it, so `rb_gc_register_mark_object` pins it.
  This fixed an order-dependent UNDEF-flicker crash (a `TypeError` on the second
  `GC.compact`); do not remove the pin. The pin is needed because `UNDEF` makes the
  round trip: the user writes the Ruby constant, and C compares what arrives against
  the C global.

A second, unrelated singleton lives in `ext/ruby_carray.c`: `CA_UNSPECIFIED`
(`CArray::UNSPECIFIED`), which means "the caller did not give this argument". It
exists because `nil` is itself a legal fill value, so `nil` cannot mark absence —
see `unmask`, `shift(fill_value:)` and `window(fill_value:)`. It never makes the
round trip through Ruby, so every comparison reads the same C global and no pin is
required. Do not pass it in from Ruby.

The Ruby surface assigns `UNDEF` to mark a cell missing:

```ruby
a[2, 3] = UNDEF       # sets the (2,3) mask bit; the underlying byte
                      # is undefined (it could be the prior value,
                      # zero, or kernel-overwrite garbage)
```

At the C level the assignment path tests `val == CA_UNDEF` and, on hit, sets the
mask byte without touching the data byte.

## Delivery: how propagation actually happens

Mask propagation is not re-implemented per operation — it falls out of the kernel
iterator ([ch. 11](11_kernel_iterator.md)). A kernel receives mask-aware iteration
by default: alongside each data run, the iterator delivers the corresponding mask
run (`m`, or `NULL` if the source is unmasked), and gathers/materialises the mask
in lockstep with the data, including a per-fiber mask gather for non-innermost
axes. The kernel reads `m[j]` to skip masked cells and the result inherits the
mask. So *any* kernel written on the standard surface propagates masks for free —
the author writes no mask plumbing.

A kernel that genuinely cannot accept a masked source declares
**`CA_KERNEL_NO_MASK`**; the engine then rejects a masked source at entry rather
than silently dropping the mask (a "physically impossible" rejection in the
deliver-the-materials sense, [ch. 10](10_author_surface_overview.md)).

`value` — the mask-dropping view a user reaches for — is, at the C level, simply a
**CARefer** over the parent's data buffer with the `mask` field left unset. No copy;
it is a view that doesn't see the mask.

## The contract: masked data is undefined, not protected

A load-bearing design point for every kernel author: **the *data value* under a
masked cell is out of contract.** Masking marks a cell missing; it does not
promise to preserve whatever bytes sit in that cell's storage. A kernel may
overwrite, skip, or compute garbage into masked positions, as long as the mask
correctly records them as masked.

This is not a limitation — it is what *licenses* the optimisation freedom. Because
masked cells need not be preserved, a kernel can run branchless or SIMD over the
whole buffer and reconcile the mask separately, instead of branching per element to
protect masked data. Any design premised on "the mask protects the value
underneath" is rejected on this ground.
This is precisely the kind of C-level invariant a developer must internalise and a
user never needs to know.

## Boolean storage is uint8

The mask is boolean, and boolean recurs throughout the kernels. CArray's boolean
`data_type` is `CA_BOOLEAN`, stored as `uint8`, but *surfaced* four different ways
depending on context — numeric in arithmetic and `:plus`-reductions, Ruby
true/false on scalar access, integer `0`/`1` in bulk conversion, rejected for
`min`/`max`/`variance`. These four rules are fixed for 3.0; a kernel that touches
boolean storage picks the rule matching its family. The full table and rationale
are in [ch. 12](12_mkkernel_dsl.md) (which dispatch a generated kernel emits).

## The mask API surface

All declared in `ext/carray.h`. Group by purpose:

### Read

```c
boolean8_t *ca_mask_ptr         (void *ca);   /* NULL if no mask */
int         ca_has_mask         (void *ca);
int         ca_is_any_masked    (void *ca);
int         ca_is_all_masked    (void *ca);
ca_size_t   ca_count_masked     (void *ca);
ca_size_t   ca_count_not_masked (void *ca);
```

`ca_has_mask` is the cheap "mask field is non-NULL" probe;
`ca_is_any_masked` walks the mask buffer (so it's O(N) and may
attach). Use `ca_has_mask` for branching; reserve the walking
predicates for cases where you genuinely need to inspect contents.

### Build / clear

```c
void ca_create_mask  (void *ca);              /* allocate mask, zero-fill */
void ca_clear_mask   (void *ca);              /* zero an existing mask */
void ca_setup_mask   (void *ca, CArray *mask);/* attach a given mask */
void ca_update_mask  (void *ca);              /* re-gather from parent */
```

`ca_create_mask` dispatches through `ca_func[ca->obj_type].create_mask`
— so a CABlock yields a `CABlockMask`, not a generic mask. **Forget to
override `create_mask` on a new view and you get a mask of the wrong
class** reading the wrong bytes.

At the Ruby surface, `mask=` (and the other 6 mask-metadata bindings —
`create_mask`, `unmask`, `inherit_mask`/`inherit_mask_replace` × 2) all
funnel through `rb_ca_modify`, which raises when `CA_FLAG_READ_ONLY` is
set. That is the general contract, and `set_read_only_flag` is
deliberately "One-way" at the public surface — READONLY cannot be
lifted from user code. READONLY carries class-dependent semantics
(truly immutable external memory / formal-API-only writes / no
writable target at all — see ch. 18 for the taxonomy), so a library /
class author who knows *which* semantic applies has access to a
private, block-scoped escape: `CArray#without_read_only_flag { }`,
reached via `send`. The `send` requirement *is* the signal that the
caller is an author who knows the invariants, not general user code.
See ch. 18 §"Author-only escape".

### Copy / overlay

```c
void ca_copy_mask           (void *ca, void *other);
void ca_copy_mask_overlay   (void *ca, ca_size_t elements, int n, ...);
void ca_copy_mask_overlay_n (void *ca, ca_size_t elements, int n,
                             CArray **slist);
void ca_copy_mask_overwrite (void *ca, ca_size_t elements, int n, ...);
void ca_copy_mask_overwrite_n(void *ca, ca_size_t elements, int n,
                              CArray **slist);
void ca_mask_overlay_safe   (CArray *ca_out, int n, ...);
```

`*_overlay` = **OR-merge** N input masks into the target's mask (= the
"any source masked → output masked" propagation every multi-input
operator wants). `*_overwrite` = **replace** the target's mask
wholesale (rare; used when the kernel's output mask is unrelated to
the inputs').

`ca_mask_overlay_safe` is the **attach-safe** variant: it gathers the
input masks via `xfer_all` into arena scratch and byte-ORs them onto
`ca_out->mask`, **never** calling `ca_attach` on the input masks. Use
it whenever the input could be a shrinking view of a giant parent —
which is "always" in user-facing arithmetic kernels.

### Drop / fill

```c
void    ca_unmask        (void *ca, char *fill_value);   /* in-place */
CArray *ca_unmasked_copy (void *ca, char *fill_value);   /* fresh copy */
```

`ca_unmask` fills masked cells with `fill_value` bytes (cast from the
caller's interpretation) and drops the mask. `ca_unmasked_copy`
returns a new CArray with the same effect. The VALUE counterparts are
`rb_ca_unmask` / `rb_ca_unmask_copy` / `rb_ca_mask_fill` /
`rb_ca_mask_fill_copy` ([ch. 15](15_carray_h_helper_reference.md)).

### Iterator helpers

```c
boolean8_t *ca_allocate_mask_iterator   (int n, ...);
boolean8_t *ca_allocate_mask_iterator_n (int n, CArray **slist);
```

Pre-build a combined mask byte array across N sources — the per-cell
fast-path the sweep engine uses internally.

## Mask sibling registration template

When you add a new view kind, the Init incantation for the mask
sibling looks like this:

```c
/* In Init_ca_obj_<kind>: */
extern int8_t CA_OBJ_<KIND>;
CA_OBJ_<KIND> = ca_install_obj_type(
    rb_cCA<Kind>,
    &ca<kind>_data_type,
    rb_cCA<Kind>Mask,                /* parallel Ruby class */
    &ca<kind>_mask_data_type,        /* TypedData with dfree = ca_free_nop */
    ca_<kind>_func                   /* op table; func.create_mask must
                                        emit a CA<Kind>Mask, not a generic */
);
```

The **mask TypedData** must register with `dfree = ca_free_nop`:

```c
const rb_data_type_t ca<kind>_mask_data_type = {
  "CA<Kind>Mask",
  { ca_mark, ca_free_nop, NULL, NULL, },   /* ← ca_free_nop, not ca_free */
  &carray_mask_data_type,                  /* parent */
  /* ... */
};
```

If you register the mask with `dfree = ca_free` instead, the mask is
freed twice (once by the parent's cascade, once by its own GC pass)
and the process crashes — the "Ownership: `ca_free_nop`" section above
and [ch. 3](03_memory_management.md) carry the ownership story.

## The boolean data_type quadrant

The mask is boolean storage, and CArray's boolean `data_type` is
**surfaced four different ways** depending on context — this is the
load-bearing invariant any kernel author has to know:

| Path | Surface | Discipline |
|---|---|---|
| binop arithmetic | numeric (silent 0/1 coerce) | `(a > 0) * b` works |
| reduce `:plus` family | numeric (0/1 summed) | `sum` = count, `mean` = proportion |
| reduce `:min/:max/:variance/:star` | **reject** | use `.all` / `.any` instead |
| scalar Ruby access | `Qtrue` / `Qfalse` | `if ca[i, j]` is natural |
| bulk conversion / `cast_table` | Integer 0/1 | `(a > 0).to_a == [1, 0, 1]` |

A new reduce kernel that mentions `:bool` in `source:` is opting into
either the count semantic (the `:plus` family) or the all/any semantic
(the boolean-only family) — never the min/max/variance one. The
mkkernel DSL ([ch. 12](12_mkkernel_dsl.md)) enforces this by excluding
`:bool` from `ALL_NUMERIC` and requiring an explicit `:bool` in
`source:` for the cases that accept it.

## A worked propagation example

A binop `+` that propagates masks looks like this in skeleton:

```c
static VALUE
rb_ca_my_binop (VALUE self, VALUE other)
{
  CArray *ca; GetCArray(self, ca);
  VALUE rother = rb_ca_wrap_readonly(other, INT2NUM(ca->data_type));
  CArray *cb; GetCArray(rother, cb);

  ca_check_same_shape(ca, cb);

  /* (1) Allocate the output entity, same shape and type as inputs */
  VALUE vout = rb_ca_template(self);
  CArray *co; GetCArray(vout, co);

  /* (2) Propagate masks: union of ca.mask + cb.mask onto co.mask */
  ca_mask_overlay_safe(co, 2, ca, cb);

  /* (3) Run the kernel — kernel iterator delivers data + mask; the
         per-cell loop reads m[j] to skip masked cells. Output writes
         to those cells are out of contract (mask-is-not-protection). */
  /* ... iterator + body ... */

  return vout;
}
```

Three points: the mask is built **before** the kernel runs (so the
kernel can see and skip masked cells, but also: even if the kernel
writes garbage to masked cells, the output mask is already correct);
the overlay is **safe** (no attach on input masks); and the kernel
itself writes no mask-propagation code — that's what `ca_mask_overlay_safe`
encapsulates.

## Where to go next

- How the kernel iterator delivers and propagates masks →
  [ch. 11](11_kernel_iterator.md).
- How a view's mask is itself a view of the parent's mask →
  [ch. 6](06_view_algebra_and_castride.md).
- The storage-ownership side (`ca_free_nop`) →
  [ch. 3](03_memory_management.md).
- The Ruby-facing mask surface (assign `UNDEF`, `mask_eq`,
  `count_masked`, …) → user's guide.
- The C idiom for "set up a fresh output and propagate masks" →
  [ch. 15a](15a_common_idioms.md).

---
*When done, update the status row in [README](README.md).*
