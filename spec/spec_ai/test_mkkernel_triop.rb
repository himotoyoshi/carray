# frozen_string_literal: true
#
# `MkKernel.triop` DSL framework + initial consumers.
#
# Framework: 3-input / 1-output element-wise kernel form, eager-only
# (no lazy substrate yet, parallels how `sign` / `arg` are eager-only).
# Inherits per-axis dispatch / view universality / mask SIMD path
# from the kernel signature (= same stride-element form as binop).
#
# First consumers:
#   fma(b, c)   = self * b + c   (HW FMA, single rounding)
#   fms(b, c)   = self * b - c
#   clip(lo, hi) per-element clamp (= migrated from hand-written eager)

require "test/unit"
require "carray"

class TestMkKernelTriop < Test::Unit::TestCase
  # =================================================================
  # fma  -- fused multiply-add
  # =================================================================

  def test_fma_float64
    a = CA_FLOAT64([1.0, 2.0, 3.0])
    b = CA_FLOAT64([10.0, 20.0, 30.0])
    c = CA_FLOAT64([100.0, 200.0, 300.0])
    assert_equal [110.0, 240.0, 390.0], a.fma(b, c).to_a
  end

  def test_fma_scalar_operands
    a = CA_FLOAT64([1.0, 2.0, 3.0])
    assert_equal [7.0, 9.0, 11.0], a.fma(2.0, 5.0).to_a
  end

  def test_fma_int
    a = CA_INT32([1, 2, 3])
    assert_equal [7, 9, 11], a.fma(2, 5).to_a
  end

  def test_fma_complex
    a = CA_CMPLX128([Complex(1, 0), Complex(0, 1)])
    b = CA_CMPLX128([Complex(2, 0), Complex(0, 1)])
    c = CA_CMPLX128([Complex(10, 0), Complex(5, 0)])
    r = a.fma(b, c)
    assert_equal CA_CMPLX128, r.data_type
    assert_equal Complex(12, 0), r[0]   # 1*2 + 10
    assert_equal Complex(4, 0),  r[1]   # i*i + 5 = -1 + 5 = 4
  end

  def test_fma_precision_matches_eager_binop_within_tolerance
    # fma is single-rounded; a*b + c is double-rounded.  For most
    # inputs the difference is within 1 ulp.  We don't try to assert
    # exact bit-equality — just that the chain produces the same
    # mathematical result to within ulp tolerance.
    a = CA_FLOAT64([1.1, 2.2, 3.3, -4.4])
    b = CA_FLOAT64([5.5, 6.6, 7.7,  8.8])
    c = CA_FLOAT64([0.1, 0.2, 0.3,  0.4])
    fma_r = a.fma(b, c)
    chain = (a * b) + c
    fma_r.elements.times do |i|
      assert_in_delta chain[i], fma_r[i], 1e-12
    end
  end

  def test_fma_mask_propagated
    a = CA_FLOAT64([1.0, 2.0, 3.0])
    a.mask = CA_BOOLEAN([0, 1, 0])
    r = a.fma(2.0, 0.0)
    assert_equal [false, true, false], r.mask.to_a
    assert_equal 2.0, r[0]
    assert_equal 6.0, r[2]
  end

  def test_fma_bang_in_place
    a = CA_FLOAT64([1.0, 2.0, 3.0])
    ret = a.fma!(10.0, 1.0)
    assert_same a, ret
    assert_equal [11.0, 21.0, 31.0], a.to_a
  end

  def test_fma_2d_shape_preserved
    a = CArray.float64(2, 3) { |i, j| i * 3 + j + 1.0 }
    r = a.fma(2.0, 0.5)
    assert_equal [2, 3], r.dim
    a.elements.times do |k|
      i, j = k.divmod(3)
      assert_in_delta a[i, j] * 2.0 + 0.5, r[i, j], 1e-12
    end
  end

  def test_fma_through_transpose
    a = CArray.float64(2, 3).seq
    r = a.transpose.fma(2.0, 1.0)
    assert_equal [3, 2], r.dim
  end

  # =================================================================
  # fms  -- fused multiply-subtract
  # =================================================================

  def test_fms_float
    a = CA_FLOAT64([1.0, 2.0, 3.0])
    b = CA_FLOAT64([10.0, 20.0, 30.0])
    c = CA_FLOAT64([5.0, 10.0, 15.0])
    assert_equal [5.0, 30.0, 75.0], a.fms(b, c).to_a
  end

  def test_fms_int
    a = CA_INT32([1, 2, 3])
    assert_equal [5, 30, 75], a.fms(CA_INT32([10, 20, 30]), CA_INT32([5, 10, 15])).to_a
  end

  def test_fms_bang
    a = CA_FLOAT64([1.0, 2.0, 3.0])
    a.fms!(10.0, 1.0)
    assert_equal [9.0, 19.0, 29.0], a.to_a
  end

  # =================================================================
  # clip  -- per-element clamp (migration from hand-written)
  # =================================================================

  def test_clip_scalar_bounds_float
    v = CA_FLOAT64([-2.0, 0.5, 1.0, 1.5, 3.0])
    assert_equal [0.0, 0.5, 1.0, 1.0, 1.0], v.clip(0.0, 1.0).to_a
  end

  def test_clip_scalar_bounds_int
    a = CA_INT32([-5, 0, 3, 10, 100])
    assert_equal [0, 0, 3, 10, 10], a.clip(0, 10).to_a
  end

  def test_clip_array_bounds_new_capability
    # 3.0 NEW: clip with CArray bounds (= per-element variable lo / hi).
    # Old hand-written clip rejected this.
    v = CA_FLOAT64([-2.0, 0.5, 1.0, 1.5, 3.0])
    lo = CA_FLOAT64([0.0, 0.0, 0.5, 1.0, 0.0])
    hi = CA_FLOAT64([1.0, 0.4, 1.0, 1.0, 2.0])
    assert_equal [0.0, 0.4, 1.0, 1.0, 2.0], v.clip(lo, hi).to_a
  end

  def test_clip_nan_preserved
    nan = 0.0 / 0.0
    v = CA_FLOAT64([nan, 0.5, nan])
    r = v.clip(0.0, 1.0)
    assert r[0].nan?
    assert_equal 0.5, r[1]
    assert r[2].nan?
  end

  def test_clip_mask_propagated
    a = CA_FLOAT64([0.5, -1.0, 2.0, 3.0])
    a.mask = CA_BOOLEAN([0, 1, 0, 0])
    r = a.clip(0.0, 1.5)
    assert_equal [false, true, false, false], r.mask.to_a
    assert_equal 0.5, r[0]
    assert_equal 1.5, r[2]
    assert_equal 1.5, r[3]
  end

  def test_clip_bang_retired
    # `clip!` is retired in 3.0 (view-by-default convention).  In-place
    # idiom: `a[] = a.clip(lo, hi)`.
    a = CA_FLOAT64([-2.0, 0.5, 3.0])
    refute a.respond_to?(:clip!)
    a[] = a.clip(0.0, 1.0)
    assert_equal [0.0, 0.5, 1.0], a.to_a
  end

  def test_clip_strict_interval_semantics
    # The new clip uses `< lo` and `> hi` (= strict interval).  Values
    # equal to a bound stay unchanged.  Old hand-written clip used
    # `>= max` (= inclusive upper bound).  This is a quiet 3.0 breaking.
    a = CA_INT32([5, 10, 15])
    r = a.clip(5, 15)
    assert_equal [5, 10, 15], r.to_a  # both ends preserved
  end

  def test_clip_through_block_view
    a = CA_FLOAT64([-1.0, 0.5, 0.7, 1.5, 2.0])
    blk = a[1..3]
    assert_equal [0.5, 0.7, 1.0], blk.clip(0.0, 1.0).to_a
  end

  def test_clip_2d
    a = CArray.float64(2, 3) { |i, j| (i * 3 + j) - 2.5 }
    r = a.clip(0.0, 1.5)
    assert_equal [2, 3], r.dim
    r.elements.times do |k|
      i, j = k.divmod(3)
      v = a[i, j]
      expected = v < 0.0 ? 0.0 : (v > 1.5 ? 1.5 : v)
      assert_in_delta expected, r[i, j], 1e-12
    end
  end

  # =================================================================
  # Framework: arity / method registration
  # =================================================================

  def test_triop_method_arity
    # mkkernel triop registers method with arity 2 (= operand 2 + 3,
    # self is implicit receiver).  `clip` is wrapped in Ruby (defaults
    # for max / fill_value), so its arity is -1 — covered by the
    # dedicated clip tests.
    assert_equal 2, CArray.instance_method(:fma).arity
    assert_equal 2, CArray.instance_method(:fms).arity
  end

  def test_triop_bang_present
    assert CArray.method_defined?(:fma!)
    assert CArray.method_defined?(:fms!)
    # clip! is intentionally retired in 3.0 by the Ruby wrapper in
    # lib/carray/math.rb (view-by-default convention).
    refute CArray.method_defined?(:clip!)
  end

  def test_triop_element_mismatch_raises
    a = CA_FLOAT64([1.0, 2.0, 3.0])
    b = CA_FLOAT64([1.0, 2.0])  # wrong length
    c = CA_FLOAT64([1.0, 2.0, 3.0])
    assert_raise(ArgumentError) { a.fma(b, c) }
  end
end
