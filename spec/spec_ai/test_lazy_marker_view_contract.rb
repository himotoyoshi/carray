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
# The last section pins two DEFECTS that exist today.  They are asserted
# as raises so that fixing them fails loudly here rather than silently
# drifting; flip those tests together with the fix.
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
    got  = CArray.fuse(@f) { |u|
             u.shift(1, 0) + u.shift(-1, 0) + u.shift(0, 1) + u.shift(0, -1) - 4 * u
           }
    assert_equal CArray, got.class
    assert_equal want.to_a, got.to_a
  end

  def test_fuse_stencil_with_fill_value_matches_eager
    want = @f.shift(1, 0, fill_value: 0) + @f.shift(-1, 0, fill_value: 0)
    got  = CArray.fuse(@f) { |u| u.shift(1, 0, fill_value: 0) + u.shift(-1, 0, fill_value: 0) }
    assert_equal want.to_a, got.to_a
  end

  def test_fuse_stencil_over_masked_input_matches_eager
    m = @f.copy
    m[1, 1] = UNDEF
    want = m.shift(1, 0) + m.shift(-1, 0)
    got  = CArray.fuse(m) { |u| u.shift(1, 0) + u.shift(-1, 0) }
    assert_equal want.mask.to_a, got.mask.to_a
    assert_equal want.to_a, got.to_a
  end

  # === structure (this is what the proposal is allowed to change) =========

  # Pins the CURRENT tree shape.  Under PROPOSAL_LAZY_MARKER_LIFT case A
  # these become CALazyMarker at the top; update them together with the
  # implementation, and keep every assertion above unchanged.
  def test_current_tree_shape_marker_under_view
    v = @a.lazy.shift(1, 0)
    assert_equal CAShift, v.class
    assert_equal CALazyMarker, v.parent.class
    # `to_ca` follows the class: a data view returns self, a lazy view
    # forces.  Lifting the marker therefore also moves this method's
    # meaning for marker-rooted views (see proposal section 6).
    assert_same v, v.to_ca
  end

  def test_current_tree_shape_entity_rooted_is_already_marker_on_top
    v = @a.shift(1, 0).lazy
    assert_equal CALazyMarker, v.class
    assert_equal CAShift, v.parent.class
  end

  # A marker-rooted view does not currently take part in lazy dispatch:
  # `m.shift + m.shift` is an eager add, not a CABinOp.
  def test_current_marker_rooted_view_is_not_a_lazy_operand
    m = @a.lazy
    assert_equal false, m.shift(1, 0).__lazy_view__?
    assert_equal CArray, (m.shift(1, 0) + m.shift(-1, 0)).class
  end

  # === defect pins (assert the bug; flip these with the fix) ==============

  # CA_OBJ_LAZY_MARKER is absent from ca_iter_classify_source
  # (ext/ca_kernel_iterator.c), so a bare marker is CA_ITER_SRC_NONE.
  # Full unmasked reductions dodge this via the streaming lazy fast path
  # in the generated reducers, so the failure only surfaces per-axis or
  # under a mask.
  def test_defect_marker_per_axis_reduction_raises
    assert_equal [12.0, 15.0, 18.0, 21.0], @a.sum(axis: 0).to_a
    assert_raise(RuntimeError) { @a.lazy.sum(axis: 0) }
    assert_raise(RuntimeError) { CArray.fuse(@a) { |v| v.mean(axis: 0) } }
    # One lazy op above the marker is enough to be classified again.
    assert_equal [12.0, 15.0, 18.0, 21.0], (@a.lazy + 0).sum(axis: 0).to_a
  end

  def test_defect_masked_marker_full_reduction_raises
    m = @a.copy
    m[0, 0] = UNDEF
    assert_equal 66.0, m.sum
    assert_raise(RuntimeError) { m.lazy.sum }
    assert_equal 66.0, m.lazy.to_ca.sum   # documented workaround
  end
end
