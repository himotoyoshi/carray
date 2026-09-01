# Changelog

Releases from 3.0.0 onward are recorded here. For the pre-3.0 history
(1.4.x through 2.0.1) see [CHANGELOG.1.0-2.0.md](CHANGELOG.1.0-2.0.md).

<!-- Newest first, at both levels: a new release section goes above the
     ones below it, and a new entry goes directly under its own release
     heading -- not at the end of the section. The kind of change is
     carried by the `- Fix:` / `- Change:` / `- New:` that opens the
     entry; there are no per-kind subheadings. -->

## 3.0.1 (unreleased)

- Change: the `:*` unbound repeat is retired. `a[:*, nil]` now raises
  `IndexError`, and `CArray#unbound_repeat`, the `CAUnboundRepeat` class and
  `insert_axis(repeat: :*)` are gone. Write `:_` instead: it produces the same
  shape, and a size-1 axis now stretches on a store as well as in an operation,
  which is what `:*` was for. `CArray#broadcast_to` is unaffected (the
  `broadcast_to` that goes with `:*` was an alias on the retired class).
  `CArray.meshgrid(sparse: true)` returns the same shapes as before.

- Change: a binary operation refuses operands it cannot bring to one shape.
  `(3,2) + (2,3)` used to answer in the left operand's shape and `(6) + (3,2)`
  in the right's, so the result depended on the order the operands were
  written; both now raise `ArgumentError`. Shapes must agree, or differ only
  in size-1 axes at equal ndim. To combine the values in the order they lie,
  flatten both sides: `a.flatten + b.flatten`. Comparisons, `fma` and the lazy
  forms follow the same rule. Scalars are unaffected. A one-element 1-D array
  such as `CArray.int32(1)` states a shape and is no longer taken as a scalar
  by the lazy path, which the eager path had already refused.

- Change: assignment matches shapes, and a size-1 axis now stretches.
  `t[] = src` accepted any source of the same element count, so a `(2,3)`
  source landed in a `(3,2)` destination silently reinterpreted; that now
  raises `RuntimeError`. Use `src.flatten` to store the values in the order
  they lie. In exchange a smaller source is repeated into the destination, so
  `t[] = row[:_, nil, nil]` and `t[] = col` (shape `(n,1)`) now work where
  they used to raise. Shapes differing only in size-1 axes are accepted, as
  is a 1-D side, whether it is the source or the destination. Ruby Arrays and
  scalars are unchanged: `a[] = [1, 2, 3, 4, 5, 6]` still fills by count. The
  in-place operators (`add!` and its siblings) follow the assignment rule,
  since they write into the receiver.

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
