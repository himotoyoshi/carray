require "test/unit"
require "carray"

# 3.0 refinement: CArray::CoreExtensions
#
# The legacy global monkey patches on Float / Integer / Rational /
# Numeric / TrueClass / FalseClass have been removed.  Files that
# need the postfix-math / angle / comparison / symmetric-bitwise
# forms opt in with:
#
#     using CArray::CoreExtensions
#
# Refinements are lexically scoped; outside the using scope the
# core classes are pristine.
#
# This file tests both sides:
#   * Without using:  patches are absent (global cleanliness).
#   * With using:     full API restored, scalar/CArray polymorphism
#                     works, refined methods agree with the
#                     vectorised C implementations on CArray.

class TestCoreExtensionsAbsent < Test::Unit::TestCase

  def test_float_math_not_defined_globally
    refute Float.method_defined?(:sqrt)
    refute Float.method_defined?(:sin)
    refute Float.method_defined?(:tanh)
    refute Float.method_defined?(:rad)
    refute Float.method_defined?(:deg)
    refute Float.method_defined?(:distance)
  end

  def test_integer_math_not_defined_globally
    refute Integer.method_defined?(:sqrt)
    refute Integer.method_defined?(:log)
  end

  def test_rational_math_not_defined_globally
    refute Rational.method_defined?(:sqrt)
    refute Rational.method_defined?(:sin)
  end

  def test_complex_math_not_defined_globally
    refute Complex.method_defined?(:sqrt)
    refute Complex.method_defined?(:exp)
    refute Complex.method_defined?(:tanh)
    refute Complex.method_defined?(:asin)
  end

  def test_numeric_angle_and_comparison_not_defined_globally
    refute Numeric.method_defined?(:deg_360)
    refute Numeric.method_defined?(:deg_180)
    refute Numeric.method_defined?(:rad_2pi)
    refute Numeric.method_defined?(:rad_pi)
    refute Numeric.method_defined?(:eq)
    refute Numeric.method_defined?(:ne)
  end

  def test_true_class_and_is_core_ruby
    # Plain Ruby semantics: true & x returns boolean (x is truthy or not).
    # If carray had overridden it, true & ca would dispatch into the CArray.
    ca = CA_BOOLEAN([true, false, true])
    result = true & ca
    assert_equal TrueClass, result.class
    refute_kind_of CArray, result
  end

  def test_false_class_or_is_core_ruby
    ca = CA_BOOLEAN([true, false, true])
    result = false | ca
    # false | truthy -> true (core Ruby).  Carray override would return CArray.
    assert_equal TrueClass, result.class
    refute_kind_of CArray, result
  end

  # Note on Integer#| / & / ^ / << / >>: even without the refinement,
  # `5 | ca` works because Ruby's core Integer#| invokes coerce for
  # non-Integer operands, and CArray#coerce returns [CA_INT(5), ca].
  # The refinement still adds value for boolean CArrays (the
  # bit_or/bit_and/bit_xor fast path) and for TrueClass/FalseClass
  # symmetric forms.

end

class TestCoreExtensionsPresent < Test::Unit::TestCase
  using CArray::CoreExtensions

  # --- Postfix math on Float / Integer / Rational ----------------------

  def test_float_postfix_math
    assert_in_delta Math.sqrt(2.0), 2.0.sqrt, 1e-15
    assert_in_delta Math.sin(1.5),  1.5.sin,  1e-15
    assert_in_delta Math.tanh(0.5), 0.5.tanh, 1e-15
    assert_in_delta Math.log(10.0), 10.0.log, 1e-15
  end

  def test_integer_postfix_math
    assert_in_delta 4.0, 16.sqrt, 1e-15
    assert_in_delta Math.log(8), 8.log, 1e-15
  end

  def test_rational_postfix_math
    assert_in_delta 0.5, Rational(1, 4).sqrt, 1e-15
  end

  def test_rad_deg
    assert_in_delta Math::PI, 180.0.rad, 1e-12
    assert_in_delta 180.0,    Math::PI.deg, 1e-12
  end

  def test_distance
    assert_in_delta 2.0, 5.0.distance(3.0), 1e-15
    assert_in_delta 2.0, 5.distance(3),     1e-15
  end

  # --- Postfix math on Complex -----------------------------------------
  #
  # CArray's complex kernels are the platform's C99 complex.h, so the
  # scalar forms are pinned against a one-element cmplx128 array rather
  # than against a formula.  The comparison is exact and includes the
  # sign of a zero: on a branch cut that sign is the entire answer, and
  # an assert_in_delta would not see it.

  COMPLEX_MATH = %i[
    sqrt exp log
    sin cos tan sinh cosh tanh
    asin acos atan asinh acosh atanh
    square rsqrt
  ].freeze

  # Canonical text for a Float that distinguishes -0.0 from 0.0 and
  # makes NaN comparable.
  def float_key(v)
    if v.nan?     then "NaN"
    elsif v.zero? then (1 / v).negative? ? "-0.0" : "0.0"
    else               v.to_s
    end
  end

  def complex_key(z)
    [float_key(z.real), float_key(z.imaginary)]
  end

  def assert_matches_kernel(m, z)
    ref = CArray.cmplx128(1) { z }.send(m)[0]
    assert_equal complex_key(ref), complex_key(z.send(m)),
                 "Complex##{m}(#{z}) disagrees with the cmplx128 kernel"
  end

  def test_complex_postfix_math_matches_kernel
    z = Complex(1.0, 2.0)
    COMPLEX_MATH.each { |m| assert_matches_kernel(m, z) }
  end

  def test_complex_postfix_math_matches_kernel_negative_quadrant
    z = Complex(-0.7, -1.3)
    COMPLEX_MATH.each { |m| assert_matches_kernel(m, z) }
  end

  # Branch cuts.  sqrt and log are cut along the negative real axis;
  # asin / acos along the real axis outside [-1, 1]; atanh likewise;
  # acosh for real x < 1.  Each is approached from both sides by the
  # sign of the zero imaginary part.
  BRANCH_CUT_CASES = [
    [:sqrt,  Complex(-1.0,  0.0)],
    [:sqrt,  Complex(-1.0, -0.0)],
    [:log,   Complex(-1.0,  0.0)],
    [:log,   Complex(-1.0, -0.0)],
    [:asin,  Complex( 2.0,  0.0)],
    [:asin,  Complex( 2.0, -0.0)],
    [:acos,  Complex( 2.0,  0.0)],
    [:acos,  Complex( 2.0, -0.0)],
    [:atanh, Complex( 2.0,  0.0)],
    [:atanh, Complex( 2.0, -0.0)],
    [:acosh, Complex( 0.5,  0.0)],
    [:acosh, Complex( 0.5, -0.0)],
  ].freeze

  def test_complex_branch_cuts_match_kernel
    BRANCH_CUT_CASES.each { |m, z| assert_matches_kernel(m, z) }
  end

  # The two sides of a cut must actually differ, otherwise the test
  # above would pass on an implementation that ignores the sign of zero.
  def test_complex_branch_cuts_are_two_sided
    BRANCH_CUT_CASES.each_slice(2) do |(m, above), (_, below)|
      refute_equal complex_key(above.send(m)), complex_key(below.send(m)),
                   "Complex##{m} gives the same answer on both sides of its cut"
    end
  end

  def test_complex_specials_match_kernel
    [Complex(0.0, 0.0), Complex(-0.0, 0.0), Complex(0.0, -0.0),
     Complex(Float::INFINITY, 1.0), Complex(1.0, Float::INFINITY),
     Complex(Float::NAN, 1.0)].each do |z|
      COMPLEX_MATH.each { |m| assert_matches_kernel(m, z) }
    end
  end

  # Integer / Rational components are accepted the way the cmplx128
  # constructor accepts them.
  def test_complex_with_exact_components
    assert_matches_kernel(:exp, Complex(1, 2))
    assert_matches_kernel(:log, Complex(Rational(1, 2), Rational(3, 4)))
  end

  # cmplx64 is float32 storage, so it only agrees to single precision;
  # the scalar form stays double and is checked against it loosely.
  def test_complex_agrees_with_cmplx64_to_single_precision
    z = Complex(1.0, 2.0)
    COMPLEX_MATH.each do |m|
      ref = CArray.cmplx64(1) { z }.send(m)[0]
      got = z.send(m)
      assert_in_delta ref.real, got.real, 1e-6 * [ref.abs, 1.0].max, "real of #{m}"
      assert_in_delta ref.imaginary, got.imaginary, 1e-6 * [ref.abs, 1.0].max, "imag of #{m}"
    end
  end

  # log10 / expm1 / log1p have no complex form in C99, and a complex
  # CArray raises CArray::DataTypeError for them.  The scalar side is
  # left undefined so it fails in the same place.
  def test_complex_omits_methods_the_kernel_lacks
    z = Complex(1.0, 2.0)
    %i[log10 expm1 log1p].each do |m|
      assert_raise(NoMethodError, "Complex##{m} should not be defined") { z.send(m) }
      assert_raise(CArray::DataTypeError, "complex CArray##{m} should raise") do
        CArray.cmplx128(1) { z }.send(m)
      end
    end
  end

  # rad / deg / distance / signbit go through #to_f, which Complex
  # does not have, so they are not defined on it either.
  def test_complex_omits_to_f_based_helpers
    z = Complex(1.0, 2.0)
    %i[rad deg signbit].each do |m|
      assert_raise(NoMethodError) { z.send(m) }
    end
    assert_raise(NoMethodError) { z.distance(Complex(0.0, 0.0)) }
  end

  # Adding Complex must not disturb the classes that were already
  # refined -- in particular log10, which Float keeps and Complex lacks.
  def test_float_integer_rational_unaffected_by_complex_refinement
    assert_in_delta Math.log10(1000.0), 1000.0.log10, 1e-15
    assert_in_delta 1.0, 1.0.square, 1e-15
    assert_in_delta Math.sqrt(2.0), 2.0.sqrt, 1e-15
    assert_in_delta Math.log(8), 8.log, 1e-15
    assert_in_delta 0.5, Rational(1, 4).sqrt, 1e-15
    assert_equal true, (-1.0).signbit
  end

  # Complex is a Numeric, so the Numeric refinement reaches it.  #eq /
  # #ne work; the angle helpers raise RangeError from #to_f.  Both are
  # pre-existing behaviour, pinned here so a later change is deliberate.
  def test_complex_inherits_numeric_refinement
    ca = CA_CMPLX128([Complex(1, 2), Complex(0, 0)])
    assert_equal [true, false], Complex(1, 2).eq(ca).to_a
    assert_equal true, Complex(1, 2).eq(Complex(1, 2))
    %i[deg_360 deg_180 rad_2pi rad_pi].each do |m|
      assert_raise(RangeError) { Complex(1.0, 2.0).send(m) }
    end
  end

  # --- Numeric angle normalisation -------------------------------------

  def test_deg_360
    assert_in_delta 0.0,   720.0.deg_360, 1e-9
    assert_in_delta 350.0, (-10.0).deg_360, 1e-9
    assert_in_delta 1.0,   361.0.deg_360, 1e-9
  end

  def test_deg_180
    assert_in_delta(-90.0, 270.0.deg_180, 1e-9)
    assert_in_delta(180.0, 180.0.deg_180, 1e-9)
    assert_in_delta(-179.0, 181.0.deg_180, 1e-9)
  end

  def test_rad_2pi
    two_pi = 2 * Math::PI
    assert_in_delta 0.0, (3 * two_pi).rad_2pi, 1e-9
    assert_in_delta Math::PI, (Math::PI + two_pi).rad_2pi, 1e-9
  end

  def test_rad_pi
    assert_in_delta(-Math::PI / 2, (3 * Math::PI / 2).rad_pi, 1e-9)
    assert_in_delta(0.0, (2 * Math::PI).rad_pi, 1e-9)
  end

  # --- Numeric#eq / #ne polymorphism -----------------------------------

  def test_numeric_eq_with_carray
    ca = CA_INT32([1, 2, 3])
    assert_equal [false, true, false], 2.eq(ca).to_a
  end

  def test_numeric_eq_with_scalar
    assert_equal true,  5.eq(5)
    assert_equal false, 5.eq(6)
  end

  def test_numeric_ne_with_carray
    ca = CA_INT32([1, 2, 3])
    assert_equal [true, false, true], 2.ne(ca).to_a
  end

  def test_numeric_ne_with_scalar
    assert_equal false, 5.ne(5)
    assert_equal true,  5.ne(6)
  end

  # --- Integer symmetric bitwise ---------------------------------------

  def test_integer_or_with_boolean_carray
    bool_ca = CA_BOOLEAN([true, false, true])
    assert_equal [true, true, true], (true  | bool_ca).to_a
    assert_equal [true, false, true], (false | bool_ca).to_a
  end

  def test_integer_and_with_boolean_carray
    bool_ca = CA_BOOLEAN([true, false, true])
    assert_equal [true, false, true], (true  & bool_ca).to_a
    assert_equal [false, false, false], (false & bool_ca).to_a
  end

  def test_integer_or_with_int_carray
    assert_equal [5, 7, 5], (5 | CA_INT32([1, 2, 4])).to_a
  end

  def test_integer_and_with_int_carray
    assert_equal [0, 2, 4], (0xff & CA_INT32([0, 2, 4])).to_a
  end

  def test_integer_xor_with_int_carray
    assert_equal [4, 7, 1], (5 ^ CA_INT32([1, 2, 4])).to_a
  end

  def test_integer_lshift_with_carray
    assert_equal [1, 2, 4, 8], (1 << CA_INT32([0, 1, 2, 3])).to_a
  end

  def test_integer_rshift_with_carray
    assert_equal [8, 4, 2, 1], (8 >> CA_INT32([0, 1, 2, 3])).to_a
  end

  # --- Core operator semantics preserved -------------------------------

  def test_plain_integer_bitwise_still_works
    # Inside a using scope, plain int OP int must still use core
    # Ruby semantics via super.
    assert_equal 7, 5 | 3
    assert_equal 1, 5 & 3
    assert_equal 6, 5 ^ 3
    assert_equal 8, 1 << 3
    assert_equal 4, 8 >> 1
  end

  def test_plain_true_false_bitwise_still_works
    assert_equal true,  true & true
    assert_equal false, true & false
    assert_equal true,  true | false
    assert_equal true,  true ^ false
  end

  # --- Scalar / CArray polymorphism (the driving use case) -------------

  # Magnus saturation vapor pressure (a quick formula that exercises
  # exp, division, and Float arithmetic in one expression).  Same code
  # must run on both Float and CArray inputs.
  def magnus_es(tc)
    6.112 * (17.67 * tc / (tc + 243.5)).exp
  end

  def test_polymorphism_scalar
    assert_in_delta  6.112, magnus_es(0.0),  1e-3
    assert_in_delta 23.369, magnus_es(20.0), 1e-3
  end

  def test_polymorphism_carray
    tc = CA_FLOAT64([0.0, 10.0, 20.0])
    es = magnus_es(tc)
    assert_kind_of CArray, es
    assert_in_delta  6.112, es[0], 1e-3
    assert_in_delta 12.272, es[1], 1e-3
    assert_in_delta 23.369, es[2], 1e-3
  end

  # Murphy-Koop saturation vapor pressure (more rigorous).  Uses log
  # and tanh on Numeric/CArray inputs.
  def murphy_koop_es(t)
    a = 54.842763 - 6763.22 / t - 4.21 * t.log + 0.000367 * t
    b = (0.0415 * (t - 218.8)).tanh
    c = 53.878 - 1331.22 / t - 9.44523 * t.log + 0.014025 * t
    (a + b * c).exp / 100.0
  end

  def test_murphy_koop_polymorphism
    s = murphy_koop_es(273.15)
    a = murphy_koop_es(CA_FLOAT64([253.15, 273.15, 293.15]))
    assert_in_delta 6.112,  s,    1e-3
    assert_in_delta 1.255,  a[0], 1e-3
    assert_in_delta 6.112,  a[1], 1e-3
    assert_in_delta 23.394, a[2], 1e-3
  end

  # --- Cross-check: scalar refinement agrees with vectorised C  --------
  #
  # The Numeric angle helpers are pure-Ruby ports of the C
  # implementations in carray_mathfunc.c.  Pin them: for a small set
  # of inputs, the refinement scalar result must equal the C result
  # on a 0-d CScalar.

  ANGLES = [-720.0, -180.0, -1.0, 0.0, 1.0, 180.0, 360.0, 720.0,
            45.0, 89.999, 90.001].freeze

  def test_deg_360_matches_c_impl
    ANGLES.each do |a|
      assert_in_delta CA_DOUBLE(a).deg_360, a.deg_360, 1e-12,
                      "deg_360(#{a}) refinement vs C disagree"
    end
  end

  def test_deg_180_matches_c_impl
    ANGLES.each do |a|
      assert_in_delta CA_DOUBLE(a).deg_180, a.deg_180, 1e-12,
                      "deg_180(#{a}) refinement vs C disagree"
    end
  end

  RADS = ANGLES.map { |a| a * Math::PI / 180.0 }.freeze

  def test_rad_2pi_matches_c_impl
    RADS.each do |r|
      assert_in_delta CA_DOUBLE(r).rad_2pi, r.rad_2pi, 1e-12,
                      "rad_2pi(#{r}) refinement vs C disagree"
    end
  end

  def test_rad_pi_matches_c_impl
    RADS.each do |r|
      assert_in_delta CA_DOUBLE(r).rad_pi, r.rad_pi, 1e-12,
                      "rad_pi(#{r}) refinement vs C disagree"
    end
  end

end
