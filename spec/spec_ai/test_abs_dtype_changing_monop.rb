# abs migration via monop Hash output form (= data_type-changing monop).
#
# Framework piece landed: MkKernel.monop now accepts `output:` Hash form
# {numeric: :preserve, complex: :f64} for per-source-family output data_type
# dispatch.  Symmetric to the reduce/scan Hash output form landed earlier.
#
# Migration:
#   - rb_ca_abs / rb_ca_abs_bang / rb_cmath_abs hand-written in
#     ext/carray_math.c -> retired
#   - New mkkernel-generated monop `abs` with proper data_type-changing output
#   - abs!: legal only when in/out data_type match (= numeric source);
#     complex source raises (= data_type change in-place is ill-defined)
#   - lazy chain via lib/carray/lazy.rb override continues to work
#     (already a 2-node CAMonOp chain for complex parent: abs_i + cast_f64)

require 'test/unit'
require 'carray'

class TestAbsDtypeChangingMonop < Test::Unit::TestCase
  # ---- numeric abs preserves data_type ----

  def test_int32_abs_preserves_data_type
    a = CArray.int32(5)
    [-2, -1, 0, 1, 2].each_with_index { |v,i| a[i] = v }
    r = a.abs
    assert_equal(:int32, r.data_type_name.to_sym)
    assert_equal([2, 1, 0, 1, 2], r.to_a)
  end

  def test_int8_abs_preserves
    a = CArray.int8(3)
    [-5, 0, 5].each_with_index { |v,i| a[i] = v }
    r = a.abs
    assert_equal(:int8, r.data_type_name.to_sym)
    assert_equal([5, 0, 5], r.to_a)
  end

  def test_float32_abs_preserves
    a = CArray.float32(3)
    [-1.5, 0.0, 2.5].each_with_index { |v,i| a[i] = v }
    r = a.abs
    assert_equal(:float32, r.data_type_name.to_sym)
    [1.5, 0.0, 2.5].each_with_index { |exp,i| assert_in_delta(exp, r[i], 1e-6) }
  end

  def test_float64_abs_preserves
    a = CArray.float64(3)
    [-3.0, 0.0, 4.0].each_with_index { |v,i| a[i] = v }
    r = a.abs
    assert_equal(:float64, r.data_type_name.to_sym)
    assert_equal([3.0, 0.0, 4.0], r.to_a)
  end

  # ---- complex abs -> f64 (= data_type-changing) ----

  def test_cmplx128_abs_returns_f64
    a = CArray.cmplx128(3)
    [Complex(3, 4), Complex(0, -5), Complex(1, 1)].each_with_index { |v,i| a[i] = v }
    r = a.abs
    # framework piece: cmplx128 -> f64 (= real magnitude)
    assert_equal(:float64, r.data_type_name.to_sym)
    assert_in_delta(5.0, r[0], 1e-9)
    assert_in_delta(5.0, r[1], 1e-9)
    assert_in_delta(Math.sqrt(2), r[2], 1e-9)
  end

  def test_cmplx64_abs_returns_f64
    a = CArray.cmplx64(2)
    [Complex(3, 4), Complex(0, -1)].each_with_index { |v,i| a[i] = v }
    r = a.abs
    assert_equal(:float64, r.data_type_name.to_sym)
    assert_in_delta(5.0, r[0], 1e-6)
    assert_in_delta(1.0, r[1], 1e-6)
  end

  # ---- abs! ----

  def test_int_abs_bang_in_place
    a = CArray.int32(3)
    [-1, 0, 1].each_with_index { |v,i| a[i] = v }
    a.abs!
    assert_equal([1, 0, 1], a.to_a)
    assert_equal(:int32, a.data_type_name.to_sym)
  end

  def test_float_abs_bang_in_place
    a = CArray.float64(3)
    [-1.5, 0.0, 2.5].each_with_index { |v,i| a[i] = v }
    a.abs!
    assert_equal([1.5, 0.0, 2.5], a.to_a)
  end

  def test_cmplx_abs_bang_raises
    a = CArray.cmplx128(2)
    a[0] = Complex(3, 4); a[1] = Complex(0, 5)
    # 3.0 capability: data_type change in-place is ill-defined; complex abs!
    # raises with explicit migration message.  Migration: use non-bang
    # form `a = a.abs` to get a fresh f64 array.
    assert_raise(RuntimeError) { a.abs! }
  end

  # ---- CAMath.abs module function ----

  def test_cmath_abs_module_function_numeric
    a = CArray.int32(3)
    [-1, 0, 1].each_with_index { |v,i| a[i] = v }
    r = CAMath.abs(a)
    assert_equal([1, 0, 1], r.to_a)
    assert_equal(:int32, r.data_type_name.to_sym)
  end

  def test_cmath_abs_module_function_complex
    a = CArray.cmplx128(2)
    [Complex(3, 4), Complex(0, 1)].each_with_index { |v,i| a[i] = v }
    r = CAMath.abs(a)
    assert_equal(:float64, r.data_type_name.to_sym)
    assert_in_delta(5.0, r[0], 1e-9)
    assert_in_delta(1.0, r[1], 1e-9)
  end

  # ---- lazy chain (= lib/carray/lazy.rb override) ----

  def test_lazy_numeric_abs_returns_camonop
    a = CArray.float64(5)
    [-2.0, -1.0, 0.0, 1.0, 2.0].each_with_index { |v,i| a[i] = v }
    v = a.lazy.abs
    assert_equal(CAMonOp, v.class)
    assert_equal(:float64, v.data_type_name.to_sym)
    assert_equal([2.0, 1.0, 0.0, 1.0, 2.0], v.to_ca.to_a)
  end

  def test_lazy_complex_abs_returns_camonop_chain
    a = CArray.cmplx128(3)
    [Complex(3, 4), Complex(0, -5), Complex(1, 1)].each_with_index { |v,i| a[i] = v }
    v = a.lazy.abs
    assert_equal(CAMonOp, v.class)
    assert_equal(:float64, v.data_type_name.to_sym)
    assert_in_delta(5.0, v.to_ca[0], 1e-9)
  end

  def test_lazy_chain_abs_sum_streams
    n = 100
    a = CArray.float64(n).seq + 1.0
    b = CArray.float64(n).seq
    expected = (a - b).abs.sum
    actual = (a.lazy - b).abs.sum
    assert_in_delta(expected, actual, 1e-9)
  end

  # ---- carray_math.c retire verification ----
  # rb_ca_abs / rb_ca_abs_bang / rb_cmath_abs no longer hand-written.
  # The methods are bound by Init_carray_kernels (after Init_carray_math),
  # so abs source_location is empty (= C method) -- but for lazy.rb's
  # override the source_location points to lazy.rb.  Both are expected.

  def test_abs_method_defined
    assert(CArray.instance_method(:abs))
    assert(CArray.instance_method(:abs!))
    assert(CAMath.respond_to?(:abs))
  end

  # ---- mask propagation ----

  def test_cmplx_abs_mask_propagation
    a = CArray.cmplx128(4)
    [Complex(1, 0), Complex(2, 0), Complex(3, 0), Complex(4, 0)].each_with_index { |v,i| a[i] = v }
    a[1] = UNDEF
    r = a.abs
    assert_equal([false, true, false, false], r.is_masked.to_a)
    # unmasked cells: |1|=1, |3|=3, |4|=4
    assert_in_delta(1.0, r[0], 1e-9)
    assert_in_delta(3.0, r[2], 1e-9)
    assert_in_delta(4.0, r[3], 1e-9)
  end
end
