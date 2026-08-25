# ----------------------------------------------------------------------------
#
#  spec_ai/test_axis2addr.rb
#
#  Tests for CArray#axis2addr (= public API, ext/carray_sort_addr.c).
#  Converts per-fiber axis-local indices into view-flat addresses.
#
#  The same converter is used internally by take_along_axis and was
#  formerly a private method _take_along_axis_addrs.  Promoted to
#  public surface with full C-side validation.
#
# ----------------------------------------------------------------------------

$LOAD_PATH.unshift File.expand_path("../../../ext", __FILE__)
$LOAD_PATH.unshift File.expand_path("../../../lib", __FILE__)
require "carray"
require "test/unit"

class TestAxis2Addr < Test::Unit::TestCase

  def test_1d_identity
    # 1-D: axis2addr returns the indices themselves (= flat addr ==
    # axis-local position for 1-D arrays).
    a = CA_FLOAT64([10, 20, 30, 40, 50])
    idx = CA_INT([2, 0, 4, 1])
    assert_equal [2, 0, 4, 1], a.axis2addr(idx).to_a
  end

  def test_2d_axis_1_per_row
    a = CA_FLOAT64([[10, 20, 30], [40, 50, 60]])
    idx = CA_INT([[2, 0], [1, 2]])
    # row 0: cols 2,0 -> flat 2, 0
    # row 1: cols 1,2 -> flat 3+1=4, 3+2=5
    assert_equal [[2, 0], [4, 5]], a.axis2addr(idx, axis: 1).to_a
  end

  def test_2d_axis_0_per_col
    a = CA_FLOAT64([[10, 20, 30], [40, 50, 60]])
    idx = CA_INT([[1, 0, 1]])  # shape [1, 3]
    # col 0: row 1 -> flat 3
    # col 1: row 0 -> flat 1
    # col 2: row 1 -> flat 5
    assert_equal [[3, 1, 5]], a.axis2addr(idx, axis: 0).to_a
  end

  def test_3d_axis_2
    a = CArray.float64(2, 3, 4).seq!
    idx = CA_INT([[[0,1],[2,3],[0,2]],[[1,0],[3,2],[1,3]]])
    expected = [[[0,1],[6,7],[8,10]],[[13,12],[19,18],[21,23]]]
    assert_equal expected, a.axis2addr(idx, axis: 2).to_a
  end

  def test_default_axis_0
    a = CA_FLOAT64([10, 20, 30])
    assert_equal a.axis2addr(CA_INT([2,0,1])).to_a,
                 a.axis2addr(CA_INT([2,0,1]), axis: 0).to_a
  end

  def test_negative_axis
    a = CA_FLOAT64([[10, 20, 30], [40, 50, 60]])
    idx = CA_INT([[2, 0], [1, 2]])
    assert_equal a.axis2addr(idx, axis: 1).to_a,
                 a.axis2addr(idx, axis: -1).to_a
  end

  def test_negative_indices_normalized
    a = CA_FLOAT64([10, 20, 30, 40, 50])
    # -1 -> 4, -2 -> 3, etc.
    assert_equal [4, 3, 0], a.axis2addr(CA_INT([-1, -2, 0])).to_a
  end

  def test_oob_positive_raises
    a = CA_FLOAT64([10, 20, 30])
    assert_raise(RangeError) { a.axis2addr(CA_INT([5])) }
  end

  def test_oob_negative_after_normalize_raises
    a = CA_FLOAT64([10, 20, 30])
    assert_raise(RangeError) { a.axis2addr(CA_INT([-10])) }
  end

  def test_axis_out_of_range_raises
    a = CA_FLOAT64([1, 2, 3])
    assert_raise(IndexError) { a.axis2addr(CA_INT([0]), axis: 5) }
    assert_raise(IndexError) { a.axis2addr(CA_INT([0]), axis: -5) }
  end

  def test_ndim_mismatch_raises
    a = CA_FLOAT64([[1, 2], [3, 4]])
    assert_raise(ArgumentError) { a.axis2addr(CA_INT([0, 1]), axis: 1) }
  end

  def test_non_axis_dim_mismatch_raises
    a = CA_FLOAT64([[1, 2, 3], [4, 5, 6]])
    # dim[0]=3 != self.dim[0]=2
    assert_raise(ArgumentError) {
      a.axis2addr(CA_INT([[0,1],[1,0],[0,0]]), axis: 1)
    }
  end

  def test_indices_data_type_int8_accepted
    a = CA_FLOAT64([10, 20, 30, 40])
    assert_equal [1, 3], a.axis2addr(CA_INT8([1, 3])).to_a
  end

  def test_indices_data_type_int32_accepted
    a = CA_FLOAT64([10, 20, 30, 40])
    assert_equal [2], a.axis2addr(CA_INT32([2])).to_a
  end

  def test_indices_data_type_float_rejected
    a = CA_FLOAT64([10, 20, 30])
    assert_raise(ArgumentError) { a.axis2addr(CA_FLOAT64([1.0])) }
  end

  def test_pairs_with_min_index_for_direct_gather
    # axis2addr(min_index(axis: k), axis: k) == min_addr(axis: k)
    a = CA_FLOAT64([[5, 1, 3], [2, 9, 4]])
    pos = a.min_index(axis: 1).reshape(2, 1)
    addrs_via_axis2addr = a.axis2addr(pos, axis: 1).reshape(2)
    addrs_via_min_addr  = a.min_addr(axis: 1)
    assert_equal addrs_via_min_addr.to_a, addrs_via_axis2addr.to_a
  end

  def test_output_is_ca_size
    a = CA_FLOAT64([1, 2, 3])
    assert_equal CA_SIZE, a.axis2addr(CA_INT([0])).data_type
  end

end
