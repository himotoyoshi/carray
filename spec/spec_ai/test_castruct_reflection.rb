require "test/unit"
require "carray"

# struct.rb Step 2 (carray-3.0, 2026-05-21):
# Reflection API on CAStruct subclasses.  Promotes the opaque
# `[offset, type, opts]` tuples in MEMBER_TABLE to first-class
# CAStruct::Field value objects, exposed via Foo.fields,
# Foo.field_info(name), and Foo.offset_of(name).
#
# Also pins:
# - MEMBERS / MEMBER_TABLE are frozen at define time.
# - CAStruct#members returns the same MEMBERS array (no clone).

class TestCAStructReflection < Test::Unit::TestCase

  # --- Field value class -----------------------------------------------

  def test_field_is_frozen
    f = CAStruct::Field.new(name: "x", offset: 0, type: :int32, bytes: 4)
    assert_predicate(f, :frozen?)
  end

  def test_field_attr_readers
    f = CAStruct::Field.new(name: "x", offset: 4, type: :float64, bytes: 8)
    assert_equal("x",       f.name)
    assert_equal(4,         f.offset)
    assert_equal(:float64,  f.type)
    assert_equal(8,         f.bytes)
    assert_nil(f.bits)
    assert_nil(f.bit_offset)
  end

  def test_bitfield_predicate_and_attrs
    f = CAStruct::Field.new(name: "f", offset: 2, type: :bitfield,
                            bits: 3, bit_offset: 19)
    assert(f.bitfield?)
    assert_equal(3,  f.bits)
    assert_equal(19, f.bit_offset)
    refute_nil(f.inspect)
    assert_match(/bitfield/, f.inspect)
  end

  def test_field_equality_and_hash
    a = CAStruct::Field.new(name: "x", offset: 0, type: :int32, bytes: 4)
    b = CAStruct::Field.new(name: "x", offset: 0, type: :int32, bytes: 4)
    c = CAStruct::Field.new(name: "y", offset: 0, type: :int32, bytes: 4)
    assert(a.eql?(b))
    refute(a.eql?(c))
    assert_equal(a.hash, b.hash)
    assert_equal(a, b)
  end

  # --- Class-level reflection ------------------------------------------

  def test_struct_fields_returns_field_objects
    s = CArray.struct(pack: 1) { int32 :a; float64 :b }
    flds = s.fields
    assert_equal(2, flds.length)
    assert_kind_of(CAStruct::Field, flds[0])
    assert_equal("a",      flds[0].name)
    assert_equal(:int32,   flds[0].type)
    assert_equal(0,        flds[0].offset)
    assert_equal(4,        flds[0].bytes)
    assert_equal("b",      flds[1].name)
    assert_equal(:float64, flds[1].type)
    assert_equal(4,        flds[1].offset)
    assert_equal(8,        flds[1].bytes)
  end

  def test_struct_fields_includes_bit_members
    s = CArray.struct(pack: 1) {
      uint16 :h
      bit :flag, bits: 1
      bit :ver,  bits: 7
    }
    flds = s.fields
    assert_equal(3, flds.length)
    refute(flds[0].bitfield?)
    assert(flds[1].bitfield?)
    assert_equal(1,  flds[1].bits)
    assert_equal(16, flds[1].bit_offset)
    assert(flds[2].bitfield?)
    assert_equal(7,  flds[2].bits)
    assert_equal(17, flds[2].bit_offset)
  end

  def test_struct_fields_is_frozen_array
    s = CArray.struct(pack: 1) { int32 :a }
    assert_predicate(s.fields, :frozen?)
  end

  def test_struct_fields_is_cached
    s = CArray.struct(pack: 1) { int32 :a; float64 :b }
    assert_same(s.fields, s.fields)
  end

  def test_field_info_accepts_symbol_and_string
    s = CArray.struct(pack: 1) { int32 :a; float64 :b }
    by_sym = s.field_info(:a)
    by_str = s.field_info("a")
    refute_nil(by_sym)
    assert_equal(by_sym, by_str)
  end

  def test_field_info_returns_nil_for_unknown
    s = CArray.struct(pack: 1) { int32 :a }
    assert_nil(s.field_info(:bogus))
    assert_nil(s.field_info("bogus"))
  end

  def test_offset_of_returns_byte_offset
    s = CArray.struct(pack: 1) { int32 :a; float64 :b }
    assert_equal(0, s.offset_of(:a))
    assert_equal(4, s.offset_of(:b))
  end

  def test_offset_of_returns_bit_offset_for_bit_members
    s = CArray.struct(pack: 1) { uint16 :h; bit :flag, bits: 1 }
    assert_equal(0,  s.offset_of(:h))
    assert_equal(16, s.offset_of(:flag))   # bit_offset, not byte offset
  end

  def test_offset_of_returns_nil_for_unknown
    s = CArray.struct(pack: 1) { int32 :a }
    assert_nil(s.offset_of(:bogus))
  end

  # --- MEMBERS / MEMBER_TABLE freeze (Step 2 hygiene) ------------------

  def test_members_is_frozen
    s = CArray.struct(pack: 1) { int32 :a; float64 :b }
    assert_predicate(s::MEMBERS, :frozen?)
  end

  def test_member_table_is_frozen
    s = CArray.struct(pack: 1) { int32 :a; float64 :b }
    assert_predicate(s::MEMBER_TABLE, :frozen?)
  end

  def test_class_members_returns_members_directly
    s = CArray.struct(pack: 1) { int32 :a; float64 :b }
    assert_same(s::MEMBERS, s.members)
  end

  def test_instance_members_returns_members_directly
    s = CArray.struct(pack: 1) { int32 :a; float64 :b }
    r = s.new
    assert_same(s::MEMBERS, r.members)
  end
end
