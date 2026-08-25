# spec_ai/test_bin.rb
#
# Tests for `CArray#bin(vmin, vmax, step, bins:, include_max:)`:
# equal-width, half-open bin indices over `[vmin, vmax]`.  Step-first
# positional matches `snap` (both uniform-grid primitives); `bins:`
# kwarg is the count-first alternative (histogram convention).
#
# Also carries the dual-fill `clip` refinement (second class below).

require "test/unit"
require "carray"

class TestBin < Test::Unit::TestCase
  def test_step_form_basic
    # 10 samples over [0, 9], step 2.25 → n = round(9/2.25) = 4 bins of
    # width 2.25.  9.0 folds into the last bin via `include_max: true`.
    a = CArray.float64(10).seq!(0, 1.0)
    assert_equal [0, 0, 0, 1, 1, 2, 2, 3, 3, 3], a.bin(0.0, 9.0, 2.25).to_a
  end

  def test_bins_form_basic
    # 5 bins of width 1.8 over [0, 9].
    a = CArray.float64(10).seq!(0, 1.0)
    assert_equal [0, 0, 1, 1, 2, 2, 3, 3, 4, 4], a.bin(0.0, 9.0, bins: 5).to_a
  end

  def test_step_and_bins_equivalent
    a = CArray.float64(10).seq!(0, 1.0)
    r_step = a.bin(0.0, 9.0, 1.8)          # (9-0)/1.8 = 5 bins
    r_bins = a.bin(0.0, 9.0, bins: 5)
    assert_equal r_bins.to_a, r_step.to_a
  end

  def test_step_form_temperature
    # user's motivating case: 0.5 K bins over 270..300 → 60 bins,
    # each of width 0.5.  bin k covers [270 + 0.5*k, 270 + 0.5*(k+1)).
    temp = CA_FLOAT64([270.0, 285.5, 299.5, 270.25])
    r = temp.bin(270.0, 300.0, 0.5)
    assert_equal CA_INT64, r.data_type
    assert_equal 0, r[0]
    assert_equal 31, r[1]           # (285.5-270)/0.5 = 31
    assert_equal 59, r[2]           # (299.5-270)/0.5 = 59
    assert_equal 0, r[3]
  end

  def test_bins_form_ten_equal
    # 10 uniform bins over [0, 9], integer samples 0..9. Samples land in
    # the bin whose half-open interval contains them.
    a = CArray.float64(10).seq!(0, 1.0)
    assert_equal [0, 1, 2, 3, 4, 5, 6, 7, 8, 9], a.bin(0.0, 9.0, bins: 10).to_a
  end

  def test_bins_one_degenerate
    a = CArray.float64(10).seq!(0, 1.0)
    assert_equal [0] * 10, a.bin(0.0, 9.0, bins: 1).to_a
  end

  def test_missing_both_raises
    a = CArray.float64(3).seq!
    assert_raise(ArgumentError) { a.bin(0, 10) }
  end

  def test_both_step_and_bins_raises
    a = CArray.float64(3).seq!
    assert_raise(ArgumentError) { a.bin(0, 10, 1.0, bins: 10) }
  end

  def test_bins_zero_raises
    a = CArray.float64(3).seq!
    assert_raise(ArgumentError) { a.bin(0.0, 9.0, bins: 0) }
  end

  def test_min_equals_max_degenerate
    a = CArray.float64(5).seq!(0, 1.0)
    assert_equal [0] * 5, a.bin(5.0, 5.0, bins: 5).to_a
  end

  def test_min_gt_max_raises
    a = CArray.float64(3).seq!
    assert_raise(ArgumentError) { a.bin(9.0, 0.0, bins: 5) }
  end

  def test_oob_below_default_mask
    # 5 bins of width 2 over [0, 10]: [0,2) [2,4) [4,6) [6,8) [8,10]
    # (include_max folds 10 into last bin, but 11 is above → mask).
    b = CArray.float64(3); b[] = [-1.0, 5.0, 11.0]
    r = b.bin(0.0, 10.0, bins: 5)
    assert r.has_mask?
    assert_equal true, r.is_masked[0]      # below → mask
    assert_equal false, r.is_masked[1]
    assert_equal 2, r[1]                # 5 in [4, 6) → bin 2
    assert_equal true, r.is_masked[2]      # above → mask
  end

  def test_oob_lfill
    b = CArray.float64(3); b[] = [-1.0, 5.0, 11.0]
    r = b.bin(0.0, 10.0, bins: 5, lfill: 99)
    assert_equal 99, r[0]
    assert_equal 2, r[1]
    assert_equal true, r.is_masked[2]      # above still masked
  end

  def test_oob_lfill_and_ufill
    b = CArray.float64(3); b[] = [-1.0, 5.0, 11.0]
    r = b.bin(0.0, 10.0, bins: 5, lfill: -1, ufill: 4)
    assert_equal [-1, 2, 4], r.to_a
  end

  def test_include_max_default_true
    # vmax exactly → last bin (default include_max: true).
    r = CA_FLOAT64([10.0]).bin(0.0, 10.0, bins: 5)
    assert_equal 4, r[0]
  end

  def test_include_max_false_masks_vmax
    r = CA_FLOAT64([10.0]).bin(0.0, 10.0, bins: 5, include_max: false)
    assert_equal true, r.is_masked[0]
  end

  def test_nan_propagates_to_mask
    c = CArray.float64(5); c[] = [1, Float::NAN, 3, 4, 5]
    r = c.bin(1.0, 5.0, bins: 4)
    assert r.has_mask?
    assert_equal true, r.is_masked[1]
    assert_equal 0, r[0]                # 1 in [1, 2) → 0
    assert_equal 3, r[4]                # 5 = vmax → include_max → last bin
  end

  def test_inf_propagates_to_mask
    d = CArray.float64(4); d[] = [1, Float::INFINITY, 3, 4]
    r = d.bin(1.0, 4.0, bins: 3)
    assert r.has_mask?
    assert_equal true, r.is_masked[1]
  end

  def test_integer_input
    a = CArray.int32(5).seq!(0, 2)      # [0, 2, 4, 6, 8]
    # 4 bins of width 2 over [0, 8]: [0,2) [2,4) [4,6) [6,8]
    assert_equal [0, 1, 2, 3, 3], a.bin(0.0, 8.0, bins: 4).to_a
  end

  def test_masked_input_propagates
    a = CArray.float64(5).seq!(0, 1.0)
    a[2] = UNDEF
    r = a.bin(0.0, 4.0, bins: 4)
    assert r.has_mask?
    assert_equal true, r.is_masked[2]
  end

  def test_output_dtype_is_int64
    a = CArray.float64(5).seq!(0, 1.0)
    assert_equal CA_INT64, a.bin(0.0, 4.0, bins: 3).data_type
  end

  def test_2d_input_preserves_shape
    a = CArray.float64(3, 4).seq!(0, 1.0)
    r = a.bin(0.0, 11.0, bins: 4)
    assert_equal [3, 4], r.shape
    assert_equal CA_INT64, r.data_type
  end
end

class TestClipDualFill < Test::Unit::TestCase
  def test_legacy_clamp_no_fill
    a = CArray.float64(5); a[] = [-1, 0, 1, 2, 3]
    assert_equal [0.0, 0.0, 1.0, 2.0, 2.0], a.clip(0, 2).to_a
  end

  def test_legacy_symmetric_fill
    a = CArray.float64(5); a[] = [-1, 0, 1, 2, 3]
    assert_equal [-1.0, 0.0, 1.0, 2.0, -1.0], a.clip(0, 2, -1).to_a
  end

  def test_dual_fill_asymmetric
    a = CArray.float64(5); a[] = [-1, 0, 1, 2, 3]
    assert_equal [-9.0, 0.0, 1.0, 2.0, 99.0],
                 a.clip(0, 2, lfill: -9, ufill: 99).to_a
  end

  def test_dual_fill_mask_one_side
    a = CArray.float64(5); a[] = [-1, 0, 1, 2, 3]
    result = a.clip(0, 2, lfill: UNDEF, ufill: 99)
    assert result.has_mask?
    assert_equal true, result.is_masked[0]
    assert_equal false, result.is_masked[4]
    assert_equal 99.0, result[4]
  end

  def test_lfill_only
    a = CArray.float64(5); a[] = [-1, 0, 1, 2, 3]
    result = a.clip(0, 2, lfill: -9)
    assert_equal [-9.0, 0.0, 1.0, 2.0, 3.0], result.to_a
  end

  def test_no_bound_raises
    a = CArray.float64(5).seq!(0, 1.0)
    assert_raise(ArgumentError) { a.clip(nil, nil) }
  end

  def test_clip_bang_retired
    a = CArray.float64(5).seq!(0, 1.0)
    assert_raise(NoMethodError) { a.clip!(0, 2) }
  end
end
