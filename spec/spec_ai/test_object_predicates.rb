require "test/unit"
require "carray"
require "bigdecimal"

# The NaN / infinity / sign predicates on an object array give the answer
# Ruby gives for each element, as a boolean the reductions and the logical
# operators read like any other.

class TestObjectPredicates < Test::Unit::TestCase

  NAN = Float::NAN
  INF = Float::INFINITY

  VALUES = [1.0, NAN, INF, -INF, -0.0, 0.0, 2, 2**70, Rational(1, 2),
            BigDecimal("1.5"), BigDecimal("NaN"), BigDecimal("Infinity")]

  def ruby (v, op)
    case op
    when :is_nan    then v.respond_to?(:nan?) ? v.nan? : false
    when :is_inf    then !!v.infinite?
    when :is_finite then !!v.finite?
    end
  end

  def test_answers_match_ruby_and_eager_matches_lazy
    a = CA_OBJECT(VALUES)
    [:is_nan, :is_inf, :is_finite].each do |op|
      exp = VALUES.map { |v| ruby(v, op) }
      assert_equal exp, a.send(op).to_a, op.to_s
      assert_equal exp, a.lazy.send(op).copy.to_a, "lazy #{op}"
    end
  end

  def test_result_is_a_boolean_the_rest_of_the_library_reads
    f = CA_OBJECT([1.0, NAN, 2.0]).is_finite
    assert_equal 2, f.count(true)
    assert_equal 2, f.sum
    assert_equal false, f.all
    assert_equal [true, false, true], (f & CA_FLOAT64([1.0, NAN, 2.0]).is_finite).to_a
    assert_equal CA_FLOAT64([1.0, NAN, 2.0]).is_finite.to_a, f.to_a
    assert_equal [false, false], CA_OBJECT([1.0, 2]).is_inf.to_a
    assert_equal false, CA_OBJECT([1.0, 2]).is_inf.any
  end

  def test_signbit_of_a_float_is_its_sign_bit
    vals = [-1.0, 0.0, -0.0, -NAN, NAN]
    assert_equal CA_FLOAT64(vals).signbit.to_a, CA_OBJECT(vals).signbit.to_a
    assert_equal [true, false, false], CA_OBJECT([-3, 0, Rational(1, 2)]).signbit.to_a
  end

end
