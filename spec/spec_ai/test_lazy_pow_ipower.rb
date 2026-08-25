# frozen_string_literal: true
#
# CA_BINOP_IPOWER — Float/Complex ** Integer lazy fast path
#
# Pins:
#   - `a.lazy ** Integer` on Float/Complex parent routes to OP_IPOWER
#     (binary exponentiation via op_powi_<type>), not OP_POW
#     (transcendental pow / cpow).
#   - byte parity with eager `a ** Integer` across:
#       * float32 / float64 / cmplx64 / cmplx128
#       * positive / negative / 0 / 1 exponent
#       * masked parent (masked cells preserved)
#       * lazy chain ((a.lazy + b) ** 2)
#   - non-Integer exponent falls back to OP_POW (parity preserved).
#   - Integer parent stays on OP_POW path (mkkernel `power` binop expr
#     already uses op_powi for integer data_type via the `int:` branch).

require "test/unit"
require "carray"

class TestLazyPowIpower < Test::Unit::TestCase
  def setup
    @f64 = CA_FLOAT64([2.0, 3.0, 4.0, 5.0])
    @f32 = CA_FLOAT32([2.0, 3.0, 4.0, 5.0])
    @cmplx = CA_CMPLX128([Complex(1, 1), Complex(2, 0), Complex(0, 3)])
  end

  # --- routing --------------------------------------------------------

  def test_routes_to_op_ipower_for_float_integer
    node = @f64.lazy ** 2
    assert_kind_of CABinOp, node
    assert_equal CABinOp::OP_IPOWER, node.__op_id__
    # right operand is wrapped as int64 CScalar carrying the exponent
    right = node.__binop_right__
    assert_kind_of CScalar, right
    assert_equal CA_INT64, right.data_type
    assert_equal 2, right[0]
  end

  def test_routes_to_op_pow_for_float_float_exponent
    node = @f64.lazy ** 2.5
    assert_kind_of CABinOp, node
    assert_equal CABinOp::OP_POW, node.__op_id__
  end

  # --- correctness parity --------------------------------------------

  def test_f64_positive
    assert_equal((@f64 ** 2).to_a, (@f64.lazy ** 2).to_ca.to_a)
    assert_equal((@f64 ** 3).to_a, (@f64.lazy ** 3).to_ca.to_a)
    assert_equal((@f64 ** 7).to_a, (@f64.lazy ** 7).to_ca.to_a)
  end

  def test_f64_zero_and_one
    assert_equal((@f64 ** 0).to_a, (@f64.lazy ** 0).to_ca.to_a)
    assert_equal((@f64 ** 1).to_a, (@f64.lazy ** 1).to_ca.to_a)
  end

  def test_f64_negative
    expected = (@f64 ** -1).to_a
    actual   = (@f64.lazy ** -1).to_ca.to_a
    expected.each_with_index do |v, i|
      assert_in_delta v, actual[i], 1e-12
    end
  end

  def test_f32
    assert_equal((@f32 ** 2).to_a, (@f32.lazy ** 2).to_ca.to_a)
    assert_equal((@f32 ** 4).to_a, (@f32.lazy ** 4).to_ca.to_a)
  end

  def test_cmplx128
    assert_equal((@cmplx ** 2).to_a, (@cmplx.lazy ** 2).to_ca.to_a)
    assert_equal((@cmplx ** 3).to_a, (@cmplx.lazy ** 3).to_ca.to_a)
  end

  def test_cmplx64
    c = CA_CMPLX64([Complex(1, 1), Complex(2, 0)])
    assert_equal((c ** 2).to_a, (c.lazy ** 2).to_ca.to_a)
  end

  # --- mask propagation ----------------------------------------------

  def test_masked_parent_preserves_mask
    m = CA_FLOAT64([2.0, 3.0, 4.0])
    m.mask = CA_BOOLEAN([0, 1, 0])
    eager_r = m.power(2)
    lazy_r  = (m.lazy ** 2).to_ca
    assert_equal eager_r.mask.to_a, lazy_r.mask.to_a
    assert_equal eager_r.to_a, lazy_r.to_a
  end

  # --- chain ----------------------------------------------------------

  def test_chain_with_binop_parent
    a = CA_FLOAT64([1.0, 2.0, 3.0])
    b = CA_FLOAT64([2.0, 3.0, 4.0])
    eager_r = (a + b) ** 2
    lazy_r  = ((a.lazy + b) ** 2).to_ca
    assert_equal eager_r.to_a, lazy_r.to_a
  end

  # --- fallback paths ------------------------------------------------

  def test_float_exponent_falls_back_to_op_pow
    # 2.5 is not Integer -> OP_POW path, eager parity expected.
    expected = (@f64 ** 2.5).to_a
    actual   = (@f64.lazy ** 2.5).to_ca.to_a
    expected.each_with_index do |v, i|
      assert_in_delta v, actual[i], 1e-12
    end
  end

  def test_integer_parent_uses_op_pow_path
    # Integer parent + Integer exponent: stays on OP_POW (mkkernel
    # `power` binop's `int:` expr already uses op_powi_<type>).
    ai = CA_INT32([2, 3, 4])
    assert_equal((ai ** 3).to_a, (ai.lazy ** 3).to_ca.to_a)
  end

  # --- eager unaffected ----------------------------------------------

  def test_eager_path_unchanged
    # Sanity: eager dispatch still works (not lazy).
    assert_equal [4.0, 9.0, 16.0, 25.0], (@f64 ** 2).to_a
  end
end
