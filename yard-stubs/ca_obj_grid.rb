# DOCUMENTATION ONLY — DO NOT REQUIRE.
# Stubs for methods defined in ext/ca_obj_grid.c.
# See yard-stubs/README.md and yard-stubs/STYLE.md.
#
# CAGrid itself is an internal (:nodoc:) view class; only the CArray#grid
# entry point is user-facing.

class CArray
  # @!group Views
  # @overload grid(*selectors)
  #   Returns a coordinate-selected view of `self`: one selector per
  #   axis picks a set of parent indices along that axis, and the view
  #   is their Cartesian product.  The output size along axis `k` is the
  #   number of indices selected for that axis.
  #
  #   Each selector is one of:
  #   - a `CArray` of integer indices — gather exactly those parent
  #     indices (arbitrary order; duplicates produce duplicated cells).
  #   - a boolean `CArray` as long as its axis — the indices where it is
  #     true.
  #   - any other key, read as the indexer reads it in a block
  #     reference: `nil` the whole axis, a `Range` /
  #     `ArithmeticSequence` / Array form its run (a range ending before
  #     it starts reads backwards), the rubber marker (`false` / `:~`)
  #     as many whole axes as it stands for, and an `Integer` one cell,
  #     whose axis is then dropped from the view.
  #
  #   A masked cell of an index `CArray` selects nothing: the position
  #   stays in the view and reads as masked (`UNDEF`), and a write to it
  #   is dropped, as in {#project} and {#gather_nd}.  A masked cell of a
  #   boolean selector selects nothing either, so it adds no position.
  #   The view is writable; scattering back to overlapping cells (from
  #   duplicate indices) is last-write-wins.
  #
  #   @param selectors [Array<nil, Integer, Range, Array, CArray>] one
  #     selector per axis.
  #   @return [CArray] the grid view.
  #   @raise [ArgumentError] when more selectors than `ndim` are given, a
  #     boolean selector is not as long as its axis, or a masked index
  #     selects from a view of a value array or a mask array (which can
  #     not carry the mask that shows it).
  #   @raise [IndexError] when a selected index is out of range, or a
  #     selector is not a position (a String, a Float with a fraction).
  def grid(*selectors); end
  # @!endgroup
end
