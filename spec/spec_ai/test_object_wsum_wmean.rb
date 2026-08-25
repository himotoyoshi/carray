require_relative "../../lib/carray"
require "test/unit"

# PROPOSAL_MKKERNEL_OBJECT_DTYPE_BRANCH §4b (b): CA_OBJECT wsum / wmean.
#
# Design (2026-07-13): CA_OBJECT is handled by the mkkernel object_escape:
# hook, not a dedicated :object kernel branch.  The generated dispatcher
# (carray_kernels.c rb_ca_wsum_ki / rb_ca_wmean_ki) intercepts CA_OBJECT
# source and forwards to CArray#__wsum_object__ / #__wmean_object__ in
# runtime.rb, which compose:
#   wsum(w)  = (self * w).sum
#   wmean(w) = Σ(self*w) / Σ(w over cells valid after mask overlay)
# Rationale: object weighted reduction is exact for Rational / BigDecimal
# weights via the Ruby numeric tower, and a masked value OR weight drops the
# cell from both sums (mask overlay), matching the numeric kernels.
#
# Weight forms: Ruby Numeric scalar (W-A1) or same-shape CArray (W-A3).  The
# 1-D axis-broadcast form (W-A2) is not offered for object weights (CArray's
# explicit-broadcast rule: pass a scalar or a full-shape weight).
class TestObjectWsumWmean < Test::Unit::TestCase

  # ---- flat, no mask: parity with numeric ----------------------------

  def test_wsum_flat_matches_numeric
    af = CArray.float64(6) { |i| i + 1.0 }
    wf = CArray.float64(6) { |i| (i % 3) + 1.0 }
    ao = CA_OBJECT(af.to_a)
    wo = CA_OBJECT(wf.to_a)
    assert_in_delta(af.wsum(wf), ao.wsum(wo), 1e-12)
  end

  def test_wmean_flat_matches_numeric
    af = CArray.float64(6) { |i| i + 1.0 }
    wf = CArray.float64(6) { |i| (i % 3) + 1.0 }
    assert_in_delta(af.wmean(wf), CA_OBJECT(af.to_a).wmean(CA_OBJECT(wf.to_a)), 1e-12)
  end

  # ---- mask overlay: masked value or masked weight drops the cell ----

  def test_wsum_masked_value
    af = CArray.float64(6) { |i| i + 1.0 };  af[2] = UNDEF
    wf = CArray.float64(6) { |i| (i % 3) + 1.0 }
    ao = CA_OBJECT([1.0, 2.0, nil, 4.0, 5.0, 6.0]); ao[2] = UNDEF
    assert_in_delta(af.wsum(wf), ao.wsum(CA_OBJECT(wf.to_a)), 1e-12)
  end

  def test_wsum_masked_weight
    af = CArray.float64(6) { |i| i + 1.0 }
    wf = CArray.float64(6) { |i| (i % 3) + 1.0 }; wf[1] = UNDEF
    wo = CA_OBJECT(wf.to_a); wo[1] = UNDEF
    assert_in_delta(af.wsum(wf), CA_OBJECT(af.to_a).wsum(wo), 1e-12)
  end

  def test_wmean_masked_value_and_weight
    af = CArray.float64(6) { |i| i + 1.0 };  af[2] = UNDEF
    wf = CArray.float64(6) { |i| (i % 3) + 1.0 }; wf[4] = UNDEF
    ao = CA_OBJECT(af.to_a); ao[2] = UNDEF
    wo = CA_OBJECT(wf.to_a); wo[4] = UNDEF
    assert_in_delta(af.wmean(wf), ao.wmean(wo), 1e-12)
  end

  # ---- per-axis ------------------------------------------------------

  def test_wsum_per_axis
    am = CArray.float64(3, 4) { |i, j| i * 4 + j + 1.0 }
    wm = CArray.float64(3, 4) { |i, j| (i + j) % 3 + 1.0 }
    ref = am.wsum(wm, axis: 0).to_a
    got = CA_OBJECT(am.to_a).wsum(CA_OBJECT(wm.to_a), axis: 0).to_a
    ref.zip(got).each { |a, b| assert_in_delta(a, b, 1e-12) }
  end

  def test_wmean_per_axis_with_masked_cell
    am = CArray.float64(3, 4) { |i, j| i * 4 + j + 1.0 }; am[1, 2] = UNDEF
    wm = CArray.float64(3, 4) { |i, j| (i + j) % 3 + 1.0 }
    ref = am.wmean(wm, axis: 1).to_a
    got = CA_OBJECT(am.to_a).wmean(CA_OBJECT(wm.to_a), axis: 1).to_a
    ref.zip(got).each { |a, b| assert_in_delta(a, b, 1e-12) }
  end

  # ---- empty / all-masked -> UNDEF (denominator guard) ---------------

  def test_wmean_all_masked_is_undef
    zo = CA_OBJECT([1.0, 2.0, 3.0]); zo[] = UNDEF
    assert_equal(UNDEF, zo.wmean(CA_OBJECT([1.0, 1.0, 1.0])))
  end

  def test_wmean_per_axis_empty_slab_is_undef
    am = CArray.float64(2, 3) { |i, j| i * 3 + j + 1.0 }; am[1, nil] = UNDEF
    wm = CArray.float64(2, 3) { 1.0 }
    got = CA_OBJECT(am.to_a).wmean(CA_OBJECT(wm.to_a), axis: 1)
    assert_not_equal(0, got[0])          # row 0 well-defined
    assert_equal(UNDEF, got[1])          # row 1 all masked -> UNDEF
  end

  def test_wsum_empty_is_identity_zero
    # wsum has an additive identity: all-masked flat -> 0 (not UNDEF).
    zo = CA_OBJECT([1, 2, 3]); zo[] = UNDEF
    assert_equal(0, zo.wsum(CA_OBJECT([1, 1, 1])))
  end

  # ---- min_count / fill_value forward to the composition -------------

  def test_wsum_min_count
    ao = CA_OBJECT([1.0, 2.0, nil, 4.0, 5.0, 6.0]); ao[2] = UNDEF
    wo = CA_OBJECT([1, 1, 1, 1, 1, 1])
    assert_equal(UNDEF, ao.wsum(wo, min_count: 6))    # only 5 valid
    assert_not_equal(UNDEF, ao.wsum(wo, min_count: 5))
  end

  def test_wsum_fill_value
    ao = CA_OBJECT([1.0, 2.0, nil, 4.0, 5.0, 6.0]); ao[2] = UNDEF
    wo = CA_OBJECT([1, 1, 1, 1, 1, 1])
    assert_equal(-1.0, ao.wsum(wo, min_count: 6, fill_value: -1.0))
  end

  # ---- scalar weight (W-A1) ------------------------------------------

  def test_scalar_weight
    ao = CA_OBJECT([1.0, 2.0, 3.0, 4.0])
    assert_in_delta(20.0, ao.wsum(2), 1e-12)          # 2*(1+2+3+4)
    assert_in_delta(2.5,  ao.wmean(2), 1e-12)         # plain mean
  end

  # ---- exactness through the Ruby numeric tower ----------------------

  def test_rational_weight_exact
    a = CA_OBJECT([1, 2, 3])
    w = CA_OBJECT([Rational(1, 3), Rational(1, 3), Rational(1, 3)])
    r = a.wsum(w)
    assert_equal(Rational(6, 3), r)
    assert_kind_of(Rational, r)
  end

  def test_wmean_integer_exact
    a = CA_OBJECT([1, 2, 3])
    w = CA_OBJECT([1, 1, 1])
    assert_equal(2, a.wmean(w))
  end
end
