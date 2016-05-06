$:.unshift("../lib", "..")

require 'test/unit'
require 'carray'

class TestCArrayCARefer < Test::Unit::TestCase

  def test_virtual_array
    a = CArray.int(3,3)
    b = a.refer(CA_INT,[9])
    r = b.parent
    assert_instance_of(CARefer, b)
    assert_equal(true, b.virtual?)
    assert_equal(a, r)
  end

  def test_basic_features
    # ---
    a = CArray.int(3,2).seq!
    r = a.reshape(2,3)
    assert_equal(a.data_type, r.data_type)
    assert_equal([2,3], r.dim)
    assert_equal(CA_INT([[0,1,2],
                         [3,4,5]]), r)

    # ---
    # less data number
    a = CArray.int(3,2).seq!
    r = a.reshape(2,2)
    assert_equal(CA_INT([[0,1],
                         [2,3]]), r)

    # ---
    # data type change (int -> float)
    a = CArray.int(3,2).seq!
    r = a.refer(CA_FLOAT32, [2,3])
    rr = r.refer(CA_INT32, [3,2])
    assert_equal(CA_FLOAT, r.data_type)
    assert_equal(a, rr)
  end

  def test_refer_to_virtual_array
    # ---
    a = CArray.int(3,3).seq!
    b = a[1..2,1..2]
    r = b.reshape(4)
    assert_equal(CA_INT([4,5,7,8]), r)

    # ---
    a = CArray.int(3).seq!
    b = a[:%,3]
    r = b.reshape(9)
    assert_equal(CA_INT([0,0,0,1,1,1,2,2,2]), r)

  end

  def test_invalid_args
    # ---
    a = CArray.int8(3,3).seq!
    assert_raise(RuntimeError) { a.reshape(10) } ### too large data num
    assert_raise(RuntimeError) { a.refer(CA_INT,[9]) }
                                                   ### larger data type bytes

  end

  def test_flatten
    a = CArray.int(3,3).seq!
    b = CArray.int(9).seq!

    # ---
    assert_equal(b, a.flatten)
    assert_equal(b, a.flattened)

    # ---
    c = a.reverse
    a.flattened.reverse!
    assert_equal(c, a)
  end

  def test_refer_variant
    a = CArray.fixlen(4, :bytes=>4) {"abcd"}
    b = CA_FIXLEN([["ab", "cd"],
                   ["ab", "cd"],
                   ["ab", "cd"],
                   ["ab", "cd"]], :bytes=>2)
    c = CA_FIXLEN(["abcdabcd", "abcdabcd"], :bytes=>8)

    # ---
    assert_equal(b, a.refer(CA_FIXLEN, [4,2], :bytes=>2))
    assert_equal(c, a.refer(CA_FIXLEN, [2], :bytes=>8))

  end

end
