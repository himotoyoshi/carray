require "test/unit"
require "carray"

# A Ruby Array is not an operand of a numeric or boolean array.  It has no
# data type of its own, so the caller makes it an array first.  Against an
# object array it stays one value.
class TestArrayOperandRefused < Test::Unit::TestCase

  def assert_refused (&block)
    e = assert_raise(TypeError, &block)
    assert_match(/a Ruby Array is not an operand/, e.message)
    e
  end

  def test_operators_refuse
    i = CA_INT32([1, 2, 3])
    assert_refused { i + [1, 2, 3] }
    assert_refused { [1, 2, 3].to_ca.int32 + [1, 2, 3] }
    assert_refused { i ** [2, 2, 2] }
    assert_refused { i.divmod([1, 1, 1]) }
    assert_refused { CA_FLOAT64([1.0]) * [2.0] }
    assert_refused { CA_BOOLEAN([true]) & [false] }
    assert_refused { i.lazy + [1, 1, 1] }
  end

  def test_comparisons_and_bounds_refuse
    i = CA_INT32([1, 2, 3])
    assert_refused { i.eq([1, 5, 3]) }
    assert_refused { i.ne([1, 5, 3]) }
    assert_refused { i.lt([2, 2, 2]) }
    assert_refused { i.lazy.eq([1, 5, 3]) }
    assert_refused { i.pmax([2, 2, 2]) }
    assert_refused { i.fma([1, 1, 1], 0) }
    assert_refused { i.clip(0, [2, 2, 2]) }
    assert_refused { i.clip([0, 0, 0], [2, 2, 2]) }
  end

  def test_every_numeric_receiver_refuses
    assert_refused { CA_FLOAT32([1.0]) * [2.0] }
    assert_refused { CA_CMPLX128([1.0]) + [2.0] }
    assert_refused { CA_INT32(1) + [2] }   # a CScalar receiver
  end

  def test_in_place_forms_refuse
    x = CA_INT32([1, 2, 3])
    assert_refused { x.add!([1, 1, 1]) }
    assert_equal [1, 2, 3], x.to_a
  end

  # The message names types to write, not the receiver's: a CArray of an
  # integer type would cut a Float cell down before the operation.
  def test_the_message_names_types_to_write
    e = assert_refused { CA_UINT8([1]) + [1] }
    assert_match(/\A\+: .* of a uint8 array;/, e.message)
    assert_match(/CA_INT64\(ary\) or CA_FLOAT64\(ary\)/, e.message)
    assert_no_match(/CA_UINT8|template/, e.message)
    e = assert_refused { CA_INT32([1]) + [1] }
    assert_match(/of an int32 array;/, e.message)
    e = assert_refused { CA_BOOLEAN([true]) & [false] }
    assert_match(/CA_BOOLEAN\(ary\)/, e.message)
  end

  def test_a_carray_of_the_type_written_is_an_operand
    a = CA_UINT8([1, 2, 3])
    assert_equal [2, 4, 6], (a + CA_UINT8([1, 2, 3])).to_a
    assert_equal "float64", (a + CA_FLOAT64([0.5, 0.5, 0.5])).data_type_name
    assert_equal [1.5, 2.5, 3.5], (a + CA_FLOAT64([0.5, 0.5, 0.5])).to_a
    assert_equal [true, false, true], a.eq(CA_UINT8([1, 5, 3])).to_a
  end

  # to_ca is no way around the refusal: it makes an object array.
  def test_to_ca_gives_an_object_operand
    assert_equal "object", (CA_INT32([1, 2]) + [1, 2].to_ca).data_type_name
  end

  def test_an_object_array_keeps_an_array_as_one_value
    o = CArray.object(2)
    o[0] = [1]
    o[1] = [1]
    assert_equal [true, true], o.eq([1]).to_a
  end

  def test_a_time_array_reads_an_array_of_times
    t = CArray.time(["2024-01-01", "2024-01-02"], unit: :D)
    assert_equal [true, false], t.eq(["2024-01-01", "2024-01-03"]).to_a
  end

end
