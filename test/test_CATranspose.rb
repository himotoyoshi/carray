$:.unshift("../lib", "..")

require 'test/unit'
require 'carray'

class TestCArrayCATranspose < Test::Unit::TestCase

  def test_virtual_array
    a = CArray.int(3,3)
    b = a.transposed
    r = b.parent
    assert_instance_of(CATranspose, b)
    assert_equal(true, b.virtual?)
    assert_equal(a, r)
  end

  def test_basic_feature
    # ---
    a = CArray.int(3,3).seq!
    t = a.transposed
    assert_equal(CA_INT([[0,3,6],
                         [1,4,7],
                         [2,5,8]]), t)

    # ---
    a = CArray.int(2,2,2).seq!
    t1 = a.transposed(0,1,2)
    t2 = a.transposed(0,2,1) # 1 <-> 2
    t3 = a.transposed(2,1,0) # 0 <-> 2
    t4 = a.transposed(1,0,2) # 0 <-> 1
    assert_equal(CA_INT([[[0,1],
                          [2,3]],
                         [[4,5],
                          [6,7]]]), t1)
    assert_equal(CA_INT([[[0,2],
                          [1,3]],
                         [[4,6],
                          [5,7]]]), t2)
    assert_equal(CA_INT([[[0,4],
                          [2,6]],
                         [[1,5],
                          [3,7]]]), t3)
    assert_equal(CA_INT([[[0,1],
                          [4,5]],
                         [[2,3],
                          [6,7]]]), t4)

    # ---
    a = CArray.int(2,2,2).seq!

    x1 = a.transposed(1,2,0) # 0 -> 2, 1 -> 0, 2 -> 1
    y1 = a.transposed(2,1,0).transposed(1,0,2) # 1 <-> 2; 0 <-> 1
    assert_equal(y1, x1)

    x2 = a.transposed(2,0,1) # 0 -> 1, 1 -> 2, 2 -> 0
    y2 = a.transposed(2,1,0).transposed(0,2,1) # 0 <-> 2; 1 <-> 2
    assert_equal(y2, x2)

  end

end