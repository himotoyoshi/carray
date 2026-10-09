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
    cat  = grouping_categorical(keys)
    axis = keys.size == 1 && keys.first.is_a?(String) ? keys.first : "group"
    key  = keys.size == 1 ? key_column(keys.first) : nil
    GroupedFrame.new(self, cat, axis, keys.grep(String), key: key)
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
    name = name.to_s
    time = column_or_index(name)
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
    grid = fill && bins.count_not_masked > 0 ? resample_grid(bins, unit) : bins.unique(sort: true)
    cat = CACategorical.from_codes(bins.locate_addr(grid), grid.to_a)
    GroupedFrame.new(self, cat, name, @columns.key?(name) ? [name] : [], index: grid)
  end

  # Every bin from the first occupied one to the last. A fixed-length bin
  # steps from the first bin, so an origin's phase is kept; a month or a year
  # cannot be stepped on a finer grid and is laid on its own unit, where
  # bins start on the calendar boundary anyway.
  private def resample_grid(bins, unit)
    if %i[Y M].include?(CATime::Resolution.parse(unit).base)
      CArray.time_range(bins.min, bins.max, unit: unit)
    else
      CArray.time_range(bins.min, bins.max, unit: bins.unit, step: unit)
    end
  end

  # Number of rows currently selected — used by group per-group view-frames
  # and elsewhere; already provided by the core (attr_reader :nrow).

  private def grouping_categorical(keys)
    cols = keys.map { |k| key_column(k) }
    if cols.size == 1
      cols.first.categorize
    else
      # Composite key: one object cell per row holding the tuple of key
      # values, categorized by content (the codes are composed from the
      # per-column keys).
      n = nrow
      key = CArray.object(n) { |i| cols.map { |c| c[i] } }
      # One undetermined component makes the whole tuple undetermined, the same
      # answer a single masked key cell gets. Left as a value, the UNDEF inside
      # the tuple would intern as an ordinary distinct key and the row would
      # form a group of its own.
      undetermined = CArray.boolean(n) { |i| key[i].any? { |v| UNDEF.equal?(v) } }
      key[undetermined] = UNDEF if undetermined.any
      key.categorize
    end
  end

  private def key_column(key)
    case key
    when String
      self[key]
    when CArray
      unless key.shape[0] == nrow
        raise ArgumentError,
              "external group key length #{key.shape[0]} != nrow #{nrow}"
      end
      key
    else
      raise ArgumentError, "group key must be a column name or CArray (got #{key.class})"
    end
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
    @index     = index || (key && key.project(group_perm[group_bounds[0...ngroup]]))
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
  # with the group's column slice).
  def aggregate(spec)
    cols = {}
    spec.each do |out_name, (in_name, reduction)|
      out = out_name.to_s
      cols[out] =
        case reduction
        when Symbol
          self[in_name].public_send(reduction)
        when Proc
          per_group_column(in_name, reduction)
        else
          raise ArgumentError,
                "reduction must be a Symbol or Proc (got #{reduction.class})"
        end
    end
    CAFrame.new(cols, axis_name: @axis_name, index: label_index)
  end

  # Cross-column Ruby escape (memo §11.6). The block receives a per-group
  # view-frame and returns a Hash of output-name => value; the values are
  # collected column-wise across groups into a new frame.
  def table
    collected = {}
    order = nil
    each_group_frame do |g|
      out = yield(g)
      unless out.is_a?(Hash)
        raise ArgumentError, "table block must return a Hash (got #{out.class})"
      end
      order ||= out.keys.map(&:to_s)
      out.each { |k, v| (collected[k.to_s] ||= []) << v }
    end
    cols = {}
    (order || []).each do |name|
      vals = collected[name]
      cols[name] = CArray.object(vals.size) { |i| vals[i] }
    end
    CAFrame.new(cols, axis_name: @axis_name, index: label_index)
  end

  # Convenience reductions over every numeric scalar column (memo §6-4
  # "grp.mean"). Non-numeric / N-D columns are skipped.
  #
  # @!method sum
  #   Returns a frame of the per-group sum of every numeric one-dimensional
  #   column. Non-numeric and multi-dimensional columns are left out.
  #   @return [CAFrame] one row per group, indexed by the group labels.
  # @!method mean
  #   Returns a frame of the per-group arithmetic mean of every numeric
  #   one-dimensional column, as {#sum} does.
  #   @return [CAFrame] one row per group.
  # @!method min
  #   Returns a frame of the per-group minimum of every numeric
  #   one-dimensional column, as {#sum} does.
  #   @return [CAFrame] one row per group.
  # @!method max
  #   Returns a frame of the per-group maximum of every numeric
  #   one-dimensional column, as {#sum} does.
  #   @return [CAFrame] one row per group.
  [:sum, :mean, :min, :max].each do |red|
    define_method(red) { reduce_numeric(red) }
  end

  # @return [String]
  def inspect
    "#<GroupedFrame ngroup=#{ngroup} by=#{@axis_name.inspect}>"
  end

  # Each result gets its own index.
  private def label_index
    return @index.copy if @index
    CArray.object(@labels.size) { |i| @labels[i] }
  end

  NON_NUMERIC = [:object, :boolean, :fixlen].freeze
  private_constant :NON_NUMERIC

  private def reduce_numeric(reduction)
    cols = {}
    @frame.variable_names.each do |name|
      # A key column is the index here, not a result column. Filtering it out
      # by name rather than by data type is what makes a numeric key behave
      # like a string one: NON_NUMERIC is about which columns a reduction can
      # apply to, which happened to cover string keys and nothing else.
      next if @key_names.include?(name)
      col = @frame[name]
      next unless col.ndim == 1 && !NON_NUMERIC.include?(col.data_type)
      cols[name] = col.group_by_category(@cat).public_send(reduction)
    end
    CAFrame.new(cols, axis_name: @axis_name, index: label_index)
  end

  private def per_group_column(in_name, proc)
    results = []
    each_group_slice(in_name) { |slice| results << proc.call(slice) }
    CArray.object(results.size) { |i| results[i] }
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

  private def group_perm
    @group_perm ||= @cat.sort_addr
  end

  private def group_bounds
    @group_bounds ||= CArray.segment_offsets(lengths: @cat.category_sizes)
  end
end
