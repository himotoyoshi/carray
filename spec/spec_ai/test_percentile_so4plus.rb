# frozen_string_literal: true
#
# SO.4+ — percentile multi-p + method: tests (PROPOSAL_SORT_AXIS rev8).
#
# Pins:
#   - Multi-p variadic with axis: returns Array of CArrays (one per p)
#   - Array p / CArray p with axis: auto-flatten to variadic, same return
#   - method: 5 NumPy methods (:linear default / :lower / :higher /
#     :nearest / :midpoint), each verified against known sorted input
#   - method validation (unknown method raises)
#   - p validation (any out-of-range raises)
#   - Empty pers raises
#   - SO.4 single-p path remains intact (= backward compat)
#   - Flat path unaffected (= multi-p flat still returns Array of Floats)

require "test/unit"
require "carray"

class TestPercentileSO4Plus < Test::Unit::TestCase

  # ---- Multi-p variadic + axis -----------------------------------------

  def test_multi_p_variadic_1d
    a = CArray.float64(11)
    (0..10).each { |i| a[i] = i.to_f }    # [0..10]
    result = a.percentile(0, 25, 50, 75, 100, axis: 0)
    assert_kind_of(Array, result)
    assert_equal(5, result.length)
    [0.0, 2.5, 5.0, 7.5, 10.0].each_with_index do |expected, i|
      assert_in_delta(expected, result[i], 1e-12, "p index #{i}")
    end
  end

  def test_multi_p_variadic_2d
    a = CArray.float64(3, 11).seq
    # Each row = [11i, 11i+1, ..., 11i+10] (sorted ascending already)
    # 25th pct of row i = 11i + 2.5 (linear interp at idx 2.5)
    # 75th pct of row i = 11i + 7.5
    result = a.percentile(25, 75, axis: 1)
    assert_equal(2, result.length)
    assert_equal([2.5, 13.5, 24.5], result[0].to_a)
    assert_equal([7.5, 18.5, 29.5], result[1].to_a)
  end

  # ---- Array p / CArray p auto-flatten ---------------------------------

  def test_array_p_with_axis
    a = CArray.float64(11)
    (0..10).each { |i| a[i] = i.to_f }
    result = a.percentile([25, 50, 75], axis: 0)
    assert_equal(3, result.length)
    assert_in_delta(2.5, result[0], 1e-12)
    assert_in_delta(5.0, result[1], 1e-12)
    assert_in_delta(7.5, result[2], 1e-12)
  end

  def test_carray_p_with_axis
    a = CArray.float64(11)
    (0..10).each { |i| a[i] = i.to_f }
    ps = CArray.float64(3)
    [25, 50, 75].each_with_index { |v, i| ps[i] = v }
    result = a.percentile(ps, axis: 0)
    assert_equal(3, result.length)
    assert_in_delta(2.5, result[0], 1e-12)
    assert_in_delta(5.0, result[1], 1e-12)
    assert_in_delta(7.5, result[2], 1e-12)
  end

  # ---- method: 5 variants ----------------------------------------------

  # For input [0..10] (sorted), n=11, p=25 -> f = (n-1)*p/100 = 2.5
  # -> k = 2, r = 0.5
  #   :linear    -> (1-0.5)*2 + 0.5*3 = 2.5
  #   :lower     -> sorted[k] = 2.0
  #   :higher    -> sorted[k+1] = 3.0
  #   :nearest   -> 0.5 ties -> banker's (round to even) -> k=2 (even) -> 2.0
  #   :midpoint  -> (sorted[k] + sorted[k+1]) / 2 = 2.5

  def test_method_linear_default
    a = CArray.float64(11)
    (0..10).each { |i| a[i] = i.to_f }
    assert_in_delta(2.5, a.percentile(25, axis: 0)[0], 1e-12)
    assert_in_delta(2.5, a.percentile(25, axis: 0, method: :linear)[0], 1e-12)
  end

  def test_method_lower
    a = CArray.float64(11)
    (0..10).each { |i| a[i] = i.to_f }
    assert_in_delta(2.0, a.percentile(25, axis: 0, method: :lower)[0], 1e-12)
  end

  def test_method_higher
    a = CArray.float64(11)
    (0..10).each { |i| a[i] = i.to_f }
    assert_in_delta(3.0, a.percentile(25, axis: 0, method: :higher)[0], 1e-12)
  end

  def test_method_nearest_at_half_rounds_to_even
    a = CArray.float64(11)
    (0..10).each { |i| a[i] = i.to_f }
    # p=25 -> r=0.5, k=2 (even) -> idx 2 -> 2.0
    assert_in_delta(2.0, a.percentile(25, axis: 0, method: :nearest)[0], 1e-12)
    # p=75 -> r=0.5, k=7 (odd) -> idx 8 -> 8.0
    assert_in_delta(8.0, a.percentile(75, axis: 0, method: :nearest)[0], 1e-12)
  end

  def test_method_nearest_below_half
    a = CArray.float64(11)
    (0..10).each { |i| a[i] = i.to_f }
    # p=24 -> f = 2.4, k=2, r=0.4 < 0.5 -> idx 2 -> 2.0
    assert_in_delta(2.0, a.percentile(24, axis: 0, method: :nearest)[0], 1e-12)
  end

  def test_method_nearest_above_half
    a = CArray.float64(11)
    (0..10).each { |i| a[i] = i.to_f }
    # p=26 -> f = 2.6, k=2, r=0.6 > 0.5 -> idx 3 -> 3.0
    assert_in_delta(3.0, a.percentile(26, axis: 0, method: :nearest)[0], 1e-12)
  end

  def test_method_midpoint
    a = CArray.float64(11)
    (0..10).each { |i| a[i] = i.to_f }
    assert_in_delta(2.5, a.percentile(25, axis: 0, method: :midpoint)[0], 1e-12)
    # p=30 -> f=3.0 -> k=3, r=0 -> midpoint(sorted[3], sorted[4]) = 3.5
    assert_in_delta(3.5, a.percentile(30, axis: 0, method: :midpoint)[0], 1e-12)
  end

  # ---- multi-p × method combined ---------------------------------------

  def test_multi_p_with_method_lower_2d
    a = CArray.float64(2, 11).seq
    res = a.percentile(25, 75, axis: 1, method: :lower)
    # Row i sorted = [11i, 11i+1, ..., 11i+10]
    # p=25 method=:lower -> idx 2 -> 11i + 2
    # p=75 method=:lower -> idx 7 -> 11i + 7
    assert_equal([2.0, 13.0], res[0].to_a)
    assert_equal([7.0, 18.0], res[1].to_a)
  end

  # ---- validation errors -----------------------------------------------

  def test_unknown_method_raises
    a = CArray.float64(5).seq
    assert_raise(ArgumentError) { a.percentile(50, axis: 0, method: :foo) }
    assert_raise(ArgumentError) { a.percentile(50, axis: 0, method: :inverted_cdf) }
  end

  def test_p_out_of_range_in_multi_p
    a = CArray.float64(5).seq
    # One bad p in the middle of valid ones
    assert_raise(ArgumentError) { a.percentile(25, 150, 75, axis: 0) }
    assert_raise(ArgumentError) { a.percentile(-5, 50, axis: 0) }
  end

  def test_empty_pers_raises
    a = CArray.float64(5).seq
    assert_raise(ArgumentError) { a.percentile([], axis: 0) }
  end

  # ---- backward compat -------------------------------------------------

  def test_single_p_axis_returns_carray
    a = CArray.float64(11)
    (0..10).each { |i| a[i] = i.to_f }
    r = a.percentile(50, axis: 0)
    assert_kind_of(CArray, r)
    assert_in_delta(5.0, r[0], 1e-12)
  end

  def test_flat_multi_p_unchanged
    a = CArray.float64(11)
    (0..10).each { |i| a[i] = i.to_f }
    r = a.percentile(25, 50, 75)
    assert_kind_of(Array, r)
    assert_equal(3, r.length)
    assert_in_delta(2.5, r[0], 1e-12)
    assert_in_delta(5.0, r[1], 1e-12)
    assert_in_delta(7.5, r[2], 1e-12)
  end

  def test_quantile_flat
    a = CArray.float64(11)
    (0..10).each { |i| a[i] = i.to_f }
    # quantile = percentile(0, 25, 50, 75, 100), flat -> Array<Float> len 5
    q = a.quantile
    assert_kind_of(Array, q)
    assert_equal(5, q.length)
    [0.0, 2.5, 5.0, 7.5, 10.0].each_with_index do |exp, i|
      assert_in_delta(exp, q[i], 1e-12, "q[#{i}]")
    end
  end

  def test_quantile_per_axis
    # 2-D input, axis: 1 -> Array<CArray> len 5, each shape (rows,)
    a = CArray.float64(3, 11).seq
    q = a.quantile(axis: 1)
    assert_kind_of(Array, q)
    assert_equal(5, q.length)
    q.each { |c| assert_kind_of(CArray, c); assert_equal([3], c.shape.to_a) }
    # Row i sorted = [11i .. 11i+10]; p0=11i, p25=11i+2.5, ..., p100=11i+10
    assert_equal([0.0, 11.0, 22.0], q[0].to_a)
    assert_equal([2.5, 13.5, 24.5], q[1].to_a)
    assert_equal([5.0, 16.0, 27.0], q[2].to_a)
    assert_equal([7.5, 18.5, 29.5], q[3].to_a)
    assert_equal([10.0, 21.0, 32.0], q[4].to_a)
  end

  def test_quantile_per_axis_keep_axis
    a = CArray.float64(3, 11).seq
    q = a.quantile(axis: 1, keep_axis: true)
    assert_equal(5, q.length)
    q.each { |c| assert_equal([3, 1], c.shape.to_a) }
  end

  def test_quantile_positional_rejected
    a = CArray.float64(5).seq
    assert_raise(ArgumentError) { a.quantile(50) }
  end

  # ---- single-p unwrap (flat and per-axis) ------------------------------

  def test_single_p_array_form_unwraps
    a = CArray.float64(11)
    (0..10).each { |i| a[i] = i.to_f }
    # percentile([50]) -> Float (single-p Array unwraps)
    assert_kind_of(Float, a.percentile([50]))
    assert_in_delta(5.0, a.percentile([50]), 1e-12)
    # percentile(CArray[50]) -> Float
    ps = CArray.float64(1); ps[0] = 50.0
    assert_in_delta(5.0, a.percentile(ps), 1e-12)
  end

  def test_single_p_axis_carray_form_unwraps
    a = CArray.float64(3, 11).seq
    r = a.percentile([50], axis: 1)
    assert_kind_of(CArray, r)
    assert_equal([5.0, 16.0, 27.0], r.to_a)
  end

end
