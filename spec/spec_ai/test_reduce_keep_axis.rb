require 'test/unit'
require 'carray'

# ============================================================
# MkKernel.reduce keep_axis: kwarg (= NumPy keepdims).
#
# keep_axis: true retains each reduced axis as a length-1 axis instead
# of dropping it.  Element count and row-major order are unchanged, so
# the result is value-identical to the dropped form with size-1 axes
# inserted at the reduced positions (= automation of view[..., :_]).
#
#   - partial single axis  : drop -> keep size-1 at that axis
#   - partial multi axis   : drop -> keep size-1 at each reduced axis
#   - full reduction       : scalar -> [1, 1, ..., 1] entity
#   - mask propagation     : min_count mask carries onto the kept output
#   - returns an entity (not a view), uniform across the reduce family
#
# Covers the basic path (sum), loop-interchange path (mean / variance),
# fused-minmax path (min / max), and the count family.
# ============================================================

class TestReduceKeepAxis < Test::Unit::TestCase

  def setup
    @a = CArray.float64(2, 3, 4) { |i| i.to_f }
  end

  # ---- partial: single axis -------------------------------------

  def test_partial_single_axis_shape
    assert_equal [2, 1, 4], @a.sum(axis: 1, keep_axis: true).shape
  end

  def test_partial_single_axis_values_match_dropped
    dropped = @a.sum(axis: 1)             # [2, 4]
    kept    = @a.sum(axis: 1, keep_axis: true)
    assert_equal dropped.reshape(2, 1, 4).to_a, kept.to_a
  end

  def test_partial_returns_entity
    kept = @a.sum(axis: 1, keep_axis: true)
    assert_instance_of CArray, kept
    assert kept.entity?, "keep_axis result should be an entity"
  end

  # ---- partial: multi axis --------------------------------------

  def test_partial_multi_axis_shape
    assert_equal [1, 3, 1], @a.sum(axis: [0, 2], keep_axis: true).shape
  end

  def test_partial_multi_axis_values_match_dropped
    dropped = @a.sum(axis: [0, 2])        # [3]
    kept    = @a.sum(axis: [0, 2], keep_axis: true)
    assert_equal dropped.reshape(1, 3, 1).to_a, kept.to_a
  end

  # ---- full reduction -------------------------------------------

  def test_full_reduction_shape
    kept = @a.sum(keep_axis: true)
    assert_instance_of CArray, kept
    assert_equal [1, 1, 1], kept.shape
  end

  def test_full_reduction_value_matches_scalar
    assert_equal @a.sum, @a.sum(keep_axis: true)[0, 0, 0]
  end

  def test_full_reduction_1d
    v = CArray.float64(5).seq!(1.0, 1.0)
    kept = v.sum(keep_axis: true)
    assert_equal [1], kept.shape
    assert_equal v.sum, kept[0]
  end

  # ---- broadcast use case (the motivating idiom) ----------------

  def test_broadcast_subtract
    # a - a.sum(axis: 1, keep_axis: true) == a - a.sum(axis: 1)[nil, :_]
    expect = @a - @a.sum(axis: 1)[nil, :_, nil]
    got    = @a - @a.sum(axis: 1, keep_axis: true)
    assert_equal expect.to_a, got.to_a
  end

  # ---- loop-interchange path (mean / variance) ------------------

  def test_mean_keep_axis
    assert_equal [1, 3, 4], @a.mean(axis: 0, keep_axis: true).shape
    assert_equal @a.mean(axis: 0).reshape(1, 3, 4).to_a,
                 @a.mean(axis: 0, keep_axis: true).to_a
  end

  def test_variance_keep_axis
    assert_equal [2, 3, 1], @a.variance(axis: 2, keep_axis: true).shape
  end

  # ---- fused-minmax path (min / max) ----------------------------

  def test_min_keep_axis
    assert_equal [2, 3, 1], @a.min(axis: 2, keep_axis: true).shape
    assert_equal @a.min(axis: 2).reshape(2, 3, 1).to_a,
                 @a.min(axis: 2, keep_axis: true).to_a
  end

  def test_max_keep_axis_full
    kept = @a.max(keep_axis: true)
    assert_equal [1, 1, 1], kept.shape
    assert_equal @a.max, kept[0, 0, 0]
  end

  # ---- count family ---------------------------------------------

  def test_count_keep_axis
    c = CArray.int32(2, 3, 4) { |i| i % 5 }
    assert_equal [2, 1, 4], c.count(2, axis: 1, keep_axis: true).shape
    assert_equal c.count(2, axis: 1).reshape(2, 1, 4).to_a,
                 c.count(2, axis: 1, keep_axis: true).to_a
  end

  # ---- mask propagation (min_count) -----------------------------

  def test_masked_partial_keep_axis
    a = CArray.float64(2, 3) { |i| i.to_f }
    a[0, nil] = UNDEF                       # whole row 0 masked
    pk = a.sum(axis: 1, min_count: 3, keep_axis: true)
    assert_equal [2, 1], pk.shape
    assert_equal [[true], [false]], pk.mask.to_a   # row 0 masked, row 1 valid
  end

  def test_masked_full_keep_axis
    a = CArray.float64(2, 3) { |i| i.to_f }
    a[0, nil] = UNDEF
    a[1, nil] = UNDEF                        # everything masked
    fk = a.sum(min_count: 10, keep_axis: true)
    assert_equal [1, 1], fk.shape
    assert_not_nil fk.mask
    assert_equal true, fk.mask[0, 0]
  end

  # ---- default unchanged (keep_axis: false / omitted) -----------

  def test_default_drops_axis
    assert_equal [2, 4], @a.sum(axis: 1).shape
    assert_equal [2, 4], @a.sum(axis: 1, keep_axis: false).shape
  end

  def test_default_full_is_scalar
    assert_kind_of Numeric, @a.sum
    assert_kind_of Numeric, @a.sum(keep_axis: false)
  end

  # ---- Ruby-layer reductions (median / percentile / quantile) ---
  #
  # These are implemented in lib/carray/math.rb, not the C reduce DSL,
  # so they carry their own keep_axis handling (insert_axis on the axis
  # path, [1,...,1] wrap on the full path).

  def test_median_axis_keep
    assert_equal [2, 1, 4], @a.median(axis: 1, keep_axis: true).shape
    assert_equal @a.median(axis: 1).reshape(2, 1, 4).to_a,
                 @a.median(axis: 1, keep_axis: true).to_a
  end

  def test_median_full_keep
    kept = @a.median(keep_axis: true)
    assert_instance_of CArray, kept
    assert_equal [1, 1, 1], kept.shape
    assert_equal @a.median, kept[0, 0, 0]
  end

  def test_median_broadcast_subtract
    expect = @a - @a.median(axis: 1)[nil, :_, nil]
    got    = @a - @a.median(axis: 1, keep_axis: true)
    assert_equal expect.to_a, got.to_a
  end

  def test_median_default_drops_axis
    assert_equal [2, 4], @a.median(axis: 1).shape
    assert_kind_of Numeric, @a.median
  end

  def test_median_masked_full_keep
    a = CArray.float64(2, 3).seq!
    a[] = UNDEF
    kept = a.median(min_count: 100, keep_axis: true)
    assert_equal [1, 1], kept.shape
    assert_equal true, kept.mask[0, 0]
  end

  def test_percentile_axis_keep
    kept = @a.percentile(25, 50, 75, axis: 2, keep_axis: true)
    assert_equal [[2, 3, 1], [2, 3, 1], [2, 3, 1]], kept.map(&:shape)
    dropped = @a.percentile(25, 50, 75, axis: 2)
    assert_equal dropped.map { |r| r.reshape(2, 3, 1).to_a }, kept.map(&:to_a)
  end

  def test_percentile_full_keep
    kept = @a.percentile(50, keep_axis: true)
    # single-p unwraps -> CArray shape [1,1,1], not Array<CArray>
    assert_kind_of CArray, kept
    assert_equal [1, 1, 1], kept.shape
    assert_equal @a.percentile(50), kept[0, 0, 0]
  end

  def test_quantile_keep
    # quantile is multi-p (5 fixed) -> Array<CArray> len 5, each shape [1,1,1]
    kept = @a.quantile(keep_axis: true)
    assert_equal [[1, 1, 1]] * 5, kept.map(&:shape)
  end

  # ---- predicate sugar (all_*? / any_*? / none_*?) --------------
  #
  # Thin wrappers over .all / .any (C reduce kernels); keep_axis passes
  # through.  none_*? negates element-wise, so a full keep_axis reduction
  # yields a [1,...,1] bool array (not a scalar) -- the .not branch.

  def test_predicate_all_any_axis_keep
    b = CArray.int32(2, 3, 4) { |i| i % 4 }
    assert_equal [2, 1, 4], b.eq(0).all(axis: 1, keep_axis: true).shape
    assert_equal [2, 1, 4], b.eq(0).any(axis: 1, keep_axis: true).shape
    assert_equal [2, 3, 1], b.is_close(0, 0.5).all(axis: 2, keep_axis: true).shape
    assert_equal b.eq(0).all(axis: 1).reshape(2, 1, 4).to_a,
                 b.eq(0).all(axis: 1, keep_axis: true).to_a
  end

  def test_predicate_none_axis_keep
    b = CArray.int32(2, 3, 4) { |i| i % 4 }
    kept = b.eq(0).none(axis: 1, keep_axis: true)
    assert_equal [2, 1, 4], kept.shape
    assert_equal b.eq(0).none(axis: 1).reshape(2, 1, 4).to_a, kept.to_a
  end

  def test_predicate_none_full_keep_is_bool_array
    b = CArray.int32(2, 3, 4) { |i| i % 4 }
    kept = b.eq(99).none(keep_axis: true)   # nothing equals 99 -> all true
    assert_instance_of CArray, kept
    assert_equal [1, 1, 1], kept.shape
    assert_equal b.eq(99).none, (kept[0, 0, 0] != 0)
  end

  def test_predicate_default_unchanged
    b = CArray.int32(2, 3, 4) { |i| i % 4 }
    assert_equal [3, 4], b.eq(0).all(axis: 0).shape
    assert_kind_of FalseClass, b.eq(99).all
    assert_kind_of TrueClass, b.eq(99).none
  end
end
