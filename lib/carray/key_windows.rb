# ----------------------------------------------------------------------------
#
#  carray/key_windows.rb
#
#  CAKeyWindowIterator: a moving window bounded by a width of a key (a time
#  or a number) rather than by a count of cells.  Built by
#  `value.windows(on: key, before:, after:)`.
#
# ----------------------------------------------------------------------------

require "carray/segment_iterator"
require "carray/distance_limit"

# A moving window per row, bounded by a width of a key: the window of a row
# whose key is t holds the rows whose key lies between t - before and
# t + after.  Each reduction answers once per row, in row order.
#
# Given `at:`, the windows sit at those points instead of at the rows: the
# window of a point t holds the rows whose key lies between t - before and
# t + after, and each reduction answers once per point, in the order of the
# points.  A grid of points gives windows on a grid (`after:` the width,
# `exclude: :upper` for [t, t + width)); a window with no row answers as an
# empty reduction does.
#
# Besides the reductions, the iterator answers what each window covered:
# {#first_addr} / {#last_addr} (the rows), {#first_key} / {#last_key} (their
# keys), {#elements} (the number of rows) and {#bounds} (the range the
# window was asked to cover), and, given `interval:`, {#is_complete}
# (whether the window holds exactly the keys of that grid).
#
# The keys need not be sorted.  A row whose key (or `by:` key) is masked, or
# a float key that is NaN or infinite, is in no window and has no window: its
# answers are UNDEF (a distance to an infinite key has no value).  A masked
# value is in the windows (it counts in {#elements}) but, as in any
# reduction, takes no part in the reductions.
#
# The windows overlap, so the per-cell operations of the partition members
# (`map`, the scans, `lag`, `order`, `strip_mask`) are not offered.
class CAKeyWindowIterator < CAIterator

  EXCLUDE = [nil, :lower, :upper, :both].freeze
  private_constant :EXCLUDE

  # value    : the 1-D CArray whose windows are reduced.
  # on       : the key, one value per row: a CATime, a CATimedelta or a
  #            numeric CArray.
  # before   : how far the window reaches back from a row's key.
  # after    : how far it reaches forward.
  # exclude  : which end of the window is left out (:lower by default).
  # by       : a CArray, or an Array of them, that must match exactly:
  #            a row's window holds only the rows with the same by values.
  # interval : the grid step of the key, for {#is_complete}.
  # at       : nil, or the points the windows sit at, a 1-D CArray of the
  #            key's kind; the answers are then one per point.
  def initialize (value, on:, before: nil, after: nil, exclude: :lower,
                  by: nil, interval: nil, at: nil)
    @value = value
    unless on.is_a?(CArray) && on.ndim == 1 && on.elements == value.dim0
      raise ArgumentError,
            "windows: on: is a CArray of one key per row " \
            "(#{value.dim0} rows)"
    end
    unless EXCLUDE.include?(exclude)
      raise ArgumentError,
            "windows: exclude: must be nil, :lower, :upper or :both " \
            "(got #{exclude.inspect})"
    end
    if before.nil? && after.nil?
      raise ArgumentError, "windows: give before:, after: or both"
    end
    unless at.nil?
      unless by.nil?
        raise ArgumentError, "windows: at: and by: cannot be given together"
      end
      unless at.is_a?(CArray) && at.ndim == 1
        raise ArgumentError, "windows: at: is a one-dimensional CArray of points"
      end
    end
    @key      = on
    @n        = value.dim0
    # Taken as they are now, as the windows are: bounds reads them later.
    @points   = at&.copy
    @nout     = at.nil? ? @n : at.elements
    @ndim     = 1
    @shape    = [@nout]
    before, after, interval = { before: before, after: after, interval: interval }.map do |kw, w|
      CArray::DistanceLimit.read(w, on, "windows: #{kw}:")
    end
    @interval = interval
    keys, bw, aw, iv, points = key_numbers(on, before, after, interval, at)
    @before_value = before
    @after_value  = after
    groups = group_codes(by)

    # The rows that have a window, sorted by (group, key, row).
    valid = keys.is_not_masked & groups.is_not_masked
    valid &= keys.is_finite if keys.float?
    valid  = valid.strip_mask(false)
    rows   = CArray.int64(@n).seq[valid].copy
    perm   = CArray.sort_addr(groups.project(rows), keys.project(rows), rows)
    @order = rows.project(perm)
    m      = @order.elements
    sk     = keys.project(@order).copy
    sg     = groups.project(@order).int64.copy

    # The windows' anchors, sorted: the rows themselves, or the points that
    # have a window (one that is masked, NaN or infinite has none).
    if points
      pvalid = points.is_not_masked
      pvalid &= points.is_finite if points.float?
      pvalid = pvalid.strip_mask(false)
      prow   = CArray.int64(@nout).seq[pvalid].copy
      @anchor_order = prow.project(CArray.sort_addr(points.project(prow), prow))
      sp = points.project(@anchor_order).copy
    else
      @anchor_order = @order
      sp = nil
    end
    nwin = @anchor_order.elements

    ex_lo = (exclude == :lower || exclude == :both) && !@fraction_lower
    ex_hi = (exclude == :upper || exclude == :both) && !@fraction_upper
    expected = iv && (bw / iv + aw / iv + 1 - (ex_lo ? 1 : 0) - (ex_hi ? 1 : 0)).round
    @lo, @hi, @complete =
      CArray.__find_key_window_row_ranges__(sk, sg, bw, aw, ex_lo, ex_hi, iv, expected, sp)

    # Each answer's position among the sorted windows (UNDEF for a row or a
    # point with no window), to put the answers back in row or point order.
    @position = CArray.int64(@nout).fill(UNDEF)
    @position[@anchor_order] = CArray.int64(nwin).seq if nwin > 0

    # The cells of every window, window after window, as rows of self.
    counts  = @hi - @lo
    total   = nwin > 0 ? counts.sum.to_i : 0
    starts  = nwin > 0 ? counts.cumsum.int64 - counts : CArray.int64(0)
    @src_addr = window_cells(counts, starts, total)
    @offsets = CArray.int64(nwin + 1)
    @offsets[0] = 0
    @offsets[1..-1] = starts + counts if nwin > 0
    @segments = segments_of(value)
  end

  # The same windows over another value with one row per key (a CAFrame
  # column): the sorting and the window bounds are not computed again.
  def for_value (value) # :nodoc:
    unless value.dim0 == @n
      raise ArgumentError,
            "windows: the value has shape #{value.shape.inspect}; " \
            "windows on a key take one row per key (#{@n} rows)"
    end
    other = dup
    other.instance_variable_set(:@value, value)
    other.instance_variable_set(:@segments, segments_of(value))
    other
  end

  # @overload inspect
  #   Returns a one-line summary.
  #   @return [String]
  def inspect
    "#<#{self.class} rows=#{@n} before=#{@before_value.inspect} " \
    "after=#{@after_value.inspect}>"
  end

  # @!group What each window covered

  # @overload first_addr
  #   Returns the first row of each row's window (int64), UNDEF where the
  #   window is empty or the row has none.
  #   @return [CArray]
  def first_addr
    in_rows(edge_addr(@lo))
  end

  # @overload last_addr
  #   Returns the last row of each row's window (int64), UNDEF where the
  #   window is empty or the row has none.
  #   @return [CArray]
  def last_addr
    in_rows(edge_addr(@hi - 1))
  end

  # @overload first_key
  #   Returns the key of each window's first row.
  #   @return [CArray]
  def first_key
    @key.project(first_addr)
  end

  # @overload last_key
  #   Returns the key of each window's last row.
  #   @return [CArray]
  def last_key
    @key.project(last_addr)
  end

  # @overload elements
  #   Returns the number of rows in each window (int64), masked values
  #   included; UNDEF for a row with no window.
  #   @return [CArray]
  def elements
    in_rows(@hi - @lo)
  end

  # @overload bounds
  #   Returns the range each window was asked to cover, as two arrays of the
  #   key's kind: the key minus `before` and the key plus `after`.  Which
  #   end is left out is the `exclude:` given.  A time key whose unit does
  #   not divide the width gives bounds on the finer unit the two share,
  #   so a bound is the one the windows were cut at.
  #   @return [Array(CArray, CArray)]
  def bounds
    [window_bound(@before_value, :-), window_bound(@after_value, :+)]
  end

  # @overload is_complete
  #   Returns whether each window holds exactly the keys of the `interval`
  #   grid that starts at the row's own key: every grid point once (several
  #   rows at one point count once) and no key off the grid.  UNDEF for a
  #   row with no window.  Needs `interval:`.  A float key is on the grid
  #   within a relative 1e-9; the window itself compares a float key with
  #   its bounds exactly, so on a decimal grid (keys i * 0.1) a key that
  #   misses a bound in the last bit can make a window hold one key more.
  #   @return [CArray] boolean
  def is_complete
    unless @complete
      raise ArgumentError,
            "is_complete: give interval: to windows, the step of the key's grid"
    end
    in_rows(@complete)
  end

  # @!endgroup

  # @!group Reductions

  CArray.send(:define_named_methods, self,
              [:sum, :accumulate, :prod, :mean, :min, :max, :variance, :stddev,
               :variancep, :stddevp, :median, :first, :last, :nunique,
               :count, :count_not_masked, :count_masked, :all, :any,
               :min_index, :max_index], :segments_in_rows)

  private def segments_in_rows (op, *args, **kw)
    over_columns { |seg| in_rows(seg.public_send(op, *args, **kw)) }
  end

  # @overload percentile(p)
  #   Returns each window's p-th percentile.
  #   @return [CArray, Array<CArray>]
  def percentile (p, **kw)
    over_columns { |seg| in_rows(seg.percentile(p, **kw)) }
  end

  # @overload quantile
  #   Returns each window's five-number summary `[min, Q1, median, Q3, max]`.
  #   @return [Array<CArray>]
  def quantile (**kw)
    over_columns { |seg| in_rows(seg.quantile(**kw)) }
  end

  # @overload minmax
  #   Returns `[min, max]` of each window.
  #   @return [Array(CArray, CArray)]
  def minmax (**kw)
    over_columns { |seg| in_rows(seg.minmax(**kw)) }
  end

  # @overload wsum(weights)
  #   Returns each window's weighted sum; `weights` is shaped like the value.
  #   @return [CArray]
  def wsum (weights, **kw)
    over_columns { |seg, j| in_rows(seg.wsum(cells_of(weights, j), **kw)) }
  end

  # @overload wmean(weights)
  #   Returns each window's weighted mean.
  #   @return [CArray]
  def wmean (weights, **kw)
    over_columns { |seg, j| in_rows(seg.wmean(cells_of(weights, j), **kw)) }
  end

  # @overload min_addr(min_count: nil, fill_value: nil)
  #   Returns the row of each window's minimum (int64).
  #   @return [CArray]
  def min_addr (fill_value: nil, **kw)
    over_columns { |seg| winner_row(seg.min_addr(**kw), fill_value) }
  end

  # @overload max_addr(min_count: nil, fill_value: nil)
  #   Returns the row of each window's maximum (int64).
  #   @return [CArray]
  def max_addr (fill_value: nil, **kw)
    over_columns { |seg| winner_row(seg.max_addr(**kw), fill_value) }
  end

  # @overload reduce(*args, data_type: nil) { |piece| ... }
  #   Folds each window with the block, as {CASegmentIterator#reduce}.
  #   @return [CArray]
  def reduce (*args, **kw, &block)
    if @segments.is_a?(Array)
      raise NotImplementedError,
            "reduce: windows over a value of several columns (shape " \
            "#{@value.shape.inspect}) have no block fold; reduce a column " \
            "at a time (value[nil, j])"
    end
    in_rows(@segments.reduce(*args, **kw, &block))
  end

  # @overload each { |piece| ... }
  #   Yields each row's window, in row order; a row with no window yields an
  #   empty array.
  #   @return [self, Enumerator]
  def each
    return to_enum(:each) unless block_given?
    pieces = []
    if @segments.is_a?(Array)
      rest = [nil] * (@value.ndim - 1)
      (@offsets.elements - 1).times do |p|
        rows = @src_addr[@offsets[p]...@offsets[p + 1]]
        pieces << @value[rows, *rest]
      end
    else
      @segments.each { |piece| pieces << piece }
    end
    empty = @value[0...0, *[nil] * (@value.ndim - 1)]
    @nout.times do |r|
      p = @position[r]
      yield(UNDEF.equal?(p) ? empty : pieces[p])
    end
    self
  end

  # @!endgroup

  private

  # Answers per sorted row, put back in row order.
  def in_rows (result)
    return result.map { |r| in_rows(r) } if result.is_a?(Array)
    result.project(@position)
  end

  # A winner's address among the gathered cells, as a row of self, in row
  # order; fill_value fills the windows with none, as the core fills it.
  def winner_row (addr, fill_value)
    out = in_rows(@src_addr.project(addr))
    out[out.is_masked] = fill_value unless fill_value.nil?
    out
  end

  # The row at sorted position pos[i] of the window of sorted row i, UNDEF
  # where the window is empty.
  def edge_addr (pos)
    return CArray.int64(0) if pos.elements == 0
    out = @order.project(pos)
    out[(@hi - @lo).le(0)] = UNDEF
    out
  end

  # A weights array taken through the same cells as the value: one weight
  # per row, or for a value of several columns, weights shaped like it
  # (column +j+ of them).
  def cells_of (weights, j = nil)
    return weights unless weights.is_a?(CArray)
    if j && weights.ndim > 1 && weights.dim0 == @n
      weights = weights.reshape(@n, weights.elements / @n)[nil, j]
    end
    return weights unless weights.elements == @n
    weights.project(@src_addr)
  end

  # The segment iterators the reductions run on: one for a value with one
  # cell per row, and for a value of several columns (each row a profile)
  # one per trailing column, every one over the same windows.
  def segments_of (value)
    return CASegmentIterator.new(value.project(@src_addr), offsets: @offsets) if value.ndim == 1
    width = value.shape[1..].inject(1, :*)
    flat  = value.reshape(@n, width)
    Array.new(width) do |j|
      CASegmentIterator.new(flat[nil, j].project(@src_addr), offsets: @offsets)
    end
  end

  # A reduction of the windows: as it is for a value with one cell per row;
  # for a value of several columns, of each column, the answers laid side
  # by side in the value's trailing shape, as a group reduces a profile
  # column along the rows.
  def over_columns (&block)
    return block.call(@segments, nil) unless @segments.is_a?(Array)
    trail = @value.shape[1..]
    if @segments.empty?
      one = block.call(CASegmentIterator.new(CArray.new(@value.data_type, [0], bytes: @value.bytes),
                                             offsets: CArray.int64(1)), nil)
      return lay_out(Array.new(0), one, trail)
    end
    results = @segments.each_with_index.map { |seg, j| block.call(seg, j) }
    lay_out(results, results.first, trail)
  end

  # Answers of the columns (each one per row) as one array of the rows and
  # the trailing shape; an Array of answers (minmax, quantile) answer by
  # answer.
  def lay_out (results, sample, trail)
    if sample.is_a?(Array)
      return sample.each_index.map { |k| lay_out(results.map { |r| r[k] }, sample[k], trail) }
    end
    out = CArray.new(sample.data_type, [@nout, *trail], bytes: sample.bytes)
    flat = out.reshape(@nout, results.size)
    results.each_with_index { |r, j| flat[nil, j] = r }
    out
  end

  # The rows of every window, window after window.
  def window_cells (counts, starts, total)
    return CArray.int64(0) if total == 0
    nz    = counts.gt(0)
    owner = CArray.int64(counts.elements).seq[nz].copy
    first = starts[nz].copy
    mark  = CArray.int64(total).fill(0)
    mark[first] = 1
    run   = mark.cumsum.int64 - 1
    anchor = owner.project(run)
    pos   = @lo.project(anchor) + (CArray.int64(total).seq - first.project(run))
    @order.project(pos)
  end

  # The keys and widths as numbers the walk compares: ticks for a time or a
  # duration key, the values for a numeric one.  Widths that are not whole
  # in the key's ticks scale both up to a finer grid.  A window is decided
  # by differences of keys alone, so integer keys are measured from their
  # smallest value: that is what lets a uint64 key, or ticks on a finer
  # grid, be compared as int64.
  #
  # Points (at:) are converted together with the keys -- joined, converted
  # once, and split -- so that both are measured from the same origin on
  # the same grid.
  def key_numbers (key, before, after, interval, points = nil)
    if key.is_a?(CATime) || key.is_a?(CATimedelta)
      if points
        unless points.instance_of?(key.class)
          raise ArgumentError,
                "windows: at: holds points of the key's kind, a #{key.class} " \
                "(got #{CArray::Inspector.type_label(points)})"
        end
        unless CATimeUnitAlgebra.same_group?(key.unit.base, points.unit.base)
          raise ArgumentError,
                "windows: at: holds points in #{points.unit.count} #{points.unit.base}, " \
                "which cannot be measured on a key in #{key.unit.count} #{key.unit.base} " \
                "(months and years have no fixed length); convert one with to_unit"
        end
        unit = CATimeUnitAlgebra.finer(key.unit, points.unit)
        key, points = key.to_unit(unit), points.to_unit(unit)
      end
      widths = [before, after, interval].map { |w| w.nil? ? nil : duration_in_ticks(w, key.unit) }
      scale = widths.compact.map(&:denominator).inject(1, :lcm)
      ticks = from_smallest(joined(key.ticks, points&.ticks), scale)
      bw, aw, iv = widths.map { |w| w && (w * scale).to_i }
      bw ||= 0
      aw ||= 0
      check_widths(bw, aw, iv)
      ticks, points = split(ticks, points)
      return [ticks, bw, aw, iv, points]
    end
    unless key.numeric? && !key.complex?
      raise ArgumentError,
            "windows: on: is a time, a duration or a real number key " \
            "(got #{CArray::Inspector.type_label(key)})"
    end
    if points && (points.is_a?(CATime) || points.is_a?(CATimedelta) ||
                  !points.numeric? || points.complex?)
      raise ArgumentError,
            "windows: at: holds points of the key's kind, real numbers " \
            "(got #{CArray::Inspector.type_label(points)})"
    end
    both   = joined(key, points)
    widths = [before, after, interval]
    if both.integer? && (interval.nil? || whole?(interval))
      # Integer keys are compared as integers whatever the widths are
      # given as: k >= t - w holds for an integer k exactly when
      # k >= t - floor(w), and when w is not whole, k > t - w does too, so
      # a bound at a fraction is the bound at its floor, included.  An
      # infinite width leaves its side open; the keys are then measured
      # from the smallest, so that a bound at the int64 limit is beyond
      # every key.
      open = [before, after].any? { |w| w.is_a?(Float) && w.infinite? }
      bw, aw = [before, after].map { |w| w.nil? ? 0 : integer_width(w) }
      iv = interval && interval.to_r.to_i
      check_widths(bw, aw, iv)
      @fraction_lower = !before.nil? && !whole?(before)
      @fraction_upper = !after.nil? && !whole?(after)
      numbers, points = split(from_smallest(both, 1, shift: open), points)
      [numbers, bw, aw, iv, points]
    elsif both.integer?
      # A fractional interval on integer keys: compared as float64, which
      # is exact while the keys span less than 2**53.
      bw, aw, iv = widths.map { |w| w && w.to_f }
      bw ||= 0.0
      aw ||= 0.0
      check_widths(bw, aw, iv)
      numbers = from_smallest(both, 1, shift: true)
      if numbers.elements > 0 && (span = numbers.max) != UNDEF && span > 2**53
        raise ArgumentError,
              "windows: integer keys spanning #{span} cannot be compared with " \
              "a fractional interval: exactly; give a whole interval:"
      end
      numbers, points = split(numbers.float64, points)
      [numbers, bw, aw, iv, points]
    else
      bw, aw, iv = widths.map { |w| w && w.to_f }
      bw ||= 0.0
      aw ||= 0.0
      check_widths(bw, aw, iv)
      numbers, points = split(both.float64, points)
      [numbers, bw, aw, iv, points]
    end
  end

  # Whether a width is a whole number (an infinite one is not).
  def whole? (w)
    !(w.is_a?(Float) && w.infinite?) && w.to_r.denominator == 1
  end

  # A width on integer keys as an integer: its floor, or the int64 limit
  # for an infinite one.
  def integer_width (w)
    return 2**63 - 1 if w.is_a?(Float) && w.infinite?
    [w.to_r.floor, 2**63 - 1].min
  end

  # The keys followed by the points, one array, when there are points.
  def joined (keys, points)
    points ? CArray.concatenate([keys, points]) : keys
  end

  # The keys and the points (nil without them) back out of a joined array.
  def split (numbers, points)
    return [numbers, nil] unless points
    [numbers[0...@n].copy, numbers[@n...numbers.elements].copy]
  end

  def window_bound (width, op)
    key = @points || @key
    return key if width.nil?
    if key.is_a?(CATime) || key.is_a?(CATimedelta)
      key = key.to_unit(CATimeUnitAlgebra.finer(key.unit, width.unit))
    end
    key.public_send(op, width)
  end

  # A duration in ticks of the key's unit, as a Rational.
  def duration_in_ticks (w, unit)
    count, base = w.value * w.unit.count, w.unit.base
    unless CATimeUnitAlgebra.same_group?(base, unit.base)
      raise ArgumentError,
            "windows: a width of #{count} #{base} cannot be measured on a key in " \
            "#{unit.count} #{unit.base} (months and years have no fixed length)"
    end
    Rational(count) * CATimeUnitAlgebra.base_ratio(base) /
      (unit.count * CATimeUnitAlgebra.base_ratio(unit.base))
  end

  # An integer key as int64 numbers scaled by `scale`: the values
  # themselves when they fit, else measured from the smallest value,
  # refused when even the span does not fit.
  def from_smallest (key, scale, shift: false)
    lo = key.min
    return key.int64 if lo == UNDEF
    hi = key.max
    if !shift && lo * scale >= -2**63 && hi * scale <= 2**63 - 1
      return scale == 1 ? key.int64 : key.int64 * scale
    end
    span = hi - lo
    if span * scale > 2**63 - 1
      raise ArgumentError,
            "windows: the keys span #{span}#{scale == 1 ? "" : " ticks, #{span * scale} "             "on the grid the widths need,"} more than an int64 holds"
    end
    # uint64 subtracts in its own type, which holds every difference; any
    # other integer type is widened first, so the subtraction cannot wrap.
    numbers = key.data_type == CA_UINT64 ? (key - lo).int64 : key.int64 - lo
    scale == 1 ? numbers : numbers * scale
  end

  def check_widths (bw, aw, iv)
    return unless iv
    unless iv > 0
      raise ArgumentError, "windows: interval: is positive"
    end
    [bw, aw].each do |w|
      q = w.to_f / iv
      next if (q - q.round).abs <= 1e-9 * [1.0, q.abs].max
      raise ArgumentError,
            "windows: before: and after: are whole numbers of interval:, " \
            "so a complete window has a definite set of keys"
    end
  end

  # A code per row for the by: keys, equal codes for equal keys, none for a
  # row with a masked by: cell; zeros when there is no by:.
  def group_codes (by)
    return CArray.int64(@n).fill(0) if by.nil?
    keys = by.is_a?(Array) ? by : [by]
    if keys.empty?
      raise ArgumentError, "windows: by: names no key"
    end
    keys.each do |k|
      unless k.is_a?(CArray) && k.ndim == 1 && k.elements == @n
        raise ArgumentError, "windows: by: is a CArray of one value per row (#{@n} rows)"
      end
    end
    CACategorical.send(:from_keys, keys).codes
  end
end
