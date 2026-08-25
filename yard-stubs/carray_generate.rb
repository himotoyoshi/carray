# DOCUMENTATION ONLY — DO NOT REQUIRE.
# Stubs for methods defined in ext/carray_generate.c.
# See yard-stubs/README.md and yard-stubs/STYLE.md.

class CArray
  # @!group Scatter and generation

  # @overload where
  #   Returns a fresh 1-D CArray of flat addresses where `self` is
  #   non-zero (or `true`). Masked positions are excluded.
  #   Non-boolean arrays are first coerced to boolean.
  #   @return [CArray] 1-D, `:int64` (`ca_size_t`).
  #   @example
  #     CArray.int32(5) { [0, 1, 0, 2, 0] }.where.to_a
  #     # => [1, 3]
  def where; end

  # @!endgroup

  # @!group Scatter and generation

  # @overload seq!
  #   Fills `self` in row-major order with `0, 1, 2, ...`. Mutates
  #   `self` and clears any mask.
  #   @return [self]
  # @overload seq!(init_val)
  #   Fills `self` in row-major order with `init_val`, `init_val + 1`,
  #   `init_val + 2`, ... Mutates `self`.
  #   @param init_val [Numeric]
  #   @return [self]
  # @overload seq!(init_val, step)
  #   Fills `self` in row-major order with `init_val`, `init_val +
  #   step`, `init_val + 2*step`, ...
  #
  #   For `:object` arrays only, `step` may be a Symbol naming the
  #   stepping method to invoke on the previous element (e.g. `:succ`).
  #   @param init_val [Numeric, Object]
  #   @param step [Numeric, Symbol]
  #   @return [self]
  # @overload seq!(init_val = 0, step = 1, axis:)
  #   Fills `self` with a progression that runs along `axis` and repeats
  #   across the other axes: the cell value depends only on its
  #   coordinate along `axis`. `axis` must be a single integer (a
  #   negative value counts from the end); multi-axis fills are not
  #   supported.
  #   @param init_val [Numeric, Object]
  #   @param step [Numeric, Symbol]
  #   @param axis [Integer] the axis the progression runs along.
  #   @return [self]
  #   @raise [ArgumentError] if `axis` is out of range or not a single
  #     integer.
  def seq!(*); end

  # @overload seq(init_val = 0, step = 1, axis: nil)
  #   Equivalent to `dup.seq!(init_val, step, axis: axis)`. Returns a
  #   fresh array of the same shape and `data_type` as `self`, filled
  #   with a sequence (flat by default, or along `axis` when given).
  #   @param init_val [Numeric, Object]
  #   @param step [Numeric, Symbol]
  #   @param axis [Integer, nil] the axis the progression runs along,
  #     or `nil` for a flat row-major fill.
  #   @return [CArray]
  def seq(*); end

  # @!endgroup
end
