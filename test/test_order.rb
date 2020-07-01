$:.unshift("../lib", "..")

require 'test/unit'
require 'carray'

class TestCArrayOrder < Test::Unit::TestCase

  def test_where
    # ---
    a = CArray.int(3,3).seq!
    c = (a % 2).eq(0)
    assert_equal(a[c], c.where.int)
  end

  def test_index
    # ---
    a = CArray.float(3,3).seq!
    assert_equal(CA_INT32([[0,1,2],
                           [3,4,5],
                           [6,7,8]]), a.address)
    assert_equal(CA_INT32([0,1,2]), a.index(0))
    assert_equal(CA_INT32([0,1,2]), a.index(1))
  end

  def test_indices
    # ---
    a = CArray.float(3,3).seq!
    a.indices {|x, y|
      assert_equal(CA_INT32([[0,0,0],
                             [1,1,1],
                             [2,2,2]]), x)
      assert_equal(CA_INT32([[0,1,2],
                             [0,1,2],
                             [0,1,2]]), y)
    }
  end

  def test_reverse
    a = CArray.int32(3,3).seq!
    b = CArray.int32(3,3).seq!(8,-1)

    # ---
    assert_equal(b, a.reverse)
    assert_equal(b, a.reversed)

    c = a.to_ca.reverse!
    assert_equal(b, c)
  end

  def test_sort
    a = CA_INT32([[5,4,3],
                  [0,1,2],
                  [8,7,6]])
    s = CA_INT32([[0,1,2],
                  [3,4,5],
                  [6,7,8]])
    # ---
    assert_equal(s, a.sort)
    b = a.to_ca
    b.sort!
    assert_equal(s, b)
  end

  def test_sort_addr
    a = CA_INT32([[5,4,3],
                  [0,1,2],
                  [8,7,6]])
    # ---
    assert_equal(CA_SIZE([[3,4,5],
                           [2,1,0],
                           [8,7,6]]), a.sort_addr)
    assert_equal(CA_INT32([[5,4,3],
                           [0,1,2],
                           [8,7,6]]), a.order)
    # ---
    assert_equal(CA_SIZE([[6,7,8],
                           [0,1,2],
                           [5,4,3]]), a.sort_addr.reverse)
    assert_equal(CA_INT32([[3,4,5],
                           [8,7,6],
                           [0,1,2]]), a.order(-1))
  end

#  def test_uniq
#    a = CArray.int(100).random!(10)
#
#    # ---
#    assert_equal(a.to_a.uniq, a.uniq.to_a)
#
#  end

  def test_search
    # ---
    a = CArray.int(9,9).seq!
    assert_equal(50, a.bsearch(50))
    assert_equal(50, a.search(50))
    assert_equal([5,5], a.bsearch_index(50))
    assert_equal([5,5], a.search_index(50))
    # ---
    a = CArray.int(9,9).seq!(0,2)
    assert_equal(nil, a.bsearch(51))
    assert_equal(nil, a.search(51))
    assert_equal(nil, a.bsearch_index(51))
    assert_equal(nil, a.search_index(51))
    # ---
    a = CArray.float(9,9).span!(0..80)
    assert_equal(50, a.bsearch(50))
    assert_equal(50, a.search(50))
    assert_equal([5,5], a.bsearch_index(50))
    assert_equal([5,5], a.search_index(50))

    assert_equal(nil, a.bsearch(50.0001))
    assert_equal(nil, a.search(50.0001))
    assert_equal(nil, a.bsearch_index(50.0001))
    assert_equal(nil, a.search_index(50.0001))
    # ---
    a = CArray.float(9,9).span!(0..80)    
    assert_equal(50, a.search(50.0001, 0.0001))
    assert_equal([5,5], a.search_index(50.0001, 0.0001))    

    assert_equal(nil, a.search(50.0001, 0.00001))
    assert_equal(nil, a.search_index(50.0001, 0.00001))   
  end
  
  def test_search_nearest   
    # ---
    a = CArray.int(9,9).seq!
    assert_equal(50, a.search_nearest(50))
    assert_equal([5,5], a.search_nearest_index(50))
    # ---
    a = CArray.int(9,9).seq!(0,2)
    assert_equal(25, a.search_nearest(51))
    assert_equal([2,7], a.search_nearest_index(51))
    # ---
    a = CArray.float(9,9).span!(0..80)
    assert_equal(50, a.search_nearest(50))
    assert_equal([5,5], a.search_nearest_index(50))

    assert_equal(50, a.search_nearest(50.5))
    assert_equal([5,5], a.search_nearest_index(50.5))

    # first detected
    assert_equal(49, a.search_nearest(49.5))
    assert_equal([5,4], a.search_nearest_index(49.5))
    
  end
end
