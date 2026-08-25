require "test/unit"
require "carray"

# ENHANCE_CASTRUCT Step 3 (struct.rb): dispatch table.
#
# CAStruct#[] / #[]= previously branched on `case type` for each
# access (nil → method delegation, :bitfield → CABitfield, Class →
# nested struct decode, CArray → array-template field, else → typed
# numeric field, with an optional `.endian` view chain).  Step 3
# precomputes per-member [reader, writer] Procs once at class
# definition time and stores them in `<klass>::DISPATCH_TABLE`, so
# each runtime access is one Hash lookup + one Proc#call.
#
# Behavioural surface is unchanged; these tests pin the
# table-driven structure so a future regression that, e.g., breaks
# the unknown-name fallback or moves a bounds check back to
# first-access can be caught.

class TestCAStructDispatchTable < Test::Unit::TestCase

  S = CArray.struct(pack: 1) {
    uint16 :header
    bit :flag, bits: 1
    bit :version, bits: 7
    uint32 :payload, endian: :big
    fixlen :tag, bytes: 4
  }

  # --- table shape ------------------------------------------------------

  def test_dispatch_table_is_defined_and_frozen
    assert_kind_of Hash, S::DISPATCH_TABLE
    assert S::DISPATCH_TABLE.frozen?
  end

  def test_dispatch_table_has_one_entry_per_named_member
    assert_equal S::MEMBERS.sort, S::DISPATCH_TABLE.keys.sort
  end

  def test_dispatch_entries_are_reader_writer_pairs
    S::DISPATCH_TABLE.each do |name, pair|
      assert_kind_of Array, pair
      assert_equal 2,         pair.size,  "#{name}: pair size"
      assert_kind_of Proc,    pair[0],    "#{name}: reader"
      assert_kind_of Proc,    pair[1],    "#{name}: writer"
      assert_equal 1,         pair[0].arity, "#{name}: reader arity"
      assert_equal 2,         pair[1].arity, "#{name}: writer arity"
      assert pair.frozen?,                "#{name}: pair frozen"
    end
  end

  # --- end-to-end round-trips through each kind ------------------------

  def test_primitive_member_roundtrip
    r = S.new(header: 0x1234)
    assert_equal 0x1234, r.header
    r[:header] = 0xABCD
    assert_equal 0xABCD, r[:header]
  end

  def test_primitive_with_endian_roundtrip
    r = S.new(payload: 0xDEADBEEF)
    assert_equal 0xDEADBEEF, r.payload
    # Encoded big-endian regardless of host byte order.
    encoded = r.encode
    # payload starts at the byte after header(2) + bit byte(1) = 3
    assert_equal "\xDE\xAD\xBE\xEF".b, encoded.byteslice(3, 4)
  end

  def test_bitfield_member_roundtrip
    r = S.new(flag: 1, version: 42)
    assert_equal 1,  r.flag
    assert_equal 42, r.version
    r[:flag] = 0
    r[:version] = 7
    assert_equal 0, r.flag
    assert_equal 7, r.version
  end

  def test_fixlen_member_roundtrip
    r = S.new(tag: "abcd")
    assert_equal "abcd", r.tag
  end

  # --- unknown-name fallback to `send(name)` ---------------------------

  class WithComputedMember < CAStruct
    DATA_SIZE    = 4
    MEMBERS      = ["x"].freeze
    MEMBER_TABLE = {
      "x" => [0, :int32]
    }.freeze
    DISPATCH_TABLE =
      CAStruct::Builder.build_dispatch_table(MEMBER_TABLE, DATA_SIZE).freeze

    def x_squared
      self[:x] ** 2
    end
  end

  def test_unknown_name_falls_back_to_send
    # `x_squared` is not a struct member but is callable as a method.
    # Step 3 must route `record[:x_squared]` through `send` for
    # backwards compatibility with subclasses defining computed
    # readers.
    r = WithComputedMember.new
    r[:x] = 5
    assert_equal 25, r[:x_squared]
  end

  # --- bit-field bounds check fires at definition time ----------------

  def test_bit_field_spanning_past_record_end_fails_at_definition
    # An 8-bit field starting at bit 1 of a 1-byte struct would need
    # a 2-byte view but the record is only 1 byte.  Step 3 moves
    # this bounds check from first-access to definition time, so it
    # surfaces immediately at CArray.struct call.
    assert_raise(CAStruct::DefinitionError) do
      CArray.struct(pack: 1, size: 1) {
        bit :pad,  bits: 1
        bit :bad,  bits: 8
      }
    end
  end

  # --- dispatcher identity stability ----------------------------------

  def test_dispatcher_pair_is_stable_across_lookups
    p1 = S::DISPATCH_TABLE["header"]
    p2 = S::DISPATCH_TABLE["header"]
    assert_same p1, p2
    assert_same p1[0], p2[0]
  end

  # --- Integer index still works (legacy form) ------------------------

  def test_integer_index_routes_to_named_dispatcher
    r = S.new(header: 0x11, flag: 1, version: 33,
              payload: 0xDEADBEEF, tag: "abcd")
    assert_equal r[:header],  r[0]
    assert_equal r[:flag],    r[1]
    assert_equal r[:version], r[2]
    assert_equal r[:payload], r[3]
    assert_equal r[:tag],     r[4]
  end

  # --- Nested struct member dispatch ----------------------------------

  Inner = CArray.struct { uint8 :a; uint8 :b }
  Outer = CArray.struct {
    member Inner, :nest
    uint8 :z
  }

  def test_nested_struct_member_through_dispatch
    inner = Inner.new(a: 1, b: 2)
    o     = Outer.new(nest: inner, z: 9)
    got   = o[:nest]
    assert_kind_of Inner, got
    assert_equal 1, got.a
    assert_equal 2, got.b
    assert_equal 9, o[:z]
  end

  # --- CArray-template member dispatch --------------------------------

  WithArray = CArray.struct {
    array :coords, type: CArray.int32(3)
  }

  def test_carray_template_member_through_dispatch
    r = WithArray.new
    r[:coords] = [10, 20, 30]
    assert_equal [10, 20, 30], r[:coords].to_a
  end

end
