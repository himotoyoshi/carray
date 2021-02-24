require 'carray'
require "rspec-power_assert"

describe "TestCast " do

  example "obj_to_numeric" do
    # ---
    a = CA_OBJECT([1,2,3])
    b = CA_INT32([1,2,3])
    c = CA_FLOAT64([1,2,3])
    is_asserted_by {  b == a.int32 }
    is_asserted_by {  c == a.float64 }

    # ---
    a = CA_OBJECT(["1","2","3"])
    b = CA_INT32([1,2,3])
    c = CA_FLOAT64([1,2,3])
    is_asserted_by {  b == a.int32 }
    is_asserted_by {  c == a.float64 }

    # ---
    a = CA_OBJECT([nil, nil, nil])
    expect { a.int32 }.to raise_error(TypeError)
#    assert_raise(TypeError) { a.float32 }

    # ---
    a = CA_OBJECT(["a", "b", "c"])
    expect { a.int32 }.to raise_error(ArgumentError)
#    expect { a.float32 }.to raise_error(ArgumentError)
  end


end
