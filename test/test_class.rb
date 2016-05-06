$:.unshift("../lib", "..")

require 'test/unit'
require 'carray'

class TestCArrayClass < Test::Unit::TestCase

  # CA_BIG_ENDIAN : 1
  # CA_LITTLE_ENDIAN : 0

  def test_endian
    if [1].pack("s") == [1].pack("n")
      endian = CA_BIG_ENDIAN
    else
      endian = CA_LITTLE_ENDIAN
    end
    assert_equal(CArray.endian, endian)
    case endian
    when CA_BIG_ENDIAN
      assert_equal(CArray.big_endian?, true)
      assert_equal(CArray.little_endian?, false)
    when CA_LITTLE_ENDIAN
      assert_equal(CArray.big_endian?, false)
      assert_equal(CArray.little_endian?, true)
    end
  end

  def test_sizeof
    assert_equal(CArray.sizeof(CA_INT8), 1)
    assert_equal(CArray.sizeof(CA_UINT8), 1)
    assert_equal(CArray.sizeof(CA_INT16), 2)
    assert_equal(CArray.sizeof(CA_UINT16), 2)
    assert_equal(CArray.sizeof(CA_INT32), 4)
    assert_equal(CArray.sizeof(CA_UINT32), 4)
    # assert_equal(CArray.sizeof(CA_INT64), 8)
    # assert_equal(CArray.sizeof(CA_UINT64), 8)
    assert_equal(CArray.sizeof(CA_FLOAT32), 4)
    assert_equal(CArray.sizeof(CA_FLOAT64), 8)
    # assert_equal(CArray.sizeof(CA_FLOAT128), 16)
    # assert_equal(CArray.sizeof(CA_CMPLX64), 8)
    # assert_equal(CArray.sizeof(CA_CMPLX128), 16)
    # assert_equal(CArray.sizeof(CA_CMPLX256), 32)
    assert_equal(CArray.sizeof(CA_FIXLEN), 0)
    # assert_equal(CArray.sizeof(CA_OBJECT), 0)
  end

  def test_valid_type?
    # can't test this method
    assert_raise(ArgumentError) { CArray.data_type?(-1) }
    assert_equal(CArray.data_type?(CA_FIXLEN), true)
    assert_equal(CArray.data_type?(CA_INT8), true)
    assert_equal(CArray.data_type?(CA_INT32), true)
    assert_equal(CArray.data_type?(CA_FLOAT32), true)
    assert_equal(CArray.data_type?(CA_OBJECT), true)
    assert_raise(ArgumentError) { CArray.data_type?(CA_OBJECT+1) }
  end

  def test_type_name
    [
     [CA_INT8, "int8"],
     [CA_UINT8, "uint8"],
     [CA_INT16, "int16"],
     [CA_UINT16, "uint16"],
     [CA_INT32, "int32"],
     [CA_UINT32, "uint32"],
     [CA_INT64, "int64"],
     [CA_UINT64, "uint64"],
     [CA_FLOAT32, "float32"],
     [CA_FLOAT64, "float64"],
     [CA_FLOAT128, "float128"],
     [CA_CMPLX64, "cmplx64"],
     [CA_CMPLX128, "cmplx128"],
     [CA_CMPLX256, "cmplx256"],
     [CA_FIXLEN, "fixlen"],
     [CA_OBJECT, "object"],
    ].each do |type, name|
      if CArray.data_type?(type)
        assert_equal(CArray.data_type_name(type), name)
      else
        assert_raise(RuntimeError) { CArray.data_type_name(type) }
      end
    end
  end

end
