# frozen_string_literal: true
#
# arg (phase angle) — mkkernel monop migration.
#
# Migration of the hand-written rb_ca_arg (ext/carray_numeric.c) to a
# data_type-changing monop with output: { numeric: :f64, complex: :f64 }
# Hash form.  Always returns f64 (= NumPy `np.angle` convention).
#
# Semantics: `carg(z)` for complex, `carg((cmplx128_t)x)` for real
# (positive real -> 0, negative real -> pi, 0 -> 0).
#
# 3.0 breaking (vs hand-written rb_ca_arg):
#   - Integer input is now accepted (was a raise).  Returns f64
#     0 / pi by sign via carg semantics.
#
# Per-axis / lazy chain / view universality come for free via the
# kernel_iterator substrate (= mkkernel monop framework).

require "test/unit"
require "carray"

class TestArgMonop < Test::Unit::TestCase
  PI = Math::PI

  # --- mathematical correctness: real input ---------------------------

  def test_float64_positive_returns_zero
    a = CA_FLOAT64([1.0, 2.5, 100.0])
    r = a.arg
    assert_equal CA_FLOAT64, r.data_type
    assert_equal [0.0, 0.0, 0.0], r.to_a
  end

  def test_float64_negative_returns_pi
    a = CA_FLOAT64([-1.0, -2.5, -100.0])
    r = a.arg
    r.to_a.each { |v| assert_in_delta PI, v, 1e-12 }
  end

  def test_float64_zero
    a = CA_FLOAT64([0.0])
    r = a.arg
    assert_equal [0.0], r.to_a
  end

  def test_float32_output_data_type_is_f64
    # f64 output (not preserve) since pi does not exactly fit / NumPy
    # `np.angle` convention.
    a = CA_FLOAT32([1.0, -1.0, 0.0])
    r = a.arg
    assert_equal CA_FLOAT64, r.data_type
    assert_in_delta 0.0, r[0], 1e-12
    assert_in_delta PI,  r[1], 1e-6
    assert_in_delta 0.0, r[2], 1e-12
  end

  def test_int_input_accepted_breaking
    # 3.0 breaking: was raise.  Now returns f64 via carg((cmplx128)x).
    a = CA_INT32([1, -1, 0, 42, -42])
    r = a.arg
    assert_equal CA_FLOAT64, r.data_type
    assert_in_delta 0.0, r[0], 1e-12
    assert_in_delta PI,  r[1], 1e-12
    assert_in_delta 0.0, r[2], 1e-12
    assert_in_delta 0.0, r[3], 1e-12
    assert_in_delta PI,  r[4], 1e-12
  end

  def test_int8_input
    a = CA_INT8([1, -1, 0])
    r = a.arg
    assert_equal CA_FLOAT64, r.data_type
    assert_in_delta 0.0, r[0], 1e-12
    assert_in_delta PI,  r[1], 1e-12
  end

  # --- complex input -> f64 carg ------------------------------------

  def test_cmplx128_carg
    a = CA_CMPLX128([Complex(1, 0), Complex(0, 1), Complex(-1, 0), Complex(1, 1)])
    r = a.arg
    assert_equal CA_FLOAT64, r.data_type
    assert_in_delta 0.0,            r[0], 1e-12
    assert_in_delta PI / 2,         r[1], 1e-12
    assert_in_delta PI,             r[2], 1e-12
    assert_in_delta PI / 4,         r[3], 1e-12
  end

  def test_cmplx128_negative_imag
    # arg(z) is in (-pi, pi]; negative imag -> negative angle.
    a = CA_CMPLX128([Complex(0, -1), Complex(1, -1)])
    r = a.arg
    assert_in_delta -PI / 2, r[0], 1e-12
    assert_in_delta -PI / 4, r[1], 1e-12
  end

  def test_cmplx64_carg
    a = CA_CMPLX64([Complex(1, 0), Complex(0, 1)])
    r = a.arg
    assert_equal CA_FLOAT64, r.data_type
    assert_in_delta 0.0,    r[0], 1e-6
    assert_in_delta PI / 2, r[1], 1e-6
  end

  # --- mask propagation ---------------------------------------------

  def test_masked_real_parent
    a = CA_FLOAT64([1.0, 2.0, -3.0])
    a.mask = CA_BOOLEAN([0, 1, 0])
    r = a.arg
    assert_equal [false, true, false], r.mask.to_a
    assert_in_delta 0.0, r[0], 1e-12
    assert_in_delta PI,  r[2], 1e-12
  end

  def test_masked_complex_parent
    a = CA_CMPLX128([Complex(0, 1), Complex(1, 0), Complex(-1, 0)])
    a.mask = CA_BOOLEAN([0, 1, 0])
    r = a.arg
    assert_equal CA_FLOAT64, r.data_type
    assert_in_delta PI / 2, r[0], 1e-12
    assert_in_delta PI,     r[2], 1e-12
  end

  # --- per-axis (= kernel_iterator substrate) ------------------------

  def test_2d_real_shape_preserved
    a = CArray.float64(3, 4) { |i, j| i * 4 + j - 5 }   # mix of +/- /0
    r = a.arg
    assert_equal [3, 4], r.dim
    assert_equal CA_FLOAT64, r.data_type
    a.elements.times do |k|
      flat = a[k.divmod(4)[0], k.divmod(4)[1]]
      expected = flat < 0 ? PI : 0.0
      assert_in_delta expected, r[k.divmod(4)[0], k.divmod(4)[1]], 1e-12
    end
  end

  def test_2d_complex_input
    a = CArray.cmplx128(2, 2) { |i, j| Complex(i, j) }
    r = a.arg
    assert_equal [2, 2], r.dim
    assert_equal CA_FLOAT64, r.data_type
    assert_in_delta 0.0,    r[0, 0], 1e-12
    assert_in_delta PI / 2, r[0, 1], 1e-12
    assert_in_delta 0.0,    r[1, 0], 1e-12
    assert_in_delta PI / 4, r[1, 1], 1e-12
  end

  # --- view universality (kernel_iterator handles all source kinds) -

  def test_through_block_view
    a = CArray.float64(4, 4) { |i, j| (i * 4 + j) - 8 }
    blk = a[1..2, nil]
    r = blk.arg
    assert_equal [2, 4], r.dim
    # row 1 (= elements -4..-1) -> all pi; row 2 (= 0..3) -> all 0
    r.dim[1].times { |j| assert_in_delta PI,  r[0, j], 1e-12 }
    r.dim[1].times { |j| assert_in_delta 0.0, r[1, j], 1e-12 }
  end

  def test_through_transpose
    a = CArray.cmplx128(2, 2) { |i, j| Complex(i + 1, j + 1) }
    r = a.transpose.arg
    assert_equal [2, 2], r.dim
    assert_equal CA_FLOAT64, r.data_type
  end
end
