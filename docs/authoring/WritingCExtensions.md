# Writing C Extensions with CArray

*A guide for gem authors who want to accept, produce, or operate on CArray from C.*

## Table of Contents

### Part I — CArray from C: the object itself

1. [Introduction](#1-introduction)
   - 1.1 Who this guide is for
   - 1.2 What this guide is *not*
   - 1.3 Minimum requirements
   - 1.4 A minimal example

2. [The `CArray` struct](#2-the-carray-struct)
   - 2.1 Fields of the base struct
   - 2.2 Entities: `CArray`, `CScalar`, `CAWrap`
   - 2.3 Getting the struct from a Ruby `VALUE`
   - 2.4 Reading shape and element data

3. [Class hierarchy and `obj_type` dispatch](#3-class-hierarchy-and-obj_type-dispatch)
   - 3.1 `CAView` and the view families
   - 3.2 The function table (`ca_func[]`)
   - 3.3 `ca_install_obj_type` (defining a new kind)
   - 3.4 Identifying what you got (predicates)
   - 3.5 `CASource` — a source class of your own

4. [Views: accessing a derived array's data from C](#4-views-accessing-a-derived-arrays-data-from-c)
   - 4.1 What a view is
   - 4.2 Making the data accessible: `ca_attach` / `ca_detach`
   - 4.3 Writing back: `ca_sync`
   - 4.4 Attaching the parent is not automatic
   - 4.5 Canonical patterns
   - 4.6 Read-only views and `nosync`

5. [Masks](#5-masks)
   - 5.1 What a mask actually is, in C
   - 5.2 The mask is created on demand
   - 5.3 The mask travels with the data
   - 5.4 Views inherit their parent's mask
   - 5.5 Respecting the mask (simple model)
   - 5.6 Producing a masked result

6. [Memory and lifetime rules](#6-memory-and-lifetime-rules)
   - 6.1 `xmalloc` / `ALLOC` / `xfree`
   - 6.2 `ca_free` and `ca_free_nop`

### Part II — Ruby ↔ C interface

7. [Extracting a CArray from a Ruby VALUE](#7-extracting-a-carray-from-a-ruby-value)
   - 7.1 `GetCArray` and direct extraction
   - 7.2 Class / shape / data_type validation
   - 7.3 The `ca_check_*` helpers

8. [Wrapping C memory as a Ruby-visible CArray](#8-wrapping-c-memory-as-a-ruby-visible-carray)
   - 8.1 Entities: `rb_carray_new`, `carray_new`
   - 8.2 Wrapping foreign memory: `rb_ca_wrap_new`, `ca_wrap_new`
   - 8.3 Returning a view (`ca_stride_new` and friends)
   - 8.4 Lifetime and ownership of the wrapped buffer

9. [Type coercion at the boundary](#9-type-coercion-at-the-boundary)
   - 9.1 The `data_type` enum, `ca_sizeof[]`, `ca_valid[]`
   - 9.2 `ca_wrap_readonly(obj, data_type)` ─ accept-any, see-as-data_type
   - 9.3 `ca_wrap_writable(obj, data_type)` ─ for write-back, narrower intake
   - 9.4 Class-method routes (`CArray::Float64.from_memory_view`, etc.)
   - 9.5 `CArray.result_type` from C (N-ary common data_type)
   - 9.6 `CA_OBJECT` and what coercion cannot do

10. [MemoryView interop](#10-memoryview-interop)
    - 10.1 Consuming a MemoryView from C
    - 10.2 Exporting a CArray as a MemoryView
    - 10.3 Talking to Numo, PyCall, Arrow, fiddle

### Part III — Writing computational kernels

11. [Wrapping an external numerical library](#11-wrapping-an-external-numerical-library)
    - 11.1 The shape of the problem
    - 11.2 Worked example: `extlib_smooth`
    - 11.3 Variations and pitfalls

12. [kernel_iterator: an overview](#12-kernel_iterator-an-overview)
    - 12.1 What it gives you
    - 12.2 A glimpse of the code
    - 12.3 Where to read the full guide

### Part IV — Operational concerns

16. [Threading and concurrency](#16-threading-and-concurrency)
    - 16.1 CArray is not thread-safe
    - 16.2 The structural hazard
    - 16.3 When `rb_thread_call_without_gvl` is safe
    - 16.4 Escape hatches for thread-safe needs

17. [Error handling](#17-error-handling)
    - 17.1 `rb_raise` vs. status returns
    - 17.2 Cleaning up attach state (`rb_ensure`, `rb_protect`)
    - 17.3 Argument validation idioms

18. [Building and packaging](#18-building-and-packaging)
    - 18.1 `extconf.rb` ─ finding headers and link info
    - 18.2 Detecting CArray version / feature presence
    - 18.3 Versioning compatibility

---

# Part I — CArray from C: the object itself

## 1. Introduction

### 1.1 Who this guide is for

This guide is for people writing a C extension that needs to touch
CArray objects directly — gem authors, not end users. You are the
target if you are:

- **wrapping an existing C or Fortran numerical library** (a smoothing
  routine, a solver, a codec) and want it to accept and return CArray;
- **producing CArray from C** — reading a file format, decoding a
  buffer, or exporting the result of some computation as a
  Ruby-visible array;
- **writing a numeric kernel yourself** and want it to work on any
  CArray — an entity, a slice, a fancy-indexed view, a masked array —
  without special-casing each kind.

The guide assumes you already write Ruby C extensions: you know
`rb_define_method`, `VALUE`, `NUM2DBL`, TypedData, and the shape of an
`extconf.rb`. It does not assume any prior knowledge of CArray's
internals.

### 1.2 What this guide is *not*

This is not a reference for *using* CArray from Ruby. The Ruby-level
API — indexing, view algebra, reductions, masks as a user sees them —
is documented separately (start from `docs/WhatIsCArray.md` and the
per-feature guides). Here we are strictly below the Ruby surface,
working with `CArray *` and the C API declared in `ext/carray.h`.

It is also not the kernel-author reference. Part III sketches
`kernel_iterator` and points at
[`docs/HOW_TO_WRITE_KERNEL.md`](HOW_TO_WRITE_KERNEL.md), which is the
real reference for writing kernels that ride CArray's universal
dispatch surface. If your task is "call a library function on a
contiguous buffer," you do not need that document and this guide is
self-contained; if your task is "write the inner loop myself, for
every view kind," read this guide for the object model and then move
to the kernel reference.

Finally, it is not exhaustive. `ext/carray.h` declares far more than
any single extension uses. The functions covered here are the ones
that come up when accepting, producing, and operating on CArray at the
boundary; the header is the authority for everything else.

### 1.3 Minimum requirements

- **Ruby 3.0 or later.** CArray 3.0 requires it unconditionally —
  `ruby/memory_view.h` (Ruby 3.0+) is a hard build requirement, and
  the code assumes `xmalloc` raises `NoMemoryError` on OOM rather than
  returning `NULL`.
- **The CArray headers.** Your extension includes a single header,
  `carray.h`, which pulls in the full public C API. Your `extconf.rb`
  has to locate it and the compiled CArray shared object (§18).
- **A C compiler with the usual Ruby toolchain**, the same one that
  built your Ruby. No C++; CArray's public surface is C.

There is no separate "CArray dev" package: the header and the
compiled extension that ships with the `carray` gem are everything an
extension links against.

### 1.4 A minimal example

The smallest useful extension: take a CArray, see it as Float64,
return the sum of its elements as a Ruby Float. It shows the three
recurring moves — extract the struct from a `VALUE`, materialise the
data with `ca_attach`, release it with `ca_detach`:

```c
#include "carray.h"

static VALUE
rb_ca_mysum (VALUE self)
{
  /* See the receiver as Float64 (a no-op if it already is; a lazy
     cast view otherwise). §9 explains this coercion.               */
  volatile VALUE vin = rb_ca_wrap_readonly(self, INT2FIX(CA_FLOAT64));
  CArray *ca; GetCArray(vin, ca);

  /* Make ca->ptr a contiguous Float64 buffer, whatever kind of
     view (or entity) `ca` actually is.                            */
  ca_attach(ca);
  const double *p = (const double *)ca->ptr;

  double acc = 0.0;
  for (ca_size_t i = 0; i < ca->elements; i++) {
    acc += p[i];
  }

  ca_detach(ca);
  return rb_float_new(acc);
}

void
Init_mysum (void)
{
  rb_define_method(rb_cCArray, "mysum", rb_ca_mysum, 0);
}
```

```ruby
require "carray"
require "mysum"

CArray.int32([1, 2, 3, 4]).mysum   # => 10.0
CArray.float64([[1, 2], [3, 4]])[nil, 0].mysum   # => 4.0  (a view)
```

Everything else in this guide elaborates on these moves: getting the
struct (§2, §7), the attach lifecycle for views (§4), masks (§5),
producing arrays back to Ruby (§8), and coercion at the boundary (§9).

---

## 2. The `CArray` struct

CArray exposes a single C struct `CArray` for the base array. Every
kind of CArray — entity arrays, foreign-buffer wraps, scalars, and all
view kinds — shares the same header, so a `CArray *` is a valid handle
regardless of the underlying object. This chapter covers the base
struct, the three entity kinds, and how to obtain a struct pointer
from a Ruby `VALUE`. The view kinds and the dispatch mechanism that
distinguishes them live in §3.

### 2.1 Fields of the base struct

The struct is declared in `ext/carray.h`:

```c
typedef struct _CArray CArray;

struct _CArray {
  int16_t    obj_type;   /* CA_OBJ_ARRAY, CA_OBJ_REFER, ... */
  int8_t     data_type;  /* CA_INT32, CA_FLOAT64, CA_OBJECT, ... */
  int8_t     ndim;       /* number of dimensions (0 .. CA_RANK_MAX) */
  int32_t    flags;      /* CA_FLAG_SCALAR, CA_FLAG_READ_ONLY, ... */
  ca_size_t  bytes;      /* element size in bytes */
  ca_size_t  elements;   /* total number of elements */
  ca_size_t *dim;        /* shape, length ndim */
  char      *ptr;        /* data pointer, NULL when not attached */
  CArray    *mask;       /* optional mask array, NULL when absent */
};
```

`ca_size_t` is `int64_t` on 64-bit platforms and `int32_t` on 32-bit
platforms. `CA_RANK_MAX` is 16. `ptr` is `char *` rather than a typed
pointer because the element type is carried in `data_type`; cast it to
the appropriate concrete type before dereferencing.

The fields that always make sense on any CArray (entity or view) are
`obj_type`, `data_type`, `ndim`, `dim`, `bytes`, `elements`, and
`mask`. `ptr` is meaningful when the array is *attached* (see §4);
for an entity, that is always; for a view, only between `ca_attach` /
`ca_detach`.

### 2.2 Entities: `CArray`, `CScalar`, `CAWrap`

An *entity* is a CArray that owns its element buffer (or is responsible
for tracking foreign buffer it does not free). Three concrete entity
kinds exist:

- **`CArray`** with `obj_type == CA_OBJ_ARRAY` — the regular case.
  `ptr` owns a buffer allocated by `xmalloc`, freed by `ca_free`.
  `ndim` is 1 or more.
- **`CScalar`** (`CA_OBJ_SCALAR`) — a zero-dimensional array. Layout
  is identical to `CArray` plus a single trailing `ca_size_t _dim`
  cell that `dim` points to. `xfree(ca->dim)` is therefore incorrect
  for a `CScalar`; the `dim` storage is part of the struct.
- **`CAWrap`** (`CA_OBJ_ARRAY_WRAP`) — `typedef CArray CAWrap`. Same
  layout as `CArray`, but `ptr` references memory owned by some other
  party (a foreign library, a Ruby string, an `mmap`-ed region).
  CArray will not free that memory. The wrapped buffer's lifetime is
  the caller's responsibility.

All three present the same `CArray *` interface to the rest of the
API; you only distinguish them when you have a reason to (free
strategy, foreign-buffer lifetime concerns).

A fourth kind is open to extensions: a **source**, an array that produces
its elements itself rather than deriving them from another CArray — an
image library's pixel cache, a file-backed variable, a formula. Sources
subclass `CASource` and are written entirely in the extension; see §3.5.

### 2.3 Getting the struct from a Ruby `VALUE`

Every CArray class is registered as TypedData. From an extension, use
the `GetCArray` shorthand declared in `ext/carray.h`:

```c
CArray *ca;
GetCArray(rb_obj, ca);
```

which expands to `TypedData_Get_Struct(rb_obj, CArray, &carray_data_type,
ca)`. `&carray_data_type` is the base type tag; it accepts any concrete
subclass because every variant's TypedData is registered with
`carray_data_type` as its parent. If you need the concrete subtype,
use the corresponding tag directly (`&castride_data_type`,
`&caview_data_type`, etc.) — declarations live in `ext/carray.h`.

`GetCArray` performs the same `Check_TypedStruct` that
`TypedData_Get_Struct` does, so a non-CArray VALUE raises `TypeError`.
If you want a Ruby-level class check first (for a more specific error
message), call `rb_obj_is_kind_of(obj, rb_cCArray)` before extracting.

### 2.4 Reading shape and element data

Once you have a `CArray *`:

```c
CArray *ca;
GetCArray(rb_obj, ca);

int       n = ca->ndim;
ca_size_t total = ca->elements;
ca_size_t per_element = ca->bytes;
ca_size_t *shape = ca->dim;     /* length n */
```

To read elements, ensure the array is attached (entity arrays always
are; views need `ca_attach` first — see §4), then cast `ca->ptr` to the
concrete element type:

```c
double *data = (double *)ca->ptr;
for (ca_size_t i = 0; i < ca->elements; i++) {
  /* ... use data[i] ... */
}
```

The element type is carried in `ca->data_type`; before casting,
either know the type from context (you required `CA_FLOAT64` at the
boundary — §9), or dispatch on `ca->data_type` explicitly.

---

## 3. Class hierarchy and `obj_type` dispatch

CArray's class hierarchy has a deliberate split: every entity uses the
plain `CArray` struct, while every view extends a common `CAView`
header with view-specific tails. Dispatch between kinds is done at
runtime through a function table indexed by `obj_type`.

### 3.1 `CAView` and the view families

`CAView` is the common header for all view kinds:

```c
typedef struct {
  /* ... CArray header (obj_type ... mask) ... */
  CArray   *parent;     /* the view's source */
  uint32_t  attach;     /* attach reference count */
  uint8_t   nosync;     /* if non-zero, sync is suppressed */
} CAView;
```

Concrete view structs extend `CAView` with whatever per-kind state
they need (`strides` and `base_offset` for `CAStride`,
`start`/`step`/`count` for `CABlock`, and so on). The first fields of
every view struct are byte-identical to `CAView`, which is
byte-identical to `CArray`, so upcasting by pointer cast is always
safe.

The full hierarchy:

```
CArray            (entity)
├── CScalar
├── CAWrap
├── CASource     (extension-defined sources; §3.5)
├── CAView    (view base)
│   ├── CAStride  ── CARefer, CABlock, CATranspose, CAFarray,
│   │                CARepeat, CAField, CAUnboundRepeat
│   ├── CAWindow  ── CAShift
│   ├── CASelectAxis, CAGrid                 (per-axis scatter family)
│   ├── CASelect, CAMapping                  (flat-index family)
│   ├── CAFake, CAByteSwap, CABitarray, CABitfield  (overlays)
│   └── CAReduce                             (reduction view)
└── CAObject     (Ruby-callback bridge; may be entity or view)
```

The `CAStride` family in particular shares a common base offset +
strides representation, with concrete subclasses adding per-kind tails
or being pure `typedef`s. `CAWindow` is the substrate for bound-aware
views, with `CAShift` as a `typedef`. Most of these distinctions are
internal; for an extension consuming CArrays through the public API,
the public predicates in §3.4 are typically enough.

Mask arrays are themselves `CArray` (or a per-kind mask subclass such
as `CABlockMask`). When `ca->mask` is non-NULL, its `data_type` is
`CA_BOOLEAN` and its shape matches `ca`'s. See §5 for the mask
mechanism.

### 3.2 The function table (`ca_func[]`)

The `obj_type` field selects a per-kind function table. Five parallel
arrays, all sized `CA_OBJ_TYPE_MAX` (= 256), are indexed by `obj_type`:

```c
extern VALUE                       ca_class[CA_OBJ_TYPE_MAX];
extern const rb_data_type_t       *ca_typeddata[CA_OBJ_TYPE_MAX];
extern VALUE                       ca_mask_class[CA_OBJ_TYPE_MAX];
extern const rb_data_type_t       *ca_mask_typeddata[CA_OBJ_TYPE_MAX];
extern ca_operation_function_t     ca_func[CA_OBJ_TYPE_MAX];
```

The function table itself is:

```c
typedef struct {
  int32_t obj_type;
  int32_t entity_type;        /* CA_REAL_ARRAY or CA_VIRTUAL_ARRAY */
  void   (*free_object)  (void *ap);
  void * (*clone)        (void *ap);
  char * (*ptr_at_addr)  (void *ap, ca_size_t addr);
  char * (*ptr_at_index) (void *ap, ca_size_t *idx);
  void   (*fetch_addr)   (void *ap, ca_size_t addr, void *data);
  void   (*fetch_index)  (void *ap, ca_size_t *idx, void *data);
  void   (*store_addr)   (void *ap, ca_size_t addr, void *data);
  void   (*store_index)  (void *ap, ca_size_t *idx, void *data);
  void   (*allocate)     (void *ap);
  void   (*attach)       (void *ap);
  void   (*sync)         (void *ap);
  void   (*detach)       (void *ap);
  void   (*copy_data)    (void *ap, void *data);
  void   (*sync_data)    (void *ap, void *data);
  void   (*fill_data)    (void *ap, void *data);
  void   (*create_mask)  (void *ap);
} ca_operation_function_t;
```

When a generic helper such as `ca_attach(ca)` needs to do something
kind-specific, it dispatches through `ca_func[ca->obj_type]`. As a
consumer you do not normally call function-table slots directly —
`ca_attach`, `ca_sync`, `ca_detach`, `ca_copy_data`, `ca_fill_data`
and friends are the public wrappers.

### 3.3 `ca_install_obj_type` (defining a new kind)

A small number of `obj_type` values (`CA_OBJ_ARRAY`, `CA_OBJ_SCALAR`,
`CA_OBJ_ARRAY_WRAP`, `CA_OBJ_REFER`, `CA_OBJ_BLOCK`, `CA_OBJ_SELECT`,
`CA_OBJ_OBJECT`, `CA_OBJ_REPEAT`, `CA_OBJ_UNBOUND_REPEAT`) are fixed
compile-time constants from an enum in `ext/carray.h`. The remaining
kinds (`CAStride`, `CATranspose`, `CAFarray`, `CAGrid`, `CAWindow`,
`CAShift`, `CAByteSwap`, …) are assigned numbers at load time by
`ca_install_obj_type`:

```c
int ca_install_obj_type (VALUE klass,
                         const rb_data_type_t *typeddata,
                         VALUE mask_klass,
                         const rb_data_type_t *mask_typeddata,
                         ca_operation_function_t func);
```

The returned `int` is the new `obj_type` tag, which is typically
stored in an `int8_t` variable (e.g. `CA_OBJ_STRIDE`). Extensions that
only consume existing kinds never call this; defining a new kind is
relatively unusual and requires also providing the full
`ca_operation_function_t` table (see `ext/ca_obj_*.c` for templates).

### 3.4 Identifying what you got (predicates)

The following predicates are declared in `ext/carray.h` and cover
most of what an extension needs:

```c
/* Where the array sits in the hierarchy */
#define ca_is_entity(ca)   (ca_func[(ca)->obj_type].entity_type == CA_REAL_ARRAY)
int  ca_is_virtual    (void *ap);   /* derived view */
int  ca_is_scalar     (void *ap);   /* CScalar (ndim 0) */

/* Attachment / writability state */
#define ca_is_attached(ca) ((ca)->ptr != NULL)
#define ca_is_empty(ca)    ((ca)->elements == 0)
int  ca_is_readonly   (void *ap);

/* obj_type / flag fast-paths */
#define ca_is_caobject(ca) ((ca)->obj_type == CA_OBJ_OBJECT)
int  ca_is_value_array (void *ap);
int  ca_is_mask_array  (void *ap);

/* data_type family */
int  ca_is_fixlen_type  (void *ap);
int  ca_is_boolean_type (void *ap);
int  ca_is_numeric_type (void *ap);
int  ca_is_integer_type (void *ap);
int  ca_is_unsigned_type(void *ap);
int  ca_is_float_type   (void *ap);
int  ca_is_complex_type (void *ap);
int  ca_is_object_type  (void *ap);
```

`ca_is_entity` distinguishes "owns its data" from "refers to a parent".
`ca_is_attached` distinguishes "ptr currently points at usable data"
from "ptr is NULL pending attach"; these are different questions —
entity arrays are always attached, views are attached only between an
`ca_attach` / `ca_detach` pair (see §4).

For data_type checking, prefer the family predicates above over comparing
`data_type` to specific enum values, except when the operation truly
depends on the exact width (e.g. picking between an `int32_t *` and
an `int64_t *` cast).

What you almost never need to do at this layer is branch on a specific
view subtype (CABlock vs. CAStride vs. CASelect). The public APIs in
the rest of this guide are designed so that the same code path works
across every view kind — see §9 (`ca_wrap_*`) and Part III
(kernel_iterator) for the two main mechanisms that make this possible.

### 3.5 `CASource` — a source class of your own

An entity owns its buffer, a view derives from another CArray, and a
**source** does neither: it produces its elements itself. An image
library's pixel cache, a `cv::Mat`, a file-backed variable, an
arithmetic progression — none of them has a parent CArray, and none of
them is a buffer CArray allocated. `CASource` is where such a class
lives.

`CASource` is a marker and nothing else: a class under `CArray`, an
allocator that raises, and a TypedData chain entry. It has no operation
table, no dispatch and no shared state, and it never grows any — the
core does not ask "is this a CASource" anywhere. Your subclass registers
its own `obj_type` with `ca_install_obj_type` (§3.3) and supplies the
whole `ca_operation_function_t` itself. Reading `ca_obj_select.c` or
`ca_obj_object.c` for the shape of a complete table is the way in;
`spec/spec_ai/ext_source_smoke/source_smoke.c` is a compact worked
example of a source over a foreign buffer.

**Pick your `entity_type` first** — it decides everything else:

- **`CA_REAL_ARRAY`** — the buffer is already addressable (an image's
  pixel cache, a `cv::Mat`). Use the plain `CArray` struct prefix;
  `ca_is_entity()` is true, so the core treats the array exactly like a
  `CAWrap` and never looks for a parent.
- **`CA_VIEW_ARRAY`** — elements have to be produced on demand (a
  formula, a lazily-read file). Use the `CAView` prefix with `parent`
  left `NULL`; the engine will treat the array as a view, so paths that
  walk parents need to know to stop. That regime is not yet wired up in
  the core — a source of this shape needs core work first.

**Three things bite in practice:**

1. **`ca->ptr` is the bypass, so keep the array cold at rest** if the
   backend can move or re-shape the buffer underneath you. While `ptr`
   is non-NULL the core's dispatchers move bytes straight through it
   (`ca_xfer_stride_dispatch` / `ca_xfer_addrs_dispatch` take a memcpy
   branch on `ca->ptr != NULL`) and your slots are never reached; with
   `ptr` NULL every path lands in a slot, where re-resolving the address
   also re-validates the backend. Publishing `ptr` permanently therefore
   switches that check off for element access and region transfer, with
   no symptom.

   Cold at rest needs a hold count of your own, because entities carry
   no attach reference count (only `CAView` does): `attach` **and**
   `allocate` publish `ptr` and take a hold, `detach` releases one and
   clears `ptr` when the last goes. `allocate` has to be in that count —
   it must publish (the core writes through `ca->ptr` after
   `ca_allocate`), and the `detach` that follows it arrives without a
   matching `attach`. Without the count, an inner attach/detach pair
   clears `ptr` under an outer holder and its sync fails; with a count
   that ignores `allocate`, the array silently stays warm and the check
   stops running.

   Resolve into a **local** variable in the data slots. Assigning
   `ca->ptr` there leaks a published pointer into the next operation,
   which then bypasses the guard and returns a correct-looking answer.

   Cold at rest also means writes reach you through the slots and not
   through attach, so whatever tells your backend a write happened
   belongs in the slots too — see §4.3.
2. **Define an allocator and `initialize_copy`.** `CASource` seals its
   allocator so it cannot be instantiated; a subclass that does not
   define its own leaves `dup` / `clone` raising `TypeError`.
   `rb_define_alloc_func` + `TypedData_Make_Struct` is all it takes.
3. **`free_object` must not free a buffer you do not own**, the same
   rule `CAWrap` follows. Free the struct and whatever tail you
   allocated, and keep the foreign object alive for as long as the array
   is — an ivar on the wrapper object, or a `dmark` over a `VALUE` in
   your tail.

MemoryView export is not available to an extension-defined `obj_type`:
the strategy table in `carray_memory_view.c` is keyed by class name and
has no registration hook, so `CArray.memory_view_available?` reports
`false` for your class and export is declined. Hand out `src.copy` when
a consumer needs a MemoryView.

---

## 4. Views: accessing a derived array's data from C

You already know that `a[2..10, nil]`, `a[a < 10]`, `a.reshape(8, 2)`
return views of another array:

```ruby
a.entity?                  # => true
a[2..10, nil].virtual?     # => true
a[a < 10].virtual?         # => true
a.reshape(8, 2).virtual?   # => true
```

CArray is designed so you can use an array without having to think
about whether it's a view. You just write the expression and it works.

Under the hood, every read or write on a view goes through a small
attach / sync / detach lifecycle that produces a plain buffer for the
caller. Ruby-side code almost never drives this lifecycle directly;
C extension code does. The rest of this chapter describes the C
entry points and the contract they form.

### 4.1 What a view actually is, in C

A view is a CArray that doesn't own its data. It carries a pointer
to its `parent` (the array it derives from) and just enough state to
describe its own shape and data_type — the actual element data lives in
whatever entity sits at the root of the parent chain.

Concretely, every view extends `CAView`:

```c
typedef struct {
  int16_t    obj_type;
  int8_t     data_type;
  int8_t     ndim;
  int32_t    flags;
  ca_size_t  bytes;
  ca_size_t  elements;
  ca_size_t *dim;
  char      *ptr;       /* NULL by default; set by ca_attach */
  CArray    *mask;
  /* --- CAView additions --- */
  CArray    *parent;    /* the view's source */
  uint32_t   attach;    /* attach reference count */
  uint8_t    nosync;    /* sync suppressed when non-zero */
} CAView;
```

The view's `ndim`, `dim`, `bytes`, `elements`, `data_type` describe
the view (the post-block shape, the post-fancy-index count, …), and
are fixed at construction. The view holds a pointer to its `parent`
and an attach reference count. The view does not own data; the
bytes live in the entity at the root of the parent chain.

**Crucially, `ca->ptr` is normally `NULL` for a view.** Entity
arrays always have `ca->ptr` pointing at their owned buffer, but a
view is constructed without one. `ca->ptr` only becomes non-NULL
between matching `ca_attach` and `ca_detach` calls — outside of that
window, the view has shape and data_type but no readable bytes.

`ca_is_attached(ca)` is the predicate for this state — true for any
entity, true for a view only while it is attached:

```c
if (ca_is_attached(ca)) {
  /* ca->ptr is valid here, regardless of entity or view */
  const double *p = (const double *)ca->ptr;
  /* ... */
}
```

So from C, when you receive a CArray that happens to be a view,
`ca->ptr` is not usable yet. The C operations that change that are
described next.

### 4.2 Making the data accessible: `ca_attach` / `ca_detach`

So what if you receive a `ca` for which `ca_is_attached(ca)` is
false — a view that hasn't been attached yet? You need to materialise
`ca->ptr` before you can read or write through it. That's what
`ca_attach(ca)` does:

1. allocates `xmalloc(ca->elements * ca->bytes)`,
2. gathers the view's logical elements into it in row-major order,
3. sets `ca->ptr` to point at that buffer.

Between attach and detach the caller treats `ca->ptr` like any
entity's `ptr` — contiguous, row-major, `ca->elements * ca->bytes`
long, indexable as `(T *)ca->ptr` for the element type `T` matching
`ca->data_type`.

`ca_detach(ca)` reverses the process:

1. `xfree`s the buffer `ca->ptr` points at,
2. resets `ca->ptr` to `NULL`.

Every `ca_attach` must be paired with exactly one `ca_detach`.

Both calls are safe to invoke unconditionally: on an entity each is
a no-op, and on an already-attached view `ca_attach` leaves
`ca->ptr` as is. So you can write:

```c
ca_attach(ca);             /* ensures ca->ptr is valid */
/* ... use ca->ptr ... */
ca_detach(ca);             /* releases the access */
```

without first checking `ca_is_attached`.

### 4.3 Writing back: `ca_sync`

So what happens to your writes? If you wrote into `ca->ptr` while
the view was attached, those writes don't necessarily reach the
parent on their own. `ca_sync(ca)` is the call that makes them
visible to the parent:

1. takes the data in `ca->ptr`,
2. scatters it back into the parent according to the view's gather
   pattern.

Call it between `ca_attach` and `ca_detach`, after you finish
writing:

```c
ca_attach(v);
double *p = (double *)v->ptr;
for (ca_size_t i = 0; i < v->elements; i++) p[i] = ...;
ca_sync(v);
ca_detach(v);
```

If you only read, you don't need to sync. If you wrote, sync before
detach — otherwise the changes can be silently dropped at detach.

Like `ca_attach`, `ca_sync` is safe to invoke on an entity (no-op).
It raises if called on a view that is not currently attached, or on
a view that is read-only (§4.6).

#### If you implement slots, the slot is your commit point

`ca_sync` commits the route described above: someone attached, wrote
through `ca->ptr`, and the write has to be pushed back. It is not the
only route. If your obj_type fills in the data slots — `xfer_index`,
`xfer_addrs`, `xfer_stride`, `fill_addrs`, `fill_stride` — then a
caller writing part of your array reaches those slots directly, with
no attach and no sync anywhere in the call. That is deliberate: it is
what keeps `a[i, j] = v` and `a[1..2, nil] = v` proportional to what
was asked for rather than to the size of the array.

The consequence for you is that **anything your backend needs told
about a write has to be told from the slot**. If there is a cache to
flush, a handle to mark dirty, a library call that makes the change
real, doing it in `sync` alone means it happens for the attach route
and silently not for the others. Put it where the write is.

`carray-rmagick` is the worked example: its pixel cache notifies
ImageMagick from each data slot, because a partial fill through the
region path never attaches the cache and so never reaches its `sync`.

### 4.4 Attaching the parent is not automatic

**Do not assume that `view->parent` is attached just because you
attached `view`.** `ca_attach(view)` makes only `view->ptr` valid —
`view->parent->ptr` may well still be `NULL` after the call. The
same goes for any deeper ancestor. Each level of the parent chain
that you intend to read through must be attached explicitly.

This matters whenever you want to touch `view->parent->ptr` (or
deeper ancestors) directly — for example, to combine the view's
materialised data with values read straight from the parent's
buffer. In that case, attach both, parent first:

```c
ca_attach(parent);
ca_attach(child);
/* both parent->ptr and child->ptr are valid here */
ca_detach(child);
ca_detach(parent);
```

Detach in the reverse order — child first, parent last — so that
the child's bytes stay reachable until the child is done.

### 4.5 Canonical patterns

Most C-side use of a view follows the same skeleton: attach, work
with `ca->ptr`, sync if you wrote, detach. The variations below
cover the cases you hit in practice.

Read a view (no mutation):

```c
ca_attach(v);
const double *p = (const double *)v->ptr;
for (ca_size_t i = 0; i < v->elements; i++) {
  /* read p[i] */
}
ca_detach(v);
```

Write through a view:

```c
ca_attach(v);
double *p = (double *)v->ptr;
for (ca_size_t i = 0; i < v->elements; i++) p[i] = ...;
ca_sync(v);     /* required to propagate writes back to the parent */
ca_detach(v);
```

Several views together (varargs helpers in `ext/carray.h`):

```c
void ca_attach_n (int n, ...);
void ca_sync_n   (int n, ...);
void ca_detach_n (int n, ...);

ca_attach_n(3, a, b, c);
/* ... use a->ptr, b->ptr, c->ptr ... */
ca_sync_n(3, a, b, c);
ca_detach_n(3, a, b, c);
```

Exception safety: if anything between attach and detach can raise (a
Ruby callback, an allocation, `rb_funcall`), wrap the section in
`rb_ensure` / `rb_protect` so detach runs on the unwind path.

### 4.6 Read-only views and `nosync`

Some views can't be written through (reduction results, frozen
arrays, `value_array` variants). In C the predicate is
`ca_is_readonly(ca)`. Calling `ca_sync` on a read-only array raises;
`ca_attach` on it is fine (you can still read).

The `nosync` field on `CAView` is a per-view opt-out: even if the
caller calls `ca_sync`, no sync-back happens. CArray uses it
internally for views set up specifically as read-target scratch
buffers. As a consumer you do not normally set it; respect it if you
encounter it.

At the API boundary, when you need write access, validate
`!ca_is_readonly(ca)` early and raise with a clear message rather
than letting `ca_sync` raise mid-operation.

---

## 5. Masks

CArray has a first-class notion of "missing" or "skipped" elements,
expressed as a boolean side-array — the *mask*. A masked element keeps
its byte slot in the data buffer (its value is just whatever was
there), but the mask records that the slot should not be read as a
data value. Every CArray kind — entities, views, scalars — carries
the same mask machinery, so as an extension author you handle it in
one place.

### 5.1 What a mask actually is, in C

The mask is just another `CArray *`, hung off the main array through
`ca->mask`:

```c
struct _CArray {
  /* ... */
  CArray *mask;   /* NULL when no mask is present */
};
```

When non-NULL, `ca->mask` has `data_type == CA_BOOLEAN` (one byte per
element, the same as `boolean8_t`), and its shape matches `ca`:
`ca->mask->ndim == ca->ndim` and `ca->mask->dim[k] == ca->dim[k]` for
every `k`. The values are byte booleans: `0` means "this element is
valid", any non-zero value (canonically `1`) means "this element is
masked / missing".

```c
if (ca_has_mask(ca)) {
  ca_attach(ca);                                  /* materialise data */
  /* ca_mask_ptr() returns a boolean8_t * into the mask buffer,
   * attaching the mask itself if needed.        */
  boolean8_t *m = ca_mask_ptr(ca);
  for (ca_size_t i = 0; i < ca->elements; i++) {
    if (m[i]) continue;                           /* masked: skip */
    /* ... use ((T *)ca->ptr)[i] ... */
  }
  ca_detach(ca);
}
```

The Ruby-level sentinel `CA_UNDEF` (returned when a masked cell is
read through `ca[i]` etc.) does **not** appear at the C level. From
C, you ask `ca->mask` directly; the value sitting in `ca->ptr` for a
masked cell is undefined and must not be inspected.

### 5.2 The mask is created on demand

A freshly built CArray starts with `ca->mask == NULL` — no mask array
exists at all. CArray allocates a mask only when something is about
to mark an element as masked. The two predicates that look similar
but mean different things:

| Predicate              | Asks                                            |
|------------------------|-------------------------------------------------|
| `ca_has_mask(ca)`      | Does a mask **array** exist? (`ca->mask != NULL`) |
| `ca_is_any_masked(ca)` | Is at least one mask byte non-zero?             |

`ca_has_mask` being false implies no element is masked. `ca_has_mask`
being true says nothing about how many — an all-zero mask is common
because operations that propagate masks unconditionally allocate one.

Lazy creation is what you call before you need to write masked
flags into a fresh output:

```c
void ca_create_mask (void *ap);   /* idempotent: no-op if mask exists */
```

After `ca_create_mask`, `ca->mask` is allocated and all bytes are
zero. `ca_clear_mask(ca)` is the reverse: it removes the mask array
(returning the CArray to the `ca->mask == NULL` state) when you know
no cell is masked.

The design point is straightforward: arrays that never touch masks
pay nothing — no extra allocation, no extra memcpy in attach/sync.
The mask only appears when it has to.

### 5.3 The mask travels with the data

Once a mask exists, you do not manage its lifecycle separately. The
attach/sync/detach calls on the main array carry the mask along:

- `ca_attach(ca)` attaches the mask too (when present), so
  `ca_mask_ptr(ca)` returns a contiguous, row-major `boolean8_t *`
  buffer matching the layout of `ca->ptr`.
- `ca_sync(ca)` writes the mask back through the view chain alongside
  the data.
- `ca_detach(ca)` releases both.

`ca_mask_ptr(ca)` is the canonical accessor — prefer it over
`(boolean8_t *)ca->mask->ptr`, because it handles the attach state
of the mask uniformly across kinds.

### 5.4 Views inherit their parent's mask

A derived view (CABlock, CAStride, CASelect, CAFake, …) gets a mask
view of its parent's mask automatically. If `a.mask` is non-NULL,
then `a[2..5, nil].mask` is non-NULL too, and the slice's mask gather
follows the same gather pattern as the data.

Operations that consume CArrays (binary operators, reductions,
`ca_attach`-and-compute kernels) propagate masks from inputs to
output, typically by union (a result cell is masked if any
contributing input cell was). The propagation usually happens
automatically when you use the bundled engines; if you are writing a
brand-new kernel from scratch (§5.6), you do the propagation
explicitly.

Net effect for an extension consuming a CArray: receiving an array
that already has a mask is the normal case. Code that does not handle
masks must at least notice (`ca_has_mask(ca)`) and decide what to do
— silently ignoring it produces wrong answers on the masked cells.

### 5.5 Respecting the mask (simple model)

The straightforward pattern for a read-only kernel that needs to
honour masks:

```c
ca_attach(ca);

if (!ca_has_mask(ca)) {
  /* Fast path: no mask, plain dense loop. */
  const double *p = (const double *)ca->ptr;
  for (ca_size_t i = 0; i < ca->elements; i++) {
    /* ... use p[i] ... */
  }
} else {
  const double     *p = (const double *)ca->ptr;
  const boolean8_t *m = ca_mask_ptr(ca);
  for (ca_size_t i = 0; i < ca->elements; i++) {
    if (m[i]) continue;
    /* ... use p[i] ... */
  }
}

ca_detach(ca);
```

The pair of `ca_count_masked(ca)` and `ca_count_not_masked(ca)` give
the totals without iterating yourself — useful when allocating
output buffers sized to the non-masked count (e.g. `compress`-style
operations).

If you would rather not branch at all, `ca_unmask(ca, &fill)` and
`ca_unmasked_copy(ca, &fill)` substitute a caller-provided fill value
into masked cells. The first mutates `ca` in place (clearing its
mask); the second returns a fresh entity. Both expect `fill` to point
at a value of the correct data_type.

For kernels driven by `kernel_iterator`, the mask handling is wired
into the iterator (see §12 and `docs/HOW_TO_WRITE_KERNEL.md`); the
inline patterns above apply when you are writing a one-off kernel
that does not need the universal dispatch surface.

### 5.6 Producing a masked result

When your operation can produce missing values (division, log of
negative, an unfilled cell in a scatter, an empty reduction group),
mark them on the output:

```c
ca_create_mask(out);                       /* lazy-allocate */
boolean8_t *om = ca_mask_ptr(out);

for (ca_size_t i = 0; i < out->elements; i++) {
  if (/* result at i is missing */) {
    om[i] = 1;
  } else {
    ((double *)out->ptr)[i] = /* computed value */;
  }
}
```

When the output's mask is the union of several inputs' masks
(typical for element-wise operations), CArray ships two helpers:

```c
void ca_copy_mask_overlay (void *out, ca_size_t elements,
                           int n, /* CArray *src1, *src2, ... */);
void ca_copy_mask_overlay_n (void *out, ca_size_t elements,
                             int n, CArray **slist);
```

These OR-combine each input's mask into the output's mask, allocating
the output mask if any input has one and leaving it untouched if none
do. Use the `_n` variant when you have an array of sources, the
varargs variant for a fixed small set:

```c
ca_copy_mask_overlay(out, out->elements, 2, a, b);
/* out->mask now has a 1 wherever a or b had a 1. */
```

The companion `ca_copy_mask_overwrite` / `_overwrite_n` replace the
output mask rather than OR-ing, useful when the output is a fresh
buffer whose mask should be exactly the input's union without regard
for prior content.

After producing the output (data + mask), the usual `ca_sync(out)` /
`ca_detach(out)` propagates both through any view chain back to the
underlying entity.

---

## 6. Memory and lifetime rules

CArray uses Ruby's allocator (`xmalloc` / `xfree`) for every heap
allocation that participates in a CArray's lifetime. An extension
that allocates, borrows, or returns CArray-backed memory should
follow the same rules.

### 6.1 `xmalloc` / `ALLOC` / `xfree`

All CArray-side heap allocations go through Ruby's allocator.

| Allocate | Free |
|----------|------|
| `xmalloc(n)` | `xfree(p)` |
| `ALLOC(T)` / `ALLOC_N(T, n)` | `xfree(p)` |

Plain `malloc` / `calloc` / `realloc` / `free` from `<stdlib.h>` are
forbidden anywhere a CArray-owned buffer is involved. `xfree` on a
pointer returned by `malloc` (or vice versa) is undefined behaviour.

`ALLOC(T)` and `ALLOC_N(T, n)` are the typed sugar from `ruby.h` and
are preferred for fixed-type per-axis buffers (`ALLOC_N(ca_size_t,
ndim)`, etc.). `xmalloc` itself raises `NoMemoryError` (via
`rb_memerror`) on allocation failure, so no NULL-check is needed at
the call site.

Standalone scratch buffers inside a single C function — that do not
escape, are not handed to CArray, and are freed before return — may
use plain `malloc` / `free` if you prefer; nothing forces `xmalloc`
there.

> Historical note: earlier CArray versions provided an internal helper
> `malloc_with_check(n)` that wrapped `xmalloc` with an additional NULL
> check. Since Ruby 3.0+ `xmalloc` already raises `rb_memerror()` on
> OOM, the wrapper was functionally indistinguishable from `xmalloc`.
> It was removed in carray-3.0; call `xmalloc` directly.

### 6.2 `ca_free` and `ca_free_nop`

C extensions routinely build CArrays as temporaries — wrapping a
foreign buffer with `ca_wrap_new`, materialising a small entity with
`carray_new`, taking a view with `ca_stride_new`, and so on — without
ever exposing them to Ruby. The struct returned by these C-level
constructors owns side allocations (`dim`, `strides`, possibly `ptr`
and a mask), and must be released through CArray's own dispatcher:

```c
CArray *ca = carray_new(CA_FLOAT64, 1, &n, sizeof(double), NULL);
/* ... use ca, including ca->ptr ... */
ca_free(ca);
```

`ca_free` forwards to `ca_func[ca->obj_type].free_object`, which knows
which fields of that obj_type need `xfree` (`dim`, `strides`, tail
buffers) and which need recursive cleanup (`parent` for views, `mask`
for masked arrays). Manually `xfree`-ing the fields you can see —
`ca->ptr`, `ca->dim`, etc. — is wrong: subclasses have their own tail
allocations, `CScalar`'s `dim` is part of the struct, and views must
unwind their reference to `parent`. Always go through `ca_free`.

`ca_free_nop` is the no-op counterpart, used for objects whose lifetime
is owned by someone else. The most important case is the mask array
hung off a parent CArray: the parent's `ca_free` walks into the mask
and frees it, so the mask's own TypedData entry must use `ca_free_nop`
to avoid a double free. When you register a new TypedData entry for a
CArray subclass or its mask, pick the right one — `ca_free` for the
array itself, `ca_free_nop` for masks that share a parent's lifetime.
`ext/ca_obj_*.c` are the reference patterns.

### 6.3 Allocation cookbook: `ca_array_alloc` and the `_pool` framework

CArray 3.0 introduced a small framework that bundles every
variable-size buffer attached to a CArray subclass (its `dim`,
`strides`, and any tail arrays like CABlock's `start`/`step`/`count`/
`size0`) into a single contiguous `_pool` buffer.  This section is the
per-author recipe.

**When you add a new `obj_type` to CArray (= a new C subclass)**,
prefer the framework over the legacy `ALLOC(MyClass) + ALLOC_N(...,
ndim) + ALLOC_N(...)` pattern.  The canonical reference is
`ext/ca_obj_block.c` — copy from there, *not* from one of the
not-yet-migrated subclasses (anything still calling
`ALLOC(CAStride)` or `ALLOC(CARefer)` in its `*_new` function is on
the legacy path).

The framework has three pieces:

1. **The `_pool` field.**  Already present in the `CArray` header (and
   in every subclass struct for prefix-compatibility).  Do not read,
   write, or `xfree` it from author code — it is owned by the
   framework.  All your subclass's variable-size buffers (`dim`,
   `strides`, any tail) are sub-regions of this single allocation.
2. **Two metadata callbacks**, registered on the class's
   `ca_operation_function_t`:
   - `pool_bytes(ndim)` returns the total bytes the class needs for
     its variable-size region.  Typically
     `N * max(ndim, 1) * sizeof(ca_size_t)` for some small `N`.
   - `pool_init(self, ndim)` is run once after the pool buffer is
     allocated, and wires `self->dim`, `self->strides`, and any tail
     pointers into the pool's address range.
3. **Three framework primitives**, called from your `*_new` /
   `free_*` / `initialize_copy`:
   - `ca_array_alloc(obj_type, ndim)` — replaces `ALLOC(MyClass)`.
     Allocates the struct (using the registered `struct_size`),
     zero-fills it, then runs `ca_array_pool_alloc` internally.
   - `ca_array_pool_alloc(self, obj_type, ndim)` — used from
     `initialize_copy`, where `TypedData_Make_Struct` has already
     allocated the struct.  It only allocates the pool buffer and
     runs `pool_init`.
   - `ca_array_free(self)` — one `xfree` for the pool, one for the
     struct.  Called from your `free_*` after recursively freeing
     `ca->mask` (and any other ancestor pointers) and after gating on
     `ca->_pool != NULL`; see step 4 below.

#### Step-by-step

In your `ext/ca_obj_myclass.c`:

```c
/* (1) Pool metadata.  N depends on how many ndim-sized arrays your
   subclass owns.  CAStride owns 2 (dim + strides); CABlock owns 6. */
static size_t
ca_myclass_pool_bytes (int8_t ndim)
{
  ca_size_t n = (ndim > 0) ? ndim : 1;
  return N * (size_t) n * sizeof(ca_size_t);
}

static void
ca_myclass_pool_init (void *ap, int8_t ndim)
{
  CAMyClass *ca   = (CAMyClass *) ap;
  ca_size_t  n    = (ndim > 0) ? ndim : 1;
  ca_size_t *base = (ca_size_t *) ca->_pool;
  ca->dim     = base + 0 * n;
  ca->strides = base + 1 * n;
  /* ... wire each of your N ndim-sized fields into the pool ... */
}

/* (2) *_new switches to ca_array_alloc.  ca_*_setup may stay as-is;
   it should already gate any `ALLOC_N(ca_size_t, ndim)` on
   `ca->_pool == NULL` so the legacy path is also possible. */
CAMyClass *
ca_myclass_new (CArray *parent, int8_t ndim, /* ... */)
{
  CAMyClass *ca = (CAMyClass *) ca_array_alloc(CA_OBJ_MYCLASS, ndim);
  ca_myclass_setup(ca, parent, ndim, /* ... */);
  return ca;
}

/* (3) free_* dispatches on ca->_pool.  Free the mask (and any other
   recursive owners) first, then take one branch. */
static void
free_ca_myclass (void *ap)
{
  CAMyClass *ca = (CAMyClass *) ap;
  if (ca == NULL) return;
  ca_free(ca->mask);
  if (ca->_pool) {
    ca_array_free(ca);
  } else {
    /* legacy path, only relevant if you also want backwards-compat */
    xfree(ca->strides);
    xfree(ca->dim);
    xfree(ca);
  }
}

/* (4) initialize_copy: TypedData_Make_Struct has already allocated
   the struct via your class's allocator (rb_define_alloc_func).  Run
   ca_array_pool_alloc before your *_setup so the same pool branch
   activates inside setup. */
static VALUE
rb_ca_myclass_initialize_copy (VALUE self, VALUE other)
{
  CAMyClass *ca, *cs;
  TypedData_Get_Struct(self,  CAMyClass, &camyclass_data_type, ca);
  TypedData_Get_Struct(other, CAMyClass, &camyclass_data_type, cs);
  if (ca_func[CA_OBJ_MYCLASS].pool_init) {
    ca_array_pool_alloc(ca, CA_OBJ_MYCLASS, cs->ndim);
  }
  ca_myclass_setup(ca, cs->parent, cs->ndim, /* ... */);
  return self;
}

/* (5) Register the framework slots in Init_ca_obj_myclass after the
   op-table copy. */
void
Init_ca_obj_myclass (void)
{
  /* ... existing func-table setup ... */
  ca_myclass_func.struct_size = sizeof(CAMyClass);
  ca_myclass_func.pool_bytes  = ca_myclass_pool_bytes;
  ca_myclass_func.pool_init   = ca_myclass_pool_init;
  ca_func[CA_OBJ_MYCLASS]     = ca_myclass_func;
  /* ... */
}
```

#### Things to know

- **Order matters in setup.**  Any field that the framework's
  `create_mask` auto-dispatch reads (e.g. CABlock's
  `size0`/`start`/`step`/`count`/`offset`) must be written *before*
  `ca_stride_setup` is called.  The pool path doesn't change this —
  `ca_block_pool_init` only wires the pointers; the value copies (the
  `memcpy(ca->start, start, ndim * sizeof(ca_size_t));` line, etc.)
  still need to land before `ca_stride_setup`.
- **Pure-typedef subclasses get pool sweep for free.**  If your class
  shares the operation table of an already-pooled base (e.g. it's a
  `typedef CAStride MyClass;` that installs via
  `ca_install_obj_type(..., ca_stride_func)`), you only need to switch
  `*_new` to `ca_array_alloc` — the base class's `struct_size`,
  `pool_bytes`, and `pool_init` already flow through to your obj_type.
  CATranspose / CAFarray / CARepeat / CAField follow exactly this
  pattern.
- **Struct extensions (mask shadow tails like CARefer's `mask0`) live
  in the struct body, not the pool.**  They're plain pointers /
  ca_size_ts inside `sizeof(MyClass)` and are managed by your
  `*_setup` / `free_*`.  The pool is only for the ndim-scaled arrays.
  Override only `struct_size` in this case; the base class's
  `pool_bytes` / `pool_init` are still correct.
- **Subclasses that have not migrated keep working unchanged.**  Any
  obj_type whose `pool_bytes` / `pool_init` are still NULL leaves
  `ca->_pool == NULL` through the whole lifecycle, and your
  `ca_stride_setup` / `free_*` legacy branches run as before.  You can
  migrate one class at a time; there is no flag-day requirement.

---

# Part II — Ruby ↔ C interface

## 7. Extracting a CArray from a Ruby VALUE

### 7.1 `GetCArray` and direct extraction

Every CArray class is registered as TypedData with `carray_data_type`
at the root of the tag hierarchy. To get the `CArray *` out of a
`VALUE`, use the `GetCArray` shorthand from `ext/carray.h`:

```c
CArray *ca;
GetCArray(rb_obj, ca);
```

which expands to

```c
TypedData_Get_Struct(rb_obj, CArray, &carray_data_type, ca);
```

Because every concrete kind (entities, all view kinds, scalars, wraps)
registers its TypedData with `carray_data_type` as the parent tag,
`GetCArray` accepts *any* CArray and hands you a valid `CArray *`
regardless of `obj_type`. This is the normal extraction path — you
almost never need the concrete subtype tag.

`GetCArray` performs the `Check_TypedStruct` that
`TypedData_Get_Struct` always does, so passing a non-CArray `VALUE`
raises `TypeError` at that point with Ruby's generic "wrong argument
type" message. If you want a class-specific error message (or to
branch rather than raise), test first:

```c
if (!rb_obj_is_kind_of(obj, rb_cCArray)) {
  rb_raise(rb_eArgError, "expected a CArray, got %"PRIsVALUE,
           rb_obj_class(obj));
}
GetCArray(obj, ca);
```

`rb_cCArray` is the exported `VALUE` for the base `CArray` class; the
view classes (`rb_cCAView`, etc.) are also exported in `ext/carray.h`
if you ever need a narrower check, though branching on view class at
the boundary is rarely the right design (§3.4).

If you have accepted an argument that may be a CArray *or* something
convertible (a Ruby Array, a Numo array, a MemoryView producer), do
the conversion first (`CArray.from_memory_view`, `#to_ca`, etc. — §9,
§10) and extract from the resulting CArray.

### 7.2 Class / shape / data_type validation

Once you hold a `CArray *`, validate what the operation requires
before touching data. The fields to check are exactly the ones that
are meaningful on any kind (§2.1): `data_type`, `ndim`, `dim`,
`elements`.

```c
CArray *ca; GetCArray(self, ca);

if (ca->data_type != CA_FLOAT64) {
  rb_raise(rb_eArgError, "expected Float64, got %s",
           ca_type_name[ca->data_type]);
}
if (ca->ndim != 2) {
  rb_raise(rb_eArgError, "expected 2-D, got %d-D", ca->ndim);
}
if (ca->dim[0] != ca->dim[1]) {
  rb_raise(rb_eArgError, "expected a square matrix");
}
```

`ca_type_name[data_type]` gives the human-readable name for an error
message. Validate against the *family* predicates from §3.4
(`ca_is_float_type(ca)`, `ca_is_integer_type(ca)`) when the operation
works for a whole family, and against the exact enum value only when
the width genuinely matters (you are about to cast to `int32_t *`).

Two important boundary conventions:

- **Coerce, don't reject, when you can.** If your kernel needs
  Float64 but the user passed Int32, the CArray idiom is to *see* the
  input as Float64 via `rb_ca_wrap_readonly(self, INT2FIX(CA_FLOAT64))`
  (§9), not to raise a data_type error. Reserve hard `data_type`
  checks for cases where coercion is genuinely impossible or wrong.
- **Check shape after coercion.** Coercion (§9) never changes shape,
  so a shape check reads the same on the wrapped view as on the
  original; do it on whichever handle you are about to compute
  through.

### 7.3 The `ca_check_*` helpers

For the common validations, `ext/carray.h` provides raising helpers so
you do not hand-write the `if`/`rb_raise` each time:

```c
void ca_check_type            (void *ap, int8_t data_type);
void ca_check_ndim            (void *ap, int ndim);
void ca_check_shape           (void *ap, int ndim, ca_size_t *dim);
void ca_check_same_data_type  (void *ap1, void *ap2);
void ca_check_same_ndim       (void *ap1, void *ap2);
void ca_check_same_elements   (void *ap1, void *ap2);
void ca_check_same_shape      (void *ap1, void *ap2);
void ca_check_index           (void *ap, ca_size_t *idx);
```

`ca_check_data_type` is a macro alias for `ca_check_type` — use
whichever name reads better at the call site. Each raises on mismatch
and returns normally otherwise:

- `ca_check_type(ca, CA_FLOAT64)` raises `CADataTypeError` if
  `ca->data_type` is not `CA_FLOAT64`.
- `ca_check_ndim(ca, 2)` raises unless `ca` is 2-D (a scalar,
  `ndim == 0`, is exempt — it satisfies any expected `ndim`).
- `ca_check_shape(ca, ndim, dim)` raises unless the full shape matches.
- The `ca_check_same_*` pair compares two arrays — used when two
  operands must agree on data_type, rank, element count, or full shape.

These give short, uniform error messages. When you want a more
descriptive message (naming the argument, showing both shapes),
write the explicit check of §7.2 instead. The helpers exist for the
routine cases; they are not mandatory.

A typical two-operand entry:

```c
CArray *a, *b;
GetCArray(va, a);
GetCArray(vb, b);
ca_check_same_shape(a, b);      /* raises unless shapes agree */
/* proceed, knowing a and b are conformable */
```

---

## 8. Wrapping C memory as a Ruby-visible CArray

Producing a CArray from C comes in three flavours, distinguished by
who owns the element buffer: CArray allocates and owns it (an
*entity*, §8.1); a foreign party owns it and CArray merely references
it (a *wrap*, §8.2); or the data lives in another CArray and you are
returning a *view* of it (§8.3). §8.4 covers the lifetime rules that
tie them together.

### 8.1 Entities: `rb_carray_new`, `carray_new`

An entity owns its buffer. To create one, you choose whether you want
a Ruby-visible `VALUE` or a bare C `CArray *`:

```c
VALUE   rb_carray_new (int8_t data_type, int8_t ndim, ca_size_t *dim,
                       ca_size_t bytes, CArray *mask);
CArray *carray_new    (int8_t data_type, int8_t ndim, ca_size_t *dim,
                       ca_size_t bytes, CArray *mask);
```

- `data_type` — one of the `CA_*` codes (`CA_FLOAT64`, `CA_INT32`, …).
- `ndim`, `dim` — rank and shape; `dim` is an array of `ndim`
  `ca_size_t` values, copied into the new array (you keep ownership of
  the `dim` you pass).
- `bytes` — element width. Pass `0` for the fixed-width types and the
  correct width is filled in from `ca_sizeof[data_type]`; pass the
  actual width only for `CA_FIXLEN` (where the element size is not
  implied by the type).
- `mask` — an optional mask array to attach, or `NULL` for none (the
  usual case; you create the mask lazily later with `ca_create_mask`
  if needed — §5.2).

`rb_carray_new` returns a `VALUE` you can hand straight back to Ruby;
its buffer is managed by GC thereafter. `carray_new` returns a raw
`CArray *` for a C-internal temporary that never reaches Ruby — you
are then responsible for releasing it with `ca_free` (§6.2). The
freshly created entity is already attached: `ca->ptr` points at a
zero-initialised buffer of `elements * bytes` bytes, ready to write.

```c
ca_size_t shape[2] = { rows, cols };
volatile VALUE vout = rb_carray_new(CA_FLOAT64, 2, shape, 0, NULL);
CArray *out; GetCArray(vout, out);

double *op = (double *)out->ptr;      /* already attached, zero-filled */
/* ... fill op[0 .. rows*cols-1] ... */
return vout;
```

The `_safe` variants (`rb_carray_new_safe`, `carray_new_safe`) add
overflow checking on the `elements * bytes` product for shapes that
could overflow `ca_size_t`; use them when the shape is derived from
untrusted input.

When your output is a reduction result (input shape with some axes
removed), `rb_ca_new_reduced(self, axes, naxes, data_type, keep_axis)`
computes the reduced shape for you and allocates the entity — see the
kernel example in §12.2.

### 8.2 Wrapping foreign memory: `rb_ca_wrap_new`, `ca_wrap_new`

When the element data already exists in a buffer *outside* CArray — a
region you decoded, an `mmap`, a buffer owned by another library — you
wrap it instead of copying:

```c
VALUE   rb_ca_wrap_new (int8_t data_type, int8_t ndim, ca_size_t *dim,
                        ca_size_t bytes, CArray *mask, char *ptr);
CAWrap *ca_wrap_new    (int8_t data_type, int8_t ndim, ca_size_t *dim,
                        ca_size_t bytes, CArray *mask, char *ptr);
```

Same parameters as the entity constructors plus a trailing `ptr`: the
address of your existing buffer, which must hold at least
`elements * bytes` bytes laid out row-major. The result is a `CAWrap`
— a CArray whose `ptr` *is* your buffer. Reads and writes go straight
through to it; CArray never reallocates or frees it.

```c
/* `raw` points at rows*cols doubles we decoded ourselves. */
ca_size_t shape[2] = { rows, cols };
volatile VALUE v = rb_ca_wrap_new(CA_FLOAT64, 2, shape, 0, NULL,
                                  (char *)raw);
/* v now reads and writes through `raw` with zero copy. */
```

`ca_wrap_new_null` is the same but takes no `ptr`; it creates a wrap
with `ptr == NULL` that you fill in afterwards (rare — used when the
buffer address is not known at construction time).

This is the zero-copy import path. `CArray.wrap_memory_view` (§10)
is the Ruby-facing form of exactly this, wrapping a MemoryView
producer's buffer as a `CAWrap`.

### 8.3 Returning a view (`ca_stride_new` and friends)

When the data you want to expose already lives in another CArray and
can be reached by a linear stride computation — a reshape, a
transpose, a strided slice — return a *view* rather than copying. The
general constructor is `ca_stride_new`:

```c
CAStride *ca_stride_new (int8_t obj_type, CArray *parent,
                         int8_t data_type, ca_size_t bytes,
                         int8_t ndim, ca_size_t *dim,
                         ca_size_t *strides, ca_size_t base_offset);
VALUE     rb_ca_stride_new (VALUE cary,
                            int8_t data_type, ca_size_t bytes,
                            int8_t ndim, ca_size_t *dim,
                            ca_size_t *strides, ca_size_t base_offset);
```

The view addresses parent element `base_offset + Σ idx[k] * strides[k]`
(strides and offset are in **bytes**, and strides may be negative or
zero). `parent` is the source CArray; the view holds a reference to
it, so the parent stays alive as long as the view does. The view has
no buffer of its own — `ca->ptr` is `NULL` until someone attaches it
(§4).

Most extensions do not build stride vectors by hand. The concrete
strided views have their own constructors and, more usually, you reach
them through the Ruby API (`reshape`, `transpose`, `[]`) and return
*those*. Hand-rolling `ca_stride_new` is for the case where you are
implementing a genuinely new strided access pattern in C. When you do,
mind the CAStride invariants (tail-bearing subclasses, `clone` / allocator
overrides, mask class).

The decision rule: **copy only when you must.** If the result is a
re-view of existing data, return a view — it is O(1) and composes with
the rest of CArray's view algebra. Allocate an entity (§8.1) only when
the result is genuinely new data (a computed reduction, a
transformed buffer).

### 8.4 Lifetime and ownership of the wrapped buffer

The three constructors differ precisely in who frees the element
buffer, and getting this wrong is the main hazard when producing
CArray from C:

| Constructor        | Buffer owner     | Freed by                         |
|--------------------|------------------|----------------------------------|
| `carray_new` / `rb_carray_new` | CArray | `ca_free` / GC (the buffer is CArray's) |
| `ca_wrap_new` / `rb_ca_wrap_new` | **you (foreign)** | your code / the foreign owner — CArray never frees it |
| `ca_stride_new`    | the parent entity | the parent, via GC — the view frees nothing |

For a **wrap**, the wrapped buffer must outlive the `CAWrap`. If the
buffer is freed while a Ruby-visible `CAWrap` still references it, any
later access is a use-after-free. Two safe patterns:

- **Copy in, then own it.** If the foreign buffer is transient, do not
  wrap it — allocate an entity with `rb_carray_new` and `memcpy` the
  data in. Now CArray owns a buffer with a clear lifetime, and the
  foreign buffer can be freed immediately.
- **Tie the lifetimes.** If you genuinely want zero-copy, keep the
  object that owns the buffer alive for as long as the wrap. The
  standard mechanism is to store a reference to the owner so GC cannot
  collect it before the wrap; `CArray.wrap_memory_view` does this by
  holding the MemoryView producer.

Never mix allocators across the boundary: a buffer that CArray will
free must come from `xmalloc` (§6.1); a buffer allocated by an
external library must be freed by that library's freer, which means it
should be wrapped (foreign-owned) or copied into an `xmalloc` entity,
never handed to `carray_new` as if CArray owned it.

For a **view**, there is nothing extra to manage — the view holds a
reference to its parent, so the parent (and its buffer) stays alive as
long as the view is reachable, and GC releases both in order.

---

## 9. Type coercion at the boundary

A CArray kernel is written for a specific element type — the library
wants `double *`, your loop casts to `int32_t *`. But the user can
pass any data_type. Coercion at the boundary is how you reconcile the
two: you declare the type you need, and CArray delivers the input as
that type, casting lazily and without disturbing the original.

### 9.1 The `data_type` enum, `ca_sizeof[]`, `ca_valid[]`

The element types are the `CA_*` enum in `ext/carray.h`:

```c
CA_FIXLEN    /* 0  — fixed-width opaque bytes (struct records, strings) */
CA_BOOLEAN   /* 1  — one byte per element, 0 / non-0 */
CA_INT8      /* 2  */    CA_UINT8    /* 3  */
CA_INT16     /* 4  */    CA_UINT16   /* 5  */
CA_INT32     /* 6  */    CA_UINT32   /* 7  */
CA_INT64     /* 8  */    CA_UINT64   /* 9  */
CA_FLOAT32   /* 10 */    CA_FLOAT64  /* 11 */
CA_FLOAT128  /* 12 — not built (long double family removed in 3.0) */
CA_CMPLX64   /* 13 */    CA_CMPLX128 /* 14 */
CA_CMPLX256  /* 15 — not built (long double family removed in 3.0) */
CA_OBJECT    /* 16 — arbitrary Ruby VALUE per element */
CA_NTYPE     /* 17 — count of type codes, not a type */
```

Convenience aliases exist: `CA_BYTE = CA_UINT8`, `CA_SHORT = CA_INT16`,
`CA_INT = CA_INT32`, `CA_FLOAT = CA_FLOAT32`, `CA_DOUBLE = CA_FLOAT64`,
`CA_COMPLEX = CA_CMPLX64`, `CA_DCOMPLEX = CA_CMPLX128`.

Three parallel tables, all sized `CA_NTYPE` and indexed by data_type
code, describe each type:

```c
extern const int32_t ca_sizeof[CA_NTYPE];    /* element size in bytes  */
extern const int32_t ca_valid[CA_NTYPE];     /* 1 if the type is built */
extern const char   *ca_type_name[CA_NTYPE]; /* "float64", "int32", …  */
```

- `ca_sizeof[CA_FLOAT64]` is `8`; `ca_sizeof[CA_FIXLEN]` is `0`
  (variable — width comes from `ca->bytes`), likewise the object type
  stores a `VALUE`.
- `ca_valid[t]` is `0` for types not compiled into this build. The
  **long-double family (`CA_FLOAT128`, `CA_CMPLX256`) was removed in
  CArray 3.0** and is always invalid; do not emit code that constructs
  those types. Test `ca_valid[t]` before trusting a data_type code
  that came from outside.
- `ca_type_name[t]` is what you put in error messages.

### 9.2 `ca_wrap_readonly(obj, data_type)` ─ accept-any, see-as-data_type

This is the workhorse of boundary coercion. Given `obj` — a CArray or
not — and a target `data_type`, it returns a CArray that presents
`obj`'s data *as* that type:

```c
#define ca_wrap_readonly(obj, data_type) \
  (obj = rb_ca_wrap_readonly(obj, INT2NUM(data_type)), (CArray*) DATA_PTR(obj))
```

Two behaviours in one call:

- If `obj` already has the requested data_type, it is returned
  unchanged — no copy, no view.
- Otherwise, a **lazily-casting view** is returned, converting elements
  to the requested type when it is attached (a `CAMonOp` cast for a
  plain numeric target; a `CAFake` for `CA_FIXLEN`, `CA_OBJECT`, and
  the data_class overlay).

The `_readonly` in the name is **your declaration, not a property of
what you get back** — you are saying you will only read this operand.
Because nothing is written back, the call is free to convert widely,
which is why it also accepts non-CArray sources (a Numeric / String /
arbitrary object becomes a CScalar, an Array goes through `to_ca`)
where the writable form cannot. It does not make anything read-only:
a matching CArray comes back as the same object, and a cast view
writes through to its parent. Only reading is your side of the deal.

The macro reassigns `obj` to the wrapping `VALUE` (so it stays GC-safe
while you use it) and yields the `CArray *`. In practice most code
calls the underlying function directly for clarity:

```c
volatile VALUE vin = rb_ca_wrap_readonly(self, INT2FIX(CA_FLOAT64));
CArray *in; GetCArray(vin, in);
ca_attach(in);          /* materialises a contiguous Float64 buffer */
/* ... read (const double *)in->ptr ... */
ca_detach(in);
```

Keep the returned `VALUE` in a `volatile VALUE` local for the lifetime
of your use, so the cast view (and therefore the buffer it attaches)
is not collected mid-computation.

The point of `ca_wrap_readonly` is that your kernel body only ever
sees one type. You do not branch on the user's data_type; you declare
the type you compute in, and the boundary makes it so.

### 9.3 `ca_wrap_writable(obj, data_type)` ─ for write-back, narrower intake

When your operation writes *back* into the caller's array, declare that
with the writable form:

```c
#define ca_wrap_writable(obj, data_type) \
  (obj = rb_ca_wrap_writable(obj, INT2NUM(data_type)), (CArray*) DATA_PTR(obj))
```

It syncs writes back through the cast to the original array, converting
on the way. The declaration also narrows what it will take: because a
write has to land somewhere real, it accepts **only sources that can
share storage with the result** — a writable CArray, `nil`, an object
whose `to_ca` honours `writable: true`, a writable MemoryView producer.
Anything that would have to be copied to become a CArray (a Numeric, an
Array, a String) is refused up front, since a copy would swallow your
writes in silence. That is the entire difference between the two wraps:
one has a write to land, the other does not.

For a foreign object the refusal is the object's own to make. This calls
`obj.to_ca(writable: true)`, the caller's half of the `to_ca` contract:
"give me a CArray *whose writes reach you*". A `to_ca` that can only
produce a copy raises instead of answering, so nothing is lost silently.
If you write `to_ca` in C for your own class, read the keyword with
`ca_to_ca_writable_arg(argc, argv)` and refuse via
`ca_to_ca_refuse_writable(self)`; define the method with arity `-1`.

You must pair it with `ca_sync` before `ca_detach`:

```c
volatile VALUE vio = rb_ca_wrap_writable(self, INT2FIX(CA_FLOAT64));
CArray *io; GetCArray(vio, io);

ca_attach(io);
/* ... write (double *)io->ptr ... */
ca_sync(io);            /* convert + propagate back to `self` */
ca_detach(io);
return self;
```

If the original is read-only (`ca_is_readonly` — a reduction result, a
frozen array), `rb_ca_wrap_writable` refuses; validate writability
early (§4.6) so the error is clear.

The two wraps mirror the two roles: `_readonly` for inputs you only
read, `_writable` for the in-place / write-back case (the `smooth!`
variant in §11.3).

### 9.4 Class-method routes (`CArray::Float64.from_memory_view`, etc.)

For inputs that are not yet CArray — a Numo array, a NumPy array via
PyCall, a fiddle pointer, anything exposing the MemoryView protocol —
the coercion also happens at the *import* step. The typed class
methods let you name both the target data_type and the copy/wrap
choice at once:

```ruby
CArray::Float64.from_memory_view(obj)   # copy, seen as Float64
CArray::Int32.wrap_memory_view(obj)     # zero-copy wrap, seen as Int32
```

These matter because a MemoryView producer may be *typeless* (its
format string is `NULL`). In that case the untyped
`CArray.from_memory_view(obj)` has no data_type to assume and raises;
the typed route `CArray::Float64.from_memory_view(obj)` supplies it.
For a producer that *does* declare a format, the untyped form infers
the data_type and the typed form additionally coerces to the type you
name.

From C you generally trigger these by `rb_funcall` to the class method
rather than a dedicated C entry point — the import path is
Ruby-surface machinery (§10). The takeaway for coercion is that "see
this foreign buffer as type T" is expressed by choosing the typed
class (`CArray::T`) as the receiver.

### 9.5 `CArray.result_type` from C (N-ary common data_type)

When an operation has several inputs of different types, you need the
common type to compute in — Int32 + Float64 should compute in Float64.
The promotion rule is a pure function over the cast table, exposed in
C as:

```c
int8_t ca_promote_type (int8_t a, int8_t b);
```

`ca_promote_type(CA_INT32, CA_FLOAT64)` returns `CA_FLOAT64`. It is
the same reducer that backs `CArray.result_type` at the Ruby level.
For more than two operands, fold it:

```c
int8_t rt = a->data_type;
rt = ca_promote_type(rt, b->data_type);
rt = ca_promote_type(rt, c->data_type);
/* now coerce each operand to rt with ca_wrap_readonly */
```

Then wrap every input to `rt` (§9.2), attach, and your loop is
single-typed. This is the standard preamble for an N-ary element-wise
operation whose inputs may be mixed types.

### 9.6 `CA_OBJECT` and what coercion cannot do

`CA_OBJECT` stores a Ruby `VALUE` per element — arbitrary objects, not
a numeric machine type. Coercion has hard limits here:

- **You cannot cast an arbitrary `CA_OBJECT` array to a numeric type
  for free.** `ca_wrap_readonly(obj, CA_FLOAT64)` on a `CA_OBJECT`
  input builds a cast view whose attach calls `NUM2DBL` (or the
  appropriate conversion) on every element — it works only insofar as
  each stored object *is* convertible, and it raises element-by-element
  if one is not. It is a per-element Ruby call, not a reinterpret; do
  not expect it to be cheap or to be a plain buffer of doubles.
- **The reverse — seeing a numeric array as `CA_OBJECT`** — boxes each
  element into a Ruby `VALUE`. That is a real materialisation, not a
  view onto the same bytes.
- **A `CA_OBJECT` buffer is `VALUE *`, and its elements are GC-managed.**
  You must not `memcpy` it into a foreign buffer and treat the results
  as opaque data, and you cannot export it as a MemoryView (§10 lists
  `CA_OBJECT` as reject) — there is no C-level layout to hand out.

For numeric kernels, the clean stance is: require a numeric input
(coerce with `ca_wrap_readonly` to your compute type, letting the
conversion raise if the user passed genuinely non-numeric objects), or
handle `CA_OBJECT` on an explicit, separate code path that calls
through to Ruby per element (`rb_funcall`) rather than pretending the
bytes are numbers. `ca_is_object_type(ca)` is the predicate that lets
you split those paths.

---

## 10. MemoryView interop

CArray implements Ruby's `rb_memory_view_t` protocol (Ruby 3.0+) as
both a **consumer** (import a foreign buffer) and a **producer**
(export CArray's buffer). This is the zero-copy bridge to Numo, NumPy
via PyCall, Red Arrow, fiddle, and anything else that speaks the same
protocol. For most extensions you do not implement any protocol
callbacks yourself — you call CArray's Ruby-facing import methods and
let the export side work automatically. `docs/MemoryView.md` is the
canonical user reference; this section is the C author's view of it.

### 10.1 Consuming a MemoryView from C

To bring a foreign buffer into CArray, use the two class methods (call
them from C via `rb_funcall` on `rb_cCArray`, or expose them directly
in Ruby):

| Method | Result | Copy? | Accepts |
|---|---|---|---|
| `CArray.from_memory_view(obj)` | owned `CArray` | copy | any layout, including strided |
| `CArray.wrap_memory_view(obj)` | `CAWrap` (or `CAStride`) | zero-copy | row-major contiguous (strided → wrapped as a `CAStride`) |
| `CArray.memory_view_available?(obj)` | boolean | — | lightweight probe |

- **`from_memory_view`** borrows a view of `obj`, copies the bytes into
  a freshly-allocated entity, and releases the view. The result is
  independent of the source — the source can change or be freed
  afterward. Strided sources are fine; the copy gathers them.
- **`wrap_memory_view`** borrows the view and *keeps it alive* for the
  lifetime of the returned `CAWrap`, sharing memory with the source
  (zero-copy). The source object is anchored so it cannot be GC'd
  before the wrap. This is the C-level ownership tie of §8.4, done for
  you.

A **typeless producer** (format string `NULL`) carries no data_type;
name one explicitly, either through the typed class
(`CArray::Float64.from_memory_view(obj)`) or a `type:` argument. A
producer that declares a format is imported at its natural data_type.

```c
/* From C: snapshot-import an arbitrary MemoryView producer. */
VALUE vin = rb_funcall(rb_cCArray, rb_intern("from_memory_view"),
                       1, foreign_obj);
CArray *in; GetCArray(vin, in);
/* `in` owns its buffer; foreign_obj is no longer referenced. */
```

### 10.2 Exporting a CArray as a MemoryView

The producer side works automatically: any consumer that requests a
MemoryView from a CArray gets one, and CArray picks the right strategy
per `obj_type`. As a producer you do nothing beyond handing the CArray
to the consumer — but you should know which arrays can be exported and
how:

| obj_type family | Strategy | Notes |
|---|---|---|
| entities (`CA_OBJ_ARRAY`, `CA_OBJ_ARRAY_WRAP`, `CA_OBJ_SCALAR`) | direct | contiguous buffer exported as-is |
| CAStride family (`REFER`, `BLOCK`, `FARRAY`, `TRANSPOSE`, `REPEAT`, `STRIDE`) | strided | zero-copy, exported with a stride vector |
| scatter / bound / overlay / reduce views (`SELECT`, `MAPPING`, `GRID`, `SHIFT`, `WINDOW`, `FAKE`, `FIELD`, `REDUCE`) | attach | materialised to a contiguous buffer first |
| `CA_OBJ_BITARRAY`, `CA_OBJ_BITFIELD`, `CA_OBJ_OBJECT`, `CA_OBJ_UNBOUND_REPEAT` | reject | no C-level layout to hand out |

Two consumer-driven wrinkles:

- **Strided but SIMPLE-only consumers.** A consumer that sets the
  `SIMPLE` flag (it wants contiguous only — NetCDF, HDF5 backends)
  cannot take a strided export. The producer transparently attaches →
  fills → syncs to give it a contiguous buffer.
- **Masks reject.** A CArray *with a mask* cannot be exported directly
  (a MemoryView has no place for the mask). Pass one of `ca.value`
  (mask-ignoring view), `ca.mask` (the boolean array), or
  `ca.unmask_copy(fill)` (masked cells filled) — see §5. The
  `CA_OBJECT` type and sub-byte types cannot be exported at all.

Writable exports are refused for read-only arrays (`ca_is_readonly` —
`CARepeat`, value views): a consumer asking for a writable view of
those gets an error rather than a buffer it cannot legally write.

If you are extending the export machinery (adding a strategy for a new
`obj_type`), the table is `ca_mv_runtime_types` in
`ext/carray_memory_view.c`; register the new kind as direct / strided /
attach / reject there, and update `docs/MemoryViewFormat.md`.

### 10.3 Talking to Numo, PyCall, Arrow, fiddle

The protocol is the lingua franca; the format string is the detail
that has to line up. `docs/MemoryViewFormat.md` is the authority on
CArray's format-string contract (PEP 3118, strict at the top level).
Practical notes per peer:

- **Numo::NArray** — Numo does not itself implement the MemoryView
  producer protocol in the shipped release, so the interop is not
  symmetric out of the box; where a MemoryView bridge exists (e.g.
  `numo-narray-memoryview`), CArray consumes and produces against it
  with the format synonyms documented in `docs/MemoryViewFormat.md`.
- **NumPy via PyCall** — NumPy arrays expose a buffer with a PEP 3118
  format; `CArray.from_memory_view(numpy_array)` copies it in,
  `wrap_memory_view` shares it. Strided NumPy arrays import fine (copy
  gathers, wrap yields a `CAStride`).
- **Red Arrow** — CArray is an Arrow *consumer*; a primitive Arrow
  buffer maps to a `(value view, mask view)` pair. The consumer-side
  format synonyms are maintained deliberately for Arrow interop (see
  the MemoryView format doc §3.2).
- **fiddle** — a `Fiddle::Pointer` region can be wrapped; supply the
  data_type via the typed class route (§9.4) since a bare pointer is
  typeless.

The recurring rule: **contiguous + row-major imports zero-copy,
anything else copies** (or, for wrap, comes back as a `CAStride` that
still shares the memory). When in doubt about a peer's format string,
check `docs/MemoryViewFormat.md` rather than guessing — a format
mismatch is the usual cause of a failed import.

---

# Part III — Writing computational kernels

There are two distinct situations an extension author lands in:

1. You already have a C function from some external library that
   operates on a plain contiguous buffer of a specific data_type, and you
   want to expose it as a CArray-aware Ruby method. → **the boundary
   pattern** (§11). This is the common case and uses only the
   machinery introduced in Parts I and II.

2. You are writing the numeric loop yourself, in C, and want it to
   work uniformly across every CArray kind (entity, strided view,
   fancy-indexed view, masked input, chain of views, …) without
   branching on subtype. → **kernel_iterator** (§12). This is the
   more advanced path, with its own dedicated reference.

The two are not exclusive — a large extension typically does both —
but they use different machinery and have different starting points.

## 11. Wrapping an external numerical library

The common situation: there is already a C function out in the
world that does what you want. It takes a `const double *` (or
`float *`, or `int32_t *`, …), a length, and some parameters, and
returns or fills a buffer of the same shape. You want to expose it as
a CArray-aware Ruby method.

You do **not** need kernel_iterator for this. The job is to (a) bring
the input into a contiguous buffer of the data_type the library expects,
(b) call the function, (c) deliver the result back to Ruby. CArray's
view machinery (§4) and data_type-coercing wrappers (§9) cover all three
steps.

### 11.1 The shape of the problem

Suppose the library exposes:

```c
/* Gaussian-smooth n samples in place. Float64 only. */
void extlib_smooth (double *x, size_t n, double sigma);
```

You want a Ruby method `CArray#smooth(sigma)` that:

- accepts any CArray (entity, view, integer data_type, masked, …);
- runs `extlib_smooth` on the data with `sigma` as a Float;
- returns a fresh Float64 CArray of the same shape, leaving the input
  untouched;
- raises a sensible error on shapes the library does not handle.

### 11.2 Worked example: `extlib_smooth`

```c
/* extconf.rb has already linked against the library. */
#include "carray.h"
extern void extlib_smooth (double *x, size_t n, double sigma);

static VALUE
rb_ca_smooth (VALUE self, VALUE vsigma)
{
  double sigma = NUM2DBL(vsigma);

  /* (1) Accept any view, see it as Float64. ca_wrap_readonly returns
   *     the input as-is when it is already Float64, or a CAFake view
   *     that lazily casts on attach otherwise. The original `self` is
   *     not modified.                                                 */
  volatile VALUE vin = rb_ca_wrap_readonly(self, INT2FIX(CA_FLOAT64));
  CArray *in; GetCArray(vin, in);

  if (in->ndim != 1) {
    rb_raise(rb_eArgError, "smooth: expected 1-D, got %d-D", in->ndim);
  }

  /* (2) Allocate the output entity (Float64, same shape).            */
  volatile VALUE vout = rb_carray_new(CA_FLOAT64, in->ndim, in->dim,
                                      0, NULL);
  CArray *out; GetCArray(vout, out);

  /* (3) Attach both, copy input into the output buffer, call the lib
   *     in place, then release. ca_attach on an entity is a no-op; on
   *     a view it materialises into a contiguous Float64 buffer.     */
  ca_attach(in);
  /* out is a freshly allocated entity — already attached. */

  memcpy(out->ptr, in->ptr, in->elements * sizeof(double));
  extlib_smooth((double *)out->ptr, (size_t)out->elements, sigma);

  ca_detach(in);
  return vout;
}

void
Init_smooth (void)
{
  rb_define_method(rb_cCArray, "smooth", rb_ca_smooth, 1);
}
```

What each piece is doing:

- **`rb_ca_wrap_readonly(self, INT2FIX(CA_FLOAT64))`** — the boundary
  coercion (§9). It is the standard way to say "I want to see this
  input as Float64, no matter what data_type the user actually passed."
  Integer inputs become a CAFake view that casts on attach; Float64
  inputs are returned as-is. The original `self` is untouched.
- **`rb_carray_new(CA_FLOAT64, ndim, dim, 0, NULL)`** — allocate a
  fresh entity that owns its buffer. The shape mirrors the input.
- **`ca_attach(in)`** — materialises `in->ptr` into a contiguous
  row-major Float64 buffer, regardless of whether the input was an
  entity, a strided view, a fancy-indexed view, or a chain of those.
  This is the single line that makes the function "accept any view".
- **`extlib_smooth(...)`** — the library call. It sees a plain
  `double *` and has no idea CArray exists.
- **`ca_detach(in)`** — releases the materialised input buffer. The
  output entity is returned to Ruby; its lifetime is managed by GC.

The mask, if any, rides along with the input through `ca_attach`. If
your wrapper needs to honour masked elements (for example, skip them
or propagate to the output), inspect `in->mask` before the library
call — see §5.

### 11.3 Variations and pitfalls

**Write-in-place variant (`smooth!`).** When the library function
mutates the buffer and you want to expose that semantics:

```c
volatile VALUE vio = rb_ca_wrap_writable(self, INT2FIX(CA_FLOAT64));
CArray *io; GetCArray(vio, io);

ca_attach(io);
extlib_smooth((double *)io->ptr, (size_t)io->elements, sigma);
ca_sync(io);      /* propagate writes back through the view chain */
ca_detach(io);
return self;
```

`rb_ca_wrap_writable` is the same idea as `_readonly` but reserves the
right to sync back. Always pair it with `ca_sync` before `ca_detach`,
or the writes are silently dropped.

**Multiple inputs.** Wrap each one with `ca_wrap_readonly` to the
appropriate data_type, then `ca_attach_n(2, a, b)` / `ca_detach_n(2, a,
b)`. If the two inputs need a common data_type, derive it once with
`rb_ca_result_type` and coerce both to it.

**Shape constraints.** Most external libraries care about contiguity
and shape, not view-ness. Once you have `ca_attach`-ed, the buffer
*is* contiguous and row-major; the call site does not have to
distinguish. Shape checks (`ndim`, `dim[k]` ranges, leading-dim
constraints for column-major libs) go right before the library call.

**Column-major libraries (LAPACK et al.).** Allocate the materialised
input as a `CAFarray` view, or transpose explicitly before attach.
Either way, the contract at the library call site is plain pointer +
shape; the conversion is done by the view layer.

**`xmalloc` vs library allocators.** Buffers handed to or returned by
CArray must come from `xmalloc` (§6.1). If the external library
allocates and returns a pointer of its own, copy into an `rb_carray_new`
output and free the library's pointer with the library's freer — never
mix the allocators.

**Exception safety.** If anything between `ca_attach` and `ca_detach`
can raise (a callback, a `rb_funcall`, a deep `rb_raise` from a
validator), wrap the section in `rb_ensure` so detach still runs on
the unwind path. For straight library calls that cannot raise this is
unnecessary.

This pattern — wrap, attach, call, (sync,) detach — is the everyday
shape of CArray boundary code, and it composes with the rest of the
guide: §7 (extracting), §9 (data_type coercion), §10 (handing a buffer to
something MemoryView-aware) are the same building blocks viewed from
different angles.

---

## 12. kernel_iterator: an overview

When the boundary pattern of §11 is not enough — typically because
you are writing the numeric loop yourself and want it to work on any
view kind without subtype dispatch — CArray provides a dedicated
mechanism: `kernel_iterator`. This section is a brief tour; the
full reference lives in a separate document.

### 12.1 What it gives you

`kernel_iterator` is CArray's universal dispatch surface for in-house
kernels. You write a single per-slab function — given a contiguous
span of `n` elements of a known data_type, do the work — and the iterator
handles everything else:

- accepts any of CArray's view kinds as input (CAStride family,
  CASelect, CAMapping, CAWindow, CAShift, CAGrid, CAFake, CAByteSwap,
  CABitfield, CABitarray, CAReduce, CAObject, …), without your kernel
  having to know which it got;
- folds view chains down to the root entity where possible, yielding
  aliased spans of parent memory directly; materialises (gather) only
  where it must;
- carries masks alongside the data, with opt-out (`CA_KERNEL_NO_MASK`)
  for kernels that do not handle them;
- supports three levels of access — L1 (contiguous slab), L2 (strided
  slab), L3 (K-D slab) — so you can pick the loop shape that matches
  the kernel.

It is the same mechanism that the in-tree `sum_ki`, `map_ki` and
related kernels are built on.

### 12.2 A glimpse of the code

A reduction-style kernel looks roughly like this (Float64, sum over a
chosen set of axes):

```c
static VALUE
rb_ca_sum_ki (int argc, VALUE *argv, VALUE self)
{
  CArray *ca; GetCArray(self, ca);
  ca_check_data_type(ca, CA_FLOAT64);

  volatile VALUE ropt = rb_pop_options(&argc, &argv);
  volatile VALUE raxis = Qnil;
  rb_scan_options(ropt, "axis", &raxis);
  int8_t  axes[CA_RANK_MAX];
  int8_t  naxes = rb_ca_parse_reduce_axes_kw(raxis, ca, axes);

  VALUE   vout = rb_ca_new_reduced(self, axes, naxes, CA_FLOAT64);
  CArray *out; GetCArray(vout, out);

  ca_iter_state_t st;
  ca_iter_init_l2(&st, ca, CA_SLAB_AXES, axes, naxes, 0);

  ca_attach(out);
  double *op = (double *)out->ptr;
  ca_size_t outer = 0;

  const char *p; ca_size_t n, stride;
  while (ca_iter_next_slab_strided(&st, &p, &n, &stride)) {
    double acc = 0.0;
    for (ca_size_t i = 0; i < n; i++) {
      acc += *(const double *)(p + i * stride);
    }
    op[outer++] = acc;
  }
  ca_iter_finish(&st);
  ca_sync(out); ca_detach(out);
  return vout;
}
```

That same kernel runs against `a`, `a[1..-2, nil]`, `a.transpose`,
`a[mask]`, `a.shift(1).window(...)`, etc. — the iterator hides the
differences.

### 12.3 Where to read the full guide

The contract, the three access levels, mask handling, the L2 inner-loop
macro family, WRITE kernels and sync semantics, and the recommended
specialisation patterns are covered in detail in a dedicated document:

> **[`docs/HOW_TO_WRITE_KERNEL.md`](HOW_TO_WRITE_KERNEL.md)** — the
> kernel author's reference. Start there once you have decided that
> kernel_iterator is the right tool for your task.

---

# Part IV — Operational concerns

## 16. Threading and concurrency

### 16.1 CArray is not thread-safe

CArray does not guarantee safety when multiple Ruby threads operate on
the same array series concurrently. This is a deliberate, documented
contract with the *user*, not an implementation gap: a caller must
ensure that two threads never operate on the same underlying entity at
the same time — one directly and one through a derived view, or both
through views.

Independent arrays in independent threads are fine. What is unsafe is
concurrent access to the *same* data through the attach machinery. As
an extension author, you inherit this contract: your C code may assume
single-owner access to any array it is handed, and need not take locks
to defend the attach lifecycle.

Note this is about *Ruby-thread* concurrency. It says nothing against
data-parallelism *inside* a single kernel call — SIMD, or a future
in-kernel worker split over a buffer you own exclusively for the
duration of the call, is orthogonal and permitted. The contract is:
one Ruby-visible owner of the array at a time.

### 16.2 The structural hazard

The reason is the attach lifecycle itself (§4). A view materialises
its parent's data into a private buffer on `ca_attach`, and scatters
it back on `ca_sync`. If one thread is mid-lifecycle on a view while
another mutates the parent entity directly:

- the view's sync-back can overwrite the other thread's changes with
  stale gathered data, or
- the view's gather can copy a half-written parent into itself.

This is specific to CArray's materialise-and-sync view model. Array
libraries without a sync-back step (a view that is only ever an alias)
do not have this hazard. It has existed structurally since derived
views were introduced; the GVL has masked it, not removed it. As Ruby
gains more parallel execution paths, the friction surfaces.

The practical consequence for your extension: do not build APIs that
invite a caller to hold a view in one thread and hand the parent to
another. If you expose long-running work, document that the array
(and any view of it) must not be touched elsewhere for the duration.

### 16.3 When `rb_thread_call_without_gvl` is safe

Releasing the GVL around a long C computation is allowed under two
conditions, both required:

1. **The released region is self-contained.** Before releasing, finish
   every attach you need and capture only the raw `ptr` and sizes. In
   the released region, touch *only* those buffers — no `rb_*` calls,
   no allocation that runs Ruby, no access to CArray struct fields that
   another thread might change.
2. **It actually helps.** The release buys something measurable — a
   genuinely long, CArray-independent stretch: a big `memcpy`, file
   I/O, a call into an external library that does its own work.

The safe shape is: attach → grab `ptr`/`elements`/`bytes` → release
GVL → compute on the raw buffer → reacquire → sync/detach. Blocking
I/O and large external-library calls fit this well. CPU-bound numeric
loops generally do *not* pay off through GVL release under MRI (its
thread scheduler is not built for CPU parallelism), so pursue speed
through SIMD and folding within the GVL first.

Do **not** release the GVL across a region that calls back into Ruby,
allocates CArray, or reads through a view whose parent another thread
could be mutating — that reintroduces exactly the hazard of §16.2 with
no GVL to serialise it.

### 16.4 Escape hatches for thread-safe needs

If a user genuinely needs to move array data across threads safely,
the answer is to hand out *owned, independent* data rather than a view
into a shared series:

- **`copy`** — produce an independent entity (its own buffer) that the
  other thread can own outright. From C, `carray_new` + fill, or
  `rb_ca_copy`.
- **MemoryView export** — hand the buffer to another library that has
  its own ownership model (§10), zero-copy where its lifetime rules
  allow.
- **Ractor** — Ractor's no-shared-mutable rule aligns with CArray's
  view-everywhere model: it structurally forbids sharing a mutable
  CArray across Ractors, so the §16.2 hazard cannot arise. Any
  cross-Ractor design moves whole entities, never shares views.

Frame this to users not as "CArray is unsafe" versus some safe
alternative, but as a design consequence: a library built on
materialise-and-sync views cannot also promise lock-free concurrent
access to the same series. When that is the requirement, the escape is
to stop sharing the series — copy out, or export.

---

## 17. Error handling

### 17.1 `rb_raise` vs. status returns

CArray's C API signals errors the Ruby way: it `rb_raise`s. The
`ca_check_*` helpers (§7.3), the `ca_wrap_*` coercions (§9), and the
constructors all raise directly on bad input rather than returning an
error code. Your extension should do the same — raise at the boundary,
compute in the interior on the assumption that inputs are already
validated.

The consequence to internalise is that **almost any CArray call can
longjmp out of your function.** `rb_raise` unwinds the C stack via
`setjmp`/`longjmp`; it does not return. A local you allocated, a buffer
you `xmalloc`ed, an array you attached — none of their cleanup code
runs if a call between them raises. That is what §17.2 is about.

Reserve C status-return style for genuinely internal helpers that never
face user input and whose callers handle the code. At the Ruby method
boundary, raise.

### 17.2 Cleaning up attach state (`rb_ensure`, `rb_protect`)

The attach lifecycle (§4) is the classic leak site: if anything between
`ca_attach` and `ca_detach` raises, the detach never runs and the
materialised buffer leaks (and the view is left in an attached state).
Whenever the guarded region can raise — a Ruby callback, a `rb_funcall`,
an allocation, a validator that might `rb_raise`, arithmetic that could
trip a Ruby-level exception — wrap it so detach runs on the unwind path.

`rb_ensure` is the usual tool: a body function and an ensure function
that runs whether the body returned or raised.

```c
struct work { CArray *v; };

static VALUE
do_work (VALUE arg)
{
  struct work *w = (struct work *)arg;
  double *p = (double *)w->v->ptr;
  for (ca_size_t i = 0; i < w->v->elements; i++) {
    p[i] = risky_transform(p[i]);   /* may raise */
  }
  return Qnil;
}

static VALUE
cleanup (VALUE arg)
{
  struct work *w = (struct work *)arg;
  ca_detach(w->v);                  /* runs on normal + exceptional exit */
  return Qnil;
}

/* ... */
ca_attach(v);
struct work w = { v };
rb_ensure(do_work, (VALUE)&w, cleanup, (VALUE)&w);
```

`rb_protect` is the variant to use when you need to *catch* the
exception (inspect the state, decide whether to re-raise) rather than
just guaranteeing cleanup; it runs a body and reports via a `state`
out-param instead of propagating. Prefer `rb_ensure` for the common
"always detach" case — it is simpler and expresses the intent.

For a straight external-library call that provably cannot raise (a pure
C function on a raw buffer, as in §11.2), the guard is unnecessary — the
region between attach and detach is exception-free, so a plain
`ca_detach` after it suffices. Reach for `rb_ensure` exactly when the
guarded region can longjmp.

The same discipline applies to any `xmalloc`ed scratch you hold across a
possibly-raising call, and to output arrays you have attached — release
them in the ensure handler too.

### 17.3 Argument validation idioms

Validate at the top of the method, before allocating or attaching, so a
bad argument fails cleanly with nothing to unwind:

```c
static VALUE
rb_ca_scale (VALUE self, VALUE vfactor, VALUE vaxis)
{
  /* 1. Convert scalars first — NUM2DBL/NUM2INT raise TypeError on
   *    non-numeric input, before any CArray work.                 */
  double factor = NUM2DBL(vfactor);
  int    axis   = NUM2INT(vaxis);

  /* 2. Extract and check the array.                               */
  CArray *ca; GetCArray(self, ca);
  if (axis < 0 || axis >= ca->ndim) {
    rb_raise(rb_eArgError, "axis %d out of range for %d-D array",
             axis, ca->ndim);
  }

  /* 3. Only now coerce / allocate / attach.                       */
  volatile VALUE vin = rb_ca_wrap_readonly(self, INT2FIX(CA_FLOAT64));
  /* ... */
}
```

Conventions worth keeping consistent with the rest of CArray:

- **Error classes.** `rb_eArgError` for shape / rank / axis / value
  problems; `TypeError` (raised for you by `GetCArray`, `NUM2*`) for
  wrong object types; `CADataTypeError` (raised by `ca_check_type`) for
  data_type mismatches you cannot coerce.
- **Messages name the mismatch.** Report what was expected and what was
  received (`"expected 1-D, got %d-D"`), and use
  `ca_type_name[data_type]` for type names.
- **Coerce before you reject.** As in §7.2, prefer `ca_wrap_readonly`
  over a hard data_type check when the input can reasonably be seen as
  your compute type; raise only for the genuinely unusable.
- **Negative-axis normalisation.** If you accept Python-style negative
  axes, normalise (`if (axis < 0) axis += ca->ndim;`) and then
  range-check; `rb_ca_parse_reduce_axes` does this for the multi-axis
  reduction case.

Front-loading validation keeps the interior of the method
raise-light, which in turn keeps the §17.2 cleanup burden small: the
fewer things that can raise after you attach, the less you have to
guard.

---

## 18. Building and packaging

### 18.1 `extconf.rb` ─ finding headers and link info

CArray installs its public header `carray.h` (plus the umbrella of
headers it includes) into the gem's `archdir`, which is on
`$LOAD_PATH`. Your extension does not hunt for it by hand — CArray
ships an mkmf helper that does the locating. In your `extconf.rb`:

```ruby
require 'mkmf'
require 'carray/mkmf'

if have_carray()
  create_makefile("my_ext")
end
```

`have_carray` (from `lib/carray/mkmf.rb`):

1. `require`s `carray`, aborting with a clear message if CArray is not
   installed;
2. scans `$LOAD_PATH` for `carray.h` and runs `dir_config` on the
   directory it finds, so the compiler's include path picks it up;
3. confirms `carray.h` is reachable with `have_header`, and on
   Cygwin/MinGW additionally links `libcarray`.

On the usual Unix / macOS platforms CArray is a Ruby extension that is
already loaded into the process, so there is **no separate shared
library to link against** — the symbols (`ca_attach`, `rb_carray_new`,
…) are resolved at load time from the already-loaded `carray` extension.
That is why `have_carray` only links a library on Cygwin/MinGW, where
the linker needs the import library. Your `Init_my_ext` runs after
`carray` is loaded, so the CArray API is present.

Your source then includes the single umbrella header:

```c
#include "carray.h"
```

which transitively pulls in the kernel-iterator surface, the dispatch
headers, and everything else the public API needs. Do **not** include
`carray_internal.h` — it is deliberately not installed and is not part
of the public contract.

If your extension *also* wraps a third-party numerical library, add
that library's own `dir_config` / `have_library` / `have_header`
checks in the usual mkmf way alongside `have_carray`. CArray's
`carray/mkmf` provides `possible_prefix` / `possible_includes` /
`carray_dir_config` helpers that probe common install prefixes (conda,
Homebrew, MacPorts, `/usr/local`, …) and prefer a `.pc` pkg-config
description when one exists — convenient for hand-rolled scientific
libraries that ship no `.pc` file.

### 18.2 Detecting CArray version / feature presence

Because a downstream extension is compiled *after* `carray` is
`require`d (that happens inside `have_carray`), the reliable place to
check the CArray version is Ruby, at `extconf.rb` time — not a C
preprocessor macro. CArray exposes:

```ruby
CArray::VERSION        # => "3.0.0"      (string)
CArray::VERSION_CODE   # => 300          (integer, major*100 + minor*10 + teeny)
CArray::VERSION_MAJOR  # => 3
CArray::VERSION_MINOR  # => 0
CArray::VERSION_TEENY  # => 0
```

Gate the build on a minimum version in `extconf.rb`:

```ruby
require 'carray/mkmf'

if CArray::VERSION_CODE < 300
  abort "my_ext requires CArray 3.0 or later (found #{CArray::VERSION})"
end

if have_carray()
  create_makefile("my_ext")
end
```

`VERSION_CODE` is the integer form to compare against (`300` for 3.0.0);
it is monotonic across releases, so `>=` comparisons are safe.

For finer-grained *feature* detection — "does this CArray build have
function `foo`?" — use mkmf's `have_func`:

```ruby
have_func("ca_some_new_helper", "carray.h")
```

which compiles a probe and defines `HAVE_CA_SOME_NEW_HELPER` on
success, so your C code can `#ifdef` on it. This is the robust way to
straddle CArray versions that added an API you optionally use, since it
tests the actual symbol rather than inferring from a version number.

Note the version macros (`CA_VERSION`, `CA_VERSION_CODE`, …) live in
`ext/version.h`, which is **not** an installed header — do not rely on
them from a downstream `#include`. The Ruby constants above are the
supported surface.

### 18.3 Versioning compatibility

CArray 3.0 is an intentionally breaking major release; its C API is not
promised to be identical to 2.x, and future majors may again break
source or ABI. A few practical rules for a companion gem:

- **Pin a minimum CArray version** in both your gemspec (as a runtime
  dependency) and `extconf.rb` (as a build-time `VERSION_CODE` check),
  so an incompatible CArray fails early with a clear message rather
  than as a confusing compile error.
- **Recompile against the CArray you run on.** Because symbols resolve
  from the loaded `carray` extension at load time, an extension built
  against one CArray and run against a materially different one can
  break if the API it uses changed. Native gems are per-Ruby /
  per-platform builds already; treat a CArray major bump the same way —
  rebuild.
- **Watch the operation-function table.** The
  `ca_operation_function_t` struct (§3.2) is part of the ABI for any
  extension that *defines a new obj_type*. Adding fields to it is an
  ABI break for such gems (a stale build reads a struct of the wrong
  size). If you define a new kind, rebuild against the CArray you
  target and pin the version tightly. Extensions that only *consume*
  existing kinds are insulated from this — they never touch the table
  directly.
- **Prefer the public, coarse-grained API.** The functions this guide
  documents (`ca_attach`, `ca_wrap_readonly`, `rb_carray_new`, the
  `ca_check_*` family, kernel_iterator) are the stable surface. The
  further you reach into internals (raw view struct tails, unpublished
  helpers, `carray_internal.h`), the more exposed you are to a future
  break. Stay on the public surface and version compatibility stays
  manageable.

When in doubt, match your gem's supported CArray range to what you
actually test against, state it in the gemspec dependency, and let the
`extconf.rb` version gate turn an unsupported combination into a
readable abort rather than a mysterious failure.
