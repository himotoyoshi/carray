#$:.unshift("../lib", "..")

require 'test/unit'
require 'carray'

class TestCArray < Test::Unit::TestCase

  def test_conversion
    assert_equal(CA_INT32(1), CScalar.int32{1})
    assert_equal(CA_INT32([1]), CArray.int32(1){[1]})
    assert_equal(CA_INT32([[0,1],[2,3]]), CArray.int32(2,2).seq!)
    assert_raise(TypeError) { CA_INT32([1,[1,2]]) }
  end

  def test_s_span
    a = CArray.span(CA_FLOAT32, 0..2, 0.5)
    assert_equal(a, CA_FLOAT32([0,0.5,1,1.5,2]))
    a = CArray.span(CA_FLOAT32, 0...2, 0.5)
    assert_equal(a, CA_FLOAT32([0,0.5,1,1.5]))
  end

  def test_wrap_readonly
    a = CArray.wrap_readonly([[1,2,3],[4,5,6],[7,8,9]], CA_INT32)
    assert_equal(CA_INT32([[1,2,3],[4,5,6],[7,8,9]]), a)
  end

  def test_compact
    a = CArray.int(4,1,3,1,2,1).seq!
    b = CArray.int(4,3,2).seq!
    
    assert_equal(b, a.compacted)
    assert_equal(CARefer, a.compacted.class)
    assert_equal(b, a.compact)
    assert_equal(CArray, a.compact.class)
  end

  def test_to_a
    # ---
    a = CArray.int(3).seq!
    assert_equal([ 0,1,2 ], a.to_a)

    # ---
    a = CArray.int(3,3).seq!
    assert_equal([ [0,1,2], [3,4,5], [6,7,8] ], a.to_a)
  end

  def test_convert
    # ---
    a = CArray.int(3).seq!
    if RUBY_VERSION >= "1.9.0"
      b = a.convert(CA_OBJECT) {|x| (x+"a".ord).chr }
    else  
      b = a.convert(CA_OBJECT) {|x| (x+?a).chr }
    end 
    assert_equal(CA_OBJECT(["a","b","c"]), b)
  end 

  def test_map
    # ---
    a = CArray.int(3).seq!
    if RUBY_VERSION >="1.9.0"
      b = a.map {|x| (x+"a".ord).chr }
    else
      b = a.map {|x| (x+?a).chr }
    end
    assert_equal([ "a","b","c" ], b)

    # ---
    a = CArray.int(3,3).seq!
    if RUBY_VERSION >= "1.9.0"
      b = a.map {|x| (x+"a".ord).chr }
    else
      b = a.map {|x| (x+?a).chr }
    end
    assert_equal([ ["a","b","c"], ["d","e","f"], ["g","h","i"] ], b)
  end

  
end
