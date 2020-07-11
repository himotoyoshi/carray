require "carray"
require 'rspec-power_assert'

describe "CArray#ne" do
  it "returns 0 if self is not a valid IEEE floating-point number" do
    nan = 0.0/0.0
    is_asserted_by { 0.0.ne(CA_DOUBLE(nan))[0] == 1 }
    is_asserted_by { nan.ne(CA_DOUBLE(nan))[0] == 1 }
    is_asserted_by { nan.ne(CA_DOUBLE(0.0))[0] == 1 }
    is_asserted_by { CA_DOUBLE(nan).ne(0.0)[0] == 1 }
    is_asserted_by { CA_DOUBLE(nan).ne(nan)[0] == 1 }
    is_asserted_by { CA_DOUBLE(0.0).ne(nan)[0] == 1 }
    is_asserted_by { CA_DOUBLE(nan).ne(CA_DOUBLE(0.0))[0] == 1 }
    is_asserted_by { CA_DOUBLE(nan).ne(CA_DOUBLE(nan))[0] == 1 }
    is_asserted_by { CA_DOUBLE(0.0).ne(CA_DOUBLE(nan))[0] == 1 }
  end
end
    