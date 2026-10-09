require "test/unit"
require "carray"

# A bitarray view takes no masked array and holds no mask of its own: the
# bits of one byte would share that byte's one mask cell, so a mask set on a
# single bit would stand for eight bits.  Reading the bits of a masked array
# goes through .value.
class TestBitarrayNoMask < Test::Unit::TestCase

  def masked_bytes
    b = CA_UINT8([5, 6])
    b[1] = UNDEF
    b
  end

  def test_masked_array_is_refused
    assert_raise(ArgumentError) { masked_bytes.bitarray }
  end

  def test_view_of_masked_array_is_refused
    assert_raise(ArgumentError) { masked_bytes[0..0].bitarray }
  end

  def test_value_reads_the_bits_without_the_mask
    assert_equal([[true, false, true, false, false, false, false, false],
                  [false, true, true, false, false, false, false, false]],
                 masked_bytes.value.bitarray.to_a)
  end

  def test_mask_assignment_is_refused
    assert_raise(ArgumentError) { CA_UINT8([5, 6]).bitarray.mask = 1 }
  end

  def test_storing_undef_into_a_bit_is_refused
    b = CA_UINT8([5, 6])
    assert_raise(ArgumentError) { b.bitarray[0, 3] = UNDEF }
    assert_equal(false, b.has_mask?)
  end

  def test_mask_through_a_slice_is_refused
    b = CA_UINT8([5, 6])
    assert_raise(ArgumentError) { b.bitarray[3...12].mask = CArray.boolean(9) { 1 } }
    assert_equal(false, b.has_mask?)
  end

  def test_storing_a_masked_array_is_refused
    m = CArray.boolean(3) { |i| i == 1 }
    m[0] = UNDEF
    b = CA_UINT8([5])
    assert_raise(ArgumentError) { b.bitarray[0, 0..2] = m }
    assert_equal(false, b.has_mask?)
  end

  def test_mask_gained_after_the_view_is_made_is_refused
    b = CA_UINT8([5, 6])
    v = b.bitarray
    b[0] = UNDEF
    error = assert_raise(ArgumentError) { v.to_a }
    assert_match(/gained a mask/, error.message)
  end

  def test_values_are_still_stored
    b = CA_UINT8([5, 6])
    b.bitarray[1, 0] = true
    assert_equal([5, 7], b.to_a)
  end

  def test_pack_bits_refuses_masked_cells
    x = CArray.boolean(10) { |i| i.odd? }
    x[7] = UNDEF
    error = assert_raise(ArgumentError) { x.pack_bits }
    assert_match(/validity_bits/, error.message)
  end

  def test_pack_bits_takes_a_mask_with_nothing_masked
    x = CArray.boolean(3) { 1 }
    x.mask = 0
    assert_equal([7], x.pack_bits.to_a)
  end

  def test_validity_bits_still_packs_the_mask
    x = CArray.boolean(10) { |i| i.odd? }
    x[2] = UNDEF
    assert_equal([251, 3], x.validity_bits.to_a)
  end

end
