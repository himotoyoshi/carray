require "test/unit"
require "carray"

# Direct tests of the consumer-side format parser per
# devel/MEMORYVIEW_FORMAT.md.  Mirrors the equivalent test on the
# numo-narray-memoryview side (test/test_format_parser.rb) so that
# both implementations cover the same (format, item_size) matrix.
#
# Uses the private CArray.__memory_view_parse_format__(format,
# item_size) hook to exercise the parser without going through a
# producer.

class TestFormatParser < Test::Unit::TestCase

  def parse(format, item_size)
    CArray.__memory_view_parse_format__(format, item_size)
  end

  # ============================================================
  # §2 canonical table — each producer canonical entry round-trips
  # ============================================================

  def test_canonical_int8
    assert_equal(CA_INT8, parse("c", 1))
  end

  def test_canonical_uint8
    assert_equal(CA_UINT8, parse("C", 1))
  end

  def test_canonical_int16
    assert_equal(CA_INT16, parse("s", 2))
  end

  def test_canonical_uint16
    assert_equal(CA_UINT16, parse("S", 2))
  end

  def test_canonical_int32
    assert_equal(CA_INT32, parse("l", 4))
  end

  def test_canonical_uint32
    assert_equal(CA_UINT32, parse("L", 4))
  end

  def test_canonical_int64
    assert_equal(CA_INT64, parse("q", 8))
  end

  def test_canonical_uint64
    assert_equal(CA_UINT64, parse("Q", 8))
  end

  def test_canonical_float32
    assert_equal(CA_FLOAT32, parse("f", 4))
  end

  def test_canonical_float64
    assert_equal(CA_FLOAT64, parse("d", 8))
  end

  # v1.1: PEP 3118 canonical for bool and complex
  def test_canonical_boolean
    assert_equal(CA_BOOLEAN, parse("?", 1))
  end

  def test_canonical_complex64
    assert_equal(CA_CMPLX64, parse("Zf", 8))
  end

  def test_canonical_complex128
    assert_equal(CA_CMPLX128, parse("Zd", 16))
  end

  # ============================================================
  # §3.2 synonym table — accepted alternative spellings
  # ============================================================

  def test_synonyms_int8
    assert_equal(CA_INT8, parse("b", 1))
  end

  def test_synonyms_uint8
    assert_equal(CA_UINT8, parse("B", 1))
  end

  # v1.1: legacy v1.0 compat synonyms for complex (ff/dd).
  # New producers emit Zf/Zd; these rows ensure interop with
  # pre-v1.1 CArray and pre-076351a numo-narray-memoryview.
  def test_compat_synonym_complex64_ff
    assert_equal(CA_CMPLX64, parse("ff", 8))
  end

  def test_compat_synonym_complex128_dd
    assert_equal(CA_CMPLX128, parse("dd", 16))
  end

  def test_synonyms_int16
    assert_equal(CA_INT16, parse("s!", 2))
    assert_equal(CA_INT16, parse("h", 2))
  end

  def test_synonyms_uint16
    assert_equal(CA_UINT16, parse("S!", 2))
    assert_equal(CA_UINT16, parse("H", 2))
  end

  def test_synonyms_int32
    assert_equal(CA_INT32, parse("i", 4))
    assert_equal(CA_INT32, parse("i!", 4))
    assert_equal(CA_INT32, parse("l!", 4))   # LP32 native long
  end

  def test_synonyms_uint32
    assert_equal(CA_UINT32, parse("I", 4))
    assert_equal(CA_UINT32, parse("I!", 4))
    assert_equal(CA_UINT32, parse("L!", 4))  # LP32 native unsigned long
  end

  def test_synonyms_int64
    assert_equal(CA_INT64, parse("q!", 8))
    assert_equal(CA_INT64, parse("l!", 8))   # LP64 native long
  end

  def test_synonyms_uint64
    assert_equal(CA_UINT64, parse("Q!", 8))
    assert_equal(CA_UINT64, parse("L!", 8))  # LP64 native unsigned long
  end

  # ============================================================
  # §1.2 item_size authority — the tuple key disambiguates
  # ============================================================

  def test_l_bang_routes_by_item_size
    assert_equal(CA_INT32, parse("l!", 4))
    assert_equal(CA_INT64, parse("l!", 8))
  end

  def test_L_bang_routes_by_item_size
    assert_equal(CA_UINT32, parse("L!", 4))
    assert_equal(CA_UINT64, parse("L!", 8))
  end

  # ============================================================
  # §3.3 rejects on item_size mismatch
  # ============================================================

  def test_canonical_with_wrong_size_rejects
    assert_nil(parse("c", 2))    # int8 with 2 bytes
    assert_nil(parse("s", 4))    # int16 with 4 bytes
    assert_nil(parse("i", 8))    # int32 with 8 bytes
    assert_nil(parse("f", 8))    # float32 with 8 bytes
    assert_nil(parse("d", 4))    # float64 with 4 bytes
    # `("l", 8)` is intentionally accepted as int64 (LP64 platform long,
    # numpy default emission); not in this reject set.
  end

  def test_zero_or_negative_item_size_rejects
    assert_nil(parse("l", 0))
    assert_nil(parse("l", -1))
  end

  # ============================================================
  # §3.1 prefix handling
  # ============================================================

  def test_alignment_prefix_stripped
    assert_equal(CA_INT32, parse("|l", 4))
  end

  def test_host_matching_endian_prefix_stripped
    if CArray.little_endian?
      assert_equal(CA_INT32, parse("<l", 4))
      assert_equal(CA_INT32, parse("=l", 4))
    else
      assert_equal(CA_INT32, parse(">l", 4))
      assert_equal(CA_INT32, parse("=l", 4))
    end
  end

  def test_host_mismatching_endian_prefix_rejects
    if CArray.little_endian?
      assert_nil(parse(">l", 4))
    else
      assert_nil(parse("<l", 4))
    end
  end

  # ============================================================
  # §3.1 explicit-endian primary specifiers are rejected in v1.0
  # ============================================================

  def test_endian_bearing_specifiers_rejected
    %w[e g E G n v N V].each do |spec|
      [1, 2, 4, 8].each do |sz|
        assert_nil(parse(spec, sz),
                   "explicit-endian specifier #{spec.inspect} must reject")
      end
    end
  end

  # ============================================================
  # §3.3 misc rejects
  # ============================================================

  def test_nil_format_rejects
    assert_nil(parse(nil, 4))
  end

  def test_empty_format_rejects
    assert_nil(parse("", 4))
  end

  def test_prefix_only_format_rejects
    assert_nil(parse("<", 4))
    assert_nil(parse("|", 4))
  end

  def test_unknown_format_rejects
    assert_nil(parse("Z", 8))     # bare Z without precision marker
    assert_nil(parse("x", 1))
    assert_nil(parse("zzz", 4))
  end

  # v1.1 negative space: well-formed Z* prefixes must reject when
  # the precision marker is unknown or item_size disagrees.
  def test_unknown_Z_specifiers_rejected
    assert_nil(parse("Zc", 1))    # Z + int8 — not PEP 3118
    assert_nil(parse("ZF", 8))    # uppercase — Zf is the canonical form
    assert_nil(parse("ZD", 16))
    assert_nil(parse("Zfx", 8))   # trailing junk
    assert_nil(parse("Zf", 16))   # size mismatch
    assert_nil(parse("Zd", 8))    # size mismatch
  end
end
