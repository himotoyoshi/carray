# ---------------------------------------------------------------------------
# spec_ai/test_mkkernel_monop_p5b1.rb
#
# Phase 5b P.5b.1 — MkKernel.monop DSL PoC, "zero" op migrated to
# mkkernel.rb.  Pins byte parity vs eager-known semantics (= zero is
# trivial: all data_types produce 0/false), and confirms the lazy path
# (CAMonOp via .lazy.zero.to_ca) routes through the same generated
# kernel tables.
#
# Migration target: monop("zero", ...) declaration moved from
# ext/carray_math.rb to ext/mkkernel.rb via MkKernel.monop :zero.
# Calling convention unchanged (ca_monop_zero_<ctype>(n, m, ...) /
# ca_monop_zero[CA_NTYPE] / rb_ca_zero / rb_ca_zero_bang), so
# ca_monop_dispatch.c's extern references continue to resolve and
# the lazy dispatch path is unaffected.
# ---------------------------------------------------------------------------

$LOAD_PATH.unshift File.expand_path('../../../ext', __FILE__)
$LOAD_PATH.unshift File.expand_path('../../../lib', __FILE__)

require 'test/unit'
require 'carray'

class TestMkKernelMonopP5b1 < Test::Unit::TestCase
  ALL_NUMERIC_DTYPES = [
    :int8, :uint8, :int16, :uint16, :int32, :uint32, :int64, :uint64,
    :float32, :float64,
  ]

  def test_zero_returns_new_array_of_zeros_for_all_numeric
    ALL_NUMERIC_DTYPES.each do |dt|
      arr = CArray.send(dt, 5).seq(7)
      z = arr.zero
      assert_kind_of CArray, z
      assert_equal arr.data_type, z.data_type
      assert_equal [0]*5, z.to_a, "#{dt}: #{z.to_a}"
      # original untouched (non-bang)
      assert_equal arr.elements, arr.to_a.size
      assert_not_equal [0]*5, arr.to_a, "#{dt} original should be untouched"
    end
  end

  def test_zero_bang_in_place
    arr = CArray.float64(5).seq(1.0)
    rv = arr.zero!
    assert_same arr, rv
    assert_equal [0.0]*5, arr.to_a
  end

  def test_zero_on_boolean
    arr = CArray.boolean(3)
    arr[] = true
    z = arr.zero
    # CArray boolean displays as 0/1
    assert_equal [false, false, false], z.to_a
  end

  def test_zero_on_complex
    arr = CArray.cmplx128(3)
    arr[] = Complex(3, 4)
    z = arr.zero
    assert_equal [Complex(0, 0)]*3, z.to_a
  end

  def test_zero_on_object
    arr = CArray.object(3)
    arr[0] = "hello"
    arr[1] = 42
    arr[2] = [1, 2, 3]
    z = arr.zero
    # OBJ_TYPES => INT2FIX(0) — all slots become Integer 0
    assert_equal [0, 0, 0], z.to_a
  end

  def test_zero_through_lazy_view
    a = CArray.float64(5).seq(1.0)
    lazy = a.lazy.zero
    assert_kind_of CAMonOp, lazy
    materialised = lazy.to_ca
    assert_kind_of CArray, materialised
    assert_equal [0.0]*5, materialised.to_a
  end

  def test_zero_on_view_input
    a = CArray.float64(10).seq(1.0)
    block = a[2..6]
    z = block.zero
    assert_equal [0.0]*5, z.to_a
    # block's parent (a) unchanged
    assert_equal (1.0..10.0).step(1.0).to_a, a.to_a
  end

  def test_mkkernel_emitted_symbols_present_in_kernels_c
    kernels_c = Dir[File.expand_path('../../../ext/carray_kernels_*.c', __FILE__)].map { |__f| File.read(__f, encoding: 'UTF-8') }.join("\n")
    assert_match(/ca_monop_zero_float64_t/, kernels_c)
    assert_match(/ca_monop_zero\[CA_NTYPE\]/, kernels_c)
    assert_match(/rb_ca_zero \(VALUE self\)/, kernels_c)
    assert_match(/rb_ca_zero_bang/, kernels_c)
    assert_match(/rb_cmath_zero/, kernels_c)
    assert_match(/rb_define_method\(rb_cCArray, "zero"/, kernels_c)
    assert_match(/rb_define_method\(rb_cCArray, "zero!"/, kernels_c)
    assert_match(/rb_define_module_function\(rb_mCAMath, "zero"/, kernels_c)
  end

  def test_no_mkmath_emitted_zero_symbols_in_ipower_c
    # 2026-06-10: carray_math.c merged into ca_op_ipower.c.  Check the
    # successor file still has no stray mkmath-era zero/monop symbols.
    ipower_c = File.read(File.expand_path('../../../ext/ca_op_ipower.c', __FILE__), encoding: 'UTF-8')
    refute_match(/^ca_monop_zero_/, ipower_c)
    refute_match(/^ca_monop_zero\[CA_NTYPE\]/, ipower_c)
    refute_match(/rb_ca_zero \(VALUE self\)/, ipower_c)
  end
end
