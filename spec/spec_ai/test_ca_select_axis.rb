# frozen_string_literal: true
#
# spec_ai/test_ca_select_axis.rb
#
# Formal test suite for CASelectAxis (Phase 1, 2026-05-22).
#
# Scope (per PROPOSAL_CASELECT_AXIS.md + handoff):
#   - dispatch eligibility (mask at axis 0, all AP step == 1, argc == ndim)
#   - 2-D and 3-D parent with mask + AP (nil / Integer / Range)
#   - round-trip write-back through the view
#   - mask propagation (parent mask -> view mask, view write -> parent mask)
#   - masked selector reject (ArgumentError)
#   - selector length / range bounds validation
#   - edge cases: empty mask (all false), all-true, size-1 axes
#   - CAGrid fallback for non-eligible patterns (mask not at axis 0, etc.)
#   - numerical cross-check vs CAGrid path via `_csa_bypass`
#   - benchmark bypass flag works
#
# Phase 1 implementation: ext/ca_obj_select_axis.c

require "test/unit"
require_relative "../../lib/carray"

class TestCASelectAxis < Test::Unit::TestCase

  def teardown
    CArray._csa_bypass = false
  end

  # ---------------------------------------------------------------
  # Dispatch routing
  # ---------------------------------------------------------------

  def test_dispatch_2d_mask_with_nil
    a = CArray.int(4, 3).seq
    m = CArray.boolean(4).tap { |__a| __a[] = [1, 0, 1, 1] }
    v = a[m, nil]
    assert_equal CASelectAxis, v.class
    assert_equal [3, 3], v.dim.to_a
    assert_equal [[0, 1, 2], [6, 7, 8], [9, 10, 11]], v.to_a
  end

  def test_dispatch_2d_mask_with_range
    a = CArray.int(4, 3).seq
    m = CArray.boolean(4).tap { |__a| __a[] = [1, 0, 1, 1] }
    v = a[m, 0..1]
    assert_equal CASelectAxis, v.class
    assert_equal [3, 2], v.dim.to_a
    assert_equal [[0, 1], [6, 7], [9, 10]], v.to_a
  end

  def test_dispatch_2d_mask_with_negative_range
    a = CArray.int(4, 3).seq
    m = CArray.boolean(4).tap { |__a| __a[] = [1, 0, 1, 1] }
    v = a[m, -2..-1]
    assert_equal CASelectAxis, v.class
    assert_equal [[1, 2], [7, 8], [10, 11]], v.to_a
  end

  def test_dispatch_2d_mask_with_scalar
    a = CArray.int(4, 3).seq
    m = CArray.boolean(4).tap { |__a| __a[] = [1, 0, 1, 1] }
    v = a[m, 1]
    assert_equal CASelectAxis, v.class
    assert_equal [3, 1], v.dim.to_a
    assert_equal [[1], [7], [10]], v.to_a
  end

  def test_dispatch_2d_mask_with_negative_scalar
    a = CArray.int(4, 3).seq
    m = CArray.boolean(4).tap { |__a| __a[] = [1, 0, 1, 1] }
    v = a[m, -1]
    assert_equal CASelectAxis, v.class
    assert_equal [[2], [8], [11]], v.to_a
  end

  def test_dispatch_3d_mask_outer
    a = CArray.int(3, 2, 2).seq
    m = CArray.boolean(3).tap { |__a| __a[] = [1, 0, 1] }
    v = a[m, nil, nil]
    assert_equal CASelectAxis, v.class
    assert_equal [2, 2, 2], v.dim.to_a
    assert_equal [[[0, 1], [2, 3]], [[8, 9], [10, 11]]], v.to_a
  end

  def test_dispatch_3d_mask_outer_with_mixed_ap
    a = CArray.int(3, 4, 2).seq
    m = CArray.boolean(3).tap { |__a| __a[] = [1, 0, 1] }
    v = a[m, 1..2, 0]
    assert_equal CASelectAxis, v.class
    assert_equal [2, 2, 1], v.dim.to_a
    expected = [
      [[2], [4]],     # row 0: a[0,1,0]=2, a[0,2,0]=4
      [[18], [20]],   # row 2: a[2,1,0]=18, a[2,2,0]=20
    ]
    assert_equal expected, v.to_a
  end

  # ---------------------------------------------------------------
  # CAGrid fallback (non-eligible patterns)
  # ---------------------------------------------------------------

  def test_fallback_mask_not_at_axis_zero
    # Pattern B (interleaved AP/INDIRECT): CSA defers to CAGrid in Phase 1.
    a = CArray.int(4, 3).seq
    m = CArray.boolean(3).tap { |__a| __a[] = [1, 0, 1] }
    v = a[nil, m]
    assert_equal CAGrid, v.class
    assert_equal [[0, 2], [3, 5], [6, 8], [9, 11]], v.to_a
  end

  def test_fallback_1d_uses_caselect
    # argc == 1 with a single boolean parent path goes through CASelect,
    # not CASelectAxis (CSA requires argc == ndim for parent.ndim >= 1
    # but the 1-D boolean indexer hits CASelect first by design).
    a = CArray.int(6).seq
    m = CArray.boolean(6).tap { |__a| __a[] = [0, 1, 1, 0, 1, 0] }
    v = a[m]
    assert_equal CASelect, v.class
    assert_equal [1, 2, 4], v.to_a
  end

  # ---------------------------------------------------------------
  # Bypass flag — production-grade switch used by benches/regression
  # ---------------------------------------------------------------

  def test_csa_bypass_routes_to_cagrid
    a = CArray.int(4, 3).seq
    m = CArray.boolean(4).tap { |__a| __a[] = [1, 0, 1, 1] }
    CArray._csa_bypass = true
    assert_equal CAGrid, a[m, nil].class
  ensure
    CArray._csa_bypass = false
  end

  def test_csa_bypass_predicate
    CArray._csa_bypass = false
    assert_equal false, CArray._csa_bypass?
    CArray._csa_bypass = true
    assert_equal true, CArray._csa_bypass?
  ensure
    CArray._csa_bypass = false
  end

  # ---------------------------------------------------------------
  # Numerical cross-check vs CAGrid (the only authority pre-CSA)
  # ---------------------------------------------------------------

  def test_numerical_match_with_cagrid_2d
    a = CArray.int(8, 5).seq
    m = CArray.boolean(8).tap { |__a| __a[] = [1, 0, 1, 1, 0, 1, 0, 1] }
    # NOTE: negative-range endpoints (e.g. `1..-1`) intentionally excluded
    # here — CSA normalises -1 to dim-1 (Ruby semantics), while CAGrid
    # treats `1..-1` as a reverse strided range.  The CSA-only test
    # `test_dispatch_2d_mask_with_negative_range` covers CSA's normalisation
    # path on its own; this cross-check stays on cases where both views
    # agree on indexer semantics.
    [
      [m, nil],
      [m, 0..2],
      [m, 2],
    ].each do |spec|
      csa = a[*spec]
      assert_equal CASelectAxis, csa.class
      CArray._csa_bypass = true
      grid = a[*spec]
      CArray._csa_bypass = false
      assert_equal CAGrid, grid.class
      assert_equal grid.to_a, csa.to_a, "mismatch for spec=#{spec.inspect}"
    end
  end

  def test_numerical_match_with_cagrid_3d
    a = CArray.int(4, 3, 2).seq
    m = CArray.boolean(4).tap { |__a| __a[] = [1, 0, 1, 1] }
    csa = a[m, 1..2, nil]
    CArray._csa_bypass = true
    grid = a[m, 1..2, nil]
    CArray._csa_bypass = false
    assert_equal CASelectAxis, csa.class
    assert_equal CAGrid, grid.class
    assert_equal grid.to_a, csa.to_a
  end

  # ---------------------------------------------------------------
  # Write-back (round-trip)
  # ---------------------------------------------------------------

  def test_write_back_scalar_value
    a = CArray.int(4, 3).seq
    m = CArray.boolean(4).tap { |__a| __a[] = [1, 0, 1, 1] }
    b = a.to_ca
    b[m, nil] = -1
    expected = [[-1, -1, -1], [3, 4, 5], [-1, -1, -1], [-1, -1, -1]]
    assert_equal expected, b.to_a
  end

  def test_write_back_into_ap_scalar_axis
    a = CArray.int(4, 3).seq
    m = CArray.boolean(4).tap { |__a| __a[] = [1, 0, 1, 1] }
    b = a.to_ca
    b[m, 1] = -9
    expected = [[0, -9, 2], [3, 4, 5], [6, -9, 8], [9, -9, 11]]
    assert_equal expected, b.to_a
  end

  def test_write_back_into_ap_range
    a = CArray.int(4, 3).seq
    m = CArray.boolean(4).tap { |__a| __a[] = [1, 0, 1, 1] }
    b = a.to_ca
    b[m, 0..1] = -2
    expected = [[-2, -2, 2], [3, 4, 5], [-2, -2, 8], [-2, -2, 11]]
    assert_equal expected, b.to_a
  end

  def test_write_back_with_array_value
    a = CArray.int(4, 3).seq
    m = CArray.boolean(4).tap { |__a| __a[] = [1, 0, 1, 1] }
    b = a.to_ca
    rhs = CArray.int(3, 3).tap { |__a| __a[] = [100, 101, 102, 103, 104, 105, 106, 107, 108] }
    b[m, nil] = rhs
    expected = [
      [100, 101, 102],
      [3, 4, 5],
      [103, 104, 105],
      [106, 107, 108],
    ]
    assert_equal expected, b.to_a
  end

  # ---------------------------------------------------------------
  # Mask propagation
  # ---------------------------------------------------------------

  def test_parent_mask_filters_to_view
    a = CArray.int(4, 3).seq
    pm = a.to_ca
    pm[0, 1] = UNDEF
    pm[2, nil] = UNDEF
    m = CArray.boolean(4).tap { |__a| __a[] = [1, 0, 1, 1] }
    v = pm[m, nil]
    assert_equal CASelectAxis, v.class
    assert v.has_mask?
    assert_equal [[false, true, false], [true, true, true], [false, false, false]], v.mask.to_a
  end

  def test_view_write_undef_propagates_to_parent
    a = CArray.int(4, 3).seq
    b = a.to_ca
    m = CArray.boolean(4).tap { |__a| __a[] = [1, 0, 1, 1] }
    sel = b[m, nil]
    sel[0, 1] = UNDEF
    assert b.has_mask?
    assert_equal [[false, true, false], [false, false, false], [false, false, false], [false, false, false]], b.mask.to_a
  end

  # ---------------------------------------------------------------
  # Validation / error paths
  # ---------------------------------------------------------------

  def test_masked_selector_rejected
    a = CArray.int(4, 3).seq
    mm = CArray.boolean(4).tap { |__a| __a[] = [1, 0, 1, 1] }
    mm[0] = UNDEF
    assert_raise(ArgumentError) { a[mm, nil] }
  end

  def test_selector_length_mismatch_rejected
    a = CArray.int(4, 3).seq
    mw = CArray.boolean(5).fill(1)
    assert_raise(ArgumentError) { a[mw, nil] }
  end

  def test_range_out_of_bounds_rejected
    a = CArray.int(4, 3).seq
    m = CArray.boolean(4).fill(1)
    assert_raise(IndexError) { a[m, 0..99] }
  end

  def test_integer_out_of_bounds_rejected
    a = CArray.int(4, 3).seq
    m = CArray.boolean(4).fill(1)
    assert_raise(IndexError) { a[m, 99] }
  end

  # ---------------------------------------------------------------
  # Edge cases
  # ---------------------------------------------------------------

  def test_empty_mask_all_false
    a = CArray.int(4, 3).seq
    mz = CArray.boolean(4).fill(0)
    v = a[mz, nil]
    assert_equal CASelectAxis, v.class
    assert_equal [0, 3], v.dim.to_a
    assert_equal 0, v.elements
  end

  def test_all_true_mask_full_passthrough
    a = CArray.int(4, 3).seq
    ma = CArray.boolean(4).fill(1)
    v = a[ma, nil]
    assert_equal CASelectAxis, v.class
    assert_equal [4, 3], v.dim.to_a
    assert_equal a.to_a, v.to_a
  end

  def test_size_one_indirect_axis
    a = CArray.int(1, 3).seq
    m = CArray.boolean(1).tap { |__a| __a[] = [1] }
    v = a[m, nil]
    assert_equal CASelectAxis, v.class
    assert_equal [1, 3], v.dim.to_a
    assert_equal [[0, 1, 2]], v.to_a
  end

  def test_size_one_ap_axis
    a = CArray.int(4, 1).seq
    m = CArray.boolean(4).tap { |__a| __a[] = [1, 0, 1, 0] }
    v = a[m, nil]
    assert_equal CASelectAxis, v.class
    assert_equal [2, 1], v.dim.to_a
    assert_equal [[0], [2]], v.to_a
  end

  def test_single_true_selector
    a = CArray.int(4, 3).seq
    m = CArray.boolean(4).tap { |__a| __a[] = [0, 0, 1, 0] }
    v = a[m, nil]
    assert_equal CASelectAxis, v.class
    assert_equal [1, 3], v.dim.to_a
    assert_equal [[6, 7, 8]], v.to_a
  end

  # ---------------------------------------------------------------
  # View algebra: dup / to_ca / clone-like behavior
  # ---------------------------------------------------------------

  def test_dup_preserves_class_and_data
    a = CArray.int(4, 3).seq
    m = CArray.boolean(4).tap { |__a| __a[] = [1, 0, 1, 1] }
    v = a[m, nil]
    d = v.dup
    assert_equal CASelectAxis, d.class
    assert_equal v.to_a, d.to_a
  end

  def test_copy_produces_owning_copy
    a = CArray.int(4, 3).seq
    m = CArray.boolean(4).tap { |__a| __a[] = [1, 0, 1, 1] }
    v = a[m, nil]
    c = v.copy
    assert_equal CArray, c.class
    assert_equal v.to_a, c.to_a
    # Mutating c must not affect parent
    c[0, 0] = 999
    assert_equal 0, a[0, 0]
  end

  def test_selector_copied_at_construction
    # Selector is copied (per PROPOSAL_CASELECT_AXIS.md); mutating the original
    # boolean CArray after building the view must not change the view.
    a = CArray.int(4, 3).seq
    m = CArray.boolean(4).tap { |__a| __a[] = [1, 0, 1, 1] }
    v = a[m, nil]
    snap = v.to_a
    m[1] = 1
    m[0] = 0
    assert_equal snap, v.to_a
  end

  # ---------------------------------------------------------------
  # GC safety smoke
  # ---------------------------------------------------------------

  def test_gc_safety_smoke
    a = CArray.int(20, 4).seq
    100.times do
      m = CArray.boolean(20).tap { |i| i[] = i % 2 }
      _ = a[m, nil].to_a
    end
    GC.start
    # Should not crash; selector copy means views remain valid after
    # the original boolean array goes out of scope.
    assert true
  end

end
