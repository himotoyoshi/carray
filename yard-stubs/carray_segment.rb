# DOCUMENTATION ONLY — DO NOT REQUIRE.
# Stubs for methods defined in ext/carray_segment.c.
# See yard-stubs/README.md and yard-stubs/STYLE.md.

class CArray
  # @!group Index and address conversion
  #
  # A flat sequence cut into consecutive segments has three
  # representations, and these methods convert between them:
  #
  #   lengths         [2, 0, 3]         one count per segment
  #   offsets         [0, 2, 2, 5]      every boundary, both ends included
  #   segment index   [0, 0, 2, 2, 2]   the segment each element is in
  #
  # Segment `c` spans `offsets[c]...offsets[c + 1]`, so there is no
  # special case for the last segment and none for an empty one.
  #
  # Both methods compute in int64 and return int64, so a total beyond
  # 2**53 stays exact. They accept a CArray of any integer or boolean
  # data type (views included, read in flatten order) or an Array of
  # Integers, and refuse masked cells: a masked length is not a count,
  # and a masked offset is not a position.

  # @overload segment_offsets(lengths:)
  #   Returns the boundaries of segments with the given lengths: `0`
  #   first, then the running total. `k` lengths give `k + 1` offsets,
  #   so no lengths give `[0]`.
  #
  #     CArray.segment_offsets(lengths: [2, 0, 3])   # => [0, 2, 2, 5]
  #
  #   @param lengths [CArray, Array<Integer>] one count per segment.
  #   @return [CArray] int64, one element more than `lengths`.
  #   @raise [ArgumentError] for a negative length, a masked length,
  #     or a non-Integer in an Array.
  #   @raise [CArray::DataTypeError] for a non-integer data type.
  #   @raise [RangeError] when the total overflows int64.
  def self.segment_offsets(lengths:); end

  # @overload segment_index(lengths:)
  #   Returns, for each element of the cut sequence, the segment it
  #   belongs to. A segment of length 0 contributes no elements, so
  #   its number does not appear.
  #
  #     CArray.segment_index(lengths: [2, 0, 3])   # => [0, 0, 2, 2, 2]
  #
  #   The same as `CArray.int64(k).seq.repeat(lengths)`, as an owned
  #   array rather than a view.
  #   @param lengths [CArray, Array<Integer>] one count per segment.
  #   @return [CArray] int64, `lengths.sum` elements.
  #
  # @overload segment_index(offsets:)
  #   The same from boundaries. The offsets need not start at 0: the
  #   offsets of a range cut out of a longer table start where that
  #   range starts, and the result then covers
  #   `offsets[0]...offsets[-1]` with the segments numbered from 0.
  #
  #     CArray.segment_index(offsets: [0, 2, 2, 5])   # => [0, 0, 2, 2, 2]
  #     CArray.segment_index(offsets: [4, 6, 6, 9])   # => [0, 0, 2, 2, 2]
  #
  #   @param offsets [CArray, Array<Integer>] `k + 1` non-decreasing
  #     boundaries.
  #   @return [CArray] int64, `offsets[-1] - offsets[0]` elements.
  #
  # @raise [ArgumentError] for a negative length, decreasing or empty
  #   offsets, a masked cell, a non-Integer in an Array, or unless
  #   exactly one of `lengths:` and `offsets:` is given.
  # @raise [CArray::DataTypeError] for a non-integer data type.
  # @raise [RangeError] when the total length overflows int64.
  def self.segment_index(lengths: nil, offsets: nil); end

  # @!endgroup
end
