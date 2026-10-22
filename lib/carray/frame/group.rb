# CAFrame group_by (memo §5 spine, §11.6 surface).
#
# Grouping is always on the row axis (axis 0). The key is any length-N
# thing: a column name, several column names (composite key), or an
# external length-N CArray. Everything routes through categorize -> codes
# -> group_by_category, so the frame layer only builds the key and hands
# the group iterator back (exposure, §4.3).

require "carray/distance_limit"

class CAFrame
  # How many rows hold each value of a column, or each combination of the
  # values of several (every column by default), as a frame: the values as
  # its index (one column) or its first columns (several), and their counts
  # in a column +name:+ ("count"). +sort:+ orders the rows by +:count+, the
  # most first (the default; ties in the order the values first appear), by
  # +:value+, or not at all (+false+, the order the values first appear). A
  # row with a masked value is not counted, as +group_by+ leaves it out.
  #
  #   df.value_counts("station")
  #   df.value_counts("station", "weather", sort: :value)
  #
  # The columns are given as +select+ takes them. +group_by(...).size+ is the
  # same count in the order of the groups.
  #
  # @return [CAFrame]
  # @raise [ArgumentError] for another +sort:+, or a +name:+ a key has.
  def value_counts (*names, sort: :count, name: "count")
    unless [:count, :value, false].include?(sort)
      raise ArgumentError, "value_counts: sort: is :count, :value or false (got #{sort.inspect})"
    end
    keys = names.empty? ? column_names : names_selected(names, "value_counts")
    name = column_name_arg(name, "value_counts")
    if keys.include?(name)
      raise ArgumentError,
            "value_counts: a counted column is named #{name.inspect}; name the count " \
            "otherwise, as in value_counts(..., name: \"n\")"
    end
    out = group_by(*keys).size(name: name)
    case sort
    when :count then out.sort_by_key(name, descending: true)
    when :value then out.sort_by_key(*keys)
    else             out
    end
  rescue ArgumentError, KeyError, TypeError, CArray::DataTypeError => e
    raise e.class, e.message.sub(/\A(group_by|size|sort_by_key):/, "value_counts:"), e.backtrace
  end

  # Group rows by one or more keys. Each key is a column name (String) or an
  # external length-N CArray. Returns a GroupedFrame.
  #
  # With one key, a summary's index is the key's value of each group. With
  # several, each key is a column of a summary, holding its part of each
  # group's key, and the summary has no index; a CArray key among several
  # names its column by its position, "key0", "key1", ....
  def group_by(*keys)
    raise ArgumentError, "group_by needs at least one key" if keys.empty?
    CAFrame.__send__(:refuse_repeated_names, keys.grep(String), "group_by")
    cat  = grouping_categorical(keys)
    if keys.size == 1
      axis = keys.first.is_a?(String) ? keys.first : "group"
      return GroupedFrame.new(self, cat, axis, keys.grep(String), key: key_column(keys.first))
    end
    names = keys.each_with_index.map { |k, i| k.is_a?(String) ? k : "key#{i}" }
    CAFrame.__send__(:refuse_repeated_names, names, "group_by")
    GroupedFrame.new(self, cat, "group", keys.grep(String),
                     key_columns: names.zip(keys.map { |k| key_column(k) }).to_h)
  end

  # Whether each row repeats another row: a boolean column, true for the rows
  # whose values in the named columns (every column when none are named)
  # appear on more than one row, except the one +except:+ leaves out --
  #
  #   except: :first   every occurrence but the first (the default)
  #   except: :last    every occurrence but the last
  #   except: :none    every occurrence
  #
  # so +df[df.is_duplicate.not]+ keeps one row of each, and
  # +is_duplicate(except: :none).not+ is the rows that appear only once.
  # Values compare as group_by compares keys (NaN is one value, -0.0 is 0.0),
  # and a row with a masked cell in those columns is never a duplicate, as a
  # masked key is in no group. The index is compared only when named
  # (by the row axis name, as group_by takes it).
  #
  #   df[df.is_duplicate.not]                # the rows without repeats
  #   df.is_duplicate("station", "time")     # repeats of the pair
  #   df.is_duplicate(except: :none).not     # the rows that appear once
  #
  # @param names [Array<String>] the columns to compare; default every column.
  # @param except [Symbol] the occurrence left unmarked: :first, :last or :none.
  # @return [CArray] boolean, one value per row.
  # @raise [KeyError] for a name that is no column.
  # @raise [ArgumentError] when a compared column is N-D, there is no column
  #   to compare, or +except:+ is not one of the three.
  def is_duplicate(*names, except: :first)
    unless %i[first last none].include?(except)
      raise ArgumentError,
            "is_duplicate: except: must be :first, :last or :none (got #{except.inspect})"
    end
    names = column_keys(names, "is_duplicate")
    names = column_names if names.empty?
    raise ArgumentError, "is_duplicate: the frame has no column to compare" if names.empty?
    cols = names.map { |n| key_column(n, "is_duplicate") }
    cat   = CACategorical.send(:from_keys, cols)
    codes = cat.codes
    out =
      case except
      when :first then codes.mask_duplicates.is_masked
      when :last  then codes.flip(0).mask_duplicates.is_masked.flip(0).copy
      when :none
        index = codes.value.int64
        index[codes.is_masked] = 0 if codes.has_mask?
        sizes = cat.category_sizes
        sizes.elements > 0 ? sizes[index].gt(1) : CArray.boolean(nrow) { false }
      end
    codes.has_mask? ? out & codes.is_not_masked : out
  end

  # Group rows into time bins of length +unit+ along the time column (or the
  # time index) +name+, for the reductions GroupedFrame offers:
  #
  #   df.resample("time", "1 hour").mean
  #   df.resample("time", "1 day", fill: true).aggregate("rain" => ["rain", :sum])
  #
  # The result's index is the bin labels as a CATime, in time order, and its
  # row axis is named after +name+.
  #
  # +label: :left+ (the default) makes each bin start at its label and hold
  # the times at or after it: [00:00, 01:00) is labelled 00:00. +label: :right+
  # makes it end at its label and hold the times up to and including it:
  # (00:00, 01:00] is labelled 01:00, the convention for a value that
  # describes the hour before it. +origin:+ shifts the bins as +CATime#floor+
  # does ("1 hour" with origin 00:30 gives 00:30, 01:30, ...).
  #
  # Without +fill:+, a bin with no rows does not appear. With +fill: true+
  # every bin from the first to the last is a row, and an empty one reduces
  # as an empty reduction does: UNDEF for +mean+, 0 for +count+ and +sum+.
  # A row whose time is masked belongs to no bin.
  #
  # +by:+ (a column name or an Array of them) bins each group of rows on its
  # own: a group is the rows sharing the +by:+ values and a bin. The result
  # then has no index: the +by:+ columns and the bin times (named +name+)
  # are its first columns, the groups in the order their +by:+ values first
  # appear and the bins of each in time order. With +fill: true+ every group
  # has every bin from the first to the last of the whole frame. A row whose
  # +by:+ value is masked belongs to no group.
  #
  #   df.resample("date", "1 week", by: "shop").sum
  #
  # @param name [String] the time column, or the index's axis name.
  # @param unit [String, Symbol, CATime::Resolution] the bin length.
  # @param origin [nil, Time, String, CATime::Element] where bins start.
  # @param label [:left, :right] which end of a bin names it and is closed.
  # @param fill [Boolean] whether bins with no rows are rows of the result.
  # @param by [nil, String, Array<String>] columns whose groups are binned apart.
  # @return [GroupedFrame]
  # @raise [ArgumentError] when the column is not a CATime, or +label:+ is
  #   neither :left nor :right, or +by:+ names the time column.
  def resample(name, unit, origin: nil, label: :left, fill: false, by: nil)
    name = column_key(name, "resample")
    time = key_column(name, "resample")
    unless time.is_a?(CATime)
      raise ArgumentError, "resample: #{name.inspect} is not a time column (got #{time.class})"
    end
    bins =
      case label
      when :left  then time.floor(unit: unit, origin: origin)
      when :right then time.ceil(unit: unit, origin: origin)
      else
        raise ArgumentError, "resample: label: must be :left or :right (got #{label.inspect})"
      end
    # key-labels: the bins are the index, given the column's attributes below.
    grid = fill && bins.count_not_masked > 0 ? resample_grid(bins, unit) : bins.unique(sort: true)
    return resample_by(name, time, bins, grid, by, fill) unless by.nil?
    cat = CACategorical.from_codes(bins.locate_addr(grid), grid.to_a)
    GroupedFrame.new(self, cat, name, @columns.key?(name) ? [name] : [],
                     index: CAFrame.__send__(:key_labels, time, grid))
  end

  # resample with by:. A group is a (by values, bin) pair, coded as
  # group * bins + bin, so the codes run through the groups in the order their
  # by values first appear and through each group's bins in time order.
  private def resample_by(name, time, bins, grid, by, fill)
    by_names = column_keys(Array(by), "resample")
    raise ArgumentError, "resample: by: names no column" if by_names.empty?
    if by_names.include?(name)
      raise ArgumentError, "resample: by: names the time column #{name.inspect}"
    end
    by_cols = by_names.map { |n| key_column(n, "resample") }
    gcat = CACategorical.send(:from_keys, by_cols)
    ng   = gcat.labels.size
    nb   = grid.elements
    comb = gcat.codes.int64 * nb + bins.locate_addr(grid).int64
    # key-labels: the used (group, bin) codes, not labels; those go through key_labels below
    occupied = fill ? CArray.int64(ng * nb).seq! : comb.unique(sort: true)
    codes = fill ? comb : comb.locate_addr(occupied)
    g_of = nb > 0 ? occupied / nb : occupied
    b_of = nb > 0 ? occupied % nb : occupied
    # Each group's by values, from its first row.
    order = gcat.group_addr
    first = order[CArray.segment_offsets(lengths: gcat.category_sizes)[0...ng]]
    columns = {}
    by_names.zip(by_cols).each do |n, col|
      columns[n] = CAFrame.__send__(:key_labels, col, col.project(first))[g_of].copy
    end
    columns[name] = CAFrame.__send__(:key_labels, time, grid[b_of].copy)
    glabels = gcat.labels
    blabels = grid.to_a
    labels = occupied.to_a.map do |c|
      g, b = c.divmod(nb)
      parts = by_names.size == 1 ? [glabels[g]] : glabels[g]
      parts + [blabels[b]]
    end
    cat = CACategorical.from_codes(codes, labels)
    key_names = by_names + (@columns.key?(name) ? [name] : [])
    GroupedFrame.new(self, cat, "group", key_names, label_columns: columns)
  end

  # Every bin from the first occupied one to the last, stepped from the
  # first bin so an origin's phase (or label: :right) is kept. A month or a
  # year cannot be stepped on a finer grid, so it is stepped on the one-month
  # or one-year grid and then given the bins' unit, as the labels without
  # fill: are.
  private def resample_grid(bins, unit)
    base = CATime::Resolution.parse(unit).base
    if %i[Y M].include?(base)
      CArray.time_range(bins.min, bins.max, unit: base, step: unit).to_unit(bins.unit)
    else
      CArray.time_range(bins.min, bins.max, unit: bins.unit, step: unit)
    end
  end

  # Number of rows currently selected — used by group per-group view-frames
  # and elsewhere; already provided by the core (attr_reader :nrow).

  private def grouping_categorical(keys)
    CACategorical.send(:from_keys, keys.map { |k| key_column(k) })
  end

  # The column a key names, checked -- the one reading of a key every verb
  # that takes one goes through (group_by, is_duplicate, sort_by_key, join,
  # join_asof, align, pivot, resample, windows): a column of that name, or
  # the index by the row axis name; or a CArray of one value per row.  It
  # gives each row one value.  +verb+ is the method the caller called, for
  # the messages.
  private def key_column(key, verb = "group_by")
    col = case key
          when String
            # The index names the rows, so it is a key as a column is, by the
            # row axis name, as resample and pivot take it.
            @columns.fetch(key) do
              next @index if @index && @axis_name == key
              raise KeyError, "#{verb}: no column #{key.inspect}"
            end
          when CArray
            unless key.shape[0] == nrow
              raise ArgumentError,
                    "#{verb}: the key has #{key.shape[0]} values for #{nrow} rows"
            end
            key
          when Symbol
            column_key(key, verb)
          else
            raise ArgumentError, "#{verb}: a group key is a column name or a CArray (got #{key.class})"
          end
    # A key gives each row one value.  An N-D one would be categorized cell
    # by cell, making groups of cells rather than of rows.
    unless col.ndim == 1
      name = key.is_a?(String) ? "#{key.inspect} " : ""
      raise ArgumentError,
            "#{verb}: the key #{name}has shape #{col.shape.inspect}, not one value per row; " \
            "use one of its components (e.g. df[name][nil, 0])"
    end
    col
  end

  # Each column reduced over all the rows, as a frame of one row: the
  # reductions of +GroupedFrame+ with every row in one group. Given names, the
  # frame of those columns; without, of every column whose type has the
  # reduction. A column keeps its type where the reduction keeps it (the
  # earliest time of a time column is a time), and +min_count:+ /
  # +fill_value:+ / +keep_rows:+ work as they do for a group. A frame with no
  # rows still gives its one row: a sum of nothing is 0, a mean UNDEF.
  #
  #   df.mean                     # => one row, the mean of every numeric column
  #   df.max("tmax", "tmin")      # => one row, the two maxima
  #   df["tmax"] - df.mean("tmax", keep_rows: true)   # the anomaly on each row
  #
  # For one column's value as a Ruby value, reduce the column: +df["tmax"].mean+.
  #
  # @!method sum(*names, min_count: nil, fill_value: nil, keep_rows: false)
  #   @return [CAFrame] one row.
  # @!method mean(*names, min_count: nil, fill_value: nil, keep_rows: false)
  #   @return [CAFrame] one row.
  # @!method min(*names, min_count: nil, fill_value: nil, keep_rows: false)
  #   @return [CAFrame] one row.
  # @!method max(*names, min_count: nil, fill_value: nil, keep_rows: false)
  #   @return [CAFrame] one row.
  # @!method prod(*names, min_count: nil, fill_value: nil, keep_rows: false)
  #   @return [CAFrame] one row.
  # @!method accumulate(*names, min_count: nil, fill_value: nil, keep_rows: false)
  #   @return [CAFrame] one row.
  # @!method median(*names, min_count: nil, fill_value: nil, keep_rows: false)
  #   @return [CAFrame] one row.
  # @!method variance(*names, min_count: nil, fill_value: nil, keep_rows: false)
  #   @return [CAFrame] one row.
  # @!method stddev(*names, min_count: nil, fill_value: nil, keep_rows: false)
  #   @return [CAFrame] one row.
  # @!method variancep(*names, min_count: nil, fill_value: nil, keep_rows: false)
  #   @return [CAFrame] one row.
  # @!method stddevp(*names, min_count: nil, fill_value: nil, keep_rows: false)
  #   @return [CAFrame] one row.
  # @!method first(*names, keep_rows: false)
  #   @return [CAFrame] one row: each column's first present value.
  # @!method last(*names, keep_rows: false)
  #   @return [CAFrame] one row: each column's last present value.
  # @!method nunique(*names, keep_rows: false)
  #   @return [CAFrame] one row: each column's number of distinct present values.
  # @!method count(*names, keep_rows: false)
  #   @return [CAFrame] one row: each column's number of present values.
  # @!method all(*names, keep_rows: false)
  #   @return [CAFrame] one row, for the boolean columns.
  # @!method any(*names, keep_rows: false)
  #   @return [CAFrame] one row, for the boolean columns.
  CArray.send(:define_named_methods, self,
              [:sum, :mean, :min, :max, :prod, :accumulate, :median,
               :variance, :stddev, :variancep, :stddevp], :reduce_all_rows)

  CArray.send(:define_named_methods, self,
              [:first, :last, :nunique, :count, :all, :any], :reduce_all_rows_to_a_value)

  # Each column's +p+-th percentile (0 to 100) over all the rows, as a frame
  # of one row, as {#median} gives the 50th. The percentage comes first, then
  # the names.
  #
  #   df.percentile(90, "revenue")
  #
  # @param p [Numeric] the percentage.
  # @param names [Array<String>] the columns; default every column that has
  #   a percentile.
  # @return [CAFrame, CArray] one row; with +keep_rows: true+ the frame's
  #   rows, one name giving the CArray.
  def percentile (p, *names, min_count: nil, fill_value: nil, keep_rows: false)
    CAFrame.__send__(:check_percentage, p)
    reduce_all_rows(:percentile, *names, min_count: min_count, fill_value: fill_value,
                    keep_rows: keep_rows, args: [p])
  end

  # Each column's five quartile percentiles over all the rows, as
  # +CArray#quantile+ gives them, as a frame of one row: a column "x" gives
  # the five columns "x_p0", "x_p25", "x_p50", "x_p75" and "x_p100". With
  # +keep_rows: true+ every row holds them.
  #
  #   df.quantile("temp")
  #
  # @param names [Array<String>] the columns; default every column that has
  #   a quantile.
  # @return [CAFrame]
  def quantile (*names, keep_rows: false)
    named = {}
    ColumnWalk.new(self).over(:quantile, names) do |col, name|
      named[name] = col.quantile(axis: 0, keep_axis: true).map do |q|
        keep_rows ? q[CArray.int64(@nrow).fill(0), *([nil] * (q.ndim - 1))].copy : q
      end
    end
    cols = CAFrame.__send__(:quantile_columns, named)
    return CAFrame.new(cols) unless keep_rows
    return CAFrame.new(cols, axis_name: @axis_name, index: @index)
  end

  # The five columns a quantile gives a column, by name.
  def self.quantile_columns(named)
    named.each_with_object({}) do |(name, quartiles), cols|
      QUANTILE_SUFFIXES.zip(quartiles) { |suffix, q| cols["#{name}_#{suffix}"] = q }
    end
  end
  private_class_method :quantile_columns

  QUANTILE_SUFFIXES = %w[p0 p25 p50 p75 p100].freeze
  private_constant :QUANTILE_SUFFIXES

  private def reduce_all_rows (reduction, *names, min_count: nil, fill_value: nil, keep_rows: false, args: [])
    if fill_value.is_a?(Hash)
      unknown = fill_value.keys - column_names
      unless unknown.empty?
        raise ArgumentError,
              "#{reduction}: fill_value names no column #{unknown.map(&:inspect).join(', ')}"
      end
    end
    return reduce_down_the_rows(reduction, names, keep_rows, args) do |name|
      fill = fill_value.is_a?(Hash) ? fill_value[name] : fill_value
      { min_count: min_count, fill_value: fill }.compact
    end
  end

  private def reduce_all_rows_to_a_value (reduction, *names, keep_rows: false)
    return reduce_down_the_rows(reduction, names, keep_rows) { |_| {} }
  end

  # Each named column, or every column whose type has the reduction,
  # reduced by the column itself along the rows to one row (keep_axis), so
  # it keeps its type as the column's reduction keeps it. The block gives a
  # column's keywords. A frame of one row with no index; with +keep_rows+,
  # each row holding the result, as a group's +keep_rows+ gives it.
  private def reduce_down_the_rows (reduction, names, keep_rows, args = [])
    meth  = reduction == :count ? :count_not_masked : reduction
    named = {}
    out = ColumnWalk.new(self).over(reduction, names, [], args) do |col, name|
      result = col.public_send(meth, *args, axis: 0, keep_axis: true, **yield(name))
      if keep_rows
        result = result[CArray.int64(@nrow).fill(0), *([nil] * (result.ndim - 1))].copy
      end
      named[name] = result
    end
    return CAFrame.new(named) unless keep_rows
    return out if out.is_a?(CArray)
    return CAFrame.new(named, axis_name: @axis_name, index: @index)
  end

  # Values computed down the rows, one per row, as +GroupedFrame+ computes
  # them within each group, with every row in one group: each row's rank
  # (+order+, int64, 0 the smallest) and the running values up to and
  # including it. Given names, one name gives the CArray and several a frame
  # of those columns; without names, a frame of every column whose type has
  # the operation. A frame is on the frame's rows and index.
  #
  #   df["total"] = df.cumsum("rain")
  #   df["rank"]  = df.order("temp", descending: true)
  #
  # @!method order(*names, descending: false, method: :ordinal, kind: :quick)
  #   @return [CAFrame, CArray]
  # @!method cumsum(*names)
  #   @return [CAFrame, CArray]
  # @!method cumprod(*names)
  #   @return [CAFrame, CArray]
  # @!method cummax(*names)
  #   @return [CAFrame, CArray]
  # @!method cummin(*names)
  #   @return [CAFrame, CArray]
  # @!method cumcount(*names)
  #   @return [CAFrame, CArray]
  CArray.send(:define_named_methods, self,
              [:order, :cumsum, :cumprod, :cummax, :cummin, :cumcount], :run_down_all_rows)

  private def run_down_all_rows (operation, *names, **keywords)
    # The keywords are the core's to check, before any column is read.
    CArray.float64(1).public_send(operation, **keywords)
    out = ColumnWalk.new(self).over(operation, names, [], [], keywords) do |col, _|
      col.public_send(operation, **(col.ndim > 1 ? keywords.merge(axis: 0) : keywords))
    end
    return out if out.is_a?(CArray)
    return CAFrame.new(out, axis_name: @axis_name, index: @index)
  end

  # The frame's own walk over its columns: the one rule of a frame-wide verb
  # (ColumnVerbs) -- which columns, and the shape of the answer -- for the
  # verbs that run down all the rows, each column computed by itself.
  class ColumnWalk
    include CAFrame::ColumnVerbs

    def initialize (frame)
      @frame = frame
    end

    def over (verb, names, key_names = [], args = [], keywords = {}, &block)
      return over_named_columns(verb, names, key_names, args, keywords, &block)
    end
  end
  private_constant :ColumnWalk

  # The values of the columns moved along the rows: +n:+ rows back (a
  # negative +n+ looks ahead), or the value at an exact distance of the key
  # -- +before: "1 hour"+ gives each row the value of the row whose key is
  # one hour earlier, +after:+ one hour later. The key is the index, or the
  # column +on:+ names; it is a time, a duration or a number, and the
  # distance is a duration such as "1 hour" (or a CATimedelta value) or a
  # number accordingly. A row with no row at that key gets UNDEF; so does a
  # row whose key is masked. The rows need not be in order.
  #
  #   df["dtemp"] = df["temp"] - df.lag("temp", before: "1 hour")
  #   df.lag("temp", n: 1)               # the previous row
  #
  # +GroupedFrame#lag+ does the same within each group. Given names, one
  # name gives the CArray and several a frame of those columns; without
  # names, a frame of every column (the +on:+ column left out). A frame is
  # on the frame's rows and index. A result shows the column's attributes, as +CArray#lag+'s
  # does.
  #
  # @param names [Array<String>] the columns.
  # @param n [Integer] rows back.
  # @param before [String, CATimedelta::Element, Numeric] the distance back.
  # @param after [String, CATimedelta::Element, Numeric] the distance ahead.
  # @param on [String] the key column, with +before:+ or +after:+ (default the
  #   index).
  # @return [CArray, CAFrame]
  # @raise [ArgumentError] when +n:+, +before:+ and +after:+ are combined,
  #   when +on:+ comes without a distance, when there is no key, or when the
  #   key repeats (the row at a key would not be one row).
  def lag (*names, n: nil, before: nil, after: nil, on: nil)
    distance = lag_distance("lag", n, before, after, on)
    walk = ColumnWalk.new(self)
    if distance.nil?
      step = n.nil? ? 1 : n
      cols = walk.over(:lag, names, [], [step]) do |col, _|
        col.ndim > 1 ? col.lag(step, axis: 0) : col.lag(step)
      end
    else
      addr = lag_addresses("lag", [CArray.int64(nrow).seq], *distance)
      cols = walk.over(:lag, names, [distance.first], [1]) do |col, _|
        col[addr, *([nil] * (col.ndim - 1))].copy
      end
    end
    return cols if cols.is_a?(CArray)
    CAFrame.new(cols, axis_name: @axis_name, index: @index)
  end

  # [key name, key, sign, width] for a lag by distance; nil for one by rows.
  private def lag_distance (verb, n, before, after, on)
    if before.nil? && after.nil?
      raise ArgumentError, "#{verb}: on: goes with before: or after:" unless on.nil?
      return nil
    end
    unless n.nil?
      raise ArgumentError, "#{verb}: give n: (rows) or before: / after: (a distance of the key), not both"
    end
    unless before.nil? || after.nil?
      raise ArgumentError, "#{verb}: give before: or after:, not both"
    end
    if on.nil?
      unless @index
        raise ArgumentError, "#{verb}: the frame has no index; name the key column with on:"
      end
      on_name = @axis_name
    else
      on_name = column_key(on, verb)
    end
    key   = key_column(on_name, verb)
    label = before.nil? ? "#{verb}: after:" : "#{verb}: before:"
    width = CArray::DistanceLimit.read(before || after, key, label)
    return [on_name, key, before.nil? ? :+ : :-, width]
  end

  # For each row, the address of the row of its row set whose key is its own
  # key moved by the width; masked where there is none. A row in no set is
  # masked too, and so is a row whose key is NaN or infinite, which is no
  # distance from any key (as in windows).
  private def lag_addresses (verb, row_sets, _on_name, key, sign, width)
    key  = key.mask_invalid if key.float?
    addr = CArray.int64(nrow)
    addr[] = UNDEF
    row_sets.each do |rows|
      keys = key[rows]
      next if keys.count_not_masked == 0
      if keys.nunique < keys.count_not_masked
        raise ArgumentError,
              "#{verb}: the key repeats#{row_sets.size > 1 ? " within a group" : ""}, " \
              "so the row at a key is not one row"
      end
      addr[rows] = rows[lag_target(keys, sign, width).locate_addr(keys)]
    end
    return addr
  end

  # The keys moved by the width. A time is moved on the finer of its unit and
  # the width's, so that an hour back from a day is not rounded onto the day.
  private def lag_target (keys, sign, width)
    if width.is_a?(CATimedelta::Element) &&
       CATimeUnitAlgebra.same_group?(keys.unit.base, width.unit.base)
      keys = keys.to_unit(CATimeUnitAlgebra.finer(keys.unit, width.unit))
    end
    return keys.public_send(sign, width)
  end

end

# GroupedFrame — the result of +CAFrame#group_by+ (memo §11.6, §16).
#
# Holds the grouping categorical once (grouping is per-key, computed once
# and shared across every column). The surfaces:
#   grp["col"], grp[array] -> the CArray group iterator of a column or array
#   aggregate(spec)        -> declarative per-column reductions into a new frame
#   aggregate { |grp| }    -> columns built from iterators, run once
#   table { |g| }          -> Ruby escape, g is a per-group view-frame
class GroupedFrame
  include CAFrame::ColumnVerbs
  # +key_names+ are the frame columns the grouping was keyed on. They become
  # the result's index, so the reduction shortcuts must not also return them as
  # reduced columns; an external CArray key contributes no name.
  #
  # The result's index is +index:+ when given (one entry per group, in code
  # order); otherwise, for a single +key:+, the key's value at each group's
  # first row, so it keeps the key's data type and Face; otherwise an object
  # array of the labels.
  #
  # With several keys the result has no index: +key_columns:+ (name => the
  # key, one value per row) become its first columns, each holding the key's
  # value at each group's first row; +label_columns:+ (name => one value per
  # group, in code order) give them directly, for groups that may have no
  # rows (resample with fill: true).
  #
  # The grouping and the index are taken here, so a later change to the key
  # does not rename the groups; the values are read when a reduction is.
  def initialize(frame, cat, axis_name, key_names = [], index: nil, key: nil,
                 key_columns: nil, label_columns: nil)
    @frame     = frame
    @cat       = cat
    @axis_name = axis_name
    @key_names = key_names
    @labels    = cat.labels          # group values, in code order
    @index     = index ||
                 (key && CAFrame.__send__(:key_labels, key, key.project(first_rows)))
    @label_columns = label_columns ||
                     key_columns&.transform_values { |col| CAFrame.__send__(:key_labels, col, col.project(first_rows)) }
  end

  # Number of groups.
  def ngroup
    @labels.size
  end

  # The number of rows in each group, as a frame of one column, "size"
  # unless +name:+ says otherwise, labelled as a reduction's result is. A row
  # whose key is masked is in no group, so the sizes need not add up to the
  # frame's nrow.
  #
  # @param name [String] the result column's name.
  # @return [CAFrame]
  # @raise [ArgumentError] when a key has that name.
  def size (name: "size")
    refuse_changed_rows("size")
    name = @frame.__send__(:column_name_arg, name, "size")
    if @key_names.include?(name) || @axis_name == name
      raise ArgumentError,
            "size: a key is named #{name.inspect}; name the result otherwise, as in size(name: \"n\")"
    end
    return result_frame({ name => @cat.category_sizes.int64 }, false)
  end

  # Each group's label (an Array of the key values for several keys) and its
  # rows as a sub-frame sharing the frame's columns, in the order of
  # +labels+. Without a block, an Enumerator.
  #
  #   df.group_by("station").each { |station, rows| puts station, rows.nrow }
  #
  # @yieldparam label [Object, Array] the group's key value(s).
  # @yieldparam rows [CAFrame] the group's rows.
  # @return [GroupedFrame] self
  def each
    return enum_for(:each) { ngroup } unless block_given?
    refuse_changed_rows("each")
    ngroup.times { |k| yield @labels[k], @frame[group_address(k)] }
    return self
  end

  # Group key values (one per group), as an Array.
  def labels
    @labels.dup
  end

  # The CArray group iterator of a column, or of any CArray with one entry
  # per row of the frame: a value computed from columns, or a column with
  # some cells masked to leave them out. Its reductions answer one value
  # per group, and take the arguments a CArray's reductions take.
  #
  #   grp["temp"].percentile(90)
  #   grp[df["temp"] * df["w"]].sum / grp["w"].sum
  #   grp[df["temp"].mask_where(df["qc"].ne(0))].mean   # without the flagged rows
  #
  # The array is matched to the rows by position, as a CArray key of
  # +group_by+ is. An N-D one is grouped along its first axis; pass
  # +axis: 0+ to its reductions to keep the trailing shape.
  #
  # @param source [String, CArray] a column name, or a CArray whose first
  #   axis has one entry per row.
  # @return [CACategoricalIterator]
  # @raise [KeyError] for a name that is no column.
  # @raise [ArgumentError] when the CArray's first axis is not the rows.
  def [](source)
    refuse_changed_rows("[]")
    values =
      case source
      when CArray
        rows = source.ndim == 0 ? 0 : source.shape[0]
        unless source.ndim >= 1 && rows == @cat.elements
          raise ArgumentError,
                "[]: the array has #{source.ndim == 0 ? "no axis" : "#{rows} rows"} " \
                "for the frame's #{@cat.elements}"
        end
        source
      else
        @frame[@frame.__send__(:column_key, source, "[]")]
      end
    values.group_by_category(@cat)
  end

  # Declarative aggregation (memo §11.6). Spec maps an output column name to
  # +[input_column, reduction]+, where reduction is a Symbol (vectorized,
  # applied through the group iterator) or a Proc (per-group custom, called
  # with the group's column slice). A Symbol reduction takes its arguments
  # after it, as in a call: +["temp", :percentile, 90.0]+, and its keywords
  # last: +["temp", :mean, min_count: 6]+.
  #
  # With +keep_rows: true+ the rows are not collapsed: each row of the frame
  # gets the result of its own group, so the result has the frame's rows and
  # index, and a row whose key is masked (in no group) is UNDEF. The same
  # keyword works for +table+ and the reductions below.
  #
  #   df.group_by("station").aggregate("temp_mean" => ["temp", :mean], keep_rows: true)
  #
  # Given a block instead of a spec, aggregate yields the grouped frame once
  # and the block returns a Hash of output name => a CArray with one entry
  # per group. The block computes the columns with the grouped frame's
  # reductions, +grp[...]+ iterators and CArray arithmetic, so nothing runs
  # per group in Ruby:
  #
  #   df.group_by("station").aggregate do |g|
  #     {
  #       "temp"  => g["temp"].mean,
  #       "range" => g["temp"].max - g["temp"].min,
  #       "wmean" => g[df["temp"] * df["w"]].sum / g["w"].sum,
  #       "n"     => g["temp"].group_sizes,
  #     }
  #   end
  #
  # +keep_rows: true+ lays each column over the rows as for a spec.
  #
  # @raise [ArgumentError] when both a spec and a block are given, or the
  #   block returns something other than a Hash of per-group CArrays.
  def aggregate(spec = nil, keep_rows: false, **named, &block)
    refuse_changed_rows("aggregate")
    if block
      unless spec.nil? && named.empty?
        raise ArgumentError, "aggregate: give a spec or a block, not both"
      end
      return result_frame(block_columns(yield(self)), keep_rows)
    end
    spec = (spec || {}).merge(named)
    cols = {}
    spec.each do |out_name, (in_name, reduction, *args)|
      out = @frame.__send__(:column_name_arg, out_name, "aggregate")
      if in_name.is_a?(Symbol)
        raise ArgumentError,
              "aggregate: each entry is result name => [column, reduction] " \
              "(got #{out_name.inspect} => #{spec[out_name].inspect}); " \
              "as in aggregate(\"mean_#{out_name}\" => [#{out_name.inspect}, :mean])"
      end
      @frame.__send__(:column_key, in_name, "aggregate")
      options = args.last.is_a?(Hash) ? args.pop : {}
      cols[out] =
        case reduction
        when Symbol
          group_reduce(@frame[in_name], reduction, *args, **options)
        when Proc
          unless args.empty? && options.empty?
            raise ArgumentError, "aggregate: a Proc reduction takes no arguments (#{out.inspect})"
          end
          per_group_column(in_name, reduction)
        else
          raise ArgumentError,
                "reduction must be a Symbol or Proc (got #{reduction.class})"
        end
    end
    result_frame(cols, keep_rows)
  end

  # Cross-column Ruby escape (memo §11.6). The block receives a per-group
  # view-frame and returns a Hash of output-name => value; the values are
  # collected column-wise across groups into a new frame. +keep_rows: true+
  # gives each row its group's values, as for +aggregate+.
  #
  # The columns are the names any group's Hash has, in the order they
  # first appear; a group whose Hash lacks a name is UNDEF there, as
  # +from_records+ reads a record that lacks a key.
  def table(keep_rows: false)
    refuse_changed_rows("table")
    outs = []
    each_group_frame do |g|
      out = yield(g)
      unless out.is_a?(Hash)
        raise ArgumentError, "table block must return a Hash (got #{out.class})"
      end
      out.each_key { |k| @frame.__send__(:column_name_arg, k, "table") }
      outs << out
    end
    names = CAFrame.__send__(:record_key_union, outs)
    cols = {}
    names.each do |name|
      cols[name] = column_of_values(outs.map { |out| out.fetch(name, nil) })
    end
    result_frame(cols, keep_rows)
  end

  # Convenience reductions over every column that defines the reduction. A
  # column is in the result when its type answers the reduction -- a time
  # column has a mean, a minimum and a maximum but no sum, a string column a
  # minimum and a maximum only -- and left out when it does not, as are the
  # key columns. An N-D column is reduced along the rows, so each group keeps
  # its trailing shape: a (N, L) column gives (groups, L). Each
  # takes +min_count:+ and +fill_value:+ as a core reduction does: a group
  # with fewer than min_count present values is UNDEF, and fill_value fills
  # the UNDEF cells. One fill_value goes to every column and has to suit each
  # (a number into a string column raises); a Hash of column name => value
  # fills those columns only. +keep_rows: true+ gives each row its group's value
  # instead of one row per group, as for +aggregate+.
  #
  # Given column names, they reduce those columns only, and the result is
  # the frame of those columns, one row per group, labelled as above; with
  # +keep_rows: true+ one comes back as +df[name]+ returns it, a CArray on
  # the frame's rows, and several as a frame on those rows. For a group's
  # values alone, reduce the column's group iterator: +grp["temp"].mean+.
  #
  #   grp.mean                                   # a frame, one row per group
  #   grp.mean("temp")                           # a frame of temp, one row per group
  #   df["temp"] - grp.mean("temp", keep_rows: true)   # anomaly from the group mean
  #
  # @!method sum(*names, min_count: nil, fill_value: nil, keep_rows: false)
  #   Returns a frame of the per-group sum of every column whose type has a
  #   sum, an N-D one per group along the rows. Other columns are left out.
  #   @return [CAFrame, CArray] a frame with one row per
  #     group, indexed by the group labels (of the named columns when names
  #     are given), or with keep_rows: true the frame's rows and index; given
  #     names and keep_rows: true, the CArray (one) or a frame of them on the
  #     frame's rows (several).
  # @!method mean(*names, min_count: nil, fill_value: nil, keep_rows: false)
  #   Returns a frame of the per-group mean of every column whose type has
  #   a mean, as {#sum} does.
  #   @return [CAFrame] one row per group.
  # @!method min(*names, min_count: nil, fill_value: nil, keep_rows: false)
  #   Returns a frame of the per-group minimum of every column whose type has
  #   a minimum, as {#sum} does.
  #   @return [CAFrame] one row per group.
  # @!method max(*names, min_count: nil, fill_value: nil, keep_rows: false)
  #   Returns a frame of the per-group maximum of every column whose type has
  #   a maximum, as {#sum} does.
  #   @return [CAFrame] one row per group.
  # @!method prod(*names, min_count: nil, fill_value: nil, keep_rows: false)
  #   Returns the per-group product, as {#sum} does.
  #   @return [CAFrame] one row per group.
  # @!method accumulate(*names, min_count: nil, fill_value: nil, keep_rows: false)
  #   Returns the per-group sum kept in each column's own data type, as
  #   +CArray#accumulate+, as {#sum} does.
  #   @return [CAFrame] one row per group.
  # @!method median(*names, min_count: nil, fill_value: nil, keep_rows: false)
  #   Returns the per-group median, as {#sum} does.
  #   @return [CAFrame] one row per group.
  # @!method variance(*names, min_count: nil, fill_value: nil, keep_rows: false)
  #   Returns the per-group sample variance (divisor n - 1), as {#sum} does.
  #   @return [CAFrame] one row per group.
  # @!method stddev(*names, min_count: nil, fill_value: nil, keep_rows: false)
  #   Returns the per-group sample standard deviation, as {#sum} does.
  #   @return [CAFrame] one row per group.
  # @!method variancep(*names, min_count: nil, fill_value: nil, keep_rows: false)
  #   Returns the per-group population variance (divisor n), as {#sum} does.
  #   @return [CAFrame] one row per group.
  # @!method stddevp(*names, min_count: nil, fill_value: nil, keep_rows: false)
  #   Returns the per-group population standard deviation, as {#sum} does.
  #   @return [CAFrame] one row per group.
  CArray.send(:define_named_methods, self,
              [:sum, :mean, :min, :max, :prod, :accumulate, :median,
               :variance, :stddev, :variancep, :stddevp], :group_reduction)

  private def group_reduction (red, *names, min_count: nil, fill_value: nil, keep_rows: false)
    refuse_changed_rows(red)
    reduce_columns(red, names, keep_rows, min_count: min_count, fill_value: fill_value)
  end

  # Each group's +p+-th percentile (0 to 100), as {#median} gives the 50th
  # and {#sum} gives its sums. The percentage comes first, then the names.
  #
  #   grp.percentile(90, "revenue")
  #
  # @param p [Numeric] the percentage.
  # @param names [Array<String>] the columns; default every column that has
  #   a percentile.
  # @return [CAFrame, CArray] one row per group, as {#sum} returns.
  def percentile (p, *names, min_count: nil, fill_value: nil, keep_rows: false)
    CAFrame.__send__(:check_percentage, p)
    refuse_changed_rows(:percentile)
    reduce_columns(:percentile, names, keep_rows, args: [p], min_count: min_count, fill_value: fill_value)
  end

  # Each group's five quartile percentiles, as +CAFrame#quantile+ gives them
  # for all the rows: a column "x" gives "x_p0", "x_p25", "x_p50", "x_p75"
  # and "x_p100", one row per group, labelled as {#sum} labels its result;
  # with +keep_rows: true+ on the frame's rows.
  #
  #   grp.quantile("temp")
  #
  # @param names [Array<String>] the columns; default every column that has
  #   a quantile.
  # @return [CAFrame]
  def quantile (*names, keep_rows: false)
    refuse_changed_rows(:quantile)
    refuse_key_as_result(:quantile, names) unless keep_rows
    named = {}
    over_named_columns(:quantile, names, @key_names) do |col, name|
      named[name] = group_reduce(col, :quantile).map { |q| keep_rows ? spread_to_rows(q) : q }
    end
    cols = CAFrame.__send__(:quantile_columns, named)
    return result_frame(cols, false) unless keep_rows
    return CAFrame.new(cols, axis_name: @frame.axis_name, index: @frame.index)
  end

  # The same convenience for the reductions that take no min_count: or
  # fill_value:, as the core ones take none: a value of the group (first,
  # last), a count (nunique, count) or a boolean fold (all, any).
  #
  # @!method first(*names, keep_rows: false)
  #   Returns each group's first present value in row order, UNDEF for a
  #   group with none, as {#sum} returns its sums.
  #   @return [CAFrame] one row per group.
  # @!method last(*names, keep_rows: false)
  #   Returns each group's last present value in row order.
  #   @return [CAFrame] one row per group.
  # @!method nunique(*names, keep_rows: false)
  #   Returns each group's number of distinct present values (int64).
  #   @return [CAFrame] one row per group.
  # @!method count(*names, keep_rows: false)
  #   Returns each group's number of present values (int64), a masked cell
  #   left out.
  #   @return [CAFrame] one row per group.
  # @!method all(*names, keep_rows: false)
  #   Returns whether every present value of the group is true, for the
  #   boolean columns.
  #   @return [CAFrame] one row per group.
  # @!method any(*names, keep_rows: false)
  #   Returns whether any present value of the group is true, for the
  #   boolean columns.
  #   @return [CAFrame] one row per group.
  CArray.send(:define_named_methods, self,
              [:first, :last, :nunique, :count, :all, :any], :group_value)

  private def group_value (red, *names, keep_rows: false)
    refuse_changed_rows(red)
    reduce_columns(red, names, keep_rows)
  end

  # Values computed within each group and kept on the frame's rows, in row
  # order: the value some rows back in the same group, a rank among the
  # group's rows, a running statistic. A row in no group is UNDEF. Without
  # names they give a frame of every column whose type has the operation
  # (the key columns left out), on the frame's rows and index; given names,
  # the CArray (one), as +df[name]+ returns a column, or a frame of those
  # columns (several) on the frame's rows and index. An N-D column runs along the rows.
  #
  #   df["dtemp"] = df["temp"] - grp.lag("temp")   # change since the station's previous row
  #   grp.order("temp", descending: true)          # rank within the station
  #   grp.cumsum("rain")                           # running total per station
  #
  # "Previous" is the previous row of the frame: sort the frame first
  # (+sort_by_key("time")+) when its rows are not in time order.
  #
  # @!method lag(*names, n: 1, before: nil, after: nil, on: nil)
  #   Returns each row's value +n+ rows back in its own group, UNDEF where
  #   the group has none, as +CArray#lag+; a negative +n+ looks ahead. With
  #   +before:+ (or +after:+) instead, the value of the group's row whose key
  #   (the index, or the column +on:+ names) is that distance earlier (or
  #   later), as +CAFrame#lag+ gives it.
  #   @return [CAFrame, CArray]
  # @!method order(*names, descending: false, method: :ordinal, kind: :quick)
  #   Returns each row's rank among its group's rows (int64, 0 the
  #   smallest), as +CArray#order+ ranks them.
  #   @return [CAFrame, CArray]
  # @!method cumsum(*names)
  #   Returns the running sum within each group, as +CArray#cumsum+.
  #   @return [CAFrame, CArray]
  # @!method cumprod(*names)
  #   Returns the running product within each group.
  #   @return [CAFrame, CArray]
  # @!method cummax(*names)
  #   Returns the running maximum within each group.
  #   @return [CAFrame, CArray]
  # @!method cummin(*names)
  #   Returns the running minimum within each group.
  #   @return [CAFrame, CArray]
  # @!method cumcount(*names)
  #   Returns the running count of present values within each group (int64).
  #   @return [CAFrame, CArray]
  def lag (*names, n: nil, before: nil, after: nil, on: nil)
    distance = @frame.__send__(:lag_distance, "lag", n, before, after, on)
    return transform_columns(:lag, names, [n.nil? ? 1 : n], {}) if distance.nil?
    refuse_changed_rows("lag")
    addr = @frame.__send__(:lag_addresses, "lag", (0...ngroup).map { |k| group_address(k) }, *distance)
    out = over_named_columns(:lag, names, @key_names | [distance.first], [1], {}) do |col|
      col[addr, *([nil] * (col.ndim - 1))].copy
    end
    return out if out.is_a?(CArray)
    CAFrame.new(out, axis_name: @frame.axis_name, index: @frame.index)
  end

  def order (*names, descending: false, method: :ordinal, kind: :quick)
    transform_columns(:order, names, [], { descending: descending, method: method, kind: kind })
  end

  CArray.send(:define_named_methods, self,
              [:cumsum, :cumprod, :cummax, :cummin, :cumcount], :group_scan)

  private def group_scan (op, *names)
    transform_columns(op, names, [], {})
  end

  # Fill the masked cells of a column from the rows of the same group, in
  # place, as +CAFrame#fill+ does for the whole column: +:ffill+ carries the
  # group's last present value forward in row order, +:bfill+ its next one
  # back, and +:linear+ interpolates between the group's present values
  # against the frame's index (against the row position within the group
  # when the frame has no index). A fill never reaches across into another
  # group, so a cell with nothing to carry or interpolate from in its group
  # stays masked, and a row whose key is masked (in no group) is left as it
  # is. A constant fills every masked cell, as +CAFrame#fill+ does. Returns
  # self.
  #
  #   df.group_by("station").fill("temp", :ffill)
  #   df.group_by("station").fill("temp", :linear)
  #   df.group_by("station").fill("temp" => :linear, "rain" => 0.0)
  #   df.group_by("station").fill("temp", "rain", :linear)
  #   df.group_by("station").fill(:ffill)    # every column with a masked cell
  #
  # +:ffill+ and +:bfill+ follow the row order: sort the frame first
  # (+sort_by_key("time")+) when its rows are not in time order. +:linear+
  # reads each group in the order of the index, as +CAFrame#fill+ does.
  #
  # @param args [Array] the columns, as +CAFrame#fill+ takes them, then
  #   +:ffill+, +:bfill+, +:linear+, or a constant; or one Hash of them.
  # @return [GroupedFrame] self
  # @raise [ArgumentError] for another Symbol, or for +:linear+ on a column
  #   or index +CAFrame#fill+ cannot interpolate.
  def fill (*args)
    plan = @frame.__send__(:fill_arguments, args, @key_names)
    return self if plan.nil?
    if plan.is_a?(Hash)
      @frame.__send__(:fill_by_map, plan, "fill") do |frame, key, how|
        grouped = if frame.equal?(@frame)
                    self
                  else
                    # key-labels: the groups' index as it is, on a copy of the frame
                    GroupedFrame.new(frame, @cat, @axis_name, @key_names, index: @index,
                                     label_columns: @label_columns)
                  end
        grouped.fill(key, how)
      end
      return self
    end
    name, method_or_value = plan
    refuse_changed_rows("fill")
    case method_or_value
    when :ffill, :bfill
      @frame.__send__(:refuse_if_frozen)
      key = @frame.__send__(:column_key, name, "fill")
      col = @frame[key]
      # A row in no group is UNDEF in the fill, so writing it changes nothing.
      held = group_transform(col, :strip_mask, [], { method: method_or_value })
      target = col.is_masked
      col[target] = held[target] if target.any
    when :linear
      @frame.__send__(:refuse_if_frozen)
      key = @frame.__send__(:column_key, name, "fill")
      # The column and the index are checked as CAFrame#fill checks them,
      # on no rows, so a call without groups is refused as one with groups.
      @frame.__send__(:select_rows, CA_INT64([])).fill(key, :linear)
      # Each group's rows as a frame of views, so its fill writes through.
      ngroup.times do |k|
        @frame.__send__(:select_rows, group_address(k)).fill(key, :linear)
      end
    when Symbol
      raise ArgumentError,
            "fill: unknown method #{method_or_value.inspect} " \
            "(:ffill | :bfill, or a constant fill value)"
    else
      @frame.fill(name, method_or_value)
    end
    self
  end

  # The first +n+ rows of each group, in row order, as a view-frame: the
  # rows stay in the frame's order, as +filter+ keeps them. A group with
  # fewer than +n+ rows gives all of them; a row whose group key is masked
  # is in no group.
  #
  #   df.group_by("station").head(1)    # each station's first row
  #
  # @param n [Integer] how many rows per group, 0 or more (default 5).
  # @return [CAFrame]
  def head (n = 5)
    return rows_at_the_ends_of_groups("head", n) { |addr| addr.first(n) }
  end

  # The last +n+ rows of each group, in row order, as +head+ gives the first.
  #
  # @param n [Integer] how many rows per group, 0 or more (default 5).
  # @return [CAFrame]
  def tail (n = 5)
    return rows_at_the_ends_of_groups("tail", n) { |addr| addr.last(n) }
  end

  private def rows_at_the_ends_of_groups (verb, n)
    refuse_changed_rows(verb)
    unless n.is_a?(Integer)
      raise TypeError, "#{verb}: the count is an Integer (got #{n.inspect})"
    end
    raise ArgumentError, "#{verb}: the count must be 0 or more (got #{n})" if n < 0
    picked = (0...ngroup).flat_map { |k| yield(group_address(k).to_a) }.sort
    return @frame[CA_INT64(picked)]
  end

  # The +n+ rows of each group with the largest values of the key columns,
  # as a view-frame: the groups in the order of +labels+, each group's rows
  # largest first, as +CAFrame#nlargest+ orders them (several keys break
  # ties in turn, a NaN or masked key loses to every value, rows that tie on
  # every key keep their order). A group with fewer than +n+ rows gives all
  # of them; a row whose group key is masked is in no group.
  #
  #   df.group_by("station").nlargest(3, "temp")   # each station's 3 warmest rows
  #
  # @param n [Integer] how many rows per group, 0 or more.
  # @param keys [Array<String>] the key columns (or the index axis name).
  # @return [CAFrame]
  # @raise [ArgumentError] when +n+ is negative or no key is given.
  def nlargest (n, *keys)
    return largest_rows_of_groups("nlargest", n, keys, true)
  end

  # The +n+ rows of each group with the smallest values of the key columns,
  # as +nlargest+ gives the largest.
  #
  # @param n [Integer] how many rows per group, 0 or more.
  # @param keys [Array<String>] the key columns (or the index axis name).
  # @return [CAFrame]
  # @raise [ArgumentError] when +n+ is negative or no key is given.
  def nsmallest (n, *keys)
    return largest_rows_of_groups("nsmallest", n, keys, false)
  end

  private def largest_rows_of_groups (verb, n, keys, descending)
    refuse_changed_rows(verb)
    unless n.is_a?(Integer)
      raise TypeError, "#{verb}: the count is an Integer (got #{n.inspect})"
    end
    raise ArgumentError, "#{verb}: the count must be 0 or more (got #{n})" if n < 0
    raise ArgumentError, "#{verb}: give at least one key column" if keys.empty?
    cols = keys.map do |key|
      @frame.__send__(:key_column, @frame.__send__(:column_key, key, verb), verb)
    end
    sort_keys = cols.map { |col| descending ? col.order(descending: true, method: :dense) : col }
    # Rows sorted by group, then by the keys; a row in no group comes last.
    addr = CArray.sort_addr(group_codes, *sort_keys, masked_position: :last).to_a
    picked = []
    start  = 0
    @cat.category_sizes.to_a.each do |size|
      picked.concat(addr[start, [n, size].min]) if n > 0
      start += size
    end
    return @frame[CA_INT64(picked)]
  end

  # Keep the rows of the groups the block chooses. The block receives the
  # grouped frame and returns a boolean CArray with one value per group,
  # built from the group reductions, as +CAFrame#filter+'s block returns one
  # per row:
  #
  #   grp.filter { |g| g["temp"].count_not_masked >= 20 }   # stations with 20 readings
  #   grp.filter { |g| g["temp"].mean > 15.0 }
  #
  # The rows of a chosen group are kept in the frame's order, as a sub-frame
  # sharing the frame's columns. A group whose value is UNDEF is
  # undetermined, as is a row whose key is masked (it belongs to no group):
  # such rows are not kept, as +CAFrame#filter+ does not keep them.
  #
  # @yieldparam grouped [GroupedFrame] self.
  # @yieldreturn [CArray] boolean, one value per group.
  # @return [CAFrame]
  # @raise [ArgumentError] when the block does not return a boolean CArray of
  #   shape [ngroup].
  def filter
    refuse_changed_rows("filter")
    chosen = yield(self)
    unless chosen.is_a?(CArray) && chosen.data_type == :boolean
      raise ArgumentError,
            "filter block must return a boolean CArray (got #{chosen.is_a?(CArray) ? "a #{CArray::Inspector.type_label(chosen)} CArray" : chosen.class})" +
            CAFrame.__send__(:equality_hint, chosen)
    end
    unless chosen.shape == [ngroup]
      raise ArgumentError,
            "filter mask has shape #{chosen.shape.inspect}, " \
            "expected [#{ngroup}] (one value per group)"
    end
    rows = spread_to_rows(chosen)
    @frame.filter(rows)
  end

  # Returns the grouped rows as a frame: the frame the grouping was made
  # from, its rows, columns and index, as a new frame sharing its columns.
  # Nothing is copied, so a write to a cell reaches the grouped frame's
  # rows; adding or dropping a column changes the new frame only.
  #
  #   def warm_stations (grp)
  #     grp.filter { |g| g["temp"].mean > 15.0 }   # the rows of some groups
  #   end
  #   grp.to_frame                                  # all of its rows
  #
  # @return [CAFrame]
  def to_frame
    refuse_changed_rows("to_frame")
    @frame.__send__(:rebuild, @frame.column_names.to_h { |name| [name, @frame[name]] })
  end

  # @return [String]
  def inspect
    "#<GroupedFrame ngroup=#{ngroup} by=#{@axis_name.inspect}>"
  end

  # A within-group transform of the named columns, or of every column whose
  # type has it. The arguments are checked by the core first: below, a
  # refusal reads as "this type has no such operation", and a wrong keyword
  # would otherwise leave every column out without a word.
  private def transform_columns(op, names, args, keywords)
    refuse_changed_rows(op)
    CArray.float64(1).public_send(op, *args, **keywords)
    out = over_named_columns(op, names, @key_names, args, keywords) do |col|
      group_transform(col, op, args, keywords)
    end
    return out if out.is_a?(CArray)
    CAFrame.new(out, axis_name: @frame.axis_name, index: @frame.index)
  end

  # A column's within-group transform: an N-D column runs along the rows.
  private def group_transform(col, op, args, keywords)
    it = col.group_by_category(@cat)
    keywords = keywords.merge(axis: 0) if col.ndim > 1
    it.public_send(op, *args, **keywords)
  end

  # Each result gets its own index.
  private def label_index
    return @index.copy if @index
    CArray.object(@labels.size) { |i| @labels[i] }
  end

  # A key column is the index here, not a result column.  Named columns give
  # the frame of those columns only, one row per group; with +keep_rows+
  # they come back as df[...] returns them, each on the frame's rows.
  private def reduce_columns(reduction, names, keep_rows, args: [], **keywords)
    refuse_key_as_result(reduction, names) unless keep_rows
    keywords = keywords.compact
    fills = keywords.delete(:fill_value)
    if fills.is_a?(Hash)
      unknown = fills.keys - @frame.column_names
      unless unknown.empty?
        raise ArgumentError,
              "#{reduction}: fill_value names no column #{unknown.map(&:inspect).join(', ')}"
      end
    end
    named = {}
    out = over_named_columns(reduction, names, @key_names, args) do |col, name|
      fill = fills.is_a?(Hash) ? fills[name] : fills
      kw = fill.nil? ? keywords : keywords.merge(fill_value: fill)
      col = group_reduce(col, reduction, *args, **kw)
      named[name] = keep_rows && !names.empty? ? spread_to_rows(col) : col
    end
    return result_frame(out, keep_rows) if names.empty?
    # One named column on the frame's rows comes back as df[name] returns it,
    # several as a frame on those rows; one value per group needs the group
    # labels beside it.
    if keep_rows
      return out if out.is_a?(CArray)
      return CAFrame.new(out, axis_name: @frame.axis_name, index: @frame.index)
    end
    result_frame(named, false)
  end

  # A key column named in a reduction would be a result column beside the
  # key it is the group of: the index, or a key column of the result.
  private def refuse_key_as_result(reduction, names)
    named = names.map { |n| n.is_a?(String) ? n : nil }.compact & @key_names
    return if named.empty?
    hint = reduction == :count ? "; the number of rows of each group is size" : ""
    raise ArgumentError,
          "#{reduction}: #{named.first.inspect} is the group key, already in the result#{hint}"
  end

  # One row per group, indexed by the labels; or, with +keep_rows+, the
  # frame's rows, each holding its group's result.
  private def result_frame(cols, keep_rows)
    unless keep_rows
      return CAFrame.new(cols, axis_name: @axis_name, index: label_index) unless @label_columns
      clash = cols.keys & @label_columns.keys
      unless clash.empty?
        raise ArgumentError,
              "a result column has the name of a key column: #{clash.map(&:inspect).join(', ')}"
      end
      return CAFrame.new(@label_columns.transform_values(&:copy).merge(cols))
    end
    CAFrame.new(cols.transform_values { |col| spread_to_rows(col) },
                axis_name: @frame.axis_name, index: @frame.index)
  end

  # A per-group result (one entry per group along axis 0) laid back over the
  # frame's rows through the group codes. A row in no group is UNDEF.
  private def spread_to_rows(result)
    # A row in no group has a masked index cell, which x[i] answers as a
    # hole: so even with no group at all, the result keeps its type.
    codes = group_codes
    index = codes.value.int64
    index[codes.is_masked] = UNDEF
    result[index, *[nil] * (result.ndim - 1)].copy
  end

  # A column's group reduction. An N-D column is reduced along the rows, so
  # each group keeps the trailing shape: a profile column (N, L) gives (G, L).
  private def group_reduce(col, reduction, *args, **keywords)
    it = col.group_by_category(@cat)
    if col.ndim > 1 && !keywords.key?(:axis)
      it.public_send(reduction, *args, axis: 0, **keywords)
    else
      it.public_send(reduction, *args, **keywords)
    end
  end

  # The columns an aggregate block returned: a Hash of names to CArrays
  # with one entry per group along their first axis.
  private def block_columns(out)
    unless out.is_a?(Hash)
      raise ArgumentError, "aggregate block must return a Hash (got #{out.class})"
    end
    out.each_with_object({}) do |(name, col), cols|
      name = @frame.__send__(:column_name_arg, name, "aggregate")
      unless col.is_a?(CArray) && col.ndim >= 1 && col.shape[0] == ngroup
        got = col.is_a?(CArray) ? "shape #{col.shape.inspect}" : col.class.to_s
        raise ArgumentError,
              "aggregate: #{name.inspect} must be a CArray with one value per group " \
              "(#{ngroup}), got #{got}"
      end
      cols[name] = col
    end
  end

  private def per_group_column(in_name, proc)
    results = []
    each_group_slice(in_name) { |slice| results << proc.call(slice) }
    column_of_values(results)
  end

  # The grouping holds one code per row of the frame as it was when grouped.
  # A frame whose row count changed since (a splice, a deletion) has rows
  # the grouping does not know, so every verb refuses it.
  private def refuse_changed_rows(verb)
    return if @frame.nrow == @cat.elements
    raise ArgumentError,
          "#{verb}: the frame has #{@frame.nrow} rows, #{@cat.elements} when it " \
          "was grouped; group it again"
  end

  # A column of the Ruby values the groups gave, typed as from_records types
  # a record's values: Integers int64, numbers float64, Strings text, time
  # elements a time column, arrays of one shape an N-D column, anything else
  # object. UNDEF and nil are missing.
  private def column_of_values(values)
    CAFrame.__send__(:build_record_column, values, values.size)
  end

  private def each_group_slice(in_name)
    col = @frame[in_name]
    ngroup.times do |k|
      yield col[group_address(k), *([nil] * (col.ndim - 1))]
    end
  end

  private def each_group_frame
    ngroup.times { |k| yield @frame[group_address(k)] }
  end

  # The first row of each group, in code order.
  # With few groups each row's number is folded into its group's slot by the
  # smallest, which needs no sort of the rows (a numeric column then reduces
  # without one too); a row in no group (masked code) is in no slot, and a
  # group without rows keeps no row (UNDEF). With more groups the columns
  # are gathered through the sort anyway, so the first rows are read off it.
  private def first_rows
    if ngroup > CACategoricalIterator::SCATTER_CATEGORIES_MAX
      return group_perm[group_bounds[0...ngroup]]
    end
    n     = @cat.elements
    first = CArray.int64(ngroup).fill(n)
    first.scatter_min!(@cat.codes, CArray.int64(n).seq!)
    first[first.eq(n)] = UNDEF if ngroup > 0
    first
  end

  private def group_address(k)
    group_perm[group_bounds[k]...group_bounds[k + 1]]
  end

  private def group_codes
    @cat.codes
  end

  private def group_perm
    @group_perm ||= @cat.group_addr
  end

  private def group_bounds
    @group_bounds ||= CArray.segment_offsets(lengths: @cat.category_sizes)
  end
end
