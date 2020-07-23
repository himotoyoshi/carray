
require "carray"
require "rspec-power_assert"

describe "CArray#elements" do

  example "should return element number of array" do
    ca = CArray.int32(2,3,4)
    is_asserted_by { ca.elements == 2*3*4 }
    is_asserted_by { ca.length == 2*3*4 }
    is_asserted_by { ca.size == 2*3*4 }
  end

end

describe "CArray#data_type" do
  
  example "should return data type of array" do
    ca = CArray.int32(2,3,4)
    is_asserted_by { ca.data_type == CA_INT32 }
  end

end

describe "CArray#dim" do

  example "should return a array contains the shape of array" do
    ca = CArray.int32(2,3,4)
    is_asserted_by { ca.dim == [2,3,4] }
  end

end

