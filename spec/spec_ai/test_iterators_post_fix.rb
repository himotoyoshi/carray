require "test/unit"
require_relative "../../lib/carray"

# ca_iter_*.c の initialize_copy 修正後の動作確認テスト
#
# 修正前は copy.each や @iter の each が segfault していたが、
# 修正後は dup した copy が完全に機能することを確認する。

class TestCABlockIteratorDupFull < Test::Unit::TestCase

  def setup
    @a = CArray.int(6).tap { |__a| __a[] = [1, 2, 3, 4, 5, 6] }
    @iter = @a.blocks(0..1)   # 2要素ブロック × 3個
  end

  def test_dup_copy_each_works
    copy = @iter.dup
    results = []
    copy.each { |blk| results << blk.to_a }
    assert_equal [[1, 2], [3, 4], [5, 6]], results
  end

  def test_original_still_works_after_dup
    copy = @iter.dup
    _ = copy   # use copy
    results = []
    @iter.each { |blk| results << blk.to_a }
    assert_equal [[1, 2], [3, 4], [5, 6]], results
  end

  def test_copy_and_original_iterate_independently
    copy = @iter.dup
    orig_results = []
    copy_results = []
    @iter.each { |blk| orig_results << blk.to_a }
    copy.each  { |blk| copy_results << blk.to_a }
    assert_equal orig_results, copy_results
  end

end

class TestCAWindowIteratorDupFull < Test::Unit::TestCase

  def setup
    @a = CArray.int(6).tap { |__a| __a[] = [1, 2, 3, 4, 5, 6] }
    @ker = @a.window(-1..1)
    @iter = CAWindowIterator.new(@ker)
  end

  def test_dup_copy_each_works
    copy = @iter.dup
    results = []
    copy.each { |w| results << w.to_a }
    # 幅3の窓、両端は境界外なのでデフォルト値(0)が入る
    assert_equal 6, results.size
    assert_equal [0, 1, 2], results[0]   # 左端: 境界外=0, 1, 2
    assert_equal [1, 2, 3], results[1]
    assert_equal [4, 5, 6], results[4]
    assert_equal [5, 6, 0], results[5]   # 右端: 5, 6, 境界外=0
  end

  def test_original_still_works_after_dup
    copy = @iter.dup
    _ = copy
    results = []
    @iter.each { |w| results << w.to_a }
    assert_equal 6, results.size
    assert_equal [1, 2, 3], results[1]
  end

end

# SI.3: CADimensionIterator -> CASlabIterator.  :> marks the slab axis;
# the yielded slab is the 1-D row directly (no length-1 outer axis), so
# row.to_a is flat [..], not [[..]].
class TestCASlabIteratorDupFull < Test::Unit::TestCase

  def setup
    @a = CArray.int(3, 4).tap { |__a| __a[] = [*1..12] }
    @iter = @a[nil, :>]   # row iterator (slab axis 1, outer axis 0)
  end

  def test_dup_copy_each_works
    copy = @iter.dup
    results = []
    copy.each { |row| results << row.to_a }
    assert_equal [[1, 2, 3, 4], [5, 6, 7, 8], [9, 10, 11, 12]], results
  end

  def test_original_still_works_after_dup
    copy = @iter.dup
    _ = copy
    results = []
    @iter.each { |row| results << row.to_a }
    assert_equal [[1, 2, 3, 4], [5, 6, 7, 8], [9, 10, 11, 12]], results
  end

  def test_copy_and_original_iterate_independently
    copy = @iter.dup
    orig_results = []
    copy_results = []
    @iter.each { |row| orig_results << row.to_a }
    copy.each  { |row| copy_results << row.to_a }
    assert_equal orig_results, copy_results
  end

end
