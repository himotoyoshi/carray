require "test/unit"
require "carray"

# Tests for CArray#sliding_windows (PROPOSAL_VECTORIZE_PATTERNS Pattern A).
# Parent shape [d0, d1, ...] becomes a CAStride view of shape
# [(d0 - w0)/s0 + 1, ..., w0, w1, ...].  Memory is shared with parent.

class TestSlidingWindows < Test::Unit::TestCase

  def test_method_defined
    assert(CArray.instance_methods.include?(:sliding_windows))
  end

  # ---- 1D ----

  def test_1d_basic_shape_and_strides
    src = CArray.float64(10).seq
    v = src.sliding_windows([3])
    assert_kind_of(CAStride, v)
    assert_equal([8, 3], v.shape)
    # parent byte stride is 8 (float64); both view axes share it
    assert_equal([8, 8], v.strides)
    assert_equal(0, v.byte_offset)
  end

  def test_1d_values
    src = CArray.float64(10).seq            # [0,1,2,3,4,5,6,7,8,9]
    v = src.sliding_windows([3])
    assert_equal([0.0, 1.0, 2.0], v[0, nil].to_a)
    assert_equal([1.0, 2.0, 3.0], v[1, nil].to_a)
    assert_equal([7.0, 8.0, 9.0], v[7, nil].to_a)
  end

  def test_1d_variadic_form
    src = CArray.float64(10).seq
    v1 = src.sliding_windows([3])
    v2 = src.sliding_windows(3)
    assert_equal(v1.to_a, v2.to_a)
  end

  def test_1d_moving_sum
    src = CArray.float64(10).seq
    sums = src.sliding_windows([3]).sum(axis: 1)
    # [0+1+2, 1+2+3, ..., 7+8+9]
    expected = (0..7).map { |i| (i..i+2).sum.to_f }
    assert_equal(expected, sums.to_a)
  end

  def test_1d_window_equal_length
    src = CArray.int32(5).seq
    v = src.sliding_windows([5])
    assert_equal([1, 5], v.shape)
    assert_equal([0, 1, 2, 3, 4], v[0, nil].to_a)
  end

  # ---- 2D ----

  def test_2d_basic_shape
    src = CArray.float64(4, 5).seq
    v = src.sliding_windows([2, 3])
    assert_kind_of(CAStride, v)
    assert_equal([3, 3, 2, 3], v.shape)
    # parent byte strides: [5*8, 8] = [40, 8]
    assert_equal([40, 8, 40, 8], v.strides)
  end

  def test_2d_values
    src = CArray.float64(4, 5).seq          # row-major 0..19
    v = src.sliding_windows([2, 3])
    # window at [0,0]
    expected = [[0.0, 1.0, 2.0], [5.0, 6.0, 7.0]]
    assert_equal(expected, v[0, 0, nil, nil].to_a)
    # window at [1,2]
    expected2 = [[7.0, 8.0, 9.0], [12.0, 13.0, 14.0]]
    assert_equal(expected2, v[1, 2, nil, nil].to_a)
  end

  def test_2d_moving_mean
    src = CArray.float64(4, 5).seq
    v = src.sliding_windows([2, 2])
    means = v.mean(axis: [-1, -2])
    # window at [0,0]: (0+1+5+6)/4 = 3.0
    assert_in_delta(3.0, means[0, 0], 1e-12)
    # window at [2,3]: (13+14+18+19)/4 = 16.0
    assert_in_delta(16.0, means[2, 3], 1e-12)
  end

  # ---- step ----

  def test_step_1d
    src = CArray.float64(10).seq
    v = src.sliding_windows([3], step: 2)
    # output dim: (10 - 3) / 2 + 1 = 4
    assert_equal([4, 3], v.shape)
    assert_equal([0.0, 1.0, 2.0], v[0, nil].to_a)
    assert_equal([2.0, 3.0, 4.0], v[1, nil].to_a)
    assert_equal([6.0, 7.0, 8.0], v[3, nil].to_a)
  end

  def test_step_2d_per_axis
    src = CArray.float64(6, 6).seq
    v = src.sliding_windows([2, 2], step: [2, 3])
    # out dims: (6-2)/2+1=3, (6-2)/3+1=2
    assert_equal([3, 2, 2, 2], v.shape)
    # window at [1, 1] -> parent rows 2..3, cols 3..4
    expected = [[15.0, 16.0], [21.0, 22.0]]
    assert_equal(expected, v[1, 1, nil, nil].to_a)
  end

  # ---- write-through ----

  def test_write_propagates_to_parent
    src = CArray.float64(6).seq
    v = src.sliding_windows([3])
    v[0, nil] = [100.0, 200.0, 300.0]
    assert_equal(100.0, src[0])
    assert_equal(200.0, src[1])
    assert_equal(300.0, src[2])
  end

  # ---- validation ----

  def test_error_window_too_large
    src = CArray.float64(4)
    assert_raise(ArgumentError) { src.sliding_windows([5]) }
  end

  def test_error_window_zero
    src = CArray.float64(4)
    assert_raise(ArgumentError) { src.sliding_windows([0]) }
  end

  def test_error_step_zero
    src = CArray.float64(4)
    assert_raise(ArgumentError) { src.sliding_windows([2], step: 0) }
  end

  def test_error_wrong_window_length
    src = CArray.float64(4, 5)
    assert_raise(ArgumentError) { src.sliding_windows([3]) }
    assert_raise(ArgumentError) { src.sliding_windows([3, 3, 3]) }
  end

  def test_error_wrong_step_length
    src = CArray.float64(4, 5)
    assert_raise(ArgumentError) { src.sliding_windows([2, 3], step: [1, 1, 1]) }
  end

  # (CA_RANK_MAX boundary: parent ndim must be <= CA_RANK_MAX/2.
  # With CA_RANK_MAX=16, max parent ndim is 8.  Hard to construct
  # a 9-d CArray to exercise the guard, so skipped here.)

  # ---- data_type preservation ----

  def test_int32_data_type
    src = CArray.int32(8).seq
    v = src.sliding_windows([3])
    assert_equal(CA_INT32, v.data_type)
    assert_equal([6, 3], v.shape)
    assert_equal([4, 4], v.strides)  # 4-byte stride
    assert_equal([0, 1, 2], v[0, nil].to_a)
  end
end
