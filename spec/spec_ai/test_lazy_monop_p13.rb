$LOAD_PATH.unshift File.expand_path("../../../ext", __FILE__)
$LOAD_PATH.unshift File.expand_path("../../../lib", __FILE__)
require "test/unit"
require "carray"

# PROPOSAL_LAZY_ELEMENTWISE_VIEW Phase 1 P.1.3 — surface contract tests.
#
# Pins the §3.4 operations taxonomy, the unmask fast path (kernels
# always invoked with mask=NULL, mask propagation handled by attach
# lifecycle), and inspect/dump_tree summary semantics.
class TestLazyMonopP13 < Test::Unit::TestCase

  ## ====== Inspect / dump_tree (no materialise) ===========================

  def test_inspect_does_not_materialise
    a = CArray.float64(5).seq + 1.0
    v = a.lazy.sqrt.sin.exp

    CAMonOp.__reset_materialise_counter__
    str = v.inspect
    assert_equal 0, CAMonOp.__materialise_count__,
      "inspect must not call xfer_stride"
    assert_match(/CAMonOp/, str)
    assert_match(/exp/, str)
    assert_match(/sin/, str)
    assert_match(/sqrt/, str)
  end

  def test_to_s_does_not_materialise
    a = CArray.float64(5).seq + 1.0
    v = a.lazy.sqrt

    CAMonOp.__reset_materialise_counter__
    s = v.to_s
    assert_equal 0, CAMonOp.__materialise_count__
    assert s.is_a?(String)
  end

  def test_dump_tree_does_not_materialise
    a = CArray.float64(5).seq + 1.0
    v = a.lazy.sqrt.sin.exp

    CAMonOp.__reset_materialise_counter__
    tree = v.dump_tree
    assert_equal 0, CAMonOp.__materialise_count__
    # Tree should mention all three ops in a hierarchical (deepening
    # indent) ASCII format.
    lines = tree.split("\n")
    assert_equal "exp",        lines[0]
    assert_equal "  sin",      lines[1]
    assert_equal "    sqrt",   lines[2]
    assert_match(/CArray.*float64.*\[5\]/, lines[3])
  end

  def test_dump_tree_shows_cast_node_for_widening
    a = CArray.int32(5).seq + 1
    v = a.lazy.sqrt
    tree = v.dump_tree
    lines = tree.split("\n")
    assert_equal "sqrt",          lines[0]
    assert_equal "  cast_float64", lines[1]
    assert_match(/CArray.*int32/,  lines[2])
  end

  def test_marker_inspect_and_dump_tree
    a = CArray.float64(5).seq + 1.0
    m = a.lazy
    CAMonOp.__reset_materialise_counter__
    assert_match(/CALazyMarker/, m.inspect)
    assert_match(/lazy\(marker\)/, m.dump_tree)
    assert_equal 0, CAMonOp.__materialise_count__,
      "marker inspect/dump_tree must not materialise"
  end

  ## ====== §3.4 Enumerable receivers materialise on first touch ==========

  def test_each_materialises_on_lazy
    a = CArray.float64(10).seq + 1.0
    v = a.lazy.sqrt

    CAMonOp.__reset_materialise_counter__
    collected = []
    v.each { |x| collected << x }
    assert_equal 1, CAMonOp.__materialise_count__,
      "each must materialise via to_ca once"

    expected = a.sqrt.to_a
    expected.each_with_index do |e, i|
      assert_in_delta e, collected[i], 1e-12
    end
  end

  def test_to_a_materialises_on_lazy
    a = CArray.float64(10).seq + 1.0
    v = a.lazy.sqrt

    CAMonOp.__reset_materialise_counter__
    arr = v.to_a
    assert_equal 1, CAMonOp.__materialise_count__
    assert_equal a.sqrt.to_a, arr
  end

  def test_sort_materialises_on_lazy
    a = CArray.float64(10).seq + 1.0
    v = a.lazy.neg                   # negate -> [-1, -2, -3, ...]

    CAMonOp.__reset_materialise_counter__
    sorted = v.sort
    assert_equal 1, CAMonOp.__materialise_count__,
      "sort must materialise first"
    # sort returns a CARemap view (post-SO.2); compare to eager neg sorted
    assert_equal a.neg.sort.to_a, sorted.to_a
  end

  def test_manual_reduction_via_each
    # CArray doesn't include Enumerable, so `inject` isn't on the
    # taxonomy table directly.  But user-side reductions written via
    # each must still materialise once (the each override calls to_ca).
    a = CArray.float64(5).seq + 1.0   # [1, 2, 3, 4, 5]
    v = a.lazy.neg                    # [-1, -2, -3, -4, -5]
    CAMonOp.__reset_materialise_counter__
    total = 0.0
    v.each { |x| total += x }
    assert_equal 1, CAMonOp.__materialise_count__
    assert_in_delta(-15.0, total, 1e-12)
  end

  ## ====== []= raises on lazy view ========================================

  def test_setindex_raises_on_lazy
    a = CArray.float64(5).seq + 1.0
    v = a.lazy.sqrt
    assert_raise(RuntimeError) { v[0] = 1.0 }
    assert_raise(RuntimeError) { v[0..2] = 1.0 }
  end

  ## ====== MemoryView export rejected ====================================

  def test_mv_to_memory_view_rejects_camonop
    a = CArray.float64(5).seq + 1.0
    v = a.lazy.sqrt
    err = assert_raise(TypeError) { v.to_memory_view }
    assert_match(/\.copy/, err.message,
      "error message should suggest .copy")
  end

  def test_mv_to_memory_view_rejects_marker
    a = CArray.float64(5).seq + 1.0
    m = a.lazy
    err = assert_raise(TypeError) { m.to_memory_view }
    assert_match(/\.copy/, err.message)
  end

  def test_mv_after_to_ca_succeeds
    # The recommended workflow: materialise to entity, then MV the entity.
    a = CArray.float64(5).seq + 1.0
    v = a.lazy.sqrt
    entity = v.to_ca
    # Probing for MV producer availability — must be true on entity.
    assert CArray.memory_view_available?(entity)
  end

  ## ====== Unmask fast path & mask propagation ===========================

  def test_unmask_fast_path_for_unmasked_input
    # No mask on input -> output produced via SIMD-fast (m == NULL)
    # kernel branch.  The byte parity vs eager already pins this in
    # P.1.2; here we just re-confirm with chain depth.
    a = CArray.float64(20).seq + 1.0
    chain = a.lazy
    5.times { chain = chain.sqrt }
    result = chain.to_ca
    expected = a
    5.times { expected = expected.sqrt }
    assert_equal expected.dump_binary, result.dump_binary
  end

  def test_mask_propagation_via_attach_lifecycle
    # Lazy view inherits parent's mask through ca_monop_func_create_mask
    # + CARefer over parent.mask.  Materialise produces correct output
    # mask (= parent mask), and reads of masked cells return UNDEF.
    a = CArray.float64(5).seq + 1.0
    a[2] = UNDEF
    v = a.lazy.sqrt
    result = v.to_ca

    # output mask matches eager
    assert_equal a.sqrt.is_masked.to_a, result.is_masked.to_a
    # unmasked cells match eager byte-by-byte (compute via sqrt of valid
    # values).  We can't compare full dump_binary because masked cell
    # byte content is garbage in lazy (unobservable, per design).
    [0, 1, 3, 4].each do |i|
      assert_equal a.sqrt[i], result[i], "unmasked cell #{i} mismatch"
    end
  end

  def test_mask_propagation_through_chain
    a = CArray.float64(5).seq + 1.0
    a[2] = UNDEF
    a[4] = UNDEF
    v = a.lazy.sqrt.sin.exp
    result = v.to_ca

    eager = a.sqrt.sin.exp
    assert_equal eager.is_masked.to_a, result.is_masked.to_a
    [0, 1, 3].each do |i|
      assert_in_delta eager[i], result[i], 1e-12
    end
  end

  ## ====== Per-cell access works but is documented slow path ============

  def test_per_cell_access_does_not_crash
    # R1' (Phase 1 prep doc): per-cell `lazy_view[i]` works via
    # xfer_index but with overhead.  Doc recommends `.to_ca` snapshot
    # for hot loops; here we just verify correctness.
    a = CArray.float64(5).seq + 1.0
    v = a.lazy.sqrt
    expected = a.sqrt
    5.times do |i|
      assert_in_delta expected[i], v[i], 1e-12
    end
  end
end
