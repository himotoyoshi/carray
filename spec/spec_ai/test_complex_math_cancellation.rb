# frozen_string_literal: true
#
# `log` and `pow` on a cmplx64 array are evaluated in double.
#
# Most complex functions are fine at their operand's width: `csqrtf`,
# `cexpf`, `csinf` and the rest sit within a few units in the last place
# of the same function in double, so CArray calls them and takes the
# speed.  Two do not, and they are here because the reason is not visible
# from the call site.
#
#   clog(z)'s real part is log|z|, which vanishes on the unit circle.
#   Computing |z| at float width rounds it to 1 and throws away exactly
#   the part the logarithm was about to read, so `clogf` comes back with
#   a relative error near 400 -- not a last-bit matter but a wrong
#   answer.  In double there are 29 bits underneath and the result lands
#   at float precision.
#
#   cpow(a, z) is cexp(z * clog(a)), so a variable base carries clog's
#   loss straight through: `z ** z` over the unit circle came back with a
#   relative error near 1e9.
#
# `exp2` and `exp10` reach the same cpow but with a constant base, where
# clog(2) is computed once and accurately; narrowing costs them about
# 1e-5 on a small component rather than the answer.  They are kept wide
# because they are the same call, not because they were failing.
#
# The cost is real: `log` is 1.9x and `power` 1.4x slower than the narrow
# form would be.  The tests below are what stops someone reading that
# number and narrowing them back.

require "test/unit"
require "carray"

class TestComplexMathCancellation < Test::Unit::TestCase

  # On the unit circle log|z| is the difference of two nearly equal
  # quantities, which is the whole point.
  UNIT_CIRCLE = (0...240).map do |i|
    t = 2 * Math::PI * i / 240
    Complex(Math.cos(t), Math.sin(t))
  end.freeze

  # A box away from the unit circle, where cpow's own exponential has to
  # reduce a larger argument.  `power` is checked over both.
  BOX = (0...240).map do |i|
    Complex(-4.0 + 8.0 * i / 240, -4.0 + 8.0 * ((i * 79) % 240) / 240)
  end.freeze

  def c64  = CA_CMPLX64(UNIT_CIRCLE)
  def c128 = CA_CMPLX64(UNIT_CIRCLE).to_type(:cmplx128)

  # The cmplx128 answer stands in for the true one: it carries 29 more
  # mantissa bits, so anything a float32 result can be asked for is in
  # there.
  #
  # The two parts are compared separately, each against its own size.
  # That matters here: on the unit circle `log(z)` has an imaginary part
  # of order 1 and a real part of order 1e-8, so measuring the error
  # against the modulus would divide the interesting number by the
  # uninteresting one and hide exactly the failure this file is about.
  def assert_agrees_with_cmplx128(name, tol = 1e-5, points = UNIT_CIRCLE)
    a64  = CA_CMPLX64(points)
    narrow = yield a64
    wide   = yield a64.to_type(:cmplx128)
    worst = 0.0
    where = nil
    points.each_index do |k|
      w = wide[k]
      n = Complex(narrow[k])
      # z = 1+0i and z = -1+0i are poles for atanh and friends; both
      # widths blow up there and there is nothing to compare.
      finite = ->(c) { c.real.finite? && c.imaginary.finite? }
      unless finite.(w) && finite.(n)
        assert_equal finite.(w), finite.(n),
                     "#{name} at #{points[k]}: one width is finite and the other is not"
        next
      end
      [[w.real, n.real], [w.imaginary, n.imaginary]].each do |wc, nc|
        next if wc.zero?
        e = ((nc - wc) / wc).abs
        if e > worst
          worst = e
          where = points[k]
        end
      end
    end
    assert_operator worst, :<, tol,
                    "#{name} on cmplx64 drifts from the cmplx128 answer by #{worst} at #{where}"
  end

  def test_log_on_the_unit_circle
    assert_agrees_with_cmplx128("log") { |a| a.log }
  end

  def test_power_on_the_unit_circle
    assert_agrees_with_cmplx128("power") { |a| a.power(a) }
  end

  def test_power_away_from_the_unit_circle
    assert_agrees_with_cmplx128("power", 1e-5, BOX) { |a| a.power(a) }
  end

  def test_exp2_on_the_unit_circle
    assert_agrees_with_cmplx128("exp2") { |a| a.exp2 }
  end

  def test_exp10_on_the_unit_circle
    assert_agrees_with_cmplx128("exp10") { |a| a.exp10 }
  end

  # The real part of log(z) for a z whose modulus rounds to 1 in float.
  # `clogf` answered 2.98e-08 where the value is 6.96e-11: right by
  # accident of magnitude, wrong by a factor of 400.
  def test_the_case_that_made_this_necessary
    z = CA_CMPLX64([Complex(0.7287607192993164, -0.6847684383392334)])
    got  = z.log[0].real
    want = z.to_type(:cmplx128).log[0].real
    assert_in_delta want, got, 1e-6 * [want.abs, 1e-10].max,
                    "log|z| lost its cancellation: got #{got}, want about #{want}"
  end

  # The counterpart: these were narrowed on purpose and must stay that
  # way, so the rule reads as a choice rather than an oversight.  Each
  # still has to agree with cmplx128 -- narrow is allowed to cost a few
  # ulp, not the answer.
  NARROWED = %w[sqrt exp sin cos tan asin acos atan
                sinh cosh tanh asinh atanh abs arg rsqrt].freeze

  def test_the_narrowed_ones_still_agree
    NARROWED.each do |m|
      assert_agrees_with_cmplx128(m, 1e-5) { |a| a.send(m) }
    end
  end

  # Real float32 has no cancelling step of this kind: the operand is the
  # argument itself, so `logf` is exact through x = 1 and the real side
  # was narrowed everywhere.
  def test_real_log_is_fine_narrow
    xs = (0...200).map { |i| 0.9 + 0.2 * i / 200 }
    a32 = CA_FLOAT32(xs)
    a64 = a32.to_type(:float64)
    n = a32.log
    w = a64.log
    xs.each_index do |k|
      next if w[k].abs < 1e-30
      assert_operator ((n[k] - w[k]) / w[k]).abs, :<, 1e-6,
                      "float32 log drifted at x = #{a32[k]}"
    end
  end
end
