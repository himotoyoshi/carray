# DOCUMENTATION ONLY — DO NOT REQUIRE.
# Stubs for methods defined in ext/carray_broadcast.c.
# See yard-stubs/README.md and yard-stubs/STYLE.md.

class CArray
  # @!group Views

  # @overload broadcast_to(*shape)
  #   Returns a read-only `CARepeat` view of `self` whose shape is
  #   `shape`. Axes are paired right-to-left:
  #
  #   - matching extents reuse the source stride
  #   - target extent `> 1` against source extent `1` repeats with
  #     stride `0`
  #   - extra leading target axes require the corresponding source
  #     axis to be `1` (otherwise raises)
  #
  #   `CScalar` sources broadcast to any target shape with all
  #   strides `0`.
  #
  #   The result is read-only because writes against a stride-0
  #   axis would be ambiguous.
  #   @param shape [Array<Integer>] target shape, with
  #     `length >= self.ndim`.
  #   @return [CArray]
  #   @raise [RuntimeError] if a source axis cannot be paired with a
  #     target axis (cross-ndim expansion is intentionally strict —
  #     see {CArray.broadcast} for the explicit-`:_` / `:*` axis
  #     declaration form).
  #   @example
  #     a = CArray.float64(3) { [1.0, 2.0, 3.0] }
  #     a.broadcast_to(2, 3).to_a
  #     # => [[1.0, 2.0, 3.0], [1.0, 2.0, 3.0]]
  def broadcast_to(*shape); end

  # @!endgroup
end
