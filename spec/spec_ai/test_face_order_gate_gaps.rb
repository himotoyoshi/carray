# frozen_string_literal: true
#
# Ordering members that test_face_family_matrix.rb does not enumerate, run on
# Faces whose storage order differs from their surface order:
#
#   - CAConstString: a cell is a (start, end) byte range, so storage order is
#     the order the strings were packed in
#   - CACategorical: a code's order is the vocabulary's, not the labels'
#   - CATimedelta over 255 / 256: memcmp on little-endian int64 puts 256
#     (00 01 ..) before 255 (ff 00 ..)
#
# Each of these answered silently wrong: the comparison operators, partition_copy
# and the tile min / max compared storage bytes.

require "test/unit"
require "carray"
require "carray/categorical"

class TestFaceOrderGateGaps < Test::Unit::TestCase

  def strings
    CArray.const_string(%w[ab dd cd ee])
  end

  def ticks
    CArray.int64(5) { |i| [256, 255, 1, 300, 7][i] }.timedelta(unit: :s)
  end

  def seconds (a)
    a.to_a.map { |e| e == UNDEF ? e : e.value }
  end

  # ---- comparison operators on CAConstString -----------------------------

  def test_const_string_comparison_against_a_string
    s = strings
    assert_equal [true,  false, true,  false], (s < "dd").to_a
    assert_equal [true,  true,  true,  false], (s <= "dd").to_a
    assert_equal [false, false, false, true ], (s > "dd").to_a
    assert_equal [false, true,  false, true ], (s >= "dd").to_a
    assert_equal [true,  false, true,  true ], s.ne("dd").to_a
    assert_equal [-1, 0, -1, 1], (s <=> "dd").to_a
  end

  def test_const_string_comparison_against_a_const_string
    s = strings
    assert_equal [true, false, true, false], (s < s.reverse).to_a
    assert_equal [true, false, true, false], s.lt(s.reverse).to_a
    assert_equal [false, false, false, false], (s < s.to_string).to_a
  end

  def test_const_string_comparison_keeps_the_mask
    s = CArray.const_string(["ab", nil, "zz"])
    assert_equal [true, UNDEF, false], (s < "b").to_a
  end

  # ---- partition_copy ------------------------------------------------------

  def test_partition_copy_selects_in_surface_order
    t = ticks
    r = t.partition_copy(0)
    assert_kind_of CATimedelta, r
    assert_equal 1, r[0].value
    assert_equal 300, t.partition_copy(4)[4].value
  end

  def test_partition_copy_keeps_the_face_and_the_mask
    t = ticks
    t[1] = UNDEF
    r = t.partition_copy(0)
    assert_kind_of CATimedelta, r
    assert_equal [1, 7, 256, 300, UNDEF], seconds(r)
  end

  def test_partition_copy_refuses_a_categorical
    c = CA_OBJECT(%w[ab dd cd ee]).categorize
    assert_raise(ArgumentError) { c.partition_copy(1) }
  end

  def test_partition_copy_keeps_a_fixlen_string
    f = strings.to_fixlen_string
    r = f.partition_copy(1)
    assert_kind_of CAFixlenString, r
    assert_equal "cd", r[1]
  end

  # ---- tile min / max --------------------------------------------------------

  def test_block_view_keeps_the_face
    assert_kind_of CATimedelta, ticks[0..3].block_view(2)
  end

  def test_blocks_min_max_answer_in_surface_order_as_the_face
    t = ticks
    assert_kind_of CATimedelta, t.blocks(2).min
    assert_equal [255, 1, 7],   seconds(t.blocks(2).min)
    assert_equal [256, 300, 7], seconds(t.blocks(2).max)
    assert_equal [[255, 1, 7], [256, 300, 7]],
                 t.blocks(2).minmax.map { |a| seconds(a) }
  end

  def test_blocks_min_with_empty_tiles
    t = ticks
    t[2..3] = UNDEF
    assert_equal [255, UNDEF, 7],   seconds(t.blocks(2).min)
    assert_equal [255, UNDEF, UNDEF], seconds(t.blocks(2).min(min_count: 2))
    assert_equal [255, 256, 7],
                 seconds(t.blocks(2).min(fill_value: t[0]))
  end

  def test_blocks_min_on_a_const_string
    s = CArray.const_string(["ab", "dd", nil, nil, "zz", "cd"])
    r = s.blocks(2).min
    assert_kind_of CAConstString, r
    assert_equal ["ab", UNDEF, "cd"], r.to_a
    assert_equal ["dd", UNDEF, "zz"], s.blocks(2).max.to_a
  end

  def test_blocks_min_on_a_time_grid
    d = CArray.time(%w[2024-01-01 2024-01-03 2024-01-02
                       2024-01-04 2024-02-01 2024-01-05], unit: :D).reshape(2, 3)
    r = d.blocks(2, 2).min
    assert_kind_of CATime, r
    assert_equal [1, 2], r.shape
    assert_equal %w[2024-01-01 2024-01-02], r.to_a.flatten.map(&:to_s)
  end

  def test_blocks_min_refuses_a_categorical
    c = CA_OBJECT(%w[ab dd cd ee]).categorize
    assert_raise(ArgumentError) { c.blocks(2).min }
  end

end
