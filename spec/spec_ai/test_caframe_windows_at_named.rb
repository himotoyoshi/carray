# frozen_string_literal: true

require "test/unit"
require "carray"

# A windowed reduction placed at points gives a frame labelled by the points,
# named columns or not; without at: it gives the rows' values as before.
class TestCAFrameWindowsAtNamed < Test::Unit::TestCase
  def frame
    CAFrame.new("time" => CArray.time_range("2024-01-01 00:00", "2024-01-01 11:00", unit: :h),
                "v" => CArray.float64(12).seq!, "w" => CA_INT32((0...12).map { |i| i % 3 }))
  end

  def test_named_at_points
    g = CArray.time_range("2024-01-01 00:00", "2024-01-01 06:00", unit: "6 hours")
    w = frame.windows(on: "time", at: g, after: "6 hours", exclude: :upper)
    out = w.mean("v")
    assert_kind_of CAFrame, out
    assert_equal ["v"], out.column_names
    assert_equal "time", out.axis_name
    assert_equal %w[2024-01-01T00:00:00Z 2024-01-01T06:00:00Z], out.index.to_a.map(&:to_s)
    assert_equal [2.5, 8.5], out["v"].to_a
    assert_equal %w[v w], w.max("v", "w").column_names
    assert_equal w.mean.select("v")["v"].to_a, out["v"].to_a
  end

  def test_named_at_rows_stays_an_array
    out = frame.windows(on: "time", before: "2 hours").mean("v")
    assert_kind_of CArray, out
    assert_equal 12, out.elements
  end
end
