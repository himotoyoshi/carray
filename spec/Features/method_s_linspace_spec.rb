require "carray"
require 'rspec-power_assert'

describe "CArray.linspace" do

  # 2020-07-10
  example "float range" do

    a = CArray.linspace(0.0,1.0)
    b = CArray.double(100).span(0.0..1.0)
    
    is_asserted_by { a == b }

  end

  # 2020-07-10
  example "integer range -> float array" do

    a = CArray.linspace(0,1)
    b = CArray.double(100).span(0.0..1.0)
    
    is_asserted_by { a == b }

  end

  # 2020-07-10
  example "specify number" do

    a = CArray.linspace(0.0,1.0,5)
    b = CArray.double(5).span(0.0..1.0)
    
    is_asserted_by { a == b }

  end

  # 2020-07-10
  example "integer array" do

    a = CArray::Int32.linspace(0.0,1.0)
    b = CArray.int32(100).span(0.0..1.0)
    
    is_asserted_by { a == b }

  end

  
end
  