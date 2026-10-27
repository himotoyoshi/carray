# spec_ai/test_scalar_operand_branch.rb
#
# An operation against a scalar gives the answer the same operation gives
# against an array filled with that scalar: on either side, for arithmetic,
# comparisons and bang forms, contiguous or not.

require "test/unit"
require "carray"

class TestScalarOperandBranch < Test::Unit::TestCase

  TYPES = [CA_INT8, CA_UINT8, CA_INT32, CA_INT64, CA_FLOAT32, CA_FLOAT64,
           CA_CMPLX128, CA_OBJECT]

  def operand (type, n)
    vals = (0...n).map { |i| (i % 7) + 1 }
    a = CArray.new(type, [n]) { vals }
    a = a.to_type(CA_CMPLX128) * Complex(1, 1) if type == CA_CMPLX128
    a
  end

  def assert_same_answer (got, want, message)
    assert_equal want.data_type, got.data_type, message
    assert_equal want.to_a, got.to_a, message
  end

  def test_arithmetic_on_either_side
    TYPES.each do |type|
      a = operand(type, 37)
      s = (type == CA_CMPLX128) ? Complex(2, 1) : 3
      filled = CArray.new(a.data_type, [37]) { s }
      %i[+ - *].each do |op|
        assert_same_answer a.send(op, s), a.send(op, filled), "#{op} scalar right, type #{type}"
        assert_same_answer s.send(op, a), filled.send(op, a), "#{op} scalar left, type #{type}"
      end
    end
  end

  def test_comparison_on_either_side
    TYPES.each do |type|
      next if type == CA_CMPLX128
      a = operand(type, 37)
      filled = CArray.new(a.data_type, [37]) { 4 }
      %i[> < >= <= eq ne].each do |op|
        assert_same_answer a.send(op, 4), a.send(op, filled), "#{op} scalar right, type #{type}"
      end
      assert_same_answer 4 < a, filled < a, "scalar left <, type #{type}"
      assert_same_answer 4 > a, filled > a, "scalar left >, type #{type}"
    end
  end

  def test_bang_against_a_scalar
    [CA_INT32, CA_FLOAT32, CA_FLOAT64].each do |type|
      a = operand(type, 37)
      b = a.copy
      a.add!(2)
      b.add!(CArray.new(type, [37]) { 2 })
      assert_equal b.to_a, a.to_a, "add! type #{type}"
    end
  end

  def test_strided_operand_and_mask
    a = operand(CA_FLOAT64, 74)[[0, 37, 2]]
    filled = CArray.float64(37) { 1.5 }
    assert_equal (a - filled).to_a, (a - 1.5).to_a
    m = operand(CA_FLOAT64, 37)
    m[[0, 5, 3]] = UNDEF
    assert_equal (m * CArray.float64(37) { 2.0 }).to_a, (m * 2.0).to_a
    assert_equal (m > CArray.float64(37) { 3.0 }).to_a, (m > 3.0).to_a
  end

end
