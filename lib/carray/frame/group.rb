# CAFrame group_by (memo §5 spine, §11.6 surface).
#
# Grouping is always on the row axis (axis 0). The key is any length-N
# thing: a column name, several column names (composite key), or an
# external length-N CArray. Everything routes through categorize -> codes
# -> group_by_category, so the frame layer only builds the key and hands
# the group iterator back (exposure, §4.3).

class CAFrame
  # Group rows by one or more keys. Each key is a column name (String) or an
  # external length-N CArray. Returns a GroupedFrame.
  def group_by(*keys)
    raise ArgumentError, "group_by needs at least one key" if keys.empty?
    CAFrame.__send__(:refuse_repeated_names, keys.grep(String), "group_by")
    cat  = grouping_categorical(keys)
    axis = keys.size == 1 && keys.first.is_a?(String) ? keys.first : "group"
    key  = keys.size == 1 ? key_column(keys.first) : nil
    GroupedFrame.new(self, cat, axis, keys.grep(String), key: key)
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
  # @param name [String] the time column, or the index's axis name.
  # @param unit [String, Symbol, CATime::Resolution] the bin length.
  # @param origin [nil, Time, String, CATime::Element] where bins start.
  # @param label [:left, :right] which end of a bin names it and is closed.
  # @param fill [Boolean] whether bins with no rows are rows of the result.
  # @return [GroupedFrame]
  # @raise [ArgumentError] when the column is not a CATime, or +label:+ is
  #   neither :left nor :right.
  def resample(name, unit, origin: nil, label: :left, fill: false)
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
    cat = CACategorical.from_codes(bins.locate_addr(grid), grid.to_a)
    GroupedFrame.new(self, cat, name, @columns.key?(name) ? [name] : [],
                     index: CAFrame.__send__(:key_labels, time, grid))
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
end

# GroupedFrame — the result of +CAFrame#group_by+ (memo §11.6, §16).
#
# Holds the grouping categorical once (grouping is per-key, computed once
# and shared across every column). Three surfaces:
#   grp["col"]   -> the CArray group iterator (raw exposure)
#   aggregate    -> declarative per-column reductions into a new frame
#   table { |g| }-> cross-column Ruby escape, g is a per-group view-frame
class GroupedFrame
  include CAFrame::ColumnVerbs
  # +key_names+ are the frame columns the grouping was keyed on. They become
  # the result's index, so the reduction shortcuts must not also return them as
  # reduced columns; an external CArray key contributes no name.
  #
  # The result's index is +index:+ when given (one entry per group, in code
  # order); otherwise, for a single +key:+, the key's value at each group's
  # first row, so it keeps the key's data type and Face; otherwise an object
  # array of the labels (a composite key's tuples).
  #
  # The grouping and the index are taken here, so a later change to the key
  # does not rename the groups; the values are read when a reduction is.
  def initialize(frame, cat, axis_name, key_names = [], index: nil, key: nil)
    @frame     = frame
    @cat       = cat
    @axis_name = axis_name
    @key_names = key_names
    @labels    = cat.labels          # group values, in code order
    @index     = index ||
                 (key && CAFrame.__send__(:key_labels, key, key.project(group_perm[group_bounds[0...ngroup]])))
  end

  # Number of groups.
  def ngroup
    @labels.size
  end

  # Group key values (one per group), as an Array.
  def labels
    @labels.dup
  end

  # Raw exposure: the CArray group iterator for one column (memo §11.6).
  def [](name)
    @frame[name].group_by_category(@cat)
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
  def aggregate(spec = nil, keep_rows: false, **named)
    spec = (spec || {}).merge(named)
    cols = {}
    spec.each do |out_name, (in_name, reduction, *args)|
      out = @frame.__send__(:column_name_arg, out_name, "aggregate")
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
  # the UNDEF cells. +keep_rows: true+ gives each row its group's value
  # instead of one row per group, as for +aggregate+.
  #
  # Given column names, they reduce those columns only and return them as
  # +df[...]+ does: one name gives the CArray, several an Array of them.
  #
  #   grp.mean                                   # a frame, one row per group
  #   grp.mean("temp")                           # CArray, one value per group
  #   df["temp"] - grp.mean("temp", keep_rows: true)   # anomaly from the group mean
  #
  # @!method sum(*names, min_count: nil, fill_value: nil, keep_rows: false)
  #   Returns a frame of the per-group sum of every column whose type has a
  #   sum, an N-D one per group along the rows. Other columns are left out.
  #   @return [CAFrame, CArray, Array<CArray>] a frame with one row per
  #     group, indexed by the group labels, or with keep_rows: true the
  #     frame's rows and index; given names, the CArray (one) or the Array of
  #     them (several).
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
    reduce_columns(red, names, keep_rows, min_count: min_count, fill_value: fill_value)
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
    reduce_columns(red, names, keep_rows)
  end

  # Values computed within each group and kept on the frame's rows, in row
  # order: the value some rows back in the same group, a rank among the
  # group's rows, a running statistic. A row in no group is UNDEF. Without
  # names they give a frame of every column whose type has the operation
  # (the key columns left out), on the frame's rows and index; given names,
  # the CArray (one) or the Array of them (several), as +df[...]+ returns
  # columns. An N-D column runs along the rows.
  #
  #   df["dtemp"] = df["temp"] - grp.lag("temp")   # change since the station's previous row
  #   grp.order("temp", descending: true)          # rank within the station
  #   grp.cumsum("rain")                           # running total per station
  #
  # "Previous" is the previous row of the frame: sort the frame first
  # (+sort_by_key("time")+) when its rows are not in time order.
  #
  # @!method lag(*names, n: 1)
  #   Returns each row's value +n+ rows back in its own group, UNDEF where
  #   the group has none, as +CArray#lag+; a negative +n+ looks ahead.
  #   @return [CAFrame, CArray, Array<CArray>]
  # @!method order(*names, descending: false, method: :ordinal, kind: :quick)
  #   Returns each row's rank among its group's rows (int64, 0 the
  #   smallest), as +CArray#order+ ranks them.
  #   @return [CAFrame, CArray, Array<CArray>]
  # @!method cumsum(*names)
  #   Returns the running sum within each group, as +CArray#cumsum+.
  #   @return [CAFrame, CArray, Array<CArray>]
  # @!method cumprod(*names)
  #   Returns the running product within each group.
  #   @return [CAFrame, CArray, Array<CArray>]
  # @!method cummax(*names)
  #   Returns the running maximum within each group.
  #   @return [CAFrame, CArray, Array<CArray>]
  # @!method cummin(*names)
  #   Returns the running minimum within each group.
  #   @return [CAFrame, CArray, Array<CArray>]
  # @!method cumcount(*names)
  #   Returns the running count of present values within each group (int64).
  #   @return [CAFrame, CArray, Array<CArray>]
  def lag (*names, n: 1)
    transform_columns(:lag, names, [n], {})
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
  # back. A fill never reaches across into another group, so a cell with
  # nothing to carry in its group stays masked, and a row whose key is
  # masked (in no group) is left as it is. A constant fills every masked
  # cell, as +CAFrame#fill+ does. Returns self.
  #
  #   df.group_by("station").fill("temp", :ffill)
  #
  # Sort the frame first (+sort_by_key("time")+) when its rows are not in
  # time order.
  #
  # @param name [String] the column.
  # @param method_or_value [Symbol, Object] +:ffill+, +:bfill+, or a constant.
  # @return [GroupedFrame] self
  # @raise [ArgumentError] for +:linear+, which within groups is not
  #   provided, or another Symbol.
  def fill (name, method_or_value)
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
      raise ArgumentError,
            "fill(#{name.inspect}, :linear): an interpolation within each group " \
            "is not provided; use :ffill or :bfill, or interpolate one group at a " \
            "time with CAFrame#fill"
    when Symbol
      raise ArgumentError,
            "fill: unknown method #{method_or_value.inspect} " \
            "(:ffill | :bfill, or a constant fill value)"
    else
      @frame.fill(name, method_or_value)
    end
    self
  end

  # Keep the rows of the groups the block chooses. The block receives the
  # grouped frame and returns a boolean CArray with one value per group,
  # built from the group reductions, as +CAFrame#filter+'s block returns one
  # per row:
  #
  #   grp.filter { |g| g["temp"].count_not_masked >= 20 }   # stations with 20 readings
  #   grp.filter { |g| g.mean("temp") > 15.0 }
  #
  # The rows of a chosen group are kept in the frame's order, as a sub-frame
  # sharing the frame's columns. A group whose value is UNDEF is
  # undetermined, as is a row whose key is masked (it belongs to no group):
  # such rows are dropped, or with +keep_masked: true+ carried with their
  # cells masked, as +CAFrame#filter+ does.
  #
  # @param keep_masked [Boolean] carry the undetermined rows forward masked.
  # @yieldparam grouped [GroupedFrame] self.
  # @yieldreturn [CArray] boolean, one value per group.
  # @return [CAFrame]
  # @raise [ArgumentError] when the block does not return a boolean CArray of
  #   shape [ngroup].
  def filter (keep_masked: false)
    chosen = yield(self)
    unless chosen.is_a?(CArray) && chosen.data_type == :boolean
      raise ArgumentError,
            "filter block must return a boolean CArray (got #{chosen.class})"
    end
    unless chosen.shape == [ngroup]
      raise ArgumentError,
            "filter mask has shape #{chosen.shape.inspect}, " \
            "expected [#{ngroup}] (one value per group)"
    end
    rows = spread_to_rows(chosen)
    @frame.filter(keep_masked: keep_masked) { rows }
  end

  # Returns the grouped rows as a frame: the frame the grouping was made
  # from, its rows, columns and index, as a new frame sharing its columns.
  # Nothing is copied, so a write to a cell reaches the grouped frame's
  # rows; adding or dropping a column changes the new frame only.
  #
  #   def warm_stations (grp)
  #     grp.filter { |g| g.mean("temp") > 15.0 }   # the rows of some groups
  #   end
  #   grp.to_frame                                  # all of its rows
  #
  # @return [CAFrame]
  def to_frame
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
    CArray.float64(1).public_send(op, *args, **keywords)
    out = over_named_columns(op, names, @key_names, args, keywords) do |col|
      group_transform(col, op, args, keywords)
    end
    return out unless names.empty?
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

  # A key column is the index here, not a result column.  Named columns
  # come back as df[...] returns them, each on the frame's rows with
  # +keep_rows+.
  private def reduce_columns(reduction, names, keep_rows, **keywords)
    keywords = keywords.compact
    out = over_named_columns(reduction, names, @key_names) do |col|
      col = group_reduce(col, reduction, **keywords)
      keep_rows && !names.empty? ? spread_to_rows(col) : col
    end
    return out unless names.empty?
    result_frame(out, keep_rows)
  end

  # One row per group, indexed by the labels; or, with +keep_rows+, the
  # frame's rows, each holding its group's result.
  private def result_frame(cols, keep_rows)
    return CAFrame.new(cols, axis_name: @axis_name, index: label_index) unless keep_rows
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

  private def per_group_column(in_name, proc)
    results = []
    each_group_slice(in_name) { |slice| results << proc.call(slice) }
    column_of_values(results)
  end

  # A column of the Ruby values the groups gave, typed as from_records types
  # a record's values: Integers int64, numbers float64, arrays of one shape
  # an N-D column, anything else object. UNDEF and nil are missing.
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

  private def group_address(k)
    group_perm[group_bounds[k]...group_bounds[k + 1]]
  end

  private def group_codes
    @cat.codes
  end

  private def group_perm
    @group_perm ||= @cat.sort_addr
  end

  private def group_bounds
    @group_bounds ||= CArray.segment_offsets(lengths: @cat.category_sizes)
  end
end
