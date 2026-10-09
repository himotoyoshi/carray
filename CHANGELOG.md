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

## 3.0.3 (unreleased)

- Fix: `min` and `max` of a raw fixlen array grouped by a categorical
  (`group_by_category`) raised `invalid bytes`; they now answer per group.

- Fix: `CAFrame.from_csv` reads an input with no record at all (an empty
  file, or only blank lines) as a frame with no columns and no rows, which is
  what `to_csv` writes for such a frame. It used to raise `MalformedCSV`. A
  header expected after skipped lines still has to be there.

- New: CAFrame reads booleans from CSV: `types: { "flag" => :boolean }` (and
  `cast("flag" => :boolean)`) reads `1` / `0` and `true` / `false` in any case,
  with a blank field as UNDEF and other text handled by `on_error:`.
  `types: :infer` reads a column of `true` / `false` as boolean; a column of
  0 / 1 is still inferred as integers. `cast(name => :boolean)` on an integer
  column now follows `on_error:` for values other than 0 and 1 instead of
  always raising.

- Change: `to_csv` writes a boolean column as `1` / `0` rather than
  `true` / `false`. Files written before still read back as boolean with
  `types: { name => :boolean }`.

- Change: `locate_nearest_addr` now finds a match beyond the ends of the
  reference when its `direction:` names one: `:floor` takes the last value for
  a cell after it, `:ceil` the first value for a cell before it, and `:round`
  the nearer end. These cells used to be masked. The same holds when the
  reference has a single value. `join_asof`, `CArray.align_nearest_addr` and
  `snap_to` follow (`snap_to` still masks or fills the cells outside the list
  as `lfill:` / `ufill:` say). Pass `tolerance:` to refuse a match that is too
  far away.

- Change: a time array compares with, searches for and stores a `String` or a
  `Date` as well as a `Time`, so `t.eq("2024-01-02")`, `t.is_in(["2024-01-02"])`
  and a CAFrame time index's `at("2024-01-02")` work, and `t[0] = "2024-01-02"`
  stores it. The text is read in the grammar `CArray.time` reads. A `Time`,
  `Date` or `String` is read at the precision it carries: one that is not on
  the array's grid (09:00 against a day-unit array) now raises, where a `Time`
  used to be floored onto the grid and match the day.

- Fix: `dup` and `clone` of a view now keep what the view was: the copy of
  `x.value` (or of its reshape) could take UNDEF into the mask of `x`, and
  `clone` of a frozen array answered `read_only?` false. A copy of a mask
  (`x.mask.dup`) is a mask again and refuses a mask of its own. `dup` and `clone` of
  a view still return another view onto the same storage; to copy a CArray,
  use `copy`.

- Fix: `reshape`, `flatten`, `insert_axis` and `[:_, ...]` now keep what the
  array they start from means. On `x.value` they read the mask of `x` again,
  so `x.value.sort`, `.cumsum`, `.median` and `.unique` skipped the masked
  cells (or raised) instead of reading their values; on a read-only view
  such as a broadcast they gave a writable view onto the original array.

- Fix: comparing a `CATime` or `CATimedelta` array of two or more
  dimensions with a single value (an element, a `Time`) no longer raises a
  shape mismatch; it compares every cell with that value, as a 1-D array
  already did.
- Fix: `broadcast_to` on a Face (`CATime`, the string faces,
  `CACategorical`, ...) returns the same Face instead of a plain array of
  its storage.
- Fix: `CArray.meld` reductions answer as on a copy: `min` / `max` /
  `stddev` / `stddevp` with `axis: 0` on a 1-D meld no longer raise; `mean`
  of an object meld stays exact (Rational, Integer division) instead of
  returning a Float; the variance family of a complex meld no longer
  returns a wrong complex value; `mean` / `stddev` of a meld of `CATime` /
  `CATimedelta` no longer raise.
- Fix: a copy of the mask of a `CArray.stack` / `CArray.meld`
  (`s.mask.dup`) writes to the parents' masks. Before, what it wrote did
  not reach the parents and was lost at the next write through `s.mask`.
- Fix: a stack or meld with a value array (`a.value`) among its parents
  takes writes when another parent is masked. Before, every write raised
  "can not store data to read-only array". Writing UNDEF into the value
  array's cells raises `TypeError`, as writing it into the value array
  does.
- Change: `CArray.stack([face])` of a single Face array (CATime,
  CAConstString, ...) returns that Face, as `CArray.meld` does; it used to
  return the raw storage. `CArray.meld`, `CAMeld.new` and `CAStack.new`
  raise `ArgumentError` for a list mixing Face and non-Face arrays, or two
  Face classes, as `CArray.stack` already did; they used to return the raw
  storage.
- Fix: a view of a `CArray.stack` / `CArray.meld` that swaps a length-1
  axis with another (`stack([r1, r2]).transpose(1, 0, 2)` with `r1` of
  shape `[1, 3]`), or that reshapes a flat window back to rows
  (`s.reshape(9)[1..6].reshape(2, 3)`), returns the right cells. Before,
  reads returned other values or memory outside the parents, and writes
  landed outside the parents' buffers.

- New: `CAFrame#cast` takes what `from_csv` and `from_records` take as
  `types:`: `cast(:infer)`, and a map with `default:` (`:infer` or a type)
  for the columns it does not name, where `nil` leaves a named column as it
  is. `option_name: :types` makes an error about the map name that option,
  for a reader that passes its own `types:` to `cast`.
- Change: `CAFrame#cast` raises `ArgumentError` for a Symbol map key other
  than `default:` (`cast(temp: :float64)` used to cast the column "temp");
  name the columns with Strings.
- Change: errors a caller can cause no longer raise `RuntimeError`. A
  shape, size, step, offset or option the operation cannot take raises
  `ArgumentError` (`b[] = c` with another shape, `reshape`, `broadcast_to`,
  a zero step, a negative dimension, an unknown data type name, a corrupt
  `_CARRAY3` stream for `load`); a data type it cannot take raises
  `CArray::DataTypeError` (`result_type` without a common type, `abs!` /
  `arg!` whose result type differs); an integer array cast to boolean with
  a value other than 0 or 1 raises `RangeError`; an object that is not a
  CArray where one is needed raises `TypeError`; `a[:x]` raises
  `IndexError` and `df[:x]` `ArgumentError` (both were
  `NotImplementedError`). Code that rescues `RuntimeError` around these
  needs the new class. A write to a read-only array and a `to_ca` that
  refuses `writable: true` still raise `RuntimeError`.
- Change: a frozen `CAFrame` refuses `[]=`, `set_index`, `reset_index`,
  `cast`, `promote`, `parse_to_time`, `to_time`, `fill` and `mask_eq` with
  `FrozenError`; `df["c"] = col` used to add the column. The verbs that
  return a new frame work as before, and the columns' own cells can still be
  written through the columns.
- Change: `windows` takes a Range of Integer offsets for each axis and raises
  `TypeError` for anything else (`nil`, an Integer, an endless range). An
  exclusive range leaves out its end: `windows(-1...1)` is the offsets -1
  and 0; it used to be read as `-1..1`.
- Fix: `blocks` and `windows` over an array with no cells, and a
  `bounds: :truncate` window wider than its source, return an empty array of
  the reduction's type instead of raising.
- Change: an array branch of `then_else` pairs with the condition as an
  operator's operands do. A branch in another shape with the same number of
  cells raises `ArgumentError` instead of being read in the condition's
  order, and a size-1 axis broadcasts. An object or fixlen result needs the
  condition's shape exactly.
- Change: a `bitarray` view has no mask. The bits of one byte would share
  that byte's one mask cell, so `bitarray` raises `ArgumentError` on an
  array with a mask (read its bits with `value.bitarray`), and a bit view
  refuses `mask=`, `UNDEF` and masked arrays instead of masking or
  unmasking the whole byte. `pack_bits` raises on masked cells instead of
  writing them as bits; pack the mask with `validity_bits`.
- Change: when an operator cannot combine its two operands, it raises
  `TypeError` instead of `RuntimeError`. Code that rescues `RuntimeError`
  around such an operation needs to rescue `TypeError`.
- Fix: when an operator cannot combine its two operands, the error names a
  time, categorical, record or string column by its class
  (`'int64' and 'CATimedelta'`) instead of `'fixlen'`, the data type it
  stores its values in.
- New: the value reductions of `group_by_category`, `segments` and
  `group_by_run`, and `sum` / `mean` / `min` / `max` of a `CAFrame`'s
  `group_by` and `resample`, take `min_count:` and `fill_value:` as the core
  reduction does: a group with fewer than `min_count` present values is
  UNDEF, and `fill_value` fills the UNDEF cells
  (`df.resample("time", "1 hour", label: :right).mean(min_count: 6)`).
  `CAFrame` `aggregate` takes them as a third element,
  `["temp", :mean, min_count: 6]`. For `wsum` and `wmean` a present value
  is one whose weight is present too, as for `CArray#wsum` / `#wmean`.
  `quantile` takes neither, as `CArray#quantile` does not.

- Change: `inspect` of a `CATime` or `CATimedelta` array names the tick
  (`<CATime[us](7)`, `<CATimedelta[10 m](2)`) where it named the storage
  type (`fixlen[8]`), and writes each cell as `to_s` does
  (`2024-12-01T00:01:00Z`, `2024-12-01`, `60s`) where it wrote the cell's
  whole `inspect`. A time array writes the digits of a second that some
  present cell needs, the same in every cell. `inspect` of a single element
  is unchanged.

- Change: on an object array, `min`, `max`, `minmax`, `min_index`,
  `max_index`, `cummin`, `cummax`, `pmin`, `pmax`, `minimum`, `maximum`
  and `elem_min` / `elem_max` compare cells with `<=>`, as `sort` already
  did and as Ruby's `Array#min` does. They used `<` / `>`, so an element
  with only `<=>` could be sorted but had no minimum. A pair `<=>` cannot
  order raises `ArgumentError` ("comparison of A with B failed"), where
  `<` raised `NoMethodError`. A Float NaN still loses every contest.

- Fix: `&`, `|`, `^` (and `and` / `or` / `xor`) between an object array and
  a boolean array read the boolean cells as Integer 1 / 0, both true in
  Ruby, so `CA_OBJECT([true]) & CA_BOOLEAN([false])` was `[true]`, and
  raised with the boolean on the left. The boolean cells now take part as
  true / false. Arithmetic still reads them as 1 / 0.

- Fix: a group `count` / `count_not_masked` / `count_masked` / `elements`
  on an `axis_group` iterator over an object (or other non-numeric) array
  raised; they read only the mask and now answer. The group reductions
  that read the values raise `CArray::DataTypeError` naming the type
  (was `RuntimeError` with an internal type number).

- New: `CAFrame.from_csv(columns: [...])` reads only the columns named, or
  given by index from 0 (Integers and Ranges), in that order. The fields of
  the other columns are passed over without being made into Strings, so a
  few columns of a wide file take little more time and memory than a narrow
  file; 3 columns of a 50-column file of 100,000 rows read in 0.09 s, where
  reading it whole and selecting took 0.46 s. The reading block has the same
  as `columns`.

- Fix: the variance family on a `CArray.meld` of object arrays answered a
  Float where the copy answers an exact Rational or BigDecimal; it now
  gives the copy's answer.

- Fix: on an object array, `median` of an odd count and
  `percentile(method: :lower / :higher / :nearest)` raised for elements
  without `*` (Symbol, Date, ...), though they only pick an element;
  `percentile(axis:)` interpolated a fiber of Strings to `""` when the
  first fiber held numbers; and an empty axis or a banded `axis_group`
  answered float64 where every other path answers an object array.

- Fix: a reduction on an `axis_group` iterator dropped every keyword
  except `axis:`. A group reduction (`axis: :group`) now takes
  `min_count:` and `fill_value:` as a core reduction does and refuses any
  other keyword (`percentile(..., method: :lower)` used to be accepted and
  ignored); without `:group` every keyword reaches the plain reduction.

- Fix: on an object array, `is_nan`, `is_inf` and `is_finite` returned
  booleans that `count(true)`, `sum`, `all` and `&` misread (`is_inf` was
  true everywhere), and `signbit` was false for `-0.0`. `is_nan` now
  answers false for an Integer or a Rational instead of raising.

- Fix: `refer(:object, ...)` on a numeric array, and `field` on an object
  array, read raw bytes as Ruby objects (or objects as bytes) and could
  crash; both now raise.

- Fix: `stddev` and `stddevp` returned 0.0 where the variance is NaN (a
  NaN or an infinity among the values), on every data type; they now
  return NaN.

- Fix: `CACategorical#categorize` raised; it now categorizes by the labels,
  as for any key array (categories that have no cells are dropped). With it,
  `CAFrame#group_by` accepts a categorical column as a key, alone or in a
  composite key, and the result's index stays a `CACategorical`.

- Fix: `CAFrame#filter(keep_masked: true)` raised "can not modify
  read-only array" when the frame had a categorical or `CAConstString`
  column and a row's membership was undetermined. Those columns now carry
  the row as masked, keeping their class, as the other columns do.

- Fix: `linear_section` on a one-point axis put every value at position 0.
  A value equal to the point is at 0, and any other value is now out of
  range (NaN, or `nil` for a single value), as a value outside a longer
  axis is.

- Fix: `locate_nearest_addr`, and `CAFrame#join_asof` with it, accept a
  masked reference value and an empty query. A masked value matches
  nothing, as in `locate_addr`; before, either case raised an error naming
  `linear_section`. A reference with a single value matched every query
  to it; it now matches only the values equal to it, as a value outside
  the reference's range is masked.

- Fix: a column declared time (`from_csv(types: { name => :time })`,
  `cast(name => :time)`, `parse_to_time`) reads what `to_csv` writes for
  any `CATime`: a month (`"2024-01"`, read in months), a year (`"2024"`,
  read in years) and a year with a sign or more than four digits. Before,
  these cells came back masked. `types: :infer` still reads them as text
  or numbers. A `CATime` in years now prints a negative year with four
  digits (`"-0030"`, was `"-030"`), as the other units do.

- Fix: a `GroupedFrame` from `group_by` with a single key named its groups
  by the key as it was when a reduction ran, not when the grouping was
  taken: after a change to the key, groups could share a name or carry
  another group's. The index is now taken with the grouping; values are
  still read when a reduction runs (`docs/topics/CAFrame.md` §9). Each
  result frame also gets its own index, including after `resample`.

- Fix: text read as a complex number (`from_csv`, `to_type`, `cast`) reads
  what `Complex#to_s` writes for a part that is not finite, such as
  `"1.0+Infinity*i"` and `"NaN+0i"`. Before, such cells came back masked,
  so a complex column holding one did not survive `to_csv` / `from_csv`.

- Fix: `to_csv` quotes a value made only of spaces and tabs. A one-column
  frame whose column name was such a value lost its first row, and that
  row's value became the column name, when read back with `from_csv`.

- Fix: `from_csv(sep: " ")` read two spaces in a row as one separator
  when the file was read without the fast reader (with `strip: true`, or
  in an encoding other than UTF-8), so the columns after an empty field
  shifted left. With `sep: "\t"` or `sep: " "`, `strip: true` no longer
  takes the separator as padding, which shifted columns or raised
  `MalformedCSV` on a valid file.

- Fix: `unmask(value)` and `strip_mask(value)` on a `CATime` or
  `CATimedelta` read the value as `a[i] = value` does. A `Time` was taken
  as a count of seconds in the array's unit (a date column filled with
  2024-01-09 showed year 4669439), and an element of the same class
  raised `TypeError`. `CAFrame#fill(name, value)` is fixed with them.

- Fix: `CArray.meld` of a single Face array (`CATime`, `CACategorical`,
  `CAConstString`, the string Faces) returned the storage under it: ticks,
  codes or offsets. It now keeps the Face, as it does for two or more.
  `CAFrame#melt` with one value column, and `CAFrame.meld` of one frame,
  are fixed with it.

- Fix: `CArray.sort_addr` (the class method) ordered a `CAConstString` key
  by its storage rather than its strings, and a `CARecord` key by its bytes
  rather than its struct's `order_by:` members, and accepted a `CARecord`
  whose struct declares no order. It now orders them as their own
  `sort_addr` does, and raises for a record with no order.
  `CAFrame#sort_by_key` in ascending order is fixed with it.

- Fix: `each_slab`, `map_slab` and `reduce_slab` left their slab pointing
  at freed memory once the walk ended, unless the slab was a window onto
  an array's last axis. A slab (or `slab.dup`) kept past the walk read
  garbage, and over an object array the garbage collector could crash
  even when nothing was kept. A kept slab now shows the last slab; take
  `slab.copy` or `slab.to_a` in the block to keep each one (the docs
  used to suggest `slab.dup`, which shares the slab's data).

- Change: faster, with the same results: `CAFrame.from_csv` with `types:`
  reads two to five times faster on a file of numbers, as a column cast to
  a number is read from the text without making a String per cell. A column
  left as text is a `CAString` as before, now one of its own rather than a
  view over an array shared by every column. Without `types:`, or with
  `missing:`, the file is read as before.

- Change: faster, with the same results: `CAConstString#to_string` is
  about 25 times faster.

- Change: faster, with the same results: `CAFrame#infer_types`, and
  `from_csv(types: :infer)`, no longer read a whole text column to rule out
  time when its first cell that holds something is not a date or time.

- Change: faster, with the same results: text read as a float (`to_type`,
  a String stored into a float array, `CAFrame#cast`) is about eight times
  faster. The value is still the correctly rounded double `Float()` gives.

- Change: `CAFrame` raises `CAFrame::UnreadableColumn` instead of
  `ArgumentError` when a column's contents cannot be read: `cast` and
  `from_csv(types:)` under `on_error: :raise`, `parse_to_time`,
  `infer_time_format` / `parse_to_time(name, :infer)` when no format fits,
  and `to_time` on a float column with a fractional value. When more than
  one time format fits every cell, `infer_time_format` and
  `parse_to_time(name, :infer)` raise
  `CAFrame::AmbiguousTimeFormat`, whose `formats` lists them. Neither is an
  `ArgumentError`, so a `rescue ArgumentError` around these calls no longer
  catches them; rescue the new classes. Bad arguments still raise
  `ArgumentError`.

- Change: asking a `CArray.stack` or `CArray.meld` view about its mask
  (`has_mask?`, `mask`, `copy`, a reduction, ...) no longer gives its
  unmasked parents an all-unmasked mask; they are read as unmasked and
  left alone, and a mask a parent gains later shows through. Writing UNDEF
  through the view still gives every parent without a mask one.

- Change: `map_slab` carries the mask of the array the block returns into
  its result: a cell masked there is masked in the result. It used to
  write the value stored under the mask and drop the mask. A block that
  returns an array without a mask (`slab.value * 2`, a scalar) gives a
  result without one, as before.

- Fix: for C extensions: a `CA_KERNEL_WRITE` walk over a view that holds
  a cell of its array more than once (`tile`, an array stacked or melded
  with itself) lost the cells the kernel wrote when it left others
  alone: the untouched copies were sent back over them. A walk now sends
  back only the cells the kernel changed, as `[]=` does. A walk over a
  conversion or multi-array view also no longer sends the whole view
  back after every slab.

- Fix: reductions along an axis of an object-type view running in
  several Ractors at once could hang the process in the garbage
  collector; each Ractor now keeps its own record of the cells it holds.

- Change: for C extensions: `CA_FOR_EACH_FIBER_PAIR` and
  `CA_FOR_EACH_FIBER_PAIR_MASKED` raise `ArgumentError` when the two
  arrays differ in shape, as the INOUT forms do. They used to skip the
  body when the rank, element count or fiber length differed, and to pair
  fibers from unrelated positions when only the shape did.

- Fix: for C extensions: `ca_iter_state_init_l1` / `_init_l2` handed a
  NULL source crashed; they return `CA_ITER_ERR_FLAGS`, as the header
  says.

- Fix: `sum`, `min`, `max`, `mean` and the variance family on the mask of
  a `CArray.meld` view raised `NoMethodError`; they now answer as on the
  mask's copy.

- Fix: `each_slab`, `map_slab` and `reduce_slab` over a view (a
  transpose, a block, a lazy expression, a stack, ...) handed the block a
  slab whose derived arrays (`slab.dup`, `slab.sort_copy`, ...) read
  other memory, and could crash; they now read the slab's cells. A slab
  of several axes (`axis: [0, 2]`) is now taken from every kind of source:
  before, a lazy, stack, meld or `as_type` source, and some index-array
  views, raised `NotImplementedError`.

- Fix: `sort_copy`, `median`, `percentile`, `is_mode` and
  `mask_duplicates` along an axis of a `CArray.stack` view that was
  neither the stack axis nor the last axis read the wrong cells, and the
  same methods on a masked view selected with an index array
  (`a[nil, idx, nil]`) read the mask of the wrong cells. Both now give
  the answers of the copy.
- Fix: for C extensions: a `CA_FOR_EACH_FIBER` walk over those two kinds
  of view now gets its fiber and its mask as contiguous runs, as the
  header promises.

- Change: for C extensions and build scripts that read
  `CArray::VERSION_CODE`: it is now `major*10000 + minor*100 + teeny`
  (`30003` for 3.0.3), so 3.0.10 is `30010` and comes before 3.1.0
  (`30100`). It was `major*100 + minor*10 + teeny`, under which 3.0.10
  would have equalled 3.1.0. A check against an old-form value (`< 303`)
  still turns away 3.0.2 and earlier; compare against the new form from now on.

- New: `bitfield(range, type)` reads the field as an integer of `type`.
  A signed type reads the field's top bit as its sign (`0b101` in 3 bits
  is -3 as `:int8`), and a type wider than the field widens the value.
  The argument was accepted and ignored before; without it the type is
  the narrowest unsigned one, as it was.

- Fix: `bitfield` refuses an object array (writing the field rewrote the
  references held in the cells) and a field that starts inside a byte and
  reaches more than 64 bits past it (its top bits were dropped); both raise.

- Change: `bitfield` refuses a complex array, as `bitarray` does.

- Fix: `bitfield(-1)` is the last bit of the cell, as `bitfield(-1..-1)`
  is (it read a bit that was not there).

- Fix: `dup` and `clone` of a `bitfield` view whose field reaches past the
  width of its value type (`bitfield(4..11)` on a uint16 array) are the
  same field; the copy was a narrower one.

- New: `CAFrame.from_csv` takes `header:` (the line of the column names, or
  `false`), `data:` (the first line of the data, or a Range of lines) and
  `column_names:`, with a line given by its index from 0, as in
  `File.readlines`: `from_csv("obs.csv", header: 2, data: 4)`,
  `from_csv("big.csv", data: 1..100)`.
- Change: the reading block of `CAFrame.from_csv` is given the reader as its
  parameter, and its `body` verb is now `data`: write `from_csv(path) { |r|
  r.skip 2; r.header; r.data }`, or `{ it.skip 2; it.header; it.data }`. A
  block without a parameter raises. It was run with the reader as `self`,
  where a local variable named after a verb took its place without a word.
- Change: `CAFrame#to_csv` writes a float32 value as the shortest decimal
  that reads back as the same float32 (`0.1` rather than
  `0.10000000149011612`), and each part of a cmplx64 value likewise.
  Reading the file back as `:float32` gives the same values as before; read
  as float64, it gives the decimal, not the widened double.
- Change: `CAFrame#to_csv` names the row and the column of a cell it cannot
  write, as `to_csv: row 1500 of "s" ("東😀"): "😀" (U+1F600) cannot be
  written in CP932`. A String cell in another encoding is now transcoded to
  UTF-8 rather than raising or making the result depend on the row order; a
  cell of bytes not valid in their encoding, written before without a word,
  now raises `Encoding::InvalidByteSequenceError`, and one of bytes with no
  encoding (ASCII-8BIT) raises `Encoding::CompatibilityError`.
- Change: `CAFrame.from_csv` names the file and the line of a malformed
  record, as `obs.csv:5004: ...`, counting the lines of the file rather than
  its records (the two differ after a quoted field of several lines or a
  `skip`); `MalformedCSV` also answers `path`, `lineno` and `record`. A
  record with more fields than there are columns now raises `MalformedCSV`
  with its line, not an `ArgumentError` counting data rows.
- New: `CAFrame#split_column(name, sep, into: [...])` splits a text column
  at a String or Regexp into the named columns, in its place, as a new
  frame. A cell with more separators keeps the rest in the last column; the
  columns a cell does not reach are `UNDEF`.
- Change: `extract` on a string column masks a cell its pattern does not
  match, where it gave `""`; a following `cast` to a number left that cell 0
  through `to_i`. A match of the empty string is still `""`.

- Change: `CAFrame.from_csv` gives each text column as a `CAString` over the
  same cells, where it was a plain object array, so the string operations
  work on the column: `df["station"].strip!` trims it in place, and
  `extract` / `gsub` / `match?` need no conversion. `data_type` is still
  `:object` and nothing is copied; code that checked for a plain object
  array (`df["a"].class`, `face?`) sees a `CAString`. `infer_types` and
  `types: :infer` now also look at string Face columns.

- Fix: `CAFrame.from_csv` skips a line of only spaces in a file of more than
  one column, as it skips an empty line; it was a short row. A file read
  without a header or `column_names` keeps its empty lines as masked rows
  when it has one column, as a file with a header does; they were skipped.

- Fix: `CAFrame.from_csv` raises `MalformedCSV` on a quote inside an
  unquoted field (`5"in`), where it joined the lines after it into one
  record; a field holding a quote is written quoted, with the quote
  doubled. A quoted field of many lines is read in linear time. With
  `strip: true`, spaces before an opening quote are skipped.
- Fix: in the reading block of `CAFrame.from_csv`, a second `data` keeps the
  rows already read; rows from a `parser:` callable are no longer changed.
  An empty `sep:`, a `quote:` that is not one character, and a `skip` that
  is not a number of lines raise `ArgumentError`.
- Change: `CAFrame#cast` of a `CArray.string` or `CArray.const_string`
  column to a number reads it as an object column of text is read: the
  decimal grammar (`"010"` is 10) and `on_error:`. `on_error:` also holds
  for a complex target, and a Rational or BigDecimal in an object column
  reads as its value, where it was `UNDEF`.
- Fix: `CAFrame#parse_to_time` reads hour 24 only as `24:00:00`; `24:30` was
  read as 00:30 of the next day. Its `unit:` takes a `CATime::Resolution`
  and the other spellings `CArray.time` takes.
- Fix: `CARecord.new` fills the records with zeros, as `CArray.new` does; they
  held whatever the memory held before.

- Fix: `CAFrame.from_csv` raises `MalformedCSV` on text after a closing
  quote (`"ab"cd`, or `"x" ,2`) instead of dropping the rest of the record;
  `strip: true` lets spaces through there.
- Fix: `CAFrame.from_csv` with a separator longer than one character
  (`sep: "::"`) reads a record that contains a quote; it ended a field at
  any one character of the separator. `to_csv` quotes a value that ends in
  part of such a separator, so the file reads back.
- Fix: `CAFrame.from_csv` raises `ArgumentError` on a header that names a
  column twice; the earlier column was dropped.
- Change: `CAFrame#cast(name => :time)` and `infer_types` / `types: :infer`
  raise `RangeError` for a year-first date the column's unit cannot hold,
  under every `on_error:`. One cell with nanoseconds puts a column in `:ns`
  (1677 to 2262), and dates outside it were masked without a warning.
  `parse_to_time(name, unit: :us)` reads such a column.

- New: `CAFrame#resample(name, unit)` groups rows into time bins along a
  time column or the time index and returns a `GroupedFrame`, so
  `df.resample("time", "1 hour").mean` gives hourly means indexed by a
  `CATime` in time order. `label: :right` makes a bin end at its label and
  include it, as `(00:00, 01:00]` labelled `01:00`; `origin:` shifts the
  bins; `fill: true` keeps empty bins as rows (`UNDEF` for `mean`, 0 for
  `count`).
- Change: the index of a frame reduced by `CAFrame#group_by` on one key
  keeps the key's data type and Face: an integer key gives an integer
  index and a `CATime` key a `CATime` index, where both were object arrays
  of the values. A composite key's index is still an object array of tuples.

- New: `CAFrame#describe` summarizes a frame one row per column, as a new
  frame: type, present and masked counts, distinct values, and min / max /
  mean / stddev where the column's kind has them (numbers, booleans, times;
  text and categorical columns get the counts). `puts df.describe.to_table`
  is a first look at a table that has just been read.

- New: `types:` of `CAFrame.from_csv` and `CAFrame.from_records` takes
  `default:` for the columns the map does not name, so inference and
  columns set by hand combine in one call:
  `types: { default: :infer, "code" => :int32, "id" => nil }`. The default
  is `:infer` or a type; `nil` leaves a column as read. A map without
  `default:` casts only what it names, as before; a Symbol key other than
  `:default` now raises (column names are Strings).

- Change: `CArray.time` and `CAFrame#parse_to_time` with a strptime format
  no longer read a text that has more after the format:
  `"13/02/2024xyz"` with `"%d/%m/%Y"` is now unparseable (`UNDEF`, or
  `ArgumentError` with `on_error: :raise`) instead of 2024-02-13. Trailing
  spaces are still accepted.

- New: `CAFrame#parse_to_time(name, :infer)` finds the one format a text
  column is written in: the first cell gives the candidates (day-first or
  month-first dates, month names, `YYYYMMDD`, Japanese dates such as
  `2024年1月2日`, with an optional time and zone such as `+0900`) and
  later cells drop those they do not fit, so `13/02/2024` further down
  settles that `01/02/2024` is day-first. It raises when no format or more
  than one is left, and for a cell not in the format. `infer_time_format`
  returns the format it chose.

- New: `CAFrame#cast(name => :time)` parses a text column written year
  first (`2024-01-01`, `2024/1/2 3:04`, `2024-01-01T12:00:00.5+09:00`) into
  a `CATime` column, in the finest unit its text shows (`:D` for dates
  alone, `:s` with a time of day, `:ms` and finer for fractions of a
  second). `CAFrame#parse_to_time` takes `on_error:` as `cast` does.

- Change: `CAFrame#parse_to_time` without a format reads only text written
  year first, and much faster; it no longer guesses at other forms, so
  `"01/02/2024"` or `"Jan 2, 2024"` is now `UNDEF`. Pass a strptime format
  for those, or `:mixed` for the old guess at each cell. Without a format
  the unit now defaults to the finest the text shows, so a column of dates
  alone is `:D` (it was `:s`); pass `unit:` to keep another.

- New: `CAFrame.from_csv(types: :infer)` (and `from_records`) casts each
  text column whose cells all read as numbers to `:int64` or `:float64`,
  and one whose cells are all year-first dates or times to `:time`,
  ignoring missing cells; `CAFrame#infer_types` returns that decision as a
  map for `cast`. A leading-zero code (`"007"`), an integer too long for
  `:int64` and a date such as `"01/02/2024"` stay text. Without `:infer`
  nothing is inferred.

- New: `CAFrame.from_csv` takes `missing:` for a file that spells missing
  values its own way: `missing: ["-999", "///"]` for every column, or a
  Hash such as `{ default: "-999", "id" => [] }` where a column name
  replaces the default for that column. A field whose text is a token is
  `UNDEF`, before `types:` casts. Tokens are Strings matched against the
  field's text, so `"-999"` does not match `-999.0`. `CAFrame#to_csv` takes
  the same `missing:` and writes a masked cell as the token instead of an
  empty field (`""` keeps the empty field), raising if a value would be
  written as the same text.

- New: `CAFrame#pivot` spreads a long frame into a wide one (one row per
  distinct `index:` value, one column per distinct `columns:` value), and
  `CAFrame#melt` stacks columns back into a long one. A pair no row carries
  is UNDEF. `pivot` raises on a repeated pair unless `aggregate:` names a
  reduction (`:mean`, `:sum`, ...), and takes several value columns
  (`values: ["temp", "rh"]` gives `temp_<label>`, `rh_<label>`).
  `CAFrame#pivot_grid` returns the same cells as one 2-D CArray together
  with its row and column keys. The result of `melt` is a view of the wide
  frame, so its value columns must share one data type.

- Fix: `categorize(sort_labels: true)` takes one pass over the array, as
  `categorize` does, instead of one pass per category (876,000 cells with
  36,500 categories took 32 seconds). A lone Float NaN is now a category,
  as it already was without `sort_labels:`.

- New: `CAFrame#to_csv` takes `encoding:` and transcodes the text before
  writing or returning it, as in `df.to_csv("out.csv", encoding: "CP932")`
  for Excel in Japanese. Left out, the CSV is UTF-8 as before. A character
  the encoding cannot hold raises `Encoding::UndefinedConversionError`.
- Change: `CAFrame.from_csv` on a file that is not in the encoding it was
  read as now says to pass `encoding:` (for example `"CP932:UTF-8"` for a
  CSV written by Excel in Japanese), or for an IO, to open it in the file's
  encoding. The error class is unchanged.

- New: `CAFrame#cast`, `CAFrame.from_csv` and `CAFrame.from_records` take
  `on_error:` for a cell that holds something but does not read as the
  number type. `:mask` (the default) makes it `UNDEF` as before, `:warn`
  also warns once per column, and `:raise` raises `ArgumentError` naming
  the column, the row and the cell. Blank and missing cells are never
  errors.

- Change: `CAFrame#cast` to an integer type no longer truncates a Ruby
  number in an object column: `2.5` becomes `UNDEF` (it was `2`), as the
  string `"2.5"` does, and so does a number the type cannot hold. An
  Integer that fits and a Float with no fractional part are kept. A
  numeric column casts as before.

- Change: a String stored into a numeric array, or converted to one by
  `to_type`, is read as a decimal number, not a Ruby literal: `"010"` is 10
  (an integer type read 8) and `"1.0"` / `"1e3"` fill an integer type.
  `"0x10"`, `"1_000"`, `"x"`, `""` and `"300"` for int8 raise from a store
  and are `UNDEF` from `to_type` (a float array read `"x"` as `0.0`; int8
  wrapped `"300"`). A complex array also reads what `Complex()` reads, such
  as `"1+2i"`. Values that are not Strings convert as before.

- Fix: `search`, `bsearch` and `search_nearest` compare a CArray query in
  the type the two arrays share on a float reference too (a float64 query
  is no longer rounded to a float32 array's type), and match integers of
  mixed sign by value (`-1` no longer raises against a uint8 array). An
  infinite query finds an equal cell and nothing else: `search(Float::INFINITY)`
  matched any finite cell under the default tolerance, and
  `search_nearest(Float::INFINITY)` answered `nil` even with an infinite cell.

- Change: `CArray.result_type` lets a scalar argument (a Ruby number, or a
  CScalar) take the type of the arrays it is given with, as an operator
  does: `result_type(float32_array, 0.1)` is `:float32` (was `:float64`),
  the type of `float32_array + 0.1`, and `result_type(int8_array, 1)` is
  `:int8` (was `:int64`). A scalar of another kind still promotes
  (`result_type(int32_array, 1.5)` is `:float64`), and an Integer that does
  not fit the array's type takes `:int64`. `then_else`, `select`, `choose`
  and an Array given to `is_in` / `union` follow: `cond.then_else(0,
  int32_array)` is int32, and `float32_array.is_in([0.1])` matches the cell
  `eq(0.1)` matches. Called with scalars only, `result_type` is unchanged.

- Fix: a masked index no longer reads or writes cell 0. `gather_nd`,
  `take_along_axis` and `axis2addr` answer `UNDEF` for a masked index (or
  coordinate tuple), as `project` does; `put_nd` and `put_along_axis` write
  nothing there, as `scatter_replace!` does. `gather_nd` read cell 0 without
  a mask, and `put_nd` / `put_along_axis` overwrote it. The value stored
  under a masked index is not read, so it is not range-checked either.

- Fix: the mask of a `CArray.meld` or `CArray.stack` view no longer fails or
  writes to a part that cannot carry a mask. With a value array part
  (`x.value`) it raised `RuntimeError`; a frozen or read-only part was given
  a mask just by reading the view. Such a part now counts as unmasked, and
  writing `UNDEF` into it through the view raises as a write to a read-only
  array does. A writable part still takes the mask written through the view.

- Fix: on an object array, `count(v)`, `search(v)` and
  `rank_index(method: :dense)` treat a Float NaN as equal to nothing, as
  they do on a float array. Whether two NaN cells matched depended on
  whether they held the same Float object. `unique`, `is_in` and the set
  operations still fold every NaN into one value, on every data type.

- Fix: `is_in`, `intersection`, `difference`, `union` and `locate_addr`
  match integers of mixed sign by value, as `eq` compares them: `-1` in an
  int8 array no longer matches `255` in a uint8 one. The set operations
  answer such a pair in a type that holds both: int16 for uint8 with int8
  (was uint8), and object for uint64 with int64, which no numeric type holds.

- Fix: `unmask` / `strip_mask(method: :linear)` and `CAFrame#fill(name,
  :linear)` leave the cells that were not masked as they were: an int64
  value above 2**53 is no longer rounded through float64, and a NaN or Inf
  stored in such a cell is no longer turned into a masked cell. Only a
  masked cell outside the span of the present ones stays masked.

- Fix: on an object array, `pmax` / `pmin` let a Float NaN lose and
  `maximum` / `minimum` let it win, as on a float array; they raised
  `ArgumentError`, and so did `windows(...).max` / `.min` on an object
  array. The running `cummax` / `cummin` of `group_by_category` and the
  axis group no longer hold a group's leading NaN to its end (and no longer
  raise on an object array): the first number displaces it, as the core
  `cummax` / `cummin` do.

- New: `value.segments(offsets:)` / `value.segments(lengths:)` return a
  `CASegmentIterator`, the iterator-family member for consecutive runs of
  cells, with the same reductions, scans, `map` and addresses as the other
  members. `CArray.segment_offsets(lengths:)` and
  `CArray.segment_index(lengths:)` / `segment_index(offsets:)` convert
  between segment lengths, boundaries and the segment of each element,
  counting in int64. `CACategoricalIterator` now descends from
  `CASegmentIterator`; what it answers is unchanged.

- New: `CArray#set_attrs(hash)` sets several attributes at once;
  `b.set_attrs(a.attrs)` gives `b` the attributes `a` shows.

- New: `order` takes `kind:` (`:quick` or `:stable`), as `rank_index` does.

- New: for whoever registers a `CArray.expression_evaluator` (carray-jit):
  more of a lazy expression reaches it. A plan can now hold mixed data
  types (`f32.lazy + f64.lazy`), a Float array to an Integer power, the
  comparisons, `then_else`, and `shift` (`CArray::Fusion::Shifted`), and a
  reduction along an axis, a masked reduction, `variance`, `min_index`,
  `cumsum`, `sort_index`, `median` and `percentile` of an expression ask
  the evaluator as `to_ca` does. `CArray.__kernel_helpers__` returns the C
  the kernel bodies call beyond the standard library. An evaluator that
  does not know a node declines the plan, and CArray computes it as
  before; the answer is the same either way.

- New: for C extensions: `ca_iter_ensure` runs a kernel-iterator walk whose
  body can raise and finishes the walk however the body leaves;
  `ca_sync_detach` closes an attach window even when the sync raises;
  `ca_attach_n` / `ca_allocate_n` attach all of their arrays or none;
  `ca_iter_state_init_l2_paired` opens an input and an output walk that
  finish together (the `_INOUT` macros use it); `ca_stride_setup(NULL, ...)`
  checks without writing, so a constructor can check before it allocates;
  `ca_check_uninitialized(ca)` guards your own `initialize` /
  `initialize_copy`. Nothing changes where nothing raises.

- Change: `sort_index`, `rank_index`, `partition_index`, `partition` and
  `partition_copy` without `axis:` (or with `axis: nil`) work on the
  whole array, as `sort` and `order` already did. They used to work along
  axis 0. On a 1-D array nothing changes. On an N-D array `sort_index`,
  `partition_index`, `partition` and `partition_copy` return a 1-D result
  (`a.flatten[a.sort_index]` is `a.sort`) and `rank_index` ranks every
  cell against the whole array. To keep the old result, pass `axis: 0`.

- Change: storing `nil` into a numeric or boolean array raises, as
  `Float(nil)`, `Integer(nil)` and `Complex(nil)` do (`TypeError`, or
  `CArray::DataTypeError` for boolean). It used to become NaN, 0+0i or
  false. Store `Float::NAN` or `UNDEF` for what you mean. `to_type` from an
  object array still reads `nil` as `UNDEF`, for complex too.

- Change: a reduction's `fill_value:` is what storing it into the result
  would give, with or without `axis:` (without `axis:` it came back as
  given): `uint8` `accumulate(min_count: 256, fill_value: -9999)` returns
  `241`, and a fill the result cannot read raises. `fill_value: UNDEF`
  leaves the result undefined (it filled `0.0` along an axis). `median`
  and `percentile` take a fill the same way, and `minmax` fills both
  members. Pick a fill the result's data type can hold.

- Change: `strip_mask(UNDEF)` and `unmask(UNDEF)` leave the masked cells
  masked, as storing `UNDEF` does. They used to fill them with `0`.

- Change: `variance` and `stddev` (the sample statistics) answer `UNDEF`
  when fewer than two values are present, instead of `0.0`, on `CArray`,
  along an axis and in every iterator. `variancep` and `stddevp` still
  answer `0.0` for a single value. For the old answer pass
  `fill_value: 0.0`.

- Change: `minmax` of an empty or fully masked array, or one with fewer
  cells than `min_count:`, returns `[UNDEF, UNDEF]` instead of a single
  `UNDEF`, so `lo, hi = a.minmax` always gets both.

- Change: an Integer operand that the array's type cannot hold raises
  `RangeError` in arithmetic, `count` and the `search` family:
  `CA_INT32([5]) * 2**32` used to answer `[0]`. A uint64 array accepts
  operands up to `2**64 - 1`. The six comparisons answer by value instead
  (`CA_UINT8([0]).eq(256)` is `[false]`). Float operands are unchanged.

- Change: an axis is checked the same way everywhere. Out of range raises
  `ArgumentError` (the reductions, `normalize_axes`, `axis2addr` and
  `take_along_axis` raised `IndexError`); an axis that is not an Integer
  raises `TypeError` (`median`, `sort`, `flip` and others truncated
  `1.5`). A negative axis counts from the end everywhere, including the
  `axis:` reductions of `group_by_category` and `unmask(method: :forward)`
  (where `-3` on a 2-D array filled along axis 1). `axis: nil` is the same
  as leaving it out for `flip`, `meld`, `concatenate` and `stack`. Code
  that rescues `IndexError` for a bad axis should rescue `ArgumentError`.

- Change: `min_count:`, `kth` and `n` (`nlargest`, `nsmallest`) take an
  Integer and nothing else: `1.5` raises `TypeError` instead of being
  truncated. A negative `n` raises `ArgumentError`, as `Array#max(n)`
  does (it returned an empty result). `masked_position:`, `kind:` and
  `method:` raise `TypeError` for a value that is not a Symbol. The
  `windows` reductions refuse a `min_count:` the core reductions refuse.
  `min_count: nil` is the same as leaving it out.

- Change: error messages name the method you called and the value you
  passed (`"cumsum: ..."`, `"sort: axis 3 out of range for ndim 2"`),
  where they named internal functions ending in `_ki`, a sibling method,
  or the axis after adding `ndim`. Data types are listed by their CArray
  names. Exception classes are unchanged; code that matches on the
  wording needs updating.

- Change: a shift count means what it means to `Integer#<<` and `#>>`: a
  negative count shifts the other way and a count of the width or more
  shifts every bit out (`CA_INT64([3]) << 64` is `[0]`). Before, the
  result depended on the machine.

- Change: `to_type` from a float or complex array to an integer type makes
  a NaN cell UNDEF. A finite value outside the integer type is still
  converted as the machine's C converts it, so it can differ between
  machines. `as_type` and stores are unchanged.

- Change: on signed integers, `rcp_mul` and `rcp` round toward minus
  infinity as `/` does: `CA_INT32([2]).rcp_mul(CA_INT32([-7]))` is `[-4]`.

- Change: `maximum` and `minimum` of two zeros no longer depend on the
  argument order: `maximum` is `0.0` and `minimum` is `-0.0`, as `pmax`
  and `pmin` give.

- Change: `clip(min, max)` raises `ArgumentError` when `min` exceeds `max`
  in any cell, as Ruby's `clamp` does. With `lfill:` or `ufill:` alone,
  the side given no fill is now clamped; it was left unchanged.

- Change: a view of a frozen array is read-only rather than frozen. A
  write through it raises `RuntimeError` ("can not modify read-only
  array") instead of `FrozenError`, a subclass of it; `frozen?` on the
  view is false. In exchange `sort`, a boolean row selection, lazy
  expressions, `real` / `imag` and views of a frozen Face work on a
  frozen array; they raised `FrozenError`.

- Change: an operator operand that exports MemoryView and also defines
  `to_ca` (an Apache Arrow array, given a bridge that adds `to_ca`) is
  taken through `to_ca`, as `wrap_readonly` already did. Arrow nulls come
  in as masked cells, a sliced Arrow array reads correctly, and an Arrow
  time column arrives as a `CATime` (to add raw counts, pass
  `arrow.to_ca.ticks`). The operators of `CATime` and `CATimedelta` take
  such an operand the same way, so a duration or timestamp column from
  Arrow can be added to or subtracted from them directly.

- Change: `CArray.save` / `CArray.dump` and `Marshal.dump` refuse a Face
  other than a record (`CATime`, `CATimedelta`, string arrays,
  categoricals) and a `CAWrap`, with `TypeError`. They wrote the storage
  without its unit, buffer or labels, or failed to load. Save `.parent` to
  keep the storage, or `.copy`.

- Change: a `CARecord` is ordered only by the members named in the new
  `order_by:` option of `CArray.struct`, which gives the records `<=>`,
  the comparison operators, the sort family, `min` / `max` / `minmax` and
  `partition_copy` (NaN after every number; `==` is unchanged). Without it
  these raise; they ordered by the record bytes, which for a float or a
  negative integer is not the order of the values.

- Change: for whoever writes a Face: the read and write hooks are renamed
  `storage_to_element` and `element_to_storage` (were `storage_to_scalar`
  and `scalar_to_storage`), and so are the C registration functions and
  macros. The old names are gone.

- Change: a fixlen array needs `bytes:` of 1 or more; `bytes: 0` and a
  missing `bytes:` raise `RuntimeError`. They gave zero-width cells that
  dropped what was written. `CA_FIXLEN(data)` still takes the width from
  the longest string.

- Change: the `CA_<TYPE>()` cast shorthands refuse argument lists they used
  to ignore: `CA_INT32(0, 2)` answered `0` and now raises `ArgumentError`.
  The two-argument form is a Range and its step (`CA_INT32(0..6, 2)`),
  unchanged.

- Change: `.lazy` on a Face (`CATime`, `CATimedelta`, `CACategorical`,
  string arrays) returns the array itself, and its operations run eagerly,
  inside `CArray.fuse` too. The lazy expression used to drop the Face and
  compute on storage.

- Change: a lazy expression over a boolean array follows the eager rules:
  arithmetic reads the 0/1 values as int64, where it raised; a math
  function raises and wants an explicit cast, where it widened to float64.

- Change: `then_else` returns a lazy view when the condition or a branch is
  lazy, as the other element-wise operations do. The view is read-only;
  `copy` makes an array of it.

- Change: `sort` of a lazy expression returns a read-only sorted view over
  the expression, where it sorted a copy. A write to it raises, and its
  cells follow later changes of the operands. Call `copy` first to sort a
  snapshot.

- Change: a masked cell of a boolean selector for one axis (`a[sel, nil]`)
  selects nothing, as it does for `a[sel]`. It raised `ArgumentError`.

- Change: `shift`, `roll`, `tile` and `window` on an array with a
  zero-length axis return an empty view; they raised `IndexError`.

- Change: attributes set with `set_attr` survive `copy` and `to_type` (and
  its shorthands such as `int32`). A lazy operation no longer shows its
  left operand's attributes.

- Change: `dup` and `clone` of a `CAWrap`, including a subclass made with
  `wrap_memory_view`, return a plain `CArray`, as `copy` does.

- Change: a `CAString` can go through `CArray.stack`, `concatenate` and
  `meld`, and comes back a `CAString`; they raised.

- Change: for C extensions: the `CA_FOR_EACH_ELEMENT` macros
  (`ca_for_each_element.h`) and `CA_WITH_BUFFER` /
  `CA_WITH_BUFFER_WRITABLE` are removed. For element-wise work use
  `ca_call_cslab_N_r` or `ca_call_cfunc_N_r`; to hand the whole buffer to a
  library use `rb_ca_call_with_buffer`, which also closes the array when
  the body or the write-back raises.

- Change: for C extensions: `CA_FOR_EACH_FIBER_INOUT` and its `_MASKED`
  form raise `ArgumentError` when the input and the output differ in
  shape; a mismatched pair walked the wrong fibers or skipped the body.
  Rebuild the extension to take the check.

- Change: for C extensions: the kernels are built with `-fwrapv`, and
  `CArray::BUILD_FLAGS` says so. Signed overflow wraps across a whole
  carray-jit expression as it does one operation at a time.

- Change: for C extensions: a view onto an entity installed with
  `ca_install_obj_type` (a `CASource` subclass) is not exported through
  MemoryView, as the entity itself already was not. Export a `copy`.

- Change: faster, with the same results: a block of a `roll` view (three
  to six times), reductions over a `shift` or `window` view (two to ten
  times), reductions over any view that has to be gathered (the buffer is
  kept between calls, up to 64 MB), `group_by_category(...).sum(axis:)`
  and `count(axis:)` when there is one category per fiber (the sums can
  differ in the last bits), a later call of the same `CArray.fuse` block
  (about 3 µs instead of 60 µs), and selecting by index or boolean from a
  lazy expression or `CAObject`, which now computes only the selected
  cells.

- Fix: a Float operand of an integer array is no longer truncated to the
  array's type: `CA_INT32([1, 2, 3]).count(1.5)` is `0` and
  `CA_INT8([1, 3]).search(3.9)` is `nil` (both found `1`). This covers
  `count`, `search`, `bsearch`, `search_nearest`, `snap_to` with an Array
  grid, and a Float, Complex or `true` beside a lazy expression
  (`int32.lazy * 0.5` truncated to integers).

- Fix: integers and narrow floats keep their own data type and value:
  `scatter_*!` writes an Integer scalar exactly (above 2**53 it was
  rounded), `CAMath.atan2`, `hypot`, `copysign`, `logaddexp`,
  `nextafter`, `fmod`, `expm1` and `log1p` answer a float32 or integer
  CArray in its own type, `search_nearest` on int64 / uint64 measures
  distances exactly, and float32 `fma` / `fms` round once.

- Fix: comparisons between an unsigned and a signed integer array compare
  by value, eager and lazy: `CA_UINT64([7]).lt(CA_INT64([-7]))` is
  `[false]`. Arithmetic still promotes to the unsigned type.

- Fix: the signed minimum divided by -1 no longer crashes Linux on x86;
  `MIN / -1` is `MIN` and `MIN % -1` is `0` everywhere. `2 ** -64` is 0
  rather than `ZeroDivisionError`, and a power of `-2**63` no longer
  recurses without end. `CA_INT32(0...5, 2)` is `[0, 2, 4]`, not `[0, 2]`.

- Fix: NaN is ordered the same way everywhere. In an object array a Float
  NaN loses `min`, `max`, `minmax`, `cummin`, `cummax` and the `*_index`
  forms, and `sort` and its family put it last instead of raising.
  `median` and `percentile` interpolate toward `Infinity` or NaN when it
  is the next sorted value (`[1.0, Infinity].median` is `Infinity`), and
  every form of them agrees. `min` / `max` of a `CArray.meld` with an
  all-NaN part no longer raise.

- Fix: `min_count:` and `fill_value:` are honoured where they were
  ignored: reductions along one axis of a large contiguous array, `median`
  / `percentile` / `quantile` over an unmasked array, object `wmean`
  (which raised), and reductions of a lazy expression. A lazy reduction
  over an empty array answers as the array's does (UNDEF), where it gave
  `0.0` or the type's limits.

- Fix: `min_index`, `max_index`, `min_addr` and `max_addr` never point at a
  masked cell or a NaN; they reported position 0 when the extremum
  equalled the type's limit.

- Fix: `count_masked` and `count_not_masked` with `axis:` answer the same
  with or without a mask, take `keep_axis:`, `min_count:` and
  `fill_value:`, and return an Integer when every axis is named.
  `cumcount` works for every data type. `bincount_nd` skips a NaN weight.
  A group scan with no category answers UNDEF instead of raising.
  `CATimedelta` has `cumsum` and `accumulate`.

- Fix: a slice of a lazy expression returns the cells it names. A column
  or inner box of a lazy comparison, and a stepped or reversed slice of
  an expression that converts its input (`int16.lazy.sinh[(0...12).step(2)]`),
  read the first cells in order instead.

- Fix: a lazy expression answers as the eager one does: it skips masked
  cells where computing them could raise, works on an empty array beside
  a scalar, gives `float32.lazy.arg` exactly, raises `DataTypeError` for
  fixlen arithmetic, compares two fixlen arrays without overrunning its
  buffer, and `clip` / `fma` / `fms` can be reduced, scanned and sorted.

- Fix: the mask of a lazy expression follows its operands on every read
  (it was fixed at the first read), is read-only, and is not shared with
  an operand: `expr.mask[i] = 1` used to mask the operand. Reductions
  along an inner axis of `CArray.stack` over lazy expressions skip their
  masked cells.

- Fix: the mask of a read-only array is read-only, and `invert_mask` raises
  on a frozen array or a lazy expression without changing anything. On a
  selection or a transpose `invert_mask` now flips the parent's mask; it
  did nothing.

- Fix: a boolean selection or a `shift` of a masked array follows later
  changes to the array's mask; it kept answering the mask of its first
  read.

- Fix: storing into an array a value that reads from that same array
  (`c[] = c.flip(0)`, `c[] = c.lazy + 1`) keeps the value's masked cells
  masked; they were stored as values.

- Fix: a `CAObject` that keeps its mask in Ruby is asked for every read of
  its mask and handed every write; assigning a whole mask, partial writes,
  `unmask` and `obj[i] = UNDEF` did not reach the hooks or passed the
  wrong mask.

- Fix: writes that were dropped now reach the array: a store through a
  grid, boolean selection or `select_axis` on a `reshape` over a
  `transpose`, `flip` or block; `seq!` and a store of another data type
  through a window over whole inner axes; the in-place methods on a
  `stack` or `meld` of selections or `CAObject`s; a partial write through
  a `reshape` over a `tile`; byte-swapped values through a `stack` or
  `meld`. `refer` with `offset:` reads its own cells' mask, and
  `scatter_*!` through a converting view writes only the named cells.

- Fix: Faces stay Faces. The reductions of `windows` and `blocks`,
  `block_view`, `sliding_windows`, `cummax` / `cummin`, `partition_copy`,
  `then_else` and `mask_eq` / `mask_where` / `mask_invalid` return the
  Face, in its own order; a `CATime` result came back as 8-byte strings or
  raised, and `partition_copy` compared tick bytes. Assigning a `CATime` or
  `CATimedelta` array through `[]=`, a boolean selection or an index array
  stores it. A `CACategorical` raises where it has no order.

- Fix: the comparison operators on a `CAConstString` compare the strings;
  they compared where each string sat in the buffer.

- Fix: `abs` of an object array calls each cell's `abs`; `imag` of an
  object array returns each cell's `imaginary`; `imag` of a real array
  keeps the mask and is a new array each call; `b.real =` / `b.imag =`
  after `b = a.dup` write into `b`. `hash` of an object array agrees with
  `eql?`. `cond.then_else(x, UNDEF)` keeps `x`'s data type.

- Fix: `scatter_add!`, `scatter_sub!`, `scatter_mul!` and
  `scatter_replace!` work on a complex array; every `scatter_*!` crashed
  the process there. `scatter_min!` / `scatter_max!` raise.

- Fix: `dup` and `clone` of `a.sort` and of `a[i]` with an index array of
  `a`'s shape work; the methods a `CAShift` inherits from `CAWindow`
  answer; `join(axis:)` over a zero-length axis gives `""` per cell; a
  view with no cells can be copied, summed and written, and a boolean
  selection along one axis keeps another axis of length zero;
  `unmask(method: :linear)` on a string Face says it does not interpolate.

- Fix: MemoryView: a `CARecord` exports as its `T{...}` struct and a
  `CAFixlenString` as `Ns` bytes; a frozen fixlen array can be exported;
  `CATime`, `CATimedelta`, `CACategorical` and `CAConstString` are refused
  by `memory_view_available?` with a reason (export `.ticks` or `.codes`)
  instead of answering `true` and failing; `memory_view_reject_reason`
  suggests `arr.copy`.

- Fix: `CArray.load` refuses a file whose header fields disagree and checks
  the size before allocating; `Marshal.load` of a view or a `CScalar`
  works; a record array saved in the other byte order is swapped member by
  member; `load_binary` into a read-only array raises before writing.

- Fix: `CArray.struct` places or refuses a member's `offset:` (it was
  dropped), and refuses a member at a negative offset or past the record,
  which read and wrote outside the array. `CARecord.wrap` refuses elements
  of another size.

- Fix: no more reading or writing outside an array: shapes, block indices
  and uint64 indices whose arithmetic overflows, `percentile(NaN)`, a
  shape of more than 16 entries, and an index array of the array's own
  shape with an index out of range are refused. Megabyte-wide fixlen cells
  no longer raise `SystemStackError` in `search` and `count`.

- Fix: no more crashes or wrong values from a garbage collection in the
  middle of an operation on object arrays whose cells are computed (a
  `CAObject`, a lazy expression, views of them), in `sort_copy`, or for
  the `fill_value:` of an object `window` or `shift`, and `dup` of a view
  made by an index array no longer reads freed memory.

- Fix: an operation that raises part way (a block, a conversion, an
  object cell without the method, a division by zero, an argument that is
  refused) leaves its arrays closed and frees its memory: the cells
  written before the raise stay written, through a view as well, and the
  array, a `CAObject` parent and later lazy expressions keep working.
  Before, an array could stay attached or answer "cyclic reference" on
  every access, and after 32 such errors every lazy expression failed with
  "all 32 slots in use".

- Fix: with an expression evaluator registered (carray-jit), two
  expressions that differ only in which operand an operation reads no
  longer share a compiled kernel. A store whose destination overlaps an
  operand is computed by CArray, and a masked destination stays as it
  would without the evaluator. Through `CArray::AddressBasis`, a view that
  converts its cells sends back only the changed cells, and an overflowing
  region is refused.

- Fix: for C extensions: a write walk through the block macros left with
  `break` writes back its slab; writes into a `CAGrid`, `CASelectAxis`,
  `CAWindow` or `CAShift` whose parent is a view reach the array;
  `ca_iter_state_next_slab_strided` hands out the mask cursor of an entity
  or strided view; the mask cursor of a walk over `CArray.stack` is the
  walk's own copy; `CA_FOR_EACH_FIBER_PAIR` closes its first source when
  the second fails. `ca_for_buffer.h`, `ca_sweep_engine.h` and
  `ca_triop_dispatch.h` are installed with the gem. Rebuild the extension
  to take the fixes.

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
