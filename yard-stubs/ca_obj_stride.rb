# DOCUMENTATION ONLY — DO NOT REQUIRE.
# Stubs for CAStride and the CArray view constructors defined in
# ext/ca_obj_stride.c.  See yard-stubs/README.md and yard-stubs/STYLE.md.

# Generic strided view of the parent: each cell is addressed as
# `base_offset + Σ idx[k] * strides[k]` bytes from the parent's buffer, with
# byte strides that may be negative or zero.  That is enough to express axis
# permutation, reshape, stepped slicing and broadcasting, so most view
# classes are CAStride subclasses and inherit its behaviour unchanged.
class CAStride < CAView
end

# Mask companion of {CAStride}.
class CAStrideMask < CAStride
end

class CArray
  # @!group Views

  # Returns a {CAStride} view of `self` with the given byte strides and
  # starting byte offset, inheriting the receiver's data type and element
  # size.  Memory is shared with the receiver.
  #
  # This is a low-level escape hatch: the strides and offset are **not**
  # bounds-checked against the receiver's memory, so a combination that
  # addresses outside it reads or writes past the buffer.  Prefer the
  # derived constructors ({#sliding_windows}, {#block_view}, {#flip},
  # {#diagonal}) when one of them expresses the layout.
  #
  # @overload as_strided(shape:, strides:, offset: 0)
  #   @param shape [Array<Integer>] axis lengths.
  #   @param strides [Array<Integer>] byte stride per axis, same length as
  #     `shape`; negative values are allowed.
  #   @param offset [Integer] byte offset from the receiver's buffer to the
  #     `[0, ..., 0]` element.
  #   @return [CAStride]
  #   @raise [ArgumentError] when `shape:` or `strides:` is missing, when
  #     their lengths differ, or when the rank is 0 or above `CA_RANK_MAX`.
  def as_strided(shape:, strides:, offset: 0); end

  # Returns a {CAStride} view of overlapping windows over every axis.  A
  # parent of shape `[d0, ..., dN-1]` becomes a view of shape
  # `[(d0-w0)/s0+1, ..., (dN-1-wN-1)/sN-1+1, w0, ..., wN-1]`, where `wi` is
  # the window length on axis `i` and `si` the step.
  #
  # Truncate mode: a trailing partial window is dropped rather than padded.
  # Memory is shared with the parent, and because windows overlap, one parent
  # cell is visible from several positions of the view.
  #
  # Reduce over the trailing `ndim` axes for a rolling statistic.
  #
  # @overload sliding_windows(window, step: nil)
  # @overload sliding_windows(w0, w1, ..., step: nil)
  #   @param window [Array<Integer>, Integer] window length per axis, one per
  #     dimension, as an Array or as variadic arguments.
  #   @param step [Array<Integer>, Integer, nil] stride between windows per
  #     axis; `nil` means 1 on every axis.
  #   @return [CAStride] of rank `2 * ndim`.
  #   @raise [ArgumentError] when the window count does not equal `ndim`,
  #     when a window or step is not positive, when a window is longer than
  #     its axis, or when `2 * ndim` exceeds `CA_RANK_MAX`.
  def sliding_windows(*window, step: nil); end

  # Returns a {CAStride} view of overlapping windows over the leading `S`
  # axes, with the remaining `ndim - S` trailing axes riding along untouched
  # at their original strides — {#sliding_windows} generalised to arrays that
  # carry non-spatial dimensions such as channels.
  #
  # The window axes are inserted before the trailing axes, so the result rank
  # is `ndim + S`.  With `S == ndim` there are no trailing axes and the
  # result is identical to {#sliding_windows}.  Truncate mode; memory is
  # shared with the parent.
  #
  # @overload unfold(window, step: nil)
  # @overload unfold(w0, w1, ..., step: nil)
  #   @param window [Array<Integer>, Integer] window length for each of the
  #     leading axes; its size chooses how many axes are slid over.
  #   @param step [Array<Integer>, Integer, nil] stride between windows;
  #     `nil` means 1.
  #   @return [CAStride] of rank `ndim + window.size`.
  #   @raise [ArgumentError] when the window count is not between 1 and
  #     `ndim`, when a window or step is not positive, when a window is
  #     longer than its axis, or when `ndim + S` exceeds `CA_RANK_MAX`.
  def unfold(*window, step: nil); end

  # Returns a {CAStride} view of non-overlapping tiles.  A parent of shape
  # `[d0, ..., dN-1]` becomes a view of shape
  # `[d0/b0, ..., dN-1/bN-1, b0, ..., bN-1]`, where `bi` is the tile length
  # on axis `i`.
  #
  # Unlike {#sliding_windows} each parent dimension must divide evenly by its
  # tile size: nothing is truncated and no cell is aliased twice.  Reduce over
  # the trailing `ndim` axes (e.g. `v.mean(-1, -2)` for a 2-D parent) for
  # per-tile statistics such as pooling or block-wise aggregation.  Memory is
  # shared with the parent.
  #
  # @overload block_view(block)
  # @overload block_view(b0, b1, ...)
  #   @param block [Array<Integer>, Integer] tile length per axis, one per
  #     dimension, as an Array or as variadic arguments.
  #   @return [CAStride] of rank `2 * ndim`.
  #   @raise [ArgumentError] when the tile count does not equal `ndim`, when
  #     a tile length is not positive, when an axis is not divisible by its
  #     tile length, or when `2 * ndim` exceeds `CA_RANK_MAX`.
  def block_view(*block); end

  # Returns a `CATranspose` view in which the given axes are moved to the
  # front, in the order given, with the remaining axes following in their
  # original order — a thin alias over `transposed` that names the intent
  # "bring these axes to the front, keep the rest as the inner slice".
  #
  # @example
  #   a = CArray.float64(3, 4, 5).seq
  #   a.dim_view(0, 2)    # shape [3, 5, 4]
  #   a.dim_view(1)       # shape [4, 3, 5]
  #   a.dim_view(-1)      # shape [5, 3, 4]
  #
  # @overload dim_view(axes)
  # @overload dim_view(a0, a1, ...)
  #   @param axes [Array<Integer>, Integer] axes to bring to the front;
  #     negative indices count from the last axis.
  #   @return [CATranspose]
  #   @raise [ArgumentError] when no axis is given, when more axes are given
  #     than `ndim`, or when an axis is out of range or repeated.
  def dim_view(*axes); end

  # Returns a {CAStride} view with the listed axes reversed (a negative
  # stride on each); with no argument every axis is reversed.  Memory is
  # shared with the parent, so writes through the view propagate.
  #
  # This is the named counterpart of the indexer form
  # `ca[-1..0, nil, -1..0]` — both produce a true negative-stride view with
  # no copy.  Use `flip` when the axis list is parametric or when the named
  # intent reads better than the slice form.  There is no `flip!`; the
  # in-place idiom is `ca[] = ca.flip`.
  #
  # `reverse` is an alias of `flip`.
  #
  # @example
  #   a = CArray.float64(4, 5).seq
  #   a.flip              # every axis reversed
  #   a.flip(0)           # row order reversed
  #   a.flip(-1)          # same as a.flip(1)
  #   a.flip([0, 1])      # Array form
  #
  # @overload flip
  # @overload flip(axis)
  # @overload flip(a0, a1, ...)
  # @overload flip([a0, a1, ...])
  #   @param axis [Array<Integer>, Integer] axes to reverse; negative indices
  #     count from the last axis.
  #   @return [CAStride]
  #   @raise [ArgumentError] when an axis is out of range or repeated.
  def flip(*axis); end

  # Returns a {CAStride} view of one diagonal of the parent.  For a 2-D
  # parent of shape `[m, n]` this is a 1-D view of length
  # `min(m, n - offset)` for `offset >= 0`, or `min(m + offset, n)` for
  # `offset < 0`.
  #
  # For a higher-rank parent, the two axes named by `axis:` collapse into a
  # single diagonal axis appended at the **end** of the result, and the
  # remaining axes keep their order in front.  Memory is shared with the
  # parent.
  #
  # @overload diagonal(offset = 0, axis: [0, 1])
  #   @param offset [Integer] signed shift from the main diagonal; positive
  #     selects a super-diagonal, negative a sub-diagonal.  An offset larger
  #     than the relevant axis yields an empty view rather than an error.
  #     May be passed positionally or as `offset:`, but not both.
  #   @param axis [Array<Integer>] the two distinct axes to take the diagonal
  #     over; negative indices count from the last axis.
  #   @return [CAStride]
  #   @raise [ArgumentError] when the parent has fewer than two dimensions,
  #     when `offset` is given both positionally and as a keyword, or when
  #     `axis:` is not two distinct in-range axes.
  def diagonal(offset = 0, axis: [0, 1]); end

  # @!endgroup
end
