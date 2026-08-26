# Changelog

Releases from 3.0.0 onward are recorded here. For the pre-3.0 history
(1.4.x through 2.0.1) see [NEWS.md](NEWS.md).

## 3.0.1 (unreleased)

- Fix: the MemoryView producer published format strings outside the
  vocabulary `ruby/memory_view.h` specifies. Below 32 bits CArray emitted
  PEP 3118's spelling (`b` / `B` / `h` / `H`), which Ruby's own parser has
  no reading for, so no generic Ruby consumer could read elements —
  `Fiddle::MemoryView.new(CArray.int16(3))[0]` raised. It now emits
  `c` / `C` / `s` / `S`; from 32 bits up the two vocabularies already
  agreed. `?`, `Zf` / `Zd`, `T{...}` bodies and the `Ns` form stay PEP
  3118, which Ruby has no spelling for. The consumer side is unchanged —
  it already accepted both — so views produced by 3.0.0 still import.
  This supersedes the producer table documented in 3.0.0's
  [MemoryViewFormat.md](docs/interop/MemoryViewFormat.md).

- Fix: the mask-format check rejected a uint8 mask published as `C`.

## 3.0.0 — 2026-08-25

First public release. Earlier versions existed on RubyGems, but the library
was developed for the author's own use; 3.0 is where it is packaged,
documented and tested as something other people can pick up. It is not
source-compatible with 2.0.1.

See [README.md](README.md) for what the library does, and [docs/](docs/)
and [guides/](guides/) for the reference and the guides.

**Requires Ruby 3.0 or later** (3.1 for the MemoryView-backed paths).
