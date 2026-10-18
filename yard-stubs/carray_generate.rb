# DOCUMENTATION ONLY — DO NOT REQUIRE.
# Stubs for methods defined in ext/carray_generate.c.
# See yard-stubs/README.md and yard-stubs/STYLE.md.

class CArray
  # @!group Scatter and generation

  # @overload where
  #   Returns a fresh 1-D CArray of flat addresses where `self` is
  #   non-zero (or `true`). Masked positions are excluded.
  #   An integer, float or complex array selects its non-zero cells
  #   (NaN is non-zero). Any other array that is not boolean is cast to
  #   boolean, which takes only `0`, `1`, `true` and `false`.
  #   @return [CArray] 1-D, `:int64` (`ca_size_t`).
  #   @raise [CArray::DataTypeError, TypeError] if an array that is not
  #     boolean, integer, float or complex cannot be cast to boolean.
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
  #   On an integer array an `init_val` or `step` that is not an Integer
  #   (a Float, a Rational) makes each cell `init_val + step*i` cut
  #   toward zero, as a store takes a float: `int32.seq(0.5, 0.5)` is
  #   `[0, 1, 1, 2]`.  The first and last values must fit the type.
  #
  #   For `:object` arrays only, `step` may be a Symbol naming the
  #   stepping method to invoke on the previous element (e.g. `:succ`).
  #   A CAString takes only a run of Strings (`s.seq!("a", :succ)`), as a
  #   store into it does.
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
  #   @raise [RangeError] for an integer array, if `init_val` does not fit
  #     its type, or an Integer `step` is larger than the type can hold. An
  #     unsigned array takes a negative step (a descending run). A run of
  #     Integers that passes the end of the type wraps, as integer
  #     arithmetic does; a real run (a Float or Rational argument) whose
  #     first or last value does not fit raises.
  #   @raise [FloatDomainError] for an integer array given a NaN argument.
  #   @raise [TypeError] if `init_val` or `step` is not a number (a Symbol
  #     `step` on an `:object` array excepted).
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
