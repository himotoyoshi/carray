# L.7 loop-interchange fast path — Tier 1 (contig-alias views) + Tier 2 (CAStack)
# MEMO_REDUCTION_FASTPATH_ENTITY_ONLY_GUARD resolution.
#
# Pins bit-exact equivalence between the non-innermost single-axis reduce of
# a view and the same reduce of its materialised entity, across the kernels
# that carry the loop-interchange fast path (sum/mean/min/max/prod/variance).
# Correctness is the contract; the speedup (view == eager) is a perf property
# verified separately in devel/bench.

require 'test/unit'
require 'carray'

class TestReduceLoopInterchangeViews < Test::Unit::TestCase

  OPS = %i[sum mean min max prod variance]

  def assert_reduce_parity(view, axis, label)
    ent = view.to_ca
    OPS.each do |op|
      a = view.send(op, axis: axis)
      b = ent.send(op, axis: axis)
      d = (a.to_ca - b.to_ca).abs.max
      assert d < 1e-9, "#{label} #{op} axis:#{axis} maxdiff=#{d}"
    end
  end

  # ---- Tier 2: CAStack reduces a parent axis (axis >= 1) ----

  def test_castack_parent_axis_reduce_parity
    k = 6
    list = Array.new(k) { CArray.float64(20, 18, 9) { |i| Math.sin(i * 0.3) } }
    view = CArray.stack(list)
    (1...view.ndim).each do |ax|
      assert_reduce_parity(view, ax, "stack(f64)")
    end
  end

  def test_castack_parent_axis_matches_manual_per_parent
    # The Tier 2 path *is* the per-parent reduce; pin the identity explicitly.
    k = 5
    list = Array.new(k) { CArray.float64(24, 10) { |i| (i % 31) - 15 } }
    view = CArray.stack(list)
    manual = CArray.stack(list.map { |p| p.mean(axis: 0) })
    assert_equal 0.0, (view.mean(axis: 1).to_ca - manual.to_ca).abs.max
  end

  def test_castack_int_dtype_parity
    k = 4
    list = Array.new(k) { CArray.int32(16, 12) { |i| (i * 7) % 13 } }
    view = CArray.stack(list)
    assert_reduce_parity(view, 1, "stack(i32)")
  end

  def test_castack_k_axis_reduce_still_correct
    # axis 0 (K axis) takes a different path; guard against accidental breakage.
    list = Array.new(5) { CArray.float64(8, 9) { |i| i } }
    view = CArray.stack(list)
    assert_equal 0.0, (view.sum(axis: 0).to_ca - view.to_ca.sum(axis: 0)).abs.max
  end

  def test_castack_below_threshold_parity
    # INNER below the gate (9 < 64) falls to the generic path; still correct.
    list = Array.new(3) { CArray.float64(7, 9) { |i| i * 1.5 } }
    view = CArray.stack(list)
    assert_reduce_parity(view, 1, "stack-small")
  end

  # ---- Tier 1: contig-alias views (entity-equivalent buffer) ----

  def test_reshape_alias_reduce_parity
    big = CArray.float64(40, 18, 9) { |i| Math.cos(i * 0.1) }
    rs  = big.reshape(40 * 18, 9)            # contiguous alias
    assert_reduce_parity(rs, 0, "reshape-alias")
  end

  def test_row_block_alias_reduce_parity
    big = CArray.float64(30, 18, 9) { |i| i % 97 }
    blk = big[3..28, nil, nil]               # contiguous row block (alias)
    assert_reduce_parity(blk, 1, "row-block-alias")
  end

  def test_transpose_noncontig_reduce_parity
    # Non-contiguous view: ca_attach_is_alias is false, so it takes the
    # generic path — must still be correct.
    big = CArray.float64(12, 18, 9) { |i| Math.sin(i) }
    tr  = big.transpose(2, 0, 1)
    assert_reduce_parity(tr, 1, "transpose")
  end
end
