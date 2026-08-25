# DOCUMENTATION ONLY — DO NOT REQUIRE.
# Stub for CArray#count defined in ext/carray_count.c.
# See yard-stubs/README.md and yard-stubs/STYLE.md.

class CArray
  # @!group Statistics

  # @overload count(axis: nil)
  #   With no value argument, returns the number of present (not-masked)
  #   cells — the arity-0 rung of the dispatch ladder, answering "how
  #   many are there".  Forwards to {#count_not_masked} (which stays as
  #   an explicit, self-documenting named method).
  #
  #   @param axis [Integer, Array<Integer>, nil] reduction axis or
  #     axes; `nil` reduces fully.
  #   @return [Integer, CArray] `Integer` when `axis` is `nil`,
  #     otherwise a `CArray` of int64 with the given axes collapsed.
  #
  # @overload count(v, axis: nil, min_count: 0, fill_value: nil)
  #   Returns the number of cells of `self` that equal `v`, with
  #   mask-aware reduction along `axis`.
  #
  #   `count` is an orthogonal arity-dispatch ladder (like Ruby's
  #   `Array#count`): no argument counts present cells, `count(UNDEF)`
  #   counts masked cells, and `count(v)` counts cells equal to `v`.
  #   Mask-cardinality and value-match are distinct concepts, so the
  #   overloading is unambiguous.
  #
  #   Dispatch:
  #   - no argument: forwards to {#count_not_masked} (present-cell
  #     count).
  #   - `v == UNDEF`: forwards to {#count_masked} (UNDEF is mask-state
  #     vocabulary, not a value).
  #   - `v` is a CArray: broadcasts; each `v[k]` is counted
  #     independently and stacked into a result whose trailing axes
  #     have shape `v.shape`.  Not supported when `self.data_type` is
  #     `:boolean`.
  #   - `self.data_type == :boolean`: `v` must be `true` / `false`, or
  #     the integer literal `1` (= true) / `0` (= false) — boolean
  #     stores 0/1, so `count(1)` == `count(true)`.  Any other value
  #     (`2`, `1.0`, `nil`, …) raises `TypeError`.
  #   - `self` is numeric, `v` is scalar: `v` must be numeric (true /
  #     false are rejected).
  #
  #   When `axis` is `nil` (default), reduces over all axes and
  #   returns an `Integer`.  Otherwise reduces along the given
  #   axis / axes and returns a `CArray`.
  #
  #   An empty or fully-masked reduction returns `0`: a count has
  #   identity `0`, so the count over no cells is `0`, not `UNDEF`
  #   (pass `min_count:` to get `UNDEF` below a threshold instead).
  #
  #   `:fixlen` and `:object` data types raise `CArray::DataTypeError`.
  #
  #   A time array counts by its own values: `CATime` / `CATimedelta`
  #   descend to their storage and reconcile `v` into their unit, so `v`
  #   may be an element of the array, another time array (in any unit that
  #   converts exactly), or a Ruby `Time` / `DateTime`.  A bare storage
  #   number is refused — use `ca.parent.count(n)` to count raw ticks.
  #
  #   @param v [Object, CArray] value (or array of values) to count.
  #     `UNDEF` is treated as a mask-state query.
  #   @param axis [Integer, Array<Integer>, nil] reduction axis or
  #     axes; `nil` reduces fully.
  #   @param min_count [Integer] minimum number of non-masked cells
  #     required per reduced slice; slices below the threshold come
  #     back masked.  Accepted only by the value-argument form
  #     (`count(v)`); the no-argument form accepts `axis:` only.
  #   @param fill_value [Object, nil] replacement for masked output
  #     cells; `nil` leaves them masked.  Value-argument form only.
  #   @return [Integer, CArray]
  #   @raise [TypeError] when `v`'s type does not match the dispatch
  #     rule above.
  #   @raise [CArray::DataTypeError] when `self.data_type` is
  #     `:fixlen` or `:object`.
  def count(*args, axis: nil, min_count: 0, fill_value: nil); end

  # @!endgroup
end
