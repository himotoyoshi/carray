# Ruby front-end for CArray#bincount.  Validates inputs, picks the
# output length, and dispatches to the dedicated C kernels in
# ext/carray_bincount.c (`__bincount_count__` / `__bincount_weighted__`).

class CArray

  # @overload bincount(weights: nil, length: 0)
  #   Returns occurrence counts per non-negative integer label in
  #   `self`, or a per-label sum of `weights`.
  #
  #   Masked labels are skipped (not counted). Masked weights are
  #   skipped too (their label contributes 0).
  #
  #   @param weights [CArray, nil] when given, sums weights per
  #     label instead of counting; length must equal `self.elements`
  #     and the output `data_type` is inherited from `weights`.
  #     When `nil` (default), counts occurrences and returns
  #     `CA_UINT32` (or `CA_UINT64` if `length >= 2^32`).
  #   @param length [Integer] minimum output length; the actual
  #     length is `max(length, self.max + 1)`.
  #   @return [CArray] 1-D output of length `max(length, self.max + 1)`.
  #   @raise [CArray::DataTypeError] when `self` is not an integer
  #     `data_type`.
  #   @raise [ArgumentError] when a label is negative or `weights`
  #     length disagrees with `self.elements`.
  #   @example
  #     labels = CA_INT32([0, 1, 1, 2, 0, 1])
  #     labels.bincount                    # => CA_UINT32([2, 3, 1])
  #     labels.bincount(length: 5)         # => CA_UINT32([2, 3, 1, 0, 0])
  #     weights = CA_DOUBLE([1, 2, 3, 4, 5, 6])
  #     labels.bincount(weights: weights)  # => CA_DOUBLE([6, 11, 4])
  def bincount(weights: nil, length: 0)
    unless [CA_INT8, CA_INT16, CA_INT32, CA_INT64,
            CA_UINT8, CA_UINT16, CA_UINT32, CA_UINT64].include?(data_type)
      raise CArray::DataTypeError,
            "bincount requires an integer label array (got #{data_type_name})"
    end

    if elements.zero?
      if weights
        out = CArray.new(weights.data_type, [length])
      else
        out_type = (length > 0xFFFFFFFF) ? CA_UINT64 : CA_UINT32
        out = CArray.new(out_type, [length])
      end
      out.fill(0) unless length.zero?
      return out
    end

    # Single-pass fused min+max so the prereq scan over labels costs
    # one walk instead of two.
    label_min, label_max = minmax
    if label_min.equal?(UNDEF)
      # Every cell is masked: no labels to count, same result as an empty
      # input (all-zero output of the requested minimum length).
      if weights
        out = CArray.new(weights.data_type, [length])
      else
        out_type = (length > 0xFFFFFFFF) ? CA_UINT64 : CA_UINT32
        out = CArray.new(out_type, [length])
      end
      out.fill(0) unless length.zero?
      return out
    end
    if label_min < 0
      raise ArgumentError,
            "bincount: negative label not allowed (got #{label_min})"
    end

    n = [length, label_max + 1].max

    if weights
      unless weights.is_a?(CArray)
        raise ArgumentError, "bincount: weights must be a CArray"
      end
      if weights.elements != elements
        raise ArgumentError,
              "bincount: weights length (#{weights.elements}) doesn't " \
              "match labels length (#{elements})"
      end
      __bincount_weighted__(weights, n)
    else
      __bincount_count__(n)
    end
  end

end
