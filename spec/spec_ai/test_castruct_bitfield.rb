require "test/unit"
require "carray"

# ENHANCE_CASTRUCT Phase A.3 (carray-3.0, 2026-05-21):
# CAStruct::Builder gains a `bit :name, bits: N` method that lays out
# packed bit members within the struct.  Tests the layout math
# (bit-offset tracking, byte boundary cross/round-up) and the
# instance-level read/write round-trip through CABitfield.
#
# Out of scope for this commit (deferred):
# - bits > 8 (CABitfield C-side has parent-bytes ∈ {1,2,4,8}
#   limitation; covered safely for bits ≤ 8 in the current impl).
# - Anonymous bit padding (`bit nil, bits: N`).
#
# Column-level `records["bit_name"]` access landed as Phase A.3+;
# its coverage lives in spec_ai/test_castruct_bitfield_column.rb.

class TestCAStructBitfield < Test::Unit::TestCase

  # --- Layout math ------------------------------------------------------

  def test_simple_bit_layout
    s = CArray.struct(pack: 1) {
      bit :a, bits: 1
      bit :b, bits: 1
      bit :c, bits: 6
    }
    # 8 bits total → 1 byte
    assert_equal(1, s::DATA_SIZE)
    # bit_offsets accumulate
    assert_equal(0, s::MEMBER_TABLE["a"][2][:bit_offset])
    assert_equal(1, s::MEMBER_TABLE["b"][2][:bit_offset])
    assert_equal(2, s::MEMBER_TABLE["c"][2][:bit_offset])
    assert_equal(6, s::MEMBER_TABLE["c"][2][:bits])
  end

  def test_bit_after_byte_member
    s = CArray.struct(pack: 1) {
      uint16 :header
      bit :flag, bits: 1
    }
    # header at bytes 0-1, bit at bit 16
    assert_equal(16, s::MEMBER_TABLE["flag"][2][:bit_offset])
    # DATA_SIZE rounds up to next byte after bit accumulator
    assert_equal(3, s::DATA_SIZE)
  end

  def test_bits_then_byte_member_rounds_up_byte
    s = CArray.struct(pack: 1) {
      bit :a, bits: 3
      uint32 :payload     # forces byte boundary
    }
    # a uses bits 0-2 of byte 0; bits 3-7 are padding; payload at byte 1
    assert_equal(0, s::MEMBER_TABLE["a"][2][:bit_offset])
    assert_equal(1, s::MEMBER_TABLE["payload"][0])
    # 1 (byte for bit a, rounded up) + 4 (payload) = 5
    assert_equal(5, s::DATA_SIZE)
  end

  def test_bits_cross_byte_boundary
    s = CArray.struct(pack: 1) {
      bit :a, bits: 5
      bit :b, bits: 4   # bits 5-8: spans bytes 0 and 1
    }
    assert_equal(0, s::MEMBER_TABLE["a"][2][:bit_offset])
    assert_equal(5, s::MEMBER_TABLE["b"][2][:bit_offset])
    # 5 + 4 = 9 bits → 2 bytes
    assert_equal(2, s::DATA_SIZE)
  end

  # --- Round-trip read/write -------------------------------------------

  def test_round_trip_simple
    s = CArray.struct(pack: 1) {
      uint16 :header
      bit :flag_a, bits: 1
      bit :flag_b, bits: 1
      bit :version, bits: 6
      uint32 :payload
    }
    r = s.new(header: 0x1234,
              flag_a: 1, flag_b: 0, version: 42,
              payload: 0xDEADBEEF)
    assert_equal(0x1234,     r.header)
    assert_equal(1,          r.flag_a)
    assert_equal(0,          r.flag_b)
    assert_equal(42,         r.version)
    assert_equal(0xDEADBEEF, r.payload)
  end

  def test_round_trip_modify_only_bit_does_not_disturb_neighbours
    s = CArray.struct(pack: 1) {
      uint16 :header
      bit :flag_a, bits: 1
      bit :flag_b, bits: 1
      bit :version, bits: 6
      uint32 :payload
    }
    r = s.new(header: 0xCAFE,
              flag_a: 0, flag_b: 0, version: 0,
              payload: 0xDEADBEEF)
    r.version = 17
    assert_equal(0xCAFE,     r.header)
    assert_equal(0,          r.flag_a)
    assert_equal(0,          r.flag_b)
    assert_equal(17,         r.version)
    assert_equal(0xDEADBEEF, r.payload)
  end

  def test_round_trip_all_zeros_then_set
    s = CArray.struct(pack: 1) {
      bit :a, bits: 1
      bit :b, bits: 1
      bit :c, bits: 1
    }
    r = s.new
    r.a = 1; r.c = 1
    assert_equal(1, r.a)
    assert_equal(0, r.b)
    assert_equal(1, r.c)
  end

  def test_round_trip_8bit_field
    # 8 bits at bit position 4 spans two bytes (4 bits of byte 0,
    # 4 bits of byte 1).  Exercises the 2-byte view path.
    s = CArray.struct(pack: 1) {
      bit :pad, bits: 4
      bit :value, bits: 8
    }
    r = s.new(pad: 0xA, value: 0xCD)
    assert_equal(0xA,  r.pad)
    assert_equal(0xCD, r.value)
  end

  # --- Builder errors --------------------------------------------------

  def test_bit_requires_name
    assert_raise(CAStruct::DefinitionError) do
      CArray.struct { bit nil, bits: 1 }
    end
  end

  def test_bit_requires_bits_in_range
    [0, -1, 65, 100].each do |bad|
      assert_raise(CAStruct::DefinitionError) do
        CArray.struct { bit :x, bits: bad }
      end
    end
  end

  def test_bit_requires_bits_kwarg
    assert_raise(ArgumentError) do
      CArray.struct { bit :x }      # missing keyword
    end
  end

  def test_bit_in_union_rejected
    assert_raise(CAStruct::DefinitionError) do
      CArray.union { bit :x, bits: 4 }
    end
  end

  # --- Reflection coexistence ------------------------------------------

  def test_bit_member_appears_in_each_pair
    s = CArray.struct(pack: 1) {
      uint8 :tag
      bit :flag, bits: 1
    }
    r = s.new(tag: 7, flag: 1)
    pairs = []
    r.each_pair { |k, v| pairs << [k, v] }
    assert_equal([[:tag, 7], [:flag, 1]], pairs)
  end

  def test_bit_member_eql_round_trip
    s = CArray.struct(pack: 1) {
      uint8 :tag
      bit :flag, bits: 4
    }
    a = s.new(tag: 5, flag: 9)
    b = s.new(tag: 5, flag: 9)
    c = s.new(tag: 5, flag: 8)
    assert(a.eql?(b))
    refute(a.eql?(c))
    assert_equal(a.hash, b.hash)
  end

end
