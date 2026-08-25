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

    # --- parse failure -> UNDEF (3.0: symmetric float/int, mask on failure) ---
    a = CA_OBJECT([nil, nil, nil])
    is_asserted_by { a.int32.is_masked.to_a == [true, true, true] }
    is_asserted_by { a.float64.is_masked.to_a == [true, true, true] }

    # ---
    a = CA_OBJECT(["a", "b", "c"])
    is_asserted_by { a.int32.is_masked.to_a == [true, true, true] }
    is_asserted_by { a.float64.is_masked.to_a == [true, true, true] }

    # --- mixed: only unparseable cells masked ---
    a = CA_OBJECT(["", "xx", "1.5", 2, nil])
    is_asserted_by { a.float64.is_masked.to_a == [true, true, false, false, true] }
    is_asserted_by { a.float64.to_a == [UNDEF, UNDEF, 1.5, 2.0, UNDEF] }
    is_asserted_by { a.int32.is_masked.to_a == [true, true, true, false, true] }

    # --- explicit nan/inf literals kept (case-insensitive, exact token) ---
    a = CA_OBJECT(["nan", "NaN", "inf", "-inf", "infinity"])
    f = a.float64
    is_asserted_by { f.is_masked.to_a == [false, false, false, false, false] }
    is_asserted_by { f[0].nan? and f[1].nan? }
    is_asserted_by { f[2].infinite? == 1 and f[3].infinite? == -1 and f[4].infinite? == 1 }

    # --- prefix over-match is gone: nancy/info -> UNDEF ---
    a = CA_OBJECT(["nancy", "info", "inflation"])
    is_asserted_by { a.float64.is_masked.to_a == [true, true, true] }
  end


end
