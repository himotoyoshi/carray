require "test/unit"
require "carray"

# PROPOSAL_SIGIL_NEWAXIS_AND_SLAB_ITER (SI.1-SI.4):
#   :_  = newaxis (size-1 axis insertion, numpy np.newaxis)
#   :>  = slab-axis (iterator) marker, role-reversed vs the old :_ iterator
#         (= :> marks the SLAB/kernel axis, the unmarked axes are outer).
# CADimensionIterator retired; CASlabIterator delegates to each_slab /
# map_slab / reduce_slab.

class TestNewaxisSigil < Test::Unit::TestCase

  # --- AC1-AC3: shape insertion ---

  def test_column_vector
    a = CArray.int32(5).seq
    assert_equal [5, 1], a[nil, :_].dim
  end

  def test_row_vector
    a = CArray.int32(5).seq
    assert_equal [1, 5], a[:_, nil].dim
  end

  def test_multiple_newaxis_2d
    a = CArray.int32(3, 4).seq
    assert_equal [3, 1, 4],    a[nil, :_, nil].dim
    assert_equal [1, 3, 4, 1], a[:_, nil, nil, :_].dim
    assert_equal [3, 4, 1, 1], a[nil, nil, :_, :_].dim
  end

  def test_newaxis_with_scalar_axis_dropped
    a = CArray.int32(3, 4).seq
    # axis 0 scalar -> dropped; axis 1 ALL -> kept; :_ -> size-1
    assert_equal [4, 1], a[2, nil, :_].dim
  end

  # --- view semantics: zero-copy alias, write propagates ---

  def test_newaxis_is_view_alias
    a = CArray.int32(5).seq
    assert_kind_of CAStride, a[nil, :_]
    v = a[nil, :_]
    v[2, 0] = 99
    assert_equal 99, a[2]
  end

  def test_newaxis_store
    c = CArray.int32(5) { 0 }
    c[:_, nil] = CArray.int32(1, 5) { |i, j| j + 10 }
    assert_equal [10, 11, 12, 13, 14], c.to_a
  end

  def test_outer_product_via_newaxis
    a = CArray.int32(4).seq   # [0,1,2,3]
    m = a[nil, :_] * a[:_, nil]
    assert_equal [4, 4], m.dim
    assert_equal 6, m[2, 3]   # 2*3
  end

  # --- AC8 / reject cases (IndexError) ---

  def test_all_scalar_newaxis_raises
    a = CArray.int32(3, 4).seq
    assert_raise(IndexError) { a[2, 3, :_] }
  end

  def test_partial_newaxis_raises
    a = CArray.int32(3, 4).seq
    assert_raise(IndexError) { a[2, :_] }   # 1 real index for ndim 2
  end

  def test_bare_newaxis_raises
    # bare ca[:_] (no per-axis indices) -> raise; no NumPy-style trailing
    # ALL fill (CArray explicit-axis philosophy).  Use ca[:_, nil, ...].
    a = CArray.int32(3, 4).seq
    assert_raise(IndexError) { a[:_] }
    v = CArray.int32(5).seq
    assert_raise(IndexError) { v[:_] }
  end

  def test_newaxis_mixed_with_slab_raises
    a = CArray.int32(3, 4).seq
    assert_raise(IndexError) { a[:_, :>, nil] }
  end

  def test_newaxis_mixed_with_rubber_raises
    a = CArray.int32(3, 4).seq
    assert_raise(IndexError) { a[:_, false] }
  end

end

class TestSlabSigil < Test::Unit::TestCase

  def setup
    @a = CArray.int32(3, 4).seq   # [[0,1,2,3],[10,11,12,13]...] actually seq 0..11
  end

  # --- AC4: parity with each_slab ---

  def test_row_iterator_parity
    rows = []
    @a[nil, :>].each { |s| rows << s.to_a }
    ref = []
    @a.each_slab(axis: 1) { |s| ref << s.to_a }
    assert_equal ref, rows
  end

  def test_column_iterator_parity
    cols = []
    @a[:>, nil].each { |s| cols << s.to_a }
    ref = []
    @a.each_slab(axis: 0) { |s| ref << s.to_a }
    assert_equal ref, cols
  end

  # --- named reductions: delegate to core per-axis over the slab axes ---

  def test_slab_named_reductions_parity
    si = @a[nil, :>]                       # slab = axis 1
    assert_equal @a.sum(axis: 1).to_a,      si.sum.to_a
    assert_equal @a.prod(axis: 1).to_a,     si.prod.to_a
    assert_equal @a.mean(axis: 1).to_a,     si.mean.to_a
    assert_equal @a.min(axis: 1).to_a,      si.min.to_a
    assert_equal @a.max(axis: 1).to_a,      si.max.to_a
    assert_equal @a.variance(axis: 1).to_a, si.variance.to_a
    assert_equal @a.stddev(axis: 1).to_a,   si.stddev.to_a
  end

  def test_slab_count_family_and_elements
    si = @a[nil, :>]
    # elements: constant slab size (4 cells per row), shaped like the outer space
    assert_equal [4, 4, 4], si.elements.to_a
    # count no-arg == count_not_masked; count(v) matches core
    assert_equal @a.count_not_masked(axis: 1).to_a, si.count.to_a
    assert_equal @a.count(5, axis: 1).to_a,         si.count(5).to_a
    # mask reflected in count_masked / count_not_masked, not in elements
    b  = @a.to_ca; b[0, 0] = UNDEF
    sb = b[nil, :>]
    assert_equal [1, 0, 0], sb.count_masked.to_a
    assert_equal [3, 4, 4], sb.count_not_masked.to_a
    assert_equal [4, 4, 4], sb.elements.to_a          # structural, mask-independent
  end

  def test_slab_tier2_parity
    si = @a[nil, :>]
    assert_equal @a.variancep(axis: 1).to_a, si.variancep.to_a
    assert_equal @a.stddevp(axis: 1).to_a,   si.stddevp.to_a
    assert_equal @a.min_index(axis: 1).to_a, si.min_index.to_a
    assert_equal @a.max_index(axis: 1).to_a, si.max_index.to_a
    smn, smx = si.minmax
    rmn, rmx = @a.minmax(axis: 1)
    assert_equal rmn.to_a, smn.to_a
    assert_equal rmx.to_a, smx.to_a
  end

  def test_slab_weighted
    a  = CA_DOUBLE([[1, 2, 3], [10, 20, 30]])
    w  = CA_DOUBLE([[1, 1, 2], [1, 1, 2]])
    si = a[nil, :>]
    assert_equal a.wsum(w, axis: 1).to_a,  si.wsum(w).to_a
    assert_equal a.wmean(w, axis: 1).to_a, si.wmean(w).to_a
    # multi-axis slab (core wsum/wmean accept multi-axis)
    b  = CA_DOUBLE([[[1, 2], [3, 4]], [[10, 20], [30, 40]]])
    wb = b * 0 + 1
    assert_equal b.wsum(wb, axis: [1, 2]).to_a, b[nil, :>, :>].wsum(wb).to_a
  end

  def test_slab_min_max_addr
    a  = CA_DOUBLE([[3, 1, 2], [6, 4, 5]])
    si = a[nil, :>]
    assert_equal a.min_index(axis: 1).to_a, si.min_index.to_a   # axis-local index
    assert_equal a.min_addr(axis: 1).to_a,  si.min_addr.to_a    # flat source address
    assert_equal a.max_addr(axis: 1).to_a,  si.max_addr.to_a
  end

  def test_slab_sort_addr_index_parity
    a  = CA_DOUBLE([[3, 1, 2], [6, 4, 5]])
    si = a[nil, :>]                       # slab = axis 1
    assert_equal a.sort_addr(axis: 1).to_a,  si.sort_addr.to_a   # flat source address
    assert_equal a.sort_index(axis: 1).to_a, si.sort_index.to_a  # axis-local index
    # column slab (axis 0)
    sj = a[:>, nil]
    assert_equal a.sort_addr(axis: 0).to_a,  sj.sort_addr.to_a
    assert_equal a.sort_index(axis: 0).to_a, sj.sort_index.to_a
    # a multi-axis slab has no single sort axis
    assert_raises(ArgumentError) { a[:>, :>].sort_addr }
    assert_raises(ArgumentError) { a[:>, :>].sort_index }
  end

  def test_slab_tier3_order_stats
    a  = CA_DOUBLE([[1, 2, 3, 4, 5], [10, 20, 30, 40, 50]])
    si = a[nil, :>]
    assert_equal a.median(axis: 1).to_a,         si.median.to_a
    assert_equal a.percentile(25, axis: 1).to_a, si.percentile(25).to_a
    q = si.quantile
    assert_equal 5, q.size
    assert_equal a.quantile(axis: 1).map(&:to_a), q.map(&:to_a)
    # multi-axis slab: the order stat folds each slab flat (via reduce_slab)
    b = CA_DOUBLE([[[1, 2], [3, 4]], [[10, 20], [30, 40]]])   # 2 slabs of 2x2
    assert_equal [2.5, 25.0], b[nil, :>, :>].median.to_a
    # masked source: each slab's order statistic skips masked cells (present
    # values only), inherited from the per-axis masked support.
    m = a.to_ca; m[0, 0] = UNDEF   # row0 present [2,3,4,5] -> median 3.5
    assert_equal [3.5, 30.0], m[nil, :>].median.to_a
  end

  # --- AC5: multi-axis slab ---

  def test_multi_axis_slab
    b = CArray.int32(2, 3, 4).seq
    shapes = []
    b[nil, :>, :>].each { |s| shapes << s.dim }
    assert_equal [[3, 4], [3, 4]], shapes
  end

  def test_multi_axis_slab_parity
    b = CArray.int32(2, 3, 4).seq
    got = []
    b[nil, :>, :>].each { |s| got << s.to_a }
    ref = []
    b.each_slab(axis: [1, 2]) { |s| ref << s.to_a }
    assert_equal ref, got
  end

  # --- AC6 / AC7: slice integration ---

  def test_slice_plus_slab
    got = []
    @a[1..2, :>].each { |s| got << s.to_a }
    ref = []
    @a[1..2, nil].each_slab(axis: 1) { |s| ref << s.to_a }
    assert_equal ref, got
  end

  def test_scalar_plus_slab
    b = CArray.int32(2, 3, 4).seq   # seq: b[1,0,0] = 1*12 = 12
    got = []
    b[1, :>, :>].each { |s| got << [s.dim, s[0, 0]] }
    assert_equal [[[3, 4], 12]], got
  end

  def test_non_trailing_slab
    b = CArray.int32(2, 3, 4).seq
    got = []
    b[nil, :>, nil].each { |s| got << s.dim }
    ref = []
    b.each_slab(axis: 1) { |s| ref << s.dim }
    assert_equal ref, got
  end

  # --- AC9: all-axis slab ---

  def test_all_axis_slab
    n = 0
    shape = nil
    @a[:>, :>].each { |s| n += 1; shape = s.dim }
    assert_equal 1, n
    assert_equal [3, 4], shape
  end

  # --- 1-D self ---

  def test_1d_slab
    a = CArray.int32(5).seq
    got = []
    a[:>].each { |s| got << s.to_a }
    assert_equal [[0, 1, 2, 3, 4]], got
  end

  # --- map / reduce ---

  def test_map_slab
    got = @a[nil, :>].map { |row| row + 1 }
    assert_equal (@a + 1).to_a, got.to_a
  end

  def test_reduce_per_slab
    got = @a[nil, :>].reduce { |slab| slab.sum }
    ref = []
    @a.each_slab(axis: 1) { |s| ref << s.sum }
    assert_equal ref, got.to_a
  end

  # --- class identity ---

  def test_class_is_slab_iterator
    assert_kind_of CASlabIterator, @a[nil, :>]
  end

  def test_introspection
    it = @a[nil, :>]
    assert_equal 1, it.ndim
    assert_equal [3], it.dim
    assert_equal [1], it.slab_axes
  end

  # --- store via :> rejected ---

  def test_store_via_slab_raises
    assert_raise(IndexError) { @a[nil, :>] = 0 }
  end

  # --- false rubber + :> = ndim-agnostic "rest outer + trailing slab" ---
  # (existing rubber expands to nil = outer, composes with :> slab markers;
  #  no dedicated rest-sigil needed — see proposal §8.1)

  def test_rubber_plus_slab_trailing
    a = CArray.int32(2, 3, 4, 5).seq
    got = []
    a[false, :>, :>].each { |s| got << s.dim }
    ref = []
    a.each_slab(axis: [-2, -1]) { |s| ref << s.dim }
    assert_equal ref, got
  end

  def test_rubber_plus_slab_single_trailing
    got = []
    @a[false, :>].each { |s| got << s.to_a }
    ref = []
    @a.each_slab(axis: -1) { |s| ref << s.to_a }
    assert_equal ref, got
  end

end

class TestSigilRetirementAndReservation < Test::Unit::TestCase

  # AC12: CADimensionIterator removed from the gem.
  def test_cadimensioniterator_removed
    assert_nil defined?(CADimensionIterator)
  end

  # :i / :j etc. still reserved for future contraction notation.
  def test_single_alpha_reserved_for_contraction
    a = CArray.int32(3, 4).seq
    %i[i j k a z].each do |sym|
      e = assert_raise(NotImplementedError) { a[sym, nil] }
      assert_match(/reserved for future contraction notation/, e.message)
    end
  end

  # Non-alphabet single-char symbol -> IndexError pointing at :>.
  def test_nonalphabet_symbol_indexerror_points_at_gt
    a = CArray.int32(3, 4).seq
    e = assert_raise(IndexError) { a[0, :"+"] }
    assert_match(/:>/, e.message)
  end

end
