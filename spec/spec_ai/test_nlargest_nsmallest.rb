# ----------------------------------------------------------------------------
#
#  spec_ai/test_nlargest_nsmallest.rb
#
#  Tests for the nlargest / nsmallest / nlargest_index / nsmallest_index
#  family (lib/carray/ordering.rb).  3.0 refactor: previous per-cell
#  UNDEF-mutation Ruby loop (O(n*N)) replaced by partition_index_ki +
#  sort_index (O(N) average + O(n log n)).
#
#  Flat addresses idiom: a.flatten.nlargest_index(n, axis: 0).
#  No dedicated _addr method (= degenerate axis-less form rejected
#  per CLAUDE.md _addr convention).
#
# ----------------------------------------------------------------------------

$LOAD_PATH.unshift File.expand_path("../../../ext", __FILE__)
$LOAD_PATH.unshift File.expand_path("../../../lib", __FILE__)
require "carray"
require "test/unit"

class TestNlargestNsmallest < Test::Unit::TestCase

  def test_nlargest_basic
    a = CA_FLOAT64([5, 1, 4, 2, 3])
    assert_equal [5.0, 4.0, 3.0], a.nlargest(3).to_a
  end

  def test_nlargest_flat_positions_idiom
    a = CA_FLOAT64([5, 1, 4, 2, 3])
    # Sorted desc by value: 5@0, 4@2, 3@4
    assert_equal [0, 2, 4], a.flatten.nlargest_index(3, axis: 0).to_a
  end

  def test_nsmallest_basic
    a = CA_FLOAT64([5, 1, 4, 2, 3])
    assert_equal [1.0, 2.0], a.nsmallest(2).to_a
  end

  def test_nsmallest_flat_positions_idiom
    a = CA_FLOAT64([5, 1, 4, 2, 3])
    # Sorted asc: 1@1, 2@3
    assert_equal [1, 3], a.flatten.nsmallest_index(2, axis: 0).to_a
  end

  def test_n_greater_than_elements_returns_all
    a = CA_FLOAT64([3, 1, 2])
    assert_equal [3.0, 2.0, 1.0], a.nlargest(10).to_a
    assert_equal [1.0, 2.0, 3.0], a.nsmallest(10).to_a
  end

  def test_n_equals_elements_returns_full_sort
    a = CA_FLOAT64([3, 1, 4, 1, 5, 9, 2, 6])
    assert_equal a.sort.reverse.to_a, a.nlargest(a.elements).to_a
    assert_equal a.sort.to_a,         a.nsmallest(a.elements).to_a
  end

  def test_n_zero_returns_empty
    a = CA_FLOAT64([1, 2, 3])
    assert_equal [], a.nlargest(0).to_a
    assert_equal [], a.nsmallest(0).to_a
  end

  def test_empty_self
    a = CA_FLOAT64([])
    assert_equal [], a.nlargest(3).to_a
    assert_equal [], a.nsmallest(3).to_a
    assert_equal [], a.flatten.nlargest_index(3, axis: 0).to_a
  end

  def test_multidim_self_flattened
    # 2-D self gets flattened internally; result is 1-D
    a = CA_FLOAT64([[5, 1, 4], [2, 3, 6]])
    assert_equal [6.0, 5.0, 4.0], a.nlargest(3).to_a
    # flat positions via the documented idiom
    # values: 5@0, 1@1, 4@2, 2@3, 3@4, 6@5  ->  top 3: 6@5, 5@0, 4@2
    assert_equal [5, 0, 2], a.flatten.nlargest_index(3, axis: 0).to_a
  end

  def test_nlargest_with_ties
    a = CA_FLOAT64([3, 1, 3, 2, 3])
    # 3 occurs at addrs 0, 2, 4; top 3 should be those.
    addrs = a.flatten.nlargest_index(3, axis: 0).to_a.sort
    assert_equal [0, 2, 4], addrs
  end

  def test_value_output_data_type_matches_self
    # Values are gathered via self.flatten[addrs], so data_type = self's
    a = CA_INT32([5, 1, 4, 2, 3])
    assert_equal CA_INT32, a.nlargest(3).data_type
  end

  # ---- per-axis (axis: kwarg) ------------------------------------------

  def test_nlargest_axis_0
    # columns: [5,1,7,2], [2,9,4,8], [8,3,6,1]
    b = CA_INT32([[5, 2, 8], [1, 9, 3], [7, 4, 6], [2, 8, 1]])
    assert_equal [[7, 9, 8], [5, 8, 6]], b.nlargest(2, axis: 0).to_a
  end

  def test_nlargest_axis_1
    b = CA_INT32([[5, 2, 8], [1, 9, 3], [7, 4, 6], [2, 8, 1]])
    assert_equal [[8, 5], [9, 3], [7, 6], [8, 2]],
                 b.nlargest(2, axis: 1).to_a
  end

  def test_nsmallest_axis_0
    b = CA_INT32([[5, 2, 8], [1, 9, 3], [7, 4, 6], [2, 8, 1]])
    assert_equal [[1, 2, 1], [2, 4, 3]], b.nsmallest(2, axis: 0).to_a
  end

  def test_nsmallest_axis_1
    b = CA_INT32([[5, 2, 8], [1, 9, 3], [7, 4, 6], [2, 8, 1]])
    assert_equal [[2, 5], [1, 3], [4, 6], [1, 2]],
                 b.nsmallest(2, axis: 1).to_a
  end

  def test_nlargest_index_axis
    # col 0: values [5,1,7,2] -> sorted desc = [7,5], at positions [2,0]
    # col 1: values [2,9,4,8] -> sorted desc = [9,8], at positions [1,3]
    # col 2: values [8,3,6,1] -> sorted desc = [8,6], at positions [0,2]
    b = CA_INT32([[5, 2, 8], [1, 9, 3], [7, 4, 6], [2, 8, 1]])
    assert_equal [[2, 1, 0], [0, 3, 2]],
                 b.nlargest_index(2, axis: 0).to_a
  end

  def test_nsmallest_index_axis
    b = CA_INT32([[5, 2, 8], [1, 9, 3], [7, 4, 6], [2, 8, 1]])
    # col 0 asc positions of [1,2]: [1,3]; col 1 of [2,4]: [0,2]; col 2 of [1,3]: [3,1]
    assert_equal [[1, 0, 3], [3, 2, 1]],
                 b.nsmallest_index(2, axis: 0).to_a
  end

  def test_axis_full_sort_fallback
    # cap >= dim[axis] takes the full-sort path
    b = CA_INT32([[5, 2, 8], [1, 9, 3], [7, 4, 6], [2, 8, 1]])
    full_desc = b.nlargest(10, axis: 0)
    assert_equal [4, 3], full_desc.shape   # capped at dim[0] = 4
    assert_equal [[7, 9, 8], [5, 8, 6], [2, 4, 3], [1, 2, 1]],
                 full_desc.to_a
  end

  def test_axis_cap_zero_returns_empty
    b = CArray.int32(4, 3)
    r = b.nlargest(0, axis: 0)
    assert_equal [0, 3], r.shape
  end

  def test_axis_negative
    b = CA_INT32([[5, 2, 8], [1, 9, 3], [7, 4, 6], [2, 8, 1]])
    assert_equal b.nlargest(2, axis: 1).to_a,
                 b.nlargest(2, axis: -1).to_a
  end

  def test_axis_oor_raises
    b = CArray.int32(2, 3)
    assert_raise(ArgumentError) { b.nlargest(2, axis: 5) }
    assert_raise(ArgumentError) { b.nsmallest_index(2, axis: -3) }
  end

  def test_axis_3d
    # 2x3x4 cube, top-2 along axis 2
    c = CArray.int32(2, 3, 4) { |i, j, k| (i + 1) * 100 + (j + 1) * 10 + k }
    r = c.nlargest(2, axis: 2)
    assert_equal [2, 3, 2], r.shape
    # Each axis-2 fiber is monotonically increasing in k, so top-2 desc
    # = [k=3, k=2] of original = (i+1)*100 + (j+1)*10 + {3, 2}
    expected = Array.new(2) do |i|
      Array.new(3) do |j|
        base = (i + 1) * 100 + (j + 1) * 10
        [base + 3, base + 2]
      end
    end
    assert_equal expected, r.to_a
  end

end
