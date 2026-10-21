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

  QUARTILE_NAMES = %w[v_p0 v_p25 v_p50 v_p75 v_p100].freeze

  # quantile: the five quartile percentiles, each a column "<name>_p<pct>".
  def test_quantile_of_the_frame
    df  = frame
    out = df.quantile("v")
    assert_equal QUARTILE_NAMES, out.column_names
    assert_equal 1, out.nrow
    assert_equal [[1.0, 2.25, 3.5, 4.75, 6.0]], out.to_a
    assert_equal %w[t_p0 t_p25 t_p50 t_p75 t_p100] + QUARTILE_NAMES, df.quantile.column_names
    rows = df.quantile("v", keep_rows: true)
    assert_equal df.index.to_a, rows.index.to_a
    assert_equal [3.5] * 6, rows["v_p50"].to_a
  end

  def test_quantile_of_a_group
    grp = frame.group_by("g")
    out = grp.quantile("v")
    assert_equal %w[a b], out.index.to_a
    assert_equal QUARTILE_NAMES, out.column_names
    assert_equal [[1.0, 2.0, 3.0, 4.0, 5.0], [2.0, 3.0, 4.0, 5.0, 6.0]], out.to_a
    assert_equal grp.percentile(25, "v").to_a.flatten, out["v_p25"].to_a
    assert_equal [3.0, 4.0, 3.0, 4.0, 3.0, 4.0], grp.quantile("v", keep_rows: true)["v_p50"].to_a
    assert_raise(ArgumentError) { grp.quantile("g") }
  end

  def test_quantile_of_windows
    df  = frame
    out = df.windows(on: "t", before: 2).quantile("v")
    assert_equal QUARTILE_NAMES, out.column_names
    assert_equal df.index.to_a, out.index.to_a
    assert_equal [5.0, 5.25, 5.5, 5.75, 6.0], out.to_a.last
    at = df.windows(on: "t", before: 2, at: CA_FLOAT64([3, 6])).quantile("v")
    assert_equal [3.0, 6.0], at.index.to_a
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
