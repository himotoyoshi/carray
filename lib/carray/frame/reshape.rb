# CAFrame long <-> wide reshaping: +pivot+ and +melt+.
#
# Both are compositions of landed addressing primitives, like join:
#
#   pivot  the distinct keys come from +unique(sort: true)+, each row's
#          position on them from +locate_addr+, and each output column is a
#          +project+ of the value column through an inverse address (a cell
#          no row reached stays UNDEF).  The result is a new frame;
#          +pivot_grid+ gathers the same cells into one 2-D CArray.
#   melt   the value columns are welded with +CArray.meld+ and each id column
#          is welded with itself, so the result is a view frame: a write to
#          its value column lands in the wide frame it came from.

class CAFrame
  # Spread a long frame into a wide one.  Each distinct value of the +index+
  # key becomes a row, each distinct value of the +columns+ key becomes a
  # column, and the cell at their crossing holds +values+ from the row that
  # carried that pair.
  #
  #   long = CAFrame.new("time" => t, "station" => s, "temp" => x)
  #   wide = long.pivot(index: "time", columns: "station", values: "temp")
  #   wide["tokyo"]       # temperature at tokyo, one cell per time
  #
  # Both keys are sorted ascending.  The +index+ key becomes the result's
  # index and names its row axis; the +columns+ key values become column
  # names through +to_s+.  A pair no row carries is UNDEF, and so is a pair
  # whose value cell is masked.  A row whose +index+ or +columns+ key is
  # masked belongs to no cell and is left out.
  #
  # +index:+ and +columns:+ are column names; +index:+ may also name the
  # frame's index (its row axis name).  A value column may have trailing
  # dimensions, which each output column keeps.
  #
  # +values:+ may be an Array of column names.  Every one of them is spread
  # over the same rows and columns, and the output columns are named
  # +"<value>_<label>"+, all of the first value's columns before the next's:
  #
  #   long.pivot(index: "time", columns: "station", values: ["temp", "rh"])
  #   # temp_osaka, temp_tokyo, rh_osaka, rh_tokyo
  #
  # Without +aggregate:+, two rows with the same pair raise: pivot places
  # values, it does not combine them.  With +aggregate:+ (a reduction name
  # such as +:mean+, +:sum+, +:max+ or +:count+) every pair holds that
  # reduction over the rows that carry it, computed by +group_by_category+;
  # masked values are left out of it as in any reduction, so a pair whose
  # values are all masked is UNDEF.  A pair no row carries stays UNDEF
  # whatever the reduction, +:count+ included.  +aggregate:+ needs
  # one-dimensional value columns.
  #
  #   long.pivot(index: "day", columns: "station", values: "temp", aggregate: :mean)
  #
  # For the same cells as one CArray rather than named columns, see
  # {#pivot_grid}.
  #
  # @param index [String] key whose values become the rows.
  # @param columns [String] key whose values become the columns.
  # @param values [String, Array<String>] column(s) whose cells fill the
  #   result.
  # @param aggregate [Symbol, nil] reduction applied to the rows of each pair.
  # @return [CAFrame] a new frame, not a view of +self+.
  # @raise [ArgumentError] on a repeated pair without +aggregate:+, on an
  #   unknown reduction or a multi-dimensional value column with it, or when
  #   two output columns would share a name.
  def pivot(index:, columns:, values:, aggregate: nil)
    plan = pivot_plan(index.to_s, columns.to_s, aggregate)
    labels = Array.new(plan[:nc]) { |j| plan[:clab][j].to_s }
    value_names = values.is_a?(Array) ? values.map(&:to_s) : nil
    names =
      if value_names
        value_names.flat_map { |v| labels.map { |l| "#{v}_#{l}" } }
      else
        labels
      end
    dup = names.tally.select { |_, count| count > 1 }.keys
    unless dup.empty?
      raise ArgumentError, "pivot: output columns would share the names #{dup.inspect}"
    end

    source = plan[:source].reshape(plan[:nr], plan[:nc])
    cols = {}
    (value_names || [values.to_s]).each_with_index do |value, k|
      val = pivot_value(plan, value)
      plan[:nc].times do |j|
        cols[names[k * plan[:nc] + j]] = project_rows(val, source[nil, j])
      end
    end
    CAFrame.new(cols, axis_name: plan[:index], index: plan[:rlab])
  end

  # The cells of {#pivot} as one CArray: rows are the sorted +index+ key,
  # columns the sorted +columns+ key, and any trailing dimensions of the
  # value column follow.  Returns the grid together with the two key arrays
  # that label its axes, so it destructures:
  #
  #   temp, times, stations = long.pivot_grid(index: "time", columns: "station",
  #                                           values: "temp")
  #   temp.shape          # => [times.elements, stations.elements]
  #   temp.mean(axis: 0)  # mean per station
  #
  # Missing pairs, masked keys, repeats and +aggregate:+ behave as in
  # {#pivot}.  The grid keeps the value column's data type, Face included.
  #
  # @param index [String] key whose values label axis 0.
  # @param columns [String] key whose values label axis 1.
  # @param values [String] column whose cells fill the grid.
  # @param aggregate [Symbol, nil] reduction applied to the rows of each pair.
  # @return [Array(CArray, CArray, CArray)] the grid, the axis-0 key values
  #   and the axis-1 key values; the grid is new, not a view of +self+.
  # @raise [ArgumentError] as {#pivot}.
  def pivot_grid(index:, columns:, values:, aggregate: nil)
    plan = pivot_plan(index.to_s, columns.to_s, aggregate)
    val  = pivot_value(plan, values.to_s)
    grid = project_rows(val, plan[:source]).reshape(plan[:nr], plan[:nc], *val.shape[1..])
    [grid, plan[:rlab], plan[:clab]]
  end

  # Everything pivot needs that does not depend on the value column: the
  # sorted keys and, for each of the nr * nc cells, the address of the row
  # (or with +aggregate:+, of the reduced pair) that fills it.
  private def pivot_plan(index, columns, aggregate)
    rkey = column_or_index(index)
    ckey = column_or_index(columns)
    rlab = rkey.unique(sort: true)
    clab = ckey.unique(sort: true)
    nr = rlab.elements
    nc = clab.elements

    r = rkey.locate_addr(rlab)
    c = ckey.locate_addr(clab)
    placed = r.is_not_masked & c.is_not_masked
    cell = r[placed] * nc + c[placed]
    source = CArray.int64(nr * nc)
    source[] = UNDEF
    plan = { index: index, rlab: rlab, clab: clab, nr: nr, nc: nc,
             placed: placed, aggregate: aggregate, source: source }
    if aggregate
      unless aggregate.is_a?(Symbol)
        raise ArgumentError, "pivot: aggregate: takes a reduction name (got #{aggregate.inspect})"
      end
      pairs = cell.categorize(sort_labels: true)
      plan[:pairs] = pairs
      source[CA_INT64(pairs.labels)] = CArray.int64(pairs.labels.size).seq
    else
      if cell.nunique != cell.elements
        first = cell.to_a.tally.find { |_, count| count > 1 }.first
        raise ArgumentError,
              "pivot: more than one row for #{index}=#{rlab[first / nc].inspect}, " \
              "#{columns}=#{clab[first % nc].inspect}; pass aggregate: to combine them"
      end
      source[cell] = CArray.int64(nrow).seq[placed]
    end
    plan
  end

  # The column the plan's addresses point into: the value column itself, or
  # with +aggregate:+ one reduced value per occupied pair.
  private def pivot_value(plan, name)
    val = self[name]
    return val unless plan[:aggregate]
    unless val.ndim == 1
      raise ArgumentError,
            "pivot: aggregate: needs one-dimensional value columns " \
            "(#{name.inspect} has shape #{val.shape.inspect})"
    end
    groups = val[plan[:placed]].group_by_category(plan[:pairs])
    unless groups.respond_to?(plan[:aggregate])
      raise ArgumentError, "pivot: unknown reduction #{plan[:aggregate].inspect} for aggregate:"
    end
    groups.public_send(plan[:aggregate])
  end

  # Gather a wide frame into a long one.  The +value_columns+ are stacked one
  # after another into a single +value_name+ column, a +var_name+ column says
  # which of them each row came from, and every +id+ column repeats once per
  # value column.
  #
  #   wide.melt(id: "time")     # time / variable / value
  #
  # With no +value_columns+, every column that is not an id is melted.  When
  # the frame has an index it is carried as an id column named after the row
  # axis.  Masked cells stay masked.
  #
  # The result is a view frame: the value column is +CArray.meld+ of the
  # melted columns and each id column is +CArray.meld+ of itself, so a write
  # to the result lands in +self+.  The value columns must therefore share
  # one data type and one trailing shape; cast first when they do not.
  #
  # @param id [String, Array<String>] columns repeated alongside each value.
  # @param value_columns [Array<String>, nil] columns to stack; default all
  #   non-id columns.
  # @param var_name [String] name of the column holding the source names.
  # @param value_name [String] name of the stacked value column.
  # @return [CAFrame] a view frame of +nrow * value_columns.size+ rows.
  # @raise [ArgumentError] when there is nothing to melt, or the value
  #   columns differ in data type.
  def melt(id: [], value_columns: nil, var_name: "variable", value_name: "value")
    ids = Array(id).map(&:to_s)
    ids.each { |name| self[name] }
    vars = (value_columns || column_names - ids).map(&:to_s)
    raise ArgumentError, "melt: no columns to melt" if vars.empty?
    overlap = vars & ids
    unless overlap.empty?
      raise ArgumentError, "melt: #{overlap.inspect} named both as id and value column"
    end
    pieces = vars.map { |name| self[name] }
    types = pieces.map(&:data_type).uniq
    unless types.size == 1
      raise ArgumentError,
            "melt: value columns differ in data type (#{vars.zip(pieces.map(&:data_type)).to_h}); " \
            "cast them to one type first"
    end

    k = vars.size
    out = {}
    out[@axis_name] = CArray.meld(Array.new(k, @index)) if @index
    ids.each { |name| out[name] = CArray.meld(Array.new(k, self[name])) }
    [var_name, value_name].each do |name|
      if out.key?(name)
        raise ArgumentError, "melt: #{name.inspect} is already an id column"
      end
    end
    n = nrow
    out[var_name]   = CArray.object(n * k) { |i| vars[i / n] }
    out[value_name] = CArray.meld(pieces)
    CAFrame.new(out)
  end

  # Stack each group's rows into one row: the rows sharing a value of +by+
  # become one row, and every other column becomes an N-D column whose new
  # axis runs over the group's rows, in the order they are in the frame.  A
  # long table of one observation per row -- a station's readings at several
  # levels -- becomes one row per station:
  #
  #   long.stack_rows(by: "station")
  #   # station  level             temp
  #   # tokyo    [1000, 850, 500]  [15.0, 5.0, -20.0]
  #
  # The key becomes the index, as in +group_by+.  A column that tells the rows
  # apart (+level+ here) is stacked like any other, so what position k means
  # stays in the frame as a column of its own; the new axis carries no label.
  # Sort first (+sort_by+) when the rows are to be stacked in another order.
  #
  # Without +on:+ the rows are stacked by position, so every group has to
  # have the same number of rows: filling a short group with UNDEF at its end
  # would put its values at the wrong positions (a station missing one level
  # would have the next level's value in its place).  With +on:+ a column
  # says which rows go together: position k is the k-th value of that column
  # in the order it first appears in the frame, a group without a row for it
  # has UNDEF there, as +pivot+ leaves a missing cell, and a group with two
  # rows for it is refused.  The +on:+ column is stacked too, the same values
  # in every row.  A row whose key or +on:+ value is masked belongs nowhere
  # and is refused.  The frame's own index, if it has one, is stacked as a
  # column named after the row axis.  +unstack_rows+ is the inverse.
  #
  # Without +on:+ the result is a view, and writes reach this frame.  With
  # +on:+ it is a new frame, since the missing cells are new.
  #
  #   long.stack_rows(by: "station", on: "level")
  #
  # @param by [String, CArray, Array] the keys, as for +group_by+: column
  #   names, or a CArray of one value per row (a day computed from a time
  #   column, say), or several of them.
  # @param on [String, nil] the column whose values line the rows up.
  # @return [CAFrame] one row per group, indexed by the group labels.
  def stack_rows(by:, on: nil)
    keys = (by.is_a?(Array) ? by : [by]).map { |k| k.is_a?(Symbol) ? k.to_s : k }
    raise ArgumentError, "stack_rows: by: names no key" if keys.empty?
    frame = @index ? CAFrame.new({ @axis_name => @index }.merge(@columns)) : self
    return stack_rows_on(frame, keys, on.to_s) if on
    grouped = frame.group_by(*keys)
    perm    = grouped.__send__(:group_perm)
    bounds  = grouped.__send__(:group_bounds).to_a
    sizes   = bounds.each_cons(2).map { |a, b| b - a }
    stacked = sizes.sum
    if stacked != frame.nrow
      raise ArgumentError,
            "stack_rows: #{frame.nrow - stacked} rows have no value of the key; " \
            "every row has to belong to a group"
    end
    unless sizes.uniq.size <= 1
      raise ArgumentError,
            "stack_rows: the groups have #{sizes.uniq.sort.join(', ')} rows; " \
            "stacked rows need the same number in every group"
    end
    count = sizes.first || 0
    perm  = stacked.zero? ? CArray.int64(0) : perm[0...stacked]
    cols = {}
    frame.columns.zip(frame.column_names).each do |col, name|
      next if keys.include?(name)
      rows = col[perm, *([nil] * (col.ndim - 1))]
      cols[name] = rows.reshape(sizes.size, count, *col.shape[1..])
    end
    axis = keys.size == 1 && keys.first.is_a?(String) ? keys.first : "group"
    CAFrame.new(cols, axis_name: axis, index: grouped.__send__(:label_index))
  end

  private def stack_rows_on(frame, keys, on)
    if keys.include?(on)
      raise ArgumentError, "stack_rows: #{on.inspect} is a key; on: names another column"
    end
    place = frame[on]
    unless place.ndim == 1
      raise ArgumentError, "stack_rows: on: #{on.inspect} has shape #{place.shape.inspect}, not one value per row"
    end
    grouped = frame.group_by(*keys)
    perm    = grouped.__send__(:group_perm)
    bounds  = grouped.__send__(:group_bounds).to_a
    groups  = bounds.size - 1
    if bounds.last != frame.nrow
      raise ArgumentError,
            "stack_rows: #{frame.nrow - bounds.last} rows have no value of the key; " \
            "every row has to belong to a group"
    end
    if place.has_mask? && place.count_masked > 0
      raise ArgumentError,
            "stack_rows: #{place.count_masked} rows have no value of #{on.inspect}; " \
            "every row has to have a place"
    end
    positions = place.categorize                       # labels in order of first appearance
    count     = positions.labels.size
    group_of  = CArray.int64(frame.nrow)
    groups.times { |g| group_of[perm[bounds[g]...bounds[g + 1]]] = g }
    slot = group_of * count + positions.codes.int64
    rows = CArray.int64(groups * count)
    rows[] = UNDEF
    seen = CArray.int64(groups * count)
    seen.scatter_add!(slot, 1) if frame.nrow > 0
    if frame.nrow > 0 && seen.max > 1
      at = seen.gt(1).where[0]
      raise ArgumentError,
            "stack_rows: more than one row for #{grouped.labels[at / count].inspect}, " \
            "#{on}=#{positions.labels[at % count].inspect}"
    end
    rows[slot] = CArray.int64(frame.nrow).seq if frame.nrow > 0
    first = CArray.int64(count)
    count.times { |k| first[k] = positions.codes.eq(k).where[0] }
    cols = {}
    frame.column_names.each do |name|
      next if keys.include?(name)
      col  = frame[name]
      src  = name == on ? (CArray.int64(groups * count).seq % count).then { |k| first[k] } : rows
      cols[name] = gather_rows(col, src).reshape(groups, count, *col.shape[1..])
    end
    axis = keys.size == 1 && keys.first.is_a?(String) ? keys.first : "group"
    CAFrame.new(cols, axis_name: axis, index: grouped.__send__(:label_index))
  end

  # The rows +rows+ names of +col+, a masked entry giving a masked row.
  private def gather_rows(col, rows)
    inner = col.shape[1..].inject(1, :*)
    return col.project(rows) if inner == 1
    addr = (rows[nil, :_] * inner + CArray.int64(inner).seq[:_, nil]).reshape(rows.elements * inner)
    col.project(addr)
  end

  # Unstack the rows +stack_rows+ stacked: every N-D column is spread back
  # into rows along its first trailing axis, and every other column, and the
  # index, repeats once per position.  The N-D columns have to agree on the
  # length of that axis.  The index stays the index; +reset_index+ turns it
  # back into a column.
  #
  # @return [CAFrame] a frame of +nrow * length+ rows.
  def unstack_rows
    stacked = @columns.select { |_, c| c.ndim >= 2 }
    if stacked.empty?
      raise ArgumentError, "unstack_rows: the frame has no N-D column to unstack"
    end
    lengths = stacked.transform_values { |c| c.shape[1] }
    unless lengths.values.uniq.size == 1
      raise ArgumentError,
            "unstack_rows: the N-D columns differ in length along their first axis #{lengths}"
    end
    count  = lengths.values.first
    repeat = CArray.int64(nrow * count).seq / count
    cols = @columns.to_h do |name, col|
      if col.ndim >= 2
        [name, col.reshape(nrow * count, *col.shape[2..])]
      else
        [name, col[repeat]]
      end
    end
    CAFrame.new(cols, axis_name: @axis_name, index: @index && @index[repeat])
  end

  # A column, or the index when +name+ is the row axis name (pivot and resample
  # keys may be either).
  private def column_or_index(name)
    return @index if @index && !@columns.key?(name) && @axis_name == name
    self[name]
  end
end
