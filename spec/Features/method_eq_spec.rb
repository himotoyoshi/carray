
require "carray"
require 'rspec-power_assert'

describe "CArray#eq" do

  example "returns 1 if self and other equal (int)" do
    ca123 = CA_INT([123])

    is_asserted_by { (ca123).eq(123  )[0] == 1 }
    is_asserted_by { (ca123).eq(ca123)[0] == 1 }
  end

  example "returns 1 if self and other equal (object)" do
    ca123 = CA_OBJECT(["123"])

    is_asserted_by { (ca123).eq("123")[0] == 1 }
    is_asserted_by { (ca123).eq(ca123)[0] == 1 }
  end

  example "returns 1 if self and other equal (fixlen)" do
    ca123 = CA_FIXLEN(["123"], :bytes=>3)

    is_asserted_by { (ca123).eq("123")[0] == 1 }
    is_asserted_by { (ca123).eq(ca123)[0] == 1 }
  end

  example "returns 0 if self and other equal (int)" do
    ca123 = CA_INT([123])
    ca124 = CA_INT([124])

    is_asserted_by { (ca123).eq(124  )[0] == 0 }
    is_asserted_by { (ca123).eq(ca124)[0] == 0 }
  end

  example "returns 0 if self and other equal (object)" do
    ca123 = CA_OBJECT(["123"])
    ca124 = CA_OBJECT(["124"])

    is_asserted_by { (ca123).eq("124")[0] == 0 }
    is_asserted_by { (ca123).eq(ca124)[0] == 0 }
  end

  example "returns 0 if self and other equal (fixlen)" do
    ca123 = CA_FIXLEN(["123"], :bytes=>3)
    ca124 = CA_FIXLEN(["124"], :bytes=>3)
    ca12  = CA_FIXLEN(["12"], :bytes=>3)

    is_asserted_by { (ca123).eq("124")[0] == 0 }
    is_asserted_by { (ca123).eq(ca124)[0] == 0 }

    is_asserted_by { (ca123).eq("12")[0] == 0 }
    is_asserted_by { (ca123).eq(ca12)[0] == 0 }
  end

  example "returns 0 if self is a NaN" do
    nan = 0.0/0.0 

    is_asserted_by { (nan             ).eq(CA_DOUBLE([0.0]))[0] == 0 }
    is_asserted_by { (CA_DOUBLE([nan])).eq(0.0             )[0] == 0 }
    is_asserted_by { (CA_DOUBLE([nan])).eq(CA_DOUBLE([0.0]))[0] == 0 }
  end

  example "returns 0 if self and other are NaN" do
    nan = 0.0/0.0 

    is_asserted_by { (nan             ).eq(CA_DOUBLE([nan]))[0] == 0 }
    is_asserted_by { (CA_DOUBLE([nan])).eq(nan             )[0] == 0 }
    is_asserted_by { (CA_DOUBLE([nan])).eq(CA_DOUBLE([nan]))[0] == 0 }
  end

  example "returns 0 if other is a NaN" do
    nan = 0.0/0.0 

    is_asserted_by { (0.0             ).eq(CA_DOUBLE([nan]))[0] == 0 }
    is_asserted_by { (CA_DOUBLE([0.0])).eq(nan             )[0] == 0 }
    is_asserted_by { (CA_DOUBLE([0.0])).eq(CA_DOUBLE([nan]))[0] == 0 }
  end

end

