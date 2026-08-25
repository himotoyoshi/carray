# frozen_string_literal: true
#
# spec_ai/test_cawindow_unification.rb
#
# Tier 2.G regression tests for the CAShift = typedef CAWindow
# unification.  Pins:
#
#   - CAShift / CAWindow behavior identity for the equivalent
#     window-with-FILL-or-PERIODIC patterns
#   - per-axis bounds correctness (CAShift with mixed roll[])
#   - mask propagation under fill_value: UNDEF (== CAShift fill_mask=1)
#   - clone / initialize_copy preserve type and behavior
#   - in-place `ca[] = ca.shift/roll(...)` still work
#   - class hierarchy: CAShift < CAWindow < CAView

require "test/unit"
require_relative "../../lib/carray"

class TestCAWindowUnification < Test::Unit::TestCase

  # ---------- class hierarchy ----------

  def test_cashift_inherits_from_cawindow
    assert_operator CAShift, :<, CAWindow
    assert_operator CAWindow, :<, CAView
    a = CArray.int(5).seq
    v = a.shift(1)
    assert_kind_of CAShift, v
    assert_kind_of CAWindow, v
    assert_kind_of CAView, v
  end

  # ---------- CAShift fill mode (boundary cells = fill value) ----------

  def test_shift_positive
    a = CArray.int(5).seq
    assert_equal [0, 0, 1, 2, 3], a.shift(1).to_a
  end

  def test_shift_negative
    a = CArray.int(5).seq
    assert_equal [1, 2, 3, 4, 0], a.shift(-1).to_a
  end

  def test_shift_with_explicit_fill_value
    a = CArray.int(5).seq
    assert_equal [99, 0, 1, 2, 3], a.shift(1, fill_value: 99).to_a
  end

  def test_shift_2d
    a = CArray.int(3, 4).seq
    expected = [[0, 0, 0, 0], [0, 1, 2, 3], [4, 5, 6, 7]]
    assert_equal expected, a.shift(1, 0).to_a
  end

  def test_shift_with_block_fill
    a = CArray.int(5).seq
    v = a.shift(1, fill_value: 77)
    assert_equal [77, 0, 1, 2, 3], v.to_a
  end

  # ---------- CAShift roll mode (cyclic) ----------

  def test_roll_positive
    a = CArray.int(5).seq
    assert_equal [4, 0, 1, 2, 3], a.roll(1).to_a
  end

  def test_roll_negative
    a = CArray.int(5).seq
    assert_equal [2, 3, 4, 0, 1], a.roll(-2).to_a
  end

  # Phase 2 T.6 (2026-05-26): :roll option removed.  Mixed per-axis
  # PERIODIC + FILL is now expressed via chain (= a.roll(1, 0).shift(0, 1, fill_value: 0)).
  def test_shift_with_per_axis_roll_removed_raises
    a = CArray.int(3, 4).seq
    assert_raise(ArgumentError) { a.shift(1, 1, roll: [1, 0]) }
  end

  # ---------- UNDEF fill → mask propagation ----------

  def test_shift_undef_creates_mask
    a = CArray.int(5).seq
    v = a.shift(1, fill_value: UNDEF)
    assert v.has_mask?, "shift(1) { UNDEF } should produce a masked view"
    assert_equal [true, false, false, false, false], v.is_masked.to_a,
                 "cell 0 (out-of-range) should be masked, others not"
  end

  # ---------- CAShift ≡ CAWindow equivalence ----------

  def test_shift_N_equals_window_minus_N_full_count_fill
    a = CArray.float64(7).seq
    n = 2
    v_shift  = a.shift(n)                                       # = [0,0, 0,1,2,3,4]
    v_window = a.window(-n..(a.dim[0] - n - 1), bounds: "fill") # = same
    assert_equal v_shift.to_a, v_window.to_a
  end

  # Phase 2 T.6: bounds=>'periodic' removed; the equivalence test no
  # longer applies since the window+periodic API is gone.  a.roll(n)
  # is the canonical periodic surface (returns CARoll view).


  def test_shift_2d_equals_window_2d_fill
    a = CArray.int(4, 5).seq
    s0, s1 = 1, 2
    v_shift = a.shift(s0, s1)
    # Equivalent CAWindow: per-axis start = -s, count = full
    v_window = a.window(-s0..(a.dim[0] - s0 - 1),
                        -s1..(a.dim[1] - s1 - 1),
                        bounds: "fill")
    assert_equal v_shift.to_a, v_window.to_a
  end

  # ---------- clone / dup ----------

  def test_shift_clone_preserves_type_and_data
    a = CArray.int(5).seq
    v = a.shift(2, fill_value: 100)
    v2 = v.clone
    assert_kind_of CAShift, v2
    assert_equal v.to_a, v2.to_a
  end

  def test_shift_clone_independence_from_parent
    a = CArray.int(5).seq
    v  = a.shift(1, fill_value: 50)
    v2 = v.clone
    a[0] = 999    # mutate parent
    # Both views should see the parent mutation (still live ref to parent)
    assert_equal v.to_a, v2.to_a
  end

  # ---------- in-place shift / roll via `ca[] = ca.shift/roll(...)` ----------
  # (3.0: `shift!` / `roll!` retired per view-by-default policy)

  def test_shift_view_self_assignment
    a = CArray.int(5).seq
    a[] = a.shift(1)
    assert_equal [0, 0, 1, 2, 3], a.to_a
  end

  def test_roll_view_self_assignment
    a = CArray.int(5).seq
    a[] = a.roll(2)
    assert_equal [3, 4, 0, 1, 2], a.to_a
  end

  # ---------- CAWindow per-axis bounds correctness (G.1 main change) ----------

  def test_cawindow_fill_unchanged
    a = CArray.int(5).seq
    v = a.window(-1..3, bounds: "fill")
    assert_equal [0, 0, 1, 2, 3], v.to_a
  end

  # Phase 2 T.6: bounds=>'periodic' removed; the test that round-tripped
  # via CAWindow PERIODIC path is no longer applicable.  Use a.roll(...)
  # for cyclic semantics.

  def test_cawindow_within_range_unchanged
    a = CArray.int(5).seq
    v = a.window(0..2)
    assert_equal [0, 1, 2], v.to_a
  end

  def test_cawindow_bounds_accessor_returns_first_axis_policy
    # Phase 2 T.6: PERIODIC variant removed; FILL still tested.  STRICT
    # / NEAREST also valid and retained per bounds zoo §6 (NEAREST is
    # eager-only future, currently the enum branch lives).
    a = CArray.int(5).seq
    v_f = a.window(-1..3, bounds: "fill")
    assert_equal 6, v_f.bounds   # CA_BOUNDS_FILL
  end

  # ---------- data_type variety ----------

  def test_shift_data_type_variety
    [:int8, :int16, :int32, :int64, :float32, :float64].each do |dt|
      a = CArray.send(dt, 5).seq
      assert_equal [0, 0, 1, 2, 3], a.shift(1).to_a, "data_type #{dt}"
      assert_equal [4, 0, 1, 2, 3], a.roll(1).to_a,  "data_type #{dt}"
    end
  end

  # ---------- attach! round-trip (engine path uses shared CAWindow ops) ----------

  def test_shift_to_ca_then_writeback_via_scatter
    a = CArray.int(5).seq
    v = a.shift(1)
    gathered = v.to_ca                # gather through CAWindow attach
    transformed = gathered * 10
    v[] = transformed                 # scatter through CAWindow sync_data
    # shift(1) maps view[k] to parent[k-1].  Writing transformed to
    # view also writes to parent[k-1] for k=1..4 (k=0 out-of-range,
    # boundary policy = FILL = skip).
    # transformed = [0, 0, 10, 20, 30]  (gathered was [0, 0, 1, 2, 3], *10)
    # parent post: [0, 10, 20, 30, 4]  (only positions 0..3 written;
    # position 4 keeps original 4 since k=0 was out-of-range so no
    # write hits position -1 of parent)
    # Actually: view[k] = parent[k - shift] = parent[k - 1] for k>=1.
    # Scatter writes transformed[k] -> parent[k - 1] for k=1..4.
    # So parent[0]=transformed[1]=0, parent[1]=transformed[2]=10,
    #    parent[2]=transformed[3]=20, parent[3]=transformed[4]=30,
    #    parent[4] untouched (no view index maps to it).
    assert_equal [0, 10, 20, 30, 4], a.to_a
  end

end
