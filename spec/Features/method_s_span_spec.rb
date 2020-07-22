require 'carray'
require "rspec-power_assert"

describe "CArray.span" do

  # 2020-07-22
  example "s_span" do
    a = CArray.span(CA_FLOAT32, 0..2, 0.5)
    is_asserted_by { a == CA_FLOAT32([0, 0.5, 1, 1.5, 2]) }
    a = CArray.span(CA_FLOAT32, 0...2, 0.5)
    is_asserted_by { a == CA_FLOAT32([0, 0.5, 1, 1.5]) }
  end

end
