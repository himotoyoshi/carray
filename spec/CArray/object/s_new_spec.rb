
require "carray"

describe "CArray.new" do

  it "should return a CA_INT type carray if CA_INT is specified as data_type" do
    ca = CArray.new(CA_INT, [2,3,4])
    ( ca.class ).should == CArray
    ( ca.data_type ).should == CA_INT
  end

  it "should return a CA_FIXLEN type carray if CA_FIXLEN is specified as data_type" do
    ca = CArray.new(CA_FIXLEN, [2,3,4], :bytes=>3)
    ( ca.class ).should == CArray
    ( ca.data_type ).should == CA_FIXLEN
    ( ca.bytes ).should == 3
  end

  it "should return a carray filled by 0 when data_type == CA_INT" do
    ca = CArray.new(CA_INT, [2,3,4])
    ( ca[0] ).should == 0
    ( ca.all_equal?(0) ).should == true
  end

  it "should return a carray filled by string filled by 0 when data_type == CA_FIXLEN" do
    ca = CArray.new(CA_FIXLEN, [2,3,4], :bytes=>3)
    ( ca[0] ).should == "\0\0\0"
    ( ca.all_equal?("\0\0\0") ).should == true
  end

end
