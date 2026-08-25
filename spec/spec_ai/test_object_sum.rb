require_relative "../../lib/carray"
require "test/unit"

# PROPOSAL_MKKERNEL_OBJECT_DTYPE_BRANCH Phase 1: CA_OBJECT.sum via
# mkkernel per-dtype branch (Hash form init: / reduce: / output: with
# :object family).  Covers 9 cases sized in proposal §1 POC.

class TestObjectSum < Test::Unit::TestCase
  def test_basic
    a = CA_OBJECT([1, 2, 3, 4, 5])
    assert_equal(15, a.sum)
  end

  def test_with_mask
    a = CA_OBJECT([1, 2, 3, 4, 5])
    a[2] = UNDEF
    assert_equal(12, a.sum)
  end

  def test_axis
    b = CA_OBJECT([[1,2,3,4,5],[6,7,8,9,10],[11,12,13,14,15]])
    r = b.sum(axis: 1)
    assert_equal([15, 40, 65], r.to_a)
  end

  def test_axis_with_mask
    b = CA_OBJECT([[1,2,3,4,5],[6,7,8,9,10],[11,12,13,14,15]])
    b[1, 2] = UNDEF
    r = b.sum(axis: 1)
    assert_equal([15, 32, 65], r.to_a)
    assert_equal(false, r.has_mask?)
  end

  def test_all_masked_slab_identity_default
    # ERI.0: under the default min_count, an all-masked slab is the sum
    # over the empty set of unmasked cells = the additive identity (0),
    # NOT UNDEF.  (skipna semantics: masked cells are excluded, and the
    # sum of no cells is 0.)  UNDEF is opt-in via min_count: 1.
    b = CA_OBJECT([[1,2,3,4,5],[6,7,8,9,10]])
    b[0, nil] = UNDEF
    r = b.sum(axis: 1)
    assert_equal(false, r.has_mask?)
    assert_equal(0, r[0])
    assert_equal(40, r[1])
  end

  def test_fill_value
    # ERI.0: an all-masked slab is now identity 0 (not UNDEF) under the
    # default min_count, so fill_value has no UNDEF to fill there.  To get
    # a genuinely-UNDEF slab that fill_value replaces, require valid cells
    # via min_count: 1 (0 valid < 1 -> UNDEF -> filled).
    b = CA_OBJECT([[1,2,3,4,5],[6,7,8,9,10]])
    b[0, nil] = UNDEF
    r = b.sum(axis: 1, min_count: 1, fill_value: -1)
    assert_equal([-1, 40], r.to_a)
  end

  def test_min_count_gate_flat
    a = CA_OBJECT([1, 2, 3])
    a[0] = UNDEF
    a[1] = UNDEF
    r = a.sum(min_count: 2)
    assert(r.nil? || r == UNDEF || (r.respond_to?(:masked?) && r.masked?),
           "expected UNDEF-equivalent for 1 valid < 2 required, got #{r.inspect}")
  end

  def test_view_block
    e = CA_OBJECT([[1,2,3,4],[5,6,7,8]])
    assert_equal(10, e[0, nil].sum)
  end

  def test_mixed_numeric
    c = CA_OBJECT([1, 2.5, Rational(3, 2)])
    assert_equal(5.0, c.sum)
  end
end
