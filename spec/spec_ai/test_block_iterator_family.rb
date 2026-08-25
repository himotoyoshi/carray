require "test/unit"
require_relative "../../lib/carray"

# CABlockIterator 3.0 (lib/carray/block_iterator.rb) family surface.  The engine
# is block_view decomposition (interior + 2^m-1 boundary regions); every named
# reduction is checked against a brute-force present-only oracle, so a partial
# edge tile folds only its real cells (ceil tile grid).  See
# devel/PROPOSAL_BLOCK_ITERATOR_3_0.md.
class TestCABlockIteratorFamily < Test::Unit::TestCase

  # Brute-force per-tile fold over the ceil grid, present-only (edge tiles use
  # whatever cells fall inside the source).
  def tiles_of (a, bs, offs = Array.new(a.ndim, 0))
    nd = a.ndim
    grid = nd.times.map { |i| n = a.shape[i] - offs[i]; n / bs[i] + (n % bs[i] > 0 ? 1 : 0) }
    out = []
    CArray.each_index(*grid) do |*g|
      rngs = nd.times.map { |i| (offs[i] + g[i] * bs[i])...[offs[i] + (g[i] + 1) * bs[i], a.shape[i]].min }
      cells = []
      a[*rngs].each { |v| cells << v }
      out << [g, cells]
    end
    [grid, out]
  end

  def assert_grid (grid, expected_by_g, actual_ca, msg, tol: 0)
    CArray.each_index(*grid) do |*g|
      exp = expected_by_g[g]
      got = actual_ca[*g]
      if tol > 0
        assert_in_delta(exp, got, tol, "#{msg} @#{g.inspect}")
      else
        assert_equal(exp, got, "#{msg} @#{g.inspect}")
      end
    end
  end

  def test_tier1_present_only_vs_brute
    [[CArray.float64(7).seq, [3]],
     [CArray.float64(7, 5).seq, [3, 2]],
     [CArray.float64(5, 4, 7).seq, [2, 2, 3]]].each do |a, bs|
      grid, tiles = tiles_of(a, bs)
      bi = a.blocks(*bs)
      { sum:  ->(c) { c.sum },
        mean: ->(c) { c.sum.to_f / c.size },
        min:  ->(c) { c.min },
        max:  ->(c) { c.max } }.each do |op, f|
        exp = {}; tiles.each { |g, c| exp[g] = f.call(c) }
        assert_grid(grid, exp, bi.send(op), "#{op} #{a.shape.inspect}/#{bs.inspect}", tol: 1e-9)
      end
    end
  end

  def test_ceil_grid_shape_and_offset
    assert_equal [3], CArray.float64(7).seq.blocks(3).mean.shape       # ceil(7/3)
    assert_equal [1], CArray.float64(2).seq.blocks(5).mean.shape       # b > N
    assert_equal [3, 3], CArray.float64(7, 5).seq.blocks(3, 2).mean.shape
    # range form: offset absorbed by pre-slice, remainder covered
    assert_equal [9, 18, 17], CArray.int32(10).seq.blocks(2..4).sum.to_a
  end

  def test_min_count_marks_partial_tile_undef
    m = CArray.float64(7).seq(1).blocks(3).mean(min_count: 3)   # last tile has 1 cell
    assert_equal [2.0, 5.0], m[0..1].to_a
    assert(m.is_masked && m.mask[2], "partial tile must be UNDEF under min_count")
  end

  def test_count_family_invariant
    bi = CArray.float64(7).seq.blocks(3)
    el = bi.elements.to_a; cn = bi.count_not_masked.to_a; cm = bi.count_masked.to_a
    assert_equal [3, 3, 3], el                # structural, uniform
    assert_equal [3, 3, 1], cn                # present per tile
    assert_equal [0, 0, 2], cm                # OOB of the partial tile
    el.each_index { |i| assert_equal el[i], cn[i] + cm[i] }
  end

  def test_minmax_and_position
    bi = CArray.float64(7).seq.blocks(3)      # [0,1,2],[3,4,5],[6]
    mn, mx = bi.minmax
    assert_equal [0.0, 3.0, 6.0], mn.to_a
    assert_equal [2.0, 5.0, 6.0], mx.to_a
    assert_equal [0, 0, 0], bi.min_index.to_a
    assert_equal [2, 2, 0], bi.max_index.to_a  # tile-local flat index
  end

  def test_order_stats_1d_and_multiaxis
    bi = CArray.float64(7).seq.blocks(3)
    assert_equal [1.0, 4.0, 6.0], bi.median.to_a
    assert_equal [1.0, 4.0, 6.0], bi.percentile(50).to_a
    p25, p75 = bi.percentile(25, 75)
    assert_equal [0.5, 3.5, 6.0], p25.to_a
    q = bi.quantile
    assert_equal 5, q.size
    assert_equal [1.0, 4.0, 6.0], q[2].to_a
    # multi-axis tile: materialize + flatten path
    b = CArray.float64(4, 4).seq
    assert_equal [[2.5, 4.5], [10.5, 12.5]], b.blocks(2, 2).median.to_a
    # ragged corner (single cell) median
    assert_equal 24.0, CArray.float64(5, 5).seq.blocks(2, 2).median[2, 2]
  end

  def test_weighted_ragged_boundary
    bi = CArray.float64(7).seq.blocks(3)      # weights sliced at the [6] tile
    w = CA_FLOAT64([1, 2, 3])
    assert_equal [0*1 + 1*2 + 2*3, 3*1 + 4*2 + 5*3, 6*1].map(&:to_f), bi.wsum(w).to_a
    assert_in_delta 6.0, bi.wmean(w)[2], 1e-9   # 6*1 / 1
  end

  def test_each_uniform_masked_tiles
    tiles = CArray.int32(7).seq.blocks(3).each.map(&:to_a)
    assert_equal [[0, 1, 2], [3, 4, 5], [6, UNDEF, UNDEF]], tiles
    assert_instance_of Enumerator, CArray.int32(6).seq.blocks(2).each
  end

  def test_map_scatters_back_source_shaped
    a = CArray.float64(7).seq
    out = a.blocks(3).map { |t| t * t }
    assert_equal [7], out.shape
    assert_equal [0, 1, 4, 9, 16, 25, 36].map(&:to_f), out.to_a
    # 2D
    b = CArray.float64(4, 4).seq
    assert_equal [4, 4], b.blocks(2, 2).map { |t| t + 100 }.shape
  end

  def test_reduce_custom_fold
    a = CArray.int32(6).seq                   # [0,1],[2,3],[4,5]
    assert_equal [1, 3, 5], a.blocks(2).reduce { |t| t.max }.to_a
  end

  def test_map_without_block_is_nomethod_removed
    # map is now defined; ensure it is present (family completeness).
    assert_respond_to CArray.int32(4).seq.blocks(2), :map
  end
end
