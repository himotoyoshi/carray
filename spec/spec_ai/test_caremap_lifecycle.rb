# frozen_string_literal: true
#
# spec_ai/test_caremap_lifecycle.rb
#
# M.5: CARemap lifecycle (allocate/attach/sync/detach) + fill_data +
# mask propagation.
#
# Lifecycle is exercised by any operation that materialises the view:
#   view.to_a            -> attach + xfer_all(GET) + detach
#   view[k] = v          -> attach + xfer_index(PUT) + sync + detach
#   view.fill(v)         -> fill_data
#   view.mask            -> ensures mask propagation (ref.mask -> view.mask)

require "test/unit"
require_relative "../../lib/carray"

class TestCARemapLifecycle < Test::Unit::TestCase

  def mk_idx (dims, values)
    a = CArray.new(CA_SIZE, dims); a[] = values; a
  end

  # ---------------------------------------------------------------- attach (materialise)

  def test_materialise_2d
    ref  = CArray.int32(2, 3).seq + 10                # 10..15
    idx  = mk_idx([2, 3], [5, 3, 1, 0, 4, 2])
    view = ref[idx]
    assert_equal [[15, 13, 11], [10, 14, 12]], view.to_a
  end

  def test_materialise_through_view_parent
    base = CArray.int32(3, 4).seq                     # 0..11
    ref  = base.farray                                # 4 × 3 view
    idx  = mk_idx([4, 3], (0..11).to_a)
    view = ref[idx]
    assert_equal ref.to_a, view.to_a
  end

  # ---------------------------------------------------------------- write-back (sync)

  def test_whole_view_write_back_to_ref
    ref  = CArray.int32(2, 3).fill(0)
    idx  = mk_idx([2, 3], [5, 3, 1, 0, 4, 2])
    view = ref[idx]
    src  = CArray.int32(2, 3); src[] = [[10, 20, 30], [40, 50, 60]]
    view[] = src
    # ref.flat[5]=10, [3]=20, [1]=30, [0]=40, [4]=50, [2]=60
    assert_equal [[40, 30, 60], [20, 50, 10]], ref.to_a
  end

  def test_write_back_preserves_unmapped_cells
    ref  = CArray.int32(2, 3).fill(-1)
    # idx has repeats; cells 1 and 3 never appear, so they stay at -1.
    idx  = mk_idx([2, 3], [0, 2, 4, 0, 2, 4])
    view = ref[idx]
    src  = CArray.int32(2, 3); src[] = [[1, 2, 3], [4, 5, 6]]
    view[] = src
    # ref.flat[0] sequentially 1,4 (last=4); [2] = 2,5 (last=5); [4] = 3,6 (last=6)
    # ref.flat[1] and [3] untouched.
    assert_equal [[4, -1, 5], [-1, 6, -1]], ref.to_a
  end

  # ---------------------------------------------------------------- fill_data

  def test_fill_broadcasts_scalar
    ref  = CArray.int32(2, 3).fill(-1)
    idx  = mk_idx([2, 3], (0..5).to_a)                # identity full coverage
    view = ref[idx]
    view.fill(42)
    assert_equal [[42, 42, 42], [42, 42, 42]], ref.to_a
  end

  def test_fill_only_touches_mapped_cells
    ref  = CArray.int32(2, 3).fill(-1)
    idx  = mk_idx([2, 3], [0, 2, 4, 0, 2, 4])         # only hits 0,2,4
    view = ref[idx]
    view.fill(99)
    assert_equal [[99, -1, 99], [-1, 99, -1]], ref.to_a
  end

  def test_fill_2d
    ref  = CArray.float64(2, 3).fill(0.0)
    idx  = mk_idx([2, 3], (0..5).to_a)                # identity full coverage
    view = ref[idx]
    view.fill(7.5)
    assert_equal [[7.5, 7.5, 7.5], [7.5, 7.5, 7.5]], ref.to_a
  end

  # ---------------------------------------------------------------- mask propagation

  def test_mask_propagates_through_view
    ref = CArray.int32(2, 3).seq + 10                 # 10..15
    ref[0, 0] = UNDEF                                 # ref.flat[0] masked
    ref[1, 0] = UNDEF                                 # ref.flat[3] masked
    idx = mk_idx([2, 3], [5, 0, 2, 3, 1, 4])
    view = ref[idx]
    # view masked where idx -> {0, 3}: positions where idx==0 or idx==3
    # idx.flat = [5,0,2,3,1,4] -> masked at flat positions 1 (idx=0) and 3 (idx=3)
    expected_mask = [[false, true, false], [true, false, false]]
    assert_equal expected_mask, view.mask.to_a
  end

  def test_no_mask_when_ref_unmasked
    ref  = CArray.int32(2, 3).seq
    idx  = mk_idx([2, 3], (0..5).to_a)
    view = ref[idx]
    refute view.has_mask?, "view must not have a mask when ref is unmasked"
    assert_equal ref.to_a, view.to_a
  end

  # ---------------------------------------------------------------- N-D

  def test_materialise_3d
    ref  = CArray.float64(2, 2, 2).seq                # 0..7
    idx  = mk_idx([2, 2, 2], [7, 6, 5, 4, 3, 2, 1, 0])
    view = ref[idx]
    assert_equal [7.0, 6.0, 5.0, 4.0, 3.0, 2.0, 1.0, 0.0], view.to_a.flatten
  end
end
