require "test/unit"
require "carray"

# Compose-fold + mask interaction tests.
#
# Compose-fold (ce7b90d..bf4415e) folds CAStride chains to the entity
# (or first non-CAStride ancestor) for copy_data / sync_data /
# fill_data / attach.  The mask of a CAStride is itself a CAStride
# (ca_stride_func_create_mask in ext/ca_obj_stride.c), built with
# mask-byte-scaled strides, so it independently folds when accessed.
#
# These tests target paths where the folded element traversal and the
# folded mask traversal must agree:
#
#   - copy_data  (view.to_ca, view operations that materialise)
#   - sync_data  (attach! block, scatter write-back)
#   - fill_data  (view.fill(val), view.fill(UNDEF))
#
# across the CAStride subclasses (CARefer / CABlock / CATranspose /
# CAFarray / CARepeat) and across composition patterns where the
# leaf's parent chain has multiple CAStride links.

# ---------------------------------------------------------------- #
# 1. to_ca (copy_data) -- mask round-trip through chains
# ---------------------------------------------------------------- #

class TestComposeFoldMaskCopyData < Test::Unit::TestCase
  def test_to_ca_preserves_mask_block_of_transposed
    # Entity mask + chain: refer -> transpose -> block.  to_ca pulls
    # through compose-fold; the mask must be the parallel composed
    # walk of entity.mask.
    src = CArray.int32(3, 4).seq
    src.mask = [[0, 1, 0, 1],
                [1, 0, 1, 0],
                [0, 1, 0, 1]]                    # (i + j).odd?
    chain = src.transpose[1..2, nil]   # CABlock on CATranspose, shape (2, 3)
    copy = chain.to_ca
    assert_equal(chain.to_a, copy.to_a)
    assert_equal(chain.is_masked.to_a, copy.is_masked.to_a,
                 "to_ca through CABlock-of-CATranspose must preserve mask layout")
  end

  def test_to_ca_preserves_mask_refer_reshape_of_block
    src = CArray.float64(4, 6).seq
    src.mask = [[0, 0, 1, 0, 0, 0]] * 4              # column 2 masked
    # Contiguous row-slice block, then reshape -- both pure CAStride.
    chain = src[1..2, nil].refer(:float64, [12])
    copy = chain.to_ca
    assert_equal(chain.to_a, copy.to_a)
    assert_equal(chain.is_masked.to_a, copy.is_masked.to_a)
    # Sanity: row 1 col 2 (chain index 2) and row 2 col 2 (chain idx 8)
    # are the masked ones.
    expected_mask = [false, false, true, false, false, false, false, false, true, false, false, false]
    assert_equal(expected_mask, copy.is_masked.to_a)
  end

  def test_to_ca_non_contig_column_slice_with_mask
    # Column slice is non-contig: forces the gather path (not the
    # alias fast path).  Mask gather must follow the same composed
    # stride pattern.
    src = CArray.int32(4, 5).seq
    src.mask = [[0]*5, [0]*5, [1]*5, [0]*5]           # row 2 masked
    col = src[nil, 1..2]
    copy = col.to_ca
    assert_equal(col.to_a, copy.to_a)
    assert_equal([[false,false],[false,false],[true,true],[false,false]], copy.is_masked.to_a)
  end

  def test_to_ca_negative_stride_with_mask
    # Negative-stride view: composed stride is negative; mask must
    # be gathered with the parallel negative stride (mask-byte units).
    src = CArray.float64(10).seq
    src.mask = [0, 0, 0, 0, 0, 0, 0, 1, 0, 0]         # idx 7 masked
    rev = src.as_strided(shape: [10], strides: [-8], offset: 72)
    copy = rev.to_ca
    # Compare raw data with mask stripped (to_a renders UNDEF for masked).
    assert_equal((0..9).to_a.reverse.map(&:to_f), copy.value.to_a)
    # Original index 7 was masked => reversed view index 2.
    expected = [false, false, true, false, false, false, false, false, false, false]
    assert_equal(expected, copy.is_masked.to_a,
                 "reversed view to_ca must mirror mask in reverse too")
  end

  def test_to_ca_four_level_chain_with_mask
    # Block of refer-reshape of transpose of refer-reshape.  Every
    # link folds; mask must walk the same fold.
    src = CArray.int32(20).seq
    src.mask = (0...20).map { |i| i % 5 == 0 ? 1 : 0 }
    chain = src.refer(:int32, [4, 5])     # CARefer reshape
                .transpose               # (5, 4)
                .refer(:int32, [20])      # CARefer flatten
                [4..15]                   # CABlock contig slice
    copy = chain.to_ca
    assert_equal(chain.to_a, copy.to_a)
    assert_equal(chain.is_masked.to_a, copy.is_masked.to_a,
                 "4-level CAStride chain must preserve mask under compose-fold")
  end
end

# ---------------------------------------------------------------- #
# 2. sync_data (attach! block, scatter write-back) -- mask edits
# ---------------------------------------------------------------- #

class TestComposeFoldMaskSyncData < Test::Unit::TestCase
  def test_attach_bang_view_mask_edit_propagates_to_entity
    # Edit the mask on a CAStride view inside attach!; the scatter
    # path must write the mask change back to the entity.
    src = CArray.int32(10).seq
    src.mask = 0
    view = src[2..7]                       # contig CABlock => alias path
    view.attach! do |v|
      v[1] = UNDEF                     # masks view index 1 = entity idx 3
    end
    assert_equal(true, src.is_masked[3])
    assert_equal(false, src.is_masked[2])
    assert_equal(false, src.is_masked[4])
  end

  def test_attach_bang_non_contig_view_mask_edit_propagates
    # Non-contig column slice: forces gather-on-attach / scatter-on-detach.
    # Mask scatter must follow composed stride.
    src = CArray.int32(4, 5).seq
    src.mask = 0
    col = src[nil, 1..2]
    col.attach! do |c|
      c[2, 0] = UNDEF                  # entity row 2, col 1
      c[1, 1] = UNDEF                  # entity row 1, col 2
    end
    assert_equal(true, src.is_masked[2, 1])
    assert_equal(true, src.is_masked[1, 2])
    assert_equal(false, src.is_masked[2, 2])
    assert_equal(false, src.is_masked[1, 1])
  end

  def test_attach_bang_chain_mask_edit_propagates
    # CABlock of CATranspose: write-back must compose mask strides
    # through both links to land in the right entity position.
    src = CArray.int32(3, 4).seq
    src.mask = 0
    chain = src.transpose[1..2, nil]    # shape (2, 3) viewing src.T rows 1..2
    chain.attach! do |c|
      c[0, 0] = UNDEF                  # transposed[1,0] = src[0,1]
    end
    assert_equal(true, src.is_masked[0, 1],
                 "mask edit through CABlock-of-CATranspose must land at src[0,1]")
  end

  def test_index_assignment_propagates_mask_through_view
    # Direct []= on view (no explicit attach! block): also goes through
    # compose-fold sync via store_index.
    src = CArray.float64(5, 5).seq
    src.mask = 0
    view = src[1..3, 1..3]
    view[0, 0] = UNDEF
    assert_equal(true, src.is_masked[1, 1])
  end
end

# ---------------------------------------------------------------- #
# 3. fill_data -- view.fill(val) and view.fill(UNDEF)
# ---------------------------------------------------------------- #

class TestComposeFoldMaskFillData < Test::Unit::TestCase
  def test_fill_value_clears_mask_in_filled_region_only
    # rb_ca_fill on a masked entity: when filling with a concrete
    # value, ca_fill is called on the mask with 0 first (clears mask
    # in the *view's* region), then on the elements.  Both go through
    # CAStride fill_data + compose-fold; only entity positions covered
    # by the view should change.
    src = CArray.int32(10).seq
    src.mask = CArray.boolean(10).fill(1)   # everything masked
    view = src[3..6]                         # contig CABlock, view of 4 elements
    view.fill(42)
    # In-view positions: unmasked and = 42
    assert_equal([42, 42, 42, 42], view.to_a)
    assert_equal([false, false, false, false], view.is_masked.to_a)
    # Out-of-view positions: mask preserved (still 1)
    assert_equal(true, src.is_masked[0])
    assert_equal(true, src.is_masked[2])
    assert_equal(true, src.is_masked[7])
    assert_equal(true, src.is_masked[9])
  end

  def test_fill_undef_sets_mask_in_view_region
    src = CArray.int32(10).seq
    src.mask = 0
    view = src[3..6]
    view.fill(UNDEF)
    # Mask set on entity positions 3..6
    assert_equal([false, false, false, true, true, true, true, false, false, false], src.is_masked.to_a)
  end

  def test_fill_undef_through_non_contig_view
    # Column slice: fill_data goes through the scatter path with
    # composed stride; the mask fill_data must use the parallel
    # composed mask stride.
    src = CArray.int32(4, 5).seq
    src.mask = 0
    col = src[nil, 1..2]
    col.fill(UNDEF)
    expected = [[false, true, true, false, false],
                [false, true, true, false, false],
                [false, true, true, false, false],
                [false, true, true, false, false]]
    assert_equal(expected, src.is_masked.to_a)
  end

  def test_fill_undef_through_chain
    # Chain: CABlock of CATranspose.  Mask fill must reach the right
    # entity columns.
    src = CArray.int32(3, 4).seq
    src.mask = 0
    chain = src.transpose[1..2, nil]    # transposed shape (4, 3), slice rows 1..2
    chain.fill(UNDEF)
    # transposed[1..2, :] covers transposed indices (1..2, 0..2) which
    # correspond to src[(0..2), (1..2)].
    expected = [[false, true, true, false],
                [false, true, true, false],
                [false, true, true, false]]
    assert_equal(expected, src.is_masked.to_a)
  end
end

# ---------------------------------------------------------------- #
# 4. CARepeat (stride=0) -- mask broadcasts through compose-fold
# ---------------------------------------------------------------- #

class TestComposeFoldMaskCARepeat < Test::Unit::TestCase
  def test_repeat_mask_to_ca_broadcasts_correctly
    # Entity mask on a 3-element src, repeated 4 times along axis 0.
    # to_ca's compose-fold must broadcast both elements and mask.
    src = CArray.int32(3).seq
    src.mask = [0, 1, 0]
    rep = src[4, :%]                     # CARepeat shape (4, 3), axis 0 stride 0
    copy = rep.to_ca
    expected_data = [[0,1,2]] * 4
    expected_mask = [[false, true, false]] * 4
    assert_equal(expected_data, copy.value.to_a)
    assert_equal(expected_mask, copy.is_masked.to_a,
                 "CARepeat mask must broadcast through compose-fold copy_data")
  end

  def test_repeat_of_block_mask_compose
    # CARepeat over a non-entity parent (CABlock).  Mask must compose
    # through both the block's stride and the repeat's stride=0 axis.
    src = CArray.int32(6).seq
    src.mask = [0, 0, 1, 0, 0, 1]
    blk = src[2..5]                      # CABlock view, mask = [1, 0, 0, 1]
    rep = blk[3, :%]                     # CARepeat (3, 4)
    copy = rep.to_ca
    assert_equal([[2,3,4,5]] * 3, copy.value.to_a)
    assert_equal([[true,false,false,true]] * 3, copy.is_masked.to_a)
  end
end

# ---------------------------------------------------------------- #
# 5. is_masked / mask reads through chains (compose-fold of mask CAStride)
# ---------------------------------------------------------------- #

class TestComposeFoldMaskRead < Test::Unit::TestCase
  def test_is_masked_through_chain_matches_entity
    # The mask itself is a CAStride; is_masked composes it.  Compare
    # against an explicit gather via per-index lookups to guarantee
    # the composed walk is right.
    src = CArray.float64(5, 6).seq
    src.mask = Array.new(5) { |i|
      Array.new(6) { |j| ((i * 7 + j * 3) % 5).zero? ? 1 : 0 }
    }
    chain = src.transpose[1..4, 1..3]   # shape (4, 3)
    composed_mask = chain.is_masked.to_a
    # Compute expected by walking chain indices through transpose: chain[a,b]
    # = src.transpose[1+a, 1+b] = src[1+b, 1+a].
    expected = Array.new(4) do |a|
      Array.new(3) { |b| src.is_masked[1 + b, 1 + a] }
    end
    assert_equal(expected, composed_mask,
                 "is_masked through CABlock-of-CATranspose must compose mask strides correctly")
  end

  def test_entity_mask_update_visible_through_existing_view
    # After view is built, mutate entity mask; view (which holds no
    # buffered mask copy: it just composes on read) must see the new
    # state.
    src = CArray.int32(8).seq
    src.mask = 0
    view = src[2..5]
    assert_equal([false, false, false, false], view.is_masked.to_a)
    src.mask[3] = 1                       # entity index 3 = view index 1
    assert_equal([false, true, false, false], view.is_masked.to_a,
                 "view.mask should reflect live entity.mask after compose-fold")
  end
end

# ---------------------------------------------------------------- #
# 6. Round-trip: write into view, read mask back from entity (and vice versa)
# ---------------------------------------------------------------- #

class TestComposeFoldMaskRoundTrip < Test::Unit::TestCase
  def test_mask_assigned_via_chain_lands_correctly_on_entity
    # Build a 2-link chain, set mask via assignment on the chain,
    # check the entity sees it at the composed positions.
    src = CArray.int32(4, 5).seq
    src.mask = 0
    chain = src.transpose[nil, 1..2]   # shape (5, 2), srcT[k, j] = src[j, k]
    chain.mask = Array.new(5) { |a|
      Array.new(2) { |b| (a + b).odd? ? 1 : 0 }
    }
    # chain[a, b] = src[1+b, a], so src[1+b, a] is masked iff (a+b).odd?
    5.times do |a|
      2.times do |b|
        assert_equal((a + b).odd? ? true : false, src.is_masked[1 + b, a],
                     "mask assigned via chain[#{a},#{b}] should land at src[#{1+b},#{a}]")
      end
    end
  end

  def test_entity_value_change_seen_by_chained_view_after_attach
    src = CArray.int32(10).seq
    src.mask = 0
    view = src.refer(:int32, [2, 5])
    src[3] = -99
    src.mask[7] = 1
    # view[0, 3] = src[3]; view[1, 2] = src[7]
    assert_equal(-99, view[0, 3])
    assert_equal(true, view.is_masked[1, 2])
  end
end
