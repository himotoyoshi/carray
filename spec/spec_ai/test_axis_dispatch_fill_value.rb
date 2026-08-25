# frozen_string_literal: true
#
# spec_ai/test_axis_dispatch_fill_value.rb
#
# D6 unit tests: per-axis descriptor broadcast-fill engine.
#
# See devel/PROPOSAL_AXIS_DESCRIPTOR_FRAMEWORK.md §4 D6 / §6 R6.
#
# Correctness criterion: broadcasting a single value via
# ca_axis_dispatch_fill_value must produce the same final parent
# state as the view's existing fill path (CSA: ca_select_axis_fill_with;
# CAGrid: ca_grid_fill).  Both invoked via debug accessors.
#
# Duplicate INDEX semantics: trivially satisfied since writing the
# same value N times to the same cell leaves it equal to the value.

require "test/unit"
require_relative "../../lib/carray"

module DispatchFillValueAssertions
  # For a view-builder and a scalar value, run fill via D6 and via
  # the view's existing path on independent parent copies, then assert
  # the two resulting parent states are equal.
  def assert_fill_matches (parent_template, view_builder, value, data_type = :int)
    omit "requires CARRAY_DEV_BUILD" unless CAGrid.method_defined?(:_dispatch_fill_value_debug)
    # baseline: existing fill path via `view = value`
    b_base = parent_template.to_ca
    v_base = view_builder.call(b_base)
    v_base[nil] = value if v_base.ndim == 1
    v_base[*([nil] * v_base.ndim)] = value if v_base.ndim > 1
    # D6
    b_d6 = parent_template.to_ca
    v_d6 = view_builder.call(b_d6)
    val_array = CArray.send(data_type, 1).tap { |__a| __a[] = [value] }
    v_d6._dispatch_fill_value_debug(val_array.dump_binary)

    assert_equal b_base.to_a, b_d6.to_a,
                 "fill_value result mismatch:\n  baseline=#{b_base.to_a.inspect}\n  D6      =#{b_d6.to_a.inspect}"
  end
end

class TestAxisDispatchFillValueCSA < Test::Unit::TestCase
  include DispatchFillValueAssertions

  def test_2d_mask_with_nil
    a = CArray.int(4, 3).seq
    m = CArray.boolean(4).tap { |__a| __a[] = [1, 0, 1, 1] }
    assert_fill_matches(a, ->(b) { b[m, nil] }, -7)
  end

  def test_2d_mask_with_range
    a = CArray.int(4, 3).seq
    m = CArray.boolean(4).tap { |__a| __a[] = [1, 0, 1, 1] }
    assert_fill_matches(a, ->(b) { b[m, 0..1] }, -2)
  end

  def test_2d_mask_with_scalar
    a = CArray.int(4, 3).seq
    m = CArray.boolean(4).tap { |__a| __a[] = [1, 0, 1, 1] }
    assert_fill_matches(a, ->(b) { b[m, 1] }, -9)
  end

  def test_2d_all_true_mask
    a = CArray.int(4, 3).seq
    m = CArray.boolean(4).fill(1)
    assert_fill_matches(a, ->(b) { b[m, nil] }, 42)
  end

  def test_2d_single_true_mask
    a = CArray.int(4, 3).seq
    m = CArray.boolean(4).tap { |__a| __a[] = [0, 0, 1, 0] }
    assert_fill_matches(a, ->(b) { b[m, nil] }, 999)
  end

  def test_3d_mask_outer_with_nils
    a = CArray.int(3, 2, 2).seq
    m = CArray.boolean(3).tap { |__a| __a[] = [1, 0, 1] }
    assert_fill_matches(a, ->(b) { b[m, nil, nil] }, -42)
  end

  def test_3d_mask_with_partial_ap_nested
    a = CArray.int(3, 4, 2).seq
    m = CArray.boolean(3).tap { |__a| __a[] = [1, 0, 1] }
    assert_fill_matches(a, ->(b) { b[m, 1..2, 0] }, 88)
  end

  def test_2d_float_data_type
    a = CArray.float64(5, 4).seq * 0.25
    m = CArray.boolean(5).tap { |__a| __a[] = [1, 1, 0, 1, 0] }
    assert_fill_matches(a, ->(b) { b[m, nil] }, 1.25, :float64)
  end

end

class TestAxisDispatchFillValueCAGrid < Test::Unit::TestCase
  include DispatchFillValueAssertions

  def test_1d_integer_grid
    a   = CArray.int(6).tap { |__a| __a[] = [10, 20, 30, 40, 50, 60] }
    idx = CArray.int(3).tap { |__a| __a[] = [5, 2, 0] }
    assert_fill_matches(a, ->(b) { b.grid(idx) }, -1)
  end

  def test_2d_all_nil
    a = CArray.int(4, 3).seq
    assert_fill_matches(a, ->(b) { b.grid(nil, nil) }, 7)
  end

  def test_2d_idx_and_nil
    a   = CArray.int(4, 3).seq
    idx = CArray.int(2).tap { |__a| __a[] = [0, 2] }
    assert_fill_matches(a, ->(b) { b.grid(idx, nil) }, 99)
  end

  def test_2d_nil_and_idx
    a   = CArray.int(4, 3).seq
    idx = CArray.int(2).tap { |__a| __a[] = [1, 2] }
    assert_fill_matches(a, ->(b) { b.grid(nil, idx) }, -5)
  end

  def test_2d_idx_and_idx
    a  = CArray.int(4, 3).seq
    ri = CArray.int(2).tap { |__a| __a[] = [0, 2] }
    ci = CArray.int(2).tap { |__a| __a[] = [1, 2] }
    assert_fill_matches(a, ->(b) { b.grid(ri, ci) }, 100)
  end

  def test_2d_range_inputs
    a = CArray.int(4, 3).seq
    assert_fill_matches(a, ->(b) { b.grid(nil, 0..1) }, 33)
  end

  def test_3d_mixed
    a   = CArray.int(3, 4, 2).seq
    idx = CArray.int(2).tap { |__a| __a[] = [0, 3] }
    assert_fill_matches(a, ->(b) { b.grid(nil, idx, nil) }, -111)
  end

  def test_float_data_type
    a   = CArray.float64(5, 4).seq * 0.25
    idx = CArray.int(2).tap { |__a| __a[] = [1, 3] }
    assert_fill_matches(a, ->(b) { b.grid(idx, nil) }, 3.5, :float64)
  end

  # Duplicate INDEX: every duplicate write deposits the same value;
  # the end-state must be the value at each addressed cell.
  def test_duplicate_index_writes_same_value
    a = CArray.int(3).fill(0)
    idx = CArray.int(4).tap { |__a| __a[] = [0, 0, 0, 1] }
    assert_fill_matches(a, ->(b) { b.grid(idx) }, 42)
  end

  def test_pin_duplicate_index_end_state
    omit "requires CARRAY_DEV_BUILD" unless CAGrid.method_defined?(:_dispatch_fill_value_debug)
    a = CArray.int(3).fill(0)
    idx = CArray.int(4).tap { |__a| __a[] = [0, 0, 0, 1] }
    b = a.to_ca
    v = b.grid(idx)
    val = CArray.int(1).tap { |__a| __a[] = [42] }
    v._dispatch_fill_value_debug(val.dump_binary)
    assert_equal [42, 42, 0], b.to_a
  end

end
