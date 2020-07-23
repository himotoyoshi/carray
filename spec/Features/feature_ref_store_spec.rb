
require 'carray'
require "rspec-power_assert"

describe "TestCArrayRefStore " do

  example "access_point" do
    # ---
    a = CArray.int(3,3).seq!
    is_asserted_by {  0 == a[0, 0] }
    is_asserted_by {  4 == a[1, 1] }
    is_asserted_by {  8 == a[-1, -1] }
    expect { a[0,3] }.to raise_error(IndexError)
    expect { a[-4,0] }.to raise_error(IndexError)

    # ---
    a = CArray.int(3,3).seq!
    a[0,0] = -1
    a[1,1] = -2
    a[-1,-1] = -3
    is_asserted_by {  (-1) == a[0, 0] }
    is_asserted_by {  (-2) == a[1, 1] }
    is_asserted_by {  (-3) == a[-1, -1] }
    expect { a[0,3] = -4 }.to raise_error(IndexError)
    expect { a[-4,0] = -5 }.to raise_error(IndexError)
  end

  example "access_block" do
    # ---
    a = CArray.int(3,3).seq!
    is_asserted_by {  CA_INT([1, 4, 7]) == a[0..-1, 1] }
    is_asserted_by {  CA_INT([[1], [4], [7]]) == a[0..-1, [1]] }
    is_asserted_by {  CABlock == a[0..2, 0..2].class }
    is_asserted_by {  a == a[0..2, 0..2] }
    is_asserted_by {  CABlock == a[nil, nil].class }
    is_asserted_by {  a == a[nil, nil] }
    is_asserted_by {  a == a[-3..-1, -3..-1] }
    is_asserted_by {  CA_INT([[0, 1, 2], [3, 4, 5]]) == a[0..1, nil] }
    is_asserted_by {  CA_INT([[0, 2], [3, 5]]) == a[0..1, [nil, 2]] }
    expect { a[0,0..3]  }.to raise_error(IndexError)
    expect { a[-4..-1,0] }.to raise_error(IndexError)
    expect { a[0,[0,3,2]] }.to raise_error(IndexError)
    expect { a[0,[0,4]] }.to raise_error(IndexError)

    # ---
    a = CArray.int(3,3).seq!
    is_asserted_by {  CA_INT([[0, 1, 2], [3, 4, 5], [6, 7, 8]]) == a }

    # ---
    a = CArray.int(3,3).seq!
    a[0..-1, 1] = 9
    is_asserted_by {  CA_INT([[0, 9, 2], [3, 9, 5], [6, 9, 8]]) == a }

    # ---
    a = CArray.int(3,3).seq!
    a[0..-1, [1]] = 9
    is_asserted_by {  CA_INT([[0, 9, 2], [3, 9, 5], [6, 9, 8]]) == a }

    # ---
    a = CArray.int(3,3).seq!
    a[nil, nil] = 9
    is_asserted_by {  CA_INT([[9, 9, 9], [9, 9, 9], [9, 9, 9]]) == a }

    # ---
    a = CArray.int(3,3).seq!
    a[0..1, [nil,2]] = 9
    is_asserted_by {  CA_INT([[9, 1, 9], [9, 4, 9], [6, 7, 8]]) == a }

    # ---
    a = CArray.int(3,3).seq!
    expect { a[0,0..3] = -3  }.to raise_error(IndexError)
    expect { a[-4..-1,0] = -4 }.to raise_error(IndexError)
    expect { a[0,[0,3,2]] = -5  }.to raise_error(IndexError)
    expect { a[0,[0,4]] = -6  }.to raise_error(IndexError)
  end

  example "access_selection" do
    # ---
    a = CArray.int(3,3).seq!;
    is_asserted_by {  CA_INT([0, 1, 2, 3, 4]) == a[a < 5] }

    # ---
    a = CArray.int(3,3).seq!
    a[a < 5] = 1
    is_asserted_by {  CA_INT([[1, 1, 1], [1, 1, 5], [6, 7, 8]]) == a }
  end

#  example "access_mapping" do
#    # ---
#    a = CArray.int(3,3).seq!;
#    m = a.shuffle
#    is_asserted_by { 10*m, (10*a)[m])

    # ---
#    a = CArray.int(3,3).seq!
#    b = 10*a
#    m = a.shuffle
#    a[m] = (10*m)
#    is_asserted_by { b, a)
#  end

  example "access_grid" do
    # ---
    a = CArray.int(3,3).seq!;
    is_asserted_by {  CA_INT([[1, 2], [4, 5]]) == a[CA_INT([0, 1]), 1..2] }
    is_asserted_by {  CA_INT([[0, 2], [6, 8]]) == a[+[0, 2], +[0, 2]] }

    # ---
    a = CArray.int(3,3).seq!
    a[+[0,2],+[0,2]] = 9
    is_asserted_by {  CA_INT([[9, 1, 9], [3, 4, 5], [9, 7, 9]]) == a }
  end

  example "access_repeat" do
    # ---
    # See test_CARepeat
  end

  example "access_method" do
    # ---
    a = CArray.int(3,3).seq!
    is_asserted_by {  CA_INT([0, 1, 2, 3, 4]) == a[:lt, 5] }

    # ---
    a = CArray.int(3,3).seq!
    a[:lt,5] = 1
    is_asserted_by {  CA_INT([[1, 1, 1], [1, 1, 5], [6, 7, 8]]) == a }
  end

  example "access_address" do
    # ---
    a = CArray.int(3,3).seq!
    is_asserted_by {  0 == a[0] }
    is_asserted_by {  4 == a[4] }
    is_asserted_by {  8 == a[-1] }
    expect { a[9] }.to raise_error(IndexError)
    expect { a[-10] }.to raise_error(IndexError)

    # ---
    a = CArray.int(3,3).seq!
    a[0] = -1
    a[4] = -2
    a[-1] = -3
    is_asserted_by {  (-1) == a[0, 0] }
    is_asserted_by {  (-2) == a[1, 1] }
    is_asserted_by {  (-3) == a[-1, -1] }
    expect { a[9] = -4 }.to raise_error(IndexError)
    expect { a[-10] = -5  }.to raise_error(IndexError)
  end

  example "access_address_block" do
    # ---
    a = CArray.int(3,3).seq!
    is_asserted_by {  CA_INT([4]) == a[[4]] }
    is_asserted_by {  CA_INT([0, 1, 2, 3]) == a[[(0..3)]] }
    is_asserted_by {  CARefer == a[nil].class }
    is_asserted_by {  CA_INT([0, 1, 2, 3, 4, 5, 6, 7, 8]) == a[nil] }
    expect { a[0..9]  }.to raise_error(IndexError)
    expect {  a[-10..-1] }.to raise_error(IndexError)

    # ---
    a = CArray.int(3,3).seq!
    is_asserted_by {  CA_INT([[0, 1, 2], [3, 4, 5], [6, 7, 8]]) == a }

    # ---
    a = CArray.int(3,3).seq!
    a[[1..-1,3]] = 9
    is_asserted_by {  CA_INT([[0, 9, 2], [3, 9, 5], [6, 9, 8]]) == a }

    # ---
    a = CArray.int(3,3).seq!
    a[[1,3,3]] = 9
    is_asserted_by {  CA_INT([[0, 9, 2], [3, 9, 5], [6, 9, 8]]) == a }

    # ---
    a = CArray.int(3,3).seq!
    a[nil] = 9
    is_asserted_by {  CA_INT([[9, 9, 9], [9, 9, 9], [9, 9, 9]]) == a }

    # ---
    a = CArray.int(3,3).seq!
    expect { a[0..9] = -3  }.to raise_error(IndexError)
    expect { a[-10..-1] = -4  }.to raise_error(IndexError)
  end

  example "access_address_selection" do
    # ---
    a = CArray.int(3,3).seq!;
    a1 = a.flatten
    is_asserted_by {  CA_INT([0, 1, 2, 3, 4]) == a[a1 < 5] }

    # ---
    a = CArray.int(3,3).seq!
    a[a1 < 5] = 1
    is_asserted_by {  CA_INT([[1, 1, 1], [1, 1, 5], [6, 7, 8]]) == a }
  end

  example "access_address_grid" do
    # ---
    a = CArray.int(3,3).seq!;
    is_asserted_by {  CA_INT([0, 2, 4, 6, 8]) == a[+[0, 2, 4, 6, 8]] }

    # ---
    a = CArray.int(3,3).seq!
    a[+[0,2,4,6,8]] = 9
    is_asserted_by {  CA_INT([[9, 1, 9], [3, 9, 5], [9, 7, 9]]) == a }
  end

end
