require "carray"
require "test/unit"

# Filling part of a view must write only the cells it addresses.
#
# Where the chain bottoms out at something that has to be gathered rather
# than aliased -- a transform view like CAFake, whose attach materialises the
# whole thing -- the old path attached that root, wrote the region, and synced
# the root back.  Cells the caller never named made the round trip, and
# through a lossy transform they did not come back the same.
#
# uint16 30000 does not survive a trip through uint8: it returns as 48.  So an
# untouched cell reading 48 is proof it was carried through the CAFake and
# written back.
#
# See devel/PROPOSAL_PARTIAL_FILL_WHOLE_ROOT_WRITEBACK.md and
# devel/probe_partial_fill_whole_root.rb.

class TestPartialFillRegion < Test::Unit::TestCase

  def setup
    @a = CArray.uint16(4, 4) { 30000 }
    @f = @a.fake(:uint8)
  end

  def assert_untouched_intact (msg)
    assert_equal 30000, @a[0, 0], "#{msg}: untouched cell went through the root"
  end

  # ----- the shapes a partial fill can take ---------------------------

  def test_block_form_writes_only_its_region
    @f[2..3, 2..3] = 1
    assert_equal [[1, 1], [1, 1]], @f[2..3, 2..3].to_a
    assert_untouched_intact "block form"
  end

  def test_held_subview_writes_only_its_region
    b = @f[2..3, nil]
    b[] = 1
    assert_equal [[1, 1, 1, 1], [1, 1, 1, 1]], b.to_a
    assert_untouched_intact "held subview"
  end

  # The boolean form is a different call site (CASelect, not CAStride) and had
  # no full-coverage relaxation at all.  It has to move in step with the block
  # form: a fix that left one of them writing the whole root would make the
  # damage depend on how the write was spelled.
  def test_boolean_form_writes_only_its_selection
    @a[3, 3] = 100
    f = @a.fake(:uint8)
    f[f.eq(100)] = 1
    assert_equal 1, f[3, 3]
    assert_equal 30000, @a[0, 0], "boolean form: untouched cell went through the root"
  end

  def test_single_cell_writes_only_that_cell
    @f[3, 3] = 1
    assert_equal 1, @f[3, 3]
    assert_untouched_intact "single cell"
  end

  # A 1-D view over a 2-D root: the region it covers is not a box in the
  # root's index space, so nothing here can be expressed as one strided
  # request against the root.  Descending a hop at a time never needs it to be.
  def test_ndim_mismatch_writes_only_its_region
    r = @f.reshape(16)
    r[4..7] = 1
    assert_equal [1, 1, 1, 1], r[4..7].to_a
    assert_untouched_intact "ndim mismatch"
  end

  # ----- the value must not depend on how the write is spelled --------

  def test_scalar_and_array_rvalues_agree
    b = CArray.uint16(4, 4) { 30000 }
    g = b.fake(:uint8)
    @f[2..3, 2..3] = 1
    g[2..3, 2..3] = CArray.uint8(2, 2) { 1 }
    assert_equal b.to_a, @a.to_a
  end

  # A stride-0 view is what a scalar fill means, spelled as an array.
  def test_scalar_and_broadcast_view_rvalues_agree
    b = CArray.uint16(4, 4) { 30000 }
    g = b.fake(:uint8)
    one = CArray.uint8(1) { 1 }
    @f[2..3, 2..3] = 1
    g[2..3, 2..3] = one[2, 2, :%].reshape(2, 2)
    assert_equal b.to_a, @a.to_a
  end

  # A swap reorders bytes within a cell, never cells within the array, so the
  # one value is swapped once and the region goes down as it stands.
  def test_byte_swap_writes_only_its_region
    s = CArray.fixlen(4, bytes: 2)
    s[] = ["ab", "cd", "ef", "gh"]
    sw = s.swap_bytes
    assert_equal CAByteSwap, sw.class
    sw[1..2] = "xy"
    assert_equal ["ab", "yx", "yx", "gh"], s.to_a
  end

  # The gather views select cells rather than a box, so they hand each slab to
  # the parent as a region of its own.  Their fill was already writing only the
  # selected cells -- it was the attach and sync around it that carried the
  # rest of the parent through.
  def test_grid_writes_only_its_selection
    ri = CArray.int(2).tap { |x| x[] = [1, 3] }
    ci = CArray.int(2).tap { |x| x[] = [1, 3] }
    g = @f.grid(ri, ci)
    assert_equal CAGrid, g.class
    g[] = 1
    assert_equal [[1, 1], [1, 1]], g.to_a
    assert_untouched_intact "grid"
  end

  def test_select_axis_writes_only_its_selection
    m = CArray.boolean(4) { |i| i > 0 }
    v = @f[m, nil]
    assert_equal CASelectAxis, v.class
    v[] = 1
    assert_equal 1, @f[1, 0]
    assert_untouched_intact "select_axis"
  end

  # ----- regions a view cannot pass on as a region --------------------

  # A view hands its region to its parent described over addresses, and that
  # only carries if the region is a box in the *view's* index space.  A flat
  # index over a multi-axis view is not one: it walks the whole thing in
  # address order, so the index carries from the end of one row to the start of
  # the next and no single per-axis step describes it.  These have to reach the
  # per-cell walk; the earlier attempt at passing them on wrote half the region
  # and ran off the end of the view.  See section 8.3 of the proposal.

  def reversed_block
    a = CArray.int32(4, 4).seq!
    [a, a[0..2, 0..2][1..0, 0..1]]   # 2x2, row stride reversed
  end

  def test_flat_index_over_a_reversed_block_reaches_every_cell
    a, c = reversed_block
    c[nil] = 99
    assert_equal [[99, 99], [99, 99]], c.to_a
    assert_equal [[99, 99, 2, 3],
                  [99, 99, 6, 7],
                  [8, 9, 10, 11],
                  [12, 13, 14, 15]], a.to_a
  end

  def test_flat_range_over_a_reversed_block_stays_inside_it
    a, c = reversed_block
    c[1..2] = 99          # crosses the row boundary in flat order
    assert_equal [[4, 99], [99, 1]], c.to_a
    assert_equal 2, a[0, 2], "wrote past the view's own columns"
    assert_equal 6, a[1, 2], "wrote past the view's own columns"
  end

  def test_flat_index_over_a_reversed_block_through_a_transform
    a = CArray.uint16(4, 4) { 30000 }
    c = a.fake(:uint8)[0..2, 0..2][1..0, 0..1]
    c[nil] = 9
    assert_equal [[9, 9], [9, 9]], c.to_a
    assert_equal 30000, a[3, 3], "untouched cell went through the root"
    assert_equal 30000, a[0, 2], "wrote past the view's own columns"
  end

  # The chain the region path is for: a transform layer between two strided
  # views, so the lower one is handed a sub-box rather than its whole extent.
  # Every axis of that request does correspond to one of its own, so it is a
  # box and can be passed on.
  def test_sub_box_through_a_transform_layer
    a = CArray.uint16(8, 8) { 30000 }
    f = a[2..5, nil].fake(:uint8)
    v = f[1..2, 2..5]
    v[] = 1
    assert_equal [[1, 1, 1, 1], [1, 1, 1, 1]], v.to_a
    assert_equal 30000, a[0, 0]
    assert_equal 1, a[3, 3]
  end

  # Whatever route each spelling takes, the two must agree.
  def test_skewed_views_agree_with_the_array_rvalue
    [["transpose",          ->(f) { f.transpose[1..3, 2..4] }],
     ["reversed",           ->(f) { f[2..4, nil].flip(0) }],
     ["axis dropped",       ->(f) { f[2, 1..4] }],
     ["reshaped",           ->(f) { f.reshape(36)[4..20] }],
     ["block over a block", ->(f) { f[1..4, 1..4][1..2, 0..2] }],
     ["reversed, flat",     ->(f) { f[0..2, 0..2][1..0, 0..1][nil] }],
    ].each do |label, build|
      x = CArray.uint16(6, 6) { |i| i }
      y = CArray.uint16(6, 6) { |i| i }
      vx = build.call(x.fake(:uint8))
      vy = build.call(y.fake(:uint8))
      vx[] = 7
      vy[] = CArray.uint8(*vy.shape) { 7 }
      assert_equal y.to_a, x.to_a, "#{label}: scalar and array rvalues disagree"
    end
  end

  # ----- the sub-byte views -------------------------------------------

  # These write part of a parent cell, so a fill is a read-modify-write and
  # the bits the view does not own have to survive it.  The region path must
  # keep that true while touching only the cells it was given.

  def test_bitfield_partial_fill_keeps_the_other_bits
    a = CArray.uint16(4) { 0xBEE0 }
    bf = a.bitfield(0..3, CA_UINT8)
    bf[1..2] = 0x5
    assert_equal [0xBEE0, 0xBEE5, 0xBEE5, 0xBEE0], a.to_a
  end

  def test_bitfield_partial_fill_over_a_transform
    a = CArray.uint16(4) { 30000 }
    bf = a.fake(:uint8).bitfield(0..3, CA_UINT8)
    bf[1..2] = 0x5
    # The fake's cell is the low byte of 30000, which is 48; its low nibble
    # becomes 5.  The cells outside the range keep 30000 whole.
    assert_equal [30000, 53, 53, 30000], a.to_a
  end

  def test_bitfield_partial_fill_agrees_with_the_array_rvalue
    x = CArray.uint16(6) { 0xBEE0 }
    y = CArray.uint16(6) { 0xBEE0 }
    x.bitfield(0..3, CA_UINT8)[1..4] = 0x5
    y.bitfield(0..3, CA_UINT8)[1..4] = CArray.uint8(4) { 0x5 }
    assert_equal y.to_a, x.to_a
  end

  # The bit axis is the awkward one: a range over it is not whole cells, so
  # the region does not land on parent byte boundaries.
  def test_bitarray_partial_fill_on_the_bit_axis
    a = CArray.uint16(4) { 0 }
    a.bitarray[nil, 2..3] = 1
    assert_equal [0b1100] * 4, a.to_a
  end

  def test_bitarray_partial_fill_on_the_cell_axis
    a = CArray.uint16(4) { 0 }
    a.bitarray[1..2, nil] = 1
    assert_equal [0, 0xFFFF, 0xFFFF, 0], a.to_a
  end

  def test_bitarray_partial_fill_agrees_with_the_array_rvalue
    [[->(b) { b[1..2, nil] }, [2, 16]],
     [->(b) { b[nil, 2..5] }, [6, 4]],
     [->(b) { b[1..4, 3..9] }, [4, 7]],
    ].each do |build, shape|
      x = CArray.uint16(6) { 0xA5A5 }
      y = CArray.uint16(6) { 0xA5A5 }
      build.call(x.bitarray)[] = 1
      build.call(y.bitarray)[] = CArray.boolean(*shape) { 1 }
      assert_equal y.to_a, x.to_a, "shape #{shape.inspect} disagrees"
    end
  end

  # ----- the paths that were already correct stay correct -------------

  def test_full_coverage_still_delegates
    # The whole view covers the whole root, so "fill everything I cover" is a
    # correct request to pass on -- this took the delegate before and still does.
    @f[] = 1
    assert_equal Array.new(4) { Array.new(4, 1) }, @f.to_a
  end

  def test_entity_fill_is_unaffected
    a = CArray.int32(6, 6) { 0 }
    a[1..4, 1..4] = 7
    assert_equal 7 * 16, a.sum
    assert_equal 0, a[0, 0]
  end

  def test_stride_family_root_is_unaffected
    a = CArray.int32(6, 6) { 0 }
    v = a[1..4, 1..4]            # CABlock over an entity: attach is an alias
    v[0..1, 0..1] = 5
    assert_equal 5 * 4, a.sum
    assert_equal [[5, 5], [5, 5]], a[1..2, 1..2].to_a
  end

  def test_masked_fill_still_only_touches_data
    a = CArray.uint16(4, 4) { 30000 }
    f = a.fake(:uint8)
    f[2..3, 2..3] = UNDEF
    assert_equal 4, f.count_masked
    assert_equal 0, f[0..1, nil].count_masked
  end

end
