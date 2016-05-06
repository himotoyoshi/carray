$:.unshift("../lib", "..")

require 'test/unit'
require 'carray'

class TestCArrayBlockIterator < Test::Unit::TestCase

  def test_block_asignment
    a = CArray.object(4,4)
    b = a.blocks(0..1,0..1).each_with_addr{|x,i| x[] = i * 2 }
    c = CArray.object(2,2).seq!(0,2)[:%,:%,2,2].transposed(0,2,1,3).reshape(4,4)
    assert_equal(c, a)
  end

end


