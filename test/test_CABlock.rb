$:.unshift("../lib", "..")

require 'test/unit'
require 'carray'

class TestCABlock < Test::Unit::TestCase

  def test_virtual_array
    a = CArray.int(3,3)
    b = a[0..1,0..1]
    r = b.parent
    t = b.root_array
    assert_instance_of(CABlock, b)
    assert_instance_of(CArray, r)
    assert_equal(a, r)
    assert_equal(a, t)
  end

  def test_block
    a = CArray.int32(3, 3) { 1 }
    b = CArray.int32(3) { 1 }

    assert_equal(a[nil, 1], b)
    assert_equal(a[1, nil], b)

    a[nil, 1].seq!
    b.seq!
    assert_equal(a[nil, 1], b)

    a[1, nil].seq!
    b.seq!
    assert_equal(a[1, nil], b)
  end

  def test_CABlock
    a = CArray.int32(4, 4)

    a.seq!
    b = a[1..2, 1..2]

    assert_instance_of(CABlock, b)
    assert_equal(b.rank, a.rank)
    assert_equal(b.dim, [2,2])
    assert_equal(b.elements, 4)

    c = CArray.int32(2, 2){ [[5,6],[9,10]] }
    assert_equal(b, c)

    d = a.clone
    d[1..2, 1..2] = 1
    b[] = 1
    assert_equal(a, d)

    a.seq!
    assert_equal(b, c)
  end


  def test_s_new
    a = CArray.int32(4, 4) { 1 }
    b = a[0..2, 0..2]
    assert_equal(b.data_type, CA_INT32)
    assert_equal(b.rank, 2)
    assert_equal(b.bytes, CArray.sizeof(CA_INT32))
    assert_equal(b.size0, [4, 4])
    assert_equal(b.dim, [3, 3])
    assert_equal(b.start, [0, 0])
    assert_equal(b.step, [1, 1])
    assert_equal(b.count, [3, 3])
    assert_equal(b.elements, 9)
    assert_equal(b, CArray.int32(3,3){1})
  end

  def test_block_of_block
    a = CArray.new(CA_INT32, [4, 4]).seq!
    b = a[0..2, 0..2]
    c = b[0..1, 0..1]

    assert_equal(b, CArray.int32(3, 3) {
       [
         [0, 1, 2],
         [4, 5, 6],
         [8, 9, 10],
       ]
     })

    assert_equal(c, CArray.int32(2, 2) {
       [
         [0, 1],
         [4, 5],
       ]
     })
  end

  def test_block_of_block_set_value
    a = CArray.new(CA_INT32, [4, 4]).seq!
    b = a[0..2, 0..2]
    c = b[0..1, 0..1]

    a[0..1, 0..1] = 1

    assert_equal(b, CArray.int32(3, 3) {
       [
         [1, 1, 2],
         [1, 1, 6],
         [8, 9, 10],
       ]
     })

    assert_equal(c, CArray.int32(2, 2) {
       [
         [1, 1],
         [1, 1],
       ]
     })

    c[] = 2

    assert_equal(b, CArray.int32(3, 3) {
       [
         [2, 2, 2],
         [2, 2, 6],
         [8, 9, 10],
       ]
     })

    assert_equal(a[0..1, 0..1], CArray.int32(2, 2) {
       [
         [2, 2],
         [2, 2],
       ]
     })
  end

  def test_block_of_block_downrank
    a = CArray.new(CA_INT32, [4, 4, 4]) { 0 }
    b = a[0..2, 0..2, 1]
    c = b[0..1, 1]

    b.seq!

    assert_equal(b, a[0..2, 0..2, 1])
    assert_equal(c, CArray.int32(2) { [1, 4] })

    c[] = 1

    assert_equal(a[0..1, 1, 1], CArray.int(2) {1})
  end

  def test_block_of_block_ref_address
    a = CArray.new(CA_INT32, [4, 4]).seq!
    b = a[0..2, 0..2]
    c = b[1..0, 0..1]

    assert_equal(c[2], 0)
    assert_equal(c[[2]], CArray.int32(1) { [0] })
    assert_equal(c[nil], CArray.int32(4) { [4, 5, 0, 1] })
    assert_equal(c[1..2], CArray.int32(2) { [5, 0] })
    assert_equal(c[[nil,2]], CArray.int32(2) { [4, 0] })
    assert_equal(c[[1..-1,2]], CArray.int32(2) { [5, 1] })

    c[nil] = 1
    assert_equal(a[0..1,0..1], CArray.int32(2,2) { 1 })
  end

  def test_refer_of_block
    a = CArray.new(CA_INT32, [4, 4]).seq!
    b = a[nil, 0..2]
    c = b.reshape(2, 6)
#    assert_equal(b.to_a.flatten, c.to_a.flatten)

    c[0, 0] = 3
    assert_equal(b[0, 0], 3)
    assert_equal(a[0, 0], 3)
  end

  def test_refer_of_block_cast
    a = CArray.new(CA_INT32, [4, 4]).seq!
    b = a[nil, 0..2]
    c = b.reshape(2, 6)
    assert_equal(c.float32[0, 1], 1.0)
    assert_equal(c.float64[0, 1], 1.0)
  end

  def test_block_of_block_self_asign
    a = CArray.new(CA_INT32, [4, 4]).seq!
    b = a[0..2, 0..2]
    b[0..1, 0..1] = a[0..1, 0..1]
  end

  def test_block_move
    a = CArray.int(10, 10).seq!
    b = a[0..2, 0..2]

    assert_equal(b, CArray.int(3, 3){[[0,1,2],[10,11,12],[20,21,22]]})

    b.move(1,1)
    assert_equal(b, CArray.int(3, 3){[[11,12,13],[21,22,23],[31,32,33]]})

    b.move(7,7)
    assert_equal(b, CArray.int(3, 3){[[77,78,79],[87,88,89],[97,98,99]]})

    assert_raise(ArgumentError) {
      b.move(8,8)
    }
  end
  
end
