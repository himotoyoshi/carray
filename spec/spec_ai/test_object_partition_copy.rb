# partition_copy CA_OBJECT branch tests.
#
# PROPOSAL_MKKERNEL_OBJECT_DTYPE_BRANCH Phase 5b 第一段: partition_copy
# (= hand-written in ext/carray_order.c) に CA_OBJECT branch 追加。中身は
# Phase 2 で CA_OBJECT 対応済の partition_index_ki + take_along_axis + copy。
#
# median 内部 escape (= __median_axis_object / __median_flat_object) は
# partition_copy が masked input を reject するため keep、別途維持。
# 本 test は partition_copy 単独 primitive としての CA_OBJECT 動作確認。
#
# String 等 Comparable 任意型で sort property (= kth 位置の値が k-th smallest、
# 前 <= 後 >=) を確認。

require "test/unit"
require "carray"

class TestObjectPartitionCopy < Test::Unit::TestCase
  def test_numeric_object_partition_copy_full_perm
    # 9 cell shuffled, partition at kth=4 (= median position).
    a = CA_OBJECT([5, 2, 8, 1, 9, 3, 7, 4, 6])
    r = a.partition_copy(4)
    # NumPy contract: r[k] == sorted[k], r[0..k-1] all <= r[k], r[k+1..] all >= r[k]
    assert_equal 5, r[4]
    assert(r.to_a[0..3].all? { |v| v <= 5 })
    assert(r.to_a[5..].all? { |v| v >= 5 })
  end

  def test_object_partition_copy_axis
    b = CArray.object(3, 7) { |i, j| (i + 1) * 10 + (6 - j) }
    r = b.partition_copy(3, axis: 1)
    # Each row: kth=3 holds 4th-smallest, but full reorder check is OK here
    # since all rows are full perm.
    3.times do |i|
      row = r[i, nil].to_a
      assert_equal (10*(i+1)..16+10*i).to_a, row
    end
  end

  def test_string_partition_copy_odd
    s = CA_OBJECT(["foo", "bar", "baz", "qux", "abc"])
    r = s.partition_copy(2)
    sorted = ["abc", "bar", "baz", "foo", "qux"]
    assert_equal sorted[2], r[2]                  # kth = "baz"
    assert(r.to_a[0..1].all? { |v| v <= sorted[2] })
    assert(r.to_a[3..].all? { |v| v >= sorted[2] })
  end

  def test_string_partition_copy_even
    s = CA_OBJECT(["d", "b", "c", "a"])
    r = s.partition_copy(1)
    sorted = ["a", "b", "c", "d"]
    assert_equal sorted[1], r[1]
  end

  def test_object_partition_copy_returns_entity_not_view
    a = CA_OBJECT([3, 1, 2])
    r = a.partition_copy(1)
    # Entity = independent copy, mutating r does not affect a.
    r[0] = 999
    assert_equal 3, a[0]
  end

  def test_object_partition_copy_kth_negative_indexing
    a = CA_OBJECT([3, 1, 4, 1, 5, 9, 2, 6])
    # kth = -1 = last position = sorted[7] = 9 (max)
    r = a.partition_copy(-1)
    assert_equal 9, r[-1]
  end

  def test_object_partition_copy_masked_input_clusters_to_masked_position
    a = CA_OBJECT([1, 2, 3])
    a[1] = UNDEF                                # [1, UNDEF, 3]
    p_last = a.partition_copy(1)                # valid slice [1,3] kth=1 -> 3
    assert_equal([1, 3, UNDEF], p_last.to_a)
    assert_equal([false, false, true], p_last.mask.to_a)

    p_first = a.partition_copy(1, masked_position: :first)
    assert_equal([UNDEF, 1, 3], p_first.to_a)
    assert_equal([true, false, false], p_first.mask.to_a)
  end

  def test_object_partition_copy_view_input
    # Phase 2 partition_index_ki handles views; partition_copy CA_OBJECT
    # branch builds on that, so view input should work transparently.
    parent = CA_OBJECT([3, 1, 4, 1, 5, 9, 2, 6])
    view = parent[0..4]   # CABlock view, 5 elements
    r = view.partition_copy(2)
    sorted_view = [1, 1, 3, 4, 5]
    assert_equal sorted_view[2], r[2]
  end

  def test_object_partition_copy_mixed_numeric
    # Mixed Integer + Float + Rational: all Comparable via <=>
    require "bigdecimal"
    a = CA_OBJECT([3.5, 1, Rational(7, 2), 2])
    r = a.partition_copy(1)
    # sorted: [1, 2, 3.5, 7/2] (= 1 < 2 < 3.5 == 3.5 by Ruby <=>)
    assert(r[0] <= r[1])
    assert(r.to_a[2..].all? { |v| v >= r[1] })
  end
end
