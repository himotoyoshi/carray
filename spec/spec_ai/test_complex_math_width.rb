# frozen_string_literal: true
#
# Complex element-wise math is computed at the width of the array's own
# complex data_type.
#
# `csqrt` and friends take a `double _Complex`, so a body naming only
# them still compiles for a cmplx64 cell -- the cell widens on the way
# in and rounds on the way out.  The kernel then computes at cmplx128
# whatever the array said it was, while the `+ - *` kernels beside it
# stay narrow.  The f-suffix names (`csqrtf`, `cabsf`, `cargf`, ...)
# close that split.
#
# What is checkable from Ruby is the pair of things a wrong suffix or a
# dropped expr entry would break: every op still reaches a cmplx64
# kernel at all, and the value it produces still agrees with the
# cmplx128 answer to float32 precision.

require "test/unit"
require "carray"

class TestComplexMathWidth < Test::Unit::TestCase

  # Every complex-capable element-wise op, with the kind of result it
  # hands back: :complex keeps the complex data_type, :real demotes to
  # that type's real component width.
  UNARY = {
    "sqrt"  => :complex, "exp"   => :complex, "log"   => :complex,
    "sin"   => :complex, "cos"   => :complex, "tan"   => :complex,
    "asin"  => :complex, "acos"  => :complex, "atan"  => :complex,
    "sinh"  => :complex, "cosh"  => :complex, "tanh"  => :complex,
    "asinh" => :complex, "acosh" => :complex, "atanh" => :complex,
    "exp2"  => :complex, "exp10" => :complex, "rsqrt" => :complex,
    "conj"  => :complex, "sign"  => :complex, "abs_i" => :complex,
    "imag_i" => :complex,
    "abs"   => :real,    "abs2"  => :real,    "arg"   => :real,
    "real"  => :real,    "imag"  => :real,
  }.freeze

  # Ordinary points, away from branch cuts so the two widths are
  # comparing the same branch.
  SAMPLES = [Complex(1.0, 2.0), Complex(0.5, -0.75), Complex(3.25, 0.125)].freeze

  def c64  = CA_CMPLX64(SAMPLES)
  def c128 = CA_CMPLX128(SAMPLES)

  # A dropped or mis-keyed expr entry leaves the cmplx64 slot filled
  # with `not_implement`, which raises rather than returning a wrong
  # number -- so reaching the kernel at all is worth asserting on its
  # own.
  def test_every_op_reaches_a_cmplx64_kernel
    UNARY.each_key do |m|
      assert_nothing_raised("#{m} has no cmplx64 kernel") { c64.send(m) }
    end
  end

  def test_result_width_follows_the_operand
    UNARY.each do |m, kind|
      assert_equal((kind == :complex ? CA_CMPLX64 : CA_FLOAT32),
                   c64.send(m).data_type, "#{m} on cmplx64")
      assert_equal((kind == :complex ? CA_CMPLX128 : CA_FLOAT64),
                   c128.send(m).data_type, "#{m} on cmplx128")
    end
  end

  # The narrow kernel is allowed to differ from the wide one in the last
  # bits; it is not allowed to be a different function.  A wrong suffix
  # (csinf where csinhf was meant, say) shows up here immediately.
  def test_cmplx64_agrees_with_cmplx128_to_float32_precision
    UNARY.each_key do |m|
      narrow = c64.send(m)
      wide   = c128.send(m)
      SAMPLES.each_index do |i|
        a = Complex(narrow[i])
        b = Complex(wide[i])
        scale = [b.abs, 1.0].max
        assert_in_delta 0.0, (a - b).abs, 1e-5 * scale,
                        "#{m} at #{SAMPLES[i]}: #{a} vs #{b}"
      end
    end
  end

  def test_power_agrees_across_widths
    e = Complex(2.0, 0.5)
    narrow = c64.power(CA_CMPLX64([e] * SAMPLES.size))
    wide   = c128.power(CA_CMPLX128([e] * SAMPLES.size))
    assert_equal CA_CMPLX64,  narrow.data_type
    assert_equal CA_CMPLX128, wide.data_type
    SAMPLES.each_index do |i|
      a = Complex(narrow[i])
      b = Complex(wide[i])
      assert_in_delta 0.0, (a - b).abs, 1e-5 * [b.abs, 1.0].max, "power at #{SAMPLES[i]}"
    end
  end

  # abs_i / imag_i / arg_i are the type-preserving primitives the lazy
  # chains are built from; they carry the same width rule.
  def test_lazy_chain_matches_eager
    %w[sqrt exp log sin abs arg].each do |m|
      eager = c64.send(m)
      lazy  = c64.lazy.send(m).to_ca
      assert_equal eager.data_type, lazy.data_type, "#{m} data_type"
      SAMPLES.each_index do |i|
        assert_in_delta 0.0, (Complex(eager[i]) - Complex(lazy[i])).abs,
                        1e-6 * [Complex(eager[i]).abs, 1.0].max, "#{m} at #{i}"
      end
    end
  end
end
