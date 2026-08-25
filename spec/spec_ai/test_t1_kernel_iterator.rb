# frozen_string_literal: true
#
# spec_ai/test_t1_kernel_iterator.rb
#
# T1 kernel_iterator MVP — Phase 1 step 1 + step 2 smoke tests.
#
# Cumulative coverage (PROPOSAL_T1_KERNEL_ITERATOR.md §10.3):
#   step 1: alias path     — entity / CAStride contig
#   step 2: scratch path   — CAStride family non-contig
#
# Smoke surface: CArray.t1_smoke(ca) returns a Hash with rc / slabs /
# total_elems / ptr_nonnull / alias_mode / data (slab bytes joined).

require "test/unit"
require_relative "../../lib/carray"

# === CARRAY_DEV_BUILD guard (auto-added by S.7) ===
# This test exercises smoke surface gated by -DCARRAY_DEV_BUILD.
# Rebuild with `CARRAY_DEV=1 rake build_ext` to enable.
unless CArray.respond_to?(:t1_smoke)
  warn "skipping #{File.basename(__FILE__)}: requires CARRAY_DEV_BUILD"
  return
end

class TestT1KernelIterator < Test::Unit::TestCase

  OK            = CArray::T1_ITER_OK
  ERR_NOT_CHEAP = CArray::T1_ITER_ERR_NOT_CHEAP
  ERR_POLICY    = CArray::T1_ITER_ERR_POLICY
  ERR_FLAGS     = CArray::T1_ITER_ERR_FLAGS
  ALIAS_CONTIG  = CArray::T1_ITER_ALIAS_CONTIG
  ALIAS_NONE    = CArray::T1_ITER_ALIAS_NONE
  ALIAS_STRIDED = CArray::T1_ITER_ALIAS_STRIDED
  ERR_READONLY  = CArray::T1_ITER_ERR_READONLY
  ERR_MASK      = CArray::T1_ITER_ERR_MASK

  # ====================================================================
  # step 1 — alias path
  # ====================================================================

  def test_entity_1d
    a = CArray.int32(10).seq
    r = CArray.t1_smoke(a)
    assert_equal OK,            r[:rc]
    assert_equal 1,             r[:slabs]
    assert_equal 10,            r[:total_elems]
    assert_equal true,          r[:ptr_nonnull]
    assert_equal ALIAS_CONTIG,  r[:alias_mode]
    assert_equal a.dump_binary, r[:data]
  end

  def test_entity_2d
    a = CArray.float64(3, 4).seq
    r = CArray.t1_smoke(a)
    assert_equal OK,            r[:rc]
    assert_equal 1,             r[:slabs]
    assert_equal 12,            r[:total_elems]
    assert_equal true,          r[:ptr_nonnull]
    assert_equal ALIAS_CONTIG,  r[:alias_mode]
    assert_equal a.dump_binary, r[:data]
  end

  def test_entity_empty
    a = CArray.int32(0)
    r = CArray.t1_smoke(a)
    assert_equal OK,            r[:rc]
    assert_equal 1,             r[:slabs]
    assert_equal 0,             r[:total_elems]
    assert_equal ALIAS_CONTIG,  r[:alias_mode]
    assert_equal "",            r[:data]
  end

  def test_castride_contig_full_view
    a = CArray.int32(2, 6).seq
    v = a.reshape(12)
    r = CArray.t1_smoke(v)
    assert_equal OK,            r[:rc]
    assert_equal ALIAS_CONTIG,  r[:alias_mode]
    assert_equal v.to_ca.dump_binary, r[:data]
  end

  def test_castride_row_slice_contig
    a = CArray.float64(5, 4).seq
    v = a[2, nil]
    r = CArray.t1_smoke(v)
    assert_equal OK,            r[:rc]
    assert_equal 4,             r[:total_elems]
    assert_equal ALIAS_CONTIG,  r[:alias_mode]
    assert_equal v.to_ca.dump_binary, r[:data]
  end

  # ====================================================================
  # step 2 — scratch path (CAStride family non-contig)
  # ====================================================================

  def test_noncontig_column_slice
    # a[nil, 1] is a column slice — non-contig in row-major.
    # ca_attach_is_alias = 0 (renamed from _is_cheap in 9.4a), but the
    # source is CAStride family, so
    # step 2 routes it to the scratch path.
    a = CArray.float64(5, 4).seq
    v = a[nil, 1]
    r = CArray.t1_smoke(v)
    assert_equal OK,           r[:rc]
    assert_equal 1,            r[:slabs]
    assert_equal 5,            r[:total_elems]
    assert_equal true,         r[:ptr_nonnull]
    assert_equal ALIAS_NONE,   r[:alias_mode]
    assert_equal v.to_ca.dump_binary, r[:data]
  end

  def test_transpose_scratch
    a = CArray.float64(3, 4).seq
    v = a.transpose
    r = CArray.t1_smoke(v)
    assert_equal OK,           r[:rc]
    assert_equal 12,           r[:total_elems]
    assert_equal ALIAS_NONE,   r[:alias_mode]
    assert_equal v.to_ca.dump_binary, r[:data]
  end

  def test_block_step2_noncontig
    # a[nil, 0..3, 1..2] — 3D non-contig pattern (drops innermost columns).
    a = CArray.int32(2, 4, 4).seq
    v = a[nil, 0..3, 1..2]
    r = CArray.t1_smoke(v)
    assert_equal OK,           r[:rc]
    assert_equal v.elements,   r[:total_elems]
    assert_equal ALIAS_NONE,   r[:alias_mode]
    assert_equal v.to_ca.dump_binary, r[:data]
  end

  def test_castride_inner_step_scratch
    # Inner-axis stride != bytes — definitively non-contig. Compose-fold
    # can collapse many seemingly non-contig chains to contig when the
    # leaf shape lines up; pinning a hand-picked stride pattern keeps
    # the scratch path covered.
    a = CArray.float64(10, 6).seq
    v = a[nil, [0..5, 2]]   # every other column, shape [10, 3], strides [48, 16]
    r = CArray.t1_smoke(v)
    assert_equal OK,           r[:rc]
    assert_equal v.elements,   r[:total_elems]
    assert_equal ALIAS_NONE,   r[:alias_mode]
    assert_equal v.to_ca.dump_binary, r[:data]
  end

  # ====================================================================
  # rejected sources — descriptor framework + overlay views
  # ====================================================================

  def test_csa_view_l1_scratch_path
    # CSA (CASelectAxis, a[bool_mask, nil]) — accepted via descriptor
    # path in sub-step 5.1.  byte parity against view.to_ca.
    a = CArray.float64(5, 4).seq
    mask = CA_BOOLEAN([true, false, true, false, true])
    v = a[mask, nil]
    assert_equal CASelectAxis, v.class
    r = CArray.t1_smoke(v)
    assert_equal OK,         r[:rc]
    assert_equal 1,          r[:slabs]
    assert_equal v.elements, r[:total_elems]
    assert_equal ALIAS_NONE, r[:alias_mode]
    assert_equal v.to_ca.dump_binary, r[:data]
  end

  def test_cagrid_view_l1_scratch_path
    # CAGrid (a[idx, nil]) — accepted via descriptor path in sub-step 5.1.
    a = CArray.int32(5, 5).seq
    idx = CA_INT([0, 2, 4])
    v = a[idx, nil]
    assert_equal CAGrid, v.class
    r = CArray.t1_smoke(v)
    assert_equal OK,         r[:rc]
    assert_equal v.elements, r[:total_elems]
    assert_equal ALIAS_NONE, r[:alias_mode]
    assert_equal v.to_ca.dump_binary, r[:data]
  end

  # ----- sub-step 5.2: remaining 4 descriptor views -----

  def test_caselect_1d_filter_l1_scratch_path
    # CASelect: 1-D boolean filter (a[mask] with 1-D mask) — accepted
    # via descriptor path in sub-step 5.2, always materialises.
    a = CArray.float64(10).seq
    v = a[a > 3]
    assert_equal CASelect, v.class
    r = CArray.t1_smoke(v)
    assert_equal OK,         r[:rc]
    assert_equal v.elements, r[:total_elems]
    assert_equal ALIAS_NONE, r[:alias_mode]
    assert_equal v.to_ca.dump_binary, r[:data]
  end

  # CAMapping was removed in R.3 (PROPOSAL_CAMAPPING_REMOVAL); a[mapper]
  # now normalises to a CAStride/CAGrid chain, each layer of which has
  # descriptor.ndim == view.ndim and is already covered by entity /
  # CAStride / CAGrid tests above.

  def test_cawindow_with_bounds_fill
    # CAWindow with fill bounds → SHIFT axes, materialise via engine.
    a = CArray.float64(5).seq
    v = a.window(-1..3, bounds: "fill")
    assert_equal CAWindow,   v.class
    r = CArray.t1_smoke(v)
    assert_equal OK,         r[:rc]
    assert_equal v.elements, r[:total_elems]
    assert_equal ALIAS_NONE, r[:alias_mode]
    assert_equal v.to_ca.dump_binary, r[:data]
  end

  def test_cashift_view_routes_via_window_func
    # CAShift is a Phase G typedef of CAWindow (ca_shift_func ==
    # ca_window_func with 3 override slots). The kernel_iterator
    # classifier routes both to DESCRIPTOR via the shared attach
    # function pointer.
    a = CArray.float64(5).seq
    v = a.shift(2)
    assert_equal CAShift,    v.class
    r = CArray.t1_smoke(v)
    assert_equal OK,         r[:rc]
    assert_equal v.elements, r[:total_elems]
    assert_equal ALIAS_NONE, r[:alias_mode]
    assert_equal v.to_ca.dump_binary, r[:data]
  end

  def test_cafake_accepted
    # Step 9: CAFake is accepted via the SRC_ATTACH path.
    # 2026-05-31 refactor: SRC_ATTACH now uses iter-owned scratch +
    # ca_xfer_all (not src.attach lifecycle) -> alias_mode = ALIAS_NONE
    # (was ALIAS_ATTACH = 3).  Comprehensive 5-view × L1/L2 ×
    # READ/WRITE matrix is exercised in sub-step 9.3; this one keeps
    # the legacy slot to pin the SRC_NONE → SRC_ATTACH flip.
    a = CArray.int32(4).seq
    v = a.fake(CA_FLOAT64)
    assert_equal CAFake,                v.class
    r = CArray.t1_smoke(v)
    assert_equal OK,                    r[:rc]
    assert_equal v.elements,            r[:total_elems]
    assert_equal ALIAS_NONE,            r[:alias_mode]
    assert_equal v.to_ca.dump_binary,   r[:data]
  end

  # ====================================================================
  # lifecycle — repeated walks don't leak
  # ====================================================================

  def test_repeated_alias_walks
    a = CArray.float64(8).seq
    20.times do
      r = CArray.t1_smoke(a)
      assert_equal OK, r[:rc]
      assert_equal 8,  r[:total_elems]
    end
  end

  def test_repeated_scratch_walks
    a = CArray.float64(8, 8).seq
    v = a.transpose
    20.times do
      r = CArray.t1_smoke(v)
      assert_equal OK,         r[:rc]
      assert_equal 64,         r[:total_elems]
      assert_equal ALIAS_NONE, r[:alias_mode]
    end
  end

  # ====================================================================
  # step 3 — L2 strided dispatch
  #
  # Smoke surface: CArray.t1_smoke_strided(ca) walks via
  # ca_iter_state_next_slab_strided.  Reconstructs slab bytes through
  # the reported (ptr, n, stride_bytes) tuples; result :data must
  # equal view.to_ca.dump_binary.
  # ====================================================================

  def test_l2_entity_1d
    a = CArray.float64(10).seq
    r = CArray.t1_smoke_strided(a)
    assert_equal OK,           r[:rc]
    assert_equal 1,            r[:slabs]
    assert_equal 10,           r[:total_elems]
    assert_equal ALIAS_CONTIG, r[:alias_mode]
    assert_equal [a.bytes],    r[:strides]
    assert_equal a.dump_binary, r[:data]
  end

  def test_l2_entity_2d_yields_per_row
    # entity 3x4 should yield 3 row slabs, each n=4, stride=bytes.
    a = CArray.int32(3, 4).seq
    r = CArray.t1_smoke_strided(a)
    assert_equal OK,           r[:rc]
    assert_equal 3,            r[:slabs]
    assert_equal 12,           r[:total_elems]
    assert_equal ALIAS_CONTIG, r[:alias_mode]
    assert_equal [4, 4, 4],    r[:strides]
    assert_equal a.dump_binary, r[:data]
  end

  def test_l2_castride_contig_yields_per_row
    # CARefer reshape — contig CAStride, treated like entity.
    a = CArray.int32(2, 6).seq
    v = a.reshape(3, 4)
    r = CArray.t1_smoke_strided(v)
    assert_equal OK,           r[:rc]
    assert_equal 3,            r[:slabs]
    assert_equal 12,           r[:total_elems]
    assert_equal ALIAS_CONTIG, r[:alias_mode]
    assert_equal v.to_ca.dump_binary, r[:data]
  end

  def test_l2_column_slice_alias_strided
    # a[nil, 1] is 1-D non-contig; one strided slab covers the whole view.
    a = CArray.float64(5, 4).seq
    v = a[nil, 1]
    r = CArray.t1_smoke_strided(v)
    assert_equal OK,            r[:rc]
    assert_equal 1,             r[:slabs]
    assert_equal 5,             r[:total_elems]
    assert_equal ALIAS_STRIDED, r[:alias_mode]
    # stride bytes = parent row stride = 4 columns * float64 = 32
    assert_equal [32],          r[:strides]
    assert_equal v.to_ca.dump_binary, r[:data]
  end

  def test_l2_transpose_yields_outer_rows
    # transpose [3,4] -> [4,3]. Engine walks outer axis 0 (count=4),
    # each yield = 3 elements with stride = parent inner stride.
    a = CArray.float64(3, 4).seq
    v = a.transpose
    r = CArray.t1_smoke_strided(v)
    assert_equal OK,            r[:rc]
    assert_equal 4,             r[:slabs]
    assert_equal 12,            r[:total_elems]
    assert_equal ALIAS_STRIDED, r[:alias_mode]
    # stride = parent row stride = 4 columns * float64 = 32
    assert_equal [32, 32, 32, 32], r[:strides]
    assert_equal v.to_ca.dump_binary, r[:data]
  end

  def test_l2_inner_step_alias_strided
    # a[nil, [0..5, 2]] — every other column, shape [10, 3].
    # Strides [48, 16]. Outer walks 10 rows, each n=3 stride=16.
    a = CArray.float64(10, 6).seq
    v = a[nil, [0..5, 2]]
    r = CArray.t1_smoke_strided(v)
    assert_equal OK,            r[:rc]
    assert_equal 10,            r[:slabs]
    assert_equal 30,            r[:total_elems]
    assert_equal ALIAS_STRIDED, r[:alias_mode]
    assert_equal Array.new(10, 16), r[:strides]
    assert_equal v.to_ca.dump_binary, r[:data]
  end

  def test_l2_3d_noncontig
    # 3D non-contig: a[nil, 0..3, 1..2]. Outer prefix walks the two
    # leading axes; each yield = inner dim count * inner stride.
    a = CArray.int32(2, 4, 4).seq
    v = a[nil, 0..3, 1..2]
    r = CArray.t1_smoke_strided(v)
    assert_equal OK,            r[:rc]
    assert_equal v.dim[0] * v.dim[1], r[:slabs]
    assert_equal v.elements,    r[:total_elems]
    assert_equal ALIAS_STRIDED, r[:alias_mode]
    assert_equal v.to_ca.dump_binary, r[:data]
  end

  def test_l2_csa_alias
    # F-2 (rev6): innermost axis is STRIDE (axis 1 full slice), outer is
    # INDEX (mask-selected rows).  L2 alias path activates: per outer-
    # selected row a strided slab is yielded with stride = bytes
    # (contig within each row).  Pre-rev6 this materialised into a
    # single flat 1-D slab; now we yield N slabs.
    a = CArray.float64(5, 4).seq
    m = CA_BOOLEAN([true, false, true, false, true])
    v = a[m, nil]
    r = CArray.t1_smoke_strided(v)
    assert_equal OK,            r[:rc]
    assert_equal 3,             r[:slabs]      # one per selected row
    assert_equal v.elements,    r[:total_elems]
    assert_equal ALIAS_STRIDED, r[:alias_mode]
    assert_equal [v.bytes] * 3, r[:strides]    # inner contig: 8 bytes/cell
    assert_equal v.to_ca.dump_binary, r[:data]
  end

  def test_l2_cagrid_alias
    # F-2 (rev6): innermost axis STRIDE (axis 1 full), outer axis INDEX
    # (explicit integer index).  L2 alias activates per selected row.
    a = CArray.int32(5, 5).seq
    idx = CA_INT([0, 2, 4])
    v = a[idx, nil]
    r = CArray.t1_smoke_strided(v)
    assert_equal OK,            r[:rc]
    assert_equal 3,             r[:slabs]      # one per selected row
    assert_equal v.elements,    r[:total_elems]
    assert_equal ALIAS_STRIDED, r[:alias_mode]
    assert_equal [v.bytes] * 3, r[:strides]    # inner contig: 4 bytes/cell
    assert_equal v.to_ca.dump_binary, r[:data]
  end

  def test_l2_caselect_materialise
    # Q3 reversal: CASelect at L2 → materialise (not reject), per
    # delivery principle.  Use non-constant-step mask so Y.6 STRIDE
    # promotion does not fire (= INDEX kind preserved, materialise path).
    a = CArray.float64(10).seq
    m = CArray.boolean(10).tap { |__a| __a[] = [0, 1, 1, 0, 1, 1, 0, 0, 1, 0] }   # indices [1,2,4,5,8]
    v = a[m]
    r = CArray.t1_smoke_strided(v)
    assert_equal OK,         r[:rc]
    assert_equal v.elements, r[:total_elems]
    assert_equal ALIAS_NONE, r[:alias_mode]
    assert_equal v.to_ca.dump_binary, r[:data]
  end

  # CAMapping L2 entry removed in R.3; chain layers (CAStride/CAGrid) are
  # exercised by test_l2_cagrid_materialise et al.

  def test_l2_cawindow_materialise
    a = CArray.float64(5).seq
    v = a.window(-1..3, bounds: "fill")
    r = CArray.t1_smoke_strided(v)
    assert_equal OK,         r[:rc]
    assert_equal v.elements, r[:total_elems]
    assert_equal ALIAS_NONE, r[:alias_mode]
    assert_equal v.to_ca.dump_binary, r[:data]
  end

  # ----- sub-step 5.4: WRITE for descriptor views -----
  #
  # sync_slab branches on src_kind; descriptor sources scatter back
  # via ca_axis_dispatch_scatter.  3 corner cases pinned per reviewer
  # advice:
  #   - CAGrid duplicate INDEX → last-write-wins (R5 spec), iteration
  #     order engine-defined (user code must not depend on it)
  #   - CAWindow FILL bound region → no parent destination, scatter
  #     skips OOB cells silently
  #   - CAShift WRAP/REFLECT bounds → map back to interior, writes
  #     do reach parent

  def test_write_csa_round_trip
    # CSA selection: writes via the kernel propagate to the parent
    # rows where the mask is true.
    a = CArray.float64(5, 4).seq
    m = CA_BOOLEAN([true, false, true, false, true])
    v = a[m, nil]
    rc = CArray.t1_smoke_write_fill_f64(v, 99.0)
    assert_equal CArray::T1_ITER_OK, rc
    assert_equal Array.new(4, 99.0), a[0, nil].to_a
    assert_equal Array.new(4, 99.0), a[2, nil].to_a
    assert_equal Array.new(4, 99.0), a[4, nil].to_a
    # rows where mask was false stay original
    assert_equal [4.0, 5.0, 6.0, 7.0],   a[1, nil].to_a
    assert_equal [12.0, 13.0, 14.0, 15.0], a[3, nil].to_a
  end

  def test_write_cagrid_round_trip
    # CAGrid: writes via the kernel propagate to parent at the
    # indexed rows.
    a = CArray.float64(5, 5).seq
    idx = CA_INT([1, 3])
    v = a[idx, nil]
    rc = CArray.t1_smoke_write_fill_f64(v, -1.0)
    assert_equal CArray::T1_ITER_OK, rc
    assert_equal Array.new(5, -1.0), a[1, nil].to_a
    assert_equal Array.new(5, -1.0), a[3, nil].to_a
    # untouched rows
    assert_equal [0.0, 1.0, 2.0, 3.0, 4.0], a[0, nil].to_a
  end

  def test_write_cagrid_duplicate_index_last_write_wins
    # R5 spec: duplicate INDEX values write the same parent cell
    # multiple times; last-write-wins under output-row-major
    # iteration.  We pin the *result* (= the value we wrote
    # corresponding to the last iteration that touched the parent
    # cell), without specifying engine iteration order.
    #
    # The kernel here writes a constant; with last-write-wins that's
    # equivalent for duplicate indices and we just check parity with
    # the view's own scatter behaviour (= existing v[] = val path).
    a = CArray.float64(5).seq
    idx = CA_INT([0, 0, 2])   # parent[0] hit twice
    v = a[idx]
    rc = CArray.t1_smoke_write_fill_f64(v, 42.0)
    assert_equal CArray::T1_ITER_OK, rc
    # all touched cells (parent[0] and parent[2]) end up with the
    # written value; non-touched cells unchanged
    assert_equal 42.0, a[0]
    assert_equal 1.0,  a[1]
    assert_equal 42.0, a[2]
    assert_equal 3.0,  a[3]
    assert_equal 4.0,  a[4]
  end

  def test_write_cawindow_fill_bound_region_does_not_propagate
    # CAWindow with FILL bounds: scratch holds the fill_value in OOB
    # slots.  Even if the kernel writes those slots, scatter skips
    # them — parent has no destination cell there.  Result: only the
    # interior of the window propagates back.
    a = CArray.float64(5).seq          # [0, 1, 2, 3, 4]
    v = a.window(-1..3, bounds: "fill")  # window covers -1..3 of parent
    # view: [fill, 0, 1, 2, 3]  (index 0 is OOB at -1)
    rc = CArray.t1_smoke_write_fill_f64(v, 99.0)
    assert_equal CArray::T1_ITER_OK, rc
    # interior of the window (parent indices 0..3) get 99; parent[4]
    # was never in the window and stays original
    assert_equal [99.0, 99.0, 99.0, 99.0, 4.0], a.to_a
  end

  def test_write_cashift_round_trip
    # CAShift basic (default FILL): writes through the in-bounds
    # region propagate; OOB region is dropped at scatter.
    a = CArray.float64(5).seq        # [0, 1, 2, 3, 4]
    v = a.shift(2)                   # view: [fill, fill, 0, 1, 2]
    rc = CArray.t1_smoke_write_fill_f64(v, 7.0)
    assert_equal CArray::T1_ITER_OK, rc
    # the 3 in-bounds positions of the view map to parent[0..2];
    # parent[3..4] were OOB in the shifted view, untouched.
    assert_equal [7.0, 7.0, 7.0, 3.0, 4.0], a.to_a
  end

  def test_l2_cashift_materialise
    a = CArray.float64(5).seq
    v = a.shift(2)
    r = CArray.t1_smoke_strided(v)
    assert_equal OK,         r[:rc]
    assert_equal v.elements, r[:total_elems]
    assert_equal ALIAS_NONE, r[:alias_mode]
    assert_equal v.to_ca.dump_binary, r[:data]
  end

  def test_l2_cafake_accepted
    # Step 9 L2: CAFake yields a 1-D L2 strided slab via SRC_ATTACH
    # (stride = bytes after view's attach materialisation).
    a = CArray.int32(4).seq
    v = a.fake(CA_FLOAT64)
    r = CArray.t1_smoke_strided(v)
    assert_equal OK,                  r[:rc]
    assert_equal v.elements,          r[:total_elems]
    assert_equal v.to_ca.dump_binary, r[:data]
  end

  def test_l2_repeated_walks_balance
    # attach/detach balance — large entity + non-contig view, many
    # iterations, no leak.
    a = CArray.float64(64, 64).seq
    v = a.transpose
    20.times do
      r = CArray.t1_smoke_strided(v)
      assert_equal OK,            r[:rc]
      assert_equal 64,            r[:slabs]
      assert_equal ALIAS_STRIDED, r[:alias_mode]
    end
  end

  # ====================================================================
  # step 4 — WRITE path
  #
  # See devel/PROPOSAL_T1_WRITE_SEMANTICS.md.
  #   (a) alias path uses direct write (case A), sync_slab no-op
  #   (b) scratch path scatters back via ca_sync_data in sync_slab
  #   (c) kernel raise leaves alias path partially-written, scratch
  #       path unchanged (sync_slab boundary)
  #
  # Smoke entries:
  #   - t1_smoke_write_fill_f64(ca, val)             — L1 in-place fill
  #   - t1_smoke_write_partial_raise_f64(ca, val, k) — fills 0..k-1 then raises
  #   - t1_smoke_sort_row_f64(ca)                    — L2 per-row qsort
  # ====================================================================

  def test_write_l1_alias_entity_fill
    # entity contig: alias direct write, parent reflects immediately.
    a = CArray.float64(10).seq
    rc = CArray.t1_smoke_write_fill_f64(a, 42.0)
    assert_equal CArray::T1_ITER_OK, rc
    assert_equal Array.new(10, 42.0), a.to_a
  end

  def test_write_l1_alias_contig_castride_fill
    # reshape → contig CAStride → alias direct write.
    a = CArray.float64(2, 6).seq
    v = a.reshape(12)
    rc = CArray.t1_smoke_write_fill_f64(v, 7.0)
    assert_equal CArray::T1_ITER_OK, rc
    assert_equal Array.new(12, 7.0), v.to_a
    # parent shape unchanged but values reflect the alias write.
    assert_equal Array.new(12, 7.0), a.reshape(12).to_a
  end

  def test_write_l1_scratch_column_slice_scatter_back
    # column slice → scratch path. After the kernel writes scratch,
    # sync_slab scatters back into the parent column.
    a = CArray.float64(5, 4).seq
    v = a[nil, 1]
    rc = CArray.t1_smoke_write_fill_f64(v, 99.0)
    assert_equal CArray::T1_ITER_OK, rc
    assert_equal Array.new(5, 99.0), a[nil, 1].to_a
    # the other columns must be untouched
    assert_equal [0, 2, 3], a[0, nil].to_a.values_at(0, 2, 3).map(&:to_i)
  end

  def test_write_l1_scratch_3d_noncontig_scatter_back
    a = CArray.float64(2, 4, 4).seq
    v = a[nil, 0..3, 1..2]
    rc = CArray.t1_smoke_write_fill_f64(v, -1.0)
    assert_equal CArray::T1_ITER_OK, rc
    assert_equal Array.new(v.elements, -1.0), v.to_a.flatten
    # innermost columns 0 / 3 untouched at one sample row
    assert_in_delta a[0, 0, 0],  0.0, 0.0
    assert_in_delta a[0, 0, 3],  3.0, 0.0
  end

  def test_write_l2_sort_per_row
    a = CArray.float64(3, 4).seq
    a[0, nil] = CA_DOUBLE([3.0, 1.0, 4.0, 1.5])
    a[1, nil] = CA_DOUBLE([9.0, 2.0, 6.0, 5.0])
    a[2, nil] = CA_DOUBLE([8.0, 7.0, 1.0, 3.0])
    rc = CArray.t1_smoke_sort_row_f64(a)
    assert_equal CArray::T1_ITER_OK, rc
    assert_equal [1.0, 1.5, 3.0, 4.0], a[0, nil].to_a
    assert_equal [2.0, 5.0, 6.0, 9.0], a[1, nil].to_a
    assert_equal [1.0, 3.0, 7.0, 8.0], a[2, nil].to_a
  end

  def test_write_l2_sort_transposed
    # L2 dispatch on a transposed view exercises the strided WRITE
    # back through the same composed_strides path.  We sort the
    # transposed view per-row (= a column of the original).
    a = CArray.float64(4, 3).seq
    a[0, nil] = CA_DOUBLE([3.0, 9.0, 8.0])
    a[1, nil] = CA_DOUBLE([1.0, 2.0, 7.0])
    a[2, nil] = CA_DOUBLE([4.0, 6.0, 1.0])
    a[3, nil] = CA_DOUBLE([1.5, 5.0, 3.0])
    v = a.transpose   # shape [3, 4]
    rc = CArray.t1_smoke_sort_row_f64(v)
    assert_equal CArray::T1_ITER_OK, rc
    # each "row" of v is a column of a — those columns should be
    # individually sorted now.
    assert_equal [1.0, 1.5, 3.0, 4.0], a[nil, 0].to_a
    assert_equal [2.0, 5.0, 6.0, 9.0], a[nil, 1].to_a
    assert_equal [1.0, 3.0, 7.0, 8.0], a[nil, 2].to_a
  end

  # ----- exception safety (proposal §(c)) -----

  def test_write_l1_alias_partial_write_on_raise
    # alias path: writes prior to the raise are visible in parent
    # (partially-written semantics, case A direct write).
    a = CArray.float64(10).seq
    assert_raise(RuntimeError) {
      CArray.t1_smoke_write_partial_raise_f64(a, 999.0, 5)
    }
    # entries 0..4 written; 5..9 keep original .seq values.
    assert_equal [999.0, 999.0, 999.0, 999.0, 999.0,
                  5.0,   6.0,   7.0,   8.0,   9.0], a.to_a
  end

  def test_write_l1_scratch_unchanged_on_raise_before_sync
    # scratch path: writes happen on scratch only; sync_slab is never
    # called when the kernel raises mid-walk, so parent is unchanged.
    a = CArray.float64(5, 4).seq
    snapshot = a[nil, 1].to_a
    v = a[nil, 1]
    assert_raise(RuntimeError) {
      CArray.t1_smoke_write_partial_raise_f64(v, 999.0, 3)
    }
    # parent column 1 is unchanged because sync_slab was skipped.
    assert_equal snapshot, a[nil, 1].to_a
  end

  # ----- gate rejections -----

  def test_write_readonly_carepeat_rejected
    # CARepeat (stride-0 axis) is marked read-only at construction —
    # writing through a stride-0 element would aliassing-write every
    # repeated entry, which is undefined.  The iterator rejects WRITE
    # with ERR_READONLY before any kernel runs.
    a = CArray.float64(5).seq
    v = a[:%, 3]   # CARepeat, shape [3, 5], stride [0, 8]
    assert v.read_only?, "CARepeat should be read_only?"
    rc = CArray.t1_smoke_write_fill_f64(v, 0.0)
    assert_equal ERR_READONLY, rc
    # original entity must remain untouched
    assert_equal [0.0, 1.0, 2.0, 3.0, 4.0], a.to_a
  end

  def test_write_masked_source_accepted_step6
    # Step 6 lifted the step-4 mask reject (default-borne mask per
    # bakeoff #5).  Without iter-level mask skip yet, the smoke
    # fill kernel still writes through to all cells (mask is
    # informational); behaviour we pin here is just that the iter
    # accepts and returns OK without crashing.
    m = CArray.float64(5).seq
    m.mask = CA_BOOLEAN([false, true, false, true, false])
    rc = CArray.t1_smoke_write_fill_f64(m, 0.0)
    assert_equal CArray::T1_ITER_OK, rc
  end

  def test_read_masked_source_accepted_step6
    # READ also accepts masked source now.  Byte parity holds (engine
    # gathers raw value bytes, mask is delivered alongside but the
    # smoke's :data path concatenates value bytes only).
    m = CArray.float64(5).seq
    m.mask = CA_BOOLEAN([false, true, false, true, false])
    r = CArray.t1_smoke(m)
    assert_equal CArray::T1_ITER_OK, r[:rc]
    assert_equal m.dump_binary, r[:data]
  end

  # ----- step 6: mask delivery to kernel -----

  def test_step6_unmasked_source_mask_ptr_is_null
    # No mask on source → out_mask is NULL at next_slab (proposal §3.2
    # contract).  Smoke records this as mask_seen = false.
    a = CArray.float64(5).seq
    r = CArray.t1_smoke_with_mask(a)
    assert_equal CArray::T1_ITER_OK, r[:rc]
    assert_equal false, r[:mask_seen]
    assert_equal 0,     r[:mask_bytes].bytesize
  end

  def test_step6_masked_entity_delivers_mask_to_kernel
    # mask is gathered into the scratch_mask buffer (step 6 baseline
    # = uniform scratch path) and surfaced through out_mask.  The
    # bytes must match parent.mask.
    a = CArray.float64(5).seq
    a.mask = CA_BOOLEAN([false, true, false, true, false])
    r = CArray.t1_smoke_with_mask(a)
    assert_equal CArray::T1_ITER_OK, r[:rc]
    assert_equal true, r[:mask_seen]
    assert_equal [0, 1, 0, 1, 0], r[:mask_bytes].bytes
  end

  def test_step6_masked_castride_view_delivers_mask
    # Masked CAStride (column slice of a masked parent).  Mask
    # propagates through ca_copy_data which uses the view's own
    # mask-aware gather.
    a = CArray.float64(5, 4).seq
    a.mask = CA_BOOLEAN(Array.new(20) { |i| i % 3 == 0 ? 1 : 0 })
    v = a[nil, 1]   # column slice, CAStride non-contig
    r = CArray.t1_smoke_with_mask(v)
    assert_equal CArray::T1_ITER_OK, r[:rc]
    assert_equal true, r[:mask_seen]
    # mask bytes should match v.mask.to_a
    assert_equal v.mask.to_type(:int8).to_a.flatten, r[:mask_bytes].bytes
  end

  def test_step6_masked_descriptor_csa_delivers_mask
    # Masked CSA (CASelectAxis).  Mask propagates via descriptor
    # framework's mask handling in ca_copy_data.
    a = CArray.float64(5, 4).seq
    a.mask = CA_BOOLEAN(Array.new(20) { |i| i.even? ? 1 : 0 })
    sel = CA_BOOLEAN([true, false, true, false, true])
    v = a[sel, nil]   # CSA
    r = CArray.t1_smoke_with_mask(v)
    assert_equal CArray::T1_ITER_OK, r[:rc]
    assert_equal true, r[:mask_seen]
    assert_equal v.mask.to_type(:int8).to_a.flatten, r[:mask_bytes].bytes
  end

  def test_step6_no_mask_flag_accepted
    # CA_KERNEL_NO_MASK flag is accepted by validate_inputs since
    # step 6 (was rejected as unsupported in step 4-5).  Enforcement
    # (= reject masked source IF NO_MASK is set) lands in step 7.
    # Verified here only via the t1_smoke entry which uses flags=0,
    # so we just confirm a quick build + masked source path keeps
    # working — direct flag test will come with step 7's smoke entry.
    a = CArray.float64(5).seq
    a.mask = CA_BOOLEAN([false, true, false, true, false])
    r = CArray.t1_smoke(a)
    assert_equal CArray::T1_ITER_OK, r[:rc]
  end

  # ====================================================================
  # step 7 — CA_KERNEL_NO_MASK flag enforcement (proposal §6.3)
  # ====================================================================

  NO_MASK            = CArray::T1_KERNEL_NO_MASK
  ERR_MASK_NOT_ALLOWED = CArray::T1_ITER_ERR_MASK_NOT_ALLOWED

  def test_step7_no_mask_flag_accepts_unmasked
    # NO_MASK flag + source without mask → accept.  This is the
    # primary "kernel says I only handle unmasked, source agrees"
    # contract.
    a = CArray.float64(5).seq
    rc = CArray.t1_smoke_init_rc(a, NO_MASK)
    assert_equal CArray::T1_ITER_OK, rc
  end

  def test_step7_no_mask_flag_rejects_masked
    # NO_MASK flag + source with mask → ERR_MASK_NOT_ALLOWED.  The
    # kernel declared it cannot handle mask, so the iter refuses
    # rather than delivering an unsafe value stream.
    a = CArray.float64(5).seq
    a.mask = CA_BOOLEAN([false, true, false, true, false])
    rc = CArray.t1_smoke_init_rc(a, NO_MASK)
    assert_equal ERR_MASK_NOT_ALLOWED, rc
  end

  def test_step7_no_flag_masked_still_accepted
    # No NO_MASK flag + masked source → accept (step 6 behaviour
    # unchanged).  The default-borne mask path stays available when
    # the kernel doesn't opt out.
    a = CArray.float64(5).seq
    a.mask = CA_BOOLEAN([false, true, false, true, false])
    rc = CArray.t1_smoke_init_rc(a, 0)
    assert_equal CArray::T1_ITER_OK, rc
  end

  def test_step7_no_flag_unmasked_accepted
    # Sanity: flags = 0 + no mask = the original step 1 path,
    # still works.
    a = CArray.float64(5).seq
    rc = CArray.t1_smoke_init_rc(a, 0)
    assert_equal CArray::T1_ITER_OK, rc
  end

  def test_step6_mask_macro_count_unmasked
    # Smoke-test the CA_COUNT_UNMASKED macro via a C extension shim
    # isn't worth wiring up; we instead pin the equivalent Ruby
    # observation (= the same kernel-author skip logic) by checking
    # that the smoke's mask_bytes contains the expected number of
    # 1-bits (= masked count) so a kernel using CA_FOR_EACH_UNMASKED
    # would skip them.
    a = CArray.float64(10).seq
    a.mask = CA_BOOLEAN([1, 0, 1, 0, 1, 0, 1, 0, 1, 0])
    r = CArray.t1_smoke_with_mask(a)
    masked_count = r[:mask_bytes].bytes.count(1)
    unmasked_count = r[:mask_bytes].bytes.count(0)
    assert_equal 5, masked_count
    assert_equal 5, unmasked_count
  end

  # ----- hand-written strided sum kernel for parity vs sum(axis=1) -----
  #
  # The user-side equivalent of an L2 kernel: walk yielded (ptr, n,
  # stride_bytes) tuples and accumulate.  We can't run a C kernel
  # from Ruby directly, but t1_smoke_strided's :data emission is the
  # same loop a C kernel would do; the parity assertion is exactly
  # the binary-identical check the spec asks for.
  #
  # For the explicit "sum kernel" parity, compute Σ from the
  # reconstructed bytes and compare with view.sum(axis: 0) etc.
  def test_l2_strided_sum_kernel_parity_vs_axis_reduction
    # 1000-element transposed view, compare to axis=1 sum on the
    # entity (axis=1 of [3, 1000] = row-major contig reduction, used as
    # a reference for what the kernel-equivalent total is).
    a = CArray.float64(3, 1000).seq
    v = a.transpose  # shape [1000, 3], stride [8, 8000]

    # Reconstruct elements via t1_smoke_strided and sum them.
    r = CArray.t1_smoke_strided(v)
    assert_equal OK, r[:rc]
    # data is concatenated slab elements (n=3 per slab, 1000 slabs)
    # interpreted as float64.
    reconstructed = r[:data].unpack("d*")
    assert_equal v.elements, reconstructed.size

    # The sum of all elements through the kernel iter should match
    # the sum of the entity (every element visited exactly once).
    assert_in_delta a.sum, reconstructed.sum, 1e-9
  end

end
