require "test/unit"
require "carray"

# CIFY Phase 1: C-native CAStruct#[] / #[]= for primitive members
# without `endian:`.  The C path consults the per-class
# FAST_PRIMITIVES hash and does a direct memcpy + INT2FIX/DBL2NUM
# from @data.ptr + offset, skipping the CAField view allocation
# that the previous Ruby path went through.
#
# These tests pin:
#
# - FAST_PRIMITIVES is built with the right shape and only includes
#   the C-eligible members (no bit / endian / nested / template /
#   fixlen / cmplx).
# - The C `[]` / `[]=` are installed as `CAStruct#[]` / `#[]=`.
# - Each supported primitive type round-trips through C (including
#   edge values: type min/max, negative, fractional).
# - Behaviour identical to the pre-Phase-1 Ruby path for all the
#   members that the fast path doesn't cover (bit / endian / fixlen /
#   nested / template).
# - Unknown-name fallback to `send` still works (computed members in
#   subclasses).

class TestCAStructCIFYPhase1 < Test::Unit::TestCase

  # --- FAST_PRIMITIVES content ---------------------------------------

  def test_fast_primitives_includes_plain_numeric_members
    s = CArray.struct(pack: 1) {
      int8    :i8
      uint8   :u8
      int16   :i16
      uint16  :u16
      int32   :i32
      uint32  :u32
      int64   :i64
      uint64  :u64
      float32 :f32
      float64 :f64
    }
    expected = %w[i8 u8 i16 u16 i32 u32 i64 u64 f32 f64]
    assert_equal expected.sort, s::FAST_PRIMITIVES.keys.sort
    s::FAST_PRIMITIVES.each_value do |entry|
      assert_kind_of Array, entry
      # Phase 2 onward: entry[0] is a kind tag (FAST_KIND_*),
      # rest is per-kind payload.  Primitive entries are
      # [FAST_KIND_PRIMITIVE=0, byte_offset, ca_type_code].
      assert_equal CAStruct::Builder::FAST_KIND_PRIMITIVE, entry[0]
      assert_equal 3, entry.size
      assert_kind_of Integer, entry[1]   # byte offset
      assert_kind_of Integer, entry[2]   # CA_* type code
      assert entry.frozen?
    end
  end

  def test_fast_primitives_includes_bit_members
    # Phase 2: bit-fields land in FAST_PRIMITIVES with kind tag
    # FAST_KIND_BITFIELD = 1 and payload
    # [start_byte, view_bytes, bit_in_word, bits].
    s = CArray.struct(pack: 1) {
      uint16 :ok
      bit :flag, bits: 1
    }
    assert s::FAST_PRIMITIVES.key?("ok")
    assert s::FAST_PRIMITIVES.key?("flag")
    flag_entry = s::FAST_PRIMITIVES["flag"]
    assert_equal CAStruct::Builder::FAST_KIND_BITFIELD, flag_entry[0]
    assert_equal 5, flag_entry.size
    assert_equal 2, flag_entry[1]   # start_byte: 2 (after uint16)
    assert_equal 1, flag_entry[2]   # view_bytes: 1
    assert_equal 0, flag_entry[3]   # bit_in_word: 0
    assert_equal 1, flag_entry[4]   # bits: 1
  end

  def test_fast_primitives_endian_matching_host_is_primitive_kind
    # When the requested endian matches the host, no swap is needed
    # and Builder folds the member into FAST_KIND_PRIMITIVE.
    host_endian = CArray.endian
    matching_endian = host_endian == CA_LITTLE_ENDIAN ? :little : :big
    s = CArray.struct(pack: 1) {
      uint32 :v, endian: matching_endian
    }
    entry = s::FAST_PRIMITIVES["v"]
    assert_equal CAStruct::Builder::FAST_KIND_PRIMITIVE, entry[0]
  end

  def test_fast_primitives_endian_differing_from_host_is_endian_kind
    host_endian = CArray.endian
    other_endian = host_endian == CA_LITTLE_ENDIAN ? :big : :little
    s = CArray.struct(pack: 1) {
      uint32 :v, endian: other_endian
    }
    entry = s::FAST_PRIMITIVES["v"]
    assert_equal CAStruct::Builder::FAST_KIND_ENDIAN, entry[0]
    assert_equal 3, entry.size
  end

  def test_fast_primitives_excludes_fixlen_nested_template
    inner = CArray.struct { uint8 :x }
    s = CArray.struct {
      uint16 :ok
      fixlen :tag, bytes: 4
      member inner, :nest
      array  :coords, type: CArray.int32(3)
    }
    assert s::FAST_PRIMITIVES.key?("ok")
    refute s::FAST_PRIMITIVES.key?("tag")
    refute s::FAST_PRIMITIVES.key?("nest")
    refute s::FAST_PRIMITIVES.key?("coords")
  end

  # --- C methods installed -------------------------------------------

  def test_castruct_aref_is_defined_in_c
    # Methods sourced from C extensions have nil source_location.
    assert_nil CAStruct.instance_method(:[]).source_location
    assert_nil CAStruct.instance_method(:[]=).source_location
  end

  # --- Per-type round-trip --------------------------------------------

  S_ALL_PRIMS = CArray.struct(pack: 1) {
    int8    :i8
    uint8   :u8
    int16   :i16
    uint16  :u16
    int32   :i32
    uint32  :u32
    int64   :i64
    uint64  :u64
    float32 :f32
    float64 :f64
    boolean :bo
  }

  def test_int8_range
    r = S_ALL_PRIMS.new
    [-128, -1, 0, 1, 127].each do |v|
      r[:i8] = v
      assert_equal v, r[:i8], "int8 round-trip for #{v}"
    end
  end

  def test_uint8_range
    r = S_ALL_PRIMS.new
    [0, 1, 127, 128, 255].each do |v|
      r[:u8] = v
      assert_equal v, r[:u8]
    end
  end

  def test_int16_range
    r = S_ALL_PRIMS.new
    [-32768, -1, 0, 32767].each do |v|
      r[:i16] = v
      assert_equal v, r[:i16]
    end
  end

  def test_uint16_range
    r = S_ALL_PRIMS.new
    [0, 65535].each do |v|
      r[:u16] = v
      assert_equal v, r[:u16]
    end
  end

  def test_int32_range
    r = S_ALL_PRIMS.new
    [-(2**31), -1, 0, 2**31 - 1].each do |v|
      r[:i32] = v
      assert_equal v, r[:i32]
    end
  end

  def test_uint32_range
    r = S_ALL_PRIMS.new
    [0, 2**32 - 1].each do |v|
      r[:u32] = v
      assert_equal v, r[:u32]
    end
  end

  def test_int64_range
    r = S_ALL_PRIMS.new
    [-(2**63), -1, 0, 2**63 - 1].each do |v|
      r[:i64] = v
      assert_equal v, r[:i64]
    end
  end

  def test_uint64_range
    r = S_ALL_PRIMS.new
    [0, 2**64 - 1].each do |v|
      r[:u64] = v
      assert_equal v, r[:u64]
    end
  end

  def test_float32_values
    r = S_ALL_PRIMS.new
    r[:f32] = 1.5
    assert_in_delta 1.5, r[:f32], 1e-6
    r[:f32] = -3.25
    assert_in_delta(-3.25, r[:f32], 1e-6)
  end

  def test_float64_values
    r = S_ALL_PRIMS.new
    r[:f64] = Math::PI
    assert_in_delta Math::PI, r[:f64], 1e-15
  end

  def test_boolean_round_trip
    r = S_ALL_PRIMS.new
    r[:bo] = 1
    assert_equal 1, r[:bo]
    r[:bo] = 0
    assert_equal 0, r[:bo]
  end

  # --- Sibling fields stay isolated (no aliasing across offsets) ------

  def test_fast_writes_isolated_from_neighbours
    s = CArray.struct(pack: 1) {
      int32  :a
      int32  :b
      int32  :c
    }
    r = s.new(a: 0xAAAAAAA, b: 0xBBBBBBB, c: 0xCCCCCCC)
    r[:b] = 0x1234
    assert_equal 0xAAAAAAA, r[:a]
    assert_equal 0x1234,    r[:b]
    assert_equal 0xCCCCCCC, r[:c]
  end

  # --- Integer-index routing --------------------------------------

  def test_integer_index_routes_through_c
    s = CArray.struct { int32 :x; int32 :y }
    r = s.new(x: 11, y: 22)
    assert_equal 11, r[0]
    assert_equal 22, r[1]
    r[0] = 99
    assert_equal 99, r[:x]
  end

  # --- Symbol vs String name parity ----------------------------------

  def test_symbol_and_string_name_lookup_agree
    s = CArray.struct { int32 :v }
    r = s.new(v: 42)
    assert_equal 42, r[:v]
    assert_equal 42, r["v"]
    r[:v] = 7
    assert_equal 7, r["v"]
    r["v"] = 99
    assert_equal 99, r[:v]
  end

  # --- Fallback paths still work (bit / endian / fixlen) --------------

  def test_bit_member_still_works_via_dispatch_table
    s = CArray.struct(pack: 1) {
      uint16 :head
      bit :flag, bits: 1
      bit :version, bits: 7
    }
    r = s.new(head: 0x1234, flag: 1, version: 42)
    assert_equal 1,  r[:flag]
    assert_equal 42, r[:version]
    r[:version] = 7
    assert_equal 7, r[:version]
    assert_equal 1, r[:flag]    # neighbour unchanged
  end

  def test_endian_member_still_works_via_dispatch_table
    s = CArray.struct(pack: 1) { int32 :payload, endian: :big }
    r = s.new(payload: 0x01020304)
    assert_equal "\x01\x02\x03\x04".b, r.encode
    assert_equal 0x01020304, r[:payload]
  end

  def test_fixlen_member_still_works_via_dispatch_table
    s = CArray.struct { fixlen :tag, bytes: 4 }
    r = s.new(tag: "abcd")
    assert_equal "abcd", r[:tag]
    r[:tag] = "wxyz"
    assert_equal "wxyz", r[:tag]
  end

  # --- Unknown-name fallback to send ----------------------------------

  class WithComputed < CAStruct
    DATA_SIZE       = 4
    MEMBERS         = ["x"].freeze
    MEMBER_TABLE    = { "x" => [0, :int32] }.freeze
    DISPATCH_TABLE  =
      CAStruct::Builder.build_dispatch_table(MEMBER_TABLE, DATA_SIZE).freeze
    FAST_PRIMITIVES =
      CAStruct::Builder.build_fast_primitives(MEMBER_TABLE).freeze

    def twice
      self[:x] * 2
    end
  end

  def test_unknown_name_routes_to_send
    r = WithComputed.new
    r[:x] = 21
    assert_equal 42, r[:twice]
  end

  def test_subclass_without_fast_primitives_still_works
    # Defensive: the C path should not crash if FAST_PRIMITIVES is
    # absent (e.g. on a subclass constructed by hand that only sets
    # DISPATCH_TABLE).  It must fall through to DISPATCH_TABLE.
    klass = Class.new(CAStruct) do
      const_set :DATA_SIZE, 4
      const_set :MEMBERS, ["v"].freeze
      const_set :MEMBER_TABLE, { "v" => [0, :int32] }.freeze
      const_set :DISPATCH_TABLE,
                CAStruct::Builder.build_dispatch_table(self::MEMBER_TABLE,
                                                       self::DATA_SIZE).freeze
      # Intentionally no FAST_PRIMITIVES.
    end
    refute klass.const_defined?(:FAST_PRIMITIVES, false)
    r = klass.new
    r[:v] = 7
    assert_equal 7, r[:v]
  end

end
