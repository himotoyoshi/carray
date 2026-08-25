# MS.4: mask_eq(v) -- return-form sugar for masking equal-to-v cells.
#
# PROPOSAL_MASK_SET_FAMILY.md §2.2: most-frequent use-case shortcut
# replacing maskout(v).  Arity 1 strict ("all arguments mandatory").
#
# Equivalent to ca.dup.tap { |c| c[:eq, v] = UNDEF }, but written as
# one short chain-friendly method.

$LOAD_PATH.unshift File.expand_path("../../../ext", __FILE__)
$LOAD_PATH.unshift File.expand_path("../../../lib", __FILE__)
require "carray"
require "test/unit"

class TestMS4MaskEq < Test::Unit::TestCase

  def test_returns_new_array
    a = CArray.int32(5).seq
    b = a.mask_eq(2)
    refute_equal(a.object_id, b.object_id)
  end

  def test_self_unchanged
    a = CArray.int32(5).seq
    a.mask_eq(2)
    refute(a.has_mask?, "self should not gain mask")
  end

  def test_value_mask_basic
    a = CArray.int32(8).seq.mod(3)   # [0,1,2,0,1,2,0,1]
    b = a.mask_eq(1)
    # 1 occurs at indices 1, 4, 7
    assert_equal([false, true, false, false, true, false, false, true], b.is_masked.to_a)
  end

  def test_value_mask_no_match
    a = CArray.int32(5).seq
    b = a.mask_eq(99)
    refute(b.has_mask?, "no matching cell -> output without mask")
  end

  def test_consistency_with_indexer_idiom
    # mask_eq(v) should be equivalent to ca.dup with [:eq, v] = UNDEF.
    a = CArray.int32(20).seq.mod(4)
    [0, 1, 2, 3].each do |v|
      x = a.mask_eq(v)
      y = a.dup
      y[:eq, v] = UNDEF
      assert_equal(y.is_masked.to_a, x.is_masked.to_a, "v=#{v} mismatch")
      assert_equal(y.to_a, x.to_a)
    end
  end

  def test_data_type_preserved
    [:int8, :int16, :int32, :int64,
     :uint8, :uint16, :uint32, :uint64,
     :float32, :float64].each do |t|
      a = CArray.send(t, 5).seq
      b = a.mask_eq(2)
      assert_equal(a.data_type, b.data_type, "data_type #{t} preservation")
    end
  end

  def test_shape_preserved
    a = CArray.int32(3, 4).seq
    b = a.mask_eq(5)
    assert_equal(a.shape, b.shape)
  end

  def test_preserves_existing_mask
    # Pre-existing masked cells should remain masked.
    a = CArray.int32(5).seq
    a[0] = UNDEF
    b = a.mask_eq(2)
    assert_equal(true, b.is_masked[0], "pre-existing mask retained")
    assert_equal(true, b.is_masked[2], "matching cell newly masked")
  end

  # ---- arity strict ----------------------------------------------------

  def test_no_arg_raises
    a = CArray.int32(3).seq
    assert_raise(ArgumentError) { a.mask_eq }
  end

  def test_two_args_raises
    a = CArray.int32(3).seq
    assert_raise(ArgumentError) { a.mask_eq(1, 2) }
  end

  # ---- chain ergonomics ------------------------------------------------

  def test_chain_with_count_masked
    a = CArray.int32(8).seq.mod(3)
    assert_equal(3, a.mask_eq(1).count_masked)
  end

  def test_chain_with_sum
    a = CArray.float64(6).seq    # [0,1,2,3,4,5] sum=15
    # Mask the 3, sum of remaining = 0+1+2+4+5 = 12
    assert_equal(12.0, a.mask_eq(3.0).sum)
  end
end
