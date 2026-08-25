require "test/unit"
require_relative "../../lib/carray"

# CABlockIterator 3.0 (Ruby, block_view decomposition).  A leading offset in a
# range block spec (a.blocks(2..4) = size-3 tiles starting at index 2) is
# absorbed by a zero-copy pre-slice; the remainder is covered by a present-only
# edge tile (ceil grid), a 3.0 change from the 2.0 engine's silent truncation.
class TestCABlockIteratorNonZeroStart < Test::Unit::TestCase

  def test_1d_offset_tiles_via_each
    a  = CArray.int32(10).seq
    it = a.blocks(2..4)                     # size-3 tiles from offset 2
    # a[2..9] = [2..9]; tiles [2,3,4], [5,6,7], and the partial edge [8,9,·]
    # yielded as a uniform size-3 tile with the OOB cell masked.
    via_each = it.each.map(&:to_a)
    assert_equal [[2, 3, 4], [5, 6, 7], [8, 9, UNDEF]], via_each
  end

  def test_1d_offset_named_reduction
    a = CArray.int32(10).seq
    # present-only sum: 2+3+4, 5+6+7, 8+9
    assert_equal [9, 18, 17], a.blocks(2..4).sum.to_a
  end

  def test_2d_offset_first_tile
    a  = CArray.int32(6, 6).seq
    it = a.blocks(2..3, 2..3)               # 2x2 tiles from (2,2)
    # a[2..5, 2..5] is 4x4 -> a 2x2 tile grid.  First tile covers rows 2-3,
    # cols 2-3: seq row2 = [12..17] -> [14,15]; row3 = [18..23] -> [20,21].
    assert_equal [[14, 15], [20, 21]], it.each.first.to_a
    assert_equal [2, 2], it.mean.shape
  end

  def test_zero_start_exact_unaffected
    a = CArray.int32(6).seq
    assert_equal [[0, 1], [2, 3], [4, 5]], a.blocks(0..1).each.map(&:to_a)
  end
end
