
require 'carray'
require "rspec-power_assert"

describe "TestCArrayCARepeat " do

  example "virtual_array" do
    a = CArray.int(3)
    b = a[:%,3]
    r = b.parent
    is_asserted_by { b.class == CARepeat }
    is_asserted_by { true == b.virtual? }
    is_asserted_by { true == b.read_only? }
    is_asserted_by { false == b.attached? }
    is_asserted_by { a == r }
  end

  example "basic_feature" do
    # ---
    a = CArray.int(3).seq!
    r1 = a[3,:%]
    r2 = a[:%,3]
    is_asserted_by { CA_INT([[0,1,2],
                         [0,1,2],
                         [0,1,2]]) == r1 }
    is_asserted_by { CA_INT([[0,0,0],
                         [1,1,1],
                         [2,2,2]]) == r2 }
    # ---
    b = CArray.int(2,2).seq!
    is_asserted_by { CA_INT([[[ 0, 1 ],
                          [ 0, 1 ]],
                         [[ 2, 3 ],
                          [ 2, 3 ]]]) == b[:%,2,:%] }
  end

  example "store" do
    a = CArray.int(3).seq!
    r1 = a[3,:%]
    expect { r1[1,1] = 1 }.to raise_error(RuntimeError)
    expect { r1.seq! }.to raise_error(RuntimeError)    
    r2 = a[:%,3]
    expect { r1[1,1] = 1 }.to raise_error(RuntimeError)
    expect { r1.seq! }.to raise_error(RuntimeError)    
  end

  example "mask_repeat" do
    a = CArray.int(3).seq!
    a[1] = UNDEF
    r1 = a[3,:%]
    x1 = r1.to_ca
    is_asserted_by { 3 == r1.count_masked }
    is_asserted_by { 3 == r1[nil, 1].count_masked }
    is_asserted_by { 3 == x1.count_masked }
    is_asserted_by { 3 == x1[nil, 1].count_masked }
    
    r2 = a[:%,3]
    x2 = r2.to_ca
    is_asserted_by { 3 == r2.count_masked }
    is_asserted_by { 3 == r2[1, nil].count_masked }
    is_asserted_by { 3 == x2.count_masked }
    is_asserted_by { 3 == x2[1, nil].count_masked }
  end

end
