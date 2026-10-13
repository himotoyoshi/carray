require "test/unit"
require "bigdecimal"
require "carray"
require "stringio"

# CAFrame#cast of text to numbers: every text column reads the same way,
# on_error: holds for every number target, and other real numbers in an
# object column read as the value they stand for.
class TestCAFrameCastText < Test::Unit::TestCase
  # A string Face column used to go through to_type, which ignored
  # on_error: and read "010" as 8.
  def test_a_string_face_reads_as_an_object_column_does
    df = CAFrame.new("s" => CArray.string(%w[010 x 3]))
    assert_equal [10, UNDEF, 3], df.cast("s", :int64)["s"].to_a
    df = CAFrame.new("s" => CArray.string(%w[1 x 3]))
    err = assert_raise(CAFrame::UnreadableColumn) { df.cast("s", :int64, on_error: :raise) }
    assert_match(/row 1 "x" cannot be read as int64/, err.message)
  end

  def test_a_const_string_column_casts_to_a_number
    df = CAFrame.new("s" => CArray.const_string(%w[1 2.5]))
    assert_equal [1.0, 2.5], df.cast("s", :float64)["s"].to_a
  end

  def test_on_error_holds_for_a_complex_target
    df = CAFrame.new("c" => CA_OBJECT(["1+2i", "x", ""]))
    err = assert_raise(CAFrame::UnreadableColumn) { df.cast("c", :cmplx128, on_error: :raise) }
    assert_match(/row 1 "x" cannot be read as cmplx128/, err.message)
    assert_equal [Complex(1, 2), UNDEF, UNDEF], df.cast("c", :cmplx128)["c"].to_a
  end

  def test_a_storage_target_is_still_refused_for_a_face
    df = CAFrame.new("s" => CArray.const_string(["ab"]))
    assert_raise(TypeError) { df.cast("s", :fixlen) }
  end

  # A Rational or a BigDecimal used to be UNDEF, where to_type read it.
  def test_other_real_numbers_read_as_their_value
    cells = [Rational(1, 2), Rational(4, 2), BigDecimal("2.0"), BigDecimal("2.5"),
             BigDecimal("NaN"), 3, 2.0]
    df = CAFrame.new("r" => CA_OBJECT(cells))
    f = df.copy.cast("r", :float64)["r"].to_a
    assert_equal [0.5, 2.0, 2.0, 2.5], f[0, 4]
    assert f[4].nan?
    assert_equal [3.0, 2.0], f[5, 2]
    assert_equal [UNDEF, 2, 2, UNDEF, UNDEF, 3, 2], df.copy.cast("r", :int64)["r"].to_a
  end

  def test_a_complex_cell_is_not_a_real_number
    df = CAFrame.new("r" => CA_OBJECT([Complex(1, 0)]))
    assert_equal [UNDEF], df.cast("r", :float64)["r"].to_a
  end

  # parse_to_time used to take only a Symbol unit on the year-first path.
  def test_parse_to_time_takes_any_unit_spelling
    df = CAFrame.new("t" => CA_OBJECT(["2024-01-01 12:34:56.5"]))
    t = df.copy.parse_to_time("t", unit: CATime::Resolution.parse(:s))["t"]
    assert_equal ["2024-01-01T12:34:56Z"], t.to_a.map(&:to_s)
    t = df.copy.parse_to_time("t", unit: "10 minutes")["t"]
    assert_equal ["2024-01-01T12:30:00Z"], t.to_a.map(&:to_s)
    t = df.copy.parse_to_time("t", unit: :ms)["t"]
    assert_equal "ms", t.unit.to_s
  end

  def test_a_column_casts_to_categorical
    df = CAFrame.new("s" => CArray.string(["x", "y", "x", ""]), "n" => CA_INT32([3, 1, 3, 1]))
    df.cast("s" => :categorical, "n" => :categorical)
    assert_kind_of CACategorical, df["s"]
    assert_equal ["x", "y", ""], df["s"].labels
    assert_equal ["x", "y", "x", ""], df["s"].to_a
    assert_equal [3, 1], df["n"].labels
    cat = df["s"]
    assert_same cat, df.cast("s", :categorical)["s"]
  end

  # from_csv reads a types: column as CAConstString, which categorizes
  # without a String made per cell; the labels are those to_string gives.
  def test_from_csv_reads_a_column_as_categorical
    csv = "a,b\nx,1\n,2\ny,3\nx,4\n\"\",5\n"
    df = CAFrame.from_csv(StringIO.new(csv), types: { "a" => :categorical, "b" => :int64 })
    assert_kind_of CACategorical, df["a"]
    assert_equal ["x", "y", ""], df["a"].labels
    assert_equal ["x", UNDEF, "y", "x", ""], df["a"].to_a
    assert_equal [1, 2, 3, 4, 5], df["b"].to_a
  end
end
