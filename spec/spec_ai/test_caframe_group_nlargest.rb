# frozen_string_literal: true

require "test/unit"
require "carray"

# GroupedFrame#nlargest / #nsmallest give each group's n rows with the
# largest / smallest keys, the groups in the order of labels.
class TestCAFrameGroupNLargest < Test::Unit::TestCase
  def frame
    v = CA_FLOAT64([3, 9, 1, 7, Float::NAN, 5, 2])
    v[6] = UNDEF
    k = CA_OBJECT(%w[b a b a a b b])
    CAFrame.new({ "k" => k, "v" => v, "j" => CA_INT32([0, 0, 0, 1, 0, 0, 0]) },
                axis_name: "r", index: CA_INT32([0, 1, 2, 3, 4, 5, 6]))
  end

  def test_largest
    out = frame.group_by("k").nlargest(2, "v")
    assert_equal %w[b b a a], out["k"].to_a
    assert_equal [5.0, 3.0, 9.0, 7.0], out["v"].to_a
    assert_equal [5, 0, 1, 3], out.index.to_a
  end

  def test_smallest_with_nan_and_masked_last
    assert_equal [2, 0, 5, 6, 3, 1, 4], frame.group_by("k").nsmallest(5, "v").index.to_a
  end

  def test_a_second_key_breaks_ties
    df = CAFrame.new("k" => CA_OBJECT(%w[a a a]), "v" => CA_INT32([1, 1, 0]), "j" => CA_INT32([0, 5, 9]))
    assert_equal [5, 0], df.group_by("k").nlargest(2, "v", "j")["j"].to_a
  end

  def test_a_row_in_no_group_is_left_out
    df = frame
    df["k"][1] = UNDEF
    # row 1 (a, 9.0) has no group, so a's largest is row 3 (7.0)
    assert_equal [5, 3], df.group_by("k").nlargest(1, "v").index.to_a
  end

  def test_a_view_of_the_frame
    df  = frame
    out = df.group_by("k").nlargest(1, "v")
    out["v"][0] = -1.0
    assert_equal(-1.0, df["v"][5])
  end

  def test_refusals
    g = frame.group_by("k")
    assert_raise(ArgumentError) { g.nlargest(-1, "v") }
    assert_raise(ArgumentError) { g.nlargest(1) }
    assert_raise(TypeError) { g.nlargest(1.5, "v") }
    assert_raise(KeyError) { g.nlargest(1, "nope") }
    assert_equal 0, g.nlargest(0, "v").nrow
  end
end
