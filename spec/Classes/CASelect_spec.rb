
require 'carray'
require "rspec-power_assert"

describe "TestCArrayCASelect " do

  example "select_to_a" do
    a = CArray.int(3,3).seq!
    s = a[a >= 4]
    is_asserted_by { [4, 5, 6, 7, 8] == a[s].to_a }
  end

end
