require "carray"
require 'rspec-power_assert'

describe "CArray#span" do

  # 2020-07-10
  example "integer range (integer steps)" do

    a = CArray.int(10).span(1..10)
    
    is_asserted_by { a == CA_INT([1,2,3,4,5,6,7,8,9,10]) }

    b = CArray.int(10).span(1...11)
    
    is_asserted_by { b == CA_INT([1,2,3,4,5,6,7,8,9,10]) }

  end

  # 2020-07-10
  example "integer range (fraction steps)" do

    a = CArray.int(10).span(1..5)
    
    is_asserted_by { a == CA_INT([1,1,2,2,3,3,4,4,5,5]) }

    b = CArray.int(10).span(1...6)
    
    is_asserted_by { b == CA_INT([1,1,2,2,3,3,4,4,5,5]) }

  end

  # 2020-07-10
  example "float range" do

    a = CArray.double(11).span(0..5)
    
    is_asserted_by { a == CA_DOUBLE([0.0,0.5,1.0,1.5,2.0,2.5,3.0,3.5,4.0,4.5,5.0]) }

  end
  
end
  