$:.unshift("../lib", "..")

require 'test/unit'
require 'carray'

class TestCArrayCAWindow < Test::Unit::TestCase

  def test_virtual_array
    a = CArray.int(3,3).seq!
    b = a.window(-1..1, -1..1)
    r = b.parent
    assert_instance_of(CAWindow, b)
    assert_equal(true, b.virtual?)
    assert_equal(a, r)
  end


  def test_basic_features
    # ---
    a = CArray.int(3,3).seq!
    b = a.window(-1..1, -1..1)
    assert_equal(CA_INT([[0,0,0],
                         [0,0,1],
                         [0,3,4]]), b)

    # ---
    a = CArray.int(3,3).seq!
    b = a.window(-1..1, -1..1) { UNDEF}
    _ = UNDEF
    assert_equal(CA_INT([[_,_,_],
                         [_,0,1],
                         [_,3,4]]), b)
  end

  def test_invalid_args
    # ---
    a = CArray.int(3,3).seq
    assert_raise(ArgumentError) { a.window(1) }
    assert_raise(ArgumentError) { a.window([nil]) }
    assert_raise(ArgumentError) { a.window(nil, [nil,2]) }
    assert_raise(ArgumentError) { a.window(1..-1, nil) }
  end

  def test_out_of_index
    # ---
    a = CArray.int(3,3).seq
    i1 = CA_INT([1,2,3])
    i2 = CA_INT([-4,-3,-2])
    assert_raise(IndexError) { a[i1,nil] }
    assert_raise(IndexError) { a[nil,i1] }
    assert_raise(IndexError) { a[i2,nil] }
    assert_raise(IndexError) { a[nil,i2] }
  end

end
