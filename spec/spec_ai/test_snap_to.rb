# spec_ai/test_snap_to.rb
#
# Tests for `CArray#snap_to(list, lfill:, ufill:)`: nearest-neighbour
# snap to an ascending non-uniform grid.  Sibling of `quantize` (uniform
# step) and `digitize` (bin index, half-open intervals).

require "test/unit"
require "carray"

class TestSnapTo < Test::Unit::TestCase

  def test_basic_snap
    # nearest by linear position; ties (3.0 is equidistant to 1 and 5)
    # round half-away-from-zero → higher-magnitude side.
    a = CArray.float64(5); a[] = [0.4, 1.2, 3.0, 4.8, 5.0]
    r = a.snap_to([0.0, 1.0, 5.0, 20.0])
    assert_equal [0.0, 1.0, 5.0, 5.0, 5.0], r.to_a
  end

  def test_default_clamps_below_and_above
    a = CArray.float64(4); a[] = [-5.0, 0.5, 25.0, 100.0]
    r = a.snap_to([0.0, 1.0, 5.0, 20.0])
    # 0.5 is halfway between 0 and 1 → round up to 1
    assert_equal [0.0, 1.0, 20.0, 20.0], r.to_a
    # The mask array may exist (created by locate_nearest_addr) but all
    # cells are clamped, so no bits are set.
    assert_equal 0, r.is_masked.count(true)
  end

  def test_lfill_nil_masks_below
    a = CArray.float64(4); a[] = [-1.0, 0.5, 3.0, 25.0]
    r = a.snap_to([0.0, 1.0, 5.0, 20.0], lfill: nil)
    assert r.has_mask?
    assert_equal true, r.is_masked[0]                 # below → masked
    assert_equal false, r.is_masked[1]                 # in-range
    assert_equal 20.0, r[3]                        # above → clamp (default)
  end

  def test_ufill_nil_masks_above
    a = CArray.float64(4); a[] = [-1.0, 0.5, 3.0, 25.0]
    r = a.snap_to([0.0, 1.0, 5.0, 20.0], ufill: nil)
    assert r.has_mask?
    assert_equal false, r.is_masked[0]                 # below → clamp (default)
    assert_equal 0.0, r[0]
    assert_equal true, r.is_masked[3]                 # above → masked
  end

  def test_explicit_fill_values
    a = CArray.float64(3); a[] = [-1.0, 3.0, 25.0]
    r = a.snap_to([0.0, 5.0, 10.0], lfill: -99.0, ufill: 99.0)
    assert_equal [-99.0, 5.0, 99.0], r.to_a
  end

  def test_both_nil_masks_both_sides
    a = CArray.float64(3); a[] = [-1.0, 3.0, 25.0]
    r = a.snap_to([0.0, 5.0, 10.0], lfill: nil, ufill: nil)
    assert r.has_mask?
    assert_equal [true, false, true], r.is_masked.to_a
  end

  def test_nan_always_masked
    a = CArray.float64(4); a[] = [0.5, Float::NAN, 3.0, 5.0]
    r = a.snap_to([0.0, 1.0, 5.0, 20.0])
    assert r.has_mask?
    assert_equal true, r.is_masked[1]
    assert_equal 1.0, r[0]                         # 0.5 tie → 1.0 (higher magnitude)
  end

  def test_masked_input_propagates
    a = CArray.float64(4); a[] = [0.5, 1.5, 3.0, 5.0]
    a[2] = UNDEF
    r = a.snap_to([0.0, 1.0, 5.0, 20.0])
    assert r.has_mask?
    assert_equal true, r.is_masked[2]
  end

  def test_output_dtype_follows_list
    a = CArray.float64(3); a[] = [0.4, 5.6, 9.9]
    ref = CArray.int32(3) { |i| [0, 5, 10][i] }
    r = a.snap_to(ref)
    assert_equal CA_INT32, r.data_type
    assert_equal [0, 5, 10], r.to_a
  end

  def test_single_value_list
    a = CArray.float64(4); a[] = [-1.0, 0.0, 5.0, Float::NAN]
    r = a.snap_to([3.0])
    assert_equal 3.0, r[0]
    assert_equal 3.0, r[1]
    assert_equal 3.0, r[2]
    assert r.has_mask?
    assert_equal true, r.is_masked[3]                 # NaN still masked
  end

  def test_list_not_1d_raises
    a = CArray.float64(3).seq!
    assert_raise(ArgumentError) { a.snap_to(CArray.float64(2, 2)) }
  end

  def test_empty_list_raises
    a = CArray.float64(3).seq!
    assert_raise(ArgumentError) { a.snap_to([]) }
  end

  def test_shape_preserved
    a = CArray.float64(3, 4).seq!(0, 0.5)
    r = a.snap_to([0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0])
    assert_equal [3, 4], r.shape
  end

  def test_composes_with_categorize
    rain = CArray.float64(5); rain[] = [0.05, 0.8, 3.0, 10.0, 200.0]
    cat = rain.snap_to([0.0, 1.0, 5.0, 20.0]).categorize
    assert_kind_of(CACategorical, cat)
    # values are clamped and rounded to nearest grid point; each cell's
    # snapped value becomes its own label
    assert_equal rain.snap_to([0.0, 1.0, 5.0, 20.0]).to_a, cat.to_a
  end

  # ---- direction: :round / :floor / :ceil ----

  def test_direction_floor
    # floor: pick the list value at or below the sample
    a = CArray.float64(5); a[] = [0.0, 0.5, 1.0, 3.0, 5.0]
    r = a.snap_to([0.0, 1.0, 5.0, 20.0], direction: :floor)
    assert_equal [0.0, 0.0, 1.0, 1.0, 5.0], r.to_a
  end

  def test_direction_ceil
    # ceil: pick the list value at or above the sample
    a = CArray.float64(5); a[] = [0.0, 0.5, 1.0, 3.0, 5.0]
    r = a.snap_to([0.0, 1.0, 5.0, 20.0], direction: :ceil)
    assert_equal [0.0, 1.0, 1.0, 5.0, 5.0], r.to_a
  end

  def test_direction_round_default
    a = CArray.float64(3); a[] = [0.3, 3.0, 4.7]
    ref = [0.0, 1.0, 5.0, 20.0]
    assert_equal a.snap_to(ref).to_a, a.snap_to(ref, direction: :round).to_a
  end

  def test_direction_invalid_raises
    a = CArray.float64(3).seq!
    assert_raise(ArgumentError) {
      a.snap_to([0.0, 1.0, 5.0], direction: :bogus)
    }
  end
end
