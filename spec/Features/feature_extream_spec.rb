
require 'carray'
require "rspec-power_assert"

describe "TestCArrayExtream " do

  example "zero_length_array" do
    # ---
    a = CArray.int(0)
    is_asserted_by { 1 == a.rank }
    is_asserted_by { 0 == a.elements }
    is_asserted_by { [0] == a.dim }
    is_asserted_by { 0 == a.dim0 }

    # ---
    a = CArray.int(0, 3)
    is_asserted_by { 2 == a.rank }
    is_asserted_by { 0 == a.elements }
    is_asserted_by { [0, 3] == a.dim }
    is_asserted_by { 0 == a.dim0 }
    is_asserted_by { 3 == a.dim1 }

    # ---
    a = CArray.int(3, 0)
    is_asserted_by { 2 == a.rank }
    is_asserted_by { 0 == a.elements }
    is_asserted_by { [3, 0] == a.dim }
    is_asserted_by { 3 == a.dim0 }
    is_asserted_by { 0 == a.dim1 }
  end

  example "zero_length_fixlen" do
    # ---
    expect { CArray.new(CA_FIXLEN, [3,3], :bytes => 0) }.not_to raise_error()
    expect { CArray.new(CA_FIXLEN, [3,3], :bytes => -1) }.to raise_error(RuntimeError)
  end

  example "large_rank_array" do
    # ---
    dim = [2] * (CA_RANK_MAX)
    is_asserted_by { CArray.int8(*dim).class == CArray }

    # ---
    dim = [2] * (CA_RANK_MAX+1)
    expect { CArray.int8(*dim) }.to raise_error(RuntimeError)
  end

  example "negative_dimension_size" do
    # ---
    expect { CArray.int8(-1) }.to raise_error(RuntimeError)
    expect { CArray.int8(-1, -1) }.to raise_error(RuntimeError)
  end

end
