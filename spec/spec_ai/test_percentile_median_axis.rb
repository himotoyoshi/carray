# frozen_string_literal: true
#
# SO.4 — percentile / median axis: kwarg tests
# (PROPOSAL_SORT_AXIS rev7).
#
# Pins:
#   - median(axis: k) returns CArray of shape (self.shape minus axis),
#     or scalar Float for 1-D input
#   - percentile(p, axis: k) returns [CArray] (1-element Array) for
#     consistency with the flat percentile contract (= always Array)
#   - Linear interp at fractional position (NumPy method=:linear)
#   - Edge cases: p == 0 (min) / p == 100 (max) / n == 1 (single cell)
#   - Negative axis (= ndim + axis)
#   - 3.0 restrictions raise ArgumentError (multi-p, min_count,
#     fill_value with axis:; positional argv on median with axis:)
#   - axis out-of-range raise
#   - Empty axis (size 0) raise
#   - p out-of-range raise

require "test/unit"
require "carray"

class TestPercentileMedianAxis < Test::Unit::TestCase

  # ---- zero-length reduction axis ---------------------------------------
  # A 0-length axis has nothing to take an order statistic of.  With no
  # identity, every reduced cell is UNDEF (matching mean/min), not a raise.
  def test_zero_length_axis_yields_undef_cells
    z = CArray.float64(0, 3)              # shape (0, 3): reduce axis 0
    [z.percentile(50, axis: 0), z.median(axis: 0)].each do |r|
      assert_equal(3, r.elements)
      assert_equal([true, true, true], r.is_masked.to_a)
    end
    # multi-p and quantile: one all-masked result per requested p
    z.percentile([25, 50, 75], axis: 0).each { |r| assert_equal([true, true, true], r.is_masked.to_a) }
    z.quantile(axis: 0).each { |r| assert_equal([true, true, true], r.is_masked.to_a) }
    # keep_axis keeps the reduced axis as length 1
    k = z.percentile(50, axis: 0, keep_axis: true)
    assert_equal([1, 3], k.shape)
    assert_equal([true, true, true], k.is_masked.to_a.flatten)
  end

  # ---- median 1-D --------------------------------------------------------

  def test_median_1d_odd
    a = CArray.float64(5)
    [1.0, 5.0, 3.0, 2.0, 4.0].each_with_index { |v, i| a[i] = v }
    assert_in_delta(3.0, a.median(axis: 0), 1e-12)
  end

  def test_median_1d_even
    a = CArray.float64(4)
    [4.0, 1.0, 3.0, 2.0].each_with_index { |v, i| a[i] = v }
    # sorted = [1,2,3,4], median = (2+3)/2 = 2.5
    assert_in_delta(2.5, a.median(axis: 0), 1e-12)
  end

  # ---- median N-D --------------------------------------------------------

  def test_median_2d_axis_0
    a = CArray.float64(3, 4)
    [[5,4,3,2], [10,9,8,7], [15,14,13,12]].each_with_index do |row, i|
      row.each_with_index { |v, j| a[i, j] = v.to_f }
    end
    # Per-column: col 0 = [5,10,15], med = 10
    #             col 1 = [4,9,14],  med = 9
    #             col 2 = [3,8,13],  med = 8
    #             col 3 = [2,7,12],  med = 7
    assert_equal([10.0, 9.0, 8.0, 7.0], a.median(axis: 0).to_a)
  end

  def test_median_2d_axis_1
    a = CArray.float64(3, 5)
    [[5,4,3,2,1], [10,9,8,7,6], [15,14,13,12,11]].each_with_index do |row, i|
      row.each_with_index { |v, j| a[i, j] = v.to_f }
    end
    # Per-row median: each row has 5 elements, median = sorted[2]
    # row 0 sorted [1,2,3,4,5] -> 3
    # row 1 sorted [6,7,8,9,10] -> 8
    # row 2 sorted [11,12,13,14,15] -> 13
    assert_equal([3.0, 8.0, 13.0], a.median(axis: 1).to_a)
  end

  def test_median_3d_axis_middle
    a = CArray.float64(2, 5, 3).seq
    m = a.median(axis: 1)
    assert_equal([2, 3], m.dim.to_a)
    # Each (i, *, k) fiber has 5 consecutive values (because seq is row-major
    # in (2,5,3), the axis-1 fiber values jump by dim[2]=3 each step)
    # so median is the middle (= 3rd) element
    2.times do |i|
      3.times do |k|
        fiber = (0...5).map { |j| a[i, j, k] }
        assert_in_delta(fiber.sort[2], m[i, k], 1e-12,
                        "(i=#{i}, k=#{k}) fiber=#{fiber}")
      end
    end
  end

  def test_median_negative_axis
    a = CArray.float64(2, 3, 4).seq
    assert_equal(a.median(axis: 2).to_a, a.median(axis: -1).to_a)
    assert_equal(a.median(axis: 0).to_a, a.median(axis: -3).to_a)
  end

  # ---- percentile 1-D ---------------------------------------------------

  def test_percentile_1d_50
    a = CArray.float64(5)
    [1.0, 5.0, 3.0, 2.0, 4.0].each_with_index { |v, i| a[i] = v }
    result = a.percentile(50, axis: 0)
    assert_kind_of(CArray, result)
    assert_in_delta(3.0, result[0], 1e-12)
  end

  def test_percentile_1d_0_and_100
    a = CArray.float64(4)
    [3.0, 1.0, 4.0, 2.0].each_with_index { |v, i| a[i] = v }
    assert_in_delta(1.0, a.percentile(0, axis: 0)[0], 1e-12)
    assert_in_delta(4.0, a.percentile(100, axis: 0)[0], 1e-12)
  end

  def test_percentile_1d_linear_interp
    # 4 sorted values: [10, 20, 30, 40]; p=25 -> position (4-1)*0.25 = 0.75
    # lower idx 0 (=10), upper idx 1 (=20), frac = 0.75
    # result = 0.25*10 + 0.75*20 = 17.5
    a = CArray.float64(4)
    [10.0, 30.0, 20.0, 40.0].each_with_index { |v, i| a[i] = v }
    assert_in_delta(17.5, a.percentile(25, axis: 0)[0], 1e-12)
  end

  # ---- percentile N-D ---------------------------------------------------

  def test_percentile_2d_axis_1_returns_carray
    a = CArray.float64(3, 5)
    [[5,4,3,2,1], [10,9,8,7,6], [15,14,13,12,11]].each_with_index do |row, i|
      row.each_with_index { |v, j| a[i, j] = v.to_f }
    end
    result = a.percentile(50, axis: 1)
    assert_kind_of(CArray, result)
    assert_equal([3.0, 8.0, 13.0], result.to_a)
  end

  def test_percentile_3d_axis_middle
    a = CArray.float64(2, 4, 3).seq
    result = a.percentile(50, axis: 1)
    assert_kind_of(CArray, result)
    assert_equal([2, 3], result.shape.to_a)
  end

  # ---- restrictions / errors --------------------------------------------

  def test_median_positional_with_axis_rejected
    a = CArray.float64(5).seq
    assert_raise(ArgumentError) { a.median(0, axis: 0) }
  end

  def test_percentile_multi_p_with_axis_accepted_in_so4plus
    # SO.4+ (rev8): multi-p with axis is now supported and returns
    # Array of CArrays.  Detailed coverage in test_percentile_so4plus.rb.
    a = CArray.float64(3, 5).seq
    result = a.percentile(25, 75, axis: 1)
    assert_kind_of(Array, result)
    assert_equal(2, result.length)
    assert_kind_of(CArray, result[0])
    assert_kind_of(CArray, result[1])
  end

  def test_percentile_axis_out_of_range
    a = CArray.float64(3, 4).seq
    assert_raise(ArgumentError) { a.percentile(50, axis: 5) }
    assert_raise(ArgumentError) { a.percentile(50, axis: -5) }
  end

  def test_median_axis_out_of_range
    a = CArray.float64(3, 4).seq
    assert_raise(ArgumentError) { a.median(axis: 5) }
    assert_raise(ArgumentError) { a.median(axis: -5) }
  end

  def test_percentile_p_out_of_range
    a = CArray.float64(5).seq
    assert_raise(ArgumentError) { a.percentile(-1, axis: 0) }
    assert_raise(ArgumentError) { a.percentile(101, axis: 0) }
  end

  def test_median_min_count_with_axis
    # min_count is honoured per fiber: a fiber with fewer present cells than
    # min_count reduces to UNDEF.  Row 0 has 2 present (< 3) -> UNDEF; row 1
    # has 4 present (>= 3) -> median 12.0.
    a = CArray.float64(2, 5) { |i, j| 10.0*i + j }
    a[0, 1] = UNDEF; a[0, 2] = UNDEF; a[0, 3] = UNDEF   # row0 present [0,4]
    a[1, 2] = UNDEF                                       # row1 present [10,11,13,14]
    m = a.median(axis: 1, min_count: 3)
    assert_equal [UNDEF, 12.0], m.to_a
    assert_equal true, m.has_mask?
  end

  def test_percentile_min_count_with_axis
    a = CArray.float64(2, 5) { |i, j| 10.0*i + j }
    a[0, 1] = UNDEF; a[0, 2] = UNDEF; a[0, 3] = UNDEF
    a[1, 2] = UNDEF
    m = a.percentile(50, axis: 1, min_count: 3)
    assert_equal [UNDEF, 12.0], m.to_a
  end

  def test_percentile_fill_value_with_axis
    # fill_value replaces the UNDEF cell instead of masking it.
    a = CArray.float64(2, 5) { |i, j| 10.0*i + j }
    a[0, 1] = UNDEF; a[0, 2] = UNDEF; a[0, 3] = UNDEF
    a[1, 2] = UNDEF
    m = a.percentile(50, axis: 1, min_count: 3, fill_value: 99)
    assert_equal [99.0, 12.0], m.to_a
    assert_equal false, m.has_mask?
  end

  # ---- flat path remains intact (backward compat) ------------------------

  def test_flat_median_still_works
    a = CArray.float64(5)
    [1.0, 5.0, 3.0, 2.0, 4.0].each_with_index { |v, i| a[i] = v }
    assert_in_delta(3.0, a.median, 1e-12)
  end

  def test_flat_percentile_single_p_unwraps
    a = CArray.float64(5)
    [1.0, 5.0, 3.0, 2.0, 4.0].each_with_index { |v, i| a[i] = v }
    result = a.percentile(50)
    assert_kind_of(Float, result)
    assert_in_delta(3.0, result, 1e-12)
  end

  def test_flat_percentile_multi_p_still_works
    a = CArray.float64(5)
    [1.0, 5.0, 3.0, 2.0, 4.0].each_with_index { |v, i| a[i] = v }
    result = a.percentile(0, 50, 100)
    assert_equal(3, result.length)
    assert_in_delta(1.0, result[0], 1e-12)
    assert_in_delta(3.0, result[1], 1e-12)
    assert_in_delta(5.0, result[2], 1e-12)
  end

  # ---- view chain transparency ------------------------------------------

  def test_median_on_view_chain
    a = CArray.float64(4, 3).seq
    # 行: [0,1,2], [3,4,5], [6,7,8], [9,10,11]
    # transpose: shape (3, 4)
    tv = a.transpose
    m = tv.median(axis: 1)
    # Per-row median of tv (= per-column median of a)
    # tv row 0 = [0, 3, 6, 9] sorted -> median = (3+6)/2 = 4.5
    # tv row 1 = [1, 4, 7, 10] -> 5.5
    # tv row 2 = [2, 5, 8, 11] -> 6.5
    assert_equal([4.5, 5.5, 6.5], m.to_a)
  end

  # ---- per-axis mask support (B9): each fiber uses its own n_present -------

  def test_percentile_axis_mask_multi_p_not_silent_wrong
    # Regression for the multi-p / quantile silent-wrong path: before the
    # per-fiber select, the multi-p sort_copy path used a uniform n (= axis
    # length) and picked the wrong k for masked fibers, returning a plausible
    # but wrong value without raising.  Row 0 has one masked cell so its
    # present run is [10,20,30] (n=3, median 20); a uniform n=4 would give 25.
    a = CA_DOUBLE([[10, 20, 30, 99], [40, 50, 60, 70]])
    a[0, 3] = UNDEF
    assert_equal [[20.0, 55.0], [20.0, 55.0]], a.percentile(50, 50, axis: 1).map(&:to_a)
    assert_equal [[10.0, 40.0], [15.0, 47.5], [20.0, 55.0], [25.0, 62.5], [30.0, 70.0]],
                 a.quantile(axis: 1).map(&:to_a)
  end

  def test_median_axis_all_masked_fiber_is_undef
    # A fully masked fiber has no present value: order statistic is UNDEF
    # (not a raise), matching mean(axis:).  The output gains a mask only
    # because one cell is UNDEF.
    b = CA_DOUBLE([[10, 20], [30, 40]])
    b[0, 0] = UNDEF; b[0, 1] = UNDEF
    m = b.median(axis: 1)
    assert_equal [UNDEF, 35.0], m.to_a
    assert_equal true, m.has_mask?
  end

  def test_percentile_axis_mask_keep_axis
    a = CA_DOUBLE([[10, 20, 30, 99], [40, 50, 60, 70]])
    a[0, 3] = UNDEF
    k = a.percentile(50, axis: 1, keep_axis: true)
    assert_equal [2, 1], k.shape
    assert_equal [[20.0], [55.0]], k.to_a
  end

end
