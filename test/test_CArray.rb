$:.unshift("../lib", "..")

require 'test/unit'
require 'carray'

class TestCArray < Test::Unit::TestCase

  def assert_carray (ca, type, dim, ary)
    assert_equal(ca, CArray.new(type, dim){ary})
  end

  def test_s_new
    a = CArray.new(CA_INT32, [3, 2, 1]) { 1 }
    assert_instance_of(CArray, a)
  end

  def test_s_type
    a = CArray.int32(3, 3) { 1 }
    assert_carray(a, CA_INT32, [3,3], 1)
  end

  def test_equal
    a = CArray.int32(3, 3)  { 0 }
    b = CArray.int32(3, 3)  { 0 }
    c = CArray.uint32(3, 3) { 0 }
    d = CArray.uint32(2, 3) { 0 }
    e = CArray.int32(3, 3)  { 1 }
    assert_equal(a == b, true)
    assert_equal(a != b, false)
    assert_equal(a == c, false)
    assert_equal(a != c, true)
    assert_equal(a == d, false)
    assert_equal(a != d, true)
    assert_equal(a == e, false)
    assert_equal(a != e, true)
  end

  def test_clone
    a = CArray.int32(3, 3)
    assert_equal(a.clone, a)
  end

  def test_to_s
    a = CArray.int8(3, 3) { 1 }
    assert_equal(a.to_s, "\001"*9)

    a = CArray.int32(3, 3) { 1 }
    assert_equal(a.to_s, [1].pack("l")*9)
  end

  def test_to_ca
    a = CArray.int32(3, 3).seq
    assert_equal(a.to_ca, a)

    c = CArray.int32(4, 4)
    c[0..2, 0..2] = a
    b = c[0..2, 0..2]
    assert_equal(b.to_ca, b)

    a = CArray.int32(3, 3).seq
    assert_carray(a[nil, 0].to_ca, CA_INT32, [3], [0,3,6])
    assert_carray(a[nil, 1].to_ca, CA_INT32, [3], [1,4,7])
    assert_carray(a[nil, 2].to_ca, CA_INT32, [3], [2,5,8])

    a = CArray.int32(3, 3).seq
#    assert_carray(a[0, nil].to_ca, CA_INT32, [3], [0,1,2])
#    assert_carray(a[1, nil].to_ca, CA_INT32, [3], [3,4,5])
#    assert_carray(a[2, nil].to_ca, CA_INT32, [3], [6,7,8])
  end

  def test_store_array
    a = CArray.int32(3, 3){1}
    b = CArray.int32(3, 3)
    b[] = [[1, 1, 1], [1, 1, 1], [1, 1, 1]]
    assert_equal(a, b)
  end

  def test_seq
    a = CArray.int32(3, 3)
    a.seq!
    assert_carray(a, CA_INT32, [3,3], [
        [0, 1, 2],
        [3, 4, 5],
        [6, 7, 8]
      ])
    assert_equal(a.seq, a)
  end

  def test_set_value
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

  def test_set_point
    a = CArray.int32(3, 3) { 0 }

    a[1, 1] = 1
    assert_equal(a[1,1], 1)

  end

  def test_set_addr
    a = CArray.int32(3, 3) { 0 }

    a[4] = 1
    assert_equal(a[1,1], 1)

    a[3..5] = -1
    assert_equal(a[1,1], -1)

    a[3..5] = [1,2,3]
    assert_equal(a[1,1], 2)
  end

  def test_dump_io ()
    a = CArray.int32(3, 3).seq!
    b = CArray.int32(3, 3)
    open("bintest", "w") { |io| a.dump_binary(io) }
    open("bintest")      { |io| b.load_binary(io) }
    assert_equal(a, b)

    a = CArray.int32(3, 3).seq!
    b = CArray.int32(3, 3).seq!
    open("bintest", "w") { |io| a[0..1, 0..1].dump_binary(io) }
    open("bintest")      { |io| b[0..1, 0..1].load_binary(io) }
    assert_equal(a, b)
  ensure
    File.unlink("bintest")
  end

  def test_dump_str ()
    a = CArray.int32(3, 3).seq!
    b = CArray.int32(3, 3)
    s = ""
    a.dump_binary(s)
    b.load_binary(s)
    assert_equal(a, b)

    a = CArray.int32(3, 3).seq!
    b = CArray.int32(3, 3).seq!
    s = ""
    a[0..1, 0..1].dump_binary(s)
    b[0..1, 0..1].load_binary(s)
    assert_equal(a, b)
  end

  def test_reverse
    a = CArray.uint8(100).seq!
    b = a[-1..0].to_ca
    assert_equal(a.reverse!, b)
  end

  def test_stat
    a = CArray.float32(3,3).seq!(1,2)
    stddev = Math.sqrt(((a - a.mean)**2).sum/(a.elements-1))

    assert_equal(a.max, 17)
    assert_equal(a.min, 1)
    assert_equal(a.sum, 81)
    assert_equal(a.mean, 9)
    assert_equal(a.stddev, stddev)

    c = CArray.int32(4,4)
    c[0..2, 0..2] = a
    a = c[0..2, 0..2]
    assert_equal(a.max, 17)
    assert_equal(a.min, 1)
    assert_equal(a.sum, 81)
    assert_equal(a.mean, 9)
    assert_equal(a.stddev, stddev)
  end

  def test_ancestors
    # ---
    a = CArray.int(3,3).seq!
    b = a.reshape(9)
    c = b.reshape(3,3)
    d = c[0..1,0..1]
    assert_equal(a, d.root_array)
    assert_equal([a,b,c,d], d.ancestors)
  end

end
