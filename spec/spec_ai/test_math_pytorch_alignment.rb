$LOAD_PATH.unshift File.expand_path("../../../ext", __FILE__)
$LOAD_PATH.unshift File.expand_path("../../../lib", __FILE__)
require "test/unit"
require "carray"

# Refinement scope: `using` must appear at top-level / class-body scope,
# not inside a method.  Pre-define helper modules here so the
# polymorphic-helper tests can reference them.
module PyTorchAlignmentHelper
  using CArray::CoreExtensions
  module_function
  def polymorphic_compose(x); x.square + x.expm1; end
  def polymorphic_signbit(x); x.signbit; end
end

# PyTorch-aligned math surface coverage.
#
# Pins the methods added / migrated when the math surface was lifted
# onto the mkkernel substrate:
#   - new monfunc: expm1 / log1p / rsqrt / trunc / square / signbit
#   - new binop:   copysign / logaddexp / nextafter / fmod
#   - atan2 / hypot migration from hand-written CAMath wrappers
#   - deg_360 / deg_180 / rad_2pi / rad_pi migration
#   - bang variants where dtype-preserving
#   - lazy substrate (a.lazy.X)
#   - CArray::CoreExtensions refinement parity for scalar polymorphism
class TestMathPyTorchAlignment < Test::Unit::TestCase

  # ---- new monfuncs -------------------------------------------------------

  def test_m1_expm1_log1p_byte_parity
    a = CArray.float64(7).seq + 0.5
    # expm1(log1p(x)) == x (numerical identity within tolerance)
    round_trip = a.log1p.expm1
    a.each_addr do |i|
      assert_in_delta a[i], round_trip[i], 1e-12
    end
  end

  def test_m1_rsqrt
    a = CArray.float64(4) { |i| 1.0 + i }
    expected = [1.0, 1/Math.sqrt(2), 1/Math.sqrt(3), 0.5]
    a.rsqrt.to_a.zip(expected).each do |got, exp|
      assert_in_delta exp, got, 1e-14
    end
  end

  def test_m1_trunc_float_int_object
    af = CArray.float64(5) { |i| i - 2.7 }
    # i - 2.7 for i=0..4: [-2.7, -1.7, -0.7, 0.3, 1.3]
    # trunc → toward zero: [-2, -1, -0, 0, 1]
    assert_equal [-2.0, -1.0, -0.0, 0.0, 1.0], af.trunc.to_a
    ai = CArray.int64(5).seq - 2
    assert_equal [-2, -1, 0, 1, 2], ai.trunc.to_a   # int identity
  end

  def test_m1_square
    a = CArray.float64(4).seq + 1
    assert_equal [1.0, 4.0, 9.0, 16.0], a.square.to_a
    ai = CArray.int32(4).seq + 1
    assert_equal [1, 4, 9, 16], ai.square.to_a
  end

  def test_m1_signbit_float_int
    a = CArray.float64(5) { |i| i - 2.5 }
    assert_equal [true, true, true, false, false], a.signbit.to_a
    # signbit dtype = boolean
    assert_equal CA_BOOLEAN, a.signbit.data_type
    si = CArray.int32(5) { |i| i - 2 }
    assert_equal [true, true, false, false, false], si.signbit.to_a
    ui = CArray.uint8(5).seq
    assert_equal [false, false, false, false, false], ui.signbit.to_a   # uint: always false
  end

  def test_m1_lazy_chain
    a = CArray.float64(4).seq + 1
    # (a.lazy.square.expm1.log1p).sqrt ≈ a (within float)
    chain = a.lazy.square.expm1.log1p.sqrt.to_ca
    chain.to_a.zip(a.to_a).each do |got, exp|
      assert_in_delta exp, got, 1e-10
    end
  end

  def test_m1_bang_preserve_dtype
    a = CArray.float64(4).seq + 1
    a.square!
    assert_equal [1.0, 4.0, 9.0, 16.0], a.to_a
    b = CArray.float64(4).seq + 1
    b.rsqrt!
    b.to_a.zip([1, 1/Math.sqrt(2), 1/Math.sqrt(3), 0.5]).each do |g, e|
      assert_in_delta e, g, 1e-14
    end
  end

  # ---- new binops ---------------------------------------------------------

  def test_m2_copysign
    a = CArray.float64(4) { |i| (i + 1).to_f }      # [1, 2, 3, 4]
    s = CArray.float64(4) { |i| (-1) ** i * 1.0 }   # [1, -1, 1, -1]
    assert_equal [1.0, -2.0, 3.0, -4.0], a.copysign(s).to_a
  end

  def test_m2_fmod
    a = CArray.float64(4) { |i| (i + 1) * 2.5 }    # [2.5, 5.0, 7.5, 10.0]
    b = CArray.float64(4) { 3.0 }
    expected = a.to_a.map { |v| v.modulo(3.0) }
    a.fmod(b).to_a.zip(expected).each do |g, e|
      assert_in_delta e, g, 1e-12
    end
  end

  def test_m2_logaddexp
    # logaddexp(x, y) == log(exp(x) + exp(y))
    a = CArray.float64(4) { |i| (i - 1).to_f }
    b = CArray.float64(4) { |i| (i + 1).to_f }
    a.logaddexp(b).to_a.each_with_index do |got, i|
      exp = Math.log(Math.exp(a[i]) + Math.exp(b[i]))
      assert_in_delta exp, got, 1e-12
    end
  end

  def test_m2_nextafter
    a = CArray.float64(3) { |i| (i + 1).to_f }
    b = a + 10.0
    n = a.nextafter(b)
    # all should be > a (since b > a)
    a.elements.times do |i|
      assert n[i] > a[i]
    end
  end

  def test_m2_lazy_logaddexp
    a = CArray.float64(3).seq
    b = CArray.float64(3).seq + 2
    chain = a.lazy.logaddexp(b).to_ca
    chain.to_a.zip(a.logaddexp(b).to_a).each do |g, e|
      assert_in_delta e, g, 1e-14
    end
  end

  # ---- atan2 / hypot migration --------------------------------------------

  def test_m3_atan2_y_first
    y = CArray.float64(4) { |i| (i + 1).to_f }
    x = CArray.float64(4) { 1.0 }
    expected = y.to_a.map { |v| Math.atan2(v, 1.0) }
    y.atan2(x).to_a.zip(expected).each do |g, e|
      assert_in_delta e, g, 1e-14
    end
  end

  def test_m3_hypot_symmetric
    a = CArray.float64(4) { |i| 3.0 + i }
    b = CArray.float64(4) { |i| 4.0 + i }
    a.hypot(b).to_a.zip(b.hypot(a).to_a).each do |g1, g2|
      assert_in_delta g2, g1, 1e-14
    end
  end

  def test_m3_camath_wrappers
    y = CArray.float64(3).seq + 1
    x = CArray.float64(3).seq + 2
    # CAMath delegates to receiver methods with original argument order
    assert_equal y.atan2(x).to_a, CAMath.atan2(y, x).to_a
    assert_equal x.hypot(y).to_a, CAMath.hypot(x, y).to_a
    assert_equal x.expm1.to_a,    CAMath.expm1(x).to_a
    assert_equal x.log1p.to_a,    CAMath.log1p(x).to_a
  end

  def test_m3_camath_scalar_first_arg_auto_wrap
    y = CArray.float64(3).seq + 1
    out = CAMath.atan2(1.0, y)   # 1.0 wraps to CScalar
    expected = y.to_a.map { |v| Math.atan2(1.0, v) }
    out.to_a.zip(expected).each do |g, e|
      assert_in_delta e, g, 1e-14
    end
  end

  # ---- angle normalisation ------------------------------------------------

  def test_m4_deg_360
    a = CArray.float64(5) { |i| (i - 2) * 100.0 }     # [-200, -100, 0, 100, 200]
    assert_equal [160.0, 260.0, 0.0, 100.0, 200.0], a.deg_360.to_a
  end

  def test_m4_deg_180
    a = CArray.float64(5) { |i| (i - 2) * 100.0 }
    out = a.deg_180.to_a
    out.each { |v| assert v >= -180.0 && v < 180.0, "out of range: #{v}" }
    # Round-trip identity: deg_180(deg_180(x)) == deg_180(x)
    a.deg_180.deg_180.to_a.zip(out) { |g, e| assert_in_delta e, g, 1e-12 }
  end

  def test_m4_rad_2pi
    a = CArray.float64(5) { |i| (i - 2) * Math::PI }
    a.rad_2pi.to_a.each do |v|
      assert v >= 0.0 && v < 2 * Math::PI + 1e-12, "out of range: #{v}"
    end
  end

  def test_m4_rad_pi
    a = CArray.float64(5) { |i| (i - 2) * Math::PI }
    a.rad_pi.to_a.each do |v|
      assert v >= -Math::PI - 1e-12 && v < Math::PI + 1e-12, "out of range: #{v}"
    end
  end

  def test_m4_lazy_chain
    a = CArray.float64(5) { |i| (i - 2) * 100.0 }
    eager = a.deg_360
    lazy  = a.lazy.deg_360.to_ca
    assert_equal eager.dump_binary, lazy.dump_binary
  end

  def test_m4_bang_dtype_preserve
    a = CArray.float64(3) { |i| (i + 1) * 200.0 }
    expected = a.deg_360.to_a
    a.deg_360!
    assert_equal expected, a.to_a
  end

  # ---- CArray::CoreExtensions refinement parity --------------------------

  def test_refinement_polymorphic_helper
    # Float
    assert_in_delta (2.0 ** 2) + (Math.exp(2.0) - 1.0),
                    PyTorchAlignmentHelper.polymorphic_compose(2.0), 1e-12
    # CArray
    arr = CArray.float64(3).seq + 1
    expected = arr.to_a.map { |v| v ** 2 + (Math.exp(v) - 1.0) }
    PyTorchAlignmentHelper.polymorphic_compose(arr).to_a.zip(expected).each do |g, e|
      assert_in_delta e, g, 1e-12
    end
  end

  def test_refinement_signbit_scalar
    assert_equal true,  PyTorchAlignmentHelper.polymorphic_signbit(-3)
    assert_equal false, PyTorchAlignmentHelper.polymorphic_signbit(3)
  end

  # ---- op_id constants exposed ------------------------------------------

  def test_op_id_constants_exposed
    %i[OP_EXPM1 OP_LOG1P OP_RSQRT OP_TRUNC OP_SQUARE
       OP_DEG_360 OP_DEG_180 OP_RAD_2PI OP_RAD_PI].each do |c|
      assert CAMonOp.const_defined?(c), "CAMonOp::#{c} not defined"
    end
    %i[OP_COPYSIGN OP_LOGADDEXP OP_NEXTAFTER OP_FMOD
       OP_ATAN2 OP_HYPOT].each do |c|
      assert CABinOp.const_defined?(c), "CABinOp::#{c} not defined"
    end
    assert CAMonCmp.const_defined?(:OP_SIGNBIT)
  end

  def test_lazy_dispatch_tables_include_new_ops
    %i[expm1 log1p rsqrt trunc square deg_360 deg_180 rad_2pi rad_pi].each do |m|
      assert CArray::LAZY_MONOP_OP_IDS.key?(m), "monop missing #{m}"
    end
    %i[copysign logaddexp nextafter fmod atan2 hypot].each do |m|
      assert CArray::LAZY_BINOP_OP_IDS.key?(m), "binop missing #{m}"
    end
    assert CArray::LAZY_MONCMP_OP_IDS.key?(:signbit)
  end

end
