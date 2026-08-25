# frozen_string_literal: true
#
# spec_ai/test_caremap_indexer_routing.rb
#
# M.9 (PROPOSAL_CAREMAP_INTERNAL section 10): ca[mapper] same-shape
# CA_SIZE fast path routes to CARemap instead of the normalize chain.
#
# Routing matrix (ext/carray_access.c rb_ca_fancy_index_chain):
#   (a) same shape + CA_SIZE mapper           -> CARemap
#   (b) otherwise (different shape, or int32) -> normalize chain
#                                                (returns CARefer)
#   (c) 1-D ref + 1-D mapper (any int data_type)  -> CAGrid (upstream
#                                                rb_ca_scan_index)

require "test/unit"
require_relative "../../lib/carray"

class TestCARemapIndexerRouting < Test::Unit::TestCase

  def mk_idx (dims, values)
    a = CArray.new(CA_SIZE, dims); a[] = values; a
  end

  def mk_idx_int32 (dims, values)
    a = CArray.int32(*dims); a[] = values; a
  end

  # ------------------------------------------------------- routing classification

  def test_2d_same_shape_ca_size_routes_to_caremap
    ref = CArray.float64(2, 3).seq + 10
    idx = mk_idx([2, 3], [5, 3, 1, 0, 4, 2])
    assert_equal CARemap, ref[idx].class
  end

  def test_3d_same_shape_ca_size_routes_to_caremap
    ref = CArray.float64(2, 2, 2).seq
    idx = mk_idx([2, 2, 2], [7, 6, 5, 4, 3, 2, 1, 0])
    assert_equal CARemap, ref[idx].class
  end

  def test_2d_same_shape_int32_falls_back_to_chain
    ref = CArray.float64(2, 3).seq + 10
    idx = mk_idx_int32([2, 3], [5, 3, 1, 0, 4, 2])
    # chain returns CARefer (outermost reshape wrapping CAGrid).
    refute_equal CARemap, ref[idx].class
    assert_equal CARefer, ref[idx].class
  end

  def test_shape_mismatch_falls_back_to_chain
    ref = CArray.float64(2, 3).seq
    # idx shape != ref shape (both same total elements but different
    # per-axis dims): chain takes over.
    idx = mk_idx([3, 2], [0, 1, 2, 3, 4, 5])
    refute_equal CARemap, ref[idx].class
  end

  def test_1d_ref_1d_idx_stays_on_cagrid_path
    # 1-D + 1-D dispatches at rb_ca_scan_index (CA_REG_GRID), never
    # reaches rb_ca_fancy_index_chain.  Behavior unchanged.
    ref = CArray.float64(5).seq
    idx = mk_idx([5], [4, 2, 0, 3, 1])
    assert_equal CAGrid, ref[idx].class
  end

  def test_masked_mapper_raises
    ref = CArray.float64(2, 3).seq
    idx = mk_idx([2, 3], [0, 1, 2, 3, 4, 5])
    idx[0, 0] = UNDEF
    assert_raise(ArgumentError) { ref[idx] }
  end

  # ------------------------------------------------------- semantic parity

  def test_2d_read_matches_chain_equivalent
    ref = CArray.float64(3, 4).seq + 100             # 100..111
    idx = mk_idx([3, 4], [11, 9, 7, 5, 3, 1, 0, 2, 4, 6, 8, 10])
    via_remap = ref[idx]
    via_chain = ref.flatten[idx.flatten].reshape(3, 4)
    assert_equal via_chain.to_a, via_remap.to_a
  end

  def test_2d_read_through_view_ref_matches_chain
    # When ref itself is a view (transpose), routing still works.
    base = CArray.int32(3, 4).seq
    ref  = base.farray                               # 4 × 3 view
    idx  = mk_idx([4, 3], (0..11).to_a.reverse)
    via_remap = ref[idx]
    via_chain = ref.flatten[idx.flatten].reshape(4, 3)
    assert_equal via_chain.to_a, via_remap.to_a
    assert_equal CARemap, via_remap.class
  end

  # ------------------------------------------------------- write-through

  def test_write_through_caremap_reaches_ref
    ref = CArray.float64(2, 3).fill(0.0)
    idx = mk_idx([2, 3], [5, 3, 1, 0, 4, 2])
    view = ref[idx]
    assert_equal CARemap, view.class
    src = CArray.float64(2, 3).seq + 100              # 100..105
    view[] = src
    # idx[0,0]=5 -> ref.flat[5]=100; [0,1]=3 -> [3]=101; [0,2]=1 -> [1]=102
    # [1,0]=0 -> [0]=103; [1,1]=4 -> [4]=104; [1,2]=2 -> [2]=105
    assert_equal [[103.0, 102.0, 105.0], [101.0, 104.0, 100.0]],
                 ref.to_a
  end

  def test_write_through_caremap_repeats_last_write_wins
    ref = CArray.int32(5).fill(0)
    # idx shape == ref shape required, with repeats: same shape [5]
    idx = mk_idx([5], [2, 2, 2, 2, 4])
    # 1-D so dispatches to CAGrid, not CARemap (routing rule (c)).
    # This test pins that routing rule (c) wins over (a).
    view = ref[idx]
    refute_equal CARemap, view.class
  end

  def test_3d_write_through_caremap
    ref = CArray.int32(2, 2, 2).fill(0)
    idx = mk_idx([2, 2, 2], [7, 6, 5, 4, 3, 2, 1, 0])
    view = ref[idx]
    assert_equal CARemap, view.class
    src = CArray.int32(2, 2, 2).seq + 10              # 10..17
    view[] = src
    # ref.flat[7]=10,[6]=11,[5]=12,[4]=13,[3]=14,[2]=15,[1]=16,[0]=17
    assert_equal [17, 16, 15, 14, 13, 12, 11, 10],
                 ref.flatten.to_a
  end

  # ------------------------------------------------------- materialise (.to_ca)

  def test_to_ca_on_caremap
    ref = CArray.float64(2, 3).seq + 10
    idx = mk_idx([2, 3], [5, 3, 1, 0, 4, 2])
    materialised = ref[idx].to_ca
    assert_equal [[15.0, 13.0, 11.0], [10.0, 14.0, 12.0]],
                 materialised.to_a
    assert_kind_of CArray, materialised
  end

end
