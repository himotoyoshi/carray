$:.unshift("../lib", "..")

require 'test/unit'
require 'carray'

class TestCArrayRefStore < Test::Unit::TestCase

  def test_access_point
    # ---
    a = CArray.int(3,3).seq!
    assert_equal(0, a[0,0])
    assert_equal(4, a[1,1])
    assert_equal(8, a[-1,-1])
    assert_raise(IndexError) { a[0,3] }
    assert_raise(IndexError) { a[-4,0] }

    # ---
    a = CArray.int(3,3).seq!
    a[0,0] = -1
    a[1,1] = -2
    a[-1,-1] = -3
    assert_equal(-1, a[0,0])
    assert_equal(-2, a[1,1])
    assert_equal(-3, a[-1,-1])
    assert_raise(IndexError) { a[0,3] = -4 }
    assert_raise(IndexError) { a[-4,0] = -5 }
  end

  def test_access_block
    # ---
    a = CArray.int(3,3).seq!
    assert_equal(CA_INT([1, 4, 7]), a[0..-1,1])
    assert_equal(CA_INT([[1], [4], [7]]), a[0..-1,[1]])
    assert_equal(CABlock, a[0..2,0..2].class)
    assert_equal(a, a[0..2,0..2])
    assert_equal(CABlock, a[nil,nil].class)
    assert_equal(a, a[nil,nil])
    assert_equal(a, a[-3..-1,-3..-1])
    assert_equal(CA_INT([[0,1,2],[3,4,5]]), a[0..1, nil])
    assert_equal(CA_INT([[0,2],[3,5]]), a[0..1, [nil,2]])
    assert_raise(IndexError) { a[0,0..3] }
    assert_raise(IndexError) { a[-4..-1,0] }
    assert_raise(IndexError) { a[0,[0,3,2]] }
    assert_raise(IndexError) { a[0,[0,4]] }

    # ---
    a = CArray.int(3,3).seq!
    assert_equal(CA_INT([[0,1,2], [3,4,5], [6,7,8]]), a)

    # ---
    a = CArray.int(3,3).seq!
    a[0..-1, 1] = 9
    assert_equal(CA_INT([[0,9,2], [3,9,5], [6,9,8]]), a)

    # ---
    a = CArray.int(3,3).seq!
    a[0..-1, [1]] = 9
    assert_equal(CA_INT([[0,9,2], [3,9,5], [6,9,8]]), a)

    # ---
    a = CArray.int(3,3).seq!
    a[nil, nil] = 9
    assert_equal(CA_INT([[9,9,9], [9,9,9], [9,9,9]]), a)

    # ---
    a = CArray.int(3,3).seq!
    a[0..1, [nil,2]] = 9
    assert_equal(CA_INT([[9,1,9], [9,4,9], [6,7,8]]), a)

    # ---
    a = CArray.int(3,3).seq!
    assert_raise(IndexError) { a[0,0..3] = -3 }
    assert_raise(IndexError) { a[-4..-1,0] = -4 }
    assert_raise(IndexError) { a[0,[0,3,2]] = -5 }
    assert_raise(IndexError) { a[0,[0,4]] = -6 }

  end

  def test_access_selection
    # ---
    a = CArray.int(3,3).seq!;
    assert_equal(CA_INT([0,1,2,3,4]), a[a < 5])

    # ---
    a = CArray.int(3,3).seq!
    a[a < 5] = 1
    assert_equal(CA_INT([[1,1,1],[1,1,5],[6,7,8]]), a)
  end

#  def test_access_mapping
#    # ---
#    a = CArray.int(3,3).seq!;
#    m = a.shuffle
#    assert_equal(10*m, (10*a)[m])

    # ---
#    a = CArray.int(3,3).seq!
#    b = 10*a
#    m = a.shuffle
#    a[m] = (10*m)
#    assert_equal(b, a)
#  end

  def test_access_grid
    # ---
    a = CArray.int(3,3).seq!;
    assert_equal(CA_INT([[1,2],[4,5]]), a[CA_INT([0,1]),1..2])
    assert_equal(CA_INT([[0,2],[6,8]]), a[+[0,2],+[0,2]])

    # ---
    a = CArray.int(3,3).seq!
    a[+[0,2],+[0,2]] = 9
    assert_equal(CA_INT([[9,1,9], [3,4,5], [9,7,9]]), a)
  end

  def test_access_repeat
    # ---
    # See test_CARepeat
  end

  def test_access_method
    # ---
    a = CArray.int(3,3).seq!
    assert_equal(CA_INT([0,1,2,3,4]), a[:lt, 5])

    # ---
    a = CArray.int(3,3).seq!
    a[:lt,5] = 1
    assert_equal(CA_INT([[1,1,1],[1,1,5],[6,7,8]]), a)
  end

  def test_access_address
    # ---
    a = CArray.int(3,3).seq!
    assert_equal(0, a[0])
    assert_equal(4, a[4])
    assert_equal(8, a[-1])
    assert_raise(IndexError) { a[9] }
    assert_raise(IndexError) { a[-10] }

    # ---
    a = CArray.int(3,3).seq!
    a[0] = -1
    a[4] = -2
    a[-1] = -3
    assert_equal(-1, a[0,0])
    assert_equal(-2, a[1,1])
    assert_equal(-3, a[-1,-1])
    assert_raise(IndexError) { a[9] = -4 }
    assert_raise(IndexError) { a[-10] = -5 }
  end

  def test_access_address_block
    # ---
    a = CArray.int(3,3).seq!
    assert_equal(CA_INT([4]), a[[4]])
    assert_equal(CA_INT([0,1,2,3]), a[[0..3]])
    assert_equal(CARefer, a[nil].class)
    assert_equal(CA_INT([0,1,2,3,4,5,6,7,8]), a[nil])
    assert_raise(IndexError) { a[0..9] }
    assert_raise(IndexError) { a[-10..-1] }

    # ---
    a = CArray.int(3,3).seq!
    assert_equal(CA_INT([[0,1,2], [3,4,5], [6,7,8]]), a)

    # ---
    a = CArray.int(3,3).seq!
    a[[1..-1,3]] = 9
    assert_equal(CA_INT([[0,9,2], [3,9,5], [6,9,8]]), a)

    # ---
    a = CArray.int(3,3).seq!
    a[[1,3,3]] = 9
    assert_equal(CA_INT([[0,9,2], [3,9,5], [6,9,8]]), a)

    # ---
    a = CArray.int(3,3).seq!
    a[nil] = 9
    assert_equal(CA_INT([[9,9,9], [9,9,9], [9,9,9]]), a)

    # ---
    a = CArray.int(3,3).seq!
    assert_raise(IndexError) { a[0..9] = -3 }
    assert_raise(IndexError) { a[-10..-1] = -4 }
  end

  def test_access_address_selection
    # ---
    a = CArray.int(3,3).seq!;
    a1 = a.flatten
    assert_equal(CA_INT([0,1,2,3,4]), a[a1 < 5])

    # ---
    a = CArray.int(3,3).seq!
    a[a1 < 5] = 1
    assert_equal(CA_INT([[1,1,1],[1,1,5],[6,7,8]]), a)
  end

  def test_access_address_grid
    # ---
    a = CArray.int(3,3).seq!;
    assert_equal(CA_INT([0,2,4,6,8]), a[+[0,2,4,6,8]])

    # ---
    a = CArray.int(3,3).seq!
    a[+[0,2,4,6,8]] = 9
    assert_equal(CA_INT([[9,1,9],[3,9,5],[9,7,9]]), a)
  end

end
