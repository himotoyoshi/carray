require "test/unit"
require "carray"

# CAFrame#resample: group rows into time bins.
class TestCAFrameResample < Test::Unit::TestCase
  def setup
    @time = CArray.time(["2024-01-01 00:10", "2024-01-01 00:50", "2024-01-01 01:00",
                         "2024-01-01 03:05", "2024-01-01 03:40"], unit: :m)
    @df = CAFrame.new("time" => @time, "temp" => CA_FLOAT64([1, 2, 3, 4, 5]),
                      "rain" => CA_INT32([0, 1, 1, 0, 2]))
  end

  def labels(frame)
    frame.index.to_a.map(&:to_s)
  end

  def test_left_bins_start_at_their_label
    r = @df.resample("time", "1 hour").mean
    assert_kind_of CATime, r.index
    assert_equal "time", r.axis_name
    assert_equal ["2024-01-01T00:00:00Z", "2024-01-01T01:00:00Z", "2024-01-01T03:00:00Z"], labels(r)
    assert_equal [1.5, 3.0, 4.5], r["temp"].to_a
  end

  def test_right_bins_end_at_their_label_and_include_it
    r = @df.resample("time", "1 hour", label: :right).mean
    assert_equal ["2024-01-01T01:00:00Z", "2024-01-01T04:00:00Z"], labels(r)
    assert_equal [2.0, 4.5], r["temp"].to_a      # 01:00 belongs to (00:00, 01:00]
  end

  def test_fill_lays_every_bin
    r = @df.resample("time", "1 hour", fill: true).mean
    assert_equal ["2024-01-01T00:00:00Z", "2024-01-01T01:00:00Z",
                  "2024-01-01T02:00:00Z", "2024-01-01T03:00:00Z"], labels(r)
    assert_equal [1.5, 3.0, UNDEF, 4.5], r["temp"].to_a
  end

  def test_an_empty_bin_counts_and_sums_to_zero
    r = @df.resample("time", "1 hour", fill: true).aggregate(
      "n" => ["temp", :count], "rain" => ["rain", :sum])
    assert_equal [2, 1, 0, 2], r["n"].to_a
    assert_equal [1, 1, 0, 2], r["rain"].to_a
  end

  def test_origin_shifts_the_bins
    r = @df.resample("time", "1 hour", origin: "2024-01-01 00:30", fill: true).mean
    assert_equal ["2023-12-31T23:30:00Z", "2024-01-01T00:30:00Z", "2024-01-01T01:30:00Z",
                  "2024-01-01T02:30:00Z", "2024-01-01T03:30:00Z"], labels(r)
    assert_equal [1.0, 2.5, UNDEF, 4.0, 5.0], r["temp"].to_a
  end

  def test_rows_in_any_order
    df = @df[CA_INT64([4, 2, 0, 3, 1])]
    r = df.resample("time", "1 hour").mean
    assert_equal ["2024-01-01T00:00:00Z", "2024-01-01T01:00:00Z", "2024-01-01T03:00:00Z"], labels(r)
    assert_equal [1.5, 3.0, 4.5], r["temp"].to_a
  end

  def test_calendar_bins
    t = CArray.time(["2024-01-05", "2024-01-20", "2024-03-02"], unit: :D)
    df = CAFrame.new("time" => t, "v" => CA_FLOAT64([1, 3, 10]))
    r = df.resample("time", "1 month", fill: true).mean
    assert_equal ["2024-01", "2024-02", "2024-03"], labels(r)
    assert_equal [2.0, UNDEF, 10.0], r["v"].to_a
  end

  def test_a_masked_time_belongs_to_no_bin
    @time[1] = UNDEF
    r = @df.resample("time", "1 hour").mean
    assert_equal [1.0, 3.0, 4.5], r["temp"].to_a
  end

  def test_the_time_column_is_not_a_result_column
    assert_not_include @df.resample("time", "1 hour").mean.column_names, "time"
  end

  def test_the_index_as_the_time_key
    df = @df.set_index("time")
    r = df.resample("time", "1 hour").mean
    assert_equal ["temp", "rain"], r.column_names
    assert_equal [1.5, 3.0, 4.5], r["temp"].to_a
  end

  def test_table_and_raw_iterators_work
    g = @df.resample("time", "1 hour")
    assert_equal 3, g.ngroup
    r = g.table { |sub| { "n" => sub.nrow } }
    assert_equal [2, 1, 2], r["n"].to_a
  end

  def test_the_result_aligns_with_a_time_grid
    r = @df.resample("time", "1 hour").mean
    grid = CArray.time_range("2024-01-01 00:00", "2024-01-01 03:00", unit: :m, step: "1 hour")
    assert_equal [1.5, 3.0, UNDEF, 4.5], r.align("time", grid)["temp"].to_a
  end

  def test_no_present_time
    @time[] = UNDEF
    r = @df.resample("time", "1 hour", fill: true).mean
    assert_equal 0, r.nrow
  end

  def test_rejects_a_column_that_is_not_time
    assert_raise(ArgumentError) { @df.resample("temp", "1 hour") }
  end

  def test_rejects_an_unknown_label
    assert_raise(ArgumentError) { @df.resample("time", "1 hour", label: :center) }
  end
end

# group_by on a single key keeps the key's data type and Face in the index.
class TestCAFrameGroupByIndexType < Test::Unit::TestCase
  def test_a_time_key_gives_a_time_index
    t = CArray.time(["2024-01-02", "2024-01-01", "2024-01-02"], unit: :D)
    df = CAFrame.new("day" => t, "v" => CA_FLOAT64([1, 2, 3]))
    r = df.group_by("day").mean
    assert_kind_of CATime, r.index
    assert_equal ["2024-01-02", "2024-01-01"], r.index.to_a.map(&:to_s)
    assert_equal [2.0, 2.0], r["v"].to_a
  end

  def test_an_integer_key_gives_an_integer_index
    df = CAFrame.new("k" => CA_INT32([3, 1, 3]), "v" => CA_FLOAT64([1, 2, 3]))
    r = df.group_by("k").mean
    assert_equal :int32, r.index.data_type
    assert_equal [3, 1], r.index.to_a
  end

  def test_an_external_key
    df = CAFrame.new("v" => CA_FLOAT64([1, 2, 3]))
    r = df.group_by(CA_INT16([5, 5, 6])).sum
    assert_equal :int16, r.index.data_type
    assert_equal [3.0, 3.0], r["v"].to_a
  end

  def test_a_composite_key_keeps_tuples
    df = CAFrame.new("a" => CA_INT32([1, 1, 2]), "b" => CA_OBJECT(%w[x x y]),
                     "v" => CA_FLOAT64([1, 2, 3]))
    r = df.group_by("a", "b").sum
    assert_equal [[1, "x"], [2, "y"]], r.index.to_a
  end
end
