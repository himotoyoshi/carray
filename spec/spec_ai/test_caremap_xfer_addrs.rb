# frozen_string_literal: true
#
# spec_ai/test_caremap_xfer_addrs.rb
#
# M.3: CARemap batched gather/scatter through xfer_addrs.
#
# The xfer_addrs slot is an internal dispatch primitive; per-cell
# (xfer_index) and region-based (xfer_stride) access both route
# through it.  We exercise its correctness from ordinary Ruby via
# region access patterns, plus deeper dispatch chains (view-of-view,
# view-of-view-idx).

require "test/unit"
require_relative "../../lib/carray"

class TestCARemapXferAddrs < Test::Unit::TestCase

  def mk_idx (dims, values)
    a = CArray.new(CA_SIZE, dims); a[] = values; a
  end

  # ---------------------------------------------------------------- region read

  def test_region_read_2d_row
    ref  = CArray.int32(2, 3).seq + 10
    idx  = mk_idx([2, 3], [5, 3, 1, 0, 4, 2])
    view = ref[idx]
    # view = [[15, 13, 11], [10, 14, 12]]
    assert_equal [15, 13, 11], view[0, nil].to_a
    assert_equal [10, 14, 12], view[1, nil].to_a
  end

  def test_region_read_2d_column
    ref  = CArray.int32(2, 3).seq + 10
    idx  = mk_idx([2, 3], [5, 3, 1, 0, 4, 2])
    view = ref[idx]
    assert_equal [13, 14], view[nil, 1].to_a
  end

  def test_region_read_2d_block
    ref  = CArray.int32(3, 4).seq                  # 0..11
    idx  = mk_idx([3, 4], (0..11).to_a)            # identity
    view = ref[idx]
    # Window (1..2, 1..2) -> ref[1,1]=5, [1,2]=6, [2,1]=9, [2,2]=10
    assert_equal [[5, 6], [9, 10]], view[1..2, 1..2].to_a
  end

  # ---------------------------------------------------------------- region write

  def test_region_write_2d_row
    ref  = CArray.float64(2, 3).fill(0.0)
    idx  = mk_idx([2, 3], [5, 3, 1, 0, 4, 2])
    view = ref[idx]
    src  = CArray.float64(3); src[] = [99.0, 88.0, 77.0]
    view[0, nil] = src
    # view row 0 maps to ref.flat[5,3,1] = 99, 88, 77
    assert_equal [[0.0, 77.0, 0.0], [88.0, 0.0, 99.0]], ref.to_a
  end

  # ---------------------------------------------------------------- empty edge

  def test_empty_axis_slice_is_noop
    ref  = CArray.float64(2, 3).fill(0.0)
    idx  = mk_idx([2, 3], [5, 3, 1, 0, 4, 2])
    view = ref[idx]
    sliced = view[0...0, nil]    # empty range over axis 0
    assert_equal 0, sliced.elements
  end

  # ---------------------------------------------------------------- through view-of-view

  def test_through_view_ref_and_view_idx
    base  = CArray.int32(3, 4).seq               # 12 cells
    ref   = base.farray                          # 4 × 3 view (CAStride)
    idx_e = CArray.new(CA_SIZE, [3, 4]).seq.farray # idx also transpose
    view  = ref[idx_e]
    # remap_view.flat[k] = ref.flat[idx.flat[k]]
    ref_flat = ref.flatten.to_a
    idx_flat = idx_e.flatten.to_a
    expected = (0...view.elements).map { |k| ref_flat[idx_flat[k]] }
    assert_equal expected, view.to_a.flatten
  end

  def test_through_view_ref_round_trip
    base = CArray.int32(3, 4).seq
    ref  = base.farray                           # 4 × 3
    idx  = CArray.new(CA_SIZE, [4, 3]).seq       # identity over view
    view = ref[idx]
    assert_equal ref.to_a, view.to_a
  end
end
