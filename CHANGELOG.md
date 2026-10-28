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

## 3.0.6

- New: `CAFrame` answers the column reductions itself, as a frame of one
  row (`df.mean`, `df.sum("rain", "temp")`), and the running values down
  all its rows (`df.cumsum("rain")`, `order`), as a grouped frame does
  down each group. `percentile(p, *names)` and `quantile` (a column per
  quartile, `"rain_p0"` ... `"rain_p100"`) are added to the frame, groups
  and windows.

- New: `CAFrame` row picks: `nlargest` / `nsmallest` (also on
  `GroupedFrame`), `drop_masked` for the rows with no masked cell,
  `GroupedFrame#head` / `#tail` for the first and last rows of each group,
  and `filter` given a boolean selector directly (`df.filter(df["n"] > 3)`).

- New: `CAFrame#transform` computes columns with a block, keeping their
  names and the index. `select`, `drop`, `transform` and `describe` pick
  columns by a Range of names, a Regexp, a kind (`:float`, `:integer`,
  `:complex`, `:timedelta`, ...) or a data type.

- New: `CAFrame#value_counts` (how many rows hold each value, as a
  frame), `#strip_mask` (the masked cells filled, in a new frame), `#to_a`
  (the rows as Arrays, masked cells `UNDEF`), `#shape`, `#empty?`, and
  `GroupedFrame#each` and `#size`. `CAFrame#==` compares two frames by
  their table: names, columns, index and row axis name.

- New: `CAFrame#lag` and `GroupedFrame#lag` take a distance of the key,
  `before: "1 hour"` or `after:`, giving each row the value of the row at
  exactly that distance (`UNDEF` where there is none). The key is the
  index or the column `on:` names: a time, a duration or a number.

- New: `join` and `join_asof` take a key named differently on the two
  sides, and `view: :full`, which gives every column of the result as a
  view, with holes for the unmatched rows, so a write reaches either
  frame.

- New: `df[name] = value` with a single value repeats it on every row.
  `fill` takes several columns, an Array of names or a Hash of column =>
  value; `rename` takes a block, can exchange two names, and renames the
  index under its name. `sort_by_key` and `sort_by` take `descending:`.

- New: `CAFrame#set_column_attrs` gives columns their names and common
  attributes; `CArray#attrs_symkey` and `CAFrame#attrs_symkey` return the
  attributes with Symbol keys. `CAFrame#to_csv` takes `precision:`.

- New: `GroupedFrame#fill(name, :linear)` interpolates within each group.
  On a frame, `:linear` reads an index that is not in order as one series
  in index order.

- New: `melt` brings number columns of different types (an `int64` and a
  `float64` column) to their common type, still as a view. A mixture no
  type holds without changing a value (`int64` beside `uint64`), or one
  with text or time, is refused; cast the columns first.

- New: `wsum` and `wmean` take weights shaped as the reduced axes, matched
  in ascending axis order, besides a scalar and weights of the receiver's
  shape.

- New (C extensions and carray-jit): `CArray::AddressBasis.sweep(function,
  fsync, arrays, *parts)` runs a chunked element-wise sweep
  (`ca_call_cslab_N_r`, arities 1 to 7) from Ruby, handing the slab
  pointers to the parts' own String bytes. An `fsync` character other than
  `0` or `1` is refused.

- Change: CArray requires Ruby 3.2 or later, up from 3.0. On an older
  Ruby, `gem install carray` does not offer this release; install a
  newer Ruby with a version manager such as rbenv or mise, or stay on
  3.0.5.

- Change: CSV reading and writing are split by what they take.
  `CAFrame.read_csv` and `#write_csv` take a path or an IO;
  `CAFrame.from_csv` takes CSV text as a String and `#to_csv` returns it.
  Code that gave `from_csv` a path or an IO calls `read_csv`, and
  `to_csv(path)` becomes `write_csv(path)`. No aliases are kept.

- Change: `read_csv` and `from_csv` infer the column types by default
  (`int64`, `float64`, `boolean`, `time`, otherwise text); `types:` names
  some columns and the rest are still inferred. Pass `types: :string` to
  read every column as text, as before. A column with a blank but present
  value (a quoted `""`) stays text.

- Change: `CAFrame#set_index`, `#reset_index`, `#cast`, `#promote`,
  `#parse_to_time` and `#to_time` return a new frame and leave the
  receiver as it is (the two share their columns). Assign the result:
  `df = df.set_index("time")`.

- Change: a `GroupedFrame` reduction given column names returns a frame of
  those columns, one row per group, labelled as without names; it
  returned the `CArray` (one name) or an `Array` of them. Take the column
  (`grp.mean("temp")["temp"]`) or reduce the group iterator
  (`grp["temp"].mean`) for the values alone.

- Change: a `GroupedFrame` or window value on the frame's rows given
  several column names (`keep_rows: true`, the running values, `lag`,
  `w.mean("a", "b")`) returns a frame of them on the frame's rows and
  index, instead of an `Array`. One name still gives the `CArray`.

- Change: `CAFrame#filter` no longer takes `keep_masked:`, so every row
  selection is a view. To keep the rows whose condition is undetermined,
  say so in the selector: `df.filter(cond.is_masked)` or
  `df.filter(cond.strip_mask(true))`.

- Change: `df[sel] = ...` refuses a Ruby Array as the row selector, as
  `df[]` does; the column indexer would read `[0, 2]` as two rows from
  row 0. Write `df[CA_INT64([0, 2])]` for rows 0 and 2.

- Change: a group key named in a `GroupedFrame` reduction, and the index's
  name given to a verb that reads or changes columns (`df[...]`,
  `select`, `fill`, `cast`, the reductions), raise and point at `size`
  or `df.index`. A key argument (`group_by`, `sort_by_key`, `join(on:)`)
  still names the index.

- Change: an `:inner` or `:right` `join` gives the other frame's columns
  as views picked by row, not copies, so a write to them reaches that
  frame. Call `copy` on the result to keep it apart.

- Change: a `CScalar` takes only `s[]` and `s[0]`, reading or writing its
  one cell; any other index (`s[3]`, a range, `nil`, an index array)
  raises. A view such as `s.refer(s.data_type, [1])` takes the usual
  indexes.

- Change: `CArray.stack` and `CArray.meld` refuse a value array
  (`a.value`) or a mask array (`a.mask`) as a part. Pass a copy
  (`a.value.copy`), or `a.is_masked` for the mask's values.

- Change: `CArray#==` finds a NaN equal to a NaN, so an array holding NaN
  equals its copy and the array read back from a file. The cell-by-cell
  IEEE comparison is `eq`; `eql?` still compares bits.

- Change: `CARemap#mapper` returns a read-only array; writing it raises.
  The index array given to `a[idx]` is not affected.

- Change: `Marshal.dump` of a `CAWrap` (from `CArray.wrap_memory_view`)
  writes its values, and the load gives a plain array owning a copy of
  them, as for a view of the wrap; it raised `TypeError`.

- Change: `as_type` returns a view also when the data type is the
  receiver's own, and `CATime#to_unit` / `CATimedelta#to_unit` return a
  new array when the unit does not change, so an attribute set on, or a
  freeze of, the result does not reach the receiver.

- Change: `wmean` gives `UNDEF` where the weights sum to zero, on every
  path; numeric arrays gave NaN or an infinity. A weight array with one
  element is no longer read as a scalar: give a Ruby number or a
  `CScalar`.

- Change: a computation over an object array that comes back into the
  array (a cell holding the array, or a view of it) raises, as reading
  such a cell does; it recursed until the process died. A lazy
  expression over such an array (a cell holding `x + 1` for the array `x`)
  raises the same way instead of overflowing the stack or not ending, and
  so does `Marshal.dump` of an object view whose cells lead back to its
  root.

- Change (CAObject authors): a `CAObject` without `create_mask` raises
  `TypeError` when its `copy_data` writes `UNDEF`, as it does when a
  fetcher answers `UNDEF`; the `UNDEF` was dropped and read as a value.

- Change (C extensions): `ca_install_obj_type` refuses an operation table
  without `allocate`, `attach`, `sync` and `detach` slots;
  `ca_iter_register_source_kind` refuses carray's own types; and the
  kernel iterator's `FIBER_PAIR` forms refuse `CA_KERNEL_WRITE`.

- Fix: `require "carray"` works on Ruby 4.0; it raised
  `Ractor::IsolationError` since 3.0.4.

- Fix: `CArray.fuse` works on Ruby 3.2 and 3.3. The gem now depends on
  prism 1.0 or later, which `gem install` and Bundler bring in on Ruby
  3.2, which ships none, and 3.3, whose own prism is too old; Ruby 3.4
  and later already ship it.

- Fix: a block of a reshape over a strided view
  (`a[1..2, 1..3].reshape(3, 2)[0..1, nil]`) read and wrote past the end
  of a row, outside the buffer at the edges.

- Fix: a frozen object array shared between Ractors can be computed over
  in several at once; it was refused as cyclic. A cell holding a view of
  other cells of the same array is no longer refused.

- Fix: a record array (`CARecord`) exports through MemoryView from a
  Ractor other than the main one; it raised `Ractor::IsolationError`.

- Fix: `Marshal.dump` of a view no longer writes its whole parent (a
  one-cell view of a 100,000-cell array dumped about 400 KB), and an
  array's mask marshals as a plain boolean array.

- Fix: an `each_slab` Enumerator stopped part way with `next` leaves no
  array attached once its Fiber is collected.

- Fix: a window or block iterator reads its source afresh on each call;
  after the source changed, a later reduction mixed new sums with old
  counts.

- Fix: a frozen or read-only `CArray.meld` refuses writes through a meld
  of it (`CArray.meld(m, m)` wrote into the frozen root).

- Fix: a write to a `CArray.stack` or `CArray.meld` whose parts share
  cells (`CArray.meld(a, a)`) gives those cells the value, or the mask, of
  the last part; `add!` could leave an earlier part's result, and a mask
  write masked the cells of every part.

- Fix: a write to a `CArray.stack` or `CArray.meld` that one part refuses
  (a value outside a part's data type) writes nothing; the parts before
  it were written.

- Fix: `blocks(...).sort_addr` works when the source holds more than one
  tile; it failed with `IndexError`.

- Fix: `elem_fetch` answers a boolean cell with `true` or `false` when given
  an index array over a view, as `[]` does; it answered `0` or `1`.

- Fix: `CAFrame#fill(:linear)` leaves a row with no coordinate out of the
  interpolation; it was filled with 0.

- Fix: `bin_to` and `histogram1d` put a value next to an edge in the bin
  that edge bounds when the edges are nearly but not exactly equally
  spaced.

- Fix: `float ** Integer` takes any exponent that fits 64 bits, eagerly
  as lazily, and `x.lazy.pow(k)` answers as `x.pow(k)`. A lazy array
  compared with `UNDEF` (`eq`, `ne`) answers as the eager one does.

- Fix: writing `UNDEF` through a widening `refer` (`r.refer(:float64,
  ...)`) no longer masks parent cells outside the written cells, and a
  mask written onto a `CAObject` without mask hooks survives the next
  read of its values.

- Fix: a masked cell that is not a String reads as `""` when a `CAString`
  wraps a view, as it does over an entity.

- Fix (CASource authors): a source that leaves its `ptr` NULL at rest no
  longer crashes `elem_*`, `dump_binary` to a File or `nlargest` over a
  whole axis.

## 3.0.5

- New: `GroupedFrame#aggregate` takes a block instead of a spec. The block
  is given the grouping once and returns a Hash of output name => a
  CArray with one value per group, built from `g["col"]` iterators and
  CArray arithmetic (`g["temp"].max - g["temp"].min`). `grp[array]`
  groups any CArray with one entry per row, such as a value computed
  from columns or a column with cells masked.

- New: a `CAFrame` grouped reduction takes a Hash of column name => value
  as `fill_value:`, filling only the named columns. A single
  `fill_value:` still goes to every column and has to suit each.

- New: `CArray.meld` brings pieces of different data types to a common
  one, as `CArray.stack` does, and takes `data_type:`. `CAFrame.meld` and
  a frame splice still refuse a column whose pieces differ in data type;
  cast the column first, or use `concatenate`.

- New: `scatter_replace!` takes an object or fixed-length array, as
  `put_nd` and `put_along_axis` do. The accumulating members
  (`scatter_add!` and the others) still take numeric arrays only.

- New: `CAConstString#count` and `CACategorical#count` with no argument
  count the cells that are not masked, as `CArray#count` does.

- New: `CAFixlenString` answers `minmax`, `cummax` and `cummin`, as
  `CAString` does.

- New (C extensions): `carray.h` defines `ca_u_<type>` cell types and
  `CA_U(type)`, of the same size and value as the plain types but with no
  alignment requirement, for reading cells that need not be aligned (a
  refer with a byte offset, a struct member, a wrapped buffer). The slab
  macros in `ca_kernel_iterator.h` use them for their pointers.

- Change: `CACategorical#sort_addr` is renamed `group_addr`, the order of
  the cells by category. `sort_addr` on a categorical now raises, as
  `sort_index` does, since a categorical has no order of values.

- Change: a Face's `parent` (of a `CATime`, `CARecord`, ...) is a
  read-only view of its storage. Write the storage of a time through
  `CATime#ticks`.

- Change: an operator that cannot bring two data types together raises
  `CArray::DataTypeError` instead of `TypeError`. `DataTypeError` is a
  `TypeError`, so `rescue TypeError` still catches it.

- Change: a float cell with no integer of the target type -- an infinity,
  or a value out of the type's range -- is now treated the way NaN
  already was. `to_type` (`int32`, `as_int64`, ...) masks it to `UNDEF`;
  storing it into an integer array raises `RangeError`
  (`FloatDomainError` for an infinity). Before, it became whatever the
  machine's C conversion gave, which differed between x86 and ARM.
  `clip_int64` and the other `clip_<type>` methods saturate a float
  source to the type's limits on every machine; integer `linspace` raises
  `RangeError` for a span the type cannot hold.

- Change: a Ruby Array operand of a numeric or boolean array is read as
  its cells: `a.eq([1, 5, 3])` compares cell by cell (it compared every
  cell with the whole Array), and `a + [1, 2, 3]` adds (it raised).
  Nested Arrays give the axes. An object array still takes an Array as
  one value.

- Change: `window`'s `bounds:` is a policy named by a Symbol or String,
  matched whole; an Integer and an abbreviation raise. A `fill_value:`
  given with a policy that does not use it (`:nearest`, `:strict`, ...)
  raises instead of being dropped.

- Change: a length, count, offset or shift given to a view
  (`sliding_windows`, `block_view`, `tile`, `roll`, `shift`, `field`,
  `diagonal`) must be an Integer; a Float raises `TypeError` instead of
  being truncated. `transpose` reads its axes as the other axis arguments
  are read: negative from the end, an Integer only.

- Change: `drop_axis` on an array whose every axis has size 1 keeps one
  axis of size 1, and `reshape` with no axes raises.

- Change: in an index of one key per axis, an index array of more than
  one axis on one axis raises `ArgumentError`; it was read flat. Pass
  `idx.flatten` for the old reading.

- Change: `elem_fetch`, `elem_store` and the other `elem_*` methods read
  an index as `[]` reads a key: a Float with no fraction is an index, a
  Float with a fraction raises `IndexError`.

- Change: two string arrays of different kinds (`CAString`,
  `CAFixlenString`, `CAConstString`) or of different widths compare by
  their strings. A String query longer than a fixed-width cell matches
  no cell in `eq`, `count`, `search`, `bsearch` and `is_in`; it was cut
  to the cell's width.

- Change: `str_index` and `rindex` give `UNDEF` for a cell that does not
  hold the substring; they raised for the whole array.

- Change: `bsearch` and `bsearch_addr` answer the first of several equal
  cells.

- Change: `search` and `search_addr` raise `ArgumentError` for a negative
  or NaN `eps`, which acted as an exact match.

- Change: `inherit_mask` and `inherit_mask_replace` raise `ArgumentError`
  for a source whose number of cells differs from the receiver's (a
  scalar source still applies to every cell).

- Change: a reduction's `fill_value:` that its result cannot hold raises
  even when no cell needs it, and `fill` on an empty array checks its
  value as an assignment does.

- Change: rounding a `:M` or `:Y` `CATime` to a calendar bucket
  (`round(unit: :Y)`, `"3 months"`) measures the distance by the instant,
  so it agrees with the same dates on `:D`.

- Change: a `CATime` reduction (`mean`, `median`, ...) sends a tie to the
  later tick on both sides of 1970; before 1970 it went to the earlier
  one.

- Change: a duration String added to or subtracted from a `CATime` is
  one step of its own resolution, so `"15 minutes"` on a `"10 minutes"`
  grid raises, as the same duration as a `CATimedelta` does. It was read
  as fifteen one-minute steps and cut to the grid.

- Change: of `-0.0` and `0.0`, `pmax` gives `0.0` and `pmin` gives
  `-0.0`, in either order and on every platform, as `maximum` and
  `minimum` do. Which zero `min` and `max` answer is not specified.

- Change: a one-sided `clip` passes a NaN cell through, as a two-sided
  `clip` does.

- Change: a categorical's `fill_value:` (of `shift`, `window`, `project`)
  is a label; a `CAConstString` takes only `UNDEF` as a fill value.

- Change: a lazy operator with a Face operand (a categorical, a time, a
  string array) answers as the eager operator does; it read the Face's
  storage. `CAConstString#eq` with another array compares cell by cell.

- Change: a boolean member of a record (or `field(offset, :boolean)` of a
  fixed-length array) raises `RangeError` when read as a byte that is not
  0 or 1, instead of answering differently in each method.

- Change: unmasking a cell of a `CAString` that holds no String gives an
  empty String.

- Change: `swap_bytes` keeps the attributes, as `refer` and `bitfield`
  do. An array with no cells has no say in the attributes a `meld`,
  `stack` or `concatenate` keeps.

- Change: `dim_view` keeps a Face, as `transpose` does.

- Change: `CArray.string(n)` without a block, and `CArray.string("ab")`,
  raise; `fixlen_string` and `to_fixlen_string` raise for `bytes:` below 1.
  `project` raises for a keyword argument, `paste` into a frozen array
  raises `FrozenError`, and `CArray.result_type` refuses a MemoryView
  operand whose format carray cannot read, as the operators do.

- Change: `CArray.sort_addr` with numeric keys is two to three times as fast, and
  `nlargest` / `nsmallest` read each fiber once with a work area of a
  few times n.

- Fix: x86-64 Linux. Inputs that reached an integer division by zero
  inside the library stopped the process with SIGFPE there (on ARM they
  were refused later or gave a wrong answer): a sum over a view with a
  zero-length axis, `wsum` / `wmean` with 1-D weights over a zero-length
  axis, a view of a stack of empty arrays, `window` with a step of 0, and
  `wrap_readonly(String, CA_FIXLEN)`. Each now answers or raises
  `ArgumentError`. The extension builds with GCC 14 without warnings.

- Fix: big-endian hosts. `bitfield` read 0 and lost writes, a struct's
  bit members overwrote each other, and an element-wise operation applied
  in place could give a wrong cell.

- Fix: `save` and `dump` with `endian: :little` or `:big` wrote the other
  byte order. `load` reads the marker, so files written so far still load
  correctly.

- Fix: running out of memory inside a kernel left a view attached, lost
  the keywords of the call (`a.sum(axis: 1)` returned the total), or
  leaked the array being built.

- Fix: an array with 16 axes (the maximum) given to `bitarray`, `field`,
  a narrowing `refer` or a `:_` index wrote past an internal array.

- Fix: a lazy chain whose step narrows the cells (`a.lazy.abs` of a
  complex array) overran the heap; `seq` on an empty object array wrote
  past its end.

- Fix: a CAObject's copy and sync hooks: a view the hook kept of the
  array it was lent, or the lent array's mask, pointed at freed memory
  after the hook returned.

- Fix: `CArray.fuse` crashed when several Ractors ran a fuse block for the
  first time at once.

- Fix: a grouped `variancep` / `stddevp` matches `CArray#variancep` to the
  last bit.

- Fix: `count` with an array of values honours `keep_axis:`.

- Fix: `CARecord.wrap` of a record array wraps its storage, not the
  record array.

- Fix: an unnamed struct's `order_by` survives `save` / `load` and
  Marshal.

- Fix: `CAFrame.from_csv` and `cast(name => :time)` read a leap second
  (`23:59:60`) as `CArray.time` does, into the next minute.

## 3.0.4

- New: `CAFrame#verify(rules)` judges every row against named rules (each
  a callable that returns a boolean CArray) and returns the verdicts as a
  frame, one column per rule; a row whose rule read a masked value is
  `UNDEF`, so `count(false)` counts the rows that break it.

- New: `CAFrame#join` takes `how: :semi` and `:anti` (the left rows that
  have, or have no, match), several key columns (`on: ["station",
  "date"]`), and the index as a key by the row axis name.
  `CAFrame#join_asof` takes the index too, and `by:` columns that must
  match exactly before the nearest key is taken.

- New: a `CAFrame` grouping has more verbs. The short form of `prod`,
  `accumulate`, `median`, `variance`, `stddev`, `variancep`, `stddevp`,
  `first`, `last`, `nunique`, `count`, `all` and `any`, beside `sum` /
  `mean` / `min` / `max`; `filter` (keep the groups a block chooses);
  `lag`, `order`, `cumsum` and the other running values, and
  `fill(name, :ffill)` / `:bfill`, all kept on the frame's rows; and
  `to_frame`. The reductions take column names (`grp.mean("temp")` is a
  CArray) and `keep_rows: true`, which gives each row its own group's
  result.

- New: `CAFrame#resample` takes `by:`, columns whose groups are binned
  apart: `df.resample("time", "1 day", by: "station").max("temp")`.

- New: `CArray#windows(on:, before:, after:)` bounds each window by a
  width of a key (a time, a duration or a number) instead of a count of
  cells, with `by:`, `exclude:`, `interval:` and `at:` (windows placed at
  given points, which may overlap). The key need not be sorted, and the
  value may have several columns (shape `(N, ...)`). `CAFrame#windows(on:
  "time", ...)` does the same for a frame's columns.

- New: `CArray#lag(n = 1, axis:)` is the value `n` steps earlier along an
  axis, `UNDEF` where there is none, so `x - x.lag` starts with `UNDEF`.

- New: the slab, block, segment, categorical and axis-group iterators
  have `lag`, `order` (each cell's rank within its piece) and
  `strip_mask(method: :ffill / :bfill)`; each of them works within one
  piece and never takes a value from another. Every iterator has `first`,
  `last` and `nunique`.

- New: `CArray#is_between(lo, hi, exclude:)` (or a Range) is true where a
  value lies between two bounds; `exclude: :lower`, `:upper` or `:both`
  leaves bounds out, and `nil` or an open end leaves a side unbounded.

- New: `CArray#round(ndigits)` rounds each element to `ndigits` decimal
  places (negative for tens, hundreds, ...), as `Float#round` and
  `Integer#round` do.

- New: `CArray#to_frame(*names, axis: -1)` shows an array as a CAFrame
  whose columns are views of it, one per position along `axis`.

- New: `CACategorical#contrast(base:, full:)` gives one int8 column per
  category (1 in the cell's category, the base left out unless `full:
  true`), and `CAFrame#contrast_columns(name, ...)` puts those columns in
  the frame in place of the categorical.

- New: `CAFrame#is_duplicate(*names, except:)` is true for the rows that
  repeat an earlier row in the named columns; `except: :last` or `:none`
  chooses which occurrence stays unmarked.

- New: `CAFrame#append(name, col, before:, after:)` puts the column next
  to another one.

- New: a `CAFrame` carries attributes of the frame as a whole (`attr`,
  `set_attr`, `attrs`, ..., and `CAFrame.new(..., attrs:)`), separate from
  each column's. A row selection or a change of columns keeps them; a
  summary, a join or a reshape does not.

- New: `CAFrame#to_csv(attrs: [:units, ...])` writes one line per
  attribute key below the names, and `CAFrame.from_csv(attrs: [...])`
  reads them back as column attributes; in a reading block,
  `r.header(:units)` does the same for a line anywhere in the header.

- New: `CAFrame.from_csv` `columns:` takes a Hash that selects and names
  columns, and the names `c0`, `c1`, ... of a file without a header;
  `cast` and `from_csv` `types:` take `:categorical`. `CAFrame.new` takes
  `types:` and `on_error:`, as `from_records` does.

- New: `CArray#delete_attr(key)` removes an attribute and returns its
  value.

- New: `CATime#end_of(unit:, origin:)` (the last tick of each time's
  bucket), `days_in_month`, `quarter`, and the ISO 8601 week `iso_week`
  with its year `iso_year`.

- New: a time or duration array takes a single value in `+` and `-`
  (`t + "3 days"`, `t - t.min`, `t - Time.utc(2024, 1, 1)`), and a month
  or year duration moves a time on a day or finer grid as `Date#>>` does
  (`2024-01-31 + 1 month` is `2024-02-29`). A bare number is still
  refused.

- New: a time array compares with a value off its grid (`days.eq(
  "2024-01-03T05:00")`, `<`, `search_nearest`, `is_in`, ...) in the finer
  unit the two share, where it raised `ArgumentError`. An assignment
  still raises.

- New: `CATime#pmax` / `pmin` (and `maximum` / `minimum` / `fmax` /
  `fmin`) give the later / earlier time cell by cell.

- New: CArray can be used in a Ractor other than the main one, `fuse`
  included, and a frozen array is shared between Ractors without
  copying. See `docs/topics/Ractor.md`.

- New: C extensions: `CA_FOR_EACH_WHOLE` and `CA_FOR_EACH_WHOLE_MASKED`
  hand a kernel the whole array as one contiguous run.

- Change: `CArray#rank` is removed; use `#ndim`.

- Change: `CArray::TableMethods` (`column_names=`, `column`, `row`, `rows`
  and `select` on a 2-D array) is removed; use `a.to_frame("x", "y")`,
  then `df["x"]` for a column or `df.to_records[i]` for a row.

- Change: `CArray.load_arrow_tensor`, `CArray#save_arrow_tensor` and
  `CArray::ArrowTensor`, the experimental Arrow tensor IPC reader and
  writer, are removed.

- Change: methods whose names start and end with `__` that were public
  internals are now private, renamed or removed. Call the public method
  they served instead.

- Change: CAFrame takes column names as Strings only. A Symbol name
  (`df.drop(:a)`, `join(on: :a)`, `CAFrame.new(axis_name: :row)`) raises
  `TypeError`; write `"a"`. Record keys given to `from_records` may still
  be Symbols, and `df[:x]` stays the predicate syntax.

- Change: a masked cell of an integer index array keeps its place:
  `x[i]`, the grid forms and `CAFrame` row selection `df[i]` give a
  result shaped like `i`, `UNDEF` where `i` is masked, where they dropped
  those positions. To drop them as before, index by
  `i[i.is_not_masked]`.

- Change: an index beside a CArray key is read as it is without one: a
  range ending before its start reads backwards (`a[i, -1..1]`), and an
  Integer key drops its axis (`a[i, 1]` has the shape of `i`; add `:_`
  or use `1..1` to keep it).

- Change: an index with a Float that has a fraction (`a[1.5..3]`, a step
  of `0.5`) raises `IndexError`; it was cut to an integer. Convert with
  `to_i` or `round` first. A Float that holds an integer, such as a count
  from `sum`, is still that position.

- Change: an index step says the direction, as in Ruby: a step pointing
  away from the end reads nothing (`a[(0..4).step(-1)]` read `a[0]`).

- Change: a boolean selector of more than one axis must have the array's
  shape; it picked cells by flat position. Flatten both sides to keep the
  old reading.

- Change: storing an integer a cell cannot hold raises `RangeError`
  (`CA_INT8([300])`, `a[0] = 300`, `fill`, `scatter_add!`, a record
  member); it wrapped (`300` into int8 was `44`). Storing or reading a
  NaN into an integer cell (`ints[] = floats`, `as_type`, `fake`) raises
  `FloatDomainError`. To keep C's conversion, use `to_type`, which is
  unchanged.

- Change: `CArray.time` reads an Integer as a count of ticks of `unit:`
  (`CArray.time(CA_INT64([0, 10]), unit: :m)` is 00:00 and 00:10); it
  read Unix seconds. To read Unix seconds onto another unit, write
  `CArray.time(secs).to_unit(:m)`.

- Change: `CArray.time` without `unit:`, and `CAFrame#parse_to_time` with
  a format or `:mixed`, read the values in the finest unit they show
  (dates alone `:D`, fractions of a second `:ms` / `:us` / `:ns`); it was
  always `:s`. Pass `unit: :s` to keep the old unit.

- Change: adding a duration that is coarser than a time's unit and not a
  whole number of its ticks (`"1 day"` on a `"7 hours"` time) raises, and
  so does `CArray#time(origin:)` between two ticks of `unit:`; both were
  cut to the grid. Convert the time to a unit both share first.

- Change: `order(descending: true)` puts NaN last and keeps tied cells in
  their original order (`[5, 3, 5, 1, 5]` gives `[0, 3, 1, 4, 2]`, was
  `[2, 3, 1, 4, 0]`); with `method: :dense` the largest value is 0 and
  the ranks have no gaps. Code that used `(n - 1) - order` for the
  descending rank needs that formula written out. `nlargest` no longer
  returns NaN or masked cells first, and `nsmallest` / `nlargest` and
  their `_index` forms break ties by position.

- Change: a CAFrame column built from Ruby values is typed by them:
  Integers `int64`, numbers `float64`, Strings a text column (`CAString`),
  arrays of one shape an N-D column, anything else `:object`; it was
  `:object`. This holds for `CAFrame.new("x" => [...])`, `df["x"] = [...]`,
  a group's `table` block and a Proc in `aggregate`. Wrap the values in
  `CA_OBJECT(...)` to keep an object column. A returned array is read
  from the N-D column as `col[i, nil]`.

- Change: `CAFrame#melt` names each row's source in a text column
  (`CAString`); it was an object column.

- Change: `CAFrame#group_by` on several keys gives a result with no
  index: each key is a column, before the reduced columns. Read the keys
  with `result["station"]` and so on, where the index held tuples.

- Change: `CAFrame#data_types`, `describe` and `p df` name a Face column
  by its class (`CATime[D]`, `CAString`) where they gave its storage
  `data_type` (`:fixlen` for most). Read the storage through the Face's
  accessor (`ticks`, `codes`, ...).

- Change: a CAFrame verb that takes a list of columns refuses a name
  given twice (`select("a", "a")`, `group_by("a", "a")`) with
  `ArgumentError`. `df["a", "a"]` still gives the column twice.

- Change: a CAFrame group or window reduction over a column whose type
  lacks it raises `CArray::DataTypeError`; it raised `ArgumentError`.

- Change: a `CAString` holds only Strings: storing `nil`, a number or an
  Array into it raises (use `UNDEF` to mask a cell). A selection among
  Strings (`then_else`, `choose`, `select`, `conditional`) and a
  `CAString`'s String operators give a `CAString`, where they gave an
  object array.

- Change: attributes follow conversions, views and copies but not
  reductions: `categorize`, `cast`, `parse_to_time`, `dup`, Marshal and a
  Face's views keep them, and `first` / `last` of a grouping no longer
  carry them. A joined or concatenated array shows the keys every piece
  shows with the same value. An attribute value is stored frozen; change
  it by setting it again.

- Change: an error names the method you called, and the common refusals
  open with it ("+: shape mismatch between operands ...", "fill: can not
  modify read-only array"). The exception classes are unchanged; code
  that matches a message needs the new text.

- Change: `clip` refuses `UNDEF` or a masked cell as a bound with
  `ArgumentError`. To mask the cells out of range, pass `UNDEF` as the
  fill (`clip(0, 10, UNDEF)`).

- Change: `is_in`, `intersection`, `difference` and `union` refuse a
  Range; pass an Array (`(1..3).to_a`), or use `is_between` for an
  interval.

- Change: `median`, `percentile` and `quantile` along the only axis of a
  1-D array give a bare value, as `sum` does. `nunique(axis:)` naming
  every axis gives an Integer; pass `keep_axis: true` to keep an array.

- Change: `valid_index?` and `valid_addr?` count a negative index from
  the end, as `[]` does. `elem_fetch` on an empty array raises
  `IndexError`; it returned `nil`.

- Change: `seq` / `seq!` on an integer array take a Float or Rational
  start or step as `init_val + step*i` cut toward zero
  (`int32.seq(0.5, 0.5)` is `[0, 1, 1, 2]`, was `[0, 0, 1, 1]`), and
  raise `RangeError` for a start or Integer step the type cannot hold.

- Change: `random!` on an integer array raises for bounds the type
  cannot hold or a Float bound, and clears the mask. `bin`, `bincount`,
  `bincount_nd` and the histograms raise for a non-Integer count and for
  edges that decrease.

- Change: MemoryView: `wrap_memory_view` refuses a boolean buffer (any
  byte other than 0 or 1 cannot be told apart; use `from_memory_view`,
  which reads it as true), and a wrap with a read-only `mask:` is
  read-only. `CArray.memory_view_reject_reason` returns `nil` for an
  object that is not a CArray.

- Change: C extensions: fifteen kernel iterator shorthand macros
  (`CA_SLAB_REDUCE_F64`, `CA_SLAB_REDUCE_T_PLUS`,
  `CA_L2_FOR_EACH_UNMASKED` and others) are removed; write the macro they
  stood for (`CA_SLAB_REDUCE_T` with `double`, ...).
  `ca_iter_state_next_slab_strided` is removed, and
  `ca_iter_state_init_l2` takes `CA_SLAB_AXES` only.

## 3.0.3

- New: `CAFrame.from_csv` reads messy tables: `types: :infer` (numbers,
  booleans, year-first dates and times), `types: { default: ... }`,
  `missing:` tokens, `on_error:` (`:mask`, `:warn`, `:raise`), `columns:` to
  read only some columns, and `header:` / `data:` / `column_names:` by line.
  `CAFrame#cast` takes the same map; `parse_to_time(name, :infer)` finds a
  column's date format; `describe` and `split_column` are new; `to_csv`
  takes `encoding:` and `missing:`.

- New: `CAFrame` reshapes and resamples: `pivot` / `pivot_grid` / `melt`,
  `stack_rows(by:)` / `unstack_rows`, `stack_columns` / `unstack_column`,
  `CAFrame.stack` / `unstack` (frames as layers), and `resample(name, unit)`
  for time bins. The stacked forms are views. `protect` makes a frame
  read-only.

- New: `CAFrame` group reductions and `aggregate` reduce N-D columns along
  the rows (a column `(N, L)` gives `(groups, L)`), take `min_count:` and
  `fill_value:`, and pass a reduction its arguments
  (`"p90" => ["temp", :percentile, 90.0]`).

- New: `value.segments(offsets:)` / `segments(lengths:)` iterate over
  consecutive runs of cells, with `CArray.segment_offsets` /
  `segment_index` to convert between lengths, boundaries and segment
  numbers. The scans, `map`, `median` and `percentile` of
  `group_by_category` take `axis:`, and a window's `median`, `percentile`
  and `quantile` answer under the default `bounds: :skip`.

- New: `bitfield(range, type)` reads a field as a signed or wider integer;
  `set_attrs(hash)`; `order(kind:)`; `tolerance: "10 minutes"` for time keys
  in `locate_nearest_addr` and `CAFrame#join_asof`. A `CARecord` answers
  `unique`, `value_counts`, `mode`, `is_in`, the set operations,
  `categorize`, `count(v)` and `locate_addr`.

- New: for whoever registers a `CArray.expression_evaluator` (carray-jit):
  mixed data types, integer powers, comparisons, `then_else`, `shift`, and
  reductions, scans and sorts of an expression now reach the evaluator. An
  evaluator that does not know a node declines, and CArray computes the
  expression as before.

- New: for C extensions: `ca_iter_ensure`, `ca_sync_detach`,
  `ca_attach_n` / `ca_allocate_n`, `ca_iter_state_init_l2_paired`,
  `ca_stride_setup(NULL, ...)` and `ca_check_uninitialized` let an
  extension clean up when its code raises.

- Change: `CAFrame` names its columns "columns": `variable_names` is now
  `column_names`, `variables` is `columns` and `nvar` is `ncol`. The old
  names are gone.

- Change: `sort_index`, `rank_index`, `partition_index`, `partition` and
  `partition_copy` without `axis:` work on the whole array, as `sort` does;
  they worked along axis 0. On an N-D array pass `axis: 0` to keep the old
  result.

- Change: errors a caller can cause no longer raise `RuntimeError`: a bad
  shape, step, axis, option or data type raises `ArgumentError`,
  `TypeError`, `RangeError` or `CArray::DataTypeError`, and every index out
  of range raises `IndexError` (`take_along_axis`, `axis2addr` and
  `addr2index` raised others). `CArray::DataTypeError` is now a
  `TypeError`. A write to a read-only array still raises `RuntimeError`.
  Messages name the method you called and the value you gave. Update a
  `rescue` that matched the old class or wording.

- Change: arguments that were truncated or ignored now raise: an axis,
  `min_count:`, `kth` or `n` that is not an Integer; a misspelt keyword; a
  keyword a method does not take (`min_count:` to `all` / `any` of an
  iterator, as to the core); a Symbol column name in `cast` and `types:`;
  `windows` given anything but Ranges (an exclusive range now leaves out
  its end); `CA_INT32(0, 2)`; a fixlen array without `bytes:`. A negative
  axis counts from the end everywhere. The indexer's method form
  (`a[:eq, 0]`) calls public methods only.

- Change: a Hash passed as a positional argument is an argument, as in
  Ruby 3, not keywords: `a.sum({axis: 0})` raises (write `a.sum(axis: 0)`
  or `a.sum(**opts)`). An object array of Hashes can now be searched and
  counted.

- Change: values that cannot be held raise instead of being bent: storing
  `nil` into a numeric or boolean array, an Integer operand the array's type
  cannot hold (`RangeError`; the comparisons answer by value instead), and a
  String that is not a decimal number (`"010"` is now 10, and `to_type` gives
  `UNDEF`). `CAFrame#cast` to an integer makes `2.5` `UNDEF` instead of 2.
  Store `Float::NAN` or `UNDEF` for a missing value.

- Change: reductions with too few values: `variance` / `stddev` of fewer
  than two values is `UNDEF` (pass `fill_value: 0.0` for the old answer),
  and `minmax` of nothing is `[UNDEF, UNDEF]`. `fill_value:` is stored into
  the result's type with or without `axis:`; `fill_value: UNDEF`,
  `strip_mask(UNDEF)` and `unmask(UNDEF)` leave the cells masked.

- Change: arrays of mixed types meet in a type that holds both: signed with
  unsigned integers (`uint8` with `int8` is `int16`, `uint64` with `int64` is
  `:object`) and 32-bit or wider integers with `float32` (in `float64`) when
  joined or matched. `CArray.result_type` lets a scalar take the arrays'
  type, as an operator does (`result_type(float32_array, 0.1)` is
  `:float32`). Arithmetic is unchanged.

- Change: integer and float edge cases no longer depend on the machine or
  the argument order: a shift count means what it does to `Integer#<<`,
  signed `rcp` / `rcp_mul` round down as `/` does, `to_type` to an integer
  makes NaN `UNDEF`, `maximum` / `minimum` of two zeros are `0.0` / `-0.0`,
  and `clip` raises when `min` exceeds `max` (a one-sided fill clamps the
  other side).

- Change: `CAFrame#join` matches as SQL joins do: a key on 2 left and 3
  right rows gives 6 rows, and a masked key matches nothing and stays as an
  unmatched row. When the other frame's key is unique, `:left` gives the
  same rows as before.

- Change: `CAFrame.from_csv`'s reading block takes the reader as its
  parameter and its `body` verb is `data`
  (`from_csv(path) { |r| r.skip 2; r.header; r.data }`). Text columns come
  back as `CAString`. Contents that cannot be read raise
  `CAFrame::UnreadableColumn` or `CAFrame::AmbiguousTimeFormat`, which are
  not `ArgumentError`.

- Change: reading time from text is stricter: `parse_to_time` without a
  format reads year-first text only (pass a format, or `:mixed` for the old
  guess) in the finest unit the text shows; `CArray.time` and strptime
  formats refuse trailing text and a time of day they cannot read; a date
  the column's unit cannot hold raises `RangeError`. Before, these cells
  were guessed, floored or masked.

- Change: `CAFrame#to_csv` writes a boolean as `1` / `0` and a float32 as
  its shortest decimal, refuses a record column, and raises naming the row
  and column of a cell it cannot encode. `extract` masks a cell its pattern
  does not match, where it gave `""`.

- Change: `CAFrame`: a frozen frame refuses `[]=`, `set_index`, `cast` and
  the other in-place verbs; `at` on a numeric index takes numbers only; the
  index of a `group_by` result keeps the key's type (a `CATime` key gives a
  `CATime` index); group `sum` / `mean` / `min` / `max` include every column
  whose type has the reduction (times and strings among them).

- Change: `CAStruct` / `CARecord`: records are ordered only by the members
  named in `CArray.struct(order_by:)`; without it sorting, `min` / `max` and
  comparison raise. An element's `[]` takes a String or a position (a
  Symbol raises), a member named like a method (`hash`, `size`) gets no
  accessor, a nested member reads as a view (`dup` it for a copy), boolean
  and 1-bit members read as `true` / `false`, and `UNDEF` cannot be stored
  in a member. Records of another struct are refused.

- Change: a `CARecord` exported through MemoryView uses Ruby's own format
  (`ruby/memory_view.h`) instead of PEP 3118 `T{...}`; the member names are
  `CARecord#memory_view_field_names`. A union is no longer exported.

- Change: a time array compares with, searches for and stores a `String` or
  `Date` as well as a `Time`, at the precision the value carries: a value
  off the array's grid (09:00 against a day array) raises, where a `Time`
  was floored. `union` of two units gives the finer unit. `inspect` shows
  the tick and each cell as `to_s` does.

- Change: `==` on a Face (a time, string or categorical array) compares the
  values it holds, and only with a Face of its own class: time arrays of
  different units holding the same instants are `==`, and a `CAString` is
  no longer `==` to an object array of the same strings (compare
  `to_type(:object)` for that).

- Change: Faces (`CATime`, `CATimedelta`, `CACategorical`, string arrays):
  `.lazy` returns the Face and computes eagerly; storing one into a
  non-object plain array raises (convert with `to_type(:object)` or
  `ticks`); `CArray.save`, `dump` and `Marshal.dump` refuse one, and a
  `CAWrap` (save `.parent` or `.copy`); `CArray.stack([face])` returns the
  Face, and mixing Faces raises.

- Change: for whoever writes a Face: the hooks are renamed
  `storage_to_element` / `element_to_storage`, and a stored value goes
  through `element_to_storage` once (it went through twice). A Face written
  in Ruby on `CAObject` over a numeric storage refuses arithmetic, math and
  reductions unless it passes `numeric: true`.

- Change: views: a view of a frozen array is read-only rather than frozen
  (`RuntimeError`, `frozen?` false), so `sort`, selections and lazy
  expressions work on a frozen array. `then_else` and `sort` on a lazy
  expression return a read-only lazy view (call `copy` for a snapshot), and
  `then_else` branches broadcast as operands do. `dup` of a `CAWrap` is a
  plain `CArray`. Attributes survive `copy` and `to_type`.

- Change: a `bitarray` view has no mask and refuses a masked array (use
  `value.bitarray`); `pack_bits` raises on masked cells (pack the mask with
  `validity_bits`). `bitfield` refuses a complex array.

- Change: on an object array, `min`, `max`, `cummin`, `pmin` and the rest
  compare with `<=>`, as `sort` does; a pair that cannot be ordered raises
  `ArgumentError`. `median`, `percentile` and `quantile` answer in the
  elements' own arithmetic (`CA_OBJECT([1, 2]).median` is `3/2`; convert
  with `to_type(:float64)` for a Float). `&`, `|` and `^` with a boolean
  array read its cells as `true` / `false`, eager and lazy.

- Change: smaller behaviour changes: `locate_nearest_addr` (and `join_asof`,
  `snap_to`) with `direction:` matches beyond the reference's ends (limit it
  with `tolerance:`); `map_slab` carries the mask of the block's result; a
  masked cell of a one-axis boolean selector selects nothing; `shift`,
  `roll`, `tile` and `window` on a zero-length axis return an empty view;
  boolean sums in `axis_group` and categorical scans are uint64, as in the
  core; `group_by_category` raises `TypeError` for a non-categorical.

- Change: an operand that exports MemoryView and defines `to_ca` (an Arrow
  array, with a bridge) is taken through `to_ca`, so Arrow nulls arrive as
  masked cells and time columns as `CATime`.

- Change: for C extensions: `CArray::VERSION_CODE` is
  `major*10000 + minor*100 + teeny` (`30003`); the `CA_FOR_EACH_ELEMENT`
  macros, `CA_WITH_BUFFER` and `CA_CHECK_BOUND` are removed (use
  `ca_call_cslab_N_r`, `ca_call_cfunc_N_r` or `rb_ca_call_with_buffer`);
  the `_INOUT` and `_PAIR` fiber macros raise on a shape mismatch; kernels
  are built with `-fwrapv`. Rebuild the extension.

- Change: faster, with the same results: `from_csv` with `types:` (two to
  five times), text to float (eight times), `CAConstString#to_string`,
  reductions over gathered, `shift` and `window` views, a repeated
  `CArray.fuse` block, and selecting from a lazy expression.

- Fix: wrong answers that came without an error. An in-place operation
  reading an argument that shares its memory read cells it had already
  written (`a[1..5].add!(a[0..4])` gave a running sum; `scatter_*!`,
  `inherit_mask` and `mask=` too); `refer` to a wider type on a transposed
  or stepped parent read neighbouring values; views of a stack or meld,
  and a slice of a lazy expression, returned other cells; a Float operand
  of an integer array was truncated (`count(1.5)` found `1`); `mask=` with
  another shape copied cells by count; a masked index read cell 0 in
  `gather_nd`; `stddev` of NaN data was 0.0.

- Fix: wrong answers that came without an error, time and strings: time
  keys of different units matched or not depending on the side in `is_in`,
  `join` and `align`; `locate_nearest_addr` picked a wrong row for a NaN,
  an infinite or a nanosecond key; `unmask(time)`, `resize(fill_value:)`
  and `insert_block` read a `Time` as a count; `CAConstString` comparisons
  compared buffer positions; a `CAString` compared against a time,
  categorical or const string compared their encodings.

- Fix: writes that were lost now reach the array: through a grid, selection
  or `select_axis` over a reshaped transpose, through a stack or meld of
  views, into a nested struct member, into the mask copy of a stack or meld,
  and the masked cells of `c[] = c.flip(0)`.

- Fix: crashes and reads outside an array: a garbage collection during an
  operation on a converted or computed array (`CAObject`, lazy, object
  data); a slab kept after `each_slab`; a `CARecord` after `Marshal.load`;
  shapes and indices whose arithmetic overflows; `refer(:object)` and
  `bitfield` on object data; `scatter_*!` on complex; `MIN / -1` on Linux
  x86; struct members outside the record; fixlen stores of another width;
  reductions in several Ractors.

- Fix: an operation that raises part way (a block, a conversion, a
  division by zero) leaves its arrays usable and frees its memory. Before,
  an array could stay attached, and after 32 such errors every lazy
  expression failed with "all 32 slots in use".

- Fix: iterator reductions answer as the same reduction on an array: every
  one takes `min_count:` and `fill_value:` (`blocks(n).percentile(p,
  min_count: k)` read them as a second percentile), a group's counts apply
  `min_count:` to the right cells, a group's `wmean` no longer takes
  `fill_value:` as a weight, a window of only NaN gives NaN, and object
  weights in `segments` stay exact.

- Fix: `CAFrame` round trips through CSV and records: quotes, separators of
  several characters or spaces, lines of spaces, a duplicated header name,
  complex `Infinity` / `NaN`, months and years, hour 24, a one-column file
  with a blank name; nested arrays, `Complex` and `Rational` in
  `from_records`. `fill`, `to_table` and `filter(keep_masked:)` work with
  N-D and categorical columns; `meld` and `concatenate` take empty frames;
  `group_by` takes a categorical key and treats NaN in a composite key as
  one value.

- Fix: Faces stay Faces: the reductions of `windows` and `blocks`,
  `partition_copy`, `then_else`, `clip`, `mask_eq` and `meld` return the
  Face, and a Face's own state survives `min(axis:)`, `cummax` and
  `partition_copy`. `axis_group` and categorical reductions take boolean,
  complex, object and Face values; a time array's `fill_value:` is a time
  on every path. `CAFrame#fill(:linear)` interpolates any Face that defines
  `linear_fetch`. A categorical refuses `clip` and `minmax` as it refuses
  `min`.

- Fix: types kept through operations: complex arrays work with `unique`,
  `is_in` and the rest of that family; `meld` reductions answer as on a
  copy; fixlen strings of different widths match; `atan2`, `hypot` and
  others keep float32 and integer types; a record member declared with
  `endian:` reads, sorts, saves and loads correctly.

- Fix: NaN and masked cells are treated the same everywhere: NaN is last in
  object sorts and `categorize`, loses `min` / `max`, and is found by
  `CAFrame#at(Float::NAN)`; `min_index` never points at a masked cell or a
  NaN; `min_count:` and `fill_value:` are honoured where they were ignored;
  a lazy expression's mask follows its operands; a selection or `shift`
  follows later mask changes; `invert_mask` works on a selection.

- Fix: MemoryView: a `CAFixlenString` exports as bytes and a frozen fixlen
  array can be exported; `CATime`, `CACategorical` and `CAConstString` are
  refused by `memory_view_available?` with the reason, instead of answering
  `true` and failing.

- Fix: with carray-jit: two expressions that differ only in which operand an
  operation reads no longer share a kernel, and a store whose destination
  overlaps an operand is computed by CArray.

- Fix: for C extensions: a `CA_KERNEL_WRITE` walk over a view that holds a
  cell more than once keeps the cells the kernel wrote; a walk left with
  `break` writes back its slab; writes through a `CAGrid`, `CAWindow` or
  `CAShift` over a view reach the array; the sweep engine and paired walks
  read an argument sharing the output's memory as it was; a view class
  that is not registered with `ca_iter_register_source_kind` is still
  accepted. Rebuild the extension.

## 3.0.2

- New: `CArray::AddressBasis`, for a C extension whose code addresses cells
  itself rather than being handed them — a kernel generated from an
  expression, which writes its own loop. `open` lends a pointer and one byte
  stride per axis for the length of a block, and closes what it opened even
  when the block raises; `classify` reports how an array would be opened
  without opening it. It is a runtime facility at the `ca_attach` layer, not
  a user API: what it lends is a raw machine address, so it is described in
  the developer's guide rather than in the user documentation.

- New: a `CAString` column can be searched, not only sorted: `bsearch`,
  `bsearch_addr`, `search` and `count(v)` answer where they used to raise
  `ArgumentError`. A cell of one is the Ruby String it shows, so a String query
  compares against it directly, with nothing to reconcile. Sorting, which
  already worked, is unchanged, and so is `CAConstString`, which answers
  `search` / `count(v)` natively and still has no `bsearch`.

- New: `count(v)` counts an object or fixlen array, which used to raise
  `CArray::DataTypeError`. An object array compares by Ruby `==`, so
  `count(1)` and `count(1.0)` agree, and `true` / `false` / `nil` are values to
  count rather than the boolean array's `true` / `false`. A fixlen array
  compares the whole cell by `memcmp`, with a short String query padded out to
  the cell width -- so a 4-byte cell holding `"a\0\0\0"` is counted by
  `count("a")`.

- New: `CArray.empty(data_type, dim, bytes: nil)` allocates without the zero
  fill, for an array whose every cell is written before anything reads it. One
  existing call changes: `CArray.empty(3, [4])` raised `TypeError` in 3.0.1
  and now matches `CArray.new(3, [4])`.

- New: `CAFrame.from_csv` reads an open IO as well as a path, so CSV already
  in memory need not go through a temporary file first. A String argument is
  still always a path, never CSV text.

- New: `inspect_full` renders an array the way `inspect` does but without the
  `...` abbreviation.

- New: `repeat` lays each element of an array down several times --
  `v.repeat(2)`, or `v.repeat([3, 1, 2])` for a count each. It is not `tile`,
  which lays the whole array down again. The result is a view.

- New: `unique`, `nunique` and `mask_duplicates` take `along: k`, comparing
  whole sub-arrays instead of cells -- `z.unique(along: 0)` gives the distinct
  rows of a 2-D array. Giving both `along:` and `axis:` raises.

- New: each numeric data type names its own limits on its class --
  `CArray::Int32::MIN` / `MAX`, and `TINY` / `EPSILON` for float and complex
  types. `MIN` is the bottom of the range, where Ruby's `Float::MIN` is what
  is called `TINY` here.

- New: `CArray::Rng` is a random number generator with its own state, which
  `random!`, `randomn!` and `shuffle!` accept as `rng:` alongside a Ruby
  `Random`. Without `rng:`, or with a Ruby `Random`, nothing changes.

- New: `CArray#factorize` answers `[codes, levels]` in one pass, for a caller
  who wants the codes as storage rather than the `CACategorical` that
  `categorize` builds from the same two.

- New: C extensions only. `CA_FOR_EACH_FIBER_PAIR` and
  `CA_FOR_EACH_FIBER_PAIR_MASKED` yield one contiguous fiber from each of two
  sources at the same position.

- Change: `CArray.meld` (and `CAMeld.new`, and so `CAFrame.meld`) now treats a
  homogeneous list of Faces the way `CArray.stack` does: a Face whose state is
  per-parent is refused, and one that can be carried is kept on the result.
  `CAConstString` and `CAString` now raise `ArgumentError` — weld the storage
  instead, with `.parent`, or use `CArray.concatenate`. `CAFixlenString`,
  `CATime` and `CATimedelta` come back as themselves rather than as the raw
  storage; melding pieces whose Face state differs, such as two `CATime`
  columns in different units, now raises rather than welding the ticks. Lists
  of plain arrays, and a list of one, are unaffected.

- Change: `CAConstString.wrap` now checks the `(start, end)` pairs it is given
  against the buffer, and takes ownership of the offsets entity by marking it
  read-only. A pair outside the buffer raises `ArgumentError` naming the
  element; masked cells are exempt, since their bytes may be anything. Code
  that built a column with well-formed offsets is unaffected, except that the
  entity it passed can no longer be written afterwards — pass `.copy` to keep
  a mutable one. This also means the storage behind an existing column
  (`column.parent[i] = ...`) now raises rather than silently rewriting a column
  that reports itself read-only.

- Change: `all` and `any` on an `axis_group` reduction now require a boolean
  payload, as `CArray#all` / `#any` and the other iterators do. They folded any
  numeric payload, counting a non-zero cell as true, so `data.all` refused and
  `data[g].all(axis: :group)` answered for the same float array. Convert first
  if you meant the old reading: `data.ne(0)[g].all(axis: :group)`.

- Change: the `axis:` reductions on `group_by_category` now read the source
  array when asked, rather than some of them answering from a result kept
  from an earlier call. `sum`, `mean`, `min`, `max` and the counts shared a
  kept result per axis while `prod`, the variance family and `wsum` / `wmean`
  did not, so after a write through the source one iterator could report a
  mean and a variance that no data can produce together. Reading several
  members off one iterator now costs one kernel run each instead of one
  shared run; keep the result if you want the old sharing. The no-axis
  reductions are unchanged: they still work from the copy taken when the
  iterator was built.

- Change: `CAFrame#at(UNDEF)` now raises `ArgumentError` instead of returning a
  row. An index can hold a masked cell -- an `:outer` / `:right` join and
  `align` both produce one -- but a row with no label cannot be identified by
  one, and two undefined labels are not the same label; the key matching behind
  `join` and `align` already treats a masked key as matching nothing. Use
  `df.filter { |f| f.index.is_masked }` for the rows with no label, which also
  handles more than one of them. Asking for a real label whose cell is masked
  still raises `KeyError`, unchanged.

- Change: functions built on the C-extension bridge (`ca_call_cfunc_*`,
  `ca_call_cslab_*`, and `CAMath.spherical_to_xyz` / `xyz_to_spherical`)
  pair two array operands only when their shapes agree, and otherwise
  raise `ArgumentError` naming both shapes. Arrays of the same size but
  different shape, such as (2,3) and (3,2), used to be accepted and read
  in flat order; reshape one of them first. Arrays of different sizes
  raised `RuntimeError` before, so a `rescue` of that class needs
  updating. A scalar still pairs with any array.

- Change: `min`, `max`, `minmax`, `cummin` and `cummax` answer `NaN`, and
  `min_index`, `max_index`, `min_addr` and `max_addr` answer `UNDEF`, when every
  cell a float array contributes is `NaN`. They used to answer `Infinity`,
  `-Infinity`, the interval `[Infinity, -Infinity]` and position `0`. A `NaN`
  still loses to any number, so an array holding at least one number answers as
  before, as does one holding only real infinities. Empty and all-masked still
  answer `UNDEF`, and integer, boolean, fixlen and object arrays are unchanged
  -- an object array already answered `NaN`. To have `NaN` counted as missing
  rather than skipped, call `mask_invalid` first; `min_count:` and `fill_value:`
  act on masked cells and do not reach `NaN` ones.

- Change: the `CAConstString` ordering family takes `axis:` -- and `kind:` /
  `masked_position:` / `keep_axis:` where CArray does -- across `min`, `max`,
  `minmax`, `min_index`, `max_index`, `sort`, `sort_copy`, `sort_addr`,
  `sort_index`, `rank_index`, `order`, `partition_copy` and `partition_index`.
  Three answers move to CArray's: `sort_index` gives per-fiber indices where it
  gave view-flat addresses (ask `sort_addr` for those); `sort` with no `axis:`
  flattens first, where it kept the shape (a 1-D column is unaffected); and
  `min` / `max` on an empty or wholly masked column give UNDEF, not nil.

- Change: `CABlock#count` and `CAWindow#count` are gone. They gave back the
  per-axis number of cells the view exposes -- which is what `shape` answers
  -- and in doing so hid `CArray#count` on the two classes an indexing
  expression lands on most: `a[2...8].count(true)` raised `ArgumentError`,
  and `a[2...8].count` gave a shape rather than a population. Read the
  geometry with `shape`. `size0` / `start` / `step` / `offset`, which say
  where the view sits in its parent, are unchanged.

- Change: `CArray.jit_for`, `CArray.jit_each` and `CArray.jit_map` are no
  longer defined here; they arrive with `require "carray/jit"`. Without it a
  call raises `NoMethodError` where 3.0.1 raised `NotImplementedError`, so
  code that rescued that to fall back asks `CArray.respond_to?(:jit_each)`.

- Change: the Ruby attach surface is gone from released builds:
  `CArray.attach` / `.attach!`, `CArray#attach` / `#attach!`, and
  `#__attach__` / `#__sync__` / `#__detach__`. Write through the array
  directly instead. `CArray#attached?` and the C lifecycle are unchanged.

- Change: `a[1, :_]` returns a view of the axes `:_` asked for instead of
  raising `IndexError`. To keep an axis rather than drop it, index it with
  something that is not a scalar -- `a[[1], :_]`.

- Change: C extensions only. A kernel iterator init the engine refuses now
  raises instead of returning a code the block macros discarded. To handle a
  refusal rather than propagate it, call `ca_iter_state_init_l1` / `_l2`
  directly and read the code.

- Change: `CACategorical.from_codes` now materialises `codes` when it is a
  view rather than an array of its own, so writing through the array the view
  was taken from no longer changes the categorical underneath it. A wrapped
  memory view is an array of its own and is still adopted without a copy, so a
  zero-copy import stays zero-copy. The array you pass is never marked
  read-only beyond what you handed over.

- Change: `CACategorical.from_codes` now checks what it is handed and
  normalises it. It raises `ArgumentError` for duplicate labels, for more
  labels than the codes data type can carry once its top value is reserved as
  the exclusion sentinel, and for an unmasked code outside `0...labels.size`
  that is not the sentinel. A cell that arrives masked also gets the sentinel
  written into its code byte, so the mask and the byte now agree for every
  reader, a byte-reinterpret export included. Codes built by `categorize`
  already satisfy all of this, so nothing changes for a categorical made that
  way.

- Change: `search_nearest` and `search_nearest_addr` work on an object array of
  numbers, and say why when they cannot. They measured only with `#distance`,
  and since `Numeric#distance` became an opt-in refinement -- which a C-level
  call does not see -- that raised `NoMethodError` for an Integer as readily as
  for a String. A number is now measured as `(query - cell).abs`, exactly for
  Rational and BigDecimal; an object defining a real `#distance` still uses it;
  anything else raises `CArray::DataTypeError` naming the query's class, and
  points at `search` / `bsearch` for an exact match. Numeric arrays are
  unaffected.

- Change: `CAFrame.from_csv` reads a missing field as UNDEF in every column,
  not only in one named by `types:`. An unquoted empty field, and a cell a
  short row never reached, used to arrive as a Ruby `nil` sitting in an
  uncast column, so a mask written by `to_csv` did not survive the trip back.
  A quoted empty field (`""`) is still the empty string, which is a value.
  Code that worked around this with `col[:eq, nil] = UNDEF` can drop the line.

- Change: `CArray.time` reads a string array about eight times faster with an
  explicit `format:`, and about three times faster letting it auto-detect --
  so `CAFrame#parse_to_time`, which calls it, speeds up by the same amount.
  Parsed values are unchanged.

- Change: `window` accepts `bounds:` as a Symbol as well as a String, which is
  the spelling `windows` already took. Strings keep working.

- Change: C extensions only. A partial fill of an array backed by a CAObject
  or CASource subclass takes the `fill_block` / `fill_addrs` slots where the
  subclass defines them, instead of one `store_addr` per cell. Which cells are
  written is unchanged, and a subclass defining no fill slot keeps the
  per-cell path.

- Fix: `is_in`, `count(v)`, the set operations, `locate_addr`, `search`,
  `bsearch` and `linear_section` no longer compare a Face operand by its
  storage when that storage is not the value it shows. Passing a
  `CAConstString` (whose cells are byte ranges) to one of these on another
  Face used to answer from the byte ranges: where the two cell widths
  coincided — a `CAConstString` cell is 16 bytes, and so is a
  `CAFixlenString` cell whose column is 16 bytes wide — you got a wrong
  answer with no error, and a set operation could return raw offset bytes as
  its values. Such an operand now raises `ArgumentError`; convert it first,
  with `#to_string` for a string Face, or pass `.parent` on both sides to work
  in storage space. Plain operands, and Faces whose cells are their values
  (`CAString`, `CAFixlenString`), are unaffected, as is the cross-unit
  reconciliation `CATime` does through `to_comparable`.

- Fix: the reductions without `axis:` on `group_by_category` now agree with one
  another about which values they are reducing. `cumsum` and the other scans
  read the array when called while every other member worked from the copy
  taken when the iterator was built, so a write through the source between two
  calls was visible to one and not the other. All of them now answer about the
  values as they were when the iterator was built; build a new iterator to pick
  up a write. The `axis:` reductions read the array when called, unchanged.

- Fix: `CArray.load_from_file` no longer exhausts the stack. It was
  registered for autoload but defined nowhere, so calling it recursed until
  Ruby gave up; it now raises `NoMethodError` like any other method that does
  not exist. Use `CArray.load`, which is unchanged. An autoload registration
  whose library defines no such method now says which method and which
  library, rather than recursing.

- Fix: a `group_by_category` reduction over a read-only Face — a
  `CAConstString` column — no longer fails with an `IndexError` about a buffer
  range. Such a Face cannot be built by writing into it, so `min`, `max` and
  the other value members hand back the surface values (the strings) rather
  than the Face. A writable Face such as `CATime` still answers in its Face.

- Fix: a group iterator from `axis_group` now answers `shape`, `ndim` and
  `dim`, which every other iterator answers and which it returned `nil` for,
  and its `count` takes the two forms the family declares: `count(UNDEF)` for
  masked cells and `count(v)` for cells equal to `v`. Both previously raised
  `ArgumentError` about the number of arguments.

- Fix: a `group_by_category` reduction over values that carry a Face (a
  `CATime` column, say) now answers in that Face, as `CArray`'s own reduction
  does: `min`, `max` and `median` come back as a `CATime` of elements rather
  than failing with an internal message about a zero width. A member the core
  does not define for that Face still refuses, in the core's own words.

- Fix: the band-only classifier shape for a `group_by_category(axis:)`
  reduction is now reachable on a two-dimensional source, where it was
  refused and the refusal listed it among the accepted forms. Where both the
  case A shape and the band-only shape fit, which a square source allows,
  case A is taken, as before. The refusal no longer names `sum` when another
  reduction was the one called.

- Fix: `count(axis:)` and `count_not_masked(axis:)` on `group_by_category`
  now work for a complex, boolean or object payload. They counted cells
  through a numeric-only kernel, which refused those payloads for an answer
  that never depended on the payload. The no-axis form already worked.

- Fix: a `group_by_category` iterator whose classifier does not line up
  cell-for-cell with the value now says so. A no-axis reduction on one raises
  `ArgumentError` naming the mismatch and pointing at the `axis:` form, rather
  than a `NoMethodError` about `nil`; `elements` raises the same instead of
  answering `nil`; and `inspect` says "per-fiber only" instead of printing an
  empty grouping. `accumulate(axis:)`, which failed outright on such an
  iterator, now works.

- Fix: a reduction from `group_by_category` now hands back an array of the
  caller's own. `min`, `max`, `minmax`, `count`, `count_not_masked`,
  `elements`, `min_index` and `max_index` returned the iterator's memo itself,
  so writing into a result changed what that iterator answered from then on,
  and changed it for the other members reading the same memo. `sum` already
  copied. Nothing to change in calling code unless you relied on writing
  through a result.

- Fix: an `axis_group` reduction or scan that raises part-way through no
  longer leaks the working memory it had taken. An object-valued scan
  (`cumsum`, `cummax` and the rest) calls back into Ruby for every cell, so a
  value that will not coerce or a `<=>` that answers `nil` raises from an
  ordinary call and used to leave roughly 36 bytes per source element behind
  each time. Nothing to change in calling code.

- Fix: `CAFrame#set_index` on a frame that already has an index no longer
  discards it. The index being replaced now goes back to being a column, the
  same demotion `reset_index` performs and in the same position, so re-indexing
  keeps every column and `set_index("b")` on a frame indexed by `"a"` is the
  same as `reset_index` followed by `set_index("b")`. Previously the column the
  old index had been made from was gone, with nothing said.

- Fix: `CAFrame#reset_index` now restores the row axis name the frame had
  before `set_index` promoted a column over it, so the two are each other's
  inverse as documented. It used to leave `"row"`, which is user-visible: the
  row axis name is the header of the index's column in `to_csv` and its key in
  a row `Hash`. A frame built with an index, or derived from one, never had an
  earlier name, so `reset_index` still leaves the default there.

- Fix: `min` and `max` on an `axis_group` reduction now answer in the source
  array's data type, as `CArray#min` / `#max` do, instead of float64 -- an
  int64 beyond the float mantissa came back rounded. A boolean array answers
  as its 0/1 numeric storage (`all` / `any` are the boolean-returning twins).
  A group holding nothing but `NaN` now answers `NaN` rather than the
  accumulator's infinity, and `min_addr` / `max_addr` answer UNDEF for it,
  since no cell won.

- Fix: an `axis_group` reduction over a grouping whose group axis has length
  zero now answers each output cell the way a group with no member is answered
  -- `sum` 0, `prod` 1, `count` 0, `all` true, `any` false, and UNDEF for
  `mean`, `min`, `max`, `min_addr`, `max_addr` and the variance family. It
  previously returned an unmasked 0 for all of them, so a mean and a variance
  both read as 0.0. A zero-length band axis, which reduces to no cells at all,
  is unchanged.

- Fix: a per-category `min`, `max`, `min_index`, `max_index`, `median`,
  `percentile` or `quantile` from `group_by_category` now treats `NaN` the way
  `CArray`'s own reduction does: a `NaN` loses every contest, a category
  holding nothing but `NaN` answers `NaN` for an extremum and UNDEF for a
  position, and an order statistic sorts `NaN` last. Before, the answer
  depended on where in the category the `NaN` sat, so the same values in a
  different row order gave different results. Nothing to change in calling
  code.

- Fix: `p` / `inspect` on a `CAFrame` whose only data is its index now shows the
  table. It printed the summary line alone, because it gated on the column set
  while the table itself counts the index as a column.

- Fix: `CAFrame` no longer reports a row count that nothing in the frame backs.
  Splicing a frame that has no columns into another that has neither columns nor
  an index left the target claiming the spliced frame's row count, while its own
  `copy`, `head` and `filter` all answered 0 and it would then accept only
  columns of that length. The count is now read off a column, or off the index
  when there are no columns. Nothing to change in calling code.

- Fix: `CAFrame`'s `df[rows] = UNDEF` now refuses a row outside the frame on a
  frame with no columns, as the read and delete forms already did. It used to
  return quietly, because the bound check came from the column indexer the
  selector was handed to and there was no column to hand it to. Masking a row
  that does exist on such a frame is still a no-op -- there are no data cells,
  and the index is left alone by design.

- Fix: `CAFrame`'s `to_table` (and so `p` / `puts` / `to_s`) now prints a masked
  element inside an N-D cell as `_`, the marker it already used for a masked
  scalar cell, instead of the literal `UNDEF`. Nothing to change in calling
  code.

- Fix: `CAFrame#group_by` with a composite key no longer makes a group of its
  own for rows whose key has a masked component. Such a row now forms no group,
  which is what a single masked key cell already did. Nothing to change in
  calling code unless you relied on the UNDEF-labelled group.

- Fix: two `CAFrame` verbs that change every column now decide before changing
  any, so a column that refuses no longer leaves the frame half-changed in an
  order that depends on how the columns were inserted. `df[sel] = UNDEF` on a
  frame holding a read-only column (a categorical) raises without masking
  anything, and `promote(type)` raises without casting anything when some
  column would narrow. Nothing to change in calling code.

- Fix: `CAFrame.from_records` now reads a `nil` cell back as UNDEF in every
  column, not only in one a numeric cast happens to convert. A string, boolean,
  object or N-D column used to keep the `nil` as a value, so a mask written by
  `to_records` did not survive the trip and a row with no index label came back
  labelled `nil`. Note that the data type is still rebuilt from the values, so
  an integer column returns as `int64` and a boolean column as an object
  column; `cast` afterwards if the exact type matters.

- Fix: a CSV written from a frame with a single column -- or with only an
  index -- now reads back with all of its rows. A masked cell is written as an
  empty field, which for a one-column row is a line with nothing on it, and the
  reader skipped it as a blank line. Blank lines in a file with more than one
  column are still skipped, as a row there always carries a separator. Nothing
  to change in calling code.

- Fix: linear gap-fill on an **integer** array no longer fills the cells
  outside the interpolable span with `0` and drops their mask. It now leaves
  them masked, as it already did for a float array and as the documentation
  says. This covers `unmask(method: :linear)` and `strip_mask(method: :linear)`
  as well as `CAFrame#fill(name, :linear)`, with or without a frame index.
  Nothing to change in calling code.

- Fix: on a frame grouped by a numeric column, `CAFrame`'s `mean`, `sum`, `min`
  and `max` shortcuts now work. They raised `axis_name "..." collides with a
  column of the same name`, because the key column was reduced into the result
  while also being its index; a key only stayed out of the way when its data
  type was one a reduction skips anyway -- a string, boolean, categorical or
  time column. A composite numeric key no longer returns its key columns as
  reduced columns either, so it gives the same column set a composite string
  key gives. `aggregate` and `table` were never affected. Nothing to change in
  calling code.

- Fix: `CAFrame#filter(keep_masked: true)` no longer hands back a frame whose
  index writes through to the original. Its columns were already independent,
  so writing the result's index changed the original while writing its columns
  did not. The result is now materialized throughout -- columns and index --
  whether or not the selector actually carries a masked cell, so the same call
  site no longer switches between sharing and copying depending on the data.
  Code that wants a frame sharing storage with the original should use plain
  `filter`, which is still a view-frame.

- Fix: reductions, scans and order statistics no longer leak memory when
  reading their source raises part way through -- for example
  `cumsum`, `sum` or `median` over a float64 view of an object array
  holding a cell that is not a number. Each call used to leave the
  slab the walk was gathering into behind. Nothing to change in calling
  code.

- Fix: `a[sel]` no longer leaks memory when reading the boolean selector
  raises -- for example `fake(CA_BOOLEAN)` over an int32 array holding a
  2. Nothing to change in calling code.

- Fix: a view that converts on read -- for example `fake(CA_BOOLEAN)` over
  an int32 array holding a 2 -- now raises every time it is read, where
  the second read used to succeed silently and return values from a
  half-converted buffer. A view stacked or melded over such an array no
  longer leaves its other parents attached when the read raises, and a
  reshape of a lazy view no longer leaks its buffer. Nothing to change in
  calling code.

- Fix: for C extensions, a callback passed to `ca_call_cfunc_*` or
  `ca_call_cslab_*` may now `rb_raise` to refuse a value: the bridge
  detaches and frees what it holds before the exception propagates,
  where it used to leave an output view attached and its scratch memory
  behind. The outputs are left partly written. Nothing to change in
  calling code.

- Fix: when `to_type` on a view raises part way through the cast -- for
  example an int32 value other than 0 or 1 cast to boolean -- the view is
  no longer left holding a stale copy of its parent, which made later
  reads through it return the old values. Nothing to change in calling
  code.

- Fix: `copy` and `strip_mask(fill)` no longer leak the result's memory
  when reading the source raises part way through -- for example a
  float64 view of an object array holding a cell that is not a number.
  Nothing to change in calling code.

- Fix: functions built on the C-extension bridge (`ca_call_cfunc_*`,
  `ca_call_cslab_*`, the `CA_FOR_EACH_ELEMENT` macros, and
  `CAMath.lgamma` and its siblings) no longer leak memory, or leave an
  output view attached, when reading an operand raises part way through
  -- for example a float64 view of an object array holding a cell that is
  not a number. Nothing to change in calling code.

- Fix: `is_in`, `intersection`, `difference` and `union` take an Array or Range
  of Strings against a fixlen array, where every such call raised
  `CArray::DataTypeError` -- `CAFixlenString` included. The set is built at the
  array's cell width, so a short String matches a padded cell the way it does
  everywhere else. A set given as a CArray must still be of that width; when it
  is not, the refusal now says which width was wanted instead of reporting a
  data type mismatch between two fixlen arrays.

- Fix: comparing a fixlen array against a String compares it as a value of
  that array's cell width. The String became an object operand, so `eq` / `ne` /
  `lt` / `gt` / `ge` / `le` and the `[:eq, v]` indexer ran `String#==` per cell
  against the cell's NUL-padded text -- and an array pads a short String on
  write, so `a[i] = "be"` then `a.eq("be")` was false, `a.gt("be")` was true,
  and the scan took 30x longer than the same one in `search`. Two fixlen
  arrays of different widths compare as before, as does a Regexp for `match`.
  `CAFixlenString` was never affected.

- Fix: `percentile` and `median` no longer interpolate between objects that
  have no arithmetic. On a column of Strings `percentile(30)` quietly answered
  `""` and even-length `median` raised `NoMethodError` from inside a funcall;
  both now raise `CArray::DataTypeError` naming `method: :lower` / `:higher` /
  `:nearest`, which pick an element and work. A `p` that lands exactly on an
  element (`percentile(50)` of five) still answers, as does an odd-length
  `median`. Numbers stored as objects -- Integer, Rational, BigDecimal -- are
  unaffected.

- Fix: `sort_copy` takes whatever `sort` takes. It refused everything its own
  fast path could not handle, so an object or boolean array sorted through
  `sort` and raised `CArray::DataTypeError` through `sort_copy`; complex, which
  neither can order, refused differently depending on which one was asked, and
  now refuses alike. Numeric arrays keep the fast path and are unchanged.

- Fix: `CAConstString#sort_addr`, `#sort_index`, `#rank_index`, `#order`,
  `#min_index`, `#max_index`, `#partition_copy` and `#partition_index` read the
  strings. They read the `(start, end)` offsets that hold them, which order by
  how the column was packed, so they gave well-formed wrong answers rather than
  raising: `sort_addr` on an unsorted column gave the identity, and
  `partition_copy` gave NUL bytes. `#minmax` answers instead of raising, and
  sorting a column with masked cells no longer raises.

- Fix: `to_const_string` gives an N-D source back with its shape instead of
  flattened, and `CAConstString#unique` / `#mode` / `#mask_duplicates` /
  `#intersection` / `#difference` / `#union` keep the column's encoding --
  on a column that was not UTF-8 they raised out of the builder's check.

- Fix: `each_with_index` and `map_with_index!` no longer raise
  `SystemStackError` on a long array, and neither do `CArray#format` /
  `CArray.format`, which are built on them. The ceiling was the C stack, so
  where it fell depended on where the code ran: around a million cells on the
  main thread, under a hundred thousand inside a `Thread`.

- Fix: `CArray.concatenate` and `CArray.mosaic` take a zero-length piece --
  an empty slice such as `a[0...0]`, or `CArray.int32(0)` -- instead of
  raising `IndexError`. The piece contributes nothing and the remaining ones
  concatenate as before. `CArray#paste` likewise accepts a source covering no
  cell, and writes nothing.

- Fix: C extensions only. A kernel writing into a view the caller supplied now
  reaches the array; writes were lost, or crashed, for several view kinds
  iterated along an axis whose fiber is not contiguous. Kernels writing into
  an array they allocated themselves were never affected.

- Fix: `CArray#each_slab` yields a read-only slab, and writing through it
  raises rather than reaching the array on one axis and being dropped on
  another. Return values from the block instead, or assign through the array.

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
