
require 'carray'
require "rspec-power_assert"

describe "TestCArrayOrder " do

  example "where" do
    # ---
    a = CArray.int(3,3).seq!
    c = (a % 2).eq(0)
    is_asserted_by { a[c] == c.where.int }
  end

  example "index" do
    # ---
    a = CArray.float(3,3).seq!
    is_asserted_by { CA_INT32([[0,1,2],
                               [3,4,5],
                               [6,7,8]]) == a.address }
    is_asserted_by { CA_INT32([0, 1, 2]) == a.index(0) }
    is_asserted_by { CA_INT32([0, 1, 2]) == a.index(1) }
  end

  example "indices" do
    # ---
    a = CArray.float(3,3).seq!
    a.indices {|x, y|
      is_asserted_by { CA_INT32([[0,0,0],
                                 [1,1,1],
                                 [2,2,2]]) == x }
      is_asserted_by { CA_INT32([[0,1,2],
                                 [0,1,2],
                                 [0,1,2]]) == y }
    }
  end

  example "reverse" do
    a = CArray.int32(3,3).seq!
    b = CArray.int32(3,3).seq!(8,-1)

    # ---
    is_asserted_by { b == a.reverse }
    is_asserted_by { b == a.reversed }

    c = a.to_ca.reverse!
    is_asserted_by { b == c }
  end

  example "sort" do
    a = CA_INT32([[5,4,3],
                  [0,1,2],
                  [8,7,6]])
    s = CA_INT32([[0,1,2],
                  [3,4,5],
                  [6,7,8]])
    # ---
    is_asserted_by { s == a.sort }
    b = a.to_ca
    b.sort!
    is_asserted_by { s == b }
  end

  example "sort_addr" do
    a = CA_INT32([[5,4,3],
                  [0,1,2],
                  [8,7,6]])
    # ---
    is_asserted_by { CA_SIZE([[3,4,5],
                              [2,1,0],
                              [8,7,6]]) == a.sort_addr }
    is_asserted_by { CA_INT32([[5,4,3],
                               [0,1,2],
                               [8,7,6]]) == a.order }
    # ---
    is_asserted_by { CA_SIZE([[6,7,8],
                              [0,1,2],
                              [5,4,3]]) == a.sort_addr.reverse }
    is_asserted_by { CA_INT32([[3,4,5],
                               [8,7,6],
                               [0,1,2]]) == a.order(-1) }
  end

#  example "uniq" do
#    a = CArray.int(100).random!(10)
#
#    # ---
#    is_asserted_by { a.to_a.uniq, a.uniq.to_a)
#
#  end

  example "search" do
    # ---
    a = CArray.int(9,9).seq!
    is_asserted_by { 50 == a.bsearch(50) }
    is_asserted_by { 50 == a.search(50) }
    is_asserted_by { [5, 5] == a.bsearch_index(50) }
    is_asserted_by { [5, 5] == a.search_index(50) }
    # ---
    a = CArray.int(9,9).seq!(0,2)
    is_asserted_by { nil == a.bsearch(51) }
    is_asserted_by { nil == a.search(51) }
    is_asserted_by { nil == a.bsearch_index(51) }
    is_asserted_by { nil == a.search_index(51) }
    # ---
    a = CArray.float(9,9).span!(0..80)
    is_asserted_by { 50 == a.bsearch(50) }
    is_asserted_by { 50 == a.search(50) }
    is_asserted_by { [5, 5] == a.bsearch_index(50) }
    is_asserted_by { [5, 5] == a.search_index(50) }

    is_asserted_by { nil == a.bsearch(50.0001) }
    is_asserted_by { nil == a.search(50.0001) }
    is_asserted_by { nil == a.bsearch_index(50.0001) }
    is_asserted_by { nil == a.search_index(50.0001) }
    # ---
    a = CArray.float(9,9).span!(0..80)    
    is_asserted_by { 50 == a.search(50.0001, 0.0001) }
    is_asserted_by { [5, 5] == a.search_index(50.0001, 0.0001) }

    is_asserted_by { nil == a.search(50.0001, 1.0e-05) }
    is_asserted_by { nil == a.search_index(50.0001, 1.0e-05) }
  end
  
  example "search_nearest   " do
    # ---
    a = CArray.int(9,9).seq!
    is_asserted_by { 50 == a.search_nearest(50) }
    is_asserted_by { [5, 5] == a.search_nearest_index(50) }
    # ---
    a = CArray.int(9,9).seq!(0,2)
    is_asserted_by { 25 == a.search_nearest(51) }
    is_asserted_by { [2, 7] == a.search_nearest_index(51) }
    # ---
    a = CArray.float(9,9).span!(0..80)
    is_asserted_by { 50 == a.search_nearest(50) }
    is_asserted_by { [5, 5] == a.search_nearest_index(50) }

    is_asserted_by { 50 == a.search_nearest(50.5) }
    is_asserted_by { [5, 5] == a.search_nearest_index(50.5) }

    # first detected
    is_asserted_by { 49 == a.search_nearest(49.5) }
    is_asserted_by { [5, 4] == a.search_nearest_index(49.5) }
    
  end
end
