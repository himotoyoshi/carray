$:.unshift("../lib", "..")

require 'test/unit'
require 'carray'

class TestCArrayCAGrid < Test::Unit::TestCase

  def test_virtual_array
    a = CArray.int(3,3)
    i = CArray.int(3).seq
    b = a[i, 0..1]
    r = b.parent
    assert_instance_of(CAGrid, b)
    assert_equal(true, b.virtual?)
    assert_equal(a, r)
  end

  def test_basic_features
    # ---
    a = CArray.int(3,3).seq
    i = CA_INT([1,2,0])
    assert_equal(CA_INT([[3,4,5],
                         [6,7,8],
                         [0,1,2]]), a[i,nil])
    assert_equal(CA_INT([[1,2,0],
                         [4,5,3],
                         [7,8,6]]), a[nil,i])
    assert_equal(CA_INT([[4,5,3],
                         [7,8,6],
                         [1,2,0]]), a[i,i])
    # ---
    a = CArray.int(3,3).seq
    i = CA_INT([-1,-2,-3])
    assert_equal(CA_INT([[6,7,8],
                         [3,4,5],
                         [0,1,2]]), a[i,nil])
    assert_equal(CA_INT([[2,1,0],
                         [5,4,3],
                         [8,7,6]]), a[nil,i])
    assert_equal(CA_INT([[8,7,6],
                         [5,4,3],
                         [2,1,0]]), a[i,i])
  end

  def test_invalid_args
    # ---
    a = CArray.int(3,3).seq
    i = CA_INT([0,1,2])
    assert_raise(ArgumentError) { a.grid(i) }

    # ---
    a = CArray.int(3,3).seq
    i = CA_INT([0,1,2])
    i[0] = UNDEF
    assert_equal(CA_INT([[3,4,5],[6,7,8]]), a.grid(i, nil))

    # ---
    a = CArray.int(3,3).seq
    i = CA_INT([])
    assert_equal(CArray.int(0,3), a.grid(i, nil))
    assert_equal(CArray.int(3,0), a.grid(nil, i))
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
