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

## 3.0.4 (unreleased)

- Change: the values a `CAFrame` group's `table` block or a Proc
  reduction of `aggregate` returns become typed columns, as `from_records`
  types a record's values: Integers int64, numbers float64, arrays of one
  shape an N-D column, the rest object; `nil` and `UNDEF` are missing.
  Every such column was object before. Read a returned array from the N-D
  column as `col[i, nil]`, where `col[i]` gave it before.

- Change: `CAFrame#data_types` gives a Face column's class (`CATime`,
  `CAString`, `CACategorical`, ...) where it gave its `data_type`, which
  for most Faces is `:fixlen` -- the surface their kernels dispatch on,
  not what the column holds. Plain columns still give a Symbol. The column
  list of `p df` and the head of a Face's `inspect` name the Face the same
  way (`time:CATime[D]`, `<CAConstString(3)`). To test a column's storage
  type, use `df[name].parent.data_type`.

- New: every iterator (slab, block, window, segment, categorical and axis
  group) has `first`, `last` and `nunique`: the first and last present
  value of each piece (UNDEF for none) and its number of distinct present
  values (0 for none). A `CAFrame` group reduction reaches them too, so
  `df.resample("time", "1 hour").aggregate("open" => ["v", :first], ...)`
  keeps the column's type. Like the core ones, they take no `min_count:`
  or `fill_value:`.

- Change: `CArray#nunique(axis:)` takes an Array of axes, and naming every
  axis returns an Integer, as `sum(axis:)` does. Before, a 1-D
  `a.nunique(axis: 0)` returned a one-element CArray; read it as an
  Integer, or pass `keep_axis: true` to keep an array.

- Change: storing an integer that an integer cell cannot hold raises
  `RangeError`, as an operator already did (`int8_array + 300`). Before,
  `CA_INT8([300])`, `a[0] = 300`, `a[] = [-1]` on an unsigned array,
  `fill`, `elem_store`, a record member and `fill_value:` wrapped it
  (`300` into `int8` was `44`, `-1` into `uint8` was `255`). A Float is
  truncated first, so `1.9` still stores as `1`, but `1000.0` into `int8`
  raises. To keep the wrap, cast between arrays: `to_type` (including from
  an object array) still converts as C does.

- Fix: copying a Face (`refer`, a slice of a time or string array) read
  past the end of its struct, which could crash.

- Fix: `CAFrame#resample` with month or year bins and `fill: true` gave
  labels in the bins' unit (`2024-01`) where the same call without
  `fill:` gave them in the time column's unit (`2024-01-01`). Both are
  now in the time column's unit.

- Fix: `CArray.time` with `format:` read an Integer as Unix seconds, so
  `CArray.time(CA_INT64([20000101]), format: "%Y%m%d")` gave 1970-08-20.
  With a format, an Integer is now read as its digits. `%s` and `%Q`
  (seconds and milliseconds since the epoch) are now read, for Integers
  and Strings alike; they raised before.

- Fix: dividing a `CATimedelta` array by another truncated the ratio to
  an integer (90 s / 60 s gave 1). It is now a float64 array (1.5), the
  two durations brought to a common unit first.

- Fix: `locate_addr` with a reference given as an Array or Range compared
  in the object lane, so `float_array.locate_addr(1..3)` and
  `float_array.locate_addr([1, 3])` found nothing. The values now meet the
  array at a common type, as `is_in` meets them, so `2` finds `2.0`.

- Change: `is_in`, `intersection`, `difference` and `union` refuse a Range
  (`ArgumentError`). They read it as the set of its steps, so
  `float_array.is_in(2..4)` missed 2.5, a float or endless Range raised,
  and a long one built every step. Pass the values as an Array
  (`a.is_in((1..3).to_a)`), or compare an interval as
  `(a >= lo) & (a <= hi)`. `locate_addr` and `CAFrame#align` still take a
  Range as the list of its steps.

- Fix: `is_in` with a single value (`float_array.is_in(2)`) compared in the
  object lane, so a float array never found an Integer; the set operations
  (`intersection` and the others) did the same. A single value is now a set
  of one, as `[2]` is. A String looked for in a numeric array, as a single
  value or in an Array, raised `unknown data_type representation`; it is now
  a value that matches nothing.

- New: `CAFrame#is_duplicate(*names)` gives a boolean column, true for the
  rows that repeat an earlier row in the named columns (every column when
  none are named); `df[df.is_duplicate.not]` keeps one row of each.
  `except: :last` leaves the last occurrence unmarked instead of the first,
  and `except: :none` marks every repeated row, so its negation is the rows
  that appear once. A row with a masked cell in those columns is never a
  duplicate.

- Fix: `CAFrame.from_records` with records that spell one column both as a
  Symbol and as a String (`{ :temp => 1, "temp" => 2 }`, or `temp:` in one
  record and `"temp"` in another) kept one of the values and dropped the
  other. It now raises `ArgumentError`; use one spelling.

- Change: CAFrame takes column names as Strings only. `CAFrame.new({ a:
  col })`, `df.drop(:a)`, `df.select(:a)`, `df.rename("a" => :b)`,
  `df.join(other, on: :a)` and the other verbs that name a column turned a
  Symbol into a String; they now raise `TypeError` naming the verb. Write
  the name as a String (`"a"`). The keys of the records given to
  `from_records` may still be Symbols.

- New: `CAFrame.from_csv(path, columns: { 2 => "code", "c7" => "area" })`
  selects columns by the Hash's keys (names or indexes, as `columns:` takes
  them) and names them with its values; `types:` and `missing:` use the new
  names. `column_names:` still names the file's columns.

- New: the `sum` / `mean` / `min` / `max` of `CAFrame#group_by` and
  `resample` take column names and return those columns as `df[...]` does:
  `grp.mean("temp")` is a CArray, `grp.max("temp", "rh")` an Array of two.
  Without names they return a frame of every column, as before.

- New: `keep_rows: true` on the reductions of `CAFrame#group_by` and
  `resample` (`sum` / `mean` / `min` / `max`, `aggregate`, `table`) gives
  each row the result of its own group, in the frame's rows and index:
  `df["temp"] - df.group_by("station").mean("temp", keep_rows: true)` is the
  anomaly from the station mean. A row whose key is masked is `UNDEF`.

- Fix: a raise while an array's mask is read no longer leaks memory.
  Converting an array whose mask a `CAObject` answers in Ruby (`to_type`,
  `int32` and the like), taking a view of such an array (a slice,
  `transpose`, `reshape`, `tile`, `roll`, `shift` and the like), indexing
  it with an index array, and
  `CArray.wrap_memory_view` / `from_memory_view` with a `mask:` whose
  MemoryView export raises left the new array's buffers, the index copy or
  the MemoryView holders behind. Nothing to change in calling code.

- Fix: `cond.then_else("yes", "no")` raised `ArgumentError` (`"yes" is
  unknown data_type representation`), and `then_else("int32", ...)` took
  the String as a data type. A String or Symbol branch is now a value,
  and the result is an object array.

- New: `CAFrame.from_csv(path, header: false, columns: ["c1", "c2"])`
  selects columns by the names a file without a header gets (`c0`, `c1`,
  ...). Before, only indexes selected there.

- New: `CAFrame#cast` takes `:categorical`, which makes the column a
  `CACategorical` of its values, so `from_csv(path, types: { "station" =>
  :categorical })` reads a column of repeated text as categories. A text
  column read with `types:` becomes categories without a String made per
  cell, only one per distinct value.

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
