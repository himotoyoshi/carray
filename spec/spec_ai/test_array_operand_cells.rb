require "test/unit"
require "carray"

# A Ruby Array operand against a numeric or boolean array is read as its
# cells.  eq read it as one value (every cell false) and + raised.
class TestArrayOperandCells < Test::Unit::TestCase

  def test_cells_pair_with_cells
    i = CA_INT32([1, 2, 3])
    assert_equal [true, false, true], i.eq([1, 5, 3]).to_a
    assert_equal [true, false, false], i.lt([2, 2, 2]).to_a
    assert_equal [2, 4, 6], (i + [1, 2, 3]).to_a
    assert_equal [2, 3, 4], (i.lazy + [1, 1, 1]).to_a
  end

  def test_nested_arrays_give_the_axes
    m = CArray.int32(2, 2).seq!
    assert_equal [[1, 2], [3, 4]], (m + [[1, 1], [1, 1]]).to_a
    assert_raise(ArgumentError) { m + [1, 1, 1, 1] }
    assert_raise(ArgumentError) { CA_INT32([1, 2, 3]) + [1, 2] }
  end

  def test_each_cell_takes_its_scalar_type
    i = CA_INT32([1, 2, 3])
    assert_equal "int32",   (i + [1, 2, 3]).data_type_name
    assert_equal "float64", (i + [1, 2.5, 3]).data_type_name
    assert_equal "float32", (CA_FLOAT32([1, 2, 3]) + [1.5, 1, 1]).data_type_name
    assert_raise(RangeError) { i + [2**40, 1, 1] }
    assert_raise(RangeError) { CA_UINT8([1]) + [-1] }
  end

  def test_in_place_takes_the_left_type
    x = CA_INT32([1, 2, 3])
    x.add!([1, 1, 1])
    assert_equal [2, 3, 4], x.to_a
    assert_raise(TypeError) { x.add!([1.5, 1, 1]) }
  end

  def test_an_object_array_keeps_an_array_as_one_value
    o = CArray.object(2)
    o[0] = [1]
    o[1] = [1]
    assert_equal [true, true], o.eq([1]).to_a
  end

end
