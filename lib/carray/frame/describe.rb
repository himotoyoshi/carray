# CAFrame#describe: one row of statistics per column, for a first look at a
# table that has just been read.

class CAFrame
  # Summarize the columns, one row each, as a new frame indexed by column
  # name:
  #
  #   puts df.describe.to_table
  #
  #   column   type     count  masked  unique  min         max         mean        stddev
  #   -------  -------  -----  ------  ------  ----------  ----------  ----------  --------
  #   station  object       3       0       2  _           _           _           _
  #   temp     float64      2       1       2  19.0        22.1        20.55       2.192031
  #   time     CATime       3       0       3  2024-01-01  2024-01-03  2024-01-02  1D
  #
  # +type+ is the data type, or the Face's class for a Face column, with the
  # trailing shape of an N-D column in brackets (+float64[3]+). +count+ and
  # +masked+ count cells, so an N-D column counts every cell of every row;
  # +unique+ is the number of distinct values among the present cells.
  #
  # The other statistics apply only where the column's kind gives them a
  # meaning, and are UNDEF elsewhere:
  #
  #   real numbers, boolean   min  max  mean  stddev
  #   complex                           mean  stddev   (no order, no unique)
  #   CATime, CATimedelta     min  max  mean  stddev   (as times / durations)
  #   anything else (text, categorical, records ...)   unique only
  #
  # A boolean column counts true as 1, so its mean is the share of trues. A
  # column with no present cell has UNDEF statistics. The index is not a
  # column and is not summarized.
  #
  # @param names [Array<String>] the columns to summarize; default all.
  # @return [CAFrame] a new frame with one row per column.
  def describe(*names)
    names = names.empty? ? variable_names : names.map(&:to_s)
    rows = names.map { |name| describe_column(self[name]) }
    stats = %w[type count masked unique min max mean stddev]
    cols = stats.to_h do |stat|
      values = rows.map { |row| row[stat] }
      column =
        case stat
        when "count", "masked", "unique" then CArray.int64(values.size)
        else CArray.object(values.size)
        end
      column[] = UNDEF
      values.each_with_index { |v, i| column[i] = v unless UNDEF.equal?(v) }
      [stat, column]
    end
    CAFrame.new(cols, axis_name: "column", index: CA_OBJECT(names))
  end

  DESCRIBE_TIME_FACES = %w[CATime CATimedelta].freeze
  private_constant :DESCRIBE_TIME_FACES

  private def describe_column(col)
    kind =
      if col.face?
        DESCRIBE_TIME_FACES.include?(col.class.name) ? :ordered : :other
      elsif col.complex?
        :complex
      elsif col.numeric? || col.boolean?
        :ordered
      else
        :other
      end
    type = col.face? ? col.class.name : col.data_type_name
    type += col.shape[1..].inspect if col.ndim > 1
    row = { "type" => type,
            "count" => col.count_not_masked, "masked" => col.count_masked,
            "unique" => kind == :complex ? UNDEF : col.nunique }
    ordered = kind == :ordered
    row["min"]    = ordered ? col.min : UNDEF
    row["max"]    = ordered ? col.max : UNDEF
    row["mean"]   = kind == :other ? UNDEF : col.mean
    row["stddev"] = kind == :other ? UNDEF : col.stddev
    row
  end
end
