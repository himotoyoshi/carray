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

  # A float array with no NaN and no masked cell takes the partition, as an
  # integer array does; ties still go by position.
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

  def test_values_follow_the_indices
    a = CA_INT32([1, 3, 3, 2, 3, 0])
    assert_equal [3, 3], a.nlargest(2).to_a
    assert_equal [0, 1], a.nsmallest(2).to_a
  end

end
