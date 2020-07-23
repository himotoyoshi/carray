require "carray"
require 'rspec-power_assert'

describe "CArray#is_nan" do
  example "returns 1 if self is not a valid IEEE floating-point number" do
    is_asserted_by { CA_DOUBLE(0.0).is_nan[0] == 0 }
    is_asserted_by { CA_DOUBLE(-1.5).is_nan[0] == 0 }
    is_asserted_by { (CA_DOUBLE(0.0)/CA_DOUBLE(0.0)).is_nan[0] == 1 }
    is_asserted_by { CA_DOUBLE(0.0/0.0).is_nan[0] == 1 }
  end
end

