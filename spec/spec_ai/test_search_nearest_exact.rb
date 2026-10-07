require "test/unit"
require "carray"

# search_nearest on an integer array measures the distance exactly, also
# between neighbouring int64 values above 2**53.
class TestSearchNearestExact < Test::Unit::TestCase

  def test_nearest_in_int64_is_exact
    assert_equal 1, CA_INT64([2**62, 2**62 + 1, 2**62 + 3]).search_nearest(2**62 + 2)
    assert_equal 1, CA_INT64([-2**63, 2**63 - 1]).search_nearest(0)
    assert_equal 1, CA_UINT64([0, 2**64 - 1]).search_nearest(2**63)
    assert_equal [1], CA_INT64([[2**62, 2**62 + 1]]).search_nearest(2**62 + 1, axis: 1).to_a
  end
end
