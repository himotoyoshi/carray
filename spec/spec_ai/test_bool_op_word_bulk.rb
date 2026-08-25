# spec_ai/test_bool_op_word_bulk.rb
#
# M.3.1 — bit_and_i / bit_or_i の no-mask + contig fast path 動作 pin
# (M.3.2 で bit_xor_i / bit_not_i も追加予定)
#
# Fast path 適用条件: data_type == boolean8_t、no-mask、stride 1 (contig)
# その他の path (mask 付き / 非contig / 他 data_type) は既存 byte loop 維持、
# byte parity 確保。
#
# See devel/PROPOSAL_MASK_SUBSTRATE_BULK_SIMD.md §2.1 (b), §3.5, §5.

require 'test/unit'
require 'carray'

class TestBoolOpWordBulkM31 < Test::Unit::TestCase

  # ----- helpers --------------------------------------------------------

  def bool_array(values)
    a = CArray.boolean(values.length)
    values.each_with_index { |v, i| a[i] = v }
    a
  end

  def assert_bool_invariant(ca, msg = nil)
    # Read raw mask bytes to bypass UNDEF semantics on masked positions.
    # We are pinning the underlying byte storage invariant, which holds
    # regardless of mask state.
    ca.elements.times do |i|
      next if ca.has_mask? && ca.mask[i]  # skip masked: value irrelevant
      v = ca[i]
      assert(v == true || v == false,
             "%s: byte[%d] = %s violates boolean" %
               [msg || ca.inspect, i, v.inspect])
    end
  end

  WORD_AND_TAIL_SIZES = [1, 7, 8, 15, 16, 17, 23, 24, 100, 1000, 8193].freeze

  # ----- bit_and_i (= boolean8_t & boolean8_t) ---------------------------

  def test_and_basic
    a = bool_array([0, 0, 1, 1, 0, 0, 1, 1])
    b = bool_array([0, 1, 0, 1, 0, 1, 0, 1])
    c = a & b
    assert_equal([false, false, false, true, false, false, false, true], c.to_a)
    assert_bool_invariant(c, "and basic")
  end

  def test_and_word_and_tail_sizes_contig
    WORD_AND_TAIL_SIZES.each do |n|
      a = bool_array((0...n).map { |i| i.even? ? 1 : 0 })
      b = bool_array((0...n).map { |i| (i % 3 == 0) ? 1 : 0 })
      expected = a.to_a.zip(b.to_a).map { |x, y| x & y }
      c = a & b
      assert_equal(expected, c.to_a, "n=#{n}")
      assert_bool_invariant(c, "and n=#{n}")
    end
  end

  def test_and_identity_with_all_ones
    n = 100
    a    = bool_array((0...n).map { |i| i.even? ? 1 : 0 })
    ones = bool_array(Array.new(n, 1))
    c = a & ones
    assert_equal(a.to_a, c.to_a, "AND with all-1 must be identity")
  end

  def test_and_zero_with_all_zeros
    n = 100
    a     = bool_array((0...n).map { |i| i.even? ? 1 : 0 })
    zeros = bool_array(Array.new(n, 0))
    c = a & zeros
    assert_equal(Array.new(n, false), c.to_a, "AND with all-0 must be all-0")
  end

  # ----- bit_or_i -------------------------------------------------------

  def test_or_basic
    a = bool_array([0, 0, 1, 1, 0, 0, 1, 1])
    b = bool_array([0, 1, 0, 1, 0, 1, 0, 1])
    c = a | b
    assert_equal([false, true, true, true, false, true, true, true], c.to_a)
    assert_bool_invariant(c, "or basic")
  end

  def test_or_word_and_tail_sizes_contig
    WORD_AND_TAIL_SIZES.each do |n|
      a = bool_array((0...n).map { |i| i.even? ? 1 : 0 })
      b = bool_array((0...n).map { |i| (i % 3 == 0) ? 1 : 0 })
      expected = a.to_a.zip(b.to_a).map { |x, y| x | y }
      c = a | b
      assert_equal(expected, c.to_a, "n=#{n}")
      assert_bool_invariant(c, "or n=#{n}")
    end
  end

  def test_or_identity_with_zero
    n = 100
    a     = bool_array((0...n).map { |i| i.even? ? 1 : 0 })
    zeros = bool_array(Array.new(n, 0))
    c = a | zeros
    assert_equal(a.to_a, c.to_a, "OR with all-0 must be identity")
  end

  # ----- non-contig view path: fast path must NOT trigger ---------------

  def test_and_non_contig_view_byte_parity
    # transposed view → stride != 1, fast path branch should be skipped.
    # Compare against per-cell reference to ensure byte parity.
    a = CArray.boolean(8, 10) { |i, j| (i + j) % 2 }
    b = CArray.boolean(8, 10) { |i, j| ((i * 3 + j) % 2) }
    at = a.transpose
    bt = b.transpose
    c = at & bt
    expected = (0...10).map { |i|
      (0...8).map { |j|
        at[i, j] & bt[i, j]
      }
    }
    actual = (0...10).map { |i| (0...8).map { |j| c[i, j] } }
    assert_equal(expected, actual, "transposed AND byte parity")
    assert_bool_invariant(c, "transposed AND")
  end

  def test_or_non_contig_view_byte_parity
    a = CArray.boolean(8, 10) { |i, j| (i + j) % 2 }
    b = CArray.boolean(8, 10) { |i, j| ((i * 3 + j) % 2) }
    at = a.transpose
    bt = b.transpose
    c = at | bt
    expected = (0...10).map { |i|
      (0...8).map { |j|
        at[i, j] | bt[i, j]
      }
    }
    actual = (0...10).map { |i| (0...8).map { |j| c[i, j] } }
    assert_equal(expected, actual, "transposed OR byte parity")
    assert_bool_invariant(c, "transposed OR")
  end

  # ----- mask path: fast path must NOT trigger --------------------------

  def test_and_with_mask_byte_parity
    a = bool_array(Array.new(100) { |i| i.even? ? 1 : 0 })
    b = bool_array(Array.new(100) { |i| (i % 3 == 0) ? 1 : 0 })
    a[10] = UNDEF
    a[50] = UNDEF
    c = a & b
    # Kleene AND: a masked cell resolves to FALSE where b is known-false
    # (unknown & false = false); it stays masked only where b is true.
    expected_masked = [10, 50].select { |i| b[i] }
    mask_a = c.has_mask? ? c.mask.to_a : Array.new(c.elements, 0)
    masked = mask_a.each_with_index.select { |v, _| v }.map(&:last)
    assert_equal(expected_masked.sort, masked.sort, "Kleene AND mask")
    # fully-present cells match plain a & b
    a.elements.times do |i|
      next if a[i] == UNDEF || b[i] == UNDEF
      assert_equal(a[i] & b[i], c[i], "i=#{i}")
    end
    assert_bool_invariant(c, "AND with mask")
  end

  def test_or_with_mask_byte_parity
    a = bool_array(Array.new(100) { |i| i.even? ? 1 : 0 })
    b = bool_array(Array.new(100) { |i| (i % 3 == 0) ? 1 : 0 })
    b[20] = UNDEF
    c = a | b
    assert(c.has_mask?)
    a.elements.times do |i|
      next if c.mask[i]
      assert_equal(a[i] | b[i], c[i], "i=#{i}")
    end
    assert_bool_invariant(c, "OR with mask")
  end

  # ----- non-boolean data_type path: fast path must NOT trigger (different fn) ---

  def test_and_int32_unchanged
    # bit_and on int32 should use the int32 bitwise AND (not the boolean
    # fast path).  The int32 variant supports full bit pattern.
    a = CArray.int32(8).seq
    b = CArray.int32(8) { 0xFF }
    c = a & b
    assert_equal((0..7).to_a.map { |x| x & 0xFF }, c.to_a)
  end

  # ----- result class identity ------------------------------------------

  def test_and_returns_boolean
    a = bool_array([1, 0, 1, 0])
    b = bool_array([1, 1, 0, 0])
    c = a & b
    assert_equal(CA_BOOLEAN, c.data_type)
  end

  def test_or_returns_boolean
    a = bool_array([1, 0, 1, 0])
    b = bool_array([1, 1, 0, 0])
    c = a | b
    assert_equal(CA_BOOLEAN, c.data_type)
  end

  # ----- de Morgan-ish round-trip via M.1 and M.3.1 ---------------------

  def test_and_associative
    n = 100
    a = bool_array((0...n).map { |i| i.even? ? 1 : 0 })
    b = bool_array((0...n).map { |i| (i % 3 == 0) ? 1 : 0 })
    c = bool_array((0...n).map { |i| (i % 5 == 0) ? 1 : 0 })
    lhs = (a & b) & c
    rhs = a & (b & c)
    assert_equal(rhs.to_a, lhs.to_a)
    assert_bool_invariant(lhs, "AND associative")
  end

  def test_or_associative
    n = 100
    a = bool_array((0...n).map { |i| i.even? ? 1 : 0 })
    b = bool_array((0...n).map { |i| (i % 3 == 0) ? 1 : 0 })
    c = bool_array((0...n).map { |i| (i % 5 == 0) ? 1 : 0 })
    lhs = (a | b) | c
    rhs = a | (b | c)
    assert_equal(rhs.to_a, lhs.to_a)
    assert_bool_invariant(lhs, "OR associative")
  end

  # ==========================================================================
  # M.3.2 — bit_xor_i (= `^`) and bit_neg (= `~`) for boolean8_t
  # ==========================================================================

  # ----- bit_xor_i ------------------------------------------------------

  def test_xor_basic
    a = bool_array([0, 0, 1, 1, 0, 0, 1, 1])
    b = bool_array([0, 1, 0, 1, 0, 1, 0, 1])
    c = a ^ b
    assert_equal([false, true, true, false, false, true, true, false], c.to_a)
    assert_bool_invariant(c, "xor basic")
  end

  def test_xor_word_and_tail_sizes_contig
    WORD_AND_TAIL_SIZES.each do |n|
      a = bool_array((0...n).map { |i| i.even? ? 1 : 0 })
      b = bool_array((0...n).map { |i| (i % 3 == 0) ? 1 : 0 })
      expected = a.to_a.zip(b.to_a).map { |x, y| x ^ y }
      c = a ^ b
      assert_equal(expected, c.to_a, "n=#{n}")
      assert_bool_invariant(c, "xor n=#{n}")
    end
  end

  def test_xor_identity_with_zero
    n = 100
    a     = bool_array((0...n).map { |i| i.even? ? 1 : 0 })
    zeros = bool_array(Array.new(n, 0))
    c = a ^ zeros
    assert_equal(a.to_a, c.to_a, "XOR with all-0 must be identity")
  end

  def test_xor_self_is_all_zero
    n = 100
    a = bool_array((0...n).map { |i| i.even? ? 1 : 0 })
    c = a ^ a
    assert_equal(Array.new(n, false), c.to_a, "XOR with self must be all-0")
  end

  def test_xor_non_contig_view_byte_parity
    a = CArray.boolean(8, 10) { |i, j| (i + j) % 2 }
    b = CArray.boolean(8, 10) { |i, j| ((i * 3 + j) % 2) }
    at = a.transpose
    bt = b.transpose
    c = at ^ bt
    expected = (0...10).map { |i|
      (0...8).map { |j|
        (at[i, j] != bt[i, j])
      }
    }
    actual = (0...10).map { |i| (0...8).map { |j| c[i, j] } }
    assert_equal(expected, actual, "transposed XOR byte parity")
    assert_bool_invariant(c, "transposed XOR")
  end

  def test_xor_with_mask_byte_parity
    a = bool_array(Array.new(100) { |i| i.even? ? 1 : 0 })
    b = bool_array(Array.new(100) { |i| (i % 3 == 0) ? 1 : 0 })
    a[15] = UNDEF
    c = a ^ b
    assert(c.has_mask?)
    a.elements.times do |i|
      next if c.mask[i]
      expected = (a[i] != b[i])
      assert_equal(expected, c[i], "i=#{i}")
    end
    assert_bool_invariant(c, "XOR with mask")
  end

  # ----- bit_neg (Ruby `~`) ---------------------------------------------

  def test_neg_basic
    a = bool_array([0, 1, 0, 1, 0, 1, 0, 1])
    c = ~a
    assert_equal([true, false, true, false, true, false, true, false], c.to_a)
    assert_bool_invariant(c, "neg basic")
  end

  def test_neg_word_and_tail_sizes_contig
    WORD_AND_TAIL_SIZES.each do |n|
      a = bool_array((0...n).map { |i| i.even? ? 1 : 0 })
      expected = a.to_a.map { |v| !v }
      c = ~a
      assert_equal(expected, c.to_a, "n=#{n}")
      assert_bool_invariant(c, "neg n=#{n}")
    end
  end

  def test_neg_double_is_identity
    n = 100
    a = bool_array((0...n).map { |i| i.even? ? 1 : 0 })
    c = ~(~a)
    assert_equal(a.to_a, c.to_a, "~~a == a")
    assert_bool_invariant(c, "double neg")
  end

  def test_neg_non_contig_view_byte_parity
    a = CArray.boolean(8, 10) { |i, j| (i + j) % 2 }
    at = a.transpose
    c = ~at
    expected = (0...10).map { |i| (0...8).map { |j| !at[i, j] } }
    actual = (0...10).map { |i| (0...8).map { |j| c[i, j] } }
    assert_equal(expected, actual, "transposed NEG byte parity")
    assert_bool_invariant(c, "transposed NEG")
  end

  def test_neg_with_mask_byte_parity
    a = bool_array(Array.new(100) { |i| i.even? ? 1 : 0 })
    a[25] = UNDEF
    a[75] = UNDEF
    c = ~a
    assert(c.has_mask?)
    masked = c.mask.to_a.each_with_index.select { |v, _| v }.map(&:last)
    assert_equal([25, 75], masked.sort)
    a.elements.times do |i|
      next if c.mask[i]
      assert_equal(!a[i], c[i], "i=#{i}")
    end
    assert_bool_invariant(c, "NEG with mask")
  end

  # ----- non-boolean data_type: bit_neg / bit_xor on int32 unchanged -------

  def test_neg_int32_unchanged
    # ~ on int32 should be bitwise NOT (~v == -v - 1 in two's complement)
    a = CArray.int32(8).seq
    c = ~a
    expected = (0..7).map { |v| ~v }
    assert_equal(expected, c.to_a)
  end

  def test_xor_int32_unchanged
    a = CArray.int32(8).seq
    b = CArray.int32(8) { 0xFF }
    c = a ^ b
    expected = (0..7).map { |v| v ^ 0xFF }
    assert_equal(expected, c.to_a)
  end

  # ----- result class identity ------------------------------------------

  def test_xor_returns_boolean
    c = bool_array([1, 0, 1, 0]) ^ bool_array([1, 1, 0, 0])
    assert_equal(CA_BOOLEAN, c.data_type)
  end

  def test_neg_returns_boolean
    c = ~bool_array([1, 0, 1, 0])
    assert_equal(CA_BOOLEAN, c.data_type)
  end

  # ----- algebraic identities -------------------------------------------

  def test_xor_associative
    n = 100
    a = bool_array((0...n).map { |i| i.even? ? 1 : 0 })
    b = bool_array((0...n).map { |i| (i % 3 == 0) ? 1 : 0 })
    c = bool_array((0...n).map { |i| (i % 5 == 0) ? 1 : 0 })
    lhs = (a ^ b) ^ c
    rhs = a ^ (b ^ c)
    assert_equal(rhs.to_a, lhs.to_a)
    assert_bool_invariant(lhs, "XOR associative")
  end

  def test_de_morgan_and
    # De Morgan: ~(a & b) == (~a) | (~b)
    n = 100
    a = bool_array((0...n).map { |i| i.even? ? 1 : 0 })
    b = bool_array((0...n).map { |i| (i % 3 == 0) ? 1 : 0 })
    lhs = ~(a & b)
    rhs = (~a) | (~b)
    assert_equal(rhs.to_a, lhs.to_a)
  end

  def test_de_morgan_or
    # De Morgan: ~(a | b) == (~a) & (~b)
    n = 100
    a = bool_array((0...n).map { |i| i.even? ? 1 : 0 })
    b = bool_array((0...n).map { |i| (i % 3 == 0) ? 1 : 0 })
    lhs = ~(a | b)
    rhs = (~a) & (~b)
    assert_equal(rhs.to_a, lhs.to_a)
  end
end
