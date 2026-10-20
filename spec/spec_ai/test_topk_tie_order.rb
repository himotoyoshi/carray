$LOAD_PATH.unshift File.expand_path('../../ext', __dir__)
$LOAD_PATH.unshift File.expand_path('../../lib', __dir__)
require 'carray'
require 'test/unit'

# nsmallest / nlargest and their _index forms break ties by position, as
# `order` does, for every type and size: the cells first in the order
# (value, then NaN, then masked; the values descending for the largest).

class TestTopkTieOrder < Test::Unit::TestCase

  def reference (a, k, axis, desc)
    full = a.order(axis: axis, descending: desc).sort_index(axis: axis, kind: :stable)
    spec = Array.new(a.ndim, nil)
    spec[axis] = 0...k
    full[*spec].to_a
  end

  def test_small_cases
    assert_equal [1, 2], CA_INT32([1, 3, 3, 2, 3, 0]).nlargest_index(2, axis: 0).to_a
    assert_equal [1, 2], CA_FLOAT64([1, 3, 3, 2, 3, 0]).nlargest_index(2, axis: 0).to_a
    a = CA_FLOAT64([1, 0, 3, 2, 1, 1, 2, 3, 2, 3, 1, 0])
    assert_equal a.sort_index.to_a.first(5), a.nsmallest_index(5, axis: 0).to_a
  end

  # A float array with no NaN and no masked cell; ties go by position.
  def test_float_without_nan_or_masked_cells
    a = CA_FLOAT64(Array.new(2000) { |i| (i * 37 % 11) * 0.5 })
    m = a.copy
    m[3] = UNDEF
    m[3] = 2.0
    m[3] = a[3]
    [a, m].each do |x|
      [1, 7, 300].each do |k|
        assert_equal reference(x, k, 0, true), x.nlargest_index(k, axis: 0).to_a
        assert_equal reference(x, k, 0, false), x.nsmallest_index(k, axis: 0).to_a
      end
    end
    b = a.reshape(40, 50)
    assert_equal reference(b, 9, 1, true), b.nlargest_index(9, axis: 1).to_a
  end

  def test_random_against_order
    srand(11)
    types = [:int8, :uint8, :int32, :int64, :uint64, :float32, :float64, :boolean]
    300.times do
      t = types.sample
      shape = [[rand(1..30)], [rand(1..6), rand(1..12)], [rand(1..3), rand(1..5), rand(1..6)]].sample
      a = CArray.new(t, shape)
      a[] = t == :boolean ? Array.new(a.elements) { [true, false].sample } : Array.new(a.elements) { rand(0..3) }
      if [:float32, :float64].include?(t) && rand < 0.4
        a[CArray.boolean(*shape) { |*| rand < 0.2 }] = Float::NAN
      end
      a[CArray.boolean(*shape) { |*| rand < 0.15 }] = UNDEF if rand < 0.4
      axis = rand(a.ndim)
      k = rand(1..a.shape[axis])
      [false, true].each do |desc|
        got = desc ? a.nlargest_index(k, axis: axis) : a.nsmallest_index(k, axis: axis)
        assert_equal reference(a, k, axis, desc), got.to_a,
                     "#{t} #{shape} axis=#{axis} k=#{k} desc=#{desc}"
      end
    end
  end

  # Fibers longer than the walk keeps at a time (a few times k), so the
  # kept cells are cut back to k during the walk: in order, in reverse
  # order, with many ties, NaN and masked cells, the extremes of the
  # type, and along an axis whose fibers are not contiguous.
  def test_long_fibers
    srand(5)
    len = 3000
    {
      int64:   [-2**63, 2**63 - 1, 0, 1],
      uint8:   [0, 255, 7],
      float32: [-0.0, 0.0, Float::INFINITY, Float::NAN, 1.5],
      float64: [-Float::INFINITY, Float::INFINITY, Float::NAN, 2.5, -0.0, 0.0],
    }.each do |t, pool|
      rand_a = CArray.new(t, [len]); rand_a[] = Array.new(len) { pool.sample }
      masked = rand_a.copy; masked[CArray.boolean(len) { |*| rand < 0.1 }] = UNDEF
      asc = CArray.new(t, [len]).seq!
      [rand_a, masked, asc, asc.flip(0)].each do |a|
        [1, 3, 40, 999].each do |k|
          [true, false].each do |desc|
            got = desc ? a.nlargest_index(k, axis: 0) : a.nsmallest_index(k, axis: 0)
            assert_equal reference(a, k, 0, desc), got.to_a, "#{t} k=#{k} desc=#{desc}"
          end
        end
      end
      b = masked.reshape(60, 50)
      [0, 1].each do |axis|
        assert_equal reference(b, 7, axis, true), b.nlargest_index(7, axis: axis).to_a
        assert_equal reference(b, 7, axis, false), b.nsmallest_index(7, axis: axis).to_a
      end
    end
  end

  def test_values_follow_the_indices
    a = CA_INT32([1, 3, 3, 2, 3, 0])
    assert_equal [3, 3], a.nlargest(2).to_a
    assert_equal [0, 1], a.nsmallest(2).to_a
  end

end
