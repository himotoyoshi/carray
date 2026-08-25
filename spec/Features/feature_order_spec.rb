
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
    # index(axis:) returns the open coordinate ramp: size on that axis,
    # 1 elsewhere.
    a = CArray.float(3,3).seq!
    is_asserted_by { CA_INT32([[0,1,2],
                               [3,4,5],
                               [6,7,8]]) == a.address }
    is_asserted_by { CA_INT32([[0],[1],[2]]) == a.index(axis: 0) }   # (3,1)
    is_asserted_by { CA_INT32([[0,1,2]])     == a.index(axis: 1) }   # (1,3)
  end

  example "indices" do
    # indices yields one open ramp per axis.
    a = CArray.float(3,3).seq!
    a.indices {|x, y|
      is_asserted_by { CA_INT32([[0],[1],[2]]) == x }   # (3,1)
      is_asserted_by { CA_INT32([[0,1,2]])     == y }   # (1,3)
    }
  end

  example "reverse" do
    a = CArray.int32(3,3).seq!
    b = CArray.int32(3,3).seq!(8,-1)

    # ---
    is_asserted_by { b == a.reverse }
    is_asserted_by { b == a.reverse }

    # 3.0: reverse! removed, use `ca[] = ca.reverse` idiom.
    c = a.to_ca
    c[] = c.reverse
    is_asserted_by { b == c }
  end

  example "sort" do
    a = CA_INT32([[5,4,3],
                  [0,1,2],
                  [8,7,6]])
    # SO.2 (3.0 breaking, PROPOSAL_SORT_AXIS rev3 §3.3 Q1(A)):
    # `a.sort` (no-arg) returns a CARemap 1-D view of flatten-then-sort.
    flat = CA_INT32([0,1,2,3,4,5,6,7,8])
    is_asserted_by { flat == a.sort }
    is_asserted_by { a.sort.class == CARemap }

    # 3.0: sort! removed.  Canonical in-place idiom for 2-D shape:
    #   `ca[] = ca.sort.reshape(*ca.dim)`
    s2d = CA_INT32([[0,1,2],
                    [3,4,5],
                    [6,7,8]])
    b = a.to_ca
    b[] = b.sort.reshape(*b.dim)
    is_asserted_by { s2d == b }
  end

  example "sort with axis" do
    a = CA_INT32([[5,4,3],
                  [0,1,2],
                  [8,7,6]])
    # Sort along axis 0 (columns).  Each column independently sorted.
    s_axis0 = CA_INT32([[0,1,2],
                        [5,4,3],
                        [8,7,6]])
    is_asserted_by { s_axis0 == a.sort(axis: 0) }

    # Sort along axis 1 (rows).  Each row independently sorted.
    s_axis1 = CA_INT32([[3,4,5],
                        [0,1,2],
                        [6,7,8]])
    is_asserted_by { s_axis1 == a.sort(axis: 1) }
    is_asserted_by { s_axis1 == a.sort(axis: -1) }
    is_asserted_by { a.sort(axis: 0).class == CARemap }
  end

  example "sort_addr" do
    a = CA_INT32([[5,4,3],
                  [0,1,2],
                  [8,7,6]])
    # ---
    is_asserted_by { CA_SIZE([[3,4,5],
                              [2,1,0],
                              [8,7,6]]) == a.sort_addr }
    is_asserted_by { CA_SIZE([[5,4,3],
                              [0,1,2],
                              [8,7,6]]) == a.order }
    # ---
    is_asserted_by { CA_SIZE([[6,7,8],
                              [0,1,2],
                              [5,4,3]]) == a.sort_addr.reverse }
    is_asserted_by { CA_SIZE([[3,4,5],
                              [8,7,6],
                              [0,1,2]]) == a.order(descending: true) }
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
    is_asserted_by { [5, 5] == a.addr2index(a.bsearch_addr(50)) }
    is_asserted_by { [5, 5] == a.addr2index(a.search_addr(50)) }
    # ---
    a = CArray.int(9,9).seq!(0,2)
    is_asserted_by { nil == a.bsearch(51) }
    is_asserted_by { nil == a.search(51) }
    # No-match: bsearch_addr / search_addr return nil directly; the
    # addr2index composition isn't applicable when there's no addr.
    is_asserted_by { nil == a.bsearch_addr(51) }
    is_asserted_by { nil == a.search_addr(51) }
    # ---
    a = CArray.float(9,9).span!(0..80)
    is_asserted_by { 50 == a.bsearch(50) }
    is_asserted_by { 50 == a.search(50) }
    is_asserted_by { [5, 5] == a.addr2index(a.bsearch_addr(50)) }
    is_asserted_by { [5, 5] == a.addr2index(a.search_addr(50)) }

    is_asserted_by { nil == a.bsearch(50.0001) }
    is_asserted_by { nil == a.search(50.0001) }
    is_asserted_by { nil == a.bsearch_addr(50.0001) }
    is_asserted_by { nil == a.search_addr(50.0001) }
    # ---
    a = CArray.float(9,9).span!(0..80)    
    is_asserted_by { 50 == a.search(50.0001, 0.0001) }
    is_asserted_by { [5, 5] == a.addr2index(a.search_addr(50.0001, 0.0001)) }

    is_asserted_by { nil == a.search(50.0001, 1.0e-05) }
    is_asserted_by { nil == a.search_addr(50.0001, 1.0e-05) }
  end
  
  example "search_nearest   " do
    # ---
    a = CArray.int(9,9).seq!
    is_asserted_by { 50 == a.search_nearest(50) }
    is_asserted_by { [5, 5] == a.addr2index(a.search_nearest_addr(50)) }
    # ---
    a = CArray.int(9,9).seq!(0,2)
    is_asserted_by { 25 == a.search_nearest(51) }
    is_asserted_by { [2, 7] == a.addr2index(a.search_nearest_addr(51)) }
    # ---
    a = CArray.float(9,9).span!(0..80)
    is_asserted_by { 50 == a.search_nearest(50) }
    is_asserted_by { [5, 5] == a.addr2index(a.search_nearest_addr(50)) }

    is_asserted_by { 50 == a.search_nearest(50.5) }
    is_asserted_by { [5, 5] == a.addr2index(a.search_nearest_addr(50.5)) }

    # first detected
    is_asserted_by { 49 == a.search_nearest(49.5) }
    is_asserted_by { [5, 4] == a.addr2index(a.search_nearest_addr(49.5)) }
    
  end
end
