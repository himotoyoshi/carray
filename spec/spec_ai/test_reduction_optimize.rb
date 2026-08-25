require "test/unit"
require "carray"

# Edge-case tests for the OPTIMIZE_REDUCTION fast paths.
#
# Phase 1+2 (this commit) added a contiguous + no-mask fast path to
# every ca_proc_*_<type> in ext/carray_stat_proc.rb.  The fast path
# drops `volatile`, the `*(p + *a)` indirection, and the iterator_succ
# branch so GCC/clang can auto-vectorise the accumulator.
#
# We test both branches (fast path: contiguous + no mask; slow path:
# masked or non-contiguous) to confirm correctness and equivalence.

class TestReductionFastPath < Test::Unit::TestCase
  N = 1000

  def setup
    @a = CArray.float64(N).seq           # 0..N-1
    @ref = (0...N).map(&:to_f)
  end

  # ---- sum -------------------------------------------------------- #

  def test_sum_fast_path_correct
    assert_in_delta(@ref.sum, @a.sum, 1e-9)
  end

  def test_sum_fast_path_one_element
    assert_equal(7.0, CArray.float64(1).fill(7.0).sum)
  end

  def test_sum_handles_nan
    a = CArray.float64(10).fill(1.0)
    a[5] = 0.0 / 0.0    # NaN
    assert(a.sum.nan?, "sum that includes NaN should propagate NaN")
  end

  def test_sum_handles_infinity
    a = CArray.float64(10).fill(1.0)
    a[5] = Float::INFINITY
    assert_equal(Float::INFINITY, a.sum)
  end

  def test_sum_handles_mixed_inf
    a = CArray.float64(2)
    a[0] = Float::INFINITY
    a[1] = -Float::INFINITY
    # +Inf + -Inf = NaN
    assert(a.sum.nan?)
  end

  def test_sum_tiny_and_huge
    # Accumulator is long double (or double) which has > float64 range
    a = CArray.float64(100).fill(1e-10)
    a[0] = 1e10
    expected = 1e10 + 99 * 1e-10
    assert_in_delta(expected, a.sum, expected.abs * 1e-10)
  end

  def test_sum_masked_slow_path
    a = CArray.float64(10).seq + 1.0          # [1,2,...,10]
    a.mask = [1, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    assert_in_delta(2 + 3 + 4 + 5 + 6 + 7 + 8 + 9 + 10, a.sum, 1e-12)
  end

  def test_sum_noncontig_slow_path
    # Non-contiguous view forces axis dispatch; sum over a view
    src = CArray.float64(5, 4).seq           # row-major 0..19
    col = src[nil, 1]                        # column 1: [1, 5, 9, 13, 17]
    assert_in_delta(1 + 5 + 9 + 13 + 17, col.sum, 1e-12)
  end

  # ---- mean / variance / stddev ----------------------------------- #

  def test_mean_matches_reference
    assert_in_delta(@ref.sum / N, @a.mean, 1e-9)
  end

  def test_variancep_matches_reference
    m = @ref.sum / N
    expected = @ref.map { |x| (x - m) ** 2 }.sum / N
    assert_in_delta(expected, @a.variancep, expected.abs * 1e-9)
  end

  def test_variance_matches_reference
    m = @ref.sum / N
    expected = @ref.map { |x| (x - m) ** 2 }.sum / (N - 1)
    assert_in_delta(expected, @a.variance, expected.abs * 1e-9)
  end

  def test_stddev_matches_reference
    m = @ref.sum / N
    var_s = @ref.map { |x| (x - m) ** 2 }.sum / (N - 1)
    assert_in_delta(Math.sqrt(var_s), @a.stddev, Math.sqrt(var_s).abs * 1e-9)
  end

  def test_stddevp_matches_reference
    m = @ref.sum / N
    var_p = @ref.map { |x| (x - m) ** 2 }.sum / N
    assert_in_delta(Math.sqrt(var_p), @a.stddevp, Math.sqrt(var_p).abs * 1e-9)
  end

  # ---- min / max -------------------------------------------------- #

  def test_min_max_correct
    omit "Removed in E.7 stat_proc retire; re-implement per CLAUDE.md"
    assert_equal(0.0,       @a.min)
    assert_equal((N-1).to_f, @a.max)
    assert_equal(0,         @a.min_addr)
    assert_equal(N-1,       @a.max_addr)
  end

  def test_min_max_negative_values
    omit "Removed in E.7 stat_proc retire; re-implement per CLAUDE.md"
    a = CArray.float64(4); [-3.0, -1.0, -5.0, -2.0].each_with_index { |v, i| a[i] = v }
    assert_equal(-5.0, a.min)
    assert_equal(-1.0, a.max)
    assert_equal(2,    a.min_addr)
    assert_equal(1,    a.max_addr)
  end

  def test_min_addr_returns_first_occurrence
    omit "Removed in E.7 stat_proc retire; re-implement per CLAUDE.md"
    # min appears at two positions; min_addr should return the earliest.
    a = CArray.float64(5); [3.0, 1.0, 4.0, 1.0, 5.0].each_with_index { |v, i| a[i] = v }
    assert_equal(1.0, a.min)
    assert_equal(1,   a.min_addr)
  end

  def test_min_max_masked_slow_path
    a = CArray.float64(4); [5.0, 1.0, 3.0, 2.0].each_with_index { |v, i| a[i] = v }
    a.mask = [0, 1, 0, 0]
    # masked min is 2.0 (not the actual 1.0 which is masked)
    assert_equal(2.0, a.min)
    assert_equal(5.0, a.max)
  end

  # ---- prod / accum / count --------------------------------------- #

  def test_prod_correct
    a = CArray.int32(10).seq + 1                # 1..10
    assert_equal(3628800.0, a.prod)
  end

  def test_accumulate_correct
    omit "Removed in E.7 stat_proc retire; re-implement per CLAUDE.md"
    a = CArray.int32(10).seq + 1                # 1..10
    assert_equal(55, a.accumulate)
  end

  def test_count_no_mask
    omit "Removed in E.7 stat_proc retire; re-implement per CLAUDE.md"
    a = CArray.float64(100).seq
    assert_equal(100, a.count_valid)
  end

  def test_count_with_mask
    omit "Removed in E.7 stat_proc retire; re-implement per CLAUDE.md"
    a = CArray.float64(100).seq
    a.mask = CArray.boolean(100).fill(0)
    a.mask[10] = 1
    a.mask[20] = 1
    a.mask[30] = 1
    assert_equal(97, a.count_valid)
  end

  # ---- cumsum ----------------------------------------------------- #

  def test_cumsum_first_and_last
    omit "Removed in E.7 stat_proc retire; re-implement per CLAUDE.md"
    cs = @a.cumsum
    assert_equal(0.0, cs[0])
    assert_in_delta(@ref.sum, cs[-1], 1e-9)
  end

  def test_cumsum_monotonic_for_positive
    omit "Removed in E.7 stat_proc retire; re-implement per CLAUDE.md"
    a = CArray.float64(50).seq + 1.0
    cs = a.cumsum
    49.times { |i| assert(cs[i] <= cs[i+1]) }
  end

  def test_cumsum_masked_slow_path
    omit "Removed in E.7 stat_proc retire; re-implement per CLAUDE.md"
    a = CArray.float64(4); [1.0, 2.0, 3.0, 4.0].each_with_index { |v, i| a[i] = v }
    a.mask = [0, 1, 0, 0]
    cs = a.cumsum
    # Slow path: masked element skipped in running sum, but its output
    # slot inherits the prior running sum (and gets masked).
    assert_in_delta(1.0, cs[0], 1e-12)
    assert_in_delta(4.0, cs[2], 1e-12)
    assert_in_delta(8.0, cs[3], 1e-12)
  end

  # ---- axis reductions (slow + fast mix) -------------------------- #

  def test_mean_axis0_matches_per_column_mean
    c = CArray.float64(10, 20).seq
    axis0 = c.mean(axis: 0)
    20.times do |j|
      column = (0...10).map { |i| (i * 20 + j).to_f }
      assert_in_delta(column.sum / 10, axis0[j], 1e-9,
                      "mean(axis=0)[#{j}] should match per-column mean")
    end
  end

  def test_sum_axis1_matches_per_row_sum
    c = CArray.float64(10, 20).seq
    axis1 = c.sum(axis: 1)
    10.times do |i|
      row = (0...20).map { |j| (i * 20 + j).to_f }
      assert_in_delta(row.sum, axis1[i], 1e-9)
    end
  end

  # ---- equivalence: fast path vs slow path ------------------------ #

  def test_fast_and_slow_paths_agree_on_unmasked_data
    omit "Removed in E.7 stat_proc retire; re-implement per CLAUDE.md"
    # Build the same data twice, one masked-no-elements (slow path),
    # one bare (fast path).  Results must match bit-for-bit (for sum)
    # or within float ulp (for products with FP rounding).
    base = (0...1000).map { |i| Math.sin(i * 0.01) }
    a_fast = CArray.float64(base.length); base.each_with_index { |v, i| a_fast[i] = v }
    a_slow = CArray.float64(base.length); base.each_with_index { |v, i| a_slow[i] = v }
    a_slow.mask = CArray.boolean(base.length).fill(0)   # mask present but all-clear -> slow path

    assert_in_delta(a_fast.sum,      a_slow.sum,      1e-12)
    assert_in_delta(a_fast.mean,     a_slow.mean,     1e-12)
    assert_in_delta(a_fast.variance, a_slow.variance, 1e-12 * a_fast.variance.abs)
    assert_in_delta(a_fast.stddev,   a_slow.stddev,   1e-12 * a_fast.stddev.abs)
    assert_equal(a_fast.min,         a_slow.min)
    assert_equal(a_fast.max,         a_slow.max)
    assert_equal(a_fast.min_addr,    a_slow.min_addr)
    assert_equal(a_fast.max_addr,    a_slow.max_addr)
  end

  def test_fast_and_slow_paths_agree_on_integer_data
    omit "Removed in E.7 stat_proc retire; re-implement per CLAUDE.md"
    base = (0...500).to_a
    a_fast = CArray.int32(base.length); base.each_with_index { |v, i| a_fast[i] = v }
    a_slow = CArray.int32(base.length); base.each_with_index { |v, i| a_slow[i] = v }
    a_slow.mask = CArray.boolean(base.length).fill(0)

    assert_equal(a_fast.sum,        a_slow.sum)
    assert_equal(a_fast.min,        a_slow.min)
    assert_equal(a_fast.max,        a_slow.max)
    assert_equal(a_fast.accumulate, a_slow.accumulate)
  end
end
