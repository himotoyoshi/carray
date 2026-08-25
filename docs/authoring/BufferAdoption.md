# Buffer adoption (author-facing)

When a C extension already holds a freshly produced data buffer -- an image
decoder's output, a decompressed block, a buffer filled by a third-party
library -- and wants to expose it as a CArray, the naive path is to allocate a
CArray and `memcpy` the bytes in. **Buffer adoption** removes that copy: the
CArray takes ownership of your buffer directly.

```c
CArray  *carray_new_adopt   (int8_t data_type, int8_t ndim, ca_size_t *dim,
                             ca_size_t bytes, char *ptr);
VALUE    rb_carray_new_adopt (int8_t data_type, int8_t ndim, ca_size_t *dim,
                             ca_size_t bytes, char *ptr);
```

`rb_carray_new_adopt` returns a normal CArray entity whose data buffer **is**
`ptr`. No allocation, no copy. The buffer is freed with `xfree()` when the array
is garbage-collected, exactly as for any entity's data.

## The contract

The caller transfers ownership of `ptr`. For that to be safe:

- **`ptr` must be `ruby_xmalloc()`'d.** The entity is freed with `xfree()`, so a
  buffer allocated with libc `malloc` (or any other allocator) would be a
  mismatch. If the buffer comes from a library that uses its own allocator,
  either point that library's allocator at Ruby's (see the example) or fall back
  to `rb_carray_new` + `memcpy`.
- **`ptr` must be at least `elements * bytes` long** for the given
  `data_type` / `dim` (`bytes` is the element width; pass `0` for fixed-width
  numeric types, non-zero only for `CA_FIXLEN`).
- **`data_type` must not be `CA_OBJECT`.** A raw buffer holds no valid `VALUE`s,
  and the GC would walk them during marking. `rb_carray_new_adopt` raises on
  `CA_OBJECT`. Adoption is for numeric / fixlen data.
- **`ptr` must not be `NULL`** (raises). For an empty array, use `rb_carray_new`.

After the call, do **not** free `ptr` yourself and do not keep using it as if you
still owned it -- the CArray does.

## Adopt vs. wrap vs. copy

CArray already had two ways to build an array around memory. Adoption fills the
gap between them.

| | Who allocates | Who frees | Use when |
|---|---|---|---|
| `rb_carray_new` + `memcpy` | CArray | CArray (`xfree`) | the source is not yours to keep, or its allocator differs |
| `rb_ca_wrap_new` (CAWrap) | someone else | **nobody** (borrowed) | another live object owns the memory and outlives the view (a Numo array, an mmap region, a `String`) |
| `rb_carray_new_adopt` | **you** (`ruby_xmalloc`) | CArray (`xfree`) | you hold a fresh buffer nobody else manages and want no copy |

The distinction from `CAWrap` is ownership: a wrap **borrows** memory it never
frees and relies on the owner staying alive; adoption **takes** memory and frees
it. Do not reach for a wrap to avoid a copy of a buffer that has no other owner
-- that leaks (nobody frees it). Adopt it instead.

## Example: adopting a decoder's output

A decoder that allocates its result buffer through Ruby's allocator can hand it
straight to CArray. `stb_image` lets you redirect its allocations:

```c
#define STBI_MALLOC(sz)      ruby_xmalloc(sz)
#define STBI_REALLOC(p, sz)  ruby_xrealloc((p), (sz))
#define STBI_FREE(p)         ruby_xfree(p)
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

/* ... inside a method ... */
int w, h, ch;
unsigned char *data = stbi_load(path, &w, &h, &ch, 0);   /* ruby_xmalloc'd */
if ( data == NULL ) {
    rb_raise(rb_eRuntimeError, "decode failed: %s", stbi_failure_reason());
}
ca_size_t dim[3] = { h, w, ch };
/* No copy: CArray owns `data`, frees it with xfree at GC. */
return rb_carray_new_adopt(CA_UINT8, 3, dim, 0, (char *) data);
```

Because `STBI_MALLOC` is `ruby_xmalloc`, the decoded buffer already satisfies the
allocator contract, so the pixel bytes never get copied. The
[carray-stbimage](https://github.com/himotoyoshi/carray-stbimage) gem is built
this way.

## When to prefer a copy instead

Adoption is worth it for large payloads (a full image, a big block) where the
copy and the transient double buffer are real cost. For small buffers, or when
the producing library will not let you swap its allocator, `rb_carray_new` +
`memcpy` (or `ca_copy_data` for a strided source) is simpler and just as correct.

## Implementation note

`carray_new_adopt` routes through the same `carray_setup_i` chokepoint as
`carray_new`, taking the branch that skips allocation and sets `ca->ptr` to the
caller's buffer while still producing an owning `CA_OBJ_ARRAY` entity (not a
`CA_OBJ_ARRAY_WRAP`). This keeps the free path (`free_carray` -> `xfree(ca->ptr)`)
unchanged: an adopted entity carries a standalone `ptr` and is freed like any
other entity.
