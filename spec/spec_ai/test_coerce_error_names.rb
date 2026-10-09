require "test/unit"
require "carray"

# When an operator cannot bring its two operands to one data type, the error
# names each operand: a plain array by its data type, a Face by its class.  A
# Face's storage data type ("fixlen" for times, categoricals, records and
# string columns) does not say what the operand is.
class TestCoerceErrorNames < Test::Unit::TestCase

  FACES = {
    "CATime"         => -> { CATime.wrap(CA_INT64([0, 1]), unit: :s) },
    "CATimedelta"    => -> { CATimedelta.wrap(CA_INT64([5, 7]), unit: :ms) },
    "CACategorical"  => -> { CACategorical.from_codes(CA_INT8([0, 1]), ["x", "y"]) },
    "CARecord"       => -> { CARecord.new(CArray.struct { int32 :x }, 2) },
    "CAConstString"  => -> { CArray.const_string(["a", "bc"]) },
    "CAFixlenString" => -> { CArray.fixlen_string(["a", "bc"]) },
  }

  FACES.each do |name, build|
    define_method("test_#{name}_on_the_right") do
      error = assert_raise(RuntimeError) { CArray.int64(2) + build.call }
      assert_equal "can't coerce carray with data_types of 'int64' and '#{name}'", error.message
    end
  end

  def test_face_on_the_left
    error = assert_raise(RuntimeError) { FACES["CACategorical"].call + CArray.int64(2) }
    assert_equal "can't coerce carray with data_types of 'CACategorical' and 'int64'", error.message
  end

  def test_in_place_operator
    error = assert_raise(RuntimeError) { CArray.int64(2).add!(FACES["CATimedelta"].call) }
    assert_equal "can't coerce carray with data_types of 'int64' and 'CATimedelta'", error.message
  end

  def test_plain_array_keeps_its_data_type
    error = assert_raise(RuntimeError) { CArray.int64(2) + CArray.fixlen(2, bytes: 8) }
    assert_equal "can't coerce carray with data_types of 'int64' and 'fixlen'", error.message
  end

end
