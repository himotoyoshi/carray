# Tests for the CARefer-flatten path used by CA_REG_ADDRESS_COMPLEX,
# i.e. when CArray#[] / #[]= dispatches a flat-address spec (single
# Range, single nil, integer past last dim, etc.) against a multi-dim
# array.  The fetch/store path is roughly:
#
#   self                       (multi-dim, possibly non-contig view)
#     -> rb_ca_refer_new_flatten(self)     # CARefer ndim=1 over self
#       -> rb_ca_ref_block(flat, ...)      # CABlock over the flat CARefer
#         -> attach -> compose_to_root -> entity bytes
#
# Two ways this used to go wrong before commit 79619c4:
#
#   (1) `rake spec` loaded a stale system-installed carray_ext.bundle
#       (CComplex still present) instead of the dev build.
#   (2) ca_stride_compose_through validated stride wrap with
#       `max_advance < parent->dim[k]` only, ignoring where the base
#       sits in that dim.  A small forward step starting near the
#       end of a parent dim wrapped silently into the next parent
#       dim with the wrong stride -- so the flatten of a non-contig
#       CABlock read adjacent storage rather than the view's logical
#       iteration order.
#
# These tests exercise both directions (read + write) and a few
# stride patterns (reverse, step>1, transpose, repeat) so a future
# regression in the compose-fold validation can't reintroduce the
# bug undetected.

$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
$LOAD_PATH.unshift File.expand_path("../../ext", __dir__)

require "carray"
require "test/unit"

class TestFlattenRefer < Test::Unit::TestCase

  # ----------------------------------------------------------------
  # The original CABlock_spec.rb:149 scenario, exhaustively probed.
  # ----------------------------------------------------------------

  def setup
    @a = CArray.new(CA_INT32, [4, 4]).seq!     # 0..15 row-major
    @b = @a[0..2, 0..2]                         # 3x3 non-contig CABlock
    @c = @b[1..0, 0..1]                         # 2x2 reversed-row block
  end

  def test_reversed_block_to_a
    assert_equal [[4, 5], [0, 1]], @c.to_a
  end

  def test_reversed_block_flat_index_all
    assert_equal [4, 5, 0, 1], @c[nil].to_a
  end

  def test_reversed_block_single_int_flat_index
    assert_equal 4, @c[0]
    assert_equal 5, @c[1]
    assert_equal 0, @c[2]
    assert_equal 1, @c[3]
  end

  def test_reversed_block_flat_range_index
    # All Range slices over the flat iteration order.  The base
    # position of each slice within @c's logical 2x2 lands at
    # different (row, col) coordinates -- some span the dim
    # boundary, some don't.  The compose-fold bug always wrapped
    # into the wrong row regardless of slice extent.
    assert_equal [4],          @c[0..0].to_a
    assert_equal [4, 5],       @c[0..1].to_a
    assert_equal [5, 0],       @c[1..2].to_a    # crosses row boundary
    assert_equal [0, 1],       @c[2..3].to_a
    assert_equal [4, 5, 0],    @c[0..2].to_a
    assert_equal [5, 0, 1],    @c[1..3].to_a
    assert_equal [4, 5, 0, 1], @c[0..3].to_a
  end

  def test_reversed_block_flat_array_index
    # The CA_REG_ADDRESS_COMPLEX dispatch also handles array-form
    # flat indices.  Same iteration order must apply.
    assert_equal [0],    @c[[2]].to_a
    assert_equal [5, 0], @c[[1, 2]].to_a
  end

  def test_reversed_block_flat_write_propagates_to_entity
    # `[nil] = val` ultimately writes through every storage layer
    # back to @a.  Before the fix it was a no-op: the temporary
    # flat CARefer's compose-fold computed the wrong destination
    # bytes, so the scatter went nowhere.
    @c[nil] = 99
    assert_equal [[99, 99], [99, 99]], @c.to_a
    # The 2x2 region in @a that @c covers (a[0..1, 0..1]) must
    # also be all 99 -- read straight from @a, no view involved.
    assert_equal [[99, 99, 2, 3],
                  [99, 99, 6, 7],
                  [ 8,  9, 10, 11],
                  [12, 13, 14, 15]], @a.to_a
  end

  def test_reversed_block_flat_range_write_propagates_to_entity
    @c[1..2] = 77   # writes @c[0,1] and @c[1,0] = @a[1,1] and @a[0,0]
    assert_equal [[ 4, 77], [77,  1]], @c.to_a
    assert_equal [[77,  1,  2,  3],
                  [ 4, 77,  6,  7],
                  [ 8,  9, 10, 11],
                  [12, 13, 14, 15]], @a.to_a
  end

  # ----------------------------------------------------------------
  # Other non-contig CABlock parents.
  # ----------------------------------------------------------------

  def test_stepped_block_flat_range
    a = CArray.new(CA_INT32, [5, 5]).seq!
    # Every other row + every other column: 3x3 picking
    # 0, 2, 4, 10, 12, 14, 20, 22, 24
    v = a[[0..4, 2], [0..4, 2]]   # carray's stepped-block syntax
    assert_equal [0, 2, 4, 10, 12, 14, 20, 22, 24], v[nil].to_a
    assert_equal [2, 4, 10],  v[1..3].to_a       # spans row boundary
    assert_equal [14, 20],    v[5..6].to_a
  end

  def test_transpose_flat_range
    a = CArray.new(CA_INT32, [3, 4]).seq!
    t = a.transpose                              # 4x3
    # Logical order column-then-row of a:
    # 0, 4, 8, 1, 5, 9, 2, 6, 10, 3, 7, 11
    assert_equal [0, 4, 8, 1, 5, 9, 2, 6, 10, 3, 7, 11], t[nil].to_a
    assert_equal [4, 8, 1, 5], t[1..4].to_a       # spans column boundary
  end

  def test_repeat_flat_range
    a = CArray.new(CA_INT32, [3]).seq!            # [0, 1, 2]
    r = a[:%, 2]                                  # CARepeat -> [3, 2]
    # Iteration: [0,0, 1,1, 2,2]
    assert_equal [0, 0, 1, 1, 2, 2], r[nil].to_a
    assert_equal [0, 1, 1, 2],       r[1..4].to_a
  end

  # ----------------------------------------------------------------
  # Targeted edge cases of the compose-fold bounds check.
  # ----------------------------------------------------------------

  def test_base_near_end_of_parent_dim_forward_step
    # If the slice's base lands at the LAST column of @b (col 2) and
    # we then take a flat Range that advances forward, the
    # compose-fold check must catch that even step=1 crosses into the
    # next row.  Before the fix, base_idx[1]=2 plus max_advance=1
    # equalled 3 (== parent_dim[1]) -- that condition was never
    # tested, so iteration walked into the wrong b-row with the wrong
    # entity-space stride.
    a = CArray.new(CA_INT32, [3, 3]).seq!         # 0..8
    b = a[0..2, 2..2]                             # column 2: [[2],[5],[8]]
    # b is 3x1, fine.  Now flat-iterate a non-trivial slice across it:
    assert_equal [2, 5, 8], b[nil].to_a
    assert_equal [5, 8],    b[1..2].to_a
  end

  def test_base_near_start_with_backward_step
    a = CArray.new(CA_INT32, [4]).seq!            # [0, 1, 2, 3]
    rev = a[3..0]                                  # [3, 2, 1, 0]
    assert_equal [3, 2, 1, 0], rev[nil].to_a
    assert_equal [2, 1],       rev[1..2].to_a
    rev[1..2] = 99
    assert_equal [0, 99, 99, 3], a.to_a
  end

  # ----------------------------------------------------------------
  # The compose-fold optimisation must still kick in for the cases
  # where the bounds check legitimately passes (contig parents).
  # ----------------------------------------------------------------

  def test_simple_reshape_over_entity_still_zero_copy
    a = CArray.new(CA_INT32, [3, 4]).seq!
    r = a.reshape(2, 6)                           # contig reshape
    assert_equal [[0, 1, 2,  3,  4,  5],
                  [6, 7, 8,  9, 10, 11]], r.to_a
    # Write-through alias: writing to r must mutate a.
    r[0, 0] = 99
    assert_equal 99, a[0, 0]
    r[1..4] = 77   # flat range over the reshape view
    assert_equal [99, 77, 77, 77, 77, 5, 6, 7, 8, 9, 10, 11], a[nil].to_a
  end

  def test_row_slice_over_entity_still_zero_copy
    # Pure row slice on an entity is a contig CABlock -- compose-fold
    # should fold all the way to the entity and alias the bytes.
    a = CArray.new(CA_INT32, [4, 4]).seq!
    row = a[1, nil]                               # contig 1D view
    assert_equal [4, 5, 6, 7], row.to_a
    row[1..2] = 88
    assert_equal [4, 88, 88, 7], a[1, nil].to_a
    assert_equal [4, 88, 88, 7], row.to_a
  end

  # ----------------------------------------------------------------
  # Deeper chains: block-of-block-of-block.  The non-contig step
  # can appear at any depth; the validation has to catch wraps no
  # matter which level introduces the non-contig structure.
  # ----------------------------------------------------------------

  def test_three_level_chain_with_inner_reverse
    a = CArray.new(CA_INT32, [5, 5]).seq!
    b = a[0..3, 0..3]                             # 4x4 contig-like
    c = b[2..0, 0..2]                             # 3x3 reversed rows
    d = c[1..0, 0..1]                             # 2x2 doubly reversed
    # d's logical iteration:
    # c[1, 0..1] = b[1, 0..1] = a[1, 0..1] = [5, 6]
    # c[0, 0..1] = b[2, 0..1] = a[2, 0..1] = [10, 11]
    assert_equal [[5, 6], [10, 11]], d.to_a
    assert_equal [5, 6, 10, 11], d[nil].to_a
    assert_equal [6, 10], d[1..2].to_a            # crosses d-row boundary
  end

  # ----------------------------------------------------------------
  # `reshape` is a CARefer; on a non-contig source it must materialise
  # the view's iteration order rather than aliasing parent bytes.
  # ----------------------------------------------------------------

  def test_reshape_of_noncontig_view_preserves_iteration_order
    a = CArray.new(CA_INT32, [4, 4]).seq!
    rev_rows = a[3..0, nil]                       # rows reversed, 4x4
    flat = rev_rows.reshape(16)
    # Expected: row 3 of a, row 2, row 1, row 0
    expected =
      (12..15).to_a + (8..11).to_a + (4..7).to_a + (0..3).to_a
    assert_equal expected, flat.to_a
    assert_equal expected[4..7], flat[4..7].to_a
  end

end
