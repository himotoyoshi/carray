# frozen_string_literal: true

require "test/unit"
require "carray"

# df["name"] = value repeats a single value on every row.
class TestCAFrameAssignOneValue < Test::Unit::TestCase
  def frame
    CAFrame.new("v" => CA_FLOAT64([1, 2, 3]))
  end

  def test_values_typed_as_record_values
    df = frame
    df["n"] = 1
    df["x"] = 0.5
    df["s"] = "degC"
    df["z"] = Complex(1, 2)
    assert_equal({ "v" => :float64, "n" => :int64, "x" => :float64,
                   "s" => CAString, "z" => :cmplx128 }, df.data_types)
    assert_equal ["degC"] * 3, df["s"].to_a
    assert_equal [1, 1, 1], df["n"].to_a
  end

  def test_a_frame_with_no_rows_gets_the_same_type
    df = frame
    none = df.filter(df["v"] > 10)
    none["n"] = 7
    none["s"] = "degC"
    assert_equal :int64, none.data_types["n"]
    assert_equal CAString, none.data_types["s"]
    assert_equal 0, none["n"].elements
  end

  def test_replaces_an_existing_column
    df  = frame
    old = df["v"]
    df["v"] = 0.0
    assert_equal [0.0, 0.0, 0.0], df["v"].to_a
    assert_equal [1.0, 2.0, 3.0], old.to_a
  end

  def test_a_frame_with_only_an_index
    df = CAFrame.new({}, axis_name: "t", index: CA_INT32([5, 6]))
    df["a"] = 3
    assert_equal [3, 3], df["a"].to_a
  end

  def test_no_rows_to_repeat_on
    e = assert_raise(ArgumentError) { CAFrame.new({})["a"] = 1 }
    assert_match(/no rows to repeat/, e.message)
  end

  def test_nil_and_undef_keep_their_meanings
    df = frame
    df["v"] = UNDEF
    assert_equal 3, df["v"].count_masked
    df["v"] = nil
    assert_equal [], df.column_names
  end
end
