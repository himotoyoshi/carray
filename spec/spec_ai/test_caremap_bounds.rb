# spec_ai/test_caremap_bounds.rb
#
# `a[i]` with an index array of a's own shape (CARemap) reads the index
# array each time it moves data, so the indices are checked then: a
# negative index counts from the end of a.flatten, and one out of range
# raises IndexError instead of reading or writing outside a.

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

  def test_read_out_of_range_raises
    @i[-1] = 16
    v = @a[@i]
    assert_raise(IndexError) { v.to_a }
    assert_raise(IndexError) { v[3, 3] }
    @i[-1] = 1 << 40
    assert_raise(IndexError) { v.to_a }
    @i[-1] = -17
    assert_raise(IndexError) { v.to_a }
  end

  def test_write_out_of_range_raises
    @i[-1] = 16
    v = @a[@i]
    assert_raise(IndexError) { v[] = 7 }
    assert_raise(IndexError) { v[3, 3] = 7 }
    assert_equal (0..15).to_a, @a.to_a.flatten
  end

  def test_index_changed_after_view_is_checked
    v = @a[@i]
    assert_equal 0, v[3, 3]
    @i[-1] = 99
    assert_raise(IndexError) { v.to_a }
  end

end
