
require 'carray'
require "rspec-power_assert"

describe "Test130 " do

  example "float_arithmetic" do
    is_asserted_by { (CA_FLOAT([100]) + 1)[0] == 101.0 }
  end
  
  example "int64" do
    expect { CA_INT64([0xffffffffffffffff]) }.to raise_error(RangeError)
    is_asserted_by { CA_INT64([0x7fffffffffffffff])[0] == 0x7fffffffffffffff }
    is_asserted_by { CA_INT64([0x7fffffffffffffff])+1  == CA_INT64([-0x8000000000000000]) }
    is_asserted_by { CA_INT64([0x7fffffffffffffff, 0x7fffffffffffffff]).sum == (2*0x7fffffffffffffff).to_f }
  end


end
