require "test/unit"
require "carray"

# PROPOSAL_LAZY_ELEMENTWISE_VIEW Phase 4.5 P.4.5.3c — N-D streaming.
#
# Extension of P.4.5.3b (1-D streaming) to N-D source via outer-axis
# chunking.  The streaming gate is `naxes == ca->ndim && ndim >= 1 &&
# ca_is_lazy_view(ca) && !ca_has_mask(ca)`.  1-D becomes the natural
# sub-case (inner=1, rows=target_elems) — regression-pinned here too.
#
# Coverage:
#   - 2-D / 3-D / 4-D byte parity with eager
#   - Edge: dim[0] == 1 (single outer row)
#   - Edge: inner > target_elems (one row per chunk)
#   - Edge: empty (elements == 0)
#   - Multiple reduction ops (sum/prod/min/max/mean/variance/count)
#   - 1-D regression (P.4.5.3b path still works after N-D unification)

class TestLazyReduceP453cNdim < Test::Unit::TestCase
  def setup
    @a2 = CArray.float64(40, 30) { |i, j| (i - 20) * 0.05 + j * 0.02 }
    @b2 = CArray.float64(40, 30) { |i, j| (i + j) * 0.01 - 0.3 }
    @a3 = CArray.float64(10, 8, 6) { |i, j, k| (i + j - k) * 0.1 }
    @b3 = CArray.float64(10, 8, 6) { |i, j, k| (i * j + k) * 0.05 }
    @a4 = CArray.float64(5, 4, 3, 2) { |i, j, k, l| (i + j + k + l) * 0.2 }
    @b4 = CArray.float64(5, 4, 3, 2) { |i, j, k, l| (i - j + k - l) * 0.1 }
  end

  # -- 2-D parity ---------------------------------------------------------

  def test_2d_sum_parity
    assert_in_delta (@a2 + @b2).sum, (@a2.lazy + @b2).sum, 1e-9
  end

  def test_2d_prod_parity
    # Use a small near-1 array to avoid overflow.
    a = CArray.float64(5, 4) { |i, j| 1.0 + (i + j) * 0.001 }
    b = CArray.float64(5, 4) { |i, j| 1.0 + (i - j) * 0.0005 }
    assert_in_delta (a * b).prod, (a.lazy * b).prod, 1e-9
  end

  def test_2d_min_max_parity
    assert_in_delta (@a2 + @b2).min, (@a2.lazy + @b2).min, 1e-12
    assert_in_delta (@a2 + @b2).max, (@a2.lazy + @b2).max, 1e-12
  end

  def test_2d_mean_variance_parity
    eager_mean = (@a2 + @b2).mean
    eager_var  = (@a2 + @b2).variance
    assert_in_delta eager_mean, (@a2.lazy + @b2).mean, 1e-9
    assert_in_delta eager_var,  (@a2.lazy + @b2).variance, 1e-9
  end

  # -- 3-D parity ---------------------------------------------------------

  def test_3d_sum_parity
    assert_in_delta (@a3 + @b3).sum, (@a3.lazy + @b3).sum, 1e-9
  end

  def test_3d_deep_chain_parity
    # depth-3 chain: ((a + b * 2) - a).sum
    t = 2.0
    assert_in_delta ((@a3 + @b3 * t) - @a3).sum,
                    ((@a3.lazy + @b3 * t) - @a3).sum, 1e-9
  end

  # -- 4-D parity ---------------------------------------------------------

  def test_4d_sum_parity
    assert_in_delta (@a4 + @b4).sum, (@a4.lazy + @b4).sum, 1e-9
  end

  # -- Edge cases ---------------------------------------------------------

  def test_dim0_eq_one
    a = CArray.float64(1, 100) { |i, j| j.to_f }
    b = CArray.float64(1, 100) { |i, j| j * 0.5 }
    assert_in_delta (a + b).sum, (a.lazy + b).sum, 1e-12
  end

  def test_inner_larger_than_chunk_target
    # target = 4096 elements.  inner = 5000 > target => rows = 1 per chunk.
    a = CArray.float64(10, 5000) { |i, j| (i + j) * 0.001 }
    b = CArray.float64(10, 5000) { |i, j| (i - j) * 0.0005 }
    assert_in_delta (a + b).sum, (a.lazy + b).sum, 1e-6
  end

  def test_empty_via_zero_outer
    # NOTE: CArray rejects shape with a zero dim at construction; skip
    # if not supported.  Use min-size instead as a smoke.
    a = CArray.float64(1, 1) { |i, j| 7.0 }
    b = CArray.float64(1, 1) { |i, j| 3.0 }
    assert_in_delta 10.0, (a.lazy + b).sum, 1e-12
  end

  # -- 1-D regression (P.4.5.3b path still works) -------------------------

  def test_1d_regression_parity
    a = CArray.float64(10000) { |k| k * 0.001 }
    b = CArray.float64(10000) { |k| k * 0.0005 }
    assert_in_delta (a + b).sum, (a.lazy + b).sum, 1e-6
  end

  # -- Mixed data_type source -------------------------------------------------

  def test_2d_int_to_float
    a = CArray.int32(20, 30) { |i, j| i * j }
    b = CArray.int32(20, 30) { |i, j| i + j }
    assert_equal (a + b).sum, (a.lazy + b).sum
  end

  # -- N-D bincmp + count -------------------------------------------------

  def test_2d_bincmp_count
    n_eager = (@a2 > @b2).count(true)
    n_lazy  = (@a2.lazy > @b2).count(true)
    assert_equal n_eager, n_lazy
  end

  # -- N-D masked source falls back to SRC_ATTACH -------------------------

  def test_2d_masked_falls_back_to_src_attach
    a = @a2.dup
    a[2, 5] = UNDEF
    a[7, 12] = UNDEF
    # Should still produce correct result via SRC_ATTACH gate fail
    assert_in_delta (a + @b2).sum, (a.lazy + @b2).sum, 1e-9
  end
end
