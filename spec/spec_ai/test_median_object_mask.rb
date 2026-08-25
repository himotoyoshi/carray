# median CA_OBJECT + mask behavior tests.
#
# History:
# - commit c88ca70 (2026-06-21): median CIFY introduced
#   __median_axis_object / __median_flat_object Ruby escape helpers for
#   CA_OBJECT path.  Initial escape used `slab.to_a.sort` which raised
#   ArgumentError on masked CA_OBJECT (= UNDEF object in Array#sort).
# - commit bdae94d (2026-06-21): escape fixed via slab[:is_not_masked] +
#   n_eff recomputation + post-pass mask for all-masked slabs.  Escape
#   provided numeric にない機能 (= per-slab compact for mask+axis).
# - commit af71a87 (2026-06-22): partition_copy CA_OBJECT branch added
#   (= partition_index_ki + take_along_axis).  Escape remained for mask
#   +axis compat.
# - commit XXX (2026-06-22, this update): CA_OBJECT escape retired.
#   median CA_OBJECT path goes through numeric C path (= _kth_one /
#   _kth_pair → partition_copy CA_OBJECT branch).  mask+axis now raises
#   the same way as numeric (= partition_copy rejects masked input).
#   3.0 breaking for CA_OBJECT median + mask + axis, but resolves dtype
#   asymmetry; mask+axis support is deferred to a separate Phase that
#   extends partition_copy with per-slab compact mode for all dtypes.

require "test/unit"
require "carray"

class TestMedianObjectMask < Test::Unit::TestCase
  def test_object_median_no_mask_flat
    a = CA_OBJECT([3, 1, 4, 1, 5])
    # numeric path: _kth_one(0, 2) -> partition_copy(2)[2] * 1.0 -> 3.0
    assert_equal 3.0, a.median
  end

  def test_object_median_with_mask_flat
    # flat path: median_flat_c strips mask via [:is_not_masked] before
    # delegating to axis 0.  Works for CA_OBJECT same as numeric.
    a = CA_OBJECT([3, 1, 4, 1, 5, 9, 2])
    a[2] = UNDEF
    a[5] = UNDEF
    # remaining = [3, 1, 1, 5, 2], sorted = [1, 1, 2, 3, 5], median = 2.0
    assert_equal 2.0, a.median
  end

  def test_object_median_axis_no_mask
    # axis path no mask: numeric C path (partition_copy CA_OBJECT branch).
    a = CArray.object(3, 5) { |i, j| 10*i + j }
    m = a.median(axis: 1)
    assert_equal 2.0,  m[0]
    assert_equal 12.0, m[1]
    assert_equal 22.0, m[2]
    assert_equal false, m.has_mask?
  end

  def test_object_median_axis_with_mask
    # Per-axis order statistics honour the mask: each fiber's median is taken
    # over its own present values (skipna), matching the reduction family.
    # Row 1 has one masked cell so its present run is [10,11,13,14] (n=4,
    # median 12.0); the other rows are fully present.
    a = CArray.object(3, 5) { |i, j| 10*i + j }
    a[1, 2] = UNDEF
    m = a.median(axis: 1)
    assert_equal [2.0, 12.0, 22.0], m.to_a
    assert_equal false, m.has_mask?
  end

  def test_numeric_median_axis_with_mask
    # Parity check: numeric matches the object lane.
    a = CArray.float64(3, 5) { |i, j| 10.0*i + j }
    a[1, 2] = UNDEF
    m = a.median(axis: 1)
    assert_equal [2.0, 12.0, 22.0], m.to_a
    assert_equal false, m.has_mask?
  end

  def test_object_median_flat_all_masked
    a = CArray.object(3) { |i| i }
    a[0..2] = UNDEF
    # flat path mask strip -> empty -> UNDEF
    assert_equal UNDEF, a.median
  end

  def test_object_median_no_explicit_n_drift_flat
    # flat path with masked cells: median_flat_c strips mask, so n_eff
    # is the effective length (= 4 here, not original 7).  Tests that
    # flat path correctly recomputes after compact.
    a = CA_OBJECT([0, 1, 2, 3, 4, 5, 6])
    a[0..2] = UNDEF
    # remaining sorted [3,4,5,6] n_eff=4 even → (4+5)/2 = 4.5
    assert_equal 4.5, a.median
  end

  def test_object_median_keep_axis_flat
    a = CA_OBJECT([1, 2, 3])
    m = a.median(keep_axis: true)
    assert_equal [1], m.shape
    assert_equal 2.0, m[0]
  end
end
