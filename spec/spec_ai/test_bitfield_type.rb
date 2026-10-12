require "test/unit"
require "carray"

# bitfield(range, type): the field is read as an integer of `type`.  A
# signed type reads the field's top bit as its sign; a wider type only
# widens the value; a write keeps the low bits that fit the field.
class TestBitfieldType < Test::Unit::TestCase

  def setup
    @a = CA_UINT8([0b101, 0b011, 0b111])
  end

  def test_without_a_type_the_narrowest_unsigned
    assert_equal :uint8, @a.bitfield(0..2).data_type
    assert_equal [5, 3, 7], @a.bitfield(0..2).to_a
    assert_equal :boolean, @a.bitfield(0).data_type
  end

  def test_a_signed_type_reads_the_top_bit_as_the_sign
    assert_equal [-3, 3, -1], @a.bitfield(0..2, :int8).to_a
    assert_equal [-1, -1, -1], @a.bitfield(0, :int8).to_a
    u = CA_UINT64([2**64 - 1])
    assert_equal [-1], u.bitfield(0..63, :int64).to_a
    assert_equal [-1], u.bitfield(0..62, :int64).to_a
    v = CA_UINT16([0x8000, 0xff00, 0x7f00])
    assert_equal [-128, -1, 127], v.bitfield(8..15, :int8).to_a
  end

  def test_a_wider_type_only_widens
    b = @a.bitfield(0..2, :int32)
    assert_equal :int32, b.data_type
    assert_equal [-3, 3, -1], b.to_a
    assert_equal [5, 3, 7], @a.bitfield(0..2, :uint64).to_a
    assert_equal [1, 1, 1], @a.bitfield(0, :uint8).to_a
  end

  def test_a_write_keeps_the_bits_that_fit_the_field
    c = CA_UINT8([0, 0xff])
    w = c.bitfield(2..4, :int8)
    w[] = -3
    assert_equal [0b10100, 0b11110111], c.to_a
    assert_equal [-3, -3], w.to_a
    w[] = CA_INT8([-1, 2])
    assert_equal [0b11100, 0b11101011], c.to_a
  end

  def test_the_view_is_read_the_same_over_a_view
    v = CA_UINT16([0xff00, 0x0f00, 0x8000])[CA_INT64([2, 0])]
    assert_equal [-128, -1], v.bitfield(8..15, :int8).to_a
  end

  def test_a_copy_keeps_the_type
    d = CA_UINT16([0xf000]).bitfield(4..15, :int16)
    assert_equal :int16, d.dup.data_type
    assert_equal [-256], d.dup.to_a
  end

  def test_a_type_that_cannot_hold_the_field_is_refused
    assert_raise(ArgumentError) { CA_UINT16([0]).bitfield(0..11, :int8) }
    assert_raise(ArgumentError) { @a.bitfield(0..2, :boolean) }
    assert_raise(CArray::DataTypeError) { @a.bitfield(0..2, :float64) }
    assert_raise(CArray::DataTypeError) { @a.bitfield(0..2, :object) }
  end
end
