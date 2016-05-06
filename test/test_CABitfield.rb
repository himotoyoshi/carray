$:.unshift("../lib", "..")

require 'test/unit'
require 'carray'

class TestCArrayCABitfield < Test::Unit::TestCase

  def test_virtual_array
    a = CArray.int(3,3) { 1 }
    b = a.bitfield(0)
    r = b.parent
    assert_instance_of(CABitfield, b)
    assert_equal(true, b.virtual?)
    assert_equal(a, r)
  end

  def test_basic_features
    # ---
    a = CArray.int(3,3)
    b = a.bitfield(0)
    b[] = 1
    assert_equal(a.template{1}, a)
    assert_equal(b.template{1}, b)
    b[] = 0
    assert_equal(a.template{0}, a)    
    assert_equal(b.template{0}, b)    
    # ---
    a = CArray.int(3,3)
    b = a.bitfield(0..1)
    b[] = 3
    assert_equal(a.template{3}, a)
    assert_equal(b.template{3}, b)
    
    # ---
    a = CArray.int(3,3)
    b = a.bitfield(5..6)
    b[] = 3
    assert_equal(a.template{3 << 5}, a)
    assert_equal(b.template{3}, b)
    
    # ---
    a = CArray.int(3,3)
    b = a.bitfield(27..28)
    b[] = 3
    assert_equal(a.template{3 << 27}, a)
    assert_equal(b.template{3}, b)
  end
  
  def test_out_of_index
    # ---
    a = CArray.int8(3)
    assert_raise(IndexError) { a.bitfield(-1..0) }
    assert_raise(IndexError) { a.bitfield(0..16) }
    assert_raise(IndexError) { a.bitfield([nil,2]) }
    assert_nothing_raised    { a.bitfield([nil,1]) }
  end

  
end
