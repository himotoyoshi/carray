require "test/unit"
require "carray"

# A tolerance is a distance; a negative or NaN eps acted as an exact match.
class TestSearchNegativeEps < Test::Unit::TestCase

  def test_refused
    a = CA_DOUBLE([1, 2, 3])
    assert_raise(ArgumentError) { a.search(2.0, -0.1) }
    assert_raise(ArgumentError) { a.search(2.0, Float::NAN) }
    assert_raise(ArgumentError) { a.search_addr(2.0, -1) }
    assert_raise(ArgumentError) { a.search(2.0, -1, axis: 0) }
  end

  def test_zero_and_positive_still_work
    a = CA_DOUBLE([1, 2, 3])
    assert_equal 1, a.search(2.0, 0)
    assert_equal 1, a.search(2.0001, 0.001)
  end

end
