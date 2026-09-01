class CArray

  # @overload meshgrid(*axes, indexing: "xy", copy: true, sparse: false)
  #   Returns coordinate matrices built from 1-D coordinate vectors.
  #
  #   Given N 1-D vectors, produces N arrays each broadcasting one
  #   input axis across the others. Useful for evaluating a function
  #   on a grid.
  #
  #   With `indexing: "xy"` (default) the first two axes are swapped
  #   in the output shape (matrix-style convention): `meshgrid(x, y)`
  #   gives outputs of shape `[y.elements, x.elements]`. With
  #   `indexing: "ij"` input order is preserved:
  #   `meshgrid(x, y, indexing: "ij")` gives outputs of shape
  #   `[x.elements, y.elements]`. For more than two axes only the
  #   first two are swapped under `"xy"`; the remaining axes follow
  #   input order in both modes.
  #
  #   When `copy` is true (default) each output is a materialised
  #   CArray; when false, a view is returned. When `sparse` is true
  #   each output keeps a size-1 axis wherever the full grid would
  #   repeat, and broadcasts on demand, saving memory for large grids.
  #
  #   If a block is given, yields the resulting arrays as splat
  #   arguments and returns the block's value.
  #
  #   Each axis goes through {CArray.wrap_readonly}, so a coordinate
  #   vector may be given as anything that entry point accepts (a
  #   CArray, an Array, a Range, a Numeric, a MemoryView producer, an
  #   object answering `ca` / `to_ca`); its own data type is kept.
  #
  #   @param axes [Array<CArray, Array, Object>] 1-D coordinate vectors.
  #   @param indexing [String] `"xy"` or `"ij"`.
  #   @param copy [Boolean] materialise each output when true.
  #   @param sparse [Boolean] return broadcast-on-demand views when true.
  #   @yieldparam grids [Array<CArray>] the resulting coordinate arrays.
  #   @return [Array<CArray>] the coordinate arrays, or the block's
  #     return value.
  #   @raise [ArgumentError] when `indexing` is neither `"xy"` nor `"ij"`,
  #     or when a coordinate vector is not 1-D.
  #   @example
  #     x = CA_FLOAT64([1.0, 2.0, 3.0])
  #     y = CA_FLOAT64([10.0, 20.0])
  #     xx, yy = CArray.meshgrid(x, y)
  #     xx.shape        # => [2, 3]
  #     yy.to_a         # => [[10.0, 10.0, 10.0], [20.0, 20.0, 20.0]]
  def self.meshgrid (*axes, indexing: "xy", copy: true, sparse: false, &block)
    unless %w[xy ij].include?(indexing)
      raise ArgumentError, %{indexing option should be one of "xy" and "ij"}
    end

    # Each axis is negotiable, so no target type is imposed here; a
    # CArray comes back as itself and anything else is brought in with
    # its own data type.
    axes = axes.map.with_index do |axis, k|
      a = CArray.wrap_readonly(axis)
      unless a.ndim == 1
        raise ArgumentError,
              "coordinate vector #{k} should be 1-D (got #{a.ndim}-D)"
      end
      a
    end

    ndim = axes.size

    # dest[k] = output axis position that input axis k populates.
    # "xy" swaps the first two; everything else is in input order.
    dest = (0...ndim).to_a
    dest[0], dest[1] = 1, 0 if indexing == "xy" && ndim >= 2

    # Output shape: each output axis i takes its size from the input
    # axis that maps there.
    out_shape = Array.new(ndim)
    axes.each_with_index { |a, k| out_shape[dest[k]] = a.size }

    list = axes.map.with_index do |axis, k|
      d = dest[k]
      idx = if sparse
              Array.new(ndim) { |i| i == d ? nil : :_ }
            else
              out_shape.dup.tap { |s| s[d] = :% }
            end
      view = axis[*idx]
      copy ? view.copy : view
    end

    block ? block.call(*list) : list
  end

end
