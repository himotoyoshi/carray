# DOCUMENTATION ONLY — DO NOT REQUIRE.
# Stubs for methods defined in ext/ca_obj_tile.c.
# See yard-stubs/README.md and yard-stubs/STYLE.md.

# Tiled repetition view.  Output shape is `parent.dim[k] * reps[k]`
# along each axis; every tile is a full-parent alias, so writes to
# overlapping cells are last-write-wins.
class CATile < CAView
end

# Mask companion of {CATile}.
# @private
class CATileMask < CATile
end

class CArray
  # @!group Views
  # @overload tile(*reps)
  #   Returns a {CATile} view of `self` tiled `reps[k]` times along
  #   each axis `k`.  Accepts either positional args
  #   (`a.tile(2, 3)`) or a single array (`a.tile([2, 3])`); the
  #   number of reps must equal `ndim`.
  #   @param reps [Array<Integer>] repetition count per axis.
  #   @return [CATile]
  #   @raise [ArgumentError] when the number of reps does not match `ndim`.
  #   @raise [IndexError] when any `reps[k]` is not positive.
  def tile(*reps); end
  # @!endgroup
end
