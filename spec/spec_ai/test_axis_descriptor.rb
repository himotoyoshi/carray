# frozen_string_literal: true
#
# spec_ai/test_axis_descriptor.rb
#
# D2 unit tests: per-axis descriptor framework producer interface.
#
# See devel/PROPOSAL_AXIS_DESCRIPTOR_FRAMEWORK.md.
#
# Both CASelectAxis and CAGrid implement #_describe_axes returning
#   [[kind, count, ...], ...]  (one entry per axis)
# where the per-axis Array is:
#   [:stride, count, start, step]
#   [:index,  count, indices_ruby_array]
#
# These tests assert the descriptor output directly.  The descriptors must
# faithfully describe each view's current internal state — not what the user
# originally typed.

require "test/unit"
require_relative "../../lib/carray"

# === CARRAY_DEV_BUILD guard ===
# `_describe_axes` is a debug accessor gated by -DCARRAY_DEV_BUILD.
# Rebuild with `CARRAY_DEV=1 rake build_ext` to enable.
unless CAGrid.method_defined?(:_describe_axes)
  warn "skipping #{File.basename(__FILE__)}: requires CARRAY_DEV_BUILD"
  return
end

class TestAxisDescriptorCSA < Test::Unit::TestCase

  def test_mask_outer_with_nil
    a = CArray.int(4, 3).seq
    m = CArray.boolean(4).tap { |__a| __a[] = [1, 0, 1, 1] }
    desc = a[m, nil]._describe_axes
    assert_equal 2, desc.length
    assert_equal [:index, 3, [0, 2, 3]], desc[0]
    assert_equal [:stride, 3, 0, 1],     desc[1]
  end

  def test_mask_outer_with_range
    a = CArray.int(4, 3).seq
    m = CArray.boolean(4).tap { |__a| __a[] = [1, 0, 1, 1] }
    desc = a[m, 0..1]._describe_axes
    assert_equal [:index,  3, [0, 2, 3]], desc[0]
    assert_equal [:stride, 2, 0, 1],      desc[1]
  end

  def test_mask_outer_with_scalar
    a = CArray.int(4, 3).seq
    m = CArray.boolean(4).tap { |__a| __a[] = [1, 0, 1, 1] }
    desc = a[m, 1]._describe_axes
    assert_equal [:index,  3, [0, 2, 3]], desc[0]
    assert_equal [:stride, 1, 1, 1],      desc[1]
  end

  def test_3d_mask_outer
    a = CArray.int(3, 2, 2).seq
    m = CArray.boolean(3).tap { |__a| __a[] = [1, 0, 1] }
    desc = a[m, nil, nil]._describe_axes
    assert_equal 3, desc.length
    # Y.6: indices [0, 2] form constant step 2 -> STRIDE kind promotion
    assert_equal [:stride, 2, 0, 2],   desc[0]
    assert_equal [:stride, 2, 0, 1],   desc[1]
    assert_equal [:stride, 2, 0, 1],   desc[2]
  end

  def test_all_true_mask
    a = CArray.int(4, 3).seq
    m = CArray.boolean(4).fill(1)
    desc = a[m, nil]._describe_axes
    # Y.6: all-true mask -> indices [0..3] constant step 1 -> STRIDE
    assert_equal [:stride, 4, 0, 1],        desc[0]
    assert_equal [:stride, 3, 0, 1],        desc[1]
  end

  def test_empty_mask
    a = CArray.int(4, 3).seq
    m = CArray.boolean(4).fill(0)
    desc = a[m, nil]._describe_axes
    assert_equal [:index,  0, []],   desc[0]
    assert_equal [:stride, 3, 0, 1], desc[1]
  end

  def test_descriptor_indices_borrow_view_lifetime
    # Indices field borrows from the view's own snapshot, not from
    # the original Ruby selector.  Mutating the original boolean
    # CArray must not change the descriptor.
    a = CArray.int(4, 3).seq
    m = CArray.boolean(4).tap { |__a| __a[] = [1, 0, 1, 1] }
    v = a[m, nil]
    d1 = v._describe_axes
    m[1] = 1
    m[0] = 0
    d2 = v._describe_axes
    assert_equal d1, d2
  end

  def test_negative_range_normalised_in_stride
    # CSA dispatch normalises -1 to dim-1 at construction;
    # the resulting STRIDE descriptor reflects the normalised form.
    a = CArray.int(4, 3).seq
    m = CArray.boolean(4).tap { |__a| __a[] = [1, 0, 1, 1] }
    desc = a[m, -2..-1]._describe_axes
    assert_equal [:index,  3, [0, 2, 3]], desc[0]
    assert_equal [:stride, 2, 1, 1],      desc[1]
  end

end

class TestAxisDescriptorCAGrid < Test::Unit::TestCase

  def test_all_nil_lifts_to_stride
    a = CArray.int(4, 3).seq
    desc = a.grid(nil, nil)._describe_axes
    assert_equal 2, desc.length
    assert_equal [:stride, 4, 0, 1], desc[0]
    assert_equal [:stride, 3, 0, 1], desc[1]
  end

  def test_integer_array_emits_index
    a = CArray.int(4, 3).seq
    idx = CArray.int(2).tap { |__a| __a[] = [0, 2] }
    desc = a.grid(idx, nil)._describe_axes
    assert_equal [:index,  2, [0, 2]],   desc[0]
    assert_equal [:stride, 3, 0, 1],     desc[1]
  end

  def test_range_emits_stride_after_c1
    # Post-Tier 3 (C1, PROPOSAL_CAGRID_REBUILD): rb_ca_grid now detects
    # plain integer Range and stores it as STRIDE (start/count/step=1)
    # in the cag_axis_t internal struct, preserving the arithmetic-
    # progression structure that the legacy implementation lost.
    # describe_axes therefore emits STRIDE for Range args.
    a = CArray.int(4, 3).seq
    desc = a.grid(nil, 0..1)._describe_axes
    assert_equal [:stride, 4, 0, 1], desc[0]
    assert_equal [:stride, 2, 0, 1], desc[1]
  end

  def test_boolean_to_where_emits_index
    a = CArray.int(4, 3).seq
    m = CArray.boolean(4).tap { |__a| __a[] = [1, 0, 1, 1] }
    # CAGrid converts boolean to where (integer array) at construction
    desc = a.grid(m, nil)._describe_axes
    assert_equal [:index,  3, [0, 2, 3]], desc[0]
    assert_equal [:stride, 3, 0, 1],      desc[1]
  end

  def test_3d_mixed
    a = CArray.int(3, 4, 2).seq
    idx = CArray.int(2).tap { |__a| __a[] = [0, 3] }
    desc = a.grid(nil, idx, nil)._describe_axes
    assert_equal 3, desc.length
    assert_equal [:stride, 3, 0, 1], desc[0]
    assert_equal [:index,  2, [0, 3]], desc[1]
    assert_equal [:stride, 2, 0, 1], desc[2]
  end

end

class TestAxisDescriptorSiblingHypothesis < Test::Unit::TestCase
  # Where the sibling hypothesis "CSA and CAGrid are sister views
  # differing only in input format" actually holds vs. where the
  # construction-time information loss in CAGrid breaks symmetry.

  def test_csa_mask_and_cagrid_where_produce_same_index_descriptor
    # CSA: a[mask, nil]
    # CAGrid: a.grid(mask.where, nil) — equivalent semantically
    a = CArray.int(4, 3).seq
    m = CArray.boolean(4).tap { |__a| __a[] = [1, 0, 1, 1] }
    csa  = a[m, nil]._describe_axes
    grid = a.grid(m.where, nil)._describe_axes
    assert_equal csa[0], grid[0]
    assert_equal csa[1], grid[1]
  end

  def test_csa_and_cagrid_both_emit_stride_for_range_after_c1
    # Pre-C1 asymmetry: CSA preserved Range as STRIDE, CAGrid lost it
    # to INDEX (lossy conversion via CA_SIZE(range)).
    # Post-Tier 3 / C1 (PROPOSAL_CAGRID_REBUILD): CAGrid detects plain
    # integer Range at the rb_ca_grid level and stores STRIDE.  Both
    # views now emit STRIDE descriptors for Range arguments —
    # asymmetry #1 resolved.
    a = CArray.int(4, 3).seq
    m = CArray.boolean(4).fill(1)
    csa  = a[m, 0..1]._describe_axes
    grid = a.grid(nil, 0..1)._describe_axes
    assert_equal :stride, csa[1][0],  "CSA preserves Range as STRIDE"
    assert_equal :stride, grid[1][0], "CAGrid post-C1 also preserves Range as STRIDE"
  end

end
