require "test/unit"
require "carray"

# Complex cells do not go into real ones: the imaginary parts would be
# dropped without a word.  #real and #to_type say which part is wanted.
class TestStoreComplexIntoReal < Test::Unit::TestCase

  C = CA_CMPLX128([1+2i, 3+4i])

  def test_every_door_of_a_store
    a = CArray.float64(2)
    assert_raise(CArray::DataTypeError) { a[] = C }
    assert_raise(CArray::DataTypeError) { a[0..1] = C }
    assert_raise(CArray::DataTypeError) { a.flip(0)[] = C }
    assert_raise(CArray::DataTypeError) { a[a.ge(0)] = C }
    assert_raise(CArray::DataTypeError) { a[] = C.lazy + 1 }
    assert_raise(CArray::DataTypeError) { a.put_nd(CA_INT64([[0], [1]]), C) }
    assert_raise(CArray::DataTypeError) { a.scatter_add!(CA_INT64([0, 1]), C) }
    assert_equal [0.0, 0.0], a.to_a
  end

  def test_message_names_the_types_and_the_way_out
    e = assert_raise(CArray::DataTypeError) { CArray.int32(2)[] = C }
    assert_equal "[]=: cannot store cmplx128 cells in int32 (#real and #to_type take the part wanted)",
                 e.message
  end

  def test_a_store_into_no_cells_is_checked_the_same
    assert_raise(CArray::DataTypeError) { CArray.float64(0)[] = CArray.cmplx128(0) }
  end

  def test_the_part_wanted_goes_in
    a = CArray.float64(2)
    a[] = C.real
    assert_equal [1.0, 3.0], a.to_a
    a[] = C.to_type(:float64)
    assert_equal [1.0, 3.0], a.to_a
  end

  def test_complex_and_object_cells_take_it
    z = CArray.cmplx64(2)
    z[] = C
    assert_equal [1+2i, 3+4i], z.to_a
    o = CArray.object(2)
    o[] = C
    assert_equal [1+2i, 3+4i], o.to_a
  end

end
