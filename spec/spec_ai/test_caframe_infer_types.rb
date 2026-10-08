require "test/unit"
require "carray"
require "stringio"

# CAFrame#infer_types / from_csv(types: :infer): a text column becomes
# int64 or float64 when every cell that is not missing reads as a number of
# that kind; anything else stays text.
class TestCAFrameInferTypes < Test::Unit::TestCase
  CSV_TEXT = <<~CSV
    station,code,temp,count,id,flag,empty
    tokyo,007,22.1,3,12345678901234567890,A,
    osaka,012,,4,12345678901234567891,B,
    nagoya,105,21.0,,12345678901234567892,,
  CSV

  def frame(text = CSV_TEXT, **opts)
    CAFrame.from_csv(StringIO.new(text), **opts)
  end

  def infer(cells)
    CAFrame.new("a" => CA_OBJECT(cells)).infer_types["a"]
  end

  def test_infer_types_lists_number_columns
    assert_equal({ "temp" => :float64, "count" => :int64 }, frame.infer_types)
  end

  def test_types_infer_casts_them
    df = frame(types: :infer)
    assert_equal :float64, df["temp"].data_type
    assert_equal [22.1, UNDEF, 21.0], df["temp"].to_a
    assert_equal :int64, df["count"].data_type
    assert_equal [3, 4, UNDEF], df["count"].to_a
  end

  def test_codes_identifiers_and_text_stay_text
    df = frame(types: :infer)
    %w[station code id flag empty].each { |k| assert_equal :object, df[k].data_type, k }
    assert_equal ["007", "012", "105"], df["code"].to_a
  end

  def test_kinds
    assert_equal :int64,   infer(["1", "-2", "+3", " 4 ", "0", "-0"])
    assert_equal :float64, infer(["1", "2.5"])
    assert_equal :float64, infer(["1e3", ".5", "nan", "-Inf"])
    assert_equal :float64, infer(["1.0"])
    assert_nil infer(["007"])
    assert_nil infer(["007.5"])
    assert_nil infer(["-01"])
    assert_nil infer(["9223372036854775808"])
    assert_nil infer(["1", "x"])
    assert_nil infer(["0x10"])
    assert_nil infer(["1_000"])
    assert_equal :int64, infer(["9223372036854775807", "-9223372036854775808"])
  end

  def test_missing_cells_say_nothing
    assert_equal :int64, infer(["1", "", "  ", nil])
    assert_nil infer(["", nil])
    col = CA_OBJECT(["1", "x"])
    col[1] = UNDEF
    assert_equal({ "a" => :int64 }, CAFrame.new("a" => col).infer_types)
  end

  def test_ruby_numbers_in_an_object_column
    assert_equal :int64,   infer([1, 2])
    assert_equal :float64, infer([1, 2.5])
    assert_equal :int64,   infer([1, "2"])
    assert_nil infer([1, :x])
  end

  def test_typed_columns_are_not_listed
    df = CAFrame.new("a" => CA_INT32([1, 2]), "b" => CA_OBJECT(["1", "2"]))
    assert_equal({ "b" => :int64 }, df.infer_types)
  end

  def test_view_column
    base = CA_OBJECT([["x", "1"], ["y", "2"]])
    assert_equal({ "a" => :int64 }, CAFrame.new("a" => base[nil, 1]).infer_types)
  end

  def test_from_records
    df = CAFrame.from_records([{ "a" => "1" }, { "a" => "2" }], types: :infer)
    assert_equal :int64, df["a"].data_type
  end

  def test_types_must_be_a_map_or_infer
    assert_raise(ArgumentError) { frame(types: :auto) }
  end
end
