require "test/unit"
require "carray"

# Tests for CArray#dim_view: view counterpart of the CADimensionIterator.
# Designate certain axes as "iteration axes"; they move to the front and
# the remaining axes follow in original order.  Returns CATranspose
# (syntactic sugar over #transposed).

class TestDimView < Test::Unit::TestCase

  def test_method_defined
    assert(CArray.instance_methods.include?(:dim_view))
  end

  def test_returns_catranspose
    a = CArray.float64(3, 4, 5).seq
    v = a.dim_view(0, 2)
    assert_kind_of(CATranspose, v)
  end

  # ---- shapes ----

  def test_single_iter_axis
    a = CArray.float64(3, 4, 5).seq
    assert_equal([3, 4, 5], a.dim_view(0).shape)
    assert_equal([4, 3, 5], a.dim_view(1).shape)
    assert_equal([5, 3, 4], a.dim_view(2).shape)
  end

  def test_two_iter_axes_keep_order
    a = CArray.float64(3, 4, 5).seq
    # axes 0,2 to front (in given order), axis 1 follows
    assert_equal([3, 5, 4], a.dim_view(0, 2).shape)
    # axes 2,0 to front (in given order)
    assert_equal([5, 3, 4], a.dim_view(2, 0).shape)
  end

  def test_all_axes_is_identity_transpose
    a = CArray.float64(3, 4, 5).seq
    v = a.dim_view(0, 1, 2)
    assert_equal([3, 4, 5], v.shape)
    assert_equal(a.to_a, v.to_a)
  end

  # ---- argument forms ----

  def test_variadic_and_array_forms_equivalent
    a = CArray.float64(3, 4, 5).seq
    v1 = a.dim_view(0, 2)
    v2 = a.dim_view([0, 2])
    assert_equal(v1.shape, v2.shape)
    assert_equal(v1.to_a, v2.to_a)
  end

  def test_negative_axis
    a = CArray.float64(3, 4, 5).seq
    # -1 == 2 for ndim 3
    assert_equal(a.dim_view(2).shape, a.dim_view(-1).shape)
    assert_equal(a.dim_view(2).to_a, a.dim_view(-1).to_a)
    # mixed signs
    assert_equal(a.dim_view(0, 2).to_a, a.dim_view(0, -1).to_a)
  end

  # ---- value correctness ----

  def test_values_match_underlying_slice
    a = CArray.float64(3, 4, 5).seq
    v = a.dim_view(0, 2)   # shape [3, 5, 4]
    # v[i, k, :]  should equal a[i, :, k]
    3.times do |i|
      5.times do |k|
        assert_equal(a[i, nil, k].to_a, v[i, k, nil].to_a)
      end
    end
  end

  def test_equivalent_to_transposed
    a = CArray.float64(3, 4, 5).seq
    assert_equal(a.transpose(0, 2, 1).to_a, a.dim_view(0, 2).to_a)
    assert_equal(a.transpose(2, 0, 1).to_a, a.dim_view(2, 0).to_a)
    assert_equal(a.transpose(1, 0, 2).to_a, a.dim_view(1).to_a)
  end

  # ---- reduction patterns: the use case ----

  def test_mean_over_kept_axis
    a = CArray.float64(3, 4, 5).seq
    v = a.dim_view(0, 2)            # [3, 5, 4] -- "iter over (i, k), kept axis is dim 1"
    m = v.mean(axis: -1)                  # shape [3, 5]
    # m[i, k] should equal mean of a[i, :, k]
    3.times do |i|
      5.times do |k|
        assert_in_delta(a[i, nil, k].mean, m[i, k], 1e-12)
      end
    end
  end

  def test_dim_view_iter_correspondence
    # SI.3: CASlabIterator.  :> marks the slab axis (axis 1); axes 0,2 are
    # the outer iteration space.  The yielded slab is the 1-D axis-1 fiber
    # directly.  dim_view collapses the same outer axes into outer indices.
    a = CArray.float64(3, 4, 5).seq
    v = a.dim_view(0, 2)
    collected = []
    a[nil, :>, nil].each { |slice| collected << slice.to_a }
    flat = (0...3).flat_map { |i| (0...5).map { |k| v[i, k, nil].to_a } }
    assert_equal(collected, flat)
  end

  # ---- write-through ----

  def test_write_propagates_to_parent
    a = CArray.float64(3, 4, 5).seq
    v = a.dim_view(0, 2)
    v[1, 2, nil] = -1.0
    # a[1, :, 2] should now be all -1
    4.times { |j| assert_equal(-1.0, a[1, j, 2]) }
    # other cells untouched
    assert_equal(0.0, a[0, 0, 0])
  end

  # ---- data_type ----

  def test_int32_data_type
    a = CArray.int32(2, 3).seq
    v = a.dim_view(1)
    assert_equal(CA_INT32, v.data_type)
    assert_equal([3, 2], v.shape)
  end

  # ---- errors ----

  def test_error_no_args
    a = CArray.float64(3, 4)
    assert_raise(ArgumentError) { a.dim_view }
    assert_raise(ArgumentError) { a.dim_view([]) }
  end

  def test_error_duplicate_axis
    a = CArray.float64(3, 4, 5)
    assert_raise(ArgumentError) { a.dim_view(0, 0) }
    assert_raise(ArgumentError) { a.dim_view(1, -2) }   # -2 == 1
  end

  def test_error_out_of_range
    a = CArray.float64(3, 4, 5)
    assert_raise(ArgumentError) { a.dim_view(3) }
    assert_raise(ArgumentError) { a.dim_view(-4) }
  end

  def test_error_too_many_axes
    a = CArray.float64(3, 4, 5)
    assert_raise(ArgumentError) { a.dim_view(0, 1, 2, 0) }   # 4 > ndim 3
  end

  def test_error_unknown_keyword
    a = CArray.float64(3, 4, 5)
    assert_raise(ArgumentError) { a.dim_view(0, foo: 1) }
  end
end
