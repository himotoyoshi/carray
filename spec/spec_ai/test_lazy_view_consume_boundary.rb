# ---------------------------------------------------------------------------
# spec_ai/test_lazy_view_consume_boundary.rb
#
# Formal regression pin for the INTEROP_AUDIT boundary matrix
# (= devel/AUDIT_VIEW_CONSUME_MATRIX.md).  Covers the lazy view × consumer
# view × .to_a cells confirmed BUG pre-fix and OK post-N1+N2-fix.
#
# Lazy entry note (= INTEROP_AUDIT 反転 #5 教訓):
#   lazy 経路は lib/carray/lazy.rb の LAZY_MONOP_OP_IDS / LAZY_BINOP_OP_IDS
#   / LAZY_MONCMP_OP_IDS / LAZY_BINCMP_OP_IDS に列挙された method/operator
#   のみ.  `.neg` / `.sqrt` / `.is_finite` / `+` / `>` 等が lazy。`.add` /
#   `.sub` 等の named binop method は EAGER のままなので probe で使うと
#   lazy 経路を bypass する誤計測になる.
# ---------------------------------------------------------------------------

$LOAD_PATH.unshift File.expand_path('../../../ext', __FILE__)
$LOAD_PATH.unshift File.expand_path('../../../lib', __FILE__)

require 'test/unit'
require 'carray'

class TestLazyViewConsumeBoundary < Test::Unit::TestCase
  def setup
    @a = CArray.int32(6); @a[]  = [1, 5, 3, 7, 2, 4]
    @b = CArray.int32(6); @b[]  = [5, 2, 3, 1, 8, 4]
    @af = CArray.float64(6); @af[] = [1.0, 5.0, 3.0, 7.0, 2.0, 4.0]
    @ones_b = CArray.boolean(6); @ones_b.fill(1)
  end

  # === L1 CALazyMarker (= no self-fill, alias only) ===

  def test_l1_lazy_marker_block_wrap
    assert_equal [1, 5, 3, 7, 2, 4], @a.lazy[0..-1].to_a
  end

  def test_l1_lazy_marker_refer_wrap
    assert_equal [1, 5, 3, 7, 2, 4], @a.lazy.reshape(6).to_a
  end

  def test_l1_lazy_marker_transpose_wrap
    assert_equal [[1, 7], [5, 2], [3, 4]],
                 @a.lazy.reshape(2, 3).transpose(1, 0).to_a
  end

  # === L2 CAMonOp (`.neg`) ===

  def test_l2_monop_neg_direct
    assert_equal [-1, -5, -3, -7, -2, -4], @a.lazy.neg.to_a
  end

  def test_l2_monop_neg_block_wrap
    assert_equal [-1, -5, -3, -7, -2, -4], @a.lazy.neg[0..-1].to_a
  end

  def test_l2_monop_neg_refer_wrap
    assert_equal [-1, -5, -3, -7, -2, -4], @a.lazy.neg.reshape(6).to_a
  end

  def test_l2_monop_neg_transpose_wrap
    assert_equal [[-1, -7], [-5, -2], [-3, -4]],
                 @a.lazy.neg.reshape(2, 3).transpose(1, 0).to_a
  end

  def test_l2_monop_sqrt_block_wrap
    af = CArray.float64(4); af[] = [1.0, 4.0, 9.0, 16.0]
    assert_equal [1.0, 2.0, 3.0, 4.0], af.lazy.sqrt[0..-1].to_a
  end

  # === L3 CABinOp (`+`) ===

  def test_l3_binop_plus_direct
    assert_equal [6, 7, 6, 8, 10, 8], (@a.lazy + @b).to_a
  end

  def test_l3_binop_plus_block_wrap
    assert_equal [6, 7, 6, 8, 10, 8], (@a.lazy + @b)[0..-1].to_a
  end

  def test_l3_binop_plus_refer_wrap
    assert_equal [6, 7, 6, 8, 10, 8], (@a.lazy + @b).reshape(6).to_a
  end

  def test_l3_binop_plus_transpose_wrap
    assert_equal [[6, 8], [7, 10], [6, 8]],
                 (@a.lazy + @b).reshape(2, 3).transpose(1, 0).to_a
  end

  def test_l3_binop_minus_block_wrap
    assert_equal [-4, 3, 0, 6, -6, 0], (@a.lazy - @b)[0..-1].to_a
  end

  def test_l3_binop_mul_block_wrap
    assert_equal [5, 10, 9, 7, 16, 16], (@a.lazy * @b)[0..-1].to_a
  end

  # === L4 CAMonCmp (`.is_finite`) ===

  def test_l4_moncmp_is_finite_direct
    assert_equal [true, true, true, true, true, true], @af.lazy.is_finite.to_a
  end

  def test_l4_moncmp_is_finite_block_wrap
    assert_equal [true, true, true, true, true, true], @af.lazy.is_finite[0..-1].to_a
  end

  def test_l4_moncmp_is_finite_refer_wrap
    assert_equal [true, true, true, true, true, true], @af.lazy.is_finite.reshape(6).to_a
  end

  # === L5 CABinCmp (`>`) ===

  def test_l5_bincmp_gt_direct
    assert_equal [false, true, false, true, false, false], (@a.lazy > @b).to_a
  end

  def test_l5_bincmp_gt_block_wrap
    assert_equal [false, true, false, true, false, false], (@a.lazy > @b)[0..-1].to_a
  end

  def test_l5_bincmp_gt_refer_wrap
    assert_equal [false, true, false, true, false, false], (@a.lazy > @b).reshape(6).to_a
  end

  def test_l5_bincmp_gt_transpose_wrap
    assert_equal [[false, true], [true, false], [false, false]],
                 (@a.lazy > @b).reshape(2, 3).transpose(1, 0).to_a
  end

  def test_l5_bincmp_lt_block_wrap
    assert_equal [true, false, false, false, true, false], (@a.lazy < @b)[0..-1].to_a
  end

  # === Cross-wrap chain ===

  def test_l5_bincmp_gt_and_eager_boolean_via_block
    # (a.lazy > b)[0..-1] & ones_b — must reach the same value path
    assert_equal [false, true, false, true, false, false], ((@a.lazy > @b)[0..-1] & @ones_b).to_a
  end

  def test_l5_bincmp_gt_as_uint8_then_eager_minus
    ones_u = CArray.uint8(6); ones_u.fill(1)
    # (a.lazy > b).as_uint8 - ones_u8
    # truth: 0-1=255 (underflow), 1-1=0, ...
    assert_equal [255, 0, 255, 0, 255, 255],
                 ((@a.lazy > @b).as_uint8 - ones_u).to_a
  end

  def test_l3_binop_plus_as_int32_then_eager_minus
    assert_equal [5, 6, 5, 7, 9, 7], ((@a.lazy + @b).as_int32 - 1).to_a
  end

  # === Reduction over wrapped lazy view (= sanity for chain) ===

  def test_l3_binop_plus_block_then_sum
    # sum over the wrapped lazy view
    assert_equal 45, (@a.lazy + @b)[0..-1].sum
  end

  def test_l5_bincmp_gt_block_then_count_true
    # count_true via &-with-ones, post-fix expectation
    assert_equal 2, ((@a.lazy > @b)[0..-1] & @ones_b).count(true)
  end
end
