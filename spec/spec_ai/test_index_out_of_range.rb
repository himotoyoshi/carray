require "test/unit"
require "carray"

# An index, address or coordinate counts from the end when negative, and
# one outside the length after that raises IndexError, at every door.  A
# door is listed here with how to reach index i on a length-4 axis.

class TestIndexOutOfRange < Test::Unit::TestCase

  N = 4

  def a  = CA_INT32([10, 11, 12, 13])
  def a2 = CArray.int32(2, N).seq!

  DOORS = {
    "a[i]"            => ->(t, i) { t.a[i] },
    "a[i] = v"        => ->(t, i) { x = t.a; x[i] = 0; x.to_a },
    "a2[0, i]"        => ->(t, i) { t.a2[0, i] },
    "a[[i]]"          => ->(t, i) { t.a[[i]].to_a },
    "a[[i]] = v"      => ->(t, i) { x = t.a; x[[i]] = 0; x.to_a },
    "a[CArray]"       => ->(t, i) { t.a[CA_INT64([i])].to_a },
    "a[CArray] = v"   => ->(t, i) { x = t.a; x[CA_INT64([i])] = 0; x.to_a },
    "a[i..i]"         => ->(t, i) { t.a[i..i].to_a },
    "a[[i, 1]]"       => ->(t, i) { t.a[[i, 1]].to_a },
    "a[[i, 1]] = v"   => ->(t, i) { x = t.a; x[[i, 1]] = 0; x.to_a },
    "a[[i, 1, 1]]"    => ->(t, i) { t.a[[i, 1, 1]].to_a },
    "a2[[i, 1], nil]" => ->(t, i) { t.a2[nil, [i, 1]].to_a },
    "elem_fetch"      => ->(t, i) { t.a.elem_fetch(i) },
    "elem_store"      => ->(t, i) { x = t.a; x.elem_store(i, 0); x.to_a },
    "index2addr"      => ->(t, i) { t.a2.index2addr(0, i) },
    "addr2index"      => ->(t, i) { t.a.addr2index(i) },
    "take_along_axis" => ->(t, i) { t.a2.take_along_axis(CArray.int64(2, 1) { i }, axis: 1).to_a },
    "axis2addr"       => ->(t, i) { t.a2.axis2addr(CArray.int64(2, 1) { i }, axis: 1).to_a },
    "gather_nd"       => ->(t, i) { t.a2.gather_nd(CA_INT64([[0, i]])).to_a },
    "put_nd"          => ->(t, i) { x = t.a2; x.put_nd(CA_INT64([[0, i]]), CA_INT32([9])); x.to_a },
    "scatter_add!"    => ->(t, i) { x = t.a; x.scatter_add!(CA_INT64([i]), CA_INT32([1])); x.to_a },
    "CAFrame row"     => ->(t, i) { CAFrame.new({ "x" => t.a })[i] },
  }

  def test_a_negative_index_counts_from_the_end
    DOORS.each do |name, door|
      (1..N).each do |k|
        assert_equal door.(self, N - k), door.(self, -k), "#{name} #{-k}"
      end
    end
  end

  def test_an_index_outside_raises_index_error
    DOORS.each do |name, door|
      [N, N + 1, -N - 1, 100, -100, 2**40].each do |i|
        assert_raise(IndexError, "#{name} #{i}") { door.(self, i) }
      end
    end
  end
  # A block's start counts from the end when negative; its last cell is
  # counted from that start and has to lie inside as it is -- it does not
  # wrap back in from either end.
  BLOCKS_INSIDE  = [[0, 4], [-4, 4], [-2, 2], [-1, 1], [1, 2, 2], [-3, 2, 2],
                    [-1, 2, -2], [3, 4, -1], [2, 0], [-1, 0]]
  BLOCKS_OUTSIDE = [[-1, 2], [-2, 3], [-4, 5], [0, 5], [1, 2, -2],
                    [-1, 3, -2], [-3, 2, 3], [3, 2, 1]]

  def test_a_block_stays_inside
    BLOCKS_INSIDE.each do |b|
      start = b[0] < 0 ? b[0] + N : b[0]
      step  = b[2] || 1
      want  = Array.new(b[1]) { |k| a.to_a[start + k * step] }
      assert_equal want, a[b].to_a, b.inspect
      x = a
      x[b] = 0
      assert_equal want.size, x.to_a.count(0), "#{b.inspect} = 0"
    end
    BLOCKS_OUTSIDE.each do |b|
      assert_raise(IndexError, b.inspect) { a[b] }
      assert_raise(IndexError, "#{b.inspect} = 0") { x = a; x[b] = 0 }
    end
  end

  # valid_addr? and valid_index? say whether an index names a cell, so they
  # answer what the doors do.
  def test_valid_predicates_agree_with_the_doors
    ((-N - 2)..(N + 1)).each do |i|
      raises = begin; a[i]; false; rescue IndexError; true; end
      assert_equal !raises, a.valid_addr?(i), "valid_addr? #{i}"
      assert_equal !raises, a2.valid_index?(0, i), "valid_index? 0, #{i}"
    end
  end
end
