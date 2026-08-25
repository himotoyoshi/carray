require "test/unit"
require "carray"

# ENHANCE_CASTRUCT Phase A.1 (carray-3.0, 2026-05-21):
# CArray emits PEP 3118 struct format strings for CAStruct arrays
# via MemoryView. This test file pins the emission behaviour.
#
# The struct format used INSIDE T{...} follows PEP 3118 dialect
# (b/B/h/H/i/I/q/Q/f/d, ?, Zf, Zd), which differs from the v1.1
# top-level table that uses Ruby pack symbols (c/C/s/S/l/L/q/Q/f/d).
# See MEMORYVIEW_FORMAT.md (forthcoming v1.2 §X for struct format)
# and devel/MIGRATION_ENHANCE_CASTRUCT.md.

class TestMVStructFormat < Test::Unit::TestCase

  # --- core emission ----------------------------------------------------

  def test_simple_struct_format
    s = CArray.struct(pack: 1) { int32 :a; float64 :b }
    a = CARecord.new(s, 3)
    assert_equal("T{i:a:d:b:}", CArray.__memory_view_format__(a))
  end

  def test_field_order_preserved
    s = CArray.struct(pack: 1) { float64 :y; int32 :x; int8 :z }
    a = CARecord.new(s, 1)
    assert_equal("T{d:y:i:x:b:z:}", CArray.__memory_view_format__(a))
  end

  def test_all_primitive_types
    s = CArray.struct(pack: 1) {
      boolean  :p_bool
      int8     :p_i8
      uint8    :p_u8
      int16    :p_i16
      uint16   :p_u16
      int32    :p_i32
      uint32   :p_u32
      int64    :p_i64
      uint64   :p_u64
      float32  :p_f32
      float64  :p_f64
      cmplx64  :p_c64
      cmplx128 :p_c128
    }
    a = CARecord.new(s, 1)
    expected =
      "T{?:p_bool:b:p_i8:B:p_u8:h:p_i16:H:p_u16:" \
      "i:p_i32:I:p_u32:q:p_i64:Q:p_u64:" \
      "f:p_f32:d:p_f64:Zf:p_c64:Zd:p_c128:}"
    assert_equal(expected, CArray.__memory_view_format__(a))
  end

  def test_complex_uses_pep3118_Z_prefix
    s = CArray.struct(pack: 1) { cmplx64 :z32; cmplx128 :z64 }
    a = CARecord.new(s, 1)
    assert_equal("T{Zf:z32:Zd:z64:}", CArray.__memory_view_format__(a))
  end

  # --- padding emission (v1.2 §6.1: 'x' is PEP 3118 canonical) --------

  def test_aligned_struct_emits_padding
    # Default alignment: uint8 + uint64 has 7 bytes of implicit pad
    # between the two members.  PEP 3118 represents pad bytes with
    # 'x'; per v1.2 §6.4 (ratified 2026-05-21) the canonical form is
    # elided (no name slot after the pad spec): "T{B:a:7x:Q:b:}".
    # Consumers MUST accept both elided and legacy named
    # ("T{B:a:7x:_:Q:b:}") forms.
    s = CArray.struct { uint8 :a; uint64 :b }     # default alignment
    a = CARecord.new(s, 1)
    assert_equal(16, s::DATA_SIZE)
    assert_equal("T{B:a:7x:Q:b:}", CArray.__memory_view_format__(a))
  end

  def test_packed_struct_has_no_padding
    s = CArray.struct(pack: 1) { uint8 :a; uint64 :b }
    a = CARecord.new(s, 1)
    assert_equal(9, s::DATA_SIZE)
    assert_equal("T{B:a:Q:b:}", CArray.__memory_view_format__(a))
  end

  def test_trailing_padding_via_size_option
    # :size larger than the natural body forces trailing pad bytes.
    # Elided form per v1.2 §6.4 (see test_aligned_struct_emits_padding
    # for rationale).
    s = CArray.struct(pack: 1, size: 16) { uint32 :x }
    a = CARecord.new(s, 1)
    assert_equal("T{I:x:12x:}", CArray.__memory_view_format__(a))
  end

  def test_bitfield_member_rejects_struct_format
    # PEP 3118 has no notation for bit fields, and our producer
    # cannot express them; bit-bearing structs reject cleanly.
    s = CArray.struct(pack: 1) { uint8 :flag; bit :b, bits: 1 }
    a = CARecord.new(s, 1)
    refute(CArray.memory_view_available?(a))
    assert_nil(CArray.__memory_view_format__(a))
  end

  # --- MV availability hookup -------------------------------------------

  def test_struct_array_is_memory_view_available
    s = CArray.struct(pack: 1) { int32 :a; float64 :b }
    a = CARecord.new(s, 4)
    assert(CArray.memory_view_available?(a),
           "struct arrays should be exportable after Phase A.1")
    assert_nil(CArray.memory_view_reject_reason(a))
  end

  def test_reject_unsupported_member_types
    # fixlen member inside a struct: unsupported in A.1 (no portable
    # PEP 3118 spec for opaque fixed-bytes types).
    s = CArray.struct(pack: 1) { int32 :a; fixlen :opaque, bytes: 8 }
    a = CARecord.new(s, 1)
    refute(CArray.memory_view_available?(a))
    reason = CArray.memory_view_reject_reason(a)
    assert_match(/struct data_class contains a member type/, reason)
  end

  def test_bare_fixlen_without_data_class_emits_ns
    # PROPOSAL_MV_CONSUMER_FIXLEN_BYTES: a plain CA_FIXLEN (no
    # data_class) now exports as PEP 3118 "Ns" (fixed-width bytes),
    # joining the existing T{...} struct format for data-classed
    # FIXLEN.  Previously rejected; the producer side is symmetric
    # with the consumer-side acceptance of "Ns".
    a = CArray.new(:fixlen, [3], bytes: 4)
    assert(CArray.memory_view_available?(a))
    assert_equal("4s", CArray.__memory_view_format__(a))
  end

  # --- caching behaviour ------------------------------------------------

  def test_format_string_is_cached_on_data_class
    s = CArray.struct(pack: 1) { int32 :a; float64 :b }
    a = CARecord.new(s, 1)
    fmt1 = CArray.__memory_view_format__(a)
    fmt2 = CArray.__memory_view_format__(a)
    assert_equal(fmt1, fmt2)
    # Same object identity (cached, not rebuilt) — equality alone
    # doesn't prove caching, but identity does.
    assert_same(fmt1, fmt2)
  end

  def test_format_string_is_frozen
    s = CArray.struct(pack: 1) { int32 :a }
    a = CARecord.new(s, 1)
    fmt = CArray.__memory_view_format__(a)
    assert_predicate(fmt, :frozen?)
  end

  # --- top-level primitive format (PEP 3118 strict) ---------------------

  def test_top_level_primitive_format_uses_pep3118_strict
    assert_equal("i", CArray.__memory_view_format__(CArray.int32(3)))
    assert_equal("d", CArray.__memory_view_format__(CArray.float64(3)))
    assert_equal("?", CArray.__memory_view_format__(CArray.boolean(3)))
  end

  # --- CAField produces primitive format (Phase F sanity check) ---------

  def test_field_view_emits_primitive_format
    s = CArray.struct(pack: 1) { int32 :id; float64 :x }
    a = CARecord.new(s, 5)
    fa = a["x"]
    assert_equal("d", CArray.__memory_view_format__(fa))
  end

end
