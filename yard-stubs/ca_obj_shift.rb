# DOCUMENTATION ONLY — DO NOT REQUIRE.
# Stubs for CAShift and CArray#shift defined in ext/ca_obj_shift.c.
# See yard-stubs/README.md and yard-stubs/STYLE.md.

# Translated view of the parent along each axis.  Pure `CAWindow`
# typedef: only the obj_type tag differs.  No data is copied; in-range
# cells alias the parent, out-of-range cells take the fill value (or are
# masked).
class CAShift < CAWindow
end

# Mask companion of {CAShift}.
class CAShiftMask < CAShift
end

class CArray
  # @!group Views

  # Returns a {CAShift} view of `self` translated by `shifts` along each
  # axis (one shift per dimension; a positive shift moves cell `i` of the
  # parent to position `i + shift`).  Out-of-range cells take `fill_value`
  # (default `0`); passing `fill_value: UNDEF` masks them instead of
  # filling.  In-range cells alias the parent, so writes through the view
  # reach the parent.
  #
  # The in-place idiom is `ca[] = ca.shift(...)`; there is no `shift!`.
  # For a cyclic (wrap-around) shift use {#roll}, which returns a `CARoll`
  # view.
  #
  # @overload shift(*shifts, fill_value: 0)
  #   @param shifts [Array<Integer>] one shift per axis; the count must
  #     equal `self.ndim`.
  #   @param fill_value [Object] value written to out-of-range cells;
  #     `UNDEF` masks them instead.
  #   @return [CAShift]
  #   @raise [ArgumentError] when the number of shifts does not equal
  #     `ndim`, when the removed `:roll` option is given, or when a block
  #     is passed (the block form was removed in 3.0).
  def shift(*shifts, fill_value: 0); end

  # @!endgroup
end
