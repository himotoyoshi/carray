require 'carray'
require "rspec-power_assert"

describe "CArray#wrap_readonly" do

  # 2020-07-22
  example "array" do
    ary = [[1,2,3], 
           [4,5,6],
           [7,8,9]]
    a = CArray.wrap_readonly(ary, CA_INT32)
    is_asserted_by { a.class == CAFake }
    is_asserted_by { a.entity? == false }
    is_asserted_by { a.data_type == CA_INT32 }
    is_asserted_by { a.shape == [3,3] }
    is_asserted_by { a == CA_INT32(ary) }
  end

  # 2020-07-22
  example "string" do
    a = CA_UINT8([0,1,2,3,4,5,6,7])
    b = CArray.wrap_readonly(a.to_s, CA_UINT8)
    is_asserted_by { b == a }

    c = CArray.wrap_readonly(a.to_s, CA_OBJECT)
    is_asserted_by { c == CA_OBJECT(a.to_s) }
  end

  # 2020-07-22
  example "nil" do
    a = CA_INT(0)
    b = CArray.wrap_readonly(nil, CA_INT)
    is_asserted_by { b == a }
  end

  # 2020-07-22
  example "object" do
    a = CA_FLOAT64(1.5)
    b = CArray.wrap_readonly(1.5, CA_FLOAT64)
    is_asserted_by { b == a }
  end

end
