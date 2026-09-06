# frozen_string_literal: true
#
# Real element-wise math on a float32 array is computed at that width.
#
# `sin` takes a double, so a body naming only it still compiles for an
# f32 cell -- the cell widens on the way in and rounds on the way out,
# and the kernel computes at f64 whatever the array said it was.  The
# f-suffix names (`sinf`, `powf`, `atan2f`, ...) close that.
#
# Not every double-taking call is narrowed: `fabs`, `fmin` / `fmax`,
# `ceil` / `floor` / `trunc` and the `isnan` family are exact on a float
# either way, and `round` is `floor(x + 0.5)`, which is exact only when
# the addition happens in double.  Those keep their shared body, and the
# agreement tests below cover them too.

require "test/unit"
require "carray"

class TestFloat32MathWidth < Test::Unit::TestCase

  UNARY = %w[
    sqrt exp log sin cos tan asin acos atan
    sinh cosh tanh asinh acosh atanh
    exp2 exp10 log2 log10 logb expm1 log1p rsqrt
    trunc round ceil floor frac rad deg abs
  ].freeze

  BINARY = %w[power hypot atan2 fmod logaddexp copysign].freeze

  # In (0, 1), where every op above is defined except `acosh`, which
  # wants x >= 1.  Powers of two and their halves so the operands
  # themselves are exact in both widths and only the result differs.
  SAMPLES = [0.5, 0.125, 0.75, 0.3125].freeze
  RHS     = [0.25, 0.5, 0.875, 0.0625].freeze
  DOMAIN  = { "acosh" => [1.25, 2.5, 1.0625, 3.0].freeze }.freeze

  def samples_for(m) = DOMAIN.fetch(m, SAMPLES)

  def f32 = CA_FLOAT32(SAMPLES)
  def f64 = CA_FLOAT64(SAMPLES)
  def f32b = CA_FLOAT32(RHS)
  def f64b = CA_FLOAT64(RHS)

  def test_every_op_reaches_a_float32_kernel
    UNARY.each do |m|
      assert_nothing_raised("#{m} has no float32 kernel") do
        CA_FLOAT32(samples_for(m)).send(m)
      end
    end
    BINARY.each do |m|
      assert_nothing_raised("#{m} has no float32 kernel") { f32.send(m, f32b) }
    end
  end

  def test_result_stays_float32
    UNARY.each { |m| assert_equal CA_FLOAT32, CA_FLOAT32(samples_for(m)).send(m).data_type, m }
    BINARY.each { |m| assert_equal CA_FLOAT32, f32.send(m, f32b).data_type, m }
  end

  # The narrow kernel may differ from the wide one in the last bits; it
  # may not be a different function.  A wrong suffix (`sinf` where
  # `sinhf` was meant, say) shows up here at once.
  def test_float32_agrees_with_float64_to_float32_precision
    UNARY.each do |m|
      xs = samples_for(m)
      narrow = CA_FLOAT32(xs).send(m)
      wide   = CA_FLOAT64(xs).send(m)
      xs.each_index do |i|
        assert_in_delta wide[i], narrow[i], 1e-5 * [wide[i].abs, 1.0].max,
                        "#{m} at #{xs[i]}"
      end
    end
    BINARY.each do |m|
      narrow = f32.send(m, f32b)
      wide   = f64.send(m, f64b)
      SAMPLES.each_index do |i|
        assert_in_delta wide[i], narrow[i], 1e-5 * [wide[i].abs, 1.0].max,
                        "#{m} at #{SAMPLES[i]}, #{RHS[i]}"
      end
    end
  end

  # nextafter is the one op the widening did not merely round: the next
  # double above a float is still that same float once it comes back, so
  # the f32 form returned its own input.  The step has to be taken at
  # the operand's width to exist at all.
  def test_nextafter_steps_at_float32_width
    a = CA_FLOAT32([1.0, 2.0, 0.5])
    up = a.nextafter(a + 10.0)
    down = a.nextafter(a - 10.0)
    a.elements.times do |i|
      assert up[i] > a[i],   "nextafter up did not move at #{a[i]}"
      assert down[i] < a[i], "nextafter down did not move at #{a[i]}"
    end
    # one float32 ulp at 1.0
    assert_in_delta 2.0**-23, up[0] - 1.0, 1e-12
  end

  # round is floor(x + 0.5) and stays in double on purpose: narrowing it
  # would round the addition first and step the answer at the boundary.
  def test_round_is_not_stepped_by_the_addition
    just_under = [1.0 - 2.0**-24, 0.5 - 2.0**-25].map { |v| v.to_f }
    a = CA_FLOAT32(just_under)
    r = a.round
    assert_equal 1.0, r[0]   # 0.99999994 rounds to 1
    assert_equal 0.0, r[1]   # 0.49999997 rounds to 0, not 1
  end

  def test_lazy_chain_matches_eager
    %w[sqrt exp log sin atan tanh].each do |m|
      eager = f32.send(m)
      lazy  = f32.lazy.send(m).to_ca
      assert_equal eager.data_type, lazy.data_type, "#{m} data_type"
      SAMPLES.each_index do |i|
        assert_in_delta eager[i], lazy[i], 1e-6 * [eager[i].abs, 1.0].max, "#{m} at #{i}"
      end
    end
  end
end
