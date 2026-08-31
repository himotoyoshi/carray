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
cd samples/c-extensions/<name>
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
