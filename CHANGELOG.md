# Changelog

Releases from 3.0.0 onward are recorded here. For the pre-3.0 history
(1.4.x through 2.0.1) see [NEWS.md](NEWS.md).

<!-- Newest first, at both levels: a new release section goes above the
     ones below it, and a new entry goes directly under its own release
     heading -- not at the end of the section. The kind of change is
     carried by the `- Fix:` / `- Change:` / `- New:` that opens the
     entry; there are no per-kind subheadings. -->

## 3.0.1 (unreleased)

- Fix: a view built inside a `CArray.fuse` block stays part of the expression.
  The block hands you a lazy marker, and `v.shift(1, 0)` used to build the
  shift on top of it, burying the marker -- so the shift was not a lazy
  operand, everything after it evaluated eagerly, and the marker underneath
  turned each transfer into a whole-array materialise. Writing the guide's own
  finite-difference stencil the natural way was several times slower than
  writing it eagerly, with no better spelling available inside the block. The
  wrapper now stays on top, as it already did for Face: `[]`, `shift`, `roll`,
  `flip`/`reverse`, `transpose`/`T`, `reshape`, `flatten`, `window`,
  `diagonal`, `tile` and `refer` all keep the chain. `unbound_repeat` (and
  `[:*, ...]`) deliberately does not -- its extent stays open until an operand
  binds it, and a wrapper would fix the shape too early.

- Change: `to_ca` on a view derived from a lazy marker now returns a new
  entity rather than the view itself. This follows from the fix above -- a
  data view returns self from `to_ca` while a lazy view evaluates -- and
  applies wherever the marker came from, not only inside a `fuse` block:
  `a.lazy.shift(1, 0).to_ca` is affected as much as the block form. Use `copy`
  if you want a fresh entity either way.

- Fix: a window or shift over an unattached parent no longer duplicates the
  whole parent on every transfer. The transfer slots asked whether the parent
  had a pointer at that moment rather than whether it had memory to lend, so
  an ordinary `a[nil, nil].shift(1, 0)` copied the array once to read it and
  twice to write it. Reads over a block, refer, transpose chain or lazy marker
  are now at parity with an entity parent, and writes are several times faster.

- Fix: reductions over a bare `.lazy` marker no longer raise. Per-axis forms
  and anything over a masked array reported `kernel_iterator init failed
  rc=1`, so `a.lazy.sum(axis: 0)` and `CArray.fuse(a) { |v| v.mean(axis: 0) }`
  failed while `a.lazy.sum` worked. The kernel entry now sees through the
  marker to the array underneath.

- Fix: `ca_test_flag` did not parenthesise its argument, so testing two flags
  at once was true for every array. No caller had passed a compound flag
  before. `ca_set_flag` and `ca_unset_flag` had the same shape of bug.


- Change: `/` and `%` follow Ruby. Integer division floors toward -inf and the
  remainder carries the sign of the divisor, so `(a / b) * b + a % b == a` holds
  for every combination of signs; float `%` floors as well, while float `/` stays
  true division. Both had followed C instead -- truncate toward zero, remainder
  signed like the dividend -- so `((x - xc + 0.5) % 1.0) - 0.5`, the usual way to
  fold a coordinate into one period, quietly left the fold range wherever the
  operand went negative. The data types had also disagreed among themselves:
  object arrays delegate to Ruby and were already flooring, so the same `%` gave
  two answers depending on the data type it ran on. C's pair remains available as
  `fmod`, which now takes integer arrays as well as floats.

- Change: `reminder` is removed. It was IEEE 754 remainder on floats but C `%` on
  integers -- two different operations under one name -- and the spelling of the
  name it aimed at, `remainder`, means the floored `%` in NumPy. Use `fmod` for a
  truncated remainder. The IEEE form has no replacement: it was reachable on
  floats only, and building it needs round-half-to-even, which `round` is not.

- New: `divmod` returns `[quotient, remainder]` element-wise with the quotient
  floored, the pair Ruby's `Integer#divmod` and `Float#divmod` return. The
  quotient keeps the receiver's data type.

- New: a CAObject can take a partial fill as a region. `fill_data` carries no
  region and can only say "fill everything I cover", so writing one value into
  part of a CAObject had nowhere to go but one `store_addr` per cell -- a
  1000x1000 region meant a million Ruby calls. Two optional callbacks now take
  the region instead: `fill_block(starts, counts, steps, val)` when it is a
  forward per-axis sub-region of self, `fill_addrs(addrs, val)` when it is not.
  Defining neither leaves the old behaviour unchanged. The same two slots are
  delegated to the parent by every Face (CATime, CATimedelta, CAString,
  CAConstString, CAFixlenString, CARecord), which had been falling to the
  per-cell default as well even when the parent could take the whole region at
  once. Measured on a 2000x2000 CAObject filling a 1000x1000 region: 116 ms to
  0.6 ms.

- Fix: a Face no longer hands back its storage bytes through the view side of
  the type casts. `as_type`, `fake` and `CArray.wrap_writable` raise instead of
  reinterpreting the storage a surface exists to hide, and `CArray.wrap_readonly`
  -- which already returns entities for its non-CArray inputs -- answers with
  the conversion `to_type` performs: the surface values for `:object`, the
  Face's own `#to_numeric` for a numeric type. The eager `to_type` had made
  these judgements all along; only the view side was missing them, so
  `t.fake(:object)` gave `"\vM\x00..."` where `t.to_type(:object)` gave
  `CATime::Element`s. Because operand coercion goes through `wrap_readonly`,
  the same comparison used to answer differently depending on which side the
  Face was on -- `t.eq(o)` refused loudly while `o.eq(t)` silently compared
  byte strings. The storage stays reachable, spelled out: `t.parent.fake(...)`.
  A Numeric Face, whose surface is its storage, is unaffected.

- New: `CAFrame#to_table` renders the frame as an aligned text table, and
  `inspect` / `to_s` sit on it: `p df` is the summary line over the first 8 and
  last 2 rows, `puts df` is the whole frame. Masked cells show as `_`, N-D
  columns show each row's slice, column widths are counted in terminal cells so
  CJK names stay square, and float cells are rounded for display (`precision:`,
  default 6). `rows:` caps the printed rows and the elided middle is a `:` row.

- New: `CAFrame#to_time` takes a `CATime::Grid`, positionally or as `unit:`,
  instead of the `unit:` / `epoch:` pair, so a netCDF `units` attribute goes
  in without being taken apart. The grid form also carries an epoch phase the
  keyword form cannot: `unit: :D, epoch: "1980-01-01 12:00"` reads the epoch
  on the day grid and loses the time of day, while
  `CATime::Grid.parse("days since 1980-01-01 12:00")` resolves the finer
  storage that holds it. The keyword form is unchanged.

- New: `CATime::Grid` names the `(unit:, origin:)` pair that `#timesteps`,
  `#snap` and `.from_timesteps` already take -- a tick resolution and the
  instant tick 0 starts at -- so it is built once and passed as one value:
  `t.snap(g, direction: :floor)`, `t.timesteps(g)`, `g.at(k)`. Storage is
  unchanged (epoch-anchored int64); the grid reifies a calling convention.
  It reads and writes the `"<unit> since <instant>"` form -- udunits'
  `since` / `after` / `from` / `ref` / `@` on input, `since` on output --
  and resolves the storage resolution that holds a phased origin exactly,
  so `"12 hours since 2017-11-30 09:00"` round-trips where the bare
  keyword form cannot hold the phase. `CATime#grid` is the grid an array
  is stored on, which is what the `unit:` default has always meant.

- Change: `CATime#floor` / `#ceil` / `#round` are `CATime#snap` with
  `direction:` fixed, the shape `CArray#snap` already had for numbers.
  The three shared a prologue and differed in one expression; they are one
  method now. Results are unchanged, and so are the keyword forms of all
  six timestep methods.

- Fix: `arange` ended in a call to a method that does not exist, so every
  form raised `NoMethodError` -- `CArray.arange(5)`, `CArray::Int32.arange(0,
  10, 2)`, all of them. It builds the array now. Integer arguments count
  exactly, so a step that divides the span evenly does not pick up an extra
  element from float rounding; a zero step and a wrong argument count raise
  `ArgumentError` rather than reaching the count arithmetic.

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
