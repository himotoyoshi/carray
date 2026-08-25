# frozen_string_literal: true
#
# spec_ai/test_caremap_xfer_stride.rb
#
# M.4: CARemap whole-view + region-based access semantics.
#
# `view.to_a` materialises through xfer_all; `view[range, ...]` and
# `view[range, ...] = src` exercise xfer_stride; both transitively
# resolve through xfer_addrs.  Exercised from ordinary Ruby.

require "test/unit"
require_relative "../../lib/carray"

class TestCARemapXferStride < Test::Unit::TestCase

  def mk_idx (dims, values)
    a = CArray.new(CA_SIZE, dims); a[] = values; a
  end

  # ---------------------------------------------------------------- whole-view (xfer_all)

  def test_to_a_identity_2d
    ref  = CArray.float64(2, 3).seq
    idx  = mk_idx([2, 3], [0, 1, 2, 3, 4, 5])
    view = ref[idx]
    assert_equal ref.to_a, view.to_a
  end

  def test_to_a_permutation_2d
    ref  = CArray.int32(2, 3).seq + 10
    idx  = mk_idx([2, 3], [5, 3, 1, 0, 4, 2])
    view = ref[idx]
    assert_equal [[15, 13, 11], [10, 14, 12]], view.to_a
  end

  def test_whole_view_put_2d
    ref  = CArray.int32(2, 3).fill(0)
    idx  = mk_idx([2, 3], [5, 3, 1, 0, 4, 2])
    src  = CArray.int32(2, 3).seq
    view = ref[idx]
    view[] = src
    # writes ref.flat[5]=0,[3]=1,[1]=2,[0]=3,[4]=4,[2]=5
    assert_equal [[3, 2, 5], [1, 4, 0]], ref.to_a
  end

  def test_to_a_through_view_parent
    base = CArray.int32(3, 4).seq
    ref  = base.farray                                  # 4 × 3 view
    idx  = mk_idx([4, 3], (0..11).to_a)                 # identity over view
    view = ref[idx]
    assert_equal ref.to_a, view.to_a
  end

  # ---------------------------------------------------------------- region (xfer_stride GET)

  def test_region_read_2d_full
    ref  = CArray.int32(2, 3).seq + 10
    idx  = mk_idx([2, 3], [5, 3, 1, 0, 4, 2])
    view = ref[idx]
    assert_equal [[15, 13, 11], [10, 14, 12]], view[nil, nil].to_a
  end

  def test_region_read_2d_subregion
    ref  = CArray.int32(3, 4).seq                       # 0..11
    idx  = mk_idx([3, 4], (0..11).to_a)                 # identity
    view = ref[idx]
    # Window (1..2, 1..2) -> ref[1,1]=5, [1,2]=6, [2,1]=9, [2,2]=10
    assert_equal [[5, 6], [9, 10]], view[1..2, 1..2].to_a
  end

  def test_region_read_2d_row_with_step
    ref  = CArray.int32(2, 6).seq                       # 0..11
    idx  = mk_idx([2, 6], (0..11).to_a)                 # identity
    view = ref[idx]
    # Row 0 with step-2 along axis 1 via ArithSeq
    assert_equal [0, 2, 4], view[0, 0.step(by: 2, to: 5)].to_a
  end

  # ---------------------------------------------------------------- region (xfer_stride PUT)

  def test_region_write_2d_subregion
    ref  = CArray.int32(3, 4).fill(-1)
    idx  = mk_idx([3, 4], (0..11).to_a)                 # identity
    view = ref[idx]
    src  = CArray.int32(2, 2); src[] = [[100, 200], [300, 400]]
    view[1..2, 1..2] = src
    assert_equal [[-1, -1, -1, -1],
                  [-1, 100, 200, -1],
                  [-1, 300, 400, -1]], ref.to_a
  end
end
