
require "carray"

describe "CArray#elements" do

  it "should return element number of array" do
    ca = CArray.int32(2,3,4)
    ( ca.elements ).should == 2*3*4
    ( ca.length ).should == 2*3*4
    ( ca.size ).should == 2*3*4
  end

end

describe "CArray#data_type" do
  
  it "should return data type of array" do
    ca = CArray.int32(2,3,4)
    ( ca.data_type ).should == CA_INT32
  end

end

describe "CArray#dim" do

  it "should return a array contains the shape of array" do
    ca = CArray.int32(2,3,4)
    ( ca.dim ).should == [2,3,4]
  end

end

