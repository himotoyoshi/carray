# ENHANCE_CASTRUCT Phase B.3b — Builder field-level endian option.
#
# Verifies that `<numeric_type> :name, endian: :big|:little|:native|:preserve`
# round-trips correctly via CAByteSwap, that the on-wire bytes match the
# requested byte order regardless of host endianness, and that the
# reflection API exposes the endian on Field records.

$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
$LOAD_PATH.unshift File.expand_path("../../ext", __dir__)

require "carray"
require "test/unit"

class TestCAStructEndian < Test::Unit::TestCase

  HOST_LE = (CArray.endian == CA_LITTLE_ENDIAN)

  def test_int32_big_endian_on_wire_layout
    s = CArray.struct { int32 :v, endian: :big }
    o = s.new
    o[:v] = 0x01020304
    assert_equal "\x01\x02\x03\x04".b, o.encode
    assert_equal 0x01020304, s.decode(o.encode)[:v]
  end

  def test_int32_little_endian_on_wire_layout
    s = CArray.struct { int32 :v, endian: :little }
    o = s.new
    o[:v] = 0x01020304
    assert_equal "\x04\x03\x02\x01".b, o.encode
    assert_equal 0x01020304, s.decode(o.encode)[:v]
  end

  def test_uint16_endian
    s = CArray.struct { uint16 :port, endian: :big }
    o = s.new
    o[:port] = 0x1234
    assert_equal "\x12\x34".b, o.encode
  end

  def test_native_and_preserve_are_identity_on_host
    s = CArray.struct {
      int32 :a, endian: :native
      int32 :b, endian: :preserve
    }
    o = s.new
    o[:a] = 0x11223344
    o[:b] = 0x55667788
    o2 = s.decode(o.encode)
    assert_equal 0x11223344, o2[:a]
    assert_equal 0x55667788, o2[:b]
  end

  def test_mixed_endian_struct_roundtrip
    s = CArray.struct {
      int32  :be_field, endian: :big
      int32  :le_field, endian: :little
      uint16 :host_field
    }
    o = s.new
    o[:be_field]   = -1
    o[:le_field]   = 0x7eadbeef
    o[:host_field] = 0xABCD
    o2 = s.decode(o.encode)
    assert_equal(-1,         o2[:be_field])
    assert_equal 0x7eadbeef, o2[:le_field]
    assert_equal 0xABCD,     o2[:host_field]
  end

  def test_float64_big_endian_roundtrip
    s = CArray.struct { float64 :x, endian: :big }
    o = s.new
    o[:x] = Math::PI
    bin = o.encode
    # On a LE host, BE-stored Math::PI is the byte-reverse of native PI.
    pi_native = [Math::PI].pack("E")     # native double = LE on intel/arm64
    assert_equal pi_native.bytes.reverse, bin.bytes if HOST_LE
    assert_in_delta Math::PI, s.decode(bin)[:x], 1e-15
  end

  def test_cmplx64_endian_swaps_each_half
    s = CArray.struct { cmplx64 :c, endian: :big }
    o = s.new
    o[:c] = Complex(1.5, -2.25)
    assert_in_delta 1.5,  s.decode(o.encode)[:c].real, 1e-6
    assert_in_delta(-2.25, s.decode(o.encode)[:c].imag, 1e-6)
  end

  def test_endian_rejected_on_fixlen
    assert_raise(CAStruct::DefinitionError) do
      CArray.struct { fixlen :s, bytes: 4, endian: :big }
    end
  end

  def test_invalid_endian_symbol_rejected
    assert_raise(CAStruct::DefinitionError) do
      CArray.struct { int32 :x, endian: :middle }
    end
  end

  def test_field_reflection_exposes_endian
    s = CArray.struct {
      int32 :be, endian: :big
      int32 :plain
    }
    assert_equal :big, s.field_info("be").endian
    assert_nil         s.field_info("plain").endian
  end

  def test_struct_size_unaffected_by_endian
    plain = CArray.struct { int32 :a; int32 :b }
    mixed = CArray.struct {
      int32 :a, endian: :big
      int32 :b, endian: :little
    }
    assert_equal plain::DATA_SIZE, mixed::DATA_SIZE
  end

  def test_writing_through_endian_field_then_reading_raw
    # Writing a known value via :big endian field should produce the
    # same bytes a host-native field followed by swap_bytes would.
    s_be   = CArray.struct { int32 :v, endian: :big }
    s_host = CArray.struct { int32 :v }
    o_be   = s_be.new;   o_be[:v]   = 0x0A0B0C0D
    o_host = s_host.new; o_host[:v] = 0x0A0B0C0D
    if HOST_LE
      assert_equal o_host.encode.bytes.reverse, o_be.encode.bytes
    else
      assert_equal o_host.encode.bytes, o_be.encode.bytes
    end
  end

end
