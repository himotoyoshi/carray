require "test/unit"
require "carray"

# project takes no keyword; one given was read as a fill value and raised a
# TypeError about converting a Hash.
class TestProjectKeywords < Test::Unit::TestCase

  def test_a_keyword_is_refused
    e = assert_raise(ArgumentError) { CA_INT32([1, 2]).project(CA_INT64([0, 5]), bogus: 1) }
    assert_match(/unknown keyword: :bogus/, e.message)
  end

  def test_fills_still_work
    a = CA_INT32([1, 2])
    assert_equal [1, -1], a.project(CA_INT64([0, 5]), -1).to_a
    assert_equal [-1, 9], a.project(CA_INT64([-1, 5]), -1, 9).to_a
  end

end
