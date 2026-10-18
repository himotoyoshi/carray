class CArray

  # @overload lag(n = 1, axis: nil)
  #   Returns the value `n` steps earlier along `axis`, cell by cell: cell
  #   `i` of the result is cell `i - n` of `self`. A cell with no value `n`
  #   steps back is UNDEF, so a difference against it is UNDEF rather than
  #   a difference against a stand-in value:
  #
  #   ```
  #   x = CA_FLOAT64([1.0, 4.0, 9.0])
  #   x.lag           # => [UNDEF, 1.0, 4.0]
  #   x - x.lag       # => [UNDEF, 3.0, 5.0]
  #   x.lag(-1)       # => [4.0, 9.0, UNDEF]   (the value one step later)
  #   ```
  #
  #   The cell `n` steps back is taken by position: when it is masked, the
  #   result is UNDEF there too. It is `shift` with `UNDEF` as the fill
  #   value, and returns the same kind of view: it shares storage with
  #   `self`. Use `copy` for an independent array.
  #
  #   The steps run along one axis. A 1-D array has only one, so `axis:`
  #   may be left out; an array of more dimensions must name it, since
  #   stepping back through the cells in flatten order would carry a value
  #   across from the end of one row to the start of the next.
  #
  #   @param n [Integer] steps back; a negative `n` looks ahead.
  #   @param axis [Integer, nil] the axis the steps run along.
  #   @return [CArray] a view, shaped like `self`.
  #   @raise [TypeError] when `n` or `axis` is not an Integer.
  #   @raise [ArgumentError] when `axis` is out of range, or left out for an
  #     array of more than one dimension.
  def lag (n = 1, axis: nil)
    unless n.is_a?(Integer)
      raise TypeError, "lag: n must be an Integer (got #{n.class})"
    end
    if axis.nil?
      unless ndim == 1
        raise ArgumentError,
              "lag: name the axis to step along (axis:) for an array of " \
              "#{ndim} dimensions"
      end
      axis = 0
    end
    steps = Array.new(ndim, 0)
    steps[normalize_axis(axis, "lag")] = n
    shift(*steps, fill_value: UNDEF)
  end

end
