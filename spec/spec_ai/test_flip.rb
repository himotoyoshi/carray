require "test/unit"
require "carray"

# Tests for CArray#flip: per-axis negative-stride view.
# Functionally equivalent to the indexer form ca[-1..0, ...] but
# exposes axis selection as a named, ndim-parametric API in keeping
# with sliding_windows / block_view / dim_view.

class TestFlip < Test::Unit::TestCase

  def test_method_defined
    assert(CArray.instance_methods.include?(:flip))
  end

  def test_returns_castride
    a = CArray.float64(4, 5).seq
    v = a.flip(0)
    assert_kind_of(CAStride, v)
  end

  # ---- 1D ----

  def test_1d_flip
    a = CArray.float64(5).seq                # [0,1,2,3,4]
    v = a.flip(0)
    assert_equal([5], v.shape)
    assert_equal([-8], v.strides)
    assert_equal(4 * 8, v.byte_offset)       # last element
    assert_equal([4.0, 3.0, 2.0, 1.0, 0.0], v.to_a)
  end

  def test_1d_flip_no_args_flips_all
    a = CArray.float64(5).seq
    assert_equal(a.flip(0).to_a, a.flip.to_a)
  end

  # ---- 2D ----

  def test_2d_flip_axis0
    a = CArray.float64(4, 5).seq
    v = a.flip(0)
    assert_equal([4, 5], v.shape)
    assert_equal([-40, 8], v.strides)
    assert_equal(3 * 40, v.byte_offset)
    # row 0 of v = last row of a
    assert_equal([15.0, 16.0, 17.0, 18.0, 19.0], v[0, nil].to_a)
    assert_equal([0.0, 1.0, 2.0, 3.0, 4.0],     v[3, nil].to_a)
  end

  def test_2d_flip_axis1
    a = CArray.float64(4, 5).seq
    v = a.flip(1)
    assert_equal([40, -8], v.strides)
    assert_equal(4 * 8, v.byte_offset)         # last column of row 0
    assert_equal([4.0, 3.0, 2.0, 1.0, 0.0],   v[0, nil].to_a)
    assert_equal([19.0, 18.0, 17.0, 16.0, 15.0], v[3, nil].to_a)
  end

  def test_2d_flip_both_axes
    a = CArray.float64(4, 5).seq
    v = a.flip(0, 1)
    assert_equal([-40, -8], v.strides)
    assert_equal(3 * 40 + 4 * 8, v.byte_offset)
    assert_equal([19.0, 18.0, 17.0, 16.0, 15.0], v[0, nil].to_a)
    assert_equal([4.0, 3.0, 2.0, 1.0, 0.0],     v[3, nil].to_a)
  end

  def test_2d_flip_all_via_no_args
    a = CArray.float64(4, 5).seq
    assert_equal(a.flip(0, 1).to_a, a.flip.to_a)
  end

  # ---- equivalence with the slice form ----

  def test_equivalent_to_negative_range_slicing_1d
    a = CArray.float64(7).seq
    assert_equal(a[-1..0].to_a, a.flip(0).to_a)
  end

  def test_equivalent_to_negative_range_slicing_2d
    a = CArray.float64(4, 5).seq
    assert_equal(a[-1..0, nil].to_a,   a.flip(0).to_a)
    assert_equal(a[nil, -1..0].to_a,   a.flip(1).to_a)
    assert_equal(a[-1..0, -1..0].to_a, a.flip.to_a)
  end

  def test_equivalent_to_negative_range_slicing_3d
    a = CArray.float64(2, 3, 4).seq
    assert_equal(a[-1..0, nil, -1..0].to_a, a.flip(0, 2).to_a)
  end

  # ---- argument forms ----

  def test_variadic_and_array_forms_equivalent
    a = CArray.float64(2, 3, 4).seq
    v1 = a.flip(0, 2)
    v2 = a.flip([0, 2])
    assert_equal(v1.strides, v2.strides)
    assert_equal(v1.to_a, v2.to_a)
  end

  def test_negative_axis
    a = CArray.float64(2, 3, 4).seq
    # -1 == 2 on ndim=3
    assert_equal(a.flip(2).to_a, a.flip(-1).to_a)
    # mixed
    assert_equal(a.flip(0, 2).to_a, a.flip(0, -1).to_a)
  end

  # ---- write-through ----

  def test_write_propagates_to_parent
    a = CArray.float64(4, 5).seq
    v = a.flip(0)
    v[0, 0] = -1.0       # writes to a[3, 0]
    assert_equal(-1.0, a[3, 0])
    assert_equal(0.0,  a[0, 0])

    v[0, nil] = [-2.0, -2.0, -2.0, -2.0, -2.0]   # writes to a[3, :]
    5.times { |j| assert_equal(-2.0, a[3, j]) }
  end

  # ---- double-flip is identity (in value) ----

  def test_double_flip_recovers_data
    a = CArray.float64(4, 5).seq
    assert_equal(a.to_a, a.flip.flip.to_a)
    assert_equal(a.to_a, a.flip(0).flip(0).to_a)
  end

  # ---- reductions work normally ----

  def test_mean_invariant_under_flip
    a = CArray.float64(4, 5).seq
    assert_in_delta(a.mean, a.flip.mean, 1e-12)
  end

  def test_axis_mean_swapped_under_flip
    a = CArray.float64(4, 5).seq
    # mean along axis 0 of a: [m0, m1, ..., m4]
    # mean along axis 0 of a.flip(1): [m4, m3, ..., m0]
    m  = a.mean(axis: 0)
    mf = a.flip(1).mean(axis: 0)
    assert_equal(m.to_a.reverse, mf.to_a)
  end

  # ---- data_type ----

  def test_int32_data_type
    a = CArray.int32(5).seq
    v = a.flip
    assert_equal(CA_INT32, v.data_type)
    assert_equal([-4], v.strides)
    assert_equal([4, 3, 2, 1, 0], v.to_a)
  end

  # ---- errors ----

  def test_error_duplicate_axis
    a = CArray.float64(4, 5)
    assert_raise(ArgumentError) { a.flip(0, 0) }
    assert_raise(ArgumentError) { a.flip(1, -1) }   # -1 == 1
  end

  def test_error_out_of_range
    a = CArray.float64(4, 5)
    assert_raise(ArgumentError) { a.flip(2) }
    assert_raise(ArgumentError) { a.flip(-3) }
  end

  def test_error_too_many_axes
    a = CArray.float64(4, 5)
    assert_raise(ArgumentError) { a.flip(0, 1, 0) }   # nargs > ndim
  end

  def test_error_unknown_keyword
    a = CArray.float64(4, 5)
    assert_raise(ArgumentError) { a.flip(0, foo: 1) }
  end
end
