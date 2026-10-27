# spec_ai/test_narrow_integer_sum.rb
#
# sum and mean of an 8- or 16-bit integer array add the cells in int32
# blocks before they meet the float64 accumulator.  The answer is the
# exact integer sum, across block boundaries, at the type's extremes,
# with a mask, through a strided view and along an axis.

require "test/unit"
require "carray"

class TestNarrowIntegerSum < Test::Unit::TestCase

  RANGES = { CA_INT8 => -128..127, CA_UINT8 => 0..255,
             CA_INT16 => -32768..32767, CA_UINT16 => 0..65535 }

  def values (range, n, seed)
    r = Random.new(seed)
    v = Array.new(n) { r.rand(range) }
    v[0] = range.last if n > 0
    v[-1] = range.first if n > 1
    v
  end

  def test_exact_across_block_boundaries
    RANGES.each do |type, range|
      [0, 1, 31, 32, 32767, 32768, 32769, 65537].each do |n|
        v = values(range, n, n)
        a = CArray.new(type, [n]) { v }
        assert_equal v.sum.to_f, a.sum, "type #{type} n=#{n}"
        assert_in_delta v.sum.to_f / n, a.mean, 1e-9 * [1, range.last].max, "mean type #{type} n=#{n}" if n > 0
      end
    end
  end

  def test_all_extreme_cells
    RANGES.each do |type, range|
      [range.first, range.last].each do |x|
        a = CArray.new(type, [70000]) { x }
        assert_equal x * 70000.0, a.sum, "type #{type} x=#{x}"
      end
    end
  end

  def test_mask_view_and_axis
    RANGES.each do |type, range|
      v = values(range, 40000, 7)
      a = CArray.new(type, [40000]) { v }
      m = a.copy
      m[[0, 10000, 4]] = UNDEF
      kept = v.each_with_index.reject { |_, i| i % 4 == 0 && i < 40000 }.map(&:first)
      assert_equal kept.sum.to_f, m.sum, "masked type #{type}"
      assert_equal v.each_slice(2).map(&:first).sum.to_f, a[[0, 20000, 2]].sum, "strided type #{type}"
      b = a.reshape(4, 10000)
      assert_equal v.each_slice(10000).map { |row| row.sum.to_f }, b.sum(axis: 1).to_a, "axis 1 type #{type}"
      assert_equal (0...10000).map { |j| (0...4).sum { |i| v[i * 10000 + j] }.to_f }, b.sum(axis: 0).to_a, "axis 0 type #{type}"
    end
  end

end
