# 04 The attach lifecycle

> **Status: draft.** Written through once; not yet re-verified against a live
> build. See [README](README.md) for conventions.

This is the single most important mechanism for understanding view behaviour. A
view owns no data; it borrows its parent's. The attach lifecycle is how it
*materialises* that data into its own `ptr`, *writes back* any changes, and
*releases*. Get this wrong and views silently corrupt data; get it right and a
deep view chain still costs one gather against the root.

## The ownership marker

```c
#define ca_is_attached(ca) ( (ca)->ptr != NULL )
```

`ptr != NULL` *is* the definition of "attached and owning a buffer". An entity is
always attached (it owns its data from birth). A view starts with `ptr == NULL`
and becomes attached only when someone calls `ca_attach` on it.

## The lifecycle operations

The public C API (declared in `carray.h`):

```c
void ca_allocate (void *ca);   /* allocate ptr without filling it */
void ca_attach   (void *ca);   /* allocate ptr + gather parent's data into it */
void ca_update   (void *ca);   /* re-gather parent's data into an attached ptr */
void ca_sync     (void *ca);   /* scatter ptr's data back to the parent */
void ca_detach   (void *ca);   /* free ptr (+ detach parent) */
```

and the `_n` variadic forms (`ca_attach_n(3, a, b, c)`, etc.) for opening several
at once.

- **attach** = allocate `ptr`, then gather: read the parent through the view's
  access pattern and fill `ptr` with a contiguous image.
- **update** = re-run the gather into an already-attached `ptr` (refresh after
  the parent changed underneath).
- **sync** = scatter: write `ptr`'s contents back out through the same access
  pattern. Suppressed when `nosync` is set; a no-op while aliasing (below).
- **detach** = free `ptr` and detach the parent.

A typical internal use is attach → operate on the contiguous `ptr` → sync →
detach. Both gather and scatter run through the unified `xfer_all` hook with
`dir = CA_XFER_GET` / `CA_XFER_PUT` ([ch. 2](02_core_data_structures.md)).

## The R1–R4 contract

The lifecycle is ownership-based and **not transitive**. These four rules are the
contract every piece of view code depends on:

- **R1** — `ca_attach(x)` makes **`x.ptr` only** valid. It says nothing about any
  other array.
- **R2** — there is **no transitive guarantee**: attaching a child does *not*
  attach its parent. (An implementation may attach the parent as a side effect,
  but that is an internal optimisation, never something to rely on.)
- **R3 (necessity)** — if you want to touch `ca->parent->ptr` directly, call
  `ca_attach(ca->parent)` yourself. Do not assume the child's attach filled it
  (that is just R2 restated).
- **R4 (ordering)** — when attaching both parent and child, open parent → child
  and close child → parent, with sync in the same order as attach:
  ```c
  ca_attach(parent); ca_attach(child);
  /* … work … */
  ca_sync(child);    ca_sync(parent);
  ca_detach(child);  ca_detach(parent);
  ```
  Symmetric nesting keeps things correct even if a view internally double-attaches
  (attach/detach are idempotent via the `attach` refcount).

### Reader and writer conventions

Two conventions follow from R1–R4 for code that touches a parent's `ptr`:

- **Reader (opportunistic use of the parent buffer)** — guard with the marker,
  do not test the raw pointer:
  ```c
  if ( ca_is_attached(ca->parent) ) { use ca->parent->ptr; }
  else { self-attach, or fall back; }
  ```
- **Writer (helper that assumes the parent is attached)** — make the *caller*
  (the public attach/sync/detach entry) satisfy the precondition by calling
  `ca_attach(ca->parent)` before invoking the helper. The helper documents that
  it requires an attached parent; the caller guarantees it.

New code should never assume "the parent is already attached." If you need it,
attach it.

## The alias fast path

For a CAStride view that is fully contiguous, attach does **not** allocate and
copy. It just points `ptr` at `parent->ptr + base_offset`:

- writes land directly in the parent's memory (it *is* the parent's memory),
- `sync` is a no-op (nothing to write back — the data was never separate),
- `detach` does not `xfree` (the buffer belongs to the parent).

This is what makes `reshape` and row slices O(1): `a[i..j, nil]` and
`a.reshape(...)` produce contiguous CAStride views that alias rather than copy.
`ca_stride_is_contiguous` is the gate; [ch. 6](06_view_algebra_and_castride.md)
covers the full fast-path ladder.

## Compose-fold: collapsing a chain

A view's parent may be another view, several deep. Rather than materialise every
intermediate, the CAStride family composes strides down the chain and attaches
only the **root** entity (or the nearest non-CAStride ancestor) — the mechanism
that keeps a deep view chain as cheap as one gather. The `ca_fold_t` state, the
`fold_stride` one-hop primitive, and the measured speedup are in "Compose-fold in
detail" below.

## The public `attach!` (and the internal forms)

`attach!` is a block form that wraps attach + sync + detach in `rb_ensure`, so the
sync/detach run even if the block raises. Mechanically the pattern it expresses is
*one* materialise on entry, N operations against the now-contiguous `ptr`, then
*one* sync on exit — the amortisation that makes a "materialise once, write into
the buffer repeatedly, flush once" loop cheap.

It is a minor convenience, not load-bearing: internally it is used in only a
handful of places (`lib/carray/iterator.rb`) and is kept mainly as insurance. The
real machinery is `ca_attach` / `ca_sync` / `ca_detach`.

`__attach__` / `__sync__` / `__detach__` (double underscore) are **internal
only** — never call them from user or ext code.

## Why this is a thread-safety hazard

The whole lifecycle assumes a single owner. A view that has gathered its parent's
data, while another thread mutates the parent directly, will scatter a stale image
back over the parent on sync — corrupting it. This is a CArray-specific structural
hazard that materialise-and-sync-back libraries have and pure-strided libraries do
not. CArray's stance: thread-safety across "derived view × entity" concurrent
operation is a **non-goal**, and the lock-free attach paths depend on that
assumption. It is a user-facing contract,
not a limit on in-kernel parallelism.

## The full API surface

All declared in `ext/carray.h`. Group them by purpose:

### Lifecycle (per array)

```c
void ca_allocate (void *ca);   /* ptr only, no gather */
void ca_attach   (void *ca);   /* ptr + gather */
void ca_update   (void *ca);   /* re-gather into existing ptr */
void ca_sync     (void *ca);   /* scatter ptr back to parent */
void ca_detach   (void *ca);   /* xfree ptr (if owned) + detach parent */
```

### Lifecycle (variadic, nest-safe)

```c
void ca_allocate_n (int n, ...);
void ca_attach_n   (int n, ...);   /* opens left-to-right (R4) */
void ca_update_n   (int n, ...);
void ca_sync_n     (int n, ...);
void ca_detach_n   (int n, ...);   /* closes right-to-left (R4) */
```

The `_n` variadic forms encode R4 ordering for you. Pass the deepest
parent first, the leaf last, and they nest correctly:

```c
ca_attach_n(2, parent, child);    /* parent → child */
/* ... */
ca_sync_n(2, child, parent);      /* child → parent (R4 order) */
ca_detach_n(2, child, parent);    /* child → parent */
```

Internally each `_n` walks the va_list and calls the singular form; the
singular form is the actual contract carrier. **Idempotent**: each call
bumps a refcount; opening twice and closing twice is safe.

### Alias eligibility

```c
int  ca_attach_is_alias (void *ca);
        /* level 1 — true iff ca_attach(ca) is O(1).
           True for entities, CAWrap, CScalar, and CAStride-family
           views whose composed strides are row-major contiguous. */

int  ca_iter_can_alias  (void *ca, int level);
        /* level-aware variant (1 = contig, 2 = strided callback,
           3 = multi-d).  Used by the kernel iterator to decide its
           dispatch level without committing to attach. */
```

These are predicates: they answer "would `ca_attach` alias or copy?"
without doing the work. The kernel iterator and the sweep family use
them to choose between the alias and the materialise path
([ch. 11](11_kernel_iterator.md), [ch. 13](13_sweep_author_surface.md)).

### Operation-table slots (set per obj_type, not called by users)

These are the `ca_func[obj_type].*` callbacks the lifecycle dispatches
through; they have the same names as the user-facing API minus the
prefix:

```c
ca_func[T].allocate  (void *ca);
ca_func[T].attach    (void *ca);
ca_func[T].sync      (void *ca);
ca_func[T].detach    (void *ca);
ca_func[T].fill_data (void *ca, void *value);
ca_func[T].create_mask(void *ca);
```

You never call these directly — `ca_attach(ca)` dispatches into
`ca_func[ca->obj_type].attach(ca)`. But when you read a `ca_obj_*.c`
file, every function whose name matches one of these slots is what gets
installed there.

## The xfer protocol: the data path

Behind every `attach` / `sync` is the **xfer protocol** — the unified
gather/scatter interface that replaces the historical `copy_data` /
`sync_data` pair. The direction enum:

```c
#define CA_XFER_GET 0   /* gather: view -> data buffer */
#define CA_XFER_PUT 1   /* scatter: data buffer -> view */
```

Every view implements (or inherits) the four `xfer_*` slots in `ca_func`
(`xfer_index` / `xfer_addrs` / `xfer_stride` / `xfer_all` — the struct fields and
their per-slot comments are in [ch. 2](02_core_data_structures.md), the operation
table). Two dispatch details matter here: `xfer_stride` takes `strides[]` as the
*destination* (caller-buffer) layout, which is what the kernel iterator's
per-fiber fused path and the partial-materialise path use; `xfer_all` is the
whole-view transfer the scratch path uses, and `ca_copy_data` / `ca_sync_data` are
thin forwarders onto it.

Five public entry points wrap the dispatch:

```c
void ca_xfer_index  (void *ca, ca_size_t *idx, void *data, int dir);
void ca_xfer_addrs  (void *ca, ca_size_t n, ca_size_t *addrs,
                     void *data, int dir);
void ca_xfer_stride (void *ca, ca_size_t *starts, ca_size_t *counts,
                     ca_size_t *strides, void *data, int dir);
void ca_xfer_all    (void *ca, void *data, int dir);
void ca_copy_data   (void *ca, char *data);   /* = xfer_all GET */
void ca_sync_data   (void *ca, char *data);   /* = xfer_all PUT */
```

The take-away for an ext author:
every data move ends up in one of these four slots, so a new view
connects to the lifecycle by filling them (or, for CAStride
descendants, inheriting them from the base).

### Per-cell fetch / store wrappers

When you do need a single-cell access:

```c
void ca_fetch_index (void *ca, ca_size_t *idx, void *out);
void ca_fetch_addr  (void *ca, ca_size_t addr,  void *out);
void ca_store_index (void *ca, ca_size_t *idx, void *in);
void ca_store_addr  (void *ca, ca_size_t addr,  void *in);

/* VALUE-level analogues */
VALUE rb_ca_fetch_index (VALUE self, ca_size_t *idx);
VALUE rb_ca_fetch_addr  (VALUE self, ca_size_t addr);
VALUE rb_ca_store_index (VALUE self, ca_size_t *idx, VALUE val);
VALUE rb_ca_store_addr  (VALUE self, ca_size_t addr,  VALUE val);
```

These call `xfer_index` / `xfer_addrs` under the hood.

## Compose-fold in detail

A view's parent may be another view, several deep
(`a.transpose.reshape(...).flip[2..5]`). Attaching each link in turn
would materialise every intermediate. Instead, the CAStride family
**composes strides down the chain** and attaches only the **root**
entity (or the nearest non-CAStride ancestor), skipping the
intermediate materialisations.

The state threaded through the compose walk:

```c
typedef struct {
  int8_t    ndim;
  ca_size_t base;
  ca_size_t strides[CA_RANK_MAX];
  ca_size_t counts [CA_RANK_MAX];
} ca_fold_t;
```

The walk entry point and one-hop primitive:

```c
void ca_stride_compose_to_root (CAStride *leaf,
                                CArray  **out_root,
                                ca_size_t *out_strides,
                                ca_size_t *out_base);

int  ca_stride_compose_through (CAStride *leaf, CAStride *parent,
                                ca_size_t *out_strides,
                                ca_size_t *out_base);
```

For non-CAStride participants that can still contribute one hop, the
`fold_stride` op-table slot is the single-step decline-or-compose:

```c
int (*fold_stride)(void *ca, ca_fold_t *f, void **next_parent);
        /* Returns 1 = composed *f into next_parent's byte space.
           Returns 0 = decline; this view is the fold boundary. */
```

CAWindow currently implements `fold_stride` (a "sometimes-fold"
participant); CAGrid / CSA / CATile follow. CAStride family leaves it
NULL — they are handled open-inline by `ca_stride_compose_to_root`.

The practical effect: on the common pattern (a large entity, a
non-contiguous middle view, a small leaf), `view.copy` /
`view.dump_binary` runs 1.5×–tens-of-times faster than per-link attach,
because only the root is ever read.

## Sequential-address detection

When `xfer_addrs` receives a list that happens to be a contiguous run,
the engine can promote it to a single contig transfer. The shared
predicate:

```c
int ca_xfer_addrs_is_sequential_run (ca_size_t n, ca_size_t *addrs,
                                     ca_size_t *base_out);
        /* 1 = addrs[i] == addrs[0] + i for all i; *base_out = addrs[0].
           Used by view xfer_addrs slots + ca_xfer_addrs_dispatch to
           opportunistically promote address-list xfers to contig. */
```

Companion: `ca_resolve_attached_root_via_identity(cand)` walks
identity-CAStride layers (= reshape chains) to find an already-attached
root, so the `parent->ptr` gate lifts naturally through view
intermediates.

## Bulk bit pack / unpack (CABitarray)

Specialised xfer fast paths for CABitarray (1-bit-per-cell):

```c
void ca_bit_unpack (const uint8_t  *src, ca_size_t elements,
                    ca_size_t pbytes, int multibyte_byteswap,
                    boolean8_t *dst);
void ca_bit_pack   (const boolean8_t *src, ca_size_t elements,
                    ca_size_t pbytes, int multibyte_byteswap,
                    uint8_t *dst);
        /* LSB-first within each byte (fixed); pbytes = parent element
           width; multibyte_byteswap reverses byte order within each
           multibyte cell (big-endian network order). */
```

## Block-form attach for ext authors

Most ext code should never call `ca_attach` directly — the kernel
iterator and sweep families own the lifecycle. The one case where you
genuinely need it is "hand the whole contig buffer to a third-party
library"; for that, use the sweep buffer macros:

```c
CA_WITH_BUFFER(ca, T, ptr, n)         { /* read-only */ }
CA_WITH_BUFFER_WRITABLE(ca, T, ptr, n) { /* writable, sync on exit */ }
```

Both wrap attach / (sync) / detach in a `for` loop teardown clause —
exception-safe across `break`, leaks across `return`. For the
`rb_ensure`-protected function form, use `rb_ca_call_with_buffer`
([ch. 13](13_sweep_author_surface.md)). The Ruby-surface counterpart is `attach!`
("The public `attach!`" above).

## Where to go next

- The CAStride fast-path ladder and contiguity →
  [ch. 6](06_view_algebra_and_castride.md).
- The mask, which attaches and syncs alongside its parent →
  [ch. 5](05_mask_and_undef.md).
- Writing a kernel that lets the iterator handle attach for you (the
  default) → [ch. 10](10_author_surface_overview.md); `ca_attach` is the
  last resort.
- The per-axis-descriptor framework that drives gather/scatter for
  non-strided views → [ch. 7](07_axis_descriptor_framework.md).
- The full helper catalogue, including alias predicates and address
  arithmetic → [ch. 15](15_carray_h_helper_reference.md).

---
*When done, update the status row in [README](README.md).*
