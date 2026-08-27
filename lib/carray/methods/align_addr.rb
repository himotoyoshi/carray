class CArray

  # @overload align_addr(*arrays, join: :outer)
  #   Aligns several arrays onto one common set of coordinate values and
  #   returns, for each array, the flat addresses that gather it onto that
  #   common set. Symmetric N-ary counterpart of the instance method
  #   {#locate_addr} (which is the asymmetric self-against-ref lookup).
  #
  #   Returns `[common, idx_0, idx_1, ...]`:
  #   - `common` is a 1-D CArray of the common coordinate values, chosen by
  #     `join:` (see below), in first-appearance order.
  #   - `idx_k` is a `common`-shaped `:int64` CArray of flat addresses into
  #     `arrays[k]`: `idx_k[j]` is where `common[j]` lives in `arrays[k]`, or
  #     `UNDEF` when that array lacks the value. Each `idx_k` is exactly
  #     `common.locate_addr(arrays[k])`.
  #
  #   Reindex each array onto the common grid with `project`, then compare
  #   element-wise (missing coordinates come through masked):
  #
  #     common, idx_a, idx_b = CArray.align_addr(a_coord, b_coord, join: :outer)
  #     a_on_grid = a_data.project(idx_a)   # common-shaped, UNDEF where a lacks it
  #     b_on_grid = b_data.project(idx_b)
  #
  #   Because the addresses are returned (not the reindexed values), one
  #   alignment serves any number of `arrays[k]`-shaped variables — compute the
  #   idx once, project many.
  #
  #   `join:` selects the common coordinate set:
  #   - `:outer` — union of the distinct values of every array.
  #   - `:inner` — distinct values present in every array.
  #   - `:left`  — the first array's distinct values.
  #   - `:right` — the last array's distinct values.
  #
  #   Value equality follows the value-hash discovery family (numeric `==` with
  #   NaN collapsed and `-0.0 == +0.0`; object `hash` / `eql?`; fixlen byte
  #   equality). Arrays are coerced to the first array's data type within the same
  #   family (cross-family raises). Masked cells do not enter `common`.
  #
  #   @param arrays [Array<CArray>] two or more arrays (Array / Range coerced
  #     via `to_ca`). One array is allowed (degenerate: `common` is its distinct
  #     values).
  #   @param join [:outer, :inner, :left, :right] how to build `common`.
  #   @return [Array<CArray>] `[common, idx_0, idx_1, ...]`.
  #   @raise [ArgumentError] when no array is given or `join` is not one of the
  #     accepted symbols.
  def self.align_addr (*arrays, join: :outer)
    raise ArgumentError, "align_addr: need at least one array" if arrays.empty?
    arrays = arrays.map { |a| a.is_a?(CArray) ? a : a.to_ca }
    # Seed the fold with the first array's distinct values so N == 1 and the
    # union/intersection folds all agree (a bare reduce over one element would
    # return it with duplicates intact).
    seed = arrays.first.unique
    common = case join
             when :outer then arrays[1..-1].reduce(seed) { |acc, a| acc.union(a) }
             when :inner then arrays[1..-1].reduce(seed) { |acc, a| acc.intersection(a) }
             when :left  then seed
             when :right then arrays.last.unique
             else
               raise ArgumentError,
                     "align_addr: join must be :outer / :inner / :left / :right " \
                     "(got #{join.inspect})"
             end
    idxs = arrays.map { |a| common.locate_addr(a) }
    [common, *idxs]
  end

  # @overload align_nearest_addr(*arrays, grid: nil, direction: :round, tolerance: nil)
  #   Aligns several arrays onto one common coordinate grid by nearest match,
  #   the ordered-lane (continuous) sibling of {align_addr}. Returns
  #   `[common, idx_0, idx_1, ...]` with the same reindex contract: `idx_k` is a
  #   `common`-shaped `:int64` array of flat addresses into `arrays[k]` giving,
  #   for each grid point, the nearest value in that array — exactly
  #   `common.locate_nearest_addr(arrays[k], direction:, tolerance:)`.
  #
  #   Unlike {align_addr}, the common grid is **not** built by a set union:
  #   continuous coordinates rarely coincide exactly, so a union would merely
  #   pile up near-duplicate points. Instead the grid is a reference axis —
  #   `grid:` when given, otherwise the first array verbatim (kept as-is, not
  #   deduplicated). Pass `grid: arrays.last` to align onto the last array's
  #   axis. (`join:` has no meaning here and is not accepted; clustering nearby
  #   coordinates into a synthesised grid is out of scope.)
  #
  #     common, ia, ib = CArray.align_nearest_addr(a_coord, b_coord, grid: ref)
  #     a_on_grid = a_data.project(ia)   # each grid point <- nearest a value
  #     b_on_grid = b_data.project(ib)
  #
  #   `direction:` (`:round` / `:floor` / `:ceil`) and `tolerance:` are
  #   forwarded to {#locate_nearest_addr}: out-of-range grid points, and points
  #   whose nearest value is farther than `tolerance`, come back masked.
  #
  #   @param arrays [Array<CArray>] one or more arrays (Array / Range coerced
  #     via `to_ca`).
  #   @param grid [CArray, Array, Range, nil] the reference coordinate grid;
  #     `nil` uses the first array verbatim.
  #   @param direction [:round, :floor, :ceil] rounding rule for the nearest
  #     match.
  #   @param tolerance [Numeric, nil] maximum accepted distance; farther grid
  #     points are masked. `nil` disables the check.
  #   @return [Array<CArray>] `[common, idx_0, idx_1, ...]`.
  #   @raise [ArgumentError] when no array is given (or `direction` is invalid,
  #     raised by {#locate_nearest_addr}).
  def self.align_nearest_addr (*arrays, grid: nil, direction: :round, tolerance: nil)
    raise ArgumentError, "align_nearest_addr: need at least one array" if arrays.empty?
    arrays = arrays.map { |a| a.is_a?(CArray) ? a : a.to_ca }
    common = if grid.nil?
               arrays.first
             else
               grid.is_a?(CArray) ? grid : grid.to_ca
             end
    idxs = arrays.map { |a|
      common.locate_nearest_addr(a, direction: direction, tolerance: tolerance)
    }
    [common, *idxs]
  end

end
