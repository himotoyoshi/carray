require "carray"
require 'rspec-power_assert'

describe "CArray#seq" do
  
  example "basic" do
    res = CA_INT32([[0, 1, 2],
                    [3, 4, 5],
                    [6, 7, 8]])
    a = CArray.int32(3, 3)
    is_asserted_by { a.seq(0,1) == res }
    is_asserted_by { a.seq(0) == res }
    is_asserted_by { a.seq() == res }
  end

  example "offset" do
    res = CA_INT32([[3, 4, 5],
                    [6, 7, 8],
                    [9, 10, 11]])
    a = CArray.int32(3, 3)
    is_asserted_by { a.seq(3,1) == res }
    is_asserted_by { a.seq(3) == res }
  end

  example "step" do
    res = CA_INT32([[0, 3, 6],
                    [9, 12, 15],
                    [18, 21, 24]])
    a = CArray.int32(3, 3)
    is_asserted_by { a.seq(0,3) == res }
  end

  example "fractional step for integer" do
    res = CA_INT32([0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5])
    a = CArray.int32(11)
    is_asserted_by { a.seq(0,0.5) == res }

    res = CA_INT32([0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 2])
    a = CArray.int32(11)
    is_asserted_by { a.seq(0,0.2) == res }

    res = CA_INT32([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
    a = CArray.int32(11)
    is_asserted_by { a.seq(0,0.1) == res }
  end

end