# ---------------------------------------------------------------------------
# spec_ai/test_mkmath_retire_p5b5.rb
#
# Phase 5b P.5b.5 — ext/mkmath.rb + ext/carray_math.rb retire.
#
# ext/carray_math.c is now hand-written (committed plain C) rather than
# generated from carray_math.rb / mkmath.rb.  The hand-written file
# contains the residual math wrappers that did not migrate to
# ext/mkkernel.rb during Phase 5b B1 because they wrap or dispatch
# between kernels at the Ruby method level (= abs, and, or, xor, ipower,
# pow).  The `power` binop kernel itself migrated to mkkernel via a new
# `MkKernel.header_block` mechanism that includes ext/ca_op_powi.h.
# ---------------------------------------------------------------------------

$LOAD_PATH.unshift File.expand_path('../../../ext', __FILE__)
$LOAD_PATH.unshift File.expand_path('../../../lib', __FILE__)

require 'test/unit'
require 'carray'

class TestMkmathRetireP5b5 < Test::Unit::TestCase
  EXT_DIR = File.expand_path('../../../ext', __FILE__)

  # --- retire: .rb generators removed ----------------------------------

  def test_mkmath_rb_removed
    refute File.exist?(File.join(EXT_DIR, 'mkmath.rb')),
           'ext/mkmath.rb should be removed (P.5b.5)'
  end

  def test_carray_math_rb_removed
    refute File.exist?(File.join(EXT_DIR, 'carray_math.rb')),
           'ext/carray_math.rb should be removed (P.5b.5)'
  end

  def test_carray_math_c_removed
    # 2026-06-10: carray_math.c merged into ca_op_ipower.c.  The umbrella
    # name no longer fit (only ipower-related code remained after P.5b.5
    # retired mkmath.rb / carray_math.rb), so the residual ipower wrappers
    # joined the lazy ipower kernel table in ca_op_ipower.c — they already
    # shared op_powi_<type> from ca_op_powi.h.
    refute File.exist?(File.join(EXT_DIR, 'carray_math.c')),
           'ext/carray_math.c merged into ca_op_ipower.c'
  end

  def test_ca_op_ipower_c_contains_eager_and_lazy
    path = File.join(EXT_DIR, 'ca_op_ipower.c')
    assert File.exist?(path)
    content = File.read(path, encoding: 'UTF-8')
    # lazy kernel table
    assert_match(/ca_binop_ipower\[CA_NTYPE\]/, content,
                 'lazy CABinOp ipower table must be present')
    # eager Ruby surface
    assert_match(/rb_ca_ipower\b/, content)
    assert_match(/rb_ca_ipower_bang\b/, content)
    assert_match(/rb_ca_pow\b/, content)
    assert_match(/Init_ca_op_ipower\b/, content)
    # uses shared header
    assert_match(/#include "ca_op_powi\.h"/, content)
  end

  def test_ca_op_powi_h_exists
    path = File.join(EXT_DIR, 'ca_op_powi.h')
    assert File.exist?(path),
           'ext/ca_op_powi.h should exist (P.5b.5 shared header)'
    content = File.read(path, encoding: 'UTF-8')
    assert_match(/op_powi\(int32_t\)/, content)
    assert_match(/op_powi_fc\(float64_t\)/, content)
    assert_match(/op_powi_fc\(cmplx128_t\)/, content)
  end

  # --- power kernel migration to mkkernel -------------------------------

  def test_power_kernel_in_kernels_c
    kernels_c = Dir[File.join(EXT_DIR, 'carray_kernels_*.c')].map { |__f| File.read(__f, encoding: 'UTF-8') }.join("\n")
    assert_match(/ca_binop_power\[CA_NTYPE\]/, kernels_c,
                 'power kernel table must be emitted into carray_kernels.c')
    assert_match(/VALUE rb_ca_power \(VALUE self, VALUE other\)/, kernels_c)
    assert_match(/op_powi_int32_t/, kernels_c,
                 'power int kernel must reference op_powi_<type>')
  end

  def test_ca_op_powi_h_included_via_header_block
    kernels_c = Dir[File.join(EXT_DIR, 'carray_kernels_*.c')].map { |__f| File.read(__f, encoding: 'UTF-8') }.join("\n")
    assert_match(/#include "ca_op_powi\.h"/, kernels_c,
                 'mkkernel.rb HEADER_BLOCKS must inject the include')
  end

  # --- Ruby-level surface unchanged -------------------------------------

  def test_pow_integer_exponent_via_ipower
    a = CArray.float64(3); a[] = [1.0, 2.0, 3.0]
    assert_equal [1.0, 4.0, 9.0], a.pow(2).to_a
    assert_equal [1.0, 8.0, 27.0], (a ** 3).to_a
  end

  def test_pow_float_exponent_via_power_kernel
    a = CArray.float64(3); a[] = [1.0, 4.0, 9.0]
    result = a.pow(0.5).to_a
    assert_in_delta 1.0, result[0], 1e-12
    assert_in_delta 2.0, result[1], 1e-12
    assert_in_delta 3.0, result[2], 1e-12
  end

  def test_pow_integer_to_integer_via_power_kernel
    i = CArray.int32(3); i[] = [2, 3, 4]
    j = CArray.int32(3); j[] = [3, 2, 2]
    assert_equal [8, 9, 16], i.power(j).to_a
  end

  def test_pow_complex_integer_exponent
    a = CArray.cmplx128(2); a[] = [Complex(1, 1), Complex(2, 0)]
    result = a.pow(2).to_a
    assert_in_delta 0.0, result[0].real, 1e-12
    assert_in_delta 2.0, result[0].imaginary, 1e-12
    assert_in_delta 4.0, result[1].real, 1e-12
  end

  def test_abs_integer
    a = CArray.int32(3); a[] = [-2, 0, 5]
    assert_equal [2, 0, 5], a.abs.to_a
  end

  def test_abs_complex_returns_real_part
    a = CArray.cmplx128(2); a[] = [Complex(3, 4), Complex(5, 12)]
    result = a.abs.to_a
    assert_in_delta 5.0, result[0], 1e-12   # |3+4i| = 5
    assert_in_delta 13.0, result[1], 1e-12  # |5+12i| = 13
  end

  def test_and_or_xor_boolean
    p = CArray.boolean(3); p[] = [true, false, true]
    q = CArray.boolean(3); q[] = [true, true, false]
    assert_equal [true, false, false], p.and(q).to_a
    assert_equal [true, true, true], p.or(q).to_a
    assert_equal [false, true, true], p.xor(q).to_a
  end

  def test_and_with_non_boolean_self_requires_explicit_cast
    # 3.0 breaking: implicit non-bool -> bool coercion removed.
    # Users must now cast explicitly via `.as_boolean`.
    a = CArray.int32(3); a[] = [1, 0, 1]
    b = CArray.boolean(3); b[] = [true, true, false]
    assert_raise(CArray::DataTypeError) { a.and(b) }
    assert_equal [true, false, false], a.as_boolean.and(b).to_a
  end

  def test_pow_zerodiv_for_integer_negative_exponent
    a = CArray.int32(2); a[] = [0, 2]
    # `0 ** -1` => 1/0 raises ZeroDivisionError via op_powi's ca_zerodiv()
    e = CArray.int32(2); e[] = [-1, -1]
    assert_raise(ZeroDivisionError) { a.power(e) }
  end

  # --- mkkernel.rb HEADER_BLOCKS mechanism -----------------------------

  def test_header_blocks_dsl_documented
    mkk = File.read(File.join(EXT_DIR, 'mkkernel.rb'), encoding: 'UTF-8')
    assert_match(/HEADER_BLOCKS\s*=\s*\[\]/, mkk)
    assert_match(/def self\.header_block\(code\)/, mkk)
  end
end
