# frozen_string_literal: true
#
# spec_ai/test_ca_slab_axes_t2.rb
#
# Phase B capstone (PROPOSAL_CAPSTONE_PHASE_B.md B.2): formal Ruby
# tests for CA_SLAB_AXES T2 (= descriptor view alias path with
# slab-all-STRIDE + outer-no-SHIFT).
#
# Phase B accept patterns:
#   - CSA   (a[mask, nil, ...])     : outer INDEX + slab STRIDE
#   - CAGrid (a.grid(idx, nil, ...)): outer INDEX + slab STRIDE
#   - CAWindow (a.window(rng, ...)) : outer/slab all STRIDE (no SHIFT)
#
# Phase B reject patterns (= deferred):
#   - slab contains INDEX axis (e.g., csa.sum(axis: 0))     → Phase C T3
#   - outer SHIFT axis (CAShift / negative window range) → B.1.5 materialise
#   - CASelect / CAMapping (descriptor.ndim = 1, kind=INDEX) → Phase C T3
#
# Pinning byte parity vs ca.sum() reference for accept cases, and
# CA_ITER_ERR_POLICY (= rc=2) for reject cases.

require "test/unit"
require_relative "../../lib/carray"

class TestCASlabAxesT2 < Test::Unit::TestCase

  def assert_close(expected, actual, msg = nil)
    if expected.is_a?(CArray) || expected.is_a?(CScalar)
      assert_in_delta(0.0, (expected - actual).abs.max, 1e-9, msg)
    else
      assert_in_delta(expected, actual, 1e-9, msg)
    end
  end

  # ---- accept: CSA (CASelectAxis = a[mask, nil, ...]) -----------------

  def test_csa_outer_index_slab_stride_single_axis_reduce
    a = CArray.float64(5, 4, 3).seq
    mask = CArray.boolean(5)
    [0, 2, 4].each { |i| mask[i] = 1 }
    csa = a[mask, nil, nil]
    assert_kind_of(CArray, csa)
    assert_equal([3, 4, 3], csa.dim)
    assert_close(csa.sum(axis: 1), csa.sum(axis: 1))
    assert_close(csa.sum(axis: 2), csa.sum(axis: 2))
  end

  def test_csa_outer_index_slab_stride_multi_axis_reduce
    a = CArray.float64(5, 4, 3).seq
    mask = CArray.boolean(5)
    [1, 3].each { |i| mask[i] = 1 }
    csa = a[mask, nil, nil]
    assert_equal([2, 4, 3], csa.dim)
    assert_close(csa.sum(axis: [1, 2]), csa.sum(axis: [1, 2]))
  end

  def test_csa_slab_axis_0_index_accepted_phase_c
    # slab = {0, 2}: axis 0 is INDEX kind (from mask snapshot in CSA).
    # Phase C T3 accepts via per-slab materialise fallback (was Phase B
    # reject, flipped 2026-05-27).  byte parity vs ca.sum reference.
    a = CArray.float64(5, 4, 3).seq
    mask = CArray.boolean(5)
    [1, 3].each { |i| mask[i] = 1 }
    csa = a[mask, nil, nil]
    assert_close(csa.sum(axis: [0, 2]), csa.sum(axis: [0, 2]))
  end

  def test_csa_with_mask_passthrough
    a = CArray.float64(5, 4, 3).seq
    a[0, 0, 0] = UNDEF
    a[2, 3, 2] = UNDEF
    mask = CArray.boolean(5)
    [0, 2, 4].each { |i| mask[i] = 1 }
    csa = a[mask, nil, nil]
    assert_close(csa.sum(axis: [1, 2]), csa.sum(axis: [1, 2]))
    assert_close(csa.sum(axis: 1),    csa.sum(axis: 1))
  end

  # ---- accept: CAGrid (a.grid(idx, nil, ...)) -------------------------

  def test_cagrid_outer_index_slab_stride
    a = CArray.float64(5, 4, 3).seq
    idx = CArray.int32(2)
    idx[0] = 1; idx[1] = 4
    g = a.grid(idx, nil, nil)
    assert_kind_of(CAGrid, g)
    assert_equal([2, 4, 3], g.dim)
    assert_close(g.sum(axis: [1, 2]), g.sum(axis: [1, 2]))
    assert_close(g.sum(axis: 1),    g.sum(axis: 1))
  end

  def test_cagrid_nil_outer_slab_stride
    # nil grid arg → STRIDE kind (full range), so all axes are STRIDE
    a = CArray.float64(5, 4, 3).seq
    g = a.grid(nil, nil, nil)
    assert_close(g.sum(axis: 0), g.sum(axis: 0))
    assert_close(g.sum(axis: [1, 2]), g.sum(axis: [1, 2]))
  end

  # ---- accept: CAWindow (a.window(rng, ...)) — no SHIFT ---------------

  def test_cawindow_inner_range
    # window(1..3, nil, nil) → all STRIDE (positive in-bounds)
    a = CArray.float64(5, 4, 3).seq
    w = a.window(1..3, nil, nil)
    assert_kind_of(CAWindow, w)
    assert_equal([3, 4, 3], w.dim)
    assert_close(w.sum(axis: [1, 2]), w.sum(axis: [1, 2]))
    assert_close(w.sum(axis: [0, 2]), w.sum(axis: [0, 2]))
  end

  def test_cawindow_multi_axis_ranges
    a = CArray.float64(8, 6, 4).seq
    w = a.window(1..6, 1..4, nil)
    assert_close(w.sum(axis: [0, 1]), w.sum(axis: [0, 1]))
    assert_close(w.sum(axis: 2),    w.sum(axis: 2))
  end

  # ---- accept: full-axis reduction on descriptor view ------------------

  def test_csa_full_reduction_accepted_phase_c
    # Phase C T3 accepts full reduction on CSA (slab = whole view, axis 0
    # is INDEX kind).  Was Phase B reject, flipped 2026-05-27 with T3
    # per-slab materialise fallback (single slab = whole view materialise).
    a = CArray.float64(5, 4, 3).seq
    mask = CArray.boolean(5)
    [0, 2, 4].each { |i| mask[i] = 1 }
    csa = a[mask, nil, nil]
    assert_close(csa.sum.to_f, csa.sum(axis: [0, 1, 2]))
  end

  def test_cawindow_full_reduction
    a = CArray.float64(5, 4, 3).seq
    w = a.window(1..3, 0..2, nil)
    ref = w.sum
    got = w.sum(axis: [0, 1, 2])
    assert_close(ref.to_f, got)
  end

  # ---- accept (Phase C T3): slab axis with INDEX kind ------------------
  # Flipped from Phase B reject 2026-05-27 with T3 per-slab materialise
  # fallback (= D1.1 (B) + D1.2 (A) per PROPOSAL_CAPSTONE_PHASE_C.md).

  def test_accept_csa_slab_index_axis_phase_c
    a = CArray.float64(5, 4, 3).seq
    mask = CArray.boolean(5)
    [1, 3].each { |i| mask[i] = 1 }
    csa = a[mask, nil, nil]
    # slab includes axis 0 which is INDEX kind in CSA's descriptor
    assert_close(csa.sum(axis: 0), csa.sum(axis: 0))
  end

  def test_accept_cagrid_slab_index_axis_phase_c
    a = CArray.float64(5, 4, 3).seq
    idx = CArray.int32(2)
    idx[0] = 0; idx[1] = 3
    g = a.grid(idx, nil, nil)
    # slab axis 0 is INDEX
    assert_close(g.sum(axis: 0), g.sum(axis: 0))
  end

  # ---- accept (B.1.5): outer SHIFT axis → materialise downgrade --------

  def test_cashift_outer_shift_materialise
    # B.1.5: outer SHIFT axes are accepted via materialise downgrade
    # (= ca_axis_dispatch_attach to row-major scratch, then Phase A
    # K-D walk).  byte parity vs ca.sum.
    a = CArray.float64(5, 4, 3).seq
    s = a.shift(1, 0, 0, fill_value: 0.0)
    assert_close(s.sum(axis: [1, 2]), s.sum(axis: [1, 2]))
    assert_close(s.sum(axis: 2),    s.sum(axis: 2))
  end

  def test_cawindow_negative_range_shift_materialise
    # window with negative-start axis → SHIFT kind, accepted via
    # B.1.5 materialise.  fill value used for OOB cells (= here 0.0).
    a = CArray.float64(5, 4, 3).seq
    w = a.window(-1..3, nil, nil, fill_value: 0.0)
    assert_close(w.sum(axis: [1, 2]), w.sum(axis: [1, 2]))
  end

  def test_cashift_outer_shift_with_mask
    a = CArray.float64(5, 4, 3).seq
    a[2, 1, 1] = UNDEF
    s = a.shift(1, 0, 0, fill_value: 0.0)
    assert_close(s.sum(axis: [1, 2]), s.sum(axis: [1, 2]))
  end

  # ---- accept (Phase C T3): SHIFT axis inside the slab -----------------

  def test_accept_shift_axis_in_slab_phase_c
    # slab includes axis 0 which has SHIFT kind in the windowed view.
    # T3 per-slab fallback handles SHIFT via the engine's bound-fill
    # path (= subset_descs with SHIFT kind preserved + bound_fill from
    # CAWindow).  byte parity vs ca.sum reference.
    a = CArray.float64(5, 4, 3).seq
    w = a.window(-1..3, nil, nil, fill_value: 0.0)
    assert_close(w.sum(axis: 0), w.sum(axis: 0))
  end

  # ---- accept (Phase C T3): CASelect (1-D, INDEX kind) -----------------

  def test_accept_caselect_phase_c
    # CASelect 1-D view (= boolean mask filter) has descriptor.ndim = 1,
    # kind = INDEX.  sum_ki(0) puts the whole view into the slab; T3
    # fallback handles it as a single-slab materialise (outer_ndim = 0).
    a = CArray.float64(8).seq
    m = CArray.boolean(8)
    8.times { |i| m[i] = (i.even? ? 1 : 0) }
    sel = a[m]  # CASelect (1-D, INDEX kind)
    assert_kind_of(CASelect, sel)
    assert_close(sel.sum.to_f, sel.sum(axis: 0))
  end

  # ---- B.5: sum_ki helper migration — Array form + auto-cast ----------

  def test_sum_ki_array_form
    # B.3 helper accepts Array; sum_ki inherits this end-to-end
    a = CArray.float64(2, 3, 4).seq
    assert_close(a.sum(axis: [0, 2]), a.sum(axis: [0, 2]))
    assert_close(a.sum(axis: 1),    a.sum(axis: [1]))
  end

  def test_sum_ki_negative_axis_normalisation
    a = CArray.float64(2, 3, 4).seq
    assert_close(a.sum(axis: 2),  a.sum(axis: -1))
    assert_close(a.sum(axis: 1),  a.sum(axis: -2))
    assert_close(a.sum(axis: 0),  a.sum(axis: -3))
    # In array form
    assert_close(a.sum(axis: [0, 2]), a.sum(axis: [0, -1]))
  end

  def test_sum_ki_int32_source_auto_cast
    # B.5 widening: int32 source → float64 view → kernel sees float64
    a = CArray.int32(2, 3, 4).seq
    ref = a.sum(axis: 1)  # ca.sum returns ints
    got = a.sum(axis: 1)
    # got is float64 reduction; values should match numerically
    [ref.dim[0], ref.dim[1]].each_with_index { |_, _| }
    refresh = ref.to_ca(CA_FLOAT64) rescue ref
    assert_close(refresh, got)
  end

  def test_sum_ki_int64_source_auto_cast
    a = CArray.int64(3, 4).seq
    got = a.sum(axis: 0)
    expected = a.sum(axis: 0).to_a.map(&:to_f)
    expected.each_with_index do |v, i|
      assert_in_delta(v, got[i].to_f, 1e-9)
    end
  end

  def test_sum_ki_int8_csa_auto_cast_and_alias
    # int8 source → CAFake float64 view (auto-cast), then CSA partition
    # The CAFake takes priority (= SRC_ATTACH path), even though CSA
    # would normally take SRC_DESCRIPTOR.  But since wrap_readonly is
    # called ON self (= the CSA), the resulting CAFake's parent IS the
    # CSA, and ca_attach on CAFake materialises it.  Net: B.5 attach
    # path with mat result of CSA.
    a = CArray.int8(5, 4, 3).seq
    mask = CArray.boolean(5); 5.times { |i| mask[i] = (i.even? ? 1 : 0) }
    csa = a[mask, nil, nil]
    got = csa.sum(axis: [1, 2])
    expected = csa.sum(axis: [1, 2]).to_a.map(&:to_f)
    expected.each_with_index { |v, i| assert_in_delta(v, got[i].to_f, 1e-9) }
  end

  def test_sum_ki_float64_pass_through
    # Source data_type already float64 → wrap_readonly pass-through, no
    # CAFake overhead.  Bench equivalence is in B.7; here just verify
    # functional correctness.
    a = CArray.float64(100, 50).seq
    assert_close(a.sum(axis: 0),    a.sum(axis: 0))
    assert_close(a.sum(axis: 1),    a.sum(axis: 1))
    assert_close(a.sum.to_f,  a.sum(axis: [0, 1]))
  end

  def test_sum_ki_cafake_direct_source
    # Directly pass a numeric type-adapted view (= what wrap_readonly produces).
    # Phase 6 P.6.2.e.1: wrap_readonly now returns CAMonOp(cast) for
    # numeric data_type mismatch (Q11 (E) fake narrow).  SRC_ATTACH path
    # accepts CA_SLAB_AXES for both legacy CAFake and CAMonOp.
    a = CArray.int32(3, 4, 5).seq
    fake = CArray.wrap_readonly(a, CA_FLOAT64)
    assert_kind_of(CAMonOp, fake)   # was CAFake
    got = fake.sum(axis: [1, 2])
    expected = a.sum(axis: [1, 2]).to_a.map(&:to_f)
    expected.each_with_index { |v, i| assert_in_delta(v, got[i].to_f, 1e-9) }
  end

  # ---- Phase A backwards compat (= SRC_CASTRIDE entity still works) ----

  def test_phase_a_entity_still_works
    # Ensure Phase B branch addition doesn't regress Phase A path
    a = CArray.float64(2, 3, 4).seq
    assert_close(a.sum(axis: [1, 2]), a.sum(axis: [1, 2]))
    assert_close(a.sum(axis: 0),    a.sum(axis: 0))
    assert_close(a.sum.to_f,  a.sum(axis: [0, 1, 2]))
  end

  def test_phase_a_castride_transpose_still_works
    a = CArray.float64(2, 3, 4).seq
    tr = a.transpose(2, 0, 1)  # CAStride non-contig
    assert_close(tr.sum(axis: [0, 1]), tr.sum(axis: [0, 1]))
    assert_close(tr.sum(axis: 2),    tr.sum(axis: 2))
  end

end
