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
  #   - `nil` — the whole axis, in order.
  #   - an integer `Range` — a contiguous sub-range along the axis.
  #   - a `CArray` of integer indices — gather exactly those parent
  #     indices (arbitrary order; duplicates produce duplicated cells).
  #   - a boolean `CArray` — the indices where it is true.
  #
  #   A masked cell of an index `CArray` selects nothing: the position
  #   stays in the view and reads as masked (`UNDEF`), and a write to it
  #   is dropped, as in {#project} and {#gather_nd}.  A masked cell of a
  #   boolean selector selects nothing either, so it adds no position.
  #   The view is writable; scattering back to overlapping cells (from
  #   duplicate indices) is last-write-wins.
  #
  #   @param selectors [Array<nil, Range, CArray>] one selector per axis.
  #   @return [CArray] the grid view.
  #   @raise [ArgumentError] when more selectors than `ndim` are given,
  #     or a masked index selects from a view of a value array or a mask
  #     array (which can not carry the mask that shows it).
  #   @raise [IndexError] when a selected index is out of range.
  #   @raise [TypeError] when a selector is a plain Ruby `Array`
  #     (not supported; pass a CArray of indices instead).
  def grid(*selectors); end
  # @!endgroup
end
