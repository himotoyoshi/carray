class CArray

  # @overload broadcast(*argv, expand_scalar: false)
  #   Returns each CArray argument broadcast to the common shape, or
  #   yields the broadcast tuple to a block.
  #
  #   Non-CArray arguments (Float / Integer) pass through unchanged
  #   unless `expand_scalar` is true. CScalar instances are treated
  #   as ndim-0 scalars and excluded from the ndim check.
  #
  #   All real CArray arguments must share the same `ndim`; implicit
  #   cross-ndim trailing-align is rejected. Insert size-1 axes with
  #   `:_` to align explicitly, e.g. `arg[:_, nil]` turns `(N,)` into
  #   `(1, N)` (row vector) and `arg[nil, :_]` turns it into `(N, 1)`
  #   (column vector).
  #
  #   @param argv [Array<CArray, Numeric>] arguments to broadcast.
  #   @param expand_scalar [Boolean] when true, also expand CScalar
  #     and pass-through scalar arguments to the common shape.
  #   @yieldparam broadcast [Array<CArray, Numeric>] the broadcast
  #     arguments in input order.
  #   @return [Array<CArray, Numeric>] broadcast arguments, or the
  #     block's return value when a block is given.
  #   @raise [ArgumentError] when CArray arguments differ in `ndim`.
  def CArray.broadcast (*argv, expand_scalar: false, &block)

    sel = argv.select { |arg| arg.is_a?(CArray) && !arg.is_a?(CScalar) }
    return argv if sel.empty?

    ndims = sel.map(&:ndim).uniq
    if ndims.size > 1
      shapes = argv.each_with_index
                    .select { |a, _| a.is_a?(CArray) && !a.is_a?(CScalar) }
                    .map { |a, i| "  arg[#{i}]: shape=(#{a.shape.join(', ')})" }
      raise ArgumentError, <<~MSG.strip
        CArray.broadcast: ndim mismatch (got #{ndims.sort.join(' and ')})
        #{shapes.join("\n")}
        CArray does not implicit-broadcast across ndim.  Insert a size-1
        axis with :_ to align explicitly, e.g.
          arg[:_, nil]   # (N,) -> (1, N)   row-vector
          arg[nil, :_]   # (N,) -> (N, 1)   column-vector
      MSG
    end

    ndim = sel.first.ndim
    dim = (0...ndim).map { |k| sel.map { |a| a.shape[k] }.max }

    list = argv.map do |arg|
      case arg
      when CScalar
        expand_scalar ? arg.broadcast_to(*dim) : arg
      when CArray
        arg.broadcast_to(*dim)
      else
        expand_scalar ? arg : arg
      end
    end

    return block.call(*list) if block
    return list
  end

end
