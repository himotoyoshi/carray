
require 'carray'
require "rspec-power_assert"

describe "TestCArrayCARefer " do

  example "basic_features" do
    # ---
    a = CArray.int(3,2).seq!
    r = a.reshape(2,3)
    is_asserted_by { a.data_type == r.data_type }
    is_asserted_by { [2, 3] == r.dim }
    is_asserted_by { CA_INT([[0,1,2],
                         [3,4,5]]) == r }

    # ---
    # 3.0: reshape is strict on element count.  The pre-3.0 "less data
    # number" prefix-view (reshape to fewer elements -> view of the first
    # N) is removed; a non-preserving shape now raises.  Migration: take
    # an explicit prefix first, e.g. a.flatten[0..3].reshape(2, 2).
    a = CArray.int(3,2).seq!
    expect { a.reshape(2,2) }.to raise_error(RuntimeError)
    r = a.flatten[0..3].reshape(2, 2)
    is_asserted_by { CA_INT([[0,1],
                         [2,3]]) == r }

    # ---
    # data type change (int -> float)
    a = CArray.int(3,2).seq!
    r = a.refer(CA_FLOAT32, [2,3])
    rr = r.refer(CA_INT32, [3,2])
    is_asserted_by { CA_FLOAT == r.data_type }
    is_asserted_by { a == rr }
  end

  example "refer_to_virtual_array" do
    # ---
    a = CArray.int(3,3).seq!
    b = a[1..2,1..2]
    r = b.reshape(4)
    is_asserted_by { CA_INT([4, 5, 7, 8]) == r }

    # ---
    a = CArray.int(3).seq!
    b = a[:%,3]
    r = b.reshape(9)
    is_asserted_by { CA_INT([0, 0, 0, 1, 1, 1, 2, 2, 2]) == r }

  end

  example "invalid_args" do
    # ---
    a = CArray.int8(3,3).seq!
    expect { a.reshape(10) }.to raise_error(RuntimeError) ### too large data num
    expect { a.refer(CA_INT,[9]) }.to raise_error(RuntimeError)
                                                   ### larger data type bytes

  end

  example "flatten" do
    a = CArray.int(3,3).seq!
    b = CArray.int(9).seq!

    # ---
    is_asserted_by { b == a.flatten }
    is_asserted_by { b == a.flatten }

    # ---
    # 3.0: a.reverse returns a view, so we snapshot with .copy
    # before mutating a through the flattened view.
    # 3.0: reverse! removed, use `ca[] = ca.reverse` idiom.
    c = a.reverse.copy
    flat = a.flatten
    flat[] = flat.reverse
    is_asserted_by { c == a }
  end

  example "refer_variant" do
    a = CArray.fixlen(4, :bytes=>4) {"abcd"}
    b = CA_FIXLEN([["ab", "cd"],
                   ["ab", "cd"],
                   ["ab", "cd"],
                   ["ab", "cd"]], :bytes=>2)
    c = CA_FIXLEN(["abcdabcd", "abcdabcd"], :bytes=>8)

    # ---
    is_asserted_by { b == a.refer(CA_FIXLEN, [4, 2], bytes: 2) }
    is_asserted_by { c == a.refer(CA_FIXLEN, [2], bytes: 8) }

  end

end
