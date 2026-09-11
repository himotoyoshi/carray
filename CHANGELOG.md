# Changelog

Releases from 3.0.0 onward are recorded here. There is no separate NEWS
file: this is where to look for what changed between the version you have
and a newer one. The 1.x history, up to the 2.0.0 release, is in
[CHANGELOG.v1.md](CHANGELOG.v1.md); 2.0.1 went unrecorded.

<!-- Newest first, at both levels: a new release section goes above the
     ones below it, and a new entry goes directly under its own release
     heading -- not at the end of the section. The kind of change is
     carried by the `- Fix:` / `- Change:` / `- New:` that opens the
     entry; there are no per-kind subheadings.

     A section is written newest-first while the release is open, and
     sorted into New, Change, Fix when it closes -- in the same commit
     that drops `(unreleased)`. Within Change, the ones that ask the
     reader to change code come first. It is a reading order rather than
     a classification: where it is not obvious, either place will do.

     An entry says three things and stops: what changed, what to do about
     it (the migration, the replacement, the condition under which nothing
     changes), and what is excluded. It does not say how the code was
     broken, name the internals that were fixed, break down where the
     speed came from, or argue the design -- those belong in the commit
     message. Two to six lines.

     It is written for someone using the library, not someone working on
     it: with no NEWS file, this is what a reader consults before
     upgrading. An entry naming something only a C extension touches says
     so in its opening words.

     Every entry has to read on its own. Entries are looked at one at a
     time and move about within a section, so none may lean on a
     neighbour ("as well", "the producer above") or leave unnamed the
     method, class or keyword it is about. -->

## 3.0.2 (unreleased)

- New: `CArray::Rng` is a random number generator with its own state, which
  `random!`, `randomn!` and `shuffle!` accept as `rng:` alongside a Ruby
  `Random`. `CArray::Rng.new(seed: 4)` seeds one, and a first positional
  argument picks the generator from `CArray::Rng::GENERATORS`, which is
  `:xoshiro256pp` today and is where another would be added. `#random` takes a
  draw in `[0.0, 1.0)` and `#randomn` a standard normal, pairing as
  `CArray#random!` and `#randomn!` do; `#bits` is the raw word a draw came
  from; `#reset` starts the run over. It is not `#rand`, because Ruby's
  `random:` keyword calls `rand(n)` on what it is handed and this takes no
  argument -- a `#rand` here would look usable there and fail on arity.
  Uniform draws carry a full 53-bit mantissa, and a fill through one runs
  about 2.5x faster than through a Ruby `Random`: the draw inlines where a
  call into Ruby's MT19937 cannot. `#state` is the four `int64` cells it
  advances, and `CArray::Rng::SOURCE`, `CArray::Rng::COMMON_SOURCE` and
  `CArray::Rng::DRAW_FUNCTIONS` are the generator's C as text and the entry
  points in it -- the same files this extension compiled -- so another gem
  can paste them and continue a sequence this one started rather
  than reimplement it. It is `Rng` and not `Random` because the two are
  different generators and a `CArray::Random` would shadow `::Random` for
  every bare `Random` written inside `class CArray`. Without `rng:`, or with
  a Ruby `Random`, nothing changes: those still draw through Ruby's MT19937,
  and `randomn!` still fills in pairs there. Through a `CArray::Rng` it fills
  one cell per call instead, so that two fills -- and a kernel drawing after
  one -- are the one sequence; a normal is then two draws with no spare kept,
  which measures the same as the paired form because the transform dominates.

- New: `CArray#factorize` answers `[codes, levels]` in one pass — the distinct
  values in first-appearance order, which is what `unique` answers, and an
  integer array of the receiver's shape indexing them, so `levels[codes[i]]` is
  the cell. It is for a caller who wants the codes as storage: a position to
  scatter into, a key to group by, a dense renumbering of sparse keys.
  `categorize` wraps the same two in a `CACategorical` and hands the vocabulary
  back as a Ruby Array. A masked cell is masked in `codes` and holds the
  exclusion sentinel, as a categorical's storage is. There is no `sort:`,
  because the codes index the levels.

- New: C extensions can read two arrays along the same axis at once.
  `CA_FOR_EACH_FIBER_PAIR` and `CA_FOR_EACH_FIBER_PAIR_MASKED` yield one
  contiguous fiber from each of two sources at the same position, which is
  what a C routine taking two vectors of equal length wants. The masked
  form yields both mask cursors, since whether a cell may be used is a
  question about both fibers. Nothing else changes: the existing macros,
  the iterator engine and every Ruby method are untouched.

- Change: filling part of an array backed by a CAObject or CASource subclass
  reaches the backing in far fewer calls. A whole-array fill takes the
  `fill_block` / `fill_addrs` slots when the subclass defines them, instead of
  one `store_addr` per cell; a selection made through a slice, and a selection
  along an inner axis, arrive as one list rather than one call per cell. Which
  cells are written is unchanged, and a subclass that defines none of the fill
  slots keeps the per-cell path it had.

- Change: the Ruby attach surface is gone from released builds:
  `CArray.attach` / `.attach!`, `CArray#attach` / `#attach!`, and
  `#__attach__` / `#__sync__` / `#__detach__`. It opened an attach window from
  Ruby, and what a block did inside one depended on the spelling -- `v[0] = x`
  reached the array, `v[0..1] = x` could be silently discarded -- with nothing
  in the syntax to say which. Write through the array directly instead.
  `CArray#attached?` is unchanged, and so is the C lifecycle (`ca_attach` /
  `ca_sync` / `ca_detach`) that extensions use.

- Change: an index whose every real axis is a scalar no longer raises when it
  also carries the newaxis sigil. `a[1, :_]` returns a view of just the axes
  `:_` asked for, each of length 1, instead of `IndexError`. It states that
  rank, so to keep an axis rather than drop it, index it with something that
  is not a scalar -- `a[[1], :_]`. Indices with a non-scalar axis are
  unaffected.

- Change: C extensions only. A kernel iterator init that the engine refuses
  now raises instead of returning a code the block macros
  (`CA_FOR_EACH_SLAB`, `CA_FOR_EACH_FIBER` and their variants) discarded.
  An axis that does not exist, or a flag combination a source cannot serve,
  says so. Kernels that want to handle a refusal rather than propagate it
  can call `ca_iter_state_init_l1` / `_l2` directly and read the code.

- Fix: C extensions only. A kernel writing into a view the caller supplied
  now reaches the array. Writes were lost when the destination was a
  CAStack, and when it was a cast, byte-swapped, rolled or tiled view
  iterated along an axis whose fiber is not contiguous; a single-cast view
  iterated that way crashed. Kernels writing into an array they allocated
  themselves were never affected, which is every kernel inside carray.

- Fix: `CArray#each_slab` yields a read-only slab, and writing through it
  raises rather than reaching the array on one axis and being dropped on
  another. Return values from the block instead: `map_slab` collects them
  and `reduce_slab` folds them. To write in place, assign through the array
  itself. Reading the slab, and `map_slab` / `reduce_slab`, are unchanged.

## 3.0.1

- New: `CArray.jit_for`, `CArray.jit_each` and `CArray.jit_map` name a block
  that is compiled rather than run. Compiling needs the carray-jit gem;
  without it they raise `NotImplementedError`. An expression over whole
  arrays wants `CArray.fuse`, which needs no compiler.

- New: every iterator answers `accumulate` beside `sum`; some of them did not.
  It is the same fold kept in the source's own data type, where `sum` answers
  in the type the core promotes to -- a window or tile count over `uint8` cells
  stays one byte wide.

- New: `CArray::CoreExtensions` adds postfix math on `Complex`, so `a[0].tanh`
  reads the way `a.tanh` does. It covers the seventeen functions a complex
  array supports and agrees with the array form exactly, branch cuts and the
  sign of a zero included. Opt in with `using CArray::CoreExtensions`.

- New: `ca_is_stride_family(ca)` in `carray.h`, for a C extension that folds a
  view into `root->ptr + base + sum(idx[k] * strides[k])` itself. True for
  CAStride, CARefer, CABlock, CARepeat, CATranspose, CAFarray and CAField and
  the mask array of each, and for an externally installed view that shares
  their operation table.

- New: `divmod` returns `[quotient, remainder]` element-wise with the quotient
  floored, the pair Ruby's `Integer#divmod` and `Float#divmod` return. The
  quotient keeps the receiver's data type.

- New: two optional CAObject callbacks take a partial fill as a region instead
  of one `store_addr` per cell: `fill_block(starts, counts, steps, val)` for a
  forward per-axis sub-region, `fill_addrs(addrs, val)` otherwise. Defining
  neither keeps the old behaviour. Filling a 1000x1000 region of a 2000x2000
  CAObject: 116 ms to 0.6 ms.

- New: `CAFrame#to_table` renders the frame as an aligned text table, and
  `inspect` / `to_s` sit on it: `p df` summarises the first 8 and last 2 rows,
  `puts df` prints the whole frame. `rows:` caps the printed rows, `precision:`
  rounds float cells for display (default 6), masked cells show as `_`.

- New: `CAFrame#to_time` takes a `CATime::Grid`, positionally or as `unit:`, so
  a netCDF `units` attribute goes in whole. The grid also carries an epoch phase
  the `unit:` / `epoch:` pair cannot -- that pair reads the epoch on the coarse
  grid and loses the time of day. The keyword form is unchanged.

- New: `CATime::Grid` packages the `(unit:, origin:)` pair that `#timesteps`,
  `#snap` and `.from_timesteps` take, so it is built once and passed as one
  value: `t.snap(g, direction: :floor)`, `t.timesteps(g)`, `g.at(k)`. It parses
  and prints the udunits `"<unit> since <instant>"` form, holding a phased
  origin that the keyword pair cannot (`"12 hours since 2017-11-30 09:00"`).
  `CATime#grid` is the grid an array is stored on. Storage is unchanged.

- New: `CATime#snap(grid, direction:)` rounds to a tick grid, the shape
  `CArray#snap` has for numbers. `#floor` / `#ceil` / `#round` are its
  fixed-direction forms; their results and keyword forms are unchanged.

- New: a time element is taken directly as a start or origin literal, so a
  `floor` / `ceil` / `to_unit` answer feeds back into `CArray.time`,
  `time_range`, `time_series`, `CArray#time` and an `origin:`; it used to have
  to go out through `DateTime` and be re-parsed. A `:M` or `:Y` element names
  the first midnight of its granule. What an origin must satisfy is unchanged.

- New: `CArray.time` parses a year-month (`"2019-09"`) and a bare year
  (`"2019"`), so the form a `:M` / `:Y` element prints reads back in. A
  missing finer field names the head of that period.

- Change: `abs`, `abs2` and `arg` on a `cmplx64` array now return `float32`
  instead of `float64` -- the width that type carries its real values in, the
  same one `real` and `imag` already returned. `arg` on a `float32` array
  likewise returns `float32` rather than widening. `cmplx128` and `float64`
  are unchanged, and `arg` on an integer array still gives `float64`. To keep
  the old width, add `.to_type(:float64)`.

- Change: `CArray.fuse` takes the expression rather than the arrays it is
  over -- `CArray.fuse { (a + b) * c }` in place of
  `CArray.fuse(a, b, c) { |x, y, z| (x + y) * z }`. What comes back is the
  expression, so `x = CArray.fuse { ... }` now wants `.to_ca` for an array.
  Where the block's source cannot be read -- an `irb` prompt, inside `eval` --
  write `a.lazy + b.lazy`. `CArray.lazy(*args) { ... }` is gone.

- Change: a lazy expression (`a.lazy + b`, `CArray.fuse`) builds its mask when
  something reads it, rather than when the expression is built. A mask set on
  either operand after the expression was built is now seen; before, only the
  left one was. `root_array` and `ancestors` now stop at a lazy operation
  instead of walking into its left operand. Building a long masked expression
  is also no longer quadratic in the length of the chain.

- Change: the top-level constant `CA_NIL` is now `CArray::UNSPECIFIED`
  (`CA_UNSPECIFIED` in C). It is an internal sentinel for "the caller gave no
  argument", not a value to pass in; `unmask`, `shift(fill_value:)` and
  `window(fill_value:)` behave as before.

- Change: `group_by_category` reductions answer in the data type the core
  reduction promotes the value to, instead of one chosen per reduction. `sum`
  on an integer value now answers in float64 (`accumulate` is the spelling
  that stays in the value's type), and `mean`, `variance` and `median` on an
  object value stay exact. `sum` on a boolean value and `prod` or `mean` on a
  complex one, which raised, now work.

- Change: the `:*` unbound repeat is retired. `a[:*, nil]` raises `IndexError`;
  `CArray#unbound_repeat`, `CAUnboundRepeat` and `insert_axis(repeat: :*)` are
  gone. Use `:_`, which gives the same shape and now stretches on a store as
  well as in an operation. `CArray#broadcast_to` and
  `CArray.meshgrid(sparse: true)` are unaffected.

- Change: a binary operation requires shapes to agree, or to differ only in
  size-1 axes at equal ndim. `(3,2) + (2,3)` and `(3,2) + (6)` raise
  `ArgumentError` where they used to answer in one operand's shape; flatten
  both sides to combine the values in the order they lie. Comparisons, `fma`
  and the lazy forms follow the same rule. Scalars are unaffected, but a
  one-element 1-D array such as `CArray.int32(1)` counts as a shape.

- Change: an assignment requires the shapes to match. `t[] = src` with a
  differently shaped source raises `RuntimeError`; use `src.flatten`. In
  exchange a smaller source is repeated to fit, so `t[] = row[:_, nil, nil]`
  and `t[] = col` (shape `(n,1)`) work where they used to raise. A 1-D side on
  either end still passes, as do shapes differing only in size-1 axes; Ruby
  Arrays and scalars are unchanged.

- Change: `to_ca` on a view derived from a lazy marker returns a new entity
  rather than the view itself -- `a.lazy.shift(1, 0).to_ca`, inside a `fuse`
  block or not. `copy` behaves as before.

- Change: `/` and `%` follow Ruby instead of C. Integer division floors and the
  remainder carries the sign of the divisor; float `%` floors too, float `/` is
  unchanged. For the old behaviour use `fmod`, which now takes integers as well
  as floats.

- Change: `reminder` is removed -- it was IEEE 754 remainder on floats but C `%`
  on integers. Use `fmod` for the truncated remainder. The IEEE form has no
  replacement.

- Change: the result-type override of `CArray#conditional` and
  `CArray.select` is now `data_type:`, spelled the way the rest of the
  library spells it. There is no alias: `dtype:` raises `unknown keyword`.

- Change: a calendar-grid `origin:` given to the bucket-grid methods of a
  `CATime` array -- `timesteps`, `snap`, `floor`, `ceil`, `round`,
  `is_righttime` -- now has to be a month head (the 1st at 00:00); it used to
  drop the day and time silently. A `:Y` tick likewise has to start in
  January. `from_timesteps` already refused an off-grid origin.

- Change: the MemoryView producer emits the format vocabulary
  `ruby/memory_view.h` specifies rather than PEP 3118's, so below 32 bits it
  writes `c` / `C` / `s` / `S` in place of `b` / `B` / `h` / `H`. From 32 bits
  up the two already agreed, and `?`, `Zf` / `Zd`, `T{...}` and `Ns` stay PEP
  3118, which Ruby has no spelling for. The consumer side already accepted
  both, so views produced by 3.0.0 still import.

- Change: multiplying and dividing a `cmplx64` array (`*`, `/`, `rcp`,
  `rcp_mul`) is computed in double and rounded once, so both are correctly
  rounded; the old route could be off by about 1800 units in the last place.
  A product that overflows a float but not a double no longer comes back NaN.
  Division is 4.2-5.3x faster and multiplication 1.3x slower. `+`, `-` and
  every `cmplx128` operation are unchanged.

- Change: element-wise math on a `float32` or `cmplx64` array is computed at
  that width rather than widened and rounded back, so `sqrt`, `exp`, `log`,
  the trigonometric and hyperbolic families, `atan2`, `hypot`, `abs` and `arg`
  are 1.1-3.5x faster there and can move by a bit or two in the last place.
  Complex `log`, `power`, `exp2` and `exp10` are unchanged, as are the
  rounding, min / max, comparison and variance families and the wider types.

- Change: a rolling `sum`, `mean`, `prod`, `min`, `max`, `all` or `any` --
  `a.windows(-1..1).sum` and the like -- over a window up to five cells wide on
  every axis is 2-5x faster, and 1.3-4x over a masked source; `min_count:` and
  `fill_value:` come along. `min`, `max` and `prod` answer exactly as before;
  `sum` and `mean` may differ in the last bits. A wider window, or any other
  reduction, is unchanged.

- Change: `CATime#to_unit` floors to a coarser grid instead of raising, and
  crosses the calendar / fixed-length boundary (`:M` <-> `:D`) through
  civil-date algebra. `:Y` / `:M` -> `:W` still raises.

- Change: `CATimedelta#to_unit` truncates toward zero instead of raising on a
  coarser target. Crossing the calendar boundary still raises.

- Fix: `nextafter` on a `float32` array returned its own input. The step was
  taken in double, and the next double above a float rounds back to that same
  float. It now steps by one float32 ulp.

- Fix: a lazy expression over an object array (`CArray.object`,
  `CA_OBJECT`) returned wrong values, and crashed when materialised
  repeatedly. Affects `to_ca` and `copy` on a lazy view, an eager operation
  with a lazy operand, and a reduction over one. Other data types were never
  affected.

- Fix: reading a concatenated view (`CArray.concat`, `CAFrame.concat`)
  backwards along the concatenated axis -- `m.reverse` and any other negative
  step -- raised IndexError instead of answering.

- Fix: reading a lazy expression (`a.lazy + b`, `CArray.fuse`) with a step
  other than one -- `expr[[0, 3, 2]]`, `expr.reverse` and the like -- returned
  values the expression cannot produce, because its operands were read from
  the wrong cells. Comparisons carried the same fault, `a.lazy > b` and
  one-operand ones such as `a.lazy.is_nan` alike. Contiguous reads were never
  affected.

- Fix: `a.value + b` raised `can not create mask array for the value array`
  when `b` carried a mask. It now propagates `b`'s mask.

- Fix: a rolling window that does not cover the cell it is centred on --
  `windows(1..2)`, the two cells after this one -- was read as if it started at
  the array's edge, so every answer came out shifted by the range's start, and
  `bounds: :truncate` produced anchors whose window did not fit. `windows(1..2)`
  on `[1..8]` now sums to `[5, 7, 9, 11, 13, 15, 8, 0]`. A window that covers
  its anchor, which is every centred one, is unaffected.

- Fix: storing a `Complex` into a `cmplx64` or `cmplx128` array kept the sign
  of a negative zero real part only when the imaginary part was also negative,
  so `Complex(-0.0, 0.0)` came back as `0.0+0.0i`. The sign of a zero picks the
  side of a branch cut, so a value stored this way could be carried to the
  wrong branch. All four sign combinations now round-trip, through element
  assignment and through `to_type`.

- Fix: `sinh`, `cosh`, `tanh`, `asinh`, `acosh` and `atanh` on a complex array
  gave the hyperbolic function of the real part alone: `cmplx128` and
  `cmplx64` arrays came back with `tanh(Re z)` where `ctanh(z)` was meant,
  wrong in both parts, and `acosh` and `atanh` also returned 0 or infinity
  where the true value is finite. They now agree with C99 `complex.h`. Real
  and object arrays were never affected.

- Fix: a C extension reading a view in column-major order -- axes and steps
  reversed against the view's own -- got wrong values from a view with a
  length-1 axis, such as `v[nil, :_]`, `v.reshape(n, 1)` or a one-column slice:
  the first cell repeated, a read out of bounds, or a hang.
  `carray-linalg-accelerate`'s `solve(a, b)` returned `b[0]` repeated for a
  single-column right-hand side.

- Fix: an operation between two views of an array that computes its values --
  a lazy expression such as `(a.lazy + b)`, or a `CAObject` over a file -- no
  longer reads that source one cell at a time. `+`, `fma` and comparisons on
  such a pair now run at the speed of copying each operand first, so the
  `.copy` that worked around it is no longer needed. Single-operand
  operations, copies, region transfers and reductions were already unaffected.

- Fix: views built inside a `CArray.fuse` block stay part of the expression
  instead of dropping out of it, so a stencil written the natural way is fused.
  `[]`, `shift`, `roll`, `flip`/`reverse`, `transpose`/`T`, `reshape`,
  `flatten`, `window`, `diagonal`, `tile` and `refer` keep the chain;
  `unbound_repeat` and `[:*, ...]` deliberately do not.

- Fix: a window or shift over a view parent no longer copies that parent in
  full on every transfer. `a[nil, nil].shift(1, 0)` and friends now read at
  parity with an entity parent and write several times faster.

- Fix: reductions over a bare `.lazy` marker no longer raise. Per-axis forms
  and anything over a masked array failed, so `a.lazy.sum(axis: 0)` raised
  while `a.lazy.sum` worked.

- Fix: `ca_test_flag` / `ca_set_flag` / `ca_unset_flag` in `carray.h`, which
  only a C extension calls, did not parenthesise their flag argument, so
  testing two flags at once was true for every array.

- Fix: a Face no longer hands back its storage bytes through the type casts.
  `as_type`, `fake` and `CArray.wrap_writable` raise; `CArray.wrap_readonly`
  converts as `to_type` does, which also makes `t.eq(o)` and `o.eq(t)` agree.
  Reach the storage explicitly with `t.parent.fake(...)`. Numeric Faces are
  unaffected.

- Fix: `arange` raised `NoMethodError` in every form; it builds the array now.
  Integer arguments count exactly, so a step dividing the span evenly no longer
  picks up an extra element. A zero step or a wrong argument count raises
  `ArgumentError`.

- Fix: `from_timesteps` on a week grid answered Thursdays. The week grid counts
  from the epoch, which is one, so it cannot hold an ISO Monday head; a week
  bucket now answers on the day grid and round-trips against `floor` cell for
  cell. A day-or-finer array keeps the Monday default, a week-stored array its
  own epoch-anchored ticks.

- Fix: a masked cell decided whether a `CATime` conversion fit. The range
  guards took their extremes with the mask stripped, so `to_unit` raised
  `RangeError` over a wide value that was masked out. They now answer UNDEF
  when there is nothing to bound -- an empty array, or every cell masked.

- Fix: `CATimedelta::Element#/` floored a negative duration, so `-30h / 4`
  answered `-8h` where the array form answered `-7h`. A duration is a
  magnitude, so it shrinks toward zero, matching the array form in all four
  sign combinations.

- Fix: `CArray.time` no longer rolls a field that is out of range over into
  another date. `"2019-02-31"` parsed to 2019-03-03, and `"201909"` -- a valid
  YYMMDD to Ruby, 2020-19-09 -- to 2021-07; both now raise.

- Fix: `CATime#to_unit` and `CATimedelta#to_unit` were wrong between two
  resolutions where neither tick is a whole multiple of the other: converting
  3 hours to a `"90 minutes"` grid gave 1 unit rather than 2.

- Fix: importing a MemoryView whose mask is published as `C` or `c` no longer
  fails. The check knew only PEP 3118's `B`, `b` and `?`, so a producer that
  spells a byte in Ruby's format vocabulary was refused.

## 3.0.0

First public release. Earlier versions existed on RubyGems, but the library
was developed for the author's own use; 3.0 is where it is packaged,
documented and tested as something other people can pick up. It is not
source-compatible with 2.0.1.

See [README.md](README.md) for what the library does, and [docs/](docs/)
and [guides/](guides/) for the reference and the guides.

**Requires Ruby 3.0 or later** (3.1 for the MemoryView-backed paths).
