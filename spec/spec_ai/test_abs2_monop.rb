# abs2: squared magnitude, sqrt-free counterpart of abs.
#
# For real x: abs2(x) == x * x (identical to :square on real inputs).
# For complex z: abs2(z) == creal(z)^2 + cimag(z)^2, no sqrt.
#
# Output data_type follows :abs: numeric preserved, complex -> f64.

require 'test/unit'
require 'carray'

class TestAbs2Monop < Test::Unit::TestCase
  #  ---- real: preserves data_type, equals x * x ----

  def test_int32_abs2
    a = CArray.int32(5)
    [-2, -1, 0, 1, 2].each_with_index { |v, i| a[i] = v }
    r = a.abs2
    assert_equal(:int32, r.data_type_name.to_sym)
    assert_equal([4, 1, 0, 1, 4], r.to_a)
  end

  def test_int8_abs2
    a = CArray.int8(3)
    [-3, 0, 4].each_with_index { |v, i| a[i] = v }
    r = a.abs2
    assert_equal(:int8, r.data_type_name.to_sym)
    assert_equal([9, 0, 16], r.to_a)
  end

  def test_uint8_abs2_documented_wraparound
    #  Same wraparound contract as :square — no widening.
    a = CArray.uint8(3)
    [10, 200, 100].each_with_index { |v, i| a[i] = v }
    r = a.abs2
    assert_equal(:uint8, r.data_type_name.to_sym)
    assert_equal([100, 64, 16], r.to_a)   #  40000 % 256 = 64, 10000 % 256 = 16
  end

  def test_float32_abs2
    a = CArray.float32(3)
    [-1.5, 0.0, 2.5].each_with_index { |v, i| a[i] = v }
    r = a.abs2
    assert_equal(:float32, r.data_type_name.to_sym)
    [2.25, 0.0, 6.25].each_with_index { |exp, i| assert_in_delta(exp, r[i], 1e-6) }
  end

  def test_float64_abs2
    a = CArray.float64(4) { |i| i - 1.5 }
    r = a.abs2
    assert_equal(:float64, r.data_type_name.to_sym)
    [2.25, 0.25, 0.25, 2.25].each_with_index { |exp, i| assert_in_delta(exp, r[i], 1e-12) }
  end

  #  ---- complex: creal^2 + cimag^2, output f64 ----

  def test_cmplx128_abs2
    c = CArray.cmplx128(3) { |i| Complex(3, 4) * (i + 1) }
    r = c.abs2
    assert_equal(:float64, r.data_type_name.to_sym)
    [25.0, 100.0, 225.0].each_with_index { |exp, i| assert_in_delta(exp, r[i], 1e-12) }
  end

  def test_cmplx64_abs2
    c = CArray.cmplx64(2) { |i| Complex(1, 2) * (i + 1) }
    r = c.abs2
    assert_equal(:float64, r.data_type_name.to_sym)
    [5.0, 20.0].each_with_index { |exp, i| assert_in_delta(exp, r[i], 1e-6) }
  end

  #  ---- equivalence with abs ----

  def test_abs2_equals_abs_squared_for_reals
    a = CArray.float64(5) { |i| (i - 2).to_f * 1.7 }
    r1 = a.abs2
    r2 = a.abs * a.abs
    5.times { |i| assert_in_delta(r2[i], r1[i], 1e-12) }
  end

  def test_abs2_equals_abs_squared_for_complex
    c = CArray.cmplx128(4) { |i| Complex(i + 1, i - 2) }
    r1 = c.abs2
    r2 = c.abs * c.abs
    4.times { |i| assert_in_delta(r2[i], r1[i], 1e-12) }
  end

  #  ---- mask propagation ----

  def test_mask_propagates
    a = CArray.float64(4) { |i| (i - 1).to_f }
    a[1] = UNDEF
    r = a.abs2
    assert_equal(true, r.is_masked[1])
    assert_in_delta(1.0, r[0], 1e-12)
    assert_in_delta(1.0, r[2], 1e-12)
    assert_in_delta(4.0, r[3], 1e-12)
  end
end
