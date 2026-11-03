require "test/unit"
require "carray"

# A cast that can refuse a cell leaves the masked cells alone, and treats the
# others as it does with no mask at all.
class TestCastSkipsMaskedCells < Test::Unit::TestCase

  def test_as_type_to_boolean_does_not_read_a_masked_cell
    a = CA_UINT8([7, 1])
    a[0] = UNDEF
    assert_equal [UNDEF, true], a.as_type(:boolean).to_a
    assert_equal [true, UNDEF], a.flip(0).as_type(:boolean).to_a
  end

  def test_as_type_from_object_does_not_read_a_masked_cell
    a = CA_OBJECT([-1, 1])
    a[0] = UNDEF
    assert_equal [UNDEF, 1], a.as_type(:uint8).to_a
  end

  def test_an_object_store_refuses_a_cell_with_or_without_a_mask
    plain = CA_OBJECT([-1, 1])
    masked = CA_OBJECT([-1, 1, 2])
    masked[2] = UNDEF
    assert_raise(RangeError) { CArray.uint8(2)[] = plain }
    assert_raise(RangeError) { CArray.uint8(3)[] = masked }
  end

  def test_a_fake_refuses_a_cell_with_or_without_a_mask
    plain = CA_OBJECT([-1, 1])
    masked = CA_OBJECT([-1, 1, 2])
    masked[2] = UNDEF
    assert_raise(RangeError) { plain.fake(:uint8).to_a }
    assert_raise(RangeError) { masked.fake(:uint8).to_a }
  end

  def test_as_type_refuses_a_cell_with_or_without_a_mask
    masked = CA_OBJECT([-1, 1, 2])
    masked[2] = UNDEF
    assert_raise(RangeError) { masked.as_type(:uint8).to_a }
  end

  def test_a_store_of_an_unreadable_object_cell_refuses_it_with_a_mask
    masked = CA_OBJECT(["x", 1, 2])
    masked[2] = UNDEF
    assert_raise(ArgumentError) { CArray.int32(3)[] = masked }
  end

  def test_a_store_from_a_ruby_array_with_undef
    assert_raise(RangeError) { CArray.uint8(2)[] = [-1, UNDEF] }
    a = CArray.uint8(2)
    a[] = [3, UNDEF]
    assert_equal [3, UNDEF], a.to_a
  end

  def test_masked_cells_of_the_destination_are_written_as_masked
    s = CA_OBJECT([1, 2])
    s[1] = UNDEF
    a = CArray.int32(2)
    a[] = s
    assert_equal [1, UNDEF], a.to_a
  end

  def test_to_type_still_masks_what_it_cannot_read
    a = CA_OBJECT(["x", 1])
    assert_equal [UNDEF, 1], a.to_type(:int32).to_a
    assert_equal [255, 1], CA_OBJECT([-1, 1]).to_type(:uint8).to_a
  end

end
