# PROPOSAL_IS_CLOSE_BINCMP_MIGRATION IC.5: migration test pin
#
# Verifies:
# - eager scalar v parity with legacy semantics
# - (β) CArray v broadcast (NEW capability via bincmp framework)
# - lazy fuse via CABinCmp::OP_IS_CLOSE / OP_IS_EQUIV
# - mask propagation school A (= masked input -> masked output)
# - complex data_type coverage

require 'test/unit'
require 'carray'

class TestIsCloseBincmpMigration < Test::Unit::TestCase
  # ---- eager scalar v parity ----

  def test_is_close_scalar_v_float
    a = CArray.float64(5) { |i| i * 1.0 }
    assert_equal([true, true, false, false, false], a.is_close(0.5, 0.5).to_a)
    assert_equal([false, false, false, false, false], a.is_close(0.5, 0.1).to_a)
  end

  def test_is_close_scalar_v_int
    a = CArray.int32(5) { |i| i }
    assert_equal([false, true, true, true, false], a.is_close(2, 1).to_a)
  end

  def test_is_equiv_scalar_v_float
    a = CArray.float64(3) { |i| [100.0, 1000.0, 10000.0][i] }
    # 1% rtol around 1000: 990..1010, only index 1 matches
    assert_equal([false, true, false], a.is_equiv(1000.0, 0.01).to_a)
  end

  # ---- (β) CArray v broadcast (NEW capability) ----

  def test_is_close_carray_v_same_shape
    a = CArray.float64(5) { |i| i * 1.0 }
    b = CArray.float64(5) { |i| i * 1.0 + 0.3 }
    assert_equal([true, true, true, true, true], a.is_close(b, 0.5).to_a)
    assert_equal([false, false, false, false, false], a.is_close(b, 0.1).to_a)
  end

  def test_is_close_carray_v_size_1_broadcast
    a = CArray.float64(5) { |i| i * 1.0 }
    b = CArray.float64(1) { 2.0 }
    assert_equal([false, true, true, true, false], a.is_close(b, 1.0).to_a)
  end

  def test_is_equiv_carray_v
    a = CArray.float64(3) { |i| [100.0, 1000.0, 10000.0][i] }
    v = CArray.float64(3) { |i| [99.0, 1005.0, 11000.0][i] }
    # per-element rtol = 0.05 (5%)
    # i=0: |100-99|/100 = 0.01 <= 0.05 -> true
    # i=1: |1000-1005|/1005 = 0.00497 <= 0.05 -> true
    # i=2: |10000-11000|/11000 = 0.0909 > 0.05 -> false
    assert_equal([true, true, false], a.is_equiv(v, 0.05).to_a)
  end

  # ---- lazy fuse ----

  def test_lazy_is_close_lhs
    a = CArray.float64(5) { |i| i * 1.0 }
    b = CArray.float64(5) { |i| i * 1.0 + 0.3 }
    v = a.lazy.is_close(b, 0.5)
    assert_equal(CABinCmp, v.class)
    assert_equal([true, true, true, true, true], v.to_ca.to_a)
  end

  def test_lazy_is_close_rhs
    a = CArray.float64(5) { |i| i * 1.0 }
    b = CArray.float64(5) { |i| i * 1.0 + 0.3 }
    v = a.is_close(b.lazy, 0.5)
    assert_equal(CABinCmp, v.class)
    assert_equal([true, true, true, true, true], v.to_ca.to_a)
  end

  def test_lazy_is_equiv_chain_count
    # Phase 4.5 streaming reduce should ride this chain
    a = CArray.float64(100) { |i| i * 1.0 }
    v = CArray.float64(100) { |i| i * 1.005 }
    count = a.lazy.is_equiv(v, 0.01).count(true)
    # all within 1% rtol -> 100
    assert_equal(100, count)
  end

  # ---- mask propagation (school A) ----

  def test_is_close_mask_propagation
    a = CArray.float64(5) { |i| i * 1.0 }
    a[2] = UNDEF
    r = a.is_close(2.0, 0.5)
    assert_equal([false, false, false, false, false], r.value.to_a)
    assert_equal([false, false, true, false, false], r.is_masked.to_a)
  end

  # ---- complex data_type coverage ----

  def test_is_close_cmplx128
    a = CArray.cmplx128(3) { |i| [Complex(1, 0), Complex(0, 1), Complex(2, 2)][i] }
    b = CArray.cmplx128(3) { |i| [Complex(1.1, 0), Complex(0, 1.1), Complex(3, 3)][i] }
    # diffs: 0.1, 0.1, sqrt(2) = 1.414
    r = a.is_close(b, 0.2)
    assert_equal([true, true, false], r.to_a)
  end

  def test_is_equiv_cmplx128
    a = CArray.cmplx128(2) { |i| [Complex(100, 0), Complex(0, 1000)][i] }
    b = CArray.cmplx128(2) { |i| [Complex(101, 0), Complex(0, 1010)][i] }
    # rtol = 0.02
    # i=0: |a-b|=1, max=101, 1/101=0.0099 <= 0.02 -> true
    # i=1: |a-b|=10, max=1010, 10/1010=0.0099 <= 0.02 -> true
    assert_equal([true, true], a.is_equiv(b, 0.02).to_a)
  end

  # ---- 3.0 release narrative: deep chain memory peak ----

  def test_chain_memory_peak_streaming
    # The whole point of moving to bincmp: this chain materialises through
    # Phase 3 arena + Phase 4.5 streaming reduce, not a 3-pass eager
    # intermediate.  Correctness pin (= bench is separate).
    n = 1000
    a = CArray.float64(n) { |i| i * 0.001 }
    b = CArray.float64(n) { |i| i * 0.001 + 0.0001 }
    # all elements within tol=0.001
    count = (a.lazy - b).abs.is_close(0.0, 0.001).count(true)
    assert_equal(n, count)
  end
end
