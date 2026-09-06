# DOCUMENTATION ONLY — DO NOT REQUIRE.
# Stubs for CAWindow and CArray#window defined in ext/ca_obj_window.c.
# See yard-stubs/README.md and yard-stubs/STYLE.md.

# Sliding rectangular view of the parent whose cells may fall outside it.
# In-range cells alias the parent, out-of-range cells take the fill value
# (or are masked).  {CAShift} is the same view expressed as a translation.
class CAWindow < CAView
end

# Mask companion of {CAWindow}.
# @private
class CAWindowMask < CAWindow
end

class CArray
  # @!group Views

  # Returns a {CAWindow} view of `self` covering `ranges` — one range per
  # axis, which may extend past either end of the parent.  Cells inside the
  # parent alias it, so writes through the view reach the parent; cells
  # outside take `fill_value` (default `0`), and `fill_value: UNDEF` masks
  # them instead.
  #
  # Only unit-step ranges are accepted, and each range must run forward, so
  # the `0..-1` end-relative notation cannot be used here.
  #
  # @overload window(*ranges, fill_value: 0, bounds: "fill")
  #   @param ranges [Array<Range, Integer>] one range per axis; the count
  #     must equal `self.ndim`.
  #   @param fill_value [Object] value given to out-of-range cells; `UNDEF`
  #     masks them instead.
  #   @param bounds [String] what an out-of-range index means: `"fill"`
  #     (default) uses `fill_value`, `"nearest"` clamps to the edge cell,
  #     `"ruby"` reads negative indices from the far end, `"strict"` raises.
  #     `"mask"` masks the cell but warns — pass `fill_value: UNDEF` instead.
  #   @return [CAWindow]
  #   @raise [ArgumentError] when the number of ranges does not equal `ndim`,
  #     when a range has a step other than 1 or runs backwards, when a block
  #     is passed (the block form was removed in 3.0), or when `bounds` is
  #     `"periodic"` / `"reflect"` (both removed in 3.0; use {#roll} for a
  #     cyclic shift).
  #   @raise [IndexError] when a range selects zero cells.
  #   @raise [RuntimeError] when `bounds` conflicts with `fill_value: UNDEF`,
  #     or when `bounds` is not a recognised value.
  def window(*ranges, fill_value: 0, bounds: "fill"); end

  # @!endgroup
end
