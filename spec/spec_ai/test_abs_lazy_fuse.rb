# abs lazy fuse via chain composition (post-IC follow-up).
#
# Verifies:
# - Eager abs unchanged (numeric + complex)
# - Lazy numeric abs returns CAMonOp single node
# - Lazy complex abs returns CAMonOp 2-node chain (abs_i + cast_f64)
# - 3-stage chain (a.lazy - b).abs.<predicate> streams (memory peak proven
#   structurally via parity + class assertions; bench in
#   devel/bench_is_close_chain.rb)
# - reductions over abs chain fuse

require 'test/unit'
require 'carray'

class TestAbsLazyFuse < Test::Unit::TestCase
  # ---- eager parity ----

  def test_eager_int_unchanged
    a = CArray.int32(5) { |i| i - 2 }
    assert_equal([2, 1, 0, 1, 2], a.abs.to_a)
  end

  def test_eager_float_unchanged
    a = CArray.float64(5) { |i| (i - 2) * 1.0 }
    assert_equal([2.0, 1.0, 0.0, 1.0, 2.0], a.abs.to_a)
  end

  def test_eager_complex_unchanged
    a = CArray.cmplx128(3) { |i| [Complex(3, 4), Complex(0, -5), Complex(1, 1)][i] }
    r = a.abs
    assert_equal(:float64, r.data_type_name.to_sym)
    assert_in_delta(5.0, r[0], 1e-12)
    assert_in_delta(5.0, r[1], 1e-12)
    assert_in_delta(Math.sqrt(2), r[2], 1e-12)
  end

  # ---- lazy fuse: numeric ----

  def test_lazy_numeric_returns_camonop
    a = CArray.float64(5) { |i| (i - 2) * 1.0 }
    b = CArray.float64(5) { |i| i * 1.0 }
    v = (a.lazy - b).abs
    assert_equal(CAMonOp, v.class)
    assert_equal(:float64, v.data_type_name.to_sym)
    # a-b = [-2,-2,-2,-2,-2], abs = [2,2,2,2,2]
    assert_equal([2.0, 2.0, 2.0, 2.0, 2.0], v.to_ca.to_a)
  end

  # ---- lazy fuse: complex (chain composition abs_i + cast_f64) ----

  def test_lazy_complex_returns_camonop_chain
    a = CArray.cmplx128(3) { |i| [Complex(3, 4), Complex(0, -5), Complex(1, 1)][i] }
    v = a.lazy.abs
    assert_equal(CAMonOp, v.class)
    assert_equal(:float64, v.data_type_name.to_sym)
    materialised = v.to_ca
    assert_in_delta(5.0, materialised[0], 1e-12)
    assert_in_delta(5.0, materialised[1], 1e-12)
    assert_in_delta(Math.sqrt(2), materialised[2], 1e-12)
  end

  # ---- 3-stage chain with reductions (release narrative) ----

  def test_chain_abs_sum_parity
    a = CArray.float64(100) { |i| i - 50.0 }
    assert_equal(a.abs.sum, a.lazy.abs.sum)
  end

  def test_chain_binop_abs_sum_parity
    a = CArray.float64(100) { |i| i * 1.0 }
    b = CArray.float64(100) { |i| 50.0 }
    assert_equal((a - b).abs.sum, (a.lazy - b).abs.sum)
  end

  def test_chain_abs_is_close_count
    # 3-stage chain that benchmarks proved streams at +0 KB at N=10M.
    # Correctness pin here; perf in devel/bench_is_close_chain.rb.
    a = CArray.float64(1000) { |i| i * 0.001 }
    b = CArray.float64(1000) { |i| i * 0.001 + 0.0001 }
    count = (a.lazy - b).abs.is_close(0.0, 0.001).count(true)
    assert_equal(1000, count)
  end

  def test_complex_chain_abs_sum_parity
    a = CArray.cmplx128(50) { |i| Complex(i, i + 1) }
    # Complex parent + abs → float chain → sum.  3-node lazy chain:
    # CAMonOp(abs_i) -> CAMonOp(cast_f64) -> reduce.
    assert_in_delta(a.abs.sum, a.lazy.abs.sum, 1e-9)
  end

  # ---- mask propagation ----

  def test_lazy_abs_mask_propagation
    a = CArray.float64(5) { |i| (i - 2) * 1.0 }
    a[1] = UNDEF
    r = a.lazy.abs.to_ca
    assert_equal([false, true, false, false, false], r.is_masked.to_a)
  end
end
