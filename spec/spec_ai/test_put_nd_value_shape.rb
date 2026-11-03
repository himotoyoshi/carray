require "test/unit"
require "carray"

# put_nd takes values of the shape gather_nd gives back, (*outer, *rest).
class TestPutNdValueShape < Test::Unit::TestCase

  def test_a_round_trip_with_rest_of_several_axes
    a = CArray.int32(2, 3, 2).seq
    idx = CA_INT32([1])
    got = a.gather_nd(idx)
    assert_equal [3, 2], got.shape
    b = CArray.int32(2, 3, 2)
    b[] = 0
    b.put_nd(idx, got)
    assert_equal a[1, nil, nil].to_a, b[1, nil, nil].to_a
    assert_equal [0] * 6, b[0, nil, nil].to_a.flatten
  end

  def test_outer_and_rest_together
    a = CArray.int32(2, 3, 2).seq
    idx = CA_INT32([[1], [0]])
    b = CArray.int32(2, 3, 2)
    b.put_nd(idx, a.gather_nd(idx))
    assert_equal a.to_a, b.to_a
  end

  def test_a_masked_coordinate_writes_nothing_in_that_shape
    a = CArray.int32(2, 3, 2).seq
    idx = CA_INT32([[1], [0]])
    idx[1, 0] = UNDEF
    b = CArray.int32(2, 3, 2)
    b[] = -1
    values = CArray.int32(2, 3, 2) { 9 }
    b.put_nd(idx, values)
    assert_equal [9] * 6, b[1, nil, nil].to_a.flatten
    assert_equal [-1] * 6, b[0, nil, nil].to_a.flatten
  end

  def test_a_scalar_and_a_flat_list_still_go
    b = CArray.int32(2, 3, 2)
    b[] = 0
    b.put_nd(CA_INT32([1]), 7)
    assert_equal [7] * 6, b[1, nil, nil].to_a.flatten
    b.put_nd(CA_INT32([0]), CArray.int32(6).seq)
    assert_equal (0...6).to_a, b[0, nil, nil].to_a.flatten
  end

  def test_one_coordinate_with_no_rest
    b = CArray.int32(2, 3)
    b[] = 0
    b.put_nd(CA_INT32([1, 2]), 5)
    assert_equal 5, b[1, 2]
  end
end
