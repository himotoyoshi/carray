# Boolean-as-numeric operations (3.0).
#
# Boolean participates in arithmetic, reduction, scan, sort, and argmin
# as its 0/1 numeric storage, always returning a numeric result (never
# bool).  The only boolean-returning reductions are the logical family
# (all / any / none), and the bitwise ops (& | ^) keep boolean.
#
#   - arithmetic binop / monop  -> promote to int64 (signed: b1 - b2 = -1)
#   - value-reductions (sum/prod/min/max/minmax/cum*) -> u64
#   - ratio-reductions (mean/variance/stddev)         -> f64
#   - position (sort_index/sort_addr/min_index/rank)  -> ca_size / i64

require "test/unit"
require "carray"

class TestBooleanNumericOps < Test::Unit::TestCase
  def setup
    @b  = CA_BOOLEAN([1, 0, 1, 1, 0])
    @b2 = CA_BOOLEAN([1, 1, 0, 1, 0])
  end

  # ---- Tier 2: arithmetic binop / monop --------------------------------

  def test_binop_bool_bool_promotes_to_int64
    r = @b + @b2
    assert_equal CA_INT64, r.data_type
    assert_equal [2, 1, 1, 2, 0], r.to_a
  end

  def test_binop_subtraction_is_signed
    assert_equal [0, -1, 1, 0, 0], (@b - @b2).to_a
  end

  def test_monop_negate_promotes_to_int64
    r = -@b
    assert_equal CA_INT64, r.data_type
    assert_equal [-1, 0, -1, -1, 0], r.to_a
  end

  def test_bitwise_ops_stay_boolean
    [@b & @b2, @b | @b2, @b ^ @b2].each do |r|
      assert_equal CA_BOOLEAN, r.data_type
    end
  end

  def test_bool_times_integer_still_int64
    # bool op numeric was already supported; ensure unchanged.
    assert_equal CA_INT64, (@b * 2).data_type
    assert_equal [2, 0, 2, 2, 0], (@b * 2).to_a
  end

  # ---- Tier 3: reductions (numeric return) -----------------------------

  def test_value_reductions_return_integer
    assert_equal 3, @b.sum
    assert_equal 0, @b.prod
    assert_equal 0, @b.min
    assert_equal 1, @b.max
    assert_equal [0, 1], @b.minmax
    [@b.sum, @b.prod, @b.min, @b.max].each { |v| assert_kind_of Integer, v }
  end

  def test_ratio_reductions_return_float
    assert_in_delta 0.6, @b.mean, 1e-12
    assert_in_delta 0.3, @b.variance, 1e-12      # sample, n-1
    assert_in_delta 0.24, @b.variancep, 1e-12    # population, n
    assert_in_delta Math.sqrt(0.3),  @b.stddev,  1e-12
    assert_in_delta Math.sqrt(0.24), @b.stddevp, 1e-12
  end

  def test_all_any_stay_boolean
    assert_equal false, @b.all
    assert_equal true,  @b.any
  end

  def test_reductions_skip_masked_cells
    bm = CA_BOOLEAN([1, 0, 1, 1, 0])
    bm[1] = UNDEF
    bm[3] = UNDEF
    assert_equal 2, bm.sum          # 1 + 1 (index 0, 2)
    assert_equal 1, bm.max
    assert_equal 0, bm.min
  end

  def test_empty_and_all_masked_follow_identity_contract
    e = CA_BOOLEAN([])
    assert_equal 0, e.sum           # additive identity
    assert_equal 1, e.prod          # multiplicative identity
    assert_equal UNDEF, e.max       # no identity -> UNDEF
    am = CA_BOOLEAN([1, 0]); am[] = UNDEF
    assert_equal 0, am.sum
    assert_equal UNDEF, am.max
    assert_equal UNDEF, am.mean
  end

  # ---- Tier 1: sort / scan / argmin ------------------------------------

  def test_sort_orders_false_before_true
    assert_equal [false, false, true, true, true], @b.sort.to_a
  end

  def test_sort_index_and_addr_agree_flat
    # flat sort_index and sort_addr coincide for a 1-D array (stable).
    assert_equal [1, 4, 0, 2, 3], @b.sort_index.to_a
    assert_equal [1, 4, 0, 2, 3], @b.sort_addr.to_a
  end

  def test_min_max_index
    assert_equal 1, @b.min_index    # first false
    assert_equal 0, @b.max_index    # first true
  end

  def test_scan_returns_running_counts_u64
    assert_equal [1, 1, 2, 3, 3], @b.cumsum.to_a
    assert_equal CA_UINT64, @b.cumsum.data_type
    assert_equal [1, 0, 0, 0, 0], @b.cumprod.to_a
    assert_equal [1, 1, 1, 1, 1], @b.cummax.to_a
    assert_equal [1, 0, 0, 0, 0], @b.cummin.to_a
  end

  def test_partition_index_runs
    assert_nothing_raised { @b.partition_index(2) }
  end

  # ---- per-axis --------------------------------------------------------

  def test_per_axis_reductions
    m = CA_BOOLEAN([[1, 0, 1], [1, 1, 0]])
    assert_equal [2, 1, 1], m.sum(axis: 0).to_a
    assert_equal [1, 1],    m.max(axis: 1).to_a
    assert_equal [[1, 1, 2], [1, 2, 2]], m.cumsum(axis: 1).to_a
    assert_equal [[false, true, true], [false, true, true]], m.sort(axis: 1).to_a
    assert_equal [0, 1, 0], m.max_index(axis: 0).to_a
  end

  def test_per_axis_masked
    mm = CA_BOOLEAN([[1, 0, 1], [1, 1, 0]])
    mm[0, 1] = UNDEF
    assert_equal [2, 2], mm.sum(axis: 1).to_a   # row0: 1+_+1, row1: 1+1+0
  end
end
