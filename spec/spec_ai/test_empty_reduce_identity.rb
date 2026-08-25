require "carray"
require "test/unit"

# ERI.0-2: empty / all-masked reduction returns the reduction identity for
# identity-bearing kernels, instead of UNDEF.  Covered kernels:
#   sum -> 0, prod -> 1, accumulate -> 0, wsum -> 0.0, count(v) -> 0.
#
# Contract (devel/PROPOSAL_EMPTY_REDUCE_IDENTITY.md):
#   - default min_count: zero-contribution slab (empty OR all-masked) -> identity
#   - min_count: K (K > 0) opt-in: < K valid cells -> UNDEF
#   - partial-mask / normal reductions unchanged (skipna)
#   - non-identity kernels (min/max/mean/variance/...) keep UNDEF on empty
class TestEmptyReduceIdentity < Test::Unit::TestCase
  def test_empty_sum_is_zero
    assert_equal(0.0, CA_FLOAT64([]).sum)
    assert_equal(0.0, CA_INT32([]).sum)
    assert_equal(0,   CA_OBJECT([]).sum)
  end

  def test_all_masked_sum_is_zero
    a = CA_FLOAT64([1, 2, 3]); a[] = UNDEF
    assert_equal(0.0, a.sum)
    assert_equal(false, CScalar === a.sum && a.sum == UNDEF)
  end

  def test_empty_and_all_masked_agree
    # skipna: both are "sum over the empty set of unmasked cells".
    a = CA_FLOAT64([1, 2, 3]); a[] = UNDEF
    assert_equal(CA_FLOAT64([]).sum, a.sum)
  end

  def test_min_count_opt_in_still_undef
    assert_equal(UNDEF, CA_FLOAT64([]).sum(min_count: 1))
    a = CA_FLOAT64([1, 2, 3]); a[] = UNDEF
    assert_equal(UNDEF, a.sum(min_count: 1))
  end

  def test_partial_and_normal_unchanged
    assert_equal(6.0, CA_FLOAT64([1, 2, 3]).sum)
    assert_equal(4.0, CA_FLOAT64([1, UNDEF, 3]).sum)
  end

  def test_axis_reduce_mixed_slab_identity_is_unmasked
    m = CArray.float64(3, 2) { |i, j| i * 2.0 + j }  # [[0,1],[2,3],[4,5]]
    m[1, nil] = UNDEF                                 # middle row all-masked
    r = m.sum(axis: 1)
    assert_equal([1.0, 0.0, 9.0], r.to_a)             # masked row -> identity 0
    assert_equal(false, r.has_mask?)                  # identity cell is NOT masked
  end

  def test_axis_reduce_mixed_slab_min_count_opt_in
    m = CArray.float64(3, 2) { |i, j| i * 2.0 + j }
    m[1, nil] = UNDEF
    r = m.sum(axis: 1, min_count: 1)
    assert_equal(true, r.has_mask?)
    assert_not_equal(0, r.mask[1])                    # masked row -> UNDEF (opt-in)
    assert_equal(1.0, r[0]); assert_equal(9.0, r[2])
  end

  def test_prod_identity_is_one
    assert_equal(1.0, CA_FLOAT64([]).prod)
    a = CA_FLOAT64([2, 3]); a[] = UNDEF
    assert_equal(1.0, a.prod)
    assert_equal(UNDEF, CA_FLOAT64([]).prod(min_count: 1))
    assert_equal(6.0, CA_FLOAT64([2, 3]).prod)          # unchanged
  end

  def test_accumulate_identity_preserves_dtype
    # accumulate keeps input dtype (output: :preserve); identity is 0.
    assert_equal(0, CA_INT32([]).accumulate)
    a = CA_INT32([1, 2, 3]); a[] = UNDEF
    assert_equal(0, a.accumulate)
  end

  def test_wsum_identity_is_zero
    assert_equal(0.0, CA_FLOAT64([]).wsum(CA_FLOAT64([])))
    a = CA_FLOAT64([2, 3, 4]); a[] = UNDEF
    assert_equal(0.0, a.wsum(CA_FLOAT64([1, 1, 1])))
  end

  def test_count_value_identity_and_family_consistency
    # count(v) over empty / all-masked = 0 matches (identity), matching
    # count_masked / count_not_masked (which already returned 0).
    assert_equal(0, CA_FLOAT64([]).count(1.0))
    a = CA_FLOAT64([1, 2, 3]); a[] = UNDEF
    assert_equal(0, a.count(1.0))
    assert_equal(0, CA_FLOAT64([]).count_masked)
    assert_equal(0, CA_FLOAT64([]).count_not_masked)
    assert_equal(UNDEF, CA_FLOAT64([]).count(1.0, min_count: 1))   # opt-in
    assert_equal(2, CA_FLOAT64([1, 2, 2, 3]).count(2.0))           # unchanged
  end

  def test_count_bool_identity_and_min_count
    # count(true) / count(false) on bool storage go through the count_true /
    # count_false kernels; empty / all-masked = 0 (identity), matching count(v).
    b = CArray.boolean(3).fill(true); b[] = UNDEF
    assert_equal(0, b.count(true))
    assert_equal(0, b.count(false))
    assert_equal(0, CArray.boolean(0).count(true))
    assert_equal(UNDEF, b.count(true, min_count: 1))                # opt-in still UNDEF
    # per-axis: an all-masked slab -> 0 (unmasked), a present slab -> its count
    m = CArray.boolean(2, 3).fill(true); m[0, nil] = UNDEF
    r = m.count(true, axis: 1)
    assert_equal([0, 3], r.to_a)
    assert_equal(false, r.has_mask?)
    assert_equal(2, (CA_INT([1, 0, 1]) > 0).count(true))           # unchanged
  end

  def test_non_identity_kernels_keep_undef_on_empty
    # min/max have no identity; mean/variance/stddev/wmean are 0/0 -> undefined.
    e = CA_FLOAT64([])
    assert_equal(UNDEF, e.min)
    assert_equal(UNDEF, e.max)
    assert_equal(UNDEF, e.mean)
    assert_equal(UNDEF, e.variance)
    assert_equal(UNDEF, e.stddev)
    assert_equal(UNDEF, e.wmean(CA_FLOAT64([])))
  end
end
