require "test/unit"
require_relative "../../lib/carray"

# PROPOSAL_WINDOW_ITERATOR_3_0: the Ruby CAWindowIterator built on
# pad + sliding_windows + core window-axis reduction (replaces the 2.0 C
# engine, ext/ca_iter_window.c).  Covers the boundary policies (:skip /
# :nearest / :truncate), the named reduction spectrum (min_count / fill_value),
# correlate / convolve, order statistics, count family, each / reduce, and a
# differential test against a naive per-anchor reference implementation.

class TestWindowIterator30Basics < Test::Unit::TestCase

  def setup
    @a = CArray.float64(8).seq(1)   # [1..8]
  end

  # ---- rolling reductions, boundary policies ----------------------------

  def test_rolling_mean_skip
    # :skip (default): UNDEF margin, edges fold only in-bounds cells.
    assert_equal [1.5, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 7.5],
                 @a.windows(-1..1).mean.to_a
  end

  def test_rolling_sum_skip
    assert_equal [3.0, 6.0, 9.0, 12.0, 15.0, 18.0, 21.0, 15.0],
                 @a.windows(-1..1).sum.to_a
  end

  def test_forward_window
    assert_equal [2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 7.5, 8.0],
                 @a.windows(0..2).mean.to_a
  end

  def test_rolling_min_max_skip
    assert_equal [1.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0], @a.windows(-1..1).min.to_a
    assert_equal [2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 8.0], @a.windows(-1..1).max.to_a
  end

  def test_rolling_mean_nearest
    # :nearest: edge-replicated margin, so both edges have a real neighbour.
    assert_in_delta 4.0 / 3.0, @a.windows(-1..1, bounds: :nearest).mean.to_a[0], 1e-12
    assert_equal 8, @a.windows(-1..1, bounds: :nearest).mean.elements
  end

  def test_truncate_shrinks_output
    # :truncate: only fully in-bounds anchors; output shrinks by w-1.
    out = @a.windows(-1..1, bounds: :truncate).mean
    assert_equal [6], out.shape
    assert_equal [2.0, 3.0, 4.0, 5.0, 6.0, 7.0], out.to_a
  end

  def test_min_count_and_fill_value_pass_through
    assert_equal [UNDEF, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, UNDEF],
                 @a.windows(-1..1).mean(min_count: 3).to_a
    assert_equal [0.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 0.0],
                 @a.windows(-1..1).mean(min_count: 3, fill_value: 0.0).to_a
  end

  # ---- count family + elements -----------------------------------------

  def test_count_not_masked_drops_at_edges
    assert_equal [2, 3, 3, 3, 3, 3, 3, 2], @a.windows(-1..1).count_not_masked.to_a
  end

  def test_elements_is_constant_window_size
    assert_equal [3, 3, 3, 3, 3, 3, 3, 3], @a.windows(-1..1).elements.to_a
  end

  def test_count_value
    assert_equal [1, 1, 0, 0, 0, 0, 0, 0], @a.windows(-1..1).count(1.0).to_a
  end

  def test_count_masked
    assert_equal [1, 0, 0, 0, 0, 0, 0, 1], @a.windows(-1..1).count_masked.to_a
  end
end


class TestWindowIterator30Correlate < Test::Unit::TestCase

  def test_correlate_1d_zero_pad
    a   = CArray.float64(8).seq(1)
    ker = CA_FLOAT64([0.25, 0.5, 0.25])
    assert_equal [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 5.75],
                 a.windows(-1..1, fill_value: 0.0).correlate(ker).to_a
  end

  def test_convolve_symmetric_equals_correlate
    a   = CArray.float64(8).seq(1)
    ker = CA_FLOAT64([0.25, 0.5, 0.25])
    sw  = a.windows(-1..1, bounds: :nearest)
    assert_equal sw.correlate(ker).to_a, sw.convolve(ker).to_a
  end

  # Regression: an integer source with a fractional kernel must promote the
  # product to float (via the single-source binop coercion), not truncate the
  # kernel to the source's dtype (which zeroed the whole output).
  def test_correlate_int_source_float_kernel_promotes
    a   = CA_INT32([0, 0, 10, 0, 0])
    ker = CA_FLOAT64([0.25, 0.5, 0.25])
    out = a.windows(-1..1, fill_value: 0.0).correlate(ker)
    assert_equal [0.0, 2.5, 5.0, 2.5, 0.0], out.to_a
    assert_equal CA_FLOAT64, out.data_type
    assert_equal [0.0, 2.5, 5.0, 2.5, 0.0],
                 a.windows(-1..1, fill_value: 0.0).convolve(ker).to_a
  end

  def test_convolve_flips_asymmetric_kernel_1d
    a   = CArray.float64(6).seq(1)
    ker = CA_FLOAT64([1.0, 0.0, 0.0])              # picks the left tap
    sw  = a.windows(-1..1, bounds: :nearest)
    # correlate: out[i] = a[i-1] (left neighbour); convolve flips -> a[i+1].
    assert_equal [1.0, 1.0, 2.0, 3.0, 4.0, 5.0], sw.correlate(ker).to_a
    assert_equal [2.0, 3.0, 4.0, 5.0, 6.0, 6.0], sw.convolve(ker).to_a
  end

  def test_correlate_2d
    b   = CArray.float64(4, 5).seq
    box = CArray.float64(3, 3) { 1.0 / 9 }
    out = b.windows(-1..1, -1..1, fill_value: 0.0).correlate(box)
    assert_equal [4, 5], out.shape
    # interior cell = mean of its 3x3 neighbourhood; on a linear ramp that
    # equals the centre value.
    assert_in_delta b[1, 2], out[1, 2], 1e-12
  end

  def test_convolve_2d_flips
    b  = CArray.float64(4, 5).seq
    ka = CArray.float64(3, 3)
    ka[0, 0] = 1.0                                 # top-left tap only
    sw = b.windows(-1..1, -1..1, bounds: :nearest)
    # correlate picks a[i-1, j-1]; convolve flips to a[i+1, j+1].
    assert_equal b[0, 0],           sw.correlate(ka)[1, 1]
    assert_equal b[2, 2],           sw.convolve(ka)[1, 1]
  end
end


class TestWindowIterator30OrderStats < Test::Unit::TestCase

  def test_median_single_axis_nearest
    a = CArray.float64(8).seq(1)
    assert_equal [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0],
                 a.windows(-1..1, bounds: :nearest).median.to_a
  end

  def test_median_single_axis_truncate
    a = CArray.float64(8).seq(1)
    assert_equal [2.0, 3.0, 4.0, 5.0, 6.0, 7.0],
                 a.windows(-1..1, bounds: :truncate).median.to_a
  end

  def test_median_multi_axis_materialize
    b   = CArray.float64(4, 5).seq
    out = b.windows(-1..1, -1..1, bounds: :nearest).median
    assert_equal [4, 5], out.shape
    # interior 3x3 window median == its centre value for a linear ramp
    assert_in_delta b[1, 2], out[1, 2], 1e-12
  end

  def test_skip_order_stat_rejects
    a = CArray.float64(8).seq(1)
    assert_raise(ArgumentError) { a.windows(-1..1).median }
    assert_raise(ArgumentError) { a.windows(-1..1).percentile(50) }
  end

  def test_percentile_and_quantile
    a  = CArray.float64(8).seq(1)
    sw = a.windows(-1..1, bounds: :nearest)
    assert_equal a.to_a, sw.percentile(50).to_a
    q  = sw.quantile
    assert_equal 5, q.size
  end
end


class TestWindowIterator30Weighted < Test::Unit::TestCase

  def test_wsum_wmean
    a = CArray.float64(6).seq(1)
    w = CA_FLOAT64([1.0, 2.0, 1.0])
    sw = a.windows(-1..1, bounds: :nearest)
    # wsum[i] = a[i-1] + 2*a[i] + a[i+1]
    assert_equal [5.0, 8.0, 12.0, 16.0, 20.0, 23.0], sw.wsum(w).to_a
    assert_equal [1.25, 2.0, 3.0, 4.0, 5.0, 5.75],   sw.wmean(w).to_a
  end
end


class TestWindowIterator30EachReduce < Test::Unit::TestCase

  def test_each_yields_windows
    a = CArray.float64(4).seq(1)
    got = a.windows(-1..1, bounds: :nearest).each.to_a.map(&:to_a)
    assert_equal [[1.0, 1.0, 2.0], [1.0, 2.0, 3.0], [2.0, 3.0, 4.0], [3.0, 4.0, 4.0]], got
  end

  def test_reduce_block_form
    a = CArray.float64(5).seq(1)
    out = a.windows(-1..1, bounds: :nearest).reduce { |w| w.max - w.min }
    assert_equal [1.0, 2.0, 2.0, 2.0, 1.0], out.to_a
  end

  def test_reduce_init_form
    a = CArray.float64(5).seq(1)
    out = a.windows(-1..1, bounds: :nearest).reduce(0.0) { |acc, x| acc + x }
    assert_equal a.windows(-1..1, bounds: :nearest).sum.to_a, out.to_a
  end

  def test_map_raises_not_implemented
    a = CArray.float64(4).seq(1)
    # map is defined only to raise (overlapping windows -> no scatter-back).
    assert_raise(NotImplementedError) { a.windows(-1..1).map { |w| w } }
  end
end


class TestWindowIterator30BackwardCompat < Test::Unit::TestCase

  # The 2.0 construction CAWindowIterator.new(window_view) reads the geometry
  # (ranges / bounds / fill_value) back from the CAWindow view.
  def test_from_window_view_each
    a      = CArray.int32(5).seq
    kernel = a.window(0..2, bounds: "fill", fill_value: 99)
    got    = CAWindowIterator.new(kernel).each.to_a.map(&:to_a)
    assert_equal [[0, 1, 2], [1, 2, 3], [2, 3, 4], [3, 4, 99], [4, 99, 99]], got
  end

  def test_from_window_view_reduction
    a      = CArray.float64(6).seq(1)
    kernel = a.window(-1..1)                       # legacy FILL, fill_value 0
    assert_equal a.windows(-1..1, fill_value: 0.0).sum.to_a,
                 CAWindowIterator.new(kernel).sum.to_a
  end
end


# Differential test (proposal §10): each named reduction must agree with a
# naive per-anchor reference implementation that materializes each window and
# folds it with the same-named CArray reduction.
class TestWindowIterator30Differential < Test::Unit::TestCase

  # Naive oracle: for every anchor, extract the window (edge-replicated so all
  # cells are present) and apply the CArray reduction, assembling a reference-
  # shaped output.  This is the 2.0 per-anchor semantics.
  def naive_reduce_1d (src, lo, hi, op)
    n   = src.elements
    out = CArray.float64(n)
    n.times do |i|
      vals = (lo..hi).map { |off| src[[[i + off, 0].max, n - 1].min] }
      out[i] = CA_FLOAT64(vals).send(op)
    end
    out
  end

  def test_differential_named_reductions
    srand(1234)
    # arity-1 block: a bare `{ rand }` is evaluated once and broadcast.
    src = CArray.float64(30) { |i| rand }
    lo, hi = -2, 2
    sw = src.windows(lo..hi, bounds: :nearest)
    [:sum, :mean, :min, :max, :variance, :stddev, :prod, :median].each do |op|
      expected = naive_reduce_1d(src, lo, hi, op)
      actual   = (op == :median) ? sw.median : sw.send(op)
      actual.elements.times do |i|
        assert_in_delta expected[i], actual[i], 1e-10,
                        "op=#{op} at i=#{i}"
      end
    end
  end

  def test_differential_correlate
    srand(99)
    src = CArray.float64(20) { |i| rand }
    ker = CA_FLOAT64([0.2, 0.5, 0.3])
    actual = src.windows(-1..1, bounds: :nearest).correlate(ker)
    n = src.elements
    n.times do |i|
      exp = 0.0
      [-1, 0, 1].each_with_index do |off, j|
        idx = [[i + off, 0].max, n - 1].min
        exp += src[idx] * ker[j]
      end
      assert_in_delta exp, actual[i], 1e-12, "correlate at i=#{i}"
    end
  end
end

# A window need not cover the cell it is centred on: `windows(1..2)` is "the
# two cells after this one".  The anchor's window then starts further along the
# padded buffer than its left margin accounts for, and under :truncate the
# anchors that survive are a different set.  Both were once read as if the
# window began at the margin, which shifted every answer by the range's begin
# and, under :truncate, produced one anchor too many.
class TestWindowIterator30OneSidedWindows < Test::Unit::TestCase

  def setup
    @a = CArray.float64(8).seq(1)              # [1..8]
  end

  # Folds each window by hand, one anchor at a time.
  def by_hand (source, range, bounds, op)
    length = source.elements
    first  = [0, -range.begin].max
    last   = [length - 1, length - 1 - range.end].min
    anchors = bounds == :truncate ? (first..last).to_a : (0...length).to_a
    anchors.map do |anchor|
      cells = range.map { |offset|
        cell = anchor + offset
        if cell.between?(0, length - 1)   then source[cell]
        elsif bounds == :nearest          then source[[[cell, 0].max, length - 1].min]
        end
      }.compact
      case op
      when :sum  then cells.sum                          # nothing folded: zero
      when :prod then cells.inject(1.0) { |a, b| a * b } # nothing folded: one
      else            cells.empty? ? nil : (op == :mean ? cells.sum / cells.size
                                                        : cells.send(op))
      end
    end
  end

  def assert_folds_by_hand (range, bounds, op)
    want = by_hand(@a, range, bounds, op)
    got  = @a.windows(range, bounds: bounds).send(op).to_a
             .map { |value| value.equal?(UNDEF) ? nil : value }
    assert_equal want.size, got.size, "#{range} #{bounds} #{op}: anchor count"
    want.zip(got).each_with_index do |(wanted, actual), i|
      if wanted.nil?
        assert_nil actual, "#{range} #{bounds} #{op} at #{i}"
      else
        assert_in_delta wanted, actual, 1e-12, "#{range} #{bounds} #{op} at #{i}"
      end
    end
  end

  def test_folds_match_a_hand_written_reference
    [1..2, 2..3, -2..-1, -3..-2, -1..1, 0..2, -2..0, 0..0].each do |range|
      [:skip, :nearest, :truncate].each do |bounds|
        [:sum, :prod, :min, :max, :mean].each do |op|
          assert_folds_by_hand(range, bounds, op)
        end
      end
    end
  end

  def test_the_two_cells_after_this_one
    # anchor 0 folds cells 1 and 2, and the last anchor has nothing after it.
    assert_equal [5.0, 7.0, 9.0, 11.0, 13.0, 15.0, 8.0, 0.0],
                 @a.windows(1..2).sum.to_a
    assert_equal [2.5, 3.5, 4.5, 5.5, 6.5, 7.5, 8.0, UNDEF],
                 @a.windows(1..2).mean.to_a
  end

  def test_the_two_cells_before_this_one
    assert_equal [0.0, 1.0, 3.0, 5.0, 7.0, 9.0, 11.0, 13.0],
                 @a.windows(-2..-1).sum.to_a
  end

  # :truncate keeps the anchors whose window lies wholly inside the source.
  def test_truncate_keeps_only_the_anchors_that_fit
    assert_equal [5.0, 7.0, 9.0, 11.0, 13.0, 15.0],
                 @a.windows(1..2, bounds: :truncate).sum.to_a
    assert_equal [3.0, 5.0, 7.0, 9.0, 11.0, 13.0],
                 @a.windows(-2..-1, bounds: :truncate).sum.to_a
    assert_equal [6.0, 9.0, 12.0, 15.0, 18.0, 21.0],
                 @a.windows(-1..1, bounds: :truncate).sum.to_a
  end

  def test_the_winner_address_points_at_the_right_cell
    # The window at anchor 0 is cells 1 and 2; the smaller is cell 1.
    assert_equal 1, @a.windows(1..2).min_addr[0]
    assert_equal 2, @a.windows(1..2).max_addr[0]
    # Nothing after the last cell, so no address either.
    assert_equal UNDEF, @a.windows(1..2).min_addr[7]
  end

end
