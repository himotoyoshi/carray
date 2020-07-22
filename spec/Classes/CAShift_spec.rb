
require 'carray'
require "rspec-power_assert"

describe "TestCArrayCAShift " do

  example "virtual_array" do
    a = CArray.int(3,3)
    b = a.shifted(1,1)
    r = b.parent
    is_asserted_by { b.class == CAShift }
    is_asserted_by { true == b.virtual? }
    is_asserted_by { a == r }
  end

end
