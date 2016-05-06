$:.unshift("../lib", "..")

require 'test/unit'
require 'carray'

class TestBooleanType < Test::Unit::TestCase

  def test_boolean_bit_operations
    a = CArray.int(3,3).seq!
    e0 = a < 4
    e1 = a >= 4

    # ---
    assert_equal(e0, e0 & 1)
    assert_equal(e0, e0 & true)
    assert_equal(a.false, e0 & false)

    assert_equal(a.true, e0 | 1)
    assert_equal(a.true, e0 | true)
    assert_equal(e0, e0 | false)

    assert_equal(e1, e0 ^ 1)
    assert_equal(e1, e0 ^ true)
    assert_equal(e0, e0 ^ false)

    # ---
    assert_equal(e0, 1 & e0)
    assert_equal(e0, true & e0)
    assert_equal(a.false, false & e0)

    assert_equal(a.true, 1 | e0)
    assert_equal(a.true, true | e0)
    assert_equal(e0, false | e0)

    assert_equal(e1, 1 ^ e0)
    assert_equal(e1, true ^ e0)
    assert_equal(e0, false ^ e0)

  end

  def test_boolean_bit_operations2
    a = CArray.int(3,3).seq!
    e0 = a < 4
    e1 = a >= 4

    one  = a.one
    zero = a.zero
    tt   = a.true
    ff   = a.false

    # ---
    assert_equal(e0, e0 & one)
    assert_equal(e0, e0 & tt)
    assert_equal(ff, e0 & ff)

    assert_equal(tt, e0 | one)
    assert_equal(tt, e0 | tt)
    assert_equal(e0, e0 | ff)

    assert_equal(e1, e0 ^ one)
    assert_equal(e1, e0 ^ tt)
    assert_equal(e0, e0 ^ ff)

    # ---
    assert_equal(e0, one & e0)
    assert_equal(e0, tt & e0)
    assert_equal(ff, ff & e0)

    assert_equal(tt, one | e0)
    assert_equal(tt, tt | e0)
    assert_equal(e0, ff | e0)

    assert_equal(e1, one ^ e0)
    assert_equal(e1, tt ^ e0)
    assert_equal(e0, ff ^ e0)

  end

  def test_boolean_bit_operation_with_non_boolean_type

    a = CArray.int(3,3).seq!
    b = CArray.int(3,3).seq! + 1
    e0 = a < 4
    e1 = a >= 4

    # ---
    assert_raise(RuntimeError) { e0 & b }
    assert_raise(RuntimeError) { e0 | b }
    assert_raise(RuntimeError) { e0 ^ b }

    # ---
    assert_raise(RuntimeError) { b & e0 }
    assert_raise(RuntimeError) { b | e0 }
    assert_raise(RuntimeError) { b ^ e0 }

  end


end
