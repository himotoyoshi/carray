$:.unshift("../lib", "..")

require 'test/unit'
require 'carray'

class TestCArrayCAMapping < Test::Unit::TestCase

  def test_virtual_array
    a = CArray.int(3,3)
    idx = CArray.int(3,3).seq!
    b = a[idx]
    r = b.parent
    assert_instance_of(CAMapping, b)
    assert_equal(true, b.virtual?)
    assert_equal(a, r)
  end

  def test_basic_features
    # ---
    a   = CArray.int(3,3).seq!
    idx = CArray.int(3,3) { 4 }
    assert_equal(CA_INT([[4,4,4],
                         [4,4,4],
                         [4,4,4]]), a[idx])
    # ---
    a   = CArray.int(3,3).seq!
    idx = CArray.int(3,3).seq!.reverse!
    assert_equal(CA_INT([[8,7,6],
                         [5,4,3],
                         [2,1,0]]), a[idx])
    a[idx].seq!
    assert_equal(CA_INT([[8,7,6],
                         [5,4,3],
                         [2,1,0]]), a)
  end

  def test_invalid_args
    # ---
    a   = CArray.int(3,3).seq!
    idx = CArray.int(3,3) { 4 }
    idx[1,1] = UNDEF
    assert_raise(ArgumentError) { a[idx] }
  end

  def test_out_of_range
    # ---
    a = CArray.int(3,3).seq!
    idx = CArray.int(3,3) { 9 }
    assert_raise(IndexError) { a[idx] }

    # ---
    a = CArray.int(3,3).seq!
    idx = CArray.int(3,3) { -1 }
    assert_equal(CA_INT([[8,8,8],
                         [8,8,8],
                         [8,8,8]]), a[idx])
  end

  def test_mask
    _ = UNDEF
    # ---
    a = CArray.int(3,3).seq!
    idx = CArray.int(3,3).seq!
    a[1,1] = UNDEF
    assert_equal(CA_INT([[0,1,2],
                         [3,_,5],
                         [6,7,8]]), a[idx])
    a[idx][1,1] = -1
    assert_equal(CA_INT([[0,1,2],
                         [3,-1,5],
                         [6,7,8]]), a)
  end

  def test_fill
    _ = UNDEF
    # ---
    a = CArray.int(3,3).seq!
    idx = CArray.int(3,3).seq!
    a[idx] = 9
    assert_equal(CA_INT([[9,9,9],
                         [9,9,9],
                         [9,9,9]]), a)
    a[idx] = UNDEF
    assert_equal(CA_INT([[_,_,_],
                         [_,_,_],
                         [_,_,_]]), a)
  end

  def test_sync
    # ---
    a   = CArray.int(3,3).seq!
    idx = CArray.int(3,3) { 4 }
    a[idx] = -1                     ### not recomended usage
    assert_equal(CA_INT([[0,1,2],
                         [3,-1,5],
                         [6,7,8]]), a)
    # ---
    a   = CArray.int(3,3).seq!
    idx = CArray.int(3,3) { 4 }
    a[idx].seq!                     ### not recomended usage
    assert_equal(CA_INT([[0,1,2],
                         [3,8,5],
                         [6,7,8]]), a)
  end

end