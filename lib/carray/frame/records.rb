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
  # in first-appearance order; keys are stringified. +types:+ casts named
  # columns afterward (same map / array-key forms as +cast+).
  def self.from_records(records, types: nil)
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
    frame.cast(types) if types
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
    return CArray.object(n) { values } if present.empty?

    if present.all? { |v| v.is_a?(Array) || v.is_a?(CArray) }
      build_nd_column(values, present, n)
    else
      type = numeric_leaf_type(present)
      col = CArray.object(n) { values }
      type ? col.to_type(type) : col
    end
  end
  private_class_method :build_record_column

  # Stack equal-length array cells into an (N, L) column via an object 2-D fill
  # + to_type (nil rows -> UNDEF, int/float by leaf). Ragged lengths or
  # non-numeric leaves fall back to a 1-D object column of the raw cells.
  def self.build_nd_column(values, present, n)
    lengths = present.map { |v| v.is_a?(CArray) ? v.shape[0] : v.size }
    len = lengths.first
    return CArray.object(n) { values } unless lengths.all? { |x| x == len }

    nested = values.map { |v| v.nil? ? Array.new(len) : (v.is_a?(CArray) ? v.to_a : v) }
    type = numeric_leaf_type(nested.flatten.compact)
    table = CArray.object(n, len) { nested }
    type ? table.to_type(type) : table
  end
  private_class_method :build_nd_column

  # :int64 if every value is an Integer, :float64 if all are Numeric (int/float
  # mix), otherwise nil (strings / DateTime / booleans / mixed -> keep object).
  def self.numeric_leaf_type(values)
    if values.all? { |v| v.is_a?(Integer) }
      :int64
    elsif values.all? { |v| v.is_a?(Numeric) }
      :float64
    end
  end
  private_class_method :numeric_leaf_type
end
