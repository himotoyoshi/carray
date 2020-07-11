
require 'carray'
require "rspec-power_assert"

describe "TestCArrayCAWindow " do

  example "virtual_array" do
    a = CArray.int(3,3).seq!
    b = a.window(-1..1, -1..1)
    r = b.parent
    is_asserted_by { b.class == CAWindow }
    is_asserted_by { true == b.virtual? }
    is_asserted_by { a == r }
  end


  example "basic_features" do
    # ---
    a = CArray.int(3,3).seq!
    b = a.window(-1..1, -1..1)
    is_asserted_by { CA_INT([[0,0,0],
                         [0,0,1],
                         [0,3,4]]) ==  b }

    # ---
    a = CArray.int(3,3).seq!
    b = a.window(-1..1, -1..1) { UNDEF}
    _ = UNDEF
    is_asserted_by { CA_INT([[_,_,_],
                         [_,0,1],
                         [_,3,4]]) == b }
  end

  example "invalid_args" do
    # ---
    a = CArray.int(3,3).seq
    expect { a.window(1) }.to raise_error(ArgumentError)
    expect { a.window([nil]) }.to raise_error(ArgumentError)
    expect { a.window(nil, [nil,2]) }.to raise_error(ArgumentError)
    expect { a.window(1..-1, nil) }.to raise_error(ArgumentError)
  end

  example "out_of_index" do
    # ---
    a = CArray.int(3,3).seq
    i1 = CA_INT([1,2,3])
    i2 = CA_INT([-4,-3,-2])
    expect { a[i1,nil] }.to raise_error(IndexError)
    expect { a[nil,i1] }.to raise_error(IndexError)
    expect { a[i2,nil] }.to raise_error(IndexError)
    expect { a[nil,i2] }.to raise_error(IndexError)
  end

end
