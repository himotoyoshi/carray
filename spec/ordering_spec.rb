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

describe "CArray#sort_with" do

  # 2020-07-09
  example "basic" do
   
    a1 = CA_INT([3,2,4,1])
    b1 = CA_INT([13,12,14,11])
    c1 = CA_INT([23,22,24,21])
    
    a2,b2,c2 = a1.sort_with(b1,c1)
    
    is_asserted_by { a2 == CA_INT([1,2,3,4]) }
    is_asserted_by { b2 == CA_INT([11,12,13,14]) }
    is_asserted_by { c2 == CA_INT([21,22,23,24]) }

    a2[0] = -999    
    b2[0] = -999    
    c2[0] = -999    
    is_asserted_by { a1[3] != -999 }
    is_asserted_by { b1[3] != -999 }
    is_asserted_by { c1[3] != -999 }
    
  end

  example "technique: reverse sort" do
   
    a1 = CA_INT([3,2,4,1])
    b1 = CA_INT([13,12,14,11])
    c1 = CA_INT([23,22,24,21])
    
    _,a2,b2,c2 = (-a1).sort_with(a1,b1,c1)
    
    is_asserted_by { a2 == CA_INT([1,2,3,4]).reverse }
    is_asserted_by { b2 == CA_INT([11,12,13,14]).reverse }
    is_asserted_by { c2 == CA_INT([21,22,23,24]).reverse }

  end
  
end

describe "CArray#max_with" do
  
  # 2020-07-09
  example "basic" do
   
    a = CA_INT([3,2,4,1])
    b = CA_INT([13,12,14,11])
    c = CA_INT([23,22,24,21])
    
    list = a.max_with(b,c)
    
    is_asserted_by { list == [4,14,24] }
    
  end
  
end

describe "CArray#min_with" do
  
  # 2020-07-09
  example "basic" do
   
    a = CA_INT([3,2,4,1])
    b = CA_INT([13,12,14,11])
    c = CA_INT([23,22,24,21])
    
    list = a.min_with(b,c)
    
    is_asserted_by { list == [1,11,21] }
    
  end
  
end
