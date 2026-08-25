# 15 carray.h helper reference

> **Status: draft.** Written through once; not yet re-verified against a live
> build. See [README](README.md) for conventions.

`ext/carray.h` is the single header a companion C extension `#include`s, and
it acts as an **umbrella**: at the bottom it pulls in
`carray_math_kernel.h` (the kernel dispatch tables), `ca_kernel_iterator.h`
(the kernel-iterator surface), and `carray_call_cfunc.h` (the call_cfunc
prototypes). Once you include `carray.h`, every primitive listed in this
chapter is in scope.

The purpose of this chapter is twofold: (a) keep you from re-inventing
primitives that already exist, and (b) keep new helper names from
**leaking into the CArray vocabulary**. The latter is a firm discipline —
see [the closing section](#the-discipline-dont-grow-the-vocabulary).

## Naming conventions are a contract

The prefix tells you the input type. Read it and you know how to call the
function without reading the body (memory: prefix-decides-input-type):

| Prefix | Takes | Returns | Where to use it |
|--------|-------|---------|-----------------|
| `rb_ca_*` / `rb_carray_*` | Ruby `VALUE` | `VALUE` | bound as a Ruby method, or invoked from another `rb_*` callback that already holds a `VALUE` |
| `ca_*` / `CA_*` | `CArray *` (raw) | `void` / `int` / `CArray *` | invoked from C internals that already hold a `CArray *` (= got via `GetCArray`) |

So `rb_ca_copy` is the Ruby-method-level copy (`VALUE → VALUE`), while a C
function that already holds a `CArray *` calls the `ca_*` primitive
directly. A function that violates the prefix (takes a `CArray *` but is
named `rb_ca_*`, or vice versa) is a bug or a rename target —
`ca_call_with_buffer` → `rb_ca_call_with_buffer` is one such
correction (the function takes a `VALUE`, so `rb_ca_*` is correct).

The bridge between the two worlds is `GetCArray`:

```c
#define GetCArray(obj, ca) \
    TypedData_Get_Struct((obj), CArray, &carray_data_type, (ca))
```

It accepts any concrete CArray subclass (CScalar / CAWrap / every CAView
descendant) because every TypedData is registered with `carray_data_type`
as parent.

## The CArray core type

`CArray` is the base struct everything else extends. The public fields
(read from C; never write them by hand):

```c
struct _CArray {
  int16_t   obj_type;     /* dispatch key (CA_OBJ_ARRAY / CA_OBJ_STRIDE / ...) */
  int8_t    data_type;    /* CA_FLOAT64 / CA_INT32 / ... */
  int8_t    ndim;
  int32_t   flags;        /* CA_FLAG_* */
  ca_size_t bytes;        /* element size in bytes */
  ca_size_t elements;     /* total cells = Π dim[i] */
  ca_size_t *dim;
  char     *ptr;          /* data buffer; NULL iff not attached */
  CArray   *mask;         /* child CArray (CA_BOOLEAN) or NULL */
  char     *_pool;        /* framework-managed, do NOT touch */
};
```

The relatives — `CScalar`, `CAWrap` (`typedef CArray CAWrap`), `CAView`,
`CAStride`, `CARefer`, `CABlock`, `CAWindow`, `CAStack`, `CAObject`, … —
all start with this same prefix so a `(CArray *)` cast lets you read the
shape uniformly. See [ch. 2](02_core_data_structures.md) for the full
layout.

### Element-size and length helpers

```c
#define ca_length(ca)       ((ca)->elements * (ca)->bytes)
#define ca_ndim(ca)         ((ca)->ndim)
#define ca_shape(ca)        ((ca)->dim)
#define ca_is_attached(ca)  ((ca)->ptr != NULL)
#define ca_is_empty(ca)     ((ca)->elements == 0)
```

`ca_is_attached` is the structural property — `ca->ptr != NULL` — used as
the lifecycle marker (see [ch. 4](04_attach_lifecycle.md), R1–R4 contract).

## Allocation primitives

| Primitive | Use |
|-----------|-----|
| `CArray *carray_new(int8_t data_type, int8_t ndim, ca_size_t *dim, ca_size_t bytes, CArray *mask)` | Fresh entity, **C-side** (returns `CArray *`). Use when you need the raw struct, e.g. for a temporary entity that never becomes a Ruby object. |
| `VALUE rb_carray_new(int8_t data_type, int8_t ndim, ca_size_t *dim, ca_size_t bytes, CArray *mask)` | Same, but boxed in a Ruby object — the normal entry point for kernel output. |
| `VALUE rb_carray_new_safe(...)` | Like `rb_carray_new` but with explicit overflow checks on `Π dim[i] * bytes`. Use when `dim[]` comes from untrusted Ruby input. |
| `VALUE rb_cscalar_new(int8_t data_type, ca_size_t bytes, CArray *mask)` | Fresh rank-0 CScalar (a CArray whose `ndim == 0`). |
| `VALUE rb_carray_wrap_ptr(int8_t data_type, int8_t ndim, ca_size_t *dim, ca_size_t bytes, CArray *mask, char *ptr, VALUE refer)` | CAWrap around an externally-owned buffer (used by `from_memory_view` etc.). `refer` is the GC anchor for the underlying owner. |

`bytes` is `0` for typed elements (use the auto-resolved
`ca_sizeof[data_type]`) and the byte width for `CA_FIXLEN`.

### Slab-shaped allocation (`rb_ca_new_reduced`)

When writing a kernel that produces a reduction output, this is the right
allocator — it derives the output shape from the input shape minus the slab
axes:

```c
VALUE rb_ca_new_reduced (VALUE self,
                         int8_t *slab_axes,   /* ascending order */
                         int8_t  naxes,
                         int32_t data_type,
                         int     keep_axis);
```

`keep_axis` (0/1) controls whether reduced axes collapse (default 0) or are
preserved as size-1. The function lives in `ext/carray_core.c` and is the
capstone helper that every reduce kernel uses.

### Parsing `axis:` arguments (`rb_ca_parse_reduce_axes*`)

Variadic / kwarg axis parsers — the capstone helpers:

```c
int8_t rb_ca_parse_reduce_axes    (int argc, VALUE *argv,
                                   CArray *ca, int8_t *out_axes);
int8_t rb_ca_parse_reduce_axes_kw (VALUE axis_val,
                                   CArray *ca, int8_t *out_axes);
```

Accept Integer args, an `Array` of Integers, or `Qnil/Qundef` (= full
reduction). Normalises negative axes Python-style, checks for duplicates,
range, and overflow; raises `ArgumentError` on any violation.

## Copy / transfer primitives

Whole-view transfer is the universal data path; everything funnels through
`xfer_all`:

```c
void ca_xfer_all   (void *ca, void *data, int dir);
        /* dir = CA_XFER_GET (gather: view -> data)
                CA_XFER_PUT  (scatter: data -> view)        */

void ca_copy_data  (void *ca, char *data);      /* alias for xfer_all GET */
void ca_sync_data  (void *ca, char *data);      /* alias for xfer_all PUT */
void ca_fill_data  (void *ca, void *value);     /* broadcast a scalar */
```

`ca_xfer_all` is the protocol-level entry point ([ch. 4](04_attach_lifecycle.md)
"xfer protocol"); the legacy `ca_copy_data` / `ca_sync_data` are kept as
thin forwarders for compatibility but will eventually be removed.

### Indexed / strided transfer

For partial transfers:

```c
void ca_fetch_index (void *ca, ca_size_t *idx, void *out);
void ca_fetch_addr  (void *ca, ca_size_t addr, void *out);
void ca_store_index (void *ca, ca_size_t *idx, void *in);
void ca_store_addr  (void *ca, ca_size_t addr, void *in);

void ca_xfer_index  (void *ca, ca_size_t *idx, void *data, int dir);
void ca_xfer_addrs  (void *ca, ca_size_t n, ca_size_t *addrs,
                     void *data, int dir);
void ca_xfer_stride (void *ca, ca_size_t *starts, ca_size_t *counts,
                     ca_size_t *strides, void *data, int dir);
```

`ca_xfer_stride` is the per-region xfer with a caller-supplied destination
layout (`strides[]` in bytes). The kernel iterator uses it internally for
per-fiber fused delivery.

### CArray-to-CArray copy

```c
CArray *ca_copy     (void *ca);   /* C-side; see rb_ca_copy for VALUE */
CArray *ca_template (void *ca);   /* same shape/type, fresh allocation */
CArray *ca_template_safe2 (void *ca, int8_t data_type, ca_size_t bytes);

VALUE   rb_ca_copy              (VALUE self);
VALUE   rb_ca_to_ca             (VALUE self);  /* always self for CArrays */
VALUE   rb_ca_template          (VALUE self);
VALUE   rb_ca_template_with_type(VALUE self, VALUE rtype, VALUE rbytes);
VALUE   rb_ca_template_n        (int n, ...);  /* broadcast template */
```

Semantics nuance:
`rb_ca_copy` always allocates a fresh entity (the "I want an independent
buffer" path); `rb_ca_to_ca` returns `self` for any CArray (= the "give me
a CArray, no work needed" path, with lazy views forced via Ruby override).
Use `rb_ca_copy` whenever you intend to mutate.

`rb_ca_template_n` is the broadcasted-template entry point — use it when
your kernel has N inputs and you need an output sized by their broadcast
shape.

## The attach lifecycle

The full contract is [ch. 4](04_attach_lifecycle.md); the surface is:

```c
void ca_attach (void *ca);   /* materialise (gather) data into ca->ptr */
void ca_update (void *ca);   /* re-gather without bumping attach count */
void ca_sync   (void *ca);   /* scatter ca->ptr back to parent storage */
void ca_detach (void *ca);   /* release; xfree if scratch, decrement count */

void ca_attach_n (int n, ...);    /* attach N CArrays in nested order */
void ca_sync_n   (int n, ...);
void ca_detach_n (int n, ...);
void ca_update_n (int n, ...);
```

`ca_attach` is **the last resort** for an ext author — kernel_iterator
([ch. 11](11_kernel_iterator.md)) and sweep ([ch. 13](13_sweep_author_surface.md))
deliver data without you ever calling attach. Reach for `ca_attach`
directly only for CAObject (per-cell Ruby callback) or a documented
boundary that genuinely needs whole-view materialisation.

### Alias-eligibility predicate

```c
int ca_attach_is_alias (void *ca);          /* level 1, contig-only */
int ca_iter_can_alias  (void *ca, int level);/* level-aware (1/2/3) */
```

`ca_attach_is_alias` is true iff `ca_attach` would be `O(1)` (entity /
CAWrap / row-major-contiguous CAStride). The kernel iterator uses
`ca_iter_can_alias(ca, 2)` for the L2-strided alias decision.

## Coerce / wrap

```c
VALUE rb_ca_wrap_readonly (VALUE obj, VALUE vtype);   /* CAFake cast */
VALUE rb_ca_wrap_writable (VALUE obj, VALUE vtype);

#define ca_wrap_readonly(obj, data_type) /* writes back into obj */ \
        (obj = rb_ca_wrap_readonly(obj, INT2NUM(data_type)),       \
         (CArray *) DATA_PTR(obj))
#define ca_wrap_writable(obj, data_type) /* same, writable */      \
        (obj = rb_ca_wrap_writable(obj, INT2NUM(data_type)),       \
         (CArray *) DATA_PTR(obj))
```

`rb_ca_wrap_readonly` is **pass-through when the data type already
matches** — returns the original VALUE with no allocation, builds a CAFake
cast view only on a mismatch. Use it to coerce a kernel input to a fixed
type without paying for a copy when the type is already correct.

## Mask primitives

Full background: [ch. 5](05_mask_and_undef.md). The mask is itself a
CArray (`CA_BOOLEAN`) hung off `ca->mask`; the helpers below let you read,
build, and propagate it:

```c
boolean8_t *ca_mask_ptr        (void *ca);   /* NULL if ca has no mask */
int         ca_has_mask        (void *ca);
int         ca_is_any_masked   (void *ca);
int         ca_is_all_masked   (void *ca);
ca_size_t   ca_count_masked    (void *ca);
ca_size_t   ca_count_not_masked(void *ca);

void        ca_create_mask     (void *ca);   /* allocate ca->mask, all 0 */
void        ca_clear_mask      (void *ca);   /* zero an existing mask */
void        ca_setup_mask      (void *ca, CArray *mask);
void        ca_update_mask     (void *ca);   /* re-gather from parent */
void        ca_copy_mask       (void *ca, void *other);

/* OR-merge masks from N sources into ca's mask */
void ca_copy_mask_overlay   (void *ca, ca_size_t elements, int n, ...);
void ca_copy_mask_overlay_n (void *ca, ca_size_t elements, int n,
                             CArray **slist);
/* attach-safe variant: OR via xfer_all into arena scratch */
void ca_mask_overlay_safe   (CArray *ca_out, int n, ...);

/* Unmask in place (fill masked cells with fill_value, drop the mask) */
void    ca_unmask        (void *ca, char *fill_value);
CArray *ca_unmasked_copy (void *ca, char *fill_value);
```

The `*_overlay` variants are the workhorse for kernel mask propagation:
build the output entity first, then OR the input masks into its mask. The
`_safe` variant avoids attaching the input masks (= no shrinking-view
materialise).

`CA_UNDEF` and `CA_NIL` are the global sentinels — `CA_UNDEF` is the
"masked cell" value the user sees; `CA_NIL` is the empty-array sentinel.
Both are GC-anchored via `rb_gc_register_mark_object` so the compacting GC
won't move them.

## Type / data-type queries

```c
int8_t ca_promote_type        (int8_t a, int8_t b);
int8_t ca_value_to_data_type  (VALUE obj);
VALUE  ca_data_type_class     (int8_t data_type);
VALUE  rb_ca_data_type_to_sym (int8_t data_type);

int    ca_is_fixlen_type   (void *ca);
int    ca_is_boolean_type  (void *ca);
int    ca_is_numeric_type  (void *ca);
int    ca_is_integer_type  (void *ca);
int    ca_is_float_type    (void *ca);
int    ca_is_complex_type  (void *ca);
int    ca_is_object_type   (void *ca);
#define ca_is_caobject(ca) ((ca)->obj_type == CA_OBJ_OBJECT)
#define ca_is_face(ca)     ca_test_flag((ca), CA_FLAG_IS_FACE)
```

`ca_promote_type` is the *single source* of the data-type promotion rules
(used by `CArray.result_type` and the lazy view layer); never reimplement
the promotion table.

`ca_is_caobject` distinguishes "per-cell Ruby callback" sources, which the
kernel iterator cannot transparently deliver — kernels that want to support
CAObject take a dedicated `ca_attach` branch.

## Type checks (raise on mismatch)

```c
void ca_check_type            (void *ca, int8_t data_type);
void ca_check_ndim            (void *ca, int ndim);
void ca_check_shape           (void *ca, int ndim, ca_size_t *dim);
void ca_check_same_data_type  (void *ca1, void *ca2);
void ca_check_same_ndim       (void *ca1, void *ca2);
void ca_check_same_elements   (void *ca1, void *ca2);
void ca_check_same_shape      (void *ca1, void *ca2);
void ca_check_index           (void *ca, ca_size_t *idx);
int  ca_is_valid_index        (void *ca, ca_size_t *idx);
```

These raise on violation, so the calling code stays linear. Use
`ca_check_same_shape` at the dispatcher level for binop/triop kernels (= the
generated code emits this).

There is no `ca_is_carray` helper — by design. Use the Ruby idiom:

```c
RTEST(rb_obj_is_kind_of(v, rb_cCArray))
```

`rb_obj_is_carray(obj)` (macro) wraps this if you need it. Wrapping it in a
`mygem_is_carray` predicate is a discipline violation (see closing
section).

## Cast / type conversion

The cast table is shared across all element-wise conversion:

```c
typedef void (*ca_cast_func_t)(ca_size_t, CArray *, void *, CArray *,
                               void *, boolean8_t *);
extern ca_cast_func_t ca_cast_func_table[CA_NTYPE][CA_NTYPE];

void ca_cast_block           (ca_size_t n, void *ap1, void *ptr1,
                              void *ap2, void *ptr2);
void ca_cast_block_with_mask (ca_size_t n, void *ap1, void *ptr1,
                              void *ap2, void *ptr2, boolean8_t *m);

void ca_ptr2ptr (void *ca1, void *ptr1, void *ca2, void *ptr2);
void ca_ptr2val (void *ap1, void *ptr1, int8_t data_type2, void *ptr2);
void ca_val2ptr (int8_t data_type1, void *ptr1, void *ap2, void *ptr2);
void ca_val2val (int8_t data_type1, void *ptr1, int8_t data_type2, void *ptr2);
VALUE ca_ptr2obj (void *ca, void *ptr);
void  ca_obj2ptr (void *ca, VALUE obj, void *ptr);
```

The full `CArray#to_<type>` family wraps `rb_ca_to_type` (which inspects
the cast table); to do an inline conversion of a single buffer use
`ca_cast_block_with_mask`.

## Address arithmetic

```c
void      ca_addr2index (void *ca, ca_size_t addr, ca_size_t *idx);
ca_size_t ca_index2addr (void *ca, ca_size_t *idx);

VALUE     rb_ca_addr2index (VALUE self, VALUE raddr);
```

`addr` is the flat row-major index `0..elements-1`; `idx` is the
multi-dimensional index. The two functions are duals.

## VALUE conversion (Ruby scalar bridging)

```c
VALUE       BOOL2OBJ (boolean8_t x);    /* -> INT2FIX(0/1) */
boolean8_t  OBJ2BOOL (VALUE v);

#define     OBJ2LONG(x)  rb_obj2long((VALUE)x)
#define     OBJ2ULONG(x) rb_obj2ulong((VALUE)x)
#define     OBJ2LL(x)    rb_obj2ll((VALUE)x)
#define     OBJ2ULL(x)   rb_obj2ull((VALUE)x)
double      OBJ2DBL (VALUE v);

#define     NUM2CC(n)    /* VALUE -> double complex */
#define     CC2NUM(c)    /* double complex -> VALUE Complex */
```

Use these in `:object` kernel branches and in the bridging code that
converts Ruby method arguments to per-cell C values.

## Flag bits

```c
#define CA_FLAG_SCALAR         1
#define CA_FLAG_MASK_ARRAY     2     /* `ca` IS a mask child */
#define CA_FLAG_VALUE_ARRAY    4     /* `ca` IS the value-only CARefer */
#define CA_FLAG_READ_ONLY      8
#define CA_FLAG_SHARE_INDEX   16
#define CA_FLAG_MULTI_PARENTS 32     /* fan-out view (CAStack, ...) */
#define CA_FLAG_CYCLE_CHECK   64
#define CA_FLAG_IS_FACE      128     /* CAFace lift */

#define ca_set_flag(ca, flag)    ((ca)->flags |=  (flag))
#define ca_unset_flag(ca, flag)  ((ca)->flags &= ~(flag))
#define ca_test_flag(ca, flag)   (((ca)->flags &  (flag)) ? 1 : 0)
```

`CA_FLAG_READ_ONLY` is what a WRITE-path kernel reads via `ca_is_readonly`
to reject scatter targets. `CA_FLAG_MULTI_PARENTS` lets generic code fan
over the `parents[]` of a CAStack instead of `parent` ([ch. 8](08_view_catalog.md)).

## The macro suite

`carray.h` and `ca_kernel_iterator.h` carry the `CA_*` macro families that
build on the primitives above:

- **Kernel iterator** ([ch. 11](11_kernel_iterator.md)) —
  `CA_FOR_EACH_FIBER` / `CA_FOR_EACH_SLAB` / `CA_SLAB_REDUCE_T_*` /
  `CA_SLAB_MAP_T` / `CA_SLAB_SCAN_T` / `CA_L2_FOR_EACH`.
- **Sweep author surface** ([ch. 13](13_sweep_author_surface.md)) —
  `CA_FOR_EACH_ELEMENT` / `CA_FOR_EACH_ELEMENT_INOUT*` /
  `CA_FOR_EACH_ELEMENT_OUT` / `CA_WITH_BUFFER` / `CA_WITH_BUFFER_WRITABLE`.
- **Mask helpers** ([ch. 11](11_kernel_iterator.md)) — `CA_FOR_EACH_UNMASKED`
  / `CA_FOR_EACH_INDEX_UNMASKED` / `CA_COUNT_UNMASKED` / `CA_MASK_GET`.
- **Validation macros** — `CA_CHECK_DATA_TYPE` / `CA_CHECK_RANK` /
  `CA_CHECK_DIM` / `CA_CHECK_BYTES` / `CA_CHECK_INDEX` / `CA_CHECK_BOUND`.
- **Kernel flags** (frozen author tokens) — `CA_KERNEL_WRITE` /
  `CA_KERNEL_NO_MASK` / `CA_KERNEL_FIBER_CONTIG` / `CA_SLAB_AXES` /
  `CA_ITER_OK` / `CA_ITER_ERR_*`.

Before writing a per-type loop, an `attach`-then-read, or a hand-rolled
mask check, look here — all three are already expressed.

## Option parsing helpers

These are the small utilities that show up at the Ruby method boundary:

```c
VALUE rb_pop_options    (int *argc, VALUE **argv);
void  rb_scan_options   (VALUE opt, const char *spec, ...);
void  rb_set_options    (VALUE opt, const char *spec, ...);

int   rb_ca_normalize_axis_value  (VALUE self, VALUE raxis, const char *name);
int   rb_ca_normalize_axis_for_ndim(long raw, int ndim, const char *name);
```

`rb_pop_options` detects and removes a trailing Hash from `(argc, argv)`;
combined with `rb_scan_options` it's how mkkernel-generated dispatchers
read `axis:` / `keepdims:` / similar kwargs.

## High-level method-binding helpers

When you implement a Ruby method by hand (rather than via the DSL), these
fold common boilerplate:

```c
VALUE   rb_ca_freeze     (VALUE self);
void    rb_check_frozen  (VALUE self);     /* preferred over rb_ca_modify */
VALUE   rb_ca_to_a       (VALUE self);
VALUE   rb_ca_to_type    (VALUE self, VALUE rtype, VALUE rbytes);

/* Construction-time index walks (used by initialize-with-block) */
#define CA_LOOP_WITH_VALUE 1
#define CA_LOOP_STORE      2
VALUE   rb_ca_index_walk (VALUE self, CArray *ca, int8_t level,
                          ca_size_t *idx, VALUE ridx, int mode);
```

## What the umbrella `#include "carray.h"` actually brings in

At the bottom of the header you'll find:

```c
#include "carray_math_kernel.h"   /* monop / binop / triop / moncmp / bincmp
                                     typedefs, rb_ca_call_* drivers,
                                     per-data_type dispatch tables */
#include "ca_kernel_iterator.h"   /* CA_FOR_EACH_SLAB / _FIBER families,
                                     CA_SLAB_REDUCE_T_* macros,
                                     ca_iter_state*                       */
#include "carray_call_cfunc.h"    /* ca_call_cfunc_M_N + raw + _r          */
```

So `#include "carray.h"` alone gives you the full ext-author surface — the
data structure, the lifecycle, the kernel iterator, the sweep family
(transitively), call_cfunc, and the math kernel dispatch tables. A
companion C extension never needs to include anything else.

## The discipline: don't grow the vocabulary

This is the firmest rule of the C author surface, and the reason this
chapter exists. **Do not wrap a CArray primitive in a new gem-local
name.** A `cn_gather_to_buf` that just calls `ca_copy_data`, a
`cn_new_float64_ca` that just calls `rb_carray_new`, a `cn_is_carray` that
just calls `rb_obj_is_kind_of` — all forbidden, *even when the body is
correct*. The cost is the name itself: every parallel name forces a future
reader to learn two vocabularies (CArray's and the gem's) and to chase the
wrapper's source to confirm it does nothing extra.

A new name earns its keep **only by adding genuine semantic value**:

- ✓ binding several primitives into one **domain concept** (e.g. a
  Brent-step `cn_brent_propose(...)` that maps 1:1 to a textbook
  algorithm step);
- ✓ encoding a gem-specific **policy** (validation, error messages, a
  mask decision the gem owns);
- ✗ "type safety", "readability", "a shorter name", "avoids `ca_attach`"
  — none of these is semantic value. A `(char *)` cast in place beats a
  wrapper.

The two-stage grep before adding any helper:

```sh
# 1. does a CArray primitive already do it?
grep -nE 'ca_(copy|xfer|attach|fetch|wrap|template|new)|rb_ca(rray)?_(new|wrap)' ext/carray.h
# 2. does your own gem already have a helper?
grep -rn 'static.*inline.*<gem-prefix>_' ext/
```

If no primitive fits, use a kernel-iterator macro
([ch. 11](11_kernel_iterator.md)); if that doesn't fit either, request a
primitive *in CArray core* rather than building a parallel surface in the
gem. Adding a thin `mygem_*` wrapper around a CArray primitive only
inflates the vocabulary; the precedent is the carray-numerics `cn_*`
wrappers, which were deleted for exactly this reason.

## The reorg in flight

`ext/carray.h` is being split: a public API surface, an `internal.h` for
internals, and the ext-author surface (attach contract, the monop dispatch
table, the kernel iterator) kept on the public side. The litmus test for
the split is whether a companion gem like carray-vmath compiles against the
public header alone (memory: carray_h_public_internal_split). Until that
lands, treat `carray.h` as the single grep target; once it lands, update
this chapter to point at the right header per concern. The internal sort
kernels (`ca_sort_kernels.h`) are already explicitly *not* pulled into the
umbrella — a hint of what's coming.

## Where to go next

- The macros these primitives underpin → [ch. 11](11_kernel_iterator.md),
  [ch. 13](13_sweep_author_surface.md).
- Why `ca_attach` is the last resort, not a primitive to reach for →
  [ch. 10](10_author_surface_overview.md), [ch. 4](04_attach_lifecycle.md).
- Bridging a scalar C function instead of a per-axis kernel →
  [ch. 14](14_call_cfunc.md).
- Generating typed coverage from a one-screen DSL →
  [ch. 12](12_mkkernel_dsl.md).

---
*When done, update the status row in [README](README.md).*
