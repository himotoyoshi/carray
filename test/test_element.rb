$:.unshift("../lib", "..")

require 'test/unit'
require 'carray'

class TestCArrayElement < Test::Unit::TestCase

  def test_set_unset
    #
    a = CArray.boolean(3,3) {0}
    a.set(1,1)
    assert_equal(CA_BOOLEAN([[0,0,0],[0,1,0],[0,0,0]]), a)

    #
    a = CArray.boolean(3,3) {0}
    a.set(4)
    assert_equal(CA_BOOLEAN([[0,0,0],[0,1,0],[0,0,0]]), a)

    #
    a = CArray.boolean(3,3) {1}
    a.unset(1,1)
    assert_equal(CA_BOOLEAN([[1,1,1],[1,0,1],[1,1,1]]), a)

    #
    a = CArray.boolean(3,3) {1}
    a.unset(4)
    assert_equal(CA_BOOLEAN([[1,1,1],[1,0,1],[1,1,1]]), a)
  end

  def test_elem_swap
    #
    a = CArray.int(3,3).seq!
    a.elem_swap([1,1], [-1,-1])
    assert_equal(8, a[1,1])
    assert_equal(4, a[-1,-1])

    #
    a = CArray.int(3,3).seq!
    a[1,1] = UNDEF
    a.elem_swap([1,1], [-1,-1])
    assert_equal(8, a[1,1])
    assert_equal(UNDEF, a[-1,-1])

    #
    a = CArray.int(3,3).seq!
    a.elem_swap(0, -1)
    assert_equal(8, a[0, 0])
    assert_equal(0, a[-1,-1])

    #
    a = CArray.int(3,3).seq!
    a[0,0] = UNDEF
    a.elem_swap(0, -1)
    assert_equal(8, a[0, 0])
    assert_equal(UNDEF, a[-1,-1])

  end

  def test_elem_copy
    #
    a = CArray.int(3,3).seq!
    a.elem_copy([1,1], [-1,-1])
    assert_equal(4, a[1,1])
    assert_equal(4, a[-1,-1])

    #
    a = CArray.int(3,3).seq!
    a[1,1] = UNDEF
    a.elem_copy([1,1], [-1,-1])
    assert_equal(UNDEF, a[1,1])
    assert_equal(UNDEF, a[-1,-1])

    #
    a = CArray.int(3,3).seq!
    a.elem_copy(0, -1)
    assert_equal(0, a[0, 0])
    assert_equal(0, a[-1,-1])

    #
    a = CArray.int(3,3).seq!
    a[0,0] = UNDEF
    a.elem_copy(0, -1)
    assert_equal(UNDEF, a[0, 0])
    assert_equal(UNDEF, a[-1,-1])

  end

  def test_elem_fetch
    #
    a = CArray.int(3,3).seq!
    assert_equal(4, a.elem_fetch([1,1]))
    a[1,1] = UNDEF
    assert_equal(UNDEF, a.elem_fetch([1,1]))

    #
    a = CArray.int(3,3).seq!
    assert_equal(4, a.elem_fetch(4))
    a[1,1] = UNDEF
    assert_equal(UNDEF, a.elem_fetch(4))
  end

  def test_elem_store
    #
    a = CArray.int(3,3).seq!
    a.elem_store([1,1], -4)
    assert_equal(-4, a.elem_fetch([1,1]))
    a.elem_store([1,1], UNDEF)
    assert_equal(UNDEF, a.elem_fetch([1,1]))

    #
    a = CArray.int(3,3).seq!
    a.elem_store(4, -4)
    assert_equal(-4, a.elem_fetch(4))
    a.elem_store(4, UNDEF)
    assert_equal(UNDEF, a.elem_fetch(4))
  end

  def test_elem_incr_decr
    #
    a = CArray.int(3,3).seq!
    a.elem_incr([1,1])
    assert_equal(5, a.elem_fetch([1,1]))
    a.elem_decr([1,1])
    assert_equal(4, a.elem_fetch([1,1]))

    #
    a = CArray.int(3,3).seq!
    a.elem_incr(4)
    assert_equal(5, a.elem_fetch(4))
    a.elem_decr(4)
    assert_equal(4, a.elem_fetch(4))
  end

  def test_elem_incr_255
    #
    a = CArray.uint8(1) {255}
    a.elem_incr(0)
    assert_equal(0, a.elem_fetch(0))

    #
    a = CArray.int8(1) {127}
    a.elem_incr(0)
    assert_equal(-128, a.elem_fetch(0))
  end

end
