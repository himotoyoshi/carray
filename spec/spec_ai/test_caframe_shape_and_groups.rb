# frozen_string_literal: true

require "test/unit"
require "carray"

# df.shape / df.empty?, and a grouped frame's size and each.
class TestCAFrameShapeAndGroups < Test::Unit::TestCase
  def frame
    k = CA_OBJECT(%w[a b a b c])
    k[4] = UNDEF
    CAFrame.new({ "k" => k, "v" => CA_FLOAT64([1, 2, 3, 4, 5]) },
                axis_name: "row", index: CA_INT32([10, 11, 12, 13, 14]))
  end

  def test_shape_and_empty
    df = frame
    assert_equal [5, 2], df.shape
    assert_equal false, df.empty?
    assert_equal true, df.head(0).empty?
    assert_equal [2, 0], CAFrame.new({}, axis_name: "t", index: CA_INT32([1, 2])).shape
  end

  def test_size
    out = frame.group_by("k").size
    assert_equal ["size"], out.column_names
    assert_equal %w[a b], out.index.to_a
    assert_equal [2, 2], out["size"].to_a           # the row with a masked key is in no group
  end

  def test_size_with_several_keys
    df = frame.append("j", CA_INT32([0, 0, 1, 0, 0]))
    out = df.group_by("k", "j").size
    assert_equal %w[k j size], out.column_names
    assert_equal [1, 2, 1], out["size"].to_a
  end

  def test_each
    seen = []
    grp = frame.group_by("k")
    assert_same grp, grp.each { |label, rows| seen << [label, rows.index.to_a] }
    assert_equal [["a", [10, 12]], ["b", [11, 13]]], seen
    assert_equal %w[a b], grp.each.map { |label, _| label }
    assert_equal 2, grp.each.size
  end

  def test_each_gives_views
    df = frame
    df.group_by("k").each { |_, rows| rows["v"][0] = 0.0 }
    assert_equal [0.0, 0.0, 3.0, 4.0, 5.0], df["v"].to_a
  end
end
