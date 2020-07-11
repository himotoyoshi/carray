
require 'carray'
require "rspec-power_assert"

describe "TestCArrayCAMapping " do

  example "virtual_array" do
    a = CArray.int(3,3)
    idx = CArray.int(3,3).seq!
    b = a[idx]
    r = b.parent
    is_asserted_by { b.class == CAMapping }
    is_asserted_by { true == b.virtual? }
    is_asserted_by { a == r }
  end

  example "basic_features" do
    # ---
    a   = CArray.int(3,3).seq!
    idx = CArray.int(3,3) { 4 }
    is_asserted_by { CA_INT([[4,4,4],
                         [4,4,4],
                         [4,4,4]]) == a[idx] }
    # ---
    a   = CArray.int(3,3).seq!
    idx = CArray.int(3,3).seq!.reverse!
    is_asserted_by { CA_INT([[8,7,6],
                         [5,4,3],
                         [2,1,0]]) == a[idx] }
    a[idx].seq!
    is_asserted_by { CA_INT([[8,7,6],
                         [5,4,3],
                         [2,1,0]]) == a }
  end

  example "invalid_args" do
    # ---
    a   = CArray.int(3,3).seq!
    idx = CArray.int(3,3) { 4 }
    idx[1,1] = UNDEF
    expect { a[idx] }.to raise_error(ArgumentError)
  end

  example "out_of_range" do
    # ---
    a = CArray.int(3,3).seq!
    idx = CArray.int(3,3) { 9 }
    expect { a[idx] }.to raise_error(IndexError)

    # ---
    a = CArray.int(3,3).seq!
    idx = CArray.int(3,3) { -1 }
    is_asserted_by { CA_INT([[8,8,8],
                         [8,8,8],
                         [8,8,8]]) == a[idx] }
  end

  example "mask" do
    _ = UNDEF
    # ---
    a = CArray.int(3,3).seq!
    idx = CArray.int(3,3).seq!
    a[1,1] = UNDEF
    is_asserted_by { CA_INT([[0,1,2],
                         [3,_,5],
                         [6,7,8]]) == a[idx] }
    a[idx][1,1] = -1
    is_asserted_by { CA_INT([[0,1,2],
                         [3,-1,5],
                         [6,7,8]]) == a }
  end

  example "fill" do
    _ = UNDEF
    # ---
    a = CArray.int(3,3).seq!
    idx = CArray.int(3,3).seq!
    a[idx] = 9
    is_asserted_by { CA_INT([[9,9,9],
                         [9,9,9],
                         [9,9,9]]) == a }
    a[idx] = UNDEF
    is_asserted_by { CA_INT([[_,_,_],
                         [_,_,_],
                         [_,_,_]]) == a }
  end

  example "sync" do
    # ---
    a   = CArray.int(3,3).seq!
    idx = CArray.int(3,3) { 4 }
    a[idx] = -1                     ### not recomended usage
    is_asserted_by { CA_INT([[0,1,2],
                         [3,-1,5],
                         [6,7,8]]) == a }
    # ---
    a   = CArray.int(3,3).seq!
    idx = CArray.int(3,3) { 4 }
    a[idx].seq!                     ### not recomended usage
    is_asserted_by { CA_INT([[0,1,2],
                         [3,8,5],
                         [6,7,8]]) == a }
  end

end
