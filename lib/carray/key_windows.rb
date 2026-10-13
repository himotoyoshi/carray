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

# A moving window per row, bounded by a width of a key: the window of a row
# whose key is t holds the rows whose key lies between t - before and
# t + after.  Each reduction answers once per row, in row order.
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
  def initialize (value, on:, before: nil, after: nil, exclude: :lower,
                  by: nil, interval: nil)
    @value = value
    unless value.ndim == 1
      raise ArgumentError,
            "windows: the value has shape #{value.shape.inspect}; " \
            "windows on a key take one value per row"
    end
    unless on.is_a?(CArray) && on.ndim == 1 && on.elements == value.elements
      raise ArgumentError,
            "windows: on: is a CArray of one key per value " \
            "(#{value.elements} values)"
    end
    unless EXCLUDE.include?(exclude)
      raise ArgumentError,
            "windows: exclude: must be nil, :lower, :upper or :both " \
            "(got #{exclude.inspect})"
    end
    if before.nil? && after.nil?
      raise ArgumentError, "windows: give before:, after: or both"
    end
    @key      = on
    @n        = value.elements
    @ndim     = 1
    @shape    = [@n]
    @interval = interval
    keys, bw, aw, iv = key_numbers(on, before, after, interval)
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

    ex_lo = exclude == :lower || exclude == :both
    ex_hi = exclude == :upper || exclude == :both
    expected = iv && (bw / iv + aw / iv + 1 - (ex_lo ? 1 : 0) - (ex_hi ? 1 : 0)).round
    @lo, @hi, @complete =
      CArray.__key_window_ranges__(sk, sg, bw, aw, ex_lo, ex_hi, iv, expected)

    # Each row's position among the sorted rows (UNDEF for a row with no
    # window), to put the answers back in row order.
    @position = CArray.int64(@n).fill(UNDEF)
    @position[@order] = CArray.int64(m).seq if m > 0

    # The cells of every window, window after window, as rows of self.
    counts  = @hi - @lo
    total   = m > 0 ? counts.sum.to_i : 0
    starts  = m > 0 ? counts.cumsum.int64 - counts : CArray.int64(0)
    @src_addr = window_cells(counts, starts, total)
    @offsets = CArray.int64(m + 1)
    @offsets[0] = 0
    @offsets[1..-1] = starts + counts if m > 0
    @segments = CASegmentIterator.new(value.project(@src_addr), offsets: @offsets)
  end

  # The same windows over another value with one entry per row (a CAFrame
  # column): the sorting and the window bounds are not computed again.
  def for_value (value) # :nodoc:
    unless value.ndim == 1 && value.elements == @n
      raise ArgumentError,
            "windows: the value has shape #{value.shape.inspect}; " \
            "windows on a key take one value per row (#{@n} rows)"
    end
    other = dup
    other.instance_variable_set(:@value, value)
    other.instance_variable_set(:@segments,
                                CASegmentIterator.new(value.project(@src_addr), offsets: @offsets))
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
  #   row with no window.  Needs `interval:`.
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

  [:sum, :accumulate, :prod, :mean, :min, :max, :variance, :stddev,
   :variancep, :stddevp, :median, :first, :last, :nunique,
   :count, :count_not_masked, :count_masked, :all, :any,
   :min_index, :max_index].each do |op|
    define_method(op) do |*args, **kw|
      in_rows(@segments.public_send(op, *args, **kw))
    end
  end

  # @overload percentile(p)
  #   Returns each window's p-th percentile.
  #   @return [CArray, Array<CArray>]
  def percentile (p, **kw)
    in_rows(@segments.percentile(p, **kw))
  end

  # @overload quantile
  #   Returns each window's five-number summary `[min, Q1, median, Q3, max]`.
  #   @return [Array<CArray>]
  def quantile (**kw)
    in_rows(@segments.quantile(**kw))
  end

  # @overload minmax
  #   Returns `[min, max]` of each window.
  #   @return [Array(CArray, CArray)]
  def minmax (**kw)
    in_rows(@segments.minmax(**kw))
  end

  # @overload wsum(weights)
  #   Returns each window's weighted sum; `weights` is shaped like the value.
  #   @return [CArray]
  def wsum (weights, **kw)
    in_rows(@segments.wsum(cells_of(weights), **kw))
  end

  # @overload wmean(weights)
  #   Returns each window's weighted mean.
  #   @return [CArray]
  def wmean (weights, **kw)
    in_rows(@segments.wmean(cells_of(weights), **kw))
  end

  # @overload min_addr(min_count: nil, fill_value: nil)
  #   Returns the row of each window's minimum (int64).
  #   @return [CArray]
  def min_addr (fill_value: nil, **kw)
    winner_row(@segments.min_addr(**kw), fill_value)
  end

  # @overload max_addr(min_count: nil, fill_value: nil)
  #   Returns the row of each window's maximum (int64).
  #   @return [CArray]
  def max_addr (fill_value: nil, **kw)
    winner_row(@segments.max_addr(**kw), fill_value)
  end

  # @overload reduce(*args, data_type: nil) { |piece| ... }
  #   Folds each window with the block, as {CASegmentIterator#reduce}.
  #   @return [CArray]
  def reduce (*args, **kw, &block)
    in_rows(@segments.reduce(*args, **kw, &block))
  end

  # @overload each { |piece| ... }
  #   Yields each row's window, in row order; a row with no window yields an
  #   empty array.
  #   @return [self, Enumerator]
  def each
    return to_enum(:each) unless block_given?
    pieces = []
    @segments.each { |piece| pieces << piece }
    empty = @value[0...0]
    @n.times do |r|
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

  # A weights array taken through the same cells as the value.
  def cells_of (weights)
    return weights unless weights.is_a?(CArray) && weights.elements == @n
    weights.project(@src_addr)
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
  # in the key's ticks scale both up to a finer grid.
  def key_numbers (key, before, after, interval)
    if key.is_a?(CATime) || key.is_a?(CATimedelta)
      ticks = key.ticks.int64
      widths = [before, after, interval].map { |w| w.nil? ? nil : duration_in_ticks(w, key.unit) }
      scale = widths.compact.map(&:denominator).inject(1, :lcm)
      ticks = ticks * scale unless scale == 1
      bw, aw, iv = widths.map { |w| w && (w * scale).to_i }
      bw ||= 0
      aw ||= 0
      check_widths(bw, aw, iv)
      return [ticks, bw, aw, iv]
    end
    unless key.numeric? && !key.complex?
      raise ArgumentError,
            "windows: on: is a time, a duration or a real number key " \
            "(got #{key.face? ? key.class : key.data_type_name})"
    end
    widths = [before, after, interval]
    widths.each do |w|
      next if w.nil? || w.is_a?(Numeric)
      raise ArgumentError,
            "windows: a numeric key takes widths as numbers (got #{w.inspect})"
    end
    if key.integer? && widths.compact.all? { |w| w.is_a?(Integer) }
      bw, aw, iv = widths
      bw ||= 0
      aw ||= 0
      check_widths(bw, aw, iv)
      [key.int64, bw, aw, iv]
    else
      bw, aw, iv = widths.map { |w| w && w.to_f }
      bw ||= 0.0
      aw ||= 0.0
      check_widths(bw, aw, iv)
      [key.float64, bw, aw, iv]
    end
  end

  def window_bound (width, op)
    return @key if width.nil?
    key = @key
    if key.is_a?(CATime) || key.is_a?(CATimedelta)
      res = width.is_a?(CATimedelta::Element) ? width.unit : CATime::Resolution.parse(width)
      key = key.to_unit(CATimeUnitAlgebra.finer(key.unit, res))
    end
    key.public_send(op, width)
  end

  # A duration in ticks of the key's unit, as a Rational.
  def duration_in_ticks (w, unit)
    case w
    when String
      res = CATime::Resolution.parse(w)
      count, base = res.count, res.base
    when CATimedelta::Element
      count, base = w.value * w.unit.count, w.unit.base
    else
      raise ArgumentError,
            "windows: a time key takes widths as durations such as \"1 hour\" " \
            "or a CATimedelta value (got #{w.inspect})"
    end
    unless CATimeUnitAlgebra.same_group?(base, unit.base)
      raise ArgumentError,
            "windows: a width of #{count} #{base} cannot be measured on a key in " \
            "#{unit.count} #{unit.base} (months and years have no fixed length)"
    end
    Rational(count) * CATimeUnitAlgebra.base_ratio(base) /
      (unit.count * CATimeUnitAlgebra.base_ratio(unit.base))
  end

  def check_widths (bw, aw, iv)
    if bw < 0 || aw < 0
      raise ArgumentError, "windows: before: and after: are not negative"
    end
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
    code = nil
    keys.each do |k|
      unless k.is_a?(CArray) && k.ndim == 1 && k.elements == @n
        raise ArgumentError, "windows: by: is a CArray of one value per row (#{@n} rows)"
      end
      distinct = CArray.align_addr(k, k, join: :outer)[0]
      c = k.locate_addr(distinct)
      if code.nil?
        code = c
      else
        t = code * distinct.elements + c
        code = t.locate_addr(CArray.align_addr(t, t, join: :outer)[0])
      end
    end
    code
  end
end
