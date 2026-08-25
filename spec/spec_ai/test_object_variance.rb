require_relative "../../lib/carray"
require "test/unit"
require "bigdecimal"

# PROPOSAL_MKKERNEL_OBJECT_DTYPE_BRANCH §4b (a): CA_OBJECT variance /
# variancep / stddev / stddevp.
#
# Design (2026-07-06):
#   variance / variancep -> output :object.  acc = Sigma x, sumsq =
#     Sigma x^2 accumulated exactly in the Ruby numeric tower; finish
#     does the whole (sumsq - acc*acc/n)/(n | n-1) arithmetic with Ruby
#     operators, so BigDecimal / Rational keep full precision.  Integer
#     input follows Ruby integer division (truncated), same as :object
#     mean.
#   stddev / stddevp -> output Float.  No precision-preserving sqrt
#     spans the Ruby numeric tower, so finish drops to double + sqrt.
#     Precision-seeking users take variance (exact) + BigMath.sqrt.
class TestObjectVariance < Test::Unit::TestCase
  # ---- variance / variancep: Integer (Ruby integer arithmetic) --------

  def test_variance_integer_exact_case
    # [10,12,14,16,18]: sumsq=1020, sum=70, (1020-70*70/5)/4 = 40/4 = 10.
    a = CA_OBJECT([10, 12, 14, 16, 18])
    assert_equal(10, a.variance)
    assert_equal(8, a.variancep)   # 40/5
  end

  def test_variance_integer_truncates_like_mean
    # [1,2,3,4]: real value 5/3 ≈ 1.667 -- Integer input truncates via
    # Ruby integer division, so the returned value is lossy either way.
    # PROPOSAL_VARIANCE_STABLE_KERNEL rev2 (two-pass centred) truncates at
    # the mean step: mean = 10/4 = 2 (truncated 2.5); Σ(x-2)² = 6; variance
    # = 6/3 = 2.  The pre-migration one-pass form returned 1 because it
    # deferred the divide until after (sumsq - sum²/n).  Both are correctly
    # documented as lossy for Integer input -- feed BigDecimal / Rational
    # for exact.  Locking in the two-pass value.
    a = CA_OBJECT([1, 2, 3, 4])
    assert_equal(2, a.variance)         # Integer, truncated (two-pass)
    assert_kind_of(Integer, a.variance)
    assert_equal(1, a.variancep)        # both algorithms agree: 6/4 = 1
  end

  # ---- variance: BigDecimal (precision preserved) ----------------------

  def test_variance_bigdecimal_keeps_precision
    a = CA_OBJECT([BigDecimal("1"), BigDecimal("2"),
                   BigDecimal("3"), BigDecimal("4")])
    v = a.variance
    assert_kind_of(BigDecimal, v)
    # 5/3 as BigDecimal, exact to the working precision.
    assert_equal(BigDecimal("5") / 3, v)
    assert_kind_of(BigDecimal, a.variancep)
    assert_equal(BigDecimal("1.25"), a.variancep)
  end

  # ---- variance: Rational (precision preserved) ------------------------

  def test_variance_rational_keeps_precision
    a = CA_OBJECT([Rational(1, 2), Rational(3, 2), Rational(5, 2)])
    v = a.variance
    assert_kind_of(Rational, v)
    assert_equal(Rational(1, 1), v)               # sample = 2/2
    assert_equal(Rational(2, 3), a.variancep)     # population = 2/3
  end

  # ---- stddev / stddevp: always Float ----------------------------------

  def test_stddev_returns_float
    a = CA_OBJECT([10, 12, 14, 16, 18])
    assert_kind_of(Float, a.stddev)
    assert_in_delta(Math.sqrt(10), a.stddev, 1e-12)
    assert_kind_of(Float, a.stddevp)
    assert_in_delta(Math.sqrt(8), a.stddevp, 1e-12)
  end

  def test_stddev_bigdecimal_input_returns_float
    # Accumulation is exact object, but the final sqrt drops to Float.
    a = CA_OBJECT([BigDecimal("1"), BigDecimal("2"),
                   BigDecimal("3"), BigDecimal("4")])
    s = a.stddev
    assert_kind_of(Float, s)
    assert_in_delta(Math.sqrt(5.0 / 3.0), s, 1e-12)
  end

  # ---- precision escape hatch for stddev -------------------------------

  def test_precision_stddev_via_bigmath_on_variance
    # A user needing a precise stddev takes the exact object variance and
    # runs BigMath.sqrt themselves (documented escape hatch).
    require "bigdecimal/math"
    a = CA_OBJECT([BigDecimal("1"), BigDecimal("2"),
                   BigDecimal("3"), BigDecimal("4")])
    var = a.variance                 # exact BigDecimal (5/3)
    s = BigMath.sqrt(var, 30)
    assert_kind_of(BigDecimal, s)
    assert_in_delta(Math.sqrt(5.0 / 3.0), s.to_f, 1e-12)
  end

  # ---- axis ------------------------------------------------------------

  def test_variance_axis
    c = CA_OBJECT([[1, 2, 3], [4, 6, 8]])
    assert_equal([1, 4], c.variance(axis: 1).to_a)     # sample per row
    assert_equal([0, 2], c.variancep(axis: 1).to_a)    # 2/3->0, 8/3->2 (int)
  end

  def test_variance_axis_bigdecimal_keeps_precision
    c = CA_OBJECT([[BigDecimal("1"), BigDecimal("2")],
                   [BigDecimal("10"), BigDecimal("13")]])
    r = c.variance(axis: 1).to_a
    assert_equal([BigDecimal("0.5"), BigDecimal("4.5")], r)
    assert(r.all? { |x| x.is_a?(BigDecimal) })
  end

  def test_stddev_axis_returns_float
    c = CA_OBJECT([[1, 2, 3], [4, 6, 8]])
    r = c.stddev(axis: 1).to_a
    assert(r.all? { |x| x.is_a?(Float) })
    assert_in_delta(1.0, r[0], 1e-12)
    assert_in_delta(2.0, r[1], 1e-12)
  end

  # ---- mask ------------------------------------------------------------

  def test_variance_skips_masked
    a = CA_OBJECT([10, 20, 30, 999])
    a[3] = UNDEF
    # sample variance of {10,20,30}: (1400 - 3600/3)/2 = 200/2 = 100.
    assert_equal(100, a.variance)
    assert_equal(3, a.count_not_masked)
  end

  def test_variance_all_masked_yields_undef
    a = CA_OBJECT([1, 2, 3])
    a[] = UNDEF
    # variance has no identity on the empty set (ratio reduction) -> UNDEF.
    assert_equal(UNDEF, a.variance)
    assert_equal(UNDEF, a.stddev)
  end

  # ---- empty / single element ------------------------------------------

  def test_variance_single_element
    a = CA_OBJECT([5])
    # sample variance: cnt < 2 -> INT2FIX(0) (the object-VALUE zero, not
    # a mis-emitted Qfalse).
    assert_equal(0, a.variance)
    assert_equal(0, a.variancep)  # population of one point = 0
    assert_equal(0.0, a.stddev)
    assert_equal(0.0, a.stddevp)
  end

  def test_variance_single_element_is_not_false
    # Guard against the INT2FIX(0)-vs-C-literal-0 trap: a bad emit would
    # return Qfalse, which is != 0 in Ruby.
    a = CA_OBJECT([42])
    assert_not_equal(false, a.variance)
    assert_equal(0, a.variance)
  end
end
