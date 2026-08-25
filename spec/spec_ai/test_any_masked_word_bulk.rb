# spec_ai/test_any_masked_word_bulk.rb
#
# M.3.3 — wire M.1 word-level helpers into ca_is_any_masked / ca_is_all_masked
# consumers.  User surface: a.any_masked? / a.all_masked?
#
# Pins:
#   - byte parity with pre-M.3.3 semantics across word + tail sizes,
#     sparse / dense / first-byte / last-byte / middle-byte patterns
#   - mask == NULL path unchanged (= O(1) early return)
#   - all-clean (mask exists but all zero) path correctness (= any? false /
#     all? false)
#   - all-set path correctness (= any? true / all? true)
#   - chained binop / view scenarios via existing has_mask propagation
#
# This is the structural answer to the mask scan O(n) discussion.  F.7
# (mask state O(1) cache) was rejected as infeasible (mask is dynamic +
# view chain can introduce mask mid-chain).  Scan stays O(n) but becomes
# word-level + early-exit.
#
# See devel/PROPOSAL_MASK_SUBSTRATE_BULK_SIMD.md §5 #5, §0 rev2 changelog.

require 'test/unit'
require 'carray'

class TestAnyMaskedWordBulkM33 < Test::Unit::TestCase

  WORD_AND_TAIL_SIZES = [1, 7, 8, 15, 16, 17, 23, 24, 100, 1000, 8193].freeze

  # ----- mask == NULL: short-circuit (O(1)) -----------------------------

  def test_no_mask_any_returns_false
    a = CArray.int32(100).seq
    assert_equal(false, a.any_masked?)
    assert_equal(false, a.has_mask?)  # confirm no mask was created
  end

  def test_no_mask_all_returns_false
    a = CArray.int32(100).seq
    assert_equal(false, a.all_masked?)
  end

  # ----- mask exists but all-clean (= overlay_n created mask, set 0) ---

  def test_mask_all_zero_any_returns_false
    a = CArray.int32(100).seq
    # Create mask by binop with a masked operand, then clear it
    b = CArray.int32(100).seq
    b[0] = UNDEF  # force mask creation
    c = a + b
    assert(c.has_mask?, "c should have mask after binop")
    # Now clear all mask bits
    c.unmask
    # After unmask, has_mask? should reflect... let's check both API forms
    # The mask buffer might still exist with all-0 content.
    assert_equal(false, c.any_masked?, "all-zero mask must not report any masked")
  end

  def test_mask_all_zero_all_returns_false
    a = CArray.int32(100).seq
    b = CArray.int32(100).seq
    b[0] = UNDEF
    c = a + b
    c.unmask
    assert_equal(false, c.all_masked?, "all-zero mask must not report all masked")
  end

  # ----- single-position mask: early exit fires (any) -------------------

  def test_any_first_byte_masked
    a = CArray.int32(1000).seq
    a[0] = UNDEF
    assert_equal(true, a.any_masked?, "first-byte mask must be detected (early exit)")
    assert_equal(false, a.all_masked?)
  end

  def test_any_last_byte_masked
    [1, 7, 8, 15, 16, 17, 100, 1000].each do |n|
      a = CArray.int32(n).seq
      a[n - 1] = UNDEF
      assert_equal(true, a.any_masked?, "n=#{n}, last byte mask must be detected")
    end
  end

  def test_any_middle_word_masked
    a = CArray.int32(1000).seq
    a[500] = UNDEF
    assert_equal(true, a.any_masked?, "middle-word mask must be detected")
  end

  # ----- all-set mask --------------------------------------------------

  def test_all_set_via_mask_setter
    n = 100
    a = CArray.int32(n).seq
    a.mask = 1  # set all positions masked
    assert_equal(true,  a.any_masked?)
    assert_equal(true,  a.all_masked?)
  end

  def test_all_set_via_scalar_masked_binop
    n = 100
    a = CArray.int32(n).seq
    s = CScalar.int32
    s[0] = 0
    s[0] = UNDEF
    c = a + s
    assert_equal(true, c.any_masked?, "masked scalar broadcasts all-set")
    assert_equal(true, c.all_masked?, "scalar masked-broadcast => all_masked")
  end

  # ----- word + tail size sweep -----------------------------------------

  def test_any_word_and_tail_sizes_first
    WORD_AND_TAIL_SIZES.each do |n|
      a = CArray.int32(n).seq
      a[0] = UNDEF
      assert_equal(true, a.any_masked?, "n=#{n}, first=masked")
    end
  end

  def test_any_word_and_tail_sizes_last
    WORD_AND_TAIL_SIZES.each do |n|
      a = CArray.int32(n).seq
      a[n - 1] = UNDEF
      assert_equal(true, a.any_masked?, "n=#{n}, last=masked")
    end
  end

  def test_all_word_and_tail_sizes
    WORD_AND_TAIL_SIZES.each do |n|
      a = CArray.int32(n).seq
      a.mask = 1
      assert_equal(true, a.all_masked?, "n=#{n}, all=masked")
      # invalidate one position: write a literal value to clear mask
      a[n / 2] = 999
      assert_equal(false, a.all_masked?, "n=#{n}, one cleared")
    end
  end

  # ----- sparse / dense scan correctness --------------------------------

  def test_sparse_mask_scan
    n = 1000
    a = CArray.int32(n).seq
    (0...n).step(7) { |i| a[i] = UNDEF }
    assert_equal(true,  a.any_masked?, "sparse: any present")
    assert_equal(false, a.all_masked?, "sparse: not all")
  end

  def test_dense_mask_scan
    n = 1000
    a = CArray.int32(n).seq
    (0...n).each { |i| a[i] = UNDEF }
    assert_equal(true, a.any_masked?)
    assert_equal(true, a.all_masked?)
  end

  # ----- consistency with count_masked ---------------------------------

  def test_any_equiv_count_masked_gt_zero
    [10, 100, 1000].each do |n|
      a = CArray.int32(n).seq
      # all-zero mask via binop
      b = CArray.int32(n).seq
      b[0] = UNDEF
      c = a + b
      c.unmask  # clear
      assert_equal(c.count_masked > 0, c.any_masked?, "n=#{n}, after unmask")

      c2 = a + b  # re-create with mask
      assert_equal(c2.count_masked > 0, c2.any_masked?, "n=#{n}, with mask")
    end
  end

  def test_all_equiv_count_masked_equals_elements
    [10, 100, 1000].each do |n|
      a = CArray.int32(n).seq
      a.mask = 1
      assert_equal(a.count_masked == a.elements, a.all_masked?, "n=#{n}, all set")

      a[0] = 999  # clear mask at 0
      assert_equal(a.count_masked == a.elements, a.all_masked?, "n=#{n}, one cleared")
    end
  end
end
