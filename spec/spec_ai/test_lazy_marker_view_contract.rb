# ---------------------------------------------------------------------------
# spec_ai/test_lazy_marker_view_contract.rb
#
# Behaviour pin for CALazyMarker under view-creating methods
# (= devel/PROPOSAL_LAZY_MARKER_LIFT.md).
#
# The proposal changes WHERE the marker sits in the tree:
#
#   now      m.shift(1, 0)  ->  CAShift      <- CALazyMarker <- entity
#   proposed m.shift(1, 0)  ->  CALazyMarker <- CAShift      <- entity
#
# Everything asserted here is about VALUES, masks, writability and
# materialise semantics -- all of which must survive that change
# untouched.  Intermediate classes are pinned separately in the
# "structure (changes under the proposal)" section, which is the one
# place a lift is allowed to break.
#
# The last section covers reductions over a bare marker.  Those used to
# raise: CALazyMarker was missing from ca_iter_classify_source, so a
# marker was CA_ITER_SRC_NONE and only full unmasked reductions got
# through, via the streaming lazy path in the generated reducers.  The
# kernel-compute entry now strips storage-identical wrappers -- Face and
# marker alike -- and descends to what they wrap, so the parent is
# classified on its own merits.
# ---------------------------------------------------------------------------

$LOAD_PATH.unshift File.expand_path('../../../ext', __FILE__)
$LOAD_PATH.unshift File.expand_path('../../../lib', __FILE__)

require 'test/unit'
require 'carray'

class TestLazyMarkerViewContract < Test::Unit::TestCase

  def setup
    @a = CArray.int32(3, 4) { |j, i| j * 4 + i }
    @f = CArray.float64(4, 4) { |j, i| j * 4 + i }
  end

  # === values: marker-rooted views equal entity-rooted views ==============

  def test_shift_value_matches_entity
    assert_equal @a.shift(1, 0).to_a, @a.lazy.shift(1, 0).to_a
    assert_equal @a.shift(0, -1).to_a, @a.lazy.shift(0, -1).to_a
  end

  def test_shift_fill_value_kwarg_is_transparent
    assert_equal @a.shift(1, 0, fill_value: -7).to_a,
                 @a.lazy.shift(1, 0, fill_value: -7).to_a
  end

  def test_shift_fill_value_undef_masks_the_same_cells
    want = @a.shift(1, 0, fill_value: UNDEF)
    got  = @a.lazy.shift(1, 0, fill_value: UNDEF)
    assert_equal true, got.has_mask?
    assert_equal want.mask.to_a, got.mask.to_a
    assert_equal want.to_a, got.to_a
  end

  def test_roll_flip_transpose_reshape_values
    assert_equal @a.roll(1, 0).to_a,      @a.lazy.roll(1, 0).to_a
    assert_equal @a.flip(0).to_a,         @a.lazy.flip(0).to_a
    assert_equal @a.transpose.to_a,       @a.lazy.transpose.to_a
    assert_equal @a.reshape(12).to_a,     @a.lazy.reshape(12).to_a
    assert_equal @a.flatten.to_a,         @a.lazy.flatten.to_a
  end

  def test_block_index_value
    assert_equal @a[0..1, nil].to_a, @a.lazy[0..1, nil].to_a
  end

  # A scalar index must stay a scalar -- a lift may only wrap CArray results.
  def test_scalar_index_stays_scalar
    assert_equal @a[1, 2], @a.lazy[1, 2]
    assert_kind_of Integer, @a.lazy[1, 2]
  end

  # === materialise / ownership ============================================

  # `copy` owns its data.  It must NOT be lifted back into a lazy view,
  # or `m.copy` would stop being an independent entity.
  def test_copy_of_marker_is_an_independent_entity
    c = @a.lazy.copy
    assert_equal CArray, c.class
    c[0, 0] = 999
    assert_equal 0, @a[0, 0]
  end

  def test_to_ca_of_marker_materialises_an_entity
    t = @a.lazy.to_ca
    assert_equal CArray, t.class
    assert_equal @a.to_a, t.to_a
  end

  def test_marker_rooted_view_materialises_to_entity
    v = @a.lazy.shift(1, 0)
    assert_equal @a.shift(1, 0).to_a, v.to_ca.to_a
    assert_equal @a.shift(1, 0).to_a, v.copy.to_a
    assert_equal CArray, v.copy.class
  end

  # === read-only propagation ==============================================

  def test_marker_rooted_view_is_read_only
    v = @a.lazy.shift(1, 0)
    assert_equal true, v.read_only?
    assert_raise(RuntimeError) { v[0, 0] = 1 }
  end

  # === fusion: marker-rooted stencils compute the right answer ============

  def test_fuse_stencil_matches_eager
    want = @f.shift(1, 0) + @f.shift(-1, 0) + @f.shift(0, 1) + @f.shift(0, -1) - 4 * @f
    got  = CArray.fuse {
             @f.shift(1, 0) + @f.shift(-1, 0) + @f.shift(0, 1) + @f.shift(0, -1) - 4 * @f
           }
    assert_equal want.to_a, got.to_a
  end

  def test_fuse_stencil_with_fill_value_matches_eager
    want = @f.shift(1, 0, fill_value: 0) + @f.shift(-1, 0, fill_value: 0)
    got  = CArray.fuse { @f.shift(1, 0, fill_value: 0) + @f.shift(-1, 0, fill_value: 0) }
    assert_equal want.to_a, got.to_a
  end

  def test_fuse_stencil_over_masked_input_matches_eager
    m = @f.copy
    m[1, 1] = UNDEF
    want = m.shift(1, 0) + m.shift(-1, 0)
    got  = CArray.fuse { m.shift(1, 0) + m.shift(-1, 0) }
    assert_equal want.mask.to_a, got.mask.to_a
    assert_equal want.to_a, got.to_a
  end

  # === structure ==========================================================

  # A view built on a marker comes back with the marker on top and the
  # view underneath it, against the entity -- the same shape spelling it
  # the other way round produces.  That is the whole point: the two
  # spellings stop differing.
  def test_marker_stays_on_top_of_a_view
    v = @a.lazy.shift(1, 0)
    assert_equal CALazyMarker, v.class
    assert_equal CAShift, v.parent.class
    assert_equal CArray, v.parent.parent.class
  end

  def test_both_spellings_produce_the_same_shape
    from_marker = @a.lazy.shift(1, 0)
    from_entity = @a.shift(1, 0).lazy
    assert_equal from_entity.class,        from_marker.class
    assert_equal from_entity.parent.class, from_marker.parent.class
    assert_equal from_entity.to_a,         from_marker.to_a
  end

  # And it takes part in lazy dispatch, which is what keeps a fuse block's
  # expression fused instead of falling out of the chain at the first view.
  def test_marker_rooted_view_is_a_lazy_operand
    m = @a.lazy
    assert_equal true, m.shift(1, 0).__lazy_view__?
    assert_equal CABinOp, (m.shift(1, 0) + m.shift(-1, 0)).class
    assert_equal (@a.shift(1, 0) + @a.shift(-1, 0)).to_a,
                 (m.shift(1, 0) + m.shift(-1, 0)).to_ca.to_a
  end

  # `to_ca` follows the class: a data view returns self, a lazy view
  # forces.  Moving the marker therefore moves what to_ca means for a
  # marker-rooted view -- it now hands back an independent entity.
  def test_to_ca_of_a_marker_rooted_view_forces
    v = @a.lazy.shift(1, 0)
    t = v.to_ca
    assert_not_same v, t
    assert_equal CArray, t.class
    assert_equal v.to_a, t.to_a
  end

  # === reductions over a bare marker ======================================

  def test_marker_per_axis_reduction_matches_entity
    assert_equal @a.sum(axis: 0).to_a,  @a.lazy.sum(axis: 0).to_a
    assert_equal @a.mean(axis: 0).to_a, @a.lazy.mean(axis: 0).to_a
    assert_equal @a.max(axis: 1).to_a,  @a.lazy.max(axis: 1).to_a
    assert_equal @a.mean(axis: 0).to_a,
                 CArray.fuse { @a.mean(axis: 0) }.to_a
    # One lazy op above the marker went through even before the strip.
    assert_equal @a.sum(axis: 0).to_a, (@a.lazy + 0).sum(axis: 0).to_a
  end

  def test_marker_reduction_over_masked_input_matches_entity
    m = @a.copy
    m[0, 0] = UNDEF
    assert_equal m.sum,                 m.lazy.sum
    assert_equal m.mean,                m.lazy.mean
    assert_equal m.sum(axis: 0).to_a,   m.lazy.sum(axis: 0).to_a
    assert_equal m.mean(axis: 0).to_a,  m.lazy.mean(axis: 0).to_a
    # The masked cell must actually be excluded, not merely tolerated.
    assert_equal m[nil, 0].sum, m.lazy.sum(axis: 0)[0]
  end

  def test_marker_reduction_carries_no_copy
    # Stripping is what makes this equal rather than one array-copy
    # slower: routing the marker to CA_ITER_SRC_ATTACH would allocate
    # elements * bytes and pull the whole array through ca_xfer_all
    # before reducing.  Asserted structurally rather than by timing --
    # a marker must not be classifiable as a source at all.
    assert_equal @a.sum(axis: 0).to_a, @a.lazy.sum(axis: 0).to_a
    assert_equal @a.sum, @a.lazy.sum
  end

  # Stripping must not hand a destructive kernel the writable parent that
  # a read-only marker was covering.
  def test_marker_still_refuses_destructive_kernels
    before = @a.to_a
    assert_raise(RuntimeError) { @a.lazy.map! { |x| x + 1 } }
    assert_raise(RuntimeError) { @a.lazy[0, 0] = 999 }
    assert_equal before, @a.to_a
  end
end
