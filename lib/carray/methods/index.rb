class CArray

  # @overload index(axis: 0)
  #   Returns a writable int32 CArray holding the coordinate ramp
  #   `[0, 1, ..., shape[axis] - 1]` along `axis`, in an open
  #   broadcast shape: size `shape[axis]` on that axis and 1 on
  #   every other axis (e.g. for `(d0, d1, d2)`, `index(axis: 1)`
  #   returns `(1, d1, 1)`).
  #
  #   The result broadcasts against `self` in element-wise ops
  #   without materialising the full shape. For the dense
  #   full-shape grid use
  #   `index(axis: k).broadcast_to(*shape)` or `CArray.meshgrid`.
  #
  #   @param axis [Integer] axis to vary (negative counts from the
  #     end).
  #   @return [CArray] writable int32 CArray; size 1 on every axis
  #     except `axis`, which has size `shape[axis]`.
  def index (axis: 0)
    k = normalize_axis(axis, "index")
    oshape = Array.new(ndim, 1)
    oshape[k] = shape[k]
    CArray.int32(*oshape).seq!
  end

  # @overload indices
  #   Returns an Array of +ndim+ coordinate ramps, one per axis, each in
  #   the open broadcast shape of {#index}.
  #   @return [Array<CArray>] one open coordinate ramp per axis.
  # @overload indices { |*ramps| ... }
  #   Yields the +ndim+ open coordinate ramps as splat arguments.
  #   @yield [*ramps] the per-axis open coordinate ramps.
  #   @return [Object] the block's return value.
  def indices
    list = (0...ndim).map { |k| index(axis: k) }
    block_given? ? yield(*list) : list
  end

end
