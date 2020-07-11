
require 'carray'
require "rspec-power_assert"

describe "TestCArray " do

  def assert_carray (ca, type, dim, ary)
    is_asserted_by { ca == CArray.new(type, dim) { ary } }
  end

  example "s_new" do
    a = CArray.new(CA_INT32, [3, 2, 1]) { 1 }
    is_asserted_by { a.class == CArray }
  end

  example "s_type" do
    a = CArray.int32(3, 3) { 1 }
    assert_carray(a, CA_INT32, [3,3], 1)
  end

  example "equal" do
    a = CArray.int32(3, 3)  { 0 }
    b = CArray.int32(3, 3)  { 0 }
    c = CArray.uint32(3, 3) { 0 }
    d = CArray.uint32(2, 3) { 0 }
    e = CArray.int32(3, 3)  { 1 }
    is_asserted_by { (a == b) == true }
    is_asserted_by { (a != b) == false }
    is_asserted_by { (a == c) == false }
    is_asserted_by { (a != c) == true }
    is_asserted_by { (a == d) == false }
    is_asserted_by { (a != d) == true }
    is_asserted_by { (a == e) == false }
    is_asserted_by { (a != e) == true }
  end

  example "clone" do
    a = CArray.int32(3, 3)
    is_asserted_by { a.clone == a }
  end

  example "to_s" do
    a = CArray.int8(3, 3) { 1 }
    is_asserted_by { a.to_s == ("\u0001" * 9) }

    a = CArray.int32(3, 3) { 1 }
    is_asserted_by { a.to_s == ([1].pack("l") * 9) }
  end

  example "to_ca" do
    a = CArray.int32(3, 3).seq
    is_asserted_by { a.to_ca == a }

    c = CArray.int32(4, 4)
    c[0..2, 0..2] = a
    b = c[0..2, 0..2]
    is_asserted_by { b.to_ca == b }

    a = CArray.int32(3, 3).seq
    assert_carray(a[nil, 0].to_ca, CA_INT32, [3], [0,3,6])
    assert_carray(a[nil, 1].to_ca, CA_INT32, [3], [1,4,7])
    assert_carray(a[nil, 2].to_ca, CA_INT32, [3], [2,5,8])

    a = CArray.int32(3, 3).seq
#    assert_carray(a[0, nil].to_ca, CA_INT32, [3], [0,1,2])
#    assert_carray(a[1, nil].to_ca, CA_INT32, [3], [3,4,5])
#    assert_carray(a[2, nil].to_ca, CA_INT32, [3], [6,7,8])
  end

  example "store_array" do
    a = CArray.int32(3, 3){1}
    b = CArray.int32(3, 3)
    b[] = [[1, 1, 1], [1, 1, 1], [1, 1, 1]]
    is_asserted_by { a == b }
  end

  example "seq" do
    a = CArray.int32(3, 3)
    a.seq!
    assert_carray(a, CA_INT32, [3,3], [
        [0, 1, 2],
        [3, 4, 5],
        [6, 7, 8]
      ])
    is_asserted_by { a.seq == a }
  end

  example "set_value" do
    a = CArray.int32(3, 3)
    b = CArray.int32(3, 3)

    a[] = 0
    assert_carray(a, CA_INT32, [3,3], [
        [0, 0, 0],
        [0, 0, 0],
        [0, 0, 0]
      ])

    # reg_point
    a[] = 0
    a[1, 1] = 1
    assert_carray(a, CA_INT32, [3,3], [
        [0, 0, 0],
        [0, 1, 0],
        [0, 0, 0]
      ])


    # reg_block : idx_all
    a[] = 0
    a[nil, 1] = 1
    assert_carray(a, CA_INT32, [3,3], [
        [0, 1, 0],
        [0, 1, 0],
        [0, 1, 0]
      ])


    # reg_block : idx_block
    a[] = 0
    a[0..1, 1] = 1
    assert_carray(a, CA_INT32, [3,3], [
        [0, 1, 0],
        [0, 1, 0],
        [0, 0, 0]
      ])

    # reg_block : idx_block
    a[] = 0
    a[[0..2,2], 1] = 1
    assert_carray(a, CA_INT32, [3,3], [
        [0, 1, 0],
        [0, 0, 0],
        [0, 1, 0]
      ])
  end

  example "set_point" do
    a = CArray.int32(3, 3) { 0 }

    a[1, 1] = 1
    is_asserted_by { a[1, 1] == 1 }

  end

  example "set_addr" do
    a = CArray.int32(3, 3) { 0 }

    a[4] = 1
    is_asserted_by { a[1, 1] == 1 }

    a[3..5] = -1
    is_asserted_by { a[1, 1] == (-1) }

    a[3..5] = [1,2,3]
    is_asserted_by { a[1, 1] == 2 }
  end

  example "dump_io ()" do
    a = CArray.int32(3, 3).seq!
    b = CArray.int32(3, 3)
    open("bintest", "w") { |io| a.dump_binary(io) }
    open("bintest")      { |io| b.load_binary(io) }
    is_asserted_by { a == b }

    a = CArray.int32(3, 3).seq!
    b = CArray.int32(3, 3).seq!
    open("bintest", "w") { |io| a[0..1, 0..1].dump_binary(io) }
    open("bintest")      { |io| b[0..1, 0..1].load_binary(io) }
    is_asserted_by { a == b }
  ensure
    File.unlink("bintest")
  end

  example "dump_str ()" do
    a = CArray.int32(3, 3).seq!
    b = CArray.int32(3, 3)
    s = ""
    a.dump_binary(s)
    b.load_binary(s)
    is_asserted_by { a == b }

    a = CArray.int32(3, 3).seq!
    b = CArray.int32(3, 3).seq!
    s = ""
    a[0..1, 0..1].dump_binary(s)
    b[0..1, 0..1].load_binary(s)
    is_asserted_by { a == b }
  end

  example "reverse" do
    a = CArray.uint8(100).seq!
    b = a[-1..0].to_ca
    is_asserted_by { a.reverse! == b }
  end

  example "stat" do
    a = CArray.float32(3,3).seq!(1,2)
    stddev = Math.sqrt(((a - a.mean)**2).sum/(a.elements-1))

    is_asserted_by { a.max == 17 }
    is_asserted_by { a.min == 1 }
    is_asserted_by { a.sum == 81 }
    is_asserted_by { a.mean == 9 }
    is_asserted_by { a.stddev == stddev }

    c = CArray.int32(4,4)
    c[0..2, 0..2] = a
    a = c[0..2, 0..2]
    is_asserted_by { a.max == 17 }
    is_asserted_by { a.min == 1 }
    is_asserted_by { a.sum == 81 }
    is_asserted_by { a.mean == 9 }
    is_asserted_by { a.stddev == stddev }
  end

  example "ancestors" do
    # ---
    a = CArray.int(3,3).seq!
    b = a.reshape(9)
    c = b.reshape(3,3)
    d = c[0..1,0..1]
    is_asserted_by { a == d.root_array }
    is_asserted_by { [a, b, c, d] == d.ancestors }
  end

end
