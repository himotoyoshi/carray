require "test/unit"
require "carray"

# A block of a CARoll moves to and from its parent as a few strided boxes:
# one per run of consecutive parent rows when the inner range does not wrap,
# and through a scratch when it does.  Reads must equal the same block of
# the whole view's copy, and writes must land where writing the whole copy
# and rolling it back puts them.
class TestRollRegionTransfer < Test::Unit::TestCase

  ROLLS = [[1, 1], [0, 3], [4, 0], [-2, 5], [7, -1]]

  def blocks (rows, cols)
    [
      [nil, 0..2], [nil, 2..5], [nil, (cols - 3)..(cols - 1)], [nil, 4],
      [1..3, 0..(cols - 1)], [(rows - 2)..(rows - 1), 1..3], [0..0, 0..0],
    ]
  end

  def check (type)
    ROLLS.each do |rl|
      base = CArray.send(type, 5, 6).seq
      blocks(5, 6).each do |bx|
        v = base.roll(*rl)
        assert_equal v.copy[*bx].to_a, v[*bx].copy.to_a, "read #{type} #{rl} #{bx}"

        b = base.copy
        src = CArray.send(type, *b.roll(*rl)[*bx].shape).seq + 100
        b.roll(*rl)[*bx] = src
        full = base.roll(*rl).copy
        full[*bx] = src
        assert_equal full.roll(*rl.map { |x| -x }).to_a, b.to_a,
                     "write #{type} #{rl} #{bx}"
      end
    end
  end

  def test_float64
    check(:float64)
  end

  def test_int32
    check(:int32)
  end

  def test_object
    check(:object)
  end

  def test_3d
    base = CArray.int32(3, 4, 5).seq
    v = base.roll(1, 2, 3)
    [[nil, nil, 1..3], [nil, 1..2, 0..4], [0..1, nil, 3..4], [nil, nil, 4]].each do |bx|
      assert_equal v.copy[*bx].to_a, v[*bx].copy.to_a, "read #{bx}"
    end
  end

  def test_masked
    base = CArray.float64(5, 6).seq
    base[2, 3] = UNDEF
    v = base.roll(1, 4)
    [[nil, 0..2], [nil, 1..4], [1..3, nil]].each do |bx|
      assert_equal v.copy[*bx].to_a, v[*bx].copy.to_a, "read #{bx}"
    end
  end
end
