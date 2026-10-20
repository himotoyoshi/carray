require "test/unit"
require "carray"

# Of several equal cells, bsearch answers the first.  It answered whichever
# the halving landed on.
class TestBsearchFirstEqual < Test::Unit::TestCase

  def test_flat_and_addr
    a = CA_INT32([1, 2, 2, 2, 2, 2, 3])
    assert_equal 1, a.bsearch(2)
    assert_equal 1, a.bsearch_addr(2)
    assert_equal 0, CA_INT32([2, 2, 2]).bsearch(2)
    assert_nil CA_INT32([1, 3]).bsearch(2)
  end

  def test_every_lane
    assert_equal 1, CA_DOUBLE([1, 2, 2, 2, 3]).bsearch(2.0)
    assert_equal 1, CA_OBJECT([1, 2, 2, 2, 3]).bsearch(2)
    assert_equal [2, 2], CA_INT64([[0, 1, 5, 5, 5], [0, 0, 5, 5, 9]]).bsearch(5, axis: 1).to_a
  end

end
