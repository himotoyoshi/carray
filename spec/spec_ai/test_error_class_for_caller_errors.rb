require "test/unit"
require "stringio"
require "carray"

# A mistake a caller can make raises by its kind, never RuntimeError:
# ArgumentError for a shape, size or limit, TypeError for the wrong kind of
# object, CArray::DataTypeError (a TypeError) for a type an operation does
# not take.  utils/check_runtime_errors.rb keeps new RuntimeErrors out.

class TestErrorClassForCallerErrors < Test::Unit::TestCase

  def test_a_retired_data_type_is_a_data_type_error
    assert_raise(CArray::DataTypeError) { CArray.new(:float128, [3]) }
  end

  def test_the_wrong_kind_of_argument_is_a_type_error
    assert_raise(TypeError) { CArray.int32(3, 3).seq.grid([0, 1], [0, 1]) }
    assert_raise(TypeError) { CAMath.zero(1.0) }
  end

  def test_a_size_or_a_limit_is_an_argument_error
    a = CArray.float64(3).seq
    e = a.lazy
    200.times { e = a.lazy + e }
    assert_raise(ArgumentError) { e.to_ca }
    x = CA_FLOAT64([1, 2, 3, 4]).lazy
    300.times { x = x.sqrt }
    assert_raise(ArgumentError) { x.copy }
    assert_raise(ArgumentError) { CArray.int32(4).load_binary(StringIO.new("\0" * 3)) }
    assert_raise(ArgumentError) { CArray.int32(4, 4)[nil, 1].load_binary(StringIO.new("\0" * 3)) }
    s = CScalar.new(:int32)
    s[] = 1
    assert_raise(ArgumentError) { s.add!(CA_INT32([1, 2])) }
    s.add!(CA_INT32([5]))
    assert_equal 6, s[0]
  end

  def test_a_data_type_error_is_a_type_error
    assert_operator CArray::DataTypeError, :<, TypeError
    t = CArray.time(%w[2024-01-01], unit: :D)
    assert_raise(CArray::DataTypeError) { t.sum }
    assert_raise(TypeError) { t + 1 }
  end
end
