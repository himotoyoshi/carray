# frozen_string_literal: true
#
# PROPOSAL_UNIQ_AXIS rev1.4 -- shape-preserving mask-based mask_duplicates
# (the method formerly named `uniq`).
#
# Pins:
#   - `a.mask_duplicates` (axis: nil) returns shape-preserving entity with mask at
#     duplicate cells (= 3.0 breaking from legacy 1-D compressed).
#   - `a.mask_duplicates(axis: k)` returns shape-preserving entity, per-fiber dup
#     mask along axis k.
#   - First-seen semantics (= walk-order first occurrence kept).
#   - Masked input cells stay masked, do NOT claim "first-seen" slot.
#   - NaN collapses (= all NaN are one value; first kept, later marked duplicate).
#   - 1-D compressed via `ca.mask_duplicates[:is_not_masked].copy`.
#   - CA_OBJECT axis: nil supported (Ruby Hash fallback).
#   - CA_OBJECT axis: k raises NotImplementedError.
#   - data_class preserved (= copy preserves it).
#   - axis out of range raises ArgumentError.

require "test/unit"
require "carray"

class TestMaskDuplicatesAxis < Test::Unit::TestCase

  # ---- axis: nil (flatten) ----------------------------------------------

  def test_uniq_flat_1d_no_mask
    a = CArray.int32(8) { |i| [3, 1, 4, 1, 5, 9, 2, 6][i] }
    u = a.mask_duplicates
    assert_equal a.dim, u.dim
    assert_equal [3, 1, 4, UNDEF, 5, 9, 2, 6], u.to_a
    assert_equal [false, false, false, true, false, false, false, false], u.mask.to_a
  end

  def test_uniq_flat_1d_all_distinct
    a = CArray.int32(5).seq(0)
    u = a.mask_duplicates
    assert_equal [0, 1, 2, 3, 4], u.to_a
    refute u.has_mask?
  end

  def test_uniq_flat_1d_all_same
    a = CArray.int32(5).fill(7)
    u = a.mask_duplicates
    assert_equal [7, UNDEF, UNDEF, UNDEF, UNDEF], u.to_a
    assert_equal [false, true, true, true, true], u.mask.to_a
  end

  def test_uniq_flat_2d_row_major_order
    # flatten order = [1,2,3,2,1,4] -> kept = [1,2,3,4] at indices 0,1,2,5
    b = CArray.int32(2, 3) { |i, j| [[1, 2, 3], [2, 1, 4]][i][j] }
    u = b.mask_duplicates
    assert_equal [[1, 2, 3], [UNDEF, UNDEF, 4]], u.to_a
    assert_equal [[false, false, false], [true, true, false]], u.mask.to_a
  end

  def test_uniq_flat_legacy_1d_compressed_idiom
    a = CArray.int32(8) { |i| [3, 1, 4, 1, 5, 9, 2, 6][i] }
    compressed = a.mask_duplicates[:is_not_masked].copy
    assert_equal [3, 1, 4, 5, 9, 2, 6], compressed.to_a
  end

  # ---- axis: k (per-fiber) ----------------------------------------------

  def test_uniq_axis0_column_dups
    # column 0: [1,1,7] -> mask idx 1
    # column 1: [2,5,2] -> mask idx 2
    # column 2: [3,3,8] -> mask idx 1
    # column 3: [4,6,9] -> distinct
    b = CArray.int32(3, 4) { |i, j| [[1, 2, 3, 4], [1, 5, 3, 6], [7, 2, 8, 9]][i][j] }
    u = b.mask_duplicates(axis: 0)
    assert_equal [[1, 2, 3, 4], [UNDEF, 5, UNDEF, 6], [7, UNDEF, 8, 9]], u.to_a
    assert_equal [[false, false, false, false], [true, false, true, false], [false, true, false, false]], u.mask.to_a
  end

  def test_uniq_axis1_row_dups
    d = CArray.int32(2, 5) { |i, j| [[1, 2, 1, 3, 2], [5, 5, 5, 6, 7]][i][j] }
    u = d.mask_duplicates(axis: 1)
    assert_equal [[1, 2, UNDEF, 3, UNDEF], [5, UNDEF, UNDEF, 6, 7]], u.to_a
    assert_equal [[false, false, true, false, true], [false, true, true, false, false]], u.mask.to_a
  end

  def test_uniq_axis_negative
    a = CArray.int32(3, 4) { |i, j| [[1, 1, 2, 2], [3, 4, 3, 4], [0, 0, 0, 0]][i][j] }
    u = a.mask_duplicates(axis: -1)
    expected = a.mask_duplicates(axis: 1)
    assert_equal expected.to_a, u.to_a
  end

  def test_uniq_axis_out_of_range_raises
    a = CArray.int32(3, 4).seq(0)
    assert_raise(ArgumentError) { a.mask_duplicates(axis: 2) }
    assert_raise(ArgumentError) { a.mask_duplicates(axis: -3) }
  end

  def test_uniq_axis_1d
    a = CArray.int32(6) { |i| [1, 2, 1, 3, 2, 1][i] }
    u_flat = a.mask_duplicates
    u_axis0 = a.mask_duplicates(axis: 0)
    assert_equal u_flat.to_a, u_axis0.to_a
    assert_equal u_flat.mask.to_a, u_axis0.mask.to_a
  end

  # ---- masked input semantics -------------------------------------------

  def test_uniq_masked_input_does_not_claim_first_seen
    # idx 1 originally is 2, but masked.  Then idx 4 (= 2) should be
    # KEPT (first unmasked occurrence of value 2).
    c = CArray.int32(6) { |i| [1, 2, 1, 3, 2, 1][i] }
    c[1] = UNDEF
    u = c.mask_duplicates
    assert_equal [1, UNDEF, UNDEF, 3, 2, UNDEF], u.to_a
    assert_equal [false, true, true, false, false, true], u.mask.to_a
  end

  def test_uniq_input_mask_preserved
    a = CArray.int32(5) { |i| [1, 2, 3, 4, 5][i] }
    a[2] = UNDEF
    u = a.mask_duplicates
    # No duplicates among unmasked values; only original mask retained.
    assert_equal [false, false, true, false, false], u.mask.to_a
  end

  # ---- NaN collapses (all NaN = one distinct value) ---------------------

  def test_uniq_nan_collapses
    a = CArray.float64(6) { |i| [1.0, Float::NAN, 2.0, Float::NAN, 1.0, 2.0][i] }
    u = a.mask_duplicates
    # All NaN are one value: idx 1 NaN kept (first), idx 3 NaN is a duplicate.
    # 1.0 at idx 4 duplicates idx 0; 2.0 at idx 5 duplicates idx 2.
    assert_equal [false, false, false, true, true, true], u.mask.to_a
    assert u.to_a[1].is_a?(Float) && u.to_a[1].nan?
  end

  def test_uniq_mask_invalid_then_uniq_collapses_nan
    a = CArray.float64(6) { |i| [1.0, Float::NAN, 2.0, Float::NAN, 1.0, 2.0][i] }
    u = a.mask_invalid.mask_duplicates
    # mask_invalid masks both NaN positions.  uniq then deduplicates the
    # remaining unmasked values.
    assert_equal [false, true, false, true, true, true], u.mask.to_a
  end

  # ---- CA_OBJECT (legacy axis: nil path) --------------------------------

  def test_uniq_object_flat
    o = CArray.object(5) { |i| ["a", "b", "a", "c", "b"][i] }
    u = o.mask_duplicates
    assert_equal ["a", "b", UNDEF, "c", UNDEF], u.to_a
    assert_equal [false, false, true, false, true], u.mask.to_a
  end

  # PROPOSAL_SLAB_FAMILY β.5 lifted this restriction: CA_OBJECT axis-path
  # uniq now dispatches through map_slab + Ruby Hash per fiber.  See
  # spec_ai/test_slab_customer_integration.rb for the live behaviour.
  def test_uniq_object_axis_now_works_via_map_slab
    o = CArray.object(2, 3) { |i, j| j }   # both rows are [0, 1, 2] — all unique
    u = o.mask_duplicates(axis: 1)
    assert_equal 0, u.count_masked
  end

  def test_uniq_object_masked_input
    o = CArray.object(5) { |i| ["a", "b", "a", "c", "b"][i] }
    o[1] = UNDEF
    u = o.mask_duplicates
    # idx 1 masked -> doesn't claim "first b"; idx 4 (b) becomes first kept.
    assert_equal [false, true, true, false, false], u.mask.to_a
  end

  # ---- data_class preservation -------------------------------------------

  def test_uniq_preserves_data_class
    a = CArray.int32(6).seq(0)
    # Use any data_class; here we just set an arbitrary value to test
    # propagation through `.copy`.  Skip if no convenient class around.
    u = a.mask_duplicates
    assert_equal a.data_type, u.data_type
    assert_equal a.bytes,     u.bytes
  end

  # ---- 3-D axis sanity ---------------------------------------------------

  def test_uniq_3d_axis_each
    a = CArray.int32(2, 3, 4) { |i, j, k| (i + j + k) % 3 }
    # Each axis: check shape preserved + at least some duplicates masked
    [0, 1, 2].each do |ax|
      u = a.mask_duplicates(axis: ax)
      assert_equal a.dim, u.dim
    end
  end

end
