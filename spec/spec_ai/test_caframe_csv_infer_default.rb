# frozen_string_literal: true

require "test/unit"
require "stringio"
require "carray"

# from_csv infers the column types by default; types: :string keeps every
# column text.
class TestCAFrameCSVInferDefault < Test::Unit::TestCase
  CSV_TEXT = "date,station,t,n,code\n2024-01-01,A,1.5,3,007\n2024-01-02,B,,4,010\n"

  def test_types_are_inferred_by_default
    df = CAFrame.from_csv(StringIO.new(CSV_TEXT))
    assert_equal({ "date" => CATime, "station" => CAString, "t" => :float64,
                   "n" => :int64, "code" => CAString }, df.data_types)
    assert_equal [1.5, UNDEF], df["t"].to_a
    assert_equal %w[007 010], df["code"].to_a                 # a code keeps its zeros
  end

  def test_the_default_is_the_same_as_infer
    a = CAFrame.from_csv(StringIO.new(CSV_TEXT))
    b = CAFrame.from_csv(StringIO.new(CSV_TEXT), types: :infer)
    assert_equal b.data_types, a.data_types
  end

  def test_text_keeps_every_column_text
    df = CAFrame.from_csv(StringIO.new(CSV_TEXT), types: :string)
    assert_equal [CAString] * 5, df.data_types.values
    assert_equal ["1.5", UNDEF], df["t"].to_a
  end

  def test_a_map_names_some_columns_and_infers_the_rest
    df = CAFrame.from_csv(StringIO.new(CSV_TEXT), types: { "n" => :float64, "station" => nil })
    assert_equal :float64, df.data_types["n"]
    assert_equal :float64, df.data_types["t"]
    assert_equal CATime, df.data_types["date"]
  end

  def test_string_for_a_column_keeps_it_text
    df = CAFrame.from_csv(StringIO.new(CSV_TEXT), types: { "n" => :string })
    assert_equal CAString, df.data_types["n"]
    assert_equal :float64, df.data_types["t"]
  end

  def test_default_text_keeps_the_rest_text
    df = CAFrame.from_csv(StringIO.new(CSV_TEXT), types: { default: :string, "n" => :float64 })
    assert_equal :float64, df.data_types["n"]
    assert_equal [CAString] * 4, df.data_types.values_at("date", "station", "t", "code")
  end
end

# :string in a type map means the same for cast, from_records and from_csv.
class TestCAFrameCastString < Test::Unit::TestCase
  def test_cast
    df = CAFrame.new("o" => CA_OBJECT(%w[x y]), "s" => CArray.string(%w[a b]), "n" => CA_FLOAT64([1, 2]))
    assert_equal CAString, df.cast("o" => :string).data_types["o"]
    assert_same df["s"], df.cast("s" => :string)["s"]
    e = assert_raise(CArray::DataTypeError) { df.cast("n" => :string) }
    assert_match(/column "n".*format/, e.message)
  end

  def test_from_records
    assert_equal CAString, CAFrame.from_records([{ "a" => "x" }], types: { "a" => :string }).data_types["a"]
    assert_equal CAString, CAFrame.from_records([{ "a" => "x" }], types: :string).data_types["a"]
    assert_raise(CArray::DataTypeError) { CAFrame.from_records([{ "a" => "x", "b" => 1 }], types: :string) }
  end

  def test_from_csv_default_string
    df = CAFrame.from_csv(StringIO.new("a,b\n007,2\n"), types: { default: :string, "b" => :int32 })
    assert_equal({ "a" => CAString, "b" => :int32 }, df.data_types)
  end
end
