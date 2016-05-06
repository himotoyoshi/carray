$:.unshift("../lib", "..")

require 'test/unit'
require 'carray'

class TestCArrayCAShift < Test::Unit::TestCase

  def test_virtual_array
    a = CArray.int(3,3)
    b = a.shifted(1,1)
    r = b.parent
    assert_instance_of(CAShift, b)
    assert_equal(true, b.virtual?)
    assert_equal(a, r)
  end

end