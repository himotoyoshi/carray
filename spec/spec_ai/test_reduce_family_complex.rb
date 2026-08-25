# family-wide complex support: extends sum / prod / mean / mean_safe /
# sum_strict / accumulate to CMPLX_DTYPES via the Hash output form
# {numeric: :f64, complex: :cmplx128} landed in the previous step.
#
# Skipped (not in scope):
#   - min / max / argmin / argmax: no total order on complex
#   - variance / stddev: kernel body uses real arithmetic (E[|x|^2] needs
#     cabs, framework-wide work)
#   - count_*: data_type-agnostic, separate family
#   - all / any: bool only
#
# 3.0 breaking from old :wrap_to_f64 fallback:
#   - bool sum: now raises DataTypeError (was: NUM2DBL silent cast,
#     effectively counted true cells).  Migration: a.count(true) or
#     a.as_int32.sum.
#   - object sum: now raises.  Migration: a.as_float64.sum or a.to_a.sum.

require 'test/unit'
require 'carray'

class TestReduceFamilyComplex < Test::Unit::TestCase
  # ---- complex sum ----

  def test_sum_complex_returns_complex
    a = CArray.cmplx128(5)
    [Complex(1,1), Complex(2,2), Complex(3,3), Complex(4,4), Complex(5,5)].each_with_index { |v,i| a[i] = v }
    r = a.sum
    assert_equal(Complex, r.class)
    assert_in_delta(15.0, r.real, 1e-9)
    assert_in_delta(15.0, r.imag, 1e-9)
  end

  def test_sum_complex_cmplx64_widens
    a = CArray.cmplx64(3)
    [Complex(1,0), Complex(0,1), Complex(1,1)].each_with_index { |v,i| a[i] = v }
    r = a.sum
    # cmplx64 widens to cmplx128 output (via Hash form output: complex -> cmplx128)
    assert_equal(Complex, r.class)
    assert_in_delta(2.0, r.real, 1e-6)
    assert_in_delta(2.0, r.imag, 1e-6)
  end

  def test_sum_complex_per_axis
    m = CArray.cmplx128(2, 3)
    [[Complex(1,1), Complex(2,2), Complex(3,3)],
     [Complex(4,0), Complex(0,4), Complex(1,1)]].each_with_index do |row, i|
      row.each_with_index { |v,j| m[i,j] = v }
    end
    r = m.sum(axis: 1)
    assert_equal(:cmplx128, r.data_type_name.to_sym)
    # row 0: 1+1i + 2+2i + 3+3i = 6+6i
    assert_in_delta(6.0, r[0].real, 1e-9); assert_in_delta(6.0, r[0].imag, 1e-9)
    # row 1: 4+0i + 0+4i + 1+1i = 5+5i
    assert_in_delta(5.0, r[1].real, 1e-9); assert_in_delta(5.0, r[1].imag, 1e-9)
  end

  # ---- complex prod ----

  def test_prod_complex
    a = CArray.cmplx128(4)
    [Complex(1,0), Complex(0,1), Complex(1,0), Complex(0,1)].each_with_index { |v,i| a[i] = v }
    # 1 * i * 1 * i = i^2 = -1
    r = a.prod
    assert_in_delta(-1.0, r.real, 1e-9)
    assert_in_delta(0.0, r.imag, 1e-9)
  end

  # ---- complex mean ----

  def test_mean_complex
    a = CArray.cmplx128(5)
    [Complex(1,1), Complex(2,2), Complex(3,3), Complex(4,4), Complex(5,5)].each_with_index { |v,i| a[i] = v }
    r = a.mean
    # sum = (15+15i) / 5 = (3+3i)
    assert_in_delta(3.0, r.real, 1e-9)
    assert_in_delta(3.0, r.imag, 1e-9)
  end

  def test_mean_complex_per_axis
    m = CArray.cmplx128(2, 4)
    [[Complex(1,0), Complex(2,0), Complex(3,0), Complex(4,0)],
     [Complex(0,2), Complex(0,4), Complex(0,6), Complex(0,8)]].each_with_index do |row, i|
      row.each_with_index { |v,j| m[i,j] = v }
    end
    r = m.mean(axis: 1)
    # row 0: 10/4 = 2.5
    assert_in_delta(2.5, r[0].real, 1e-9); assert_in_delta(0.0, r[0].imag, 1e-9)
    # row 1: 20i/4 = 5i
    assert_in_delta(0.0, r[1].real, 1e-9); assert_in_delta(5.0, r[1].imag, 1e-9)
  end

  # ---- complex accumulate (output: :preserve so cmplx128 stays cmplx128) ----

  def test_accumulate_complex_preserves_data_type
    a = CArray.cmplx128(3)
    [Complex(1,1), Complex(2,2), Complex(3,3)].each_with_index { |v,i| a[i] = v }
    r = a.accumulate
    # preserve = same as source, no widening
    assert_in_delta(6.0, r.real, 1e-9)
    assert_in_delta(6.0, r.imag, 1e-9)
  end

  # ---- numeric path preserved (regression check) ----

  def test_int_sum_still_widens_to_f64
    a = CArray.int32(4).seq + 1
    r = a.sum
    assert_equal(Float, r.class)
    assert_in_delta(10.0, r, 1e-9)
  end

  def test_float_mean_still_f64
    a = CArray.float64(5).seq + 1.0
    assert_in_delta(3.0, a.mean, 1e-9)
  end

  # ---- bool sum / mean accepted (PROPOSAL_BOOLEAN_REDUCE_ACCEPT 2026-06-15) ----
  # E.6a's "reject boolean reduce" was reverted for sum/mean: those map to
  # count / proportion-of-true which are well-defined and match NumPy.
  # min/max/variance still reject — use .all/.any/Bernoulli-variance
  # explicitly.

  def test_bool_sum_returns_count
    a = CArray.boolean(5)
    [true, false, true, true, false].each_with_index { |v,i| a[i] = v }
    assert_equal(3, a.sum)
    # Equivalent to count(true)
    assert_equal(3, a.count(true))
  end

  def test_bool_mean_returns_proportion
    a = CArray.boolean(5)
    [true, false, true, true, false].each_with_index { |v,i| a[i] = v }
    assert_in_delta(0.6, a.mean, 1e-12)
  end

  # ---- object sum: works via mkkernel :object dtype branch
  # (PROPOSAL_MKKERNEL_OBJECT_DTYPE_BRANCH Phase 1) ----

  def test_object_sum_works
    a = CArray.object(3)
    [1, 2, 3].each_with_index { |v,i| a[i] = v }
    assert_equal(6, a.sum)
  end

  def test_object_mean_works
    # PROPOSAL_MKKERNEL_OBJECT_DTYPE_BRANCH Phase 3.5 (2026-06-22):
    # CA_OBJECT.mean now routes through the mkkernel :object branch
    # (= rb_funcall :+ for the accumulator, rb_funcall :/ for the
    # divisor).  Floats divide naturally as Ruby Float.
    a = CArray.object(3)
    [1.0, 2.0, 3.0].each_with_index { |v,i| a[i] = v }
    assert_equal(2.0, a.mean)
  end

  # ---- complex lazy chain + reduce streaming (release narrative) ----

  def test_lazy_complex_chain_sum_streams
    n = 100
    a = CArray.cmplx128(n) { |i| Complex(i * 0.01, i * 0.005) rescue Complex(0,0) }
    n.times { |i| a[i] = Complex(i * 0.01, i * 0.005) }   # ensure init
    b = CArray.cmplx128(n)
    n.times { |i| b[i] = Complex(0, i * 0.001) }
    # 2-stage lazy chain: (a.lazy + b).sum
    expected = (a + b).sum
    actual = (a.lazy + b).sum
    assert_in_delta(expected.real, actual.real, 1e-9)
    assert_in_delta(expected.imag, actual.imag, 1e-9)
  end

  def test_lazy_complex_correlation_pattern
    # (a.lazy.conj * b).sum = inner product / correlation
    n = 50
    a = CArray.cmplx128(n)
    b = CArray.cmplx128(n)
    n.times { |i| a[i] = Complex(Math.cos(i * 0.1), Math.sin(i * 0.1)) }
    n.times { |i| b[i] = Complex(Math.cos(i * 0.1 + 0.5), Math.sin(i * 0.1 + 0.5)) }
    expected = (a.conj * b).sum
    actual = (a.lazy.conj * b).sum
    assert_in_delta(expected.real, actual.real, 1e-9)
    assert_in_delta(expected.imag, actual.imag, 1e-9)
  end

  def test_lazy_complex_chain_mean_per_axis
    n = 100
    m = CArray.cmplx128(3, n)
    3.times { |i| n.times { |j| m[i,j] = Complex(i + 1, j * 0.1) } }
    # (m.lazy + offset).mean(axis: 1) -- per-row mean of lazy chain
    offset = CArray.cmplx128(3, n) { Complex(1, 0) }
    3.times { |i| n.times { |j| offset[i,j] = Complex(1, 0) } }
    expected = (m + offset).mean(axis: 1)
    actual = (m.lazy + offset).mean(axis: 1)
    3.times do |i|
      assert_in_delta(expected[i].real, actual[i].real, 1e-9)
      assert_in_delta(expected[i].imag, actual[i].imag, 1e-9)
    end
  end
end
