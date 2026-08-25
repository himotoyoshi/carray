# CArray samples

Worked examples of what CArray can do. Each sample is a standalone Ruby
file: `require "carray"`, then pull the sample in with `require_relative`.

## Layout

- **`face/`** — Face subclasses (semantic-type views; see
  [CAFace.md](../docs/topics/CAFace.md))
  - `ca_circular.rb` — angles (a circular range plus circular statistics)
- **`caobject/`** — callback-based views on `CAObject`, without Face mode
  - `link.rb` / `nested.rb` / `pack.rb` / `recurrence.rb` — a collection of
    patterns
  - `iterator_array.rb` — **legacy; does not run on 3.0.** A concept-only
    artifact of the old helper that wrapped an iterator to look like a
    CArray through `CAIterator#ca`. `#ca` itself was retired in 3.0, so some
    of the API in the sample no longer exists. Kept for the pattern.
- **`c-extensions/`** — complete extension examples that use CArray's C
  author surface (`CA_FOR_EACH_ELEMENT`, `CA_WITH_BUFFER`, the
  `ca_call_cfunc_*_r` family). Each builds and runs as its own extension,
  and they double as regression fixtures for
  `spec/spec_ai/test_sweep_*_smoke.rb`. See
  [`c-extensions/README.md`](c-extensions/README.md).
- **`io/`** — I/O helpers that shell out to an external command
  - `imagemagick.rb` — `CArray.load_by_magick` / `#save_by_magick` /
    `#display_by_magick`, reading and writing images through the ImageMagick
    CLI (`identify`, `stream`, `magick convert`, `display`). It used to be
    auto-wired; with `rmagick` available again it is opt-in, so pull it in
    with `require_relative` if you want it. Arguments go through
    `Shellwords.escape` and parsing through `YAML.safe_load`.

## What these are, and are not

- **Not part of the library.** Nothing here is loaded from `lib/carray/`.
  Copy from it, or take it as a starting point.
- **They run.** Each sample works as written; the quality bar is close to a
  test.
- **They teach.** The docs cross-reference them, and they are the reference
  to read before writing a Face or a view of your own.
- **They are where extensions grow up.** A useful type that does not earn a
  place in the library can live here first.
