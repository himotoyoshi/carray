require "test/unit"
require "carray"

# Tests for CArray#block_view (PROPOSAL_VECTORIZE_PATTERNS Pattern B).
# Parent shape [d0, d1, ...] becomes a CAStride view of shape
# [d0/b0, d1/b1, ..., b0, b1, ...] -- non-overlapping tiles.
# Parent dims must be exactly divisible by the block sizes.

class TestBlockView < Test::Unit::TestCase

  def test_method_defined
    assert(CArray.instance_methods.include?(:block_view))
  end

  # ---- 1D ----

  def test_1d_basic_shape_and_strides
    src = CArray.float64(12).seq
    v = src.block_view([3])
    assert_kind_of(CAStride, v)
    assert_equal([4, 3], v.shape)
    # parent stride 8 (float64); tile-grid stride = 3*8 = 24, in-tile = 8
    assert_equal([24, 8], v.strides)
    assert_equal(0, v.byte_offset)
  end

  def test_1d_values
    src = CArray.float64(12).seq          # [0..11]
    v = src.block_view([3])
    assert_equal([0.0, 1.0, 2.0], v[0, nil].to_a)
    assert_equal([3.0, 4.0, 5.0], v[1, nil].to_a)
    assert_equal([9.0, 10.0, 11.0], v[3, nil].to_a)
  end

  def test_1d_variadic_form
    src = CArray.float64(12).seq
    v1 = src.block_view([3])
    v2 = src.block_view(3)
    assert_equal(v1.to_a, v2.to_a)
    assert_equal(v1.shape, v2.shape)
  end

  def test_1d_block_aggregation
    src = CArray.float64(12).seq
    sums = src.block_view([3]).sum(axis: 1)
    # [0+1+2, 3+4+5, 6+7+8, 9+10+11] = [3, 12, 21, 30]
    assert_equal([3.0, 12.0, 21.0, 30.0], sums.to_a)
  end

  def test_1d_block_equals_parent_dim
    src = CArray.int32(5).seq
    v = src.block_view([5])
    assert_equal([1, 5], v.shape)
    assert_equal([0, 1, 2, 3, 4], v[0, nil].to_a)
  end

  # ---- 2D ----

  def test_2d_basic
    src = CArray.float64(4, 6).seq
    v = src.block_view([2, 3])
    assert_kind_of(CAStride, v)
    assert_equal([2, 2, 2, 3], v.shape)
    # parent strides [48, 8]; tile strides [2*48, 3*8] = [96, 24];
    # in-tile [48, 8]
    assert_equal([96, 24, 48, 8], v.strides)
  end

  def test_2d_values
    src = CArray.float64(4, 6).seq        # row-major 0..23
    v = src.block_view([2, 3])
    # tile [0,0]: rows 0..1, cols 0..2
    assert_equal([[0.0, 1.0, 2.0], [6.0, 7.0, 8.0]],
                 v[0, 0, nil, nil].to_a)
    # tile [1,1]: rows 2..3, cols 3..5
    assert_equal([[15.0, 16.0, 17.0], [21.0, 22.0, 23.0]],
                 v[1, 1, nil, nil].to_a)
  end

  def test_2x2_average_pooling
    src = CArray.float64(4, 6).seq
    v = src.block_view([2, 3])
    means = v.mean(axis: [-1, -2])
    # tile[0,0]: (0+1+2+6+7+8)/6 = 4.0
    # tile[0,1]: (3+4+5+9+10+11)/6 = 7.0
    # tile[1,0]: (12+13+14+18+19+20)/6 = 16.0
    # tile[1,1]: (15+16+17+21+22+23)/6 = 19.0
    assert_in_delta(4.0,  means[0, 0], 1e-12)
    assert_in_delta(7.0,  means[0, 1], 1e-12)
    assert_in_delta(16.0, means[1, 0], 1e-12)
    assert_in_delta(19.0, means[1, 1], 1e-12)
  end

  def test_2x2_max_pooling
    src = CArray.float64(4, 4).seq        # 0..15
    v = src.block_view([2, 2])
    maxes = v.max(axis: [-1, -2])
    # tile[0,0]: max(0,1,4,5) = 5
    # tile[0,1]: max(2,3,6,7) = 7
    # tile[1,0]: max(8,9,12,13) = 13
    # tile[1,1]: max(10,11,14,15) = 15
    assert_equal([[5.0, 7.0], [13.0, 15.0]], maxes.to_a)
  end

  # ---- write-through ----

  def test_write_propagates_to_parent
    src = CArray.float64(4, 4).seq
    v = src.block_view([2, 2])
    # fill tile [1, 0] (rows 2..3, cols 0..1) with -1
    v[1, 0, nil, nil] = -1.0
    assert_equal(-1.0, src[2, 0])
    assert_equal(-1.0, src[2, 1])
    assert_equal(-1.0, src[3, 0])
    assert_equal(-1.0, src[3, 1])
    # other tiles untouched
    assert_equal(0.0, src[0, 0])
    assert_equal(15.0, src[3, 3])
  end

  # ---- validation ----

  def test_error_not_divisible_1d
    src = CArray.float64(10)
    assert_raise(ArgumentError) { src.block_view([3]) }
  end

  def test_error_not_divisible_2d
    src = CArray.float64(4, 5)
    assert_raise(ArgumentError) { src.block_view([2, 2]) }   # 5 % 2 != 0
  end

  def test_error_block_zero
    src = CArray.float64(4)
    assert_raise(ArgumentError) { src.block_view([0]) }
  end

  def test_error_block_larger_than_dim
    # block > dim implies dim/block == 0 AND dim % block != 0, so divisibility
    # check catches it.  Make sure it's reported as ArgumentError.
    src = CArray.float64(4)
    assert_raise(ArgumentError) { src.block_view([5]) }
  end

  def test_error_wrong_block_length
    src = CArray.float64(4, 6)
    assert_raise(ArgumentError) { src.block_view([2]) }
    assert_raise(ArgumentError) { src.block_view([2, 2, 2]) }
  end

  def test_error_unknown_keyword
    src = CArray.float64(4, 6)
    assert_raise(ArgumentError) { src.block_view([2, 3], step: [1, 1]) }
  end

  # ---- data_type preservation ----

  def test_int32_data_type
    src = CArray.int32(8).seq
    v = src.block_view([4])
    assert_equal(CA_INT32, v.data_type)
    assert_equal([2, 4], v.shape)
    assert_equal([16, 4], v.strides)   # 4*4=16, 4
    assert_equal([0, 1, 2, 3], v[0, nil].to_a)
    assert_equal([4, 5, 6, 7], v[1, nil].to_a)
  end

  # ---- semantic relationship with sliding_windows ----

  def test_block_view_equivalent_to_sliding_with_step_equal_window
    # When parent is divisible, block_view([B,B]) should give the same
    # shape and values as sliding_windows([B,B], step: [B,B]).
    src = CArray.float64(6, 6).seq
    b = src.block_view([2, 3])
    s = src.sliding_windows([2, 3], step: [2, 3])
    assert_equal(b.shape, s.shape)
    assert_equal(b.to_a, s.to_a)
  end
end
