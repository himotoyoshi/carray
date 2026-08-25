# frozen_string_literal: true
#
# spec_ai/test_axis_dispatch.rb
#
# D3 unit tests: per-axis descriptor common attach engine.
#
# See devel/PROPOSAL_AXIS_DESCRIPTOR_FRAMEWORK.md §4 D3 / §5 Phase 2.
#
# Correctness criterion: the byte buffer produced by
# ca_axis_dispatch_attach must be binary-identical to the buffer the
# view's existing attach path produces (= view.to_ca.dump_binary).
#
# This is asserted via the debug Ruby accessor #_dispatch_attach_debug
# defined on both CASelectAxis and CAGrid.
#
# D3 alone is not yet wired into either view's func_attach — that's
# D4.  These tests validate the engine in isolation against the
# baseline behavior the engine must reproduce.

require "test/unit"
require_relative "../../lib/carray"

module DispatchAttachAssertions
  def assert_d3_matches (view, label = nil)
    omit "requires CARRAY_DEV_BUILD" unless CAGrid.method_defined?(:_dispatch_attach_debug)
    expected = view.to_ca.dump_binary
    actual   = view._dispatch_attach_debug
    assert_equal expected.length, actual.length,
                 "#{label} byte length mismatch"
    assert_equal expected, actual,
                 "#{label} byte content mismatch"
  end
end

class TestAxisDispatchCSA < Test::Unit::TestCase
  include DispatchAttachAssertions

  # ---- 2-D ----

  def test_2d_mask_with_nil
    a = CArray.int(4, 3).seq
    m = CArray.boolean(4).tap { |__a| __a[] = [1, 0, 1, 1] }
    assert_d3_matches a[m, nil]
  end

  def test_2d_mask_with_range
    a = CArray.int(4, 3).seq
    m = CArray.boolean(4).tap { |__a| __a[] = [1, 0, 1, 1] }
    assert_d3_matches a[m, 0..1]
  end

  def test_2d_mask_with_scalar
    a = CArray.int(4, 3).seq
    m = CArray.boolean(4).tap { |__a| __a[] = [1, 0, 1, 1] }
    assert_d3_matches a[m, 1]
  end

  def test_2d_negative_range
    a = CArray.int(4, 3).seq
    m = CArray.boolean(4).tap { |__a| __a[] = [1, 0, 1, 1] }
    assert_d3_matches a[m, -2..-1]
  end

  def test_2d_all_true_mask
    a = CArray.int(4, 3).seq
    m = CArray.boolean(4).fill(1)
    assert_d3_matches a[m, nil]
  end

  def test_2d_empty_mask
    a = CArray.int(4, 3).seq
    m = CArray.boolean(4).fill(0)
    assert_d3_matches a[m, nil]
  end

  def test_2d_single_true_mask
    a = CArray.int(4, 3).seq
    m = CArray.boolean(4).tap { |__a| __a[] = [0, 0, 1, 0] }
    assert_d3_matches a[m, nil]
  end

  # ---- 3-D ----

  def test_3d_mask_outer_with_nils
    a = CArray.int(3, 2, 2).seq
    m = CArray.boolean(3).tap { |__a| __a[] = [1, 0, 1] }
    assert_d3_matches a[m, nil, nil]
  end

  def test_3d_mask_with_partial_ap_nested
    # The bug-prone case from CSA Phase 1 — partial AP at axis 1
    # with single-cell AP at axis 2.  D3 must take the general
    # (non-slab) path here.
    a = CArray.int(3, 4, 2).seq
    m = CArray.boolean(3).tap { |__a| __a[] = [1, 0, 1] }
    assert_d3_matches a[m, 1..2, 0]
  end

  def test_3d_mask_with_range_and_nil
    a = CArray.int(4, 3, 2).seq
    m = CArray.boolean(4).tap { |__a| __a[] = [1, 0, 1, 1] }
    assert_d3_matches a[m, 1..2, nil]
  end

  # ---- Floats / larger ----

  def test_2d_float_data_type
    a = CArray.float64(5, 4).seq * 0.25
    m = CArray.boolean(5).tap { |__a| __a[] = [1, 1, 0, 1, 0] }
    assert_d3_matches a[m, nil]
  end

  def test_larger_2d
    a = CArray.int(20, 10).seq
    m = CArray.boolean(20).tap { |i| i[] = i % 3 == 0 }
    assert_d3_matches a[m, 2..7]
  end

end

class TestAxisDispatchCAGrid < Test::Unit::TestCase
  include DispatchAttachAssertions

  # ---- 1-D ----

  def test_1d_integer_grid
    a   = CArray.int(6).tap { |__a| __a[] = [10, 20, 30, 40, 50, 60] }
    idx = CArray.int(3).tap { |__a| __a[] = [5, 2, 0] }
    assert_d3_matches a.grid(idx)
  end

  # NOTE: a.grid(nil) (1-D nil-only) crashes in CAGrid construction
  # itself (ca_is_scalar(NULL) deref in ca_grid_setup line 175).
  # This is a pre-existing CAGrid limitation, not a D3 issue.
  # The all-stride single-memcpy path is exercised by 2-D / 3-D
  # all-nil cases below.

  # ---- 2-D ----

  def test_2d_all_nil
    a = CArray.int(4, 3).seq
    assert_d3_matches a.grid(nil, nil)
  end

  def test_2d_idx_and_nil
    a   = CArray.int(4, 3).seq
    idx = CArray.int(2).tap { |__a| __a[] = [0, 2] }
    assert_d3_matches a.grid(idx, nil)
  end

  def test_2d_nil_and_idx
    a   = CArray.int(4, 3).seq
    idx = CArray.int(2).tap { |__a| __a[] = [1, 2] }
    assert_d3_matches a.grid(nil, idx)
  end

  def test_2d_idx_and_idx
    a   = CArray.int(4, 3).seq
    ri  = CArray.int(2).tap { |__a| __a[] = [0, 2] }
    ci  = CArray.int(2).tap { |__a| __a[] = [1, 2] }
    assert_d3_matches a.grid(ri, ci)
  end

  def test_2d_range_inputs
    # Range becomes INDEX (CAGrid loses STRIDE structure) — D3
    # still must reproduce the existing attach output exactly.
    a = CArray.int(4, 3).seq
    assert_d3_matches a.grid(nil, 0..1)
  end

  def test_2d_boolean_input
    a = CArray.int(4, 3).seq
    m = CArray.boolean(4).tap { |__a| __a[] = [1, 0, 1, 1] }
    assert_d3_matches a.grid(m, nil)
  end

  # ---- 3-D ----

  def test_3d_mixed
    a   = CArray.int(3, 4, 2).seq
    idx = CArray.int(2).tap { |__a| __a[] = [0, 3] }
    assert_d3_matches a.grid(nil, idx, nil)
  end

  def test_3d_all_idx
    a    = CArray.int(3, 4, 2).seq
    r    = CArray.int(2).tap { |__a| __a[] = [0, 2] }
    s    = CArray.int(2).tap { |__a| __a[] = [1, 3] }
    t    = CArray.int(1).tap { |__a| __a[] = [0] }
    assert_d3_matches a.grid(r, s, t)
  end

  # ---- Float / larger ----

  def test_float_data_type
    a   = CArray.float64(5, 4).seq * 0.25
    idx = CArray.int(2).tap { |__a| __a[] = [1, 3] }
    assert_d3_matches a.grid(idx, nil)
  end

  def test_larger_2d
    a   = CArray.int(20, 10).seq
    idx = CArray.int(5).tap { |__a| __a[] = [0, 3, 7, 14, 19] }
    assert_d3_matches a.grid(idx, nil)
  end

end

class TestAxisDispatchCrossEquivalence < Test::Unit::TestCase
  # Same operation expressed two ways — CSA and CAGrid via mask.where —
  # must yield the same bytes through D3 too.

  def test_csa_mask_equals_cagrid_where
    omit "requires CARRAY_DEV_BUILD" unless CAGrid.method_defined?(:_dispatch_attach_debug)
    a = CArray.int(8, 5).seq
    m = CArray.boolean(8).tap { |__a| __a[] = [1, 0, 1, 1, 0, 1, 0, 1] }
    csa_bytes  = a[m, nil]._dispatch_attach_debug
    grid_bytes = a.grid(m.where, nil)._dispatch_attach_debug
    assert_equal csa_bytes, grid_bytes
  end

  def test_csa_mask_range_equals_cagrid_where_range
    omit "requires CARRAY_DEV_BUILD" unless CAGrid.method_defined?(:_dispatch_attach_debug)
    # CSA: STRIDE on axis 1; CAGrid: INDEX on axis 1 (Range collapsed).
    # Different descriptors, same bytes out of D3.
    a = CArray.int(8, 5).seq
    m = CArray.boolean(8).tap { |__a| __a[] = [1, 0, 1, 0, 1, 0, 1, 0] }
    csa_bytes  = a[m, 1..3]._dispatch_attach_debug
    grid_bytes = a.grid(m.where, 1..3)._dispatch_attach_debug
    assert_equal csa_bytes, grid_bytes
  end

end
