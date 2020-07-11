require "carray"
require 'rspec-power_assert'

describe "CArray#round" do
  example "returns the nearest Integer" do
    is_asserted_by { CA_DOUBLE(5.5).round[0] == 6 }
    is_asserted_by { CA_DOUBLE(0.4).round[0] == 0 }
    is_asserted_by { CA_DOUBLE(-2.8).round[0] == -3 }
    is_asserted_by { CA_DOUBLE(0.0).round[0] == 0 }
  end
end
