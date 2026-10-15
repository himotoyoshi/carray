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
  # @return [WindowedFrame]
  def windows (on:, before: nil, after: nil, exclude: :lower, by: nil, interval: nil)
    on_name  = column_key(on, "windows")
    key      = key_column(on_name, "windows")
    by_names = by.nil? ? [] : (by.is_a?(Array) ? by : [by]).map { |b| column_key(b, "windows") }
    by_cols  = by_names.map { |b| key_column(b, "windows") }
    plan = CAKeyWindowIterator.new(CArray.int64(nrow).seq, on: key,
                                   before: before, after: after, exclude: exclude,
                                   by: by_cols.empty? ? nil : by_cols,
                                   interval: interval)
    WindowedFrame.new(self, plan, [on_name, *by_names])
  end
end

# The windows of a CAFrame (CAFrame#windows): the reductions over each row's
# window, one answer per row, and what each window covered.
class WindowedFrame

  def initialize (frame, plan, key_names)
    @frame     = frame
    @plan      = plan
    @key_names = key_names
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
  [:sum, :mean, :min, :max, :prod, :accumulate, :median,
   :variance, :stddev, :variancep, :stddevp].each do |red|
    define_method(red, &Ractor.make_shareable(proc do |*names, min_count: nil, fill_value: nil|
      window_reduce(red, names, min_count: min_count, fill_value: fill_value)
    end))
  end

  [:first, :last, :nunique, :count, :all, :any].each do |red|
    define_method(red, &Ractor.make_shareable(proc { |*names| window_reduce(red, names) }))
  end

  private

  def window_reduce (reduction, names, **keywords)
    keywords = keywords.compact
    if names.empty?
      cols = {}
      @frame.column_names.each do |name|
        next if @key_names.include?(name)
        col = @frame[name]
        next unless col.ndim == 1 && answers?(col, reduction)
        cols[name] = @plan.for_value(col).public_send(reduction, **keywords)
      end
      return CAFrame.new(cols, axis_name: @frame.axis_name, index: @frame.index)
    end
    results = names.map do |name|
      col = @frame[@frame.__send__(:column_key, name, reduction)]
      unless col.ndim == 1 && answers?(col, reduction)
        raise ArgumentError,
              "#{reduction}: column #{name.inspect} " \
              "(#{col.face? ? col.class : col.data_type}) has no windowed #{reduction}"
      end
      @plan.for_value(col).public_send(reduction, **keywords)
    end
    results.size == 1 ? results.first : results
  end

  # Whether the column's type defines the reduction, asked of the core on
  # one cell of it, as a group asks.
  def answers? (col, reduction)
    (col.elements > 0 ? col[0..0] : col).public_send(reduction)
    true
  rescue CArray::DataTypeError, TypeError, ArgumentError
    false
  end
end
