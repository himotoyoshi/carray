# spec_ai/test_caremap_bounds.rb
#
# `a[i]` with an index array of a's own shape (CARemap) takes the indices
# as they are at the call and checks them then, as every other index form
# does: a negative index counts from the end of a.flatten, and one out of
# range raises IndexError from `a[i]` itself.

require "test/unit"
require "carray"

class TestCARemapBounds < Test::Unit::TestCase

  def setup
    @a = CArray.int32(4, 4).seq!
    @i = CArray.int64(4, 4) { 0 }
  end

  def test_in_range
    @i[-1] = 15
    v = @a[@i]
    assert_kind_of CARemap, v
    assert_equal 15, v[3, 3]
    assert_equal 0, v[0, 0]
  end

  def test_negative_counts_from_the_end
    @i[-1] = -1
    assert_equal 15, @a[@i][3, 3]
    assert_equal 15, @a[@i].to_a.last.last
  end

  def test_out_of_range_raises_when_made
    [16, 1 << 40, -17].each do |bad|
      @i[-1] = bad
      assert_raise(IndexError, bad.to_s) { @a[@i] }
      assert_raise(IndexError, bad.to_s) { @a[@i] = 7 }
    end
    assert_equal (0..15).to_a, @a.to_a.flatten
  end

  def test_index_changed_after_view_is_not_read
    v = @a[@i]
    assert_equal 0, v[3, 3]
    @i[-1] = 99
    assert_equal 0, v[3, 3]
  end

end
