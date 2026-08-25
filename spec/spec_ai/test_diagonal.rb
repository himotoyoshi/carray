require "test/unit"
require "carray"

# Tests for CArray#diagonal: CAStride view of a parent's diagonal.
# NumPy-parity API: positional or `offset:` for the diagonal shift,
# `axis: [i, j]` for the two axes that collapse into the diagonal.

class TestDiagonal < Test::Unit::TestCase

  def test_method_defined
    assert(CArray.instance_methods.include?(:diagonal))
  end

  def test_returns_castride
    a = CArray.float64(3, 4).seq
    assert_kind_of(CAStride, a.diagonal)
  end

  # ---- 2D main diagonal ----

  def test_2d_main_diagonal
    a = CArray.float64(3, 4).seq      # row-major 0..11
    d = a.diagonal
    assert_equal([3], d.shape)
    assert_equal([0.0, 5.0, 10.0], d.to_a)
  end

  def test_2d_square_main_diagonal
    a = CArray.float64(4, 4).seq
    d = a.diagonal
    assert_equal([4], d.shape)
    assert_equal([0.0, 5.0, 10.0, 15.0], d.to_a)
  end

  def test_2d_tall_matrix
    a = CArray.float64(5, 3).seq
    d = a.diagonal
    # min(5, 3) = 3
    assert_equal([3], d.shape)
    assert_equal([0.0, 4.0, 8.0], d.to_a)
  end

  # ---- 2D offset (super-diagonal) ----

  def test_2d_super_diagonal_1
    a = CArray.float64(3, 4).seq
    assert_equal([1.0, 6.0, 11.0], a.diagonal(1).to_a)
  end

  def test_2d_super_diagonal_2
    a = CArray.float64(3, 4).seq
    assert_equal([2.0, 7.0], a.diagonal(2).to_a)
  end

  def test_2d_super_diagonal_3
    a = CArray.float64(3, 4).seq
    assert_equal([3.0], a.diagonal(3).to_a)
  end

  def test_2d_offset_out_of_range_returns_empty
    a = CArray.float64(3, 4).seq
    assert_equal([0], a.diagonal(4).shape)
    assert_equal([0], a.diagonal(100).shape)
  end

  # ---- 2D offset (sub-diagonal) ----

  def test_2d_sub_diagonal_minus_1
    a = CArray.float64(3, 4).seq
    assert_equal([4.0, 9.0], a.diagonal(-1).to_a)
  end

  def test_2d_sub_diagonal_minus_2
    a = CArray.float64(3, 4).seq
    assert_equal([8.0], a.diagonal(-2).to_a)
  end

  def test_2d_sub_diagonal_out_of_range_returns_empty
    a = CArray.float64(3, 4).seq
    assert_equal([0], a.diagonal(-3).shape)
  end

  # ---- offset via keyword ----

  def test_offset_as_keyword
    a = CArray.float64(3, 4).seq
    assert_equal(a.diagonal(1).to_a,  a.diagonal(offset: 1).to_a)
    assert_equal(a.diagonal(-1).to_a, a.diagonal(offset: -1).to_a)
  end

  def test_error_both_positional_and_keyword
    a = CArray.float64(3, 4).seq
    assert_raise(ArgumentError) { a.diagonal(1, offset: 1) }
  end

  # ---- strides / byte_offset ----

  def test_2d_strides_and_offset
    a = CArray.float64(3, 4).seq      # bytes=8, strides parent = [32, 8]
    d = a.diagonal
    assert_equal([8 + 32], d.strides)  # next row + next col
    assert_equal(0, d.byte_offset)
  end

  def test_2d_super_diagonal_strides_and_offset
    a = CArray.float64(3, 4).seq
    d = a.diagonal(1)
    assert_equal([40], d.strides)
    assert_equal(8, d.byte_offset)       # start at col 1
  end

  def test_2d_sub_diagonal_strides_and_offset
    a = CArray.float64(3, 4).seq
    d = a.diagonal(-1)
    assert_equal([40], d.strides)
    assert_equal(32, d.byte_offset)      # start at row 1
  end

  # ---- write-through ----

  def test_write_propagates
    a = CArray.float64(3, 4).seq
    d = a.diagonal
    d[1] = -100.0
    assert_equal(-100.0, a[1, 1])
    assert_equal(0.0, a[0, 0])
  end

  # ---- 3D ----

  def test_3d_default_axes
    # axes default to [0, 1]; result shape: [kept (axis 2), diag]
    b = CArray.float64(2, 3, 4).seq
    d = b.diagonal
    assert_equal([4, 2], d.shape)
    # d[k, p] == b[p, p, k]
    4.times do |k|
      2.times do |p|
        assert_equal(b[p, p, k], d[k, p])
      end
    end
  end

  def test_3d_axes_0_2
    b = CArray.float64(2, 3, 4).seq
    d = b.diagonal(axis: [0, 2])
    # diag of (axis 0, axis 2): min(2, 4) = 2
    # kept: axis 1 = 3
    assert_equal([3, 2], d.shape)
    # d[j, p] == b[p, j, p]
    3.times do |j|
      2.times do |p|
        assert_equal(b[p, j, p], d[j, p])
      end
    end
  end

  def test_3d_axes_1_2
    b = CArray.float64(2, 3, 4).seq
    d = b.diagonal(axis: [1, 2])
    # diag of (axis 1, axis 2): min(3, 4) = 3
    # kept: axis 0 = 2
    assert_equal([2, 3], d.shape)
    # d[i, p] == b[i, p, p]
    2.times do |i|
      3.times do |p|
        assert_equal(b[i, p, p], d[i, p])
      end
    end
  end

  def test_3d_axes_with_offset
    b = CArray.float64(3, 4, 5).seq
    d = b.diagonal(1, axis: [0, 1])
    # diag of (3, 4) with offset 1: min(3, 4-1)=3
    # kept axis 2: 5
    assert_equal([5, 3], d.shape)
    # d[k, p] == b[p, p+1, k]
    5.times do |k|
      3.times do |p|
        assert_equal(b[p, p+1, k], d[k, p])
      end
    end
  end

  def test_3d_axes_negative_indices
    b = CArray.float64(2, 3, 4).seq
    assert_equal(b.diagonal(axis: [0, 2]).to_a,
                 b.diagonal(axis: [-3, -1]).to_a)
  end

  # ---- reductions over diagonal ----

  def test_trace_via_diagonal_sum
    # trace = sum of main diagonal
    a = CArray.float64(4, 4).seq
    assert_in_delta(0 + 5 + 10 + 15, a.diagonal.sum, 1e-12)
  end

  # ---- data_type ----

  def test_int32_data_type
    a = CArray.int32(3, 3).seq
    d = a.diagonal
    assert_equal(CA_INT32, d.data_type)
    assert_equal([0, 4, 8], d.to_a)
  end

  # ---- errors ----

  def test_error_ndim_less_than_2
    a = CArray.float64(5)
    assert_raise(ArgumentError) { a.diagonal }
  end

  def test_error_axis_wrong_length
    a = CArray.float64(3, 4)
    assert_raise(ArgumentError) { a.diagonal(axis: [0]) }
    assert_raise(ArgumentError) { a.diagonal(axis: [0, 1, 2]) }
  end

  def test_error_axis_duplicate
    a = CArray.float64(3, 4)
    assert_raise(ArgumentError) { a.diagonal(axis: [0, 0]) }
    assert_raise(ArgumentError) { a.diagonal(axis: [1, -1]) }   # -1 == 1
  end

  def test_error_axis_out_of_range
    a = CArray.float64(3, 4)
    assert_raise(ArgumentError) { a.diagonal(axis: [0, 2]) }
    assert_raise(ArgumentError) { a.diagonal(axis: [-3, 0]) }
  end

  def test_error_too_many_positional_args
    a = CArray.float64(3, 4)
    assert_raise(ArgumentError) { a.diagonal(1, 2) }
  end

  def test_error_unknown_keyword
    a = CArray.float64(3, 4)
    assert_raise(ArgumentError) { a.diagonal(foo: 1) }
  end
end
