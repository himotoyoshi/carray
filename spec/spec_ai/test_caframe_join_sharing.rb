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

  # view: :full: every column a view, UNDEF where a row has no row of a side.
  def test_full_view_gives_the_same_values
    l = CAFrame.new({ "k" => CA_INT32([1, 2, 3, 4]), "x" => CA_FLOAT64([1, 2, 3, 4]),
                      "m" => CA_INT32([[1, 2], [3, 4], [5, 6], [7, 8]]) },
                    index: CA_INT32([10, 20, 30, 40]))
    r = right
    %i[left inner right outer].each do |how|
      a = l.join(r, on: "k", how: how)
      b = l.join(r, on: "k", how: how, view: :full)
      a.column_names.each { |c| assert_equal a[c].to_a, b[c].to_a, "#{how} #{c}" }
      assert_equal a.index.to_a, b.index.to_a, how.to_s
    end
  end

  def test_full_view_outer_writes_reach_both_frames
    l, r = left, right
    j = l.join(r, on: "k", how: :outer, view: :full)
    assert_equal [1, 2, 3, 4, 5], j["k"].to_a
    j["x"][1] = -2.0
    j["y"][1] = -20.0
    j["k"][4] = 9                              # the right-only row's key
    assert_equal [1.0, -2.0, 3.0, 4.0], l["x"].to_a
    assert_equal [40.0, -20.0, 50.0], r["y"].to_a
    assert_equal [4, 2, 9], r["k"].to_a
    j["x"][4] = 99.0                           # a hole: no cell to land in
    assert_equal [1.0, -2.0, 3.0, 4.0], l["x"].to_a
  end

  def test_full_view_left_and_asof
    l, r = left, right
    j = l.join(r, on: "k", view: :full)
    j["y"][1] = -20.0
    assert_equal [40.0, -20.0, 50.0], r["y"].to_a
    t = CAFrame.new("t" => CA_FLOAT64([1, 2, 3]))
    u = CAFrame.new("t" => CA_FLOAT64([1.5, 10]), "w" => CA_INT32([7, 8]))
    a = t.join_asof(u, on: "t", view: :full)
    assert_equal [UNDEF, 7, 7], a["w"].to_a
    a["w"][1] = -7
    assert_equal [-7, 8], u["w"].to_a
  end

  # The outer key welds both key columns, so they must be of one kind; this
  # is checked whether or not a right-only row comes out.
  def test_full_view_outer_needs_one_kind_of_key
    l = left
    matched = CAFrame.new("k" => CA_FLOAT64([2]))
    assert_raise(ArgumentError) { l.join(matched, on: "k", how: :outer, view: :full) }
    d = CAFrame.new("t" => CArray.time(%w[2024-01-01], unit: :D))
    h = CAFrame.new("t" => CArray.time(%w[2024-01-01T00], unit: :h))
    assert_raise(ArgumentError) { d.join(h, on: "t", how: :outer, view: :full) }
    assert_equal [1, 2, 3, 4], l.join(matched, on: "k", view: :full)["k"].to_a
  end

  def test_view_takes_only_full
    assert_raise(ArgumentError) { left.join(right, on: "k", view: :part) }
    assert_raise(ArgumentError) { left.join(right, on: "k", how: :semi, view: :full) }
    assert_raise(ArgumentError) { left.join_asof(right, on: "k", view: true) }
  end
end
