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

  example "string" do
    expect {
      CArray.wrap_readonly("\0\0\0\0", CA_INT8)
    }.to raise_error(CArray::DataTypeError)

    a = CArray.wrap_readonly("\0\0\0\0", CA_OBJECT)
    is_asserted_by { a == CA_OBJECT("\0\0\0\0") }
  end


end
