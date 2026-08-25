# frozen_string_literal: true
#
# spec_ai/test_catile.rb
#
# COMPOSITE_FAMILY Phase 2 (T.3): CATile view tests.
#
# CATile = N-region expansion view (np.tile equivalent).
# Output shape = parent.dim[k] * reps[k] per axis.
# Each tile at output offset (i_0*parent.dim[0], ...) is full-parent alias.
#
# Reference: devel/PROPOSAL_CATILE.md §1.2 / §1.3 / §3 T.3

require "test/unit"
require_relative "../../lib/carray"

class TestCATile < Test::Unit::TestCase

  # ------------------------------------------------------------------
  # Basic class identity
  # ------------------------------------------------------------------

  def test_returns_catile_instance
    a = CArray.int32(5).seq
    v = a.tile(3)
    assert_kind_of CATile, v
    assert_kind_of CAView, v
    assert_kind_of CArray, v
  end

  def test_shape_1d
    a = CArray.int32(5).seq
    v = a.tile(3)
    assert_equal [15], v.dim
    assert_equal 15, v.elements
  end

  def test_shape_2d
    a = CArray.int32(2, 3).seq
    v = a.tile(2, 4)
    assert_equal [4, 12], v.dim
    assert_equal 48, v.elements
  end

  # ------------------------------------------------------------------
  # Argument forms (multi-arg + Array of Integer)
  # ------------------------------------------------------------------

  def test_multi_arg_1d
    a = CArray.int32(5).seq
    v = a.tile(2)
    assert_equal [10], v.dim
  end

  def test_multi_arg_2d
    a = CArray.int32(2, 3).seq
    v = a.tile(3, 2)
    assert_equal [6, 6], v.dim
  end

  def test_array_arg_1d
    a = CArray.int32(5).seq
    v = a.tile([3])
    assert_equal [15], v.dim
  end

  def test_array_arg_2d
    a = CArray.int32(2, 3).seq
    v = a.tile([3, 2])
    assert_equal [6, 6], v.dim
  end

  def test_multi_arg_and_array_equivalent
    a = CArray.int32(2, 3).seq
    v_multi = a.tile(3, 2)
    v_array = a.tile([3, 2])
    assert_equal v_multi.to_a, v_array.to_a
  end

  def test_argc_mismatch_raises_for_2d_with_1_arg
    a = CArray.int32(2, 3).seq
    assert_raise(ArgumentError) { a.tile(2) }
  end

  def test_argc_mismatch_raises_for_1d_with_2_args
    a = CArray.int32(5).seq
    assert_raise(ArgumentError) { a.tile(2, 3) }
  end

  def test_array_length_mismatch_raises
    a = CArray.int32(2, 3).seq
    assert_raise(ArgumentError) { a.tile([2]) }
  end

  def test_non_positive_reps_raises
    a = CArray.int32(5).seq
    assert_raise(IndexError) { a.tile(0) }
    assert_raise(IndexError) { a.tile(-1) }
  end

  # ------------------------------------------------------------------
  # Byte parity vs hand-computed result
  # ------------------------------------------------------------------

  def test_byte_parity_1d_3x
    a = CArray.int32(5).seq
    v = a.tile(3)
    expected = [0, 1, 2, 3, 4] * 3
    assert_equal expected, v.to_a
  end

  def test_byte_parity_1d_1x_identity
    a = CArray.int32(5).seq
    v = a.tile(1)
    assert_equal a.to_a, v.to_a
  end

  def test_byte_parity_2d_2x2
    a = CArray.int32(2, 3).seq  # [[0,1,2],[3,4,5]]
    v = a.tile(2, 2)
    expected = [
      [0, 1, 2, 0, 1, 2],
      [3, 4, 5, 3, 4, 5],
      [0, 1, 2, 0, 1, 2],
      [3, 4, 5, 3, 4, 5],
    ]
    assert_equal expected, v.to_a
  end

  def test_byte_parity_2d_3x1
    a = CArray.int32(2, 3).seq
    v = a.tile(3, 1)
    expected = [
      [0, 1, 2],
      [3, 4, 5],
      [0, 1, 2],
      [3, 4, 5],
      [0, 1, 2],
      [3, 4, 5],
    ]
    assert_equal expected, v.to_a
  end

  def test_byte_parity_2d_1x3
    a = CArray.int32(2, 3).seq
    v = a.tile(1, 3)
    expected = [
      [0, 1, 2, 0, 1, 2, 0, 1, 2],
      [3, 4, 5, 3, 4, 5, 3, 4, 5],
    ]
    assert_equal expected, v.to_a
  end

  # ------------------------------------------------------------------
  # Dtype variety
  # ------------------------------------------------------------------

  def test_data_type_float64
    a = CArray.float64(3).seq * 1.5
    v = a.tile(2)
    assert_equal [0.0, 1.5, 3.0, 0.0, 1.5, 3.0], v.to_a
  end

  def test_data_type_int8
    a = CArray.int8(3).tap { |__a| __a[] = [1, 2, 3] }
    v = a.tile(3)
    assert_equal [1, 2, 3, 1, 2, 3, 1, 2, 3], v.to_a
  end

  def test_data_type_boolean
    a = CArray.boolean(3).tap { |__a| __a[] = [true, false, true] }
    v = a.tile(2)
    assert_equal [true, false, true, true, false, true], v.to_a
  end

  # ------------------------------------------------------------------
  # Equivalence with CArray.montage (= eager pre-Phase-2 baseline)
  # ------------------------------------------------------------------

  def test_equivalent_to_combine_1d
    a = CArray.int32(4).seq
    v_tile = a.tile(3).to_ca
    v_combine = CArray.montage([a, a, a], [3], axis: 0, data_type: :int32).to_ca
    assert_equal v_combine.to_a, v_tile.to_a
  end

  def test_equivalent_to_combine_2d
    a = CArray.int32(3, 4).seq
    v_tile = a.tile(2, 2).to_ca
    v_combine = CArray.montage([a, a, a, a], [2, 2], axis: 0, data_type: :int32).to_ca
    assert_equal v_combine.to_a, v_tile.to_a
  end

  # ------------------------------------------------------------------
  # Descriptor accessor
  # ------------------------------------------------------------------

  def test_descriptor_1d
    a = CArray.int32(5).seq
    v = a.tile(3)
    d = v._tile_descriptor
    assert_equal [3], d[:reps]
    assert_equal 3, d[:total_tiles]
    assert_equal 1, d[:ndim]
  end

  def test_descriptor_2d
    a = CArray.int32(2, 3).seq
    v = a.tile(4, 5)
    d = v._tile_descriptor
    assert_equal [4, 5], d[:reps]
    assert_equal 20, d[:total_tiles]
    assert_equal 2, d[:ndim]
  end

  # ------------------------------------------------------------------
  # Mask propagation
  # ------------------------------------------------------------------

  def test_mask_propagates
    a = CArray.int32(3).seq
    a[1] = UNDEF
    v = a.tile(2)
    assert v.has_mask?
    assert_equal [false, true, false, false, true, false], v.is_masked.to_a
  end

  # ------------------------------------------------------------------
  # Write semantics: last-tile-wins for overlapping parent cells
  # ------------------------------------------------------------------

  def test_write_via_single_tile_propagates
    # Writing to view cells that map to a parent cell, no overlap.
    a = CArray.int32(3).seq    # [0, 1, 2]
    v = a.tile(1)              # identity tile, no overlap
    v[0] = 99
    assert_equal 99, a[0]
  end

  def test_write_via_tile_last_wins
    # v[0] and v[3] both map to parent[0] (= tile expansion = all tiles
    # alias same parent block).  Last assignment wins.
    a = CArray.int32(3).seq    # [0, 1, 2]
    v = a.tile(2)              # dim 6, v[0..2] = a, v[3..5] = a
    v[0] = 100
    assert_equal 100, a[0]
    v[3] = 200                 # overwrites v[0]'s effect on a[0]
    assert_equal 200, a[0]
  end

end
