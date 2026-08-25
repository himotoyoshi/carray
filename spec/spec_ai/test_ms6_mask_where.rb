# MS.6: mask_where(...) -- generic predicate mask return form.
#
# PROPOSAL_MASK_SET_FAMILY.md §2.2: mirrors the indexer key set:
#   ca.mask_where(:lt, v)      <-> ca[:lt, v]      = UNDEF
#   ca.mask_where(:gt, v)      <-> ca[:gt, v]      = UNDEF
#   ca.mask_where(:eq, v)      <-> ca[:eq, v]      = UNDEF
#   ca.mask_where(:is_invalid) <-> ca[:is_invalid] = UNDEF
#   ca.mask_where(cond_array)  <-> ca[cond_array]  = UNDEF
#
# All arguments mandatory: at least one argument required.

$LOAD_PATH.unshift File.expand_path("../../../ext", __FILE__)
$LOAD_PATH.unshift File.expand_path("../../../lib", __FILE__)
require "carray"
require "test/unit"

class TestMS6MaskWhere < Test::Unit::TestCase

  def test_returns_new_array
    a = CArray.int32(5).seq
    b = a.mask_where(:lt, 3)
    refute_equal(a.object_id, b.object_id)
  end

  def test_self_unchanged
    a = CArray.int32(5).seq
    a.mask_where(:lt, 3)
    refute(a.has_mask?)
  end

  # ---- Symbol + value predicates ---------------------------------------

  def test_lt_predicate
    a = CArray.int32(8).seq
    b = a.mask_where(:lt, 3)
    assert_equal([true, true, true, false, false, false, false, false], b.is_masked.to_a)
  end

  def test_gt_predicate
    a = CArray.int32(8).seq
    b = a.mask_where(:gt, 5)
    assert_equal([false, false, false, false, false, false, true, true], b.is_masked.to_a)
  end

  def test_eq_predicate
    a = CArray.int32(8).seq.mod(3)
    b = a.mask_where(:eq, 1)
    assert_equal([false, true, false, false, true, false, false, true], b.is_masked.to_a)
  end

  def test_ne_predicate
    a = CArray.int32(5).seq
    b = a.mask_where(:ne, 2)
    assert_equal([true, true, false, true, true], b.is_masked.to_a)
  end

  def test_le_predicate
    a = CArray.int32(6).seq
    b = a.mask_where(:le, 2)
    assert_equal([true, true, true, false, false, false], b.is_masked.to_a)
  end

  def test_ge_predicate
    a = CArray.int32(6).seq
    b = a.mask_where(:ge, 4)
    assert_equal([false, false, false, false, true, true], b.is_masked.to_a)
  end

  # ---- Symbol-only predicates ------------------------------------------

  def test_is_invalid_predicate
    a = CArray.float64(5)
    a[0] = 1.0; a[1] = 0.0 / 0.0
    a[2] = 2.0; a[3] = 1.0 / 0.0
    a[4] = 3.0
    b = a.mask_where(:is_invalid)
    assert_equal([false, true, false, true, false], b.is_masked.to_a)
  end

  # ---- boolean CArray dispatch -----------------------------------------

  def test_boolean_array_dispatch
    a = CArray.int32(8).seq
    cond = a.gt(4).and(a.lt(7))   # true for 5, 6
    b = a.mask_where(cond)
    assert_equal([false, false, false, false, false, true, true, false], b.is_masked.to_a)
  end

  # ---- consistency with indexer idiom ----------------------------------

  def test_consistency_with_indexer
    a = CArray.int32(10).seq
    [:lt, :gt, :le, :ge, :eq, :ne].each do |op|
      [2, 5, 8].each do |v|
        x = a.mask_where(op, v)
        y = a.dup
        y[op, v] = UNDEF
        assert_equal(y.is_masked.to_a, x.is_masked.to_a,
                     "#{op} #{v} mismatch")
      end
    end
  end

  def test_consistency_with_mask_eq
    # mask_where(:eq, v) should match mask_eq(v).
    a = CArray.int32(8).seq.mod(3)
    [0, 1, 2].each do |v|
      assert_equal(a.mask_eq(v).is_masked.to_a,
                   a.mask_where(:eq, v).is_masked.to_a,
                   "v=#{v} mismatch")
    end
  end

  def test_consistency_with_mask_invalid
    # mask_where(:is_invalid) should match mask_invalid.
    a = CArray.float64(6)
    a[0] = 0.0; a[1] = 0.0 / 0.0
    a[2] = 2.0; a[3] = 1.0 / 0.0
    a[4] = -1.0 / 0.0; a[5] = 5.0
    assert_equal(a.mask_invalid.is_masked.to_a,
                 a.mask_where(:is_invalid).is_masked.to_a)
  end

  # ---- arity strict ----------------------------------------------------

  def test_no_arg_raises
    a = CArray.int32(5).seq
    assert_raise(ArgumentError) { a.mask_where }
  end

  # ---- chain ergonomics ------------------------------------------------

  def test_chain_with_count_masked
    a = CArray.int32(8).seq
    assert_equal(3, a.mask_where(:lt, 3).count_masked)
  end

  def test_chain_with_sum
    a = CArray.float64(6).seq    # [0..5]
    # mask values < 2 -> sum of [2,3,4,5] = 14
    assert_equal(14.0, a.mask_where(:lt, 2.0).sum)
  end
end
