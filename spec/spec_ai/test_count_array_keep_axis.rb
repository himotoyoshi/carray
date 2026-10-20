require "test/unit"
require "carray"

# count with an array of values keeps the reduced axes at length 1 under
# keep_axis:, as count with one value does.  The keyword was ignored.
class TestCountArrayKeepAxis < Test::Unit::TestCase

  def test_keep_axis_with_an_array_of_values
    a = CArray.int32(2, 3).seq
    v = CA_INT32([1, 4])
    assert_equal [1, 3, 2], a.count(v, axis: 0, keep_axis: true).shape
    assert_equal [[[0, 0], [1, 1], [0, 0]]], a.count(v, axis: 0, keep_axis: true).to_a
    assert_equal [1, 1, 2], a.count(v, keep_axis: true).shape
    assert_equal [3, 2], a.count(v, axis: 0).shape
  end

end
