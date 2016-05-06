$:.unshift("../lib", "..")

require 'test/unit'
require 'carray'

class TestCArrayIndex < Test::Unit::TestCase

  def test_index
    a = CArray.int(3,3).seq!
    assert_raise(IndexError) { a[0, 0, 0]} ### invalid rank
    assert_raise(IndexError) { a[[0,1,1,2], 0]}
    assert_raise(IndexError) { a[[0,4], 0]}
    assert_raise(IndexError) { a[[0,3,2], 0]}
    assert_raise(NoMethodError) { a[:abcdefg, 0]}
    assert_raise(IndexError) { a[0, :abcdefg]}
  end

  def test_rubber_dim
    a = CArray.int(3,3,3,3,3).seq!

    assert_equal(a[false], a[nil, nil, nil, nil, nil])

    assert_equal(a[0,false], a[0, nil, nil, nil, nil])
    assert_equal(a[false,0], a[nil, nil, nil, nil, 0])
    assert_equal(a[0,false,0], a[0, nil, nil, nil, 0])

    assert_equal(a[0..1,false], a[0..1, nil, nil, nil, nil])
    assert_equal(a[false,0..1], a[nil, nil, nil, nil, 0..1])
    assert_equal(a[0..1,false,0..1], a[0..1, nil, nil, nil, 0..1])

    assert_equal(a[nil,false], a[nil, nil, nil, nil, nil])
    assert_equal(a[false,nil], a[nil, nil, nil, nil, nil])
    assert_equal(a[nil,false,nil], a[nil, nil, nil, nil, nil])

    assert_raise(IndexError) { a[0,0,0,0,0,0,false] }

  end


  def test_scan_index
    info = CArray.scan_index([3,3],[])
    assert_equal([info.type, info.index], [CA_REG_ALL, []])
    info = CArray.scan_index([3,3],[1])
    assert_equal([info.type, info.index], [CA_REG_ADDRESS, [1]])
    info = CArray.scan_index([3,3],[1..2])
    assert_equal([info.type, info.index], [CA_REG_ADDRESS_COMPLEX, [[1,2,1]]])
    info = CArray.scan_index([3,3],[1,1])
    assert_equal([info.type, info.index], [CA_REG_POINT, [1,1]])
    info = CArray.scan_index([3,3],[1,nil])
    assert_equal([info.type, info.index], [CA_REG_BLOCK, [1,[0,3,1]]])
    a = CArray.int(3,3).seq!
    i = CArray.int(3).seq!
    info = CArray.scan_index([3,3],[a.eq(4)])
    assert_equal([info.type, info.index], [CA_REG_SELECT, []])
    info = CArray.scan_index([3,3],[a])
    assert_equal([info.type, info.index], [CA_REG_MAPPING, []])
    info = CArray.scan_index([3,3],[i,i])
    assert_equal([info.type, info.index], [CA_REG_GRID, []])
    info = CArray.scan_index([3,3],[:%, :%, 2])
    assert_equal([info.type, info.index], [CA_REG_REPEAT, []])
    info = CArray.scan_index([3,3],[nil, nil, :*])
    assert_equal([info.type, info.index], [CA_REG_UNBOUND_REPEAT, []])
  end

  def test_addr2index
    a = CArray.int(3,3,3)
    assert_equal([1,1,1], a.addr2index(13))
    assert_equal(13, a.index2addr(1,1,1))
  end

end
