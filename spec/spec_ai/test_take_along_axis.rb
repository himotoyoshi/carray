# ----------------------------------------------------------------------------
#
#  spec_ai/test_take_along_axis.rb
#
#  Tests for PROPOSAL_TAKE_ALONG_AXIS T.1+T.2:
#    - CArray#take_along_axis(indices, axis: k)
#    - CArray#put_along_axis(indices, values, axis: k)
#
#  Sparring round 1 verdict (Q1-Q5, recommended defaults):
#    Q1 = (A) strict shape (indices.ndim == self.ndim, dim equality
#         except axis)
#    Q2 = (a) raise RangeError on OOB
#    Q3 = (a) accept Python-style negative indices
#    Q4 = (a) accept any Integer kind, cast to CA_SIZE internally
#    Q5 = last-write-wins for put_along_axis duplicate indices
#
# ----------------------------------------------------------------------------

$LOAD_PATH.unshift File.expand_path("../../../ext", __FILE__)
$LOAD_PATH.unshift File.expand_path("../../../lib", __FILE__)
require "carray"
require "test/unit"

class TestTakeAlongAxis < Test::Unit::TestCase

  # ---- 1-D ----------------------------------------------------------------

  def test_1d_basic
    a = CA_FLOAT64([10, 20, 30, 40, 50])
    idx = CA_INT([1, 3, 0])
    assert_equal [20.0, 40.0, 10.0], a.take_along_axis(idx).to_a
  end

  def test_1d_default_axis_0
    a = CA_FLOAT64([10, 20, 30])
    assert_equal a.take_along_axis(CA_INT([2,0,1])).to_a,
                 a.take_along_axis(CA_INT([2,0,1]), axis: 0).to_a
  end

  # ---- 2-D ----------------------------------------------------------------

  def test_2d_axis_1_per_row
    a = CA_FLOAT64([[10,20,30],[40,50,60]])
    idx = CA_INT([[2,0],[1,2]])
    assert_equal [[30.0,10.0],[50.0,60.0]],
                 a.take_along_axis(idx, axis: 1).to_a
  end

  def test_2d_axis_0_per_col
    a = CA_FLOAT64([[10,20,30],[40,50,60]])
    idx = CA_INT([[1,0,1]])  # shape [1, 3]
    assert_equal [[40.0, 20.0, 60.0]],
                 a.take_along_axis(idx, axis: 0).to_a
  end

  def test_2d_axis_negative
    a = CA_FLOAT64([[10,20,30],[40,50,60]])
    idx = CA_INT([[2,0,1],[1,2,0]])
    assert_equal a.take_along_axis(idx, axis: 1).to_a,
                 a.take_along_axis(idx, axis: -1).to_a
  end

  # ---- 3-D ----------------------------------------------------------------

  def test_3d_axis_2
    a = CArray.float64(2,3,4).seq!
    idx = CA_INT([[[0,1],[2,3],[0,2]],[[1,0],[3,2],[1,3]]])
    expected = [[[0.0,1.0],[6.0,7.0],[8.0,10.0]],
                [[13.0,12.0],[19.0,18.0],[21.0,23.0]]]
    assert_equal expected, a.take_along_axis(idx, axis: 2).to_a
  end

  # ---- shape rule (Q1 strict) --------------------------------------------

  def test_shape_rule_ndim_mismatch_raises
    a = CA_FLOAT64([[1,2],[3,4]])
    idx_1d = CA_INT([0, 1])
    assert_raise(ArgumentError) { a.take_along_axis(idx_1d, axis: 1) }
  end

  def test_shape_rule_non_axis_dim_mismatch_raises
    a = CA_FLOAT64([[1,2,3],[4,5,6]])
    idx = CA_INT([[0,1],[1,0],[0,0]])  # dim[0]=3 != self.dim[0]=2
    assert_raise(ArgumentError) { a.take_along_axis(idx, axis: 1) }
  end

  def test_shape_axis_dim_free
    a = CA_FLOAT64([[10,20,30],[40,50,60]])
    # axis 1, indices.dim[1] = 1 (different from self.dim[1]=3) is OK
    assert_equal [[10.0],[40.0]],
                 a.take_along_axis(CA_INT([[0],[0]]), axis: 1).to_a
    # axis 1, indices.dim[1] = 5 (greater than self.dim[1]=3) is OK
    idx5 = CA_INT([[0,1,2,1,0],[2,1,0,1,2]])
    assert_equal [[10.0,20.0,30.0,20.0,10.0],[60.0,50.0,40.0,50.0,60.0]],
                 a.take_along_axis(idx5, axis: 1).to_a
  end

  # ---- axis OOR ----------------------------------------------------------

  def test_axis_out_of_range_raises
    a = CA_FLOAT64([1,2,3])
    # axis2addr (= C side) raises IndexError, same convention as
    # min_addr / min_index / sort_addr (= per-axis kernel family).
    assert_raise(IndexError) { a.take_along_axis(CA_INT([0]), axis: 5) }
    assert_raise(IndexError) { a.take_along_axis(CA_INT([0]), axis: -5) }
  end

  # ---- OOB (Q2 raise) ----------------------------------------------------

  def test_oob_positive_raises
    a = CA_FLOAT64([10,20,30])
    assert_raise(RangeError) { a.take_along_axis(CA_INT([5])) }
  end

  def test_oob_negative_after_normalize_raises
    a = CA_FLOAT64([10,20,30])
    assert_raise(RangeError) { a.take_along_axis(CA_INT([-10])) }
  end

  # ---- negative indices (Q3 accept) --------------------------------------

  def test_negative_indices_normalized
    a = CA_FLOAT64([10,20,30,40,50])
    assert_equal [50.0,40.0,10.0],
                 a.take_along_axis(CA_INT([-1,-2,0])).to_a
  end

  def test_negative_indices_2d
    a = CA_FLOAT64([[10,20,30],[40,50,60]])
    idx = CA_INT([[-1,-2,-3],[-3,-2,-1]])
    assert_equal [[30.0,20.0,10.0],[40.0,50.0,60.0]],
                 a.take_along_axis(idx, axis: 1).to_a
  end

  # ---- data_type acceptance (Q4 any Integer) ---------------------------------

  def test_data_type_int8_accepted
    a = CA_FLOAT64([10,20,30])
    assert_equal [20.0], a.take_along_axis(CA_INT8([1])).to_a
  end

  def test_data_type_int32_accepted
    a = CA_FLOAT64([10,20,30])
    assert_equal [30.0], a.take_along_axis(CA_INT32([2])).to_a
  end

  def test_data_type_size_accepted
    a = CA_FLOAT64([10,20,30])
    assert_equal [10.0], a.take_along_axis(CA_SIZE([0])).to_a
  end

  # ---- *_index family direct consumption ---------------------------------

  def test_min_index_axis_consumption
    a = CA_FLOAT64([[5,1,3],[2,9,4]])
    mi = a.min_index(axis: 1).reshape(2, 1)
    assert_equal [[1.0],[2.0]], a.take_along_axis(mi, axis: 1).to_a
  end

  def test_max_index_axis_consumption
    a = CA_FLOAT64([[5,1,3],[2,9,4]])
    mi = a.max_index(axis: 1).reshape(2, 1)
    assert_equal [[5.0],[9.0]], a.take_along_axis(mi, axis: 1).to_a
  end

  def test_sort_index_axis_consumption_full_sort
    a = CA_FLOAT64([[5,1,3],[2,9,4]])
    si = a.sort_index(axis: 1)
    sorted = a.take_along_axis(si, axis: 1)
    assert_equal [[1.0,3.0,5.0],[2.0,4.0,9.0]], sorted.to_a
  end

  # ---- put_along_axis ----------------------------------------------------

  def test_put_along_axis_basic
    a = CArray.float64(2,3).seq!
    a.put_along_axis(CA_INT([[2,0,1],[1,2,0]]),
                     CA_FLOAT64([[99,98,97],[96,95,94]]),
                     axis: 1)
    assert_equal [[98.0,97.0,99.0],[94.0,96.0,95.0]], a.to_a
  end

  def test_put_along_axis_round_trip
    a = CArray.float64(3,4).seq!
    idx = CA_INT([[1,2],[0,3],[2,1]])
    vals = CA_FLOAT64([[100,200],[300,400],[500,600]])
    a.put_along_axis(idx, vals, axis: 1)
    got = a.take_along_axis(idx, axis: 1)
    assert_equal vals.to_a, got.to_a
  end

  def test_put_along_axis_returns_self
    a = CArray.float64(2,3).seq!
    assert_same a, a.put_along_axis(CA_INT([[0,0,0],[0,0,0]]),
                                     CA_FLOAT64([[1,2,3],[4,5,6]]),
                                     axis: 1)
  end

  def test_put_along_axis_last_write_wins
    # Q5: duplicate indices in same fiber -> last-write-wins (inherited
    # from view[]= semantics).
    a = CA_FLOAT64([0.0, 0.0, 0.0])
    # idx [0, 0, 0] all target position 0; values [10, 20, 30].
    # Last-write-wins: a[0] ends up == 30.0.
    a.put_along_axis(CA_INT([0,0,0]), CA_FLOAT64([10,20,30]))
    assert_equal 30.0, a[0]
  end

end
