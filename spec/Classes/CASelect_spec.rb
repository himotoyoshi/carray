
require 'carray'
require "rspec-power_assert"

describe "TestCArrayCASelect " do

  example "virtual_array" do
    a = CArray.int(3,3) { 0 }
    b = a[a.eq(0)]
    r = b.parent
    is_asserted_by { b.class == CASelect }
    is_asserted_by { true == b.virtual? }
    is_asserted_by { a == r }
  end

  example "select_to_a" do
    a = CArray.int(3,3).seq!
    s = a[a >= 4]
    is_asserted_by { [4, 5, 6, 7, 8] == a[s].to_a }
  end

end
