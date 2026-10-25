# frozen_string_literal: true

require "test/unit"
require "carray"

# cast(name => :timedelta) and types: { name => :timedelta } read the text
# to_csv writes for a CATimedelta column.
class TestCAFrameCastTimedelta < Test::Unit::TestCase
  def test_round_trip_through_csv
    d = CA_INT64([3, -2, 5]).timedelta(unit: "10 minutes")
    d[2] = UNDEF
    df = CAFrame.new("d" => d, "e" => CA_INT64([194400, 1, 2]).timedelta(unit: :s))
    back = CAFrame.from_csv(df.to_csv, types: { "d" => :timedelta, "e" => :timedelta })
    assert_kind_of CATimedelta, back["d"]
    assert_equal "10 m", back["d"].unit.to_s
    assert_equal true, back == df
  end

  def test_cells_in_different_units_take_the_finest
    df = CAFrame.new("x" => CA_OBJECT(["3s", "2ms", nil])).cast("x" => :timedelta)
    assert_equal "ms", df["x"].unit.to_s
    assert_equal ["3000ms", "2ms", "UNDEF"], df["x"].to_a.map(&:to_s)
  end

  def test_calendar_units
    df = CAFrame.new("x" => CA_OBJECT(["3Y", "2M"])).cast("x" => :timedelta)
    assert_equal ["36M", "2M"], df["x"].to_a.map(&:to_s)
    assert_raise(ArgumentError) { CAFrame.new("x" => CA_OBJECT(["3M", "2s"])).cast("x" => :timedelta) }
  end

  def test_unreadable_cells_follow_on_error
    df = CAFrame.new("x" => CA_OBJECT(["3s", "zz"]))
    assert_equal [false, true], df.cast("x" => :timedelta)["x"].is_masked.to_a
    assert_raise(CAFrame::UnreadableColumn) { df.cast("x" => :timedelta, on_error: :raise) }
  end

  def test_a_number_column_is_refused
    assert_raise(ArgumentError) { CAFrame.new("x" => CA_INT64([3])).cast("x" => :timedelta) }
  end

  def test_from_records
    df = CAFrame.from_records([{ "a" => "3h" }, { "a" => "-1h" }], types: { "a" => :timedelta })
    assert_equal ["3h", "-1h"], df["a"].to_a.map(&:to_s)
  end
end
