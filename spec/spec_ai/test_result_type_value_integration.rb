# frozen_string_literal: true
#
# spec_ai/test_result_type_value_integration.rb
#
# Acceptance pin for PROPOSAL_RESULT_TYPE_VALUE_INTEGRATION (rev2):
#   - CArray.result_type accepts Ruby *values* (Integer/Float/Complex/
#     true/false/nil) alongside data_type representations (Symbol/Class/
#     String/CArray), inferring the value's data_type via the same
#     ca_value_to_data_type C helper as the (removed) public
#     value_to_data_type Ruby method used.
#   - All existing data_type-representation idioms continue to work.
#   - 3.0 breaking: result_type(N) for Integer N is now value semantic
#     (=> :int64), not data_type-code semantic (e.g. pre-3.0 result_type(1)
#     => :int8 since CA_INT8 == 1).
#
# Companion: spec_ai/test_result_type.rb (= data_type-representation
# semantic, unchanged across this phase).

require "test/unit"
require_relative "../../lib/carray"

class TestResultTypeValueIntegration < Test::Unit::TestCase

  # --------------------------------------------------------------
  # (1) Value-only args
  # --------------------------------------------------------------

  def test_integer_value
    assert_equal :int64, CArray.result_type(3)
    assert_equal :int64, CArray.result_type(0)        # was :boolean pre-3.0
    assert_equal :int64, CArray.result_type(1)        # was :int8 pre-3.0
    assert_equal :int64, CArray.result_type(-100)
    assert_equal :int64, CArray.result_type(2**40)    # Bignum
  end

  def test_float_value
    assert_equal :float64, CArray.result_type(3.14)
    assert_equal :float64, CArray.result_type(0.0)
    assert_equal :float64, CArray.result_type(Float::INFINITY)
  end

  def test_boolean_value
    assert_equal :boolean, CArray.result_type(true)
    assert_equal :boolean, CArray.result_type(false)
  end

  def test_complex_value
    assert_equal :cmplx128, CArray.result_type(1+2i)
    assert_equal :cmplx128, CArray.result_type(Complex(0, 1))
  end

  def test_nil_and_object_value
    # nil and arbitrary Ruby objects map to :object via the value path.
    # Note: String is treated as a data_type-representation (name lookup),
    # not a value — `result_type("int32")` works but `result_type("foo")`
    # raises (= dispatch precedence: Symbol/String/Class for name lookup).
    assert_equal :object, CArray.result_type(nil)
    assert_equal :object, CArray.result_type([1, 2])
    assert_equal :object, CArray.result_type({})
  end

  # --------------------------------------------------------------
  # (2) Mixed value + data_type representation
  # --------------------------------------------------------------

  def test_value_plus_data_type_symbol
    assert_equal :float64, CArray.result_type(3, :float64)
    assert_equal :float32, CArray.result_type(3, :float32)
    assert_equal :int64,   CArray.result_type(0, :int64)
  end

  def test_value_plus_carray
    ca = CArray.int32(3)
    assert_equal :float64, CArray.result_type(ca, 3.14)
    assert_equal :int64,   CArray.result_type(ca, 1_000_000)
  end

  def test_multiple_values
    assert_equal :float64, CArray.result_type(3, 3.14)
    assert_equal :float64, CArray.result_type(1, 2, 3.0, 4)
    assert_equal :cmplx128, CArray.result_type(1+2i, 3.14, 5)
    assert_equal :int64,   CArray.result_type(true, 1)  # bool + int -> int
  end

  # --------------------------------------------------------------
  # (3) Dtype-representation args still work (= regression for AC9)
  # --------------------------------------------------------------

  def test_symbol_data_type_unchanged
    assert_equal :int32,   CArray.result_type(:int32)
    assert_equal :float32, CArray.result_type(:int32, :float32)
    assert_equal :float64, CArray.result_type(:float32, :float64)
  end

  def test_ca_constant_unchanged
    # CA_INT64 is a Symbol post-flip; equality with :int64 transparent.
    assert_equal CA_FLOAT32, CArray.result_type(CA_INT32, CA_FLOAT32)
    assert_equal CA_INT64,   CArray.result_type(CA_INT8, CA_INT64)
  end

  def test_string_data_type_unchanged
    assert_equal :float64, CArray.result_type("int32", "float64")
  end

  def test_carray_only_unchanged
    a = CArray.int32(3)
    b = CArray.float32(3)
    assert_equal :float32, CArray.result_type(a, b)
  end

  # --------------------------------------------------------------
  # (4) then_else integration (= primary internal customer)
  # --------------------------------------------------------------

  def test_then_else_uses_value_aware_result_type
    cond = CA_BOOLEAN([true, false, true])
    # int CArray x + float scalar y -> result must promote to float
    x = CA_INT32([1, 2, 3])
    y = 3.14
    result = cond.then_else(x, y)
    assert_equal :float64, result.data_type
  end

  def test_then_else_int_scalar_promotion
    cond = CA_BOOLEAN([true, false])
    result = cond.then_else(1, 2.5)
    assert_equal :float64, result.data_type
  end

  # --------------------------------------------------------------
  # (5) value_to_data_type Ruby method is removed (3.0 breaking)
  # --------------------------------------------------------------

  def test_value_to_data_type_removed
    assert_raise(NoMethodError) do
      CArray.value_to_data_type(3)
    end
  end

  # --------------------------------------------------------------
  # (6) No-arg still raises
  # --------------------------------------------------------------

  def test_no_args_raises
    assert_raise(ArgumentError) { CArray.result_type }
  end

end
