# spec_ai/test_accumulate_rewire.rb
#
# Rewire of CArray#accumulate (retired in E.7 stat_proc retire, commit
# f5c7ecd) to mkkernel MkKernel.reduce :accumulate with output:
# :preserve.  This is "sum that preserves input data_type" -- int8 stays
# int8 (will overflow on long arrays, same as legacy).  For the safe
# widening f64 sum use #sum instead.
#
# Existing capabilities preserved: per-axis, mask (:min_count policy
# with min_count: / fill_value: options).
#
# 3.0 breaking subtleties:
#   - empty array returns UNDEF (= consistent with mkkernel reduction
#     family); legacy returned 0.

require "test/unit"
require "carray"

class TestAccumulateRewire < Test::Unit::TestCase
  # --- flatten (preserves data_type) ---

  def test_accumulate_int32
    a = CArray.int32(5).seq
    r = a.accumulate
    assert_equal 10, r
    assert_kind_of Integer, r
  end

  def test_accumulate_float64
    a = CArray.float64(5).seq
    assert_in_delta 10.0, a.accumulate, 1e-9
    assert_kind_of Float, a.accumulate
  end

  def test_accumulate_int8_preserves_data_type_with_overflow_allowed
    # Legacy semantics: int8 sum overflows silently.  Use small values
    # so the test doesn't depend on undefined overflow behaviour.
    a = CArray.int8(5)
    a[] = [1, 2, 3, 4, 5]
    assert_equal 15, a.accumulate
  end

  # --- per-axis (preserves data_type) ---

  def test_accumulate_per_axis_preserves_data_type
    a = CArray.int32(2, 3).seq  # [[0,1,2],[3,4,5]]
    r = a.accumulate(axis: 0)
    assert_equal CA_INT32, r.data_type
    assert_equal [3, 5, 7], r.to_a
  end

  def test_accumulate_per_axis_2_returns_row_sums
    a = CArray.int32(2, 3).seq
    assert_equal [3, 12], a.accumulate(axis: 1).to_a
  end

  # --- mask handling ---

  def test_accumulate_mask_skips_cells
    a = CArray.int32(5).seq  # [0,1,2,3,4]
    a.mask = [0, 1, 0, 1, 0]
    assert_equal 6, a.accumulate  # 0 + 2 + 4
  end

  def test_accumulate_min_count_undef
    a = CArray.int32(5).seq
    a.mask = [0, 1, 0, 1, 0]   # only 3 valid
    assert_equal UNDEF, a.accumulate(min_count: 4)
  end

  def test_accumulate_min_count_with_fill_value
    a = CArray.int32(5).seq
    a.mask = [0, 1, 0, 1, 0]
    assert_equal(-1, a.accumulate(min_count: 4, fill_value: -1))
  end

  # --- distinction from sum (= f64 output) ---

  def test_accumulate_vs_sum_data_type_difference
    a = CArray.int32(5).seq
    assert_kind_of Integer, a.accumulate          # preserves int
    assert_kind_of Float, a.sum                    # widens to f64
    assert_equal a.accumulate, a.sum.to_i
  end
end
