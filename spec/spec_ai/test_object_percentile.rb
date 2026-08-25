require "test/unit"
require "carray"

# percentile / quantile CA_OBJECT contract tests (2026-06-23 CIFY).
#
# Mirrors test_median_object_mask.rb: CA_OBJECT now goes through the same
# numeric C path as float/int (= partition_copy CA_OBJECT branch + sort +
# arithmetic via rb_funcall), so mask + axis raises the same way numeric
# does.  Old Ruby escape (reduce_slab + slab.to_a.sort) is gone.

class TestObjectPercentile < Test::Unit::TestCase
  def test_object_percentile_flat_no_mask
    a = CA_OBJECT([1, 2, 3, 4, 5])
    # p=50 on [1..5]: f = 4*0.5 = 2.0, k=2, r=0, linear -> arr[2] * 1.0 = 3.0
    assert_equal 3.0, a.percentile(50)
  end

  def test_object_percentile_flat_multi_p
    a = CA_OBJECT([1, 2, 3, 4, 5])
    result = a.percentile(0, 25, 50, 75, 100)
    assert_equal 5, result.length
    assert_equal 1.0, result[0]
    assert_equal 3.0, result[2]
    assert_equal 5.0, result[4]
  end

  def test_object_percentile_flat_with_mask
    a = CA_OBJECT([1, 2, 3, 4, 5, 99, 99])
    a[5] = UNDEF
    a[6] = UNDEF
    # flat path strips mask -> [1,2,3,4,5] -> median = 3.0
    assert_equal 3.0, a.percentile(50)
  end

  def test_object_percentile_flat_all_masked
    a = CA_OBJECT([1, 2, 3])
    a[0..2] = UNDEF
    # all-masked flat -> UNDEF default fill
    assert_equal UNDEF, a.percentile(50)
  end

  def test_object_percentile_flat_min_count_fail
    a = CA_OBJECT([1, 2, 3, 4, 5])
    a[3..4] = UNDEF
    assert_equal(-1, a.percentile(50, min_count: 5, fill_value: -1))
  end

  def test_object_percentile_axis_no_mask
    a = CArray.object(3, 5) { |i, j| 10*i + j }
    # axis=1 percentile(50) per row: row 0=[0..4]->2.0, row 1=[10..14]->12.0, row 2=[20..24]->22.0
    r = a.percentile(50, axis: 1)
    assert_kind_of CArray, r
    assert_equal 2.0,  r[0]
    assert_equal 12.0, r[1]
    assert_equal 22.0, r[2]
  end

  def test_object_percentile_axis_multi_p_shared_sort
    a = CArray.object(2, 5) { |i, j| 10*i + j }
    r = a.percentile(0, 50, 100, axis: 1)
    assert_equal 3, r.length
    assert_equal 0.0,  r[0][0]
    assert_equal 2.0,  r[1][0]
    assert_equal 4.0,  r[2][0]
    assert_equal 10.0, r[0][1]
    assert_equal 12.0, r[1][1]
    assert_equal 14.0, r[2][1]
  end

  def test_object_percentile_axis_with_mask
    # Per-axis percentile honours the mask: each fiber's percentile is taken
    # over its own present values.  Row 1 present run [10,11,13,14] -> p50
    # (linear) = 12.0; the other rows are fully present.
    a = CArray.object(3, 5) { |i, j| 10*i + j }
    a[1, 2] = UNDEF
    m = a.percentile(50, axis: 1)
    assert_equal [2.0, 12.0, 22.0], m.to_a
    assert_equal false, m.has_mask?
  end

  def test_numeric_percentile_axis_with_mask
    # Parity: numeric matches the object lane.
    a = CArray.float64(3, 5) { |i, j| 10.0*i + j }
    a[1, 2] = UNDEF
    m = a.percentile(50, axis: 1)
    assert_equal [2.0, 12.0, 22.0], m.to_a
    assert_equal false, m.has_mask?
  end

  def test_object_quantile_flat
    a = CA_OBJECT([1, 2, 3, 4, 5])
    r = a.quantile
    assert_equal 5, r.length
    assert_equal 1.0, r[0]
    assert_equal 2.0, r[1]
    assert_equal 3.0, r[2]
    assert_equal 4.0, r[3]
    assert_equal 5.0, r[4]
  end

  def test_object_quantile_axis
    a = CArray.object(2, 5) { |i, j| 10*i + j }
    r = a.quantile(keep_axis: false)
    # keep_axis: false on axis: nil -> flat scalar results
    assert_equal 5, r.length
    # Flat over all 10 elements [0..4, 10..14] sorted = [0,1,2,3,4,10,11,12,13,14]
    # q50 = mean of [4, 10] = 7.0 (linear interpolation)
    assert_equal 7.0, r[2]
  end

  def test_object_percentile_method_lower
    a = CA_OBJECT([1, 2, 3, 4, 5])
    # p=50: f=2.0, k=2, r=0 -> lower = arr[2] = 3.0
    assert_equal 3.0, a.percentile(50, method: :lower)
  end

  def test_object_percentile_method_higher
    a = CA_OBJECT([1, 2, 3, 4])
    # p=50: f=1.5, k=1, r=0.5 -> higher = arr[2] = 3.0
    assert_equal 3.0, a.percentile(50, method: :higher)
  end

  def test_object_percentile_method_nearest
    a = CA_OBJECT([1, 2, 3, 4])
    # p=50: f=1.5, k=1, r=0.5 -> nearest with k=1 (odd) -> use upper -> arr[2]=3.0
    assert_equal 3.0, a.percentile(50, method: :nearest)
  end

  def test_object_percentile_method_midpoint
    a = CA_OBJECT([1, 2, 3, 4])
    # p=50: f=1.5, k=1, r=0.5 -> midpoint = (arr[1]+arr[2])/2 = 2.5
    assert_equal 2.5, a.percentile(50, method: :midpoint)
  end

  def test_object_percentile_p100
    a = CA_OBJECT([3, 1, 4, 1, 5, 9, 2, 6])
    # p=100 fast path -> max * 1.0 = 9.0
    assert_equal 9.0, a.percentile(100)
  end

  def test_object_percentile_p0
    a = CA_OBJECT([3, 1, 4, 1, 5])
    # p=0 -> sorted[0] = 1, * 1.0 -> 1.0
    assert_equal 1.0, a.percentile(0)
  end

  def test_keep_axis_flat
    a = CA_OBJECT([1, 2, 3, 4, 5])
    r = a.percentile(50, keep_axis: true)
    assert_kind_of CArray, r
    assert_equal [1], r.shape
    assert_equal 3.0, r[0]
  end

  def test_keep_axis_axis
    a = CArray.object(3, 5) { |i, j| 10*i + j }
    r = a.percentile(50, axis: 1, keep_axis: true)
    assert_kind_of CArray, r
    assert_equal [3, 1], r.shape
  end

  def test_empty_pers_raises
    a = CA_OBJECT([1, 2, 3])
    assert_raise(ArgumentError) { a.percentile }
  end

  def test_p_out_of_range_raises
    a = CA_OBJECT([1, 2, 3])
    assert_raise(ArgumentError) { a.percentile(101) }
    assert_raise(ArgumentError) { a.percentile(-1) }
  end

  def test_invalid_method_raises
    a = CA_OBJECT([1, 2, 3])
    assert_raise(ArgumentError) { a.percentile(50, method: :inverted_cdf) }
  end

  def test_empty_axis_yields_undef_cells
    # A zero-length reduction axis has no elements to take a percentile of.
    # An order statistic has no identity, so every reduced cell is UNDEF
    # (matching mean / min on an empty axis), not a raise.
    a = CArray.object(3, 0)
    r = a.percentile(50, axis: 1)
    assert_equal(3, r.elements)
    assert_equal([true, true, true], r.is_masked.to_a)   # all cells masked
  end

  def test_pers_array_flatten
    a = CA_OBJECT([1, 2, 3, 4, 5])
    # Array.from positional should flatten
    assert_equal [1.0, 3.0, 5.0], a.percentile([0, 50, 100])
  end
end
