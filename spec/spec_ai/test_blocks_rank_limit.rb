# spec_ai/test_blocks_rank_limit.rb
#
# A block iterator views each tile through an array with one axis per tile
# position and one per cell in the tile: twice the source's rank.  So
# blocks reaches rank CA_RANK_MAX / 2 (8), and a source of higher rank is
# refused when the iterator is made, by blocks and with the reason, not at
# its first reduction by a method the caller did not call.

require "test/unit"
require "carray"

class TestBlocksRankLimit < Test::Unit::TestCase

  def test_the_highest_rank_blocks_reaches
    n = CA_RANK_MAX / 2
    a = CArray.float64(*[2] * n).seq!
    assert_equal a.sum, a.blocks(*[1] * n).sum.sum
    assert_equal [1] * n, a.blocks(*[2] * n).sum.shape
  end

  def test_a_higher_rank_is_refused_by_blocks
    n = CA_RANK_MAX / 2 + 1
    a = CArray.float64(*[2] * n).seq!
    e = assert_raise(ArgumentError) { a.blocks(*[1] * n) }
    assert_match(/\Ablocks: /, e.message)
    assert_match(/rank #{n}/, e.message)
    assert_match(/#{CA_RANK_MAX / 2}/, e.message)
    assert_no_match(/block_view/, e.message)
  end
end
