# ---------------------------------------------------------------------------
# spec_ai/test_mkkernel_binop_p5b3.rb
#
# Phase 5b P.5b.3 — bulk migration of binop family ops from
# ext/carray_math.rb to ext/mkkernel.rb (MkKernel.binop /
# .alias_binop).  Pins byte parity for arithmetic / bitwise / shift
# / boolean kernels, alias_op surface (add / sub / ... / bit_lshift),
# hand-written wrappers (rb_ca_and / _or / _xor / _pow) still functional
# across the kernels.c / math.c boundary, lazy chain through CABinOp,
# and scalar broadcast semantics.
# ---------------------------------------------------------------------------

$LOAD_PATH.unshift File.expand_path('../../../ext', __FILE__)
$LOAD_PATH.unshift File.expand_path('../../../lib', __FILE__)

require 'test/unit'
require 'carray'

class TestMkKernelBinopP5b3 < Test::Unit::TestCase
  def setup
    @a = CArray.int32(3).seq(1)  # [1, 2, 3]
    @b = CArray.int32(3).seq(2)  # [2, 3, 4]
  end

  # --- arithmetic --------------------------------------------------------

  def test_plus
    assert_equal [3, 5, 7], (@a + @b).to_a
  end

  def test_minus
    assert_equal [-1, -1, -1], (@a - @b).to_a
  end

  def test_mul
    assert_equal [2, 6, 12], (@a * @b).to_a
  end

  def test_div_integer_truncates
    assert_equal [0, 0, 0], (@a / @b).to_a
  end

  def test_div_float
    a = CArray.float64(2); a[] = [10.0, 20.0]
    b = CArray.float64(2); b[] = [4.0, 5.0]
    assert_equal [2.5, 4.0], (a / b).to_a
  end

  def test_div_zerodiv_integer
    z = CArray.int32(3)
    assert_raise(ZeroDivisionError) { @a / z }
  end

  def test_mod
    assert_equal [1, 2, 3], (@a % @b).to_a
  end

  def test_mod_zerodiv_integer
    z = CArray.int32(3)
    assert_raise(ZeroDivisionError) { @a % z }
  end

  def test_reminder_float
    a = CArray.float64(2); a[] = [10.0, 7.0]
    b = CArray.float64(2); b[] = [3.0, 2.0]
    result = a.reminder(b).to_a
    # remainder(10, 3) = 1, remainder(7, 2) = -1 (IEEE 754 semantics)
    assert_in_delta 1.0, result[0], 1e-12
    assert_in_delta -1.0, result[1], 1e-12
  end

  def test_rcp_mul
    # rcp_mul(a, b) = b / a (= "reciprocal multiply" = swap then divide)
    a = CArray.int32(3); a[] = [1, 2, 4]
    b = CArray.int32(3); b[] = [10, 10, 8]
    assert_equal [10, 5, 2], a.rcp_mul(b).to_a
  end

  # --- bitwise -----------------------------------------------------------

  def test_bit_and
    assert_equal [0, 2, 0], (@a & @b).to_a
  end

  def test_bit_or
    assert_equal [3, 3, 7], (@a | @b).to_a
  end

  def test_bit_xor
    assert_equal [3, 1, 7], (@a ^ @b).to_a
  end

  def test_bit_lshift
    assert_equal [4, 16, 48], (@a << @b).to_a
  end

  def test_bit_rshift
    assert_equal [1, 0, 0], (@b >> @a).to_a
  end

  # --- pmax / pmin -------------------------------------------------------

  def test_pmax
    assert_equal [2, 3, 4], @a.pmax(@b).to_a
  end

  def test_pmin
    assert_equal [1, 2, 3], @a.pmin(@b).to_a
  end

  # --- boolean (hand-written wrapper around _i kernels across TUs) -------

  def test_and
    p = CArray.boolean(3); p[] = [true, false, true]
    q = CArray.boolean(3); q[] = [true, true, false]
    assert_equal [true, false, false], p.and(q).to_a
  end

  def test_or
    p = CArray.boolean(3); p[] = [true, false, true]
    q = CArray.boolean(3); q[] = [true, true, false]
    assert_equal [true, true, true], p.or(q).to_a
  end

  def test_xor
    p = CArray.boolean(3); p[] = [true, false, true]
    q = CArray.boolean(3); q[] = [true, true, false]
    assert_equal [false, true, true], p.xor(q).to_a
  end

  def test_and_bang
    p = CArray.boolean(3); p[] = [true, false, true]
    q = CArray.boolean(3); q[] = [true, true, false]
    p.and!(q)
    assert_equal [true, false, false], p.to_a
  end

  # --- alias_op (= rb_define_alias) --------------------------------------

  def test_add_alias
    assert_equal (@a + @b).to_a, @a.add(@b).to_a
  end

  def test_sub_alias
    assert_equal (@a - @b).to_a, @a.sub(@b).to_a
  end

  def test_bit_and_alias
    assert_equal (@a & @b).to_a, @a.bit_and(@b).to_a
  end

  def test_bit_lshift_alias
    assert_equal (@a << @b).to_a, @a.bit_lshift(@b).to_a
  end

  # --- bang variants -----------------------------------------------------

  def test_add_bang
    c = @a.dup
    c.add!(@b)
    assert_equal [3, 5, 7], c.to_a
  end

  def test_mul_bang
    c = @a.dup
    c.mul!(@b)
    assert_equal [2, 6, 12], c.to_a
  end

  # --- scalar broadcast --------------------------------------------------

  def test_scalar_plus
    assert_equal [6, 7, 8], (@a + 5).to_a
  end

  def test_scalar_mul_promotes_int_to_float
    result = @a * 1.5
    assert_equal CA_FLOAT64, result.data_type
    assert_equal [1.5, 3.0, 4.5], result.to_a
  end

  # --- pass_to_other (= Ruby coerce double-dispatch) ---------------------

  def test_noncastable_rhs_raises
    # Range doesn't define coerce-compatible interface for CArray
    assert_raise(TypeError) { @a + Range.new(1, 3) }
  end

  # --- lazy path ---------------------------------------------------------

  def test_lazy_plus_returns_cabinop
    lazy = @a.lazy + @b
    assert_kind_of CABinOp, lazy
    assert_equal [3, 5, 7], lazy.to_ca.to_a
  end

  def test_lazy_chain_arithmetic
    lazy = (@a.lazy + @b) * 2
    assert_equal [6, 10, 14], lazy.to_ca.to_a
  end

  # --- pow (hand-written, Float**Integer -> ipower fast path) ------------

  def test_pow_float_int
    f = CArray.float64(3); f[] = [1.0, 2.0, 3.0]
    assert_equal [1.0, 4.0, 9.0], f.pow(2).to_a
  end

  def test_pow_via_operator
    f = CArray.float64(3); f[] = [1.0, 2.0, 3.0]
    assert_equal [1.0, 8.0, 27.0], (f ** 3).to_a
  end

  # --- generated-file audit ----------------------------------------------

  def test_migrated_binop_symbols_in_kernels_c
    kernels_c = Dir[File.expand_path('../../../ext/carray_kernels_*.c', __FILE__)].map { |__f| File.read(__f, encoding: 'UTF-8') }.join("\n")
    %w[pmax pmin add sub mul div quo_i rcp_mul mod reminder
       bit_and_i bit_or_i bit_xor_i bit_lshift bit_rshift
       and or xor].each do |op|
      assert_match(/ca_binop_#{op}\[CA_NTYPE\]/, kernels_c,
                   "kernel table ca_binop_#{op} missing")
      assert_match(/VALUE rb_ca_#{op} \(VALUE self, VALUE other\)/, kernels_c,
                   "eager wrapper rb_ca_#{op} missing")
    end
  end

  def test_binop_aliases_registered_in_init
    kernels_c = Dir[File.expand_path('../../../ext/carray_kernels_*.c', __FILE__)].map { |__f| File.read(__f, encoding: 'UTF-8') }.join("\n")
    assert_match(/rb_define_alias\(rb_cCArray, "add", "\+"\)/, kernels_c)
    assert_match(/rb_define_alias\(rb_cCArray, "sub", "-"\)/, kernels_c)
    assert_match(/rb_define_alias\(rb_cCArray, "mul", "\*"\)/, kernels_c)
    assert_match(/rb_define_alias\(rb_cCArray, "div", "\/"\)/, kernels_c)
    assert_match(/rb_define_alias\(rb_cCArray, "mod", "%"\)/, kernels_c)
    assert_match(/rb_define_alias\(rb_cCArray, "bit_and", "&"\)/, kernels_c)
    assert_match(/rb_define_alias\(rb_cCArray, "bit_lshift", "<<"\)/, kernels_c)
    assert_match(/rb_define_alias\(rb_cCArray, "bit_rshift", ">>"\)/, kernels_c)
  end

  def test_operator_methods_registered_in_init
    kernels_c = Dir[File.expand_path('../../../ext/carray_kernels_*.c', __FILE__)].map { |__f| File.read(__f, encoding: 'UTF-8') }.join("\n")
    assert_match(/rb_define_method\(rb_cCArray, "\+", rb_ca_add/, kernels_c)
    assert_match(/rb_define_method\(rb_cCArray, "-", rb_ca_sub/, kernels_c)
    assert_match(/rb_define_method\(rb_cCArray, "\*", rb_ca_mul/, kernels_c)
    assert_match(/rb_define_method\(rb_cCArray, "&", rb_ca_bit_and_i/, kernels_c)
    assert_match(/rb_define_method\(rb_cCArray, "<<", rb_ca_bit_lshift/, kernels_c)
  end
end
