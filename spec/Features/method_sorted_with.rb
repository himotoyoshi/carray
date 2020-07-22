require "carray"
require 'rspec-power_assert'

describe "CArray#sorted_with" do

  # 2020-07-09
  example "basic" do
   
    a1 = CA_INT([3,2,4,1])
    b1 = CA_INT([13,12,14,11])
    c1 = CA_INT([23,22,24,21])
    
    a2,b2,c2 = a1.sorted_with(b1,c1)
    
    is_asserted_by { a2 == CA_INT([1,2,3,4]) }
    is_asserted_by { b2 == CA_INT([11,12,13,14]) }
    is_asserted_by { c2 == CA_INT([21,22,23,24]) }
    
    a2[0] = -999    
    b2[0] = -999    
    c2[0] = -999    
    is_asserted_by { a1[3] == -999 }
    is_asserted_by { b1[3] == -999 }
    is_asserted_by { c1[3] == -999 }
    
  end
  
end

