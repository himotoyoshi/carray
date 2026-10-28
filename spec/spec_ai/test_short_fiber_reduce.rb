require "test/unit"
require "carray"

# A single-axis reduction over the innermost axis of a contiguous array with
# short rows is folded row by row in place (shortcut short_fiber_reduce).
# The answers are checked against the rows read in Ruby, on both sides of
# the row length where the shortcut hands over to the general walk.
class TestShortFiberReduce < Test::Unit::TestCase

  def rows (a)
    a.to_a.flatten.each_slice(a.shape[-1]).to_a
  end

  def float_array (shape)
    a = CArray.float64(*shape)
    a[] = Array.new(a.elements) { |i| ((i * 37) % 23) * 0.25 - 2.0 }
    return a
  end

  def test_sum_mean_prod_across_row_lengths
    [1, 2, 4, 7, 16, 17, 32, 33, 40].each do |m|
      a = float_array([5, m])
      sums  = rows(a).map(&:sum)
      prods = rows(a).map { |r| r.inject(:*) }
      assert_equal sums, a.sum(axis: 1).to_a, "sum m=#{m}"
      assert_equal sums.map { |s| s / m }, a.mean(axis: 1).to_a, "mean m=#{m}"
      assert_equal prods, a.prod(axis: 1).to_a, "prod m=#{m}"
    end
  end

  def test_min_max_across_row_lengths
    [1, 3, 8, 16, 17, 32].each do |m|
      a = float_array([4, m])
      assert_equal rows(a).map(&:min), a.min(axis: 1).to_a, "min m=#{m}"
      assert_equal rows(a).map(&:max), a.max(axis: 1).to_a, "max m=#{m}"
    end
  end

  def test_integer_types_keep_their_answers
    [:int8, :uint8, :int16, :int32, :int64, :uint64].each do |t|
      a = CArray.new(t, [6, 5])
      a[] = Array.new(30) { |i| (i * 7) % 11 }
      assert_equal rows(a).map(&:sum), a.sum(axis: 1).to_a, "sum #{t}"
      assert_equal rows(a).map(&:max), a.max(axis: 1).to_a, "max #{t}"
      assert_equal rows(a).map(&:sum), a.accumulate(axis: 1).to_a, "accumulate #{t}"
    end
  end

  def test_nan_rows_for_min_and_max
    nan = Float::NAN
    a = CArray.float64(4, 3)
    a[] = [[nan, nan, nan],
           [1.0, nan, 2.0],
           [Float::INFINITY, Float::INFINITY, Float::INFINITY],
           [-Float::INFINITY, nan, -Float::INFINITY]]
    min = a.min(axis: 1).to_a
    max = a.max(axis: 1).to_a
    assert min[0].nan?
    assert max[0].nan?
    assert_equal [1.0, Float::INFINITY, -Float::INFINITY], min[1..3]
    assert_equal [2.0, Float::INFINITY, -Float::INFINITY], max[1..3]
  end

  def test_three_dimensional_and_keep_axis
    a = float_array([3, 4, 5])
    expect = rows(a).map(&:sum)
    assert_equal expect, a.sum(axis: 2).to_a.flatten
    assert_equal [3, 4], a.sum(axis: 2).shape
    assert_equal [3, 4, 1], a.sum(axis: 2, keep_axis: true).shape
    assert_equal expect, a.sum(axis: -1, keep_axis: true).to_a.flatten
  end

  def test_min_count_beyond_the_row_gives_undef
    a = float_array([3, 4])
    r = a.sum(axis: 1, min_count: 5)
    assert_equal [true, true, true], r.is_masked.to_a
    assert_equal rows(a).map(&:sum), a.sum(axis: 1, min_count: 4).to_a
  end

  def test_views_and_masked_arrays_answer_the_same
    a = float_array([6, 4])
    expect = rows(a).map(&:sum)
    assert_equal expect, a.reshape(6, 4).sum(axis: 1).to_a
    assert_equal rows(a)[1..3].map(&:sum), a[1..3, nil].sum(axis: 1).to_a
    assert_equal rows(a.transpose.copy).map(&:sum), a.transpose.sum(axis: 1).to_a
    m = a.copy
    m[2, 1] = UNDEF
    r = m.sum(axis: 1).to_a
    assert_equal expect[2] - a[2, 1], r[2]
  end

end
