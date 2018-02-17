$:.unshift("../lib", "..")

require 'test/unit'
require 'carray'

class Test130 < Test::Unit::TestCase

  def test_float_arithmetic
    assert_equal((CA_FLOAT([100])+1)[0], 101.0)
  end
  
  def test_int64
    assert_raise(RangeError) { CA_INT64([0xffffffffffffffff]) }
    assert_equal(CA_INT64([0x7fffffffffffffff])[0], 
                           0x7fffffffffffffff)
    assert_equal(CA_INT64([0x7fffffffffffffff])+1,
                 CA_INT64([-0x8000000000000000]))
    assert_equal(CA_INT64([0x7fffffffffffffff, 0x7fffffffffffffff]).sum,
                 (2*0x7fffffffffffffff).to_f)
  end


end