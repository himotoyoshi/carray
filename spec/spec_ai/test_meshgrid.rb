# CArray.meshgrid coordinate vectors go through CArray.wrap_readonly, so an
# axis may be given as anything that entry point accepts (Array, Numeric,
# MemoryView producer, an object answering ca / to_ca), not just a CArray.
# No target type is imposed: each axis keeps its own data type, and a CArray
# axis is passed through untouched.  Anything that does not land as a 1-D
# array is rejected up front rather than producing a misshapen grid.

require "test/unit"
require "carray"

class TestMeshgrid < Test::Unit::TestCase

  def test_carray_axes_are_passed_through
    x = CA_FLOAT64([1.0, 2.0, 3.0])
    y = CA_FLOAT64([10.0, 20.0])
    xx, yy = CArray.meshgrid(x, y, copy: false)
    assert_equal [2, 3], xx.shape
    assert_equal [2, 3], yy.shape
    assert_equal [[1.0, 2.0, 3.0], [1.0, 2.0, 3.0]], xx.to_a
    assert_equal [[10.0, 10.0, 10.0], [20.0, 20.0, 20.0]], yy.to_a
  end

  def test_array_axis_accepted
    xx, yy = CArray.meshgrid([1, 2, 3], [10, 20])
    assert_equal [2, 3], xx.shape
    assert_equal [[1, 2, 3], [1, 2, 3]], xx.to_a
    assert_equal [[10, 10, 10], [20, 20, 20]], yy.to_a
  end

  def test_each_axis_keeps_its_own_data_type
    xx, yy = CArray.meshgrid(CA_INT32([1, 2, 3]), CA_FLOAT64([10.0, 20.0]))
    assert_equal :int32, xx.data_type
    assert_equal :float64, yy.data_type
  end

  def test_mixed_carray_and_array_axes
    xx, yy = CArray.meshgrid(CA_INT32([1, 2, 3]), [10, 20])
    assert_equal :int32, xx.data_type
    assert_equal [[10, 10, 10], [20, 20, 20]], yy.to_a
  end

  def test_numeric_axis_becomes_a_single_point
    xx, yy = CArray.meshgrid(CA_INT32([1, 2, 3]), 10)
    assert_equal [1, 3], xx.shape
    assert_equal [[10, 10, 10]], yy.to_a
  end

  def test_indexing_ij_with_coerced_axes
    xx, yy = CArray.meshgrid([1, 2, 3], [10, 20], indexing: "ij")
    assert_equal [3, 2], xx.shape
    assert_equal [[1, 1], [2, 2], [3, 3]], xx.to_a
    assert_equal [[10, 20], [10, 20], [10, 20]], yy.to_a
  end

  def test_sparse_with_coerced_axes
    xx, yy = CArray.meshgrid([1, 2, 3], [10, 20], copy: false, sparse: true)
    assert_equal [[1, 2, 3], [1, 2, 3]], (xx + CArray.int32(2, 3) { 0 }).to_a
    assert_equal [[10, 10, 10], [20, 20, 20]],
                 (yy + CArray.int32(2, 3) { 0 }).to_a
  end

  def test_range_axis_accepted
    xx, yy = CArray.meshgrid(0..2, 10..11)
    assert_equal [2, 3], xx.shape
    assert_equal [[0, 1, 2], [0, 1, 2]], xx.to_a
    assert_equal [[10, 10, 10], [11, 11, 11]], yy.to_a
  end

  def test_descending_range_axis
    xx, = CArray.meshgrid(3..0, 1..2)
    assert_equal [[3, 2, 1, 0], [3, 2, 1, 0]], xx.to_a
  end

  def test_float_range_axis_is_rejected
    # a float range is not iterable; CArray.linspace / span! build a float axis
    assert_raise(TypeError) { CArray.meshgrid(0.0..1.0, CA_INT32([1, 2])) }
  end

  def test_arithmetic_sequence_axis_accepted
    xx, yy = CArray.meshgrid((0..4).step(2), 1..2)
    assert_equal [2, 3], xx.shape
    assert_equal [[0, 2, 4], [0, 2, 4]], xx.to_a
    assert_equal [[1, 1, 1], [2, 2, 2]], yy.to_a
  end

  def test_float_axis_via_arithmetic_sequence
    xx, = CArray.meshgrid((0.0..1.0).step(0.5), 1..2)
    assert_equal [[0.0, 0.5, 1.0], [0.0, 0.5, 1.0]], xx.to_a
  end

  def test_endless_arithmetic_sequence_axis_is_rejected
    assert_raise(RangeError) { CArray.meshgrid((0..).step(2), 1..2) }
  end

  def test_non_1d_axis_is_rejected
    assert_raise(ArgumentError) do
      CArray.meshgrid(CA_INT32([[1, 2], [3, 4]]), [10, 20])
    end
  end

  def test_block_form_with_coerced_axes
    sum = CArray.meshgrid([1, 2, 3], [10, 20]) { |a, b| a + b }
    assert_equal [[11, 12, 13], [21, 22, 23]], sum.to_a
  end

end
