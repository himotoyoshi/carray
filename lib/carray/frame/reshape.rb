# CAFrame long <-> wide reshaping: +pivot+ and +melt+.
#
# Both are compositions of landed addressing primitives, like join:
#
#   pivot  the distinct keys come from +unique(sort: true)+, each row's
#          position on them from +locate_addr+, and each output column is a
#          +project+ of the value column through an inverse address (a cell
#          no row reached stays UNDEF).  The result is a new frame.
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
  # frame's index (its row axis name).  The value column may have trailing
  # dimensions, which each output column keeps.
  #
  # Without +aggregate:+, two rows with the same pair raise: pivot places
  # values, it does not combine them.  With +aggregate:+ (a reduction name
  # such as +:mean+, +:sum+, +:max+ or +:count+) every pair holds that
  # reduction over the rows that carry it, computed by +group_by_category+;
  # masked values are left out of it as in any reduction, so a pair whose
  # values are all masked is UNDEF.  A pair no row carries stays UNDEF
  # whatever the reduction, +:count+ included.  +aggregate:+ needs a
  # one-dimensional value column.
  #
  #   long.pivot(index: "day", columns: "station", values: "temp", aggregate: :mean)
  #
  # @param index [String] key whose values become the rows.
  # @param columns [String] key whose values become the columns.
  # @param values [String] column whose cells fill the result.
  # @param aggregate [Symbol, nil] reduction applied to the rows of each pair.
  # @return [CAFrame] a new frame, not a view of +self+.
  # @raise [ArgumentError] on a repeated pair without +aggregate:+, on an
  #   unknown reduction or a multi-dimensional value column with it, or when
  #   two column labels share a name.
  def pivot(index:, columns:, values:, aggregate: nil)
    index   = index.to_s
    columns = columns.to_s
    rkey = pivot_key(index)
    ckey = pivot_key(columns)
    val  = self[values.to_s]

    rlab = rkey.unique(sort: true)
    clab = ckey.unique(sort: true)
    nr = rlab.elements
    nc = clab.elements
    names = Array.new(nc) { |j| clab[j].to_s }
    if names.uniq.size != nc
      raise ArgumentError,
            "pivot: column labels of #{columns.inspect} collide as names: #{names.inspect}"
    end

    r = rkey.locate_addr(rlab)
    c = ckey.locate_addr(clab)
    placed = r.is_not_masked & c.is_not_masked
    cell = r[placed] * nc + c[placed]
    source = CArray.int64(nr * nc)
    source[] = UNDEF
    if aggregate
      pairs = cell.categorize(sort_labels: true)
      val = pivot_aggregate(val, placed, pairs, aggregate)
      source[CA_INT64(pairs.labels)] = CArray.int64(val.elements).seq
    else
      if cell.nunique != cell.elements
        first = cell.to_a.tally.find { |_, count| count > 1 }.first
        raise ArgumentError,
              "pivot: more than one row for #{index}=#{rlab[first / nc].inspect}, " \
              "#{columns}=#{clab[first % nc].inspect}; pass aggregate: to combine them"
      end
      source[cell] = CArray.int64(nrow).seq[placed]
    end
    source = source.reshape(nr, nc)

    cols = {}
    names.each_with_index do |name, j|
      cols[name] = project_rows(val, source[nil, j])
    end
    CAFrame.new(cols, axis_name: index, index: rlab)
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
    vars = (value_columns || variable_names - ids).map(&:to_s)
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

  # One reduced value per occupied pair, in the order of +pairs.labels+.
  private def pivot_aggregate(val, placed, pairs, reduction)
    unless reduction.is_a?(Symbol)
      raise ArgumentError, "pivot: aggregate: takes a reduction name (got #{reduction.inspect})"
    end
    unless val.ndim == 1
      raise ArgumentError,
            "pivot: aggregate: needs a one-dimensional value column (got shape #{val.shape.inspect})"
    end
    groups = val[placed].group_by_category(pairs)
    unless groups.respond_to?(reduction)
      raise ArgumentError, "pivot: unknown reduction #{reduction.inspect} for aggregate:"
    end
    groups.public_send(reduction)
  end

  # A pivot key is a column, or the index when +name+ is the row axis name.
  private def pivot_key(name)
    return @index if @index && !@columns.key?(name) && @axis_name == name
    self[name]
  end
end
