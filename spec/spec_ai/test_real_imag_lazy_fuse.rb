# real/imag lazy fuse (post-IC follow-up).
#
# Verifies:
# - Eager .real / .imag unchanged (CAField for complex, CARefer/template
#   for non-complex)
# - Lazy complex .real → CAMonOp(cast_<float>) (1-node)
# - Lazy complex .imag → CAMonOp(cast_<float>) ∘ CAMonOp(imag_i) (2-node)
# - Lazy non-complex .real → self (pass-through, chain unchanged)
# - Lazy non-complex .imag → CAMonOp(imag_i) all-zeros
# - Chain over reduction (= sum / count) streams without intermediate
# - imag_i kernel: numeric→0, complex→cimag in real slot

require 'test/unit'
require 'carray'

class TestRealImagLazyFuse < Test::Unit::TestCase
  # ---- imag_i raw kernel ----

  def test_imag_i_int
    a = CArray.int32(5) { |i| i + 1 }
    assert_equal([0, 0, 0, 0, 0], a.imag_i.to_a)
  end

  def test_imag_i_float
    a = CArray.float64(3) { |i| i * 1.5 }
    assert_equal([0.0, 0.0, 0.0], a.imag_i.to_a)
  end

  def test_imag_i_complex_stores_in_real_slot
    a = CArray.cmplx128(3) { |i| Complex(i + 1.0, i + 0.5) }
    r = a.imag_i
    # cimag written into the real component, imag = 0
    assert_equal([Complex(0.5, 0), Complex(1.5, 0), Complex(2.5, 0)], r.to_a)
  end

  # ---- eager .real / .imag unchanged ----

  def test_eager_real_complex_is_cafield
    a = CArray.cmplx128(3) { |i| Complex(i + 1.0, i + 0.5) }
    assert_equal(CAField, a.real.class)
    assert_equal([1.0, 2.0, 3.0], a.real.to_a)
  end

  def test_eager_imag_complex_is_cafield
    a = CArray.cmplx128(3) { |i| Complex(i + 1.0, i + 0.5) }
    assert_equal(CAField, a.imag.class)
    assert_equal([0.5, 1.5, 2.5], a.imag.to_a)
  end

  def test_eager_real_float_self_view
    a = CArray.float64(3) { |i| i * 1.0 }
    # real of a real array is a CARefer self-view
    assert_equal(CARefer, a.real.class)
    assert_equal([0.0, 1.0, 2.0], a.real.to_a)
  end

  def test_eager_imag_float_template_zeros
    a = CArray.float64(3) { |i| i * 1.0 }
    # imag of a real array is a fresh template-filled zero entity
    assert_equal(CArray, a.imag.class)
    assert_equal([0.0, 0.0, 0.0], a.imag.to_a)
  end

  # ---- lazy complex ----

  def test_lazy_complex_real_returns_camonop
    a = CArray.cmplx128(3) { |i| Complex(i + 1.0, i + 0.5) }
    v = a.lazy.real
    assert_equal(CAMonOp, v.class)
    assert_equal(:float64, v.data_type_name.to_sym)
    assert_equal([1.0, 2.0, 3.0], v.to_ca.to_a)
  end

  def test_lazy_complex_imag_returns_camonop
    a = CArray.cmplx128(3) { |i| Complex(i + 1.0, i + 0.5) }
    v = a.lazy.imag
    assert_equal(CAMonOp, v.class)
    assert_equal(:float64, v.data_type_name.to_sym)
    assert_equal([0.5, 1.5, 2.5], v.to_ca.to_a)
  end

  def test_lazy_cmplx64_real_uses_float32
    a = CArray.cmplx64(3) { |i| Complex(i + 1.0, i + 0.5) }
    v = a.lazy.real
    assert_equal(:float32, v.data_type_name.to_sym)
  end

  def test_lazy_cmplx64_imag_uses_float32
    a = CArray.cmplx64(3) { |i| Complex(i + 1.0, i + 0.5) }
    v = a.lazy.imag
    assert_equal(:float32, v.data_type_name.to_sym)
  end

  # ---- lazy non-complex ----

  def test_lazy_float_real_is_passthrough
    a = CArray.float64(5) { |i| i * 1.0 }
    b = CArray.float64(5) { |i| i * 0.1 }
    chain = (a.lazy + b)
    # .real on non-complex lazy is identity (preserves chain)
    assert_equal(chain.class, chain.real.class)
  end

  def test_lazy_float_imag_returns_camonop_zeros
    a = CArray.float64(5) { |i| i * 1.0 }
    v = a.lazy.imag
    assert_equal(CAMonOp, v.class)
    assert_equal([0.0, 0.0, 0.0, 0.0, 0.0], v.to_ca.to_a)
  end

  # ---- chain reductions (streaming pin) ----

  def test_lazy_complex_real_sum_parity
    a = CArray.cmplx128(50) { |i| Complex(i * 1.0, i * 0.5) }
    assert_in_delta(a.real.sum, a.lazy.real.sum, 1e-9)
  end

  def test_lazy_complex_imag_sum_parity
    a = CArray.cmplx128(50) { |i| Complex(i * 1.0, i * 0.5) }
    assert_in_delta(a.imag.sum, a.lazy.imag.sum, 1e-9)
  end

  def test_chain_conj_real_sum_parity
    # cmplx -> conj -> real -> sum (= 3-node lazy chain ending in reduce)
    a = CArray.cmplx128(20) { |i| Complex(i + 1.0, i + 0.5) }
    assert_in_delta(a.conj.real.sum, a.lazy.conj.real.sum, 1e-9)
  end

  def test_chain_binop_real_sum_parity
    # f64 + f64 -> real -> sum (= real is passthrough on non-complex)
    a = CArray.float64(50) { |i| i * 1.0 }
    b = CArray.float64(50) { |i| i * 0.1 }
    assert_in_delta((a + b).real.sum, (a.lazy + b).real.sum, 1e-9)
  end

  # ---- mask propagation ----

  def test_lazy_complex_real_mask_propagation
    a = CArray.cmplx128(4) { |i| Complex(i + 1.0, i + 0.5) }
    a[1] = UNDEF
    r = a.lazy.real.to_ca
    assert_equal([false, true, false, false], r.is_masked.to_a)
  end

  def test_lazy_complex_imag_mask_propagation
    a = CArray.cmplx128(4) { |i| Complex(i + 1.0, i + 0.5) }
    a[2] = UNDEF
    r = a.lazy.imag.to_ca
    assert_equal([false, false, true, false], r.is_masked.to_a)
  end
end
