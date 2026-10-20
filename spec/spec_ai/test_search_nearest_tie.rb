require "test/unit"
require "carray"

# Of several equally close elements, search_nearest answers the lowest
# address; locate_nearest_addr rounds a position and answers the larger
# value.  The two rules are different on purpose.
class TestSearchNearestTie < Test::Unit::TestCase

  def test_search_nearest_takes_the_lowest_address
    assert_equal 0, CA_FLOAT64([0, 2, 4]).search_nearest(1.0)
    assert_equal 1, CA_FLOAT64([4, 2, 0]).search_nearest(1.0)
    assert_equal 1, CA_INT64([1, 5, 3, 5]).search_nearest(4)
    assert_equal [0], CA_FLOAT64([0, 2, 4]).reshape(1, 3).search_nearest(1.0, axis: 1).to_a
  end

  def test_locate_nearest_addr_takes_the_larger_value
    assert_equal [1, 2], CA_FLOAT64([1, 3]).locate_nearest_addr(CA_FLOAT64([0, 2, 4])).to_a
    assert_equal [1, 0], CA_FLOAT64([1, 3]).locate_nearest_addr(CA_FLOAT64([4, 2, 0])).to_a
  end

end
