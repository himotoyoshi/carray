# frozen_string_literal: true
#
# spec_ai/test_ca_slab_axes_t1.rb
#
# Phase A capstone (PROPOSAL_CAPSTONE_PHASE_A.md A.2): formal Ruby
# tests for CA_SLAB_AXES policy T1 (= entity + CAStride family, init_l2
# only).  Pins:
#   - axis partitioning (slab vs outer, ascending order)
#   - K-D slab yield correctness via t1_smoke_sum_axes_f64 vs ca.sum reference
#   - WHOLE-equivalent collapse (all axes specified, 1-D degenerate)
#   - CAStride non-contig sources (transpose, sliced, repeat)
#   - mask passthrough (UNDEF cells skipped, byte parity vs ca.sum)
#   - error rejects (duplicate axis, out-of-range, L1 reject, descriptor
#     reject)
#
# Sub-step A.4 will rewrite sum_ki on top of this surface; this test
# file pins the iterator behavior so A.4 regressions surface here.

require "test/unit"
require_relative "../../lib/carray"

# === CARRAY_DEV_BUILD guard (auto-added by S.7) ===
# This test exercises smoke surface gated by -DCARRAY_DEV_BUILD.
# Rebuild with `CARRAY_DEV=1 rake build_ext` to enable.
unless CArray.respond_to?(:t1_smoke)
  warn "skipping #{File.basename(__FILE__)}: requires CARRAY_DEV_BUILD"
  return
end

class TestCASlabAxesT1 < Test::Unit::TestCase

  OK            = CArray::T1_ITER_OK
  ERR_NOT_CHEAP = CArray::T1_ITER_ERR_NOT_CHEAP

  # Helper: compute reference total = ca.sum (Float), tolerant compare
  def assert_close(expected, actual, msg = nil)
    assert_in_delta(expected, actual, 1e-9, msg)
  end

  # ---- happy paths: entity sources -------------------------------------

  def test_entity_all_axes_whole_equivalent
    # All-axes specified collapses to single slab (outer_ndim=0)
    ca = CArray.float64(2, 3, 4, 5).seq
    got = CArray.t1_smoke_sum_axes_f64(ca, 0, 1, 2, 3)
    assert_close(ca.sum.to_f, got)
  end

  def test_entity_single_axis_inner
    ca = CArray.float64(2, 3, 4, 5).seq
    # slab = innermost axis 3, outer walks (2,3,4) = 24 slabs of size 5
    got = CArray.t1_smoke_sum_axes_f64(ca, 3)
    assert_close(ca.sum.to_f, got)
  end

  def test_entity_single_axis_outer
    ca = CArray.float64(2, 3, 4, 5).seq
    # slab = outermost axis 0, outer walks (3,4,5) = 60 slabs of size 2
    got = CArray.t1_smoke_sum_axes_f64(ca, 0)
    assert_close(ca.sum.to_f, got)
  end

  def test_entity_multi_axis_contiguous
    ca = CArray.float64(2, 3, 4, 5).seq
    # slab = innermost {2,3}, outer walks (2,3) = 6 slabs of size 20
    got = CArray.t1_smoke_sum_axes_f64(ca, 2, 3)
    assert_close(ca.sum.to_f, got)
  end

  def test_entity_multi_axis_non_adjacent
    ca = CArray.float64(2, 3, 4, 5).seq
    # slab = {0, 2}, outer = {1, 3}.  Non-adjacent slab axes through
    # non-row-major slab_strides.
    got = CArray.t1_smoke_sum_axes_f64(ca, 0, 2)
    assert_close(ca.sum.to_f, got)
  end

  def test_entity_axes_input_order_unaffected
    # User-supplied {3, 0, 2} should be canonicalised to ascending
    # {0, 2, 3} internally.  Total sum invariant to order.
    ca = CArray.float64(2, 3, 4, 5).seq
    a = CArray.t1_smoke_sum_axes_f64(ca, 0, 2, 3)
    b = CArray.t1_smoke_sum_axes_f64(ca, 3, 0, 2)
    c = CArray.t1_smoke_sum_axes_f64(ca, 2, 3, 0)
    assert_close(a, b)
    assert_close(a, c)
    assert_close(ca.sum.to_f, a)
  end

  def test_entity_1d_degenerate
    # 1-D + slab_axes={0} = WHOLE-equivalent (outer_ndim=0)
    ca = CArray.float64(10).seq
    assert_close(ca.sum.to_f, CArray.t1_smoke_sum_axes_f64(ca, 0))
  end

  def test_entity_2d_single_axis
    ca = CArray.float64(4, 5).seq
    assert_close(ca.sum.to_f, CArray.t1_smoke_sum_axes_f64(ca, 0))
    assert_close(ca.sum.to_f, CArray.t1_smoke_sum_axes_f64(ca, 1))
  end

  # ---- happy paths: CAStride family ------------------------------------

  def test_castride_transpose_non_contig
    # transpose produces a CAStride non-contig view; compose-fold path
    # in init_l2 computes root strides.
    ca = CArray.float64(2, 3, 4, 5).seq
    tr = ca.transpose(3, 1, 2, 0)  # shape (5, 3, 4, 2), non-contig
    # Total sum invariant under permutation
    assert_close(ca.sum.to_f, CArray.t1_smoke_sum_axes_f64(tr, 0, 1, 2, 3))
    assert_close(ca.sum.to_f, CArray.t1_smoke_sum_axes_f64(tr, 0, 2))
  end

  def test_castride_reshape_contig
    # reshape to a different shape (CAStride contig alias path)
    ca = CArray.float64(2, 3, 4, 5).seq
    rs = ca.reshape(6, 20)  # contig alias
    assert_close(ca.sum.to_f, CArray.t1_smoke_sum_axes_f64(rs, 0, 1))
    assert_close(ca.sum.to_f, CArray.t1_smoke_sum_axes_f64(rs, 0))
    assert_close(ca.sum.to_f, CArray.t1_smoke_sum_axes_f64(rs, 1))
  end

  def test_castride_row_slice
    # row slice = CAStride contig
    ca = CArray.float64(4, 5).seq
    row = ca[1, nil]  # shape (5), contig
    assert_close(row.sum.to_f, CArray.t1_smoke_sum_axes_f64(row, 0))
  end

  def test_castride_column_slice_non_contig
    # column slice = CAStride non-contig (stride != bytes on innermost)
    ca = CArray.float64(4, 5).seq
    col = ca[nil, 2]  # shape (4), non-contig
    assert_close(col.sum.to_f, CArray.t1_smoke_sum_axes_f64(col, 0))
  end

  # ---- happy paths: mask -----------------------------------------------

  def test_entity_with_mask_all_axes
    ca = CArray.float64(2, 3, 4, 5).seq
    ca[0, 0, 0, 0] = UNDEF
    ca[1, 2, 3, 4] = UNDEF
    assert_close(ca.sum.to_f, CArray.t1_smoke_sum_axes_f64(ca, 0, 1, 2, 3))
  end

  def test_entity_with_mask_multi_axis
    ca = CArray.float64(2, 3, 4, 5).seq
    ca[0, 0, 0, 0] = UNDEF
    ca[1, 2, 3, 4] = UNDEF
    # multi-axis slab + mask: each slab visits masked cells, skip
    assert_close(ca.sum.to_f, CArray.t1_smoke_sum_axes_f64(ca, 2, 3))
    assert_close(ca.sum.to_f, CArray.t1_smoke_sum_axes_f64(ca, 0, 2))
  end

  def test_castride_transpose_with_mask
    # mask passthrough through transposed CAStride (mask scratch is in
    # view row-major order, distinct from data composed_strides)
    ca = CArray.float64(2, 3, 4, 5).seq
    ca[0, 0, 0, 0] = UNDEF
    ca[1, 2, 3, 4] = UNDEF
    tr = ca.transpose(3, 1, 2, 0)
    assert_close(ca.sum.to_f, CArray.t1_smoke_sum_axes_f64(tr, 0, 1, 2, 3))
    assert_close(ca.sum.to_f, CArray.t1_smoke_sum_axes_f64(tr, 0, 2))
  end

  def test_all_masked_zero_sum
    # All cells masked → kernel skips all, acc stays at 0.0
    ca = CArray.float64(3, 4).seq
    ca[] = UNDEF
    got = CArray.t1_smoke_sum_axes_f64(ca, 0, 1)
    assert_in_delta(0.0, got, 1e-9)
  end

  # ---- error rejects --------------------------------------------------

  def test_reject_duplicate_axis
    ca = CArray.float64(2, 3, 4)
    e = assert_raise(RuntimeError) do
      CArray.t1_smoke_sum_axes_f64(ca, 0, 0)
    end
    assert_match(/rc=2/, e.message)  # CA_ITER_ERR_POLICY
  end

  def test_reject_out_of_range_axis
    ca = CArray.float64(2, 3)
    e = assert_raise(RuntimeError) do
      CArray.t1_smoke_sum_axes_f64(ca, 5)
    end
    assert_match(/rc=2/, e.message)
  end

  def test_reject_negative_axis
    # CA_SLAB_AXES API does NOT accept negative axes (caller-side
    # responsibility per axis validation in init_l2).  Python-style
    # negation can be done at the Ruby wrapper level (= rb_ca_sum_ki).
    ca = CArray.float64(2, 3)
    e = assert_raise(RuntimeError) do
      CArray.t1_smoke_sum_axes_f64(ca, -1)
    end
    assert_match(/rc=2/, e.message)
  end

  def test_reject_naxes_exceeds_ndim
    ca = CArray.float64(2, 3)  # ndim=2
    e = assert_raise(RuntimeError) do
      CArray.t1_smoke_sum_axes_f64(ca, 0, 1, 0)  # 3 axes incl duplicate
    end
    assert_match(/rc=2/, e.message)
  end

  # Phase C T3 (C.1, 2026-05-27): CASelect (= descriptor view with
  # INDEX slab when slab covers the entire 1-D view) is now accepted via
  # per-slab materialise fallback.  Originally a Phase A reject pin; the
  # T3 fallback path makes the descriptor-source case work without any
  # change to the t1_smoke surface.
  def test_descriptor_source_caselect_accepted_phase_c
    ca = CArray.float64(8).seq
    mask = CArray.boolean(8)
    8.times { |i| mask[i] = (i.even? ? 1 : 0) }
    sel = ca[mask]  # CASelect
    got = CArray.t1_smoke_sum_axes_f64(sel, 0)
    assert_in_delta(sel.sum.to_f, got, 1e-9)
  end

  # ---- order independence + canonicalisation ---------------------------

  def test_outer_walk_order_pin
    # Slab walk emits Π outer_dims slabs in row-major outer order.
    # Verified indirectly by total invariance under non-trivial slab
    # choices producing identical totals.
    ca = CArray.float64(2, 3, 4).seq
    a = CArray.t1_smoke_sum_axes_f64(ca, 0)
    b = CArray.t1_smoke_sum_axes_f64(ca, 1)
    c = CArray.t1_smoke_sum_axes_f64(ca, 2)
    d = CArray.t1_smoke_sum_axes_f64(ca, 0, 1)
    e = CArray.t1_smoke_sum_axes_f64(ca, 0, 1, 2)
    ref = ca.sum.to_f
    assert_close(ref, a)
    assert_close(ref, b)
    assert_close(ref, c)
    assert_close(ref, d)
    assert_close(ref, e)
  end

  # ---- empty-slab edge case --------------------------------------------

  def test_empty_dim_slab_axis
    # Source with one dim = 0 → slab_elements = 0, kernel sum = 0
    ca = CArray.float64(2, 0, 3)  # axis 1 empty
    got = CArray.t1_smoke_sum_axes_f64(ca, 0, 1, 2)
    assert_in_delta(0.0, got, 1e-9)
  end

end
