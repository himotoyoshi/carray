$:.unshift("../lib", "..")

require 'test/unit'
require 'carray'

class TestCArrayCASelect < Test::Unit::TestCase

  def test_virtual_array
    a = CArray.int(3,3) { 0 }
    b = a[a.eq(0)]
    r = b.parent
    assert_instance_of(CASelect, b)
    assert_equal(true, b.virtual?)
    assert_equal(a, r)
  end

  def test_select_to_a
    a = CArray.int(3,3).seq!
    s = a[a >= 4]
    assert_equal([4, 5, 6, 7, 8], a[s].to_a)
  end

end
