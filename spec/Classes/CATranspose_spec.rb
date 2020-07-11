
require 'carray'
require "rspec-power_assert"

describe "TestCArrayCATranspose " do

  example "virtual_array" do
    a = CArray.int(3,3)
    b = a.transposed
    r = b.parent
    is_asserted_by { b.class == CATranspose }
    is_asserted_by { true == b.virtual? }
    is_asserted_by { a == r }
  end

  example "basic_feature" do
    # ---
    a = CArray.int(3,3).seq!
    t = a.transposed
    is_asserted_by { CA_INT([[0,3,6],
                         [1,4,7],
                         [2,5,8]]) == t }

    # ---
    a = CArray.int(2,2,2).seq!
    t1 = a.transposed(0,1,2)
    t2 = a.transposed(0,2,1) # 1 <-> 2
    t3 = a.transposed(2,1,0) # 0 <-> 2
    t4 = a.transposed(1,0,2) # 0 <-> 1
    is_asserted_by { CA_INT([[[0,1],
                          [2,3]],
                         [[4,5],
                          [6,7]]]) == t1 }
    is_asserted_by { CA_INT([[[0,2],
                          [1,3]],
                         [[4,6],
                          [5,7]]]) == t2 }
    is_asserted_by { CA_INT([[[0,4],
                          [2,6]],
                         [[1,5],
                          [3,7]]]) == t3 }
    is_asserted_by { CA_INT([[[0,1],
                          [4,5]],
                         [[2,3],
                          [6,7]]]) == t4 }

    # ---
    a = CArray.int(2,2,2).seq!

    x1 = a.transposed(1,2,0) # 0 -> 2, 1 -> 0, 2 -> 1
    y1 = a.transposed(2,1,0).transposed(1,0,2) # 1 <-> 2; 0 <-> 1
    is_asserted_by { y1 == x1 }

    x2 = a.transposed(2,0,1) # 0 -> 1, 1 -> 2, 2 -> 0
    y2 = a.transposed(2,1,0).transposed(0,2,1) # 0 <-> 2; 1 <-> 2
    is_asserted_by { y2 == x2 }

  end

end
