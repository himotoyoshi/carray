$:.unshift("../lib", "..")

require 'test/unit'
require 'carray'

class TestCArrayCAField < Test::Unit::TestCase

  def test_virtual_array
    a = CArray.int(3,3)
    b = a.field(0,CA_INT8)
    r = b.parent
    assert_instance_of(CAField, b)
    assert_equal(true, b.virtual?)
    assert_equal(a, r)
  end

  def test_attributes
    #
    a = CArray.int16(3,3) { 0x1122 }
    b = a.field(0, CA_INT8)
    assert_equal(CA_INT8, b.data_type)
    assert_equal([3,3], b.dim)
  end

  def test_endian
    #
    a = CArray.int16(3,3) { 0x1122 }
    b = CArray.int8(3,3) { 0x11 }
    c = CArray.int8(3,3) { 0x22 }
    if CArray.big_endian?
      assert_equal(b, a.field(0, CA_INT8))
      assert_equal(c, a.field(1, CA_INT8))
    else
      assert_equal(b, a.field(1, CA_INT8))
      assert_equal(c, a.field(0, CA_INT8))
    end
  end


end
