$:.unshift("../lib", "..")

require 'test/unit'
require 'carray'

class TestCArrayRandom < Test::Unit::TestCase

  def test_random
    a = CArray.uint8(100, 100).random!(10)
    assert_equal(0, (a < 0).count_true)
    assert_equal(0, (a > 10).count_true)
  end


end
