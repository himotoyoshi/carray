# ---------------------------------------------------------------------------
# spec_ai/test_mkkernel_monop_p5b2.rb
#
# Phase 5b P.5b.2 — bulk migration of monop/monfunc family ops from
# ext/carray_math.rb to ext/mkkernel.rb (MkKernel.monop / .monfunc /
# .alias_monop).  Pins byte parity for representative ops across data_types,
# auto-widening behavior (integer input -> f64 for float-only kernels),
# alias_op surface (-@, ~), and hand-written abs wrapper still functional
# across the kernels.c / math.c translation unit boundary.
# ---------------------------------------------------------------------------

$LOAD_PATH.unshift File.expand_path('../../../ext', __FILE__)
$LOAD_PATH.unshift File.expand_path('../../../lib', __FILE__)

require 'test/unit'
require 'carray'

class TestMkKernelMonopP5b2 < Test::Unit::TestCase
  # --- migrated monop family (preserve data_type, no auto-cast) ---------------

  def test_one
    a = CArray.float64(3).seq(1.0)
    assert_equal [1.0]*3, a.one.to_a
  end

  def test_neg
    a = CArray.int32(3).seq(1)
    assert_equal [-1, -2, -3], a.neg.to_a
  end

  def test_unary_minus_operator
    a = CArray.int32(3).seq(1)
    assert_equal [-1, -2, -3], (-a).to_a
  end

  def test_bit_neg
    a = CArray.int32(3).seq(1)
    assert_equal [-2, -3, -4], a.bit_neg.to_a
  end

  def test_bit_neg_via_tilde_operator
    a = CArray.int32(3).seq(1)
    assert_equal [-2, -3, -4], (~a).to_a
  end

  def test_conj
    a = CArray.cmplx128(2)
    a[] = [Complex(3, 4), Complex(1, -2)]
    assert_equal [Complex(3, -4), Complex(1, 2)], a.conj.to_a
  end

  def test_not
    a = CArray.boolean(3); a[] = [true, false, true]
    assert_equal [false, true, false], a.not.to_a
  end

  def test_frac
    a = CArray.float64(3); a[] = [1.25, -1.5, 2.75]
    result = a.frac.to_a
    assert_in_delta 0.25, result[0], 1e-12
    assert_in_delta -0.5, result[1], 1e-12
    assert_in_delta 0.75, result[2], 1e-12
  end

  # round and frac branch on sign; the zero branch must pass the value
  # through (not emit 0.0) so a NaN input yields NaN, not 0.0.
  def test_round_frac_nan_and_signed_zero
    nan = 0.0 / 0.0
    a = CArray.float64(3); a[] = [nan, 0.0, -0.0]
    round = a.round.to_a
    frac  = a.frac.to_a
    assert round[0].nan?, "round(NaN) should be NaN, got #{round[0]}"
    assert frac[0].nan?,  "frac(NaN) should be NaN, got #{frac[0]}"
    assert_equal 0.0, round[1]
    assert_equal 0.0, frac[1]
    # -0.0 is preserved (sign bit stays negative).
    assert_equal (1.0 / round[2]), -Float::INFINITY, "round(-0.0) should stay -0.0"
    assert_equal (1.0 / frac[2]),  -Float::INFINITY, "frac(-0.0) should stay -0.0"
  end

  # --- abs (hand-written wrapper around abs_i across translation units) ---

  def test_abs_integer
    a = CArray.int32(3); a[] = [-3, 0, 5]
    assert_equal [3, 0, 5], a.abs.to_a
  end

  def test_abs_float
    a = CArray.float64(3); a[] = [-3.5, 0.0, 2.5]
    assert_equal [3.5, 0.0, 2.5], a.abs.to_a
  end

  def test_abs_bang
    a = CArray.int32(3); a[] = [-3, 0, 5]
    a.abs!
    assert_equal [3, 0, 5], a.to_a
  end

  # --- monfunc family (float-only kernels + auto-widening integer input) -

  def test_sqrt_float
    a = CArray.float64(3); a[] = [1.0, 4.0, 9.0]
    assert_equal [1.0, 2.0, 3.0], a.sqrt.to_a
  end

  def test_sqrt_integer_auto_widens_to_float64
    a = CArray.int32(3); a[] = [1, 4, 9]
    result = a.sqrt
    assert_equal CA_FLOAT64, result.data_type, "auto-cast int -> f64"
    assert_equal [1.0, 2.0, 3.0], result.to_a
  end

  def test_exp_float
    a = CArray.float64(2); a[] = [0.0, 1.0]
    result = a.exp.to_a
    assert_in_delta 1.0, result[0], 1e-12
    assert_in_delta Math::E, result[1], 1e-12
  end

  def test_exp2
    a = CArray.float64(3); a[] = [1.0, 2.0, 3.0]
    assert_equal [2.0, 4.0, 8.0], a.exp2.to_a
  end

  def test_exp10
    a = CArray.float64(3); a[] = [1.0, 2.0, 3.0]
    assert_equal [10.0, 100.0, 1000.0], a.exp10.to_a
  end

  def test_log_log10_log2
    a = CArray.float64(1); a[] = [Math::E]
    assert_in_delta 1.0, a.log[0], 1e-12
    a[] = [10.0]
    assert_in_delta 1.0, a.log10[0], 1e-12
    a[] = [8.0]
    assert_in_delta 3.0, a.log2[0], 1e-12
  end

  def test_sin_cos_tan
    a = CArray.float64(1); a[] = [0.0]
    assert_in_delta 0.0, a.sin[0], 1e-12
    assert_in_delta 1.0, a.cos[0], 1e-12
    assert_in_delta 0.0, a.tan[0], 1e-12
  end

  def test_hyperbolic
    a = CArray.float64(1); a[] = [0.0]
    assert_in_delta 0.0, a.sinh[0], 1e-12
    assert_in_delta 1.0, a.cosh[0], 1e-12
    assert_in_delta 0.0, a.tanh[0], 1e-12
  end

  # Regression: the complex branch of the hyperbolic family used to emit the
  # real-typed C function (sinh/cosh/... instead of csinh/ccosh/...), so the
  # imaginary part was silently discarded and only Re(z) was computed.
  # Expected values are C99 complex.h for z = 1+2i.
  COMPLEX_HYPERBOLIC_AT_1_PLUS_2I = {
    sinh:  Complex(-0.489056259041294,  1.40311925062204),
    cosh:  Complex(-0.64214812471552,   1.06860742138278),
    tanh:  Complex( 1.16673625724092,  -0.243458201185725),
    asinh: Complex( 1.46935174436819,   1.06344002357775),
    acosh: Complex( 1.528570919481,     1.14371774040242),
    atanh: Complex( 0.173286795139986,  1.17809724509617),
  }

  def test_complex_hyperbolic_cmplx128
    a = CArray.cmplx128(1); a[] = [Complex(1.0, 2.0)]
    COMPLEX_HYPERBOLIC_AT_1_PLUS_2I.each do |op, want|
      got = a.send(op)[0]
      assert_in_delta want.real, got.real, 1e-12, "Re(#{op})"
      assert_in_delta want.imag, got.imag, 1e-12, "Im(#{op})"
    end
  end

  def test_complex_hyperbolic_cmplx64
    a = CArray.cmplx64(1); a[] = [Complex(1.0, 2.0)]
    COMPLEX_HYPERBOLIC_AT_1_PLUS_2I.each do |op, want|
      got = a.send(op)[0]
      assert_in_delta want.real, got.real, 1e-6, "Re(#{op})"
      assert_in_delta want.imag, got.imag, 1e-6, "Im(#{op})"
    end
  end

  def test_inverse_trig
    a = CArray.float64(1); a[] = [1.0]
    assert_in_delta Math::PI/2, a.asin[0], 1e-12
    assert_in_delta 0.0, a.acos[0], 1e-12
    assert_in_delta Math::PI/4, a.atan[0], 1e-12
  end

  def test_ceil_floor_round
    a = CArray.float64(3); a[] = [1.4, -1.5, 2.5]
    assert_equal [2.0, -1.0, 3.0], a.ceil.to_a
    assert_equal [1.0, -2.0, 2.0], a.floor.to_a
    assert_equal [1.0, -2.0, 3.0], a.round.to_a
  end

  def test_rad_deg
    a = CArray.float64(1); a[] = [180.0]
    assert_in_delta Math::PI, a.rad[0], 1e-12
    a[] = [Math::PI]
    assert_in_delta 180.0, a.deg[0], 1e-12
  end

  def test_rcp_preserves_integer
    # rcp has int kernel (= ca_zerodiv on 0), so no auto-cast
    a = CArray.int32(3); a[] = [2, 4, 8]
    result = a.rcp
    assert_equal CA_INT32, result.data_type
    assert_equal [0, 0, 0], result.to_a   # integer 1/2 = 0
  end

  def test_rcp_zerodiv_on_integer_zero
    a = CArray.int32(2); a[] = [0, 1]
    assert_raise(ZeroDivisionError) { a.rcp }
  end

  # --- CAMath module functions --------------------------------------------

  def test_camath_sqrt_float
    assert_in_delta 4.0, CAMath.sqrt(16.0), 1e-12
  end

  def test_camath_exp_float
    assert_in_delta 1.0, CAMath.exp(0.0), 1e-12
  end

  # --- lazy path: every migrated monop also routes through CAMonOp -------

  def test_lazy_sqrt
    a = CArray.float64(3); a[] = [1.0, 4.0, 9.0]
    lazy = a.lazy.sqrt
    assert_kind_of CAMonOp, lazy
    assert_equal [1.0, 2.0, 3.0], lazy.to_ca.to_a
  end

  def test_lazy_chain
    a = CArray.float64(3); a[] = [1.0, 4.0, 9.0]
    lazy = a.lazy.sqrt.exp
    assert_kind_of CAMonOp, lazy
    result = lazy.to_ca.to_a
    assert_in_delta Math::E, result[0], 1e-9
    assert_in_delta Math.exp(2.0), result[1], 1e-9
    assert_in_delta Math.exp(3.0), result[2], 1e-9
  end

  def test_lazy_neg
    a = CArray.int32(3).seq(1)
    lazy = a.lazy.neg
    assert_kind_of CAMonOp, lazy
    assert_equal [-1, -2, -3], lazy.to_ca.to_a
  end

  # --- generated-file audit -----------------------------------------------

  def test_migrated_symbols_in_kernels_c
    kernels_c = Dir[File.expand_path('../../../ext/carray_kernels_*.c', __FILE__)].map { |__f| File.read(__f, encoding: 'UTF-8') }.join("\n")
    %w[zero one neg bit_neg abs_i conj not frac
       sqrt exp exp2 exp10 log log10 log2 logb
       sin cos tan asin acos atan
       sinh cosh tanh asinh acosh atanh
       ceil floor round rcp rad deg].each do |op|
      assert_match(/ca_monop_#{op}\[CA_NTYPE\]/, kernels_c,
                   "kernel table ca_monop_#{op} missing")
      assert_match(/VALUE rb_ca_#{op} \(VALUE self\)/, kernels_c,
                   "eager wrapper rb_ca_#{op} missing")
    end
  end

  def test_alias_op_registrations
    kernels_c = Dir[File.expand_path('../../../ext/carray_kernels_*.c', __FILE__)].map { |__f| File.read(__f, encoding: 'UTF-8') }.join("\n")
    # alias_monop emits rb_define_alias (= true Ruby alias) since P.5b.3
    assert_match(/rb_define_alias\(rb_cCArray, "-@", "neg"\)/, kernels_c)
    assert_match(/rb_define_alias\(rb_cCArray, "~", "bit_neg"\)/, kernels_c)
  end
end
