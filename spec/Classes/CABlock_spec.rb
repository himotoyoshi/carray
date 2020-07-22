
require 'carray'
require "rspec-power_assert"

describe "TestCABlock " do

  example "virtual_array" do
    a = CArray.int(3,3)
    b = a[0..1,0..1]
    r = b.parent
    t = b.root_array
    is_asserted_by { b.class == CABlock }
    is_asserted_by { r.class == CArray }
    is_asserted_by { a == r }
    is_asserted_by { a == t }
  end

  example "block" do
    a = CArray.int32(3, 3) { 1 }
    b = CArray.int32(3) { 1 }

    is_asserted_by { a[nil, 1] == b }
    is_asserted_by { a[1, nil] == b }

    a[nil, 1].seq!
    b.seq!
    is_asserted_by { a[nil, 1] == b }

    a[1, nil].seq!
    b.seq!
    is_asserted_by { a[1, nil] == b }
  end

  example "CABlock" do
    a = CArray.int32(4, 4)

    a.seq!
    b = a[1..2, 1..2]

    is_asserted_by { b.class == CABlock }
    is_asserted_by { b.rank == a.rank }
    is_asserted_by { b.dim == [2, 2] }
    is_asserted_by { b.elements == 4 }

    c = CArray.int32(2, 2){ [[5,6],[9,10]] }
    is_asserted_by { b == c }

    d = a.clone
    d[1..2, 1..2] = 1
    b[] = 1
    is_asserted_by { a == d }

    a.seq!
    is_asserted_by { b == c }
  end


  example "s_new" do
    a = CArray.int32(4, 4) { 1 }
    b = a[0..2, 0..2]
    is_asserted_by { b.data_type == CA_INT32 }
    is_asserted_by { b.rank == 2 }
    is_asserted_by { b.bytes == CArray.sizeof(CA_INT32) }
    is_asserted_by { b.size0 == [4, 4] }
    is_asserted_by { b.dim == [3, 3] }
    is_asserted_by { b.start == [0, 0] }
    is_asserted_by { b.step == [1, 1] }
    is_asserted_by { b.count == [3, 3] }
    is_asserted_by { b.elements == 9 }
    is_asserted_by { b == CArray.int32(3, 3) { 1 } }
  end

  example "block_of_block" do
    a = CArray.new(CA_INT32, [4, 4]).seq!
    b = a[0..2, 0..2]
    c = b[0..1, 0..1]

    is_asserted_by { b == CArray.int32(3, 3) {
       [
         [0, 1, 2],
         [4, 5, 6],
         [8, 9, 10],
       ]
       } }

    is_asserted_by { c == CArray.int32(2, 2) {
       [
         [0, 1],
         [4, 5],
       ]
       } }
  end

  example "block_of_block_set_value" do
    a = CArray.new(CA_INT32, [4, 4]).seq!
    b = a[0..2, 0..2]
    c = b[0..1, 0..1]

    a[0..1, 0..1] = 1

    is_asserted_by { b == CArray.int32(3, 3) {
       [
         [1, 1, 2],
         [1, 1, 6],
         [8, 9, 10],
       ]
       } }

    is_asserted_by { c == CArray.int32(2, 2) {
       [
         [1, 1],
         [1, 1],
       ]
       } }

    c[] = 2

    is_asserted_by { b == CArray.int32(3, 3) {
       [
         [2, 2, 2],
         [2, 2, 6],
         [8, 9, 10],
       ]
       } }

    is_asserted_by { a[0..1, 0..1] == CArray.int32(2, 2) {
       [
         [2, 2],
         [2, 2],
       ]
       } }
  end

  example "block_of_block_downrank" do
    a = CArray.new(CA_INT32, [4, 4, 4]) { 0 }
    b = a[0..2, 0..2, 1]
    c = b[0..1, 1]

    b.seq!

    is_asserted_by { b == a[0..2, 0..2, 1] }
    is_asserted_by { c == CArray.int32(2) { [1, 4] } }

    c[] = 1

    is_asserted_by { a[0..1, 1, 1] == CArray.int(2) { 1 } }
  end

  example "block_of_block_ref_address" do
    a = CArray.new(CA_INT32, [4, 4]).seq!
    b = a[0..2, 0..2]
    c = b[1..0, 0..1]

    is_asserted_by { c[2] == 0 }
    is_asserted_by { c[[2]] == CArray.int32(1) { [0] } }
    is_asserted_by { c[nil] == CArray.int32(4) { [4, 5, 0, 1] } }
    is_asserted_by { c[1..2] == CArray.int32(2) { [5, 0] } }
    is_asserted_by { c[[nil, 2]] == CArray.int32(2) { [4, 0] } }
    is_asserted_by { c[[(1..-1), 2]] == CArray.int32(2) { [5, 1] } }

    c[nil] = 1
    is_asserted_by { a[0..1, 0..1] == CArray.int32(2, 2) { 1 } }
  end

  example "refer_of_block" do
    a = CArray.new(CA_INT32, [4, 4]).seq!
    b = a[nil, 0..2]
    c = b.reshape(2, 6)
#    is_asserted_by { b.to_a.flatten, c.to_a.flatten)

    c[0, 0] = 3
    is_asserted_by { b[0, 0] == 3 }
    is_asserted_by { a[0, 0] == 3 }
  end

  example "refer_of_block_cast" do
    a = CArray.new(CA_INT32, [4, 4]).seq!
    b = a[nil, 0..2]
    c = b.reshape(2, 6)
    is_asserted_by { c.float32[0, 1] == 1.0 }
    is_asserted_by { c.float64[0, 1] == 1.0 }
  end

  example "block_of_block_self_asign" do
    a = CArray.new(CA_INT32, [4, 4]).seq!
    b = a[0..2, 0..2]
    b[0..1, 0..1] = a[0..1, 0..1]
  end

  example "block_move" do
    a = CArray.int(10, 10).seq!
    b = a[0..2, 0..2]

    is_asserted_by { b == CArray.int(3, 3) { [[0, 1, 2], [10, 11, 12], [20, 21, 22]] } }

    b.move(1,1)
    is_asserted_by { b == CArray.int(3, 3) { [[11, 12, 13], [21, 22, 23], [31, 32, 33]] } }

    b.move(7,7)
    is_asserted_by { b == CArray.int(3, 3) { [[77, 78, 79], [87, 88, 89], [97, 98, 99]] } }

    expect { b.move(8,8) }.to raise_error(ArgumentError) 
  end
  
end
