# spec_ai/test_narrow_integer_sum.rb
#
# sum and mean of an 8- or 16-bit integer array add the cells in int32
# blocks before they meet the float64 accumulator, and the variance family
# adds sum (x - c)^2 around the integer c nearest the mean.  The answers
# match exact arithmetic across block boundaries, at the type's extremes,
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

  def exact_variance (v)
    n = v.size
    mean = Rational(v.sum, n)
    m2 = v.sum { |x| (x - mean) ** 2 }
    [m2 / (n - 1), m2 / n]
  end

  def assert_close (want, got, message)
    if want == 0
      assert_equal 0.0, got, message
    else
      assert_operator ((got - want) / want).abs, :<, 1e-14, message
    end
  end

  def test_variance_family_matches_exact_arithmetic
    RANGES.each do |type, range|
      [2, 31, 32768, 32769, 70001].each do |n|
        [values(range, n, n), Array.new(n, range.last),
         Array.new(n) { |i| i.even? ? range.first : range.last }].each_with_index do |v, kind|
          a = CArray.new(type, [n]) { v }
          s, p = exact_variance(v)
          tag = "type #{type} n=#{n} kind=#{kind}"
          assert_close s, a.variance, "variance #{tag}"
          assert_close p, a.variancep, "variancep #{tag}"
          assert_close Math.sqrt(s), a.stddev, "stddev #{tag}"
          assert_close Math.sqrt(p), a.stddevp, "stddevp #{tag}"
        end
      end
    end
  end

  # A few distinct values at the top or bottom of the range give a mean far
  # from zero that is not an integer, where its rounding error would show
  # if it entered the answer to the first order.
  def test_variance_of_a_small_spread_at_the_edge_of_the_range
    a = CArray.uint16(7)
    a[] = [65534, 65534, 65535, 65535, 65535, 65535, 65535]
    assert_close Rational(5, 21), a.variance, "uint16 7 cells"
    RANGES.each do |type, range|
      [range.first, range.last].each do |edge|
        [7, 1001, 40001].each do |n|
          r = Random.new(n)
          v = Array.new(n) { (edge + r.rand(-2..2)).clamp(range) }
          a = CArray.new(type, [n]) { v }
          s, p = exact_variance(v)
          tag = "type #{type} edge=#{edge} n=#{n}"
          assert_close s, a.variance, "variance #{tag}"
          assert_close p, a.variancep, "variancep #{tag}"
        end
      end
    end
  end

  # Contiguous rows of a block reduced together share the block's mean.
  def test_variance_of_contiguous_rows_reduced_together
    RANGES.each do |type, range|
      v = values(range, 3 * 5000, 13).map { |x| (x / 4) + range.last / 2 }
      v = v.map { |x| x.clamp(range) }
      a = CArray.new(type, [3, 5001]) { 0 }
      a[nil, 0...5000] = CArray.new(type, [3, 5000]) { v }
      s, = exact_variance(v)
      assert_close s, a[nil, 0...5000].variance, "type #{type}"
    end
  end

  def test_variance_with_mask_and_axis
    RANGES.each do |type, range|
      v = values(range, 40000, 11)
      a = CArray.new(type, [40000]) { v }
      m = a.copy
      m[[0, 10000, 4]] = UNDEF
      kept = v.each_with_index.reject { |_, i| i % 4 == 0 && i < 40000 }.map(&:first)
      assert_close exact_variance(kept)[0], m.variance, "masked type #{type}"
      rows = v.each_slice(10000).map { |row| exact_variance(row)[0] }
      a.reshape(4, 10000).variance(axis: 1).to_a.zip(rows).each do |got, want|
        assert_close want, got, "axis 1 type #{type}"
      end
    end
  end

end
