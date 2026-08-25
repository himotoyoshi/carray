require "test/unit"
require "carray"

# CIFY Phase 2: C-native CAStruct#[] / #[]= for bit-field and
# endian-tagged primitive members.  Phase 1 covered plain primitives;
# Phase 2 extends the FAST_PRIMITIVES table with:
#
#   - FAST_KIND_BITFIELD = 1
#     [1, start_byte, view_bytes, bit_in_word, bits]
#     C reads do a word-sized memcpy + (word >> bit_in_word) & mask.
#     C writes do load-modify-store on the spanning word.
#
#   - FAST_KIND_ENDIAN = 2
#     [2, offset, ca_type_code]
#     C reads do memcpy + __builtin_bswap{16,32,64} + scalar convert.
#     C writes do swap-then-store.  When the requested endian matches
#     the host, Builder folds the member into FAST_KIND_PRIMITIVE and
#     no swap runs at all.
#
# Behaviour must match the pre-Phase-2 Ruby paths
# (build_bitfield_dispatcher / build_primitive_dispatcher with
# .endian view chain).  These tests pin the C semantics across
# bit-widths, byte-spanning fields, endian directions, and
# read/write isolation.

class TestCAStructCIFYPhase2 < Test::Unit::TestCase

  HOST_LE = (CArray.endian == CA_LITTLE_ENDIAN)

  # ===== Bit-field reads / writes ====================================

  def test_bitfield_single_bit_read_write
    s = CArray.struct(pack: 1) {
      uint16 :head
      bit :a, bits: 1
      bit :b, bits: 1
      bit :c, bits: 6
    }
    r = s.new(head: 0xCAFE, a: 1, b: 0, c: 42)
    assert_equal 1,    r[:a]
    assert_equal 0,    r[:b]
    assert_equal 42,   r[:c]
    assert_equal 0xCAFE, r[:head]   # neighbour primitive untouched

    r[:a] = 0
    r[:b] = 1
    r[:c] = 17
    assert_equal 0,    r[:a]
    assert_equal 1,    r[:b]
    assert_equal 17,   r[:c]
    assert_equal 0xCAFE, r[:head]   # still untouched
  end

  def test_bitfield_crossing_byte_boundary_uint16_view
    # 12-bit field starting at bit 4: spans bytes 0+1 (4 bits of byte 0,
    # 8 bits of byte 1).  view_bytes = 2 (uint16).  Surrounded by other
    # bit fields so the struct has enough trailing bytes for the
    # spanning word's bounds check.
    s = CArray.struct(pack: 1) {
      bit :pad,  bits: 4
      bit :val,  bits: 12
      bit :tail, bits: 8
    }
    r = s.new(pad: 0xF, val: 0xABC, tail: 0x55)
    entry = s::FAST_PRIMITIVES["val"]
    assert_equal CAStruct::Builder::FAST_KIND_BITFIELD, entry[0]
    assert_equal 0,    entry[1]   # start_byte
    assert_equal 2,    entry[2]   # view_bytes = uint16
    assert_equal 4,    entry[3]   # bit_in_word
    assert_equal 12,   entry[4]
    assert_equal 0xF,   r[:pad]
    assert_equal 0xABC, r[:val]
    assert_equal 0x55,  r[:tail]
    r[:val] = 0x123
    assert_equal 0x123, r[:val]
    # Neighbouring bit fields untouched
    assert_equal 0xF,  r[:pad]
    assert_equal 0x55, r[:tail]
  end

  def test_bitfield_8bit_at_aligned_offset_uses_byte_view
    s = CArray.struct(pack: 1) {
      bit :byte_field, bits: 8
    }
    r = s.new(byte_field: 0xCD)
    entry = s::FAST_PRIMITIVES["byte_field"]
    assert_equal CAStruct::Builder::FAST_KIND_BITFIELD, entry[0]
    assert_equal 0,    entry[1]   # start_byte
    assert_equal 1,    entry[2]   # view_bytes (1: byte view since aligned)
    assert_equal 0,    entry[3]   # bit_in_word
    assert_equal 8,    entry[4]   # bits
    assert_equal 0xCD, r[:byte_field]
  end

  def test_bitfield_8bit_unaligned_uses_uint16_view
    s = CArray.struct(pack: 1) {
      bit :pad,   bits: 4
      bit :value, bits: 8
      bit :tail,  bits: 4
    }
    r = s.new(pad: 0xA, value: 0xCD, tail: 0x9)
    entry = s::FAST_PRIMITIVES["value"]
    assert_equal CAStruct::Builder::FAST_KIND_BITFIELD, entry[0]
    assert_equal 2,    entry[2]   # view_bytes: uint16 (spans bytes 0+1)
    assert_equal 4,    entry[3]   # bit_in_word
    assert_equal 8,    entry[4]
    assert_equal 0xCD, r[:value]
    assert_equal 0xA,  r[:pad]
    assert_equal 0x9,  r[:tail]
  end

  def test_bitfield_write_does_not_disturb_neighbours
    s = CArray.struct(pack: 1) {
      bit :a, bits: 4
      bit :b, bits: 4
      bit :c, bits: 4
      bit :d, bits: 4
    }
    r = s.new(a: 0xA, b: 0xB, c: 0xC, d: 0xD)
    r[:b] = 0x5
    assert_equal 0xA, r[:a]
    assert_equal 0x5, r[:b]
    assert_equal 0xC, r[:c]
    assert_equal 0xD, r[:d]
  end

  def test_bitfield_value_truncates_to_bits
    # Writing too-wide a value silently truncates to the field's
    # bit width (matches CABitfield semantics).
    s = CArray.struct(pack: 1) { bit :flag, bits: 1 }
    r = s.new
    r[:flag] = 99
    assert_equal 1, r[:flag]   # 99 & 0x1 == 1
    r[:flag] = 256
    assert_equal 0, r[:flag]   # 256 & 0x1 == 0
  end

  # ===== Endian-swapped reads / writes ================================

  def test_endian_native_is_primitive_kind
    # Matching-host endian must NOT take the swap fast path.
    s = CArray.struct(pack: 1) {
      uint32 :v, endian: :native
    }
    entry = s::FAST_PRIMITIVES["v"]
    assert_equal CAStruct::Builder::FAST_KIND_PRIMITIVE, entry[0]
  end

  def test_endian_preserve_is_primitive_kind
    s = CArray.struct(pack: 1) {
      uint32 :v, endian: :preserve
    }
    entry = s::FAST_PRIMITIVES["v"]
    assert_equal CAStruct::Builder::FAST_KIND_PRIMITIVE, entry[0]
  end

  def test_endian_int32_swap_round_trip
    other = HOST_LE ? :big : :little
    s = CArray.struct(pack: 1) { int32 :v, endian: other }
    r = s.new(v: 0x01020304)
    assert_equal CAStruct::Builder::FAST_KIND_ENDIAN,
                 s::FAST_PRIMITIVES["v"][0]
    assert_equal 0x01020304, r[:v]
    # And the encoded bytes are big-endian on a LE host (the swapped
    # storage order), proving the swap happened.
    expected_bytes = HOST_LE ? "\x01\x02\x03\x04".b : "\x04\x03\x02\x01".b
    assert_equal expected_bytes, r.encode
  end

  def test_endian_uint16_swap_round_trip
    other = HOST_LE ? :big : :little
    s = CArray.struct(pack: 1) { uint16 :port, endian: other }
    r = s.new(port: 0x1234)
    assert_equal 0x1234, r[:port]
    expected = HOST_LE ? "\x12\x34".b : "\x34\x12".b
    assert_equal expected, r.encode
  end

  def test_endian_int64_swap_round_trip
    other = HOST_LE ? :big : :little
    s = CArray.struct(pack: 1) { int64 :big_v, endian: other }
    r = s.new(big_v: 0x0102030405060708)
    assert_equal 0x0102030405060708, r[:big_v]
    expected = HOST_LE ? "\x01\x02\x03\x04\x05\x06\x07\x08".b
                       : "\x08\x07\x06\x05\x04\x03\x02\x01".b
    assert_equal expected, r.encode
  end

  def test_endian_float64_swap_round_trip
    other = HOST_LE ? :big : :little
    s = CArray.struct(pack: 1) { float64 :x, endian: other }
    r = s.new(x: Math::PI)
    assert_in_delta Math::PI, r[:x], 1e-15
    # Bit-for-bit check: native double bytes reversed.
    native_bytes = [Math::PI].pack("E")  # native LE on intel/arm
    if HOST_LE
      assert_equal native_bytes.bytes.reverse, r.encode.bytes
    else
      assert_equal native_bytes.bytes, r.encode.bytes
    end
  end

  def test_endian_float32_swap_round_trip
    other = HOST_LE ? :big : :little
    s = CArray.struct(pack: 1) { float32 :x, endian: other }
    r = s.new(x: 1.5)
    assert_in_delta 1.5, r[:x], 1e-6
  end

  def test_endian_write_does_not_disturb_neighbours
    other = HOST_LE ? :big : :little
    s = CArray.struct(pack: 1) {
      uint32 :a, endian: other
      uint32 :b
      uint32 :c, endian: other
    }
    r = s.new(a: 0x11111111, b: 0x22222222, c: 0x33333333)
    r[:a] = 0xAAAAAAAA
    assert_equal 0xAAAAAAAA, r[:a]
    assert_equal 0x22222222, r[:b]
    assert_equal 0x33333333, r[:c]
    r[:c] = 0xCCCCCCCC
    assert_equal 0xAAAAAAAA, r[:a]
    assert_equal 0x22222222, r[:b]
    assert_equal 0xCCCCCCCC, r[:c]
  end

  # ===== 1-byte endian: must be primitive (no swap) ==================

  def test_endian_int8_no_swap
    # 1-byte types are excluded from ENDIAN_FAST_TYPE_CODES because
    # byte-swap is a no-op.  They land in FAST_KIND_PRIMITIVE
    # regardless of the requested endian.
    other = HOST_LE ? :big : :little
    s = CArray.struct(pack: 1) { int8 :v, endian: other }
    entry = s::FAST_PRIMITIVES["v"]
    assert_equal CAStruct::Builder::FAST_KIND_PRIMITIVE, entry[0]
    r = s.new(v: -42)
    assert_equal(-42, r[:v])
  end

  # ===== Column-level bitfield (A.3+) still works ====================

  def test_column_level_bit_access_unaffected_by_phase2
    # A.3+ routes records["bit"] through rb_ca_field_as_member, NOT
    # through CAStruct#[].  Phase 2 must not regress the column path.
    s = CArray.struct(pack: 1) {
      uint16 :head
      bit :flag, bits: 1
    }
    rs = CARecord.new(s, 3)
    rs[0] = s.new(head: 1, flag: 1)
    rs[1] = s.new(head: 2, flag: 0)
    rs[2] = s.new(head: 3, flag: 1)
    assert_equal [true, false, true], rs["flag"].to_a
  end

  # ===== Symbol vs String name parity (Phase 1 invariant) ============

  def test_symbol_and_string_lookup_parity_for_bitfield
    s = CArray.struct(pack: 1) { bit :flag, bits: 1 }
    r = s.new(flag: 1)
    assert_equal r[:flag], r["flag"]
    r["flag"] = 0
    assert_equal 0, r[:flag]
  end

  def test_symbol_and_string_lookup_parity_for_endian
    other = HOST_LE ? :big : :little
    s = CArray.struct(pack: 1) { uint32 :v, endian: other }
    r = s.new(v: 0x1234)
    assert_equal r[:v], r["v"]
    r["v"] = 0xABCD
    assert_equal 0xABCD, r[:v]
  end

end
