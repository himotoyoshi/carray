# frozen_string_literal: true
#
# spec_ai/test_axis_dispatch_scatter.rb
#
# D5 unit tests: per-axis descriptor common scatter engine.
#
# See devel/PROPOSAL_AXIS_DESCRIPTOR_FRAMEWORK.md §4 D5 / §6 R5.
#
# Correctness criterion: writing a buffer back through
# ca_axis_dispatch_scatter must produce the same final parent state as
# the view's existing sync path (CSA: xfer_general scatter; CAGrid:
# ca_grid_sync).  Both invoked via the debug accessor
# #_dispatch_scatter_debug.
#
# Duplicate INDEX semantics (R5): output-row-major iteration order,
# last-write-wins.  Engine does not check uniqueness.

require "test/unit"
require_relative "../../lib/carray"

module DispatchScatterAssertions
  # For a view `v` on parent `p` and a payload `payload`, run scatter
  # via D5 and via the view's existing sync path on independent copies
  # of `p`, then assert the two resulting parent states are equal.
  def assert_scatter_matches (parent_template, view_builder, payload)
    omit "requires CARRAY_DEV_BUILD" unless CAGrid.method_defined?(:_dispatch_scatter_debug)
    # baseline: existing sync path
    b_base = parent_template.to_ca
    v_base = view_builder.call(b_base)
    v_base[nil] = payload  # uses func_sync_data
    # D5
    b_d5 = parent_template.to_ca
    v_d5 = view_builder.call(b_d5)
    v_d5._dispatch_scatter_debug(payload.dump_binary)

    assert_equal b_base.to_a, b_d5.to_a,
                 "scatter result mismatch:\n  baseline=#{b_base.to_a.inspect}\n  D5      =#{b_d5.to_a.inspect}"
  end
end

class TestAxisDispatchScatterCSA < Test::Unit::TestCase
  include DispatchScatterAssertions

  def test_2d_mask_with_nil
    a = CArray.int(4, 3).seq
    m = CArray.boolean(4).tap { |__a| __a[] = [1, 0, 1, 1] }
    payload = CArray.int(3, 3).tap { |__a| __a[] = [100, 101, 102, 103, 104, 105, 106, 107, 108] }
    assert_scatter_matches(a, ->(b) { b[m, nil] }, payload)
  end

  def test_2d_mask_with_range
    a = CArray.int(4, 3).seq
    m = CArray.boolean(4).tap { |__a| __a[] = [1, 0, 1, 1] }
    payload = CArray.int(3, 2).tap { |__a| __a[] = [100, 101, 102, 103, 104, 105] }
    assert_scatter_matches(a, ->(b) { b[m, 0..1] }, payload)
  end

  def test_2d_mask_with_scalar
    a = CArray.int(4, 3).seq
    m = CArray.boolean(4).tap { |__a| __a[] = [1, 0, 1, 1] }
    payload = CArray.int(3, 1).tap { |__a| __a[] = [100, 101, 102] }
    assert_scatter_matches(a, ->(b) { b[m, 1] }, payload)
  end

  def test_2d_negative_range
    a = CArray.int(4, 3).seq
    m = CArray.boolean(4).tap { |__a| __a[] = [1, 0, 1, 1] }
    payload = CArray.int(3, 2).tap { |__a| __a[] = [100, 101, 102, 103, 104, 105] }
    assert_scatter_matches(a, ->(b) { b[m, -2..-1] }, payload)
  end

  def test_2d_all_true_mask
    a = CArray.int(4, 3).seq
    m = CArray.boolean(4).fill(1)
    payload = CArray.int(4, 3).seq * -1
    assert_scatter_matches(a, ->(b) { b[m, nil] }, payload)
  end

  def test_2d_single_true_mask
    a = CArray.int(4, 3).seq
    m = CArray.boolean(4).tap { |__a| __a[] = [0, 0, 1, 0] }
    payload = CArray.int(1, 3).tap { |__a| __a[] = [999, 998, 997] }
    assert_scatter_matches(a, ->(b) { b[m, nil] }, payload)
  end

  def test_3d_mask_outer_with_nils
    a = CArray.int(3, 2, 2).seq
    m = CArray.boolean(3).tap { |__a| __a[] = [1, 0, 1] }
    payload = CArray.int(2, 2, 2).seq + 100
    assert_scatter_matches(a, ->(b) { b[m, nil, nil] }, payload)
  end

  def test_3d_mask_with_partial_ap_nested
    a = CArray.int(3, 4, 2).seq
    m = CArray.boolean(3).tap { |__a| __a[] = [1, 0, 1] }
    payload = CArray.int(2, 2, 1).tap { |__a| __a[] = [10, 20, 30, 40] }
    assert_scatter_matches(a, ->(b) { b[m, 1..2, 0] }, payload)
  end

  def test_2d_float_data_type
    a = CArray.float64(5, 4).seq * 0.25
    m = CArray.boolean(5).tap { |__a| __a[] = [1, 1, 0, 1, 0] }
    payload = CArray.float64(3, 4).seq * -0.5
    assert_scatter_matches(a, ->(b) { b[m, nil] }, payload)
  end

end

class TestAxisDispatchScatterCAGrid < Test::Unit::TestCase
  include DispatchScatterAssertions

  def test_1d_integer_grid
    a   = CArray.int(6).tap { |__a| __a[] = [10, 20, 30, 40, 50, 60] }
    idx = CArray.int(3).tap { |__a| __a[] = [5, 2, 0] }
    payload = CArray.int(3).tap { |__a| __a[] = [-1, -2, -3] }
    assert_scatter_matches(a, ->(b) { b.grid(idx) }, payload)
  end

  def test_2d_all_nil
    a = CArray.int(4, 3).seq
    payload = CArray.int(4, 3).seq * -1
    assert_scatter_matches(a, ->(b) { b.grid(nil, nil) }, payload)
  end

  def test_2d_idx_and_nil
    a   = CArray.int(4, 3).seq
    idx = CArray.int(2).tap { |__a| __a[] = [0, 2] }
    payload = CArray.int(2, 3).tap { |__a| __a[] = [10, 11, 12, 20, 21, 22] }
    assert_scatter_matches(a, ->(b) { b.grid(idx, nil) }, payload)
  end

  def test_2d_nil_and_idx
    a   = CArray.int(4, 3).seq
    idx = CArray.int(2).tap { |__a| __a[] = [1, 2] }
    payload = CArray.int(4, 2).seq + 100
    assert_scatter_matches(a, ->(b) { b.grid(nil, idx) }, payload)
  end

  def test_2d_idx_and_idx
    a  = CArray.int(4, 3).seq
    ri = CArray.int(2).tap { |__a| __a[] = [0, 2] }
    ci = CArray.int(2).tap { |__a| __a[] = [1, 2] }
    payload = CArray.int(2, 2).tap { |__a| __a[] = [10, 11, 20, 21] }
    assert_scatter_matches(a, ->(b) { b.grid(ri, ci) }, payload)
  end

  def test_2d_range_inputs
    a = CArray.int(4, 3).seq
    payload = CArray.int(4, 2).seq + 100
    assert_scatter_matches(a, ->(b) { b.grid(nil, 0..1) }, payload)
  end

  def test_3d_mixed
    a   = CArray.int(3, 4, 2).seq
    idx = CArray.int(2).tap { |__a| __a[] = [0, 3] }
    payload = CArray.int(3, 2, 2).seq + 100
    assert_scatter_matches(a, ->(b) { b.grid(nil, idx, nil) }, payload)
  end

  def test_float_data_type
    a   = CArray.float64(5, 4).seq * 0.25
    idx = CArray.int(2).tap { |__a| __a[] = [1, 3] }
    payload = CArray.float64(2, 4).seq * -1.5
    assert_scatter_matches(a, ->(b) { b.grid(idx, nil) }, payload)
  end

end

class TestAxisDispatchScatterR5 < Test::Unit::TestCase
  include DispatchScatterAssertions

  # R5: duplicate INDEX values -> output-row-major last-write-wins.
  # Verify D5 matches CAGrid's existing ca_grid_sync behavior on
  # duplicates.

  def test_1d_duplicate_first_position
    a   = CArray.int(4).fill(0)
    idx = CArray.int(3).tap { |__a| __a[] = [0, 0, 1] }
    payload = CArray.int(3).tap { |__a| __a[] = [10, 20, 30] }
    # baseline expected: a[0]=10, then a[0]=20 (overwrite), then a[1]=30
    #                 => [20, 30, 0, 0]
    assert_scatter_matches(a, ->(b) { b.grid(idx) }, payload)
  end

  def test_1d_triple_duplicate
    a   = CArray.int(3).fill(99)
    idx = CArray.int(4).tap { |__a| __a[] = [0, 0, 0, 1] }
    payload = CArray.int(4).tap { |__a| __a[] = [10, 20, 30, 40] }
    # baseline expected: a[0]=10,20,30 then a[1]=40 => [30, 40, 99]
    assert_scatter_matches(a, ->(b) { b.grid(idx) }, payload)
  end

  def test_2d_duplicate_axis0
    a  = CArray.int(3, 2).fill(0)
    ri = CArray.int(3).tap { |__a| __a[] = [0, 0, 1] }
    payload = CArray.int(3, 2).tap { |__a| __a[] = [10, 11, 20, 21, 30, 31] }
    # row-major iteration: write rows 0, 0, 1 -> last-write-wins on row 0
    assert_scatter_matches(a, ->(b) { b.grid(ri, nil) }, payload)
  end

  def test_2d_duplicate_both_axes
    a  = CArray.int(2, 2).fill(0)
    ri = CArray.int(2).tap { |__a| __a[] = [0, 0] }
    ci = CArray.int(2).tap { |__a| __a[] = [0, 0] }
    payload = CArray.int(2, 2).tap { |__a| __a[] = [1, 2, 3, 4] }
    # all 4 writes hit a[0,0], last one (= 4) wins
    assert_scatter_matches(a, ->(b) { b.grid(ri, ci) }, payload)
  end

  def test_pin_expected_value_1d
    omit "requires CARRAY_DEV_BUILD" unless CAGrid.method_defined?(:_dispatch_scatter_debug)
    # Belt-and-suspenders: independent of baseline, pin the expected
    # last-write-wins value directly.
    a   = CArray.int(4).fill(0)
    idx = CArray.int(3).tap { |__a| __a[] = [0, 0, 1] }
    payload = CArray.int(3).tap { |__a| __a[] = [10, 20, 30] }
    b = a.to_ca
    v = b.grid(idx)
    v._dispatch_scatter_debug(payload.dump_binary)
    assert_equal [20, 30, 0, 0], b.to_a
  end

  def test_pin_expected_value_2d_both_axes
    omit "requires CARRAY_DEV_BUILD" unless CAGrid.method_defined?(:_dispatch_scatter_debug)
    a  = CArray.int(2, 2).fill(0)
    ri = CArray.int(2).tap { |__a| __a[] = [0, 0] }
    ci = CArray.int(2).tap { |__a| __a[] = [0, 0] }
    payload = CArray.int(2, 2).tap { |__a| __a[] = [1, 2, 3, 4] }
    b = a.to_ca
    v = b.grid(ri, ci)
    v._dispatch_scatter_debug(payload.dump_binary)
    assert_equal [[4, 0], [0, 0]], b.to_a
  end

end
