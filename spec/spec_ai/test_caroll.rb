# frozen_string_literal: true
#
# spec_ai/test_caroll.rb
#
# COMPOSITE_FAMILY Phase 2 (T.4): CARoll view tests.
#
# CARoll = same-shape cyclic shift view (= typedef CATile, Phase G
# CAShift = CAWindow precedent).  Output shape = parent shape.
# 1D: 2 regions (= §2.3.5.1 hand-rolled concat equivalent).
# N-D: 2^K regions where K = number of non-zero shift axes.
#
# Reference: devel/PROPOSAL_CATILE.md §1.1 (R-c migrate) / §1.3 (H-d typedef)

require "test/unit"
require_relative "../../lib/carray"

class TestCARoll < Test::Unit::TestCase

  # ------------------------------------------------------------------
  # Class identity (CARoll < CATile < CAView)
  # ------------------------------------------------------------------

  def test_returns_caroll_instance
    a = CArray.int32(5).seq
    v = a.roll(1)
    assert_kind_of CARoll, v
    assert_kind_of CATile, v          # typedef parent
    assert_kind_of CAView, v
    assert_kind_of CArray, v
  end

  def test_shape_preserved_1d
    a = CArray.int32(5).seq
    v = a.roll(2)
    assert_equal a.dim, v.dim
    assert_equal a.elements, v.elements
  end

  def test_shape_preserved_2d
    a = CArray.int32(3, 4).seq
    v = a.roll(1, 2)
    assert_equal a.dim, v.dim
  end

  # ------------------------------------------------------------------
  # 1D byte parity vs hand-rolled concat
  # (= §2.3.5.1 degenerate performance gate, structural form)
  # ------------------------------------------------------------------

  def test_1d_roll_right_1
    a = CArray.int32(5).seq           # [0, 1, 2, 3, 4]
    assert_equal [4, 0, 1, 2, 3], a.roll(1).to_a
  end

  def test_1d_roll_right_2
    a = CArray.int32(5).seq
    assert_equal [3, 4, 0, 1, 2], a.roll(2).to_a
  end

  def test_1d_roll_left_1
    a = CArray.int32(5).seq
    assert_equal [1, 2, 3, 4, 0], a.roll(-1).to_a
  end

  def test_1d_roll_left_2
    a = CArray.int32(5).seq
    assert_equal [2, 3, 4, 0, 1], a.roll(-2).to_a
  end

  def test_1d_roll_zero_is_identity
    a = CArray.int32(5).seq
    assert_equal a.to_a, a.roll(0).to_a
  end

  def test_1d_roll_wraps_modulo_dim
    a = CArray.int32(5).seq
    # roll(7) = roll(7 % 5) = roll(2)
    assert_equal a.roll(2).to_a, a.roll(7).to_a
    # roll(-3) = roll(2) modulo 5
    assert_equal a.roll(2).to_a, a.roll(-3).to_a
    # roll(100) on dim 5 = roll(0) (= 100 % 5 == 0)
    assert_equal a.to_a, a.roll(100).to_a
  end

  # ------------------------------------------------------------------
  # 2D byte parity (axis-0 / axis-1 / both)
  # ------------------------------------------------------------------

  def test_2d_axis0_only_roll_1
    a = CArray.int32(3, 4).seq        # rows [0..3], [4..7], [8..11]
    v = a.roll(1, 0)                  # axis 0 right by 1
    expected = [[8, 9, 10, 11], [0, 1, 2, 3], [4, 5, 6, 7]]
    assert_equal expected, v.to_a
  end

  def test_2d_axis1_only_roll_2
    a = CArray.int32(3, 4).seq
    v = a.roll(0, 2)                  # axis 1 right by 2
    expected = [[2, 3, 0, 1], [6, 7, 4, 5], [10, 11, 8, 9]]
    assert_equal expected, v.to_a
  end

  def test_2d_both_axes_roll
    a = CArray.int32(3, 4).seq
    v = a.roll(1, 1)                  # both axes right by 1
    expected = [[11, 8, 9, 10], [3, 0, 1, 2], [7, 4, 5, 6]]
    assert_equal expected, v.to_a
  end

  # ------------------------------------------------------------------
  # Argument handling
  # ------------------------------------------------------------------

  def test_missing_axes_default_to_zero
    a = CArray.int32(3, 4).seq
    # 1 arg on 2D parent → axis 0 only, axis 1 = 0
    v = a.roll(1)
    expected = [[8, 9, 10, 11], [0, 1, 2, 3], [4, 5, 6, 7]]
    assert_equal expected, v.to_a
  end

  def test_too_many_args_raises
    a = CArray.int32(5).seq
    assert_raise(ArgumentError) { a.roll(1, 2) }
  end

  def test_no_args_is_identity
    a = CArray.int32(5).seq
    v = a.roll
    assert_equal a.to_a, v.to_a
  end

  # ------------------------------------------------------------------
  # Dtype variety
  # ------------------------------------------------------------------

  def test_data_type_float64
    a = CArray.float64(4).seq * 1.5    # [0.0, 1.5, 3.0, 4.5]
    assert_equal [4.5, 0.0, 1.5, 3.0], a.roll(1).to_a
  end

  def test_data_type_int8
    a = CArray.int8(3).tap { |__a| __a[] = [10, 20, 30] }
    assert_equal [30, 10, 20], a.roll(1).to_a
  end

  # ------------------------------------------------------------------
  # Descriptor accessor
  # ------------------------------------------------------------------

  def test_descriptor_1d_normalised
    a = CArray.int32(5).seq
    # roll(7) normalised to 2
    d = a.roll(7)._roll_descriptor
    assert_equal [2], d[:shifts]
    assert_equal 2, d[:n_regions]
    assert_equal 1, d[:ndim]
  end

  def test_descriptor_2d_n_regions_4
    a = CArray.int32(3, 4).seq
    d = a.roll(1, 2)._roll_descriptor
    assert_equal [1, 2], d[:shifts]
    assert_equal 4, d[:n_regions]      # K=2 → 2^2 = 4
  end

  def test_descriptor_partial_shift_n_regions_2
    a = CArray.int32(3, 4).seq
    d = a.roll(0, 2)._roll_descriptor  # only axis 1 shifted
    assert_equal [0, 2], d[:shifts]
    assert_equal 2, d[:n_regions]      # K=1 → 2^1 = 2
  end

  def test_descriptor_zero_shift_n_regions_1
    a = CArray.int32(5).seq
    d = a.roll(0)._roll_descriptor
    assert_equal [0], d[:shifts]
    assert_equal 1, d[:n_regions]      # K=0 → 2^0 = 1 (full parent)
  end

  # ------------------------------------------------------------------
  # Mask propagation
  # ------------------------------------------------------------------

  def test_mask_propagates
    a = CArray.int32(5).seq
    a[2] = UNDEF
    v = a.roll(1)
    assert v.has_mask?
    # a[2] = masked, rolled right by 1 → mask appears at v[3]
    assert_equal [false, false, false, true, false], v.is_masked.to_a
  end

  # ------------------------------------------------------------------
  # in-place roll via `ca[] = ca.roll(...)` (3.0: `roll!` retired)
  # ------------------------------------------------------------------

  def test_roll_view_self_assignment_modifies_in_place
    a = CArray.int32(5).seq
    a[] = a.roll(1)
    assert_equal [4, 0, 1, 2, 3], a.to_a
  end

  # ------------------------------------------------------------------
  # errors
  # ------------------------------------------------------------------

  def test_error_unknown_keyword
    a = CArray.float64(4, 5)
    # Shifts are positional; a keyword must be loud, not a NUM2SIZE TypeError.
    assert_raise(ArgumentError) { a.roll(1, axis: 0) }
    assert_raise(ArgumentError) { a.roll(foo: 1) }
  end

  def test_error_too_many_axes
    a = CArray.float64(4, 5)
    assert_raise(ArgumentError) { a.roll(1, 1, 1) }
  end

end
