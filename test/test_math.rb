$:.unshift("../lib", "..")

require 'test/unit'
require 'carray'

class TestMath < Test::Unit::TestCase

  def test_zerodiv
    zero = CArray.int(3,3) { 0 }
    one  = CArray.int(3,3) { 1 }
    assert_raise(ZeroDivisionError) { 1/zero }
    assert_raise(ZeroDivisionError) { one/zero } # div, div!
    assert_raise(ZeroDivisionError) { one/0 }
    assert_raise(ZeroDivisionError) { one/zero }
    assert_raise(ZeroDivisionError) { one % 0 }  # mod, mod!
    assert_raise(ZeroDivisionError) { one % zero }
    assert_raise(ZeroDivisionError) { zero.rcp } # rcp!
    assert_raise(ZeroDivisionError) { zero.rcp_mul(1) } # rcp_mul!
    assert_raise(ZeroDivisionError) { zero.rcp_mul(one) }
    assert_raise(ZeroDivisionError) { 0 ** (-one) } # pow, pow!
    assert_raise(ZeroDivisionError) { zero ** (-one) }
  end

  def test_cmp
    a = CA_INT([0,1,2,3,4])
    b = CA_INT([4,3,2,1,0])

    # ---
    assert_equal(CA_INT8([-1,-1,0,1,1]), a <=> 2)
    assert_equal(CA_INT8([1,1,0,-1,-1]), 2 <=> a)
    assert_equal(CA_INT8([-1,-1,0,1,1]), a <=> b)
  end

  def test_bit_op
    a = CArray.int(10).seq!

    # ---
    assert_equal(a.convert{|x| ~x}, ~a)

    assert_equal(a.convert{|x| x & 1}, a & 1)
    assert_equal(a & 1, 1 & a)

    assert_equal(a.convert{|x| x | 1}, a | 1)
    assert_equal(a | 1, 1 | a)

    assert_equal(a.convert{|x| x ^ 1}, a ^ 1)
    assert_equal(a ^ 1, 1 ^ a)

    # ---
    assert_equal(a.convert{|x| x << 1}, a << 1)
    assert_equal(a.convert{|x| 1 << x}, 1 << a)

    assert_equal(a.convert{|x| x >> 1}, a >> 1)
    assert_equal(a.convert{|x| 1 >> x}, 1 >> a)
  end

  def test_max_min
    a = CArray.int(3,3).seq!
    b = a.reverse

    # ---
    assert_equal(CA_INT32([[8,7,6],
                           [5,4,5],
                           [6,7,8]]), a.pmax(b))
    assert_equal(CA_INT32([[0,1,2],
                           [3,4,3],
                           [2,1,0]]), a.pmin(b))
    # ---
    assert_equal(CA_INT32([[0,0,0],
                           [0,0,0],
                           [0,0,0]]), a.pmin(0))
    assert_equal(CA_INT32([[8,8,8],
                           [8,8,8],
                           [8,8,8]]), a.pmax(8))
    # ---
    assert_equal(CA_INT32([[0,0,0],
                           [0,0,0],
                           [0,0,0]]), CA_INT32(0).pmin(a))
    assert_equal(CA_INT32([[8,8,8],
                           [8,8,8],
                           [8,8,8]]), CA_INT32(8).pmax(a))
    # ---
    assert_equal(CA_INT32([[8,7,6],
                           [5,4,5],
                           [6,7,8]]), CAMath.max(a, b))
    assert_equal(CA_INT32([[0,1,2],
                           [3,4,3],
                           [2,1,0]]), CAMath.min(a, b))
    # ---
    assert_equal(CA_INT32([[0,0,0],
                           [0,0,0],
                           [0,0,0]]), CAMath.min(0,a,b,8))
    assert_equal(CA_INT32([[8,8,8],
                           [8,8,8],
                           [8,8,8]]), CAMath.max(0,a,b,8))
  end

end
