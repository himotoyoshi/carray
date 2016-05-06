
require "carray"

describe "CArray#round" do
  it "returns the nearest Integer" do
    CA_DOUBLE(5.5).round[0].should == 6
    CA_DOUBLE(0.4).round[0].should == 0
    CA_DOUBLE(-2.8).round[0].should == -3
    CA_DOUBLE(0.0).round[0].should == 0
  end
end
