class CArray

  # @overload repeat(count, axis: nil)
  #   @overload repeat(counts, axis: nil)
  #   Returns each element (or each sub-array) of `self` laid down
  #   `count` times in place, one after another.
  #
  #   With an Integer, every element is repeated the same number of
  #   times. With an array of counts -- one per element, or one per
  #   sub-array when `axis:` is given -- each is repeated its own number
  #   of times, and a count of 0 drops that one:
  #
  #     v = CA_INT([10, 20, 30])
  #     v.repeat(2)              #  => [ 10, 10, 20, 20, 30, 30 ]
  #     v.repeat([3, 1, 2])      #  => [ 10, 10, 10, 20, 30, 30 ]
  #     v.repeat([2, 0, 1])      #  => [ 10, 10, 30 ]
  #
  #   This is `np.repeat`, and it is not {#tile}: `repeat` puts the
  #   copies of one element next to each other, `tile` lays the whole
  #   array down again -- `v.tile(2)` is `[10, 20, 30, 10, 20, 30]`.
  #
  #   `axis: k` repeats the sub-arrays enumerated by axis `k` rather
  #   than the cells, so a 2-D array repeats whole rows and the result
  #   keeps its shape apart from that axis:
  #
  #     t = CA_INT([[0, 1], [2, 3], [4, 5]])
  #     t.repeat([2, 1, 1], axis: 0)
  #     #  => [ [ 0, 1 ],
  #     #       [ 0, 1 ],
  #     #       [ 2, 3 ],
  #     #       [ 4, 5 ] ]
  #
  #   Without `axis:` a multi-dimensional receiver is taken in flatten
  #   (row-major) order and the result is 1-D, as `np.repeat` does.
  #
  #   The result is a **view** of `self` -- the same element named as
  #   many times as it was repeated -- so nothing is copied and writing
  #   through it reaches `self`, at every position that names the cell
  #   written. Take a `copy` when that is not wanted.
  #
  #   Counts must be non-negative, and there must be exactly as many as
  #   there are elements (or sub-arrays along `axis:`). A masked count
  #   is refused: it names no number of repetitions.
  #
  #   @param count [Integer, CArray, Array] how many times to repeat --
  #     one number for all, or one per element / sub-array.
  #   @param axis [Integer, nil] axis whose index enumerates the
  #     sub-arrays to repeat; `nil` repeats cells in flatten order.
  #   @return [CArray] the repeated elements, as a view of `self`.
  def repeat (count, axis: nil)
    along = axis.nil? ? nil : normalize_axis(axis, "repeat")
    width = along ? shape[along] : elements

    counts =
      case count
      when Integer
        if count < 0
          raise ArgumentError, "repeat: count must not be negative (got #{count})"
        end
        CArray.int64(width).fill(count)
      else
        given = count.to_ca.int64
        unless given.elements == width
          raise ArgumentError,
                "repeat: #{given.elements} counts for #{width} " \
                "#{along ? "sub-arrays along axis #{along}" : 'elements'}"
        end
        if given.has_mask? and given.count_masked > 0
          raise ArgumentError,
                "repeat: a masked count names no number of repetitions"
        end
        if given.lt(0).any
          raise ArgumentError, "repeat: counts must not be negative"
        end
        given.flatten
      end

    source = along ? self : (ndim > 1 ? flatten : self)
    source[*gather_args(repeat_index(counts), along)]
  end

  #  The source index of every position in the result: element i appears
  #  at the `counts[i]` positions starting at the exclusive prefix sum.
  #
  #  Marking those starts with +1 and running a cumulative sum turns the
  #  marks back into indices, and does the right thing with a zero
  #  count for free -- two elements then share a start, that position
  #  carries 2, and the sum steps over the one that was asked for zero
  #  times.
  private def repeat_index (counts)
    total = counts.sum.to_i
    return CArray.int64(0) if total.zero?
    starts = counts.cumsum.int64 - counts
    marks  = CArray.int64(total)
    #  A trailing zero count starts one past the end; it marks nothing,
    #  which is what a zero count means.
    marks.scatter_add!(starts[starts.lt(total)], 1)
    marks.cumsum.int64 - 1
  end

  #  One index argument per axis: the gathered index on the axis being
  #  repeated, whole axes everywhere else.
  private def gather_args (index, along)
    return [index] unless along
    args = [nil] * ndim
    args[along] = index
    args
  end

end
