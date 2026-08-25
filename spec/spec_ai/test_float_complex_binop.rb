# Binop cast for (float CArray) op (Complex Ruby scalar).
#
# Previously the coercion inside rb_ca_cast_self_or_other short-circuited
# on `rb_ca_is_float_type(self)` and wrapped the Complex scalar as
# CA_FLOAT64, which triggered NUM2DBL(Complex) and raised RangeError.
# The fix wraps a Complex scalar as CA_CMPLX128 first; the downstream
# promotion then lifts the float CArray to cmplx128.
#
# Int * Complex, cmplx * Complex were unaffected and are covered here as
# guardrails.

require 'test/unit'
require 'carray'

class TestFloatComplexBinop < Test::Unit::TestCase
  def test_float64_times_complex_scalar
    a = CArray.float64(3).seq
    r = a * Complex(0, 1)
    assert_equal(:cmplx128, r.data_type_name.to_sym)
    [Complex(0, 0), Complex(0, 1), Complex(0, 2)].each_with_index do |exp, i|
      assert_in_delta(exp.real, r[i].real, 1e-12)
      assert_in_delta(exp.imag, r[i].imag, 1e-12)
    end
  end

  def test_complex_scalar_times_float64
    a = CArray.float64(3).seq
    r = Complex(0, 1) * a
    assert_equal(:cmplx128, r.data_type_name.to_sym)
    assert_in_delta(0.0, r[0].imag, 1e-12)
    assert_in_delta(1.0, r[1].imag, 1e-12)
    assert_in_delta(2.0, r[2].imag, 1e-12)
  end

  def test_float64_plus_complex_scalar
    a = CArray.float64(3).seq
    r = a + Complex(1, 2)
    assert_equal(:cmplx128, r.data_type_name.to_sym)
    assert_in_delta(1.0, r[0].real, 1e-12)
    assert_in_delta(2.0, r[0].imag, 1e-12)
    assert_in_delta(3.0, r[2].real, 1e-12)
  end

  def test_float32_times_complex_scalar
    a = CArray.float32(3).seq
    r = a * Complex(0, 1)
    #  f32 * cmplx128 promotes to cmplx128 (the wider complex).
    assert_equal(:cmplx128, r.data_type_name.to_sym)
    assert_in_delta(2.0, r[2].imag, 1e-6)
  end

  #  ---- broadcast: Complex::I * cy where cy is float64 ----

  def test_cx_plus_i_times_cy_1d
    cx = CArray.float64(3).seq
    cy = CArray.float64(3).seq
    grid = cx + Complex::I * cy
    assert_equal(:cmplx128, grid.data_type_name.to_sym)
    3.times do |i|
      assert_in_delta(i.to_f, grid[i].real, 1e-12)
      assert_in_delta(i.to_f, grid[i].imag, 1e-12)
    end
  end

  def test_cx_plus_i_times_cy_2d_broadcast
    xx   = CArray.float64(1, 4).seq
    yy   = CArray.float64(3, 1).seq
    grid = xx + Complex::I * yy
    assert_equal([3, 4], grid.shape)
    assert_equal(:cmplx128, grid.data_type_name.to_sym)
    3.times do |i|
      4.times do |j|
        assert_in_delta(j.to_f, grid[i, j].real, 1e-12)
        assert_in_delta(i.to_f, grid[i, j].imag, 1e-12)
      end
    end
  end

  #  ---- guardrails: previously working paths unchanged ----

  def test_int_times_complex_still_works
    a = CArray.int32(3).seq
    r = a * Complex(0, 1)
    assert_equal(:cmplx128, r.data_type_name.to_sym)
    assert_in_delta(2.0, r[2].imag, 1e-12)
  end

  def test_cmplx128_times_complex_still_works
    a = CArray.cmplx128(3) { |i| Complex(i, 0) }
    r = a * Complex(0, 1)
    assert_equal(:cmplx128, r.data_type_name.to_sym)
    assert_in_delta(2.0, r[2].imag, 1e-12)
  end

  def test_float64_times_float_still_widens_not_complex
    a = CArray.float64(3).seq
    r = a * 2.5
    assert_equal(:float64, r.data_type_name.to_sym)
    assert_in_delta(5.0, r[2], 1e-12)
  end
end
