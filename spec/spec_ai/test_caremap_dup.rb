# spec_ai/test_caremap_dup.rb
#
# A CARemap (`a.sort`, `a[i]` with an index array of a's own shape) can be
# duplicated.  `dup` and `clone` used to raise TypeError (allocator
# undefined).  The copy reads the same parent through the same index
# array, like the dup of any other view.  CARemap still has no allocator:
# Ruby cannot build one from nothing (test_caremap_skeleton.rb).

require "test/unit"
require "carray"

class TestCARemapDup < Test::Unit::TestCase

  def test_sort_dup_and_clone
    a = CA_FLOAT64([3, 1, 2])
    v = a.sort
    assert_kind_of CARemap, v
    [v.dup, v.clone].each do |d|
      assert_kind_of CARemap, d
      assert_equal [1.0, 2.0, 3.0], d.to_a
    end
  end

  def test_same_shape_index_dup_shares_parent_and_index
    a = CArray.int32(2, 3).seq!
    i = CArray.int64(2, 3) { 5 }
    v = a[i]
    d = v.dup
    assert_equal [[5] * 3] * 2, d.to_a
    a[1, 2] = 50                       # parent written: the copy sees it
    assert_equal [[50] * 3] * 2, d.to_a
    i[0, 0] = 0                        # index written: the copy sees it too
    assert_equal 0, d[0, 0]
    d[1, 1] = 7                        # writing through the copy reaches a
    assert_equal 7, a[1, 2]
  end

  def test_masked_parent
    a = CA_FLOAT64([3, 1, 2])
    a[0] = UNDEF
    d = a.sort.dup
    assert_equal a.sort.to_a, d.to_a
    assert_equal a.sort.is_masked.to_a, d.is_masked.to_a
  end

  def test_copy_survives_the_original_view
    a = CA_FLOAT64([3, 1, 2])
    d = a.sort.dup
    5.times { GC.start ; 10000.times { CArray.int64(3) { 1 } } }
    assert_equal [1.0, 2.0, 3.0], d.to_a
  end

  def test_clone_keeps_frozen
    v = CA_FLOAT64([3, 1, 2]).sort
    v.freeze
    assert v.clone.frozen?
    refute v.clone(freeze: false).frozen?
    refute v.dup.frozen?
  end

  def test_still_no_allocator
    assert_raise(TypeError) { CARemap.allocate }
  end

end
