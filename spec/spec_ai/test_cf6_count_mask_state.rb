# CF.4 + CF.6: count(UNDEF) forwards to count_masked; count_masked /
# count_not_masked retain their existing implementations (per-axis
# functional, accumulate-chain backed).
#
# PROPOSAL_COUNT_FAMILY.md rev3 sparring round 1 Q1: count(UNDEF) is
# treated as mask-state vocabulary -- count_masked synonym.  This pins:
#   - Q1 functional: count(UNDEF) returns count_masked result
#   - count_masked / count_not_masked retain pre-existing per-axis paths
#   - cross-TU linkage: rb_ca_count (carray_stat.c) calls
#     rb_ca_count_masked (carray_mask.c) directly via public linkage

$LOAD_PATH.unshift File.expand_path("../../../ext", __FILE__)
$LOAD_PATH.unshift File.expand_path("../../../lib", __FILE__)
require "carray"
require "test/unit"

class TestCF6CountMaskState < Test::Unit::TestCase

  def test_count_undef_equals_count_masked
    a = CArray.int32(10).seq
    a[3] = UNDEF
    a[7] = UNDEF
    assert_equal(2, a.count(UNDEF))
    assert_equal(a.count_masked, a.count(UNDEF))
  end

  def test_count_undef_no_mask
    a = CArray.int32(10).seq
    assert_equal(0, a.count(UNDEF))
    assert_equal(0, a.count_masked)
  end

  def test_count_undef_per_axis
    b = CArray.int32(3, 4).seq
    b[0, 0] = UNDEF
    b[1, 2] = UNDEF
    r0 = b.count(UNDEF, axis: 0)
    r1 = b.count(UNDEF, axis: 1)
    assert_kind_of(CArray, r0)
    assert_kind_of(CArray, r1)
    assert_equal([4], r0.shape)
    assert_equal([3], r1.shape)
    # Cross-check with count_masked directly
    assert_equal(b.count_masked(axis: 0).to_a, r0.to_a)
    assert_equal(b.count_masked(axis: 1).to_a, r1.to_a)
  end

  def test_count_not_masked_basic
    a = CArray.int32(10).seq
    a[3] = UNDEF
    a[5] = UNDEF
    assert_equal(8, a.count_not_masked)
  end

  def test_count_not_masked_no_mask
    a = CArray.int32(10).seq
    assert_equal(10, a.count_not_masked)
  end

  def test_count_not_masked_per_axis
    b = CArray.int32(3, 4).seq
    b[0, 0] = UNDEF
    b[1, 2] = UNDEF
    r0 = b.count_not_masked(axis: 0)
    r1 = b.count_not_masked(axis: 1)
    assert_equal([4], r0.shape)
    assert_equal([3], r1.shape)
    # column sums: col 0 has 1 masked, col 2 has 1 masked
    assert_equal([2, 3, 2, 3], r0.to_a)
    # row sums: row 0 has 1 masked, row 1 has 1 masked
    assert_equal([3, 3, 4], r1.to_a)
  end

  def test_per_axis_output_data_type_int64
    # count_masked / count_not_masked reduce the boolean mask through the
    # count_true_ki / count_false_ki kernels, which output i64 (a count is
    # bounded by elements, which can exceed INT32_MAX).  Matches the scalar
    # form's int64-width SIZE2NUM.
    b = CArray.int32(3, 4).seq
    b[0, 0] = UNDEF
    assert_equal(CA_INT64, b.count_masked(axis: 0).data_type)
    assert_equal(CA_INT64, b.count_not_masked(axis: 1).data_type)
    # no-mask branch (ca_make_reduced_int64) is int64 too
    c = CArray.int32(3, 4).seq
    assert_equal(CA_INT64, c.count_masked(axis: 0).data_type)
    assert_equal(CA_INT64, c.count_not_masked(axis: 1).data_type)
  end

  def test_count_masked_plus_not_masked_equals_total
    b = CArray.int32(5, 6).seq
    b[0, 0] = UNDEF
    b[2, 3] = UNDEF
    b[4, 5] = UNDEF
    # Flatten
    assert_equal(b.elements, b.count_masked + b.count_not_masked)
    # Per-axis
    [0, 1].each do |ax|
      m  = b.count_masked(axis: ax).to_a
      nm = b.count_not_masked(axis: ax).to_a
      m.each_with_index do |mv, i|
        assert_equal(b.shape[ax], mv + nm[i],
                     "axis #{ax} slice #{i}: masked + not_masked != dim")
      end
    end
  end

  def test_count_undef_with_no_axis_arg
    # count(UNDEF) with no further args = flatten count_masked
    a = CArray.int32(8).seq
    a[1] = UNDEF
    a[5] = UNDEF
    a[7] = UNDEF
    assert_kind_of(Integer, a.count(UNDEF))
    assert_equal(3, a.count(UNDEF))
  end

  def test_q3_strict_still_applies
    # UNDEF dispatch is independent of Q3 strict checks (Q3 only fires
    # on numeric self with bool v, or bool self with non-bool v).
    a = CArray.int32(5).seq
    # count(UNDEF) on numeric -> count_masked (not TypeError)
    assert_nothing_raised { a.count(UNDEF) }
    b = CArray.int32(5).seq.ne(0)
    # count(UNDEF) on bool -> still count_masked (mask state vocabulary
    # is data_type-independent)
    assert_nothing_raised { b.count(UNDEF) }
  end
end
