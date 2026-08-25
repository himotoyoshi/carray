# K.5/K.6 (PROPOSAL_CASTACK_K_AXIS): compose family chain depth
# verification.  bind / merge / composite previously returned chains of
# CAStack(axis: 0) + (transpose +) reshape.  K.5/K.6 collapse to:
#
#   merge(at)       -> CAStack(axis: at)                   (depth 1)
#   bind(at)        -> CAStack(axis: at) + reshape         (depth 2)
#   composite(t,at) -> CAStack(axis: at) + reshape         (depth 2)
#
# These tests pin chain depth + the canonical view class at each layer,
# in addition to the shape / data correctness already covered by
# test_compose_family_view_default.rb.

require 'test/unit'
require 'carray'

class TestComposeKAxisRewire < Test::Unit::TestCase

  def setup
    @a = CArray.float64(3, 4) { |i, j| i * 10 + j }
    @b = CArray.float64(3, 4) { |i, j| 100 + i * 10 + j }
    @c = CArray.float64(3, 4) { |i, j| 200 + i * 10 + j }
  end

  # ---------------- merge: single CAStack view ----------------

  def test_merge_at0_returns_castack_k_axis_0
    v = CArray.stack([@a, @b, @c], axis: 0)
    assert_kind_of CAStack, v
    assert_equal 0, v.k_axis
    assert_equal [3, 3, 4], v.shape
  end

  def test_merge_at_mid_returns_castack_k_axis_mid
    v = CArray.stack([@a, @b, @c], axis: 1)
    assert_kind_of CAStack, v
    assert_equal 1, v.k_axis
    assert_equal [3, 3, 4], v.shape
  end

  def test_merge_at_innermost_returns_castack_k_axis_pndim
    v = CArray.stack([@a, @b, @c], axis: -1)
    assert_kind_of CAStack, v
    assert_equal 2, v.k_axis      # parent_ndim = 2
    assert_equal [3, 4, 3], v.shape
  end

  def test_merge_no_transpose_in_chain
    # K.5: single view, parent is the first list element.  Previously
    # for at >= 1 the chain was CATranspose -> CAStack, two view objects.
    v = CArray.stack([@a, @b, @c], axis: 1)
    refute_kind_of CATranspose, v
    # The first parent is the CAStack's parents[0].
    assert_same @a, v.parents[0]
  end

  # ---------------- meld: CAMeld view (post-rename from concat) ----------------

  def test_bind_at0_view_class
    v = CArray.meld([@a, @b, @c], axis: 0)
    # CArray.meld now returns a CAMeld view (was CARefer wrapping CAStack
    # before the concat→meld re-taxonomy — see docs/objects/CAMeld.md).
    assert_kind_of CAMeld, v
    assert_equal 0, v.meld_axis
    assert_equal [9, 4], v.shape
    assert_equal 3, v.n_parents
  end

  def test_bind_at1_view_class
    v = CArray.meld([@a, @b, @c], axis: 1)
    assert_kind_of CAMeld, v
    assert_equal 1, v.meld_axis
    assert_equal [3, 12], v.shape
    assert_equal 3, v.n_parents
  end

  def test_bind_values_at_all_axes
    # Bit-exact cell check on top of the chain-depth assertions.
    [0, 1].each do |at|
      v = CArray.meld([@a, @b, @c], axis: at).to_ca
      if at == 0
        # row 0 = a[0,:], row 3 = b[0,:], row 6 = c[0,:]
        assert_equal 0.0,   v[0, 0]
        assert_equal 100.0, v[3, 0]
        assert_equal 200.0, v[6, 0]
      else
        # col 0..3 = a, col 4..7 = b, col 8..11 = c
        assert_equal 0.0,   v[0, 0]
        assert_equal 100.0, v[0, 4]
        assert_equal 200.0, v[0, 8]
      end
    end
  end

  # composite was removed in the post-K_AXIS surface cleanup (= a thin
  # CArray.stack + reshape wrapper that didn't earn its name).  Users
  # write `stack(...).reshape(...)` directly.
end
