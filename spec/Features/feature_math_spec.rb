
require 'carray'
require "rspec-power_assert"

describe "TestMath " do

  example "zerodiv" do
    zero = CArray.int(3,3) { 0 }
    one  = CArray.int(3,3) { 1 }
    expect { 1/zero }.to raise_error(ZeroDivisionError)
    expect { one/zero }.to raise_error(ZeroDivisionError) # div, div!
    expect { one/0 }.to raise_error(ZeroDivisionError)
    expect { one/zero }.to raise_error(ZeroDivisionError)
    expect { one % 0 }.to raise_error(ZeroDivisionError)  # mod, mod!
    expect { one % zero }.to raise_error(ZeroDivisionError)
    expect { zero.rcp }.to raise_error(ZeroDivisionError) # rcp!
    expect { zero.rcp_mul(1) }.to raise_error(ZeroDivisionError) # rcp_mul!
    expect { zero.rcp_mul(one) }.to raise_error(ZeroDivisionError)
    expect { 0 ** (-one) }.to raise_error(ZeroDivisionError) # pow, pow!
    expect { zero ** (-one) }.to raise_error(ZeroDivisionError)
  end

  example "cmp" do
    a = CA_INT([0,1,2,3,4])
    b = CA_INT([4,3,2,1,0])

    # ---
    is_asserted_by { CA_INT8([-1, -1, 0, 1, 1]) == (a <=> 2) }
    is_asserted_by { CA_INT8([1, 1, 0, -1, -1]) == (2 <=> a) }
    is_asserted_by { CA_INT8([-1, -1, 0, 1, 1]) == (a <=> b) }
  end

  example "bit_op" do
    a = CArray.int(10).seq!

    # ---
    is_asserted_by { a.convert {|x| ~x } == (~a) }

    is_asserted_by { a.convert {|x| x & 1 } == (a & 1) }
    is_asserted_by { (a & 1) == (1 & a) }

    is_asserted_by { a.convert { |x| x | 1 } == (a | 1) }
    is_asserted_by { (a | 1) == (1 | a) }

    is_asserted_by { a.convert { |x| x ^ 1 } == (a ^ 1) }
    is_asserted_by { (a ^ 1) == (1 ^ a) }

    # ---
    is_asserted_by { a.convert { |x| x << 1 } == (a << 1) }
    is_asserted_by { a.convert { |x| 1 << x } == (1 << a) }

    is_asserted_by { a.convert { |x| x >> 1 } == (a >> 1) }
    is_asserted_by { a.convert { |x| 1 >> x } == (1 >> a) }
  end

  example "max_min" do
    a = CArray.int(3,3).seq!
    b = a.reverse

    # ---
    is_asserted_by { CA_INT32([[8,7,6],
                               [5,4,5],
                               [6,7,8]]) == a.pmax(b) }
    is_asserted_by { CA_INT32([[0,1,2],
                               [3,4,3],
                               [2,1,0]]) == a.pmin(b) }
    # ---
    is_asserted_by { CA_INT32([[0,0,0],
                               [0,0,0],
                               [0,0,0]]) == a.pmin(0) }
    is_asserted_by { CA_INT32([[8,8,8],
                               [8,8,8],
                               [8,8,8]]) == a.pmax(8) }
    # ---
    is_asserted_by { CA_INT32([[0,0,0],
                               [0,0,0],
                               [0,0,0]]) == CA_INT32(0).pmin(a) }
    is_asserted_by { CA_INT32([[8,8,8],
                               [8,8,8],
                               [8,8,8]]) == CA_INT32(8).pmax(a) }
    # ---
    is_asserted_by { CA_INT32([[8,7,6],
                               [5,4,5],
                               [6,7,8]]) == CAMath.max(a, b) }
    is_asserted_by { CA_INT32([[0,1,2],
                               [3,4,3],
                               [2,1,0]]) == CAMath.min(a, b) }
    # ---
    is_asserted_by { CA_INT32([[0,0,0],
                               [0,0,0],
                               [0,0,0]]) == CAMath.min(0,a,b,8) }
    is_asserted_by { CA_INT32([[8,8,8],
                               [8,8,8],
                               [8,8,8]]) == CAMath.max(0,a,b,8) }
  end

end
