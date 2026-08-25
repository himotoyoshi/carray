# frozen_string_literal: true
#
# SO.3 — partition family + sort_index kwarg surface tests
# (PROPOSAL_SORT_AXIS rev7).
#
# Pins:
#   - sort_index(axis: k) kwarg form delegates to sort_index_ki
#   - partition(kth, axis: k) returns CARemap view (= full sort
#     stronger contract; quickselect optimization is future work)
#   - partition_index(kth, axis: k) returns CA_SIZE fiber-local index
#     CArray (= full argsort)
#   - kth validation: -dim..dim-1 range, Array rejected
#   - NumPy-style negative kth counts from end

require "test/unit"
require "carray"

class TestPartitionAxis < Test::Unit::TestCase

  # ---- sort_index(axis:) kwarg surface ----------------------------------

  def test_sort_index_kwarg_matches_ki_positional
    a = CArray.int32(3, 4)
    [[4,2,3,1], [8,6,7,5], [12,10,11,9]].each_with_index do |row, i|
      row.each_with_index { |v, j| a[i, j] = v }
    end
    assert_equal(a.sort_index_ki(0).to_a, a.sort_index(axis: 0).to_a)
    assert_equal(a.sort_index_ki(1).to_a, a.sort_index(axis: 1).to_a)
  end

  def test_sort_index_default_axis_is_0
    a = CArray.int32(3, 4).seq
    # axis: defaults to 0
    assert_equal(a.sort_index_ki(0).to_a, a.sort_index.to_a)
  end

  def test_sort_index_negative_axis
    a = CArray.int32(2, 3)
    [[3,1,2], [6,5,4]].each_with_index do |row, i|
      row.each_with_index { |v, j| a[i, j] = v }
    end
    assert_equal(a.sort_index(axis: 1).to_a, a.sort_index(axis: -1).to_a)
  end

  # ---- partition(kth, axis: k) ------------------------------------------

  def test_partition_returns_caremap_view
    a = CArray.int32(2, 3)
    [[5,1,3], [6,2,4]].each_with_index do |row, i|
      row.each_with_index { |v, j| a[i, j] = v }
    end
    result = a.partition(1, axis: 1)
    assert_equal(CARemap, result.class)
    assert_equal([2, 3], result.dim.to_a)
  end

  def test_partition_kth_at_position_is_correctly_placed
    # For full sort (= rev7 minimal implementation), every position is
    # correctly placed.  Verify the kth position holds the kth-smallest.
    a = CArray.int32(3, 4)
    [[4,1,3,2], [8,5,7,6], [12,9,11,10]].each_with_index do |row, i|
      row.each_with_index { |v, j| a[i, j] = v }
    end
    p2 = a.partition(2, axis: 1)
    # Each row sorted; position 2 = 3rd smallest
    p2.dim[0].times do |i|
      row = (0...p2.dim[1]).map { |j| p2[i, j] }
      assert_equal(row.sort[2], p2[i, 2], "row #{i}: #{row}")
    end
  end

  def test_partition_negative_kth
    a = CArray.int32(5)
    [3, 1, 4, 1, 5].each_with_index { |v, i| a[i] = v }
    # kth = -1 means last position (= largest)
    assert_nothing_raised { a.partition(-1) }
    assert_nothing_raised { a.partition(-5) }
  end

  def test_partition_kth_out_of_range
    a = CArray.int32(4).seq
    assert_raise(ArgumentError) { a.partition(4) }      # = size
    assert_raise(ArgumentError) { a.partition(-5) }     # < -size
    assert_raise(ArgumentError) { a.partition(100) }
  end

  def test_partition_array_kth_rejected
    # SO.3+ (rev8): partition is now C-defined (rb_ca_partitioned_view)
    # which routes kth through NUM2SIZE, raising TypeError for non-Integer
    # arguments.  SO.3 (rev7) raised ArgumentError via Ruby validation.
    # Both indicate "bad kth type"; accept either for backward compat.
    a = CArray.int32(5).seq
    assert_raise(ArgumentError, TypeError) { a.partition([1, 2]) }
    assert_raise(ArgumentError, TypeError) { a.partition(CArray.int32(2).seq) }
  end

  # ---- partition_index(kth, axis: k) ------------------------------------

  def test_partition_index_returns_fiber_local_indices
    a = CArray.int32(2, 4)
    [[4,2,3,1], [8,6,7,5]].each_with_index do |row, i|
      row.each_with_index { |v, j| a[i, j] = v }
    end
    pi = a.partition_index(1, axis: 1)
    assert_kind_of(CArray, pi)
    assert_equal([2, 4], pi.dim.to_a)
    # For full sort (= rev7), output matches argsort.
    # Row 0: [4,2,3,1] sorted = [1,2,3,4] -> indices [3,1,2,0]
    assert_equal([3, 1, 2, 0], (0...pi.dim[1]).map { |j| pi[0, j] })
    assert_equal([3, 1, 2, 0], (0...pi.dim[1]).map { |j| pi[1, j] })
  end

  def test_partition_index_default_axis_is_0
    a = CArray.int32(4).seq
    assert_equal(a.partition_index(1, axis: 0).to_a,
                 a.partition_index(1).to_a)
  end

  def test_partition_index_kth_out_of_range
    a = CArray.int32(4).seq
    assert_raise(ArgumentError) { a.partition_index(4) }
    assert_raise(ArgumentError) { a.partition_index(-5) }
  end

  def test_partition_index_array_kth_rejected
    a = CArray.int32(5).seq
    # C kwarg trampoline routes kth through NUM2SIZE; Array -> TypeError.
    # Previously a Ruby wrapper raised ArgumentError explicitly; with the
    # wrapper removed (= direct C bind via mkkernel sort form), NUM2SIZE
    # is the type gate.
    assert_raise(TypeError) { a.partition_index([1, 2]) }
  end

  # ---- API consistency between sort/partition --------------------------

  def test_partition_with_any_kth_matches_sort_for_rev7
    # rev7 minimal: partition(kth, axis: k) == sort(axis: k) regardless
    # of kth (= full sort always satisfies partition contract).
    a = CArray.int32(3, 4)
    [[7,3,5,1], [8,4,6,2], [11,9,12,10]].each_with_index do |row, i|
      row.each_with_index { |v, j| a[i, j] = v }
    end
    expected = a.sort(axis: 1).to_a
    [0, 1, 2, 3, -1, -4].each do |kth|
      assert_equal(expected, a.partition(kth, axis: 1).to_a,
                   "partition(#{kth}, axis: 1) should equal sort(axis: 1) in rev7")
    end
  end

end
