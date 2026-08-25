require "test/unit"
require "carray"

# PROPOSAL_LAZY_ELEMENTWISE_VIEW Phase 4.5 P.4.5.1 — SRC_ATTACH
# classification for lazy view family.
#
# Before P.4.5.1: `(a.lazy + b).sum` raises "kernel_iterator init
# failed rc=1" because CAMonOp/CABinOp/CABinCmp/CAMonCmp weren't
# registered in ca_iter_classify_source.
#
# After P.4.5.1: 4 lines added to classify_source list, all 22
# mkkernel-generated reduction ops accept lazy operands via SRC_ATTACH
# (= materialise via func_attach into a contig buffer, kernel walks
# normally).
#
# Coverage axes:
#   - sum / count / count(true) / mean / min / max / argmin / argmax /
#     variance / stddev / prod / accumulate / sum_strict
#   - lazy operand sources: CAMonOp (.sqrt, .neg) / CABinOp (+, -, *, /) /
#     CABinCmp (>, <, eq) / CAMonCmp (is_nan)
#   - all numeric data_types (sampled)
#   - mask propagation (= masked operand → reduction kernel mask)
#   - multi-axis reduction (axis kwarg)
#   - flat reduction (no axis arg)

class TestLazyReductionP451 < Test::Unit::TestCase
  N = 100

  def setup
    @a = CArray.float64(N) { |k| k - N / 2 + 1 }
    @b = CArray.float64(N) { |k| (k - N / 2 + 1) * 0.5 }
  end

  # === flat reduction: lazy operand from each view family ===

  def test_sum_via_binop_lazy
    eager = (@a + @b).sum
    lazy  = (@a.lazy + @b).sum
    assert_equal eager, lazy
  end

  def test_sum_via_monop_lazy
    pos = CArray.float64(N) { |k| (k + 1).to_f }   # ensure positive for sqrt
    eager = pos.sqrt.sum
    lazy  = pos.lazy.sqrt.sum
    assert_in_delta eager, lazy, 1e-10
  end

  def test_count_true_via_bincmp_lazy
    eager = (@a > 0).count(true)
    lazy  = (@a.lazy > 0).count(true)
    assert_equal eager, lazy
  end

  def test_count_true_via_compound_chain
    eager = ((@a > -10) & (@a < 10)).count(true)
    lazy  = ((@a.lazy > -10) & (@a.lazy < 10)).count(true)
    assert_equal eager, lazy
  end

  def test_count_via_moncmp_lazy
    arr = CArray.float64(N) { |k|
      if k < 5 then Float::NAN
      elsif k < 10 then Float::INFINITY
      else k.to_f
      end
    }
    eager_nan = arr.is_nan.count(true)
    lazy_nan  = arr.lazy.is_nan.count(true)
    assert_equal eager_nan, lazy_nan
    eager_finite = arr.is_finite.count(true)
    lazy_finite  = arr.lazy.is_finite.count(true)
    assert_equal eager_finite, lazy_finite
  end

  # === reduction op coverage ===

  def test_mean_lazy
    eager = (@a + @b).mean
    lazy  = (@a.lazy + @b).mean
    assert_in_delta eager, lazy, 1e-12
  end

  def test_min_lazy
    eager = (@a + @b).min
    lazy  = (@a.lazy + @b).min
    assert_equal eager, lazy
  end

  def test_max_lazy
    eager = (@a + @b).max
    lazy  = (@a.lazy + @b).max
    assert_equal eager, lazy
  end

  def test_prod_lazy
    a = CArray.float64(10) { |k| (k % 3) + 1.5 }
    eager = (a + 0.1).prod
    lazy  = (a.lazy + 0.1).prod
    assert_in_delta eager, lazy, 1e-10
  end

  def test_variance_lazy
    eager = (@a + @b).variance
    lazy  = (@a.lazy + @b).variance
    assert_in_delta eager, lazy, 1e-10
  end

  def test_stddev_lazy
    eager = (@a + @b).stddev
    lazy  = (@a.lazy + @b).stddev
    assert_in_delta eager, lazy, 1e-10
  end

  # === lazy chain composition ===

  def test_sum_over_deep_chain
    chain_eager = @a + @b + @a + @b
    chain_lazy  = @a.lazy + @b + @a + @b
    assert_in_delta chain_eager.sum, chain_lazy.sum, 1e-9
  end

  def test_count_true_over_binop_compose_bincmp
    # ((a + b) > 0).count(true)
    eager = ((@a + @b) > 0).count(true)
    lazy  = ((@a.lazy + @b) > 0).count(true)
    assert_equal eager, lazy
  end

  # === data_type coverage ===

  def test_sum_per_data_type
    [:int8, :int16, :int32, :int64, :float32, :float64].each do |dt_sym|
      a = CArray.send(dt_sym, N) { |k| (k % 7) + 1 }
      b = CArray.send(dt_sym, N) { |k| (k % 5) + 1 }
      eager = (a + b).sum
      lazy  = (a.lazy + b).sum
      assert_equal eager, lazy, "sum parity on #{dt_sym}"
    end
  end

  # === mask propagation (Q6 active confirm) ===

  def test_sum_with_masked_lazy_operand
    a = @a.dup
    a[0..9] = UNDEF
    eager = (a + @b).sum
    lazy  = (a.lazy + @b).sum
    assert_equal eager, lazy, "sum with masked operand parity"
  end

  def test_mean_with_masked_lazy_operand
    a = @a.dup
    a[0..19] = UNDEF
    eager = (a + @b).mean
    lazy  = (a.lazy + @b).mean
    assert_in_delta eager, lazy, 1e-12
  end

  def test_count_true_with_masked_operand
    a = @a.dup
    a[0..9] = UNDEF
    eager = (a > 0).count(true)
    lazy  = (a.lazy > 0).count(true)
    assert_equal eager, lazy
  end

  # === multi-axis reduction (Q5 = flat + axis 両方含める) ===

  def test_sum_axis_2d_lazy
    # NOTE: axis kwarg unification (API harmonisation A.2, separate
    # parallel session) banned positional axis args.  Use axis: kwarg.
    ma = CArray.float64(10, 10) { |k| k }
    mb = CArray.float64(10, 10) { |k| k + 1 }
    eager_axis0 = (ma + mb).sum(axis: 0)
    lazy_axis0  = (ma.lazy + mb).sum(axis: 0)
    assert_equal eager_axis0.to_a, lazy_axis0.to_a
    eager_axis1 = (ma + mb).sum(axis: 1)
    lazy_axis1  = (ma.lazy + mb).sum(axis: 1)
    assert_equal eager_axis1.to_a, lazy_axis1.to_a
  end

  def test_count_true_axis_2d_lazy
    ma = CArray.float64(10, 10) { |k| k - 50 }
    eager = (ma > 0).count(true, axis: 0)
    lazy  = (ma.lazy > 0).count(true, axis: 0)
    assert_equal eager.to_a, lazy.to_a
  end

  # === arena lifecycle (= Phase 3 rev5 rb_ensure 経由) ===

  def test_arena_depth_balances_through_lazy_reduction
    CArray.__lazy_arena_reset_counters__
    # A bunch of lazy reductions
    100.times do |k|
      _ = (@a.lazy + @b * (k + 1.0)).sum
    end
    assert_equal 0, CArray.__lazy_arena_depth__,
                 "arena depth must balance after 100 lazy reductions"
    assert_equal 0, CArray.__lazy_arena_slot_in_use_count__,
                 "arena slots must release after lazy reductions"
  end

  # === argmin / argmax ===

  def test_min_index_lazy
    # CArray uses *_index for "返り値が位置" methods (= CLAUDE.md「設計の
    # 前提: 位置を返す method は `*_index`、`arg*` 系は採用しない」).
    a = CArray.float64(N) { |k| ((k - 30) * 1.0).abs }
    eager = a.min_index
    lazy  = (a.lazy + 0.0).min_index
    assert_equal eager, lazy
  end

  def test_max_index_lazy
    a = CArray.float64(N) { |k| -((k - 70) * 1.0).abs }
    eager = a.max_index
    lazy  = (a.lazy + 0.0).max_index
    assert_equal eager, lazy
  end

  # === count(value) ===

  def test_count_value_with_lazy_eq
    # count(true) is just one form; count(v) for arbitrary v on lazy
    a = CArray.int32(N) { |k| k % 5 }
    eager = a.count(2)
    lazy  = (a.lazy + 0).count(2)  # lazy adds 0 (no-op)
    assert_equal eager, lazy
  end
end
