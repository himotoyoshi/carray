# ---------------------------------------------------------------------------
# spec_ai/test_lazy_taxonomy_p5a2.rb
#
# Phase 5a P.5a.2 — §3.4 操作 taxonomy table を formal test として pin.
#
# Parent proposal §3.4 (= rev3 A1 新規、Phase 0 sign-off 必須) で
# 規定された taxonomy:
#   - element-wise op (lazy 保持) → CAMonOp/CABinOp 構築、materialise なし
#   - affine view (lazy 保持) → CAShift 等が lazy-tagged で返る
#   - reduction (materialise 強制) → first touch で entity 化
#   - Enumerable 経由 (materialise 強制) → lazy_view.each / to_a / map / sort
#   - `[]=` raise (= CA_FLAG_READ_ONLY 経由、P.5a.1 で landed 済)
#   - per-cell `[]` (materialise 経由で動作)
#   - MV export → TypeError + .copy/.to_ca 推奨 message
#   - inspect / to_s (評価せず要約)
#   - dump_tree (評価せず要約)
#
# 一部の項目 (Ractor move、0-dim Numeric coerce) は CArray 既存 entity
# でも未実装の path のため、本 phase scope 外。
# ---------------------------------------------------------------------------

$LOAD_PATH.unshift File.expand_path('../../../ext', __FILE__)
$LOAD_PATH.unshift File.expand_path('../../../lib', __FILE__)

require 'test/unit'
require 'carray'

class TestLazyTaxonomyP5a2 < Test::Unit::TestCase
  def setup
    @a = CArray.float64(5).seq(1.0, 1.0)
    @b = CArray.float64(5).seq(2.0, 1.0)
  end

  # --- element-wise op (lazy 保持) ----------------------------------------

  def test_monop_builds_lazy_node_not_materialised
    r = @a.lazy.sqrt
    assert_kind_of CAMonOp, r
    refute r.class == CArray
  end

  def test_binop_builds_lazy_node_not_materialised
    r = @a.lazy + @b
    assert_kind_of CABinOp, r
    refute r.class == CArray
  end

  def test_chained_monop_builds_nested_tree
    r = @a.lazy.sqrt.sin.exp
    assert_kind_of CAMonOp, r
    # The tree depth is implicit in dump_tree; here we just verify
    # the chain doesn't collapse to an entity.
    refute r.class == CArray
  end

  def test_cmp_builds_lazy_bool
    r = @a.lazy < @b
    assert_kind_of CABinCmp, r
  end

  def test_monfunc_lt_zero_builds_lazy
    r = @a.lazy.is_nan
    assert_kind_of CAMonCmp, r
  end

  # --- reduction (materialise 強制) ---------------------------------------

  def test_reduction_sum_materialises_to_entity_scalar
    lazy = @a.lazy + @b
    s = lazy.sum
    refute_kind_of CAMonOp, s
    refute_kind_of CABinOp, s
    # Float result, byte parity with eager
    assert_in_delta (@a + @b).sum, s, 1e-12
  end

  def test_reduction_mean_materialises
    s = (@a.lazy * 2.0).mean
    refute_kind_of CAMonOp, s
    refute_kind_of CABinOp, s
    assert_in_delta (@a * 2.0).mean, s, 1e-12
  end

  # --- Enumerable 経由 (materialise + delegate) ---------------------------

  def test_each_materialises_and_yields_entity_values
    lazy = @a.lazy.sqrt
    seen = []
    lazy.each { |v| seen << v }
    expected = @a.sqrt.to_a
    assert_equal expected.size, seen.size
    seen.each_with_index do |v, i|
      assert_in_delta expected[i], v, 1e-12
    end
  end

  def test_to_a_materialises
    lazy = @a.lazy + @b
    arr = lazy.to_a
    assert_instance_of Array, arr
    assert_equal (@a + @b).to_a, arr
  end

  # --- per-cell [] (works via xfer_index) ---------------------------------

  def test_per_cell_access_works
    lazy = @a.lazy.sqrt
    # Result should equal the eager equivalent
    @a.elements.times do |i|
      assert_in_delta @a.sqrt[i], lazy[i], 1e-12,
                      "per-cell access at #{i}"
    end
  end

  # --- []= raise (= CA_FLAG_READ_ONLY、P.5a.1 で landed) -----------------

  def test_lazy_marker_assignment_raises
    m = @a.lazy
    assert_raise(RuntimeError) { m[0] = 99.0 }
  end

  def test_monop_assignment_raises
    lazy = @a.lazy.sqrt
    assert_raise(RuntimeError) { lazy[0] = 99.0 }
  end

  def test_binop_assignment_raises
    lazy = @a.lazy + @b
    assert_raise(RuntimeError) { lazy[0] = 99.0 }
  end

  # --- MV export → TypeError + recommendation -----------------------------

  def test_lazy_marker_to_memory_view_raises
    m = @a.lazy
    assert_raise(TypeError) { m.to_memory_view }
  end

  def test_monop_to_memory_view_raises_with_hint
    lazy = @a.lazy.sqrt
    e = assert_raise(TypeError) { lazy.to_memory_view }
    assert_match(/copy|to_ca|materialise/i, e.message,
                 "error message must hint at materialisation idiom")
  end

  def test_binop_to_memory_view_raises
    lazy = @a.lazy + @b
    assert_raise(TypeError) { lazy.to_memory_view }
  end

  # --- inspect / to_s (no materialise、summary only) ----------------------

  def test_monop_inspect_returns_summary_string
    lazy = @a.lazy.sqrt
    s = lazy.inspect
    assert_instance_of String, s
    assert_match(/CAMonOp/, s)
    assert_match(/sqrt/, s)
  end

  def test_binop_inspect_returns_summary_string
    lazy = @a.lazy + @b
    s = lazy.inspect
    assert_instance_of String, s
    assert_match(/CABinOp/, s)
  end

  def test_marker_inspect_no_op
    m = @a.lazy
    s = m.inspect
    assert_instance_of String, s
  end

  def test_to_s_aliases_inspect
    lazy = @a.lazy.sqrt
    assert_equal lazy.inspect, lazy.to_s
  end

  # --- dump_tree (no materialise、ASCII art) ------------------------------

  def test_monop_dump_tree_returns_ascii
    lazy = @a.lazy.sqrt.sin
    s = lazy.dump_tree
    assert_instance_of String, s
    assert_match(/sqrt/, s)
    assert_match(/sin/, s)
  end

  def test_binop_dump_tree_returns_ascii
    lazy = @a.lazy + @b
    s = lazy.dump_tree
    assert_instance_of String, s
    assert_match(/\+/, s)
  end

  # --- explicit materialise path (.to_ca) ---------------------------------

  def test_to_ca_yields_entity
    lazy = @a.lazy + @b
    e = lazy.to_ca
    assert_kind_of CArray, e
    refute_kind_of CAMonOp, e
    refute_kind_of CABinOp, e
    assert_equal (@a + @b).to_a, e.to_a
  end

  # --- regression: Phase 1+2+4 byte parity sanity -------------------------

  def test_byte_parity_monop
    lazy = @a.lazy.sqrt.exp
    eager = @a.sqrt.exp
    @a.elements.times do |i|
      assert_in_delta eager[i], lazy.to_ca[i], 1e-12
    end
  end

  def test_byte_parity_binop
    lazy = (@a.lazy + @b) * 2.0
    eager = (@a + @b) * 2.0
    @a.elements.times do |i|
      assert_in_delta eager[i], lazy.to_ca[i], 1e-12
    end
  end
end
