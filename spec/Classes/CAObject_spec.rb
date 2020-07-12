
require "carray"
require "rspec-power_assert"


describe "CArray.new" do

  example "should return a CA_INT type carray if CA_INT is specified as data_type" do
    ca = CArray.new(CA_INT, [2,3,4])
    is_asserted_by { ca.class == CArray }
    is_asserted_by { ca.data_type == CA_INT }
  end

  example "should return a CA_FIXLEN type carray if CA_FIXLEN is specified as data_type" do
    ca = CArray.new(CA_FIXLEN, [2,3,4], :bytes=>3)
    is_asserted_by { ca.class == CArray }
    is_asserted_by { ca.data_type == CA_FIXLEN }
    is_asserted_by { ca.bytes == 3 }
  end

  example "should return a carray filled by 0 when data_type == CA_INT" do
    ca = CArray.new(CA_INT, [2,3,4])
    is_asserted_by { ca[0] == 0 }
    is_asserted_by { ca.all_equal?(0) == true }
  end

  example "should return a carray filled by string filled by 0 when data_type == CA_FIXLEN" do
    ca = CArray.new(CA_FIXLEN, [2,3,4], :bytes=>3)
    is_asserted_by { ca[0] == "\0\0\0" }
    is_asserted_by { ca.all_equal?("\0\0\0") == true }
  end

end
