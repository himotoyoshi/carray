# frozen_string_literal: true

require "test/unit"
require "carray"

# percentile(p, *names) on the frame, a GroupedFrame and windows: the
# percentage first, then the names, as median gives the 50th.
class TestCAFramePercentile < Test::Unit::TestCase
  def frame
    CAFrame.new({ "g" => CA_OBJECT(%w[a b a b a b]),
                  "t" => CA_FLOAT64([1, 2, 3, 4, 5, 6]),
                  "v" => CA_FLOAT64([1, 2, 3, 4, 5, 6]),
                  "s" => CArray.string(%w[x y z u v w]) },
                index: CA_INT32([0, 1, 2, 3, 4, 5]))
  end

  def test_the_frame
    df = frame
    assert_equal %w[t v], df.percentile(50).column_names
    assert_equal [df["v"].percentile(90)], df.percentile(90, "v")["v"].to_a
    assert_equal df.median("v").to_a, df.percentile(50, "v").to_a
    assert_equal [5.5] * 6, df.percentile(90, "v", keep_rows: true).to_a
  end

  def test_a_group
    grp = frame.group_by("g")
    out = grp.percentile(50, "v")
    assert_equal %w[a b], out.index.to_a
    assert_equal [3.0, 4.0], out["v"].to_a
    assert_equal grp.median("v").to_a, out.to_a
    assert_equal [3.0, 4.0, 3.0, 4.0, 3.0, 4.0], grp.percentile(50, "v", keep_rows: true).to_a
    assert_equal [UNDEF, UNDEF], grp.percentile(50, "v", min_count: 4)["v"].to_a
    assert_equal [-1.0, -1.0], grp.percentile(50, "v", min_count: 4, fill_value: -1.0)["v"].to_a
  end

  def test_windows
    df = frame
    w  = df.windows(on: "t", before: 2)
    assert_equal [1.0, 1.5, 2.5, 3.5, 4.5, 5.5], w.percentile(50, "v").to_a
    assert_equal %w[v], w.percentile(50).column_names
    at = df.windows(on: "t", before: 2, at: CA_FLOAT64([3, 6])).percentile(50, "v")
    assert_equal [2.5, 5.5], at["v"].to_a
  end

  def test_refusals
    df = frame
    e = assert_raise(ArgumentError) { df.percentile("v", 90) }
    assert_match(/percentage first/, e.message)
    assert_raise(ArgumentError) { df.group_by("g").percentile(150, "v") }
    assert_raise(CArray::DataTypeError) { df.group_by("g").percentile(50, "s") }
    assert_raise(ArgumentError) { df.windows(on: "t", before: 2).percentile(50, "v", "v") }
  end
end
