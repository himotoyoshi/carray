
require 'carray'
require "rspec-power_assert"

describe "TestCArrayGenerate " do

  example "swap_bytes" do
    #
    a = CArray.int16(3,3) { 0x1234 }
    b = CArray.int16(3,3) { 0x3412 }
    is_asserted_by {  b == a.swap_bytes }
    is_asserted_by {  a == b.swap_bytes }
    is_asserted_by {  a == a.swap_bytes.swap_bytes }

    #
    a = CArray.int32(3,3) { 0x12345678 }
    b = CArray.int32(3,3) { 0x78563412 }
    is_asserted_by {  b == a.swap_bytes }
    is_asserted_by {  a == b.swap_bytes }
    is_asserted_by {  a == a.swap_bytes.swap_bytes }

    #
    if CArray::HAVE_COMPLEX
      c = CArray.int32(1) { 0x12345678 }
      x = c.refer(CA_FLOAT32, [1])[0]
      y = c.swap_bytes.refer(CA_FLOAT32, [1])[0]
      a = CArray.complex(3,3) { x + y*CI }
      b = CArray.complex(3,3) { y + x*CI }
      is_asserted_by {  b == a.swap_bytes }
      is_asserted_by {  a == b.swap_bytes }
      is_asserted_by {  a == a.swap_bytes.swap_bytes }
    end
  end

  example "seq" do
    # ---
    a = CArray.object(3).seq!
    is_asserted_by {  CA_OBJECT([0, 1, 2]) == a }

    # ---
    a = CArray.object(3).seq!(1)
    is_asserted_by {  CA_OBJECT([1, 2, 3]) == a }

    # ---
    a = CArray.object(3).seq!(1,2)
    is_asserted_by {  CA_OBJECT([1, 3, 5]) == a }

    # ---
    a = CArray.object(3).seq!(3,-1)
    is_asserted_by {  CA_OBJECT([3, 2, 1]) == a }

    # ---
    a = CArray.object(3).seq!("a", "a")
    is_asserted_by {  CA_OBJECT(["a", "aa", "aaa"]) == a }

    # ---
    a = CArray.object(3).seq!("a", :succ)
    is_asserted_by {  CA_OBJECT(["a", "b", "c"]) == a }

    # ---
    a = CArray.object(3).seq!("a", :succ) { |x| "@" + x }
    is_asserted_by {  CA_OBJECT(["@a", "@b", "@c"]) == a }

    # ---
    a = CArray.object(3).seq!("a", :succ)
    is_asserted_by {  CA_OBJECT(["@a", "@b", "@c"]) == (CA_OBJECT("@") + a) }

    # ---
    a = CArray.object(3).seq!([], [nil])
    is_asserted_by {  CA_OBJECT([[], [nil], [nil, nil]]) == a }
  end


end
