class CArray

  # @!group Elementwise math

  # @overload is_between(lo, hi, exclude: nil)
  # @overload is_between(range)
  #   Returns a boolean CArray of the same shape as `self`, `true` at each
  #   cell whose value lies between `lo` and `hi`.  Both bounds are included
  #   unless `exclude:` names the one to leave out:
  #
  #     a.is_between(2, 4)                    # 2 <= a <= 4
  #     a.is_between(2, 4, exclude: :upper)   # 2 <= a <  4
  #     a.is_between(2, 4, exclude: :lower)   # 2 <  a <= 4
  #     a.is_between(2, 4, exclude: :both)    # 2 <  a <  4
  #
  #   A Range says the same as the two bounds, its excluded end as
  #   `exclude: :upper`: `a.is_between(2...4)`.  A bound given as `nil` (or
  #   the open end of `..4` / `2..`) leaves that side unbounded.
  #
  #   It is the two comparisons joined by `&`, so it takes what they take --
  #   a time array is bounded by Strings, `Time` or elements -- and answers as
  #   they do: a masked cell is masked, and NaN is outside every interval.
  #   Bounds the wrong way round (`lo > hi`) contain nothing.
  #   @param lo [Object, nil] the lower bound.
  #   @param hi [Object, nil] the upper bound.
  #   @param exclude [nil, :lower, :upper, :both] the bounds left out.
  #   @return [CArray] boolean, the shape of `self`.
  #   @raise [ArgumentError] when neither bound is given, `exclude:` is not one
  #     of the three, or a Range comes with a second bound or `exclude:`.
  def is_between (*bounds, exclude: nil)
    if bounds.size == 1 && bounds[0].is_a?(Range)
      unless exclude.nil?
        raise ArgumentError,
              "is_between: a Range says which ends it includes; give two bounds to use exclude:"
      end
      range = bounds[0]
      lo, hi = range.begin, range.end
      exclude = :upper if range.exclude_end? && !hi.nil?
    elsif bounds.size == 2
      lo, hi = bounds
    else
      raise ArgumentError,
            "is_between: give a lower and an upper bound, or a Range (got #{bounds.size} arguments)"
    end
    unless [nil, :lower, :upper, :both].include?(exclude)
      raise ArgumentError,
            "is_between: exclude: must be :lower, :upper or :both (got #{exclude.inspect})"
    end
    if lo.nil? && hi.nil?
      raise ArgumentError, "is_between: give at least one bound"
    end
    lower = lo.nil? ? nil : (%i[lower both].include?(exclude) ? gt(lo) : ge(lo))
    upper = hi.nil? ? nil : (%i[upper both].include?(exclude) ? lt(hi) : le(hi))
    lower && upper ? lower & upper : (lower || upper)
  end

  # @!endgroup

end
