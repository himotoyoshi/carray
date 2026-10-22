# frozen_string_literal: true

require "test/unit"
require "carray"

# A key join shares the cells of a side whose every result row has a row of
# that side: both sides of an inner join, this frame in a left join, the
# other frame in a right join. A side that gets UNDEF for unmatched rows is
# gathered into new columns.
class TestCAFrameJoinSharing < Test::Unit::TestCase
  def left
    CAFrame.new("k" => CA_INT32([1, 2, 3, 4]), "x" => CA_FLOAT64([1, 2, 3, 4]))
  end

  def right
    CAFrame.new("k" => CA_INT32([4, 2, 5]), "y" => CA_FLOAT64([40, 20, 50]),
                "m" => CA_INT32([[1, 2], [3, 4], [5, 6]]))
  end

  def test_inner_shares_both_sides
    l, r = left, right
    j = l.join(r, on: "k", how: :inner)
    assert_equal [20.0, 40.0], j["y"].to_a
    assert_equal [[3, 4], [1, 2]], j["m"].to_a
    j["x"][0] = -2.0
    j["y"][0] = -20.0
    j["m"][1, 0] = -1
    assert_equal [1.0, -2.0, 3.0, 4.0], l["x"].to_a
    assert_equal [40.0, -20.0, 50.0], r["y"].to_a
    assert_equal [-1, 2], r["m"][0, nil].to_a
  end

  def test_right_shares_the_other_frame
    l, r = left, right
    j = l.join(r, on: "k", how: :right)
    assert_equal [4, 2, 5], j["k"].to_a
    assert_equal [40.0, 20.0, 50.0], j["y"].to_a
    j["y"][2] = -50.0
    j["k"][2] = 9
    assert_equal [40.0, 20.0, -50.0], r["y"].to_a
    assert_equal [4, 2, 9], r["k"].to_a
    j["x"][0] = -4.0                           # gathered: not this frame's cells
    assert_equal [1.0, 2.0, 3.0, 4.0], l["x"].to_a
  end

  def test_left_gathers_the_other_frame
    l, r = left, right
    j = l.join(r, on: "k", how: :left)
    assert_equal [UNDEF, 20.0, UNDEF, 40.0], j["y"].to_a
    j["y"][1] = -20.0
    assert_equal [40.0, 20.0, 50.0], r["y"].to_a
  end

  def test_copy_makes_a_result_of_its_own
    l, r = left, right
    j = l.join(r, on: "k", how: :inner).copy
    j["y"][0] = -20.0
    assert_equal [40.0, 20.0, 50.0], r["y"].to_a
  end
end
