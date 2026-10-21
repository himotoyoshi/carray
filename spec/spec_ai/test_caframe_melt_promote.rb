# frozen_string_literal: true

require "test/unit"
require "carray"

# melt brings number columns of different types to their common type and
# keeps the value column a view of them.
class TestCAFrameMeltPromote < Test::Unit::TestCase
  def frame
    CAFrame.new("k" => CA_INT32([1, 2]), "a" => CA_FLOAT64([1.5, 2.5]),
                "b" => CA_INT64([3, 4]), "c" => CA_BOOLEAN([true, false]))
  end

  def test_common_type
    m = frame.melt(id: ["k"])
    assert_equal :float64, m.data_types["value"]
    assert_equal [1.5, 2.5, 3.0, 4.0, 1.0, 0.0], m["value"].to_a
  end

  def test_still_a_view
    df = frame
    m  = df.melt(id: ["k"], value_columns: ["a", "b"])
    df["b"][0] = 30
    assert_equal 30.0, m["value"][2]
    m["value"][3] = 8.0
    assert_equal [30, 8], df["b"].to_a
    m["value"][0] = 9.5
    assert_equal 9.5, df["a"][0]
  end

  def test_integers_meet_as_integers
    df = CAFrame.new("a" => CA_INT32([1]), "b" => CA_INT64([2]))
    assert_equal :int64, df.melt["value"].data_type
  end

  def test_numbers_with_text_or_time_raise
    df = frame.append("s", CArray.string(%w[x y]))
    assert_raise(ArgumentError) { df.melt(id: ["k"]) }
    df = frame.append("t", CArray.time(["2024-01-01", "2024-01-02"]))
    assert_raise(ArgumentError) { df.melt(id: ["k"]) }
  end
end
