# DOCUMENTATION ONLY — DO NOT REQUIRE.
# Stubs for methods defined in ext/carray_median_percentile.c.
# See yard-stubs/README.md and yard-stubs/STYLE.md.

class CArray
  # @!group Statistics

  # @overload median(axis: nil, min_count: 0, fill_value: nil, keep_axis: false)
  #   Returns the median of `self` along `axis` (or over all elements
  #   when `axis` is `nil`).
  #
  #   Numeric arrays return a `Float`; `CA_OBJECT` arrays return the
  #   result of Ruby `+` / `/` on the stored objects. Fixlen arrays
  #   raise, since no numeric midpoint is defined.
  #
  #   Masked cells are excluded. Per-axis, each fiber uses only its own
  #   present values; a fully masked fiber reduces to `UNDEF`. If the
  #   count of not-masked cells (per fiber, or over all elements in the
  #   flat form) is below `min_count`, that cell is `fill_value` (or
  #   `UNDEF` when `fill_value` is `nil`).
  #
  #   With `keep_axis: true`, the reduced axis is retained with
  #   length 1 rather than dropped.
  #   @param axis [Integer, nil]
  #   @param min_count [Integer] minimum not-masked count required.
  #   @param fill_value [Object, nil] replacement when the not-masked
  #     count is below `min_count`.
  #   @param keep_axis [Boolean]
  #   @return [Float, CArray, Object]
  #   @raise [CArray::DataTypeError] for fixlen data_type.
  #   @raise [ArgumentError] on negative `min_count`.
  def median(*); end

  # @overload percentile(*p, axis: nil, min_count: 0, fill_value: nil,
  #                      method: :linear, keep_axis: false)
  #   Returns percentile values at each `p` (each in `[0, 100]`)
  #   along `axis` or over all elements.
  #
  #   `p` may be given as individual positional arguments, a single
  #   `Array<Numeric>`, or a single 1-D `CArray`. When the effective
  #   `p` count (after flattening) is 1, the result is unwrapped:
  #   flat form returns a `Float`, per-axis form returns a `CArray`.
  #   With 2 or more `p` values the result is an `Array` whose length
  #   matches the number of requested `p` values.
  #
  #   `method` picks the interpolation rule between adjacent order
  #   statistics:
  #
  #   - `:linear` (default) — linear interpolation.
  #   - `:lower` — floor to the smaller neighbor.
  #   - `:higher` — ceil to the larger neighbor.
  #   - `:nearest` — round-half-to-even to the nearer neighbor.
  #   - `:midpoint` — arithmetic mean of the two neighbors.
  #
  #   Numeric arrays produce `Float` results; `CA_OBJECT` arrays
  #   apply Ruby `+` / `/` / `*` on the stored objects. Fixlen
  #   arrays raise.
  #
  #   Masking, `min_count`, `fill_value`, and `keep_axis` follow the
  #   same rules as {#median}.
  #   @param p [Numeric, Array<Numeric>, CArray] percentile targets in
  #     `[0, 100]`.
  #   @param axis [Integer, nil]
  #   @param min_count [Integer]
  #   @param fill_value [Object, nil]
  #   @param method [Symbol] one of `:linear`, `:lower`, `:higher`,
  #     `:nearest`, `:midpoint`.
  #   @param keep_axis [Boolean]
  #   @return [Float, CArray, Object, Array<Float>, Array<CArray>, Array<Object>]
  #   @raise [CArray::DataTypeError] for fixlen data_type.
  #   @raise [ArgumentError] on empty `p` list, `p` outside `[0, 100]`,
  #     empty axis, unknown `method`, or invalid option combinations.
  def percentile(*); end

  # @overload quantile(axis: nil, keep_axis: false)
  #   Returns the five quartile percentiles
  #   `[p0, p25, p50, p75, p100]` — shorthand for
  #   `percentile(0, 25, 50, 75, 100, axis: axis, keep_axis: keep_axis)`.
  #   Accepts no positional arguments. Flat form returns
  #   `Array<Float>` of length 5; per-axis form returns `Array<CArray>`
  #   of length 5, each CArray reduced along `axis`.
  #   @param axis [Integer, nil]
  #   @param keep_axis [Boolean]
  #   @return [Array<Float>, Array<CArray>]
  #   @raise [ArgumentError] on any positional argument.
  def quantile(*); end

  # @!endgroup
end
