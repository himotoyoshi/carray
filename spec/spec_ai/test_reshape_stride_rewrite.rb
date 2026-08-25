# M4 (PROPOSAL_RESHAPE_STRIDE_REWRITE): positive behavior tests for the
# stride-rewrite path in #reshape and #flatten.  Asserts:
#   - representable reshape returns CAStride (class change is intentional)
#   - representable reshape over a non-CAStride parent (CASelect etc.)
#     falls back to CARefer
#   - content is binary identical with the pre-rewrite path
#   - the new CAStride's parent is the root entity (compose-fold collapses)
#   - writes propagate to entity through the rewritten view
#   - mask propagation works through the rewritten view
#   - chained reshape works

require "test/unit"
require "carray"

class TestReshapeStrideRewrite < Test::Unit::TestCase

  # ===== class outcome =====

  def test_reshape_on_entity_returns_castride
    a = CArray.float64(2, 3, 4).seq
    r = a.reshape(6, 4)
    assert_equal CAStride, r.class
  end

  def test_reshape_on_castride_family_parent_returns_castride
    # CABlock parent with contig-mergeable inner axes
    a = CArray.float64(2, 3, 4).seq
    sub = a[nil, 1..2, nil]   # CABlock
    r = sub.reshape(2, 8)     # axes 1+2 are mergeable (32 == 8*4)
    assert_equal CAStride, r.class
  end

  def test_flatten_on_entity_returns_castride
    a = CArray.float64(2, 3, 4).seq
    f = a.flatten
    assert_equal CAStride, f.class
  end

  def test_flatten_on_fully_contig_block_returns_castride
    # `a[1..1, nil, nil]` is a contig sub-block of entity: dim (1,3,4),
    # all axes inter-contig.  Flatten to (12,) is representable.
    a = CArray.float64(2, 3, 4).seq
    sub = a[1..1, nil, nil]
    f = sub.flatten
    assert_equal CAStride, f.class
    assert_equal (12..23).map(&:to_f), f.to_a
  end

  def test_flatten_on_non_contig_block_falls_back_to_carefer
    # `a[nil, 1..2, nil]` has dim (2,2,4) strides (96,32,8): inner pair
    # (axes 1+2) is contig, but axis 0 is NOT contig with axis 1
    # (96 != 32*2).  Flatten to (16,) crosses this break, so reshape
    # rewrite must return 0 and we fall back to CARefer.
    a = CArray.float64(2, 3, 4).seq
    sub = a[nil, 1..2, nil]
    f = sub.flatten
    assert_equal CARefer, f.class, "non-contig flatten must fall back"
    # Content still correct via fallback
    assert_equal sub.to_ca.to_a.flatten, f.to_a
  end

  # ===== fallback when parent isn't representable =====

  def test_reshape_falls_back_to_carefer_for_caselect_parent
    # CASelect (= boolean mask gather) has no strides representation;
    # reshape must fall back to CARefer.
    a = CArray.float64(12).seq
    mask = CArray.boolean(12).tap { |i| i[] = i < 6 }
    sel = a[mask]     # CASelect view (elements == parent size 12)
    assert_kind_of CASelect, sel
    # 3.0 strict reshape: use an element-preserving shape (sel.elements==12).
    r = sel.reshape(2, 6)
    assert_equal CARefer, r.class, "non-stride parent must fall back to CARefer"
  end

  # ===== root entity attachment =====

  def test_rewritten_view_parent_chains_to_entity
    a = CArray.float64(2, 3, 4).seq
    sub = a[nil, 1..2, nil]   # CABlock with strides
    r = sub.reshape(2, 8)
    # The new CAStride's C-level parent should be the entity, not sub.
    # We can probe via #parent (Ruby-level) — but that's set to `self`
    # (= sub) for GC.  Inspecting C parent is harder, but we can check
    # the strides are entity-space (= what compose-fold would produce
    # if we went view.to_ca directly).
    assert_equal [96, 8], r.strides   # entity-space byte strides
    assert_equal 32, r.byte_offset    # sub.base_offset in entity
  end

  # ===== content binary identity =====

  def test_content_matches_pre_rewrite_path
    # Compare against CARefer-style flat reinterpret: flatten then reshape
    # to the target.  Both routes must produce the same values.
    a = CArray.float64(2, 3, 4).seq
    sub = a[nil, 1..2, nil]
    r_rewrite = sub.reshape(2, 8)
    # Reference: materialise sub, then reshape on the entity copy (which
    # is itself contig).  This goes via plain CArray parent path.
    ref = sub.to_ca.reshape(2, 8)
    assert_equal ref.to_a.flatten, r_rewrite.to_ca.to_a.flatten
  end

  def test_content_matches_for_mid_axis_3d
    # The original motivating case: 3D non-contig view reshaped by
    # merging contig-mergeable axes 1+2.
    a = CArray.float64(20, 30, 10).seq
    sub = a[nil, 5..14, nil]
    r = sub.reshape(20, 100)
    ref = sub.to_ca.reshape(20, 100)
    assert_equal ref.to_a, r.to_ca.to_a
  end

  # ===== writes propagate =====

  def test_write_through_rewritten_reshape_propagates_to_entity
    a = CArray.float64(2, 3, 4).seq
    sub = a[nil, 1..2, nil]
    r = sub.reshape(2, 8)
    r[0, 0] = -1.0     # this should land at entity[0, 1, 0]
    assert_equal(-1.0, a[0, 1, 0])
  end

  def test_write_through_flatten_propagates_to_entity
    a = CArray.float64(3, 4).seq
    f = a.flatten
    f[5] = -99.0      # flat index 5 = a[1, 1]
    assert_equal(-99.0, a[1, 1])
  end

  # ===== mask propagation =====

  def test_rewritten_reshape_preserves_mask
    a = CArray.float64(2, 3, 4).seq
    a.mask = 0
    a[0, 1, 2] = UNDEF
    r = a.reshape(6, 4)
    assert_true r.has_mask?
    # flat index of a[0,1,2] = 0*12 + 1*4 + 2 = 6; in (6,4): r[1, 2]
    assert_equal true, r.is_masked[1, 2]
  end

  def test_rewritten_reshape_mask_writes_propagate
    a = CArray.float64(3, 4).seq
    a.mask = 0
    r = a.reshape(2, 6)
    r[1, 0] = UNDEF   # flat index 6 = a[1, 2]
    assert_equal true, a.is_masked[1, 2]
  end

  # ===== chained =====

  def test_chained_reshape_works
    a = CArray.float64(2, 3, 4).seq
    r1 = a.reshape(6, 4)
    r2 = r1.reshape(3, 8)
    assert_equal CAStride, r2.class
    assert_equal a.to_a.flatten, r2.to_ca.to_a.flatten
  end

  def test_reshape_then_flatten
    a = CArray.float64(2, 3, 4).seq
    r = a.reshape(6, 4).flatten
    assert_equal CAStride, r.class
    assert_equal a.to_a.flatten, r.to_a
  end

  # ===== zero-element / dim-1 edges =====

  def test_dim1_axes_in_new_shape
    a = CArray.float64(2, 3, 4).seq
    r = a.reshape(1, 2, 12)
    assert_equal CAStride, r.class
    assert_equal [1, 2, 12], r.dim
    assert_equal a.to_a.flatten, r.to_ca.to_a.flatten
  end

  def test_dim1_axes_in_old_shape
    a = CArray.float64(1, 6, 1)
    a[0, nil, 0] = CArray.float64(6).seq
    r = a.reshape(6)
    assert_equal CAStride, r.class
    assert_equal (0..5).map(&:to_f), r.to_a
  end

  # ===== contig-impossible reshape on CAStride parent =====

  def test_reshape_across_non_contig_boundary_uses_fallback
    # Reshape that crosses a non-contig axis boundary: must fall back
    # to CARefer (since CAStride can't express the resulting non-trivial
    # gather as adjacent strides).
    # Actually, our M1 only checks intra-range contig.  If the new shape
    # straddles a non-contig boundary, M1 returns 0 → CARefer fallback.
    a = CArray.float64(2, 3, 4).seq
    sub = a[nil, 1..2, nil]   # strides (96, 32, 8); inner 1+2 contig
    # Reshape (2, 2, 4) → (4, 4): merging axes 0+1 of sub. Sub's
    # axis 0 (stride 96) and axis 1 (stride 32) are NOT inter-axis
    # contig (96 != 32*2 = 64).  So this should fall back.
    r = sub.reshape(4, 4)
    # Content must still be correct via fallback path
    assert_equal sub.to_ca.to_a.flatten, r.to_ca.to_a.flatten
  end
end
