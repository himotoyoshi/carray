
require 'carray'
require "rspec-power_assert"

describe "TestCArrayCABitfield " do

  example "virtual_array" do
    a = CArray.int(3,3) { 1 }
    b = a.bitfield(0)
    r = b.parent
    is_asserted_by { b.class == CABitfield }
    is_asserted_by { true == b.virtual? }
    is_asserted_by { a == r }
  end

  example "basic_features" do
    # ---
    a = CArray.int(3,3)
    b = a.bitfield(0)
    b[] = 1
    is_asserted_by { a.template { 1 } == a }
    is_asserted_by { b.template { 1 } == b }
    b[] = 0
    is_asserted_by { a.template { 0 } == a }
    is_asserted_by { b.template { 0 } == b }
    # ---
    a = CArray.int(3,3)
    b = a.bitfield(0..1)
    b[] = 3
    is_asserted_by { a.template { 3 } == a }
    is_asserted_by { b.template { 3 } == b }
    
    # ---
    a = CArray.int(3,3)
    b = a.bitfield(5..6)
    b[] = 3
    is_asserted_by { a.template { 3 << 5 } == a }
    is_asserted_by { b.template { 3 } == b }
    
    # ---
    a = CArray.int(3,3)
    b = a.bitfield(27..28)
    b[] = 3
    is_asserted_by { a.template { 3 << 27 } == a }
    is_asserted_by { b.template { 3 } == b }
  end
  
  example "out_of_index" do
    # ---
    a = CArray.int8(3)
    expect { a.bitfield(-1..0) }.to raise_error(IndexError)
    expect { a.bitfield(0..16) }.to raise_error(IndexError)
    expect { a.bitfield([nil,2]) }.to raise_error(IndexError)
    expect { a.bitfield([nil,1]) }.not_to raise_error()
  end

  
end
