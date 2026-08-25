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
