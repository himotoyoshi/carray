# frozen_string_literal: true
#
# W.3: wmean mkkernel migration parity + new semantic pin.
#
# Validates the wmean kernel (= mkkernel array_arg framework with
# state+finish form for sum + den, public_method: true).  Same 3.0
# breaking semantics as wsum (W.2), plus normalisation `sum / den`
# specific edge cases.

require "test/unit"
require "carray"

class TestW3Wmean < Test::Unit::TestCase

  # ---- basic correctness -----------------------------------------------

  def test_uniform_weights_equals_mean
    a = CArray.float64(5).seq!(1)            # [1, 2, 3, 4, 5]
    w = CArray.float64(5) { 1.0 }
    # uniform weights -> mean(a) = 3.0
    assert_in_delta(3.0, a.wmean(w), 1e-12)
  end

  def test_weighted_mean_int
    a = CArray.int32(10).seq!(1)             # [1..10]
    w = a.reverse                            # [10..1]
    # Σ(v*w) = 1*10 + 2*9 + ... + 10*1 = 220, Σw = 55, mean = 220/55 = 4
    assert_in_delta(4.0, a.wmean(w), 1e-12)
  end

  def test_weighted_mean_float
    a = CArray.float64(5) { |i| [1.0, 2.0, 3.0, 4.0, 5.0][i] }
    w = CArray.float64(5) { |i| [0.1, 0.2, 0.3, 0.4, 0.5][i] }
    # Σ(v*w) = 5.5, Σw = 1.5, mean = 3.666...
    assert_in_delta(5.5 / 1.5, a.wmean(w), 1e-12)
  end

  def test_returns_float_for_full_reduction
    a = CArray.int32(3) { |i| (i + 1) }
    w = CArray.int32(3) { 1 }
    assert_kind_of(Float, a.wmean(w))
  end

  # ---- per-axis (W.3 newly supported) ----------------------------------

  def test_per_axis_2d_axis0_uniform
    a = CArray.float64(2, 3) { |i, j| 1.0 + i * 3 + j }   # [[1,2,3],[4,5,6]]
    w = CArray.float64(2, 3) { 1.0 }
    # axis 0 reduce: per-col mean = [(1+4)/2, (2+5)/2, (3+6)/2]
    assert_equal([2.5, 3.5, 4.5], a.wmean(w, axis: 0).to_a)
  end

  def test_per_axis_2d_axis1_weighted
    a = CArray.float64(2, 3) { |i, j| 1.0 + i * 3 + j }
    w = CArray.float64(2, 3) { |i, j| (i + 1).to_f }       # row 0 weight 1, row 1 weight 2
    # per-row: row 0 = (1+2+3)/(1+1+1) = 2.0, row 1 = (4*2+5*2+6*2)/(2+2+2) = 5.0
    r = a.wmean(w, axis: 1)
    assert_in_delta(2.0, r[0], 1e-12)
    assert_in_delta(5.0, r[1], 1e-12)
  end

  # ---- mask semantics --------------------------------------------------

  def test_self_mask_normalised_by_visible_weights
    # mask = {0}, visible cells [2,3,4], weights uniform 1.0
    a = CArray.float64(4) { |i| (i + 1).to_f }
    a[0] = UNDEF
    w = CArray.float64(4) { 1.0 }
    # mean of valid = (2+3+4)/3 = 3.0
    assert_in_delta(3.0, a.wmean(w), 1e-12)
  end

  def test_weights_mask_overlay
    a = CArray.float64(4) { |i| (i + 1).to_f }
    w = CArray.float64(4) { 1.0 }
    w[2] = UNDEF
    # overlay -> skip cell 2 -> sum=(1+2+4)=7, den=3, mean=7/3
    assert_in_delta(7.0 / 3, a.wmean(w), 1e-12)
  end

  def test_combined_mask_legacy_parity
    # legacy feature_stat_spec.rb wmean case: 200.0 / 44
    a = CArray.int32(10).seq!(1)
    w = a.reverse                            # [10..1]
    a[0] = UNDEF                             # mask cell 0
    w[9] = UNDEF                             # mask cell 9 (= original index)
    # effective mask = {0, 9}
    # valid cells: a[1..8] * w[1..8] = 2*9 + 3*8 + 4*7 + ... + 9*2
    #            = 18 + 24 + 28 + 30 + 30 + 28 + 24 + 18 = 200
    # den: w[1..8] = 9+8+7+6+5+4+3+2 = 44
    # mean = 200 / 44
    assert_in_delta(200.0 / 44, a.wmean(w), 1e-12)
  end

  def test_all_masked_returns_undef
    a = CArray.float64(3) { 1.0 }
    a[0] = a[1] = a[2] = UNDEF
    w = CArray.float64(3) { 1.0 }
    assert_equal(UNDEF, a.wmean(w))
  end

  # ---- min_count semantic (= W.2 same) --------------------------------

  def test_min_count_requires_min_valid
    a = CArray.int32(5).seq!(1)
    a.mask = 0
    a[0] = UNDEF
    a[4] = UNDEF
    w = CArray.int32(5) { 1 }
    # valid_count = 3, values = a[1..3] = [2,3,4], mean = 9/3 = 3
    assert_in_delta(3.0, a.wmean(w, min_count: 3), 1e-12)
    assert_equal(UNDEF, a.wmean(w, min_count: 4))
  end

  def test_fill_value_substitutes_undef
    a = CArray.float64(3) { 1.0 }
    a[0] = a[1] = a[2] = UNDEF
    w = CArray.float64(3) { 1.0 }
    assert_equal(-9999.0, a.wmean(w, fill_value: -9999.0))
  end

  # ---- division edge cases --------------------------------------------

  def test_zero_weights_yields_nan
    # Σw = 0 + 0 = 0, Σ(v*w) = 0; finish: 0/0 = NaN.  Legacy proc_wmean
    # had identical behavior (no division check).
    a = CArray.float64(2) { 1.0 }
    w = CArray.float64(2) { 0.0 }
    r = a.wmean(w)
    assert_true(r.nan?, "wmean with zero weights should be NaN (got #{r})")
  end

  # ---- 3.0 breaking: complex rejection --------------------------------

  def test_complex_source_raises
    cmplx_a = CArray.cmplx128(3) { Complex(1.0, 0.0) }
    cmplx_w = CArray.cmplx128(3) { Complex(1.0, 0.0) }
    assert_raise(CArray::DataTypeError) { cmplx_a.wmean(cmplx_w) }
  end if CArray::HAVE_COMPLEX

  # CA_OBJECT is now handled via the object_escape hook (runtime.rb
  # __wmean_object__), not rejected.  See test_object_wsum_wmean.
  def test_object_source_works
    obj_a = CArray.object(3) { |i| (i + 1).to_f }
    obj_w = CArray.object(3) { 1.0 }
    assert_in_delta(2.0, obj_a.wmean(obj_w), 1e-12)
  end

  # ---- shape / data_type validation ---------------------------------------

  def test_shape_mismatch_raises
    # rev5 strict (PROPOSAL_REDUCTION_PER_FIBER_AUX_OPERAND): shape validation
    # raises ArgumentError (= Ruby idiom)。legacy RuntimeError から flip。
    a = CArray.float64(3) { |i| i.to_f }
    w = CArray.float64(4) { |i| i.to_f }
    assert_raise(ArgumentError) { a.wmean(w) }
  end

  def test_missing_weights_raises
    a = CArray.float64(3) { |i| i.to_f }
    assert_raise(ArgumentError) { a.wmean }
  end

  # ---- view source -----------------------------------------------------

  def test_view_source_via_transpose
    base = CArray.float64(2, 3) { |i, j| 1.0 + i * 3 + j }
    a = base.transpose                       # [3, 2]
    w = CArray.float64(3, 2) { 1.0 }
    # mean over all cells = 21/6 = 3.5
    assert_in_delta(3.5, a.wmean(w), 1e-12)
  end
end
