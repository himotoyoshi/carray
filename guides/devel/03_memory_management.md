# 03 Memory management

> **Status: draft.** Written through once; not yet re-verified against a live
> build. See [README](README.md) for conventions.

How CArray allocates, frees, and integrates with Ruby's GC. Three topics: the
allocator discipline, the pool framework that consolidates a view's metadata, and
GC integration.

## The allocator rule: `xmalloc` / `xfree` only

All CArray allocation goes through Ruby's accounted allocator: `xmalloc`,
`xfree`, and the `ALLOC` / `ALLOC_N` macros (which wrap `xmalloc`).

**`free()` is forbidden.** Mixing raw `free()` with `xmalloc` desyncs Ruby's
internal malloc byte counters, which drive GC scheduling — the corruption is
silent and shows up far from the cause. The rule has one direction only: anything
allocated with `xmalloc`/`ALLOC`/`ALLOC_N` is released with `xfree`.

No NULL checks are needed after allocation. On Ruby 3.0+ (which CArray requires)
`xmalloc` raises `rb_memerror()` on exhaustion rather than returning `NULL`, so
the historical `malloc_with_check` wrapper was dead code and has been removed.
Write `p = ALLOC_N(...)` and use `p`; it cannot be `NULL`.

## GC integration: full delegation

CArray has **no GC trigger of its own.** It relies entirely on Ruby's GC, fed by
the byte accounting that `xmalloc`/`xfree` perform. The old NArray-style forced
collection machinery (`ca_mem_count`, `ca_mem_usage`, `ca_gc_interval`, explicit
`rb_gc()` calls) was removed as a 3.0 breaking change (commit `458e68d`). Do not
reintroduce a manual GC trigger; if memory pressure is a concern, the answer is
to allocate less (e.g. compose-fold, partial materialise), not to force GC.

For `CA_OBJECT` arrays the GC must additionally *see* the contained `VALUE`s;
that is the `dmark`/`ca_mark` responsibility covered in
[ch. 2](02_core_data_structures.md).

## The pool framework

A view carries several small metadata arrays — `dim` always, plus `strides` for
CAStride, plus a subclass tail (CABlock's `start`/`step`/`count`/`size0`). The
naive implementation allocates each with its own `ALLOC_N`, so constructing one
view is several allocations and freeing it is several frees.

The **pool framework** consolidates them into a single `char *_pool` buffer per
instance. One allocation holds `dim`, `strides`, and the tail laid end to end;
the metadata pointers are set to offsets within it. The primitives live in
`ext/ca_array_pool.c`:

```c
void * ca_array_alloc      (int8_t obj_type, int8_t ndim);  /* C construction path */
void   ca_array_pool_alloc (void *ap, int8_t obj_type, int8_t ndim);  /* initialize_copy path */
void   ca_array_free       (void *ap);  /* xfree(_pool) + xfree(struct) */
```

- `ca_array_alloc` = `xmalloc(struct_size)` then `ca_array_pool_alloc` — the
  construction path, replacing `TypedData_Make_Struct` + per-field `ALLOC_N`.
- `ca_array_pool_alloc` = `xmalloc(pool_bytes(ndim))` into `ca->_pool`, then run
  `pool_init` — used by `initialize_copy`, where the struct is already allocated.
- `ca_array_free` = `xfree(ca->_pool)` + `xfree(ca)`.

A type opts in by populating three `ca_func` hooks (set in its `Init_ca_obj_*`,
[ch. 2](02_core_data_structures.md)):

```c
ca_func[T].struct_size = sizeof(CA<T>);
ca_func[T].pool_bytes  = ca_<t>_pool_bytes;   /* (int8_t ndim) -> size_t */
ca_func[T].pool_init   = ca_<t>_pool_init;    /* (void *ap, int8_t ndim) */
```

`pool_bytes` returns the total `_pool` size for a given ndim (= dim bytes +
strides bytes + tail bytes); `pool_init` then wires the per-field pointers into
that buffer.

### Pool / legacy coexistence

The framework is per-instance, not global. The marker is `ca->_pool`:

- **`_pool != NULL`** — pool-managed. `free_object` calls `ca_array_free`.
- **`_pool == NULL`** — legacy. The metadata arrays were separately `ALLOC_N`'d,
  and `free_object` falls through to per-field `xfree`.

Per-class `free_object` callbacks branch on `ca->_pool` so the two paths coexist
safely within the same process and even the same type. The migration template for
a dim-only type is: add `pool_bytes`/`pool_init`, gate `setup` with
`if (!ca->_pool)`, route `*_new` through `ca_array_alloc`, branch `free` on
`_pool`, route `initialize_copy` through `ca_array_pool_alloc`, and register the
three hooks in `Init`. CABlock-style prefix+tail types follow CABlock as
the worked example.

### What the pool does *not* cover

The pool hook signature is `(int8_t ndim)` — it knows only the rank. Metadata
whose size depends on more than `ndim` stays on separate `ALLOC_N`:

- CAWindow's `fill` (sized in bytes),
- CAGrid / CASelectAxis `indices` (per-axis, variable, sometimes aliased when
  shared).

This is a deliberate limit of the ndim-only signature, not an omission. Such
types pool what they can (`dim`, `strides`) and allocate the variable parts
separately.

### The reset invariant

Any code that raw-`memcpy`s a CArray struct **must reset the entire `CAView`
prefix in the copy**, not just `_pool`. Three pointer fields would otherwise be
silently shared between the two structs:

- `_pool` — double-free on collection.
- `mask` — shared mask child; whichever struct frees first nukes the other's
  view.
- `parent` — shared CAView parent reference; whichever struct decrements the
  attach refcount last finds it in an inconsistent state.

The only place in core that does such a memcpy is `rb_ca_face_template`
([ch. 9](09_faces.md)), and the audit confirms it resets the prefix (it also
zeroes `attach` / `nosync`, nulls `ptr`, and re-allocates `dim` fresh). If you add
another struct-copying path, honour this invariant: reset the whole CAView prefix
(including `_pool`) so no stale pointers are aliased.

> **Ext authors: never touch `_pool` directly.** The header marks it reserved.
> Read it, write it, or `xfree` it yourself and you will corrupt the framework's
> bookkeeping. Allocate through `ca_array_alloc` / `rb_carray_new`, free through
> the registered `free_object`.

## Mask storage ownership

A mask is a child CArray on the parent's `mask` field. Its data and struct are
owned by the parent: freeing the parent frees the mask. The mask's own TypedData
therefore uses **`dfree = ca_free_nop`** so it does not double-free. This is the
storage side of the mask; its semantics are [ch. 5](05_mask_and_undef.md).

## The mark and free path

Ruby's GC calls into CArray through three TypedData hooks per
obj_type:

```c
ca_typeddata[obj_type] = &(rb_data_type_t){
  .wrap_struct_name = "CA<T>",
  .function = {
    .dmark    = ca_mark,             /* marks VALUEs when CA_OBJECT */
    .dfree    = ca_free,             /* dispatches to ca_func[T].free_object */
    .dsize    = ca_<t>_dsize,        /* exact byte size for accounting */
    .dcompact = NULL,                /* compaction off (dmark covers it) */
  },
  /* ... */
};
```

`ca_mark` walks `ca->ptr` as a `VALUE[]` when `data_type == CA_OBJECT`,
calling `rb_gc_mark` on each — so the contained Ruby objects survive
collection. For numeric arrays there is nothing to mark; `ca_mark`
returns immediately. The mask sibling is also marked (cascade).

`ca_free` dispatches to `ca_func[obj_type].free_object`. The four
variants you see across `ca_obj_*.c`:

```c
void free_carray (void *ca)
{
  ca_free(ca->mask);                    /* 1. cascade into mask */
  xfree(ca->ptr);                       /* 2. entity owns data buffer */
  if (ca->_pool) ca_array_free(ca);     /* 3a. pooled: _pool + struct */
  else           { xfree(ca->dim); xfree(ca); }  /* 3b. legacy */
}

void free_ca_wrap (void *ca)
{
  ca_free(ca->mask);
  /* NOTE: ca->ptr is foreign — DO NOT xfree */
  if (ca->_pool) ca_array_free(ca);
  else           { xfree(ca->dim); xfree(ca); }
}

/* CAStride family — ca_obj_stride.c */
void ca_stride_func_free_object (void *ca)
{
  if (((CAView *)ca)->ptr && !ca_is_alias(ca)) xfree(((CAView *)ca)->ptr);
  /* parent is freed by GC (parent's TypedData), not by us */
  if (((CArray *)ca)->_pool) ca_array_free(ca);
  else                       { /* legacy free for strides + tail */ }
}

/* Mask sibling — registered with dfree = ca_free_nop */
void ca_free_nop (void *ca) { /* no-op — parent's cascade frees us */ }
```

The mask's `dfree = ca_free_nop` is what lets the parent's cascade free it exactly
once ([ch. 5](05_mask_and_undef.md) for why this is the most-missed step when
adding a view).

## `ca_template` — building a "same-shape, same-type" entity

A frequent need is "give me a fresh entity shaped like this view, so I
can write a kernel result into it". The helpers
([ch. 15](15_carray_h_helper_reference.md)):

```c
CArray *ca_template       (void *ca);
CArray *ca_template_safe  (void *ca);
CArray *ca_template_safe2 (void *ca, int8_t data_type, ca_size_t bytes);

VALUE   rb_ca_template            (VALUE self);
VALUE   rb_ca_template_with_type  (VALUE self, VALUE rtype, VALUE rbytes);
VALUE   rb_ca_template_n          (int n, ...);
```

`rb_ca_template_n` is the multi-input broadcast template: pass N input
VALUEs, get an output sized by their broadcast shape. Used internally
by `call_cfunc` ([ch. 14](14_call_cfunc.md)).

## What about `CARRAY_DEV`?

`CARRAY_DEV=1` is the build flag every developer machine should export
permanently. It enables
~639 spec_ai smoke tests that exercise the substrate paths in this
chapter — `ca_array_pool_alloc` + `_free` symmetry, mask sibling
TypedData wiring, the struct-copy invariant. Without it, those tests
report as `omit` and a regression in the allocator paths goes
undetected. [ch. 19](19_build_generators_testing.md) covers the build
and test discipline.

## Where to go next

- The lifecycle that fills and empties `ptr` →
  [ch. 4](04_attach_lifecycle.md).
- The struct fields and `dsize` that the pool sizes →
  [ch. 2](02_core_data_structures.md).
- The mask, whose ownership cascade is implemented here →
  [ch. 5](05_mask_and_undef.md).
- `CARRAY_DEV` and the test discipline that catches allocator
  regressions → [ch. 19](19_build_generators_testing.md).

---
*When done, update the status row in [README](README.md).*
