
require 'carray'
require "rspec-power_assert"

describe "TestCArrayCAGrid " do

  example "virtual_array" do
    a = CArray.int(3,3)
    i = CArray.int(3).seq
    b = a[i, 0..1]
    r = b.parent
    is_asserted_by { b.class == CAGrid }
    is_asserted_by { true == b.virtual? }
    is_asserted_by { a == r }
  end

  example "basic_features" do
    # ---
    a = CArray.int(3,3).seq
    i = CA_INT([1,2,0])
    is_asserted_by { CA_INT([[3,4,5],
                         [6,7,8],
                         [0,1,2]]) == a[i,nil] }
    is_asserted_by { CA_INT([[1,2,0],
                         [4,5,3],
                         [7,8,6]]) == a[nil,i] }
    is_asserted_by { CA_INT([[4,5,3],
                         [7,8,6],
                         [1,2,0]]) == a[i,i] }
    # ---
    a = CArray.int(3,3).seq
    i = CA_INT([-1,-2,-3])
    is_asserted_by { CA_INT([[6,7,8],
                         [3,4,5],
                         [0,1,2]]) == a[i,nil] }
    is_asserted_by { CA_INT([[2,1,0],
                         [5,4,3],
                         [8,7,6]]) == a[nil,i] }
    is_asserted_by { CA_INT([[8,7,6],
                         [5,4,3],
                         [2,1,0]]) == a[i,i] }
  end

  example "invalid_args" do
    # ---
    a = CArray.int(3,3).seq
    i = CA_INT([0,1,2])
    expect { a.grid(i) }.to raise_error(ArgumentError)

    # ---
    a = CArray.int(3,3).seq
    i = CA_INT([0,1,2])
    i[0] = UNDEF
    is_asserted_by { CA_INT([[3, 4, 5], [6, 7, 8]]) == a.grid(i, nil) }

    # ---
    a = CArray.int(3,3).seq
    i = CA_INT([])
    is_asserted_by { CArray.int(0, 3) == a.grid(i, nil) }
    is_asserted_by { CArray.int(3, 0) == a.grid(nil, i) }
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
