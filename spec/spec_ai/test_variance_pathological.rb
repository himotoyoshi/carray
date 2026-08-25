require_relative "../../lib/carray"
require "test/unit"

# PROPOSAL_VARIANCE_STABLE_KERNEL: regression pin for the centred two-pass
# migration.  The pre-migration one-pass sum-of-squares form
#   variance = (Σx² - (Σx)²/n) / n
# loses precision catastrophically when the absolute values are large and
# the variance is small (= cancellation between Σx² and (Σx)²/n).  Two-pass
# centred (Σx → mean → Σ(x - mean)²) subtracts the mean first, so the
# squared differences stay O(spread) and never cancel.
#
# The pathological inputs below are the ones that broke first on Linux +
# GCC 11.5 (Mac + Apple clang had a happy SIMD lane ordering that hid
# some of them).  Tolerances are chosen so a one-pass regression would
# fail visibly (1e-3 = 0.1% relative error), while a working two-pass
# passes with plenty of headroom (typical ε: 1e-14 to 1e-4 depending on
# the size / mean ratio).
#
# References:
#   devel/PROPOSAL_VARIANCE_STABLE_KERNEL.md
#   devel/poc_welford_variance.c  (one-pass vs Welford vs two-pass table)
class TestVariancePathological < Test::Unit::TestCase
  # Deterministic bounded variate with known variance:
  # values alternate as -1, +1, -1, +1, ... so mean=0, Var=1 exact.
  # Adding a constant mean C shifts values to C-1, C+1 -- variance still 1.
  # (One-pass form: Σx² = 2N·C² + N; Σx = 2N·C; (Σx)²/n = 4N·C²; variance
  # = (Σx² - (Σx)²/n)/n = 1.  For large C, Σx² and (Σx)²/n both ~ 4N·C²
  # and cancel to 1 -- ε-precision limit reached at C ≈ 1e7 for f64.)
  def make_bipolar_f64(n, mean)
    CArray.float64(n) { |i| mean + (i.even? ? -1.0 : 1.0) }
  end

  def make_bipolar_f32(n, mean)
    CArray.float32(n) { |i| (mean + (i.even? ? -1.0 : 1.0)).to_f }
  end

  # ---- numeric f64: mean sweep -----------------------------------------

  # Variance of {mean±1, mean±1, ...} is exactly 1.  The pre-migration
  # one-pass form breaks at mean=1e6 (rel_err ~1e-2) and produces
  # garbage / sign-flipped values at mean >= 1e7 (variancep = 0 or NaN
  # where truth is 1).  Two-pass centred stays ε-close at every scale.
  def test_f64_large_mean_small_variance
    [1e2, 1e4, 1e6, 1e7, 1e8, 1e9].each do |mean|
      a = make_bipolar_f64(10000, mean)
      v = a.variancep
      assert_in_delta(1.0, v, 1e-6,
        "variancep(mean=#{mean}) got #{v} expected 1.0")
      s = a.stddevp
      assert_in_delta(1.0, s, 1e-6,
        "stddevp(mean=#{mean}) got #{s} expected 1.0")
    end
  end

  def test_f64_sample_variance_large_mean
    n = 10000
    [1e6, 1e8].each do |mean|
      a = make_bipolar_f64(n, mean)
      # sample = population * n/(n-1) for this deterministic input.
      exp = 1.0 * n / (n - 1)
      assert_in_delta(exp, a.variance, 1e-6)
      assert_in_delta(Math.sqrt(exp), a.stddev, 1e-6)
    end
  end

  # ---- numeric f32: reduced precision, still cancellation-safe ---------

  # f32 has ~7 decimal digits; the pre-migration one-pass form loses
  # precision by mean ~= 1e3 in f32.  Two-pass uses an f64 accumulator
  # regardless of source storage, so the walk holds full precision.
  def test_f32_large_mean
    a = make_bipolar_f32(10000, 1.0e5)
    assert_in_delta(1.0, a.variancep, 1e-4)
    a2 = make_bipolar_f32(10000, 1.0e7)   # far past f32 mantissa
    assert_in_delta(1.0, a2.variancep, 1e-4)
  end

  # ---- integer input: large absolute value ------------------------------

  # Same deterministic ±1 pattern with a huge integer offset.  One-pass
  # f64 cancellation would land at 0 for offset >= 1e9; two-pass stays
  # at 1 exact.
  def test_int64_large_mean
    a = CArray.int64(10000) { |i| 1_000_000_000 + (i.even? ? -1 : 1) }
    assert_in_delta(1.0, a.variancep, 1e-9)
  end

  # ---- complex: large-magnitude offset, small orbital variance ---------

  # z_i = offset + e^(i·2πi/n).  |z_i - offset| = 1, so E[|z - E z|²] = 1.
  # The one-pass form (E|z|² - |E z|²) subtracts two O(offset²) numbers.
  def test_cmplx128_large_mean
    n = 10000
    a = CArray.cmplx128(n) { |i|
      Complex(1e6, 0) + Complex(Math.cos(2 * Math::PI * i / n),
                                Math.sin(2 * Math::PI * i / n))
    }
    v = a.variancep
    # Discrete-lattice mean of e^(iθ) over n equal steps is exactly 0,
    # so the truth is E[|z|²] = 1 (population).
    assert_in_delta(1.0, v, 1e-3, "complex variancep with offset 1e6 got #{v}")
  end

  # ---- per-axis: pathological input still works axis-wise --------------

  def test_per_axis_large_mean
    means = [1e5, 1e7, 1e9]
    a = CArray.float64(3, 10000) do |i, j|
      means[i] + (j.even? ? -1.0 : 1.0)
    end
    per = a.variancep(axis: 1).to_a
    per.each_with_index do |v, i|
      assert_in_delta(1.0, v, 1e-6,
        "per-axis variancep row=#{i} (mean=#{means[i]}) got #{v}")
    end
  end

  # ---- masked cells: masked slabs centre on unmasked mean --------------

  # Same pathological input plus a UNDEF outlier that would blow up
  # sum²/n if included.  Two-pass takes the mean of the unmasked cells,
  # so the outlier is invisible.
  def test_masked_pathological_outlier
    n = 10001   # odd so removing index 0 leaves 5000 of each sign
    a = CArray.float64(n) { |i| 1e8 + (i.even? ? -1.0 : 1.0) }
    a[0] = UNDEF   # remove one of the -1.0 cells; parity now 5000/5000
    v = a.variancep
    # Remaining 10000 cells: 5000 with value 1e8-1, 5000 with value 1e8+1.
    # Truth = 1.0 exact.
    assert_in_delta(1.0, v, 1e-6)
    assert_equal(n - 1, a.count_not_masked)
  end

  # ---- constant slab: SIMD reassoc ε-negative must not surface -------

  # A constant slab has variance 0.  Pass 2 sums up N copies of 0.0
  # under SIMD :plus reassociation; individual lane additions may
  # introduce ε negatives that the finish's fmax(..., 0.0) clamps.
  # The stddev must be 0.0, not NaN.
  def test_constant_slab_stddev_no_nan
    a = CArray.float64(10000) { |_| 42.0 }
    s = a.stddevp
    assert(!s.nan?, "stddevp of constant slab produced NaN")
    assert_in_delta(0.0, s, 1e-10)
    assert_in_delta(0.0, a.variancep, 1e-20)
  end
end
