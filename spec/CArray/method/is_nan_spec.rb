
require "carray"

describe "CArray#is_nan" do
  it "returns 1 if self is not a valid IEEE floating-point number" do
    CA_DOUBLE(0.0).is_nan[0].should == 0
    CA_DOUBLE(-1.5).is_nan[0].should == 0
    (CA_DOUBLE(0.0)/CA_DOUBLE(0.0)).is_nan[0].should == 1
    CA_DOUBLE(0.0/0.0).is_nan[0].should == 1
  end
end

