# spec_ai/test_snap.rb
#
# Tests for the value-returning `CArray#snap(step, offset:)`: snap
# each element to the nearest point on the uniform grid
# `..., offset - step, offset, offset + step, ...`.

require "test/unit"
require "carray"

class TestSnap < Test::Unit::TestCase

  def test_basic_snap_to_step
    a = CArray.float64(6); a[] = [0.1, 0.3, 0.55, 0.75, 1.24, 1.26]
    r = a.snap(0.5)
    assert_equal [0.0, 0.5, 0.5, 1.0, 1.0, 1.5], r.to_a
  end

  def test_offset_shifts_grid
    # grid = ..., -0.25, 0.25, 0.75, 1.25, ...   (offset acts as phase)
    # 0.0 is exactly halfway between -0.25 and 0.25; half-away-from-zero
    # (the scaled -0.5 rounds to -1) sends it to -0.25.
    a = CArray.float64(5); a[] = [0.0, 0.24, 0.26, 0.74, 0.76]
    r = a.snap(0.5, offset: 0.25)
    assert_equal [-0.25, 0.25, 0.25, 0.75, 0.75], r.to_a
  end

  def test_step_zero_raises
    a = CArray.float64(3).seq!
    assert_raise(ArgumentError) { a.snap(0) }
  end

  def test_step_negative_raises
    a = CArray.float64(3).seq!
    assert_raise(ArgumentError) { a.snap(-0.5) }
  end

  def test_preserves_dtype_float64
    a = CArray.float64(3); a[] = [0.1, 0.6, 1.1]
    assert_equal CA_FLOAT64, a.snap(0.5).data_type
  end

  def test_shape_preserved
    a = CArray.float64(3, 4).seq!(0, 0.1)
    r = a.snap(0.5)
    assert_equal [3, 4], r.shape
  end

  def test_nan_masked
    a = CArray.float64(4); a[] = [0.3, Float::NAN, 1.2, -0.4]
    r = a.snap(0.5)
    assert r.has_mask?
    assert_equal true, r.is_masked[1]
    assert_equal 0.5, r[0]
    assert_equal 1.0, r[2]
    assert_equal(-0.5, r[3])
  end

  def test_inf_masked
    a = CArray.float64(3); a[] = [0.3, Float::INFINITY, 1.1]
    r = a.snap(0.5)
    assert r.has_mask?
    assert_equal true, r.is_masked[1]
  end

  def test_masked_input_propagates
    a = CArray.float64(4); a[] = [0.1, 0.6, 1.1, 1.6]
    a[2] = UNDEF
    r = a.snap(0.5)
    assert r.has_mask?
    assert_equal true, r.is_masked[2]
  end

  def test_negative_values
    a = CArray.float64(5); a[] = [-1.24, -0.76, -0.24, 0.26, 0.76]
    r = a.snap(0.5)
    assert_in_delta(-1.0, r[0], 1e-12)
    assert_in_delta(-1.0, r[1], 1e-12)
    assert_in_delta( 0.0, r[2], 1e-12)
    assert_in_delta( 0.5, r[3], 1e-12)
    assert_in_delta( 1.0, r[4], 1e-12)
  end

  def test_integer_input_returns_float
    # a = [0, 1, 2, 3, 4], step 2 → grid ..., 0, 2, 4, ...
    # 1 (halfway 0↔2) → 2 (away from zero), 3 (halfway 2↔4) → 4.
    a = CArray.int32(5).seq!(0, 1)
    r = a.snap(2)
    assert_equal CA_FLOAT64, r.data_type
    assert_equal [0.0, 2.0, 2.0, 4.0, 4.0], r.to_a
  end

  def test_composes_with_categorize
    temp = CArray.float64(6); temp[] = [268.15, 270.24, 270.27, 271.0, 285.5, 285.5]
    cat  = temp.snap(0.5).categorize
    assert_kind_of(CACategorical, cat)
    assert_equal temp.snap(0.5).to_a, cat.to_a
  end

  # ---- direction: :round / :floor / :ceil ----

  def test_direction_floor
    a = CArray.float64(5); a[] = [285.7, 285.5, 285.3, -0.3, -0.7]
    r = a.snap(0.5, direction: :floor)
    assert_equal [285.5, 285.5, 285.0, -0.5, -1.0], r.to_a
  end

  def test_direction_ceil
    a = CArray.float64(5); a[] = [285.7, 285.5, 285.3, -0.3, -0.7]
    r = a.snap(0.5, direction: :ceil)
    assert_equal [286.0, 285.5, 285.5, 0.0, -0.5], r.to_a
  end

  def test_direction_round_default
    a = CArray.float64(3); a[] = [285.7, 285.3, 285.5]
    assert_equal a.snap(0.5).to_a, a.snap(0.5, direction: :round).to_a
  end

  def test_direction_invalid_raises
    a = CArray.float64(3).seq!
    assert_raise(ArgumentError) { a.snap(0.5, direction: :bogus) }
  end

  def test_direction_floor_matches_bin
    # snap(step, direction: :floor) と bin(vmin, vmax, step) の返す
    # index が「値」レベルで対応する = value/index の pair 対称性。
    temp = CArray.float64(4); temp[] = [270.0, 285.5, 299.5, 270.25]
    snapped = temp.snap(0.5, offset: 270.0, direction: :floor)
    idx     = temp.bin(270.0, 300.0, 0.5)
    # snapped == 270.0 + idx * 0.5
    (0...4).each { |k| assert_in_delta(270.0 + idx[k] * 0.5, snapped[k], 1e-12) }
  end
end
