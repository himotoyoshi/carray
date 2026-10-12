require "test/unit"
require "carray"

# count_masked / count_not_masked answer the same with and without a mask:
# every axis named reduces to a number, keep_axis: keeps the reduced axes,
# and an axis argument is checked the same way either way.
class TestCountMaskAxes < Test::Unit::TestCase

  def arrays
    plain  = CArray.float64(2, 3)
    masked = CArray.float64(2, 3)
    masked[0, 1] = UNDEF
    [[plain, 6, 0], [masked, 5, 1]]
  end

  def test_every_axis_named
    arrays.each do |a, present, absent|
      [[0, 1], [1, 0], [-1, 0]].each do |axes|
        assert_equal present, a.count_not_masked(axis: axes), "#{axes} not masked"
        assert_equal absent,  a.count_masked(axis: axes),     "#{axes} masked"
      end
    end
  end

  def test_keep_axis
    plain, masked = arrays.map(&:first)
    assert_equal [[3], [3]], plain.count_not_masked(axis: 1, keep_axis: true).to_a
    assert_equal [[2], [3]], masked.count_not_masked(axis: 1, keep_axis: true).to_a
    assert_equal [[0], [0]], plain.count_masked(axis: 1, keep_axis: true).to_a
    assert_equal [[1], [0]], masked.count_masked(axis: 1, keep_axis: true).to_a
    assert_equal [[6]], plain.count_not_masked(axis: [0, 1], keep_axis: true).to_a
  end

  def test_axis_checked_alike
    arrays.each do |a, _, _|
      assert_raise(ArgumentError) { a.count_not_masked(axis: 5) }
      assert_raise(ArgumentError) { a.count_not_masked(axis: []) }
      assert_raise(ArgumentError) { a.count_masked(axis: [0, 0]) }
    end
  end

  def test_min_count
    plain = arrays.first.first
    assert_equal [UNDEF, UNDEF, UNDEF], plain.count_not_masked(axis: 0, min_count: 3).to_a
  end
end
