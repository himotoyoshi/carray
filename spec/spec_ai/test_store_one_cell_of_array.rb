require "test/unit"
require "carray"

class TestStoreOneCellOfArray < Test::Unit::TestCase

  def test_a_one_cell_array_gives_its_cell
    a = CArray.int32(3)
    a[1] = CA_INT32([7])
    assert_equal [0, 7, 0], a.to_a
    b = CArray.int32(2, 2)
    b[1, 0] = CA_INT32([8])
    assert_equal [[0, 0], [8, 0]], b.to_a
  end

  def test_its_mask_comes_with_it
    src = CA_INT32([7])
    src[0] = UNDEF
    a = CArray.int32(3)
    a[1] = src
    assert_equal [0, UNDEF, 0], a.to_a
  end

  def test_an_array_of_more_cells_is_a_shape_mismatch
    a = CArray.int32(3)
    assert_raise(ArgumentError) { a[1] = CA_INT32([1, 2]) }
    b = CArray.int32(2, 2)
    assert_raise(ArgumentError) { b[0, 0] = CA_INT32([]) }
  end

  def test_a_cell_of_an_object_array_holds_the_array
    a = CArray.object(2)
    x = CA_INT32([7])
    a[1] = x
    assert_equal true, a[1].equal?(x)
  end

  def test_the_type_symbol_of_the_complex_classes_is_their_data_type
    assert_equal :cmplx64, CArray::Complex64::TypeSymbol
    assert_equal :cmplx128, CArray::Complex128::TypeSymbol
    assert_equal CA_CMPLX64([1]).data_type_name.to_sym, CArray::Complex64::TypeSymbol
  end

end
