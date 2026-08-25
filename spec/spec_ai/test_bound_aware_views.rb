# frozen_string_literal: true
#
# spec_ai/test_bound_aware_views.rb
#
# Tier 2.B regression tests for the CAWindow / CAShift framework
# integration (CA_AXIS_KIND_SHIFT engine path).  Pins:
#
#   - All bounds policies (FILL / PERIODIC / REFLECT / NEAREST / RUBY
#     / STRICT / MASK) via CAWindow
#   - CAShift gather / scatter / fill behavior via the shared engine
#   - Per-axis mixed roll (engine SHIFT axis with PERIODIC vs FILL
#     side-by-side)
#   - mid-chain transparency: `a.shift(1)[mask]` (CAShift -> CASelect)
#   - data_type variety
#   - gather + whole-view scatter round-trip
#   - large iteration to exercise the engine SHIFT inner loop

require "test/unit"
require_relative "../../lib/carray"

class TestBoundAwareViews < Test::Unit::TestCase

  # ------------------------------------------------------------------
  # CAWindow — all bounds policies, 1D
  # ------------------------------------------------------------------

  def test_window_fill_below
    a = CArray.int(5).seq
    v = a.window(-2..2, bounds: "fill")
    assert_equal [0, 0, 0, 1, 2], v.to_a
  end

  def test_window_fill_above
    a = CArray.int(5).seq
    v = a.window(2..6, bounds: "fill")
    assert_equal [2, 3, 4, 0, 0], v.to_a
  end

  # Phase 2 T.6 (2026-05-26): bounds=>'periodic' and 'reflect' removed
  # in 3.0 (bounds zoo prune §3.0).  Use CArray#roll for cyclic shift
  # (returns CARoll view).  CAReflect deferred to Phase 2.x.
  def test_window_periodic_removed_raises
    a = CArray.int(5).seq
    assert_raise(ArgumentError) { a.window(-1..3, bounds: "periodic") }
  end

  def test_window_reflect_removed_raises
    a = CArray.int(5).seq
    assert_raise(ArgumentError) { a.window(-2..2, bounds: "reflect") }
  end

  def test_window_nearest_clamps
    a = CArray.int(5).seq
    # window(-2..2) nearest clamps negatives to 0: [0,0,0,1,2]
    assert_equal [0, 0, 0, 1, 2], a.window(-2..2, bounds: "nearest").to_a
    # window(3..7) nearest clamps above to 4: [3,4,4,4,4]
    assert_equal [3, 4, 4, 4, 4], a.window(3..7, bounds: "nearest").to_a
  end

  def test_window_strict_raises_on_oob
    a = CArray.int(5).seq
    assert_raise(RuntimeError) { a.window(-1..3, bounds: "strict").to_a }
  end

  # ------------------------------------------------------------------
  # CAWindow — explicit fill_value
  # ------------------------------------------------------------------

  def test_window_fill_value_explicit
    a = CArray.int(5).seq
    v = a.window(-2..2, fill_value: 99)
    assert_equal [99, 99, 0, 1, 2], v.to_a
  end

  def test_window_undef_creates_mask
    a = CArray.int(5).seq
    v = a.window(-2..2, fill_value: UNDEF)
    assert v.has_mask?
    assert_equal [true, true, false, false, false], v.is_masked.to_a
  end

  # ------------------------------------------------------------------
  # CAWindow — 2D mixed dims
  # ------------------------------------------------------------------

  def test_window_2d_full_inner_partial_outer
    a = CArray.int(3, 4).seq
    v = a.window(-1..2, 0..3, bounds: "fill")
    expected = [[0, 0, 0, 0], [0, 1, 2, 3], [4, 5, 6, 7], [8, 9, 10, 11]]
    assert_equal expected, v.to_a
  end

  # Phase 2 T.6: bounds=>'periodic' removed.  2D periodic patterns can
  # be expressed via CArray#roll (= CARoll view) when same-shape.
  def test_window_2d_periodic_removed_raises
    a = CArray.int(3, 4).seq
    assert_raise(ArgumentError) { a.window(-1..2, -1..3, bounds: "periodic") }
  end

  # ------------------------------------------------------------------
  # CAShift — driven through the same engine path
  # ------------------------------------------------------------------

  def test_shift_positive_fill
    a = CArray.int(5).seq
    assert_equal [0, 0, 1, 2, 3], a.shift(1).to_a
  end

  def test_shift_negative_fill
    a = CArray.int(5).seq
    assert_equal [1, 2, 3, 4, 0], a.shift(-1).to_a
  end

  def test_roll_positive
    a = CArray.int(5).seq
    assert_equal [4, 0, 1, 2, 3], a.roll(1).to_a
  end

  def test_roll_negative
    a = CArray.int(5).seq
    # roll(-2) maps view[k] = parent[(k+2) mod 5]
    assert_equal [2, 3, 4, 0, 1], a.roll(-2).to_a
  end

  # Phase 2 T.6: :roll option on #shift removed (bounds zoo prune).
  # Mixed per-axis PERIODIC + FILL must now be expressed via chain
  # (= a.roll(1, 0).shift(0, 1, fill_value: 0) for the original example).
  def test_shift_per_axis_mixed_roll_removed_raises
    a = CArray.int(3, 4).seq
    assert_raise(ArgumentError) { a.shift(1, 1, roll: [1, 0]) }
  end

  def test_shift_undef_propagates_mask
    a = CArray.int(5).seq
    v = a.shift(2, fill_value: UNDEF)
    assert v.has_mask?
    # shift(2): out-of-range at view positions 0 and 1
    assert_equal [true, true, false, false, false], v.is_masked.to_a
  end

  # ------------------------------------------------------------------
  # scatter / fill back through engine
  # ------------------------------------------------------------------

  def test_window_scatter_in_range
    a = CArray.int(5).seq
    v = a.window(1..3, bounds: "fill")
    v[] = CArray.int(3).tap { |__a| __a[] = [100, 200, 300] }
    assert_equal [0, 100, 200, 300, 4], a.to_a
  end

  def test_window_scatter_with_oob_skips
    a = CArray.int(5).seq
    v = a.window(-1..3, bounds: "fill")  # view position 0 is OOB
    v[] = CArray.int(5).tap { |__a| __a[] = [99, 100, 200, 300, 400] }
    # view positions 1..4 map to parent 0..3; OOB at view pos 0 is skipped
    assert_equal [100, 200, 300, 400, 4], a.to_a
  end

  def test_shift_fill_via_assignment
    a = CArray.int(5).seq
    v = a.shift(1)
    v[] = -1
    # fill_value writes -1 to parent cells that view maps to (skip OOB)
    # shift(1): view[k] = parent[k-1] for k=1..4, view[0]=fill (OOB on parent)
    # broadcast scatter -1: parent[0]=-1, parent[1]=-1, parent[2]=-1, parent[3]=-1
    assert_equal [-1, -1, -1, -1, 4], a.to_a
  end

  # ------------------------------------------------------------------
  # mid-chain transparency
  # ------------------------------------------------------------------

  def test_shift_then_caselect
    # CAShift -> CASelect chain (= bound-aware view as parent of flat-index)
    a = CArray.int(10).seq        # [0..9]
    s = a.shift(1)                # [0,0,1,2,3,4,5,6,7,8]  (view)
    m = CArray.boolean(10).tap { |__a| __a[] = Array.new(10) { |i| i.odd? ? 1 : 0 } }
    v = s[m]                      # CASelect over CAShift
    expected = [0, 2, 4, 6, 8]
    assert_equal expected, v.to_a
  end

  # ------------------------------------------------------------------
  # data_type variety
  # ------------------------------------------------------------------

  def test_data_type_variety_shift
    [:int8, :int16, :int32, :int64, :float32, :float64].each do |dt|
      a = CArray.send(dt, 5).seq
      assert_equal [0, 0, 1, 2, 3], a.shift(1).to_a, "shift, data_type #{dt}"
      assert_equal [4, 0, 1, 2, 3], a.roll(1).to_a,  "roll,  data_type #{dt}"
    end
  end

  def test_data_type_variety_window
    # Phase 2 T.6: periodic check removed (bounds option pruned).
    # Covered separately by CArray#roll (returns CARoll view).
    [:int8, :int16, :int32, :int64, :float32, :float64].each do |dt|
      a = CArray.send(dt, 5).seq
      assert_equal [0, 0, 0, 1, 2], a.window(-2..2, bounds: "fill").to_a,
                   "window fill, data_type #{dt}"
      assert_equal [4, 0, 1, 2, 3], a.roll(1).to_a,
                   "roll, data_type #{dt}"
    end
  end

  # ------------------------------------------------------------------
  # round-trip through engine
  # ------------------------------------------------------------------

  def test_window_gather_then_scatter_round_trip
    a = CArray.float64(5).seq
    v = a.window(0..3, bounds: "fill")
    gathered = v.to_ca
    transformed = gathered + 100.0
    v[] = transformed
    # All view positions are in range, all parent[0..3] get +100
    assert_equal [100.0, 101.0, 102.0, 103.0, 4.0], a.to_a
  end

  # ------------------------------------------------------------------
  # large iteration
  # ------------------------------------------------------------------

  def test_large_shift
    a = CArray.float64(1000).seq
    v = a.shift(100)
    result = v.to_a
    # view[k] for k < 100 = 0 (fill); k >= 100 = parent[k-100]
    100.times { |k| assert_equal 0.0, result[k] }
    (100...1000).each { |k| assert_equal (k - 100).to_f, result[k] }
  end

  def test_large_roll
    a = CArray.float64(1000).seq
    v = a.roll(100)
    result = v.to_a
    # view[k] = parent[(k - 100) mod 1000]
    1000.times { |k| assert_equal ((k - 100) % 1000).to_f, result[k] }
  end

  # ------------------------------------------------------------------
  # CAShift == CAWindow equivalence (re-pin after engine integration)
  # ------------------------------------------------------------------

  def test_shift_equivalent_to_window_fill
    a = CArray.float64(7).seq
    n = 2
    assert_equal a.shift(n).to_a,
                 a.window(-n..(a.dim[0] - n - 1), bounds: "fill").to_a
  end

  # Phase 2 T.6: bounds=>'periodic' removed; the equivalence test no
  # longer applies since the window+periodic API is gone.  CArray#roll
  # is the canonical periodic shift surface (returns CARoll view).


end
