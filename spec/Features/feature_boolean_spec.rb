
require 'carray'
require "rspec-power_assert"

describe "TestBooleanType " do

  example "boolean_bit_operations" do
    a = CArray.int(3,3).seq!
    e0 = a < 4
    e1 = a >= 4

    # ---
    is_asserted_by {  e0 != (e0 & 1) }
    is_asserted_by {  e0 == (e0 & true) }
    is_asserted_by {  a.false == (e0 & false) }

    is_asserted_by {  a.true != (e0 | 1) }
    is_asserted_by {  a.true == (e0 | true) }
    is_asserted_by {  e0 == (e0 | false) }

    is_asserted_by {  e1 != (e0 ^ 1) }
    is_asserted_by {  e1 == (e0 ^ true) }
    is_asserted_by {  e0 == (e0 ^ false) }

    # ---
    is_asserted_by {  e0 != (1 & e0) }
    is_asserted_by {  e0 == (true & e0) }
    is_asserted_by {  a.false == (false & e0) }

    is_asserted_by {  a.true != (1 | e0) }
    is_asserted_by {  a.true == (true | e0) }
    is_asserted_by {  e0 == (false | e0) }

    is_asserted_by {  e1 != (1 ^ e0) }
    is_asserted_by {  e1 == (true ^ e0) }
    is_asserted_by {  e0 == (false ^ e0) }

  end

  example "boolean_bit_operations2" do
    a = CArray.int(3,3).seq!
    e0 = a < 4
    e1 = a >= 4

    one  = a.one
    zero = a.zero
    tt   = a.true
    ff   = a.false

    # ---
    is_asserted_by {  e0 != (e0 & one) }
    is_asserted_by {  e0 == (e0 & tt) }
    is_asserted_by {  ff == (e0 & ff) }

    is_asserted_by {  tt != (e0 | one) }
    is_asserted_by {  tt == (e0 | tt) }
    is_asserted_by {  e0 == (e0 | ff) }

    is_asserted_by {  e1 != (e0 ^ one) }
    is_asserted_by {  e1 == (e0 ^ tt) }
    is_asserted_by {  e0 == (e0 ^ ff) }

    # ---
    is_asserted_by {  e0 != (one & e0) }
    is_asserted_by {  e0 == (tt & e0) }
    is_asserted_by {  ff == (ff & e0) }

    is_asserted_by {  tt != (one | e0) }
    is_asserted_by {  tt == (tt | e0) }
    is_asserted_by {  e0 == (ff | e0) }

    is_asserted_by {  e1 != (one ^ e0) }
    is_asserted_by {  e1 == (tt ^ e0) }
    is_asserted_by {  e0 == (ff ^ e0) }

  end

  example "boolean_bit_operation_with_non_boolean_type" do

    a = CArray.int(3,3).seq!
    b = CArray.int(3,3).seq! + 1
    e0 = a < 4
    e1 = a >= 4

    # ---
    expect { e0 & b }.not_to raise_error
    expect { e0 | b }.not_to raise_error
    expect { e0 ^ b }.not_to raise_error
    # ---             
    expect { b & e0 }.not_to raise_error
    expect { b | e0 }.not_to raise_error
    expect { b ^ e0 }.not_to raise_error

  end


end
