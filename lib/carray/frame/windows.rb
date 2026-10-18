# CAFrame windows bounded by a width of a key column.

class CAFrame
  # Moving windows bounded by a width of the key column +on+ (a time, a
  # duration or a number) instead of a count of rows: the window of a row
  # whose key is t holds the rows whose key lies between t - before and
  # t + after.  +exclude:+ leaves out the lower end (default), the upper end,
  # both or neither, as CArray#is_between does.  +by:+ names columns that
  # must match exactly, so each window stays within one station; +interval:+
  # gives the key's grid step for WindowedFrame#is_complete.  The rows need
  # not be sorted; the answers come in row order.  A row whose key is
  # masked, NaN or infinite is in no window and has no window.
  #
  #   w = df.windows(on: "time", before: "1 hour", by: "station")
  #   w.mean("temp")     # => CArray, one value per row
  #   w.mean             # => frame of the windowed mean of every column
  #   w.elements         # => the number of rows in each window
  #
  # Given +at:+, the windows sit at those points of the key instead of at
  # the rows, and every answer is one per point: a frame of the reductions
  # has a row per point, the points as its index and the on: column's name
  # as its row axis name.  The points need not be sorted or on the rows'
  # keys.  A grid of points gives windows on a grid; a window with no row
  # answers as an empty reduction does (+mean+ UNDEF, +count+ 0).  +at:+
  # cannot be given with +by:+.
  #
  #   grid = CArray.time_range(t0, t1, unit: "1 hour")
  #   df.windows(on: "time", at: grid, after: "3 hours", exclude: :upper).mean
  #   # => a frame with a row per hour, the mean over [t, t + 3 hours)
  #
  # @return [WindowedFrame]
  def windows (on:, before: nil, after: nil, exclude: :lower, by: nil, interval: nil, at: nil)
    on_name  = column_key(on, "windows")
    key      = key_column(on_name, "windows")
    by_names = by.nil? ? [] : column_keys(by.is_a?(Array) ? by : [by], "windows")
    by_cols  = by_names.map { |b| key_column(b, "windows") }
    # The points are taken as they are now: a later write to the array
    # given changes neither the windows nor a result's index.
    at = at.copy if at.is_a?(CArray)
    plan = CAKeyWindowIterator.new(CArray.int64(nrow).seq, on: key,
                                   before: before, after: after, exclude: exclude,
                                   by: by_cols.empty? ? nil : by_cols,
                                   interval: interval, at: at)
    WindowedFrame.new(self, plan, [on_name, *by_names], at: at)
  end
end

# The windows of a CAFrame (CAFrame#windows): the reductions over each row's
# window, one answer per row, and what each window covered.
class WindowedFrame
  include CAFrame::ColumnVerbs

  def initialize (frame, plan, key_names, at: nil)
    @frame     = frame
    @plan      = plan
    @key_names = key_names
    @at        = at
  end

  # @overload [](name)
  #   Returns the CAKeyWindowIterator of one column.
  #   @return [CAKeyWindowIterator]
  def [] (name)
    @plan.for_value(@frame[@frame.__send__(:column_key, name, "windows")])
  end

  # What each window covered, one value per row: see CAKeyWindowIterator.
  [:first_addr, :last_addr, :first_key, :last_key, :elements, :is_complete].each do |m|
    define_method(m, &Ractor.make_shareable(proc { @plan.public_send(m) }))
  end

  # @overload bounds
  #   Returns the range each window was asked to cover, as two arrays of the
  #   key's kind.
  #   @return [Array(CArray, CArray)]
  def bounds
    @plan.bounds
  end

  # The windowed reductions.  Without names, a frame of every column whose
  # type has the reduction (the on: and by: columns left out), on the
  # frame's rows and index; given names, the CArray (one) or the Array of
  # them (several), as +df[...]+ returns columns.
  CArray.send(:define_named_methods, self,
              [:sum, :mean, :min, :max, :prod, :accumulate, :median,
               :variance, :stddev, :variancep, :stddevp], :window_reduction)

  CArray.send(:define_named_methods, self,
              [:first, :last, :nunique, :count, :all, :any], :window_value)

  private

  def window_reduction (reduction, *names, min_count: nil, fill_value: nil)
    window_reduce(reduction, names, min_count: min_count, fill_value: fill_value)
  end

  def window_value (reduction, *names)
    window_reduce(reduction, names)
  end

  # An N-D column (each row a profile) is reduced along the rows, each
  # window keeping the trailing shape, as a group reduces it.
  def window_reduce (reduction, names, **keywords)
    keywords = keywords.compact
    out = over_named_columns(reduction, names, @key_names) do |col|
      @plan.for_value(col).public_send(reduction, **keywords)
    end
    return out unless names.empty?
    if @at
      # Each result has an index of its own, as a group's result has.
      CAFrame.new(out, axis_name: @key_names.first, index: @at.copy)
    else
      CAFrame.new(out, axis_name: @frame.axis_name, index: @frame.index)
    end
  end
end
