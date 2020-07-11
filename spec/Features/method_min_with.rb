require "carray"
require 'rspec-power_assert'

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
