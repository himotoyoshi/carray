require "test/unit"
require "carray"

# An object cell is a VALUE the garbage collector marks, so no view reads
# other bytes as object cells or object cells as bytes.

class TestObjectReinterpret < Test::Unit::TestCase

  def test_numeric_bytes_are_not_read_as_objects
    [CA_FLOAT64([1.5]), CA_INT64([1]), CA_UINT8([1] * 16)].each do |a|
      n = a.bytes * a.elements / 8
      assert_raise(CArray::DataTypeError) { a.refer(:object, [n]) }
    end
  end

  def test_object_cells_are_not_read_as_bytes
    o = CA_OBJECT(["a", "b"])
    assert_raise(CArray::DataTypeError) { o.refer(:int64, [2]) }
    assert_raise(CArray::DataTypeError) { o.field(0, :int64) }
  end

  def test_object_refer_as_object_still_works
    assert_equal [[1, 2]], CA_OBJECT([1, 2]).refer(:object, [1, 2]).to_a
  end

end
