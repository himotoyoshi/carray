# PROPOSAL_SLAB_FAMILY β.5 — customer integration tests
#
# Pins the 4 customer surfaces that β.5 lifts (proposal §5.6 Q8 Option B):
#
#   mask_duplicates(axis:)         on CA_OBJECT/CA_FIXLEN  — was NotImplementedError
#   sort(axis:)         on CA_OBJECT            — was DataTypeError
#   median(axis:)       on CA_OBJECT            — was DataTypeError
#   percentile(axis:)   on CA_OBJECT            — was DataTypeError
#
# Numeric paths are unaffected — those continue to use sort_addr_ki /
# partition_copy etc.  Each customer test exercises both an axis path
# AND a numeric sanity (= unchanged) so a regression in either direction
# is caught here.

require 'test/unit'
require 'carray'

class TestSlabCustomerIntegrationBeta5 < Test::Unit::TestCase

  # ---- mask_duplicates (formerly uniq)

  def test_uniq_object_axis_lift_via_map_slab
    a = CArray.object(3, 5) { |i, j| (i + j) % 3 }
    u = a.mask_duplicates(axis: 1)
    # Each row [0,1,2,0,1]/[1,2,0,1,2]/[2,0,1,2,0]: first 3 unique, last 2 dup
    3.times do |i|
      assert_equal [false, false, false, true, true],
                   u[i, nil].mask.to_a
    end
  end

  def test_uniq_object_axis_0
    a = CArray.object(4, 2) { |i, j| (i % 2) + j * 10 }
    u = a.mask_duplicates(axis: 0)
    # Each column: [0+10j, 1+10j, 0+10j, 1+10j] — two unique, two dup
    2.times do |j|
      assert_equal [false, false, true, true],
                   u[nil, j].mask.to_a
    end
  end

  def test_uniq_object_negative_axis
    a = CArray.object(2, 3) { |i, j| j }
    u = a.mask_duplicates(axis: -1)
    # All unique per row, no mask set
    assert_equal 0, u.count_masked
  end

  def test_uniq_object_axis_out_of_range
    a = CArray.object(2, 3) { |i, j| j }
    assert_raise(ArgumentError) { a.mask_duplicates(axis: 99) }
  end

  def test_uniq_numeric_path_unaffected
    # Sanity: numeric mask_duplicates still uses the sort_addr_ki path.
    a = CA_INT([1, 2, 3, 2, 1])
    u = a.mask_duplicates
    assert_equal [false, false, false, true, true],
                 u.mask.to_a
  end

  # ---- sort

  def test_sort_object_axis_returns_per_row_sorted
    a = CArray.object(2, 4) { |i, j| ["c", "a", "b", "d"][j] + "-#{i}" }
    s = a.sort(axis: 1)
    assert_equal ["a-0", "b-0", "c-0", "d-0"], s[0, nil].to_a
    assert_equal ["a-1", "b-1", "c-1", "d-1"], s[1, nil].to_a
  end

  def test_sort_object_axis_0
    a = CArray.object(3, 2) { |i, j| (3 - i) * (j + 1) }   # col 0: [3,2,1], col 1: [6,4,2]
    s = a.sort(axis: 0)
    assert_equal [1, 2, 3], s[nil, 0].to_a
    assert_equal [2, 4, 6], s[nil, 1].to_a
  end

  def test_sort_object_no_axis_uses_c_path
    # PROPOSAL_MKKERNEL_OBJECT_DTYPE_BRANCH Phase 2 (2026-06-22): the C
    # sort path now accepts CA_OBJECT (via mkkernel :object dtype branch
    # + qsort with rb_funcall(<=>) cmp).  Replaces the prior Beta.5
    # contract where the C path raised DataTypeError and only the
    # per-axis Ruby lift handled CA_OBJECT.  Flat sort still works
    # equivalently here.
    a = CArray.object(3) { |i| [3, 1, 2][i] }
    assert_equal([1, 2, 3], a.sort.to_a)
  end

  def test_sort_numeric_path_unaffected
    a = CArray.float64(3, 4) { |i, j| 11 - 4*i - j }
    s = a.sort(axis: 1)
    assert_equal [8.0, 9.0, 10.0, 11.0], s[0, nil].to_a
    assert_equal [4.0, 5.0, 6.0, 7.0],   s[1, nil].to_a
    assert_equal [0.0, 1.0, 2.0, 3.0],   s[2, nil].to_a
  end

  # ---- median

  def test_median_object_axis_per_row_odd_n
    a = CArray.object(2, 5) { |i, j| (i + 1) * (j + 1) }
    m = a.median(axis: 1)
    # row 0: [1,2,3,4,5], median = 3
    # row 1: [2,4,6,8,10], median = 6
    assert_equal [3, 6], m.to_a
  end

  def test_median_object_axis_per_row_even_n
    a = CArray.object(2, 4) { |i, j| (i + 1) * (j + 1) }
    m = a.median(axis: 1)
    # row 0: [1,2,3,4], median = (2+3)/2.0 = 2.5
    # row 1: [2,4,6,8], median = (4+6)/2.0 = 5.0
    assert_equal [2.5, 5.0], m.to_a
  end

  def test_median_object_axis_0
    a = CArray.object(3, 2) { |i, j| (i + 1) * (j + 1) }
    m = a.median(axis: 0)
    # col 0: [1,2,3], median = 2; col 1: [2,4,6], median = 4
    assert_equal [2, 4], m.to_a
  end

  def test_median_numeric_path_unaffected
    a = CArray.float64(3, 4).seq!
    m = a.median(axis: 1)
    assert_equal [1.5, 5.5, 9.5], m.to_a
  end

  # ---- percentile

  def test_percentile_object_axis_single_p
    a = CArray.object(2, 5) { |i, j| (i + 1) * (j + 1) }
    p50 = a.percentile(50, axis: 1)
    # single-p unwraps -> CArray directly, not Array<CArray>
    assert_kind_of CArray, p50
    assert_equal [3.0, 6.0], p50.to_a
  end

  def test_percentile_object_axis_multi_p
    a = CArray.object(2, 5) { |i, j| (i + 1) * (j + 1) }
    ps = a.percentile(25, 50, 75, axis: 1)
    assert_equal 3, ps.size
    # row 0: [1,2,3,4,5] — p25=2, p50=3, p75=4 (linear)
    # row 1: [2,4,6,8,10] — p25=4, p50=6, p75=8 (linear)
    assert_equal [2.0, 4.0], ps[0].to_a
    assert_equal [3.0, 6.0], ps[1].to_a
    assert_equal [4.0, 8.0], ps[2].to_a
  end

  def test_percentile_object_axis_method_lower
    a = CArray.object(2, 5) { |i, j| (i + 1) * (j + 1) }
    p50 = a.percentile(50, axis: 1, method: :lower)
    assert_equal [3.0, 6.0], p50.to_a
  end

  def test_percentile_object_axis_method_nearest
    a = CArray.object(2, 4) { |i, j| (i + 1) * (j + 1) }
    p50 = a.percentile(50, axis: 1, method: :nearest)
    # row 0: [1,2,3,4] f=3*0.5=1.5, r=0.5, k=1 (odd) → banker's picks k+1=2 → arr[2]=3
    # row 1: [2,4,6,8] same → arr[2]=6
    # (= numeric :nearest at the half-mark, banker's rounding to even k)
    assert_equal [3.0, 6.0], p50.to_a
  end

  def test_percentile_numeric_path_unaffected
    a = CArray.float64(3, 5).seq!
    p50 = a.percentile(50, axis: 1)
    assert_equal [2.0, 7.0, 12.0], p50.to_a
  end
end
