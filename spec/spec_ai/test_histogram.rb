# Test for histogram redesign (PROPOSAL_HISTOGRAM_REDESIGN rev2).

$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
$LOAD_PATH.unshift File.expand_path("../../ext", __dir__)
require "test/unit"
require "carray"

class TestHistogram1D < Test::Unit::TestCase

  def test_simple_1d_plain
    edges = CArray.float64(11).span(0..10)
    data = CA_FLOAT64([0.5, 1.5, 1.5, 9.9, -1.0, 10.5, 10.0])
    h = data.histogram1d(edges: edges)
    # under | bin 0..9 | over
    assert_equal [1, 1, 2, 0, 0, 0, 0, 0, 0, 0, 1, 2], h.full_counts.to_a
    assert_equal [1, 2, 0, 0, 0, 0, 0, 0, 0, 1], h.counts.to_a
    assert_equal 1, h.under
    assert_equal 2, h.over
    assert_equal 7, h.total
    assert_equal 3, h.outlier_total
  end

  def test_include_max
    edges = CArray.float64(11).span(0..10)
    data = CA_FLOAT64([0.5, 1.5, 1.5, 9.9, -1.0, 10.5, 10.0])
    h = data.histogram1d(edges: edges, include_max: true)
    # v=10.0 now lands in bin 9 (extended idx 10), v=10.5 still over
    assert_equal [1, 1, 2, 0, 0, 0, 0, 0, 0, 0, 2, 1], h.full_counts.to_a
  end

  def test_fiber_shape
    edges = CArray.float64(6).span(0..5)
    data = CArray.float64(2, 4)
    data[0, nil] = CA_FLOAT64([0.5, 1.5, 2.5, 3.5])
    data[1, nil] = CA_FLOAT64([4.5, -1.0, 5.5, 1.0])
    h = data.histogram1d(edges: edges)
    assert_equal [2, 7], h.full_counts.shape
    assert_equal [2, 5], h.counts.shape
    assert_equal [0, 1, 1, 1, 1, 0, 0], h.full_counts[0, nil].to_a
    assert_equal [1, 0, 1, 0, 0, 1, 1], h.full_counts[1, nil].to_a
    assert_equal [0, 1], h.under.to_a
    assert_equal [0, 1], h.over.to_a
    assert_equal [4, 4], h.total.to_a
  end

  def test_mask_propagation
    edges = CArray.float64(6).span(0..5)
    data = CA_FLOAT64([0.5, 1.5, 99.9, 3.5]).copy
    data[2] = UNDEF
    h = data.histogram1d(edges: edges)
    assert_equal [0, 1, 1, 0, 1, 0, 0], h.full_counts.to_a
    assert_equal 3, h.total
  end

  def test_nan_handling
    edges = CArray.float64(6).span(0..5)
    data = CA_FLOAT64([0.5, Float::NAN, 1.5, 3.5])
    h = data.histogram1d(edges: edges)
    assert_equal [0, 1, 1, 0, 1, 0, 0], h.full_counts.to_a
  end

  def test_weighted
    edges = CArray.float64(6).span(0..5)
    data = CA_FLOAT64([0.5, 1.5, 2.5])
    weights = CA_FLOAT64([2.0, 3.0, 5.0])
    h = data.histogram1d(edges: edges, weights: weights)
    assert_equal [2.0, 3.0, 5.0, 0.0, 0.0], h.counts.to_a
    assert_in_delta 10.0, h.total, 1e-9
  end

  def test_streaming_via_add
    edges = CArray.float64(6).span(0..5)
    empty = CArray.float64(0)
    h = empty.histogram1d(edges: edges)
    h.add(CA_FLOAT64([0.5, 1.5]))
    h.add(CA_FLOAT64([2.5, 3.5, 4.5]))
    assert_equal [1, 1, 1, 1, 1], h.counts.to_a
    assert_equal 5, h.total
  end

  def test_plus_composition
    edges = CArray.float64(6).span(0..5)
    h1 = CA_FLOAT64([0.5, 1.5, 2.5]).histogram1d(edges: edges)
    h2 = CA_FLOAT64([0.5, 4.5, -1.0]).histogram1d(edges: edges)
    hc = h1 + h2
    assert_equal [1, 2, 1, 1, 0, 1, 0], hc.full_counts.to_a
    assert_equal 6, hc.total
  end

  def test_plus_edges_mismatch_raises
    edges_a = CArray.float64(6).span(0..5)
    edges_b = CArray.float64(11).span(0..10)
    h1 = CA_FLOAT64([0.5]).histogram1d(edges: edges_a)
    h2 = CA_FLOAT64([0.5]).histogram1d(edges: edges_b)
    assert_raise(ArgumentError) { h1 + h2 }
  end

  def test_plus_include_max_mismatch_raises
    edges = CArray.float64(6).span(0..5)
    h1 = CA_FLOAT64([0.5]).histogram1d(edges: edges, include_max: false)
    h2 = CA_FLOAT64([0.5]).histogram1d(edges: edges, include_max: true)
    assert_raise(ArgumentError) { h1 + h2 }
  end

  def test_midpoints
    edges = CArray.float64(6).span(0..5)   # 0, 1, 2, 3, 4, 5
    h = CA_FLOAT64([0.5]).histogram1d(edges: edges)
    assert_equal [0.5, 1.5, 2.5, 3.5, 4.5], h.midpoints.to_a
    assert_equal 5, h.midpoints.elements
    assert_equal h.midpoints.elements, h.counts.elements
  end

  def test_new_is_private
    assert_raise(NoMethodError) {
      CArray::Histogram.new(edges: [CArray.float64(2).seq], fiber_shape: [])
    }
  end

  def test_histogram1d_returns_histogram_with_m1
    edges = CArray.float64(6).span(0..5)
    h = CA_FLOAT64([0.5, 1.5]).histogram1d(edges: edges)
    assert_kind_of CArray::Histogram, h
    assert_equal 1, h.m
  end

  def test_add_shape_mismatch_raises
    edges = CArray.float64(6).span(0..5)
    h = CArray.float64(3, 4).histogram1d(edges: edges)
    # different fiber shape
    assert_raise(ArgumentError) {
      h.add(CArray.float64(5, 4))
    }
  end

end


class TestHistbinKernel < Test::Unit::TestCase
  # ext/carray_histogram.c CArray#histbin_ki(edges, include_max): element-wise
  # extended bin index (0=under, 1..n bins, n+1=over), NaN/masked -> masked.
  # Not on the histogram hot path anymore (the fused kernel is), but kept as a
  # standalone binning primitive.

  def bin(v, edges, include_max = false)
    CA_FLOAT64(v).send(:histbin_ki, CA_FLOAT64(edges), include_max)
  end

  def test_uniform_under_in_over
    b = bin([-1.0, 0.5, 1.5, 4.9, 5.0, 5.5], [0, 1, 2, 3, 4, 5])
    assert_equal [0, 1, 2, 5, 6, 6], b.to_a   # 5.0 == hi -> over by default
  end

  def test_include_max
    b = bin([4.9, 5.0, 5.5], [0, 1, 2, 3, 4, 5], true)
    assert_equal [5, 5, 6], b.to_a            # 5.0 absorbed into top bin
  end

  def test_nan_is_masked
    b = bin([0.5, Float::NAN, 1.5], [0, 1, 2, 3])
    assert_equal [false, true, false], b.is_masked.to_a
    assert_equal 1, b[0]
    assert_equal 2, b[2]
  end

  def test_non_uniform_edges
    b = bin([0.5, 5.0, 50.0, 200.0, -1.0], [0, 1, 10, 100])
    assert_equal [1, 2, 3, 4, 0], b.to_a
  end

  def test_input_mask_propagates
    v = CA_FLOAT64([0.5, 1.5, 2.5]).to_ca
    v[1] = UNDEF
    b = v.send(:histbin_ki, CA_FLOAT64([0, 1, 2, 3]), false)
    assert_equal [false, true, false], b.is_masked.to_a
  end

  def test_shape_preserved_2d
    v = CArray.float64(2, 3) { |i, j| (i * 3 + j) * 0.5 }
    b = v.send(:histbin_ki, CA_FLOAT64([0, 1, 2, 3]), false)
    assert_equal [2, 3], b.shape
  end

  def test_uniform_boundary_exactness
    # Non-integer uniform edges (0.1-ish steps, not exactly representable).
    # Each edge value, fed back as input, must bin left-closed exactly: the
    # uniform fast path corrects its linearised floor against the real edges,
    # so it matches actual-edge comparison (no off-by-one at boundaries).
    e  = CArray.float64(11).span(0.0..1.0)
    ea = e.to_a
    got = CA_FLOAT64(ea).send(:histbin_ki, e, false).to_a
    truth = ea.each_index.map { |k| k == ea.size - 1 ? ea.size : k + 1 }
    assert_equal truth, got
  end
end


class TestHistogram2D < Test::Unit::TestCase

  def setup
    @edges_h = CArray.float64(11).span(0..100)   # 10 bins
    @edges_t = CArray.float64(7).span(-20..40)    # 6 bins
  end

  def test_basic_2d
    data = CArray.float64(4, 2)
    data[0, nil] = CA_FLOAT64([55.0, 15.0])    # in/in
    data[1, nil] = CA_FLOAT64([-5.0, 15.0])    # under/in
    data[2, nil] = CA_FLOAT64([55.0, 50.0])    # in/over
    data[3, nil] = CA_FLOAT64([-5.0, 50.0])    # under/over
    h = data.histogram2d(edges: [@edges_h, @edges_t])
    assert_equal [12, 8], h.full_counts.shape
    assert_equal [10, 6], h.counts.shape
    assert_equal 1, h.full_counts[6, 4]
    assert_equal 1, h.full_counts[0, 4]
    assert_equal 1, h.full_counts[6, 7]
    assert_equal 1, h.full_counts[0, 7]
  end

  def test_marginal_outliers
    data = CArray.float64(4, 2)
    data[0, nil] = CA_FLOAT64([55.0, 15.0])
    data[1, nil] = CA_FLOAT64([-5.0, 15.0])
    data[2, nil] = CA_FLOAT64([55.0, 50.0])
    data[3, nil] = CA_FLOAT64([-5.0, 50.0])
    h = data.histogram2d(edges: [@edges_h, @edges_t])
    assert_equal 2, h.under(axis: 0)    # humid under: samples 1, 3
    assert_equal 0, h.over(axis: 0)
    assert_equal 0, h.under(axis: 1)
    assert_equal 2, h.over(axis: 1)     # temp over: samples 2, 3
    assert_equal 4, h.total
    assert_equal 3, h.outlier_total     # 4 - (only sample 0 is in-range)
  end

  def test_include_max_per_dim
    # humid bounded at 100, temp unbounded
    data = CArray.float64(2, 2)
    data[0, nil] = CA_FLOAT64([100.0, 15.0])
    data[1, nil] = CA_FLOAT64([100.0, 40.0])  # both at upper edge
    h = data.histogram2d(edges: [@edges_h, @edges_t],
                        include_max: [true, false])
    # humid 100 absorbs into bin 9 (extended idx 10), temp 40 → over (extended idx 7)
    assert_equal 1, h.full_counts[10, 4]  # sample 0: humid bin 9, temp bin 3
    assert_equal 1, h.full_counts[10, 7]  # sample 1: humid bin 9, temp over
  end

  def test_2d_with_fiber
    # Each fiber has 3 samples in the in-range region
    data = CArray.float64(2, 3, 2)
    data[0, nil, nil] = CArray.float64(3, 2) { |a, c| c == 0 ? 25.0 + a * 10 : 5.0 + a * 5 }
    data[1, nil, nil] = CArray.float64(3, 2) { |a, c| c == 0 ? 75.0 - a * 10 : 25.0 - a * 5 }
    h = data.histogram2d(edges: [@edges_h, @edges_t])
    assert_equal [2, 12, 8], h.full_counts.shape
    assert_equal [2, 10, 6], h.counts.shape
    assert_equal [3, 3], h.total.to_a
  end

  def test_2d_via_general_entry
    data = CArray.float64(4, 2)
    data[0, nil] = CA_FLOAT64([55.0, 15.0])
    data[1, nil] = CA_FLOAT64([55.0, 15.0])
    h = data.histogram(edges: [@edges_h, @edges_t])
    assert_equal 2, h.full_counts[6, 4]
  end

end
