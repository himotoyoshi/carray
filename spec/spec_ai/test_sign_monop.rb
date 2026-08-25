# frozen_string_literal: true
#
# sign (signum) — mkkernel monop migration.
#
# Migration of the multi-pass Ruby `def sign` in lib/carray/math.rb to a
# preserve-data_type monop on the kernel_iterator substrate.
#
# Old implementation was:
#   out = self.zero
#   out[self.lt(0)] = -1
#   out[self.gt(0)] = 1
#   if float?
#     out[self.is_nan] = 0.0/0.0
#   end
#
# = 3-4 passes over data + intermediate boolean mask allocations.  And
# it was MATHEMATICALLY INCORRECT for complex input: `z < 0` is undefined
# in the complex field (the complex numbers are not an ordered field),
# so the lt/gt branches gave nonsense for complex sources.
#
# New mkkernel implementation:
#   bool        true -> 1, false -> 0
#   uint        x > 0 -> 1, otherwise 0
#   sint        ((x > 0) - (x < 0))                 (= -1 / 0 / 1)
#   float       isnan(x) ? x : sign-of-real         (NaN preserved)
#   complex     z == 0 ? 0 : z / |z|                (unit vector)
#
# Output data_type preserves input data_type throughout.

require "test/unit"
require "carray"

class TestSignMonop < Test::Unit::TestCase
  # --- bool / unsigned ---------------------------------------------

  def test_bool
    a = CA_BOOLEAN([true, false, true, false])
    r = a.sign
    assert_equal [true, false, true, false], r.to_a
  end

  def test_uint
    a = CA_UINT16([0, 1, 100, 0xFFFF])
    r = a.sign
    assert_equal CA_UINT16, r.data_type
    assert_equal [0, 1, 1, 1], r.to_a
  end

  # --- signed integer ----------------------------------------------

  def test_int32
    a = CA_INT32([5, -3, 0, 100, -100])
    r = a.sign
    assert_equal CA_INT32, r.data_type
    assert_equal [1, -1, 0, 1, -1], r.to_a
  end

  def test_int8_negative_boundary
    a = CA_INT8([-128, -1, 0, 1, 127])
    r = a.sign
    assert_equal CA_INT8, r.data_type
    assert_equal [-1, -1, 0, 1, 1], r.to_a
  end

  # --- float -------------------------------------------------------

  def test_float64_basic
    a = CA_FLOAT64([1.5, -2.3, 0.0, -0.0])
    r = a.sign
    assert_equal CA_FLOAT64, r.data_type
    # +0.0 and -0.0 both return 0 (neither > 0 nor < 0).
    assert_equal [1.0, -1.0, 0.0, 0.0], r.to_a
  end

  def test_float64_inf
    a = CA_FLOAT64([1.0 / 0.0, -1.0 / 0.0])
    r = a.sign
    assert_equal [1.0, -1.0], r.to_a
  end

  def test_float64_nan_preserved
    nan = 0.0 / 0.0
    a = CA_FLOAT64([nan, 1.0, nan, -1.0])
    r = a.sign
    assert r[0].nan?, "NaN should be preserved"
    assert_equal 1.0, r[1]
    assert r[2].nan?
    assert_equal(-1.0, r[3])
  end

  def test_float32_preserve_data_type
    a = CA_FLOAT32([1.0, -1.0, 0.0])
    r = a.sign
    assert_equal CA_FLOAT32, r.data_type
    assert_equal [1.0, -1.0, 0.0], r.to_a
  end

  # --- complex (= mathematically correct: z / |z|) -----------------

  def test_cmplx128_zero
    a = CA_CMPLX128([Complex(0, 0)])
    r = a.sign
    assert_equal CA_CMPLX128, r.data_type
    assert_equal Complex(0, 0), r[0]
  end

  def test_cmplx128_unit_vector
    # |3+4i| = 5, so sign(3+4i) = 0.6 + 0.8i
    a = CA_CMPLX128([Complex(3, 4), Complex(-3, -4)])
    r = a.sign
    assert_in_delta 0.6, r[0].real, 1e-12
    assert_in_delta 0.8, r[0].imaginary, 1e-12
    assert_in_delta(-0.6, r[1].real, 1e-12)
    assert_in_delta(-0.8, r[1].imaginary, 1e-12)
  end

  def test_cmplx128_axes_preserved
    # On the real axis: sign maps to +/-1 + 0i (unchanged real magnitude).
    a = CA_CMPLX128([Complex(2, 0), Complex(-7, 0)])
    r = a.sign
    assert_in_delta 1.0,  r[0].real,      1e-12
    assert_in_delta 0.0,  r[0].imaginary, 1e-12
    assert_in_delta(-1.0, r[1].real,      1e-12)
  end

  def test_cmplx128_imag_axis
    # On the imag axis: sign(0 + bi) = 0 + sign(b)*i.
    a = CA_CMPLX128([Complex(0, 5), Complex(0, -3)])
    r = a.sign
    assert_in_delta 0.0,  r[0].real,      1e-12
    assert_in_delta 1.0,  r[0].imaginary, 1e-12
    assert_in_delta 0.0,  r[1].real,      1e-12
    assert_in_delta(-1.0, r[1].imaginary, 1e-12)
  end

  def test_cmplx128_magnitude_is_unit
    # Every non-zero output must lie on the unit circle.
    a = CA_CMPLX128([Complex(1, 2), Complex(-7, 11), Complex(0.001, 0.0001)])
    r = a.sign
    a.elements.times do |k|
      assert_in_delta 1.0, r[k].abs, 1e-12, "|sign(z)| must be 1 for non-zero z (index #{k})"
    end
  end

  def test_cmplx64
    a = CA_CMPLX64([Complex(3, 4)])
    r = a.sign
    assert_equal CA_CMPLX64, r.data_type
    assert_in_delta 0.6, r[0].real,      1e-6
    assert_in_delta 0.8, r[0].imaginary, 1e-6
  end

  # --- mask propagation --------------------------------------------

  def test_mask_propagated
    a = CA_FLOAT64([1.0, -2.0, 0.0])
    a.mask = CA_BOOLEAN([0, 1, 0])
    r = a.sign
    assert_equal [false, true, false], r.mask.to_a
    assert_equal 1.0, r[0]
    assert_equal 0.0, r[2]
  end

  # --- per-axis / view universality --------------------------------

  def test_2d_shape_preserved
    a = CArray.int32(3, 4) { |i, j| (i * 4 + j) - 6 }
    r = a.sign
    assert_equal [3, 4], r.dim
    assert_equal CA_INT32, r.data_type
    a.elements.times do |k|
      i, j = k.divmod(4)
      v = a[i, j]
      expected = v > 0 ? 1 : (v < 0 ? -1 : 0)
      assert_equal expected, r[i, j]
    end
  end

  def test_through_block_view
    a = CA_INT32([-3, -1, 0, 1, 3])
    blk = a[1..3]
    r = blk.sign
    assert_equal [-1, 0, 1], r.to_a
  end

  def test_through_transpose
    a = CArray.cmplx128(2, 2) { |i, j| Complex(i + 1, j + 1) }
    r = a.transpose.sign
    assert_equal [2, 2], r.dim
    assert_equal CA_CMPLX128, r.data_type
    # |sign(z)| == 1 invariant
    2.times { |i| 2.times { |j| assert_in_delta 1.0, r[i, j].abs, 1e-12 } }
  end
end
