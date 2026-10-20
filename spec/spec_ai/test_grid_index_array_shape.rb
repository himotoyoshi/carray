require "test/unit"
require "carray"

# With one key per axis, an index array picks cells along its own axis.
# One of more axes states a shape the axis does not have; it was read flat.
class TestGridIndexArrayShape < Test::Unit::TestCase

  def test_a_two_axis_index_array_on_one_axis_is_refused
    b = CArray.int32(3, 3).seq!
    e = assert_raise(ArgumentError) { b[CA_INT64([[0, 1], [1, 2]]), CA_INT64([0, 1])] }
    assert_match(/shape \[2, 2\] on axis 0/, e.message)
    assert_raise(ArgumentError) { b[nil, CA_INT64([[0], [2]])] }
  end

  def test_flatten_gives_the_old_reading
    b = CArray.int32(3, 3).seq!
    idx = CA_INT64([[0, 1], [1, 2]])
    assert_equal [4, 2], b[idx.flatten, CA_INT64([0, 1])].shape
  end

  def test_one_axis_index_arrays_are_unchanged
    b = CArray.int32(3, 3).seq!
    assert_equal [[1], [7]], b[CA_INT64([0, 2]), CA_INT64([1])].to_a
  end

end
