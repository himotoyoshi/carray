
require "carray"

describe "CArray#[]" do

  it "should return one element array with [nil,-1]" do
    ca = CArray.int(4,4).seq!
    ( ca[[nil,-1]].elements ).should == 1
    ( ca[[nil,-1]] ).should == ca[[0]]
  end

  it "should return self[[0],nil] with [nil,-1], nil" do
    ca = CArray.int(4,4).seq!
    ( ca[[nil,-1],nil] ).should == ca[[0],nil]
  end

  it "should return self[[0],nil] with nil, [nil,-1]" do
    ca = CArray.int(4,4).seq!
    ( ca[nil,[nil,-1]] ).should == ca[nil,[0]]
  end

  it "should return self[[0],nil] with [nil,-1], [nil,-1]" do
    ca = CArray.int(4,4).seq!
    ( ca[[nil,-1],[nil,-1]] ).should == ca[[0],[0]]
  end

end