require 'carray'
require "rspec-power_assert"

describe "Cast function" do

  example "CA_SIZE" do
    # ---
    a = CA_SIZE([1,2,3])
    is_asserted_by { a.data_type == CA_INT64 }
  end

  example "CA_SIZE" do
    # ---
    a = CA_SIZE([1,2,3])
    is_asserted_by { a.data_type == CA_INT64 }
  end


end
