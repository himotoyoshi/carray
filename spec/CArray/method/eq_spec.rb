
require "carray"

describe "CArray#eq" do

  it "returns 1 if self and other equal (int)" do
    ca123 = CA_INT([123])

    ( (ca123).eq(123  )[0] ).should == 1
    ( (ca123).eq(ca123)[0] ).should == 1
  end

  it "returns 1 if self and other equal (object)" do
    ca123 = CA_OBJECT(["123"])

    ( (ca123).eq("123")[0] ).should == 1
    ( (ca123).eq(ca123)[0] ).should == 1
  end

  it "returns 1 if self and other equal (fixlen)" do
    ca123 = CA_FIXLEN(["123"], :bytes=>3)

    ( (ca123).eq("123")[0] ).should == 1
    ( (ca123).eq(ca123)[0] ).should == 1
  end

  it "returns 0 if self and other equal (int)" do
    ca123 = CA_INT([123])
    ca124 = CA_INT([124])

    ( (ca123).eq(124  )[0] ).should == 0
    ( (ca123).eq(ca124)[0] ).should == 0
  end

  it "returns 0 if self and other equal (object)" do
    ca123 = CA_OBJECT(["123"])
    ca124 = CA_OBJECT(["124"])

    ( (ca123).eq("124")[0] ).should == 0
    ( (ca123).eq(ca124)[0] ).should == 0
  end

  it "returns 0 if self and other equal (fixlen)" do
    ca123 = CA_FIXLEN(["123"], :bytes=>3)
    ca124 = CA_FIXLEN(["124"], :bytes=>3)
    ca12  = CA_FIXLEN(["12"], :bytes=>3)

    ( (ca123).eq("124")[0] ).should == 0
    ( (ca123).eq(ca124)[0] ).should == 0

    ( (ca123).eq("12")[0] ).should == 0
    ( (ca123).eq(ca12)[0] ).should == 0
  end

  it "returns 0 if self is a NaN" do
    nan = 0.0/0.0

    ( (nan             ).eq(CA_DOUBLE([0.0]))[0] ).should == 0
    ( (CA_DOUBLE([nan])).eq(0.0             )[0] ).should == 0
    ( (CA_DOUBLE([nan])).eq(CA_DOUBLE([0.0]))[0] ).should == 0
  end

  it "returns 0 if self and other are NaN" do
    nan = 0.0/0.0

    ( (nan             ).eq(CA_DOUBLE([nan]))[0] ).should == 0
    ( (CA_DOUBLE([nan])).eq(nan             )[0] ).should == 0
    ( (CA_DOUBLE([nan])).eq(CA_DOUBLE([nan]))[0] ).should == 0
  end

  it "returns 0 if other is a NaN" do
    nan = 0.0/0.0

    ( (0.0             ).eq(CA_DOUBLE([nan]))[0] ).should == 0
    ( (CA_DOUBLE([0.0])).eq(nan             )[0] ).should == 0
    ( (CA_DOUBLE([0.0])).eq(CA_DOUBLE([nan]))[0] ).should == 0
  end

end

