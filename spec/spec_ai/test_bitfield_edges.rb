require "test/unit"
require "carray"

# CArray#bitfield at the edges of where a field can sit: a field wider
# than the bytes its value is stored in, a bit counted from the end, a
# field that cannot be read in one 8-byte load, and a parent whose cells
# are Ruby objects.
class TestBitfieldEdges < Test::Unit::TestCase

  # A field that starts inside a byte and is as wide as its value type
  # reaches past that type's width in the parent; a copy of the view is
  # the same field.
  def test_a_copy_is_the_same_field
    a = CA_UINT16([0xfff0, 0x0ab0])
    b = a.bitfield(4..11)
    assert_equal [0xff, 0xab], b.to_a
    assert_equal [0xff, 0xab], b.dup.to_a
    assert_equal [0xff, 0xab], b.clone.to_a
    u = CA_UINT32([0xdead_beef])
    c = u.bitfield(13..20)
    assert_equal [(0xdead_beef >> 13) & 0xff], c.dup.to_a
  end

  # A negative bit counts from the end of the cell, as a negative range does.
  def test_a_negative_bit_counts_from_the_end
    a = CA_UINT16([0xfff0, 0x0ab0])
    assert_equal [true, false], a.bitfield(-1).to_a
    assert_equal a.bitfield(15).to_a, a.bitfield(-1).to_a
    assert_equal a.bitfield(13..15).to_a, a.bitfield(-3..-1).to_a
    assert_raise(IndexError) { a.bitfield(-17) }
    assert_raise(IndexError) { a.bitfield(16) }
  end

  # A field is read with one 8-byte load from the byte it starts in, so a
  # field of more than 57 bits that starts inside a byte cannot be read.
  def test_a_field_past_one_load_is_refused
    f = CArray.fixlen(1, bytes: 16)
    f[0] = ("\xff" * 16).b
    assert_equal 2**64 - 1, f.bitfield(0..63)[0]
    assert_equal 2**64 - 1, f.bitfield(8..71)[0]
    assert_equal 2**57 - 1, f.bitfield(7..63)[0]
    assert_raise(IndexError) { f.bitfield(4..67) }
    assert_raise(IndexError) { f.bitfield(1..64) }
  end

  # The bits of an object cell are a reference; writing them would leave
  # the cell pointing nowhere.
  def test_an_object_parent_is_refused
    o = CA_OBJECT(["abc", 1])
    assert_raise(CArray::DataTypeError) { o.bitfield(0..3) }
    assert_raise(CArray::DataTypeError) { o.bitfield(0) }
  end

  # A field is a run of bits from low to high; a descending range does
  # not name one.
  def test_a_descending_range_is_refused
    a = CA_UINT8([0b1110, 0b110000])
    assert_equal [7, 0], a.bitfield(1..3).to_a
    assert_raise(IndexError) { a.bitfield(3..1) }
    assert_raise(IndexError) { a.bitfield(3...1) }
    assert_raise(IndexError) { a.bitfield(-1..0) }
    assert_equal [true, false], a.bitfield(3..3).to_a
  end

  # A complex parent is refused, as bitarray refuses it.
  def test_a_complex_parent_is_refused
    c = CA_CMPLX128([Complex(1, 2)])
    assert_raise(CArray::DataTypeError) { c.bitfield(0..7) }
    assert_raise(CArray::DataTypeError) { CA_CMPLX64([1]).bitfield(0) }
  end
  # The refusals name the method; a bit past the cell is out of range
  # whatever size the Integer is.
  def test_refusals_name_the_method
    { -> { CArray.object(2).bitfield(0) }       => /\Abitfield: /,
      -> { CArray.cmplx128(2).bitarray }        => /\Abitarray: /,
      -> { CArray.object(2).swap_bytes }        => /\Aswap_bytes: /,
      -> { CArray.object(2).field(0, :int8) }   => /\Afield: /,
      -> { CArray.int64(2).bitfield(2**32 + 1) } => /\Abitfield: bits out of range for a cell of 64 bits\z/,
      -> { CArray.int64(2).bitfield(2**70) }    => /\Abitfield: bits out of range/ }.each do |call, message|
      e = assert_raise_kind_of(StandardError) { call.() }
      assert_match message, e.message
    end
  end

end
