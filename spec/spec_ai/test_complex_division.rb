# frozen_string_literal: true
#
# cmplx64 division is computed in double and rounded once.
#
# The compiler turns a `float _Complex` divide into a call to `__divsc3`
# -- Smith's algorithm (scale by the larger component so the squares
# cannot overflow) plus the C99 Annex G recovery for infinities.  For a
# cmplx64 the scaling buys nothing: the operands are floats, so the sum
# of squares reaches at most about 1.2e77 where a double reaches 1.8e308.
# Computing the textbook formula in double cannot overflow and carries 29
# extra mantissa bits, which is what the cancellation in the numerator
# needs when the quotient's real part lands near zero.
#
# Annex G is kept by falling back rather than by reimplementing it: when
# the quick answer is not an ordinary finite number the pair is handed to
# the compiler's helper.  The edge cases below are the assertion that the
# fallback covers what it must.
#
# cmplx128 has no wider type to borrow, so it stays on `__divdc3`.

require "test/unit"
require "carray"

class TestComplexDivision < Test::Unit::TestCase

  INF = Float::INFINITY
  NAN = Float::NAN

  def f32(r) = CA_FLOAT32([r.to_f])[0]

  # distance in float32 representations, so "correctly rounded" is 0
  def ulp32(a, b)
    return 0 if a == b
    ia = [a].pack("f").unpack1("l")
    ib = [b].pack("f").unpack1("l")
    ia = 0x80000000 - ia if ia < 0
    ib = 0x80000000 - ib if ib < 0
    (ia - ib).abs
  end

  # the exact quotient over Rationals, each part rounded to float32
  def exact_quotient(x, y)
    xr = x.real.to_r; xi = x.imaginary.to_r
    yr = y.real.to_r; yi = y.imaginary.to_r
    d = yr * yr + yi * yi
    return nil if d.zero?
    [f32((xr * yr + xi * yi) / d), f32((xi * yr - xr * yi) / d)]
  end

  # `__divsc3` was off by up to ~1800 ulp on this kind of sample, all of
  # it in the part that cancels.  Anything above 0 here means the double
  # route stopped being taken.
  def test_correctly_rounded_against_exact_rationals
    srand 12345
    n = 4000
    x = CA_CMPLX64(Array.new(n) { Complex(rand * 16 - 8, rand * 16 - 8) })
    y = CA_CMPLX64(Array.new(n) { Complex(rand * 8 - 4,  rand * 8 - 4)  })
    q = x / y
    worst = 0
    n.times do |k|
      er, ei = exact_quotient(x[k], y[k])
      next unless er
      worst = [worst, ulp32(q[k].real, er), ulp32(q[k].imaginary, ei)].max
    end
    assert_equal 0, worst, "cmplx64 / is no longer correctly rounded"
  end

  # A quotient whose real part nearly cancels: the case the float-width
  # algorithm loses and the double-width one keeps.
  def test_the_cancelling_case
    x = CA_CMPLX64([Complex(-4.458879470825195, 1.2791328430175781)])
    y = CA_CMPLX64([Complex(-1.1097438335418701, -3.8695855140686035)])
    er, ei = exact_quotient(x[0], y[0])
    q = (x / y)[0]
    assert_equal er, q.real,      "real part of the cancelling quotient"
    assert_equal ei, q.imaginary, "imaginary part of the cancelling quotient"
  end

  # ---- Annex G: the fallback has to cover all of this ----------------

  def sign_of_zero(v) = (v.zero? && 1.0 / v < 0) ? :neg : :pos

  EDGE = {
    "(1+0i)/(0+0i)"     => [Complex(1, 0),      Complex(0, 0)],
    "(0+0i)/(0+0i)"     => [Complex(0, 0),      Complex(0, 0)],
    "(1+1i)/(inf+0i)"   => [Complex(1, 1),      Complex(INF, 0)],
    "(inf+0i)/(1+1i)"   => [Complex(INF, 0),    Complex(1, 1)],
    "(1+1i)/(nan+0i)"   => [Complex(1, 1),      Complex(NAN, 0)],
    "(3+4i)/(1e-40+0i)" => [Complex(3, 4),      Complex(1e-40, 0)],
  }.freeze

  def test_infinities_and_nans_match_the_reference_helper
    expected = {
      "(1+0i)/(0+0i)"     => [INF, :nan],
      "(0+0i)/(0+0i)"     => [:nan, :nan],
      "(1+1i)/(inf+0i)"   => [0.0, 0.0],
      "(inf+0i)/(1+1i)"   => [INF, -INF],
      "(1+1i)/(nan+0i)"   => [:nan, :nan],
      "(3+4i)/(1e-40+0i)" => [INF, INF],   # 1e-40 is subnormal in float32
    }
    EDGE.each do |name, (a, b)|
      q = (CA_CMPLX64([a]) / CA_CMPLX64([b]))[0]
      er, ei = expected.fetch(name)
      [[er, q.real, "real"], [ei, q.imaginary, "imag"]].each do |want, got, part|
        if want == :nan
          assert got.nan?, "#{name} #{part}: expected NaN, got #{got}"
        else
          assert_equal want, got, "#{name} #{part}"
        end
      end
    end
  end

  # A zero's sign selects a branch cut, so the division must not quietly
  # turn -0.0 into +0.0 where the helper would not have.
  SIGNED_ZERO = {
    "(1-0.0i)/(1+0i)"    => [Complex(1, -0.0),  Complex(1, 0),    :pos, :neg],
    "(1+0.0i)/(-1+0.0i)" => [Complex(1, 0.0),   Complex(-1, 0.0), :pos, :neg],
    "(1+0.0i)/(0.0+1i)"  => [Complex(1, 0.0),   Complex(0.0, 1),  :pos, :pos],
    "(-1+0.0i)/(1+0i)"   => [Complex(-1, 0.0),  Complex(1, 0),    :pos, :pos],
  }.freeze

  def test_zero_signs_are_unchanged
    SIGNED_ZERO.each do |name, (a, b, want_re, want_im)|
      q = (CA_CMPLX64([a]) / CA_CMPLX64([b]))[0]
      assert_equal want_re, sign_of_zero(q.real),      "#{name} real sign" if q.real.zero?
      assert_equal want_im, sign_of_zero(q.imaginary), "#{name} imag sign" if q.imaginary.zero?
    end
  end

  # ---- the three surfaces share one route ---------------------------

  def sample_pair(n)
    srand 777
    [CA_CMPLX64(Array.new(n) { Complex(rand * 8 - 4, rand * 8 - 4) }),
     CA_CMPLX64(Array.new(n) { Complex(rand * 8 - 4, rand * 8 - 4) })]
  end

  def test_rcp_equals_one_over_z
    z, = sample_pair(500)
    one = CA_CMPLX64(Array.new(500) { Complex(1, 0) })
    assert_equal (one / z).to_a, z.rcp.to_a
  end

  def test_rcp_mul_equals_the_reversed_divide
    a, b = sample_pair(500)
    assert_equal (b / a).to_a, a.rcp_mul(b).to_a
  end

  def test_lazy_matches_eager
    a, b = sample_pair(500)
    assert_equal (a / b).to_a, (a.lazy / b.lazy).to_ca.to_a
  end

  # ---- cmplx128 is deliberately untouched ---------------------------

  def test_cmplx128_keeps_the_compiler_helper
    # Not an accuracy claim -- just that the wide type still divides and
    # still agrees with Ruby's own Complex to double precision.
    x = Complex(-4.458879470825195, 1.2791328430175781)
    y = Complex(-1.1097438335418701, -3.8695855140686035)
    q = (CA_CMPLX128([x]) / CA_CMPLX128([y]))[0]
    r = x / y
    assert_in_delta 0.0, (q - r).abs, 1e-12 * [r.abs, 1.0].max
  end
end
