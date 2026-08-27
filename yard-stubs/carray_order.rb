# DOCUMENTATION ONLY — DO NOT REQUIRE.
# Stubs for methods defined in ext/carray_order.c.
# See yard-stubs/README.md and yard-stubs/STYLE.md.

class CArray
  # @!group Sorting and searching

  # @overload project(idx, lval = nil, uval = nil)
  #   Returns a new array whose elements are taken from `self` at
  #   the positions named by `idx`. `idx` is a CArray of flat
  #   addresses into `self`; the result has the shape of `idx`.
  #
  #   Out-of-range positions are filled with `lval` (below-range) and
  #   `uval` (above-range); when `lval` is given alone, it fills
  #   both. Without either, out-of-range positions are masked.
  #
  #   When `self` is a Face (CATime / CATimedelta / CACategorical),
  #   the result is the same Face type, carrying the unit / labels; the
  #   gather runs on the underlying storage and misses become UNDEF. Fill
  #   (`lval` / `uval`) is not supported for a Face and raises ArgumentError
  #   — omit the fill args to get UNDEF at misses.
  #   @param idx [CArray] flat addresses, of any shape.
  #   @param lval [Object, nil] fill for indices `< 0` (non-Face only).
  #   @param uval [Object, nil] fill for indices `>= self.elements` (non-Face only).
  #   @return [CArray] a fresh array shaped like `idx`; a Face of the same
  #     type when `self` is a Face.
  #   @raise [ArgumentError] if `lval` / `uval` is given and `self` is a Face.
  def project(idx, lval = nil, uval = nil); end

  # sort / sort_copy stubs live in yard-stubs/carray_sort.rb (same
  # file split as ext/carray_sort.c <-> ext/carray_order.c).

  # @overload partition(kth, axis: 0, masked_position: :last)
  #   Returns a `CARemap` view of `self` permuted along `axis` so that
  #   the element at fiber-local position `kth` is in its final sorted
  #   place, every element before it is `<=` it, and every element
  #   after it is `>=` it. Order within the two regions is unspecified.
  #   Average `O(n)` per fiber via quickselect.
  #
  #   Negative `kth` counts from the end of the fiber
  #   (`-self.shape[axis] <= kth < self.shape[axis]`).
  #
  #   Supports numeric (`i8`..`f64`), boolean (as its `0`/`1` value,
  #   `false` < `true`), `CA_FIXLEN` (memcmp lexicographic order), and
  #   `CA_OBJECT` (via `<=>` per pair).
  #
  #   Mask handling matches {#sort}: masked cells are an incomparable
  #   sentinel, excluded from the kth-selection and clustered at
  #   `masked_position:`. A `kth` landing in the masked cluster needs
  #   no selection (unspecified order, same contract as the `<` / `>`
  #   regions); a `kth` landing in the unmasked range selects properly
  #   among unmasked values.
  #
  #   @param kth [Integer] target fiber-local position along `axis`.
  #   @param axis [Integer]
  #   @param masked_position [Symbol] `:last` (default) or `:first`.
  #   @return [CArray] `CARemap` view of `self`.
  #   @raise [ArgumentError] when `kth` is out of range.
  def partition(kth, axis: 0, masked_position: :last); end

  # @overload partition_copy(kth, axis: 0, masked_position: :last)
  #   Returns a fresh entity `CArray` with the same shape as `self`,
  #   partitioned along `axis` by the same rule as {#partition}.
  #   Bypasses the `CARemap` scatter layer for cases where an entity
  #   is wanted directly. Same dispatch (numeric / boolean / `CA_FIXLEN` /
  #   `CA_OBJECT`), same `kth` and `masked_position:` semantics.
  #   Masked input delegates to {#partition} + copy.
  #
  #   Float NaN policy: NaN cells are pre-partitioned to the tail. If
  #   `kth` falls within the finite slice, quickselect runs over the
  #   finite cells; otherwise the kth cell is already NaN.
  #
  #   @param kth [Integer]
  #   @param axis [Integer]
  #   @param masked_position [Symbol] `:last` (default) or `:first`.
  #   @return [CArray] fresh entity.
  #   @raise [ArgumentError] same conditions as {#partition}.
  def partition_copy(kth, axis: 0, masked_position: :last); end

  # @overload order(axis: nil, descending: false, method: :ordinal)
  #   Returns each cell's rank among the other cells along `axis`
  #   (`0` = smallest). When `axis` is omitted, `self` is flattened
  #   first (global rank). Sugar over `rank_index` (built on the
  #   same sort machinery as `sort_index`); the inverse relationship
  #   is `self.order == self.sort_index.sort_index`.
  #
  #   `method:` selects how ties are ranked:
  #
  #   - `:ordinal` (default) — every cell gets a distinct rank; ties
  #     are broken by original position (stable). This is a total
  #     order: no two cells ever compare equal.
  #   - `:dense` — tied values share one rank (no gaps). Useful as a
  #     `sort_addr` priority key: an `:ordinal` key never ties, so a
  #     lower-priority key after it is never consulted; a `:dense` key
  #     preserves the tie so it is.
  #
  #   `descending:` negates the rank order (`(n-1) - rank`, `n` =
  #   fiber element count minus masked cells). This composes correctly
  #   with `method: :dense`: ties stay tied after the transform, and
  #   group-to-group order still reverses.
  #
  #   Masked cells are excluded from ranking (own cell becomes UNDEF,
  #   like `rank_index`); `descending:`/`method:` apply to the
  #   remaining unmasked cells.
  #   @param axis [Integer, nil]
  #   @param descending [Boolean]
  #   @param method [Symbol] `:ordinal` (default) or `:dense`.
  #   @return [CArray] `:int64` ranks, shape == `self.shape`.
  #   @raise [ArgumentError] when `method:` is neither `:ordinal` nor `:dense`.
  def order(axis: nil, descending: false, method: :ordinal); end

  # @!endgroup

  # @!group Sorting and searching

  # @overload bsearch(val)
  #   Returns the flat address of `val` in `self` via binary search.
  #   `self` must be sorted along its single (flat) axis. Returns
  #   `nil` if `val` is not present. When `val` is a CArray, returns
  #   a CArray of `:int64` addresses (one per element of `val`),
  #   with `UNDEF` at positions where the value is not present.
  #   @param val [Numeric, CArray]
  #   @return [Integer, CArray, nil]
  #   @raise [RuntimeError] if `self` has any masked element.
  # @overload bsearch(val, axis:)
  #   Per-fiber binary search along `axis`. Returns a CArray of
  #   axis-local positions, one per fiber.
  #   @param val [Numeric, CArray]
  #   @param axis [Integer]
  #   @return [CArray]
  def bsearch(val, axis: nil); end

  # @overload bsearch_addr(val)
  #   Equivalent to {#bsearch} when `axis:` is omitted (the flat
  #   case already returns a flat address).
  #   @param val [Numeric, CArray]
  #   @return [Integer, CArray, nil]
  # @overload bsearch_addr(val, axis:)
  #   Per-fiber binary search along `axis`, returning flat addresses
  #   rather than axis-local positions.
  #   @param val [Numeric, CArray]
  #   @param axis [Integer]
  #   @return [CArray]
  def bsearch_addr(val, axis: nil); end

  # @overload search(val, eps = nil)
  #   Returns the flat address of the first element of `self` equal
  #   to `val`. For float types, `eps` (default machine epsilon)
  #   sets the tolerance. Returns `nil` if no match.
  #
  #   `self` need not be sorted; this is a linear scan. For sorted
  #   data prefer {#bsearch}.
  #   @param val [Object]
  #   @param eps [Float, nil]
  #   @return [Integer, nil]
  # @overload search(val, eps = nil, axis:)
  #   Per-fiber linear search along `axis`. Returns axis-local
  #   positions.
  #   @return [CArray]
  def search(val, eps = nil, axis: nil); end

  # @overload search_addr(val, eps = nil)
  #   Equivalent to {#search} when `axis:` is omitted.
  #   @return [Integer, nil]
  # @overload search_addr(val, eps = nil, axis:)
  #   Per-fiber linear search along `axis`, returning flat
  #   addresses rather than axis-local positions.
  #   @return [CArray]
  def search_addr(val, eps = nil, axis: nil); end

  # @overload search_nearest(val)
  #   Returns the flat address of the element of `self` whose value
  #   is closest to `val`. For `:object` arrays, uses
  #   `val.distance(other)` to compare.
  #   @param val [Object]
  #   @return [Integer, nil]
  # @overload search_nearest(val, axis:)
  #   Per-fiber nearest-value search along `axis`. Returns
  #   axis-local positions.
  #   @return [CArray]
  def search_nearest(val, axis: nil); end

  # @overload search_nearest_addr(val)
  #   Equivalent to {#search_nearest} when `axis:` is omitted.
  #   @return [Integer, nil]
  # @overload search_nearest_addr(val, axis:)
  #   Per-fiber nearest-value search along `axis`, returning flat
  #   addresses rather than axis-local positions.
  #   @return [CArray]
  def search_nearest_addr(val, axis: nil); end

  # @overload locate_addr(ref)
  #   Returns, for each element of `self`, the flat address into `ref`
  #   where the value first occurs, or `UNDEF` where it is not present.
  #   Builds a value-to-first-address map from `ref` in one pass (an
  #   open-addressing hash, the same substrate as {#unique} /
  #   {#value_counts}), then probes each element of `self`; no sort,
  #   peak memory `O(distinct ref values)`.
  #
  #   The return is `ref`'s flat address (0 to `ref.elements - 1`),
  #   so a multi-dimensional `ref` still yields a `self`-shaped
  #   result of flat addresses; downstream reads (`ref[addr]`,
  #   `model_var[addr]`, ...) apply it as a flat gather.
  #
  #   Works on numeric, `CA_OBJECT`, and `CA_FIXLEN` values, matching
  #   the value-hash discovery family: numeric follows `==` with all
  #   NaN collapsed to one value and `-0.0 == +0.0`; object follows
  #   Ruby `hash` / `eql?` with Float NaN collapsed; fixlen follows
  #   byte equality. When `ref` holds duplicate values the returned
  #   address is the earliest (appearance-order) occurrence. Masked
  #   cells of `ref` do not enter the map but still occupy their flat
  #   address; masked cells of `self` are `UNDEF` in the result.
  #
  #   Typical use is time-axis lookup: compute the address once
  #   against a reference axis, then reuse it to gather from many
  #   `ref`-shaped variables without repeating the lookup.
  #
  #   Implemented in Ruby (see `lib/carray/methods/locate_addr.rb`)
  #   over the `__locate_addr__` hash-lane kernel; `self` is coerced
  #   to `ref`'s data type within the same family (cross-family raises).
  #   @param ref [CArray] reference values to match against; any
  #     shape (used as flat).
  #   @return [CArray] `:int64` flat addresses into `ref`, same shape
  #     as `self`; unmatched cells are masked.
  def locate_addr(ref); end

  # @overload locate_nearest_addr(ref, direction: :round, tolerance: nil)
  #   Returns, for each element of `self`, the flat address into `ref`
  #   of the nearest reference value. Continuous sibling of
  #   {#locate_addr}; uses `linear_section` + rounding for non-exact
  #   matching against a sorted `ref`.
  #
  #   Out-of-range cells of `self` (outside `ref`'s span) mask through
  #   the pipeline: `linear_section` returns NaN, `mask_invalid`
  #   propagates that as `UNDEF`, rounding and the int64 cast carry
  #   the mask, and `project` scatters it into the final positions.
  #   `mask_invalid` runs before rounding because `CArray#round` maps
  #   NaN to 0 and would otherwise silently match `ref[0]`.
  #
  #   `tolerance:` (default `nil`) sets a maximum accepted absolute
  #   distance between `self[i]` and its matched `ref` value. When
  #   `|ref[addr] - self[i]| > tolerance`, the result cell is masked.
  #   Use for accuracy-controlled matching (e.g. "an observation
  #   snaps to a time step only if within N seconds").
  #
  #   Implemented in Ruby (see `lib/carray/methods/locate_addr.rb`).
  #   @param ref [CArray] 1-D sorted reference grid to match against.
  #   @param direction [Symbol] `:round`, `:floor`, or `:ceil` —
  #     rounding applied to the fractional position.
  #   @param tolerance [Numeric, nil] maximum accepted `|self - ref|`
  #     distance; cells beyond this are masked. `nil` disables the
  #     check.
  #   @return [CArray] `:int64` flat addresses into `ref`, same shape
  #     as `self`; out-of-range and beyond-tolerance cells are masked.
  #   @raise [ArgumentError] when `direction` is not one of the
  #     accepted symbols.
  def locate_nearest_addr(ref, direction: :round, tolerance: nil); end

  # @!endgroup

  # @!group Sorting and searching

  # @overload linear_section(val, axis: nil, method: :binary)
  #   Returns the fractional position of `val` within `self` (treated
  #   as a coordinate axis), interpolating linearly between the two
  #   bracketing samples. The integer part of the returned address is
  #   the index of the lower bracket, the fractional part is the
  #   interpolation weight toward the next sample. Out-of-range `val`
  #   returns NaN.
  #
  #   `self` is coerced to `:float64` if it is not already. When
  #   `axis: nil`, `self` is flattened to 1-D first.
  #
  #   `method:` selects the search backend:
  #   - `:binary` (default) — bisection. `O(log N)` per query.
  #     Assumes an ascending (sorted) axis; returns NaN on
  #     descending data.
  #   - `:linear` — sign-product scan. `O(N)` per query but handles
  #     both ascending and descending monotone axes correctly.
  #
  #   See {#linear_fetch} for the inverse operation (fractional
  #   address to interpolated value).
  #   @param val [Numeric, CArray]
  #   @param axis [Integer, nil]
  #   @param method [Symbol] `:binary` or `:linear`.
  #   @return [Float, CArray]
  #   @raise [ArgumentError] when `method:` is neither `:binary` nor
  #     `:linear`.
  def linear_section(val, axis: nil, method: :binary); end

  # @overload linear_fetch(addr, axis: nil)
  #   Returns the value of `self` (treated as a coordinate axis) at
  #   the fractional position `addr`, interpolating linearly between
  #   the two bracketing samples. The inverse of {#linear_section}.
  #
  #   `self` is coerced to `:float64` if it is not already. When
  #   `axis: nil`, `self` is flattened to 1-D first.
  #
  #   Out-of-range `addr` returns NaN.
  #
  #   Because this half of the pair returns a *value* rather than a
  #   position, a Face axis gets its Face back: `CATime#linear_fetch` /
  #   `CATimedelta#linear_fetch` return a time on the axis's own unit
  #   (rounded to that grid, UNDEF out of range) instead of raw ticks.
  #   @param addr [Float, CArray] fractional position(s) into `self`.
  #   @param axis [Integer, nil]
  #   @return [Float, CArray]
  #   @see file:docs/topics/LinearInterpolation.md
  def linear_fetch(addr, axis: nil); end

  # @!endgroup
end
