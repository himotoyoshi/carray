require "test/unit"
require "carray"

# Phase 6 後続: CArray.lazy method (= CArray.fuse の対).
#
# Block 内で args を .lazy で wrap、block return を **そのまま** 返す
# (= fuse と違って block exit で auto-materialise しない).  lazy 構造
# を関数間で渡す / 再利用 / 後で materialise する用途.

class TestCArrayLazyMethod < Test::Unit::TestCase

  def setup
    @a = CArray.float64(5).seq!(1.0)   # [1, 2, 3, 4, 5]
    @b = CArray.float64(5).seq!(10.0)  # [10, 11, 12, 13, 14]
  end

  # ----- basic semantics -----

  def test_lazy_returns_lazy_view_for_binop
    expr = CArray.lazy(@a, @b) { |s, o| (s + o) * 2 }
    assert_kind_of CABinOp, expr
  end

  def test_lazy_returns_lazy_view_for_moncmp
    expr = CArray.lazy(@a) { |s| s.is_finite }
    assert_kind_of CAMonCmp, expr
  end

  def test_lazy_returns_lazy_view_for_monop
    expr = CArray.lazy(@a) { |s| s.sqrt }
    assert_kind_of CAMonOp, expr
  end

  # ----- materialise on demand -----

  def test_to_ca_materialises_full
    expr = CArray.lazy(@a, @b) { |s, o| (s + o) * 2 }
    materialised = expr.to_ca
    assert_kind_of CArray, materialised
    assert_equal [22.0, 26.0, 30.0, 34.0, 38.0], materialised.to_a
  end

  def test_sum_materialises_via_reduction
    # deep chain + reduce: chain 全体が 1 reduction pass で計算される
    expr = CArray.lazy(@a, @b) { |s, o| (s + o) }
    # sum should be (1+10)+(2+11)+(3+12)+(4+13)+(5+14) = 75
    assert_in_delta 75.0, expr.sum, 1e-9
  end

  # ----- polymorphic semantics (= fuse §1.0 と対称) -----

  def test_lazy_passes_through_non_carray_args
    # Numeric arg は pass-through (= fuse と同 semantics)
    expr = CArray.lazy(25.0, @b) { |s, o| s + o }
    assert_kind_of CABinOp, expr
    assert_equal [35.0, 36.0, 37.0, 38.0, 39.0], expr.to_a
  end

  def test_lazy_all_numeric_args_pass_through
    # block 内が pure Float 計算なら Float pass-through (= fuse と同)
    result = CArray.lazy(25.0, 17.27) { |t, c| c * t / (t + 237.3) }
    assert_kind_of Float, result
    assert_in_delta 17.27 * 25.0 / (25.0 + 237.3), result, 1e-9
  end

  # ----- fuse との対比 -----

  def test_fuse_auto_materialises_lazy_returns_entity
    result = CArray.fuse(@a, @b) { |s, o| (s + o) * 2 }
    assert_kind_of CArray, result    # entity
  end

  def test_lazy_does_not_materialise_returns_lazy_view
    result = CArray.lazy(@a, @b) { |s, o| (s + o) * 2 }
    assert_kind_of CABinOp, result   # lazy view
    # Same value when materialised
    assert_equal CArray.fuse(@a, @b) { |s, o| (s + o) * 2 }.to_a,
                 result.to_ca.to_a
  end

  # ----- contract: requires block -----

  def test_lazy_raises_without_block
    assert_raise(LocalJumpError) do
      CArray.lazy(@a, @b)
    end
  end

  # ----- nested lazy / fuse interaction -----

  def test_nested_lazy_inside_fuse_is_materialised
    # fuse の auto-materialise は CArray.lazy で構築した chain にも
    # 効く (= lazy view が return されたら materialise する)
    inner_expr = CArray.lazy(@a, @b) { |s, o| (s + o) * 2 }
    result = CArray.fuse() { inner_expr }   # no args, return inner_expr
    assert_kind_of CArray, result
    assert_equal [22.0, 26.0, 30.0, 34.0, 38.0], result.to_a
  end
end
