# Changelog

Releases from 3.0.0 onward are recorded here. For the pre-3.0 history
(1.4.x through 2.0.1) see [CHANGELOG.1.0-2.0.md](CHANGELOG.1.0-2.0.md).

<!-- Newest first, at both levels: a new release section goes above the
     ones below it, and a new entry goes directly under its own release
     heading -- not at the end of the section. The kind of change is
     carried by the `- Fix:` / `- Change:` / `- New:` that opens the
     entry; there are no per-kind subheadings. -->

## 3.0.1 (unreleased)

- New: `CArray.per_cell` and `CArray.per_element`, the surface an array
  algorithm is written on -- an index space for the first, so that a cell may
  reach its neighbours, an element-wise expression for the second. Both run the
  block as ordinary Ruby here, so code written against them runs wherever CArray
  does; installing the carray-jit gem replaces both with versions that compile
  the block to C. The subset a block has to stay inside to compile is documented
  with the methods, in `carray/jit_fallback.rb`.

- Change: `group_by_category` reductions now answer in the data type the core
  reduction promotes the value to, instead of choosing one per reduction. `sum`
  on an integer value answers in float64 (`accumulate` is the spelling that
  stays in the value's type), and the rest follow the core for a boolean,
  complex or object value -- among them `mean`, `variance` and `median` on an
  object value, which stay exact instead of passing through float64, so a
  payload of `Rational` keeps its denominators. This also fixes three payloads
  that could not be reduced at all: `sum` on a boolean value, `prod` on a
  complex one and `mean` on a complex one all raised.

- New: every iterator now answers `accumulate` beside `sum` -- the same
  per-piece fold, kept in the source's own data type and wrapping at its width,
  where `sum` answers in the type the core promotes to (float64 for an integer
  source). A tile or window count over `uint8` cells stays one byte wide instead
  of eight. For a category or a coordinate group it is also the exact spelling:
  `sum` folds those in float64, so an integer payload wider than float64's
  mantissa loses its low bits. A boolean source accumulates as XOR parity, as it
  does in the core.

- Fix: a rolling window that does not cover the cell it is centred on --
  `windows(1..2)`, the two cells after this one -- was read as if it started at
  the array's edge, so every answer came out shifted by the range's start, and
  `bounds: :truncate` produced anchors whose window did not fit. `windows(1..2)`
  on `[1..8]` now sums to `[5, 7, 9, 11, 13, 15, 8, 0]`, the last anchor having
  nothing after it. A window that covers its anchor, which is every centred one,
  is unaffected.

- Change: a rolling `sum`, `mean`, `prod`, `min`, `max`, `all` or `any` over a
  small window is now 2-5x faster. `windows(-1..1, -1..1).sum` folded each
  window separately, once per output cell, and paid the same setup for a
  nine-cell window as for a large one; for windows up to five cells wide on
  every axis it now accumulates one window offset at a time across the whole
  array instead. `min_count:` and `fill_value:` come along, since the count a
  window folded is known without folding it, and so does a masked source
  (1.3-4x). The answers are unchanged for `min`, `max` and `prod`; `sum` and
  `mean` may differ in the last bits, as reductions always may. It holds one
  more buffer while it works -- the window's own, in the type the result is
  accumulated in -- which for a `sum` over a large byte array is more than the
  previous path held. A wider window, or any other reduction, takes the
  previous path unchanged.

- Fix: storing a `Complex` into a `cmplx64` or `cmplx128` array kept the sign
  of a negative zero real part only when the imaginary part was also negative;
  `Complex(-0.0, 0.0)` came back as `0.0+0.0i`. The sign of a zero selects the
  side of a branch cut (`log(-1+0i)` is `+pi*i`, `log(-1-0i)` is `-pi*i`), so a
  value stored this way could be carried to the wrong branch. All four sign
  combinations now round-trip, through element assignment and through
  `to_type`.

- New: `CArray::CoreExtensions` adds postfix math on `Complex`, so an
  expression written for a complex array still reads for a single cell taken
  out of it: `a[0].tanh` now works alongside `a.tanh`. Covers the fifteen
  functions a complex array supports (`sqrt` `exp` `log` `sin` `cos` `tan`
  `asin` `acos` `atan` `sinh` `cosh` `tanh` `asinh` `acosh` `atanh`) plus
  `square` and `rsqrt`, and agrees with the array form exactly, branch cuts
  and the sign of a zero included. `log10`, `expm1` and `log1p` are not
  defined on `Complex`, matching the array form, which raises
  `CArray::DataTypeError` for them. The refinement still has to be opted into
  with `using CArray::CoreExtensions`.

- Fix: `sinh`, `cosh`, `tanh`, `asinh`, `acosh` and `atanh` on a complex array
  gave the hyperbolic function of the real part alone. The kernel called the
  real-typed C function, which drops the imaginary part of its argument, so
  `cmplx128` and `cmplx64` arrays came back with `tanh(Re z)` where `ctanh(z)`
  was meant -- wrong in both parts, and `acosh` and `atanh` also returned 0 or
  infinity where the true value is finite. They now agree with C99
  `complex.h`. Real and object arrays were never affected.

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

- Change: assignment matches shapes as well. `t[] = src` with a differently
  shaped source raises `RuntimeError`; use `src.flatten`. In exchange a
  smaller source is repeated to fit, so `t[] = row[:_, nil, nil]` and
  `t[] = col` (shape `(n,1)`) work where they used to raise; the destination
  is never stretched. A 1-D side on either end still passes, as do shapes
  differing only in size-1 axes. Ruby Arrays and scalars are unchanged. The
  in-place operators (`add!` and its siblings) follow the assignment rule.

- New: `ca_is_stride_family(ca)` in `carray.h`, for C extensions that want to
  fold a view into `root->ptr + base + sum(idx[k] * strides[k])` themselves.
  It is the guard `ca_stride_compose_to_root` needs: true for CAStride,
  CARefer, CABlock, CARepeat, CATranspose, CAFarray and CAField, plus the
  mask array of each. Membership follows the operation table an `obj_type`
  was installed with, so an externally installed view sharing that table is
  recognised too.

- Fix: a region asked for in column-major order -- axes and steps reversed
  against the view's own -- came back wrong from a view with a length-1 axis.
  An `(n, 1)` view (`v[nil, :_]`, `v.reshape(n, 1)`, a one-column slice) has
  the same step on both axes, so the reversed request looked axis-aligned and
  was composed onto the length-1 axis, whose parent step is 0. `CAStride`,
  `CABlock`, `CATranspose`, `CAWindow` and `CATile` delivered the first cell n
  times with nothing raised; `CAGrid` read out of bounds and crashed; `CARoll`
  spun; a `CAObject` was handed a region outside its own axes. Reached from a
  Fortran-LAPACK backend gathering its operands -- `carray-linalg-accelerate`'s
  `solve(a, b)` returned `b[0]` repeated for a single-column right-hand side.

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

- Change: `to_ca` on a view derived from a lazy marker returns a new entity
  rather than the view itself -- `a.lazy.shift(1, 0).to_ca`, inside a `fuse`
  block or not. `copy` behaves as before.

- Fix: a window or shift over a view parent no longer copies that parent in
  full on every transfer. `a[nil, nil].shift(1, 0)` and friends now read at
  parity with an entity parent and write several times faster.

- Fix: reductions over a bare `.lazy` marker no longer raise. Per-axis forms
  and anything over a masked array failed, so `a.lazy.sum(axis: 0)` raised
  while `a.lazy.sum` worked.

- Fix: `ca_test_flag` / `ca_set_flag` / `ca_unset_flag` in `carray.h` did not
  parenthesise their flag argument, so testing two flags at once was true for
  every array. C extensions only.

- Change: `/` and `%` follow Ruby instead of C. Integer division floors and the
  remainder carries the sign of the divisor; float `%` floors too, float `/` is
  unchanged. For the old behaviour use `fmod`, which now takes integers as well
  as floats.

- Change: `reminder` is removed -- it was IEEE 754 remainder on floats but C `%`
  on integers. Use `fmod` for the truncated remainder. The IEEE form has no
  replacement.

- New: `divmod` returns `[quotient, remainder]` element-wise with the quotient
  floored, the pair Ruby's `Integer#divmod` and `Float#divmod` return. The
  quotient keeps the receiver's data type.

- New: two optional CAObject callbacks take a partial fill as a region instead
  of one `store_addr` per cell: `fill_block(starts, counts, steps, val)` for a
  forward per-axis sub-region, `fill_addrs(addrs, val)` otherwise. Defining
  neither keeps the old behaviour. Filling a 1000x1000 region of a 2000x2000
  CAObject: 116 ms to 0.6 ms.

- Fix: a Face no longer hands back its storage bytes through the type casts.
  `as_type`, `fake` and `CArray.wrap_writable` raise; `CArray.wrap_readonly`
  converts as `to_type` does, which also makes `t.eq(o)` and `o.eq(t)` agree.
  Reach the storage explicitly with `t.parent.fake(...)`. Numeric Faces are
  unaffected.

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

- Fix: `arange` raised `NoMethodError` in every form; it builds the array now.
  Integer arguments count exactly, so a step dividing the span evenly no longer
  picks up an extra element. A zero step or a wrong argument count raises
  `ArgumentError`.

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

- Change: the MemoryView producer emits the format vocabulary
  `ruby/memory_view.h` specifies rather than PEP 3118's, so below 32 bits it
  writes `c` / `C` / `s` / `S` in place of `b` / `B` / `h` / `H`. From 32 bits
  up the two already agreed, and `?`, `Zf` / `Zd`, `T{...}` and `Ns` stay PEP
  3118, which Ruby has no spelling for. The consumer side already accepted
  both, so views produced by 3.0.0 still import. Supersedes the table in
  [MemoryViewFormat.md](docs/interop/MemoryViewFormat.md).

- Fix: a mask published in Ruby's format vocabulary (`C` / `c`) is accepted on
  import. The check only knew PEP 3118's `B` / `b` / `?`, so it refused the
  masks the producer above now writes.

## 3.0.0 — 2026-08-25

First public release. Earlier versions existed on RubyGems, but the library
was developed for the author's own use; 3.0 is where it is packaged,
documented and tested as something other people can pick up. It is not
source-compatible with 2.0.1.

See [README.md](README.md) for what the library does, and [docs/](docs/)
and [guides/](guides/) for the reference and the guides.

**Requires Ruby 3.0 or later** (3.1 for the MemoryView-backed paths).
