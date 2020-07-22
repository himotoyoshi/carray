
require 'carray'
require "rspec-power_assert"

describe "TestCArray " do

  example "conversion" do
    is_asserted_by { CA_INT32(1) == CScalar.int32 { 1 } }
    is_asserted_by { CA_INT32([1]) == CArray.int32(1) { [1] } }
    is_asserted_by { CA_INT32([[0, 1], [2, 3]]) == CArray.int32(2, 2).seq! }
    expect { CA_INT32([1,[1,2]]) }.to raise_error(TypeError)
  end

  example "compact" do
    a = CArray.int(4,1,3,1,2,1).seq!
    b = CArray.int(4,3,2).seq!
    
    is_asserted_by { b == a.compacted }
    is_asserted_by { CARefer == a.compacted.class }
    is_asserted_by { b == a.compact }
    is_asserted_by { CArray == a.compact.class }
  end

  example "to_a" do
    # ---
    a = CArray.int(3).seq!
    is_asserted_by { [0, 1, 2] == a.to_a }

    # ---
    a = CArray.int(3,3).seq!
    is_asserted_by { [[0, 1, 2], [3, 4, 5], [6, 7, 8]] == a.to_a }
  end

  example "convert" do
    # ---
    a = CArray.int(3).seq!
    if RUBY_VERSION >= "1.9.0"
      b = a.convert(CA_OBJECT) {|x| (x+"a".ord).chr }
    else  
      b = a.convert(CA_OBJECT) {|x| (x+?a).chr }
    end 
    is_asserted_by { CA_OBJECT(["a", "b", "c"]) == b }
  end 

  
end
