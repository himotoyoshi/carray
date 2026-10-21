# frozen_string_literal: true

require "test/unit"
require "carray"

# lag(before: / after:) gives each row the value of the row whose key is an
# exact distance away, within each group for GroupedFrame#lag.
class TestCAFrameLagDistance < Test::Unit::TestCase
  # Two stations stacked one after another, each in time order.
  def stations
    t = CArray.time(["2024-01-01 00:00", "2024-01-01 00:30", "2024-01-01 01:00",
                     "2024-01-01 01:30", "2024-01-01 03:00",
                     "2024-01-01 00:00", "2024-01-01 01:00", "2024-01-01 02:00"])
    v = CA_FLOAT64([1.5, 1.8, 0.0, 2.4, 3.0, 5.0, 5.5, 6.1])
    v[2] = UNDEF
    v.set_attr("units", "degC")
    return CAFrame.new({ "station" => CA_OBJECT(%w[A A A A A B B B]), "temp" => v },
                       axis_name: "time", index: t)
  end

  def test_before_within_each_group
    lag = stations.group_by("station").lag("temp", before: "1 hour")
    assert_equal [UNDEF, UNDEF, 1.5, 1.8, UNDEF, UNDEF, 5.0, 5.5], lag.to_a
  end

  def test_after_within_each_group
    lag = stations.group_by("station").lag("temp", after: "30 minutes")
    # A's 00:30 looks at 01:00, whose value is masked
    assert_equal [1.8, UNDEF, 2.4, UNDEF, UNDEF, UNDEF, UNDEF, UNDEF], lag.to_a
  end

  def test_a_row_count_is_still_the_default
    lag = stations.group_by("station").lag("temp")
    assert_equal [UNDEF, 1.5, 1.8, UNDEF, 2.4, UNDEF, 5.0, 5.5], lag.to_a
  end

  def test_the_key_can_be_a_column
    df = stations.reset_index
    lag = df.group_by("station").lag("temp", before: "1 hour", on: "time")
    assert_equal [UNDEF, UNDEF, 1.5, 1.8, UNDEF, UNDEF, 5.0, 5.5], lag.to_a
  end

  def test_rows_out_of_order
    df  = stations
    rev = df[CA_INT64([7, 6, 5, 4, 3, 2, 1, 0])].copy
    lag = rev.group_by("station").lag("temp", before: "1 hour")
    assert_equal [5.5, 5.0, UNDEF, UNDEF, 1.8, 1.5, UNDEF, UNDEF], lag.to_a
  end

  def test_without_names_a_frame_without_the_key_columns
    out = stations.group_by("station").lag(before: "1 hour")
    assert_equal ["temp"], out.column_names
    assert_equal "time", out.axis_name
    assert_equal 8, out.nrow
  end

  def test_the_result_shows_the_columns_attributes
    lag = stations.group_by("station").lag("temp", before: "1 hour")
    assert_equal "degC", lag.attr("units")
  end

  def test_a_frame_without_groups
    t  = CArray.time(["2024-01-01 02:00", "2024-01-01 00:00", "2024-01-01 01:00"])
    df = CAFrame.new({ "v" => CA_FLOAT64([3, 1, 2]) }, axis_name: "time", index: t)
    assert_equal [2.0, UNDEF, 1.0], df.lag("v", before: "1 hour").to_a
    assert_equal [UNDEF, 2.0, 3.0], df.lag("v", after: "1 hour").to_a
    assert_equal [UNDEF, 3.0, 1.0], df.lag("v", n: 1).to_a
  end

  def test_a_distance_finer_than_the_key_is_not_rounded_onto_it
    t  = CArray.time(["2024-01-01", "2024-01-02"], unit: :D)
    df = CAFrame.new({ "v" => CA_FLOAT64([1, 2]) }, axis_name: "t", index: t)
    assert_equal [UNDEF, UNDEF], df.lag("v", before: "1 hour").to_a
    assert_equal [UNDEF, 1.0], df.lag("v", before: "24 hours").to_a
  end

  def test_a_number_key
    df = CAFrame.new("x" => CA_FLOAT64([0, 1, Float::NAN, Float::NAN, Float::INFINITY, 2]),
                     "v" => CA_FLOAT64([10, 11, 12, 13, 14, 15]))
    # NaN and infinite keys are no distance from any key
    assert_equal [UNDEF, 10.0, UNDEF, UNDEF, UNDEF, 11.0],
                 df.lag("v", before: 1, on: "x").to_a
  end

  def test_refusals
    df  = stations
    grp = df.group_by("station")
    assert_raise(ArgumentError) { grp.lag("temp", n: 1, before: "1 hour") }
    assert_raise(ArgumentError) { grp.lag("temp", before: "1 hour", after: "1 hour") }
    assert_raise(ArgumentError) { grp.lag("temp", on: "time") }
    assert_raise(ArgumentError) { grp.lag("temp", before: 1) }           # not a duration
    assert_raise(ArgumentError) { grp.lag("temp", before: "-1 hour") }
    e = assert_raise(ArgumentError) { df.lag("temp", before: "1 hour") }  # times repeat across stations
    assert_match(/key repeats/, e.message)
    e = assert_raise(ArgumentError) { df.reset_index.lag("temp", before: "1 hour") }
    assert_match(/no index/, e.message)
  end
end
