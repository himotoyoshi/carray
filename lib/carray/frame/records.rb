# CAFrame record (row-oriented) input (memo §11.2, §11.5).
#
# from_records takes an Array of row Hashes -- the shape JSON.parse yields for
# a JSON array of objects -- and arranges it into columns. Unlike from_csv,
# the cell values are already typed Ruby objects (Float / Integer / DateTime /
# String), so a homogeneous column is built at its native leaf type rather than
# left as strings ("arrange by the value's own type", not string inference --
# §4.2 stays intact: no date-like string is parsed, mixed columns stay object).
#
# An Array-valued cell that is the same length across every record becomes an
# N-D column (§11.5): { "temp" => [min, mean, max] } over N records is one
# (N, 3) column. Ragged or non-numeric arrays fall back to an object column.
#
# Missing keys and explicit nils become UNDEF for numeric columns (mask, not a
# float promotion): an int column with a hole stays int + UNDEF.

class CAFrame
  # Build a frame from an Array of row Hashes. Column set is the union of keys
  # in first-appearance order; keys are stringified. +types:+ takes
  # anything +cast+ takes as a map (a name => type map, :infer, or a map with
  # +default:+) and casts the built frame with it, with +on_error:+ as for
  # +cast+.
  def self.from_records(records, types: nil, on_error: :mask)
    unless records.is_a?(Array) && records.all? { |r| r.is_a?(Hash) }
      raise ArgumentError, "from_records expects an Array of Hashes"
    end
    return new if records.empty?

    keys = record_key_union(records)
    n = records.size
    cols = {}
    keys.each do |key|
      values = records.map { |r| r[key] }
      cols[key.to_s] = build_record_column(values, n)
    end

    frame = new(cols)
    frame.cast(types, on_error: on_error, option_name: :types) unless types.nil?
    frame
  end

  # Union of record keys in first-appearance order (original key objects, so a
  # String- or Symbol-keyed set both work; the column name stringifies later).
  def self.record_key_union(records)
    seen = {}
    keys = []
    records.each do |r|
      r.each_key do |k|
        unless seen.key?(k)
          seen[k] = true
          keys << k
        end
      end
    end
    keys
  end
  private_class_method :record_key_union

  # Arrange one column's values (Ruby objects, nil for missing) into a CArray.
  # All-Array cells of equal length -> N-D native column; numeric scalars ->
  # native scalar column (nil -> UNDEF); anything else -> object column.
  def self.build_record_column(values, n)
    present = values.reject(&:nil?)
    return mask_missing(CArray.object(n) { values }) if present.empty?

    if present.all? { |v| v.is_a?(Array) || v.is_a?(CArray) }
      build_nd_column(values, present, n)
    else
      type = numeric_leaf_type(present)
      col = CArray.object(n) { values }
      type ? col.to_type(type) : mask_missing(col)
    end
  end
  private_class_method :build_record_column

  # A missing cell is UNDEF, not a Ruby nil sitting in a cell.  to_records
  # writes a masked cell as nil, so nil on the way back in is the only
  # spelling a missing cell has; to_type does this conversion for a numeric
  # column, and an object column would otherwise keep the nil as a value --
  # a row with no label coming back as a row labelled nil.  The CSV reader
  # takes the same position (see build_frame in io.rb).
  def self.mask_missing(col)
    col[:eq, nil] = UNDEF
    col
  end
  private_class_method :mask_missing

  # Stack array cells of one shape into an (N, *shape) column via an object
  # fill + to_type (nil rows -> UNDEF, int/float by leaf); a cell may itself
  # be nested, an (N, L, M) column from [[..], [..]] cells.  Cells of
  # different shapes, nesting that is not rectangular, or non-numeric leaves
  # fall back to a 1-D object column of the raw cells.
  def self.build_nd_column(values, present, n)
    shapes = present.map { |v| v.is_a?(CArray) ? v.shape : nested_shape(v) }
    shape = shapes.first
    unless shape && shapes.all? { |x| x == shape }
      return mask_missing(CArray.object(n) { values })
    end

    blank = shape.reverse.inject(nil) { |cell, d| Array.new(d) { cell } }
    nested = values.map { |v| v.nil? ? blank : (v.is_a?(CArray) ? v.to_a : v) }
    leaves = nested.flatten.compact
    type = leaves.empty? ? nil : numeric_leaf_type(leaves)
    table = CArray.object(n, *shape) { nested }
    type ? table.to_type(type) : mask_missing(table)
  end
  private_class_method :build_nd_column

  # The shape of a rectangular nested Array, or nil when it is not
  # rectangular.  A leaf (anything but an Array) has shape [].
  def self.nested_shape(v)
    return [] unless v.is_a?(Array)
    inner = v.map { |e| nested_shape(e) }
    return [v.size] if v.empty?
    return nil unless inner.first && inner.all? { |x| x == inner.first }
    [v.size, *inner.first]
  end
  private_class_method :nested_shape

  # :int64 if every value is an Integer, :float64 for Integers and Floats,
  # :cmplx128 when Complex values join them, otherwise nil (keep object).
  # Other Numerics (Rational, BigDecimal) stay object: a float column would
  # round them, and a Complex one has room for them only as floats too.
  def self.numeric_leaf_type(values)
    if values.all? { |v| v.is_a?(Integer) }
      :int64
    elsif values.all? { |v| v.is_a?(Integer) || v.is_a?(Float) }
      :float64
    elsif values.all? { |v| v.is_a?(Integer) || v.is_a?(Float) || v.is_a?(Complex) }
      :cmplx128
    end
  end
  private_class_method :numeric_leaf_type
end
