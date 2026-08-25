require "test/unit"
require "carray"

# PROPOSAL_MV_CONSUMER_FIXLEN_BYTES: plain CA_FIXLEN <-> PEP 3118 "Ns"
# round trip on both producer (emit "Ns") and consumer (accept "Ns") sides.
# Validates the format parser, self round-trip via wrap/copy, width
# alignment, and interaction with the existing data_class T{...} path.

class TestMemoryViewFixlenBytes < Test::Unit::TestCase

  # ============================================================
  # parser: PEP 3118 "Ns" -> CA_FIXLEN
  # ============================================================

  def test_parse_8s_returns_fixlen
    assert_equal(:fixlen,
                 CArray.__send__(:__memory_view_parse_format__, "8s", 8))
  end

  def test_parse_1s_returns_fixlen
    assert_equal(:fixlen,
                 CArray.__send__(:__memory_view_parse_format__, "1s", 1))
  end

  def test_parse_with_align_prefix
    # numpy emits "|S8" -> "|8s" after dialect translation; the
    # consumer's '|' strip must leave the rest unchanged.
    assert_equal(:fixlen,
                 CArray.__send__(:__memory_view_parse_format__, "|8s", 8))
  end

  def test_parse_width_mismatch_rejected
    # 8s requires item_size=8; mismatched item_size is rejected the
    # same way numeric format/item_size mismatches are.
    assert_nil(CArray.__send__(:__memory_view_parse_format__, "8s", 4))
    assert_nil(CArray.__send__(:__memory_view_parse_format__, "4s", 8))
  end

  def test_parse_zero_length_rejected
    # PEP 3118 "0s" exists in numpy but CA_FIXLEN requires bytes > 0.
    assert_nil(CArray.__send__(:__memory_view_parse_format__, "0s", 0))
  end

  def test_parse_bare_s_still_int16
    # Standalone "s" with item_size=2 must still resolve to CA_INT16
    # (existing 16-bit rule), unaffected by the new "\d+s" branch.
    assert_equal(:int16,
                 CArray.__send__(:__memory_view_parse_format__, "s", 2))
  end

  def test_parse_non_numeric_prefix_rejected
    # "abc8s" must not be misread as 8s; strtol stops at 'a' and the
    # endp check fails.
    assert_nil(CArray.__send__(:__memory_view_parse_format__, "abc8s", 8))
  end

  # ============================================================
  # producer: CA_FIXLEN emits "Ns"
  # ============================================================

  def test_producer_emits_ns_for_plain_fixlen
    a = CArray.fixlen(3, bytes: 8) { |i| "abc#{i}" }
    assert_equal("8s",
                 CArray.__send__(:__memory_view_format__, a))
  end

  def test_producer_emits_1s_for_byte_wide_fixlen
    a = CArray.fixlen(5, bytes: 1) { |i| (?a.ord + i).chr }
    assert_equal("1s",
                 CArray.__send__(:__memory_view_format__, a))
  end

  def test_memory_view_available_true_for_fixlen
    a = CArray.fixlen(3, bytes: 4) { |i| "x%02d" % i }
    assert_equal(true, CArray.memory_view_available?(a))
  end

  def test_producer_format_is_cached
    # Repeat calls should reuse the same Ruby String (ivar cache),
    # giving a stable pointer for the duration of the view's lifetime.
    a = CArray.fixlen(3, bytes: 4) { |i| "x%02d" % i }
    f1 = CArray.__send__(:__memory_view_format__, a)
    f2 = CArray.__send__(:__memory_view_format__, a)
    assert_same(f1, f2, "format String should be cached on the instance")
  end

  # ============================================================
  # self round trip: wrap / from
  # ============================================================

  def test_wrap_self_round_trip
    a = CArray.fixlen(3, bytes: 8) { |i| "row#{i}" }
    w = CArray.wrap_memory_view(a)
    assert_kind_of(CAWrap, w)
    assert_equal(:fixlen, w.data_type_name.to_sym)
    assert_equal(8, w.bytes)
    assert_equal([3], w.shape)
    assert_equal(a.to_a, w.to_a)
  end

  def test_wrap_self_round_trip_2d
    a = CArray.fixlen(2, 3, bytes: 4) { |i, j| "%01d%02d" % [i, j] }
    w = CArray.wrap_memory_view(a)
    assert_equal([2, 3], w.shape)
    assert_equal(4, w.bytes)
    assert_equal(a.to_a, w.to_a)
  end

  def test_wrap_self_round_trip_write_propagates
    a = CArray.fixlen(3, bytes: 4) { |i| "x%02d#" % i }
    w = CArray.wrap_memory_view(a)
    w[1] = "abcd"
    assert_equal("abcd", a[1], "writes via wrap must reach source FIXLEN buffer")
  end

  def test_from_self_round_trip_copy_independent
    a = CArray.fixlen(3, bytes: 4) { |i| "x%02d#" % i }
    c = CArray.from_memory_view(a)
    refute_kind_of(CAWrap, c)
    assert_equal(:fixlen, c.data_type_name.to_sym)
    assert_equal(4, c.bytes)
    assert_equal(a.to_a, c.to_a)
    a[0] = "ZZZZ"
    refute_equal("ZZZZ", c[0], "copy must be independent of source")
  end

  # ============================================================
  # FIXLEN + paired mask (composes with PROPOSAL_MV_MASKED_WRAP)
  # ============================================================

  def test_wrap_fixlen_with_mask
    data = CArray.fixlen(3, bytes: 4) { |i| "x%02d#" % i }
    mask = CArray.boolean(3) { |i| i == 1 ? 1 : 0 }
    w = CArray.wrap_memory_view(data, mask: mask)
    assert_equal(true, w.has_mask?)
    assert_equal(:fixlen, w.data_type_name.to_sym)
    assert_equal([false, true, false], w.mask.to_a)
  end

  def test_from_fixlen_with_mask_copy
    data = CArray.fixlen(3, bytes: 4) { |i| "x%02d#" % i }
    mask = CArray.boolean(3) { |i| i.even? ? 1 : 0 }
    c = CArray.from_memory_view(data, mask: mask)
    assert_equal(true, c.has_mask?)
    assert_equal(:fixlen, c.data_type_name.to_sym)
    assert_equal([true, false, true], c.mask.to_a)
  end

  # ============================================================
  # data_class FIXLEN still takes the T{...} path (unchanged)
  # ============================================================

  def test_fixlen_with_data_class_still_emits_struct_format
    # CARecord-backed FIXLEN must continue using the T{...} struct
    # format, NOT the new "Ns" path.
    s = CArray.struct(pack: 1) { int32 :id; float64 :v }
    a = CARecord.new(s, 3)
    fmt = CArray.__send__(:__memory_view_format__, a)
    assert_match(/\AT\{/, fmt,
                 "data-classed FIXLEN must still emit a T{...} struct format")
  end

end
