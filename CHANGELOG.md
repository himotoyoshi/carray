# Changelog

Releases from 3.0.0 onward are recorded here. For the pre-3.0 history
(1.4.x through 2.0.1) see [NEWS.md](NEWS.md).

## 3.0.1 (unreleased)

- Change: the result-type override of `CArray#conditional` and
  `CArray.select` is now `data_type:`, spelled the way the rest of the
  library spells it. There is no alias: `dtype:` raises `unknown keyword`.

- Fix: a field out of range no longer rolls over into another date.
  `"2019-02-31"` parsed to 2019-03-03, and `"201909"` -- a valid YYMMDD to
  Ruby, 2020-19-09 -- to 2021-07; both now raise.

- New: a year-month (`"2019-09"`) and a bare year (`"2019"`) parse, so the
  form a `:M` / `:Y` element prints reads back in. A missing finer field
  names the head of that period.

- Change: a calendar-grid `origin:` now has to be a month head (the 1st at
  00:00); it used to drop the day and time silently. A `:Y` tick likewise has
  to start in January. `from_timesteps` already refused an off-grid origin.

- Change: `CATime#to_unit` floors to a coarser grid instead of raising, and
  crosses the calendar / fixed-length boundary (`:M` <-> `:D`) through
  civil-date algebra. `:Y` / `:M` -> `:W` still raises.

- Change: `CATimedelta#to_unit` truncates toward zero instead of raising on a
  coarser target. Crossing the calendar boundary still raises.

- Fix: converting between two resolutions where neither tick is a whole
  multiple of the other (`"90 minutes"` and `:h`) dropped the ratio numerator
  and gave a wrong value.

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
