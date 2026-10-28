# frozen_string_literal: true

require "test/unit"
require "carray"

# order / cumsum / cumprod / cummax / cummin / cumcount on the frame itself:
# the group's running values with every row in one group.
class TestCAFrameRunningValues < Test::Unit::TestCase
  def frame
    v = CA_FLOAT64([3, 1, 4, 1, 5])
    v[2] = UNDEF
    CAFrame.new({ "v" => v, "n" => CA_INT32([1, 2, 3, 4, 5]), "s" => CArray.string(%w[a b c d e]) },
                axis_name: "t", index: CA_INT32([10, 11, 12, 13, 14]))
  end

  def test_named
    df = frame
    assert_equal [3.0, 4.0, 4.0, 5.0, 10.0], df.cumsum("v").to_a
    assert_equal [3.0, 3.0, 3.0, 3.0, 5.0], df.cummax("v").to_a
    assert_equal [1, 2, 2, 3, 4], df.cumcount("v").to_a
    assert_equal [1, 2, 6, 24, 120], df.cumprod("n").to_a
    assert_equal [1, 2, UNDEF, 3, 0], df.order("v", descending: true).to_a
    out = df.cummin("v", "n")
    assert_kind_of CAFrame, out
    assert_equal df.index.to_a, out.index.to_a if df.index
    a, b = out["v"], out["n"]
    assert_equal [3.0, 1.0, 1.0, 1.0, 1.0], a.to_a
    assert_equal [1, 1, 1, 1, 1], b.to_a
  end

  def test_the_same_as_the_column_and_a_group_of_all
    df = frame
    assert_equal df["n"].cumsum.to_a, df.cumsum("n").to_a
  end

  def test_without_names
    out = frame.cumsum
    assert_equal %w[v n], out.column_names
    assert_equal [10, 11, 12, 13, 14], out.index.to_a
    assert_equal "t", out.axis_name
  end

  def test_no_rows
    assert_equal [], CAFrame.new("v" => CA_FLOAT64([])).cumsum("v").to_a
  end
end
