# frozen_string_literal: true
#
# spec_ai/test_caembedded_descriptor.rb
#
# Unit tests for the CAWindow / CAShift embed descriptor, computed by
# ca_compute_embed_descriptor (ext/ca_obj_window.c) at setup time and read
# back through the `CAWindow#_embed_descriptor` debug accessor.
#
# Worth pinning because nothing else observes this geometry: attach / sync /
# xfer take the embed path from these fields, so a wrong descriptor moves the
# wrong parent rectangle and returns wrong data rather than raising.

require "test/unit"
require_relative "../../lib/carray"

# === CARRAY_DEV_BUILD guard ===
# `_embed_descriptor` is a debug accessor gated by -DCARRAY_DEV_BUILD.
# Rebuild with `CARRAY_DEV=1 rake build_ext` to enable.
unless CAWindow.method_defined?(:_embed_descriptor)
  warn "skipping #{File.basename(__FILE__)}: requires CARRAY_DEV_BUILD"
  return
end

class TestCAEmbeddedDescriptor < Test::Unit::TestCase

  # ------------------------------------------------------------------
  # 1D — CAWindow via a.window(range, bounds: "fill", fill_value: 0)
  # ------------------------------------------------------------------

  def test_1d_interior_only
    # parent 10, window [2..7] = start=2, count=6 — fully inside parent
    a = CArray.int(10).seq
    v = a.window(2..7, bounds: "fill", fill_value: 0)
    d = v._embed_descriptor
    assert_equal [2], d[:parent_start]
    assert_equal [6], d[:count]
    assert_equal [0], d[:output_offset]
    assert_equal false, d[:is_empty]
    assert_equal true,  d[:covers_all]
  end

  def test_1d_extends_high
    # parent 10, window [5..12] = start=5, count=8 — last 3 cells OOB
    a = CArray.int(10).seq
    v = a.window(5..12, bounds: "fill", fill_value: 0)
    d = v._embed_descriptor
    assert_equal [5], d[:parent_start]
    assert_equal [5], d[:count]        # parent cells 5..9
    assert_equal [0], d[:output_offset]
    assert_equal false, d[:is_empty]
    assert_equal false, d[:covers_all]
  end

  def test_1d_extends_low_via_shift
    # CAShift(1) = window(-1..parent.dim-2) — leading cell OOB
    a = CArray.int(5).seq
    v = a.shift(1)                      # start=-1, count=5
    d = v._embed_descriptor
    assert_equal [0], d[:parent_start]
    assert_equal [4], d[:count]         # parent cells 0..3
    assert_equal [1], d[:output_offset] # output cell 0 is fill, alias starts at 1
    assert_equal false, d[:is_empty]
    assert_equal false, d[:covers_all]
  end

  def test_1d_extends_low_negative_shift
    # CAShift(-1) = window(1..parent.dim) — trailing cell OOB
    a = CArray.int(5).seq
    v = a.shift(-1)                     # start=1, count=5
    d = v._embed_descriptor
    assert_equal [1], d[:parent_start]
    assert_equal [4], d[:count]         # parent cells 1..4
    assert_equal [0], d[:output_offset] # alias starts at output 0
    assert_equal false, d[:is_empty]
    assert_equal false, d[:covers_all]
  end

  def test_1d_fully_outside_positive_shift
    # CAShift(100) on parent.dim=5 — entire output is fill
    a = CArray.int(5).seq
    v = a.shift(100)                    # start=-100, count=5
    d = v._embed_descriptor
    assert_equal [0], d[:parent_start]
    assert_equal [0], d[:count]
    assert_equal true,  d[:is_empty]
    assert_equal false, d[:covers_all]
  end

  def test_1d_fully_outside_negative_shift
    a = CArray.int(5).seq
    v = a.shift(-100)                   # start=100, count=5
    d = v._embed_descriptor
    assert_equal [0], d[:count]
    assert_equal true,  d[:is_empty]
    assert_equal false, d[:covers_all]
  end

  def test_1d_zero_shift_equals_interior
    a = CArray.int(5).seq
    v = a.shift(0)                      # start=0, count=5
    d = v._embed_descriptor
    assert_equal [0], d[:parent_start]
    assert_equal [5], d[:count]
    assert_equal [0], d[:output_offset]
    assert_equal false, d[:is_empty]
    assert_equal true,  d[:covers_all]
  end

  # ------------------------------------------------------------------
  # 2D — both axes
  # ------------------------------------------------------------------

  def test_2d_interior_both_axes
    a = CArray.int(5, 6).seq
    v = a.window(1..3, 2..4, bounds: "fill", fill_value: 0)
    d = v._embed_descriptor
    assert_equal [1, 2], d[:parent_start]
    assert_equal [3, 3], d[:count]
    assert_equal [0, 0], d[:output_offset]
    assert_equal false, d[:is_empty]
    assert_equal true,  d[:covers_all]
  end

  def test_2d_axis0_extends
    # axis-0 OOB, axis-1 interior
    a = CArray.int(5, 6).seq
    v = a.shift(2, 0, fill_value: 0)    # axis-0 start=-2, axis-1 start=0
    d = v._embed_descriptor
    assert_equal [0, 0], d[:parent_start]
    assert_equal [3, 6], d[:count]
    assert_equal [2, 0], d[:output_offset]
    assert_equal false, d[:is_empty]
    assert_equal false, d[:covers_all]
  end

  def test_2d_axis1_extends
    a = CArray.int(5, 6).seq
    v = a.shift(0, 2, fill_value: 0)    # axis-0 start=0, axis-1 start=-2
    d = v._embed_descriptor
    assert_equal [0, 0], d[:parent_start]
    assert_equal [5, 4], d[:count]
    assert_equal [0, 2], d[:output_offset]
    assert_equal false, d[:is_empty]
    assert_equal false, d[:covers_all]
  end

  def test_2d_both_extend
    a = CArray.int(5, 6).seq
    v = a.shift(1, 1, fill_value: 0)    # start=(-1,-1), count=(5,6)
    d = v._embed_descriptor
    assert_equal [0, 0], d[:parent_start]
    assert_equal [4, 5], d[:count]
    assert_equal [1, 1], d[:output_offset]
    assert_equal false, d[:is_empty]
    assert_equal false, d[:covers_all]
  end

  def test_2d_one_axis_fully_outside
    # axis-0 fully OOB → whole view is_empty regardless of axis-1
    a = CArray.int(5, 6).seq
    v = a.shift(100, 0, fill_value: 0)
    d = v._embed_descriptor
    assert_equal [0, 6], d[:count]      # axis-0 alias = 0, axis-1 = full
    assert_equal true,  d[:is_empty]
    assert_equal false, d[:covers_all]
  end

  # ------------------------------------------------------------------
  # MASK policy — same descriptor as FILL (policy decides fill content,
  # not which cells are in the alias).
  # ------------------------------------------------------------------

  def test_mask_policy_yields_same_descriptor_as_fill
    a = CArray.int(5).seq
    v_fill = a.shift(1, fill_value: 0)  # start=-1, count=5, bounds=FILL
    v_mask = a.shift(1, fill_value: UNDEF)       # start=-1, count=5, bounds=MASK
    d_fill = v_fill._embed_descriptor
    d_mask = v_mask._embed_descriptor
    assert_equal d_fill[:parent_start],  d_mask[:parent_start]
    assert_equal d_fill[:count],         d_mask[:count]
    assert_equal d_fill[:output_offset], d_mask[:output_offset]
    assert_equal d_fill[:is_empty],      d_mask[:is_empty]
    assert_equal d_fill[:covers_all],    d_mask[:covers_all]
  end

  # ------------------------------------------------------------------
  # Descriptor immutability across view lifetime
  # ------------------------------------------------------------------

  def test_descriptor_stable_after_materialise
    a = CArray.int(10).seq
    v = a.shift(2, fill_value: 0)
    d_before = v._embed_descriptor
    v.to_ca                              # trigger attach + materialise
    d_after = v._embed_descriptor
    assert_equal d_before, d_after
  end

  # ------------------------------------------------------------------
  # E.3: embed_eligible — which views take the embed fast path
  # ------------------------------------------------------------------

  def test_eligible_fill_bounds
    a = CArray.int(10).seq
    v = a.window(0..9, bounds: "fill", fill_value: 0)
    assert_equal true, v._embed_descriptor[:eligible]
  end

  def test_eligible_mask_bounds
    a = CArray.int(10).seq
    v = a.shift(1, fill_value: UNDEF)
    assert_equal true, v._embed_descriptor[:eligible]
  end

  # Phase 2 T.6 (2026-05-26): bounds=>'periodic' / 'reflect' and :roll
  # option removed (bounds zoo prune §3.0).  The embed_eligible flag for
  # those bound types is no longer testable through the public API;
  # NEAREST / STRICT remain.  These tests now verify that the removed
  # surfaces raise ArgumentError instead of producing a CAWindow.
  def test_periodic_bounds_removed_raises
    a = CArray.int(10).seq
    assert_raise(ArgumentError) { a.window(0..9, bounds: "periodic") }
  end

  def test_reflect_bounds_removed_raises
    a = CArray.int(10).seq
    assert_raise(ArgumentError) { a.window(0..9, bounds: "reflect") }
  end

  def test_mixed_roll_option_removed_raises
    a = CArray.int(5, 6).seq
    assert_raise(ArgumentError) {
      a.shift(1, 1, roll: [1, 0], fill_value: 0)
    }
  end

  # ------------------------------------------------------------------
  # E.3: embed fast path byte parity — to_ca via embed path produces
  # the same bytes as the legacy engine path.
  # ------------------------------------------------------------------
  #
  # We cannot directly compare against the engine path (the dispatch is
  # internal), but we can pin against hand-computed expected values
  # that the bound_aware_views suite already covers.  These tests are
  # additional safety net for the new path specifically.

  def test_embed_path_byte_parity_1d_shift_positive
    a = CArray.int(5).seq                # [0,1,2,3,4]
    v = a.shift(2, fill_value: 99)       # alias=[0,1,2], output=[fill,fill,0,1,2]
    assert_equal [99, 99, 0, 1, 2], v.to_a
  end

  def test_embed_path_byte_parity_1d_shift_negative
    a = CArray.int(5).seq
    v = a.shift(-2, fill_value: 99)      # alias=[2,3,4], output=[2,3,4,fill,fill]
    assert_equal [2, 3, 4, 99, 99], v.to_a
  end

  def test_embed_path_byte_parity_2d_axis0_shift
    a = CArray.int(3, 3).seq
    # parent rows: [0,1,2],[3,4,5],[6,7,8]
    v = a.shift(1, 0, fill_value: 99)    # axis-0 shift by 1, axis-1 zero
    # output row 0 = fill row, rows 1-2 = parent rows 0-1
    expected = [[99, 99, 99], [0, 1, 2], [3, 4, 5]]
    assert_equal expected, v.to_a
  end

  def test_embed_path_byte_parity_2d_axis1_shift
    a = CArray.int(3, 3).seq
    v = a.shift(0, 1, fill_value: 99)    # axis-0 zero, axis-1 shift by 1
    expected = [[99, 0, 1], [99, 3, 4], [99, 6, 7]]
    assert_equal expected, v.to_a
  end

  def test_embed_path_byte_parity_2d_both_axes_shift
    a = CArray.int(3, 3).seq
    v = a.shift(1, 1, fill_value: 99)
    # alias rect: parent[0..1, 0..1] = [[0,1],[3,4]]
    # output rect at (1,1): output = [[99,99,99],[99,0,1],[99,3,4]]
    expected = [[99, 99, 99], [99, 0, 1], [99, 3, 4]]
    assert_equal expected, v.to_a
  end

  def test_embed_path_fully_outside
    a = CArray.int(5).seq
    v = a.shift(10, fill_value: 99)      # entire output is fill
    assert_equal [99, 99, 99, 99, 99], v.to_a
  end

  def test_embed_path_interior_only
    a = CArray.int(10).seq
    v = a.window(2..7, bounds: "fill", fill_value: 99)  # covers_all path
    assert_equal [2, 3, 4, 5, 6, 7], v.to_a
  end

  def test_embed_path_float64
    a = CArray.float64(5).seq * 1.5      # [0.0, 1.5, 3.0, 4.5, 6.0]
    v = a.shift(1, fill_value: -1.0)
    assert_equal [-1.0, 0.0, 1.5, 3.0, 4.5], v.to_a
  end

  def test_embed_path_mask_undef
    a = CArray.int(5).seq
    v = a.shift(2, fill_value: UNDEF)
    assert v.has_mask?
    assert_equal [true, true, false, false, false], v.is_masked.to_a
  end

  # ------------------------------------------------------------------
  # Phase 2 T.6 (2026-05-26): PERIODIC engine fallback path is no longer
  # reachable from user code (bounds zoo prune §3.0).  The engine code
  # itself is retained (= dead path) but the Ruby surface raises.
  # Equivalent functionality is now CArray#roll (returns CARoll view,
  # tested in spec_ai/test_caroll.rb).
  # ------------------------------------------------------------------

  # ------------------------------------------------------------------
  # E.4: sync path (write-back) — alias region writes through to parent,
  # fill region writes are dropped (matches existing CAWindow semantics).
  # ------------------------------------------------------------------

  def test_sync_writes_alias_region_to_parent
    # 1D shift: writing to in-range cells of the view propagates to parent.
    a = CArray.int(5).seq                   # [0,1,2,3,4]
    v = a.window(1..3, bounds: "fill", fill_value: 0)
    v[] = CArray.int(3).tap { |__a| __a[] = [100, 200, 300] }
    assert_equal [0, 100, 200, 300, 4], a.to_a
  end

  def test_sync_fill_region_writes_are_dropped
    # Writing to the fill region of a shift view: those writes don't
    # reach parent (since the fill region maps nowhere in parent).
    a = CArray.int(5).seq                   # [0,1,2,3,4]
    v = a.shift(2, fill_value: 0)           # alias[0..2]=a[0..2], output=[0,0,0,1,2]
    # Write all view cells. view[0..1] is fill region (OOB), view[2..4] is alias.
    v[] = CArray.int(5).tap { |__a| __a[] = [10, 20, 30, 40, 50] }
    # Only alias cells (= view[2..4] -> a[0..2]) propagate.
    assert_equal [30, 40, 50, 3, 4], a.to_a
  end

  def test_sync_2d_axis0_shift_writes
    a = CArray.int(3, 3).seq                # rows: [0,1,2],[3,4,5],[6,7,8]
    v = a.shift(1, 0, fill_value: 0)        # axis-0 shift, view = [[0,0,0],[0,1,2],[3,4,5]]
    # Write the whole view; row 0 of view is fill (no parent backing),
    # rows 1-2 alias parent rows 0-1.
    v[] = CArray.int(3, 3).tap { |__a| __a[] = [[100, 101, 102], [200, 201, 202], [300, 301, 302]] }
    # parent rows 0-1 receive view rows 1-2; parent row 2 unchanged.
    expected = [[200, 201, 202], [300, 301, 302], [6, 7, 8]]
    assert_equal expected, a.to_a
  end

  def test_sync_fully_outside_no_parent_effect
    # If embed_is_empty: writing the entire view should leave parent untouched.
    a = CArray.int(5).seq
    original = a.to_a
    v = a.shift(100, fill_value: 0)         # all fill
    v[] = CArray.int(5).tap { |__a| __a[] = [10, 20, 30, 40, 50] }
    assert_equal original, a.to_a
  end

  def test_sync_round_trip_attach_modify_sync
    # Materialise, modify, sync_data back via to_ca then assignment is
    # implicit; explicit attach! testing the round-trip.
    a = CArray.int(10).seq
    v = a.shift(2, fill_value: 0)
    v.attach! do |inner|
      # inner is materialised view; modifying it triggers sync on close.
      # Multiply each cell by 10.  Only alias cells (view[2..9] = a[0..7])
      # propagate back to parent.
      inner[] = inner * 10
    end
    # Expected: a[0..7] = original * 10, a[8..9] unchanged
    assert_equal [0, 10, 20, 30, 40, 50, 60, 70, 8, 9], a.to_a
  end

  # ------------------------------------------------------------------
  # E.4: mask path via embed — masked cells appear in view.is_masked,
  # and the mask sub-CAWindow itself takes the embed fast path.
  # ------------------------------------------------------------------

  def test_mask_sub_window_is_embed_eligible
    # The mask CAWindow constructed by ca_window_func_create_mask
    # should inherit embed_eligible (= 1) since its bounds are FILL.
    a = CArray.int(5).seq
    v = a.shift(2, fill_value: UNDEF)
    m = v.mask                              # CAShiftMask < CAWindow
    assert_kind_of CAWindow, m
    d = m._embed_descriptor
    assert_equal true, d[:eligible]
  end

  def test_mask_propagates_through_embed_2d
    a = CArray.int(3, 3).seq
    v = a.shift(1, 0, fill_value: UNDEF)             # axis-0 shift, row 0 is masked
    assert v.has_mask?
    expected = [[true, true, true], [false, false, false], [false, false, false]]
    assert_equal expected, v.is_masked.to_a
  end

  def test_mask_fully_outside_view_all_masked
    a = CArray.int(5).seq
    v = a.shift(100, fill_value: UNDEF)              # fully OOB
    assert_equal [true, true, true, true, true], v.is_masked.to_a
  end

  # ------------------------------------------------------------------
  # Phase 1.5 (B-path, E.8): CAStride compose-fold walks through
  # interior-only CAWindow.  CAStride children wrapping such a CAWindow
  # bypass the CAWindow materialise entirely.
  # ------------------------------------------------------------------

  def test_phase15_compose_fold_read_2d_interior
    # a -> w (interior) -> s (CABlock slice).  Read via s should return
    # parent values without window materialise.
    a = CArray.int32(5, 5).seq
    w = a.window(1..3, 1..3, bounds: "fill", fill_value: 0)
    s = w[0..1, 0..1]
    # s should reflect a[1..2, 1..2]
    assert_equal [[6, 7], [11, 12]], s.to_a
  end

  def test_phase15_compose_fold_write_2d_interior
    # Write through s; with (B) compose-fold, writes go directly to a.
    a = CArray.int32(5, 5).seq
    w = a.window(1..3, 1..3, bounds: "fill", fill_value: 0)
    s = w[0..1, 0..1]
    s[] = CArray.int32(2, 2) { 999 }
    # a should observe writes at [1..2, 1..2]
    expected = [
      [  0,   1,   2,   3,   4],
      [  5, 999, 999,   8,   9],
      [ 10, 999, 999,  13,  14],
      [ 15,  16,  17,  18,  19],
      [ 20,  21,  22,  23,  24],
    ]
    assert_equal expected, a.to_a
  end

  def test_phase15_compose_fold_1d_chain
    # 1D: a -> w (1D interior) -> s (slice).  Should also fold through.
    a = CArray.int32(10).seq
    w = a.window(2..7, bounds: "fill", fill_value: 0)  # interior 6 elements
    s = w[1..3]                                         # 3 elements
    assert_equal [3, 4, 5], s.to_a    # = a[3..5]
    s[] = CArray.int32(3) { 999 }
    assert_equal [0, 1, 2, 999, 999, 999, 6, 7, 8, 9], a.to_a
  end

  def test_phase15_compose_fold_full_extent_of_window
    # s takes the full extent of an interior-only w.  No alias even
    # though leaf is "full" of w, because w is not contig in a.
    a = CArray.int32(5, 5).seq
    w = a.window(1..3, 1..3, bounds: "fill", fill_value: 0)
    s = w[nil, nil]                                     # full of w
    expected = [[6, 7, 8], [11, 12, 13], [16, 17, 18]]
    assert_equal expected, s.to_a
  end

  def test_phase15_compose_fold_axis0_only_window
    # Axis-0 only window (inner axes fully match parent).  Leaf becomes
    # contig in entity's space → alias path.
    a = CArray.int32(5, 4).seq
    w = a.window(1..3, nil, bounds: "fill", fill_value: 0)
    s = w[nil, nil]                                     # = a[1..3, nil]
    assert_equal a[1..3, nil].to_a, s.to_a
  end

  def test_phase15_compose_fold_does_not_apply_to_non_interior
    # w with axis-0 OOB.  embed_covers_all = false, compose-fold
    # cannot walk through w.  Falls back to w materialise path.
    a = CArray.int32(5, 5).seq
    w = a.shift(1, 0, fill_value: 99)                   # axis-0 shift, OOB
    s = w[1..3, 1..3]
    # s should reflect the shifted view (= a[0..2, 1..3] rows offset)
    # In w, row 0 is fill, rows 1..4 = a[0..3]
    # s = w[1..3, 1..3] = [[a[0,1..3]], [a[1,1..3]], [a[2,1..3]]]
    expected = [[1, 2, 3], [6, 7, 8], [11, 12, 13]]
    assert_equal expected, s.to_a
  end

  # ------------------------------------------------------------------
  # Phase 1.5 (A-path, E.8): CAWindow direct attach alias.  When inner
  # axes are full and outer axis is interior, ca_attach(window) sets
  # ca->ptr to alias parent storage instead of malloc+memcpy.
  # ------------------------------------------------------------------

  def test_phase15_alias_eligible_1d_interior
    a = CArray.int(10).seq
    w = a.window(2..7, bounds: "fill", fill_value: 0)
    assert_equal true, w._embed_descriptor[:alias_eligible]
  end

  def test_phase15_alias_eligible_2d_axis0_only_inner_full
    a = CArray.int(10, 5).seq
    w = a.window(2..7, nil, bounds: "fill", fill_value: 0)
    # axis-0: interior, axis-1: full → alias eligible
    assert_equal true, w._embed_descriptor[:alias_eligible]
  end

  def test_phase15_alias_not_eligible_2d_inner_partial
    a = CArray.int(10, 5).seq
    w = a.window(2..7, 1..3, bounds: "fill", fill_value: 0)
    # inner axis partial → not alias eligible (region not contig in parent)
    assert_equal false, w._embed_descriptor[:alias_eligible]
  end

  def test_phase15_alias_not_eligible_when_oob
    a = CArray.int(10).seq
    w = a.shift(2, fill_value: 0)   # axis-0 OOB → not covers_all → not alias eligible
    assert_equal false, w._embed_descriptor[:alias_eligible]
  end

  # Phase 2 T.6: removed (bounds=>'periodic' raises; alias eligibility
  # for that bound type is no longer testable via window).

  def test_phase15_alias_attach_read_byte_parity
    # Direct attach of interior window, read via to_a, byte parity.
    a = CArray.int(10).seq
    w = a.window(2..7, bounds: "fill", fill_value: 0)
    assert_equal [2, 3, 4, 5, 6, 7], w.to_a
  end

  def test_phase15_alias_attach_write_through
    # attach! block: writes through alias should land directly in parent.
    a = CArray.int(10).seq
    w = a.window(2..7, bounds: "fill", fill_value: 0)
    w.attach! do |inner|
      inner[] = inner * 10
    end
    # Parent should see the modifications at positions 2..7.
    assert_equal [0, 1, 20, 30, 40, 50, 60, 70, 8, 9], a.to_a
  end

  def test_phase15_alias_attach_write_through_2d
    a = CArray.int(5, 4).seq
    w = a.window(1..3, nil, bounds: "fill", fill_value: 0)   # axis-1 full
    assert_equal true, w._embed_descriptor[:alias_eligible]
    w.attach! do |inner|
      inner[] = CArray.int(3, 4) { 99 }
    end
    # Parent rows 1..3 should be all 99, rows 0 and 4 unchanged.
    expected = [
      [ 0,  1,  2,  3],
      [99, 99, 99, 99],
      [99, 99, 99, 99],
      [99, 99, 99, 99],
      [16, 17, 18, 19],
    ]
    assert_equal expected, a.to_a
  end

  def test_phase15_compose_fold_through_window_through_stride
    # 3-level chain: a -> w (interior) -> b (CAStride refer of w) -> s
    # Confirms compose-fold walks through all levels.
    a = CArray.int32(6, 6).seq
    w = a.window(1..4, 1..4, bounds: "fill", fill_value: 0)   # 4x4 interior
    b = w[nil, nil]                                            # CABlock of w
    s = b[0..1, 0..1]                                          # 2x2 corner of b
    assert_equal [[7, 8], [13, 14]], s.to_a   # = a[1..2, 1..2]

    s[] = CArray.int32(2, 2) { -1 }
    # Writes should reach a (via compose-fold scatter).
    assert_equal(-1, a[1, 1])
    assert_equal(-1, a[1, 2])
    assert_equal(-1, a[2, 1])
    assert_equal(-1, a[2, 2])
  end

  # ------------------------------------------------------------------
  # T.9 (= post-T.8 bugfix): CAWindowIterator (= sliding window iterator)
  # also mutates kernel->start[] internally for each iteration step
  # (ca_vi_kernel_at_index / ca_vi_kernel_move_to_index in
  #  ext/ca_iter_window.c).  Same staleness risk as #move; fix is to
  # call ca_window_recompute_embed after each mutation.
  # CAWindowIterator は speed-non-critical legacy だが correctness
  # 優先で recompute を入れる (= 「速度より動作」スタンス、user 直接指示).
  # ------------------------------------------------------------------

  def test_window_iterator_attach_path_byte_parity
    # sliding 3-window over 5-cell parent with OOB fill.
    # Each iteration step mutates kernel->start[]; .to_ca uses embed
    # path (= would have read stale embed_* before T.9 fix).
    a = CArray.int32(5).seq
    kernel = a.window(0..2, bounds: "fill", fill_value: 99)
    it = CAWindowIterator.new(kernel)
    results = []
    it.each { |k| results << k.to_ca.to_a }
    expected = [
      [0, 1, 2],
      [1, 2, 3],
      [2, 3, 4],
      [3, 4, 99],
      [4, 99, 99],
    ]
    assert_equal expected, results
  end

  def test_window_iterator_2d_attach_path
    # 2D sliding window: 2x2 kernel over 3x3 parent.
    a = CArray.int32(3, 3).seq
    kernel = a.window(0..1, 0..1, bounds: "fill", fill_value: 99)
    it = CAWindowIterator.new(kernel)
    results = []
    it.each { |k| results << k.to_ca.to_a }
    # 9 iterations (= 3 * 3), each yields a 2x2 view
    assert_equal 9, results.size
    assert_equal [[0, 1], [3, 4]], results[0]       # at (0, 0)
    assert_equal [[4, 5], [7, 8]], results[4]       # at (1, 1) = center
    assert_equal [[8, 99], [99, 99]], results[8]    # at (2, 2) = corner OOB
  end

end
