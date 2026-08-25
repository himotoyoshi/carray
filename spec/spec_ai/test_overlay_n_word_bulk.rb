# spec_ai/test_overlay_n_word_bulk.rb
#
# M.2 — ca_copy_mask_overlay_n の word-bulk 化 (= per-byte OR + defensive
# `if (*ms)` から ca_mask_word_or 経由の pure word OR + scalar branch の
# memset 化) の動作 pin。
#
# §3.2 A 採択の post-condition `mask byte ∈ {0,1}` invariant を
# binop の実 path 経由で観察し、future regression を検出する。
#
# overlay_n は public API ではないため、binop 経路で trigger する形で test
# する (= `a + b` 等で内部で呼ばれる、carray_operator.c 経由)。
#
# See devel/PROPOSAL_MASK_SUBSTRATE_BULK_SIMD.md §2.1 (a), §3.2, §5.

require 'test/unit'
require 'carray'

class TestOverlayNWordBulkM2 < Test::Unit::TestCase

  # ----- post-condition: mask byte ∈ {0,1} -------------------------------

  def assert_mask_invariant(ca, msg = nil)
    return unless ca.has_mask?
    mask = ca.mask
    mask.elements.times do |i|
      v = mask[i]
      assert(v == true || v == false,
             "%s: mask byte[%d] = %s violates boolean invariant" %
               [msg || ca.inspect, i, v.inspect])
    end
  end

  # ----- basic: binop with one masked operand ----------------------------

  def test_binop_one_masked_carries_mask
    a = CArray.int32(10).seq
    b = CArray.int32(10).seq
    a[3] = UNDEF
    a[7] = UNDEF
    c = a + b
    # masked positions propagate; values at masked positions are not verified
    # (mask take precedence) — verify mask shape only.
    assert(c.has_mask?, "result must have mask after binop with masked operand")
    masked = c.mask.to_a.each_with_index.select { |v, _| v }.map(&:last)
    assert_equal([3, 7], masked.sort)
    # unmasked positions = a + b
    assert_equal(0,  c[0])
    assert_equal(2,  c[1])
    assert_equal(18, c[9])
    assert_mask_invariant(c, "binop one masked")
  end

  def test_binop_both_masked_OR_semantics
    a = CArray.int32(10).seq
    b = CArray.int32(10).seq
    a[3] = UNDEF
    a[7] = UNDEF
    b[5] = UNDEF
    b[7] = UNDEF  # overlap with a[7]
    c = a + b
    # masked positions in result = union (= OR) of a and b mask positions
    masked = c.mask.to_a.each_with_index.select { |v, _| v }.map(&:last)
    assert_equal([3, 5, 7], masked.sort)
    assert_mask_invariant(c, "binop both masked")
  end

  # ----- scalar source path (= ca_is_scalar branch in overlay_n) ---------

  def test_binop_with_masked_scalar_broadcasts_mask
    # CScalar with mask = 1 should mask ALL output elements (= memset path)
    a = CArray.int32(10).seq
    s = CScalar.int32
    s[0] = 100
    s[0] = UNDEF                  # mask the scalar
    c = a + s
    assert(c.has_mask?, "result must have mask after binop with masked scalar")
    # all output positions masked
    assert_equal(Array.new(10, true), c.mask.to_a,
                 "masked scalar must broadcast mask to all output positions")
    assert_mask_invariant(c, "binop with masked scalar")
  end

  def test_binop_with_unmasked_scalar_does_not_create_mask_if_array_clean
    # scalar with no mask + array with no mask → result mask should not appear
    a = CArray.int32(10).seq
    s = CScalar.int32
    s[0] = 100
    c = a + s
    assert_equal(false, c.has_mask?, "no mask anywhere → result should be clean")
  end

  # ----- sizes that exercise word + tail paths --------------------------

  def test_binop_sizes_word_and_tail
    [1, 7, 8, 15, 16, 17, 23, 24, 100, 1000].each do |n|
      a = CArray.int32(n).seq
      b = CArray.int32(n).seq
      a[n / 2] = UNDEF  # somewhere in the middle
      a[n - 1] = UNDEF  # tail boundary
      c = a + b
      assert(c.has_mask?, "n=#{n}: result must have mask")
      assert_equal(true, c.mask[n / 2], "n=#{n}: middle mask preserved")
      assert_equal(true, c.mask[n - 1], "n=#{n}: tail mask preserved")
      # invariant must hold even after word path with arbitrary middle/tail
      assert_mask_invariant(c, "n=#{n}")
    end
  end

  # ----- multi-source overlay (>= 3 sources) ----------------------------

  def test_chain_binop_3_sources
    n = 100
    a = CArray.int32(n).seq
    b = CArray.int32(n).seq
    d = CArray.int32(n).seq
    a[10] = UNDEF
    b[20] = UNDEF
    d[30] = UNDEF
    c = a + b + d  # chains overlay_n twice
    masked = c.mask.to_a.each_with_index.select { |v, _| v }.map(&:last)
    assert_equal([10, 20, 30], masked.sort, "chain binop masks union")
    assert_mask_invariant(c, "chain 3-source")
  end

  # ----- byte parity vs pre-M.2 reference --------------------------------

  def test_byte_parity_with_known_pattern
    # Construct a known sparse mask pattern and verify word OR result is
    # identical to byte-level OR (= behavior preservation pin).
    n = 256
    a = CArray.int32(n).seq
    b = CArray.int32(n).seq
    # sparse mask on a (every 5th position)
    (0...n).step(5) { |i| a[i] = UNDEF }
    # different sparse mask on b (every 7th position)
    (0...n).step(7) { |i| b[i] = UNDEF }

    c = a + b
    expected = Array.new(n) { |i| (i % 5 == 0 || i % 7 == 0) ? true : false }
    assert_equal(expected, c.mask.to_a, "byte-level OR pattern match")
    assert_mask_invariant(c, "sparse byte parity")
  end

  # ----- defensive read removal: invariant {0,1} must still hold --------

  def test_repeated_binop_does_not_corrupt_mask_bytes
    # Stress: repeatedly OR mask into result, verify each result has
    # mask byte ∈ {0,1}.  This pins §3.2 A: pure word OR without
    # `if (*ms)` gating still produces clean {0,1} bytes when the input
    # invariant is respected.
    100.times do |round|
      n = 50 + round
      a = CArray.int32(n).seq
      b = CArray.int32(n).seq
      a[round % n] = UNDEF
      c = a + b
      assert_mask_invariant(c, "round=#{round}")
    end
  end
end
