# CArray C extension examples

Standalone, runnable examples that show how to write a Ruby C extension
that uses CArray's public author surface (= the sweep author surface
families; see `guides/devel/10_author_surface_overview.md`).

Each subdirectory is a complete ext (= `extconf.rb` + `.c` + `example.rb`)
that an external ext author can copy as a starting point.  They compile
against `carray.h` and resolve CArray's public symbols at load time from
the already-loaded `carray_ext.bundle`, exactly the way a real consumer
ext does.

> **Test mirror.** Each `.c` here is mirrored byte-for-byte as a spec_ai
> regression fixture under `spec_ai/ext_<name>_smoke/` so the test suite
> owns its own build and never depends on this directory.  These samples
> are the documentation copy; the spec_ai copy is the tested copy.  Edit
> both when you change one (`rake build_author_surface_smoke` rebuilds the
> fixtures).

## Build & run

Per example:

```sh
cd examples/c-extensions/<name>
ruby extconf.rb && make
ruby example.rb
```

Or build all at once from the repo root:

```sh
rake build_c_extension_examples
```

The regression tests in `spec_ai/test_sweep_*_smoke.rb` reuse the same
bundles, so `rake spec_ai` pins their behaviour automatically.

## Examples

### `per_element/` — `CA_FOR_EACH_ELEMENT` macro family

Five iteration forms covering the cell-wise idioms:

| macro | use |
|---|---|
| `CA_FOR_EACH_ELEMENT`             | read-only, no mask |
| `CA_FOR_EACH_ELEMENT_MASKED`      | read-only with mask handling |
| `CA_FOR_EACH_ELEMENT_INOUT`       | map input → output |
| `CA_FOR_EACH_ELEMENT_INOUT_MASKED`| map with mask propagation |
| `CA_FOR_EACH_ELEMENT_OUT`         | fill output only |

### `with_buffer/` — `CA_WITH_BUFFER` / `rb_ca_call_with_buffer`

Scoped attach/sync/detach for direct pointer access into a whole view.
Macro form (`CA_WITH_BUFFER` / `CA_WITH_BUFFER_WRITABLE`) is convenient for
short kernels; the function form (`rb_ca_call_with_buffer`) adds `rb_ensure`
protection so the view detaches cleanly even if the body raises.

### `cfunc_r/` — `ca_call_cfunc_*_r` (reentrant cfunc family)

The `_r` variants thread a `void *userdata` pointer to every per-cell
callback, replacing file-static / global plumbing.  Idiomatic for kernels
that carry outer state (= configurable scales, running counters,
PROJ-style transformations).

### `cslab/` — `ca_call_cslab_*` / `ca_call_cslab_*_r` (chunked slab family)

The chunked counterpart of `cfunc`.  Where `ca_call_cfunc_N` hands the
author one cell, `ca_call_cslab_N` hands it one chunk: `base` / `stride`
per operand, a cell count, and the chunk's slice of the iteration mask.
The arity does not appear in the callback signature — the operands arrive
through `base` — so one typedef (`ca_cslab_t` / `ca_cslab_r_t`) serves
every arity.

Two things follow, and they are the same thing seen from two sides:

- **memory** — a non-alias INPUT is re-gathered into a ~32KB arena scratch
  per chunk rather than materialised whole, so the input memory peak stops
  scaling with the operand.  `cfunc` is the whole-buffer caller
  (`ca_sweep_acquire` `xmalloc`s `elements * bytes` per non-alias INPUT).
- **speed** — the indirect call is paid once per chunk instead of once per
  cell, so the author's inner loop is one the compiler can vectorise.
  Measured on `out = a + b * 2.0` over 4M doubles with entity operands:
  0.32 ns/element against 0.99 for the per-cell form, and 1.69 for the
  array expression.

A masked cell is the author's to skip: a slab cannot leave a hole, so the
engine hands the mask over rather than skipping the cell for you.

`ca_call_cslab_M_N` / `_r` are the typed dispatchers, the same convenience
the cfunc family has: declare the data types the callback works in and get
a freshly allocated output back, instead of supplying one and matching
dtypes by hand.  This is where chunking pays most, and not by coincidence
— coercion is what the layer is for, and `rb_ca_wrap_readonly` implements
it as a lazy readonly cast view, which is never attach-alias.  Declaring
`CA_DOUBLE` over an int32 array is therefore the ordinary use of the typed
layer *and* exactly the operand kind the whole-buffer path copies whole:
measured over 4M cells, 4.0 ms chunked against 9.2 ms per-cell, with a
32KB scratch instead of a 32MB converted copy.

`example.rb` also prints which INPUT kinds actually take the gather path,
and what that costs.  It is not a uniform win — a `reverse` view is
cheaper to move in one `ca_xfer_all` than in 977 `ca_xfer_stride` calls,
so it runs slower chunked, while a gather view runs three times faster
chunked (the scratch stays hot).  Chunking buys a bounded memory peak; it
buys speed only where the per-chunk gather is not the dominant cost.

## Why these live outside `ext/`

The macros and helpers demonstrated here have **no internal consumers**
inside CArray itself — they exist solely as the public author surface
for third-party ext authors.  Keeping the examples outside `ext/` makes
them:

- **discoverable** as documentation (= a place to read, not a file
  buried under `ext/`)
- **realistic** as test fixtures (= compiled in the same position an
  external consumer would compile)
- **decoupled** from the main bundle (= no `#ifdef CARRAY_DEV_BUILD`
  cruft inside `ext/`, no test-only code in release binaries)
